#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lln_reset_cts.sh -- source this before `librelane` in a flow exec script.
#
#   . /work/ws/tools/lln_reset_cts.sh
#
# Installs ws/tools/librelane_reset_cts_patch.py: the CTS step declares the reset
# as a clock root (`create_clock` on the pin that drives each over-limit reset
# net), so the reset reaches the post-CTS resizer as a bounded tree instead of one
# 4,265-load net that load splitting re-drives behind a single buffer (measured:
# `split25`, 2,132 loads, 21-47 ns transition against a 3 ns limit, and the
# pinned/26Q4 STA disagreement it causes -- doc:
# wafer_space_integration/sta_engine_reconciliation.md and reset_distribution_fix.md).
#
# `-clk_nets` is deliberately NOT used: it replaces LibreLane's own clock-net
# discovery, and this design's clock net has no database name to pass.
#
# Never fatal: without it CTS runs exactly as LibreLane built it, the reset stays
# untreed, and the line printed here is the only place that says so.
#
# The interpreter is looked up the same way lln_logflush.sh does it: `python3` on
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
    echo "PATCH_LLN_RESET_CTS status=no-python -- CTS will not tree the reset nets"
else
    "$PYP" /work/ws/tools/librelane_reset_cts_patch.py 2>&1 \
        || echo "PATCH_LLN_RESET_CTS status=failed -- CTS will not tree the reset nets"
fi
