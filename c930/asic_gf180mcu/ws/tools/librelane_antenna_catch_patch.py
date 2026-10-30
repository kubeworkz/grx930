#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# librelane_antenna_catch_patch.py -- let the antenna-repair step survive a
# repair_antennas abort instead of taking the whole run down with it.
#
# WHY
#
#   scripts/openroad/antenna_repair.tcl calls
#
#       log_cmd repair_antennas {*}$arg_list
#
#   and `log_cmd` (scripts/openroad/common/io.tcl:757) is a pass-through: it
#   prints the command and returns the call, so an error inside repair_antennas
#   propagates out of the script and OpenROAD exits non-zero. LibreLane then
#   reports `OpenROAD.DiodeInsertion failed with ...` and quits the flow.
#
#   That is how wave `fanout01` died at 19:57 on 29 Oct, after 2,120 diodes and
#   before its DetailedRouting step ever started:
#
#       [INFO GRT-0015] Inserted 2120 diodes.
#       [WARNING GRT-0243] Unable to repair antennas on net with diodes.
#       [ERROR GRT-0183] Net clknet_leaf_2609_clk_PAD2CORE: heap underflow
#                        during 3D maze routing.
#       Error: antenna_repair.tcl, 27 GRT-0183
#
#   GRT-0183 is an engine bug inside OpenROAD's own maze router, not a verdict on
#   the database: the same abort is what stopped the die at RUN_ANTENNA_REPAIR=false
#   on this build, and the only upstream fix is the newer GRT that
#   ws/tools/openroad_26q4.sh pins. An arm that is measuring something else --
#   here, whether the post-CTS fanout split moves DRT's short count -- should not
#   lose its database to it.
#
# WHAT
#
#   One insertion, wrapping the existing call:
#
#       log_cmd repair_antennas {*}$arg_list
#     ->if {[catch {log_cmd repair_antennas {*}$arg_list} err]} {
#           puts "PATCH_LNN_ANTENNA status=caught error=\"$err\""
#           ...
#       }
#
#   repair_antennas mutates the odb as it goes, so the diodes inserted for the
#   nets it reached before the abort are already in the database. Catching the
#   error therefore keeps a database of the same shape a completed repair gives,
#   minus the nets the maze router never reached; the step's own second sub-step
#   (CheckAntennas) reports that residue, and `write_views` below persists it.
#
#   A step whose repair completes never enters the branch -- the tcl it runs, the
#   commands it issues and the database it writes are byte-identical to the
#   unpatched flow. Only a step that would have aborted changes outcome, from
#   "the run dies here" to "the run continues with an unrepaired net".
#
#   The abort is never silent: the step log carries two PATCH_LNN_ANTENNA lines
#   naming the error, so the harvest and the run record can tell a clean repair
#   from a caught one. `build/ws_chain.sh` greps ERROR/Fatal in the flow log and
#   the caught error is printed as a warning-level line, so it survives there too.
#
# WHY A TEXT PATCH AND NOT A LIBRELANE CHANGE
#
#   Same reason as the other patches in this directory: the image is pinned, and
#   moving LibreLane is the image bump, not a run. /nix/store is writable inside
#   the container (docker's writable layer over the image) and every new container
#   starts from the unmodified image, so the patch is applied at container start
#   and cannot drift; the host run tree is untouched.
#
# WHEN IT IS CALLED
#
#   ws/tools/lln_antenna_catch.sh, sourced by ws/ws_exec.sh before librelane runs.
#   Never fatal on its own: a missing pre-image leaves the step exactly as
#   LibreLane built it, and the status line says so.
#
# EXIT
#
#   0  applied, or already patched
#   2  nothing wrote a patch: file not found, pre-image absent, or not writable
import glob
import os
import sys

PRE = "log_cmd repair_antennas {*}$arg_list\n"

POST = """# antenna_catch: ws/tools/librelane_antenna_catch_patch.py
# repair_antennas drives the 3D maze router once per iteration, and on this engine
# build one net can take it into GRT-0183 (heap underflow) -- which takes the step,
# and with it the whole run, down at a step that is not the one being measured. The
# diodes inserted for the nets before it are already in the odb, so catch the abort,
# name the error, and let the step write the database it has. A repair that
# completes never enters this branch and runs exactly as LibreLane built it.
if {[catch {log_cmd repair_antennas {*}$arg_list} err]} {
    puts "PATCH_LNN_ANTENNA status=caught error=\\"$err\\""
    puts "PATCH_LNN_ANTENNA the diodes inserted before the abort are kept; the step continues"
}
"""

MARK = "# antenna_catch:"
CANDIDATE = "/nix/store/*-librelane-*/lib/python3.13/site-packages/librelane/scripts/openroad/antenna_repair.tcl"


def say(status, detail=""):
    print(f"PATCH_LNN_ANTENNA_CATCH status={status}{(' ' + detail) if detail else ''}", flush=True)


def targets():
    override = os.environ.get("LLN_ANTENNA_TCL")
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
    if PRE not in text:
        say("missing-preimage", f"file={path} expected={PRE.strip()!r}")
        return 2
    try:
        with open(path, "w", encoding="utf8") as f:
            f.write(text.replace(PRE, POST, 1))
    except OSError as e:
        say("read-only", f"file={path} err={e.strerror}")
        return 2
    # Read it back: a patch that reported success and did not land would leave the
    # next run dying exactly where this one did, with no line in the log to say why.
    try:
        with open(path, "r", encoding="utf8") as f:
            landed = MARK in f.read()
    except OSError:
        landed = False
    if not landed:
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
