# flow_openroad.tcl — OpenROAD physical design flow for GRX930 → SKY130
#
# Usage:
#   cd c930/asic
#   openroad -exit flow_openroad.tcl 2>&1 | tee pnr.log
#
# Prerequisites:
#   - SKY130 PDK installed at $PDK_ROOT
#   - Yosys synthesis completed (build/c930_soc_synth.v exists)
#
# Output:
#   build/c930_soc_routed.gds     — final GDS for tapeout
#   build/c930_soc_routed.v       — gate-level Verilog (post-route)
#   build/c930_soc_routed.spef    — parasitic extraction
#   build/c930_soc_routed.rpt     — timing report

# ============================================================
# Configuration
# ============================================================
set DESIGN_NAME "c930_soc_top"
set BUILD_DIR   "build"
set PDK_ROOT    $::env(PDK_ROOT)
set STD_CELL    "sky130_fd_sc_hd"
set TECH_FILE   "$PDK_ROOT/sky130_fd_sc_hd/sky130_fd_sc_hd.tlef"
set LIB_FILE    "$PDK_ROOT/sky130_fd_sc_hd/timing/sky130_fd_sc_hd__tt_025C_1v80.lib"
set LEF_FILE    "$PDK_ROOT/sky130_fd_sc_hd/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef"

# Design parameters
set CORE_UTIL  0.65           ;# 65% utilization (leaves room for routing)
set ASPECT     1.0            ;# square core
set CORE_MARG 20             ;# 20µm margin around core

# Clock
set CLK_NAME  "core_clk"
set CLK_PERIOD 10.0           ;# 100 MHz (conservative; design supports 121 MHz)
set CLK_PORT  "i_clk"

# ============================================================
# 1. Read design
# ============================================================
read_lef $TECH_FILE
read_lef $LEF_FILE
read_lib $LIB_FILE
read_verilog $BUILD_DIR/c930_soc_synth.v
link_design $DESIGN_NAME

# ============================================================
# 2. Constraints
# ============================================================
create_clock -name $CLK_NAME -period $CLK_PERIOD [get_ports $CLK_PORT]

# Input/output delay (assume 30% of clock period)
set IO_DELAY [expr {$CLK_PERIOD * 0.3}]
set_input_delay  $IO_DELAY -clock $CLK_NAME [remove_from_collection [all_inputs] [get_ports $CLK_PORT]]
set_output_delay $IO_DELAY -clock $CLK_NAME [all_outputs]

# False paths (TB preload ports — simulation only, removed in ASIC)
# These ports are tied to constants in the ASIC wrapper

# ============================================================
# 3. Floorplan
# ============================================================
initialize_floorplan \
    -core_utilization $CORE_UTIL \
    -core_aspect_ratio $ASPECT \
    -core_margin $CORE_MARG \
    -left_io2core   40 \
    -right_io2core  40 \
    -top_io2core    40 \
    -bottom_io2core 40

# ============================================================
# 4. Power grid
# ============================================================
# VDD/VSS rings on M4/M5
add_ring -nets {VDD VSS} \
    -width 2.0 -spacing 1.0 \
    -layer {M4 M5} \
    -follow_core

# Power stripes on M3
add_stripe -nets {VDD VSS} \
    -layer M3 -width 1.6 -spacing 1.8 \
    -set_to_set_distance 30 -start_offset 15

# ============================================================
# 5. Placement
# ============================================================
global_placement -density $CORE_UTIL
legalize_placement
refine_placement

# ============================================================
# 6. Clock tree synthesis
# ============================================================
repair_clock_nets
clock_tree_synthesis \
    -buf_list {sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8} \
    -root_buf sky130_fd_sc_hd__clkbuf_8 \
    -clk_port $CLK_PORT

# ============================================================
# 7. Routing
# ============================================================
global_route
detailed_route

# ============================================================
# 8. parasitic extraction + timing
# ============================================================
extract_parasitics
report_design_area
report_timing -max_paths 10 > $BUILD_DIR/c930_soc_routed.rpt
report_checks -delay max > $BUILD_DIR/c930_soc_setup.rpt
report_checks -delay min > $BUILD_DIR/c930_soc_hold.rpt

# ============================================================
# 9. GDS export
# ============================================================
write_gds $BUILD_DIR/c930_soc_routed.gds
write_verilog $BUILD_DIR/c930_soc_routed.v
write_spef $BUILD_DIR/c930_soc_routed.spef

puts "PHYSICAL_DESIGN_COMPLETE"
