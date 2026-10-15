#!/bin/bash
# Recovery v3 - GRX930 OL2 resume, process-split to avoid OOM.
#  inv1: OpenROAD.RepairAntennas only (patched antenna_repair.tcl: catches
#        DPL-0036, skips the redundant first GRT, and has NO in-process
#        post-dpl GRT - that combination was OOM-killed at >19 GB).
#  inv2: standalone OpenROAD.GlobalRouting on inv1's ODB. Fresh process
#        (~11 GB, proven profile) regenerates guides covering the inserted
#        diodes + re-legalized cells for DRT.
#  inv3: resume Classic flow from OpenROAD.STAMidPNR-3 -> DRT -> fill -> GDS.
# Stages are gated on state_out.json existence, not exit codes (OL2 may
# non-zero-exit after the step itself succeeded).

RUN=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
B=/work/build
TAG=RUN_2026-09-24_04-18-20

echo "INV1_RUNNING" > $B/v3_status.txt

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v3_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v3_status.txt; exit 1; fi

cd /work/openlane2_rtl
if [ $? -ne 0 ]; then echo "CD_FAILED" > $B/v3_status.txt; exit 1; fi

openlane --run-tag $TAG -F OpenROAD.RepairAntennas -T OpenROAD.RepairAntennas \
  -p gf180mcuD config.json > $B/v3_inv1.log 2>&1
echo "INV1_EXIT:$?" >> $B/v3_inv1.log

# locate inv1 step dir: repairantennas dir that has state_out.json
R1=""
for d in $RUN/*-openroad-repairantennas; do
  if [ -f "$d/state_out.json" ]; then R1="$d"; fi
done
if [ -z "$R1" ]; then echo "INV1_FAILED" > $B/v3_status.txt; exit 1; fi

echo "INV2_RUNNING" > $B/v3_status.txt

# next free step ordinal
MAX=0
for d in $RUN/*/; do
  b=${d%/}; b=${b##*/}
  n=${b%%-*}
  case "$n" in ''|*[!0-9]*) continue ;; esac
  if [ "$n" -gt "$MAX" ]; then MAX=$n; fi
done
OUT2="$RUN/$((MAX+1))-openroad-globalrouting"

python3 -m openlane.steps run --id OpenROAD.GlobalRouting \
  -c $RUN/39-openroad-globalrouting/config.json \
  -i "$R1/state_out.json" \
  -o "$OUT2" -p gf180mcuD > $B/v3_inv2.log 2>&1
echo "INV2_EXIT:$?" >> $B/v3_inv2.log
echo "INV2_OUT=$OUT2" >> $B/v3_inv2.log

if [ ! -f "$OUT2/state_out.json" ]; then echo "INV2_FAILED" > $B/v3_status.txt; exit 1; fi

echo "INV3_RUNNING" > $B/v3_status.txt
openlane --run-tag $TAG -F OpenROAD.STAMidPNR-3 -p gf180mcuD config.json > $B/v3_inv3.log 2>&1
echo "INV3_EXIT:$?" >> $B/v3_inv3.log

echo "V3_DONE" > $B/v3_status.txt
