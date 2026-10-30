#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# librelane_fanout_split_patch.py -- give the post-CTS resizer a fanout repair that
# bounds fanout instead of re-driving it.
#
# WHY
#
#   MAX_FANOUT_CONSTRAINT is 10 on this design (grx930_overrides.yaml / the SDC),
#   and nothing in the flow has ever enforced it on a data net: repair_design is
#   off at both of its positions (RUN_POST_GPL_DESIGN_REPAIR declined,
#   RUN_POST_GRT_DESIGN_REPAIR LibreLane's own false), so the only pass that
#   touches a high-fanout net is repair_timing's load splitting, and that answers
#   one with ONE buffer ahead of the same loads (`[INFO RSZ-0045] Inserted 2954
#   buffers, 133 to split loads.`).
#
#   Measured on the FF control (tag ffctl01, post-CTS netlist, 2026-10-29):
#
#     50 buffers named `split*` (all gf180mcu_fd_sc_mcu7t5v0__buf_12) drive
#     7,409 sinks between them; the largest is `split`, driving 1,072 pins off
#     i_chip_core.u_core.u_rom.line_p1[2]. The five copies of that net split its
#     2,083 sinks into groups of 1,072 / 537 / 269 / 136 / 69 -- one level, and
#     the largest group is never split again.
#
#     DRT then spends three routes on them: 727,148 -> 228,958 (pass 8 of the
#     first route), and the antenna repair adds its diodes to exactly those nets
#     (`GRT-0281 Net net has a large fanout of 1072 terminals`), so each re-route
#     starts higher than the last ended (doc:
#     wafer_space_integration/sram_macro_surrogate.md).
#
# WHAT
#
#   One insertion in scripts/openroad/rsz_timing_postcts.tcl, after the step's
#   own repair_timing and before `# Legalize` -- so the buffers this inserts are
#   legalized by the detailed placement the step already runs:
#
#     * raise the transition and capacitance limits for the length of the call,
#       leave the fanout limit at MAX_FANOUT_CONSTRAINT, run repair_design, put
#       the real limits back. Only fanout is repaired: with the real limits the
#       same call also answers this design's 79,417 max-slew and 7,036 max-cap
#       violations, which is the explosion class RUN_POST_GPL_DESIGN_REPAIR is
#       declined for (grx930_overrides.yaml);
#     * print the fanout tail before and after every call, because repair_design
#       splits by its own budget and does NOT reach the limit -- on the die it
#       took a 2,132-load reset to 172 in three levels
#       (ws/probe/reset_tree_fix.tcl). The loop stops when a call stops moving
#       the tail, and the number it reached is in the log either way.
#
#   Opt-in: WS_FANOUT_SPLIT=1 in the flow's environment. Off, the step prints one
#   line and behaves exactly as before, so an arm without it stays comparable to
#   the runs already on the box. WS_FANOUT_SPLIT_PASSES (default 2) bounds the
#   calls; each one costs a repair and a tail count.
#
# WHY A TEXT PATCH AND NOT A LIBRELANE CHANGE
#
#   Same reason as ws/tools/librelane_logflush_patch.py,
#   librelane_reset_cts_patch.py and librelane_1023_io_patch.py: the image is
#   pinned, and moving LibreLane is the image bump, not a run. /nix/store is
#   writable inside the container and every container starts from the unmodified
#   image, so the patch is applied at container start and cannot drift.
#
# WHEN IT IS CALLED
#
#   ws/tools/lln_fanout_split.sh, sourced by ws/ws_exec.sh (the FF column) next to
#   lln_logflush.sh and lln_reset_cts.sh. The insertion only runs when the flow's
#   -F/-T range includes the post-CTS resizer; a chain that starts after it is
#   unaffected.
#
# EXIT
#
#   0  applied, or already patched
#   2  nothing wrote a patch: file not found, pre-image absent, or not writable
import glob
import os
import sys

MARK = "# -- ws fanout split (ws/tools/librelane_fanout_split_patch.py)"

# The step's own repair_timing block ends here; the insertion lands between it and
# the `# Legalize` that sources common/dpl.tcl.
PREIMAGE = "\n# Legalize\nsource $::env(SCRIPTS_DIR)/openroad/common/dpl.tcl\n"

BLOCK = r'''
# -- ws fanout split (ws/tools/librelane_fanout_split_patch.py) ---------------
# The design-wide fanout limit is MAX_FANOUT_CONSTRAINT, but nothing in this flow
# has ever enforced it: repair_design is off at both of its positions, and
# repair_timing's load splitting re-drives a net behind one buffer instead of
# bounding it (`[INFO RSZ-0045] ... to split loads`). Measured after this step on
# the FF control: 50 such buffers carry 7,409 sinks, the largest 1,072 pins
# (doc: wafer_space_integration/sram_macro_surrogate.md).
#
# Only fanout is repaired. The transition and capacitance limits are raised for
# the length of each call and restored afterwards, because with the real limits
# repair_design also answers this design's 79,417 max-slew and 7,036 max-cap
# violations -- the explosion class RUN_POST_GPL_DESIGN_REPAIR is declined for.
#
# repair_design splits by its own budget, not to the limit (on the die it took a
# 2,132-load reset to 172 in three levels, ws/probe/reset_tree_fix.tcl), so the
# tail is printed after every call rather than assumed.
proc ws_fanout_tail {limit {top 5}} {
    set over [list]
    foreach net [get_nets -quiet *] {
        set loads 0
        foreach pin [get_pins -quiet -of_objects $net] {
            if { [string match "in*" [string tolower [get_property $pin direction]]] } { incr loads }
        }
        if { $loads > $limit } { lappend over [list $loads [get_name $net]] }
    }
    set over [lsort -integer -decreasing -index 0 $over]
    puts "\[INFO\] fanout-split: [llength $over] nets over $limit loads; worst [lrange $over 0 [expr {$top - 1}]]"
    return [llength $over]
}

if { [info exists ::env(WS_FANOUT_SPLIT)] && $::env(WS_FANOUT_SPLIT) ne "" && $::env(WS_FANOUT_SPLIT) ne "0" } {
    set ws_limit $::env(MAX_FANOUT_CONSTRAINT)
    set ws_passes 2
    if { [info exists ::env(WS_FANOUT_SPLIT_PASSES)] && $::env(WS_FANOUT_SPLIT_PASSES) ne "" } {
        set ws_passes $::env(WS_FANOUT_SPLIT_PASSES)
    }
    set ws_cells0 [llength [get_cells -quiet *]]
    set ws_before [ws_fanout_tail $ws_limit]
    set ws_now $ws_before
    for { set ws_i 1 } { $ws_i <= $ws_passes } { incr ws_i } {
        if { $ws_now == 0 } { break }
        set_max_transition 1000 [current_design]
        set_max_capacitance 1000 [current_design]
        set_max_fanout $ws_limit [current_design]
        puts "\[INFO\] fanout-split: repair_design pass $ws_i of $ws_passes, fanout = $ws_limit, slew/cap raised for the call"
        log_cmd repair_design
        set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
        set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
        set ws_next [ws_fanout_tail $ws_limit]
        if { $ws_next >= $ws_now } {
            puts "\[INFO\] fanout-split: pass $ws_i moved nothing ($ws_now -> $ws_next); stopping"
            break
        }
        set ws_now $ws_next
    }
    puts "\[INFO\] fanout-split: nets over $ws_limit loads $ws_before -> $ws_now; [expr {[llength [get_cells -quiet *]] - $ws_cells0}] cells inserted"
} else {
    puts "\[INFO\] fanout-split: off (WS_FANOUT_SPLIT unset); the resizer's load splitting is the only fanout repair"
}
'''

# The step's tcl is reached under two store layouts on this image: the pinned
# python env that COMMANDS names, and (on some builds) a python3.13-librelane
# derivation. Both are patched when present; patching is idempotent.
CANDIDATES = (
    "/nix/store/*-python3-3.13.9-env/lib/python3.13/site-packages/librelane/scripts/openroad/rsz_timing_postcts.tcl",
    "/nix/store/*-python3.13-librelane-*/lib/python3.13/site-packages/librelane/scripts/openroad/rsz_timing_postcts.tcl",
    "/nix/store/*-librelane-*/lib/python3.13/site-packages/librelane/scripts/openroad/rsz_timing_postcts.tcl",
)


def say(status, detail=""):
    print(f"PATCH_LLN_FANOUT_SPLIT status={status}{(' ' + detail) if detail else ''}", flush=True)


def targets():
    override = os.environ.get("LLN_FANOUT_TCL")
    if override:
        return [override]
    if len(sys.argv) > 1:
        return [sys.argv[1]]
    globs = os.environ.get("LLN_FANOUT_STORE_GLOB")
    patterns = (globs,) if globs else CANDIDATES
    found = []
    for pattern in patterns:
        for path in sorted(glob.glob(pattern)):
            if path not in found:
                found.append(path)
    return found


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
    if PREIMAGE not in text:
        say("missing-preimage", f"file={path} expected={PREIMAGE.strip().splitlines()[0]!r}")
        return 2
    patched = text.replace(PREIMAGE, "\n" + BLOCK + PREIMAGE, 1)
    try:
        with open(path, "w", encoding="utf8") as f:
            f.write(patched)
    except OSError as e:
        say("read-only", f"file={path} err={e.strerror}")
        return 2
    # Read it back: a patch that reported success and did not land would leave
    # every net at the fanout the resizer gave it, and the run would say nothing.
    try:
        with open(path, "r", encoding="utf8") as f:
            back = f.read()
    except OSError:
        back = ""
    legalize = "source $::env(SCRIPTS_DIR)/openroad/common/dpl.tcl"
    ok = (
        MARK in back
        and "log_cmd repair_design" in back
        and "ws_fanout_tail" in back
        and "set_max_transition $::env(MAX_TRANSITION_CONSTRAINT)" in back
        and back.count(MARK) == 1
        and back.count("log_cmd repair_design") == 1
        and back.count(legalize) == 1
        # the insertion must land before the step legalizes, or the buffers it
        # adds are never placed
        and back.index(MARK) < back.index(legalize)
    )
    if not ok:
        say("verify-failed", f"file={path}")
        return 2
    say("applied", f"file={path}")
    return 0


def main():
    found = targets()
    if not found:
        say("not-found", f"glob={CANDIDATES[0]}")
        return 2
    rc = 2
    for path in found:
        r = patch_one(path)
        if r != 0:
            rc = r
        elif rc != 0:
            rc = 0
    return rc


if __name__ == "__main__":
    sys.exit(main())
