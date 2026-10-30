#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# v4: GRT redo with GRT_ADJUSTMENT=0.0.
# Root cause of the DRT divergence: inv2 GRT (step 45) finished with
# GRT-0115 overflow at 143.72% usage (4.57M overflow units, 7.13M vias)
# because OL2's stock GRT_ADJUSTMENT=0.3 cuts all edge capacity by 30%.
# DRT then diverged: 22.8M -> 25.5M violations over 2 iterations.
# This stage ONLY reruns standalone GlobalRouting from the same
# state_out_manual.json input inv2 used. Gating on the new congestion
# report before resuming DRT is deliberate - no auto-chain.

RUN=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
B=/work/build
STATE=/work/state_out_manual.json

echo "V4_PREP" > $B/v4_status.txt

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v4_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v4_status.txt; exit 1; fi

if [ ! -f "$STATE" ]; then echo "STATE_MISSING" > $B/v4_status.txt; exit 1; fi
if [ ! -f "$B/grt_v2_config.json" ]; then echo "GRT_CONFIG_MISSING" > $B/v4_status.txt; exit 1; fi

# next free step ordinal
MAX=0
for d in $RUN/*/; do
  b=${d%/}; b=${b##*/}
  n=${b%%-*}
  case "$n" in ''|*[!0-9]*) continue ;; esac
  if [ "$n" -gt "$MAX" ]; then MAX=$n; fi
done
OUT="$RUN/$((MAX+1))-openroad-globalrouting"

echo "V4_RUNNING" > $B/v4_status.txt
python3 -m openlane.steps run --id OpenROAD.GlobalRouting \
  -c "$B/grt_v2_config.json" \
  -i "$STATE" \
  -o "$OUT" -p gf180mcuD > $B/v4_grt.log 2>&1
echo "V4_EXIT:$?" >> $B/v4_grt.log
echo "V4_OUT=$OUT" >> $B/v4_grt.log

if [ ! -f "$OUT/state_out.json" ]; then echo "V4_FAILED" > $B/v4_status.txt; exit 1; fi

echo "V4_DONE" > $B/v4_status.txt
