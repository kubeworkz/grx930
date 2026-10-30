#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# v5: resume Classic flow -F OpenROAD.DetailedRouting, seeded from
# 50-openroad-globalrouting/state_out.json (the GRT redone with
# GRT_ADJUSTMENT=0.0: total usage 102.95%, overflow 1.73M vs the old
# 143.72% / 4.57M that made DRT diverge 22.8M -> 25.5M).
# Fast-abort contract: watch the violation curve in iteration 0 - if it
# looks like the diverging run (millions piling by the 20-30% mark),
# kill this container and escalate (RT_MIN_LAYER=Metal1 GRT redo).

RUN=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
B=/work/build
TAG=RUN_2026-09-24_04-18-20

echo "V5_PREP" > $B/v5_status.txt

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v5_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v5_status.txt; exit 1; fi

if [ ! -f "$RUN/50-openroad-globalrouting/state_out.json" ]; then
  echo "GRT_STATE_MISSING" > $B/v5_status.txt; exit 1
fi

echo "V5_RUNNING" > $B/v5_status.txt
cd /work/openlane2_rtl || { echo "CD_FAILED" > $B/v5_status.txt; exit 1; }
openlane --run-tag $TAG -F OpenROAD.DetailedRouting -p gf180mcuD config.json > $B/v5_drt.log 2>&1
echo "V5_EXIT:$?" >> $B/v5_drt.log

echo "V5_DONE" > $B/v5_status.txt
