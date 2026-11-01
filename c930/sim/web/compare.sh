#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# compare.sh -- the transcript test natively and as WebAssembly: both must pass,
# and print the same bytes. Usage: c930/sim/web/compare.sh OUT_DIR  (after build.sh)
set -u
OUT=$1
t0=$(date +%s.%N); "$OUT/npu_web_test" > "$OUT/native.txt" 2>&1; rn=$?
t1=$(date +%s.%N); node "$OUT/npu_web_test.js" > "$OUT/wasm.txt" 2>&1; rw=$?
t2=$(date +%s.%N)
cat "$OUT/native.txt"
dn=$(awk "BEGIN{print $t1 - $t0}"); dw=$(awk "BEGIN{print $t2 - $t1}")
same=no; cmp -s "$OUT/native.txt" "$OUT/wasm.txt" && same=yes
{
  echo "| build | exit | seconds |"; echo "|---|---|---|"
  echo "| native | $rn | $dn |"; echo "| WebAssembly (node) | $rw | $dw |"
  echo; echo "Transcripts identical: **$same**"; echo
  echo '```'; tail -n 1 "$OUT/native.txt"; echo '```'
} > "$OUT/summary.md"
cat "$OUT/summary.md"
[ "$same" = yes ] || { echo "--- diff"; diff "$OUT/native.txt" "$OUT/wasm.txt" | head -40; }
[ $rn -eq 0 ] && [ $rw -eq 0 ] && [ "$same" = yes ]
