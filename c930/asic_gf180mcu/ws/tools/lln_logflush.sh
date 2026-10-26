#!/bin/sh
# lln_logflush.sh -- source this before `librelane` in a flow exec script.
#
#   . /work/ws/tools/lln_logflush.sh
#
# It line-buffers the flow's step logs (ws/tools/librelane_logflush_patch.py) so a
# step log grows while the step runs rather than every 8 KB. Nothing here is fatal:
# without it the log is block-buffered, which is the old behaviour, and
# build/drt_curve_guard.sh falls back to its wall-clock bounds instead of its
# no-progress one -- and says so with CURVE_NO_PROGRESS_UNOBSERVED.
#
# The interpreter is looked up the same way ws/die_predrt_exec.sh looks it up for
# the 1023 backport: `python3` on PATH first (the image's dev shell has it), then
# the nix store, because a bare `sh -c` in this image has neither.

PYP=""
if command -v python3 >/dev/null 2>&1; then
    PYP=$(command -v python3)
fi
if [ -z "$PYP" ]; then
    for c in /nix/store/*-python3-3.13.9/bin/python3.13; do
        [ -x "$c" ] && { PYP=$c; break; }
    done
fi
if [ -z "$PYP" ]; then
    echo "PATCH_LLN_LOGFLUSH status=no-python -- step logs stay block-buffered"
else
    "$PYP" /work/ws/tools/librelane_logflush_patch.py 2>&1 \
        || echo "PATCH_LLN_LOGFLUSH status=failed -- step logs stay block-buffered"
fi
