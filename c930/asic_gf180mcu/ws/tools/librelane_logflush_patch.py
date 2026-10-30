#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# librelane_logflush_patch.py -- make LibreLane's step logs line-buffered, so a
# step log is readable while the step is running instead of every 8 KB.
#
# WHY
#
#   steps/step.py runs the tool with `stdout=subprocess.PIPE` and copies it to the
#   step log with
#
#       log_file = open(log_path, "w")
#       ...
#       for line in process_stdout:
#           log_file.write(line)
#
#   `open(path, "w")` is block-buffered (8 KB) when the path is a file, so those
#   writes only reach the disk when the buffer fills. That is the second of the
#   two 8 KB gates on a DRT step log -- the first is the router's own stdio, which
#   ws/tools/openroad_26q4.sh line-buffers by preloading libstdbuf.so. Fixing
#   only the first one changes nothing: measured on diecg01, 182 log lines
#   arrived in a single 03:40:48 write after 42 minutes of silence, which is
#   indistinguishable from a router that has stopped working.
#
#   That matters because build/drt_curve_guard.sh stops a pass on an OPEN
#   iteration that stops printing (STALL_LOG_S). It refuses to act until it has
#   seen a flush land mid-iteration -- exactly the evidence a block-buffered log
#   cannot provide -- so with both gates in place its no-progress rule is inert
#   and a stall can only be caught by the 2 h wall clock.
#
# WHAT
#
#   One line, in the file that is already installed in the image:
#
#       log_file = open(log_path, "w")
#     ->log_file = open(log_path, "w", buffering=1)
#
#   Text mode + buffering=1 is line buffering: every `write(line)` from the copy
#   loop is flushed. The pre-image is checked verbatim first; if it is absent
#   (a different LibreLane build, or a file some earlier patch already changed)
#   nothing is written and the script exits 2 with `status=missing-preimage`.
#
# WHY A TEXT PATCH AND NOT A LIBRELANE CHANGE
#
#   Same reason as ws/tools/librelane_1023_io_patch.py: the image is pinned, and
#   moving LibreLane is the image bump, not a run. /nix/store is writable inside
#   the container (docker's writable layer over the image) and every new
#   container starts from the unmodified image, so the patch is applied at
#   container start and cannot drift; the host run tree is untouched.
#
# WHEN IT IS CALLED
#
#   ws/tools/lln_logflush.sh, sourced by ws/ws_exec.sh and ws/die_predrt_exec.sh
#   before librelane runs. Never fatal on its own: a missing patch leaves the log
#   block-buffered, which is the old behaviour, and the line it prints says so.
#
# EXIT
#
#   0  applied, or already patched
#   2  nothing wrote a patch: file not found, pre-image absent, or not writable
import glob
import os
import sys

PRE = '        log_file = open(log_path, "w")\n'
POST = (
    '        log_file = open(log_path, "w", buffering=1)  '
    "# logflush: ws/tools/librelane_logflush_patch.py\n"
)
MARK = "buffering=1)  # logflush:"
CANDIDATE = "/nix/store/*-python3.13-librelane-*/lib/python3.13/site-packages/librelane/steps/step.py"


def say(status, detail=""):
    print(f"PATCH_LLN_LOGFLUSH status={status}{(' ' + detail) if detail else ''}", flush=True)


def targets():
    override = os.environ.get("LLN_STEP_PY")
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
    # guard's no-progress rule silently disarmed for the whole run.
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
