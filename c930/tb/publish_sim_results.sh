#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# publish_sim_results.sh -- run the simulations gridworkz.com replays and write
# what they said, so the website shows real runs rather than a description of them.
#
# WHAT IT WRITES
#
#   $OUT/results.json   one record per workload: target, what it checks, exit
#                       status, wall time, counts of PASS / FAIL verdict lines, the
#                       testbench's own `$finish` line, and the log's file name
#   $OUT/logs/<id>.log  the full output of each workload, trimmed to its first and
#                       last 2,000 lines if it is longer than 4,000
#
#   The workflow (.github/workflows/sim-replays.yml) publishes $OUT to the
#   `sim-results` branch, where the site reads it at build time.
#
# WHAT COUNTS AS A PASS
#
#   Exit status 0 AND no `$fatal` / FAIL verdict line. A testbench that finishes with a
#   [FAIL] it did not turn into a non-zero exit is still a failure here: the
#   verdict lines are what a person reads, so they are what the record believes.
#
# WHY THESE WORKLOADS
#
#   Each needs only iverilog, vvp, make and python3 -- no RISC-V cross compiler,
#   no synthesis tool -- so a GitHub-hosted runner can finish them from a clean
#   checkout, and the self-hosted gates runner is left alone.
#
# Usage: bash c930/tb/publish_sim_results.sh [OUT_DIR]   (default build/sim-results)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/c930/build/sim-results}
TIMEOUT=${SIM_TIMEOUT:-1200}
mkdir -p "$OUT/logs"

# id | command (run from c930/) | what it checks
WORKLOADS=(
  "npu|make npu|NPU integer GEMM: every matrix shape in tb_c930_npu, INT8/INT16/INT4, plus the PTA register block"
  "npu_float|make npu_float|NPU FP16 and BF16 GEMM after integer GEMMs (tb_npu_float_prec)"
  "hazard|make hazard|CPU hazard unit: CSR flush and load-use stalls (tb_hazard_csrflush)"
  "hazard_equiv|make hazard_equiv|Hazard unit against a reference model, 300K random cycles"
  "arb_equiv|make arb_equiv|DMA arbiter B-skid against a reference model, 1,200+ transactions"
  "soc_real_work|bash tb/run_fast_path_real_work.sh|Full SoC: L2 coherence, AR withdraw, and four harts each running a GEMM on two NPUs"
)

trim() {  # keep a long log readable: head and tail, with the cut marked
  local f=$1 n
  n=$(wc -l < "$f")
  if [ "$n" -gt 4000 ]; then
    { head -n 2000 "$f"; echo "... [$((n - 4000)) lines cut by publish_sim_results.sh] ..."; tail -n 2000 "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
  fi
}

records="$OUT/records.tsv"; : > "$records"
for w in "${WORKLOADS[@]}"; do
  IFS='|' read -r id cmd what <<< "$w"
  log="$OUT/logs/$id.log"
  echo "== $id: $cmd"
  t0=$(date +%s)
  (cd "$ROOT/c930" && timeout "$TIMEOUT" bash -c "$cmd") > "$log" 2>&1
  rc=$?
  secs=$(( $(date +%s) - t0 ))
  # Verdicts come in two spellings: tb_c930_npu prints "[PASS] ...", while
  # tb_npu_float_prec ("GEMM FP16 2x3x5  PASS") and the real-work script
  # ("WORK quad-four-core: PASS") print the bare word. Count both; \b keeps
  # "PASSED" and "failed" out of it.
  passes=$(grep -cE '\[PASS\]|\bPASS\b' "$log" || true)
  fails=$(grep -cE '\[FAIL\]|\bFAIL\b|^FATAL|\$fatal|Fatal:' "$log" || true)
  finish=$(grep -m1 -oE '\$finish called at [0-9]+ *\([^)]*\)|\$finish called at [0-9]+' "$log" || true)
  trim "$log"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$cmd" "$what" "$rc" "$secs" "$passes" "$fails" "$finish" >> "$records"
  echo "   rc=$rc ${secs}s pass=$passes fail=$fails"
done

python3 - "$OUT" "$records" <<'PY'
import json, os, sys, datetime
out, records = sys.argv[1], sys.argv[2]
env = os.environ.get
runs = []
for line in open(records):
    id_, cmd, what, rc, secs, passes, fails, finish = line.rstrip('\n').split('\t')
    rc, fails = int(rc), int(fails)
    status = 'timeout' if rc == 124 else ('pass' if rc == 0 and fails == 0 else 'fail')
    runs.append(dict(id=id_, command=cmd, checks=what, status=status, exit_code=rc,
                     seconds=int(secs), pass_lines=int(passes), fail_lines=fails,
                     finish=finish or None, log=f'logs/{id_}.log'))
server, repo, run_id = env('GITHUB_SERVER_URL', 'https://github.com'), env('GITHUB_REPOSITORY', 'kubeworkz/grx930'), env('GITHUB_RUN_ID')
doc = dict(
    repo=repo,
    commit=env('GITHUB_SHA'),
    ref=env('GITHUB_REF_NAME'),
    run_url=f'{server}/{repo}/actions/runs/{run_id}' if run_id else None,
    generated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
    simulator=os.popen('iverilog -V 2>/dev/null | head -1').read().strip() or None,
    runs=runs,
)
json.dump(doc, open(os.path.join(out, 'results.json'), 'w'), indent=2)
print(f"wrote {len(runs)} runs: " + ', '.join(f"{r['id']}={r['status']}" for r in runs))
PY
rm -f "$records"

# Non-zero if anything failed, so the workflow run goes red when a simulation does.
! grep -q '"status": "\(fail\|timeout\)"' "$OUT/results.json"
