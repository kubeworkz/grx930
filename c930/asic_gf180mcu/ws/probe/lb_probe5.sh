#!/bin/sh
# lb_probe5.sh -- how LibreLane enforces the Metal1-Metal5 routing range, since
# this OpenROAD build rejects detailed_route's deprecated -bottom/-top_routing_layer
# flags (DRT-0509) and the flow's own drt.tcl passes none.
set -u
LIB=$(python3 -c 'import librelane, os; print(os.path.dirname(librelane.__file__))')
echo "LIB=$LIB"
echo
echo "== set_routing_layers / RT_MIN_LAYER hits in the scripts =="
grep -rn "set_routing_layers" "$LIB/scripts" 2>/dev/null | head -20
grep -rn "RT_MIN_LAYER\|RT_MAX_LAYER" "$LIB/scripts" "$LIB/steps" 2>/dev/null | head -20
echo
echo "== read_current_odb (io.tcl) =="
python3 - "$LIB" <<'PY'
import os, re, sys
lib = sys.argv[1]
p = os.path.join(lib, "scripts", "openroad", "common", "io.tcl")
src = open(p, encoding="utf8", errors="ignore").read()
m = re.search(r"proc read_current_odb.*?\n\}", src, re.S)
print(m.group(0) if m else "read_current_odb not found")
PY
echo
echo "== grt.tcl layer handling =="
python3 - "$LIB" <<'PY'
import os, sys
lib = sys.argv[1]
p = os.path.join(lib, "scripts", "openroad", "grt.tcl")
src = open(p, encoding="utf8", errors="ignore").read().splitlines()
for i, l in enumerate(src):
    if "routing_layer" in l.lower() or "set_routing" in l:
        print(f"{i+1}: {l}")
PY
