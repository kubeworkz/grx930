#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# grt_sweep_exec.sh -- container side of the GRT_ADJUSTMENT sweep.
#
# Resumes runs/slotcore_v1 from OpenROAD.GlobalRouting to OpenROAD.RepairAntennas
# with GRT_ADJUSTMENT=$SWEEP_ADJ, producing exactly the ODB the fast DRT loop
# consumes. Identical to slotcore_grt03_exec.sh apart from the value being passed
# in, so each sweep point differs from the 0.3 arm in this one variable.
#
# /bin/sh in this image has no sed/ls/awk -- builtins only.
set -u
: "${SWEEP_ADJ:?SWEEP_ADJ must be set}"
cd /work/openlane2_rtl || exit 1
volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af \
    > "/work/build/grt_sweep_${SWEEP_ADJ}_fetch.log" 2>&1
openlane --run-tag slotcore_v1 -F OpenROAD.GlobalRouting -T OpenROAD.RepairAntennas \
    -c GRT_ADJUSTMENT="${SWEEP_ADJ}" \
    --design-dir /work/openlane2_rtl -p gf180mcuD \
    config.json core_area_cfg.json > "/work/build/grt_sweep_${SWEEP_ADJ}_flow.log" 2>&1
echo "GRT_SWEEP_EXIT:$?" >> "/work/build/grt_sweep_${SWEEP_ADJ}_flow.log"
