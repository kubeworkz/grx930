#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# librelane_reset_cts_patch.py -- give CTS the reset nets, so the reset reaches the
# post-CTS resizer as a tree instead of as one net with thousands of loads.
#
# WHY
#
#   LibreLane's CTS step calls `clock_tree_synthesis` with no `-clk_nets`
#   (scripts/openroad/cts.tcl), so the tool trees the nets the SDC declared as
#   clocks and nothing else. An asynchronous reset is not a clock, so it is never
#   treed -- it stays a single net from the pad to every flop's RN pin.
#
#   Measured on this design (die, post-antenna-repair database, 2026-10-27):
#
#     i_chip_core.rst_n   4,266 pins at the CTS position (4,204 sequential loads)
#     split25             a clkbuf_16 inserted by ResizerTimingPostCTS (step 35,
#                         `[INFO RSZ-0045] Inserted 2954 buffers, 133 to split
#                         loads.`) driving net25 with 2,132 loads
#     transition at _351675_/RN   21.3 ns (pinned engine) / 46.8 ns (26Q4)
#                         against MAX_TRANSITION_CONSTRAINT = 3
#     setup WNS          -0.0640 ns (pinned) / -8.6457 ns (26Q4) -- the same
#                        database, two engines, because both extrapolate the
#                        delay of a 7-16x illegal transition differently
#                        (doc: wafer_space_integration/sta_engine_reconciliation.md)
#
#   `repair_timing`'s load splitting answers an over-loaded net with ONE buffer
#   ahead of the same loads (`133 to split loads`): it re-drives the fanout, it
#   does not bound it. The step that does bound fanout is `repair_design`, and
#   both of its positions are off (RUN_POST_GPL_DESIGN_REPAIR declined, see
#   grx930_overrides.yaml; RUN_POST_GRT_DESIGN_REPAIR is LibreLane's own false).
#
#   CTS is the one pass in this flow that takes a NET LIST, so it is the one pass
#   that can be pointed at the reset without also re-doing the whole design. It
#   builds a bounded tree (sink-clustering stop criterion; measured on the core's
#   pre-CTS database: 4,265 loads -> 210 nets, 11-23 loads each, in ~2 min, against
#   4,266 pins and 4,204 sequential loads before) and then every later pass sees
#   nets it can drive.
#
# WHAT
#
#   Two insertions in scripts/openroad/cts.tcl, both inside the CTS step:
#
#   1. A proc `ws_reset_cone_nets` that returns the reset nets whose fanout
#      exceeds MAX_FANOUT_CONSTRAINT: the input pad's own net, plus -- if a
#      resizer has already fragmented the reset behind load-split buffers -- every
#      net in that cone those buffers re-drive. `CTS_RESET_NETS` (space separated
#      names) overrides the search; `CTS_RESET_NET_PATTERN` overrides the pad
#      name glob (default `*rst*`), and the pad is recognised by its master
#      (`*in_c*`/`*in_s*`, the gf180mcu_fd_io input pads) and its `Y` output.
#
#   2. Those nets are declared as clock roots for this step (`create_clock` on the
#      pin that drives each net), which is what makes CTS tree them: with no
#      `-clk_nets`, clock_tree_synthesis trees the nets the SDC declares as clocks.
#      The alternative -- passing `-clk_nets` yourself -- replaces that discovery and
#      needs the clock's net name, which these databases do not have (see below).
#      The declaration lives in the step's process only; no database and no later
#      step sees it.
#
#   Nothing is fatal: with no reset pad found, or an unresolvable CLOCK_NET, the
#   step runs as before and the log says which.
#
# WHY A TEXT PATCH AND NOT A LIBRELANE CHANGE
#
#   Same reason as ws/tools/librelane_logflush_patch.py and
#   ws/tools/librelane_1023_io_patch.py: the image is pinned, and moving LibreLane
#   is the image bump, not a run. /nix/store is writable inside the container and
#   every container starts from the unmodified image, so the patch is applied at
#   container start and cannot drift from the image.
#
# WHEN IT IS CALLED
#
#   ws/tools/lln_reset_cts.sh, sourced by ws/ws_exec.sh and ws/die_predrt_exec.sh
#   next to lln_logflush.sh, so every arm that can run the CTS step carries it.
#   The step only runs when the flow's -F/-T range includes OpenROAD.CTS; the
#   die's post-GRT chains start after it and are unaffected.
#
# EXIT
#
#   0  applied, or already patched
#   2  nothing wrote a patch: file not found, pre-image absent, or not writable
import glob
import os
import sys

MARK = "# reset-cts: ws/tools/librelane_reset_cts_patch.py"

PRE_PROC = "set arg_list [list]\nlappend arg_list -buf_list [get_buflist]\n"
POST_PROC = r"""# reset-cts: ws/tools/librelane_reset_cts_patch.py
#
# The reset nets whose fanout is over the design's limit. The reset is not a
# clock, so the SDC never declared it and CTS was never given it: it reaches the
# post-CTS resizer as one net with thousands of loads, and load splitting answers
# that with a single buffer in front of the same loads. See the patch file.
# Loads on a net. Counted pin by pin rather than with
# `get_pins -filter "direction==in"`: OpenSTA's property value is `input`
# (`inout`/`internal` also exist), a filter that matches nothing reports every net
# as compliant, and a reset that is silently "compliant" is never treed -- the
# exact failure this patch exists to remove.
proc ws_net_loads {net} {
    set n 0
    foreach pin [get_pins -quiet -of_objects [get_nets $net]] {
        if { [string match "in*" [string tolower [get_property $pin direction]]] } { incr n }
    }
    return $n
}

# Output nets of a cell, for the same reason as ws_net_loads: no `direction==out`
# filter, which matches nothing in OpenSTA.
proc ws_out_nets {cell} {
    set nets [list]
    foreach pin [get_pins -quiet -of_objects $cell] {
        if { [string match "out*" [string tolower [get_property $pin direction]]] } {
            foreach net [get_nets -quiet -of_objects $pin] { lappend nets $net }
        }
    }
    return $nets
}

proc ws_reset_cone_nets {limit} {
    set explicit [list]
    if { [info exists ::env(CTS_RESET_NETS)] && $::env(CTS_RESET_NETS) ne "" } {
        foreach n $::env(CTS_RESET_NETS) {
            foreach nn [get_nets -quiet $n] {
                if { [lsearch -exact $explicit $nn] < 0 } { lappend explicit $nn }
            }
        }
        return $explicit
    }
    set pattern "*rst*"
    if { [info exists ::env(CTS_RESET_NET_PATTERN)] && $::env(CTS_RESET_NET_PATTERN) ne "" } {
        set pattern $::env(CTS_RESET_NET_PATTERN)
    }
    set queue [list]
    foreach inst [get_cells -quiet *] {
        set name [get_name $inst]
        if { ![string match -nocase $pattern $name] } { continue }
        set master [get_property $inst ref_name]
        if { ![string match -nocase "*in_c*" $master] && ![string match -nocase "*in_s*" $master] } { continue }
        foreach pin [get_pins -quiet "$name/Y"] {
            foreach net [get_nets -quiet -of_objects $pin] {
                if { [lsearch -exact $queue $net] < 0 } { lappend queue $net }
            }
        }
    }
    set seen [list]
    set out [list]
    while { [llength $queue] } {
        set net [lindex $queue 0]
        set queue [lrange $queue 1 end]
        if { [lsearch -exact $seen $net] >= 0 } { continue }
        lappend seen $net
        set loads [ws_net_loads $net]
        set through [list]
        foreach cell [get_cells -quiet -of_objects [get_nets $net]] {
            set mast [string tolower [get_property $cell ref_name]]
            # A buffer is the only cell the reset distribution can continue
            # through; anything else is a load, and a gate behind the reset is not
            # part of the distribution.
            if { ![string match "*buf*" $mast] } { continue }
            foreach onet [ws_out_nets $cell] {
                if { [lsearch -exact $queue $onet] < 0 && [lsearch -exact $through $onet] < 0 } {
                    lappend through $onet
                }
            }
        }
        if { $loads > $limit } { lappend out [get_name $net] }
        foreach onet $through {
            if { [lsearch -exact $queue $onet] < 0 } { lappend queue $onet }
        }
    }
    return $out
}

set ws_fanout_limit 10
if { [info exists ::env(MAX_FANOUT_CONSTRAINT)] && $::env(MAX_FANOUT_CONSTRAINT) ne "" } {
    set ws_fanout_limit $::env(MAX_FANOUT_CONSTRAINT)
}
# The reset is declared as a clock root FOR THIS STEP ONLY. `clock_tree_synthesis`
# with no -clk_nets trees the nets the SDC declares as clocks, so declaring the
# reset is how it gets treed without touching the clock's own net list.
#
# Why not pass -clk_nets explicitly (the first version of this patch did): passing it
# REPLACES the default net list, so the clock's net has to be named -- and it is not,
# on either of this design's databases. `get_nets -of_objects [get_pins $CLOCK_NET]`
# answers with an OpenSTA synthetic handle (`_b09185b2e7bf0000_p_Net` on
# ws_arm64_v1/32, `_b8927b36aec60000_p_Net` on the die), and a name clock_tree_
# synthesis cannot find answers `[ERROR CTS-0056]`, i.e. the CLOCK would go untreed to
# buy a reset tree. Declaring a clock leaves the step's own discovery alone: measured
# on both databases, `create_clock` on the reset's driver pin is the form that works.
#
# The clock is not written into any database: it lives in this step's process, which
# is discarded when the step ends, and every later step re-reads the SDC.
set ws_reset_nets [ws_reset_cone_nets $ws_fanout_limit]
if { [llength $ws_reset_nets] } {
    set ws_declared 0
    foreach net $ws_reset_nets {
        foreach pin [get_pins -quiet -of_objects [get_nets $net]] {
            if { [string match "out*" [string tolower [get_property $pin direction]]] } {
                incr ws_declared
                catch {
                    create_clock -name "ws_reset_$ws_declared" \
                        -period $::env(CLOCK_PERIOD) $pin
                    puts "\[INFO\] reset-cts: $net declared as a CTS clock root at $pin"
                } ws_reset_err
            }
        }
    }
    if { $ws_declared == 0 } {
        puts "\[WARNING\] reset-cts: $ws_reset_nets found but not one could be declared a clock root; clock nets unchanged"
    }
    if { [info exists ws_reset_err] && $ws_reset_err ne "" } {
        puts "\[WARNING\] reset-cts: $ws_reset_err"
    }
} else {
    puts "\[INFO\] reset-cts: no reset net over $ws_fanout_limit loads found; clock nets unchanged"
}

set arg_list [list]
lappend arg_list -buf_list [get_buflist]
"""

PRE_CALL = "log_cmd clock_tree_synthesis {*}$arg_list\n"
POST_CALL = (
    r'puts "\[INFO\] reset-cts: CTS clock roots are the SDC clocks plus any reset root declared above' + '"\n'
    "log_cmd clock_tree_synthesis {*}$arg_list\n"
)

CANDIDATE = "/nix/store/*-python3.13-librelane-*/lib/python3.13/site-packages/librelane/scripts/openroad/cts.tcl"


def say(status, detail=""):
    print(f"PATCH_LLN_RESET_CTS status={status}{(' ' + detail) if detail else ''}", flush=True)


def targets():
    override = os.environ.get("LLN_CTS_TCL")
    if override:
        return [override]
    if len(sys.argv) > 1:
        return [sys.argv[1]]
    return sorted(glob.glob(CANDIDATE))


def patch_one(path):
    try:
        with open(path, "r", encoding="utf8") as f:
            text = f.read()
    except OSError as e:
        say("unreadable", f"file={path} err={e.strerror}")
        return 2
    if MARK in text:
        say("already-patched", f"file={path}")
        return 0
    if PRE_PROC not in text:
        say("missing-preimage", f"file={path} expected={PRE_PROC.splitlines()[0]!r}")
        return 2
    if PRE_CALL not in text:
        say("missing-preimage", f"file={path} expected={PRE_CALL.strip()!r}")
        return 2
    patched = text.replace(PRE_PROC, POST_PROC, 1).replace(PRE_CALL, POST_CALL, 1)
    try:
        with open(path, "w", encoding="utf8") as f:
            f.write(patched)
    except OSError as e:
        say("read-only", f"file={path} err={e.strerror}")
        return 2
    # Read it back: a patch that reported success and did not land would leave the
    # reset untreed for the whole run, and the log would not say so.
    try:
        with open(path, "r", encoding="utf8") as f:
            back = f.read()
    except OSError:
        back = ""
    if MARK not in back or "ws_reset_cone_nets" not in back or "-clk_nets" not in back:
        say("verify-failed", f"file={path}")
        return 2
    say("applied", f"file={path}")
    return 0


def main():
    found = targets()
    if not found:
        say("not-found", f"glob={CANDIDATE}")
        return 2
    rc = 2
    for path in found:
        r = patch_one(path)
        if r == 0:
            return 0
        rc = r
    return rc


if __name__ == "__main__":
    sys.exit(main())
