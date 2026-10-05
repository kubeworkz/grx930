#!/usr/bin/env bash
# pta_mnist.sh - gate C1(a), the accuracy sweep on the D3 network
# (doc/pta_error_model_design_note.md section 5).  Runs on Linux or WSL.
#
#   sim/pta_mnist.sh MNIST_DIR WORK_DIR [gate|ablate|sweep|joint|calib|budget|depth|geometry|all]
#
# MNIST_DIR holds MNIST's four idx .gz files.  WORK_DIR receives the
# uncompressed data, the two builds, the trained networks (kept, so a rerun
# only evaluates) and the results in WORK_DIR/out.  JOBS sets how many runs go
# at once (default 4).  Exits nonzero if the self-test or the gate fails, or
# if the ablation passes.  `depth` trains fifteen more networks and is not part
# of `all`; DEPTHS sets which hidden-layer counts it runs (default "1 2 4 8").
# `geometry` is not part of `all` either; GEOMETRIES sets the tiles it runs
# beside the core's 8x8 (default "64x8 128x64 256x64 256x128").
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

# run_settings TAG: the DIN_W 8 networks, then every setting in
# out/TAG_settings.txt on each of them, each network on its own seed, and the
# table that follows
run_settings() {
    local tag=$1 setting key s
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    while read -r setting; do
        for s in 1 2 3 4 5; do echo "pta_mnist $tag d8_b6_s$s.net --seed $s $setting"; done
    done < "$work/out/${tag}_settings.txt" | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _
    printf '%-92s %7s %7s %7s %9s\n' setting mean min max "sats/elt"
    while read -r setting; do
        key=$(echo "$setting" | tr -c 'A-Za-z0-9.,' '_')
        cat "$work/out/$tag.d"/d8_b6_s*"$key".txt | awk -v name="$setting" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              a = v["acc"] + 0; s += a; n++; if (n == 1 || a < lo) lo = a; if (n == 1 || a > hi) hi = a
              sat += v["sats"]; el += v["elements"] }
            END { printf "%-92s %7.2f %7.2f %7.2f %9.2e\n", name, s / n, lo, hi, sat / el }'
    done < "$work/out/${tag}_settings.txt"
    cat "$work/nets"/d8_b6_s*.net.log | awk '{ for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
        s += v["digital"]; n++ } END { printf "%-92s %7.2f\n", "digital, same weights", s / n }'
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
    echo "== reported: DIN_W 8, B_w 6, five networks per setting, each on its own seed (mean, min, max)"
    run_settings sweep
fi

# X1 of grxcp's board_program_plan.md: the interface chip's budget, with every
# impairment on at once instead of one at a time.  v0 is that plan's 4.3 -- 5
# activation bits, a 6-bit ADC, thermal sigma of one ADC LSB, 3 photons per ADC
# LSB, programming sigma of 4 weight LSB, 10% crosstalk -- and drift at TFLT's
# fit, aged to the hour its calibration interval allows.
#
# READ WITH `budget`, BELOW.  --thermal and --photons are in LSB of the ADC a
# run configures, and C1 measured those two rows at an 8-bit ADC.  At the 6-bit
# ADC here "--thermal 1 --photons 3" is four times that receiver noise and a
# quarter of that light, so "v0 entire" below is not v0's rows together.  These
# settings are kept as they were run because the plan's tables quote them.
if [ "$what" = joint ] || [ "$what" = all ]; then
    v0_bits="--abits 5 --adcbits 6"
    v0_noise="--thermal 1 --photons 3 --prog 4 --xtalk 0.1"
    tight_bits="--abits 6 --adcbits 7"
    tight_noise="--thermal 0.5 --photons 10 --prog 2 --xtalk 0.05"
    tighter_noise="--thermal 0.25 --photons 30 --prog 1 --xtalk 0.02"
    all_but_drift="quant,thermal,shot,prog,xtalk"
    {
        echo "--impair quant $v0_bits"
        echo "--impair $all_but_drift $v0_bits $v0_noise"
        echo "--impair $all_but_drift,drift $v0_bits $v0_noise --drift tflt --hours 1"
        echo "--impair $all_but_drift,drift $v0_bits $v0_noise --drift tflt --hours 0.1"
        echo "--impair $all_but_drift,drift $v0_bits $tight_noise --drift tflt --hours 1"
        echo "--impair $all_but_drift,drift $tight_bits $v0_noise --drift tflt --hours 1"
        echo "--impair $all_but_drift,drift $tight_bits $tight_noise --drift tflt --hours 1"
        echo "--impair $all_but_drift,drift $tight_bits $tighter_noise --drift tflt --hours 1"
        echo "--impair $all_but_drift,drift $tight_bits $tighter_noise --drift tflt --hours 0.1"
    } > "$work/out/joint_settings.txt"
    echo "== X1: every impairment at once, DIN_W 8, B_w 6, five networks each"
    run_settings joint
fi

# C3(a) of grxcp's board_program_plan.md, through X3's specification: the cell
# trim, measured.  Every setting runs at version 1 of that plan's 4.3 -- 6
# activation bits, a 7-bit ADC, thermal 0.25, 30 photons an ADC LSB,
# programming sigma 1 and 2% crosstalk -- with drift on top, uncalibrated and
# then calibrated.
if [ "$what" = calib ] || [ "$what" = all ]; then
    v1="--abits 6 --adcbits 7 --thermal 0.25 --photons 30 --prog 1 --xtalk 0.02"
    imp="--impair quant,thermal,shot,prog,xtalk,drift"
    {
        echo "--impair quant,thermal,shot,prog,xtalk $v1"
        for m in tflt tfln; do for h in 1 4 46; do
            echo "$imp $v1 --drift $m --hours $h"
            echo "$imp $v1 --drift $m --hours $h --calibrate 16"
        done; done
        # a 6-bit weight code's LSB is four of these, so the last two trim
        # no finer than the code itself
        for t in 0.25 1 2 4 8; do
            echo "$imp $v1 --drift tfln --hours 46 --calibrate 16 --trimstep $t"
        done
        for h in 0.25 0.5 1 4 46; do
            echo "$imp $v1 --drift tflt --hours 0 --calibrate 16 --post-hours $h"
        done
        for c in 1 4 16; do
            echo "$imp $v1 --drift tflt --hours 4 --calibrate $c"
        done
    } > "$work/out/calib_settings.txt"
    echo "== C3(a): the cell trim, DIN_W 8, B_w 6, five networks each"
    run_settings calib
fi

# The budget in a unit that does not move with the ADC, and a probe on every
# run: each layer's error against the network's own sums, and the accuracy that
# error alone predicts (pta_mnist.c, the probe).  The rows where C1 measured
# them; all of v0 at that ADC, at v0's own converters with the same noise, and
# as X1 ran it; v1 as X1 ran it and as its table reads; what each change is
# worth from v0 and what each relaxation costs from v1; and a sweep that asks
# whether accuracy follows the amount of error whatever it is made of.
if [ "$what" = budget ] || [ "$what" = all ]; then
    all="quant,thermal,shot,prog,xtalk"
    v0n="--thermal8 1 --photons8 3 --prog 4 --xtalk 0.1"
    v1n="--thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.02"
    {
        echo "--impair quant --adcbits 8"
        echo "--impair quant --adcbits 8 --abits 5"
        echo "--impair quant --adcbits 6"
        echo "--impair quant,thermal --adcbits 8 --thermal8 1"
        echo "--impair quant,shot --adcbits 8 --photons8 3"
        echo "--impair quant,prog --adcbits 8 --prog 4"
        echo "--impair quant,xtalk --adcbits 8 --xtalk 0.1"

        echo "--impair $all --abits 5 --adcbits 8 $v0n"
        echo "--impair $all --abits 5 --adcbits 6 $v0n"
        echo "--impair $all --abits 5 --adcbits 6 --thermal 1 --photons 3 --prog 4 --xtalk 0.1"

        echo "--impair $all --abits 6 --adcbits 7 --thermal 0.25 --photons 30 --prog 1 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"

        # from v0 at its own converters, one change at a time
        echo "--impair quant,thermal,prog,xtalk --abits 5 --adcbits 6 --thermal8 1 --prog 4 --xtalk 0.1"
        echo "--impair $all --abits 5 --adcbits 6 --thermal8 1 --photons8 30 --prog 4 --xtalk 0.1"
        echo "--impair $all --abits 5 --adcbits 6 --thermal8 0.5 --photons8 3 --prog 4 --xtalk 0.1"
        echo "--impair $all --abits 5 --adcbits 6 --thermal8 1 --photons8 3 --prog 1 --xtalk 0.1"
        echo "--impair $all --abits 5 --adcbits 6 --thermal8 1 --photons8 3 --prog 4 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 6 $v0n"
        echo "--impair $all --abits 5 --adcbits 7 $v0n"

        # from v1 as X1 ran it, one relaxation at a time
        echo "--impair quant,thermal,prog,xtalk --abits 6 --adcbits 7 --thermal8 0.5 --prog 1 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 1 --photons8 15 --prog 1 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 0.5 --photons8 3 --prog 1 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 4 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.1"
        echo "--impair $all --abits 5 --adcbits 7 $v1n"
        echo "--impair $all --abits 6 --adcbits 6 $v1n"

        # two that were predicted before they were run, by adding the rows above:
        # v1's noise at v0's converters, and v0 with only its two largest rows
        # tightened
        echo "--impair $all --abits 5 --adcbits 6 $v1n"
        echo "--impair $all --abits 5 --adcbits 6 --thermal8 1 --photons8 15 --prog 1 --xtalk 0.1"

        # v0's noise at v1's converters, with drift aged as the joint runs age it
        echo "--impair $all --abits 6 --adcbits 7 $v0n"
        echo "--impair $all,drift --abits 5 --adcbits 6 $v0n --drift tflt --hours 1"
        echo "--impair $all,drift --abits 5 --adcbits 6 $v0n --drift tflt --hours 0.1"

        # does accuracy follow the amount of error, whatever it is made of?
        for x in 2 4 8; do echo "--impair quant,thermal --adcbits 8 --thermal8 $x"; done
        for x in 1 0.3 0.1; do echo "--impair quant,shot --adcbits 8 --photons8 $x"; done
        for x in 8 16 32; do echo "--impair quant,prog --adcbits 8 --prog $x"; done
        for x in 0.2 0.4; do echo "--impair quant,xtalk --adcbits 8 --xtalk $x"; done
        echo "--impair $all --adcbits 8 --thermal8 2 --photons8 0.75 --prog 8 --xtalk 0.2"
        echo "--impair $all --adcbits 8 --thermal8 3 --photons8 0.333 --prog 12 --xtalk 0.3"
    } | sed 's/$/ --probe 1/' > "$work/out/budget_settings.txt"
    echo "== budget: noise in 8-bit LSB, DIN_W 8, B_w 6, five networks each, with the probe"
    for sd in 1 2 3 4 5; do echo 8 8 $sd; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for sd in 1 2 3 4 5; do echo 8 6 $sd 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    while read -r setting; do
        for sd in 1 2 3 4 5; do echo "pta_mnist budget d8_b6_s$sd.net --seed $sd $setting"; done
    done < "$work/out/budget_settings.txt" | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _
    # acc is the tile's accuracy; iid, cov and res are the probe's three
    # predictions of it; e1 to eres are errors as a percentage of the rms they
    # are measured against; th8 and ph8 are the run's noise in 8-bit LSB.
    printf '%-86s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %5s %5s\n' \
        setting acc iid cov res e1 e2 eprop elog eres gain agree th8 ph8
    while read -r setting; do
        key=$(echo "$setting" | tr -c 'A-Za-z0-9.,' '_')
        cat "$work/out/budget.d"/d8_b6_s*"$key".txt | awk -v name="${setting% --probe 1}" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              n++; a += v["acc"]; pi += v["pred_iid"]; pc += v["pred_cov"]; pr += v["pred_res"]
              ag += v["agree"]; e1 += v["e1"]; e2 += v["e2"]; ep += v["eprop"]; el += v["elog"]
              er += v["eres"]; g += v["gain"]; t8 = v["thermal8"]; p8 = v["photons8"] }
            END { sub(/--impair /, "", name); gsub(/quant,thermal,shot,prog,xtalk/, "ALL", name)
                  printf "%-86s %6.2f %6.2f %6.2f %6.2f %6.2f %6.2f %6.2f %6.2f %6.2f %+6.3f %6.2f %5.3g %5.3g\n",
                         name, a / n, pi / n, pc / n, pr / n, 100 * e1 / n, 100 * e2 / n, 100 * ep / n,
                         100 * el / n, 100 * er / n, g / n, ag / n, t8, p8 }'
    done < "$work/out/budget_settings.txt"
    cat "$work/out/budget.d"/d8_b6_s*.txt | awk '{ for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
        r[v["net_seed"]] = v["ref"]; d[v["net_seed"]] = v["digital"] }
        END { for (k in r) { s += r[k]; t += d[k]; n++ }
              printf "%-88s %6.2f   (in floating point %.2f)\n", "the network on its host, no tile", s / n, t / n }'
fi

# Does the budget hold with depth?  D3 has one hidden layer, so a layer's error
# is the next layer's input once.  This trains the same network with more of
# them -- 784, then H layers of 100, then 10, by the same rule and from the same
# seeds -- and runs the budget's core on each: the rows of v0 alone and
# together, v0 and v1 with and without shot noise, and each of v1's rows
# relaxed to v0's.  Noise is in 8-bit LSB throughout, and the probe is on.
if [ "$what" = depth ]; then
    all="quant,thermal,shot,prog,xtalk"
    v0n="--thermal8 1 --photons8 3 --prog 4 --xtalk 0.1"
    v1n="--thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.02"
    {
        echo "--impair quant --adcbits 8"
        echo "--impair quant --adcbits 8 --abits 5"
        echo "--impair quant,thermal --adcbits 8 --thermal8 1"
        echo "--impair quant,shot --adcbits 8 --photons8 3"
        echo "--impair quant,prog --adcbits 8 --prog 4"
        echo "--impair quant,xtalk --adcbits 8 --xtalk 0.1"
        echo "--impair $all --abits 5 --adcbits 8 $v0n"
        echo "--impair $all --abits 5 --adcbits 6 $v0n"
        echo "--impair quant,thermal,prog,xtalk --abits 5 --adcbits 6 --thermal8 1 --prog 4 --xtalk 0.1"
        echo "--impair quant,thermal,shot,prog --abits 5 --adcbits 6 --thermal8 1 --photons8 3 --prog 4"
        echo "--impair $all --abits 6 --adcbits 7 $v1n"
        echo "--impair quant,thermal,prog,xtalk --abits 6 --adcbits 7 --thermal8 0.5 --prog 1 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 1 --photons8 15 --prog 1 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 0.5 --photons8 3 --prog 1 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 4 --xtalk 0.02"
        echo "--impair $all --abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.1"
        echo "--impair $all --abits 5 --adcbits 7 $v1n"
        echo "--impair $all --abits 6 --adcbits 6 $v1n"
    } | sed 's/$/ --probe 1/' > "$work/out/depth_settings.txt"

    # train_deep H WBITS SEED [FROM]: a DIN_W 8 network of H hidden layers
    train_deep() {
        local net="$PTA_WORK/nets/h$1_d8_b$2_s$3.net" from=()
        [ $# -lt 4 ] || from=(--from "$PTA_WORK/nets/h$1_d8_b$4_s$3.net")
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits "$2" \
            --seed "$3" --hidden "$1" "${from[@]}" --out "$net" > "$net.log"
    }
    export -f train_deep
    # depth H's network of seed S; D3's are the ones the other modes use
    net_of() { if [ "$1" = 1 ]; then echo "d8_b6_s$2"; else echo "h$1_d8_b6_s$2"; fi; }

    depths=${DEPTHS:-1 2 4 8}
    for sd in 1 2 3 4 5; do echo 8 8 $sd; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for sd in 1 2 3 4 5; do echo 8 6 $sd 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for h in $depths; do [ "$h" = 1 ] || for sd in 1 2 3 4 5; do echo $h 8 $sd; done; done |
        xargs -r -P "$jobs" -L 1 bash -c 'train_deep "$@"' _
    for h in $depths; do [ "$h" = 1 ] || for sd in 1 2 3 4 5; do echo $h 6 $sd 8; done; done |
        xargs -r -P "$jobs" -L 1 bash -c 'train_deep "$@"' _
    for h in $depths; do
        while read -r setting; do
            for sd in 1 2 3 4 5; do echo "pta_mnist depth $(net_of $h $sd).net --seed $sd $setting"; done
        done < "$work/out/depth_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _

    # acc is the tile's accuracy and loss what it gave up against the same
    # networks on their host; res is the probe's prediction from the error a
    # decision can see; own is the layers' own GEMM errors, averaged; elog and
    # eres are the error at the outputs, all of it and the part a decision can
    # see; and the last column is the error after each layer on the way through.
    # All errors are percentages of the rms they are measured against.
    for h in $depths; do
        echo "== depth: $h hidden layer(s), DIN_W 8, B_w 6, five networks, noise in 8-bit LSB"
        printf '%-84s %6s %6s %6s %6s %6s %6s  %s\n' setting acc loss res own elog eres "after each layer"
        while read -r setting; do
            key=$(echo "$setting" | tr -c 'A-Za-z0-9.,' '_')
            cat "$work/out/depth.d/$(net_of $h '')"*"$key".txt | awk -v name="${setting% --probe 1}" -v h="$h" '
                { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
                  n++; a += v["acc"]; rf += v["ref"]; pr += v["pred_res"]; el += v["elog"]; er += v["eres"]
                  for (l = 1; l <= h + 1; ++l) {
                      own[l] += v["e" l]
                      t[l] += (("t" l) in v) ? v["t" l] : (l == 1 ? v["e1"] : v["elog"])
                  } }
                END { sub(/--impair /, "", name); gsub(/quant,thermal,shot,prog,xtalk/, "ALL", name)
                      for (l = 1; l <= h + 1; ++l) { o += own[l] / (h + 1); ts = ts sprintf(" %5.1f", 100 * t[l] / n) }
                      printf "%-84s %6.2f %6.2f %6.2f %6.2f %6.2f %6.2f %s\n", name, a / n, (rf - a) / n,
                             pr / n, 100 * o / n, 100 * el / n, 100 * er / n, ts }'
        done < "$work/out/depth_settings.txt"
        cat "$work/out/depth.d/$(net_of $h '')"*.txt | awk '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              r[v["net_seed"]] = v["ref"]; d[v["net_seed"]] = v["digital"] }
            END { for (k in r) { s += r[k]; t += d[k]; n++ }
                  printf "%-84s %6.2f   (in floating point %.2f)\n", "the networks on their host, no tile", s / n, t / n }'
    done
fi

# Does the budget hold on another tile?  Everything above runs on the c930
# core's 8 x 8 tile, in the GEMMs that core accepts.  grxcp's board plan puts
# the tile on a chiplet -- its candidates run from 64 x 8 to 256 x 128 -- and
# gives it a layer as one command.  This runs the budget's core on each tile in
# GEOMETRIES with a layer a GEMM, and on the core's tile both ways, so that what
# the tile changes can be told from what the cut changes.  It trains nothing.
#
# The noise is in LSB of an 8-bit ADC throughout, as in `budget`, and each
# layer's ADC shift is set on the tile's own sums, so a tile of 256 inputs has
# a coarser LSB than one of 8 and the same noise in it.
if [ "$what" = geometry ]; then
    geos=${GEOMETRIES:-64x8 128x64 256x64 256x128}
    all5="quant,thermal,shot,prog,xtalk"
    v0n="--thermal8 1 --photons8 3 --prog 4 --xtalk 0.1"
    v1="--abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.02"
    {
        echo "the quantisers, 8-bit ADC|--impair quant --adcbits 8"
        echo "the same, 6-bit ADC|--impair quant --adcbits 6"
        echo "v0's rows alone: 5 activation bits|--impair quant --adcbits 8 --abits 5"
        echo "  thermal 1|--impair quant,thermal --adcbits 8 --thermal8 1"
        echo "  3 photons|--impair quant,shot --adcbits 8 --photons8 3"
        echo "  programming 4|--impair quant,prog --adcbits 8 --prog 4"
        echo "  crosstalk 10%|--impair quant,xtalk --adcbits 8 --xtalk 0.1"
        echo "v0's rows together, 8-bit ADC|--impair $all5 --abits 5 --adcbits 8 $v0n"
        echo "v0, at its 6-bit ADC|--impair $all5 --abits 5 --adcbits 6 $v0n"
        echo "v1|--impair $all5 $v1"
        echo "v1, an hour of TFLT's drift|--impair $all5,drift $v1 --drift tflt --hours 1"
        echo "v1, six minutes of it|--impair $all5,drift $v1 --drift tflt --hours 0.1"
        echo "v1, four hours of it|--impair $all5,drift $v1 --drift tflt --hours 4"
        echo "v1, 46 hours of it|--impair $all5,drift $v1 --drift tflt --hours 46"
        echo "v1, an hour of TFLN's|--impair $all5,drift $v1 --drift tfln --hours 1"
        echo "v1, an hour, then calibrated|--impair $all5,drift $v1 --drift tflt --hours 1 --calibrate 16"
    } | sed 's/$/ --probe 1/' > "$work/out/geometry_settings.txt"
    # the tiles, as a label and the options that ask for one: the core's as it
    # has always run, the core's with a layer a GEMM, and each of GEOMETRIES
    {
        echo "8x8, core's cut|"
        echo "8x8, a layer|--maxk 784 --maxn 104"
        for gxy in $geos; do echo "$gxy|--rows ${gxy%x*} --cols ${gxy#*x}"; done
    } > "$work/out/geometry_tiles.txt"
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    while IFS='|' read -r label gopt; do
        while IFS='|' read -r name setting; do
            for sd in 1 2 3 4 5; do echo "pta_mnist geometry d8_b6_s$sd.net --seed $sd $gopt $setting"; done
        done < "$work/out/geometry_settings.txt"
    done < "$work/out/geometry_tiles.txt" | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _

    # geometry_table FIELD TITLE: one row a setting, one column a tile
    geometry_table() {
        local field=$1 title=$2 name setting label gopt sd
        echo "== geometry: $title"
        printf '%-32s' ""
        while IFS='|' read -r label gopt; do printf ' %15s' "$label"; done < "$work/out/geometry_tiles.txt"
        echo
        while IFS='|' read -r name setting; do
            printf '%-32s' "$name"
            while IFS='|' read -r label gopt; do
                for sd in 1 2 3 4 5; do
                    # the file eval_one wrote: its arguments, as it joined them
                    # shellcheck disable=SC2086
                    set -- --seed $sd $gopt $setting
                    cat "$work/out/geometry.d/d8_b6_s${sd}_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
                done | awk -v field="$field" '
                    { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
                      x = (field == "loss") ? v["digital"] - v["acc"] : 100 * v[field]
                      s += x; ss += x * x; n++ }
                    END { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                          printf " %8.2f +-%4.2f", m, (n > 1) ? sqrt(var / (n - 1)) : 0 }'
            done < "$work/out/geometry_tiles.txt"
            echo
        done < "$work/out/geometry_settings.txt"
    }
    geometry_table loss "points lost against the same weights on the host, five networks, mean and standard error"
    geometry_table e1 "layer 1's error against the network's own sums, percent of their rms"
    geometry_table eprop "the error that reaches the outputs, percent of their rms"
fi

exit $((gate_status | ablate_status))
