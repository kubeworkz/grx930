#!/bin/bash
# Recovery v3 stage 2 - runs in a PLAIN container (no bind-mounted script
# patches; the RepairAntennas step is already done and will be skipped by
# the flow resume).
#  prep: state_out_manual.json (crafted on the HOST before launch - no sed
#        in the container) points odb/def at
#        44-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.{odb,def}
#  inv2: standalone OpenROAD.GlobalRouting on that ODB. Fresh process
#        (~11 GB, proven profile) regenerates global-route guides covering
#        the inserted diodes + re-legalized cells for DRT.
#  inv3: resume Classic flow from OpenROAD.STAMidPNR-3 -> DRT -> fill -> GDS.
# Stages are gated on state_out.json existence, not exit codes.

RUN=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
B=/work/build
TAG=RUN_2026-09-24_04-18-20
STATE=/work/state_out_manual.json   # crafted on the host (run dir is root-owned)

echo "INV2_PREP" > $B/v3b_status.txt

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v3b_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v3b_status.txt; exit 1; fi

if [ ! -f "$STATE" ]; then echo "STATE_MISSING" > $B/v3b_status.txt; exit 1; fi

# next free step ordinal
MAX=0
for d in $RUN/*/; do
  b=${d%/}; b=${b##*/}
  n=${b%%-*}
  case "$n" in ''|*[!0-9]*) continue ;; esac
  if [ "$n" -gt "$MAX" ]; then MAX=$n; fi
done
OUT2="$RUN/$((MAX+1))-openroad-globalrouting"

echo "INV2_RUNNING" > $B/v3b_status.txt
python3 -m openlane.steps run --id OpenROAD.GlobalRouting \
  -c $RUN/39-openroad-globalrouting/config.json \
  -i "$STATE" \
  -o "$OUT2" -p gf180mcuD > $B/v3b_inv2.log 2>&1
echo "INV2_EXIT:$?" >> $B/v3b_inv2.log
echo "INV2_OUT=$OUT2" >> $B/v3b_inv2.log

if [ ! -f "$OUT2/state_out.json" ]; then echo "INV2_FAILED" > $B/v3b_status.txt; exit 1; fi

echo "INV3_RUNNING" > $B/v3b_status.txt
openlane --run-tag $TAG -F OpenROAD.STAMidPNR-3 -p gf180mcuD config.json > $B/v3b_inv3.log 2>&1
echo "INV3_EXIT:$?" >> $B/v3b_inv3.log

echo "V3B_DONE" > $B/v3b_status.txt
