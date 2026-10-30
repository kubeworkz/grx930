#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# v7: resume Classic flow -F OpenROAD.DetailedRouting, seeded from
# 52-openroad-globalrouting/state_out.json (GRT redone with
# RT_MIN_LAYER=Metal1 + GRT_ADJUSTMENT=0.0).
# Final gate table (v6): total usage 92.66% (was 102.95%), M1 1.97M
# demand @100.2%, M3 95.24%, M4 85.94%, M5 74.85%, M2 still 103.57%
# (max per-gcell 64), total overflow 1.23M (-29%), vias 5.69M (-21%).
# NEW for DRT: drt.tcl takes min layer from RT_MIN_LAYER, so this run
# routes from Metal1 (all prior DRT attempts were Metal2-bottom) - pin
# escape + room under M2 hotspots.
# Fast-abort contract: watch iteration-0 curve. Doomed reference on
# M2-hotspot guides: 20% = 1,881,923 violations, 30% = 5,576,348. If
# 20-30% is again in the millions, kill and go to plan B (area rework).

RUN=/work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
B=/work/build
TAG=RUN_2026-09-24_04-18-20

echo "V7_PREP" > $B/v7_status.txt

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v7_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v7_status.txt; exit 1; fi

if [ ! -f "$RUN/52-openroad-globalrouting/state_out.json" ]; then
  echo "GRT_STATE_MISSING" > $B/v7_status.txt; exit 1
fi

echo "V7_RUNNING" > $B/v7_status.txt
cd /work/openlane2_rtl || { echo "CD_FAILED" > $B/v7_status.txt; exit 1; }
openlane --run-tag $TAG -F OpenROAD.DetailedRouting -p gf180mcuD config.json > $B/v7_drt.log 2>&1
echo "V7_EXIT:$?" >> $B/v7_drt.log

echo "V7_DONE" > $B/v7_status.txt
