#!/usr/bin/env bash
# Wait for the corrected die's layout, stage it inside the September tree, and run the extraction
# census -- the layout-side device and net counts, independent of the comparison.  Falls back to
# the filled (unstitched) or unfilled stream if a later pipeline step refuses, so the device count
# is still measured rather than lost with the step.
set -u
S=/home/ubuntu/grx930/c930/asic_gf180mcu
R=/home/ubuntu/rebased
W=$R/build/lvs_chip
IMG=ghcr.io/efabless/openlane2:2.3.10
cd "$S" || exit 2
echo "census watch $(date -u)"
for i in $(seq 1 500); do
    [ -s "$W/stream_out_filled_stitched.gds" ] && break
    [ -s "$W/stream_out_filled.gds" ] && break
    [ -s "$R/build/grx930_test_chip.def" ] && break
    sleep 30
done

GDS=""; TAG=""
if [ -s "$W/stream_out_filled_stitched.gds" ]; then
    GDS=$W/stream_out_filled_stitched.gds; TAG=stitched
elif [ -s "$W/stream_out_filled.gds" ]; then
    GDS=$W/stream_out_filled.gds; TAG=filled
elif [ -s "$R/build/grx930_test_chip.def" ]; then
    echo "[[FALLBACK: stream the DEF without fill/stitch]] $(date -u)"
    MSYS_NO_PATHCONV=1 docker run --rm -v "$R:/work" -v "$S:/work/c930/asic_gf180mcu" -w /work "$IMG" \
        python3 c930/asic_gf180mcu/tools/lvs_chip/stream_out.py \
        --def /work/build/grx930_test_chip.def \
        --out /work/build/lvs_chip/stream_out_unfilled.gds > "$W/stream_unfilled.log" 2>&1
    echo "stream rc=$?"
    [ -s "$W/stream_out_unfilled.gds" ] && { GDS=$W/stream_out_unfilled.gds; TAG=unfilled; }
fi
if [ -z "$GDS" ]; then
    echo "[[NO GDS]] $(date -u)"
    echo "--- pipeline log tail"; tail -25 "$R/rebased_run.log"
    exit 1
fi

CDL=$W/grx930_test_chip.cdl
[ -s "$CDL" ] || CDL=$R/build/cdl_from_synth.cdl
[ -s "$CDL" ] || { echo "[[NO CDL]]"; exit 1; }

echo "[[LAYOUT STAGED]] tag=$TAG gds=$GDS cdl=$CDL $(date -u)"
cp "$GDS" "build/lvs_chip/rebased_stream_out_$TAG.gds"
cp "$CDL" build/lvs_chip/rebased_grx930_test_chip.cdl
ls -la build/lvs_chip/rebased_*
bash build/lvs_chip_census.sh "rebased-census-$TAG" \
    --layout "build/lvs_chip/rebased_stream_out_$TAG.gds" \
    --netlist build/lvs_chip/rebased_grx930_test_chip.cdl --threads 8 \
    > build/lvs_chip/rebased_census_driver.log 2>&1
echo "census rc=$?"
cat "build/lvs_chip/evidence_census/rebased-census-$TAG/census.txt" 2>/dev/null
echo "[[CENSUS DONE]] $(date -u)"
