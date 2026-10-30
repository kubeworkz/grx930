#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lb_probe2.sh -- read the LibreLane facts off the pre-check image: its CLI
# semantics for --from/--to/--only/--initial-state, the Chip flow's step ids and
# order, and the detailed-routing step's own tcl and flags. The die pre-DRT
# resume command is then built from what the image actually runs, not from
# memory of another flow's CLI.
set -u
echo "== librelane =="
librelane --version 2>&1 | head -2
LIB=$(python3 -c 'import librelane, os; print(os.path.dirname(librelane.__file__))')
echo "LIB=$LIB"
echo
echo "== openroad =="
command -v openroad || true
openroad -version 2>&1 | head -4
echo
echo "== librelane --help (full) =="
librelane --help 2>&1 | head -140
echo
echo "== Chip flow steps (id order) =="
python3 - <<'PY'
from librelane.flows import Flow
f = Flow.factory.get("Chip")
for i, s in enumerate(f.Steps):
    print(f"{i:3d} {getattr(s, 'id', s)}")
PY
echo
echo "== drt.tcl =="
sed -n '1,220p' "$LIB/scripts/openroad/drt.tcl"
echo
echo "== DetailedRouting python step =="
python3 - <<'PY'
import inspect
try:
    from librelane.steps import openroad as S
    cls = getattr(S, "DetailedRouting", None)
    print(inspect.getsource(cls) if cls else "no DetailedRouting in librelane.steps.openroad")
    print("--- CheckAntennas/RepairAntennas/DiodesOnPorts present:",
          [n for n in dir(S) if "ntenna" in n or "iodes" in n])
except Exception as e:
    print("probe error:", e)
PY
