#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# run_adapter_lint.sh -- elaborate the wafer.space chip_core adapter together
# with the tapeout RTL and run its pad-map checks. Seconds, no PDK, no flow.
#
#   sh wafer_space_integration/run_adapter_lint.sh
#
# Purpose: the adapter is the one file that glues our core to the template's pad
# ring. A pad-count or port-name mistake there would only show up an hour into a
# LibreLane run on the server, so this gate catches it locally first.
set -e
cd "$(dirname "$0")/.."        # c930/asic_gf180mcu

RTL_DIR=openlane2_rtl/src
OUT=build/adapter_lint.vvp

# Same file set as `make sim`: the tapeout RTL minus the two ROM modules the
# chip does not instantiate (they would elaborate an unread $readmemh).
SRC=$(ls $RTL_DIR/*.sv | grep -v "$RTL_DIR/c930_bootrom.sv" | grep -v "$RTL_DIR/bootrom_wrapper.sv")

echo "=== chip_core adapter: iverilog elaboration + pad-map check ==="
iverilog -g2012 -o "$OUT" $SRC \
    wafer_space_integration/chip_core_grx930.sv \
    wafer_space_integration/tb_chip_core_grx930.sv
vvp "$OUT"
echo "=== adapter check PASSED ==="
