#!/bin/sh
# arm SLOTCORE-0.3 (container side) -- the one variant the 2026-10-11 DRT
# investigation named as worth running but never ran: stock GRT_ADJUSTMENT=0.3
# on the slot-core layout.
#
# Why here and not on the fat layout: the 0.3 arm on the fat layout made GRT
# log "Running extra iterations to remove overflow" -- the regime that made DRT
# diverge -- and it filled the disk before producing a congestion report. The
# slot-core layout sits at 50.2 % utilization with 12.2 % GRT usage and zero
# overflow at 0.0, so the 30 % capacity reservation is expected to be
# affordable; if it is, the guides leave DRT the headroom the 0.0 guides do not.
#
# Resumes the completed slotcore_v1 run from GlobalRouting (no re-synthesis, no
# re-placement: ~40 min) and stops after the antennas step, exactly the ODB the
# fast DRT loop consumes. Same design dir, same PDK, same everything as
# run_v8.sh/core_exec.sh apart from GRT_ADJUSTMENT.
cd /work/openlane2_rtl || exit 1
volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af \
    > /work/build/grt03c_fetch.log 2>&1
openlane --run-tag slotcore_v1 -F OpenROAD.GlobalRouting -T OpenROAD.RepairAntennas \
    -c GRT_ADJUSTMENT=0.3 \
    --design-dir /work/openlane2_rtl -p gf180mcuD \
    config.json core_area_cfg.json > /work/build/grt03c_flow.log 2>&1
echo "GRT03C_EXIT:$?" >> /work/build/grt03c_flow.log
