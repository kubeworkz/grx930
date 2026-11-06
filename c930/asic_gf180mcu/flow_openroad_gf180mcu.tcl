# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# flow_openroad_gf180mcu.tcl — OpenROAD P&R for GRX930 test chip
# wafer.space 1x1 slot: Die 3.932mm x 5.122mm, Core 3.048mm x 4.238mm (12.92 mm2)
#
# Floorplan, clock and netlist all follow the tapeout tree (openlane2_rtl/src):
# 25 MHz, DIAMOND ticket die.  This used to be a 20 ns flow on a 3.93 x 5.12
# die with a 10 um margin, carried over from the 8 KB / 50 MHz chip.

set DESIGN_NAME "grx930_test_chip"
set BUILD_DIR   "build"
set STD_CELL    "gf180mcu_fd_sc_mcu7t5v0"

# 1. Read design
read_lef gf180mcu_pdk/libs.ref/${STD_CELL}/lef/${STD_CELL}.tlef
read_lef gf180mcu_pdk/libs.ref/${STD_CELL}/lef/${STD_CELL}_combined_clean.lef
# 5v00 is the corner the tapeout flow runs (nom_tt_025C_5v00); 1v80 here would
# time a 5 V part at the wrong voltage.
read_lib gf180mcu_pdk/libs.ref/${STD_CELL}/lib/${STD_CELL}__tt_025C_5v00.lib
read_verilog ${BUILD_DIR}/grx930_test_chip_synth.v
link_design $DESIGN_NAME

# 1b. Mark one_/zero_ nets as special power/ground for DRT
set _block [ord::get_db_block]
foreach _net_name {one_ zero_} {
    set _net [$_block findNet $_net_name]
    if {$_net ne "NULL"} {
        $_net setSpecial
        puts "Marked net $_net_name as special"
    }
}

# 2. Constraints
create_clock -name i_clk -period 40.0 [get_ports i_clk]
set_input_delay  6.0 -clock i_clk [all_inputs]
set_output_delay 6.0 -clock i_clk [all_outputs]
set_false_path -from [get_ports i_rst_n]

# 3. Floorplan
initialize_floorplan -site GF018hv5v_mcu_sc7 -die_area {0 0 3932 5122} -core_area {441 441 3489 4679}

# 3b. Create routing tracks
make_tracks Metal1 -x_offset 0.28 -x_pitch 0.56 -y_offset 0.28 -y_pitch 0.56
make_tracks Metal2 -x_offset 0.28 -x_pitch 0.56 -y_offset 0.28 -y_pitch 0.56
make_tracks Metal3 -x_offset 0.28 -x_pitch 0.56 -y_offset 0.28 -y_pitch 0.56
make_tracks Metal4 -x_offset 0.28 -x_pitch 0.56 -y_offset 0.28 -y_pitch 0.56
make_tracks Metal5 -x_offset 0.45 -x_pitch 0.90 -y_offset 0.45 -y_pitch 0.90

# 4. Place I/O pins
place_pins -hor_layers {Metal3 Metal5} -ver_layers {Metal2 Metal4} -random

# 5. Power net connections
add_global_connection -net VDD -pin_pattern VDD -power
add_global_connection -net VSS -pin_pattern VSS -ground
set_voltage_domain -name Core -power VDD -ground VSS

# 5b. PDN
define_pdn_grid -name CoreGrid -pins {Metal1} -voltage_domains {Core}
add_pdn_stripe -grid CoreGrid -layer Metal5 -width 3.2 -pitch 50.0 -offset 25.0 -nets {VDD VSS} -followpins
add_pdn_stripe -grid CoreGrid -layer Metal4 -width 1.6 -pitch 30.0 -offset 15.0 -nets {VDD VSS}
add_pdn_stripe -grid CoreGrid -layer Metal3 -width 1.6 -pitch 20.0 -offset 10.0 -nets {VDD VSS}
add_pdn_connect -grid CoreGrid -layers {Metal4 Metal5}
add_pdn_connect -grid CoreGrid -layers {Metal3 Metal4}
add_pdn_connect -grid CoreGrid -layers {Metal1 Metal2}
pdngen

# 6. Placement
puts "STAGE placement start"
global_placement -density 0.60
detailed_placement
improve_placement

# 6b. Well taps, before routing. The fill pass can only tap a well where two sites are free and
# the filltie's Metal1 stubs are clear; on the 2026-11-05 die that left 21 nwell runs untied (10
# packed solid with cells, 8 with Metal1 across every candidate window). DF.13_LV wants a tap
# within 20 um of the p-diffusion in an nwell, so the taps are placed here, before global_route
# draws over them.
puts "STAGE tapcell start"
tapcell -distance 20 -tapcell_master gf180mcu_fd_sc_mcu7t5v0__filltie -disallow_one_site_gaps
detailed_placement
puts "STAGE tapcell done"
if {[info exists ::env(TAP_PROBE)]} {
    write_def ${BUILD_DIR}/place_tap_probe.def
    puts "TAP_PROBE_DONE"
    exit
}
puts "STAGE placement done"

# 7. CTS (skipped — clock buffer Metal1 input pins cause DRT-0073 pin access failure)
# The clock net i_clk will be routed as a flat signal net instead.
#
# repair_clock_nets is off by default.  It buffers an existing tree; with no tree it works the
# whole flat net in one go, and on the corrected 125 k-cell netlist (28,988 clock sinks) it ran
# for 45 min on one core without emitting a line, against silent-and-instant on the 54 k-cell
# die.  The taped die's i_clk is a routed signal net, so leaving it flat keeps this flow on the
# same structure.  Set CLOCK_REPAIR=1 to run it.
if {[info exists ::env(CLOCK_REPAIR)]} {
    puts "STAGE clock_repair start"
    repair_clock_nets
    puts "STAGE clock_repair done"
} else {
    puts "STAGE clock_repair skipped (flat clock net, as taped)"
}

# 8. Routing
puts "STAGE global_route start"
set_routing_layers -signal Metal1-Metal5 -clock Metal3-Metal5
set_global_routing_layer_adjustment Metal1 0.5
set_global_routing_layer_adjustment Metal2 0.5
set_global_routing_layer_adjustment Metal3 0.5
set_global_routing_layer_adjustment Metal4 0.5
set_global_routing_layer_adjustment Metal5 0.3
global_route -congestion_iterations 100
puts "STAGE global_route done"

puts "STAGE detailed_route start"
detailed_route -verbose 1
puts "STAGE detailed_route done"

# 9. Reporting
report_design_area

# 10. Export
puts "STAGE export"
write_def ${BUILD_DIR}/grx930_test_chip.def
write_verilog ${BUILD_DIR}/grx930_test_chip_routed.v

puts "PHYSICAL_DESIGN_COMPLETE"
