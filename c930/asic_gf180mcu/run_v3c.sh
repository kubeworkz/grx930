#!/bin/bash
# Recovery v3 stage 3 - resume the Classic flow from OpenROAD.STAMidPNR-3
# (4th STAMidPNR instance, right after the gated-off ResizerTimingPostGRT),
# so the run continues DRT -> fill -> GDS seeded from the latest
# 45-openroad-globalrouting/state_out.json (post-repair ODB + fresh guides).
# Fixes run_v3b.sh inv3: that invocation used a relative config.json path,
# but the container's working directory is /, so it died instantly (exit 2).

RUN=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
B=/work/build
TAG=RUN_2026-09-24_04-18-20

echo "INV3C_PREP" > $B/v3c_status.txt

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v3c_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v3c_status.txt; exit 1; fi

if [ ! -f "$RUN/45-openroad-globalrouting/state_out.json" ]; then
  echo "GRT_STATE_MISSING" > $B/v3c_status.txt; exit 1
fi

echo "INV3C_RUNNING" > $B/v3c_status.txt
cd /work/openlane2_rtl || { echo "CD_FAILED" > $B/v3c_status.txt; exit 1; }
openlane --run-tag $TAG -F OpenROAD.STAMidPNR-3 -p gf180mcuD config.json > $B/v3c_inv3.log 2>&1
echo "INV3C_EXIT:$?" >> $B/v3c_inv3.log

echo "V3C_DONE" > $B/v3c_status.txt
