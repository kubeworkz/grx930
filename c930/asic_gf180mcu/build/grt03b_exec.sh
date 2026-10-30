#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# arm GRT03 (container side) -- isolate the GlobalRouting headroom variable.
#
# Resumes the v8 run from OpenROAD.GlobalRouting with the STOCK
# GRT_ADJUSTMENT=0.3 (this design overrides it to 0.0 since v4), then stops
# after the antennas step. Same layout, same netlist, same DRT arguments as the
# baseline -- only the guide headroom differs.
cd /work/openlane2_rtl || exit 1
volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > /work/build/grt03b_fetch.log 2>&1
openlane --run-tag RUN_2026-09-30_23-41-23 -F OpenROAD.GlobalRouting -T OpenROAD.RepairAntennas \
  -c GRT_ADJUSTMENT=0.3 -p gf180mcuD config.json > /work/build/grt03b_flow.log 2>&1
echo "GRT03_EXIT:$?" >> /work/build/grt03b_flow.log
