#!/bin/sh
# arm CORE (container side) -- slot-core floorplan experiment.
#
# CORE_AREA 441 441 3489 4679 = 3048 x 4238 um = 12.92 mm2, the core that sits
# inside the pad-ring channel (pad_ring.cfg section 1; wafer.space slot core).
# DIE_AREA stays 0 0 3930 5120. Everything else is byte-identical to the v8
# config, so the only variable under test is the core rectangle:
#   cell area 6.66 mm2 -> utilization 33.4 % (baseline) => 51.6 % (this arm).
# -T stops the flow after the antennas step, which is exactly the ODB DRT was
# seeded with in v8, so the fast loop compares like with like.
#
# Two verified CLI lessons (2026-10-11), both cost one aborted start:
#   1. -c KEY=VALUE does NOT JSON-parse list values: it split "[441,..." on
#      commas and tried Decimal('[441'). Hence a config FILE instead.
#   2. `dir::` paths resolve against the directory of the LAST config file, so
#      passing the override from /work/build turned dir::src/*.sv into
#      /work/build/src/*.sv. Hence the override is co-located with config.json
#      in the design directory, and --design-dir is named explicitly too.
cd /work/openlane2_rtl || exit 1
volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af > /work/build/core_fetch.log 2>&1
openlane --run-tag slotcore_v1 -T OpenROAD.RepairAntennas \
  --design-dir /work/openlane2_rtl -p gf180mcuD \
  config.json core_area_cfg.json > /work/build/core_flow.log 2>&1
echo "CORE_EXIT:$?" >> /work/build/core_flow.log
