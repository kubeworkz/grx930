#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lb_probe4.sh -- what gates LibreLane's antenna-repair steps, and what command
# they run. Needed to state the measurement's pre-DRT arm in the flow's own terms
# (the unmodified run dies inside OpenROAD.DiodeInsertion on the pinned build).
set -u
python3 - <<'PY'
import inspect
try:
    from librelane.steps import openroad as S
    for n in dir(S):
        if "Antenna" in n or "Diode" in n:
            obj = getattr(S, n)
            print("=====", n)
            try:
                print(inspect.getsource(obj))
            except Exception as e:
                print("no source:", e)
except Exception as e:
    print("probe error:", e)
PY
echo "== gating-variable hits =="
LIB=$(python3 -c 'import librelane, os; print(os.path.dirname(librelane.__file__))')
grep -rn "RUN_ANTENNA_REPAIR" "$LIB" 2>/dev/null | head -10
