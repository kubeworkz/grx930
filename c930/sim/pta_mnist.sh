#!/usr/bin/env bash
# pta_mnist.sh - gate C1(a), the accuracy sweep on the D3 network
# (doc/pta_error_model_design_note.md section 5).  Runs on Linux or WSL.
#
#   sim/pta_mnist.sh MNIST_DIR WORK_DIR [gate|ablate|sweep|joint|calib|budget|depth|geometry|source|laser|fill|tighten|v2|trained|refsource|reflaser|refdrift|refcycle|refcal|refdraws|reflevel|reffix|refpoint|refhold|refrows|refcomb|chain|chainfit|chainbit|chainlit|chainrows|chaingain|canary|golden|band|all]
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
# comb's lines are (default 0.2).  `refrows` is the eleventh: REFROWS_TILE and
# REFROWS_BUSES set its tile and its buses (default 128x64 and 2),
# REFROWS_DRAWS the draws it runs (default "0 1 2 3 4"), REFROWS_LEVEL how far
# from level a comb's lines are (default 0.2), and REFROWS_ROWS the source's
# noise in each lit row, as TOGETHER:LINE, the first of them the chip as it is
# held (default "0.01:0.05 0.01:0.02 0.01:0.01 0.01:0 0:0.05 0:0 0.02:0.05").
# `refcomb` is the twelfth: REFCOMB_TILE and REFCOMB_BUSES set its tile and its
# buses (default 128x64 and 2), REFCOMB_DRAWS the draws it runs (default
# "0 1 2 3 4"), REFCOMB_LEVEL how far from level a comb's lines are (default
# 0.2), and REFCOMB_PARTS what each row told apart takes of what the
# correction leaves, as LIST or LIST:LAYER, the first of them none (default
# "none read,round,rail read round:1 round:2 rail:1 rail:2").
#
# SHAPE=chain builds the harness for another network and gives a new WORK_DIR
# that network's images: grxgpu's first-board classifier, 8 x 8 images, two
# hidden layers 64 wide and 16 outputs, with MNIST_DIR's images pooled to
# 8 x 8.  Such a directory runs `chain`, `chainfit`, `chainbit`, `chainlit`,
# `chainrows`, `chaingain`, `canary`, `golden` and `band` and nothing else, and
# they run in no other.
# CHAIN_TILE sets `chain`'s tile (default 128x64) and CHAIN_DRAWS the draws it
# runs (default "0 1 2 3 4");
# CHAINFIT_TILE and CHAINFIT_DRAWS are `chainfit`'s, which is the same network
# with its last layer's range fitted to the reference a board holds it to;
# CHAINBIT_TILE and CHAINBIT_DRAWS are `chainbit`'s, which gives that layer's
# converter a bit more; CHAINLIT_TILE and CHAINLIT_DRAWS are `chainlit`'s,
# which lights the source over it; CHAINROWS_TILE and CHAINROWS_DRAWS are
# `chainrows`'s, which runs the tile's budget a row at a time; and
# CHAINGAIN_TILE and CHAINGAIN_DRAWS are `chaingain`'s, which gives that
# layer's outputs one scale, fixed on images the network was not trained on.
# `canary` trains the first board's canary as grxcp's B20 fixed it, its first
# two layers the host's at eight bits and its last trained for the tile, and
# runs its five networks as `chaingain` runs the reference ones; CANARY_TILE
# and CANARY_DRAWS are its.  `golden` writes the canary's golden tensors
# twice, from the network `canary` trained, into out/golden.a and out/golden.b,
# and holds the two to each other byte for byte.  `band` runs the canary and
# the four networks of its recipe with the last layer held to its converter's
# codes, the reference the owner ruled, and one scale fixed on the calibration
# set: the format alone, version 2's budget dark and lit, and lit at 0.4 to 1.4
# times every row of the budget.  BAND_DRAWS sets the canary's draws a row
# (default 1000) and BAND_OTHER the other four's, of the budget's two rows
# (default 100).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 2 ] || { sed -n '2,114p' "$0"; exit 2; }
mnist=$1
work=$2
what=${3:-all}
jobs=${JOBS:-4}
export PTA_WORK=$work

# the network's shape: D3's, or the first board's classifier.  A build of the
# second runs the self-test's tests that are of any shape, and says so
shape=${SHAPE:-d3}
case "$shape" in
d3) defs= ;;
chain) defs="-DN_SIDE=8 -DN_HID=64 -DN_OUT=16" ;;
*) echo "SHAPE is d3 or chain" >&2; exit 2 ;;
esac
if [ "$shape" = chain ] && [ "$what" != chain ] && [ "$what" != chainfit ] && [ "$what" != chainbit ] &&
   [ "$what" != chainlit ] && [ "$what" != chainrows ] && [ "$what" != chaingain ] && [ "$what" != canary ] &&
   [ "$what" != golden ] && [ "$what" != band ]; then
    echo "SHAPE=chain runs chain, chainfit, chainbit, chainlit, chainrows, chaingain, canary, golden and band and nothing else" >&2
    exit 2
fi
if { [ "$what" = chain ] || [ "$what" = chainfit ] || [ "$what" = chainbit ] || [ "$what" = chainlit ] ||
     [ "$what" = chainrows ] || [ "$what" = chaingain ] || [ "$what" = canary ] || [ "$what" = golden ] ||
     [ "$what" = band ]; } &&
   [ "$shape" != chain ]; then
    echo "$what needs SHAPE=chain, and a WORK_DIR of its own" >&2; exit 2
fi

mkdir -p "$work/data" "$work/nets" "$work/out"
cflags="-O2 -std=c99 -Wall -Wextra -pedantic -I$here $defs"
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
# and its shape: data/shape says which, and a directory with none holds D3's
if [ -s "$work/data/shape" ] || [ -s "$work/data/train-images-idx3-ubyte" ]; then
    had=d3
    [ ! -s "$work/data/shape" ] || had=$(cat "$work/data/shape")
    [ "$had" = "$shape" ] || {
        echo "$work holds images of shape $had and SHAPE asks for $shape: a work directory is one or the other" >&2
        exit 2; }
fi
echo "$pixels" > "$work/data/pixels"
[ "$shape" = d3 ] || echo "$shape" > "$work/data/shape"
for f in train-images-idx3-ubyte train-labels-idx1-ubyte t10k-images-idx3-ubyte t10k-labels-idx1-ubyte; do
    [ ! -s "$work/data/$f" ] || continue
    gzip -dc "$mnist/$f.gz" > "$work/data/$f.part"
    if [ "$shape" != d3 ] && [ "$f" != "${f%images-idx3-ubyte}" ]; then
        "$work/pta_mnist" pool "$work/data/$f.part" "$work/data/$f.part" > /dev/null
    fi
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

# `refrows`: the source's rows, on the chip as it is held.  At the end of a
# six-minute cycle the source's rows are the larger part of what the chip
# loses on a workload that lights most of its rows, and every figure for one
# of them alone is of a tile that was not calibrated, with its lines 5% off
# and left alone.  This runs the cycle as grxcp now holds the chip, on five
# draws, which are `refpoint`'s: the tile as budgeted; a calibration's probes
# taken and nothing written; a six-minute cycle with no source; and that cycle
# with the source lit, its lines 20% off, read and corrected on the weights at
# 8 bits, once for each pair of noise asked for: for the lines together, and
# for a line on its own.  The first pair is the chip as it is held, 1% and 5%.
# Every cycle has its trim at 8 bits.  A cycle is read over the probes-only
# row of its draw.  Both kinds of network, row for row.
if [ "$what" = refrows ]; then
    tile=${REFROWS_TILE:-128x64}
    buses=${REFROWS_BUSES:-2}
    draws=${REFROWS_DRAWS:-0 1 2 3 4}
    level=${REFROWS_LEVEL:-0.2}
    rows=${REFROWS_ROWS:-0.01:0.05 0.01:0.02 0.01:0.01 0.01:0 0:0.05 0:0 0.02:0.05}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    b="--impair $all $r"
    d="--impair $all,drift $r --drift tflt"
    fix="--levelprobe 16 --levelfix weights8"
    # row|options.  Every row's name ends in its draw.
    c="--hours 0.1 --calibrate 16 --post-hours 0.1"
    for dd in $draws; do
        echo "as budgeted, draw $dd|$b"
        echo "probes only, draw $dd|$b --calibrate 16 --trimmax 0"
        echo "cycle, no source, draw $dd|$d $c --trimstep 1"
        for x in $rows; do
            echo "cycle, together ${x%:*}, a line ${x#*:}, draw $dd|$d $c --src ${x%:*} --srcline ${x#*:} --buses $buses --srcflat $level $fix --trimstep 1"
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refrows_settings.txt"
    # refrows_one NET ROW ARGS...: one test-set pass, its line to
    # out/refrows.d/NET_ROW.txt
    refrows_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refrows.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refrows.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refrows_one
    # refrows_row NAME: a row's name as a file's
    refrows_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refrows_net SEED KIND: the network's file, trained before or the reference
    refrows_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(refrows_net $sd $k) $(refrows_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/refrows_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refrows_one "$@"' _

    # refrows_file SEED KIND NAME: the file refrows_one wrote for that run
    refrows_file() { echo "$work/out/refrows.d/$(basename "$(refrows_net "$1" "$2")" .net)_$(refrows_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; its seed is its draw's; and its
    # name says whether it is a cycle, whether a source is lit, and the
    # source's noise for its lines together and for a line, which have to be
    # what it was asked and what its line printed, and one of the pairs the
    # mode was asked for.  A cycle was aged six minutes, calibrated with its
    # trims written, and aged six minutes again, with its trim at 8 bits: it
    # was asked a step of one and printed it.  The probes-only row took its
    # probes and wrote nothing, and it and the as-budgeted row were asked no
    # step and printed a quarter.  A cycle with a source lit has its lines as
    # far from level as the mode was asked, was read with sixteen shots a row
    # and corrected on the weights at 8 bits, ran the tile at 8-bit weights
    # and took nothing off its sums; and no other row is lit, or was read.
    refrows_ok=yes
    refrows_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refrows_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refrows_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(refrows_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" -v lv="$level" -v rows="$rows" '
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
                        budget = (base == "as budgeted") ? 1 : 0
                        only = (base == "probes only") ? 1 : 0
                        dark = (base == "cycle, no source") ? 1 : 0
                        lit = (base ~ /^cycle, together [0-9.]+, a line [0-9.]+$/) ? 1 : 0
                        together = 0; line = 0; known = 0
                        if (lit) { split(base, part, ", "); together = substr(part[2], 10) + 0; line = substr(part[3], 8) + 0
                                   nr = split(rows, rw, " ")
                                   for (i = 1; i <= nr; ++i) { split(rw[i], xy, ":")
                                                               if (xy[1] + 0 == together && xy[2] + 0 == line) known = 1 } }
                        cyc = (dark || lit) ? 1 : 0
                        h = 0.1 * cyc
                        fixed = lit; coarse = cyc
                        flat = lit ? lv + 0 : 0
                        drifts = cyc
                        cal = (cyc || only) ? 16 : 0
                        sane = sane && drawn && (budget + only + dark + lit == 1) && lit == known && lv + 0 > 0.05 && m == 5 + drifts &&
                               (drifts == (("drift" in on) ? 1 : 0)) && (drifts == has("drift")) && !has("seed") &&
                               (!drifts || want["drift"] == "tflt") && has("hours") == drifts && asked("hours") == h * drifts &&
                               has("calibrate") == (cal > 0) && asked("calibrate") == cal &&
                               has("post-hours") == cyc && asked("post-hours") == h * cyc &&
                               has("trimmax") == only && asked("trimmax") == 0 && !has("wbits") &&
                               has("trimstep") == coarse && asked("trimstep") == coarse &&
                               has("src") == lit && asked("src") == together && has("srcline") == lit && asked("srcline") == line &&
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
                          if (lit) ok = ok && v["src"] + 0 == together && v["srcline"] + 0 == line && v["srcflat"] + 0 == flat &&
                                        v["srcsign"] == "pair" && v["buses"] == nb
                          else ok = ok && !("src" in v)
                          if (fixed) ok = ok && v["levelprobe"] == 16 && ("level_left" in v) && near(v["level_found"] / flat, 1, 0.4) &&
                                          v["levelfix"] == "weights8" && v["levelref"] == "none" && v["level_gain"] == 1 && ("level_clip" in v)
                          else ok = ok && !("levelprobe" in v) && !("level_found" in v) && !("level_left" in v) &&
                                    !("levelfix" in v) && !("levelref" in v) && !("level_gain" in v) && !("level_clip" in v) }
                END { exit !(NR == 2 && ok) }' || refrows_ok=NO
            refrows_runs=$((refrows_runs + 1))
        done < "$work/out/refrows_settings.txt"
    done; done
    echo "== refrows: $refrows_runs runs, each of them the network and the row its place says: $refrows_ok"
    [ "$refrows_ok" = yes ] || exit 1

    # refrows_partner NAME: the row a row is read over, which meets its
    # noise: the as-budgeted row of its draw for the probes-only one, and the
    # probes-only row of its draw for a cycle.  The as-budgeted row of a draw
    # is read over the first draw's
    refrows_partner() {
        local base=${1%, draw *} dd=${1##*, draw }
        case "$base" in
        "as budgeted") echo "as budgeted, draw ${draws%% *}" ;;
        "cycle, "*) echo "probes only, draw $dd" ;;
        *) echo "as budgeted, draw $dd" ;;
        esac
    }
    # refrows_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    refrows_stat() {
        local sd partner
        partner=$(refrows_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refrows_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(refrows_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refrows_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    refrows_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(refrows_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(refrows_file $sd "$1" "$2, draw $dd")"
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
    # refrows_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    refrows_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(refrows_file $sd "$1" "$2, draw $dd")"; done
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
                    sed "s/^/A $sd2 $dd2 /" "$(refrows_file $sd2 "$1" "as budgeted, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(refrows_file $sd2 "$1" "as budgeted, draw $dd2")"
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
            p=$(refrows_partner "$2, draw 0")
            refrows_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # refrows_lines KIND BASE: a corrected row over its runs: what the probe
    # found on the lines and what its reading would leave, percent rms, and
    # the share of the weights the rail held back, percent
    refrows_lines() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(refrows_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              fs += v["level_found"]; ls += v["level_left"]; cs += v["level_clip"]; runs++ }
            END { printf " %7.2f %6.2f %6.3f", 100 * fs / runs, 100 * ls / runs, 100 * cs / runs }'
    }
    echo "== refrows: the $tile tile on $buses buses at v2, five networks, mean and standard error.  How"
    echo "== often right, percent, and what a row adds over the row it is read over, network by"
    echo "== network: the probes-only row over the as-budgeted row of its draw, a cycle over the"
    echo "== probes-only row of its draw, and the as-budgeted row over the first draw's"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do refrows_stat $k "$name"; done
        echo
    done < "$work/out/refrows_settings.txt"
    echo "== refrows: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/refrows_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do refrows_over $k "$base"; done
        echo
    done
    echo "== refrows: one row over another on the same draws: how often right in the second, less"
    echo "== in the first, network by network over the draws, with its standard error and its"
    echo "== standard deviation from draw to draw.  The two of a pair meet the same noise"
    printf '%-92s %24s %24s' "" "before" "reference"
    echo
    held=${rows%% *}
    hb="cycle, together ${held%:*}, a line ${held#*:}"
    {
        for x in $rows; do
            echo "together ${x%:*}, a line ${x#*:}: over the cycle with no source|cycle, together ${x%:*}, a line ${x#*:}|cycle, no source"
        done
        for x in $rows; do
            [ "$x" != "$held" ] || continue
            echo "the chip as it is held, over together ${x%:*}, a line ${x#*:}|$hb|cycle, together ${x%:*}, a line ${x#*:}"
        done
    } | while IFS='|' read -r label one other; do
        printf '%-92s' "$label"
        for k in before reference; do refrows_pair $k "$one" "$other"; done
        echo
    done
    echo "== refrows: the rows that are read and corrected: what the probe found on the lines and"
    echo "== what its reading would leave, percent rms, and the share of the weights held at the rail,"
    echo "== percent: a mean over the runs"
    printf '%-84s %22s %22s' "" "before" "reference"
    echo
    for x in $rows; do
        base="cycle, together ${x%:*}, a line ${x#*:}"
        printf '%-84s' "$base"
        for k in before reference; do refrows_lines $k "$base"; done
        echo
    done
fi

# `refcomb`: what a corrected comb leaves, told apart.  On a workload that
# lights most of its rows, about half of what a source adds at the end of a
# cycle is not noise: a comb 20% off with no noise at all, read and corrected
# on the weights at 8 bits, still adds it.  Three things could: what the
# reading missed, what writing a weight at 8 bits dropped, and what a weight
# at the rail could not be raised by.  `eval --levelpart` leaves the tile the
# network as it was and adds to its sums, after the converter, the parts
# asked for of what the rewritten weights would be off by, in every layer or
# in one, so that a run with a part is the run with no source but for that
# part.  This runs a six-minute cycle with its trim at 8 bits on five draws,
# which are `refrows`'s: with no source; with a still comb 20% off, read and
# corrected on the weights at 8 bits on the tile, as `refrows` ran it; with
# the reading taken off the model's own line; and told apart, once for each
# of the parts asked for.  A row is read over the cycle with no source of its
# draw.  Both kinds of network, row for row.
if [ "$what" = refcomb ]; then
    tile=${REFCOMB_TILE:-128x64}
    buses=${REFCOMB_BUSES:-2}
    draws=${REFCOMB_DRAWS:-0 1 2 3 4}
    level=${REFCOMB_LEVEL:-0.2}
    parts=${REFCOMB_PARTS:-none read,round,rail read round:1 round:2 rail:1 rail:2}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    d="--impair $all,drift $r --drift tflt"
    fix="--levelprobe 16 --levelfix weights8"
    # refcomb_name PART: the row told apart that takes it, by name; and
    # refcomb_opts PART: what it is asked
    refcomb_name() { case "$1" in *:*) echo "cycle, apart, ${1%:*}, layer ${1#*:}" ;; *) echo "cycle, apart, $1" ;; esac; }
    refcomb_opts() { case "$1" in *:*) echo "--levelpart ${1%:*} --levellayer ${1#*:}" ;; *) echo "--levelpart $1" ;; esac; }
    # row|options.  Every row's name ends in its draw.
    c="--hours 0.1 --calibrate 16 --post-hours 0.1"
    q="--src 0 --srcline 0 --buses $buses --srcflat $level"
    for dd in $draws; do
        echo "cycle, no source, draw $dd|$d $c --trimstep 1"
        echo "cycle, on the tile, draw $dd|$d $c $q $fix --trimstep 1"
        echo "cycle, on the model, draw $dd|$d $c $q --levelprobe 16 --trimstep 1"
        for x in $parts; do
            echo "$(refcomb_name "$x"), draw $dd|$d $c $q $fix --trimstep 1 $(refcomb_opts "$x")"
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ --probe 1/" > "$work/out/refcomb_settings.txt"
    # refcomb_one NET ROW ARGS...: one test-set pass, its line to
    # out/refcomb.d/NET_ROW.txt
    refcomb_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/refcomb.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/refcomb.d/$(basename "$net" .net)_$row.txt"
    }
    export -f refcomb_one
    # refcomb_row NAME: a row's name as a file's
    refcomb_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # refcomb_net SEED KIND: the network's file, trained before or the reference
    refcomb_net() { if [ "$2" = before ]; then echo "d8_b6_s$1.net"; else ref_net "$1"; fi; }
    for s in 1 2 3 4 5; do echo 8 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo 8 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'train_one "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'train_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(refcomb_net $sd $k) $(refcomb_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/refcomb_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'refcomb_one "$@"' _

    # refcomb_file SEED KIND NAME: the file refcomb_one wrote for that run
    refcomb_file() { echo "$work/out/refcomb.d/$(basename "$(refcomb_net "$1" "$2")" .net)_$(refcomb_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network: as in `refsource`, by its training's own line.
    # A run: the network it ran is the one that training wrote; its six rows
    # are version 2's, written out again here; its seed is its draw's; and it
    # is a six-minute cycle with its trim at 8 bits: aged six minutes,
    # calibrated with its trims written, and aged six minutes again, asked a
    # step of one and printing it.  Its name says whether a source is lit,
    # where its reading was applied, and for a row told apart the parts and
    # the layer, which have to be what it was asked and what its line
    # printed, and one of those the mode was asked for.  A lit row has a still
    # source with its lines as far from level as the mode was asked, and was
    # read with sixteen shots a row, and found what the row on the tile of
    # its draw found; the cycle with no source is not lit and was not read.
    # The row on the tile was corrected on the weights at 8 bits and ran the
    # tile at 8-bit weights.  A row told apart was asked that correction and
    # ran the tile at its 6: what its reading would leave and the share the
    # rail held are the row on the tile's of its draw, and its count of the
    # rail a layer comes to that share.  The row on the model was asked no
    # correction.  And a row told apart with no part got right what the cycle
    # with no source of its draw did, with as many saturations.
    refcomb_ok=yes
    refcomb_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(refcomb_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 2 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || refcomb_ok=NO
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            cat "$log" "$(refcomb_file $sd $k "cycle, on the tile, draw $dd")" \
                "$(refcomb_file $sd $k "cycle, no source, draw $dd")" "$(refcomb_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v nb="$buses" -v sd="$sd" -v lv="$level" -v parts="$parts" '
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
                        dark = (base == "cycle, no source") ? 1 : 0
                        ontile = (base == "cycle, on the tile") ? 1 : 0
                        onmodel = (base == "cycle, on the model") ? 1 : 0
                        apart = (base ~ /^cycle, apart, [a-z,]+(, layer [0-9]+)?$/) ? 1 : 0
                        list = ""; layer = 0; known = 0
                        if (apart) { np = split(base, part, ", "); list = part[3]; layer = (np == 4) ? substr(part[4], 7) + 0 : 0
                                     nr = split(parts, pw, " ")
                                     for (i = 1; i <= nr; ++i) { nx = split(pw[i], xy, ":")
                                                                 if (xy[1] == list && nx == np - 2 && ((nx == 2) ? xy[2] + 0 : 0) == layer) known = 1 } }
                        lit = (ontile || onmodel || apart) ? 1 : 0
                        fixed = (ontile || apart) ? 1 : 0
                        flat = lit ? lv + 0 : 0
                        sane = sane && drawn && (dark + ontile + onmodel + apart == 1) && apart == known && lv + 0 > 0.05 && m == 6 &&
                               ("drift" in on) && has("drift") && !has("seed") && want["drift"] == "tflt" &&
                               has("hours") && asked("hours") == 0.1 && has("calibrate") && asked("calibrate") == 16 &&
                               has("post-hours") && asked("post-hours") == 0.1 && !has("trimmax") && !has("wbits") &&
                               has("trimstep") && asked("trimstep") == 1 &&
                               has("src") == lit && asked("src") == 0 && has("srcline") == lit && asked("srcline") == 0 &&
                               has("srcflat") == lit && asked("srcflat") == flat && has("buses") == lit && asked("buses") == nb * lit &&
                               !has("srcsign") && has("levelprobe") == lit && asked("levelprobe") == 16 * lit &&
                               has("levelfix") == fixed && (!fixed || want["levelfix"] == "weights8") && !has("levelref") &&
                               has("levelpart") == apart && (!apart || want["levelpart"] == list) &&
                               has("levellayer") == (layer > 0) && asked("levellayer") == layer }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { found = v["level_found"]; left = v["level_left"]; clip = v["level_clip"]
                          theirs = v["seed"] == sd + 10 * draw && v["net_seed"] == sd && v["wbits"] == 8 && v["levelfix"] == "weights8" }
                NR == 3 { right = v["correct"]; sats = v["sats"]
                          theirs = theirs && v["seed"] == sd + 10 * draw && v["net_seed"] == sd && v["wbits"] == 6 && !("src" in v) }
                NR == 4 { ok = sane && theirs && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw && v["net_wbits"] == 6 &&
                               v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 && v["adcbits"] == 8 &&
                               v["wbits"] == (ontile ? 8 : 6) &&
                               near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                               near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0 &&
                               v["drift"] == "tflt" && v["hours"] == 0.1 && v["steps"] > 0 &&
                               v["cal"] == 16 && v["post_hours"] == 0.1 && near(v["trimstep"], 1, 1e-12) &&
                               v["trimmax"] == 128 && !("hidshift" in v) && !("thermalline" in v)
                          if (lit) ok = ok && v["src"] + 0 == 0 && v["srcline"] + 0 == 0 && v["srcflat"] + 0 == flat &&
                                        v["srcsign"] == "pair" && v["buses"] == nb && v["levelprobe"] == 16 &&
                                        ("level_left" in v) && near(v["level_found"] / flat, 1, 0.4) && v["level_found"] == found
                          else ok = ok && !("src" in v) && !("levelprobe" in v) && !("level_found" in v) && !("level_left" in v)
                          if (fixed) ok = ok && v["levelfix"] == "weights8" && v["levelref"] == "none" && v["level_gain"] == 1 &&
                                          ("level_clip" in v) && v["level_left"] == left && v["level_clip"] == clip
                          else ok = ok && !("levelfix" in v) && !("levelref" in v) && !("level_gain" in v) && !("level_clip" in v)
                          if (apart) { nm = split(v["level_moved"], mv, ","); nh = split(v["level_held"], hd, ",")
                                       ok = ok && ("levelpart" in v) && ("levellayer" in v) && v["levelpart"] == list && v["levellayer"] == layer && nm == 2 && nh == 2 &&
                                            mv[1] > 0 && mv[2] > 0 && hd[1] + 0 <= mv[1] + 0 && hd[2] + 0 <= mv[2] + 0 &&
                                            near((hd[1] + hd[2]) / (mv[1] + mv[2]), v["level_clip"], 5.1e-6) }
                          else ok = ok && !("levelpart" in v) && !("levellayer" in v) && !("level_moved" in v) && !("level_held" in v)
                          if (apart && list == "none") ok = ok && v["correct"] == right && v["sats"] == sats }
                END { exit !(NR == 4 && ok) }' || refcomb_ok=NO
            refcomb_runs=$((refcomb_runs + 1))
        done < "$work/out/refcomb_settings.txt"
    done; done
    echo "== refcomb: $refcomb_runs runs, each of them the network and the row its place says: $refcomb_ok"
    [ "$refcomb_ok" = yes ] || exit 1

    # refcomb_partner NAME: the row a row is read over, which meets its
    # noise: the cycle with no source of its draw.  The cycle with no source
    # of a draw is read over the first draw's
    refcomb_partner() {
        local base=${1%, draw *} dd=${1##*, draw }
        case "$base" in
        "cycle, no source") echo "cycle, no source, draw ${draws%% *}" ;;
        *) echo "cycle, no source, draw $dd" ;;
        esac
    }
    # refcomb_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    refcomb_stat() {
        local sd partner
        partner=$(refcomb_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(refcomb_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(refcomb_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # refcomb_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    refcomb_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(refcomb_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(refcomb_file $sd "$1" "$2, draw $dd")"
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
    # refcomb_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    refcomb_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(refcomb_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd) }'
        # the row it is read over is its partner on its own draw, but for the
        # cycle with no source, whose partner is one row for all of them
        if [ "$2" = "cycle, no source" ]; then
            local first=${draws%% *} sd2 dd2
            for sd2 in 1 2 3 4 5; do
                for dd2 in $draws; do
                    sed "s/^/A $sd2 $dd2 /" "$(refcomb_file $sd2 "$1" "cycle, no source, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(refcomb_file $sd2 "$1" "cycle, no source, draw $dd2")"
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
            p=$(refcomb_partner "$2, draw 0")
            refcomb_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # refcomb_lines KIND BASE: a row that was read, over its runs: what the
    # probe found on the lines and what its reading would leave, percent rms
    refcomb_lines() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(refcomb_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              fs += v["level_found"]; ls += v["level_left"]; runs++ }
            END { printf " %7.2f %6.2f", 100 * fs / runs, 100 * ls / runs }'
    }
    # refcomb_rail KIND BASE: a row told apart, over its runs: of a layer's
    # weights that are not zero, how many the rail held back and the share
    # that is, percent: the first layer, and then the last
    refcomb_rail() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(refcomb_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              split(v["level_moved"], mv, ","); split(v["level_held"], hd, ",")
              h1 += hd[1]; s1 += hd[1] / mv[1]; h2 += hd[2]; s2 += hd[2] / mv[2]; runs++ }
            END { printf " %7.1f %6.3f %7.1f %6.3f", h1 / runs, 100 * s1 / runs, h2 / runs, 100 * s2 / runs }'
    }
    echo "== refcomb: the $tile tile on $buses buses at v2, five networks, mean and standard error.  How"
    echo "== often right, percent, and what a row adds over the row it is read over, network by"
    echo "== network: the cycle with no source of its draw, and for that row the first draw's"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do refcomb_stat $k "$name"; done
        echo
    done < "$work/out/refcomb_settings.txt"
    echo "== refcomb: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/refcomb_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do refcomb_over $k "$base"; done
        echo
    done
    echo "== refcomb: one row over another on the same draws: how often right in the second, less"
    echo "== in the first, network by network over the draws, with its standard error and its"
    echo "== standard deviation from draw to draw.  The two of a pair meet the same noise"
    printf '%-92s %24s %24s' "" "before" "reference"
    echo
    {
        for x in $parts; do
            echo "on the tile, over ${x/:/, layer } told apart|cycle, on the tile|$(refcomb_name "$x")"
        done
        for x in $parts; do
            echo "on the model, over ${x/:/, layer } told apart|cycle, on the model|$(refcomb_name "$x")"
        done
    } | while IFS='|' read -r label one other; do
        printf '%-92s' "$label"
        for k in before reference; do refcomb_pair $k "$one" "$other"; done
        echo
    done
    echo "== refcomb: the rows that are read: what the probe found on the lines and what its"
    echo "== reading would leave, percent rms: a mean over the runs"
    printf '%-84s %14s %14s' "" "before" "reference"
    echo
    for base in "cycle, on the tile" "cycle, on the model"; do
        printf '%-84s' "$base"
        for k in before reference; do refcomb_lines $k "$base"; done
        echo
    done
    echo "== refcomb: the rail, a layer.  Of a layer's weights that are not zero, how many the rail"
    echo "== held back and the share that is, percent, in the first layer and in the last: a mean"
    echo "== over the runs.  Every row told apart counts the same, and this is the first"
    printf '%-84s %29s %29s' "" "before" "reference"
    echo
    base=$(refcomb_name "${parts%% *}")
    printf '%-84s' "$base"
    for k in before reference; do refcomb_rail $k "$base"; done
    echo
fi

# `chain`: the last layer of grxgpu's first-board classifier, on the tile.
# grxgpu's first development board runs one classifier's three layers on
# three engines: the first on the GRX930's NPU, the second on the G100 and
# the third on the PTA, with the CPU converting between them.  It holds the
# PTA to a raw output error against a reference in the PTA's own declared
# format, and to how often the final class is that reference's.  Nothing
# said what the tile does on those terms.  This trains a stand-in for that
# classifier, 64-64-64-16 on a work directory's images pooled to 8 x 8, and
# runs it with `eval --host 2 --gate 1`: the first two layers on the host,
# exactly, as a digital engine has them, and the last on the tile.  Version 2
# on the working tile, five draws, each at the test set's 10,000 images and
# at its first thousand, which is the size of the board's acceptance set: the
# tile's declared format and nothing else, its quantisers and its converter;
# the tile as budgeted; and the tile at the end of a six-minute cycle with
# its trim at 8 bits.  No source is lit: a layer the host runs has no light.
# As budgeted is read over the format alone, and a cycle over as budgeted.
# Both kinds of network, row for row.
if [ "$what" = chain ]; then
    tile=${CHAIN_TILE:-128x64}
    draws=${CHAIN_DRAWS:-0 1 2 3 4}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    f="--impair quant --abits 6 --adcbits 8"
    b="--impair $all $r"
    d="--impair $all,drift $r --drift tflt"
    c="--hours 0.1 --calibrate 16 --post-hours 0.1"
    t="--host 2 --probe 1 --gate 1"
    # row|options.  Every row's name ends in its draw.
    for dd in $draws; do
        for n in "" ", a thousand"; do
            i=
            [ -z "$n" ] || i=" --images 1000"
            echo "format only$n, draw $dd|$f$i"
            echo "as budgeted$n, draw $dd|$b$i"
            echo "cycle$n, draw $dd|$d $c --trimstep 1$i"
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ $t/" > "$work/out/chain_settings.txt"
    # chain_train WBITS SEED [FROM]: a DIN_W 8 network of two hidden layers,
    # unless it is already there, starting from the same seed's at FROM bits
    chain_train() {
        local net="$PTA_WORK/nets/h2_d8_b$1_s$2.net" from=()
        [ $# -lt 3 ] || from=(--from "$PTA_WORK/nets/h2_d8_b$3_s$2.net")
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits "$1" \
            --seed "$2" --hidden 2 "${from[@]}" --out "$net" > "$net.log"
    }
    # chain_ref SEED: that seed's reference network, the header's recipe at
    # this shape
    chain_ref() {
        local net="$PTA_WORK/nets/h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
            --seed "$1" --hidden 2 --from "$PTA_WORK/nets/h2_d8_b8_s$1.net" \
            --sumnoise "$PTA_REF_NOISE" --epochs "$PTA_REF_EPOCHS" --out "$net" > "$net.log"
    }
    # chain_one NET ROW ARGS...: one test-set pass, its line to
    # out/chain.d/NET_ROW.txt
    chain_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/chain.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/chain.d/$(basename "$net" .net)_$row.txt"
    }
    export -f chain_train chain_ref chain_one
    # chain_row NAME: a row's name as a file's
    chain_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # chain_net SEED KIND: the network's file, trained before or the reference
    chain_net() {
        if [ "$2" = before ]; then echo "h2_d8_b6_s$1.net"
        else echo "h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; fi
    }
    for s in 1 2 3 4 5; do echo 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'chain_train "$@"' _
    for s in 1 2 3 4 5; do echo 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'chain_train "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'chain_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(chain_net $sd $k) $(chain_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/chain_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'chain_one "$@"' _

    # chain_file SEED KIND NAME: the file chain_one wrote for that run
    chain_file() { echo "$work/out/chain.d/$(basename "$(chain_net "$1" "$2")" .net)_$(chain_row "$3").txt"; }
    # Every network has to be the kind its column says, and every run the row
    # its name says.  A network has two hidden layers, 6-bit weights, and its
    # seed, and came from that seed's 8-bit one; a reference was trained for
    # the header's epochs with the header's noise on all three layers' sums,
    # and one trained before with none.  A run: the network it ran is the one
    # that training wrote; its seed is its draw's; its name says whether it
    # is the format alone, the tile as budgeted or a cycle, and whether it is
    # of a thousand images or of all, which have to be what it was asked and
    # what its line printed.  Every run has its first two layers on the host
    # and the last on the tile, whose sums are all the sums it counts, and no
    # more than one in a hundred of them past the converter's range; and the
    # probe and the gate's figures taken, with the class against the declared
    # reference among them, and that reference right as often as it is in the
    # format alone of the first draw, since no draw moves it:
    # the first two layers' own error is nothing, the last layer's is
    # something, and no figure against a largest value is past the largest
    # error against it.  The format alone has the quantisers and the
    # converter and nothing else, and on every draw gets right what it gets
    # right on the first.  As budgeted is version 2, written out again here.
    # A cycle is that, aged six minutes, calibrated with its trims written,
    # and aged six minutes again, with its trim at 8 bits.  No run is lit.
    chain_ok=yes
    chain_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(chain_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2 &&
                   v["hidden"] == 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 3 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || chain_ok=NO
        while IFS='|' read -r name setting; do
            first="format only"
            [ "${name%, a thousand, draw *}" = "$name" ] || first="format only, a thousand"
            cat "$log" "$(chain_file $sd $k "$first, draw ${draws%% *}")" "$(chain_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v sd="$sd" -v d0="${draws%% *}" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        few = (base ~ /, a thousand$/) ? 1 : 0
                        core = few ? substr(base, 1, length(base) - 12) : base
                        fmt = (core == "format only") ? 1 : 0
                        bud = (core == "as budgeted") ? 1 : 0
                        cyc = (core == "cycle") ? 1 : 0
                        noisy = (bud || cyc) ? 1 : 0
                        split(tile, tt, "x"); per = 16 * int((64 + tt[1] - 1) / tt[1])
                        sane = drawn && (fmt + bud + cyc == 1) && m == (fmt ? 1 : 5 + cyc) && ("quant" in on) &&
                               asked("abits") == 6 && asked("adcbits") == 8 && has("thermal8") == noisy &&
                               has("photons8") == noisy && has("prog") == noisy && has("xtalk") == noisy &&
                               (!noisy || (asked("thermal8") == 0.25 && asked("photons8") == 30 && asked("prog") == 1 &&
                                           asked("xtalk") == 0.02 && ("thermal" in on) && ("shot" in on) &&
                                           ("prog" in on) && ("xtalk" in on))) &&
                               (cyc == (("drift" in on) ? 1 : 0)) && has("drift") == cyc && (!cyc || want["drift"] == "tflt") &&
                               has("hours") == cyc && asked("hours") == 0.1 * cyc &&
                               has("calibrate") == cyc && asked("calibrate") == 16 * cyc &&
                               has("post-hours") == cyc && asked("post-hours") == 0.1 * cyc &&
                               has("trimstep") == cyc && asked("trimstep") == cyc && !has("trimmax") && !has("wbits") &&
                               !has("seed") && !has("src") && !has("srcline") && !has("srcflat") && !has("levelprobe") &&
                               has("host") && asked("host") == 2 && has("probe") && asked("probe") == 1 &&
                               has("gate") && asked("gate") == 1 && has("images") == few && asked("images") == 1000 * few }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { right = v["correct"]; gref = v["gate_ref"]
                          theirs = ("gate_ref" in v) && v["impair"] == "0x01" && v["seed"] == sd + 10 * d0 && v["net_seed"] == sd &&
                                   v["images"] == (few ? 1000 : 10000) }
                NR == 3 { ns = split(v["S"], sh, ",")
                          ok = sane && theirs && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw &&
                               v["net_wbits"] == 6 && v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["hidden"] == 2 && ns == 3 && v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 &&
                               v["adcbits"] == 8 && v["wbits"] == 6 && v["drift"] == (cyc ? "tflt" : "none") &&
                               v["hours"] == 0.1 * cyc && (v["steps"] > 0) == cyc && v["cal"] == 16 * cyc &&
                               v["post_hours"] == 0.1 * cyc && near(v["trimstep"], cyc ? 1 : 0.25, 1e-12) &&
                               v["trimmax"] == 128 && v["images"] == (few ? 1000 : 10000) && ("host" in v) && v["host"] == 2 &&
                               !("src" in v) && !("levelprobe" in v) && !("hidshift" in v) && !("thermalline" in v) &&
                               ("gate_bits" in v) && v["gate_bits"] == 6 && ("gate_rms" in v) && v["gate_rms"] > 0 &&
                               v["gate_peak"] > 0 && v["gate8_peak"] > 0 && v["gate_rmsfs"] > 0 &&
                               v["gate_rmsfs"] + 0 <= v["gate_maxfs"] + 0 && v["gate8_rmsfs"] + 0 <= v["gate8_maxfs"] + 0 &&
                               ("e1" in v) && ("e2" in v) && v["e1"] == 0 && v["e2"] == 0 && v["e3"] > 0 &&
                               ("agree" in v) && ("ref" in v) && v["agree"] > 50 &&
                               ("sats" in v) && ("elements" in v) && v["elements"] == per * v["images"] &&
                               v["sats"] + 0 <= v["elements"] / 100 &&
                               ("gate_agree" in v) && ("gate_ref" in v) && v["gate_agree"] > 50 &&
                               v["gate_agree"] + 0 <= 100 && v["gate_ref"] == gref && v["gate_ref"] > 0
                          if (noisy) ok = ok && near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                                          near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0
                          else ok = ok && v["thermal8"] == 0 && v["photons8"] == 0 && v["prog"] == 0 && v["xtalk"] == 0 &&
                                    v["correct"] == right }
                END { exit !(NR == 3 && ok) }' || chain_ok=NO
            chain_runs=$((chain_runs + 1))
        done < "$work/out/chain_settings.txt"
    done; done
    echo "== chain: $chain_runs runs, each of them the network and the row its place says: $chain_ok"
    [ "$chain_ok" = yes ] || exit 1

    # chain_partner NAME: the row a row is read over, at its own count of
    # images: the format alone of its draw for the tile as budgeted, and the
    # tile as budgeted of its draw for a cycle.  The format alone of a draw
    # is read over the first draw's, which it is
    chain_partner() {
        local base=${1%, draw *} dd=${1##*, draw } n=
        [ "${base%, a thousand}" = "$base" ] || n=", a thousand"
        case "$base" in
        "format only"*) echo "format only$n, draw ${draws%% *}" ;;
        "as budgeted"*) echo "format only$n, draw $dd" ;;
        *) echo "as budgeted$n, draw $dd" ;;
        esac
    }
    # chain_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    chain_stat() {
        local sd partner
        partner=$(chain_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(chain_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(chain_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # chain_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    chain_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(chain_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(chain_file $sd "$1" "$2, draw $dd")"
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
    # chain_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    chain_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(chain_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd) }'
        # the row it is read over is its partner on its own draw, but for a
        # format-only row, whose partner is one row for all of them
        if [ "${2#format only}" != "$2" ]; then
            local first=${draws%% *} sd2 dd2
            for sd2 in 1 2 3 4 5; do
                for dd2 in $draws; do
                    sed "s/^/A $sd2 $dd2 /" "$(chain_file $sd2 "$1" "$2, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(chain_file $sd2 "$1" "$2, draw $dd2")"
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
            p=$(chain_partner "$2, draw 0")
            chain_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # chain_agree KIND BASE FIELD: a row over its draws: how often the class
    # the tile gives is the class the host gives (agree) or the class its
    # declared reference gives (gate_agree), percent: the mean, its standard
    # error from the five networks each averaged over its draws, and the
    # draws' standard deviation; the least of any run; and of the runs, how
    # many agree on 99.5% or more
    chain_agree() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(chain_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v fld="$3" '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v[fld] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++
              if (runs == 0 || x < least) least = x
              runs++; pass += (x >= 99.5) }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f %7.2f %3d of %2d", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd), least, pass, runs }'
    }
    # chain_declared KIND BASE: how often the declared reference is right in
    # a row, percent, a mean over its runs: what its own format leaves the
    # network, before any tile
    chain_declared() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(chain_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              s += v["gate_ref"]; runs++ }
            END { printf " %7.3f", s / runs }'
    }
    # chain_gate KIND BASE RMS RMSFS MAXFS: a row over its runs, against one
    # reference: the last layer's rms error over the reference's rms, over
    # the largest the reference is, and its largest error over that, percent:
    # a mean, and for the third the most of any run; and of the runs, how
    # many are within 1.0% on the first, 1.0% on the second and 2.0% on the
    # third
    chain_gate() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(chain_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v a="$3" -v b="$4" -v c="$5" '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = 100 * v[a]; y = 100 * v[b]; z = 100 * v[c]
              xs += x; ys += y; zs += z; if (z > most) most = z
              px += (x <= 1.0); py += (y <= 1.0); pz += (z <= 2.0); runs++ }
            END { printf " %7.3f %6.3f %6.3f %6.3f %3d %2d %2d", xs / runs, ys / runs, zs / runs, most, px, py, pz }'
    }
    # chain_range KIND BASE: a row over its runs, and the converter's range,
    # which the harness sets on a thousand training images to pass all but one
    # sum in ten thousand: the runs with a sum past it, the most sums past it
    # in a run, and of how many; and the most the largest error against the
    # declared format is, percent of the largest the reference is, in the runs
    # with none past it and in the runs with some.  Nothing where there is no
    # such run
    chain_range() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(chain_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              z = 100 * v["gate_maxfs"]; s = v["sats"] + 0; runs++; of = v["elements"] + 0
              if (s > 0) { past++; if (s > most) most = s; if (z > clipped) clipped = z }
              else if (z > whole) whole = z }
            END { printf " %5d of %2d %5d of %6d %7.3f %7.3f", past, runs, most, of, whole, clipped }'
    }
    echo "== chain: the $tile tile at v2, the last layer of three on it, five networks, mean and"
    echo "== standard error.  How often right, percent, and what a row adds over the row it is"
    echo "== read over, network by network: the format alone of its draw for the tile as budgeted,"
    echo "== and the tile as budgeted of its draw for a cycle"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do chain_stat $k "$name"; done
        echo
    done < "$work/out/chain_settings.txt"
    echo "== chain: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do chain_over $k "$base"; done
        echo
    done
    echo "== chain: the class the tile gives against the class the host gives, percent, a row over"
    echo "== its draws: the mean, its standard error from five networks, the draws' standard"
    echo "== deviation, the least of any run, and the runs that agree on 99.5% or more"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do chain_agree $k "$base" agree; done
        echo
    done
    echo "== chain: the class the tile gives against the class its declared reference gives,"
    echo "== percent, a row over its draws: the same five; and how often that reference is"
    echo "== right, a mean over the runs"
    printf '%-84s %48s %48s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do chain_agree $k "$base" gate_agree; chain_declared $k "$base"; done
        echo
    done
    for ref in "its declared format|gate_rms gate_rmsfs gate_maxfs" "its operands as they were given|e3 gate8_rmsfs gate8_maxfs"; do
        echo "== chain: the last layer's error against ${ref%|*}, percent, a row over its"
        echo "== runs: its rms over the reference's rms, over the largest the reference is, and its"
        echo "== largest over that, a mean; the most the third is in any run; and the runs within"
        echo "== 1.0% on the first, 1.0% on the second and 2.0% on the third"
        printf '%-84s %40s %40s' "" "before" "reference"
        echo
        sed 's/, draw [0-9]*|.*//' "$work/out/chain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
            printf '%-84s' "$base"
            for k in before reference; do chain_gate $k "$base" ${ref#*|}; done
            echo
        done
    done
    echo "== chain: the converter's range, a row over its runs: the runs with a sum past it, the"
    echo "== most sums past it in a run, and of how many; and the most the largest error against"
    echo "== the declared format is, percent of the largest the reference is, in the runs with"
    echo "== none past it and in the runs with some"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do chain_range $k "$base"; done
        echo
    done
fi

# `chainfit`: `chain`'s last layer, with a range that clips nothing.
# `chain` found the largest error of the first board's last layer decided, in
# five networks of thirty, by the converter's range and not by noise: the
# harness sets a range on training images, to pass all but one sum in ten
# thousand, which is a rule for the class.  A board that holds a layer's raw
# outputs to a reference defines its full scale from that reference.
# `eval --gatefit F` does: the smallest step at which the largest the declared
# reference is, on the images run, is within the share F of the converter's
# full scale.  The noise stays what version 2 has it, in LSB of the converter,
# so a larger step is more noise in a sum's own units: that is what a range
# costs.  The same networks as `chain`, and its format alone and its tile as
# budgeted, each three ways: with the range training's rule gives, which are
# `chain`'s own runs; fitted, F of 1; and with a bit spare, F of 0.5.  Five
# draws, on 10,000 images and on the first thousand.  A fitted row is read
# over its own row with training's range, and a row with a bit spare over
# the fitted one, draw for draw.  Both kinds of network, row for row.
if [ "$what" = chainfit ]; then
    tile=${CHAINFIT_TILE:-128x64}
    draws=${CHAINFIT_DRAWS:-0 1 2 3 4}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    f="--impair quant --abits 6 --adcbits 8"
    b="--impair $all $r"
    t="--host 2 --probe 1 --gate 1"
    # row|options.  Every row's name ends in its draw.  A row is the format
    # alone or the tile as budgeted; with the range training's rule gives,
    # fitted, or with a bit spare; on all the images or on a thousand
    for dd in $draws; do
        for n in "" ", a thousand"; do
            i=
            [ -z "$n" ] || i=" --images 1000"
            for x in "|" ", fitted| --gatefit 1" ", a bit spare| --gatefit 0.5"; do
                echo "format only${x%|*}$n, draw $dd|$f$i${x#*|}"
                echo "as budgeted${x%|*}$n, draw $dd|$b$i${x#*|}"
            done
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ $t/" > "$work/out/chainfit_settings.txt"
    # fit_train WBITS SEED [FROM]: a DIN_W 8 network of two hidden layers,
    # unless it is already there, starting from the same seed's at FROM bits
    fit_train() {
        local net="$PTA_WORK/nets/h2_d8_b$1_s$2.net" from=()
        [ $# -lt 3 ] || from=(--from "$PTA_WORK/nets/h2_d8_b$3_s$2.net")
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits "$1" \
            --seed "$2" --hidden 2 "${from[@]}" --out "$net" > "$net.log"
    }
    # fit_ref SEED: that seed's reference network, the header's recipe at
    # this shape
    fit_ref() {
        local net="$PTA_WORK/nets/h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
            --seed "$1" --hidden 2 --from "$PTA_WORK/nets/h2_d8_b8_s$1.net" \
            --sumnoise "$PTA_REF_NOISE" --epochs "$PTA_REF_EPOCHS" --out "$net" > "$net.log"
    }
    # fit_one NET ROW ARGS...: one test-set pass, its line to
    # out/chainfit.d/NET_ROW.txt
    fit_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/chainfit.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/chainfit.d/$(basename "$net" .net)_$row.txt"
    }
    export -f fit_train fit_ref fit_one
    # fit_row NAME: a row's name as a file's
    fit_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # fit_net SEED KIND: the network's file, trained before or the reference
    fit_net() {
        if [ "$2" = before ]; then echo "h2_d8_b6_s$1.net"
        else echo "h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; fi
    }
    for s in 1 2 3 4 5; do echo 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'fit_train "$@"' _
    for s in 1 2 3 4 5; do echo 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'fit_train "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'fit_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(fit_net $sd $k) $(fit_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/chainfit_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'fit_one "$@"' _

    # fit_file SEED KIND NAME: the file fit_one wrote for that run
    fit_file() { echo "$work/out/chainfit.d/$(basename "$(fit_net "$1" "$2")" .net)_$(fit_row "$3").txt"; }
    # fit_partner NAME: the row a row is read over, at its own count of
    # images: its own row with training's range for a fitted one, and the
    # fitted one for one with a bit spare, each of its draw.  With training's
    # range the tile as budgeted is read over the format alone of its draw,
    # and the format alone over the first draw's, which it is
    fit_partner() {
        local base=${1%, draw *} dd=${1##*, draw } n= core
        [ "${base%, a thousand}" = "$base" ] || n=", a thousand"
        core=${base%, a thousand}
        case "$core" in
        *", a bit spare") echo "${core%, a bit spare}, fitted$n, draw $dd" ;;
        *", fitted") echo "${core%, fitted}$n, draw $dd" ;;
        "format only") echo "format only$n, draw ${draws%% *}" ;;
        *) echo "format only$n, draw $dd" ;;
        esac
    }
    # The rows with training's range are `chain`'s rows.  Where this directory
    # has what `chain` wrote, each has to be that line, byte for byte.
    if [ -d "$work/out/chain.d" ]; then
        same=0
        other=0
        for k in before reference; do for sd in 1 2 3 4 5; do
            while IFS='|' read -r name setting; do
                case "$name" in *fitted*|*spare*) continue ;; esac
                was="$work/out/chain.d/$(basename "$(fit_file $sd $k "$name")")"
                [ -s "$was" ] || continue
                if cmp -s "$was" "$(fit_file $sd $k "$name")"; then same=$((same + 1)); else other=$((other + 1)); fi
            done < "$work/out/chainfit_settings.txt"
        done; done
        echo "== chainfit: against what chain wrote for the same runs: $same the same, $other not"
        [ "$other" = 0 ] || exit 1
    fi
    # Every network has to be the kind its column says, and every run the row
    # its name says, as `chain` holds its own.  A run's name says its draw,
    # whether it is the format alone or the tile as budgeted, whether its
    # range is training's, fitted or with a bit spare, and whether it is of a
    # thousand images or of all, which have to be what it was asked and what
    # its line printed.  A run with training's range says nothing of a fit,
    # and its last shift is the one the format alone of the first draw has.
    # A fitted run says the share it was asked and the shift training's rule
    # had given, which is that same one; its last shift is the smallest at
    # which the largest its declared reference is, is within that share of
    # 127 codes, and is its 8-bit shift too, since its noise is in its own
    # LSB; and that largest is the one the format alone has with training's
    # range, since a range does not move a reference.  The format alone,
    # fitted or with a bit spare, has no sum past its range.  A fitted run
    # whose shift is the one it had is the run with training's range of its
    # draw, figure for figure.  And a run with a bit spare has a larger shift
    # than the fitted run of its draw.  The format alone, whatever its range,
    # gets right on every draw what its own row gets right on the first.  No
    # run is lit.
    fit_ok=yes
    fit_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(fit_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2 &&
                   v["hidden"] == 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 3 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || fit_ok=NO
        while IFS='|' read -r name setting; do
            first="format only"
            [ "${name%, a thousand, draw *}" = "$name" ] || first="format only, a thousand"
            cat "$log" "$(fit_file $sd $k "$first, draw ${draws%% *}")" \
                "$(fit_file $sd $k "${name%, draw *}, draw ${draws%% *}")" \
                "$(fit_file $sd $k "$(fit_partner "$name")")" "$(fit_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v sd="$sd" -v d0="${draws%% *}" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        few = (base ~ /, a thousand$/) ? 1 : 0
                        core = few ? substr(base, 1, length(base) - 12) : base
                        kind = 0; share = 0
                        if (core ~ /, fitted$/) { kind = 1; share = 1; core = substr(core, 1, length(core) - 8) }
                        else if (core ~ /, a bit spare$/) { kind = 2; share = 0.5; core = substr(core, 1, length(core) - 13) }
                        fmt = (core == "format only") ? 1 : 0
                        bud = (core == "as budgeted") ? 1 : 0
                        cyc = (core == "cycle") ? 1 : 0
                        noisy = (bud || cyc) ? 1 : 0
                        split(tile, tt, "x"); per = 16 * int((64 + tt[1] - 1) / tt[1])
                        sane = drawn && (fmt + bud + cyc == 1) && m == (fmt ? 1 : 5 + cyc) && ("quant" in on) &&
                               asked("abits") == 6 && asked("adcbits") == 8 && has("thermal8") == noisy &&
                               has("photons8") == noisy && has("prog") == noisy && has("xtalk") == noisy &&
                               (!noisy || (asked("thermal8") == 0.25 && asked("photons8") == 30 && asked("prog") == 1 &&
                                           asked("xtalk") == 0.02 && ("thermal" in on) && ("shot" in on) &&
                                           ("prog" in on) && ("xtalk" in on))) &&
                               (cyc == (("drift" in on) ? 1 : 0)) && has("drift") == cyc && (!cyc || want["drift"] == "tflt") &&
                               has("hours") == cyc && asked("hours") == 0.1 * cyc &&
                               has("calibrate") == cyc && asked("calibrate") == 16 * cyc &&
                               has("post-hours") == cyc && asked("post-hours") == 0.1 * cyc &&
                               has("trimstep") == cyc && asked("trimstep") == cyc && !has("trimmax") && !has("wbits") &&
                               !has("seed") && !has("src") && !has("srcline") && !has("srcflat") && !has("levelprobe") &&
                               has("host") && asked("host") == 2 && has("probe") && asked("probe") == 1 &&
                               has("gate") && asked("gate") == 1 && has("images") == few && asked("images") == 1000 * few &&
                               has("gatefit") == (kind > 0 ? 1 : 0) && (!kind || asked("gatefit") == share) }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { right = v["correct"]; gref = v["gate_ref"]; split(v["S"], s0, ","); was = s0[3]; peak0 = v["gate_peak"]
                          theirs = ("gate_ref" in v) && v["impair"] == "0x01" && v["seed"] == sd + 10 * d0 && v["net_seed"] == sd &&
                                   v["images"] == (few ? 1000 : 10000) }
                NR == 3 { own = v["correct"] }
                NR == 4 { pright = v["correct"]; psats = v["sats"]; split(v["S"], ps, ",")
                          pfig = v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"] }
                NR == 5 { ns = split(v["S"], sh, ","); n8 = split(v["S8"], s8, ",")
                          ok = sane && theirs && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw &&
                               v["net_wbits"] == 6 && v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["hidden"] == 2 && ns == 3 && v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 &&
                               v["adcbits"] == 8 && v["wbits"] == 6 && v["drift"] == (cyc ? "tflt" : "none") &&
                               v["hours"] == 0.1 * cyc && (v["steps"] > 0) == cyc && v["cal"] == 16 * cyc &&
                               v["post_hours"] == 0.1 * cyc && near(v["trimstep"], cyc ? 1 : 0.25, 1e-12) &&
                               v["trimmax"] == 128 && v["images"] == (few ? 1000 : 10000) && ("host" in v) && v["host"] == 2 &&
                               !("src" in v) && !("levelprobe" in v) && !("hidshift" in v) && !("thermalline" in v) &&
                               ("gate_bits" in v) && v["gate_bits"] == 6 && ("gate_rms" in v) && v["gate_rms"] > 0 &&
                               v["gate_peak"] > 0 && v["gate8_peak"] > 0 && v["gate_rmsfs"] > 0 &&
                               v["gate_rmsfs"] + 0 <= v["gate_maxfs"] + 0 && v["gate8_rmsfs"] + 0 <= v["gate8_maxfs"] + 0 &&
                               ("e1" in v) && ("e2" in v) && v["e1"] == 0 && v["e2"] == 0 && v["e3"] > 0 &&
                               ("agree" in v) && ("ref" in v) && v["agree"] > 50 &&
                               ("sats" in v) && ("elements" in v) && v["elements"] == per * v["images"] &&
                               v["sats"] + 0 <= v["elements"] / 100 &&
                               ("gate_agree" in v) && ("gate_ref" in v) && v["gate_agree"] > 50 &&
                               v["gate_agree"] + 0 <= 100 && v["gate_ref"] == gref && v["gate_ref"] > 0 &&
                               v["gate_peak"] == peak0 && sh[1] == s0[1] && sh[2] == s0[2] && n8 == 3 && s8[3] == sh[3]
                          if (kind == 0) ok = ok && !("gate_fit" in v) && !("gate_was" in v) && sh[3] == was
                          else { lim = int(share * 127)
                                 ok = ok && ("gate_fit" in v) && v["gate_fit"] == share && ("gate_was" in v) &&
                                      v["gate_was"] == was && int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= lim &&
                                      (sh[3] == 0 || int(v["gate_peak"] / 2 ^ (sh[3] - 1) + 0.5) > lim)
                                 if (fmt) ok = ok && v["sats"] == 0
                                 if (kind == 1 && sh[3] == was)
                                     ok = ok && v["correct"] == pright && v["sats"] == psats &&
                                          pfig == v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"]
                                 if (kind == 2) ok = ok && sh[3] > ps[3] }
                          if (noisy) ok = ok && near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                                          near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0
                          else ok = ok && v["thermal8"] == 0 && v["photons8"] == 0 && v["prog"] == 0 && v["xtalk"] == 0 &&
                                    v["correct"] == own && (kind > 0 || own == right) }
                END { exit !(NR == 5 && ok) }' || fit_ok=NO
            fit_runs=$((fit_runs + 1))
        done < "$work/out/chainfit_settings.txt"
    done; done
    echo "== chainfit: $fit_runs runs, each of them the network and the row its place says: $fit_ok"
    [ "$fit_ok" = yes ] || exit 1

    # fit_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    fit_stat() {
        local sd partner
        partner=$(fit_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(fit_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(fit_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # fit_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    fit_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(fit_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(fit_file $sd "$1" "$2, draw $dd")"
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
    # fit_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    fit_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(fit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd) }'
        # the row it is read over is its partner on its own draw, but for a
        # format-only row, whose partner is one row for all of them
        if [ "$2" = "format only" ] || [ "$2" = "format only, a thousand" ]; then
            local first=${draws%% *} sd2 dd2
            for sd2 in 1 2 3 4 5; do
                for dd2 in $draws; do
                    sed "s/^/A $sd2 $dd2 /" "$(fit_file $sd2 "$1" "$2, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(fit_file $sd2 "$1" "$2, draw $dd2")"
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
            p=$(fit_partner "$2, draw 0")
            fit_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # fit_agree KIND BASE FIELD: a row over its draws: how often the class
    # the tile gives is the class the host gives (agree) or the class its
    # declared reference gives (gate_agree), percent: the mean, its standard
    # error from the five networks each averaged over its draws, and the
    # draws' standard deviation; the least of any run; and of the runs, how
    # many agree on 99.5% or more
    fit_agree() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(fit_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v fld="$3" '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v[fld] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++
              if (runs == 0 || x < least) least = x
              runs++; pass += (x >= 99.5) }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f %7.2f %3d of %2d", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd), least, pass, runs }'
    }
    # fit_declared KIND BASE: how often the declared reference is right in
    # a row, percent, a mean over its runs: what its own format leaves the
    # network, before any tile
    fit_declared() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(fit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              s += v["gate_ref"]; runs++ }
            END { printf " %7.3f", s / runs }'
    }
    # fit_gate KIND BASE RMS RMSFS MAXFS: a row over its runs, against one
    # reference: the last layer's rms error over the reference's rms, over
    # the largest the reference is, and its largest error over that, percent:
    # a mean, and for the third the most of any run; and of the runs, how
    # many are within 1.0% on the first, 1.0% on the second and 2.0% on the
    # third
    fit_gate() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(fit_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v a="$3" -v b="$4" -v c="$5" '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = 100 * v[a]; y = 100 * v[b]; z = 100 * v[c]
              xs += x; ys += y; zs += z; if (z > most) most = z
              px += (x <= 1.0); py += (y <= 1.0); pz += (z <= 2.0); runs++ }
            END { printf " %7.3f %6.3f %6.3f %6.3f %3d %2d %2d", xs / runs, ys / runs, zs / runs, most, px, py, pz }'
    }
    # fit_range KIND BASE: a row over its runs, and the converter's range,
    # which the harness sets on a thousand training images to pass all but one
    # sum in ten thousand: the runs with a sum past it, the most sums past it
    # in a run, and of how many; and the most the largest error against the
    # declared format is, percent of the largest the reference is, in the runs
    # with none past it and in the runs with some.  Nothing where there is no
    # such run.  And the runs whose step is larger than the one training's
    # rule gave, and by how many bits at the most
    fit_range() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(fit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              z = 100 * v["gate_maxfs"]; s = v["sats"] + 0; runs++; of = v["elements"] + 0
              if (s > 0) { past++; if (s > most) most = s; if (z > clipped) clipped = z }
              else if (z > whole) whole = z
              if ("gate_was" in v) { split(v["S"], sh, ","); more = sh[3] - v["gate_was"]
                                     if (more != 0) moved++; if (more > bits) bits = more } }
            END { printf " %5d of %2d %5d of %6d %7.3f %7.3f %3d %2d", past, runs, most, of, whole, clipped, moved, bits }'
    }
    echo "== chainfit: the $tile tile at v2, the last layer of three on it, five networks, mean and"
    echo "== standard error.  How often right, percent, and what a row adds over the row it is"
    echo "== read over, network by network: its own row with training's range for a fitted one,"
    echo "== and the fitted one of its draw for one with a bit spare"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do fit_stat $k "$name"; done
        echo
    done < "$work/out/chainfit_settings.txt"
    echo "== chainfit: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainfit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do fit_over $k "$base"; done
        echo
    done
    echo "== chainfit: the class the tile gives against the class the host gives, percent, a row over"
    echo "== its draws: the mean, its standard error from five networks, the draws' standard"
    echo "== deviation, the least of any run, and the runs that agree on 99.5% or more"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainfit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do fit_agree $k "$base" agree; done
        echo
    done
    echo "== chainfit: the class the tile gives against the class its declared reference gives,"
    echo "== percent, a row over its draws: the same five; and how often that reference is"
    echo "== right, a mean over the runs"
    printf '%-84s %48s %48s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainfit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do fit_agree $k "$base" gate_agree; fit_declared $k "$base"; done
        echo
    done
    for ref in "its declared format|gate_rms gate_rmsfs gate_maxfs" "its operands as they were given|e3 gate8_rmsfs gate8_maxfs"; do
        echo "== chainfit: the last layer's error against ${ref%|*}, percent, a row over its"
        echo "== runs: its rms over the reference's rms, over the largest the reference is, and its"
        echo "== largest over that, a mean; the most the third is in any run; and the runs within"
        echo "== 1.0% on the first, 1.0% on the second and 2.0% on the third"
        printf '%-84s %40s %40s' "" "before" "reference"
        echo
        sed 's/, draw [0-9]*|.*//' "$work/out/chainfit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
            printf '%-84s' "$base"
            for k in before reference; do fit_gate $k "$base" ${ref#*|}; done
            echo
        done
    done
    echo "== chainfit: the converter's range, a row over its runs: the runs with a sum past it, the"
    echo "== most sums past it in a run, and of how many; and the most the largest error against"
    echo "== the declared format is, percent of the largest the reference is, in the runs with"
    echo "== none past it and in the runs with some; and the runs whose step is larger than the"
    echo "== one training's rule gave, and by how many bits at the most"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainfit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do fit_range $k "$base"; done
        echo
    done
fi

# `chainbit`: `chain`'s last layer, with a converter of a bit more.
# `chainfit` bought a range that clips nothing by fitting an 8-bit converter
# to the reference, and it cost the networks it moved a fifth more error: the
# noise is in LSB of the converter, and a wider range was a larger LSB.  The
# other way to buy range is a bit.  `eval --gatebits 9` gives the last
# layer's converter 9 bits at the step the 8-bit one has, which is twice the
# range at the same LSB, with the noise what it was.  And with `--gatefit 1`
# it is 9 bits over the fitted range, which is the same range in steps half
# the size: a bit spent on resolution.  The same networks as `chain`, and its
# format alone and its tile as budgeted, each four ways: 8 bits with the
# range training's rule gives, which are `chain`'s own runs; 8 bits fitted,
# which are `chainfit`'s; 9 bits at training's step; and 9 bits fitted.  Five
# draws, on 10,000 images and on the first thousand.  A row with 9 bits is
# read over its own row with 8 at the same range, draw for draw.  Both kinds
# of network, row for row.
if [ "$what" = chainbit ]; then
    tile=${CHAINBIT_TILE:-128x64}
    draws=${CHAINBIT_DRAWS:-0 1 2 3 4}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    f="--impair quant --abits 6 --adcbits 8"
    b="--impair $all $r"
    t="--host 2 --probe 1 --gate 1"
    # row|options.  Every row's name ends in its draw.  A row is the format
    # alone or the tile as budgeted; with 8 bits or with 9, each at the range
    # training's rule gives or fitted; on all the images or on a thousand
    for dd in $draws; do
        for n in "" ", a thousand"; do
            i=
            [ -z "$n" ] || i=" --images 1000"
            for x in "|" ", fitted| --gatefit 1" ", nine bits| --gatebits 9" ", nine bits, fitted| --gatebits 9 --gatefit 1"; do
                echo "format only${x%|*}$n, draw $dd|$f$i${x#*|}"
                echo "as budgeted${x%|*}$n, draw $dd|$b$i${x#*|}"
            done
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ $t/" > "$work/out/chainbit_settings.txt"
    # bit_train WBITS SEED [FROM]: a DIN_W 8 network of two hidden layers,
    # unless it is already there, starting from the same seed's at FROM bits
    bit_train() {
        local net="$PTA_WORK/nets/h2_d8_b$1_s$2.net" from=()
        [ $# -lt 3 ] || from=(--from "$PTA_WORK/nets/h2_d8_b$3_s$2.net")
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits "$1" \
            --seed "$2" --hidden 2 "${from[@]}" --out "$net" > "$net.log"
    }
    # bit_ref SEED: that seed's reference network, the header's recipe at
    # this shape
    bit_ref() {
        local net="$PTA_WORK/nets/h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
            --seed "$1" --hidden 2 --from "$PTA_WORK/nets/h2_d8_b8_s$1.net" \
            --sumnoise "$PTA_REF_NOISE" --epochs "$PTA_REF_EPOCHS" --out "$net" > "$net.log"
    }
    # bit_one NET ROW ARGS...: one test-set pass, its line to
    # out/chainbit.d/NET_ROW.txt
    bit_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/chainbit.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/chainbit.d/$(basename "$net" .net)_$row.txt"
    }
    export -f bit_train bit_ref bit_one
    # bit_row NAME: a row's name as a file's
    bit_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # bit_net SEED KIND: the network's file, trained before or the reference
    bit_net() {
        if [ "$2" = before ]; then echo "h2_d8_b6_s$1.net"
        else echo "h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; fi
    }
    for s in 1 2 3 4 5; do echo 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'bit_train "$@"' _
    for s in 1 2 3 4 5; do echo 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'bit_train "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'bit_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(bit_net $sd $k) $(bit_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/chainbit_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'bit_one "$@"' _

    # bit_file SEED KIND NAME: the file bit_one wrote for that run
    bit_file() { echo "$work/out/chainbit.d/$(basename "$(bit_net "$1" "$2")" .net)_$(bit_row "$3").txt"; }
    # bit_partner NAME: the row a row is read over, at its own count of
    # images: for a row with 9 bits its own row with 8, fitted for a fitted
    # one, and for a fitted row with 8 bits its own row with training's
    # range, each of its draw.  With 8 bits and training's range the tile as
    # budgeted is read over the format alone of its draw, and the format
    # alone over the first draw's, which it is
    bit_partner() {
        local base=${1%, draw *} dd=${1##*, draw } n= core
        [ "${base%, a thousand}" = "$base" ] || n=", a thousand"
        core=${base%, a thousand}
        case "$core" in
        *", nine bits, fitted") echo "${core%, nine bits, fitted}, fitted$n, draw $dd" ;;
        *", nine bits") echo "${core%, nine bits}$n, draw $dd" ;;
        *", fitted") echo "${core%, fitted}$n, draw $dd" ;;
        "format only") echo "format only$n, draw ${draws%% *}" ;;
        *) echo "format only$n, draw $dd" ;;
        esac
    }
    # The rows with 8 bits are the modes' before this one: `chain`'s with
    # training's range, and `chainfit`'s fitted.  Where this directory has
    # what they wrote, each has to be that line, byte for byte.
    if [ -d "$work/out/chain.d" ] || [ -d "$work/out/chainfit.d" ]; then
        same=0
        other=0
        for k in before reference; do for sd in 1 2 3 4 5; do
            while IFS='|' read -r name setting; do
                case "$name" in *"nine bits"*) continue ;; *fitted*) was=chainfit.d ;; *) was=chain.d ;; esac
                was="$work/out/$was/$(basename "$(bit_file $sd $k "$name")")"
                [ -s "$was" ] || continue
                if cmp -s "$was" "$(bit_file $sd $k "$name")"; then same=$((same + 1)); else other=$((other + 1)); fi
            done < "$work/out/chainbit_settings.txt"
        done; done
        echo "== chainbit: against what chain and chainfit wrote for the same runs: $same the same, $other not"
        [ "$other" = 0 ] || exit 1
    fi
    # Every network has to be the kind its column says, and every run the row
    # its name says, as `chain` holds its own.  A run's name says its draw,
    # whether it is the format alone or the tile as budgeted, whether its
    # last converter has 8 bits or 9, whether its range is training's or
    # fitted, and whether it is of a thousand images or of all, which have to
    # be what it was asked and what its line printed.  A run with 8 bits
    # says nothing of its last converter's width, and one with 9 says 9.  A
    # run that is not fitted says nothing of a fit: its last shift is the
    # one the format alone of the first draw has, whatever its width, and is
    # its 8-bit shift too, since its noise is in that LSB.  A fitted run says
    # the share, 1, and the shift training's rule had given; its last shift
    # is the smallest at which the largest its declared reference is, is
    # within its converter's codes, 127 or 255, and its 8-bit shift the
    # smallest at which it is within 127: with 9 bits the noise is in the LSB
    # of the 8-bit converter of that range.  That largest is the one the
    # format alone of the first draw has, since neither a range nor a width
    # moves a reference.  The format alone, fitted, has no sum past its
    # range, and at training's step it has none wherever its reference is
    # within its converter's codes.  A fitted run with 8 bits whose shift is
    # the one it had is the run with training's range of its draw, figure for
    # figure.  A run with 9 bits at training's step has no more sums past its
    # range than the run with 8 of its draw, and where that one had none is
    # that run figure for figure.  And a fitted run with 9 bits
    # has a smaller shift than the fitted run with 8 of its draw, whose shift
    # is its 8-bit one.  The format alone, whatever its row, gets right on
    # every draw what its own row gets right on the first: with 9 bits that
    # need not be what it gets right with 8, where the 8 had sums past their
    # range.  No run is lit.
    bit_ok=yes
    bit_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(bit_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2 &&
                   v["hidden"] == 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 3 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || bit_ok=NO
        while IFS='|' read -r name setting; do
            first="format only"
            [ "${name%, a thousand, draw *}" = "$name" ] || first="format only, a thousand"
            cat "$log" "$(bit_file $sd $k "$first, draw ${draws%% *}")" \
                "$(bit_file $sd $k "${name%, draw *}, draw ${draws%% *}")" \
                "$(bit_file $sd $k "$(bit_partner "$name")")" "$(bit_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v sd="$sd" -v d0="${draws%% *}" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        few = (base ~ /, a thousand$/) ? 1 : 0
                        core = few ? substr(base, 1, length(base) - 12) : base
                        kind = 0; share = 0; nine = 0
                        if (core ~ /, nine bits, fitted$/) { kind = 1; share = 1; nine = 1; core = substr(core, 1, length(core) - 19) }
                        else if (core ~ /, nine bits$/) { nine = 1; core = substr(core, 1, length(core) - 11) }
                        else if (core ~ /, fitted$/) { kind = 1; share = 1; core = substr(core, 1, length(core) - 8) }
                        fmt = (core == "format only") ? 1 : 0
                        bud = (core == "as budgeted") ? 1 : 0
                        cyc = (core == "cycle") ? 1 : 0
                        noisy = (bud || cyc) ? 1 : 0
                        split(tile, tt, "x"); per = 16 * int((64 + tt[1] - 1) / tt[1])
                        sane = drawn && (fmt + bud + cyc == 1) && m == (fmt ? 1 : 5 + cyc) && ("quant" in on) &&
                               asked("abits") == 6 && asked("adcbits") == 8 && has("thermal8") == noisy &&
                               has("photons8") == noisy && has("prog") == noisy && has("xtalk") == noisy &&
                               (!noisy || (asked("thermal8") == 0.25 && asked("photons8") == 30 && asked("prog") == 1 &&
                                           asked("xtalk") == 0.02 && ("thermal" in on) && ("shot" in on) &&
                                           ("prog" in on) && ("xtalk" in on))) &&
                               (cyc == (("drift" in on) ? 1 : 0)) && has("drift") == cyc && (!cyc || want["drift"] == "tflt") &&
                               has("hours") == cyc && asked("hours") == 0.1 * cyc &&
                               has("calibrate") == cyc && asked("calibrate") == 16 * cyc &&
                               has("post-hours") == cyc && asked("post-hours") == 0.1 * cyc &&
                               has("trimstep") == cyc && asked("trimstep") == cyc && !has("trimmax") && !has("wbits") &&
                               !has("seed") && !has("src") && !has("srcline") && !has("srcflat") && !has("levelprobe") &&
                               has("host") && asked("host") == 2 && has("probe") && asked("probe") == 1 &&
                               has("gate") && asked("gate") == 1 && has("images") == few && asked("images") == 1000 * few &&
                               has("gatefit") == kind && (!kind || asked("gatefit") == share) &&
                               has("gatebits") == nine && (!nine || asked("gatebits") == 9) }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { right = v["correct"]; gref = v["gate_ref"]; split(v["S"], s0, ","); was = s0[3]; peak0 = v["gate_peak"]
                          theirs = ("gate_ref" in v) && v["impair"] == "0x01" && v["seed"] == sd + 10 * d0 && v["net_seed"] == sd &&
                                   v["images"] == (few ? 1000 : 10000) }
                NR == 3 { own = v["correct"] }
                NR == 4 { pright = v["correct"]; psats = v["sats"]; split(v["S"], ps, ",")
                          pfig = v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"] }
                NR == 5 { ns = split(v["S"], sh, ","); n8 = split(v["S8"], s8, ",")
                          ok = sane && theirs && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw &&
                               v["net_wbits"] == 6 && v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["hidden"] == 2 && ns == 3 && v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 &&
                               v["adcbits"] == 8 && v["wbits"] == 6 && v["drift"] == (cyc ? "tflt" : "none") &&
                               v["hours"] == 0.1 * cyc && (v["steps"] > 0) == cyc && v["cal"] == 16 * cyc &&
                               v["post_hours"] == 0.1 * cyc && near(v["trimstep"], cyc ? 1 : 0.25, 1e-12) &&
                               v["trimmax"] == 128 && v["images"] == (few ? 1000 : 10000) && ("host" in v) && v["host"] == 2 &&
                               !("src" in v) && !("levelprobe" in v) && !("hidshift" in v) && !("thermalline" in v) &&
                               ("gate_bits" in v) && v["gate_bits"] == 6 && ("gate_rms" in v) && v["gate_rms"] > 0 &&
                               v["gate_peak"] > 0 && v["gate8_peak"] > 0 && v["gate_rmsfs"] > 0 &&
                               v["gate_rmsfs"] + 0 <= v["gate_maxfs"] + 0 && v["gate8_rmsfs"] + 0 <= v["gate8_maxfs"] + 0 &&
                               ("e1" in v) && ("e2" in v) && v["e1"] == 0 && v["e2"] == 0 && v["e3"] > 0 &&
                               ("agree" in v) && ("ref" in v) && v["agree"] > 50 &&
                               ("sats" in v) && ("elements" in v) && v["elements"] == per * v["images"] &&
                               v["sats"] + 0 <= v["elements"] / 100 &&
                               ("gate_agree" in v) && ("gate_ref" in v) && v["gate_agree"] > 50 &&
                               v["gate_agree"] + 0 <= 100 && v["gate_ref"] == gref && v["gate_ref"] > 0 &&
                               v["gate_peak"] == peak0 && sh[1] == s0[1] && sh[2] == s0[2] && n8 == 3 &&
                               (("gate_adcbits" in v) ? 1 : 0) == nine && (!nine || v["gate_adcbits"] == 9)
                          fig = v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"]
                          if (kind == 0) { ok = ok && !("gate_fit" in v) && !("gate_was" in v) && sh[3] == was && s8[3] == sh[3]
                                           if (fmt && int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= (nine ? 255 : 127)) ok = ok && v["sats"] == 0
                                           if (nine) ok = ok && v["sats"] + 0 <= psats + 0
                                           if (nine && psats == 0) ok = ok && v["correct"] == pright && v["sats"] == 0 && pfig == fig }
                          else { lim = nine ? 255 : 127
                                 ok = ok && ("gate_fit" in v) && v["gate_fit"] == share && ("gate_was" in v) && v["gate_was"] == was &&
                                      int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= lim &&
                                      (sh[3] == 0 || int(v["gate_peak"] / 2 ^ (sh[3] - 1) + 0.5) > lim) &&
                                      int(v["gate_peak"] / 2 ^ s8[3] + 0.5) <= 127 &&
                                      (s8[3] == 0 || int(v["gate_peak"] / 2 ^ (s8[3] - 1) + 0.5) > 127)
                                 if (fmt) ok = ok && v["sats"] == 0
                                 if (!nine) ok = ok && s8[3] == sh[3]
                                 if (!nine && sh[3] == was) ok = ok && v["correct"] == pright && v["sats"] == psats && pfig == fig
                                 if (nine) ok = ok && sh[3] < ps[3] && s8[3] == ps[3] }
                          if (noisy) ok = ok && near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                                          near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0
                          else ok = ok && v["thermal8"] == 0 && v["photons8"] == 0 && v["prog"] == 0 && v["xtalk"] == 0 &&
                                    v["correct"] == own && (kind > 0 || nine || own == right) }
                END { exit !(NR == 5 && ok) }' || bit_ok=NO
            bit_runs=$((bit_runs + 1))
        done < "$work/out/chainbit_settings.txt"
    done; done
    echo "== chainbit: $bit_runs runs, each of them the network and the row its place says: $bit_ok"
    [ "$bit_ok" = yes ] || exit 1

    # bit_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    bit_stat() {
        local sd partner
        partner=$(bit_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(bit_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(bit_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # bit_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    bit_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(bit_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(bit_file $sd "$1" "$2, draw $dd")"
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
    # bit_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    bit_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(bit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd) }'
        # the row it is read over is its partner on its own draw, but for a
        # format-only row, whose partner is one row for all of them
        if [ "$2" = "format only" ] || [ "$2" = "format only, a thousand" ]; then
            local first=${draws%% *} sd2 dd2
            for sd2 in 1 2 3 4 5; do
                for dd2 in $draws; do
                    sed "s/^/A $sd2 $dd2 /" "$(bit_file $sd2 "$1" "$2, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(bit_file $sd2 "$1" "$2, draw $dd2")"
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
            p=$(bit_partner "$2, draw 0")
            bit_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # bit_agree KIND BASE FIELD: a row over its draws: how often the class
    # the tile gives is the class the host gives (agree) or the class its
    # declared reference gives (gate_agree), percent: the mean, its standard
    # error from the five networks each averaged over its draws, and the
    # draws' standard deviation; the least of any run; and of the runs, how
    # many agree on 99.5% or more
    bit_agree() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(bit_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v fld="$3" '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v[fld] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++
              if (runs == 0 || x < least) least = x
              runs++; pass += (x >= 99.5) }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f %7.2f %3d of %2d", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd), least, pass, runs }'
    }
    # bit_declared KIND BASE: how often the declared reference is right in
    # a row, percent, a mean over its runs: what its own format leaves the
    # network, before any tile
    bit_declared() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(bit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              s += v["gate_ref"]; runs++ }
            END { printf " %7.3f", s / runs }'
    }
    # bit_gate KIND BASE RMS RMSFS MAXFS: a row over its runs, against one
    # reference: the last layer's rms error over the reference's rms, over
    # the largest the reference is, and its largest error over that, percent:
    # a mean, and for the third the most of any run; and of the runs, how
    # many are within 1.0% on the first, 1.0% on the second and 2.0% on the
    # third
    bit_gate() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(bit_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v a="$3" -v b="$4" -v c="$5" '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = 100 * v[a]; y = 100 * v[b]; z = 100 * v[c]
              xs += x; ys += y; zs += z; if (z > most) most = z
              px += (x <= 1.0); py += (y <= 1.0); pz += (z <= 2.0); runs++ }
            END { printf " %7.3f %6.3f %6.3f %6.3f %3d %2d %2d", xs / runs, ys / runs, zs / runs, most, px, py, pz }'
    }
    # bit_range KIND BASE: a row over its runs, and the converter's range,
    # which the harness sets on a thousand training images to pass all but one
    # sum in ten thousand: the runs with a sum past it, the most sums past it
    # in a run, and of how many; and the most the largest error against the
    # declared format is, percent of the largest the reference is, in the runs
    # with none past it and in the runs with some.  Nothing where there is no
    # such run.  And the runs whose step is not the one training's rule
    # gave, and by how many bits it is larger at the most, and smaller
    bit_range() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(bit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              z = 100 * v["gate_maxfs"]; s = v["sats"] + 0; runs++; of = v["elements"] + 0
              if (s > 0) { past++; if (s > most) most = s; if (z > clipped) clipped = z }
              else if (z > whole) whole = z
              if ("gate_was" in v) { split(v["S"], sh, ","); more = sh[3] - v["gate_was"]
                                     if (more != 0) moved++; if (more > bits) bits = more; if (-more > less) less = -more } }
            END { printf " %5d of %2d %5d of %6d %7.3f %7.3f %3d %2d %2d", past, runs, most, of, whole, clipped, moved, bits, less }'
    }
    echo "== chainbit: the $tile tile at v2, the last layer of three on it, five networks, mean and"
    echo "== standard error.  How often right, percent, and what a row adds over the row it is"
    echo "== read over, network by network: for a row with nine bits its own row with eight, at"
    echo "== the same range, and for a fitted row with eight its own row with training's range"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do bit_stat $k "$name"; done
        echo
    done < "$work/out/chainbit_settings.txt"
    echo "== chainbit: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainbit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do bit_over $k "$base"; done
        echo
    done
    echo "== chainbit: the class the tile gives against the class the host gives, percent, a row over"
    echo "== its draws: the mean, its standard error from five networks, the draws' standard"
    echo "== deviation, the least of any run, and the runs that agree on 99.5% or more"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainbit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do bit_agree $k "$base" agree; done
        echo
    done
    echo "== chainbit: the class the tile gives against the class its declared reference gives,"
    echo "== percent, a row over its draws: the same five; and how often that reference is"
    echo "== right, a mean over the runs"
    printf '%-84s %48s %48s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainbit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do bit_agree $k "$base" gate_agree; bit_declared $k "$base"; done
        echo
    done
    for ref in "its declared format|gate_rms gate_rmsfs gate_maxfs" "its operands as they were given|e3 gate8_rmsfs gate8_maxfs"; do
        echo "== chainbit: the last layer's error against ${ref%|*}, percent, a row over its"
        echo "== runs: its rms over the reference's rms, over the largest the reference is, and its"
        echo "== largest over that, a mean; the most the third is in any run; and the runs within"
        echo "== 1.0% on the first, 1.0% on the second and 2.0% on the third"
        printf '%-84s %40s %40s' "" "before" "reference"
        echo
        sed 's/, draw [0-9]*|.*//' "$work/out/chainbit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
            printf '%-84s' "$base"
            for k in before reference; do bit_gate $k "$base" ${ref#*|}; done
            echo
        done
    done
    echo "== chainbit: the converter's range, a row over its runs: the runs with a sum past it, the"
    echo "== most sums past it in a run, and of how many; and the most the largest error against"
    echo "== the declared format is, percent of the largest the reference is, in the runs with"
    echo "== none past it and in the runs with some; and the runs whose step is not the one"
    echo "== training's rule gave, and by how many bits it is larger at the most, and smaller"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainbit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do bit_range $k "$base"; done
        echo
    done
fi

# `chainlit`: `chain`'s last layer, with a light source switched on.  Every
# run of that layer so far had the tile's own noise and no source: the
# harness would not light a tile that had only some of a network's layers.
# It now does, and a source lights the tile's layers alone.  This runs the
# source as grxcp holds it (its B16): its noise within 1% rms a shot for the
# lines together and 5% for a line on its own, and its lines level to 20%,
# read with the level probe at sixteen shots a row and corrected on the
# weights, written at 8 bits.  The same networks as `chain`, on 8 bits (its
# B14), ten rows on each of five draws: the format alone and the tile as
# budgeted, which are `chain`'s own runs; the tile as budgeted with its range
# fitted, which is `chainfit`'s; the tile as budgeted with each of the
# source's rows alone, the lines' level twice, left alone and read; with all
# three, which is the source; that with the range fitted; and the format
# alone with the source, which is the source's share with no noise of the
# tile's under it.  On 10,000 images and on the first thousand.  A lit row
# is read over its own row with no source, at the same range and of its
# draw.  The light's share is added after the converter, as the harness has
# it: it is neither rounded nor held at the range.  Both kinds of network,
# row for row.
if [ "$what" = chainlit ]; then
    tile=${CHAINLIT_TILE:-128x64}
    draws=${CHAINLIT_DRAWS:-0 1 2 3 4}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    r="--abits 6 --adcbits 8 --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    f="--impair quant --abits 6 --adcbits 8"
    b="--impair $all $r"
    t="--host 2 --probe 1 --gate 1"
    # the source's three rows, as grxcp's B16 has them, on B10's two buses
    shared=0.01
    own=0.05
    level=0.2
    buses=2
    src="--src $shared --srcline $own --srcflat $level --buses $buses"
    fix="--levelprobe 16 --levelfix weights8"
    # row|options.  Every row's name ends in its draw.  A row is the format
    # alone or the tile as budgeted; with no source, with one of its rows, or
    # with all three; at the range training's rule gives or fitted; on all
    # the images or on a thousand
    for dd in $draws; do
        for n in "" ", a thousand"; do
            i=
            [ -z "$n" ] || i=" --images 1000"
            echo "format only$n, draw $dd|$f$i"
            echo "as budgeted$n, draw $dd|$b$i"
            echo "as budgeted, fitted$n, draw $dd|$b$i --gatefit 1"
            echo "format only, lit$n, draw $dd|$f$i $src $fix"
            echo "as budgeted, lit: shared$n, draw $dd|$b$i --src $shared"
            echo "as budgeted, lit: a line$n, draw $dd|$b$i --srcline $own --buses $buses"
            echo "as budgeted, lit: level, left$n, draw $dd|$b$i --srcflat $level --buses $buses"
            echo "as budgeted, lit: level$n, draw $dd|$b$i --srcflat $level --buses $buses $fix"
            echo "as budgeted, lit$n, draw $dd|$b$i $src $fix"
            echo "as budgeted, lit, fitted$n, draw $dd|$b$i $src $fix --gatefit 1"
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ $t/" > "$work/out/chainlit_settings.txt"
    # lit_train WBITS SEED [FROM]: a DIN_W 8 network of two hidden layers,
    # unless it is already there, starting from the same seed's at FROM bits
    lit_train() {
        local net="$PTA_WORK/nets/h2_d8_b$1_s$2.net" from=()
        [ $# -lt 3 ] || from=(--from "$PTA_WORK/nets/h2_d8_b$3_s$2.net")
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits "$1" \
            --seed "$2" --hidden 2 "${from[@]}" --out "$net" > "$net.log"
    }
    # lit_ref SEED: that seed's reference network, the header's recipe at
    # this shape
    lit_ref() {
        local net="$PTA_WORK/nets/h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
            --seed "$1" --hidden 2 --from "$PTA_WORK/nets/h2_d8_b8_s$1.net" \
            --sumnoise "$PTA_REF_NOISE" --epochs "$PTA_REF_EPOCHS" --out "$net" > "$net.log"
    }
    # lit_one NET ROW ARGS...: one test-set pass, its line to
    # out/chainlit.d/NET_ROW.txt
    lit_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/chainlit.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/chainlit.d/$(basename "$net" .net)_$row.txt"
    }
    export -f lit_train lit_ref lit_one
    # lit_row NAME: a row's name as a file's
    lit_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # lit_net SEED KIND: the network's file, trained before or the reference
    lit_net() {
        if [ "$2" = before ]; then echo "h2_d8_b6_s$1.net"
        else echo "h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; fi
    }
    for s in 1 2 3 4 5; do echo 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'lit_train "$@"' _
    for s in 1 2 3 4 5; do echo 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'lit_train "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'lit_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(lit_net $sd $k) $(lit_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/chainlit_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'lit_one "$@"' _

    # lit_file SEED KIND NAME: the file lit_one wrote for that run
    lit_file() { echo "$work/out/chainlit.d/$(basename "$(lit_net "$1" "$2")" .net)_$(lit_row "$3").txt"; }
    # lit_partner NAME: the row a row is read over, at its own count of
    # images: for a lit row its own row with no source, at the same range,
    # and for the fitted row with no source the row with training's range,
    # each of its draw.  The tile as budgeted is read over the format alone
    # of its draw, and the format alone over the first draw's, which it is
    lit_partner() {
        local base=${1%, draw *} dd=${1##*, draw } n= core
        [ "${base%, a thousand}" = "$base" ] || n=", a thousand"
        core=${base%, a thousand}
        case "$core" in
        "as budgeted, lit, fitted") echo "as budgeted, fitted$n, draw $dd" ;;
        "as budgeted, lit"*) echo "as budgeted$n, draw $dd" ;;
        "format only, lit") echo "format only$n, draw $dd" ;;
        "as budgeted, fitted") echo "as budgeted$n, draw $dd" ;;
        "format only") echo "format only$n, draw ${draws%% *}" ;;
        *) echo "format only$n, draw $dd" ;;
        esac
    }
    # The rows with no source are the modes' before this one: `chain`'s with
    # training's range, and `chainfit`'s fitted.  Where this directory has
    # what they wrote, each has to be that line, byte for byte.
    if [ -d "$work/out/chain.d" ] || [ -d "$work/out/chainfit.d" ]; then
        same=0
        other=0
        for k in before reference; do for sd in 1 2 3 4 5; do
            while IFS='|' read -r name setting; do
                case "$name" in *lit*) continue ;; *fitted*) was=chainfit.d ;; *) was=chain.d ;; esac
                was="$work/out/$was/$(basename "$(lit_file $sd $k "$name")")"
                [ -s "$was" ] || continue
                if cmp -s "$was" "$(lit_file $sd $k "$name")"; then same=$((same + 1)); else other=$((other + 1)); fi
            done < "$work/out/chainlit_settings.txt"
        done; done
        echo "== chainlit: against what chain and chainfit wrote for the same runs: $same the same, $other not"
        [ "$other" = 0 ] || exit 1
    fi
    # Every network has to be the kind its column says, and every run the row
    # its name says, as `chain` holds its own.  A run's name says its draw,
    # whether it is the format alone or the tile as budgeted, which of the
    # source's rows are lit, whether its range is training's or fitted, and
    # whether it is of a thousand images or of all, which have to be what it
    # was asked and what its line printed.  A run with no source says nothing
    # of one.  A lit run says its three rows, each what the row's name lights
    # and nought for the others, its buses, and that a weight is read through
    # a pair.  Where the lines are read it says the probe's sixteen shots,
    # what the lines were, within a half of the 20% they were drawn at, and
    # what the reading leaves, under a quarter of that; that the reading went
    # on the weights at 8 bits, with nothing scaled to the dimmest line; and
    # its weights are 8 bits wide where every other run's are 6.  A lit run's
    # range is its row with no source's, shift for shift.  Where no weight is
    # rewritten it has that run's sums past its range, as many: the light's
    # share is added after the converter.  And it is not that run: its error
    # and its class are not that run's, figure for figure, since a source is
    # lit.  A fitted run says the share, 1,
    # and the shift training's rule had given; its last shift is the smallest
    # at which the largest its declared reference is, is within 127 codes,
    # and is its 8-bit shift.  That largest is the one the format alone of
    # the first draw has: neither a range nor a light moves a reference.  The
    # format alone with no source has no sum past its range wherever its
    # reference is within its codes, and gets right on every draw what it
    # gets right on the first.  A fitted run with no source whose shift is
    # the one it had is the run with training's range of its draw, figure for
    # figure.
    lit_ok=yes
    lit_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(lit_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2 &&
                   v["hidden"] == 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 3 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || lit_ok=NO
        while IFS='|' read -r name setting; do
            first="format only"
            [ "${name%, a thousand, draw *}" = "$name" ] || first="format only, a thousand"
            cat "$log" "$(lit_file $sd $k "$first, draw ${draws%% *}")" \
                "$(lit_file $sd $k "${name%, draw *}, draw ${draws%% *}")" \
                "$(lit_file $sd $k "$(lit_partner "$name")")" "$(lit_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v sd="$sd" -v d0="${draws%% *}" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        few = (base ~ /, a thousand$/) ? 1 : 0
                        core = few ? substr(base, 1, length(base) - 12) : base
                        kind = 0; share = 0; lit = 0; part = ""
                        if (core ~ /, lit, fitted$/) { kind = 1; share = 1; lit = 1; core = substr(core, 1, length(core) - 13) }
                        else if (core ~ /, lit: shared$/) { lit = 1; part = "shared"; core = substr(core, 1, length(core) - 13) }
                        else if (core ~ /, lit: a line$/) { lit = 1; part = "line"; core = substr(core, 1, length(core) - 13) }
                        else if (core ~ /, lit: level, left$/) { lit = 1; part = "left"; core = substr(core, 1, length(core) - 18) }
                        else if (core ~ /, lit: level$/) { lit = 1; part = "level"; core = substr(core, 1, length(core) - 12) }
                        else if (core ~ /, lit$/) { lit = 1; core = substr(core, 1, length(core) - 5) }
                        else if (core ~ /, fitted$/) { kind = 1; share = 1; core = substr(core, 1, length(core) - 8) }
                        all = (lit && (part == "" || part == "shared")) ? 0.01 : 0
                        line = (lit && (part == "" || part == "line")) ? 0.05 : 0
                        flat = (lit && (part == "" || part == "left" || part == "level")) ? 0.2 : 0
                        bus = (line > 0 || flat > 0) ? 2 : 1
                        read = (lit && (part == "" || part == "level")) ? 1 : 0
                        fmt = (core == "format only") ? 1 : 0
                        bud = (core == "as budgeted") ? 1 : 0
                        cyc = (core == "cycle") ? 1 : 0
                        noisy = (bud || cyc) ? 1 : 0
                        split(tile, tt, "x"); per = 16 * int((64 + tt[1] - 1) / tt[1])
                        sane = drawn && (fmt + bud + cyc == 1) && m == (fmt ? 1 : 5 + cyc) && ("quant" in on) &&
                               asked("abits") == 6 && asked("adcbits") == 8 && has("thermal8") == noisy &&
                               has("photons8") == noisy && has("prog") == noisy && has("xtalk") == noisy &&
                               (!noisy || (asked("thermal8") == 0.25 && asked("photons8") == 30 && asked("prog") == 1 &&
                                           asked("xtalk") == 0.02 && ("thermal" in on) && ("shot" in on) &&
                                           ("prog" in on) && ("xtalk" in on))) &&
                               (cyc == (("drift" in on) ? 1 : 0)) && has("drift") == cyc && (!cyc || want["drift"] == "tflt") &&
                               has("hours") == cyc && asked("hours") == 0.1 * cyc &&
                               has("calibrate") == cyc && asked("calibrate") == 16 * cyc &&
                               has("post-hours") == cyc && asked("post-hours") == 0.1 * cyc &&
                               has("trimstep") == cyc && asked("trimstep") == cyc && !has("trimmax") && !has("wbits") &&
                               !has("seed") && has("src") == (all > 0) && asked("src") == all &&
                               has("srcline") == (line > 0) && asked("srcline") == line &&
                               has("srcflat") == (flat > 0) && asked("srcflat") == flat &&
                               has("buses") == (bus > 1) && (bus == 1 || asked("buses") == bus) &&
                               has("levelprobe") == read && asked("levelprobe") == 16 * read &&
                               has("levelfix") == read && (!read || want["levelfix"] == "weights8") &&
                               !has("srcsign") && !has("levelref") && !has("levelpart") && !has("levellayer") &&
                               has("host") && asked("host") == 2 && has("probe") && asked("probe") == 1 &&
                               has("gate") && asked("gate") == 1 && has("images") == few && asked("images") == 1000 * few &&
                               has("gatefit") == kind && (!kind || asked("gatefit") == share) && !has("gatebits") }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { right = v["correct"]; gref = v["gate_ref"]; split(v["S"], s0, ","); was = s0[3]; peak0 = v["gate_peak"]
                          theirs = ("gate_ref" in v) && v["impair"] == "0x01" && v["seed"] == sd + 10 * d0 && v["net_seed"] == sd &&
                                   v["images"] == (few ? 1000 : 10000) }
                NR == 3 { own = v["correct"] }
                NR == 4 { pright = v["correct"]; psats = v["sats"]; split(v["S"], ps, ","); split(v["S8"], ps8, ",")
                          pfig = v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"] }
                NR == 5 { ns = split(v["S"], sh, ","); n8 = split(v["S8"], s8, ",")
                          ok = sane && theirs && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw &&
                               v["net_wbits"] == 6 && v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["hidden"] == 2 && ns == 3 && v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 &&
                               v["adcbits"] == 8 && v["wbits"] == (read ? 8 : 6) && v["drift"] == (cyc ? "tflt" : "none") &&
                               v["hours"] == 0.1 * cyc && (v["steps"] > 0) == cyc && v["cal"] == 16 * cyc &&
                               v["post_hours"] == 0.1 * cyc && near(v["trimstep"], cyc ? 1 : 0.25, 1e-12) &&
                               v["trimmax"] == 128 && v["images"] == (few ? 1000 : 10000) && ("host" in v) && v["host"] == 2 &&
                               (("src" in v) ? 1 : 0) == lit && (("levelprobe" in v) ? 1 : 0) == read &&
                               (("levelfix" in v) ? 1 : 0) == read && !("levelpart" in v) &&
                               !("hidshift" in v) && !("thermalline" in v) && !("gate_adcbits" in v) &&
                               ("gate_bits" in v) && v["gate_bits"] == 6 && ("gate_rms" in v) && v["gate_rms"] > 0 &&
                               v["gate_peak"] > 0 && v["gate8_peak"] > 0 && v["gate_rmsfs"] > 0 &&
                               v["gate_rmsfs"] + 0 <= v["gate_maxfs"] + 0 && v["gate8_rmsfs"] + 0 <= v["gate8_maxfs"] + 0 &&
                               ("e1" in v) && ("e2" in v) && v["e1"] == 0 && v["e2"] == 0 && v["e3"] > 0 &&
                               ("agree" in v) && ("ref" in v) && v["agree"] > 50 &&
                               ("sats" in v) && ("elements" in v) && v["elements"] == per * v["images"] &&
                               v["sats"] + 0 <= v["elements"] / 100 &&
                               ("gate_agree" in v) && ("gate_ref" in v) && v["gate_agree"] > 50 &&
                               v["gate_agree"] + 0 <= 100 && v["gate_ref"] == gref && v["gate_ref"] > 0 &&
                               v["gate_peak"] == peak0 && sh[1] == s0[1] && sh[2] == s0[2] && n8 == 3
                          if (lit) ok = ok && v["src"] == all && v["srcline"] == line && v["srcflat"] == flat &&
                                         v["buses"] == bus && v["srcsign"] == "pair" && sh[3] == ps[3] && s8[3] == ps8[3]
                          if (lit && !read) ok = ok && v["sats"] == psats
                          if (lit) ok = ok && pfig != v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"]
                          if (read) ok = ok && v["levelprobe"] == 16 && near(v["level_found"], 0.2, 0.1) &&
                                          v["level_left"] > 0 && v["level_left"] + 0 < v["level_found"] / 4 &&
                                          v["levelfix"] == "weights8" && v["levelref"] == "none" && v["level_gain"] == 1 &&
                                          v["level_clip"] >= 0 && v["level_clip"] < 0.5
                          fig = v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"]
                          if (kind == 0) { ok = ok && !("gate_fit" in v) && !("gate_was" in v) && sh[3] == was && s8[3] == sh[3]
                                           if (fmt && !lit && int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= 127) ok = ok && v["sats"] == 0 }
                          else { ok = ok && ("gate_fit" in v) && v["gate_fit"] == share && ("gate_was" in v) && v["gate_was"] == was &&
                                      int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= 127 &&
                                      (sh[3] == 0 || int(v["gate_peak"] / 2 ^ (sh[3] - 1) + 0.5) > 127) && s8[3] == sh[3]
                                 if (!lit && sh[3] == was) ok = ok && v["correct"] == pright && v["sats"] == psats && pfig == fig }
                          if (noisy) ok = ok && near(v["thermal8"], 0.25, 1e-6) && near(v["photons8"] / 30, 1, 0.03) &&
                                          near(v["prog"], 1, 1e-9) && near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0
                          else ok = ok && v["thermal8"] == 0 && v["photons8"] == 0 && v["prog"] == 0 && v["xtalk"] == 0 &&
                                    (lit || (v["correct"] == own && (kind > 0 || own == right))) }
                END { exit !(NR == 5 && ok) }' || lit_ok=NO
            lit_runs=$((lit_runs + 1))
        done < "$work/out/chainlit_settings.txt"
    done; done
    echo "== chainlit: $lit_runs runs, each of them the network and the row its place says: $lit_ok"
    [ "$lit_ok" = yes ] || exit 1

    # lit_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    lit_stat() {
        local sd partner
        partner=$(lit_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(lit_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(lit_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # lit_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    lit_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(lit_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(lit_file $sd "$1" "$2, draw $dd")"
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
    # lit_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    lit_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(lit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd) }'
        # the row it is read over is its partner on its own draw, but for a
        # format-only row, whose partner is one row for all of them
        if [ "$2" = "format only" ] || [ "$2" = "format only, a thousand" ]; then
            local first=${draws%% *} sd2 dd2
            for sd2 in 1 2 3 4 5; do
                for dd2 in $draws; do
                    sed "s/^/A $sd2 $dd2 /" "$(lit_file $sd2 "$1" "$2, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(lit_file $sd2 "$1" "$2, draw $dd2")"
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
            p=$(lit_partner "$2, draw 0")
            lit_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # lit_agree KIND BASE FIELD: a row over its draws: how often the class
    # the tile gives is the class the host gives (agree) or the class its
    # declared reference gives (gate_agree), percent: the mean, its standard
    # error from the five networks each averaged over its draws, and the
    # draws' standard deviation; the least of any run; and of the runs, how
    # many agree on 99.5% or more
    lit_agree() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(lit_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v fld="$3" '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v[fld] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++
              if (runs == 0 || x < least) least = x
              runs++; pass += (x >= 99.5) }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f %7.2f %3d of %2d", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd), least, pass, runs }'
    }
    # lit_declared KIND BASE: how often the declared reference is right in
    # a row, percent, a mean over its runs: what its own format leaves the
    # network, before any tile
    lit_declared() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(lit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              s += v["gate_ref"]; runs++ }
            END { printf " %7.3f", s / runs }'
    }
    # lit_gate KIND BASE RMS RMSFS MAXFS: a row over its runs, against one
    # reference: the last layer's rms error over the reference's rms, over
    # the largest the reference is, and its largest error over that, percent:
    # a mean, and for the third the most of any run; and of the runs, how
    # many are within 1.0% on the first, 1.0% on the second and 2.0% on the
    # third
    lit_gate() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(lit_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v a="$3" -v b="$4" -v c="$5" '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = 100 * v[a]; y = 100 * v[b]; z = 100 * v[c]
              xs += x; ys += y; zs += z; if (z > most) most = z
              px += (x <= 1.0); py += (y <= 1.0); pz += (z <= 2.0); runs++ }
            END { printf " %7.3f %6.3f %6.3f %6.3f %3d %2d %2d", xs / runs, ys / runs, zs / runs, most, px, py, pz }'
    }
    # lit_range KIND BASE: a row over its runs, and the converter's range,
    # which the harness sets on a thousand training images to pass all but one
    # sum in ten thousand: the runs with a sum past it, the most sums past it
    # in a run, and of how many; and the most the largest error against the
    # declared format is, percent of the largest the reference is, in the runs
    # with none past it and in the runs with some.  Nothing where there is no
    # such run.  And the runs whose step is not the one training's rule
    # gave, and by how many bits it is larger at the most, and smaller
    lit_range() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(lit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              z = 100 * v["gate_maxfs"]; s = v["sats"] + 0; runs++; of = v["elements"] + 0
              if (s > 0) { past++; if (s > most) most = s; if (z > clipped) clipped = z }
              else if (z > whole) whole = z
              if ("gate_was" in v) { split(v["S"], sh, ","); more = sh[3] - v["gate_was"]
                                     if (more != 0) moved++; if (more > bits) bits = more; if (-more > less) less = -more } }
            END { printf " %5d of %2d %5d of %6d %7.3f %7.3f %3d %2d %2d", past, runs, most, of, whole, clipped, moved, bits, less }'
    }
    # lit_lines KIND BASE: a row over its runs, and the source's lines: the
    # runs that read them; what the lines were, rms, and what the reading
    # leaves, each a mean over those runs; the runs that put the reading on
    # the weights; and of the weights it scaled, the share the rail held
    # back, a mean over those runs and the most of any
    lit_lines() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(lit_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              runs++
              if ("levelprobe" in v) { f += v["level_found"]; l += v["level_left"]; n++ }
              if ("levelfix" in v) { c = v["level_clip"] + 0; cs += c; if (c > cm) cm = c; m++ } }
            END { printf " %3d of %2d %6.4f %6.4f %3d of %2d %7.5f %7.5f", n, runs, n ? f / n : 0, n ? l / n : 0,
                         m, runs, m ? cs / m : 0, cm }'
    }
    echo "== chainlit: the $tile tile at v2, the last layer of three on it, five networks, mean and"
    echo "== standard error.  How often right, percent, and what a row adds over the row it is"
    echo "== read over, network by network: for a lit row its own row with no source, at the"
    echo "== same range, and for the fitted row with no source the row with training's range"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do lit_stat $k "$name"; done
        echo
    done < "$work/out/chainlit_settings.txt"
    echo "== chainlit: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainlit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do lit_over $k "$base"; done
        echo
    done
    echo "== chainlit: the class the tile gives against the class the host gives, percent, a row over"
    echo "== its draws: the mean, its standard error from five networks, the draws' standard"
    echo "== deviation, the least of any run, and the runs that agree on 99.5% or more"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainlit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do lit_agree $k "$base" agree; done
        echo
    done
    echo "== chainlit: the class the tile gives against the class its declared reference gives,"
    echo "== percent, a row over its draws: the same five; and how often that reference is"
    echo "== right, a mean over the runs"
    printf '%-84s %48s %48s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainlit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do lit_agree $k "$base" gate_agree; lit_declared $k "$base"; done
        echo
    done
    for ref in "its declared format|gate_rms gate_rmsfs gate_maxfs" "its operands as they were given|e3 gate8_rmsfs gate8_maxfs"; do
        echo "== chainlit: the last layer's error against ${ref%|*}, percent, a row over its"
        echo "== runs: its rms over the reference's rms, over the largest the reference is, and its"
        echo "== largest over that, a mean; the most the third is in any run; and the runs within"
        echo "== 1.0% on the first, 1.0% on the second and 2.0% on the third"
        printf '%-84s %40s %40s' "" "before" "reference"
        echo
        sed 's/, draw [0-9]*|.*//' "$work/out/chainlit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
            printf '%-84s' "$base"
            for k in before reference; do lit_gate $k "$base" ${ref#*|}; done
            echo
        done
    done
    echo "== chainlit: the converter's range, a row over its runs: the runs with a sum past it, the"
    echo "== most sums past it in a run, and of how many; and the most the largest error against"
    echo "== the declared format is, percent of the largest the reference is, in the runs with"
    echo "== none past it and in the runs with some; and the runs whose step is not the one"
    echo "== training's rule gave, and by how many bits it is larger at the most, and smaller"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainlit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do lit_range $k "$base"; done
        echo
    done
    echo "== chainlit: the source's lines, a row over its runs: the runs that read them; what the"
    echo "== lines were, rms, and what the reading leaves, a mean; the runs that put it on the"
    echo "== weights; and of the weights scaled, the share the rail held back, a mean and the most"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainlit_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do lit_lines $k "$base"; done
        echo
    done
fi

# `chainrows`: `chain`'s last layer, with the tile's budget a row at a time.
# Four modes have moved that layer's error by a quarter at the most, with a
# range, a bit and a source, and none has said what the error is made of.
# Against its declared format a tile at grxcp's version 2 is off by the
# converter's rounding and by four rows of the budget: the receiver's noise,
# 0.25 of an LSB; the shot noise of 30 photons an LSB; a programming error
# of an LSB of an 8-bit weight; and 2% of crosstalk.  This runs each of the
# four alone over the format, each left out of the tile as budgeted, and the
# shot noise and the crosstalk left out together.  And all of it again with
# the source lit as `chainlit` lit it, since what a source adds was found
# there to depend on what it is added to.  The same networks as `chain`, on
# five draws and 10,000 images, eleven rows with no source and eleven with
# it; four of the twenty-two are `chain`'s and `chainlit`'s own runs.  A row
# with one row of the budget alone is read over the format alone, one with
# a row left out over the tile as budgeted, and a lit row over its own row
# with no source, each of its draw.  Both kinds of network, row for row.
if [ "$what" = chainrows ]; then
    tile=${CHAINROWS_TILE:-128x64}
    draws=${CHAINROWS_DRAWS:-0 1 2 3 4}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    # the tile's format, and the four rows of version 2's budget that add to it
    q="--abits 6 --adcbits 8"
    th="--thermal8 0.25"
    ph="--photons8 30"
    pg="--prog 1"
    xk="--xtalk 0.02"
    r="$q $th $ph $pg $xk"
    f="--impair quant $q"
    b="--impair $all $r"
    t="--host 2 --probe 1 --gate 1"
    # the source's three rows, as grxcp's B16 has them, on B10's two buses
    shared=0.01
    own=0.05
    level=0.2
    buses=2
    src="--src $shared --srcline $own --srcflat $level --buses $buses"
    fix="--levelprobe 16 --levelfix weights8"
    # row|options.  Every row's name ends in its draw.  A row is the format
    # alone, the format and one row of the budget, the tile as budgeted, or
    # that with one row left out, or two; with no source or with it
    for dd in $draws; do
        for x in "|" ", lit| $src $fix"; do
            echo "format only${x%|*}, draw $dd|$f${x#*|}"
            echo "only thermal${x%|*}, draw $dd|--impair quant,thermal $q $th${x#*|}"
            echo "only shot${x%|*}, draw $dd|--impair quant,shot $q $ph${x#*|}"
            echo "only prog${x%|*}, draw $dd|--impair quant,prog $q $pg${x#*|}"
            echo "only xtalk${x%|*}, draw $dd|--impair quant,xtalk $q $xk${x#*|}"
            echo "less thermal${x%|*}, draw $dd|--impair quant,shot,prog,xtalk $q $ph $pg $xk${x#*|}"
            echo "less shot${x%|*}, draw $dd|--impair quant,thermal,prog,xtalk $q $th $pg $xk${x#*|}"
            echo "less prog${x%|*}, draw $dd|--impair quant,thermal,shot,xtalk $q $th $ph $xk${x#*|}"
            echo "less xtalk${x%|*}, draw $dd|--impair quant,thermal,shot,prog $q $th $ph $pg${x#*|}"
            echo "less shot, xtalk${x%|*}, draw $dd|--impair quant,thermal,prog $q $th $pg${x#*|}"
            echo "as budgeted${x%|*}, draw $dd|$b${x#*|}"
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ $t/" > "$work/out/chainrows_settings.txt"
    # row_train WBITS SEED [FROM]: a DIN_W 8 network of two hidden layers,
    # unless it is already there, starting from the same seed's at FROM bits
    row_train() {
        local net="$PTA_WORK/nets/h2_d8_b$1_s$2.net" from=()
        [ $# -lt 3 ] || from=(--from "$PTA_WORK/nets/h2_d8_b$3_s$2.net")
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits "$1" \
            --seed "$2" --hidden 2 "${from[@]}" --out "$net" > "$net.log"
    }
    # row_ref SEED: that seed's reference network, the header's recipe at
    # this shape
    row_ref() {
        local net="$PTA_WORK/nets/h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
            --seed "$1" --hidden 2 --from "$PTA_WORK/nets/h2_d8_b8_s$1.net" \
            --sumnoise "$PTA_REF_NOISE" --epochs "$PTA_REF_EPOCHS" --out "$net" > "$net.log"
    }
    # row_one NET ROW ARGS...: one test-set pass, its line to
    # out/chainrows.d/NET_ROW.txt
    row_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/chainrows.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/chainrows.d/$(basename "$net" .net)_$row.txt"
    }
    export -f row_train row_ref row_one
    # row_row NAME: a row's name as a file's
    row_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # row_net SEED KIND: the network's file, trained before or the reference
    row_net() {
        if [ "$2" = before ]; then echo "h2_d8_b6_s$1.net"
        else echo "h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; fi
    }
    for s in 1 2 3 4 5; do echo 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'row_train "$@"' _
    for s in 1 2 3 4 5; do echo 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'row_train "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'row_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(row_net $sd $k) $(row_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/chainrows_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'row_one "$@"' _

    # row_file SEED KIND NAME: the file row_one wrote for that run
    row_file() { echo "$work/out/chainrows.d/$(basename "$(row_net "$1" "$2")" .net)_$(row_row "$3").txt"; }
    # row_partner NAME: the row a row is read over, of its draw: for a lit
    # row its own row with no source; for a row with a row of the budget left
    # out, the tile as budgeted; and for the tile as budgeted and for a row
    # with one row of the budget alone, the format alone.  The format alone
    # is read over the first draw's, which it is
    row_partner() {
        local base=${1%, draw *} dd=${1##*, draw }
        case "$base" in
        *", lit") echo "${base%, lit}, draw $dd" ;;
        "less "*) echo "as budgeted, draw $dd" ;;
        "format only") echo "format only, draw ${draws%% *}" ;;
        *) echo "format only, draw $dd" ;;
        esac
    }
    # Four rows are the modes' before this one: the format alone and the tile
    # as budgeted are `chain`'s, and the two of them lit are `chainlit`'s.
    # Where this directory has what they wrote, each has to be that line,
    # byte for byte.
    if [ -d "$work/out/chain.d" ] || [ -d "$work/out/chainlit.d" ]; then
        same=0
        other=0
        for k in before reference; do for sd in 1 2 3 4 5; do
            while IFS='|' read -r name setting; do
                case "$name" in
                "format only, draw "*|"as budgeted, draw "*) was=chain.d ;;
                "format only, lit, draw "*|"as budgeted, lit, draw "*) was=chainlit.d ;;
                *) continue ;;
                esac
                was="$work/out/$was/$(basename "$(row_file $sd $k "$name")")"
                [ -s "$was" ] || continue
                if cmp -s "$was" "$(row_file $sd $k "$name")"; then same=$((same + 1)); else other=$((other + 1)); fi
            done < "$work/out/chainrows_settings.txt"
        done; done
        echo "== chainrows: against what chain and chainlit wrote for the same runs: $same the same, $other not"
        [ "$other" = 0 ] || exit 1
    fi
    # Every network has to be the kind its column says, and every run the row
    # its name says, as `chain` holds its own.  A run's name says its draw,
    # which rows of the budget are in it, and whether the source is lit,
    # which have to be what it was asked and what its line printed: the
    # impairments it names and no other, each at version 2's figure and
    # nought for the ones left out.  A lit run says the source's three rows,
    # its buses and its lines' reading, as `chainlit` holds them, and its
    # weights are 8 bits wide where every other run's are 6.  Every run's
    # range is the one the format alone of the first draw has, and its
    # largest reference is that row's: no row of the budget moves either.  A
    # run is not the run it is read over: its error and its class are not
    # that run's, figure for figure.  A run has the probe's gain and what
    # that leaves, which is no more than all of its error; and all of its
    # error is the last layer's, the host's two being exact.  The format
    # alone has no sum past its range wherever its reference is within its
    # codes.  And a row with nothing in it that is drawn, the format alone
    # and the crosstalk alone with no source, is on every draw the run it is
    # on the first: what it gets right, its error and its class, figure for
    # figure.
    row_ok=yes
    row_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(row_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2 &&
                   v["hidden"] == 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 3 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || row_ok=NO
        while IFS='|' read -r name setting; do
            cat "$log" "$(row_file $sd $k "format only, draw ${draws%% *}")" \
                "$(row_file $sd $k "${name%, draw *}, draw ${draws%% *}")" \
                "$(row_file $sd $k "$(row_partner "$name")")" "$(row_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v sd="$sd" -v d0="${draws%% *}" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        core = base
                        lit = 0
                        if (core ~ /, lit$/) { lit = 1; core = substr(core, 1, length(core) - 5) }
                        nth = 0; nsh = 0; npr = 0; nxt = 0
                        if (core == "as budgeted") { nth = 1; nsh = 1; npr = 1; nxt = 1 }
                        else if (core == "only thermal") nth = 1
                        else if (core == "only shot") nsh = 1
                        else if (core == "only prog") npr = 1
                        else if (core == "only xtalk") nxt = 1
                        else if (core == "less thermal") { nsh = 1; npr = 1; nxt = 1 }
                        else if (core == "less shot") { nth = 1; npr = 1; nxt = 1 }
                        else if (core == "less prog") { nth = 1; nsh = 1; nxt = 1 }
                        else if (core == "less xtalk") { nth = 1; nsh = 1; npr = 1 }
                        else if (core == "less shot, xtalk") { nth = 1; npr = 1 }
                        fmt = (core == "format only") ? 1 : 0
                        known = (fmt || nth + nsh + npr + nxt > 0) ? 1 : 0
                        still = (!lit && nth + nsh + npr == 0) ? 1 : 0
                        split(tile, tt, "x"); per = 16 * int((64 + tt[1] - 1) / tt[1])
                        sane = drawn && known && m == 1 + nth + nsh + npr + nxt && ("quant" in on) &&
                               asked("abits") == 6 && asked("adcbits") == 8 &&
                               has("thermal8") == nth && asked("thermal8") == 0.25 * nth && (("thermal" in on) ? 1 : 0) == nth &&
                               has("photons8") == nsh && asked("photons8") == 30 * nsh && (("shot" in on) ? 1 : 0) == nsh &&
                               has("prog") == npr && asked("prog") == npr && (("prog" in on) ? 1 : 0) == npr &&
                               has("xtalk") == nxt && asked("xtalk") == 0.02 * nxt && (("xtalk" in on) ? 1 : 0) == nxt &&
                               !("drift" in on) && !has("drift") && !has("hours") && !has("calibrate") &&
                               !has("post-hours") && !has("trimstep") && !has("trimmax") && !has("wbits") && !has("seed") &&
                               has("src") == lit && asked("src") == 0.01 * lit &&
                               has("srcline") == lit && asked("srcline") == 0.05 * lit &&
                               has("srcflat") == lit && asked("srcflat") == 0.2 * lit &&
                               has("buses") == lit && asked("buses") == 2 * lit &&
                               has("levelprobe") == lit && asked("levelprobe") == 16 * lit &&
                               has("levelfix") == lit && (!lit || want["levelfix"] == "weights8") &&
                               !has("srcsign") && !has("levelref") && !has("levelpart") && !has("levellayer") &&
                               has("host") && asked("host") == 2 && has("probe") && asked("probe") == 1 &&
                               has("gate") && asked("gate") == 1 && !has("images") && !has("gatefit") && !has("gatebits") }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { right = v["correct"]; gref = v["gate_ref"]; split(v["S"], s0, ","); was = s0[3]; peak0 = v["gate_peak"]
                          theirs = ("gate_ref" in v) && v["impair"] == "0x01" && v["seed"] == sd + 10 * d0 && v["net_seed"] == sd &&
                                   v["images"] == 10000 && !("src" in v) }
                NR == 3 { own = v["correct"]
                          ofig = v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"] }
                NR == 4 { pfig = v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"] }
                NR == 5 { ns = split(v["S"], sh, ","); n8 = split(v["S8"], s8, ",")
                          fig = v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " v["agree"] " " v["e3"]
                          ok = sane && theirs && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw &&
                               v["net_wbits"] == 6 && v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["hidden"] == 2 && ns == 3 && v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 &&
                               v["adcbits"] == 8 && v["wbits"] == (lit ? 8 : 6) && v["drift"] == "none" &&
                               v["hours"] == 0 && v["steps"] == 0 && v["cal"] == 0 && v["post_hours"] == 0 &&
                               near(v["trimstep"], 0.25, 1e-12) && v["trimmax"] == 128 && v["images"] == 10000 &&
                               ("host" in v) && v["host"] == 2 &&
                               (("src" in v) ? 1 : 0) == lit && (("levelprobe" in v) ? 1 : 0) == lit &&
                               (("levelfix" in v) ? 1 : 0) == lit && !("levelpart" in v) &&
                               !("hidshift" in v) && !("thermalline" in v) && !("gate_adcbits" in v) &&
                               !("gate_fit" in v) && !("gate_was" in v) &&
                               ("gate_bits" in v) && v["gate_bits"] == 6 && ("gate_rms" in v) && v["gate_rms"] > 0 &&
                               v["gate_peak"] > 0 && v["gate8_peak"] > 0 && v["gate_rmsfs"] > 0 &&
                               v["gate_rmsfs"] + 0 <= v["gate_maxfs"] + 0 && v["gate8_rmsfs"] + 0 <= v["gate8_maxfs"] + 0 &&
                               ("e1" in v) && ("e2" in v) && v["e1"] == 0 && v["e2"] == 0 && v["e3"] > 0 &&
                               ("gain" in v) && ("eres" in v) && ("elog" in v) && v["eres"] > 0 &&
                               v["eres"] + 0 <= v["elog"] + 0 && v["elog"] == v["e3"] &&
                               ("agree" in v) && ("ref" in v) && v["agree"] > 50 &&
                               ("sats" in v) && ("elements" in v) && v["elements"] == per * v["images"] &&
                               v["sats"] + 0 <= v["elements"] / 100 &&
                               ("gate_agree" in v) && ("gate_ref" in v) && v["gate_agree"] > 50 &&
                               v["gate_agree"] + 0 <= 100 && v["gate_ref"] == gref && v["gate_ref"] > 0 &&
                               v["gate_peak"] == peak0 && sh[1] == s0[1] && sh[2] == s0[2] && sh[3] == was && n8 == 3 &&
                               s8[3] == sh[3] &&
                               near(v["thermal8"], 0.25 * nth, 1e-6) &&
                               (nsh ? near(v["photons8"] / 30, 1, 0.03) : v["photons8"] == 0) &&
                               near(v["prog"], npr, 1e-9) &&
                               (nxt ? (near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0) : v["xtalk"] == 0)
                          if (lit) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] == 0.2 &&
                                         v["buses"] == 2 && v["srcsign"] == "pair" &&
                                         v["levelprobe"] == 16 && near(v["level_found"], 0.2, 0.1) &&
                                         v["level_left"] > 0 && v["level_left"] + 0 < v["level_found"] / 4 &&
                                         v["levelfix"] == "weights8" && v["levelref"] == "none" && v["level_gain"] == 1 &&
                                         v["level_clip"] >= 0 && v["level_clip"] < 0.5
                          if (lit || !fmt) ok = ok && pfig != fig
                          if (fmt && !lit && int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= 127) ok = ok && v["sats"] == 0
                          if (still) ok = ok && v["correct"] == own && fig == ofig && (!fmt || own == right) }
                END { exit !(NR == 5 && ok) }' || row_ok=NO
            row_runs=$((row_runs + 1))
        done < "$work/out/chainrows_settings.txt"
    done; done
    echo "== chainrows: $row_runs runs, each of them the network and the row its place says: $row_ok"
    [ "$row_ok" = yes ] || exit 1

    # row_stat KIND NAME: how often the five networks are right in a row,
    # mean and standard error, and what the row adds over its partner, network
    # by network
    row_stat() {
        local sd partner
        partner=$(row_partner "$2")
        for sd in 1 2 3 4 5; do
            sed 's/^/A /' "$(row_file $sd "$1" "$partner")"
            sed 's/^/B /' "$(row_file $sd "$1" "$2")"
        done | awk '
            function se(s, ss, n,    m, var) { m = s / n; var = ss / n - m * m; if (var < 0) var = 0
                                               return (n > 1) ? sqrt(var / (n - 1)) : 0 }
            { delete v; for (i = 2; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"]
              if ($1 == "A") { a = x; next }
              n++; s += x; ss += x * x; g = a - x; gs += g; gss += g * g }
            END { printf " %7.2f +-%4.2f %7.2f +-%4.2f", s / n, se(s, ss, n), gs / n, se(gs, gss, n) }'
    }
    # row_pair KIND BASE OTHER: a row over all its draws, against another
    # row of the same draws: how often right in the other, less in the row,
    # network by network.  The mean; its standard error, from the five
    # networks, each averaged over its draws; and the standard deviation from
    # draw to draw of the five networks' mean
    row_pair() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do
                sed "s/^/A $sd $dd /" "$(row_file $sd "$1" "$3, draw $dd")"
                sed "s/^/B $sd $dd /" "$(row_file $sd "$1" "$2, draw $dd")"
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
    # row_over KIND BASE: a row over all its draws.  How often right: the
    # mean, its standard error from the five networks each averaged over its
    # draws, and the draws' standard deviation; and what it adds over the row
    # it is read over, the same three
    row_over() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(row_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["acc"] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++ }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd) }'
        # the row it is read over is its partner on its own draw, but for a
        # format-only row, whose partner is one row for all of them
        if [ "$2" = "format only" ]; then
            local first=${draws%% *} sd2 dd2
            for sd2 in 1 2 3 4 5; do
                for dd2 in $draws; do
                    sed "s/^/A $sd2 $dd2 /" "$(row_file $sd2 "$1" "$2, draw $first")"
                    sed "s/^/B $sd2 $dd2 /" "$(row_file $sd2 "$1" "$2, draw $dd2")"
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
            p=$(row_partner "$2, draw 0")
            row_pair "$1" "$2" "${p%, draw *}"
        fi
    }
    # row_agree KIND BASE FIELD: a row over its draws: how often the class
    # the tile gives is the class the host gives (agree) or the class its
    # declared reference gives (gate_agree), percent: the mean, its standard
    # error from the five networks each averaged over its draws, and the
    # draws' standard deviation; the least of any run; and of the runs, how
    # many agree on 99.5% or more
    row_agree() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do sed "s/^/$sd $dd /" "$(row_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v fld="$3" '
            function dev(s, ss, n,    m, var) { if (n < 2) return 0; m = s / n; var = (ss - n * m * m) / (n - 1); return (var > 0) ? sqrt(var) : 0 }
            { delete v; for (i = 3; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v[fld] + 0; rn[$1] += x; cn[$1]++; rd[$2] += x; cd[$2]++
              if (runs == 0 || x < least) least = x
              runs++; pass += (x >= 99.5) }
            END { for (k in cn) { x = rn[k] / cn[k]; rs += x; rss += x * x; nn++ }
                  for (k in cd) { x = rd[k] / cd[k]; ds += x; dss += x * x; nd++ }
                  printf " %8.3f +-%5.3f %6.3f %7.2f %3d of %2d", rs / nn, dev(rs, rss, nn) / sqrt(nn), dev(ds, dss, nd), least, pass, runs }'
    }
    # row_declared KIND BASE: how often the declared reference is right in
    # a row, percent, a mean over its runs: what its own format leaves the
    # network, before any tile
    row_declared() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(row_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              s += v["gate_ref"]; runs++ }
            END { printf " %7.3f", s / runs }'
    }
    # row_gate KIND BASE RMS RMSFS MAXFS: a row over its runs, against one
    # reference: the last layer's rms error over the reference's rms, over
    # the largest the reference is, and its largest error over that, percent:
    # a mean, and for the third the most of any run; and of the runs, how
    # many are within 1.0% on the first, 1.0% on the second and 2.0% on the
    # third
    row_gate() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(row_file $sd "$1" "$2, draw $dd")"; done
        done | awk -v a="$3" -v b="$4" -v c="$5" '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = 100 * v[a]; y = 100 * v[b]; z = 100 * v[c]
              xs += x; ys += y; zs += z; if (z > most) most = z
              px += (x <= 1.0); py += (y <= 1.0); pz += (z <= 2.0); runs++ }
            END { printf " %7.3f %6.3f %6.3f %6.3f %3d %2d %2d", xs / runs, ys / runs, zs / runs, most, px, py, pz }'
    }
    # row_range KIND BASE: a row over its runs, and the converter's range,
    # which the harness sets on a thousand training images to pass all but one
    # sum in ten thousand: the runs with a sum past it, the most sums past it
    # in a run, and of how many; and the most the largest error against the
    # declared format is, percent of the largest the reference is, in the runs
    # with none past it and in the runs with some.  Nothing where there is no
    # such run
    row_range() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(row_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              z = 100 * v["gate_maxfs"]; s = v["sats"] + 0; runs++; of = v["elements"] + 0
              if (s > 0) { past++; if (s > most) most = s; if (z > clipped) clipped = z }
              else if (z > whole) whole = z }
            END { printf " %5d of %2d %5d of %6d %7.3f %7.3f", past, runs, most, of, whole, clipped }'
    }
    # row_lines KIND BASE: a row over its runs, and the source's lines: the
    # runs that read them; what the lines were, rms, and what the reading
    # leaves, each a mean over those runs; the runs that put the reading on
    # the weights; and of the weights it scaled, the share the rail held
    # back, a mean over those runs and the most of any
    row_lines() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(row_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              runs++
              if ("levelprobe" in v) { f += v["level_found"]; l += v["level_left"]; n++ }
              if ("levelfix" in v) { c = v["level_clip"] + 0; cs += c; if (c > cm) cm = c; m++ } }
            END { printf " %3d of %2d %6.4f %6.4f %3d of %2d %7.5f %7.5f", n, runs, n ? f / n : 0, n ? l / n : 0,
                         m, runs, m ? cs / m : 0, cm }'
    }
    # row_probe KIND BASE: a row over its runs, and the probe's account of
    # its error against the host's own network: the gain, which is the slope
    # of the error on the outputs with each image's common shift taken out, a
    # mean and the least and the most of any run; and what is left of the
    # error with the shift and the gain out, percent of the reference's rms,
    # a mean.  A class does not move with a shift or a gain
    row_probe() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(row_file $sd "$1" "$2, draw $dd")"; done
        done | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              g = v["gain"] + 0; gs += g; rs += 100 * v["eres"]
              if (runs == 0 || g < least) least = g
              if (runs == 0 || g > most) most = g
              runs++ }
            END { printf " %+8.4f %+8.4f %+8.4f %7.3f", gs / runs, least, most, rs / runs }'
    }
    echo "== chainrows: the $tile tile at v2, the last layer of three on it, five networks, mean and"
    echo "== standard error.  How often right, percent, and what a row adds over the row it is"
    echo "== read over, network by network: for a lit row its own row with no source, for a"
    echo "== row with a row of the budget left out the tile as budgeted, and else the format"
    printf '%-92s %14s %14s %14s %14s' "" "before right" "and adds" "reference" "and adds"
    echo
    while IFS='|' read -r name setting; do
        printf '%-92s' "$name"
        for k in before reference; do row_stat $k "$name"; done
        echo
    done < "$work/out/chainrows_settings.txt"
    echo "== chainrows: a row over its draws.  How often right, and what it adds over the row it is"
    echo "== read over: the mean, its standard error from five networks each averaged over its"
    echo "== draws, and the standard deviation from draw to draw of the five networks' mean"
    printf '%-84s %25s %24s %25s %24s' "" "before right" "and adds" "reference right" "and adds"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainrows_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do row_over $k "$base"; done
        echo
    done
    echo "== chainrows: the class the tile gives against the class the host gives, percent, a row over"
    echo "== its draws: the mean, its standard error from five networks, the draws' standard"
    echo "== deviation, the least of any run, and the runs that agree on 99.5% or more"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainrows_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do row_agree $k "$base" agree; done
        echo
    done
    echo "== chainrows: the class the tile gives against the class its declared reference gives,"
    echo "== percent, a row over its draws: the same five; and how often that reference is"
    echo "== right, a mean over the runs"
    printf '%-84s %48s %48s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainrows_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do row_agree $k "$base" gate_agree; row_declared $k "$base"; done
        echo
    done
    for ref in "its declared format|gate_rms gate_rmsfs gate_maxfs" "its operands as they were given|e3 gate8_rmsfs gate8_maxfs"; do
        echo "== chainrows: the last layer's error against ${ref%|*}, percent, a row over its"
        echo "== runs: its rms over the reference's rms, over the largest the reference is, and its"
        echo "== largest over that, a mean; the most the third is in any run; and the runs within"
        echo "== 1.0% on the first, 1.0% on the second and 2.0% on the third"
        printf '%-84s %40s %40s' "" "before" "reference"
        echo
        sed 's/, draw [0-9]*|.*//' "$work/out/chainrows_settings.txt" | awk '!seen[$0]++' | while read -r base; do
            printf '%-84s' "$base"
            for k in before reference; do row_gate $k "$base" ${ref#*|}; done
            echo
        done
    done
    echo "== chainrows: the converter's range, a row over its runs: the runs with a sum past it, the"
    echo "== most sums past it in a run, and of how many; and the most the largest error against"
    echo "== the declared format is, percent of the largest the reference is, in the runs with"
    echo "== none past it and in the runs with some"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainrows_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do row_range $k "$base"; done
        echo
    done
    echo "== chainrows: the source's lines, a row over its runs: the runs that read them; what the"
    echo "== lines were, rms, and what the reading leaves, a mean; the runs that put it on the"
    echo "== weights; and of the weights scaled, the share the rail held back, a mean and the most"
    printf '%-84s %40s %40s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainrows_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do row_lines $k "$base"; done
        echo
    done
    echo "== chainrows: the last layer's error against the host's own network as the probe has it, a"
    echo "== row over its runs: the gain, the slope of the error on the outputs with each image's"
    echo "== common shift out, a mean and the least and the most of any run; and what is left"
    echo "== with the shift and the gain out, percent of the reference's rms, a mean"
    printf '%-84s %34s %34s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chainrows_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do row_probe $k "$base"; done
        echo
    done
fi

# `chaingain`: `chain`'s last layer, with one scale on its outputs.
# `chainrows` found most of the crosstalk's error to be a gain on every
# output, against the host's own network, and a source corrected on the
# weights to take gain off; and the gate holds the layer's raw outputs to a
# reference in their declared format.  This gives the outputs one scale,
# fixed at calibration on the first thousand of the images the network was
# not trained on (eval --gatescale), and gives the gate's figures again with
# it: the scale a board could hold in its reference, and what it buys.  Nine
# rows: the format alone; the crosstalk alone and the shot noise alone; the
# tile as budgeted, with each of those two left out, and with its range
# fitted; and the tile as budgeted lit, as `chainlit` lit it, at training's
# range and fitted.  The same networks as `chain`, on five draws, on 10,000
# images and on the first thousand, the gate's own set.  Every row but four
# on a thousand is a run a mode before this one made, which the scale leaves
# as it was: where a directory has what that mode wrote, every figure its
# line printed has to be that line's, byte for byte.  Both kinds of network,
# row for row.
if [ "$what" = chaingain ]; then
    tile=${CHAINGAIN_TILE:-128x64}
    draws=${CHAINGAIN_DRAWS:-0 1 2 3 4}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    # the tile's format, and the four rows of version 2's budget that add to it
    q="--abits 6 --adcbits 8"
    th="--thermal8 0.25"
    ph="--photons8 30"
    pg="--prog 1"
    xk="--xtalk 0.02"
    r="$q $th $ph $pg $xk"
    f="--impair quant $q"
    b="--impair $all $r"
    # the scale is fixed on this many of the held-out images, the gate's own number
    cal=1000
    t="--host 2 --probe 1 --gate 1 --gatescale $cal"
    # the source's three rows, as grxcp's B16 has them, on B10's two buses
    shared=0.01
    own=0.05
    level=0.2
    buses=2
    src="--src $shared --srcline $own --srcflat $level --buses $buses"
    fix="--levelprobe 16 --levelfix weights8"
    # row|options.  Every row's name ends in its draw, and is the name the
    # mode before it that ran it gave it
    for dd in $draws; do
        for n in "" ", a thousand"; do
            i=
            [ -z "$n" ] || i=" --images 1000"
            echo "format only$n, draw $dd|$f$i"
            echo "only xtalk$n, draw $dd|--impair quant,xtalk $q $xk$i"
            echo "only shot$n, draw $dd|--impair quant,shot $q $ph$i"
            echo "less xtalk$n, draw $dd|--impair quant,thermal,shot,prog $q $th $ph $pg$i"
            echo "less shot$n, draw $dd|--impair quant,thermal,prog,xtalk $q $th $pg $xk$i"
            echo "as budgeted$n, draw $dd|$b$i"
            echo "as budgeted, fitted$n, draw $dd|$b$i --gatefit 1"
            echo "as budgeted, lit$n, draw $dd|$b$i $src $fix"
            echo "as budgeted, lit, fitted$n, draw $dd|$b$i $src $fix --gatefit 1"
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ $t/" > "$work/out/chaingain_settings.txt"
    # gain_train WBITS SEED [FROM]: a DIN_W 8 network of two hidden layers,
    # unless it is already there, starting from the same seed's at FROM bits
    gain_train() {
        local net="$PTA_WORK/nets/h2_d8_b$1_s$2.net" from=()
        [ $# -lt 3 ] || from=(--from "$PTA_WORK/nets/h2_d8_b$3_s$2.net")
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits "$1" \
            --seed "$2" --hidden 2 "${from[@]}" --out "$net" > "$net.log"
    }
    # gain_ref SEED: that seed's reference network, the header's recipe at
    # this shape
    gain_ref() {
        local net="$PTA_WORK/nets/h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
            --seed "$1" --hidden 2 --from "$PTA_WORK/nets/h2_d8_b8_s$1.net" \
            --sumnoise "$PTA_REF_NOISE" --epochs "$PTA_REF_EPOCHS" --out "$net" > "$net.log"
    }
    # gain_one NET ROW ARGS...: one test-set pass and its calibration, its
    # line to out/chaingain.d/NET_ROW.txt
    gain_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/chaingain.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/chaingain.d/$(basename "$net" .net)_$row.txt"
    }
    export -f gain_train gain_ref gain_one
    # gain_row NAME: a row's name as a file's
    gain_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # gain_net SEED KIND: the network's file, trained before or the reference
    gain_net() {
        if [ "$2" = before ]; then echo "h2_d8_b6_s$1.net"
        else echo "h2_d8_b6_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; fi
    }
    for s in 1 2 3 4 5; do echo 8 $s; done | xargs -P "$jobs" -L 1 bash -c 'gain_train "$@"' _
    for s in 1 2 3 4 5; do echo 6 $s 8; done | xargs -P "$jobs" -L 1 bash -c 'gain_train "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'gain_ref "$@"' _
    for k in before reference; do
        while IFS='|' read -r name setting; do
            dd=${name##*, draw }
            for sd in 1 2 3 4 5; do echo "$(gain_net $sd $k) $(gain_row "$name") --seed $((sd + 10 * dd)) $setting"; done
        done < "$work/out/chaingain_settings.txt"
    done | xargs -P "$jobs" -L 1 bash -c 'gain_one "$@"' _

    # gain_file SEED KIND NAME: the file gain_one wrote for that run
    gain_file() { echo "$work/out/chaingain.d/$(basename "$(gain_net "$1" "$2")" .net)_$(gain_row "$3").txt"; }
    # gain_was NAME: the mode before this one that ran a row, or nothing:
    # `chain` the format alone and the tile as budgeted, `chainfit` that
    # fitted, `chainlit` it lit, and `chainrows` the other four on all the
    # images, which it ran on no thousand
    gain_was() {
        case "$1" in
        "format only, "*|"as budgeted, draw "*|"as budgeted, a thousand, draw "*) echo chain.d ;;
        "as budgeted, fitted, "*) echo chainfit.d ;;
        "as budgeted, lit, "*) echo chainlit.d ;;
        *", a thousand, draw "*) ;;
        "only "*|"less "*) echo chainrows.d ;;
        esac
    }
    # The scale leaves a run as it was: its figures are printed after every
    # other, and where this directory has the mode before's lines, every run
    # that mode made has to be among them and its line up to the scale's
    # figures has to be that line, byte for byte.  A line that is not there
    # is one that is not the same.
    if [ -d "$work/out/chain.d" ] || [ -d "$work/out/chainfit.d" ] || [ -d "$work/out/chainrows.d" ] ||
       [ -d "$work/out/chainlit.d" ]; then
        same=0
        other=0
        for k in before reference; do for sd in 1 2 3 4 5; do
            while IFS='|' read -r name setting; do
                was=$(gain_was "$name")
                [ -n "$was" ] && [ -d "$work/out/$was" ] || continue
                was="$work/out/$was/$(basename "$(gain_file $sd $k "$name")")"
                if [ -s "$was" ] && sed 's/ gate_scale=.*$//' "$(gain_file $sd $k "$name")" | cmp -s "$was" -; then
                    same=$((same + 1))
                else
                    other=$((other + 1))
                fi
            done < "$work/out/chaingain_settings.txt"
        done; done
        echo "== chaingain: against what chain, chainfit, chainrows and chainlit wrote for the same runs: $same the same, $other not"
        [ "$other" = 0 ] || exit 1
    fi
    # Every network has to be the kind its column says, and every run the row
    # its name says, as `chainlit` and `chainrows` hold their own.  A run's
    # name says its draw, which rows of the budget are in it, whether its
    # range is training's or fitted, whether the source is lit, and whether
    # it is of a thousand images or of all, which have to be what it was
    # asked and what its line printed: the impairments it names and no
    # other, each at version 2's figure and nought for the ones left out; a
    # lit run's source, buses and lines' reading as `chainlit` holds them,
    # and its weights 8 bits wide where every other run's are 6; and a
    # fitted run's share, 1, and the shift training's rule had given, its
    # last shift the smallest at which the largest its declared reference
    # is, is within 127 codes.  Every run's largest reference is the format
    # alone's of the first draw, of as many images, and so is the range of a
    # run that is not fitted.  The format alone has no sum past its range
    # wherever its reference is within its codes.  And of the scale, every
    # run says it was fixed on a thousand images, and gives its figures with
    # the scale: the scale is within a hundredth of the one the test images
    # would fit themselves, which a run can come to by chance; what
    # that one leaves is no more than what the run leaves with no scale, or
    # with its own, to the printed figure; its rms error is no more than its
    # largest; and its class is the reference's on more than half the
    # images.  The scale was fixed from image 54,000 of the training set on,
    # the first of the 6,000 the network was not trained on.  The two rows
    # with nothing drawn in them, the format alone and the crosstalk alone,
    # are on every draw the run they are on the first, figure for figure,
    # the scale's figures among them.
    gain_ok=yes
    gain_runs=0
    for k in before reference; do for sd in 1 2 3 4 5; do
        log="$work/nets/$(gain_net $sd $k).log"
        awk -v k="$k" -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["epochs"] >= 2 &&
                   v["hidden"] == 2
              if (k == "before") ok = ok && !("sumnoise" in v) && !("fixed_epochs" in v)
              else { n = split(v["got"], g, ",")
                     ok = ok && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && n == 3 &&
                          v["fixed_epochs"] == e && v["epochs"] == e
                     for (i = 1; i <= n; ++i) ok = ok && g[i] > 0.95 * f && g[i] < 1.05 * f }
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || gain_ok=NO
        while IFS='|' read -r name setting; do
            first="format only"
            [ "${name%, a thousand, draw *}" = "$name" ] || first="format only, a thousand"
            cat "$log" "$(gain_file $sd $k "$first, draw ${draws%% *}")" \
                "$(gain_file $sd $k "${name%, draw *}, draw ${draws%% *}")" "$(gain_file $sd $k "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v sd="$sd" -v d0="${draws%% *}" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                function figs() { return v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " \
                                         v["agree"] " " v["e3"] " " v["gate_scale"] " " v["gate_scale_rms"] " " \
                                         v["gate_scale_rmsfs"] " " v["gate_scale_maxfs"] " " v["gate_scale_agree"] " " \
                                         v["gate_scale_best"] " " v["gate_scale_best_rms"] }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        few = (base ~ /, a thousand$/) ? 1 : 0
                        core = few ? substr(base, 1, length(base) - 12) : base
                        kind = 0; lit = 0
                        if (core ~ /, lit, fitted$/) { kind = 1; lit = 1; core = substr(core, 1, length(core) - 13) }
                        else if (core ~ /, lit$/) { lit = 1; core = substr(core, 1, length(core) - 5) }
                        else if (core ~ /, fitted$/) { kind = 1; core = substr(core, 1, length(core) - 8) }
                        nth = 0; nsh = 0; npr = 0; nxt = 0
                        if (core == "as budgeted") { nth = 1; nsh = 1; npr = 1; nxt = 1 }
                        else if (core == "only shot") nsh = 1
                        else if (core == "only xtalk") nxt = 1
                        else if (core == "less shot") { nth = 1; npr = 1; nxt = 1 }
                        else if (core == "less xtalk") { nth = 1; nsh = 1; npr = 1 }
                        fmt = (core == "format only") ? 1 : 0
                        known = (fmt || nth + nsh + npr + nxt > 0) && (core == "as budgeted" || (!lit && !kind))
                        still = (!lit && nth + nsh + npr == 0) ? 1 : 0
                        split(tile, tt, "x"); per = 16 * int((64 + tt[1] - 1) / tt[1])
                        sane = drawn && known && m == 1 + nth + nsh + npr + nxt && ("quant" in on) &&
                               asked("abits") == 6 && asked("adcbits") == 8 &&
                               has("thermal8") == nth && asked("thermal8") == 0.25 * nth && (("thermal" in on) ? 1 : 0) == nth &&
                               has("photons8") == nsh && asked("photons8") == 30 * nsh && (("shot" in on) ? 1 : 0) == nsh &&
                               has("prog") == npr && asked("prog") == npr && (("prog" in on) ? 1 : 0) == npr &&
                               has("xtalk") == nxt && asked("xtalk") == 0.02 * nxt && (("xtalk" in on) ? 1 : 0) == nxt &&
                               !("drift" in on) && !has("drift") && !has("hours") && !has("calibrate") &&
                               !has("post-hours") && !has("trimstep") && !has("trimmax") && !has("wbits") && !has("seed") &&
                               has("src") == lit && asked("src") == 0.01 * lit &&
                               has("srcline") == lit && asked("srcline") == 0.05 * lit &&
                               has("srcflat") == lit && asked("srcflat") == 0.2 * lit &&
                               has("buses") == lit && asked("buses") == 2 * lit &&
                               has("levelprobe") == lit && asked("levelprobe") == 16 * lit &&
                               has("levelfix") == lit && (!lit || want["levelfix"] == "weights8") &&
                               !has("srcsign") && !has("levelref") && !has("levelpart") && !has("levellayer") &&
                               has("host") && asked("host") == 2 && has("probe") && asked("probe") == 1 &&
                               has("gate") && asked("gate") == 1 && has("images") == few && asked("images") == 1000 * few &&
                               has("gatefit") == kind && (!kind || asked("gatefit") == 1) && !has("gatebits") &&
                               has("gatescale") && asked("gatescale") == 1000 }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { right = v["correct"]; gref = v["gate_ref"]; split(v["S"], s0, ","); was = s0[3]; peak0 = v["gate_peak"]
                          theirs = ("gate_ref" in v) && v["impair"] == "0x01" && v["seed"] == sd + 10 * d0 && v["net_seed"] == sd &&
                                   v["images"] == (few ? 1000 : 10000) && !("src" in v) && !("gate_fit" in v) }
                NR == 3 { own = v["correct"]; ofig = figs() }
                NR == 4 { ns = split(v["S"], sh, ","); n8 = split(v["S8"], s8, ",")
                          fig = figs()
                          ok = sane && theirs && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw &&
                               v["net_wbits"] == 6 && v["digital"] == digital && v["epochs"] == epochs && v["from"] == 8 &&
                               v["hidden"] == 2 && ns == 3 && v["impair"] == sprintf("0x%02x", mask) && v["abits"] == 6 &&
                               v["adcbits"] == 8 && v["wbits"] == (lit ? 8 : 6) && v["drift"] == "none" &&
                               v["hours"] == 0 && v["steps"] == 0 && v["cal"] == 0 && v["post_hours"] == 0 &&
                               near(v["trimstep"], 0.25, 1e-12) && v["trimmax"] == 128 && v["images"] == (few ? 1000 : 10000) &&
                               ("host" in v) && v["host"] == 2 &&
                               (("src" in v) ? 1 : 0) == lit && (("levelprobe" in v) ? 1 : 0) == lit &&
                               (("levelfix" in v) ? 1 : 0) == lit && !("levelpart" in v) &&
                               !("hidshift" in v) && !("thermalline" in v) && !("gate_adcbits" in v) &&
                               ("gate_bits" in v) && v["gate_bits"] == 6 && ("gate_rms" in v) && v["gate_rms"] > 0 &&
                               v["gate_peak"] > 0 && v["gate8_peak"] > 0 && v["gate_rmsfs"] > 0 &&
                               v["gate_rmsfs"] + 0 <= v["gate_maxfs"] + 0 && v["gate8_rmsfs"] + 0 <= v["gate8_maxfs"] + 0 &&
                               ("e1" in v) && ("e2" in v) && v["e1"] == 0 && v["e2"] == 0 && v["e3"] > 0 &&
                               ("gain" in v) && ("eres" in v) && ("elog" in v) && v["eres"] > 0 &&
                               v["eres"] + 0 <= v["elog"] + 0 && v["elog"] == v["e3"] &&
                               ("agree" in v) && ("ref" in v) && v["agree"] > 50 &&
                               ("sats" in v) && ("elements" in v) && v["elements"] == per * v["images"] &&
                               v["sats"] + 0 <= v["elements"] / 100 &&
                               ("gate_agree" in v) && ("gate_ref" in v) && v["gate_agree"] > 50 &&
                               v["gate_agree"] + 0 <= 100 && v["gate_ref"] == gref && v["gate_ref"] > 0 &&
                               v["gate_peak"] == peak0 && sh[1] == s0[1] && sh[2] == s0[2] && n8 == 3 &&
                               near(v["thermal8"], 0.25 * nth, 1e-6) &&
                               (nsh ? near(v["photons8"] / 30, 1, 0.03) : v["photons8"] == 0) &&
                               near(v["prog"], npr, 1e-9) &&
                               (nxt ? (near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0) : v["xtalk"] == 0)
                          # the scale
                          ok = ok && ("gate_scale" in v) && v["gate_scale_images"] == 1000 && v["gate_scale_first"] == 54000 &&
                               v["gate_scale"] > 0.5 &&
                               v["gate_scale"] < 1.5 && ("gate_scale_best" in v) &&
                               near(v["gate_scale"], v["gate_scale_best"], 0.01) && v["gate_scale_rms"] > 0 &&
                               v["gate_scale_best_rms"] + 0 <= v["gate_rms"] + 0.00001 &&
                               v["gate_scale_best_rms"] + 0 <= v["gate_scale_rms"] + 0.00001 &&
                               v["gate_scale_rmsfs"] + 0 <= v["gate_scale_maxfs"] + 0 &&
                               v["gate_scale_agree"] > 50 && v["gate_scale_agree"] + 0 <= 100
                          if (lit) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] == 0.2 &&
                                         v["buses"] == 2 && v["srcsign"] == "pair" &&
                                         v["levelprobe"] == 16 && near(v["level_found"], 0.2, 0.1) &&
                                         v["level_left"] > 0 && v["level_left"] + 0 < v["level_found"] / 4 &&
                                         v["levelfix"] == "weights8" && v["levelref"] == "none" && v["level_gain"] == 1 &&
                                         v["level_clip"] >= 0 && v["level_clip"] < 0.5
                          if (kind == 0) { ok = ok && !("gate_fit" in v) && !("gate_was" in v) && sh[3] == was && s8[3] == sh[3]
                                           if (fmt && int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= 127) ok = ok && v["sats"] == 0 }
                          else ok = ok && ("gate_fit" in v) && v["gate_fit"] == 1 && ("gate_was" in v) && v["gate_was"] == was &&
                                    int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= 127 &&
                                    (sh[3] == 0 || int(v["gate_peak"] / 2 ^ (sh[3] - 1) + 0.5) > 127) && s8[3] == sh[3]
                          if (still) ok = ok && v["correct"] == own && fig == ofig && (!fmt || own == right) }
                END { exit !(NR == 4 && ok) }' || gain_ok=NO
            gain_runs=$((gain_runs + 1))
        done < "$work/out/chaingain_settings.txt"
    done; done
    echo "== chaingain: $gain_runs runs, each of them the network and the row its place says: $gain_ok"
    [ "$gain_ok" = yes ] || exit 1

    # gain_lines KIND BASE: a row's lines over its draws, five networks a draw
    gain_lines() {
        local sd dd
        for sd in 1 2 3 4 5; do
            for dd in $draws; do cat "$(gain_file $sd "$1" "$2, draw $dd")"; done
        done
    }
    # gain_scale KIND BASE: a row over its runs, and the scale: fixed on the
    # held-out images, a mean and the least and the most of any run; the one
    # the test images would fit themselves, a mean; and the most the two
    # differ by in a run
    gain_scale() {
        gain_lines "$1" "$2" | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              s = v["gate_scale"] + 0; bs = v["gate_scale_best"] + 0; d = s - bs; if (d < 0) d = -d
              if (runs == 0 || s < least) least = s
              if (runs == 0 || s > most) most = s
              if (d > apart) apart = d
              ss += s; sb += bs; runs++ }
            END { printf " %7.5f %7.5f %7.5f %7.5f %7.5f", ss / runs, least, most, sb / runs, apart }'
    }
    # gain_gate KIND BASE RMS RMSFS MAXFS: a row over its runs, the last
    # layer against its declared format, with no scale or with one: its rms
    # error over the reference's rms, over the largest the reference is, and
    # its largest over that, percent, each a mean; and the runs within 1.0%,
    # 1.0% and 2.0% on the three
    gain_gate() {
        gain_lines "$1" "$2" | awk -v a="$3" -v b="$4" -v c="$5" '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = 100 * v[a]; y = 100 * v[b]; z = 100 * v[c]
              xs += x; ys += y; zs += z
              px += (x <= 1.0); py += (y <= 1.0); pz += (z <= 2.0); runs++ }
            END { printf " %6.3f %6.3f %6.3f %3d %2d %2d", xs / runs, ys / runs, zs / runs, px, py, pz }'
    }
    # gain_best KIND BASE: what the scale the test images would fit
    # themselves leaves of the rms error over the reference's rms, percent,
    # a mean over the row's runs
    gain_best() {
        gain_lines "$1" "$2" | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              s += 100 * v["gate_scale_best_rms"]; runs++ }
            END { printf " %6.3f", s / runs }'
    }
    # gain_class KIND BASE: a row over its runs, and how often the class the
    # tile gives is the class its declared reference gives, percent: with no
    # scale, a mean and the runs at 99.5% or more; and with the scale, a
    # mean, the runs at 99.5% or more, and the least of any run
    gain_class() {
        gain_lines "$1" "$2" | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              x = v["gate_agree"] + 0; y = v["gate_scale_agree"] + 0
              xs += x; ys += y; px += (x >= 99.5); py += (y >= 99.5)
              if (runs == 0 || y < least) least = y
              runs++ }
            END { printf " %7.3f %3d %7.3f %3d %7.2f", xs / runs, px, ys / runs, py, least }'
    }
    echo "== chaingain: the $tile tile at v2, the last layer of three on it, five networks and their"
    echo "== draws.  The scale, a row over its runs: fixed on $cal held-out images, a mean, the least and"
    echo "== the most; the one the test images would fit themselves, a mean; and the most the two differ by"
    printf '%-84s %39s %39s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chaingain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do gain_scale $k "$base"; done
        echo
    done
    for ref in "no scale|gate_rms gate_rmsfs gate_maxfs" "the scale|gate_scale_rms gate_scale_rmsfs gate_scale_maxfs"; do
        echo "== chaingain: the last layer's error against its declared format with ${ref%|*}, percent, a"
        echo "== row over its runs: its rms over the reference's rms, over the largest the reference is, and"
        echo "== its largest over that, a mean; and the runs within 1.0%, 1.0% and 2.0% on the three"
        printf '%-84s %30s %30s' "" "before" "reference"
        echo
        sed 's/, draw [0-9]*|.*//' "$work/out/chaingain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
            printf '%-84s' "$base"
            for k in before reference; do gain_gate $k "$base" ${ref#*|}; done
            echo
        done
    done
    echo "== chaingain: what the scale the test images would fit themselves leaves of the rms error over"
    echo "== the reference's rms, percent, a mean over a row's runs: no scale does better"
    printf '%-84s%7s%7s' "" "before" "ref."
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chaingain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do gain_best $k "$base"; done
        echo
    done
    echo "== chaingain: the class the tile gives against the class its declared reference gives, percent,"
    echo "== a row over its runs: with no scale, a mean and the runs at 99.5% or more; and with the scale,"
    echo "== a mean, the runs at 99.5% or more, and the least of any run"
    printf '%-84s %31s %31s' "" "before" "reference"
    echo
    sed 's/, draw [0-9]*|.*//' "$work/out/chaingain_settings.txt" | awk '!seen[$0]++' | while read -r base; do
        printf '%-84s' "$base"
        for k in before reference; do gain_class $k "$base"; done
        echo
    done
fi

# The first board's canary, as grxcp's B20 fixed it on 2026-10-14: MNIST
# pooled to 8 x 8, its first two layers the host's, at eight bits and trained
# with no tile noise, and its last trained for the tile at six bits, all three
# in one network from the same seed's 8-bit one, by the header's recipe for a
# reference network.  Seed 1's network is the canary, by a rule written before
# any was trained, and the other four are reported beside it.  Each is run as
# `chaingain` runs the reference networks: the format alone, the tile as
# budgeted, with its range fitted, lit, and lit and fitted, on 10,000 images
# and on the first thousand, the gate's own, with the scale `chaingain` fixes.
if [ "$what" = canary ]; then
    tile=${CANARY_TILE:-128x64}
    draws=${CANARY_DRAWS:-0 1 2 3 4}
    gopt="--rows ${tile%x*} --cols ${tile#*x}"
    all="quant,thermal,shot,prog,xtalk"
    # the tile's format, and the four rows of version 2's budget that add to it
    q="--abits 6 --adcbits 8"
    r="$q --thermal8 0.25 --photons8 30 --prog 1 --xtalk 0.02"
    f="--impair quant $q"
    b="--impair $all $r"
    cal=1000
    t="--host 2 --probe 1 --gate 1 --gatescale $cal"
    # the source's three rows, as grxcp's B16 has them, on B10's two buses
    src="--src 0.01 --srcline 0.05 --srcflat 0.2 --buses 2"
    fix="--levelprobe 16 --levelfix weights8"
    # the canary, by the rule written before any network was trained
    canary_seed=1
    # row|options.  Every row's name ends in its draw
    for dd in $draws; do
        for n in "" ", a thousand"; do
            i=
            [ -z "$n" ] || i=" --images 1000"
            echo "format only$n, draw $dd|$f$i"
            echo "as budgeted$n, draw $dd|$b$i"
            echo "as budgeted, fitted$n, draw $dd|$b$i --gatefit 1"
            echo "as budgeted, lit$n, draw $dd|$b$i $src $fix"
            echo "as budgeted, lit, fitted$n, draw $dd|$b$i $src $fix --gatefit 1"
        done
    done | sed "s/|--impair/|$gopt --impair/; s/\$/ $t/" > "$work/out/canary_settings.txt"
    # canary_start SEED: the seed's 8-bit network of two hidden layers, all of
    # it the tile's, unless it is already there: what the canary starts from
    canary_start() {
        local net="$PTA_WORK/nets/h2_d8_b8_s$1.net"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 8 \
            --seed "$1" --hidden 2 --out "$net" > "$net.log"
    }
    # canary_net SEED: the seed's canary network's file
    canary_net() { echo "h2_d8_b6_host2_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; }
    # canary_make SEED: the seed's canary network, from its 8-bit one: the
    # first two layers the host's, the last at six bits, noise on its sums
    canary_make() {
        local net="$PTA_WORK/nets/$(canary_net "$1")"
        [ -s "$net" ] || "$PTA_WORK/pta_mnist" train --data "$PTA_WORK/data" --din 8 --wbits 6 \
            --host 2 --seed "$1" --hidden 2 --from "$PTA_WORK/nets/h2_d8_b8_s$1.net" \
            --sumnoise "$PTA_REF_NOISE" --epochs "$PTA_REF_EPOCHS" --out "$net" > "$net.log"
    }
    # canary_one NET ROW ARGS...: one test-set pass and its calibration, its
    # line to out/canary.d/NET_ROW.txt
    canary_one() {
        local net=$1 row=$2
        shift 2
        mkdir -p "$PTA_WORK/out/canary.d"
        "$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" \
            > "$PTA_WORK/out/canary.d/$(basename "$net" .net)_$row.txt"
    }
    export -f canary_start canary_net canary_make canary_one
    # canary_row NAME: a row's name as a file's
    canary_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'canary_start "$@"' _
    for s in 1 2 3 4 5; do echo $s; done | xargs -P "$jobs" -L 1 bash -c 'canary_make "$@"' _
    while IFS='|' read -r name setting; do
        dd=${name##*, draw }
        for sd in 1 2 3 4 5; do echo "$(canary_net $sd) $(canary_row "$name") --seed $((sd + 10 * dd)) $setting"; done
    done < "$work/out/canary_settings.txt" | xargs -P "$jobs" -L 1 bash -c 'canary_one "$@"' _

    # canary_file SEED NAME: the file canary_one wrote for that run
    canary_file() { echo "$work/out/canary.d/$(basename "$(canary_net "$1")" .net)_$(canary_row "$2").txt"; }
    # Every network has to be the canary its seed says, and every run the row
    # its name says, as `chaingain` holds the reference networks' own.  A
    # network was trained from its seed's 8-bit one for the header's epochs,
    # its first two layers the host's: none of the noise on their sums and all
    # of it on the last layer's, at the header's figure, and its weights at six
    # bits.  A run's name says its draw, whether the tile is as budgeted or its
    # format alone, whether its range is training's or fitted, whether the
    # source is lit, and whether it is of a thousand images or of all, which
    # have to be what it was asked and what its line printed: the network's
    # first two layers the host's, as it was trained, and run at eight bits,
    # the impairments it names and no other at version 2's figures, a lit run's
    # source and its lines' reading as `chainlit` holds them, and a fitted
    # run's share, 1, and the shift training's rule had given.  Every run's
    # largest reference is the format alone's of the first draw, of as many
    # images, and so is the range of a run that is not fitted; the format alone
    # has no sum past its range wherever its reference is within its codes, and
    # is on every draw the run it is on the first.  And every run's scale was
    # fixed on a thousand images from image 54,000 on, and is within a
    # hundredth of the one the test images would fit themselves.
    canary_ok=yes
    canary_runs=0
    for sd in 1 2 3 4 5; do
        log="$work/nets/$(canary_net $sd).log"
        awk -v f="$PTA_REF_NOISE" -v e="$PTA_REF_EPOCHS" -v sd="$sd" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              n = split(v["got"], g, ",")
              ok = v["din"] == 8 && v["wbits"] == 6 && v["from"] == 8 && v["seed"] == sd && v["hidden"] == 2 &&
                   v["host"] == 2 && f == 0.1 && e == 8 && v["sumnoise"] == f + 0 && v["fixed_epochs"] == e &&
                   v["epochs"] == e && n == 3 && g[1] == 0 && g[2] == 0 && g[3] > 0.95 * f && g[3] < 1.05 * f &&
                   v["held_out"] > 50 && v["held_out"] <= 100 && v["digital"] > 50 && v["digital"] <= 100
              lines++ }
            END { exit !(lines == 1 && ok) }' "$log" || canary_ok=NO
        while IFS='|' read -r name setting; do
            first="format only"
            [ "${name%, a thousand, draw *}" = "$name" ] || first="format only, a thousand"
            cat "$log" "$(canary_file $sd "$first, draw ${draws%% *}")" \
                "$(canary_file $sd "${name%, draw *}, draw ${draws%% *}")" "$(canary_file $sd "$name")" |
            awk -v opts="$setting" -v tile="$tile" -v name="$name" -v sd="$sd" -v d0="${draws%% *}" '
                function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
                function asked(key) { return (key in given) ? want[key] + 0 : 0 }
                function has(key) { return (key in given) ? 1 : 0 }
                function figs() { return v["gate_rms"] " " v["gate_rmsfs"] " " v["gate_maxfs"] " " v["gate_agree"] " " \
                                         v["agree"] " " v["e3"] " " v["gate_scale"] " " v["gate_scale_rms"] " " \
                                         v["gate_scale_rmsfs"] " " v["gate_scale_maxfs"] " " v["gate_scale_agree"] " " \
                                         v["gate_scale_best"] " " v["gate_scale_best_rms"] }
                BEGIN { n = split(opts, o, " ")
                        for (i = 1; i < n; ++i) if (o[i] ~ /^--/) { want[substr(o[i], 3)] = o[i + 1]; given[substr(o[i], 3)] = 1 }
                        bit["quant"] = 1; bit["thermal"] = 2; bit["shot"] = 4; bit["drift"] = 8; bit["xtalk"] = 16; bit["prog"] = 64
                        m = split(want["impair"], im, ","); for (i = 1; i <= m; ++i) { mask += bit[im[i]]; on[im[i]] = 1 }
                        drawn = match(name, /, draw [0-9]+$/) ? 1 : 0
                        draw = drawn ? substr(name, RSTART + 7) + 0 : 0
                        base = drawn ? substr(name, 1, RSTART - 1) : name
                        few = (base ~ /, a thousand$/) ? 1 : 0
                        core = few ? substr(base, 1, length(base) - 12) : base
                        kind = 0; lit = 0
                        if (core ~ /, lit, fitted$/) { kind = 1; lit = 1; core = substr(core, 1, length(core) - 13) }
                        else if (core ~ /, lit$/) { lit = 1; core = substr(core, 1, length(core) - 5) }
                        else if (core ~ /, fitted$/) { kind = 1; core = substr(core, 1, length(core) - 8) }
                        fmt = (core == "format only") ? 1 : 0
                        tiled = (core == "as budgeted") ? 1 : 0
                        known = fmt + tiled == 1 && (tiled || (!lit && !kind))
                        split(tile, tt, "x"); per = 16 * int((64 + tt[1] - 1) / tt[1])
                        sane = drawn && known && m == (fmt ? 1 : 5) && ("quant" in on) &&
                               asked("abits") == 6 && asked("adcbits") == 8 &&
                               has("thermal8") == tiled && asked("thermal8") == 0.25 * tiled && (("thermal" in on) ? 1 : 0) == tiled &&
                               has("photons8") == tiled && asked("photons8") == 30 * tiled && (("shot" in on) ? 1 : 0) == tiled &&
                               has("prog") == tiled && asked("prog") == tiled && (("prog" in on) ? 1 : 0) == tiled &&
                               has("xtalk") == tiled && asked("xtalk") == 0.02 * tiled && (("xtalk" in on) ? 1 : 0) == tiled &&
                               !("drift" in on) && !has("drift") && !has("hours") && !has("calibrate") &&
                               !has("post-hours") && !has("trimstep") && !has("trimmax") && !has("wbits") && !has("seed") &&
                               has("src") == lit && asked("src") == 0.01 * lit &&
                               has("srcline") == lit && asked("srcline") == 0.05 * lit &&
                               has("srcflat") == lit && asked("srcflat") == 0.2 * lit &&
                               has("buses") == lit && asked("buses") == 2 * lit &&
                               has("levelprobe") == lit && asked("levelprobe") == 16 * lit &&
                               has("levelfix") == lit && (!lit || want["levelfix"] == "weights8") &&
                               !has("srcsign") && !has("levelref") && !has("levelpart") && !has("levellayer") &&
                               has("host") && asked("host") == 2 && has("probe") && asked("probe") == 1 &&
                               has("gate") && asked("gate") == 1 && has("images") == few && asked("images") == 1000 * few &&
                               has("gatefit") == kind && (!kind || asked("gatefit") == 1) && !has("gatebits") &&
                               has("gatescale") && asked("gatescale") == 1000 }
                { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] } }
                NR == 1 { digital = v["digital"]; epochs = v["epochs"] }
                NR == 2 { right = v["correct"]; gref = v["gate_ref"]; split(v["S"], s0, ","); was = s0[3]; peak0 = v["gate_peak"]
                          theirs = ("gate_ref" in v) && v["impair"] == "0x01" && v["seed"] == sd + 10 * d0 && v["net_seed"] == sd &&
                                   v["images"] == (few ? 1000 : 10000) && !("src" in v) && !("gate_fit" in v) && v["net_host"] == 2 }
                NR == 3 { own = v["correct"]; ofig = figs() }
                NR == 4 { ns = split(v["S"], sh, ","); n8 = split(v["S8"], s8, ",")
                          fig = figs()
                          ok = sane && theirs && v["tile"] == tile && v["net_seed"] == sd && v["seed"] == sd + 10 * draw &&
                               v["net_wbits"] == 6 && v["net_host"] == 2 && v["host_wbits"] == 8 && v["digital"] == digital &&
                               v["epochs"] == epochs &&
                               v["from"] == 8 && v["hidden"] == 2 && ns == 3 && v["impair"] == sprintf("0x%02x", mask) &&
                               v["abits"] == 6 && v["adcbits"] == 8 && v["wbits"] == (lit ? 8 : 6) && v["drift"] == "none" &&
                               v["hours"] == 0 && v["steps"] == 0 && v["cal"] == 0 && v["post_hours"] == 0 &&
                               near(v["trimstep"], 0.25, 1e-12) && v["trimmax"] == 128 && v["images"] == (few ? 1000 : 10000) &&
                               ("host" in v) && v["host"] == 2 &&
                               (("src" in v) ? 1 : 0) == lit && (("levelprobe" in v) ? 1 : 0) == lit &&
                               (("levelfix" in v) ? 1 : 0) == lit && !("levelpart" in v) &&
                               !("hidshift" in v) && !("thermalline" in v) && !("gate_adcbits" in v) &&
                               ("gate_bits" in v) && v["gate_bits"] == 6 && ("gate_rms" in v) && v["gate_rms"] > 0 &&
                               v["gate_peak"] > 0 && v["gate8_peak"] > 0 && v["gate_rmsfs"] > 0 &&
                               v["gate_rmsfs"] + 0 <= v["gate_maxfs"] + 0 && v["gate8_rmsfs"] + 0 <= v["gate8_maxfs"] + 0 &&
                               ("e1" in v) && ("e2" in v) && v["e1"] == 0 && v["e2"] == 0 && v["e3"] > 0 &&
                               ("gain" in v) && ("eres" in v) && ("elog" in v) && v["eres"] > 0 &&
                               v["eres"] + 0 <= v["elog"] + 0 && v["elog"] == v["e3"] &&
                               ("agree" in v) && ("ref" in v) && v["agree"] > 50 &&
                               ("sats" in v) && ("elements" in v) && v["elements"] == per * v["images"] &&
                               v["sats"] + 0 <= v["elements"] / 100 &&
                               ("gate_agree" in v) && ("gate_ref" in v) && v["gate_agree"] > 50 &&
                               v["gate_agree"] + 0 <= 100 && v["gate_ref"] == gref && v["gate_ref"] > 0 &&
                               v["gate_peak"] == peak0 && sh[1] == s0[1] && sh[2] == s0[2] && n8 == 3 &&
                               near(v["thermal8"], 0.25 * tiled, 1e-6) &&
                               (tiled ? near(v["photons8"] / 30, 1, 0.03) : v["photons8"] == 0) &&
                               near(v["prog"], tiled, 1e-9) &&
                               (tiled ? (near(v["xtalk"], 0.02, 1 / 512 + 1e-9) && v["xtalk"] > 0) : v["xtalk"] == 0)
                          # the scale
                          ok = ok && ("gate_scale" in v) && v["gate_scale_images"] == 1000 && v["gate_scale_first"] == 54000 &&
                               v["gate_scale"] > 0.5 && v["gate_scale"] < 1.5 && ("gate_scale_best" in v) &&
                               near(v["gate_scale"], v["gate_scale_best"], 0.01) && v["gate_scale_rms"] > 0 &&
                               v["gate_scale_best_rms"] + 0 <= v["gate_rms"] + 0.00001 &&
                               v["gate_scale_best_rms"] + 0 <= v["gate_scale_rms"] + 0.00001 &&
                               v["gate_scale_rmsfs"] + 0 <= v["gate_scale_maxfs"] + 0 &&
                               v["gate_scale_agree"] > 50 && v["gate_scale_agree"] + 0 <= 100
                          if (lit) ok = ok && v["src"] == 0.01 && v["srcline"] == 0.05 && v["srcflat"] == 0.2 &&
                                         v["buses"] == 2 && v["srcsign"] == "pair" &&
                                         v["levelprobe"] == 16 && near(v["level_found"], 0.2, 0.1) &&
                                         v["level_left"] > 0 && v["level_left"] + 0 < v["level_found"] / 4 &&
                                         v["levelfix"] == "weights8" && v["levelref"] == "none" && v["level_gain"] == 1 &&
                                         v["level_clip"] >= 0 && v["level_clip"] < 0.5
                          if (kind == 0) { ok = ok && !("gate_fit" in v) && !("gate_was" in v) && sh[3] == was && s8[3] == sh[3]
                                           if (fmt && int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= 127) ok = ok && v["sats"] == 0 }
                          else ok = ok && ("gate_fit" in v) && v["gate_fit"] == 1 && ("gate_was" in v) && v["gate_was"] == was &&
                                    int(v["gate_peak"] / 2 ^ sh[3] + 0.5) <= 127 &&
                                    (sh[3] == 0 || int(v["gate_peak"] / 2 ^ (sh[3] - 1) + 0.5) > 127) && s8[3] == sh[3]
                          if (fmt) ok = ok && v["correct"] == own && fig == ofig && own == right }
                END { exit !(NR == 4 && ok) }' || canary_ok=NO
            canary_runs=$((canary_runs + 1))
        done < "$work/out/canary_settings.txt"
    done
    echo "== canary: $canary_runs runs, each of them the network and the row its place says: $canary_ok"
    [ "$canary_ok" = yes ] || exit 1

    echo "== canary: the five networks, the canary seed $canary_seed's: trained from the seed's 8-bit network"
    echo "== for $PTA_REF_EPOCHS epochs, the first two layers the host's; held-out and test accuracy on the"
    echo "== host, percent; and the noise put on each layer's sums in the last epoch, of their rms"
    printf '%-16s %9s %9s %24s\n' "" "held out" "digital" "noise on the sums"
    for sd in 1 2 3 4 5; do
        awk -v sd="$sd" -v c="$canary_seed" '
            { for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              printf "%-16s %9.2f %9.2f %24s\n", "seed " sd (sd == c ? ", canary" : ""), v["held_out"], v["digital"], v["got"] }' \
            "$work/nets/$(canary_net $sd).log"
    done
    # canary_lines SEEDS BASE: a row's lines over its draws, the seeds given a draw
    canary_lines() {
        local sd dd
        for sd in $1; do
            for dd in $draws; do cat "$(canary_file $sd "$2, draw $dd")"; done
        done
    }
    # canary_fig SEEDS BASE: a row over its runs, means: the tile's accuracy;
    # how often its class is the declared reference's; the last layer's rms
    # error over the reference's rms, over the largest the reference is, and
    # its largest over that; the scale, and the rms error over the
    # reference's rms with it, all percent but the scale; and the runs at
    # 99.5% on the class and within 1.0%, 1.0% and 2.0% on the three
    canary_fig() {
        canary_lines "$1" "$2" | awk '
            { delete v; for (i = 1; i <= NF; ++i) { split($i, kv, "="); v[kv[1]] = kv[2] }
              a += v["acc"]; c = v["gate_agree"] + 0; cs += c; pc += (c >= 99.5)
              x = 100 * v["gate_rms"]; y = 100 * v["gate_rmsfs"]; z = 100 * v["gate_maxfs"]
              xs += x; ys += y; zs += z; px += (x <= 1.0); py += (y <= 1.0); pz += (z <= 2.0)
              s += v["gate_scale"]; w += 100 * v["gate_scale_rms"]; runs++ }
            END { printf " %6.2f %6.2f %6.3f %6.3f %6.3f %7.5f %6.3f %3d %3d %3d %3d", a / runs, cs / runs, xs / runs, ys / runs,
                         zs / runs, s / runs, w / runs, pc, px, py, pz }'
    }
    for who in "the canary, seed $canary_seed, over its draws|$canary_seed" "the five networks over their runs|1 2 3 4 5"; do
        echo "== canary: ${who%|*}: the tile's accuracy and the class the declared reference's,"
        echo "== percent; the last layer's error against its declared format, its rms over the reference's"
        echo "== rms, over the largest the reference is, and its largest over that, percent; the scale, and"
        echo "== the rms error with it; and the runs at 99.5% on the class and within 1.0%, 1.0% and 2.0%"
        printf '%-44s %6s %6s %6s %6s %6s %7s %6s %3s %3s %3s %3s\n' "" "acc" "class" "rms" "rmsfs" "max" "scale" "srms" "cl" "rms" "fs" "max"
        sed 's/, draw [0-9]*|.*//' "$work/out/canary_settings.txt" | awk '!seen[$0]++' | while read -r base; do
            printf '%-44s' "$base"
            canary_fig "${who#*|}" "$base"
            echo
        done
    done
fi

# The canary's golden tensors, as grxcp's B20 and the owner's rulings of
# 2026-10-14 fix them: the network `canary` trained for seed 1, the canary;
# the first thousand test images and the first thousand of the 6,000 held-out
# training images, the calibration set; FC3's declared reference the 8-bit
# converter's codes, at the step training's rule gives on the 128 x 64 tile.
# Written twice, each into a folder of its own, and the two have to be the
# same, byte for byte; the harness itself fails if any code is past the
# range, or if the tile with its format alone is not the declared reference.
if [ "$what" = golden ]; then
    net="$work/nets/h2_d8_b6_host2_s1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"
    [ -s "$net" ] || { echo "golden: $net is not there: run canary first" >&2; exit 2; }
    for r in a b; do
        mkdir -p "$work/out/golden.$r"
        "$work/pta_mnist" golden --data "$work/data" --net "$net" --out "$work/out/golden.$r" --abits 6 --adcbits 8 \
            --rows 128 --cols 64 --images 1000 --cal 1000 > "$work/out/golden.$r.txt"
    done
    cmp -s "$work/out/golden.a.txt" "$work/out/golden.b.txt" && diff -r "$work/out/golden.a" "$work/out/golden.b" > /dev/null ||
        { echo "golden: the two writings differ" >&2; exit 1; }
    echo "== golden: written twice, the same byte for byte: $(cat "$work/out/golden.a.txt")"
    (cd "$work/out/golden.a" && sha256sum -- *.bin)
    sha256sum "$net" | sed "s#$work/nets/##"
fi

# The band.  The canary, and the four other networks of its recipe, through
# the 128 x 64 tile with the last layer held to its converter's codes, as the
# owner ruled on 2026-10-14 (eval --gateref codes), and one scale fixed on the
# calibration set's thousand images from image 54,000.  The rows: the format
# alone; version 2's budget with no source; the same lit, with B16's source
# read and corrected on the weights at 8 bits, the board's own case; and lit
# with every row of the budget, the source's three among them, 0.4, 0.6, 0.8,
# 1.2 and 1.4 times its size.  The canary runs every row on BAND_DRAWS draws;
# the other four the budget's two rows on BAND_OTHER, and the format alone on
# one, which draws nothing.  A draw is another run of the same thousand
# vectors: the tile programmed again at every load of its weights, and every
# shot's noise and the source's drawn again.  The band itself is grxcp's to
# propose from these lines and the owner's to rule; here are the lines, the
# check that each is the run its place says, and the tables.
if [ "$what" = band ]; then
    draws=${BAND_DRAWS:-1000}
    other=${BAND_OTHER:-100}
    canary_seed=1
    [ "$draws" -ge 1 ] && [ "$other" -ge 1 ] && [ "$other" -le "$draws" ] ||
        { echo "band: BAND_DRAWS and BAND_OTHER are counts, and BAND_OTHER is no more than BAND_DRAWS" >&2; exit 2; }
    [ -s "$work/out/golden.a.txt" ] ||
        { echo "band: run golden first: the canary's reference is held to its line" >&2; exit 2; }
    band_net() { echo "h2_d8_b6_host2_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}.net"; }
    for sd in 1 2 3 4 5; do
        [ -s "$work/nets/$(band_net $sd)" ] || { echo "band: $(band_net $sd) is not there: run canary first" >&2; exit 2; }
    done
    q="--rows 128 --cols 64 --abits 6 --adcbits 8"
    t="--images 1000 --host 2 --probe 1 --gate 1 --gatescale 1000 --gateref codes"
    all="quant,thermal,shot,prog,xtalk"
    # band_budget F, band_source F: version 2's four rows, and B16's source
    # and the reading of its lines, each row F times its size: the noise's
    # sigma and the crosstalk times F, and so the photons over F squared
    band_budget() { awk -v f="$1" 'BEGIN { printf "--thermal8 %g --photons8 %g --prog %g --xtalk %g", 0.25 * f, 30 / (f * f), f, 0.02 * f }'; }
    band_source() { awk -v f="$1" 'BEGIN { printf "--src %g --srcline %g --srcflat %g --buses 2 --levelprobe 16 --levelfix weights8", 0.01 * f, 0.05 * f, 0.2 * f }'; }
    {
        echo "format only|--impair quant"
        echo "as budgeted|--impair $all $(band_budget 1)"
        echo "as budgeted, lit|--impair $all $(band_budget 1) $(band_source 1)"
        for f in 0.4 0.6 0.8 1.2 1.4; do
            echo "lit, $f of the budget|--impair $all $(band_budget $f) $(band_source $f)"
        done
        echo "as budgeted, lit, ten sources|--impair $all $(band_budget 1) $(band_source 1)"
    } | sed "s/|/|$q /; s/\$/ $t/" > "$work/out/band_settings.txt"
    # band_row NAME: a row's name as a file's
    band_row() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    # band_one NET ROW DRAW ARGS...: one run, its line to out/band.d/NET_ROW_dDRAW.txt.  A
    # lit run whose source has a line all but dark, which the reading of its lines cannot
    # correct, is refused, as a board's calibration would refuse that source, and its file
    # says so; any other failure is the sweep's
    band_one() {
        local net=$1 row=$2 dd=$3 out err
        shift 3
        out="$PTA_WORK/out/band.d/$(basename "$net" .net)_${row}_d$dd.txt"
        if ! err=$("$PTA_WORK/pta_mnist" eval --data "$PTA_WORK/data" --net "$PTA_WORK/nets/$net" "$@" 2>&1 > "$out"); then
            [ "$err" = "pta_mnist: --levelfix could not be applied: a line was read under a twentieth of its level" ] ||
                { echo "$err" >&2; return 1; }
            echo "refused=dark_line" > "$out"
        fi
    }
    export -f band_one
    mkdir -p "$work/out/band.d"
    while IFS='|' read -r name setting; do
        n=$draws
        [ "$name" = "format only" ] && n=1
        for ((dd = 0; dd < n; ++dd)); do
            for sd in 1 2 3 4 5; do
                if [ "$sd" != "$canary_seed" ]; then
                    [ "$dd" -lt "$other" ] || continue
                    case "$name" in "format only"|"as budgeted"|"as budgeted, lit") ;; *) continue ;; esac
                fi
                # the ten sources: the lit row's first ten draws' line levels, a draw's
                # the one its draw's last digit says, on every draw's own shots
                extra=
                [ "$name" = "as budgeted, lit, ten sources" ] && extra=" --lightseed $((sd + 10 * (dd % 10)))"
                echo "$(band_net $sd) $(band_row "$name") $dd --seed $((sd + 10 * dd)) $setting$extra"
            done
        done
    done < "$work/out/band_settings.txt" | xargs -P "$jobs" -L 1 bash -c 'band_one "$@"' _

    # Every run has to be the one its place says, and no other line may be
    # there.  A run's file names its network, row and draw.  Its line has to
    # be that network, trained as `canary` trained it, its first two layers
    # the host's at eight bits; on the draw's seed; with the row's
    # impairments and no other, each at its factor of version 2's figure,
    # the crosstalk to its 1/256 step and the photons to 6%, and a lit row's
    # source and the reading of its lines; the reference in codes, at the
    # step training's rule gives its network, the canary's the golden line's; and
    # the scale fixed on a thousand images from 54,000, within a hundredth of
    # the one the test images would fit themselves.  Every run's largest
    # reference, and how often that reference is right, are its network's
    # with the format alone, and the canary's is the golden line's.  The
    # format alone is its reference exactly: no error, no output a code off,
    # every class, a scale of one, and the tile's accuracy the reference's.
    # A tail falls as it goes, and says what the largest error says.
    {
        printf 'GOLDEN\t%s\n' "$(cat "$work/out/golden.a.txt")"
        awk '{ print "SET\t" $0 }' "$work/out/band_settings.txt"
        find "$work/out/band.d" -name '*.txt' -print0 | sort -z | xargs -0 awk '{ print FILENAME "\t" $0 }'
    } > "$work/out/band_lines.txt"
    band_ok=$(awk -v draws="$draws" -v other="$other" -v c="$canary_seed" -v noise="$PTA_REF_NOISE" -v ep="$PTA_REF_EPOCHS" '
        function near(a, b, tol,    d) { d = a - b; if (d < 0) d = -d; return d <= tol }
        function parse(text,    n, i, kv, f) { delete v; n = split(text, f, " "); for (i = 1; i <= n; ++i) { split(f[i], kv, "="); v[kv[1]] = kv[2] } }
        function san(x) { gsub(/[^A-Za-z0-9]/, "_", x); return x }
        function tail_ok(list, top,    tt, j, n) {
            n = split(list, tt, ",")
            if (n != 32 || tt[1] > 16000) return 0
            for (j = 1; j <= 32; ++j) {
                if (j > 1 && tt[j] + 0 > tt[j - 1] + 0) return 0
                if (top > j - 0.5 + 0.01 && tt[j] + 0 == 0) return 0
                if (top < j - 0.5 - 0.01 && tt[j] + 0 != 0) return 0
            }
            return 1 }
        BEGIN { FS = "\t"
                want[1] = "format only"; want[2] = "as budgeted"; want[3] = "as budgeted, lit"
                want[4] = "lit, 0.4 of the budget"; want[5] = "lit, 0.6 of the budget"; want[6] = "lit, 0.8 of the budget"
                want[7] = "lit, 1.2 of the budget"; want[8] = "lit, 1.4 of the budget"; want[9] = "as budgeted, lit, ten sources"
                fac[1] = 0; fac[2] = 1; fac[3] = 1; fac[4] = 0.4; fac[5] = 0.6; fac[6] = 0.8; fac[7] = 1.2; fac[8] = 1.4; fac[9] = 1
                for (i = 1; i <= 9; ++i) { islit[i] = i >= 3; rowof[san(want[i])] = i }
                none = "0"; for (j = 2; j <= 32; ++j) none = none ",0" }
        $1 == "GOLDEN" { parse($2); gright = v["declared_right"]; gstep = v["S"]; gseed = v["net_seed"]; next }
        $1 == "SET" { split($2, p, "|"); ++rows; if (p[1] != want[rows]) badset = 1; next }
        { f = $1; sub(/.*\//, "", f)
          if (!match(f, /_d[0-9]+\.txt$/)) { ++stray; next }
          dd = substr(f, RSTART + 2, RLENGTH - 6) + 0; stem = substr(f, 1, RSTART - 1)
          if (!match(stem, /^h2_d8_b6_host2_s[0-9]+_n[0-9.]+_e[0-9]+_/)) { ++stray; next }
          pre = substr(stem, 1, RLENGTH); r = substr(stem, RLENGTH + 1)
          if (pre != "h2_d8_b6_host2_s" substr(pre, 17, 1) "_n" noise "_e" ep "_" || !(r in rowof)) { ++stray; next }
          sd = substr(pre, 17, 1) + 0; i = rowof[r]; k = sd SUBSEP i SUBSEP dd
          if (k in got) ++twice
          else ++ngot
          got[k] = $2 }
        END {
          ok = rows == 9 && !badset && !stray && !twice && gseed == c && gstep > 0 && gright > 0
          expect = 0
          for (sd = 1; sd <= 5; ++sd) {
              k = sd SUBSEP 1 SUBSEP 0
              if (!(k in got)) { ok = 0; continue }
              parse(got[k]); fpeak[sd] = v["gate_peak"]; fref[sd] = v["gate_ref"]; facc[sd] = v["acc"]
              split(v["S"], fs, ","); fstep[sd] = fs[3] }
          ok = ok && fref[c] == gright && facc[c] == gright && fstep[c] == gstep
          for (i = 1; i <= 9; ++i) for (sd = 1; sd <= 5; ++sd) {
              n = (i == 1) ? 1 : (sd == c ? draws : (i <= 3 ? other : 0))
              for (dd = 0; dd < n; ++dd) {
                  ++expect; k = sd SUBSEP i SUBSEP dd
                  if (!(k in got)) { ok = 0; continue }
                  parse(got[k]); fm = fac[i]; lit = islit[i]; fmt = i == 1
                  # a refused run: lit, and refused for a line all but dark, and nothing else on its line
                  if ("refused" in v) { ++refused[i]
                                        if (!lit || v["refused"] != "dark_line" || got[k] != "refused=dark_line") {
                                            ok = 0; if (++shown <= 5) print "band: refused where it may not be: " want[i] ", seed " sd ", draw " dd > "/dev/stderr" }
                                        if (i == 9) { k3 = sd SUBSEP 3 SUBSEP dd; if (dd < 10 && (k3 in got)) { ok = ok && got[k] == got[k3]; ++same3 } }
                                        continue }
                  ns = split(v["S"], sh, ",")
                  good = v["net_seed"] == sd && v["seed"] == sd + 10 * dd && v["net_wbits"] == 6 && v["net_host"] == 2 &&
                         v["host_wbits"] == 8 && v["host"] == 2 && v["hidden"] == 2 && v["din"] == 8 && v["from"] == 8 &&
                         v["epochs"] == ep && v["tile"] == "128x64" && v["abits"] == 6 && v["adcbits"] == 8 &&
                         v["images"] == 1000 && v["drift"] == "none" && v["hours"] == 0 && v["cal"] == 0 &&
                         v["post_hours"] == 0 && v["wbits"] == (lit ? 8 : 6) && ns == 3 &&
                         v["gate_bits"] == 6 && ("gate_codes" in v) && v["gate_codes"] == sh[3] && sh[3] == fstep[sd] &&
                         !("gate_fit" in v) && !("gate_adcbits" in v) && !("levelpart" in v) && !("thermalline" in v) &&
                         !("hidshift" in v) && v["e1"] == 0 && v["e2"] == 0 && v["e3"] > 0 &&
                         v["gate_peak"] == fpeak[sd] && v["gate_ref"] == fref[sd] &&
                         v["gate_scale_images"] == 1000 && v["gate_scale_first"] == 54000 &&
                         tail_ok(v["gate_tail"], v["gate_maxcode"] + 0) && tail_ok(v["gate_scale_tail"], v["gate_scale_maxcode"] + 0) &&
                         v["impair"] == (fmt ? "0x01" : "0x57") &&
                         near(v["thermal8"], 0.25 * fm, 0.004) && near(v["prog"], fm, 1 / 256) &&
                         (fmt ? v["photons8"] == 0 : near(v["photons8"] * fm * fm / 30, 1, 0.06)) &&
                         (fmt ? v["xtalk"] == 0 : near(v["xtalk"], 0.02 * fm, 1 / 512 + 1e-9) && v["xtalk"] > 0) &&
                         (("src" in v) ? 1 : 0) == lit && (("levelprobe" in v) ? 1 : 0) == lit && (("levelfix" in v) ? 1 : 0) == lit &&
                         (("lightseed" in v) ? 1 : 0) == (i == 9)
                  # the ten sources: the levels of a draw are those of the lit row on the draw of its
                  # last digit, and on that draw itself the run is the lit run, but for the field
                  if (i == 9) { good = good && v["lightseed"] == sd + 10 * (dd % 10) && near(v["light_levels"], 0.2, 0.1)
                                if ((dd % 10) in levels) good = good && v["light_levels"] == levels[dd % 10]
                                else { levels[dd % 10] = v["light_levels"]; for (j in seen) if (seen[j] == v["light_levels"]) good = 0
                                       seen[dd % 10] = v["light_levels"] }
                                k3 = sd SUBSEP 3 SUBSEP dd
                                if (dd < 10 && (k3 in got)) { x = got[k]; sub(/ lightseed=[0-9]+ light_levels=[0-9.]+/, "", x)
                                                               good = good && x == got[k3]; ++same3 } }
                  if (lit) good = good && near(v["src"], 0.01 * fm, 1e-9) && near(v["srcline"], 0.05 * fm, 1e-9) &&
                                  near(v["srcflat"], 0.2 * fm, 1e-9) && v["buses"] == 2 && v["srcsign"] == "pair" &&
                                  v["levelprobe"] == 16 && near(v["level_found"], 0.2 * fm, 0.1 * fm) && v["level_left"] >= 0 &&
                                  v["level_left"] + 0 < v["level_found"] / 4 && v["levelfix"] == "weights8" &&
                                  v["levelref"] == "none" && v["level_gain"] == 1
                  if (fmt) good = good && v["gate_rms"] == 0 && v["gate_maxcode"] == 0 && v["gate_tail"] == none &&
                                  v["gate_agree"] == 100 && v["gate_scale"] == 1 && v["gate_scale_rms"] == 0 &&
                                  v["gate_scale_maxcode"] == 0 && v["gate_scale_tail"] == none &&
                                  v["gate_scale_agree"] == 100 && v["sats"] == 0 && v["acc"] == v["gate_ref"]
                  else good = good && v["gate_rms"] > 0 && v["gate_scale_rms"] > 0 && v["gate_maxcode"] > 0 &&
                                  near(v["gate_scale"], v["gate_scale_best"], 0.01) &&
                                  v["gate_scale_best_rms"] + 0 <= v["gate_scale_rms"] + 0.00001 &&
                                  v["gate_scale_best_rms"] + 0 <= v["gate_rms"] + 0.00001 &&
                                  v["gate_agree"] > 50 && v["gate_agree"] + 0 <= 100 &&
                                  v["gate_scale_agree"] > 50 && v["gate_scale_agree"] + 0 <= 100 &&
                                  v["sats"] + 0 <= v["elements"] / 100
                  if (!good) { ok = 0; if (++shown <= 5) print "band: not the run its place says: " want[i] ", seed " sd ", draw " dd > "/dev/stderr" }
              } }
          for (i = 1; i <= 9; ++i) out = out " " (refused[i] + 0)
          printf "%d %s%s", expect, (ok && expect == ngot && same3 == (draws < 10 ? draws : 10)) ? "yes" : "NO", out }' "$work/out/band_lines.txt")
    read -r band_runs band_ok band_refused <<< "$band_ok"
    echo "== band: $band_runs runs, each of them the network, the row and the draw its place says: $band_ok"
    [ "$band_ok" = yes ] || exit 1
    rows=$(sed 's/|.*//' "$work/out/band_settings.txt")
    echo "== band: runs refused for a line of the source all but dark when the lines were read, which"
    echo "== the reading cannot correct, as a board's calibration would refuse that source: each row's"
    echo "== runs on every network, and of them refused.  The tables after are over the runs that ran"
    printf '%-30s %6s %8s\n' "" "runs" "refused"
    i=0
    for r in $band_refused; do
        i=$((i + 1))
        case $i in 1) n=5 ;; 2|3) n=$((draws + 4 * other)) ;; *) n=$draws ;; esac
        printf '%-30s %6d %8d\n' "$(sed -n "${i}p" <<< "$rows")" "$n" "$r"
    done

    # band_vals SEED ROW FIELD [DRAWS]: the field over the row's draws, or its
    # first DRAWS of them, one a line, in the order of the files' names
    band_vals() {
        awk -F'\t' -v want="_s$1_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}_$(band_row "$2")_d" -v k="$3" -v most="${4:-1000000000}" '
            index($1, want) { d = substr($1, index($1, want) + length(want)); sub(/\.txt$/, "", d)
                              if (d + 0 >= most + 0) next
                              n = split($2, f, " "); for (i = 1; i <= n; ++i) if (index(f[i], k "=") == 1) print substr(f[i], length(k) + 2) }' \
            "$work/out/band_lines.txt"
    }
    # band_dist SEED ROW FIELD SCALE: the field times SCALE over the row's draws:
    # mean, standard deviation, smallest, 1st percentile, median, 99th
    # percentile and largest; a percentile p is the ceil(pn)'th smallest
    band_dist() {
        band_vals "$1" "$2" "$3" | awk -v s="$4" '{ print $1 * s }' | sort -g | awk '
            { x[++n] = $1; t += $1; t2 += $1 * $1 }
            function at(p,    k) { k = int(p * n); if (k < p * n) ++k; if (k < 1) k = 1; return x[k] }
            END { m = t / n; sd = n > 1 ? sqrt((t2 - n * m * m) / (n - 1)) : 0
                  printf " %7.3f %6.3f %7.3f %7.3f %7.3f %7.3f %7.3f", m, sd, x[1], at(0.01), at(0.5), at(0.99), x[n] }'
    }
    echo "== band: the format alone, each network: how often its reference, FC3's codes, is right, and the"
    echo "== tile's accuracy, percent; its rms error over the reference's rms, its largest error in codes,"
    echo "== and the scale"
    printf '%-16s %8s %8s %8s %8s %8s\n' "" "ref" "acc" "rms" "max" "scale"
    for sd in 1 2 3 4 5; do
        awk -F'\t' -v want="_s${sd}_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}_format_only_d0.txt" -v sd="$sd" -v c="$canary_seed" '
            index($1, want) { n = split($2, f, " "); for (i = 1; i <= n; ++i) { split(f[i], kv, "="); v[kv[1]] = kv[2] }
                              printf "%-16s %8.2f %8.2f %8.3f %8.2f %8.5f\n", "seed " sd (sd == c ? ", canary" : ""), v["gate_ref"], v["acc"],
                                     100 * v["gate_rms"], v["gate_maxcode"], v["gate_scale"] }' "$work/out/band_lines.txt"
    done
    echo "== band: the canary, seed $canary_seed, over its $draws draws: the last layer's rms error over its"
    echo "== reference's rms with the scale, percent: mean, standard deviation, smallest, 1st percentile,"
    echo "== median, 99th percentile and largest"
    printf '%-30s %7s %6s %7s %7s %7s %7s %7s\n' "" "mean" "sd" "least" "1%" "median" "99%" "most"
    echo "$rows" | while read -r row; do
        [ "$row" = "format only" ] && continue
        printf '%-30s' "$row"; band_dist "$canary_seed" "$row" gate_scale_rms 100; echo
    done
    echo "== band: the same without the scale"
    printf '%-30s %7s %6s %7s %7s %7s %7s %7s\n' "" "mean" "sd" "least" "1%" "median" "99%" "most"
    echo "$rows" | while read -r row; do
        [ "$row" = "format only" ] && continue
        printf '%-30s' "$row"; band_dist "$canary_seed" "$row" gate_rms 100; echo
    done
    echo "== band: the canary: how often the class with the scale is the reference's, percent, and the"
    echo "== largest error in codes with the scale, over its draws"
    printf '%-38s %7s %6s %7s %7s %7s %7s %7s\n' "" "mean" "sd" "least" "1%" "median" "99%" "most"
    echo "$rows" | while read -r row; do
        [ "$row" = "format only" ] && continue
        printf '%-38s' "$row: class"; band_dist "$canary_seed" "$row" gate_scale_agree 1; echo
        printf '%-38s' "$row: largest"; band_dist "$canary_seed" "$row" gate_scale_maxcode 1; echo
    done
    echo "== band: the canary: outputs of the 16,000 a run that are t or more codes off with the scale,"
    echo "== to the nearest code: the mean over its draws, and the most"
    sel="1 2 3 4 6 8 12 16 20 24 28 32"
    printf '%-30s' ""; for tt in $sel; do printf ' %12s' "t=$tt"; done; echo
    echo "$rows" | while read -r row; do
        [ "$row" = "format only" ] && continue
        printf '%-30s' "$row"
        band_vals "$canary_seed" "$row" gate_scale_tail | awk -F, -v sel="$sel" '
            { for (j = 1; j <= 32; ++j) { s[j] += $j; if ($j + 0 > m[j]) m[j] = $j + 0 } ++n }
            END { k = split(sel, at, " "); for (i = 1; i <= k; ++i) printf " %7.1f %4d", s[at[i]] / n, m[at[i]] }'
        echo
    done
    echo "== band: the five networks on the first $other draws of the budget's two rows: the rms error with"
    echo "== the scale, percent, and the class with it, over each network's draws"
    printf '%-26s %-16s %7s %6s %7s %7s %7s %7s\n' "" "" "mean" "sd" "least" "most" "class" "least"
    for row in "as budgeted" "as budgeted, lit"; do
        for sd in 1 2 3 4 5; do
            printf '%-26s %-16s' "$row" "seed $sd$([ "$sd" = "$canary_seed" ] && echo ", canary")"
            paste -d' ' <(band_vals "$sd" "$row" gate_scale_rms "$other") \
                        <(band_vals "$sd" "$row" gate_scale_agree "$other") | awk '
                { x = 100 * $1; t += x; t2 += x * x; if (n == 0 || x < lo) lo = x; if (n == 0 || x > hi) hi = x
                  c += $2; if (n == 0 || $2 + 0 < cl) cl = $2 + 0; ++n }
                END { m = t / n; printf " %7.3f %6.3f %7.3f %7.3f %7.2f %7.2f", m, sqrt((t2 - n * m * m) / (n - 1)), lo, hi, c / n, cl }'
            echo
        done
    done
    echo "== band: the canary lit at its budget on ten sources, the lit row's first ten draws' line"
    echo "== levels, a draw's the one its last digit says: the rms error with the scale, percent, over"
    echo "== each source's repeats; and the standard deviation from repeat to repeat, pooled within a"
    echo "== source, against that of the ten sources' means"
    printf '%-26s %5s %7s %6s %7s %7s\n' "" "runs" "mean" "sd" "least" "most"
    awk -F'\t' -v want="_s${canary_seed}_n${PTA_REF_NOISE}_e${PTA_REF_EPOCHS}_$(band_row "as budgeted, lit, ten sources")_d" '
        index($1, want) { d = substr($1, index($1, want) + length(want)); sub(/\.txt$/, "", d); g = d % 10
                          x = ""; n = split($2, f, " "); for (i = 1; i <= n; ++i) if (index(f[i], "gate_scale_rms=") == 1) x = 100 * substr(f[i], 16)
                          if (x == "") next
                          ++c[g]; s[g] += x; s2[g] += x * x
                          if (c[g] == 1 || x < lo[g]) lo[g] = x
                          if (c[g] == 1 || x > hi[g]) hi[g] = x
                          ++N }
        END { for (g = 0; g < 10; ++g) if (c[g]) {
                  m = s[g] / c[g]; w += s2[g] - c[g] * m * m; ++K; mm += m; mm2 += m * m
                  printf "%-26s %5d %7.3f %6.3f %7.3f %7.3f\n", "source " g, c[g], m, (c[g] > 1 ? sqrt((s2[g] - c[g] * m * m) / (c[g] - 1)) : 0), lo[g], hi[g] }
              bm = mm / K
              printf "%-26s %5d %7.3f %6.3f\n", "repeat to repeat", N, bm, (N > K ? sqrt(w / (N - K)) : 0)
              printf "%-26s %5d %7.3f %6.3f\n", "source to source", K, bm, (K > 1 ? sqrt((mm2 - K * bm * bm) / (K - 1)) : 0) }' \
        "$work/out/band_lines.txt"
fi

exit $((gate_status | ablate_status))
