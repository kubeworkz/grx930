#!/usr/bin/env bash
# pta_mnist.sh - gate C1(a), the accuracy sweep on the D3 network
# (doc/pta_error_model_design_note.md section 5).  Runs on Linux or WSL.
#
#   sim/pta_mnist.sh MNIST_DIR WORK_DIR [gate|ablate|sweep|joint|calib|budget|depth|geometry|source|laser|fill|tighten|v2|trained|refsource|reflaser|refdrift|refcycle|refcal|refdraws|reflevel|reffix|refpoint|refhold|all]
#
# MNIST_DIR holds MNIST's four idx .gz files.  WORK_DIR receives the
# uncompressed data, the two builds, the trained networks (kept, so a rerun
# only evaluates) and the results in WORK_DIR/out.  JOBS sets how many runs go
# at once (default 4).  Exits nonzero if the self-test or the gate fails, or
# if the ablation passes.  `depth` trains fifteen more networks and is not part
# of `all`; DEPTHS sets which hidden-layer counts it runs (default "1 2 4 8").
# `geometry` is not part of `all` either; GEOMETRIES sets the tiles it runs
# beside the core's 8x8 (default "64x8 128x64 256x64 256x128").  Nor is `source`;
# SOURCE_TILE and SOURCE_BUSES set its tile and its buses (default 256x64 and 4).
# Nor is `laser`; LASER_TILES sets its tiles (default "256x64 128x64").
# Nor is `fill`; FILL_TILE sets its tile (default 128x64) and FILL_TIMES the
# lasers it runs, in multiples of grxcp's B5 (default "2 4 8").
# Nor is `tighten`; TIGHTEN_TILE sets its tile (default 128x64).
# Nor is `v2`; V2_TILE and V2_BUSES set its tile and its buses (default 128x64 and 2).
# Nor is `trained`, which trains twenty more networks; TRAINED_NOISES sets the noise
# they are trained with (default "0 0.05 0.1 0.2"), TRAINED_EPOCHS for how long (8),
# and TRAINED_TILE and TRAINED_BUSES the tile.
#
# MNIST_DIR need not be MNIST.  Any set in its format and under its four file
# names is a workload: Fashion-MNIST is one.  And PIXELS=inverted gives a new
# WORK_DIR the same images with every pixel taken from 255, the page lit and the
# ink dark.  A WORK_DIR is one workload for good, since its networks were
# trained on what it holds, and PIXELS has to say the same each time.
#
# The reference networks, since 2026-10-06 (grxcp's B17): each seed's 6-bit
# network trained for 8 epochs with noise of 0.1 on its sums, which is
# WORK_DIR/nets/d8_b6_sN_n0.1_e8.net.  `TRAINED_NOISES=0.1 ... trained` makes
# them and prints what a tile costs them.  Every mode above was run on the
# networks trained before, d8_b6_sN.net, and still is: its recorded lines are
# theirs.  A mode added after that date runs the reference networks.
# `refsource` is the first, and not part of `all`: REFSOURCE_TILE and
# REFSOURCE_BUSES set its tile and its buses (default 128x64 and 2).
# `reflaser` is the second: REFLASER_TILE sets its tile (default 128x64) and
# REFLASER_TIMES the lasers it runs, in multiples of grxcp's B5 (default
# "2 4 8 16 32").  `refdrift` is the third: REFDRIFT_TILE and REFDRIFT_BUSES
# set its tile and its buses (default 128x64 and 2), REFDRIFT_HOURS the
# intervals it drifts for (default "0.05 0.1 0.25 0.5 1 2 4") and REFDRIFT_HELD
# those it holds a source at the end of (default "0.1 0.5 1").  `refcycle` is
# the fourth: REFCYCLE_TILE and REFCYCLE_BUSES set its tile and its buses
# (default 128x64 and 2), REFCYCLE_HOURS the intervals it cycles at (default
# "0.05 0.1 0.25 0.5 1") and REFCYCLE_HELD those it holds (default "0.1 0.5 1").
# `refcal` is the fifth: REFCAL_TILE sets its tile (default 128x64),
# REFCAL_PROBES the probes a cell it calibrates with (default "1 4 16 64", and
# 16 has to be one), REFCAL_STEPS the finer trim steps it tries at 16 probes,
# in weight LSB (default "0.0625 0.00390625"), REFCAL_DRAWS the other draws it
# calibrates on (default "1 2") and REFCAL_MORE those it only runs the tile as
# budgeted on (default "3 4 5 6").  Draw D seeds the tile with the network's
# seed and 10 D more.  `refdraws` is the sixth: REFDRAWS_TILE and
# REFDRAWS_BUSES set its tile and its buses (default 128x64 and 2),
# REFDRAWS_DRAWS the draws it runs (default "0 1 2 3 4 5 6 7 8 9") and
# REFDRAWS_HOURS the intervals it cycles at (default "0.05 0.1").  `reflevel`
# is the seventh: REFLEVEL_TILE and REFLEVEL_BUSES set its tile and its buses
# (default 128x64 and 2), REFLEVEL_DRAWS the draws it runs (default "0 1 2"),
# REFLEVEL_LINES how far from level it leaves a comb's lines (default
# "0.05 0.2 0.4"), and REFLEVEL_SHOTS the other shots a row it reads them
# with, beside 16, at REFLEVEL_AT (default "1 64", at 0.2, which has to be
# one of the lines).  `reffix` is the eighth: REFFIX_TILE and REFFIX_BUSES set
# its tile and its buses (default 128x64 and 2), REFFIX_DRAWS the draws it
# runs (default "0 1 2") and REFFIX_LINES how far from level it leaves a
# comb's lines (default "0.05 0.2").  `refpoint` is the ninth: REFPOINT_TILE
# and REFPOINT_BUSES set its tile and its buses (default 128x64 and 2),
# REFPOINT_DRAWS the draws it runs (default "0 1 2 3 4") and REFPOINT_LEVEL how
# far from level a comb's lines are where they are read and corrected
# (default 0.2).  `refhold` is the tenth: REFHOLD_TILE and REFHOLD_BUSES set
# its tile and its buses (default 128x64 and 2), REFHOLD_DRAWS the draws it
# runs (default "0 1 2 3 4 5 6 7 8 9"), REFHOLD_CYCLES the intervals it cycles
# at, in hours (default "0.05 0.1"), and REFHOLD_LEVEL how far from level a
# comb's lines are (default 0.2).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 2 ] || { sed -n '2,74p' "$0"; exit 2; }
mnist=$1
work=$2
what=${3:-all}
jobs=${JOBS:-4}
export PTA_WORK=$work

mkdir -p "$work/data" "$work/nets" "$work/out"
cflags="-O2 -std=c99 -Wall -Wextra -pedantic -I$here"
${CC:-gcc} $cflags -o "$work/pta_mnist" "$here/pta_mnist.c" "$here/pta_tile_model.c" -lm
${CC:-gcc} $cflags -DPTA_MODEL_ABLATE_QROUND -o "$work/pta_mnist_qround" \
    "$here/pta_mnist.c" "$here/pta_tile_model.c" -lm
"$work/pta_mnist" selftest

# the data, as it came or inverted.  data/pixels says which a directory holds,
# and is written before a file is, so that a run cut short is not finished the
# other way; a directory made before there was a choice holds them as they came
pixels=${PIXELS:-as-is}
[ "$pixels" = as-is ] || [ "$pixels" = inverted ] || { echo "PIXELS is as-is or inverted" >&2; exit 2; }
if [ -s "$work/data/pixels" ] || [ -s "$work/data/train-images-idx3-ubyte" ]; then
    held=as-is
    [ ! -s "$work/data/pixels" ] || held=$(cat "$work/data/pixels")
    [ "$held" = "$pixels" ] || {
        echo "$work holds its pixels $held and PIXELS asks for $pixels: a work directory is one or the other" >&2
        exit 2; }
fi
echo "$pixels" > "$work/data/pixels"
for f in train-images-idx3-ubyte train-labels-idx1-ubyte t10k-images-idx3-ubyte t10k-labels-idx1-ubyte; do
    [ ! -s "$work/data/$f" ] || continue
    gzip -dc "$mnist/$f.gz" > "$work/data/$f.part"
    if [ "$pixels" = inverted ] && [ "$f" != "${f%images-idx3-ubyte}" ]; then
        "$work/pta_mnist" invert "$work/data/$f.part" "$work/data/$f.part" > /dev/null
    fi
    mv "$work/data/$f.part" "$work/data/$f"
done

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

# The reference networks (grxcp's B17; the header): a seed's 6-bit network
# trained from its 8-bit one for PTA_REF_EPOCHS epochs, with noise of
# PTA_REF_NOISE of a layer's rms on its sums.  `trained` writes the same files
# under the same names when it is asked for that noise and those epochs.
export PTA_REF_NOISE=0.1 PTA_REF_EPOCHS=8
# ref_net SEED: that seed's reference network, by its file's name
ref_net() { echo "d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; }
# train_ref SEED: that network, unless it is already there
train_ref() {
    local net
    net="$PTA_WORK/nets/$(ref_net "$1")"
    [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
        --seed "$1" --from "$PTA_WORK/nets/d8_b8_s$1.net" --sumnoise "$PTA_REF_NOISE" \
        --epochs "$PTA_REF_EPOCHS" --out "$net" > "$net.log"
}
export -f ref_net train_ref

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

# `source`: what the light costs.  grxcp's board makes the tile 256 x 64, a ring
# bank on four buses lit by a comb (its B10 to B12), and the error model has no
# term for a source.  pta_mnist adds one on the host's side of the line (--src,
# --srcline, --srcflat), and this runs it on that tile over version 1 of the
# budget: every line together, each line on its own, and lines that are not
# level, each through a weight alone and through a weight and an offset.  It
# trains nothing.
if [ "$what" = source ]; then
    tile=${SOURCE_TILE:-256x64}
    buses=${SOURCE_BUSES:-4}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    v1="--impair quant,thermal,shot,prog,xtalk --abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.02"
    {
        echo "v1, and no light's error|$v1"
        for x in 0.002 0.005 0.01 0.02 0.05 0.1; do echo "together, $x|$v1 --src $x"; done
        for x in 0.002 0.01 0.02 0.05 0.1 0.2; do echo "a line, $x|$v1 --srcline $x --buses $buses"; done
        echo "a line, 0.05, on one bus|$v1 --srcline 0.05 --buses 1"
        for x in 0.01 0.02 0.05 0.1 0.2; do echo "level, $x|$v1 --srcflat $x --buses $buses"; done
        echo "all three: 0.02, 0.05, 0.05|$v1 --src 0.02 --srcline 0.05 --srcflat 0.05 --buses $buses"
        echo "all three, 0.05 each|$v1 --src 0.05 --srcline 0.05 --srcflat 0.05 --buses $buses"
        for x in 0.002 0.005 0.01 0.02; do echo "offset: together, $x|$v1 --srcsign offset --src $x"; done
        for x in 0.002 0.01 0.02 0.05; do echo "offset: a line, $x|$v1 --srcsign offset --srcline $x --buses $buses"; done
        for x in 0.01 0.02 0.05; do echo "offset: level, $x|$v1 --srcsign offset --srcflat $x --buses $buses"; done
        echo "offset: all three, 0.002, 0.01, 0.01|$v1 --srcsign offset --src 0.002 --srcline 0.01 --srcflat 0.01 --buses $buses"
        echo "the quantisers alone|--impair quant --adcbits 8"
        echo "  and together, 0.01|--impair quant --adcbits 8 --src 0.01"
        echo "  and a line, 0.05|--impair quant --adcbits 8 --srcline 0.05 --buses $buses"
        echo "  and level, 0.05|--impair quant --adcbits 8 --srcflat 0.05 --buses $buses"
    } | sed 's/$/ --probe 1/' > "$work/out/source_settings.txt"
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    while IFS='|' read -r name setting; do
        for sd in 1 2 3 4 5; do echo "pta_mnist source d8_b6_s$sd.net --seed $sd $gopt $setting"; done
    done < "$work/out/source_settings.txt" | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _

    echo "== source: the $tile tile on $buses buses, five networks, mean and standard error"
    printf '%-36s %15s %15s %15s\n' "" "points lost" "e1, % of rms" "eprop, % of rms"
    while IFS='|' read -r name setting; do
        printf '%-36s' "$name"
        for field in loss e1 eprop; do
            for sd in 1 2 3 4 5; do
                # the file eval_one wrote: its arguments, as it joined them
                # shellcheck disable=SC2086
                set -- --seed $sd $gopt $setting
                cat "$work/out/source.d/d8_b6_s${sd}_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
            done | awk -v field="$field" '
                { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
                  x = (field == "loss") ? v["digital"] - v["acc"] : 100 * v[field]
                  s += x; ss += x * x; n++ }
                END { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                      printf " %8.2f +-%4.2f", m, (n > 1) ? sqrt(var / (n - 1)) : 0 }'
        done
        echo
    done < "$work/out/source_settings.txt"
fi

# `laser`: the receiver's noise as one laser fixes it.  The budget gives that
# noise in LSB, a layer at a time and each at its own shift.  A tile has one
# laser.  grxcp's board plan sizes it (its B5) so that a detector's full scale,
# 256 LSB of an 8-bit ADC, is the light a column is sent: all of its rows at
# full scale through weights of one.  Under version 1's half an LSB that puts
# the receiver's noise at rows / 512 of one line's light, in every layer.  This
# runs version 1 with its receiver row given that way, at that laser and at 2
# to 64 times it, beside version 1 as budgeted.  It trains nothing.
if [ "$what" = laser ]; then
    tiles=${LASER_TILES:-256x64 128x64}
    rest="--impair quant,thermal,shot,prog,xtalk --abits 6 --adcbits 7 --photons8 15 --prog 1 --xtalk 0.02"
    times="1 2 4 8 16 32 64"
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    # laser_opts TILE TIMES: the options for one run; TIMES 0 is version 1 as budgeted
    laser_opts() {
        local rows=${1%x*} cols=${1#*x}
        if [ "$2" = 0 ]; then
            echo "--rows $rows --cols $cols $rest --thermal8 0.5 --probe 1"
        else
            echo "--rows $rows --cols $cols $rest --thermalline $(awk -v r="$rows" -v m="$2" \
                'BEGIN { printf "%.10g", r / 512 / m }') --probe 1"
        fi
    }
    for t in $tiles; do
        for m in 0 $times; do
            for sd in 1 2 3 4 5; do echo "pta_mnist laser d8_b6_s$sd.net --seed $sd $(laser_opts "$t" "$m")"; done
        done
    done | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _

    # Every layer's noise, in its own LSB and at its own shift, has to be the one
    # fraction of a line's light its run asked for, to the Q8.8 it is held in.
    cat "$work/out/laser.d"/*.txt | awk '
        { delete v
          for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
          if (v["thermalline"] == "") next
          line = (2 ^ (v["din"] - 1) - 1) * 2 ^ (v["din"] - 1)
          n = split(v["thermal_l"], tl, ","); split(v["S"], sv, ",")
          for (i = 1; i <= n; ++i) {
              d = tl[i] * 2 ^ sv[i] / line - v["thermalline"]
              if (d < 0) d = -d
              if (d > 2 ^ sv[i] / 512 / line) bad++
          }
          runs++ }
        END { printf "== laser: %d runs, and every layer of each at the fraction of a line it was asked for: %s\n",
                     runs, (runs > 0 && !bad) ? "yes" : "NO"
              exit !(runs > 0 && !bad) }' || exit 1

    # laser_table FIELD TITLE [LASERS]: one row a laser, one column a tile
    laser_table() {
        local field=$1 title=$2 lasers=${3:-0 $times} t m sd
        echo "== laser: $title"
        printf '%-28s' ""
        for t in $tiles; do printf ' %15s' "$t"; done
        echo
        for m in $lasers; do
            if [ "$m" = 0 ]; then printf '%-28s' "v1 as budgeted"; else printf '%-28s' "B5's laser, times $m"; fi
            for t in $tiles; do
                for sd in 1 2 3 4 5; do
                    # the file eval_one wrote: its arguments, as it joined them
                    # shellcheck disable=SC2046
                    set -- --seed $sd $(laser_opts "$t" "$m")
                    cat "$work/out/laser.d/d8_b6_s${sd}_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
                done | awk -v field="$field" '
                    { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
                      if (field == "loss") x = v["digital"] - v["acc"]
                      else if (field == "lsb1" || field == "lsb2") { split(v["thermal_l"], tl, ","); split(v["S"], sv, ","); split(v["S8"], s8, ",")
                          i = (field == "lsb1") ? 1 : 2
                          x = (v["thermal_l"] == "") ? v["thermal8"] : tl[i] * 2 ^ (sv[i] - s8[i]) }
                      else if (field == "lit1" || field == "lit2" || field == "max1" || field == "max2") {
                          split(v[substr(field, 1, 3) == "lit" ? "lit" : "litmax"], lv, ",")
                          x = lv[substr(field, 4, 1)] }
                      else x = 100 * v[field]
                      s += x; ss += x * x; n++ }
                    END { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                          printf " %8.2f +-%4.2f", m, (n > 1) ? sqrt(var / (n - 1)) : 0 }'
            done
            echo
        done
    }
    laser_table loss "points lost against the same weights on the host, five networks, mean and standard error"
    laser_table lsb1 "the receiver's noise on layer 1, in LSB of an 8-bit ADC at that layer's shift"
    laser_table lsb2 "and on layer 2"
    laser_table eprop "the error that reaches the outputs, percent of their rms"
    # the light a shot sends a column, in lines.  It is the inputs', so on the
    # first layer no laser moves it, and one row says it
    laser_table lit1 "the light a shot sends a column on layer 1, in lines: the mean" 8
    laser_table max1 "and the most" 8
    laser_table lit2 "the same on layer 2: the mean" "1 8 64"
    laser_table max2 "and the most" "1 8 64"
fi

# `fill`: how a network is put on the tile, and what that buys of a laser.  A
# converter's full scale is a fraction of the light a column is sent (`laser`),
# because a layer's sums are small beside it.  The host sets two things that
# make them larger, and both clip: each hidden layer's rescale (--hidshift) and
# the scale the first layer's weights are written at (--w1gain).  This runs
# version 1 at three lasers under nine pairs of them.  It trains nothing.
if [ "$what" = fill ]; then
    tile=${FILL_TILE:-128x64}
    rows=${tile%x*}
    rest="--rows $rows --cols ${tile#*x} --impair quant,thermal,shot,prog,xtalk --abits 6 --adcbits 7 --photons8 15 --prog 1 --xtalk 0.02"
    shifts="0 -1 -2"
    gains="0 1 2"
    times=${FILL_TIMES:-2 4 8}
    # the laser the clip columns and the second table are read at: 4 times B5's
    # if it was run, or else the first that was
    at=4
    case " $times " in *" 4 "*) ;; *) at=${times%% *} ;; esac
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    # fill_opts SHIFT GAIN TIMES: the options for one run
    fill_opts() {
        echo "$rest --hidshift $1 --w1gain $2 --thermalline $(awk -v r="$rows" -v m="$3" \
            'BEGIN { printf "%.10g", r / 512 / m }') --probe 1"
    }
    for h in $shifts; do for g in $gains; do for m in $times; do
        for sd in 1 2 3 4 5; do echo "pta_mnist fill d8_b6_s$sd.net --seed $sd $(fill_opts "$h" "$g" "$m")"; done
    done; done; done | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _

    # Every run has to say it was put on the tile as it was asked to be, and to
    # show it: a hidden rescale that moved by the bits asked, against the same
    # network's run at the same gain with none.  (The gain's own bits come back
    # in the rescale through the clip rule, which a clipped weight can move.)
    fill_ok=yes
    fill_runs=0
    for h in $shifts; do for g in $gains; do for m in $times; do for sd in 1 2 3 4 5; do
        # shellcheck disable=SC2046
        set -- --seed $sd $(fill_opts "$h" "$g" "$m")
        f="$work/out/fill.d/d8_b6_s${sd}_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
        # shellcheck disable=SC2046
        set -- --seed $sd $(fill_opts 0 "$g" "$m")
        f0="$work/out/fill.d/d8_b6_s${sd}_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
        cat "$f0" "$f" | awk -v h="$h" -v g="$g" '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
            NR == 1 { sh0 = v["sh"] + 0 }
            NR == 2 { bad = !(v["hidshift"] == h && v["w1gain"] == g && v["sh"] + 0 == sh0 + h) }
            END { exit bad || NR != 2 }' || fill_ok=NO
        fill_runs=$((fill_runs + 1))
    done; done; done; done
    echo "== fill: $fill_runs runs, each put on the tile as it was asked to be: $fill_ok"
    [ "$fill_ok" = yes ] || exit 1

    # fill_cell FIELD SHIFT GAIN TIMES: five networks' mean and standard error
    fill_cell() {
        local field=$1 h=$2 g=$3 m=$4 sd
        for sd in 1 2 3 4 5; do
            # the file eval_one wrote: its arguments, as it joined them
            # shellcheck disable=SC2046
            set -- --seed $sd $(fill_opts "$h" "$g" "$m")
            sed "s/^/$field /" "$work/out/fill.d/d8_b6_s${sd}_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
        done | awk '
            { field = $1; delete v
              for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              if (field == "loss") x = v["digital"] - v["acc"]
              else if (field == "scaled") x = v["digital"] - v["ref"]
              else if (field == "hidclip") { split(v["hidclip"], hc, ","); x = 100 * hc[1] }
              else if (field == "w1clip") x = 100 * v["w1clip"]
              else if (field == "lsb1" || field == "lsb2") { split(v["thermal_l"], tl, ","); split(v["S"], sv, ","); split(v["S8"], s8, ",")
                  i = (field == "lsb1") ? 1 : 2; x = tl[i] * 2 ^ (sv[i] - s8[i]) }
              else if (field == "lit2") { split(v["lit"], lv, ","); x = lv[2] }
              else x = v[field]
              s += x; ss += x * x; n++ }
            END { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                  printf " %7.2f +-%4.2f", m, (n > 1) ? sqrt(var / (n - 1)) : 0 }'
    }
    echo "== fill: the $tile tile, five networks, mean and standard error.  Points lost against the"
    echo "== network as trained, on the host; a laser is in multiples of grxcp's B5"
    printf '%-18s %14s %14s %14s' "rescale, gain" "units clipped%" "weights clip%" "scaled, host"
    lead="laser x"
    for m in $times; do printf ' %14s' "$lead$m"; lead=x; done
    echo
    for h in $shifts; do for g in $gains; do
        printf '%-18s' "$h bits, $g bits"
        fill_cell hidclip "$h" "$g" "$at"; fill_cell w1clip "$h" "$g" "$at"; fill_cell scaled "$h" "$g" "$at"
        for m in $times; do fill_cell loss "$h" "$g" "$m"; done
        echo
    done; done
    echo "== fill: the receiver's noise in LSB of an 8-bit ADC at each layer's shift, at $at times B5's"
    echo "== laser, and the light a shot sends a column on layer 2, in lines"
    printf '%-18s %14s %14s %14s' "rescale, gain" "layer 1" "layer 2" "lines, layer 2"
    echo
    for h in $shifts; do for g in $gains; do
        printf '%-18s' "$h bits, $g bits"
        fill_cell lsb1 "$h" "$g" "$at"; fill_cell lsb2 "$h" "$g" "$at"; fill_cell lit2 "$h" "$g" "$at"
        echo
    done; done
fi

# `tighten`: what tightening v1 buys.  grxcp's board plan holds its interface
# chip to v1, and on a second data set v1 costs over a point (design note
# section 5, "another workload").  Nothing had asked which of its six rows that
# point is in.  This takes each row away alone, which is the most that
# tightening it could buy; tightens each a notch alone, then in pairs, in
# threes and all six, a notch and two; runs the two converters with nothing
# else; and puts v1's rows and two tighter sets under a laser, the hidden
# rescale a bit down, to say what laser each needs.  It trains nothing.
if [ "$what" = tighten ]; then
    tile=${TIGHTEN_TILE:-128x64}
    rows=${tile%x*}
    all="quant,thermal,shot,prog,xtalk"
    lasers="4 8 16 32 64"
    # tighten_set LABEL ABITS ADCBITS THERMAL8 PHOTONS8 PROG XTALK: one setting,
    # as label|options.  A - for a noise row or a weight's row is that row gone;
    # an activation DAC of 0 bits is none, which at these operands is all 8
    tighten_set() {
        local imp=quant o="--abits $2 --adcbits $3"
        [ "$4" = - ] || { imp=$imp,thermal; o="$o --thermal8 $4"; }
        [ "$5" = - ] || { imp=$imp,shot; o="$o --photons8 $5"; }
        [ "$6" = - ] || { imp=$imp,prog; o="$o --prog $6"; }
        [ "$7" = - ] || { imp=$imp,xtalk; o="$o --xtalk $7"; }
        echo "$1|--impair $imp $o"
    }
    # tighten_laser LABEL ABITS ADCBITS PHOTONS8 PROG XTALK TIMES: those rows
    # under a laser of TIMES grxcp's B5, the hidden rescale a bit down
    tighten_laser() {
        echo "$1|--impair $all --abits $2 --adcbits $3 --photons8 $4 --prog $5 --xtalk $6 --hidshift -1 --thermalline $(awk \
            -v r="$rows" -v m="$7" 'BEGIN { printf "%.10g", r / 512 / m }')"
    }
    {
        tighten_set "v1" 6 7 0.5 15 1 0.02
        tighten_set "one row gone: the activation DAC's" 0 7 0.5 15 1 0.02
        tighten_set "  the ADC's, at 12 bits" 6 12 0.5 15 1 0.02
        tighten_set "  the receiver's noise" 6 7 - 15 1 0.02
        tighten_set "  the shot noise" 6 7 0.5 - 1 0.02
        tighten_set "  programming error" 6 7 0.5 15 - 0.02
        tighten_set "  crosstalk" 6 7 0.5 15 1 -
        tighten_set "one row a notch: 7 activation bits" 7 7 0.5 15 1 0.02
        tighten_set "  an 8-bit ADC" 6 8 0.5 15 1 0.02
        tighten_set "  receiver noise 0.25 LSB" 6 7 0.25 15 1 0.02
        tighten_set "  30 photons" 6 7 0.5 30 1 0.02
        tighten_set "  programming error 0.5 LSB" 6 7 0.5 15 0.5 0.02
        tighten_set "  crosstalk 1.2%" 6 7 0.5 15 1 0.01
        tighten_set "a notch together: both converters" 7 8 0.5 15 1 0.02
        tighten_set "  both noise rows" 6 7 0.25 30 1 0.02
        tighten_set "  both of a weight's rows" 6 7 0.5 15 0.5 0.01
        tighten_set "  the ADC and both noise rows" 6 8 0.25 30 1 0.02
        tighten_set "  the other three" 7 7 0.5 15 0.5 0.01
        tighten_set "  all six" 7 8 0.25 30 0.5 0.01
        tighten_set "all six, two notches" 0 9 0.125 60 0.25 0.005
        tighten_set "the ADC and both noise rows gone" 6 12 - - 1 0.02
        tighten_set "the converters alone: v1's" 6 7 - - - -
        tighten_set "  a notch tighter" 7 8 - - - -
        for m in $lasers; do tighten_laser "v1's rows, laser x$m" 6 7 15 1 0.02 "$m"; done
        for m in $lasers; do tighten_laser "the ADC and the light, laser x$m" 6 8 30 1 0.02 "$m"; done
        for m in $lasers; do tighten_laser "all six, laser x$m" 7 8 30 0.5 0.01 "$m"; done
    } | sed "s/|/|--rows $rows --cols ${tile#*x} /; s/\$/ --probe 1/" > "$work/out/tighten_settings.txt"
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    while IFS='|' read -r name setting; do
        for sd in 1 2 3 4 5; do echo "pta_mnist tighten d8_b6_s$sd.net --seed $sd $setting"; done
    done < "$work/out/tighten_settings.txt" | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _

    # tighten_file SD SETTING: the file eval_one wrote for that run
    tighten_file() {
        local sd=$1
        # shellcheck disable=SC2086
        set -- --seed "$sd" $2
        echo "$work/out/tighten.d/d8_b6_s${sd}_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
    }
    # Every run has to have run what its row says: the tile, the converters,
    # which rows are on, and each row's size to the Q8.8 it is held in.  A row
    # that is on has to have a size, and one that is off none.  A row named for
    # a laser has to be that laser.  And the first row has to be v1 as every
    # mode before this ran it, since everything here is measured from it.
    v1set=$(sed -n '1s/^[^|]*|//p' "$work/out/tighten_settings.txt")
    tighten_ok=yes
    tighten_runs=0
    [ "$v1set" = "--rows $rows --cols ${tile#*x} --impair $all --abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.02 --probe 1" ] || tighten_ok=NO
    while IFS='|' read -r name setting; do
        for sd in 1 2 3 4 5; do
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v rows="$rows" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = (("thermal" in on) == (("thermal8" in given) || ("thermalline" in given))) &&
                               (("shot" in on) == ("photons8" in given)) && (("prog" in on) == ("prog" in given)) &&
                               (("xtalk" in on) == ("xtalk" in given)) && ("quant" in on)
                        laser = match(name, /laser x[0-9]+$/)
                        sane = sane && ((laser > 0) == ("thermalline" in given))
                        if (laser) sane = sane && near(want["thermalline"] * 512 * substr(name, RSTART + 7) / rows, 1, 1e-6) }
                { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
                  ok = sane && v["tile"] == tile && v["impair"] == sprintf("0x%02x", mask) &&
                       v["abits"] == want["abits"] && v["adcbits"] == want["adcbits"]
                  if ("thermal8" in given) ok = ok && near(v["thermal8"], want["thermal8"], 1e-6) && v["thermal8"] > 0
                  else if ("thermalline" in given) {
                      line = (2 ^ (v["din"] - 1) - 1) * 2 ^ (v["din"] - 1)
                      k = split(v["thermal_l"], tl, ","); split(v["S"], sv, ",")
                      ok = ok && k == 2 && v["thermalline"] == want["thermalline"] + 0 && want["thermalline"] > 0
                      for (i = 1; i <= k; ++i)
                          ok = ok && near(tl[i] * 2 ^ sv[i] / line, want["thermalline"], 2 ^ sv[i] / 512 / line)
                  } else ok = ok && v["thermal8"] == 0
                  if ("photons8" in given) ok = ok && near(v["photons8"] / want["photons8"], 1, 0.03)
                  else ok = ok && v["photons8"] == 0
                  if ("prog" in given) ok = ok && near(v["prog"], want["prog"], 1e-9) && v["prog"] > 0
                  else ok = ok && v["prog"] == 0
                  if ("xtalk" in given) ok = ok && near(v["xtalk"], want["xtalk"], 1 / 512 + 1e-9) && v["xtalk"] > 0
                  else ok = ok && v["xtalk"] == 0
                  if ("hidshift" in given) ok = ok && v["hidshift"] == want["hidshift"]
                  else ok = ok && !("hidshift" in v)
                  lines++ }
                END { exit !(lines == 1 && ok) }' "$(tighten_file "$sd" "$setting")" || tighten_ok=NO
            tighten_runs=$((tighten_runs + 1))
        done
    done < "$work/out/tighten_settings.txt"
    echo "== tighten: $tighten_runs runs, each of them the rows its line says: $tighten_ok"
    [ "$tighten_ok" = yes ] || exit 1

    # tighten_stat SETTING [BASE]: five networks' loss, mean and standard
    # error; then, given a BASE setting, what this one buys of it, network by
    # network; then the error that reaches the outputs, percent of their rms
    tighten_stat() {
        local sd
        for sd in 1 2 3 4 5; do
            [ $# -lt 2 ] || sed 's/^/A /' "$(tighten_file "$sd" "$2")"
            sed 's/^/B /' "$(tighten_file "$sd" "$1")"
        done | awk -v base=$(($# - 1)) '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["digital"] - v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g
              e = 100 * v["eprop"]; es += e; ess += e * e }
            END { printf " %7.2f +-%4.2f", s / n, se(s, ss, n)
                  if (base) printf " %7.2f +-%4.2f %9.2f +-%4.2f", gs / n, se(gs, gss, n), es / n, se(es, ess, n) }'
    }
    echo "== tighten: the $tile tile, five networks, mean and standard error.  Points lost against the"
    echo "== same weights on the host; what a row buys is v1's loss less its own, network by network;"
    echo "== and the error that reaches the outputs, percent of their rms"
    printf '%-36s %14s %14s %16s' "" "points lost" "bought of v1" "error at outputs"
    echo
    while IFS='|' read -r name setting; do
        case $setting in *--thermalline*) continue ;; esac
        printf '%-36s' "$name"
        tighten_stat "$setting" "$v1set"
        echo
    done < "$work/out/tighten_settings.txt"

    # tighten_named LABEL: the setting with that label
    tighten_named() { awk -F'|' -v l="$1" '$1 == l { print $2 }' "$work/out/tighten_settings.txt"; }
    echo "== tighten: rows under a laser, in multiples of grxcp's B5, the hidden rescale a bit down:"
    echo "== v1's; v1's with an 8-bit ADC and 30 photons; and all six a notch tighter.  As budgeted"
    echo "== is at the rule's rescale, with the receiver's noise the budget's and not a laser's"
    printf '%-18s %14s %20s %14s' "" "v1's rows" "the ADC and the light" "all six"
    echo
    printf '%-18s' "as budgeted"
    tighten_stat "$v1set"; printf '      '; tighten_stat "$(tighten_named "  the ADC and both noise rows")"
    tighten_stat "$(tighten_named "  all six")"
    echo
    for m in $lasers; do
        printf '%-18s' "laser x$m"
        tighten_stat "$(tighten_named "v1's rows, laser x$m")"; printf '      '
        tighten_stat "$(tighten_named "the ADC and the light, laser x$m")"
        tighten_stat "$(tighten_named "all six, laser x$m")"
        echo
    done
fi

# `v2`: grxcp's board plan now holds its interface chip to its version 2 (its
# B14): v1 with an 8-bit ADC, half the receiver's noise and twice the photons,
# which is `tighten`'s "the ADC and both noise rows".  Drift and the source's
# rows were measured at v1 and nowhere else.  This runs both at v2, with v1
# beside it on the same lines: each version as budgeted; after six minutes, an
# hour, four hours and 46 hours of TFLT's drift, an hour of TFLN's, and an hour
# and then calibrated; and with a source's noise through a balanced pair, the
# lines together, a line on its own and the lines' level, each at several
# sizes, and the three together.  grxcp then set the lines together to 1% and
# the calibration to every six minutes (its B15 and B16), so the last two rows
# are the three at 1%, 5% and 5%, and the same at the end of such an interval:
# a version with everything it is held to.  It trains nothing.
if [ "$what" = v2 ]; then
    tile=${V2_TILE:-128x64}
    buses=${V2_BUSES:-2}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    # version|row|options, a version's twenty-two rows each
    {
        for ver in v1 v2; do
            if [ $ver = v1 ]; then r="--abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.02"
            else r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"; fi
            echo "$ver|as budgeted|--impair $all $r"
            echo "$ver|six minutes of TFLT's drift|--impair $all,drift $r --drift tflt --hours 0.1"
            echo "$ver|an hour of it|--impair $all,drift $r --drift tflt --hours 1"
            echo "$ver|four hours of it|--impair $all,drift $r --drift tflt --hours 4"
            echo "$ver|46 hours of it|--impair $all,drift $r --drift tflt --hours 46"
            echo "$ver|an hour of TFLN's|--impair $all,drift $r --drift tfln --hours 1"
            echo "$ver|an hour of TFLT's, then calibrated|--impair $all,drift $r --drift tflt --hours 1 --calibrate 16"
            for x in 0.01 0.02 0.05 0.1; do echo "$ver|the source: together, $x|--impair $all $r --src $x"; done
            for x in 0.02 0.05 0.1 0.2; do echo "$ver|  a line, $x|--impair $all $r --srcline $x --buses $buses"; done
            for x in 0.02 0.05 0.1; do echo "$ver|  level, $x|--impair $all $r --srcflat $x --buses $buses"; done
            echo "$ver|  all three: 0.02, 0.05, 0.05|--impair $all $r --src 0.02 --srcline 0.05 --srcflat 0.05 --buses $buses"
            echo "$ver|  all three, 0.05 each|--impair $all $r --src 0.05 --srcline 0.05 --srcflat 0.05 --buses $buses"
            echo "$ver|  all three: 0.01, 0.05, 0.05|--impair $all $r --src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
            echo "$ver|six minutes and all three: 0.01, 0.05, 0.05|--impair $all,drift $r --drift tflt --hours 0.1 --src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
        done
    } | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/v2_settings.txt"
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    while IFS='|' read -r ver name setting; do
        for sd in 1 2 3 4 5; do echo "pta_mnist v2 d8_b6_s$sd.net --seed $sd $setting"; done
    done < "$work/out/v2_settings.txt" | xargs -P "$jobs" -L 1 bash -c 'eval_one "$@"' _

    # v2_file SD SETTING: the file eval_one wrote for that run
    v2_file() {
        local sd=$1
        # shellcheck disable=SC2086
        set -- --seed "$sd" $2
        echo "$work/out/v2.d/d8_b6_s${sd}_$(echo "$*" | tr -c 'A-Za-z0-9.,' '_').txt"
    }
    # Every run has to have run what its row says.  Its version's six rows, as
    # grxcp's plan has them and written out again here.  The drift, the hours
    # and the calibration its name says, and the source's three sizes its name
    # says.  And each of those in the line the run printed.
    v2_ok=yes
    v2_runs=0
    while IFS='|' read -r ver name setting; do
        for sd in 1 2 3 4 5; do
            awk -v opts="$setting" -v tile="$tile" -v ver="$ver" -v name="$name" -v nb="$buses" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function after(str, key,    p) { p = index(str, key); return p ? substr(str, p + length(key)) + 0 : 0 }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        rows["v1"] = "6 7 0.5 15 1 0.02"; rows["v2"] = "6 8 0.25 30 1 0.02"
                        sane = (ver in rows) && split(rows[ver], r, " ") == 6 &&
                               asked("abits") == r[1] && asked("adcbits") == r[2] && asked("thermal8") == r[3] &&
                               asked("photons8") == r[4] && asked("prog") == r[5] && asked("xtalk") == r[6] &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        drifts = (name ~ /minutes|hour/) ? 1 : 0
                        kind = drifts ? ((name ~ /TFLN/) ? "tfln" : "tflt") : "none"
                        hours = !drifts ? 0 : (name ~ /six minutes/) ? 0.1 : (name ~ /four hours/) ? 4 : (name ~ /46 hours/) ? 46 : 1
                        cal = (name ~ /calibrated/) ? 16 : 0
                        ns = after(name, "together, "); nl = after(name, "a line, "); nf = after(name, "level, ")
                        if (name ~ /all three: /) { split(substr(name, index(name, "all three: ") + 11), t3, ", ")
                                                    ns = t3[1] + 0; nl = t3[2] + 0; nf = t3[3] + 0 }
                        if (name ~ /all three, .* each/) ns = nl = nf = after(name, "all three, ")
                        lit = (ns > 0 || nl > 0 || nf > 0) ? 1 : 0
                        sane = sane && (drifts == (("drift" in on) ? 1 : 0)) && (drifts == (("drift" in given) ? 1 : 0)) &&
                               (!drifts || want["drift"] == kind) && asked("hours") == hours && asked("calibrate") == cal &&
                               asked("src") == ns && asked("srcline") == nl && asked("srcflat") == nf &&
                               (name == "as budgeted") == (!drifts && !lit) &&
                               asked("buses") == ((nl > 0 || nf > 0) ? nb : 0) }
                { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
                  ok = sane && v["tile"] == tile && v["impair"] == sprintf("0x%02x", mask) &&
                       v["abits"] == r[1] && v["adcbits"] == r[2] && near(v["thermal8"], r[3], 1e-6) &&
                       near(v["photons8"] / r[4], 1, 0.03) && near(v["prog"], r[5], 1e-9) &&
                       near(v["xtalk"], r[6], 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                       v["drift"] == kind && v["hours"] == hours && v["cal"] == cal && (v["steps"] > 0) == drifts &&
                       !("hidshift" in v) && !("thermalline" in v)
                  if (lit) ok = ok && v["src"] == ns && v["srcline"] == nl && v["srcflat"] == nf && v["srcsign"] == "pair" &&
                                v["buses"] == ((nl > 0 || nf > 0) ? nb : 1)
                  else ok = ok && !("src" in v)
                  lines++ }
                END { exit !(lines == 1 && ok) }' "$(v2_file "$sd" "$setting")" || v2_ok=NO
            v2_runs=$((v2_runs + 1))
        done
    done < "$work/out/v2_settings.txt"
    echo "== v2: $v2_runs runs, each of them the version and the row its line says: $v2_ok"
    [ "$v2_ok" = yes ] || exit 1

    # v2_named VER NAME: that version's setting for that row
    v2_named() { awk -F'|' -v v="$1" -v l="$2" '$1 == v && $2 == l { print $3 }' "$work/out/v2_settings.txt"; }
    # v2_stat SETTING BASE: five networks' loss, mean and standard error, and
    # what the setting adds to BASE, network by network
    v2_stat() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(v2_file "$sd" "$2")"
            sed 's/^/B /' "$(v2_file "$sd" "$1")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["digital"] - v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    echo "== v2: the $tile tile on $buses buses, five networks, mean and standard error.  Points lost"
    echo "== against the same weights on the host, and what a row adds to its own version as"
    echo "== budgeted, network by network.  A source's noise is through a balanced pair"
    printf '%-44s %14s %14s %14s %14s' "" "v1 loses" "and adds" "v2 loses" "and adds"
    echo
    awk -F'|' '$1 == "v1" { print $2 }' "$work/out/v2_settings.txt" | while IFS= read -r name; do
        printf '%-44s' "$name"
        for ver in v1 v2; do v2_stat "$(v2_named "$ver" "$name")" "$(v2_named "$ver" "as budgeted")"; done
        echo
    done
fi

# `trained`: a network trained for the tile.  Every network above was trained on
# the host and then run on a tile it had never seen, and every figure since the
# second data set carries that caveat.  `pta_mnist train --sumnoise F` puts
# Gaussian noise of F of a layer's rms on every sum while it trains, which is
# the tile as a network being trained can be shown it: the probe puts a tile's
# error at about a tenth of the sums' rms at v1.  This trains each seed's 6-bit
# network again from the same 8-bit network, for a fixed number of epochs, with
# no noise and with three sizes of it.  The one with none is there to tell the
# noise from the epochs: the networks above stop when their held-out accuracy
# first fails to rise, and a noisy one stops at once by that rule.  Every
# network is then run at grxcp's v1 and v2, as budgeted and with everything
# grxcp holds a version to: its source's three rows, at the end of six minutes
# of drift.
if [ "$what" = trained ]; then
    tile=${TRAINED_TILE:-128x64}
    buses=${TRAINED_BUSES:-2}
    noises=${TRAINED_NOISES:-0 0.05 0.1 0.2}
    epochs=${TRAINED_EPOCHS:-8}
    export PTA_TRAINED_EPOCHS=$epochs
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    v1r="--abits 6 --adcbits 7 --thermal8 0.5 --photons8 15 --prog 1 --xtalk 0.02"
    v2r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    held="--drift tflt --hours 0.1 --src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
    {
        echo "v1|$gopt --impair $all $v1r --probe 1"
        echo "v2|$gopt --impair $all $v2r --probe 1"
        echo "v1, held|$gopt --impair $all,drift $v1r $held --probe 1"
        echo "v2, held|$gopt --impair $all,drift $v2r $held --probe 1"
    } > "$work/out/trained_settings.txt"
    # train_noisy SEED NOISE: that seed's 6-bit network again, with that noise,
    # for the mode's epochs
    train_noisy() {
        local net="$PTA_WORK/nets/d8_b6_s$1_n$2_e$PTA_TRAINED_EPOCHS.net"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
            --seed "$1" --from "$PTA_WORK/nets/d8_b8_s$1.net" --sumnoise "$2" \
            --epochs "$PTA_TRAINED_EPOCHS" --out "$net" > "$net.log"
    }
    # trained_one NET ROW ARGS...: one test-set pass, its line to
    # out/trained.d/NET_ROW.txt.  Not eval_one's name, which is its arguments:
    # a held row's, beside a network trained here, are longer than a file's
    # name may be.
    trained_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/trained.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/trained.d/$(basename "$net" .net)_$row.txt"
    }
    export -f train_noisy trained_one
    # trained_row NAME: a row's name as a file's
    trained_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # trained_net SEED KIND: the network's file; a kind of "before" is the one
    # trained above, and any other is a noise
    trained_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else echo "d8_b6_s$1_n$2_e$epochs.net"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for f in $noises; do for s in 1 2 3 4 5; do echo "$s $f"; done; done |
        xargs -P "$jobs" -L 1 bash -c 'train_noisy "$@"' _
    for f in before $noises; do
        while IFS='|' read -r name setting; do
            for sd in 1 2 3 4 5; do echo "$(trained_net $sd "$f") $(trained_row "$name") --seed $sd $setting"; done
        done < "$work/out/trained_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'trained_one "$@"' _

    # trained_file SEED KIND NAME: the file trained_one wrote for that run
    trained_file() { echo "$work/out/trained.d/$(basename "$(trained_net "$1" "$2")" .net)_$(trained_row "$3").txt"; }
    # Every network has to be the one its row says, and every run the version
    # its column says.  A network trained here: its training's own line says
    # the epochs it ran and the noise it was asked for, and how much was put on
    # each layer's sums over its last epoch, which has to be that to a
    # twentieth, and none where none was asked.  A run: the
    # network it ran is the one that training wrote, by its accuracy on the
    # host and its epochs; and its rows are the version's, written out again
    # here, with or without the drift and the source that holding it adds.
    trained_ok=yes
    trained_runs=0
    for f in before $noises; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(trained_net $sd "$f").log"
        awk -v f="$f" -v e="$epochs" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (f == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && v["sumnoise"] == f + 0 && n == 2 && v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i)
                         ok = ok && ((f + 0 == 0) ? g[i] == 0 : (g[i] > 0.95 * f && g[i] < 1.05 * f)) }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || trained_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(trained_file $sd "$f" "$name")" | awk -v name="$name" -v tile="$tile" -v nb="$buses" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { two = (name ~ /^v2/); is_held = (name ~ /held/)
                          ok = v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == (is_held ? "0x5f" : "0x57") && v["abits"] == 6 &&
                               v["adcbits"] == (two ? 8 : 7) && near(v["thermal8"], two ? 0.25 : 0.5, 1e-6) &&
                               near(v["photons8"] / (two ? 30 : 15), 1, 0.03) && v["prog"] == 1 &&
                               near(v["xtalk"], 0.02, 1 / 512) && !("hidshift" in v) && !("thermalline" in v)
                          if (is_held) ok = ok && v["drift"] == "tflt" && v["hours"] == 0.1 && v["cal"] == 0 && v["steps"] > 0 &&
                                            v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] == 0.05 &&
                                            v["buses"] == nb && v["srcsign"] == "pair"
                          else ok = ok && v["drift"] == "none" && v["hours"] == 0 && !("src" in v) }
                END { exit !(NR == 2 && ok) }' || trained_ok=NO
            trained_runs=$((trained_runs + 1))
        done < "$work/out/trained_settings.txt"
    done; done
    echo "== trained: $trained_runs runs, each of them the network and the version its place says: $trained_ok"
    [ "$trained_ok" = yes ] || exit 1

    # trained_stat FIELD KIND [NAME]: five networks' mean and standard error.
    # host is a network's accuracy on its host; acc its accuracy on the tile;
    # loss the one less the other; epochs and got are its training's
    trained_stat() {
        local field=$1 f=$2 sd
        for sd in 1 2 3 4 5; do
            if [ $# -lt 3 ]; then cat "$work/nets/$(trained_net $sd "$f").log"
            else cat "$(trained_file $sd "$f" "$3")"; fi
        done | awk -v field="$field" '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              if (field == "loss") x = v["digital"] - v["acc"]
              else if (field == "host") x = v["digital"]
              else if (field == "got1" || field == "got2") { split(v["got"], g, ","); x = 100 * g[substr(field, 4)] }
              else x = v[field]
              s += x; ss += x * x; n++ }
            END { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                  printf " %7.2f +-%4.2f", m, (n > 1) ? sqrt(var / (n - 1)) : 0 }'
    }
    trained_label() {
        if [ "$1" = before ]; then echo "trained as before"
        elif [ "$1" = 0 ]; then echo "$epochs epochs, no noise"
        else echo "$epochs epochs, noise of $1"; fi
    }
    echo "== trained: the $tile tile on $buses buses, five networks, mean and standard error.  A network's"
    echo "== accuracy on its host and on the tile, percent.  Held is with a source's three rows at"
    echo "== 1%, 5% and 5%, at the end of six minutes of TFLT's drift"
    printf '%-28s %14s %14s %14s %14s %14s' "" "on its host" "v1" "v2" "v1, held" "v2, held"
    echo
    for f in before $noises; do
        printf '%-28s' "$(trained_label "$f")"
        trained_stat host "$f"
        while IFS='|' read -r name setting; do trained_stat acc "$f" "$name"; done < "$work/out/trained_settings.txt"
        echo
    done
    echo "== trained: the same, as points lost against the network's own accuracy on its host; and"
    echo "== its training: epochs, and the noise put on each layer's sums, percent of their rms"
    printf '%-28s %14s %14s %14s %14s %14s %14s %14s' "" "v1" "v2" "v1, held" "v2, held" "epochs" "layer 1" "layer 2"
    echo
    for f in before $noises; do
        printf '%-28s' "$(trained_label "$f")"
        while IFS='|' read -r name setting; do trained_stat loss "$f" "$name"; done < "$work/out/trained_settings.txt"
        trained_stat epochs "$f"
        if [ "$f" != before ]; then trained_stat got1 "$f"; trained_stat got2 "$f"; fi
        echo
    done
fi

# `refsource`: does a network trained for the tile need the 1%?  grxcp's B16
# holds the row a source's lines share to 1% and not 2%, on what the networks
# trained before lose on the inverted set, and lists a network trained for the
# tile among what would reopen it.  This is the first mode on the reference
# networks (the header).  It runs them at grxcp's version 2 with a source's
# noise through a balanced pair: the lines together at 1, 2 and 5%, a line and
# the level at 5%, the three at 2%, 5%, 5% and at 1%, 5%, 5%, six minutes of
# drift, and six minutes with each of those two.  The networks trained before
# run beside them row for row, because the 1% was chosen on those.  It trains
# the reference networks where they are not there.
if [ "$what" = refsource ]; then
    tile=${REFSOURCE_TILE:-128x64}
    buses=${REFSOURCE_BUSES:-2}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    # row|options: version 2's eleven rows
    {
        echo "as budgeted|--impair $all $r"
        for x in 0.01 0.02 0.05; do echo "the source: together, $x|--impair $all $r --src $x"; done
        echo "  a line, 0.05|--impair $all $r --srcline 0.05 --buses $buses"
        echo "  level, 0.05|--impair $all $r --srcflat 0.05 --buses $buses"
        for x in 0.02 0.01; do
            echo "  all three: $x, 0.05, 0.05|--impair $all $r --src $x --srcline 0.05 --srcflat 0.05 --buses $buses"
        done
        echo "six minutes of TFLT's drift|--impair $all,drift $r --drift tflt --hours 0.1"
        for x in 0.02 0.01; do
            echo "six minutes and all three: $x, 0.05, 0.05|--impair $all,drift $r --drift tflt --hours 0.1 --src $x --srcline 0.05 --srcflat 0.05 --buses $buses"
        done
    } | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refsource_settings.txt"
    # refsource_one NET ROW ARGS...: one test-set pass, its line to
    # out/refsource.d/NET_ROW.txt
    refsource_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refsource.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refsource.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refsource_one
    # refsource_row NAME: a row's name as a file's
    refsource_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refsource_net SEED KIND: the network's file, trained before or the reference
    refsource_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            for sd in 1 2 3 4 5; do echo "$(refsource_net $sd $k) $(refsource_row "$name") --seed $sd $setting"; done
        done < "$work/out/refsource_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refsource_one "$@"' _

    # refsource_file SEED KIND NAME: the file refsource_one wrote for that run
    refsource_file() { echo "$work/out/refsource.d/$(basename "$(refsource_net "$1" "$2")" .net)_$(refsource_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A reference network: its training's own line says the
    # header's epochs and noise, and the noise put on each layer's sums, which
    # has to be that to a twentieth; one trained before says neither.  A run:
    # the network it ran is the one that training wrote, by its accuracy on the
    # host and its epochs; its six rows are version 2's, written out again
    # here; and the drift and the source's three sizes are its name's, in what
    # it was asked and in the line it printed.
    refsource_ok=yes
    refsource_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refsource_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refsource_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(refsource_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function after(str, key,    p) { p = index(str, key); return p ? substr(str, p + length(key)) + 0 : 0 }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        split("6 8 0.25 30 1 0.02", r, " ")
                        sane = asked("abits") == r[1] && asked("adcbits") == r[2] && asked("thermal8") == r[3] &&
                               asked("photons8") == r[4] && asked("prog") == r[5] && asked("xtalk") == r[6] &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        drifts = (name ~ /six minutes/) ? 1 : 0
                        ns = after(name, "together, "); nl = after(name, "a line, "); nf = after(name, "level, ")
                        if (name ~ /all three: /) { split(substr(name, index(name, "all three: ") + 11), t3, ", ")
                                                    ns = t3[1] + 0; nl = t3[2] + 0; nf = t3[3] + 0 }
                        lit = (ns > 0 || nl > 0 || nf > 0) ? 1 : 0
                        sane = sane && (drifts == (("drift" in on) ? 1 : 0)) && (drifts == (("drift" in given) ? 1 : 0)) &&
                               (!drifts || want["drift"] == "tflt") && asked("hours") == 0.1 * drifts &&
                               !("calibrate" in given) && asked("src") == ns && asked("srcline") == nl &&
                               asked("srcflat") == nf && (name == "as budgeted") == (!drifts && !lit) &&
                               asked("buses") == ((nl > 0 || nf > 0) ? nb : 0) }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) &&
                               v["abits"] == r[1] && v["adcbits"] == r[2] && near(v["thermal8"], r[3], 1e-6) &&
                               near(v["photons8"] / r[4], 1, 0.03) && near(v["prog"], r[5], 1e-9) &&
                               near(v["xtalk"], r[6], 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == (drifts ? "tflt" : "none") && v["hours"] == 0.1 * drifts && v["cal"] == 0 &&
                               (v["steps"] > 0) == drifts && !("hidshift" in v) && !("thermalline" in v)
                          if (lit) ok = ok && v["src"] == ns && v["srcline"] == nl && v["srcflat"] == nf &&
                                        v["srcsign"] == "pair" && v["buses"] == ((nl > 0 || nf > 0) ? nb : 1)
                          else ok = ok && !("src" in v) }
                END { exit !(NR == 2 && ok) }' || refsource_ok=NO
            refsource_runs=$((refsource_runs + 1))
        done < "$work/out/refsource_settings.txt"
    done; done
    echo "== refsource: $refsource_runs runs, each of them the network and the row its place says: $refsource_ok"
    [ "$refsource_ok" = yes ] || exit 1

    # refsource_stat KIND NAME: five networks' loss, mean and standard error,
    # and what the row adds to that kind as budgeted, network by network
    refsource_stat() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refsource_file $sd "$1" "as budgeted")"
            sed 's/^/B /' "$(refsource_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["digital"] - v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refsource_buys KIND AT2 AT1: how often five networks are right in each of
    # two rows, and the second less the first, network by network
    refsource_buys() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refsource_file $sd "$1" "$2")"
            sed 's/^/B /' "$(refsource_file $sd "$1" "$3")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; as += a; ass += a * a; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f %7.2f +-%4.2f", as / n, se(as, ass, n), s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    echo "== refsource: the $tile tile on $buses buses at v2, five networks, mean and standard error.  Points"
    echo "== lost against the same weights on the host, and what a row adds to its own networks as"
    echo "== budgeted, network by network.  The reference networks are $PTA_REF_EPOCHS epochs with noise of $PTA_REF_NOISE"
    printf '%-44s %14s %14s %14s %14s' "" "before loses" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-44s' "$name"
        for k in before reference; do refsource_stat $k "$name"; done
        echo
    done < "$work/out/refsource_settings.txt"
    echo "== refsource: what the 1% buys.  How often five networks are right with the row the lines"
    echo "== share at 2% and at 1%, percent, and the second less the first, network by network"
    printf '%-44s %14s %14s %14s %14s %14s %14s' "" "before, at 2%" "at 1%" "the 1% buys" "reference, 2%" "at 1%" "the 1% buys"
    echo
    while IFS='|' read -r label two one; do
        printf '%-44s' "$label"
        for k in before reference; do refsource_buys $k "$two" "$one"; done
        echo
    done <<'ROWS'
the lines together, alone|the source: together, 0.02|the source: together, 0.01
all three, a line and the level at 5%|  all three: 0.02, 0.05, 0.05|  all three: 0.01, 0.05, 0.05
the same, at the end of six minutes|six minutes and all three: 0.02, 0.05, 0.05|six minutes and all three: 0.01, 0.05, 0.05
ROWS
fi

# `reflaser`: the laser the reference networks need.  grxcp sizes its laser as a
# multiple of its B5: the least at which a set of rows is within a tenth of a
# point of what it loses as budgeted.  `tighten` put version 2's rows under
# lasers on the networks trained before, the hidden rescale a bit down, and
# they need 8, 16 and 16 times on the three data sets.  A reference network
# was trained with noise on its sums, and a receiver's noise is noise on a
# sum.  This runs version 2's rows under lasers of 2 to 32 times B5's on the
# reference networks, with the hidden rescale a bit down and at the rule's,
# and the networks trained before beside them row for row.  The receiver's row
# is the laser's and the light's row is held at the budget's, as in `tighten`.
# It trains the reference networks where they are not there.
if [ "$what" = reflaser ]; then
    tile=${REFLASER_TILE:-128x64}
    rows=${tile%x*}
    lasers=${REFLASER_TIMES:-2 4 8 16 32}
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --photons8 30 --prog 1 --xtalk 0.02"
    # reflaser_line TIMES: the receiver's noise under that laser, of a line's light
    reflaser_line() { awk -v r="$rows" -v m="$1" 'BEGIN { printf "%.10g", r / 512 / m }'; }
    # row|options: version 2 as budgeted, and its rows under each laser twice
    {
        echo "as budgeted|--impair $all --abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
        for m in $lasers; do
            echo "the rescale a bit down, laser x$m|--impair $all $r --hidshift -1 --thermalline $(reflaser_line "$m")"
        done
        for m in $lasers; do
            echo "the rule's rescale, laser x$m|--impair $all $r --thermalline $(reflaser_line "$m")"
        done
    } | sed "s/|/|--rows $rows --cols ${tile#*x} /; s/\$/ --probe 1/" > "$work/out/reflaser_settings.txt"
    # reflaser_one NET ROW ARGS...: one test-set pass, its line to
    # out/reflaser.d/NET_ROW.txt
    reflaser_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/reflaser.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/reflaser.d/$(basename "$net" .net)_$row.txt"
    }
    export -f reflaser_one
    # reflaser_row NAME: a row's name as a file's
    reflaser_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # reflaser_net SEED KIND: the network's file, trained before or the reference
    reflaser_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            for sd in 1 2 3 4 5; do echo "$(reflaser_net $sd $k) $(reflaser_row "$name") --seed $sd $setting"; done
        done < "$work/out/reflaser_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'reflaser_one "$@"' _

    # reflaser_file SEED KIND NAME: the file reflaser_one wrote for that run
    reflaser_file() { echo "$work/out/reflaser.d/$(basename "$(reflaser_net "$1" "$2")" .net)_$(reflaser_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its rows are
    # version 2's, written out again here; under a laser the receiver's noise
    # has to be that laser's in what it was asked, rows / 512 over the multiple
    # its name says, and in every layer of the line it printed, to the Q8.8 it
    # is held in; the hidden rescale has to be a bit down where its name says
    # and the rule's where it does not; and as budgeted there is no laser.
    reflaser_ok=yes
    reflaser_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(reflaser_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || reflaser_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(reflaser_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v rows="$rows" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = m == 5 && asked("abits") == 6 && asked("adcbits") == 8 && asked("photons8") == 30 &&
                               asked("prog") == 1 && asked("xtalk") == 0.02 && !("drift" in given) && !("src" in given) &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        laser = match(name, /laser x[0-9]+$/)
                        times = laser ? substr(name, RSTART + 7) + 0 : 0
                        down = (name ~ /a bit down/) ? 1 : 0
                        if (laser) sane = sane && times > 0 && !("thermal8" in given) &&
                                          near(asked("thermalline") * 512 * times / rows, 1, 1e-6) &&
                                          (down == (("hidshift" in given) ? 1 : 0)) && (!down || want["hidshift"] == -1) &&
                                          (down || name ~ /^the rule.s rescale, /)
                        else sane = sane && name == "as budgeted" && asked("thermal8") == 0.25 &&
                                    !("thermalline" in given) && !("hidshift" in given) }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               near(v["photons8"] / 30, 1, 0.03) && near(v["prog"], 1, 1e-9) &&
                               near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == "none" && v["hours"] == 0 && !("src" in v)
                          if (laser) {
                              line = (2 ^ (v["din"] - 1) - 1) * 2 ^ (v["din"] - 1)
                              nl = split(v["thermal_l"], tl, ","); split(v["S"], sv, ",")
                              ok = ok && nl == 2 && v["thermalline"] == want["thermalline"] + 0
                              for (i = 1; i <= nl; ++i)
                                  ok = ok && near(tl[i] * 2 ^ sv[i] / line, want["thermalline"], 2 ^ sv[i] / 512 / line)
                              if (down) ok = ok && v["hidshift"] == -1 && v["w1gain"] == 0
                              else ok = ok && !("hidshift" in v) && !("w1gain" in v)
                          } else ok = ok && near(v["thermal8"], 0.25, 1e-6) && !("thermalline" in v) && !("hidshift" in v) }
                END { exit !(NR == 2 && ok) }' || reflaser_ok=NO
            reflaser_runs=$((reflaser_runs + 1))
        done < "$work/out/reflaser_settings.txt"
    done; done
    echo "== reflaser: $reflaser_runs runs, each of them the network and the row its place says: $reflaser_ok"
    [ "$reflaser_ok" = yes ] || exit 1

    # reflaser_stat KIND NAME: five networks' loss, mean and standard error,
    # and that less the same networks' as budgeted, network by network
    reflaser_stat() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(reflaser_file $sd "$1" "as budgeted")"
            sed 's/^/B /' "$(reflaser_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["digital"] - v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # reflaser_right NAME: how often the five networks of each kind are right
    # in a row, and the reference less the one trained before, seed by seed
    reflaser_right() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(reflaser_file $sd before "$1")"
            sed 's/^/B /' "$(reflaser_file $sd reference "$1")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; as += a; ass += a * a; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f %7.2f +-%4.2f", as / n, se(as, ass, n), s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    echo "== reflaser: the $tile tile at v2, five networks, mean and standard error.  Points lost against"
    echo "== the same weights on the host under a laser, in multiples of grxcp's B5, and that less the"
    echo "== same networks as budgeted.  The reference networks are $PTA_REF_EPOCHS epochs with noise of $PTA_REF_NOISE"
    printf '%-36s %14s %14s %14s %14s' "" "before loses" "over budget" "reference" "over budget"
    echo
    while IFS='|' read -r name setting; do
        printf '%-36s' "$name"
        for k in before reference; do reflaser_stat $k "$name"; done
        echo
    done < "$work/out/reflaser_settings.txt"
    echo "== reflaser: how often they are right, percent, and the reference less the one trained"
    echo "== before, seed by seed"
    printf '%-36s %14s %14s %14s' "" "before" "reference" "the difference"
    echo
    while IFS='|' read -r name setting; do
        printf '%-36s' "$name"
        reflaser_right "$name"
        echo
    done < "$work/out/reflaser_settings.txt"
fi

# `refdrift`: how long a calibration holds for a reference network.  grxcp
# calibrates its version 2 every six minutes (its B15), chosen on what an
# hour of TFLT's drift adds to the networks trained before: 0.67 and 1.99
# points on the two harder data sets.  `refsource` ran six minutes on the
# reference networks and nothing longer.  This runs version 2 after three
# minutes to four hours of TFLT's drift on the reference networks, after an
# hour and then calibrated, after an hour of TFLN's, and held: a source's
# three rows at 1%, 5% and 5% at the end of six minutes, half an hour and an
# hour.  The networks trained before run beside them row for row, with more
# intervals than `v2` gave them.  It trains the reference networks where they
# are not there.
if [ "$what" = refdrift ]; then
    tile=${REFDRIFT_TILE:-128x64}
    buses=${REFDRIFT_BUSES:-2}
    hours=${REFDRIFT_HOURS:-0.05 0.1 0.25 0.5 1 2 4}
    heldh=${REFDRIFT_HELD:-0.1 0.5 1}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    # row|options: version 2 as budgeted, drifted, calibrated, and held
    {
        echo "as budgeted|--impair $all $r"
        for h in $hours; do echo "TFLT's drift, $h h|--impair $all,drift $r --drift tflt --hours $h"; done
        echo "TFLT's drift, 1 h, then calibrated|--impair $all,drift $r --drift tflt --hours 1 --calibrate 16"
        echo "TFLN's drift, 1 h|--impair $all,drift $r --drift tfln --hours 1"
        for h in $heldh; do
            echo "held, $h h|--impair $all,drift $r --drift tflt --hours $h --src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
        done
    } | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refdrift_settings.txt"
    # refdrift_one NET ROW ARGS...: one test-set pass, its line to
    # out/refdrift.d/NET_ROW.txt
    refdrift_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refdrift.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refdrift.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refdrift_one
    # refdrift_row NAME: a row's name as a file's
    refdrift_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refdrift_net SEED KIND: the network's file, trained before or the reference
    refdrift_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            for sd in 1 2 3 4 5; do echo "$(refdrift_net $sd $k) $(refdrift_row "$name") --seed $sd $setting"; done
        done < "$work/out/refdrift_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refdrift_one "$@"' _

    # refdrift_file SEED KIND NAME: the file refdrift_one wrote for that run
    refdrift_file() { echo "$work/out/refdrift.d/$(basename "$(refdrift_net "$1" "$2")" .net)_$(refdrift_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; it drifted for the hours its
    # name says, by TFLT's fit unless its name says TFLN's, and took steps of
    # drift if it drifted at all; it was calibrated only where its name says;
    # and a held run has a source's three rows at 1%, 5% and 5% through a
    # balanced pair, and no other run has a source.
    refdrift_ok=yes
    refdrift_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refdrift_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refdrift_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(refdrift_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = asked("abits") == 6 && asked("adcbits") == 8 && asked("thermal8") == 0.25 &&
                               asked("photons8") == 30 && asked("prog") == 1 && asked("xtalk") == 0.02 &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        budgeted = (name == "as budgeted") ? 1 : 0
                        hours = match(name, /, [0-9.]+ h/) ? substr(name, RSTART + 2, RLENGTH - 4) + 0 : 0
                        kind = budgeted ? "none" : (name ~ /^TFLN/) ? "tfln" : "tflt"
                        cal = (name ~ /then calibrated$/) ? 16 : 0
                        is_held = (name ~ /^held, /) ? 1 : 0
                        sane = sane && (budgeted || hours > 0) && (name ~ /^(as budgeted|TFL[TN].s drift, |held, )/) &&
                               ((!budgeted) == (("drift" in on) ? 1 : 0)) && ((!budgeted) == (("drift" in given) ? 1 : 0)) &&
                               (budgeted || want["drift"] == kind) && asked("hours") == hours && asked("calibrate") == cal &&
                               asked("src") == 0.01 * is_held && asked("srcline") == 0.05 * is_held &&
                               asked("srcflat") == 0.05 * is_held && asked("buses") == nb * is_held }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == kind && v["hours"] == hours && v["cal"] == cal &&
                               (v["steps"] > 0) == (!budgeted) && !("hidshift" in v) && !("thermalline" in v)
                          if (is_held) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] == 0.05 &&
                                            v["srcsign"] == "pair" && v["buses"] == nb
                          else ok = ok && !("src" in v) }
                END { exit !(NR == 2 && ok) }' || refdrift_ok=NO
            refdrift_runs=$((refdrift_runs + 1))
        done < "$work/out/refdrift_settings.txt"
    done; done
    echo "== refdrift: $refdrift_runs runs, each of them the network and the row its place says: $refdrift_ok"
    [ "$refdrift_ok" = yes ] || exit 1

    # refdrift_stat KIND NAME: five networks' loss, mean and standard error,
    # and what the row adds to that kind as budgeted, network by network
    refdrift_stat() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refdrift_file $sd "$1" "as budgeted")"
            sed 's/^/B /' "$(refdrift_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["digital"] - v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refdrift_right NAME: how often the five networks of each kind are right
    # in a row, and the reference less the one trained before, seed by seed
    refdrift_right() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refdrift_file $sd before "$1")"
            sed 's/^/B /' "$(refdrift_file $sd reference "$1")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; as += a; ass += a * a; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f %7.2f +-%4.2f", as / n, se(as, ass, n), s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    echo "== refdrift: the $tile tile on $buses buses at v2, five networks, mean and standard error.  Points"
    echo "== lost against the same weights on the host, and what a row adds to its own networks as"
    echo "== budgeted, network by network.  Held is with a source's three rows at 1%, 5% and 5%"
    printf '%-36s %14s %14s %14s %14s' "" "before loses" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-36s' "$name"
        for k in before reference; do refdrift_stat $k "$name"; done
        echo
    done < "$work/out/refdrift_settings.txt"
    echo "== refdrift: how often they are right, percent, and the reference less the one trained"
    echo "== before, seed by seed"
    printf '%-36s %14s %14s %14s' "" "before" "reference" "the difference"
    echo
    while IFS='|' read -r name setting; do
        printf '%-36s' "$name"
        refdrift_right "$name"
        echo
    done < "$work/out/refdrift_settings.txt"
fi

# `refcycle`: an interval that starts from a calibration.  Every drift row
# above ages a tile from weights as they were written.  A tile in use is
# never that: it is calibrated, drifts for an interval, and is calibrated
# again.  `refdrift` found a calibration leaves the reference networks about
# a tenth of a point short of where they started on two data sets, and
# could not say whether that was the calibration or the hour before it.  This
# runs version 2 calibrated as it was written, with no drift at all;
# calibrated after six minutes and after an hour; at the end of a cycle, which
# is a tile aged an interval, calibrated, and aged the interval again; an hour
# and a calibration and six minutes more, to see whether what came before a
# calibration matters; and held, with a source's three rows at 1%, 5% and 5%,
# at the end of a cycle and at the end of the same interval from weights as
# written.  Both kinds of network, row for row.  It trains the reference
# networks where they are not there.
if [ "$what" = refcycle ]; then
    tile=${REFCYCLE_TILE:-128x64}
    buses=${REFCYCLE_BUSES:-2}
    hours=${REFCYCLE_HOURS:-0.05 0.1 0.25 0.5 1}
    heldh=${REFCYCLE_HELD:-0.1 0.5 1}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    d="--impair $all,drift $r --drift tflt"
    src="--src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
    # row|options
    {
        echo "as budgeted|--impair $all $r"
        echo "calibrated|--impair $all $r --calibrate 16"
        for h in 0.1 1; do echo "aged $h h, calibrated|$d --hours $h --calibrate 16"; done
        for h in $hours; do echo "cycle of $h h|$d --hours $h --calibrate 16 --post-hours $h"; done
        echo "aged 1 h, calibrated, 0.1 h more|$d --hours 1 --calibrate 16 --post-hours 0.1"
        for h in $heldh; do echo "as written, $h h|$d --hours $h"; done
        for h in $heldh; do echo "held, as written, $h h|$d --hours $h $src"; done
        for h in $heldh; do echo "held, cycle of $h h|$d --hours $h --calibrate 16 --post-hours $h $src"; done
    } | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refcycle_settings.txt"
    # refcycle_one NET ROW ARGS...: one test-set pass, its line to
    # out/refcycle.d/NET_ROW.txt
    refcycle_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refcycle.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refcycle.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refcycle_one
    # refcycle_row NAME: a row's name as a file's
    refcycle_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refcycle_net SEED KIND: the network's file, trained before or the reference
    refcycle_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            for sd in 1 2 3 4 5; do echo "$(refcycle_net $sd $k) $(refcycle_row "$name") --seed $sd $setting"; done
        done < "$work/out/refcycle_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refcycle_one "$@"' _

    # refcycle_file SEED KIND NAME: the file refcycle_one wrote for that run
    refcycle_file() { echo "$work/out/refcycle.d/$(basename "$(refcycle_net "$1" "$2")" .net)_$(refcycle_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; and its name says how it was
    # aged, whether it was calibrated and how it was aged after, which have to
    # be what it was asked and what its line printed.  A cycle is aged the
    # same before its calibration and after.  A held run has a source's three
    # rows at 1%, 5% and 5% through a balanced pair, and no other run has one.
    refcycle_ok=yes
    refcycle_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refcycle_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refcycle_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(refcycle_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = asked("abits") == 6 && asked("adcbits") == 8 && asked("thermal8") == 0.25 &&
                               asked("photons8") == 30 && asked("prog") == 1 && asked("xtalk") == 0.02 &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        is_held = (name ~ /^held, /) ? 1 : 0
                        base = is_held ? substr(name, 7) : name
                        cyc = (base ~ /^cycle of [0-9.]+ h$/) ? 1 : 0
                        hours = match(base, /[0-9.]+ h/) ? substr(base, RSTART, RLENGTH - 2) + 0 : 0
                        rest = hours > 0 ? substr(base, RSTART + RLENGTH) : ""
                        more = match(rest, /[0-9.]+ h more$/) ? substr(rest, RSTART, RLENGTH - 7) + 0 : 0
                        post = cyc ? hours : more
                        cal = (cyc || base ~ /calibrated/) ? 16 : 0
                        drifts = (hours > 0) ? 1 : 0
                        known = base == "as budgeted" || base == "calibrated" || cyc ||
                                base ~ /^aged [0-9.]+ h, calibrated(, [0-9.]+ h more)?$/ || base ~ /^as written, [0-9.]+ h$/
                        sane = sane && known && (base != "as budgeted" || (!cal && !drifts && !is_held)) &&
                               (drifts == (("drift" in on) ? 1 : 0)) && (drifts == (("drift" in given) ? 1 : 0)) &&
                               (!drifts || want["drift"] == "tflt") && asked("hours") == hours &&
                               asked("calibrate") == cal && asked("post-hours") == post && (post == 0 || cal == 16) &&
                               asked("src") == 0.01 * is_held && asked("srcline") == 0.05 * is_held &&
                               asked("srcflat") == 0.05 * is_held && asked("buses") == nb * is_held }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == (drifts ? "tflt" : "none") && v["hours"] == hours && v["cal"] == cal &&
                               v["post_hours"] == post && (v["steps"] > 0) == drifts &&
                               !("hidshift" in v) && !("thermalline" in v)
                          if (is_held) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] == 0.05 &&
                                            v["srcsign"] == "pair" && v["buses"] == nb
                          else ok = ok && !("src" in v) }
                END { exit !(NR == 2 && ok) }' || refcycle_ok=NO
            refcycle_runs=$((refcycle_runs + 1))
        done < "$work/out/refcycle_settings.txt"
    done; done
    echo "== refcycle: $refcycle_runs runs, each of them the network and the row its place says: $refcycle_ok"
    [ "$refcycle_ok" = yes ] || exit 1

    # refcycle_stat KIND NAME: five networks' loss, mean and standard error,
    # and what the row adds to that kind as budgeted, network by network
    refcycle_stat() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refcycle_file $sd "$1" "as budgeted")"
            sed 's/^/B /' "$(refcycle_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["digital"] - v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refcycle_right NAME: how often the five networks of each kind are right
    # in a row, and the reference less the one trained before, seed by seed
    refcycle_right() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refcycle_file $sd before "$1")"
            sed 's/^/B /' "$(refcycle_file $sd reference "$1")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; as += a; ass += a * a; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f %7.2f +-%4.2f", as / n, se(as, ass, n), s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    echo "== refcycle: the $tile tile on $buses buses at v2, five networks, mean and standard error.  Points"
    echo "== lost against the same weights on the host, and what a row adds to its own networks as"
    echo "== budgeted, network by network.  A cycle is aged, calibrated and aged the same again"
    printf '%-36s %14s %14s %14s %14s' "" "before loses" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-36s' "$name"
        for k in before reference; do refcycle_stat $k "$name"; done
        echo
    done < "$work/out/refcycle_settings.txt"
    echo "== refcycle: how often they are right, percent, and the reference less the one trained"
    echo "== before, seed by seed"
    printf '%-36s %14s %14s %14s' "" "before" "reference" "the difference"
    echo
    while IFS='|' read -r name setting; do
        printf '%-36s' "$name"
        refcycle_right "$name"
        echo
    done < "$work/out/refcycle_settings.txt"
fi

# `refcal`: what in a calibration costs a network.  `refcycle` found a tile
# calibrated as it was written, with no drift at all, costs the reference
# networks 0.08 of a point on MNIST, and that the tile's sums are no further
# off for it.  A calibrated run differs from the run as budgeted in two
# things.  One is the trims it writes: with no drift a trim is minus the mean
# of the programming errors its probes happened to meet, which is nothing a
# cell will meet again.  The other is its draws: the probes are GEMMs, 6 a
# probe, and every GEMM takes the next seed, so each image of a calibrated run
# meets other noise and other programming errors than it does as budgeted.
# This takes them apart.  `--calibrate N --trimmax 0` takes the probes and
# writes nothing, which is the calibrated run's draws on the budgeted tile:
# a calibrated row less that one is the trims and nothing else.  It runs both
# at each number of probes, a finer trim step, and the tile as budgeted on
# other draws, which says how far a network moves from one draw to the next
# with nothing else changed.  Both kinds of network, row for row.  No drift
# anywhere.
if [ "$what" = refcal ]; then
    tile=${REFCAL_TILE:-128x64}
    probes=${REFCAL_PROBES:-1 4 16 64}
    steps=${REFCAL_STEPS:-0.0625 0.00390625}
    draws=${REFCAL_DRAWS:-1 2}
    more=${REFCAL_MORE:-3 4 5 6}
    case " $probes " in *" 16 "*) ;; *) echo "pta_mnist.sh: REFCAL_PROBES has to hold 16" >&2; exit 2 ;; esac
    most=${probes##* }
    fine=${steps##* }
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    b="--impair $all $r"
    # row|options.  A row's name says its probes, its trim step if it is not
    # the quarter LSB, and its draw if it is not the network's own seed.
    {
        echo "as budgeted|$b"
        for n in $probes; do echo "calibrated, $n probes|$b --calibrate $n"; done
        for n in $probes; do echo "probes only, $n probes|$b --calibrate $n --trimmax 0"; done
        for x in $steps; do echo "calibrated, 16 probes, step $x|$b --calibrate 16 --trimstep $x"; done
        [ "$most" = 16 ] || echo "calibrated, $most probes, step $fine|$b --calibrate $most --trimstep $fine"
        for dd in $draws; do
            echo "as budgeted, draw $dd|$b"
            echo "calibrated, 16 probes, draw $dd|$b --calibrate 16"
            echo "probes only, 16 probes, draw $dd|$b --calibrate 16 --trimmax 0"
        done
        for dd in $more; do echo "as budgeted, draw $dd|$b"; done
    } | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refcal_settings.txt"
    # refcal_one NET ROW ARGS...: one test-set pass, its line to
    # out/refcal.d/NET_ROW.txt
    refcal_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refcal.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refcal.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refcal_one
    # refcal_row NAME: a row's name as a file's
    refcal_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refcal_net SEED KIND: the network's file, trained before or the reference
    refcal_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    # refcal_draw NAME: the draw a row's name says, 0 if it says none
    refcal_draw() { case "$1" in *", draw "*) echo "${1##*, draw }" ;; *) echo 0 ;; esac; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=$(refcal_draw "$name")
            for sd in 1 2 3 4 5; do echo "$(refcal_net $sd $k) $(refcal_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/refcal_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refcal_one "$@"' _

    # refcal_file SEED KIND NAME: the file refcal_one wrote for that run
    refcal_file() { echo "$work/out/refcal.d/$(basename "$(refcal_net "$1" "$2")" .net)_$(refcal_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; nothing in it drifts and no
    # source is lit; and its name says whether it was calibrated, with how many
    # probes, whether the trims were written, at what trim step and on which
    # draw, which have to be what it was asked and what its line printed.
    refcal_ok=yes
    refcal_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refcal_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refcal_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(refcal_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = asked("abits") == 6 && asked("adcbits") == 8 && asked("thermal8") == 0.25 &&
                               asked("photons8") == 30 && asked("prog") == 1 && asked("xtalk") == 0.02 && m == 5 &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        base = name
                        draw = 0
                        if (match(base, /, draw [0-9]+$/)) { draw = substr(base, RSTART + 7) + 0; base = substr(base, 1, RSTART - 1) }
                        step = 0.25
                        stepped = 0
                        if (match(base, /, step [0-9.]+$/)) { step = substr(base, RSTART + 7) + 0; stepped = 1; base = substr(base, 1, RSTART - 1) }
                        only = (base ~ /^probes only, [0-9]+ probes$/) ? 1 : 0
                        wrote = (base ~ /^calibrated, [0-9]+ probes$/) ? 1 : 0
                        probes = match(base, /[0-9]+ probes$/) ? substr(base, RSTART, RLENGTH - 7) + 0 : 0
                        known = base == "as budgeted" || only || wrote
                        sane = sane && known && (!stepped || wrote) && ((only || wrote) == (probes > 0)) &&
                               (name !~ /, draw 0$/) && (step > 0) && (step < 0.25 || !stepped) &&
                               !has("drift") && !has("hours") && !has("post-hours") && !has("src") && !has("seed") &&
                               has("calibrate") == (only || wrote) && asked("calibrate") == probes &&
                               has("trimmax") == only && asked("trimmax") == 0 &&
                               has("trimstep") == stepped && (!stepped || near(asked("trimstep"), step, 1e-12)) }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == "none" && v["hours"] == 0 && v["steps"] == 0 && v["post_hours"] == 0 &&
                               v["cal"] == probes && near(v["trimstep"], step, 1e-12) && v["trimmax"] == (only ? 0 : 128) &&
                               !("hidshift" in v) && !("thermalline" in v) && !("src" in v) }
                END { exit !(NR == 2 && ok) }' || refcal_ok=NO
            refcal_runs=$((refcal_runs + 1))
        done < "$work/out/refcal_settings.txt"
    done; done
    echo "== refcal: $refcal_runs runs, each of them the network and the row its place says: $refcal_ok"
    [ "$refcal_ok" = yes ] || exit 1

    # refcal_stat KIND NAME: five networks' loss, mean and standard error,
    # and what the row adds to that kind as budgeted, network by network
    refcal_stat() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refcal_file $sd "$1" "as budgeted")"
            sed 's/^/B /' "$(refcal_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["digital"] - v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refcal_right NAME: how often the five networks of each kind are right
    # in a row, and the reference less the one trained before, seed by seed
    refcal_right() {
        local sd
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refcal_file $sd before "$1")"
            sed 's/^/B /' "$(refcal_file $sd reference "$1")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; as += a; ass += a * a; next }
              n++; s += x; ss += x * x; g = x - a; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f %7.2f +-%4.2f", as / n, se(as, ass, n), s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refcal_partner NAME: the row that took a calibrated row's probes, on its
    # draw, and wrote nothing
    refcal_partner() {
        local n=${1#calibrated, } dd
        n=${n%% probes*}
        dd=$(refcal_draw "$1")
        if [ "$dd" = 0 ]; then echo "probes only, $n probes"; else echo "probes only, $n probes, draw $dd"; fi
    }
    # refcal_trims KIND NAME: what the trims add: how often the five networks
    # are right with the probes taken and nothing written, less calibrated,
    # network by network
    refcal_trims() {
        local sd partner
        partner=$(refcal_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refcal_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(refcal_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f", gs / n, se(gs, gss, n) }'
    }
    # refcal_draws KIND: the tile as budgeted on its other draws, which are
    # the other seeds and the rows that took probes and wrote nothing.  How
    # many; how often the five networks are right on them; the as-budgeted row
    # less a network's mean over them, network by network; a network's
    # standard deviation from draw to draw, rms over the five; and that of the
    # five networks' mean
    refcal_draws() {
        local sd name setting r
        for sd in 1 2 3 4 5; do
            sed "s/^/O $sd 0 /" "$(refcal_file $sd "$1" "as budgeted")"
            r=0
            while IFS='|' read -r name setting; do
                case "$name" in
                "as budgeted, draw "*|"probes only, "*) r=$((r + 1)); sed "s/^/D $sd $r /" "$(refcal_file $sd "$1" "$name")" ;;
                esac
            done < "$work/out/refcal_settings.txt"
        done | awk '
            { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0
              if ($1 == "O") { own[$2] = x; next }
              s[$2] += x; ss[$2] += x * x; n[$2]++; rs[$3] += x; rn[$3]++ }
            END { for (sd = 1; sd <= 5; ++sd) { m = s[sd] / n[sd]; var = (ss[sd] - n[sd] * m * m) / (n[sd] - 1); if (var < 0) var = 0
                                                 d = own[sd] - m; ds += d; dss += d * d; ms += m; vs += var; nd = n[sd] }
                  for (r in rs) { q = rs[r] / rn[r]; qs += q; qss += q * q; nr++ }
                  dm = ds / 5; dvar = dss / 5 - dm * dm; if (dvar < 0) dvar = 0
                  qm = qs / nr; qvar = (qss - nr * qm * qm) / (nr - 1); if (qvar < 0) qvar = 0
                  printf " %6d %9.3f %8.3f +-%5.3f %9.3f %9.3f", nd, ms / 5, dm, sqrt(dvar / 4), sqrt(vs / 5), sqrt(qvar) }'
    }
    echo "== refcal: the $tile tile at v2, no drift, five networks, mean and standard error.  Points"
    echo "== lost against the same weights on the host, and what a row adds to its own networks as"
    echo "== budgeted, network by network.  Probes only: the probes taken and no trim written"
    printf '%-40s %14s %14s %14s %14s' "" "before loses" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-40s' "$name"
        for k in before reference; do refcal_stat $k "$name"; done
        echo
    done < "$work/out/refcal_settings.txt"
    echo "== refcal: how often they are right, percent, and the reference less the one trained"
    echo "== before, seed by seed"
    printf '%-40s %14s %14s %14s' "" "before" "reference" "the difference"
    echo
    while IFS='|' read -r name setting; do
        printf '%-40s' "$name"
        refcal_right "$name"
        echo
    done < "$work/out/refcal_settings.txt"
    echo "== refcal: what the trims add: right with the same probes taken and nothing written,"
    echo "== less right calibrated, network by network.  The two runs meet the same draws"
    printf '%-40s %14s %14s' "" "before" "reference"
    echo
    while IFS='|' read -r name setting; do
        case "$name" in "calibrated, "*) ;; *) continue ;; esac
        printf '%-40s' "$name"
        for k in before reference; do refcal_trims $k "$name"; done
        echo
    done < "$work/out/refcal_settings.txt"
    echo "== refcal: the tile as budgeted on its other draws: other seeds, and probes taken and"
    echo "== nothing written.  How often right on them; the as-budgeted row less a network's mean"
    echo "== over them, network by network; and the standard deviation from draw to draw"
    printf '%-12s %6s %9s %15s %9s %9s' "" "draws" "right" "as budgeted less" "a network" "the mean"
    echo
    for k in before reference; do
        printf '%-12s' "$k"
        refcal_draws $k
        echo
    done
fi

# `refdraws`: the working point over draws.  `refcal` found that a row moves
# when nothing changes but its draw, that every row before it is one draw,
# and that a row is to be read against a row that meets the same draws.  A
# six-minute cycle on the inverted set had by then been drawn three times, at
# 0.08, 0.11 and 0.30 of a point over the tile as budgeted, and a tenth was
# not pinned between them.  This runs five rows on each of ten draws: the
# tile as budgeted; held as grxcp holds the chip, which is six minutes of
# drift from weights as written and a source's three rows at 1%, 5% and 5%;
# a calibration's probes taken and nothing written; and a cycle of three
# minutes and of six.  A draw D seeds the tile with the network's seed and
# 10 D more, which moves its noise, its drift's walk and its source.  A cycle
# is read over the probes-only row of its own draw and the held row over the
# as-budgeted row of its own draw: each pair meets the same noise.  Both
# kinds of network, row for row.
if [ "$what" = refdraws ]; then
    tile=${REFDRAWS_TILE:-128x64}
    buses=${REFDRAWS_BUSES:-2}
    draws=${REFDRAWS_DRAWS:-0 1 2 3 4 5 6 7 8 9}
    hours=${REFDRAWS_HOURS:-0.05 0.1}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    b="--impair $all $r"
    d="--impair $all,drift $r --drift tflt"
    src="--src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
    # row|options.  Every row's name ends in its draw.
    for dd in $draws; do
        echo "as budgeted, draw $dd|$b"
        echo "held, as written, 0.1 h, draw $dd|$d --hours 0.1 $src"
        echo "probes only, draw $dd|$b --calibrate 16 --trimmax 0"
        for h in $hours; do echo "cycle of $h h, draw $dd|$d --hours $h --calibrate 16 --post-hours $h"; done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refdraws_settings.txt"
    # refdraws_one NET ROW ARGS...: one test-set pass, its line to
    # out/refdraws.d/NET_ROW.txt
    refdraws_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refdraws.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refdraws.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refdraws_one
    # refdraws_row NAME: a row's name as a file's
    refdraws_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refdraws_net SEED KIND: the network's file, trained before or the reference
    refdraws_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(refdraws_net $sd $k) $(refdraws_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/refdraws_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refdraws_one "$@"' _

    # refdraws_file SEED KIND NAME: the file refdraws_one wrote for that run
    refdraws_file() { echo "$work/out/refdraws.d/$(basename "$(refdraws_net "$1" "$2")" .net)_$(refdraws_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; its seed is its draw's; and its
    # name says whether it drifted, for how long before a calibration and
    # after, whether its probes were taken and its trims written, and whether
    # a source is lit, which have to be what it was asked and what its line
    # printed.
    refdraws_ok=yes
    refdraws_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refdraws_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refdraws_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(refdraws_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = asked("abits") == 6 && asked("adcbits") == 8 && asked("thermal8") == 0.25 &&
                               asked("photons8") == 30 && asked("prog") == 1 && asked("xtalk") == 0.02 &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        budget = (base == "as budgeted") ? 1 : 0
                        only = (base == "probes only") ? 1 : 0
                        is_held = (base ~ /^held, as written, [0-9.]+ h$/) ? 1 : 0
                        cyc = (base ~ /^cycle of [0-9.]+ h$/) ? 1 : 0
                        hours = (is_held || cyc) ? (match(base, /[0-9.]+ h$/) ? substr(base, RSTART, RLENGTH - 2) + 0 : 0) : 0
                        post = cyc ? hours : 0
                        cal = (cyc || only) ? 16 : 0
                        drifts = (hours > 0) ? 1 : 0
                        sane = sane && drawn && (budget + only + is_held + cyc == 1) && ((is_held || cyc) == drifts) && m == 5 + drifts &&
                               (drifts == (("drift" in on) ? 1 : 0)) && (drifts == has("drift")) && !has("seed") &&
                               (!drifts || want["drift"] == "tflt") && has("hours") == drifts && asked("hours") == hours &&
                               has("calibrate") == (cal > 0) && asked("calibrate") == cal &&
                               has("post-hours") == cyc && asked("post-hours") == post &&
                               has("trimmax") == only && asked("trimmax") == 0 && !has("trimstep") &&
                               has("src") == is_held && asked("src") == 0.01 * is_held && asked("srcline") == 0.05 * is_held &&
                               asked("srcflat") == 0.05 * is_held && asked("buses") == nb * is_held }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == (drifts ? "tflt" : "none") && v["hours"] == hours && (v["steps"] > 0) == drifts &&
                               v["cal"] == cal && v["post_hours"] == post && near(v["trimstep"], 0.25, 1e-12) &&
                               v["trimmax"] == (only ? 0 : 128) && !("hidshift" in v) && !("thermalline" in v)
                          if (is_held) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] == 0.05 &&
                                            v["srcsign"] == "pair" && v["buses"] == nb
                          else ok = ok && !("src" in v) }
                END { exit !(NR == 2 && ok) }' || refdraws_ok=NO
            refdraws_runs=$((refdraws_runs + 1))
        done < "$work/out/refdraws_settings.txt"
    done; done
    echo "== refdraws: $refdraws_runs runs, each of them the network and the row its place says: $refdraws_ok"
    [ "$refdraws_ok" = yes ] || exit 1

    # refdraws_partner NAME: the row a row is read over, which meets its
    # noise: the as-budgeted row of its draw for the held row and the
    # probes-only one, and the probes-only row of its draw for a cycle.  The
    # as-budgeted row of a draw is read over the first draw's
    refdraws_partner() {
        local base=${1%, draw *} dd=${1##*, draw }
        case "$base" in
        "as budgeted") echo "as budgeted, draw ${draws%% *}" ;;
        "cycle of "*) echo "probes only, draw $dd" ;;
        *) echo "as budgeted, draw $dd" ;;
        esac
    }
    # refdraws_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    refdraws_stat() {
        local sd partner
        partner=$(refdraws_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refdraws_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(refdraws_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refdraws_over KIND BASE: a row over all its draws.  How often right, and
    # what it adds over its partner: the mean; its standard error, from the
    # five networks, each averaged over its draws; and the standard deviation
    # from draw to draw of the five networks' mean
    refdraws_over() {
        local sd dd name
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                name="$2, draw $dd"
                sed "s/^/A $sd $dd /" "$(refdraws_file $sd "$1" "$(refdraws_partner "$name")")"
                sed "s/^/B $sd $dd /" "$(refdraws_file $sd "$1" "$name")"
            done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0
              if ($1 == "A") { a = x; next }
              g = a - x
              rn[$2] += x; gn[$2] += g; cn[$2]++; rd[$3] += x; gd[$3] += g; cd[$3]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; g = gn[k] / cn[k]; rs += x; rss += x * x; gs += g; gss += g * g; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; g = gd[k] / cd[k]; ds += x; dss += x * x; hs += g; hss += g * g; nd++ }
                  printf " %8.3f +-%5.3f %6.3f %7.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd),
                         gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd) }'
    }
    echo "== refdraws: the $tile tile on $buses buses at v2, five networks, mean and standard error.  How"
    echo "== often right, percent, and what a row adds over the row it is read over, network by"
    echo "== network: a cycle over the probes-only row of its draw, the held row and the probes-only"
    echo "== one over the as-budgeted row of their draw, and that over the first draw's"
    printf '%-34s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-34s' "$name"
        for k in before reference; do refdraws_stat $k "$name"; done
        echo
    done < "$work/out/refdraws_settings.txt"
    echo "== refdraws: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-26s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/refdraws_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-26s' "$base"
        for k in before reference; do refdraws_over $k "$base"; done
        echo
    done
fi

# `reflevel`: a comb's lines that are not level, and a probe that reads them.
# grxcp's plan asks for lines level to 5% and says nothing built measures a
# line's level: the cell calibration probes through a weight of zero, which a
# line's power multiplies.  `eval --levelprobe P` is that measurement: a row
# at full scale against a full-scale weight, its neighbours' weights at zero,
# P shots a row, and what it reads taken off the line.  This lights the tile
# with a source's noise at the plan's two rows, 1% for the lines together and
# 5% for a line on its own, and then leaves the lines level, or off by 5%,
# 20% and 40% rms, each as it is and each read with sixteen shots a row; the
# middle one read with one shot and with sixty-four; and the tile held as
# grxcp holds the chip, six minutes of drift on, as it is and read.  The probe
# draws from a seed of its own, so a row that is read meets the noise the row
# that is not does, and every lit row meets the noise of the level row of its
# draw.  A draw D seeds the tile with the network's seed and 10 D more, which
# moves its noise, its drift's walk, its source and which lines are high.
# Both kinds of network, row for row.
if [ "$what" = reflevel ]; then
    tile=${REFLEVEL_TILE:-128x64}
    buses=${REFLEVEL_BUSES:-2}
    draws=${REFLEVEL_DRAWS:-0 1 2}
    lines=${REFLEVEL_LINES:-0.05 0.2 0.4}
    shots=${REFLEVEL_SHOTS:-1 64}
    at=${REFLEVEL_AT:-0.2}
    case " $lines " in *" $at "*) ;; *) echo "reflevel: REFLEVEL_AT has to be one of REFLEVEL_LINES" >&2; exit 2 ;; esac
    case " $shots " in *" 16 "*) echo "reflevel: REFLEVEL_SHOTS are the shots beside 16" >&2; exit 2 ;; esac
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    b="--impair $all $r"
    d="--impair $all,drift $r --drift tflt"
    n="--src 0.01 --srcline 0.05 --buses $buses"
    src="--src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
    # row|options.  Every row's name ends in its draw.
    for dd in $draws; do
        echo "as budgeted, draw $dd|$b"
        echo "lit, lines level, draw $dd|$b $n"
        echo "lit, lines level, read, draw $dd|$b $n --levelprobe 16"
        for x in $lines; do
            echo "lit, lines to $x, draw $dd|$b $n --srcflat $x"
            echo "lit, lines to $x, read, draw $dd|$b $n --srcflat $x --levelprobe 16"
        done
        for p in $shots; do echo "lit, lines to $at, read with $p, draw $dd|$b $n --srcflat $at --levelprobe $p"; done
        echo "held, as written, 0.1 h, draw $dd|$d --hours 0.1 $src"
        echo "held, as written, 0.1 h, read, draw $dd|$d --hours 0.1 $src --levelprobe 16"
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/reflevel_settings.txt"
    # reflevel_one NET ROW ARGS...: one test-set pass, its line to
    # out/reflevel.d/NET_ROW.txt
    reflevel_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/reflevel.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/reflevel.d/$(basename "$net" .net)_$row.txt"
    }
    export -f reflevel_one
    # reflevel_row NAME: a row's name as a file's
    reflevel_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # reflevel_net SEED KIND: the network's file, trained before or the reference
    reflevel_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(reflevel_net $sd $k) $(reflevel_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/reflevel_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'reflevel_one "$@"' _

    # reflevel_file SEED KIND NAME: the file reflevel_one wrote for that run
    reflevel_file() { echo "$work/out/reflevel.d/$(basename "$(reflevel_net "$1" "$2")" .net)_$(reflevel_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; its seed is its draw's; and its
    # name says whether it is lit, how far from level its lines are, whether
    # they were read and with how many shots a row, and whether it drifted,
    # which have to be what it was asked and what its line printed.  A row that
    # was read also has to have found what its name says is there: nothing on
    # level lines, and otherwise within four parts in ten of it, which sixty-four
    # lines drawn at that rms are.
    reflevel_ok=yes
    reflevel_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(reflevel_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || reflevel_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(reflevel_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = asked("abits") == 6 && asked("adcbits") == 8 && asked("thermal8") == 0.25 &&
                               asked("photons8") == 30 && asked("prog") == 1 && asked("xtalk") == 0.02 &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        probe = 0
                        if (match(base, /, read with [0-9]+$/)) { probe = substr(base, RSTART + 12) + 0; base = substr(base, 1, RSTART - 1) }
                        else if (match(base, /, read$/)) { probe = 16; base = substr(base, 1, RSTART - 1) }
                        budget = (base == "as budgeted") ? 1 : 0
                        is_held = (base == "held, as written, 0.1 h") ? 1 : 0
                        level = (base == "lit, lines level") ? 1 : 0
                        uneven = (base ~ /^lit, lines to [0-9.]+$/) ? 1 : 0
                        flat = uneven ? substr(base, 15) + 0 : 0.05 * is_held
                        lit = level + uneven + is_held
                        sane = sane && drawn && (budget + lit == 1) && !(budget && probe) && (!uneven || flat > 0) && m == 5 + is_held &&
                               (is_held == (("drift" in on) ? 1 : 0)) && (is_held == has("drift")) && !has("seed") &&
                               (!is_held || want["drift"] == "tflt") && has("hours") == is_held && asked("hours") == 0.1 * is_held &&
                               !has("calibrate") && !has("post-hours") && !has("trimmax") && !has("trimstep") &&
                               has("src") == lit && asked("src") == 0.01 * lit && has("srcline") == lit && asked("srcline") == 0.05 * lit &&
                               has("srcflat") == (flat > 0) && asked("srcflat") == flat && has("buses") == lit && asked("buses") == nb * lit &&
                               !has("srcsign") && has("levelprobe") == (probe > 0) && asked("levelprobe") == probe }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == (is_held ? "tflt" : "none") && v["hours"] == 0.1 * is_held && (v["steps"] > 0) == is_held &&
                               v["cal"] == 0 && v["post_hours"] == 0 && near(v["trimstep"], 0.25, 1e-12) &&
                               v["trimmax"] == 128 && !("hidshift" in v) && !("thermalline" in v)
                          if (lit) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] + 0 == flat &&
                                        v["srcsign"] == "pair" && v["buses"] == nb
                          else ok = ok && !("src" in v)
                          if (probe) ok = ok && v["levelprobe"] == probe && ("level_left" in v) &&
                                          ((flat > 0) ? near(v["level_found"] / flat, 1, 0.4) : v["level_found"] == 0)
                          else ok = ok && !("levelprobe" in v) && !("level_found" in v) && !("level_left" in v) }
                END { exit !(NR == 2 && ok) }' || reflevel_ok=NO
            reflevel_runs=$((reflevel_runs + 1))
        done < "$work/out/reflevel_settings.txt"
    done; done
    echo "== reflevel: $reflevel_runs runs, each of them the network and the row its place says: $reflevel_ok"
    [ "$reflevel_ok" = yes ] || exit 1

    # reflevel_partner NAME: the row a row is read over, which meets its
    # noise: the level row of its draw for a lit row, read or not, and the
    # as-budgeted row of its draw for the level row and for the two held
    # rows.  The as-budgeted row of a draw is read over the first draw's
    reflevel_partner() {
        local base=${1%, draw *} dd=${1##*, draw }
        case "$base" in
        "as budgeted") echo "as budgeted, draw ${draws%% *}" ;;
        "lit, lines level") echo "as budgeted, draw $dd" ;;
        "lit, "*) echo "lit, lines level, draw $dd" ;;
        *) echo "as budgeted, draw $dd" ;;
        esac
    }
    # reflevel_unread BASE: the row a read row was read from
    reflevel_unread() { echo "${1%, read*}"; }
    # reflevel_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    reflevel_stat() {
        local sd partner
        partner=$(reflevel_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(reflevel_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(reflevel_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # reflevel_over KIND BASE: a row over all its draws.  How often right, and
    # what it adds over its partner: the mean; its standard error, from the
    # five networks, each averaged over its draws; and the standard deviation
    # from draw to draw of the five networks' mean
    reflevel_over() {
        local sd dd name
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                name="$2, draw $dd"
                sed "s/^/A $sd $dd /" "$(reflevel_file $sd "$1" "$(reflevel_partner "$name")")"
                sed "s/^/B $sd $dd /" "$(reflevel_file $sd "$1" "$name")"
            done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0
              if ($1 == "A") { a = x; next }
              g = a - x
              rn[$2] += x; gn[$2] += g; cn[$2]++; rd[$3] += x; gd[$3] += g; cd[$3]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; g = gn[k] / cn[k]; rs += x; rss += x * x; gs += g; gss += g * g; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; g = gd[k] / cd[k]; ds += x; dss += x * x; hs += g; hss += g * g; nd++ }
                  printf " %8.3f +-%5.3f %6.3f %7.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd),
                         gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd) }'
    }
    # reflevel_read KIND BASE: a read row over all its draws, against the row
    # it was read from.  What the read buys, which is the read row less the
    # other, network by network: the mean, its standard error from the five
    # networks each averaged over its draws, and the standard deviation from
    # draw to draw of the five networks' mean.  And the lines themselves, in
    # percent, a mean over the runs of each run's rms: what was there, and
    # what the probe left
    reflevel_read() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(reflevel_file $sd "$1" "$(reflevel_unread "$2"), draw $dd")"
                sed "s/^/B $sd $dd /" "$(reflevel_file $sd "$1" "$2, draw $dd")"
            done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0
              if ($1 == "A") { a = x; next }
              g = x - a
              gn[$2] += g; cn[$2]++; gd[$3] += g; cd[$3]++; fs += v["level_found"]; ls += v["level_left"]; runs++ }
            END { for (k in cn) { g = gn[k] / cn[k]; gs += g; gss += g * g; nn++ }
                  for (k in cd) { g = gd[k] / cd[k]; hs += g; hss += g * g; nd++ }
                  printf " %7.3f +-%5.3f %6.3f %7.2f %6.2f", gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd),
                         100 * fs / runs, 100 * ls / runs }'
    }
    echo "== reflevel: the $tile tile on $buses buses at v2, five networks, mean and standard error.  How"
    echo "== often right, percent, and what a row adds over the row it is read over, network by"
    echo "== network: a lit row over the level row of its draw, the level row and the held rows"
    echo "== over the as-budgeted row of their draw, and that over the first draw's"
    printf '%-40s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-40s' "$name"
        for k in before reference; do reflevel_stat $k "$name"; done
        echo
    done < "$work/out/reflevel_settings.txt"
    echo "== reflevel: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-32s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/reflevel_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-32s' "$base"
        for k in before reference; do reflevel_over $k "$base"; done
        echo
    done
    echo "== reflevel: what a read buys: a read row less the row it was read from, network by"
    echo "== network, over its draws, with its standard error and its standard deviation from draw"
    echo "== to draw; and the lines, percent rms: what was there, and what the probe left"
    printf '%-32s %24s %14s %24s %14s' "" "before: buys" "found, left" "reference: buys" "found, left"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/reflevel_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        case "$base" in *", read"*) ;; *) continue ;; esac
        printf '%-32s' "$base"
        for k in before reference; do reflevel_read $k "$base"; done
        echo
    done
fi

# `reffix`: what the level probe reads, applied where a chip could apply it.
# `reflevel` read a comb's lines and took what it read off the model's own
# record of each line, exactly, which no chip can do.  `eval --levelfix` puts
# the reading where a host has something to turn, a row at a time: on the
# weights as written, which the tile then quantises to its 6 bits; on the
# 6-bit weights written at 8 bits, which is what grxcp's calibration note
# puts behind a weight code; or on the inputs.  A dim line's row has to be
# raised and a weight or an input at the rail cannot be, so either it is held
# there, or with `--levelref dimmest` every row is scaled down to the dimmest
# line's and the sums divided back, which costs light.  This lights the tile
# as `reflevel` does, with the source's noise at 1% and 5% and the lines 5%
# and 20% off, and runs each as it is, read as `reflevel` read it, and
# corrected five ways; and the tile held as grxcp holds the chip, as it is,
# read, and corrected two ways.  Every row with a probe takes the same probe
# draws, and none of them the run's, so every lit row meets the noise of the
# level row of its draw.  Both kinds of network, row for row.
if [ "$what" = reffix ]; then
    tile=${REFFIX_TILE:-128x64}
    buses=${REFFIX_BUSES:-2}
    draws=${REFFIX_DRAWS:-0 1 2}
    lines=${REFFIX_LINES:-0.05 0.2}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    b="--impair $all $r"
    d="--impair $all,drift $r --drift tflt"
    n="--src 0.01 --srcline 0.05 --buses $buses"
    src="--src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
    p="--levelprobe 16"
    # row|options.  Every row's name ends in its draw.
    for dd in $draws; do
        echo "as budgeted, draw $dd|$b"
        echo "lit, lines level, draw $dd|$b $n"
        for x in $lines; do
            echo "lit, lines to $x, draw $dd|$b $n --srcflat $x"
            echo "lit, lines to $x, read, draw $dd|$b $n --srcflat $x $p"
            echo "lit, lines to $x, on the weights, draw $dd|$b $n --srcflat $x $p --levelfix weights"
            echo "lit, lines to $x, on the weights at 8 bits, draw $dd|$b $n --srcflat $x $p --levelfix weights8"
            echo "lit, lines to $x, on the weights at 8 bits, to the dimmest, draw $dd|$b $n --srcflat $x $p --levelfix weights8 --levelref dimmest"
            echo "lit, lines to $x, on the inputs, draw $dd|$b $n --srcflat $x $p --levelfix inputs"
            echo "lit, lines to $x, on the inputs, to the dimmest, draw $dd|$b $n --srcflat $x $p --levelfix inputs --levelref dimmest"
        done
        echo "held, as written, 0.1 h, draw $dd|$d --hours 0.1 $src"
        echo "held, as written, 0.1 h, read, draw $dd|$d --hours 0.1 $src $p"
        echo "held, as written, 0.1 h, on the weights at 8 bits, draw $dd|$d --hours 0.1 $src $p --levelfix weights8"
        echo "held, as written, 0.1 h, on the inputs, to the dimmest, draw $dd|$d --hours 0.1 $src $p --levelfix inputs --levelref dimmest"
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/reffix_settings.txt"
    # reffix_one NET ROW ARGS...: one test-set pass, its line to
    # out/reffix.d/NET_ROW.txt
    reffix_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/reffix.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/reffix.d/$(basename "$net" .net)_$row.txt"
    }
    export -f reffix_one
    # reffix_row NAME: a row's name as a file's
    reffix_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # reffix_net SEED KIND: the network's file, trained before or the reference
    reffix_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(reffix_net $sd $k) $(reffix_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/reffix_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'reffix_one "$@"' _

    # reffix_file SEED KIND NAME: the file reffix_one wrote for that run
    reffix_file() { echo "$work/out/reffix.d/$(basename "$(reffix_net "$1" "$2")" .net)_$(reffix_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; its seed is its draw's; and its
    # name says whether it is lit, how far from level its lines are, whether
    # they were read, where the reading was applied and whether to the dimmest
    # line, and whether it drifted, which have to be what it was asked and
    # what its line printed.  A row that was read has to have found what its
    # name says is there.  One corrected at 8 bits has to have run the tile at
    # 8-bit weights, and no other may.  One scaled to the dimmest line has to
    # have taken something off its sums and held nothing at a rail, and one
    # that was not has to have taken nothing off.
    reffix_ok=yes
    reffix_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(reffix_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || reffix_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(reffix_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                function ends(text, tail) { return length(text) >= length(tail) && substr(text, length(text) - length(tail) + 1) == tail }
                function less(text, tail) { return substr(text, 1, length(text) - length(tail)) }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = asked("abits") == 6 && asked("adcbits") == 8 && asked("thermal8") == 0.25 &&
                               asked("photons8") == 30 && asked("prog") == 1 && asked("xtalk") == 0.02 &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        probe = 0; fix = "ideal"; dim = 0
                        if (ends(base, ", to the dimmest")) { dim = 1; base = less(base, ", to the dimmest") }
                        if (ends(base, ", on the weights at 8 bits")) { fix = "weights8"; base = less(base, ", on the weights at 8 bits") }
                        else if (ends(base, ", on the weights")) { fix = "weights"; base = less(base, ", on the weights") }
                        else if (ends(base, ", on the inputs")) { fix = "inputs"; base = less(base, ", on the inputs") }
                        else if (ends(base, ", read")) { probe = 16; base = less(base, ", read") }
                        fixed = (fix != "ideal") ? 1 : 0
                        if (fixed) probe = 16
                        budget = (base == "as budgeted") ? 1 : 0
                        is_held = (base == "held, as written, 0.1 h") ? 1 : 0
                        level = (base == "lit, lines level") ? 1 : 0
                        uneven = (base ~ /^lit, lines to [0-9.]+$/) ? 1 : 0
                        flat = uneven ? substr(base, 15) + 0 : 0.05 * is_held
                        lit = level + uneven + is_held
                        sane = sane && drawn && (budget + lit == 1) && !((budget || level) && probe) && !(dim && !fixed) &&
                               (!uneven || flat > 0) && m == 5 + is_held &&
                               (is_held == (("drift" in on) ? 1 : 0)) && (is_held == has("drift")) && !has("seed") &&
                               (!is_held || want["drift"] == "tflt") && has("hours") == is_held && asked("hours") == 0.1 * is_held &&
                               !has("calibrate") && !has("post-hours") && !has("trimmax") && !has("trimstep") && !has("wbits") &&
                               has("src") == lit && asked("src") == 0.01 * lit && has("srcline") == lit && asked("srcline") == 0.05 * lit &&
                               has("srcflat") == (flat > 0) && asked("srcflat") == flat && has("buses") == lit && asked("buses") == nb * lit &&
                               !has("srcsign") && has("levelprobe") == (probe > 0) && asked("levelprobe") == probe &&
                               has("levelfix") == fixed && (!fixed || want["levelfix"] == fix) &&
                               has("levelref") == dim && (!dim || want["levelref"] == "dimmest") }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               v["wbits"] == ((fix == "weights8") ? 8 : 6) &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == (is_held ? "tflt" : "none") && v["hours"] == 0.1 * is_held && (v["steps"] > 0) == is_held &&
                               v["cal"] == 0 && v["post_hours"] == 0 && near(v["trimstep"], 0.25, 1e-12) &&
                               v["trimmax"] == 128 && !("hidshift" in v) && !("thermalline" in v)
                          if (lit) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] + 0 == flat &&
                                        v["srcsign"] == "pair" && v["buses"] == nb
                          else ok = ok && !("src" in v)
                          if (probe) ok = ok && v["levelprobe"] == probe && ("level_left" in v) && near(v["level_found"] / flat, 1, 0.4)
                          else ok = ok && !("levelprobe" in v) && !("level_found" in v) && !("level_left" in v)
                          if (fixed) ok = ok && v["levelfix"] == fix && v["levelref"] == (dim ? "dimmest" : "none") && ("level_clip" in v) &&
                                          (dim ? (v["level_gain"] > 0 && v["level_gain"] < 1 && v["level_clip"] == 0) : v["level_gain"] == 1)
                          else ok = ok && !("levelfix" in v) && !("levelref" in v) && !("level_gain" in v) && !("level_clip" in v) }
                END { exit !(NR == 2 && ok) }' || reffix_ok=NO
            reffix_runs=$((reffix_runs + 1))
        done < "$work/out/reffix_settings.txt"
    done; done
    echo "== reffix: $reffix_runs runs, each of them the network and the row its place says: $reffix_ok"
    [ "$reffix_ok" = yes ] || exit 1

    # reffix_partner NAME: the row a row is read over, which meets its noise:
    # the level row of its draw for a lit row, corrected or not, and the
    # as-budgeted row of its draw for the level row and for the held rows.
    # The as-budgeted row of a draw is read over the first draw's
    reffix_partner() {
        local base=${1%, draw *} dd=${1##*, draw }
        case "$base" in
        "as budgeted") echo "as budgeted, draw ${draws%% *}" ;;
        "lit, lines level") echo "as budgeted, draw $dd" ;;
        "lit, "*) echo "lit, lines level, draw $dd" ;;
        *) echo "as budgeted, draw $dd" ;;
        esac
    }
    # reffix_alone BASE: the row a read or a corrected row was read from
    reffix_alone() {
        local base=$1
        base=${base%, read}
        base=${base%, to the dimmest}
        base=${base%, on the weights at 8 bits}
        base=${base%, on the weights}
        base=${base%, on the inputs}
        echo "$base"
    }
    # reffix_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    reffix_stat() {
        local sd partner
        partner=$(reffix_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(reffix_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(reffix_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # reffix_over KIND BASE: a row over all its draws.  How often right, and
    # what it adds over its partner: the mean; its standard error, from the
    # five networks, each averaged over its draws; and the standard deviation
    # from draw to draw of the five networks' mean
    reffix_over() {
        local sd dd name
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                name="$2, draw $dd"
                sed "s/^/A $sd $dd /" "$(reffix_file $sd "$1" "$(reffix_partner "$name")")"
                sed "s/^/B $sd $dd /" "$(reffix_file $sd "$1" "$name")"
            done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0
              if ($1 == "A") { a = x; next }
              g = a - x
              rn[$2] += x; gn[$2] += g; cn[$2]++; rd[$3] += x; gd[$3] += g; cd[$3]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; g = gn[k] / cn[k]; rs += x; rss += x * x; gs += g; gss += g * g; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; g = gd[k] / cd[k]; ds += x; dss += x * x; hs += g; hss += g * g; nd++ }
                  printf " %8.3f +-%5.3f %6.3f %7.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd),
                         gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd) }'
    }
    # reffix_buys KIND BASE: a read or a corrected row over all its draws,
    # against the row it was read from.  What it buys, which is the row less
    # the other, network by network: the mean, its standard error from the
    # five networks each averaged over its draws, and the standard deviation
    # from draw to draw of the five networks' mean.  And a mean over the runs:
    # what was left on the lines, percent rms; what the scaling took off the
    # sums, which is 1 where it took nothing; and the share of what it scaled
    # that a rail held back, percent
    reffix_buys() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(reffix_file $sd "$1" "$(reffix_alone "$2"), draw $dd")"
                sed "s/^/B $sd $dd /" "$(reffix_file $sd "$1" "$2, draw $dd")"
            done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0
              if ($1 == "A") { a = x; next }
              g = x - a
              gn[$2] += g; cn[$2]++; gd[$3] += g; cd[$3]++; ls += v["level_left"]
              ts += ("level_gain" in v) ? v["level_gain"] : 1; cs += ("level_clip" in v) ? v["level_clip"] : 0; runs++ }
            END { for (k in cn) { g = gn[k] / cn[k]; gs += g; gss += g * g; nn++ }
                  for (k in cd) { g = gd[k] / cd[k]; hs += g; hss += g * g; nd++ }
                  printf " %7.3f +-%5.3f %6.3f %5.2f %6.4f %6.2f", gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd),
                         100 * ls / runs, ts / runs, 100 * cs / runs }'
    }
    echo "== reffix: the $tile tile on $buses buses at v2, five networks, mean and standard error.  How"
    echo "== often right, percent, and what a row adds over the row it is read over, network by"
    echo "== network: a lit row over the level row of its draw, the level row and the held rows"
    echo "== over the as-budgeted row of their draw, and that over the first draw's"
    printf '%-70s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-70s' "$name"
        for k in before reference; do reffix_stat $k "$name"; done
        echo
    done < "$work/out/reffix_settings.txt"
    echo "== reffix: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-62s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/reffix_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-62s' "$base"
        for k in before reference; do reffix_over $k "$base"; done
        echo
    done
    echo "== reffix: what a read or a correction buys: the row less the row it was read from, network"
    echo "== by network, over its draws, with its standard error and its standard deviation from draw"
    echo "== to draw; what was left on the lines, percent rms; what the scaling took off the sums;"
    echo "== and the share of what it scaled that a rail held back, percent"
    printf '%-62s %24s %20s %24s %20s' "" "before: buys" "left, off, held" "reference: buys" "left, off, held"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/reffix_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        [ "$(reffix_alone "$base")" != "$base" ] || continue
        printf '%-62s' "$base"
        for k in before reference; do reffix_buys $k "$base"; done
        echo
    done
fi

# `refpoint`: the working point as the chip is now held.  grxcp moved its
# source's third row on 2026-10-09: a comb's lines level to 20% as they reach
# the tile, where it was 5%, read at each calibration and corrected on the
# weights a row at a time, written at 8 bits.  Every row a mode here calls
# held was run with lines 5% off and left alone, and a cycle was run with a
# source lit on one draw alone, `refcycle`'s, and read as what the tile costs
# and not over the probes-only row of its draw.  This runs ten rows on each
# of five draws: the tile as budgeted; held as it was, six minutes of drift
# from weights as written and the source at 1%, 5% and 5%; held with lines
# 20% off and left alone; held as it now is, the same read and corrected; a
# calibration's probes taken and nothing written; a six-minute cycle with no
# source, as `refdraws` ran it; a cycle with the source as it was, which on
# the first draw is `refcycle`'s held cycle; a cycle as it is now run; and
# the first and the last of those three cycles again with the trim at 8
# bits.  A trim's step is `--trimstep`, in LSB of the operand, which is an
# 8-bit weight's.  Every cycle a mode here ran before was at a quarter of
# one, a sixteenth of a 6-bit code.  The 8-bit DAC that grxcp's calibration
# note puts behind a 6-bit code holds steps of one, and at one the corrected
# weights and the trim are on the same 8 bits.  The level probe runs when the
# evaluation starts, which in a cycle is six minutes after the calibration,
# and reads through the drift of those six minutes.  A held row is read over
# the as-budgeted row of its draw and a cycle over the probes-only row of its
# draw: each pair meets the same noise, and no correction takes a seed of the
# run's.  Both kinds of network, row for row.
if [ "$what" = refpoint ]; then
    tile=${REFPOINT_TILE:-128x64}
    buses=${REFPOINT_BUSES:-2}
    draws=${REFPOINT_DRAWS:-0 1 2 3 4}
    level=${REFPOINT_LEVEL:-0.2}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    b="--impair $all $r"
    d="--impair $all,drift $r --drift tflt"
    n="--src 0.01 --srcline 0.05 --buses $buses"
    src="--src 0.01 --srcline 0.05 --srcflat 0.05 --buses $buses"
    fix="--levelprobe 16 --levelfix weights8"
    cyc="--hours 0.1 --calibrate 16 --post-hours 0.1"
    # row|options.  Every row's name ends in its draw.
    for dd in $draws; do
        echo "as budgeted, draw $dd|$b"
        echo "held, as written, 0.1 h, draw $dd|$d --hours 0.1 $src"
        echo "held, as written, 0.1 h, lines to $level, draw $dd|$d --hours 0.1 $n --srcflat $level"
        echo "held, as written, 0.1 h, lines to $level, on the weights at 8 bits, draw $dd|$d --hours 0.1 $n --srcflat $level $fix"
        echo "probes only, draw $dd|$b --calibrate 16 --trimmax 0"
        echo "cycle of 0.1 h, draw $dd|$d $cyc"
        echo "cycle of 0.1 h, lit, draw $dd|$d $cyc $src"
        echo "cycle of 0.1 h, lit, lines to $level, on the weights at 8 bits, draw $dd|$d $cyc $n --srcflat $level $fix"
        echo "cycle of 0.1 h, trim at 8 bits, draw $dd|$d $cyc --trimstep 1"
        echo "cycle of 0.1 h, lit, lines to $level, on the weights at 8 bits, trim at 8 bits, draw $dd|$d $cyc $n --srcflat $level $fix --trimstep 1"
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refpoint_settings.txt"
    # refpoint_one NET ROW ARGS...: one test-set pass, its line to
    # out/refpoint.d/NET_ROW.txt
    refpoint_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refpoint.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refpoint.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refpoint_one
    # refpoint_row NAME: a row's name as a file's
    refpoint_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refpoint_net SEED KIND: the network's file, trained before or the reference
    refpoint_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(refpoint_net $sd $k) $(refpoint_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/refpoint_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refpoint_one "$@"' _

    # refpoint_file SEED KIND NAME: the file refpoint_one wrote for that run
    refpoint_file() { echo "$work/out/refpoint.d/$(basename "$(refpoint_net "$1" "$2")" .net)_$(refpoint_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; its seed is its draw's; and its
    # name says whether it is held or cycled, whether a source is lit and how
    # far from level its lines are, and whether they were read and corrected on
    # the weights at 8 bits, which have to be what it was asked and what its
    # line printed.  A held row has drifted and was not calibrated; a cycle was
    # aged, calibrated with its trims written, and aged again; the probes-only
    # row took its probes and wrote nothing.  A corrected row has to have run
    # the tile at 8-bit weights and taken nothing off its sums, and no other
    # row may have been read at all.  A cycle whose name says its trim is at 8
    # bits was asked a step of one and printed it, and every other row was
    # asked none and printed a quarter.
    refpoint_ok=yes
    refpoint_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refpoint_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refpoint_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(refpoint_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" -v lv="$level" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                function ends(text, tail) { return length(text) >= length(tail) && substr(text, length(text) - length(tail) + 1) == tail }
                function less(text, tail) { return substr(text, 1, length(text) - length(tail)) }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = asked("abits") == 6 && asked("adcbits") == 8 && asked("thermal8") == 0.25 &&
                               asked("photons8") == 30 && asked("prog") == 1 && asked("xtalk") == 0.02 &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        fixed = 0; uneven = 0; shone = 0; coarse = 0
                        if (ends(base, ", trim at 8 bits")) { coarse = 1; base = less(base, ", trim at 8 bits") }
                        if (ends(base, ", on the weights at 8 bits")) { fixed = 1; base = less(base, ", on the weights at 8 bits") }
                        if (ends(base, ", lines to " lv)) { uneven = 1; base = less(base, ", lines to " lv) }
                        if (ends(base, ", lit")) { shone = 1; base = less(base, ", lit") }
                        budget = (base == "as budgeted") ? 1 : 0
                        only = (base == "probes only") ? 1 : 0
                        is_held = (base == "held, as written, 0.1 h") ? 1 : 0
                        cyc = (base == "cycle of 0.1 h") ? 1 : 0
                        lit = (is_held || (cyc && shone)) ? 1 : 0
                        flat = lit ? (uneven ? lv + 0 : 0.05) : 0
                        drifts = (is_held || cyc) ? 1 : 0
                        cal = (cyc || only) ? 16 : 0
                        sane = sane && drawn && (budget + only + is_held + cyc == 1) && !(shone && !cyc) && !(uneven && !lit) &&
                               !(fixed && !uneven) && !(coarse && !cyc) && lv + 0 > 0.05 && m == 5 + drifts &&
                               (drifts == (("drift" in on) ? 1 : 0)) && (drifts == has("drift")) && !has("seed") &&
                               (!drifts || want["drift"] == "tflt") && has("hours") == drifts && asked("hours") == 0.1 * drifts &&
                               has("calibrate") == (cal > 0) && asked("calibrate") == cal &&
                               has("post-hours") == cyc && asked("post-hours") == 0.1 * cyc &&
                               has("trimmax") == only && asked("trimmax") == 0 && !has("wbits") &&
                               has("trimstep") == coarse && asked("trimstep") == coarse &&
                               has("src") == lit && asked("src") == 0.01 * lit && has("srcline") == lit && asked("srcline") == 0.05 * lit &&
                               has("srcflat") == lit && asked("srcflat") == flat && has("buses") == lit && asked("buses") == nb * lit &&
                               !has("srcsign") && has("levelprobe") == fixed && asked("levelprobe") == 16 * fixed &&
                               has("levelfix") == fixed && (!fixed || want["levelfix"] == "weights8") && !has("levelref") }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               v["wbits"] == (fixed ? 8 : 6) &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == (drifts ? "tflt" : "none") && v["hours"] == 0.1 * drifts && (v["steps"] > 0) == drifts &&
                               v["cal"] == cal && v["post_hours"] == 0.1 * cyc && near(v["trimstep"], coarse ? 1 : 0.25, 1e-12) &&
                               v["trimmax"] == (only ? 0 : 128) && !("hidshift" in v) && !("thermalline" in v)
                          if (lit) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] + 0 == flat &&
                                        v["srcsign"] == "pair" && v["buses"] == nb
                          else ok = ok && !("src" in v)
                          if (fixed) ok = ok && v["levelprobe"] == 16 && ("level_left" in v) && near(v["level_found"] / flat, 1, 0.4) &&
                                          v["levelfix"] == "weights8" && v["levelref"] == "none" && v["level_gain"] == 1 && ("level_clip" in v)
                          else ok = ok && !("levelprobe" in v) && !("level_found" in v) && !("level_left" in v) &&
                                    !("levelfix" in v) && !("levelref" in v) && !("level_gain" in v) && !("level_clip" in v) }
                END { exit !(NR == 2 && ok) }' || refpoint_ok=NO
            refpoint_runs=$((refpoint_runs + 1))
        done < "$work/out/refpoint_settings.txt"
    done; done
    echo "== refpoint: $refpoint_runs runs, each of them the network and the row its place says: $refpoint_ok"
    [ "$refpoint_ok" = yes ] || exit 1

    # refpoint_partner NAME: the row a row is read over, which meets its
    # noise: the as-budgeted row of its draw for a held row and for the
    # probes-only one, and the probes-only row of its draw for a cycle.  The
    # as-budgeted row of a draw is read over the first draw's
    refpoint_partner() {
        local base=${1%, draw *} dd=${1##*, draw }
        case "$base" in
        "as budgeted") echo "as budgeted, draw ${draws%% *}" ;;
        "cycle of "*) echo "probes only, draw $dd" ;;
        *) echo "as budgeted, draw $dd" ;;
        esac
    }
    # refpoint_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    refpoint_stat() {
        local sd partner
        partner=$(refpoint_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refpoint_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(refpoint_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refpoint_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    refpoint_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(refpoint_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(refpoint_file $sd "$1" "$2, draw $dd")"
            done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0
              if ($1 == "A") { a = x; next }
              g = a - x
              gn[$2] += g; cn[$2]++; gd[$3] += g; cd[$3]++ }
            END { for (k in cn) { g = gn[k] / cn[k]; gs += g; gss += g * g; nn++ }
                  for (k in cd) { g = gd[k] / cd[k]; hs += g; hss += g * g; nd++ }
                  printf " %7.3f +-%5.3f %6.3f", gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd) }'
    }
    # refpoint_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    refpoint_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(refpoint_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd) }'
        # the row it is read over is its partner on its own draw, but for the
        # as-budgeted row, whose partner is one row for all of them
        if [ "$2" = "as budgeted" ]; then
            local first=${draws%% *} sd2 dd2
            for sd2 in 1 2 3 4 5; do
                for dd2 in $draws; do
                    sed "s/^/A $sd2 $dd2 /" "$(refpoint_file $sd2 "$1" "as budgeted, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(refpoint_file $sd2 "$1" "as budgeted, draw $dd2")"
                done
            done | awk '
                function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
                { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
                  x = v["acc"] + 0
                  if ($1 == "A") { a = x; next }
                  g = a - x; gn[$2] += g; cn[$2]++; gd[$3] += g; cd[$3]++ }
                END { for (k in cn) { g = gn[k] / cn[k]; gs += g; gss += g * g; nn++ }
                      for (k in cd) { g = gd[k] / cd[k]; hs += g; hss += g * g; nd++ }
                      printf " %7.3f +-%5.3f %6.3f", gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd) }'
        else
            local p
            p=$(refpoint_partner "$2, draw 0")
            refpoint_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # refpoint_lines KIND BASE: a corrected row over its runs: what the probe
    # found on the lines and what its reading would leave, percent rms, and
    # the share of the weights the rail held back, percent
    refpoint_lines() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(refpoint_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              fs += v["level_found"]; ls += v["level_left"]; cs += v["level_clip"]; runs++ }
            END { printf " %7.2f %6.2f %6.3f", 100 * fs / runs, 100 * ls / runs, 100 * cs / runs }'
    }
    echo "== refpoint: the $tile tile on $buses buses at v2, five networks, mean and standard error.  How"
    echo "== often right, percent, and what a row adds over the row it is read over, network by"
    echo "== network: a held row and the probes-only one over the as-budgeted row of their draw, a"
    echo "== cycle over the probes-only row of its draw, and the as-budgeted row over the first draw's"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do refpoint_stat $k "$name"; done
        echo
    done < "$work/out/refpoint_settings.txt"
    echo "== refpoint: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/refpoint_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do refpoint_over $k "$base"; done
        echo
    done
    echo "== refpoint: one row over another on the same draws: how often right in the second, less"
    echo "== in the first, network by network over the draws, with its standard error and its"
    echo "== standard deviation from draw to draw.  The two of a pair meet the same noise"
    printf '%-92s %24s %24s' "" "before" "reference"
    echo
    h="held, as written, 0.1 h"
    c="cycle of 0.1 h"
    w="on the weights at 8 bits"
    {
        echo "held as it now is, over held as it was|$h, lines to $level, $w|$h"
        echo "held with the lines left alone, over held as it was|$h, lines to $level|$h"
        echo "held as it now is, over held with the lines left alone|$h, lines to $level, $w|$h, lines to $level"
        echo "a cycle with the source as it was, over a cycle with none|$c, lit|$c"
        echo "a cycle as it is now run, over a cycle with no source|$c, lit, lines to $level, $w|$c"
        echo "a cycle as it is now run, over a cycle with the source as it was|$c, lit, lines to $level, $w|$c, lit"
        echo "a cycle with its trim at 8 bits, over a cycle|$c, trim at 8 bits|$c"
        echo "a cycle as it is now run, its trim at 8 bits, over one as it is now run|$c, lit, lines to $level, $w, trim at 8 bits|$c, lit, lines to $level, $w"
        echo "a cycle as it is now run, its trim at 8 bits, over a cycle with its trim at 8 bits|$c, lit, lines to $level, $w, trim at 8 bits|$c, trim at 8 bits"
    } | while IFS='|' read -r what one other; do
        printf '%-92s' "$what"
        for k in before reference; do refpoint_pair $k "$one" "$other"; done
        echo
    done
    echo "== refpoint: the rows that are read and corrected: what the probe found on the lines and"
    echo "== what its reading would leave, percent rms, and the share of the weights held at the rail,"
    echo "== percent: a mean over the runs"
    printf '%-84s %22s %22s' "" "before" "reference"
    echo
    for base in "$h, lines to $level, $w" "$c, lit, lines to $level, $w" "$c, lit, lines to $level, $w, trim at 8 bits"; do
        printf '%-84s' "$base"
        for k in before reference; do refpoint_lines $k "$base"; done
        echo
    done
fi

# `refhold`: B15's cycle on the DAC as it is specified, with the source lit.
# grxcp kept the weight DAC at 8 bits on 2026-10-09, which `refpoint` had found
# every cycle here to have been run two bits finer than; and its six minutes
# were kept on a cycle with no source.  This runs the cycle as the chip is now
# held, on ten draws, which are `refdraws`'s: the tile as budgeted; a
# calibration's probes taken and nothing written; and at each interval, three
# minutes and six, a cycle with no source and a cycle with the source lit,
# its lines 20% off, read and corrected on the weights at 8 bits.  Every cycle
# has its trim at 8 bits, `--trimstep 1`.  A cycle is read over the
# probes-only row of its draw, which meets its noise.  Both kinds of network,
# row for row.
if [ "$what" = refhold ]; then
    tile=${REFHOLD_TILE:-128x64}
    buses=${REFHOLD_BUSES:-2}
    draws=${REFHOLD_DRAWS:-0 1 2 3 4 5 6 7 8 9}
    cycles=${REFHOLD_CYCLES:-0.05 0.1}
    level=${REFHOLD_LEVEL:-0.2}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    b="--impair $all $r"
    d="--impair $all,drift $r --drift tflt"
    n="--src 0.01 --srcline 0.05 --buses $buses"
    fix="--levelprobe 16 --levelfix weights8"
    # row|options.  Every row's name ends in its draw.
    for dd in $draws; do
        echo "as budgeted, draw $dd|$b"
        echo "probes only, draw $dd|$b --calibrate 16 --trimmax 0"
        for h in $cycles; do
            c="--hours $h --calibrate 16 --post-hours $h"
            echo "cycle of $h h, trim at 8 bits, draw $dd|$d $c --trimstep 1"
            echo "cycle of $h h, lit, lines to $level, on the weights at 8 bits, trim at 8 bits, draw $dd|$d $c $n --srcflat $level $fix --trimstep 1"
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refhold_settings.txt"
    # refhold_one NET ROW ARGS...: one test-set pass, its line to
    # out/refhold.d/NET_ROW.txt
    refhold_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refhold.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refhold.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refhold_one
    # refhold_row NAME: a row's name as a file's
    refhold_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refhold_net SEED KIND: the network's file, trained before or the reference
    refhold_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(refhold_net $sd $k) $(refhold_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/refhold_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refhold_one "$@"' _

    # refhold_file SEED KIND NAME: the file refhold_one wrote for that run
    refhold_file() { echo "$work/out/refhold.d/$(basename "$(refhold_net "$1" "$2")" .net)_$(refhold_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; its seed is its draw's; and its
    # name says whether it is a cycle and of what interval, and whether a
    # source is lit, which have to be what it was asked and what its line
    # printed.  A cycle was aged its interval, calibrated with its trims
    # written, and aged its interval again, and its interval is one of those
    # asked for; the probes-only row took its probes and wrote nothing.  Every
    # cycle has its trim at 8 bits: it was asked a step of one and printed it,
    # and the other two rows were asked none and printed a quarter.  A cycle
    # with a source lit has its lines as far from level as the mode was asked,
    # was read with sixteen shots a row and corrected on the weights at 8
    # bits, ran the tile at 8-bit weights and took nothing off its sums; and
    # no other row is lit, or was read at all.
    refhold_ok=yes
    refhold_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refhold_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refhold_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(refhold_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" -v lv="$level" -v cycles="$cycles" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                function ends(text, tail) { return length(text) >= length(tail) && substr(text, length(text) - length(tail) + 1) == tail }
                function less(text, tail) { return substr(text, 1, length(text) - length(tail)) }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        sane = asked("abits") == 6 && asked("adcbits") == 8 && asked("thermal8") == 0.25 &&
                               asked("photons8") == 30 && asked("prog") == 1 && asked("xtalk") == 0.02 &&
                               ("quant" in on) && ("thermal" in on) && ("shot" in on) && ("prog" in on) && ("xtalk" in on)
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        fixed = 0; uneven = 0; shone = 0; coarse = 0
                        if (ends(base, ", trim at 8 bits")) { coarse = 1; base = less(base, ", trim at 8 bits") }
                        if (ends(base, ", on the weights at 8 bits")) { fixed = 1; base = less(base, ", on the weights at 8 bits") }
                        if (ends(base, ", lines to " lv)) { uneven = 1; base = less(base, ", lines to " lv) }
                        if (ends(base, ", lit")) { shone = 1; base = less(base, ", lit") }
                        budget = (base == "as budgeted") ? 1 : 0
                        only = (base == "probes only") ? 1 : 0
                        cyc = (base ~ /^cycle of [0-9.]+ h$/) ? 1 : 0
                        h = cyc ? substr(base, 10, length(base) - 11) + 0 : 0
                        known = 0; nc = split(cycles, cy, " ")
                        for (i = 1; i <= nc; ++i) if (cyc && h > 0 && cy[i] + 0 == h) known = 1
                        lit = (cyc && shone) ? 1 : 0
                        flat = lit ? lv + 0 : 0
                        drifts = cyc
                        cal = (cyc || only) ? 16 : 0
                        sane = sane && drawn && (budget + only + cyc == 1) && cyc == known && coarse == cyc && shone == lit &&
                               uneven == lit && fixed == lit && lv + 0 > 0.05 && m == 5 + drifts &&
                               (drifts == (("drift" in on) ? 1 : 0)) && (drifts == has("drift")) && !has("seed") &&
                               (!drifts || want["drift"] == "tflt") && has("hours") == drifts && asked("hours") == h * drifts &&
                               has("calibrate") == (cal > 0) && asked("calibrate") == cal &&
                               has("post-hours") == cyc && asked("post-hours") == h * cyc &&
                               has("trimmax") == only && asked("trimmax") == 0 && !has("wbits") &&
                               has("trimstep") == coarse && asked("trimstep") == coarse &&
                               has("src") == lit && asked("src") == 0.01 * lit && has("srcline") == lit && asked("srcline") == 0.05 * lit &&
                               has("srcflat") == lit && asked("srcflat") == flat && has("buses") == lit && asked("buses") == nb * lit &&
                               !has("srcsign") && has("levelprobe") == fixed && asked("levelprobe") == 16 * fixed &&
                               has("levelfix") == fixed && (!fixed || want["levelfix"] == "weights8") && !has("levelref") }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { ok = sane && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               v["wbits"] == (fixed ? 8 : 6) &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == (drifts ? "tflt" : "none") && v["hours"] == h * drifts && (v["steps"] > 0) == drifts &&
                               v["cal"] == cal && v["post_hours"] == h * cyc && near(v["trimstep"], coarse ? 1 : 0.25, 1e-12) &&
                               v["trimmax"] == (only ? 0 : 128) && !("hidshift" in v) && !("thermalline" in v)
                          if (lit) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] + 0 == flat &&
                                        v["srcsign"] == "pair" && v["buses"] == nb
                          else ok = ok && !("src" in v)
                          if (fixed) ok = ok && v["levelprobe"] == 16 && ("level_left" in v) && near(v["level_found"] / flat, 1, 0.4) &&
                                          v["levelfix"] == "weights8" && v["levelref"] == "none" && v["level_gain"] == 1 && ("level_clip" in v)
                          else ok = ok && !("levelprobe" in v) && !("level_found" in v) && !("level_left" in v) &&
                                    !("levelfix" in v) && !("levelref" in v) && !("level_gain" in v) && !("level_clip" in v) }
                END { exit !(NR == 2 && ok) }' || refhold_ok=NO
            refhold_runs=$((refhold_runs + 1))
        done < "$work/out/refhold_settings.txt"
    done; done
    echo "== refhold: $refhold_runs runs, each of them the network and the row its place says: $refhold_ok"
    [ "$refhold_ok" = yes ] || exit 1

    # refhold_partner NAME: the row a row is read over, which meets its
    # noise: the as-budgeted row of its draw for the probes-only one, and the
    # probes-only row of its draw for a cycle.  The as-budgeted row of a draw
    # is read over the first draw's
    refhold_partner() {
        local base=${1%, draw *} dd=${1##*, draw }
        case "$base" in
        "as budgeted") echo "as budgeted, draw ${draws%% *}" ;;
        "cycle of "*) echo "probes only, draw $dd" ;;
        *) echo "as budgeted, draw $dd" ;;
        esac
    }
    # refhold_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    refhold_stat() {
        local sd partner
        partner=$(refhold_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refhold_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(refhold_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refhold_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    refhold_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(refhold_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(refhold_file $sd "$1" "$2, draw $dd")"
            done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0
              if ($1 == "A") { a = x; next }
              g = a - x
              gn[$2] += g; cn[$2]++; gd[$3] += g; cd[$3]++ }
            END { for (k in cn) { g = gn[k] / cn[k]; gs += g; gss += g * g; nn++ }
                  for (k in cd) { g = gd[k] / cd[k]; hs += g; hss += g * g; nd++ }
                  printf " %7.3f +-%5.3f %6.3f", gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd) }'
    }
    # refhold_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    refhold_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(refhold_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd) }'
        # the row it is read over is its partner on its own draw, but for the
        # as-budgeted row, whose partner is one row for all of them
        if [ "$2" = "as budgeted" ]; then
            local first=${draws%% *} sd2 dd2
            for sd2 in 1 2 3 4 5; do
                for dd2 in $draws; do
                    sed "s/^/A $sd2 $dd2 /" "$(refhold_file $sd2 "$1" "as budgeted, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(refhold_file $sd2 "$1" "as budgeted, draw $dd2")"
                done
            done | awk '
                function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
                { delete v; for (i = 4; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
                  x = v["acc"] + 0
                  if ($1 == "A") { a = x; next }
                  g = a - x; gn[$2] += g; cn[$2]++; gd[$3] += g; cd[$3]++ }
                END { for (k in cn) { g = gn[k] / cn[k]; gs += g; gss += g * g; nn++ }
                      for (k in cd) { g = gd[k] / cd[k]; hs += g; hss += g * g; nd++ }
                      printf " %7.3f +-%5.3f %6.3f", gs / nn, dev(gs, gss, nn) / sqrt(nn), dev(hs, hss, nd) }'
        else
            local p
            p=$(refhold_partner "$2, draw 0")
            refhold_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # refhold_lines KIND BASE: a corrected row over its runs: what the probe
    # found on the lines and what its reading would leave, percent rms, and
    # the share of the weights the rail held back, percent
    refhold_lines() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(refhold_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              fs += v["level_found"]; ls += v["level_left"]; cs += v["level_clip"]; runs++ }
            END { printf " %7.2f %6.2f %6.3f", 100 * fs / runs, 100 * ls / runs, 100 * cs / runs }'
    }
    echo "== refhold: the $tile tile on $buses buses at v2, five networks, mean and standard error.  How"
    echo "== often right, percent, and what a row adds over the row it is read over, network by"
    echo "== network: the probes-only row over the as-budgeted row of its draw, a cycle over the"
    echo "== probes-only row of its draw, and the as-budgeted row over the first draw's"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do refhold_stat $k "$name"; done
        echo
    done < "$work/out/refhold_settings.txt"
    echo "== refhold: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/refhold_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do refhold_over $k "$base"; done
        echo
    done
    echo "== refhold: one row over another on the same draws: how often right in the second, less"
    echo "== in the first, network by network over the draws, with its standard error and its"
    echo "== standard deviation from draw to draw.  The two of a pair meet the same noise"
    printf '%-92s %24s %24s' "" "before" "reference"
    echo
    w="on the weights at 8 bits"
    t="trim at 8 bits"
    short=${cycles%% *}
    long=${cycles##* }
    {
        for h in $cycles; do
            echo "a cycle of $h h with the source lit, over one with none|cycle of $h h, lit, lines to $level, $w, $t|cycle of $h h, $t"
        done
        if [ "$short" != "$long" ]; then
            echo "with no source, a cycle of $long h over one of $short h|cycle of $long h, $t|cycle of $short h, $t"
            echo "with the source lit, a cycle of $long h over one of $short h|cycle of $long h, lit, lines to $level, $w, $t|cycle of $short h, lit, lines to $level, $w, $t"
        fi
    } | while IFS='|' read -r label one other; do
        printf '%-92s' "$label"
        for k in before reference; do refhold_pair $k "$one" "$other"; done
        echo
    done
    echo "== refhold: the rows that are read and corrected: what the probe found on the lines and"
    echo "== what its reading would leave, percent rms, and the share of the weights held at the rail,"
    echo "== percent: a mean over the runs"
    printf '%-84s %22s %22s' "" "before" "reference"
    echo
    for h in $cycles; do
        base="cycle of $h h, lit, lines to $level, $w, $t"
        printf '%-84s' "$base"
        for k in before reference; do refhold_lines $k "$base"; done
        echo
    done
fi

exit $((gate_status | ablate_status))
