#!/bin/bash
# Run OpenLane2 full flow for GRX930 test chip with CTS
# Uses GF180MCU PDK via volare

set -e

echo "=== Step 1: Fetch GF180MCU PDK ==="
volare fetch --pdk gf180mcu c6d73a35f524070e85faff4a6a9eef49553ebc2b 2>&1 | tail -5
volare enable --pdk gf180mcu c6d73a35f524070e85faff4a6a9eef49553ebc2b 2>&1 | tail -5

export PDK_ROOT=/root/.volare
echo "PDK_ROOT=$PDK_ROOT"

echo "=== Step 2: Run OL2 flow with GF180MCU PDK ==="
cd c930/asic_gf180mcu/openlane2_rtl
openlane --pdk gf180mcuD config.json 2>&1 | tee /work/c930/asic_gf180mcu/build/ol2_cts.log

echo "=== FLOW COMPLETE ==="
