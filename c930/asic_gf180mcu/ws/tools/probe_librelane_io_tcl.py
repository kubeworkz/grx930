#!/usr/bin/env python3
# probe_librelane_io_tcl.py -- read the INSTALLED LibreLane's io.tcl and the
# get_script_dir()/SCRIPTS_DIR wiring, so the #1023 backport can be written
# against the file that is actually there rather than against the diff's
# 3.0.12 pre-image.
#
# Runs INSIDE the flow image (no sed there):
#   docker run --rm -i --entrypoint python3 IMG - < probe_librelane_io_tcl.py
#
# Why: the pin arm (ws/tools/openroad_26q4.sh) dies at flow level with
#   [ERROR STA-0107] <id>_p_Scene is not the name of a scene.
# because this image's LibreLane predates #1023 (io.tcl's scene handling for
# OpenSTA >= 3.1, commit 998806cb). The backport is a text patch to this exact
# file; this probe prints the text to patch and checks it is writable.
import glob
import os
import sys

roots = sorted(glob.glob("/nix/store/*librelane*/lib/python*/site-packages/librelane"))
if not roots:
    print("no librelane install found")
    sys.exit(1)
root = roots[-1]
print("LIBRELANE_ROOT", root)

io_tcl = os.path.join(root, "scripts", "openroad", "common", "io.tcl")
print("IO_TCL", io_tcl, "writable=%s" % os.access(io_tcl, os.W_OK))
text = open(io_tcl, encoding="utf-8").read()
lines = text.splitlines()
print("IO_TCL_LINES", len(lines))
print("HAS scene_name proc:", "proc scene_name" in text)
print("HAS sta::is_object:", "sta::is_object" in text)
print("HAS sta::scenes:", "sta::scenes" in text)
print("HAS set_cmd_scene:", "set_cmd_scene" in text)
print("HAS find_scene:", "find_scene" in text)
print("--- io.tcl lines 1-80 ---")
for i, line in enumerate(lines[:80], 1):
    print("%4d %s" % (i, line))
print("--- get_script_dir / SCRIPTS_DIR wiring ---")
for path in glob.glob(os.path.join(root, "**", "*.py"), recursive=True):
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        continue
    if "def get_script_dir" in src or "SCRIPTS_DIR" in src:
        for i, line in enumerate(src.splitlines(), 1):
            if "get_script_dir" in line or "SCRIPTS_DIR" in line:
                print("%s:%d: %s" % (os.path.relpath(path, root), i, line.strip()))
