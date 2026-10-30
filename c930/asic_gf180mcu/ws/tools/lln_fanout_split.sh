#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lln_fanout_split.sh -- source this before `librelane` in a flow exec script.
#
#   . /work/ws/tools/lln_fanout_split.sh
#
# Installs ws/tools/librelane_fanout_split_patch.py: the post-CTS resizer runs
# repair_design with the transition and capacitance limits raised, so the only
# violation class it answers is fanout, and the design's MAX_FANOUT_CONSTRAINT is
# enforced on data nets for the first time in this flow. Measured on the FF
# control, 50 load-split buffers carry 7,409 sinks and the largest drives 1,072
# pins off the ROM decode (doc: wafer_space_integration/sram_macro_surrogate.md).
#
# Opt-in: the patch installs the pass but the pass only runs when the flow is
# launched with WS_FANOUT_SPLIT=1. Without it the step prints one line and behaves
# exactly as it did, so an arm stays comparable to the runs already on the box.
# WS_FANOUT_SPLIT_PASSES (default 2) bounds how many repair_design calls it makes.
#
# Never fatal: without it the resizer runs exactly as LibreLane built it, every
# net keeps the fanout it had, and the line printed here is the only place that
# says so.
#
# The interpreter is looked up the same way lln_reset_cts.sh does it: `python3` on
# PATH first (the image's dev shell has it), then the nix store, because a bare
# `sh -c` in this image has neither.

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
    echo "PATCH_LLN_FANOUT_SPLIT status=no-python -- the resizer will not bound fanout"
else
    "$PYP" /work/ws/tools/librelane_fanout_split_patch.py 2>&1 \
        || echo "PATCH_LLN_FANOUT_SPLIT status=failed -- the resizer will not bound fanout"
fi
