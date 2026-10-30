#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# antenna_recon.sh -- what is actually in the pinned image, for the antenna-repair
# abort. Read-only: prints versions, the step's own script, and every config
# variable LibreLane declares for it. The point is that the lever list is measured
# here rather than assumed from documentation for a different build.
set -u
echo "== entrypoint / PATH =="
echo "PATH=$PATH"
echo "which librelane: $(command -v librelane || echo none)"
librelane --version 2>&1 | head -3
echo "which openroad:  $(command -v openroad || echo none)"
openroad -version 2>&1 | head -2
echo
echo "== python package =="
P=$(python3 -c "import librelane,os;print(os.path.dirname(librelane.__file__))" 2>/dev/null)
echo "librelane dir: ${P:-none}"
if [ -n "${P:-}" ]; then
    python3 -c "import librelane;print('librelane.__version__:', getattr(librelane,'__version__','?'))" 2>&1 | head -2
    echo
    echo "== the step module =="
    ls "$P/steps/OpenROAD" 2>/dev/null | head -50
    echo
    echo "== every GRT_ANTENNA_* / antenna variable it declares =="
    grep -rn "GRT_ANTENNA" "$P" --include=*.py | head -30
    echo
    echo "== RepairAntennas step source =="
    f=$(ls "$P/steps/OpenROAD/RepairAntennas.py" 2>/dev/null || grep -rln "class RepairAntennas" "$P" --include=*.py | head -1)
    echo "file: ${f:-none}"
    [ -n "${f:-}" ] && sed -n '1,120p' "$f"
fi
echo
echo "== the tcl the step runs =="
t=$(find /nix/store /usr /opt -name "antenna_repair.tcl" 2>/dev/null | head -1)
echo "path: ${t:-none}"
[ -n "${t:-}" ] && cat "$t"
