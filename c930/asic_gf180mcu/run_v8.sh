#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# v8: FRESH full OL2 run (no --run-tag, no -F resume) from the Option B RTL:
#   - grx930_sram_64kb DEPTH 1024 -> 256   (8 KB -> 2 KB FF SRAM)
#   - ICACHE/DCACHE_INDEX_WIDTH 5 -> 4     (data arrays 1 KB -> 512 B each)
# Probe before launch: 380,083 -> 152,774 generic cells (-60%), flat-equivalent
# ~209K gf180 cells, est. ~3.9 mm^2 yosys area, est. 25-30% core util (was 84.4%).
# Gates (PLAN_B_netlist_rework.md 6): GRT total <=90% & every layer <=100%
# (no GRT-0115), then DRT "Completing 20%" < 50,000 violations.
# Config unchanged: RT_MIN_LAYER=Metal1, GRT_ADJUSTMENT=0.0, CLOCK_PERIOD 40.

B=/work/build

echo "V8_PREP" > $B/v8_status.txt

# Guard: make sure the Option B RTL actually landed on the server.
if ! grep -q 'DEPTH = 256' /work/openlane2_rtl/src/grx930_test_chip.sv || \
   ! grep -q 'ICACHE_INDEX_WIDTH (4)' /work/openlane2_rtl/src/grx930_test_chip.sv; then
  echo "RTL_MISMATCH" > $B/v8_status.txt
  exit 1
fi

volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > $B/v8_fetch.log 2>&1
if [ $? -ne 0 ]; then echo "VOLARE_FAILED" > $B/v8_status.txt; exit 1; fi

echo "V8_RUNNING" > $B/v8_status.txt
cd /work/openlane2_rtl || { echo "CD_FAILED" > $B/v8_status.txt; exit 1; }
openlane -p gf180mcuD config.json > $B/v8_flow.log 2>&1
rc=$?
echo "V8_EXIT:$rc" >> $B/v8_flow.log

if [ $rc -ne 0 ]; then
  echo "V8_FAILED:$rc" > $B/v8_status.txt
  exit $rc
fi
echo "V8_DONE" > $B/v8_status.txt
