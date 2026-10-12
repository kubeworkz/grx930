#!/bin/bash
# v6: GRT redo #2 - RT_MIN_LAYER=Metal1 (in addition to GRT_ADJUSTMENT=0.0).
# Why: after the adjustment fix, GRT still finished at 102.95% total usage
# (M2 105%, M3 106%) on a placement that is 84.4% dense (722,223 instances,
# 16.81 mm^2 cells vs 19.93 mm^2 core - the netlist is simply huge for this
# fixed wafer.space die). DRT on those guides produced 22.8M violations
# (shorts-dominated) and diverged (22.8M -> 25.5M) with a curve identical
# to the old 144%-over guides, i.e. keyed to placement-level congestion
# rather than guide quality. Allowing M1 routing adds ~4.3M track capacity
# (M1 has the same fine pitch as M2), dropping projected usage from ~103%
# to ~80%. Gate on the final congestion report before resuming DRT - no
# auto-chain.

RUN=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
B=/work/build
STATE=/work/state_out_manual.json

echo "V6_PREP" > $B/v6_status.txt

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v6_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v6_status.txt; exit 1; fi

if [ ! -f "$STATE" ]; then echo "STATE_MISSING" > $B/v6_status.txt; exit 1; fi
if [ ! -f "$B/grt_v3_config.json" ]; then echo "GRT_CONFIG_MISSING" > $B/v6_status.txt; exit 1; fi

# next free step ordinal
MAX=0
for d in $RUN/*/; do
  b=${d%/}; b=${b##*/}
  n=${b%%-*}
  case "$n" in ''|*[!0-9]*) continue ;; esac
  if [ "$n" -gt "$MAX" ]; then MAX=$n; fi
done
OUT="$RUN/$((MAX+1))-openroad-globalrouting"

echo "V6_RUNNING" > $B/v6_status.txt
python3 -m openlane.steps run --id OpenROAD.GlobalRouting \
  -c "$B/grt_v3_config.json" \
  -i "$STATE" \
  -o "$OUT" -p gf180mcuD > $B/v6_grt.log 2>&1
echo "V6_EXIT:$?" >> $B/v6_grt.log
echo "V6_OUT=$OUT" >> $B/v6_grt.log

if [ ! -f "$OUT/state_out.json" ]; then echo "V6_FAILED" > $B/v6_status.txt; exit 1; fi

echo "V6_DONE" > $B/v6_status.txt
