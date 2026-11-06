#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# rebased_pipeline.sh -- fill -> stream-out -> PDN stitch -> CDL for the corrected netlist's DEF.
#
# Runs on the build server against ~/rebased (P&R tree) with the September LVS tree mounted at
# /work/c930/asic_gf180mcu for the LEF, the artifact GDS and the PDK cell GDS.  Every step takes
# its paths explicitly, so nothing here overwrites the September die or its CDL.
#
#   bash build/rebased_pipeline.sh            # DEFS from ~/rebased/build/grx930_test_chip.def
#   bash build/rebased_pipeline.sh --lvs      # ... and then start the 12,300-bound comparison
set -u

R=/home/ubuntu/rebased
S=/home/ubuntu/grx930/c930/asic_gf180mcu
IMG=ghcr.io/efabless/openlane2:2.3.10
WORK=$R/build/lvs_chip
DEF=$R/build/grx930_test_chip.def
ROUTED=$R/build/grx930_test_chip_routed.v
DO_LVS=0
[ "${1:-}" = "--lvs" ] && DO_LVS=1

mkdir -p "$WORK"
rc=0
step() { echo; echo "=== $*"; }

# Every script runs inside the flow image with the P&R tree at /work and the September tree at
# /work/c930/asic_gf180mcu (LEF, artifact GDS, PDK cell GDS, library CDL).
run() {
    MSYS_NO_PATHCONV=1 docker run --rm \
        -v "$R:/work" -v "$S:/work/c930/asic_gf180mcu" -w /work "$IMG" "$@"
}

step "DEF"
[ -s "$DEF" ] || { echo "no DEF at $DEF -- P&R has not written it"; exit 2; }
echo "components: $(awk '/^COMPONENTS/{f=1;next}/^END COMPONENTS/{f=0}f' "$DEF" | grep -c '^- ')"
echo "nets:       $(awk '/^NETS/{f=1;next}/^END NETS/{f=0}f' "$DEF" | grep -c '^ *- ')"
echo "routed:     $(grep -c '+ ROUTED' "$DEF")"

step "fill (metal1-aware fillers + well taps)"
run python3 c930/asic_gf180mcu/tools/lvs_chip/fill_def.py \
    --def /work/build/grx930_test_chip.def \
    --lef /work/c930/asic_gf180mcu/build/cells.lef \
    --out /work/build/lvs_chip/filled.def 2>&1 | tee "$WORK/fill.log"
rc=${PIPESTATUS[0]}; [ "$rc" -eq 0 ] || { echo "fill refused/failed ($rc)"; exit "$rc"; }

step "stream out (DEF cells, NETS/SPECIALNETS routing and vias at the DEF's die frame)"
run python3 c930/asic_gf180mcu/tools/lvs_chip/stream_out.py \
    --def /work/build/lvs_chip/filled.def \
    --lef /work/c930/asic_gf180mcu/build/cells.lef \
    --routing def \
    --out /work/build/lvs_chip/stream_out_filled.gds 2>&1 | tee "$WORK/stream.log"
rc=${PIPESTATUS[0]}; [ "$rc" -eq 0 ] || { echo "stream_out refused/failed ($rc)"; exit "$rc"; }

step "PDN stitch (metal1 islands -> metal3 grid)"
run python3 c930/asic_gf180mcu/tools/lvs_chip/pdn_stitch.py \
    --def /work/build/lvs_chip/filled.def \
    --gds /work/build/lvs_chip/stream_out_filled.gds \
    --out-gds /work/build/lvs_chip/stream_out_filled_stitched.gds \
    --report /work/build/lvs_chip/strap_report.json 2>&1 | tee "$WORK/stitch.log"
rc=${PIPESTATUS[0]}; [ "$rc" -eq 0 ] || { echo "pdn_stitch refused/failed ($rc)"; exit "$rc"; }

step "CDL (routed netlist)"
[ -s "$ROUTED" ] || { echo "no routed netlist at $ROUTED"; exit 2; }
run python3 c930/asic_gf180mcu/tools/lvs_chip/mk_chip_cdl.py \
    --routed /work/build/grx930_test_chip_routed.v \
    --out /work/build/lvs_chip/grx930_test_chip.cdl 2>&1 | tee "$WORK/cdl.log"
rc=${PIPESTATUS[0]}; [ "$rc" -eq 0 ] || { echo "mk_chip_cdl refused/failed ($rc)"; exit "$rc"; }

step "stage into the September tree (the LVS wrapper only mounts its own root)"
cp "$WORK/stream_out_filled_stitched.gds" "$S/build/lvs_chip/rebased_stream_out_filled_stitched.gds"
cp "$WORK/grx930_test_chip.cdl"           "$S/build/lvs_chip/rebased_grx930_test_chip.cdl"
ls -la "$S/build/lvs_chip/rebased_"*

if [ "$DO_LVS" -eq 1 ]; then
    step "LVS 12,300 bounds"
    cd "$S" || exit 2
    bash build/lvs_chip_bounds_test.sh "${LVS_TAG:-rebased-b12300}" --branch 12300 --threads 8 \
        --layout build/lvs_chip/rebased_stream_out_filled_stitched.gds \
        --netlist build/lvs_chip/rebased_grx930_test_chip.cdl
fi

step "done"
echo "filled DEF:   $WORK/filled.def"
echo "stitched GDS: $WORK/stream_out_filled_stitched.gds"
echo "chip CDL:     $WORK/grx930_test_chip.cdl"
