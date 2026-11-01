#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# compare.sh -- the transcript test natively, as the WebAssembly build of the
# same C test, and through the browser module itself (run-web.mjs): all three
# must pass and print the same bytes. Usage: c930/sim/web/compare.sh OUT_DIR
set -u
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd)
t0=$(date +%s.%N); "$OUT/npu_web_test" > "$OUT/native.txt" 2>&1; rn=$?
t1=$(date +%s.%N); node "$OUT/npu_web_test.js" > "$OUT/wasm.txt" 2>&1; rw=$?
t2=$(date +%s.%N); node "$HERE/run-web.mjs" "$OUT/web" > "$OUT/web.txt" 2>&1; rb=$?
t3=$(date +%s.%N)
cat "$OUT/native.txt"
dn=$(awk "BEGIN{print $t1 - $t0}"); dw=$(awk "BEGIN{print $t2 - $t1}"); db=$(awk "BEGIN{print $t3 - $t2}")
same=no
cmp -s "$OUT/native.txt" "$OUT/wasm.txt" && cmp -s "$OUT/native.txt" "$OUT/web.txt" && same=yes
{
  echo "| build | exit | seconds |"; echo "|---|---|---|"
  echo "| native | $rn | $dn |"; echo "| WebAssembly, C test | $rw | $dw |"; echo "| WebAssembly, browser module | $rb | $db |"
  echo; echo "Transcripts identical: **$same**"; echo
  echo '```'; tail -n 1 "$OUT/native.txt"; echo '```'
} > "$OUT/summary.md"
cat "$OUT/summary.md"
if [ "$same" != yes ]; then
  echo "--- diff, C test as WebAssembly:"; diff "$OUT/native.txt" "$OUT/wasm.txt" | head -20
  echo "--- diff, browser module:"; diff "$OUT/native.txt" "$OUT/web.txt" | head -20
fi
cp "$OUT/native.txt" "$OUT/web/transcript.txt"
[ $rn -eq 0 ] && [ $rw -eq 0 ] && [ $rb -eq 0 ] && [ "$same" = yes ]
