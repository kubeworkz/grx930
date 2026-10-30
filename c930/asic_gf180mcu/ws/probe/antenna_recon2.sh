#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# antenna_recon2.sh -- who passes which antenna-repair flag, and with what script.
# The first probe found the four config variables; this one asks which of the two
# sub-steps inside OpenROAD.RepairAntennas sets them, because that decides whether a
# config change can reach the pass that aborts (measured: the abort is in the
# second invocation, OpenROAD.DiodeInsertion, not in the jumper pass).
set -u
P=$(python3 -c 'import librelane,os;print(os.path.dirname(librelane.__file__))')
echo "librelane=$P"
echo
echo "=== _DiodeInsertion, with the context that says what it is ==="
grep -n -B 16 -A 14 'class _DiodeInsertion' "$P/steps/openroad.py"
echo
echo "=== GlobalRouting: script it runs ==="
grep -n -A 42 '^class GlobalRouting' "$P/steps/openroad.py" | head -52
echo
echo "=== _DiodeInsertion / RepairAntennas env and script handling ==="
grep -rn 'jumper_only\|diode_only\|JUMPER_ONLY\|DIODE_ONLY\|antenna_repair' "$P" --include=*.py | head -30
echo
echo "=== the four variable declarations, with defaults ==="
grep -n -B 6 -A 12 'GRT_ANTENNA_REPAIR_ITERS' "$P/steps/common_variables.py"
