#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# librelane_1023_io_patch.py -- backport LibreLane PR #1023's io.tcl scene
# handling into the flow image's installed LibreLane, in-container.
#
# WHY
#
#   The engine pin (ws/tools/openroad_26q4.sh) makes the die's global-routing
#   step complete on an OpenROAD that has the FastRoute fixes -- and then the
#   step dies as it finishes, on this image's LibreLane, not on the engine:
#
#     [ERROR STA-0107] _70aee23fd3100000_p_Scene is not the name of a scene.
#     ... (procedure "sta::parse_scene_or_null" line 15) ...
#
#   That is librelane/scripts/openroad/common/io.tcl treating an OpenSTA scene
#   as a string. OpenSTA commit 998806cb (2026-06-30) made scenes bridge as Tcl
#   objects, and this image's LibreLane 3.1.0.dev1 predates the fix -- PR #1023
#   ("handle OpenSTA scenes bridged as objects in io.tcl", merged 2026-09-06,
#   shipped in 3.0.13). The three procs below are the whole fix; this script
#   applies exactly those edits to the installed file.
#
# Why a text patch and not a LibreLane upgrade
#
#   * the image is pinned; moving LibreLane is the image bump, not a run
#   * the file is the same file the GRT step sources (`source
#     $::env(SCRIPTS_DIR)/openroad/common/io.tcl`, and SCRIPTS_DIR is set from
#     the Python package -- steps/tclstep.py:142 -- so an env override does not
#     exist to point elsewhere)
#   * /nix/store is WRITABLE inside the container (docker's writable layer over
#     the image), and each new container starts from the unmodified image, so
#     the patch is applied at container start and cannot drift: the host run
#     tree is untouched.
#
# WHEN IT IS CALLED
#
#   ws/die_predrt_exec.sh, guarded by PREDRT_PATCH_LLN=1023, before librelane
#   runs. Opt-in: unset, nothing here executes. Verified to apply cleanly (and
#   to be idempotent) by build/... / see the run log line PATCH_LLN for the
#   applied/unchanged verdict.
#
# WHAT IT WILL NOT DO
#
#   Guess. Every pre-image string is checked verbatim against the file first;
#   if any is absent (a different LibreLane build, or a partially patched file
#   from a future image), it writes nothing and exits 2 with the list.
import glob
import os
import sys

MARKER = "proc scene_name"
BACKUP_SUFFIX = ".pre1023"

# (pre-image, post-image) -- PR #1023 as merged, against the context that is
# actually in this image's file (checked: 3.1.0.dev1's io.tcl has the 3.0.12
# pre-image for all three procs).
EDITS = [
    (
        "namespace eval lln {\n"
        "    proc get_corner_names {} {\n",
        "namespace eval lln {\n"
        "    proc scene_name {scene} {\n"
        "        # OpenSTA >= 3.1 (commit 998806cb, 2026-06-30) bridges scenes as SWIG\n"
        "        # objects instead of strings. Older OpenSTA 3 bridges them as strings,\n"
        "        # in which case the value already is the name.\n"
        "        if { [sta::is_object $scene] } {\n"
        "            return [sta::get_property $scene name]\n"
        "        }\n"
        "        return $scene\n"
        "    }\n"
        "    proc get_corner_names {} {\n",
    ),
    (
        "        if {[string length [namespace which sta::scenes]] != 0} {\n"
        "            # scenes are bridged as a list of strings\n"
        "            return [sta::scenes]\n"
        "        } else {\n",
        "        if {[string length [namespace which sta::scenes]] != 0} {\n"
        "            set result [list]\n"
        "            foreach scene [sta::scenes] {\n"
        "                lappend result [scene_name $scene]\n"
        "            }\n"
        "            return $result\n"
        "        } else {\n",
    ),
    (
        "        # - in OpenSTA 3, that's the scene's name again\n"
        "        # - in OpenSTA 2, that's an opaque Tcl pointer\n"
        "        set result [dict create]\n"
        "        if {[string length [namespace which sta::scenes]] != 0} {\n"
        "            foreach scene [sta::scenes] {\n"
        "                dict set result $scene $scene\n"
        "            }\n",
        "        # - in OpenSTA 3, that's whatever sta::find_scene returns (a name in\n"
        "        #   OpenSTA 3.0, a Scene object since 3.1)\n"
        "        # - in OpenSTA 2, that's an opaque Tcl pointer\n"
        "        set result [dict create]\n"
        "        if {[string length [namespace which sta::scenes]] != 0} {\n"
        "            foreach scene [sta::scenes] {\n"
        "                set name [scene_name $scene]\n"
        "                dict set result $name [sta::find_scene $name]\n"
        "            }\n",
    ),
    (
        "    proc set_sta_cmd_corner {corner_name} {\n"
        "        if {[string length [namespace which sta::set_cmd_scene]] != 0} {\n"
        "            sta::set_cmd_scene $corner_name\n"
        "        } else {\n",
        "    proc set_sta_cmd_corner {corner_name} {\n"
        "        # sta::set_scene takes a name in every OpenSTA 3; sta::set_cmd_scene\n"
        "        # takes a name before 998806cb and a Scene object after.\n"
        "        if {[string length [namespace which sta::set_scene]] != 0} {\n"
        "            sta::set_scene $corner_name\n"
        "        } elseif {[string length [namespace which sta::set_cmd_scene]] != 0} {\n"
        "            sta::set_cmd_scene $corner_name\n"
        "        } else {\n",
    ),
]

POST_CHECKS = [
    "proc scene_name",
    "[sta::is_object $scene]",
    "sta::get_property $scene name",
    "lappend result [scene_name $scene]",
    "dict set result $name [sta::find_scene $name]",
    "if {[string length [namespace which sta::set_scene]] != 0}",
]


def find_io_tcl():
    hits = sorted(
        glob.glob(
            "/nix/store/*librelane*/lib/python*/site-packages/librelane/"
            "scripts/openroad/common/io.tcl"
        )
    )
    if not hits:
        # A LibreLane vendored into the run tree (not the image's) shows up
        # here. Fixed candidates only -- a recursive walk of /work is a walk
        # over the run trees and is not worth doing at container start.
        for cand in (
            "/work/ws/template/librelane/scripts/openroad/common/io.tcl",
            "/work/ws/librelane/scripts/openroad/common/io.tcl",
        ):
            if os.path.exists(cand):
                hits = [cand]
                break
    return hits[0] if hits else None


def main():
    path = find_io_tcl()
    if path is None:
        print("PATCH_LLN status=no-io-tcl (no installed LibreLane found)")
        return 2
    text = open(path, encoding="utf-8").read()
    if MARKER in text:
        print("PATCH_LLN status=already-patched io.tcl=%s" % path)
        return 0
    missing = [i for i, (pre, _) in enumerate(EDITS) if pre not in text]
    if missing:
        print(
            "PATCH_LLN status=preimage-mismatch io.tcl=%s edits_missing=%s "
            "-- refusing to guess" % (path, missing)
        )
        return 2
    patched = text
    for pre, post in EDITS:
        patched = patched.replace(pre, post, 1)
    bad = [s for s in POST_CHECKS if s not in patched]
    if bad:
        print("PATCH_LLN status=self-check-failed checks_missing=%s" % bad)
        return 2
    backup = path + BACKUP_SUFFIX
    if not os.path.exists(backup):
        with open(backup, "w", encoding="utf-8") as fh:
            fh.write(text)
    tmp = path + ".new"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(patched)
    os.replace(tmp, path)
    print(
        "PATCH_LLN status=applied pr=1023 io.tcl=%s backup=%s edits=%d checks=%d"
        % (path, backup, len(EDITS), len(POST_CHECKS))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
