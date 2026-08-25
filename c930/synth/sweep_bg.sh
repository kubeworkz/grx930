#!/usr/bin/env bash
# Detached seed sweep - run from cmd: cmd //c "start /min cmd /c C:\...\sweep_bg.sh"
export PATH="/c/Users/kubew/grx930/c930/toolchain/oss-cad-suite/bin:$PATH"
cd /c/Users/kubew/grx930/c930

OUT="build/synth"
RESULT="$OUT/seed_sweep.txt"
: > "$RESULT"

for seed in 0 2 3 5 7 11 13 17 42; do
    LOG="$OUT/pnr_seed_${seed}.log"
    CFG="$OUT/ecp5_seed_${seed}.config"
    echo "== seed $seed =="
    nextpnr-ecp5 -l "$LOG" --json "$OUT/ecp5.json" \
        --lpf synth/ecp5_85f.lpf --85k --package CABGA381 --speed 8 \
        --seed "$seed" --textcfg "$CFG" > /dev/null 2>&1

    routed=$(grep -a "Max frequency for clock" "$LOG" | tail -1 | sed 's/.*: *//' | sed 's/ .*//')
    plest=$(grep -a "Max frequency for clock" "$LOG" | head -1 | sed 's/.*: *//' | sed 's/ .*//')
    echo "seed $seed: routed $routed  (placement-est $plest)" | tee -a "$RESULT"
done

echo "SWEEP_DONE" >> "$RESULT"
echo "Sweep complete."
