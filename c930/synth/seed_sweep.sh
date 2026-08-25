#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# C930 SoC nextpnr placement-seed sweep.
#
# The synthesized netlist (build/synth/ecp5.json) is fixed; only the placer/
# router seed varies. Reports the routed Fmax per seed. The routing term
# dominates the critical path, so seed choice can swing the result.
#
# Usage:
#   bash synth/seed_sweep.sh [seed ...]
#     default seeds: 0 2 3 5 11
#
# Outputs (under c930/build/synth/):
#   pnr_seed_<n>.log   per-seed nextpnr log
#   seed_sweep.txt     "seed <n>: routed <fmax> MHz (placement-est <fmax>)"
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OSS="$HERE/../toolchain/oss-cad-suite"
OUT="$HERE/../build/synth"

SEEDS=("$@")
if [ ${#SEEDS[@]} -eq 0 ]; then
    SEEDS=(0 2 3 5 11)
fi

if [ ! -x "$OSS/bin/nextpnr-ecp5.exe" ]; then
    echo "ERROR: oss-cad-suite not found at $OSS" >&2
    exit 1
fi

export PATH="$OSS/bin:$OSS/lib:$PATH"
mkdir -p "$OUT"
cd "$HERE/.."

RESULT="$OUT/seed_sweep.txt"
: > "$RESULT"

for seed in "${SEEDS[@]}"; do
    LOG="$OUT/pnr_seed_${seed}.log"
    CFG="$OUT/ecp5_seed_${seed}.config"
    echo "== seed $seed: placement + routing =="
    nextpnr-ecp5 -l "$LOG" --json "$OUT/ecp5.json" \
        --lpf synth/ecp5_85f.lpf --85k --package CABGA381 --speed 8 \
        --seed "$seed" --textcfg "$CFG" > /dev/null 2>&1

    routed=$(grep -a "Max frequency for clock" "$LOG" | tail -1 | sed 's/.*: *//' | sed 's/ .*//')
    plest=$(grep -a "Max frequency for clock" "$LOG" | head -1 | sed 's/.*: *//' | sed 's/ .*//')
    echo "seed $seed: routed $routed  (placement-est $plest)" | tee -a "$RESULT"
done

echo
echo "===================== SEED SWEEP RESULTS ====================="
sort -t' ' -k4 -g -r "$RESULT" | cat
echo "=============================================================="
