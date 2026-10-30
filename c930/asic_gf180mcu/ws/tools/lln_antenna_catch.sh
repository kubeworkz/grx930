#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lln_antenna_catch.sh -- source this before `librelane` in a flow exec script.
#
#   . /work/ws/tools/lln_antenna_catch.sh
#
# Installs ws/tools/librelane_antenna_catch_patch.py: the antenna-repair step's
# repair_antennas call is wrapped in catch, so an abort inside OpenROAD's maze
# router (GRT-0183 heap underflow) ends the step with the database it had instead
# of ending the run. Measured on wave `fanout01`: 2,120 diodes inserted, then the
# abort on clknet_leaf_2609_clk_PAD2CORE, and the arm never reached DetailedRouting
# -- the step it existed to measure (doc:
# wafer_space_integration/sram_macro_surrogate.md).
#
# Installed by default, unlike the fanout pass: a repair that completes never
# enters the branch, so a successful run is unchanged, and the only outcome this
# changes is the one where the run would otherwise die. WS_ANTENNA_CATCH=0 skips it
# for an arm that wants the old fatal behaviour.
#
# Never fatal: without it the step runs exactly as LibreLane built it and any
# repair_antennas abort still ends the run, and the line printed here is the only
# place that says so.
#
# The interpreter is looked up the same way lln_reset_cts.sh does it: `python3` on
# PATH first (the image's dev shell has it), then the nix store, because a bare
# `sh -c` in this image has neither.

if [ "${WS_ANTENNA_CATCH:-1}" = "0" ]; then
    echo "PATCH_LLN_ANTENNA_CATCH status=disabled -- a repair_antennas abort will end the run"
    exit 0
fi

PYP=""
if command -v python3 >/dev/null 2>&1; then
    PYP=$(command -v python3)
fi
if [ -z "$PYP" ]; then
    for c in /nix/store/*-python3-3.13*/bin/python3.13; do
        [ -x "$c" ] && { PYP=$c; break; }
    done
fi
if [ -z "$PYP" ]; then
    echo "PATCH_LLN_ANTENNA_CATCH status=no-python -- a repair_antennas abort will end the run"
else
    "$PYP" /work/ws/tools/librelane_antenna_catch_patch.py 2>&1 \
        || echo "PATCH_LLN_ANTENNA_CATCH status=failed -- a repair_antennas abort will end the run"
fi
