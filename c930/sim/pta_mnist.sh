#!/usr/bin/env bash
# pta_mnist.sh - gate C1(a), the accuracy sweep on the D3 network
# (doc/pta_error_model_design_note.md section 5).  Runs on Linux or WSL.
#
#   sim/pta_mnist.sh MNIST_DIR WORK_DIR [gate|ablate|sweep|all]
#
# MNIST_DIR holds MNIST's four idx .gz files.  WORK_DIR receives the
# uncompressed data, the two builds, the trained networks (kept, so a rerun
# only evaluates) and the results in WORK_DIR/out.  JOBS sets how many runs go
# at once (default 4).  Exits nonzero if the self-test or the gate fails, or
# if the ablation passes.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 2 ] || { sed -n '2,12p' "$0"; exit 2; }
mnist=$1
work=$2
what=${3:-all}
jobs=${JOBS:-4}
export PTA_WORK=$work

mkdir -p "$work/data" "$work/nets" "$work/out"
for f in train-images-idx3-ubyte train-labels-idx1-ubyte t10k-images-idx3-ubyte t10k-labels-idx1-ubyte; do
    [ -s "$work/data/$f" ] || gzip -dc "$mnist/$f.gz" > "$work/data/$f"
done
cflags="-O2 -std=c99 -Wall -Wextra -pedantic -I$here"
${CC:-gcc} $cflags -o "$work/pta_mnist" "$here/pta_mnist.c" "$here/pta_tile_model.c" -lm
${CC:-gcc} $cflags -DPTA_MODEL_ABLATE_QROUND -o "$work/pta_mnist_qround" \
    "$here/pta_mnist.c" "$here/pta_tile_model.c" -lm
"$work/pta_mnist" selftest

# Fig. 3(c) of arXiv:2105.00227, zero attack strength, B = 1..10
ref="94.85 96.41 97.59 97.76 97.67 97.81 97.83 97.61 97.81 97.73"

# train DIN WBITS SEED [FROM]: one network, unless it is already there,
# starting from the same seed's network at FROM bits if FROM is given
train_one() {
    local net="$PTA_WORK/nets/d$1_b$2_s$3.net" from=()
    [ $# -lt 4 ] || from=(--from "$PTA_WORK/nets/d$1_b$4_s$3.net")
    [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din "$1" --wbits "$2" \
        --seed "$3" "${from[@]}" --out "$net" > "$net.log"
}
# evaluate TOOL TAG NET ARGS...: one test-set pass, its line to out/TAG.d/
eval_one() {
    local tool=$1 tag=$2 net=$3
    shift 3
    mkdir -p "$PTA_WORK/out/$tag.d"
    "$PTA_WORK/$tool" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
        > "$PTA_WORK/out/$tag.d/$(basename "$net" .net)_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
}
export -f train_one eval_one

# compare TAG: each width's five-network mean in out/TAG.d against the curve,
# by the criterion; returns 0 if it holds
compare() {
    cat "$work/out/$1.d"/d16_b*_s*.txt | awk -v ref="$ref" '
        { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
          b = v["net_wbits"] + 0; acc[b] += v["acc"]; dig[b] += v["digital"]; n[b]++ }
        END {
            split(ref, r, " ")
            printf "%-4s %8s %8s %9s %7s  %s\n", "B", "tile", "digital", "Fig.3(c)", "diff", "verdict"
            for (b = 1; b <= 10; ++b) {
                if (n[b] != 5) { printf "%-4d %d of 5 runs\n", b, n[b]; bad = 1; continue }
                m = acc[b] / 5; d = m - r[b]; tol = (b == 1) ? 0 : (b == 2) ? 1.0 : 0.5
                if (tol == 0) verdict = "reported"
                else if (d <= tol + 1e-9 && d >= -tol - 1e-9) verdict = "within " tol
                else { verdict = "OUTSIDE " tol; bad = 1 }
                printf "%-4d %8.2f %8.2f %9.2f %+7.2f  %s\n", b, m, dig[b] / 5, r[b], d, verdict
            }
            exit bad
        }'
}

# the gate's networks: each seed at B = 16, then B = 1..10 from it
train_gate() {
    local b s
    for s in 1 2 3 4 5; do echo 16 16 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for b in 1 2 3 4 5 6 7 8 9 10; do for s in 1 2 3 4 5; do echo 16 $b $s 16; done; done |
        xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
}

# eval_gate TOOL TAG: every gate network through the tile at its own width
eval_gate() {
    local b s
    for b in 1 2 3 4 5 6 7 8 9 10; do for s in 1 2 3 4 5; do
        echo "$1" "$2" d16_b${b}_s${s}.net --impair quant --wbits $b
    done; done | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _
}

gate_status=0
ablate_status=0
if [ "$what" = gate ] || [ "$what" = all ]; then
    train_gate
    eval_gate pta_mnist gate
    echo "== gate C1(a): tile at B_w = B against Fig. 3(c), five networks each"
    compare gate || gate_status=1
    [ $gate_status = 0 ] && echo "gate C1(a): PASS" || echo "gate C1(a): FAIL"
fi

if [ "$what" = ablate ] || [ "$what" = all ]; then
    train_gate
    eval_gate pta_mnist_qround ablate
    echo "== ablation: the model without the quantiser's rounding term"
    if compare ablate; then
        echo "ablation: PASSES the gate, so the gate cannot see it"
        ablate_status=1
    else
        echo "ablation: red, as it must be"
    fi
fi

if [ "$what" = sweep ] || [ "$what" = all ]; then
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    {
        echo "--impair quant"
        for x in 2 3 4 5 6 7; do echo "--impair quant --abits $x"; done
        for x in 4 5 6 7 8 10 12; do echo "--impair quant --adcbits $x"; done
        for x in 0.25 0.5 1 2 4 8; do echo "--impair quant,thermal --adcbits 8 --thermal $x"; done
        for x in 100 30 10 3 1 0.3; do echo "--impair quant,shot --adcbits 8 --photons $x"; done
        for x in 0.5 1 2 4 8; do echo "--impair quant,prog --adcbits 8 --prog $x"; done
        for x in 0.01 0.02 0.05 0.1 0.2; do echo "--impair quant,xtalk --adcbits 8 --xtalk $x"; done
        for m in tflt tfln; do for x in 0.1 1 4 12 46; do
            echo "--impair quant,drift --adcbits 8 --drift $m --hours $x"
        done; done
    } > "$work/out/sweep_settings.txt"
    # each network draws its noise and its drifting device from its own seed
    while read -r setting; do
        for s in 1 2 3 4 5; do echo "pta_mnist sweep d8_b6_s$s.net --seed $s $setting"; done
    done < "$work/out/sweep_settings.txt" | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _
    echo "== reported: DIN_W 8, B_w 6, five networks per setting, each on its own seed (mean, min, max)"
    printf '%-58s %7s %7s %7s %9s\n' setting mean min max "sats/elt"
    while read -r setting; do
        key=$(echo "$setting" | tr -c 'A-Za-z0-9.,' '_')
        cat "$work/out/sweep.d"/d8_b6_s*"$key".txt | awk -v name="$setting" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              a = v["acc"] + 0; s += a; n++; if (n == 1 || a < lo) lo = a; if (n == 1 || a > hi) hi = a
              sat += v["sats"]; el += v["elements"]; dig += v["digital"] }
            END { printf "%-58s %7.2f %7.2f %7.2f %9.2e\n", name, s / n, lo, hi, sat / el }'
    done < "$work/out/sweep_settings.txt"
    cat "$work/nets"/d8_b6_s*.net.log | awk '{ for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
        s += v["digital"]; n++ } END { printf "%-58s %7.2f\n", "digital, same weights", s / n }'
fi

exit $((gate_status | ablate_status))
