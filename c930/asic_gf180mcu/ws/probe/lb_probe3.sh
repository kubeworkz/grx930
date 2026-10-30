#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lb_probe3.sh -- second probe: which shell/binaries exist in the pre-check
# image, and the exact drt.tcl LibreLane's DetailedRouting step runs (sed is not
# on PATH there, so python3 reads the file out).
set -u
echo "== which =="
for c in bash sh sed grep ls head wc python3 zstd cargo openroad klayout; do
    printf '%-8s %s\n' "$c" "$(command -v $c || echo MISSING)"
done
echo
LIB=$(python3 -c 'import librelane, os; print(os.path.dirname(librelane.__file__))')
echo "== $LIB/scripts/openroad/drt.tcl =="
python3 - "$LIB" <<'PY'
import os, sys
lib = sys.argv[1]
p = os.path.join(lib, "scripts", "openroad", "drt.tcl")
print("exists:", os.path.exists(p), "size:", os.path.getsize(p) if os.path.exists(p) else "-")
if os.path.exists(p):
    for i, line in enumerate(open(p, encoding="utf8", errors="ignore").read().splitlines(), 1):
        print(f"{i:3d}| {line}")
PY
