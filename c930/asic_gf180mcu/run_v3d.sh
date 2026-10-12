#!/bin/bash
# Recovery v3 stage 4 - the host rebooted during DRT (swap exhaustion ->
# sshd starved, hard reboot). 47-openroad-detailedrouting never produced
# state_out.json; 46-openroad-stamidpnr-3/state_out.json is the latest
# concluded state, so resuming with -F OpenROAD.DetailedRouting seeds from
# 46, skips everything through STAMidPNR-3, and restarts DRT fresh.

RUN=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
B=/work/build
TAG=RUN_2026-09-24_04-18-20

echo "V3D_PREP" > $B/v3d_status.txt

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v3d_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v3d_status.txt; exit 1; fi

if [ ! -f "$RUN/46-openroad-stamidpnr-3/state_out.json" ]; then
  echo "STA_STATE_MISSING" > $B/v3d_status.txt; exit 1
fi

echo "V3D_RUNNING" > $B/v3d_status.txt
cd /work/openlane2_rtl || { echo "CD_FAILED" > $B/v3d_status.txt; exit 1; }
openlane --run-tag $TAG -F OpenROAD.DetailedRouting -p gf180mcuD config.json > $B/v3d_drt.log 2>&1
echo "V3D_EXIT:$?" >> $B/v3d_drt.log

echo "V3D_DONE" > $B/v3d_status.txt
