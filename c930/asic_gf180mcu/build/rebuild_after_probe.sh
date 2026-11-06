#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# rebuild_after_probe.sh -- wait for the placement probe, then rebuild the die with well taps.
#
# The probe (openroad with TAP_PROBE=1) stops after `tapcell` and writes build/place_tap_probe.def.
# If it completed and put fillties down, the current DEF and routed netlist are moved aside and the
# full flow runs: place (with taps) -> route -> DEF. Then the fill/stream/stitch/CDL pipeline and
# LVS under a new tag, so the unlabelled 752-device baseline is not overwritten.
#
#   setsid bash build/rebuild_after_probe.sh > build/rebuild_tap.log 2>&1 &
set -u

R=/home/ubuntu/rebased
S=/home/ubuntu/grx930/c930/asic_gf180mcu
IMG=ghcr.io/efabless/openlane2:2.3.10
TAG=rebased-tap-b12300
# The PDK is not a real directory in this tree: the flow expects it at /work/gf180mcu_pdk, so it
# has to be mounted separately or the first read_lef fails with ORD-0001.
PDK=$(find /home/ubuntu -name "gf180mcu_fd_sc_mcu7t5v0.tlef" 2>/dev/null | head -1 | sed "s#/libs.ref/.*##")
if [ -z "$PDK" ]; then echo "[[NO PDK]] $(date -u)"; exit 2; fi
echo "PDK: $PDK"

cd "$R" || exit 2
echo "watch start $(date -u)"

# 1. Wait for the probe to finish (placement itself ran 12 min on 2026-11-05). A probe DEF that
# already carries taps is reused, so a rerun after a downstream failure does not place twice.
NTIE=$(grep -c "gf180mcu_fd_sc_mcu7t5v0__filltie" build/place_tap_probe.def 2>/dev/null || true)
if [ "${NTIE:-0}" -lt 100 ]; then
    for i in $(seq 1 120); do
        grep -q "TAP_PROBE_DONE" build/tap_probe.log 2>/dev/null && break
        grep -q "PHYSICAL_DESIGN_COMPLETE" build/tap_probe.log 2>/dev/null && break
        if ! docker ps --format '{{.Names}}' | grep -q rebased_tap_probe; then
            echo "[[PROBE EXITED]] $(date -u)"; break
        fi
        sleep 30
    done
    if ! grep -q "TAP_PROBE_DONE" build/tap_probe.log 2>/dev/null; then
        echo "[[PROBE FAILED, no rebuild]] $(date -u)"
        tail -25 build/tap_probe.log
        exit 3
    fi
    NTIE=$(grep -c "gf180mcu_fd_sc_mcu7t5v0__filltie" build/place_tap_probe.def 2>/dev/null || true)
fi

# 2. The probe is only useful if it actually placed taps.
echo "probe fillties: ${NTIE:-0}"
if [ "${NTIE:-0}" -lt 100 ]; then
    echo "[[TOO FEW TAPS, no rebuild]] $(date -u)"
    exit 4
fi

# 3. Keep the un-tapped die and its routed netlist; the flow writes the standard names.
[ -f build/grx930_test_chip.def ] && mv build/grx930_test_chip.def build/grx930_test_chip_notap.def
[ -f build/grx930_test_chip_routed.v ] && mv build/grx930_test_chip_routed.v build/grx930_test_chip_notap_routed.v
[ -f build/lvs_chip/stream_out_filled_stitched.gds ] && mv build/lvs_chip/stream_out_filled_stitched.gds build/lvs_chip/stream_out_filled_stitched_notap.gds
[ -f build/lvs_chip/filled.def ] && mv build/lvs_chip/filled.def build/lvs_chip/filled_notap.def
[ -f build/lvs_chip/grx930_test_chip.cdl ] && mv build/lvs_chip/grx930_test_chip.cdl build/lvs_chip/grx930_test_chip_notap.cdl

# 4. Full flow: placement with taps, then routing.
echo "=== full flow start $(date -u)"
docker run --rm --name rebased_tap -v "$R:/work" -v "$PDK:/work/gf180mcu_pdk" \
    -v "$S:/work/c930/asic_gf180mcu" -w /work "$IMG" \
    openroad -no_init flow_openroad_gf180mcu.tcl > build/pnr_tap.log 2>&1
if ! grep -q "PHYSICAL_DESIGN_COMPLETE" build/pnr_tap.log; then
    echo "[[PNR FAILED]] $(date -u)"
    tail -25 build/pnr_tap.log
    exit 5
fi
echo "[[PNR COMPLETE]] $(date -u)"
ls -la build/grx930_test_chip.def build/grx930_test_chip_routed.v

# 5. fill -> stream -> stitch -> CDL -> LVS under a new tag.
echo "=== pipeline start $(date -u)"
LVS_TAG="$TAG" bash "$S/build/rebased_pipeline.sh" --lvs > build/pipeline_tap.log 2>&1
echo "[[PIPELINE DONE rc=$?]] $(date -u)"
tail -6 build/pipeline_tap.log
