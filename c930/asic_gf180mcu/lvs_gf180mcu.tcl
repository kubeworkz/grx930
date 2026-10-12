# lvs_gf180mcu.tcl — Netgen LVS for GRX930 test chip → GF180MCU
#
# Usage:
#   netgen -script lvs_gf180mcu.tcl
#
# Compares:
#   1. Gate-level netlist (from synthesis/P&R)
#   2. Layout (extracted from GDS)

set build_dir "build"

# Gate-level netlist (from Yosys synthesis)
set netlist1 "$build_dir/grx930_test_chip_routed.v"

# Layout (extracted from GDS via Magic)
set layout1  "$build_dir/grx930_test_chip_routed.gds"

# Run LVS
lvs "$netlist1 $layout1" "$build_dir/lvs_results.rpt" \
    -supply {VDD VSS} \
    -cell_name grx930_test_chip
