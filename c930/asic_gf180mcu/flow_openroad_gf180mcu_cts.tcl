# flow_openroad_gf180mcu_cts.tcl — OpenROAD P&R with CTS
# Metal2 I-pin stubs on clock buffers fix DRT-0073 pin access issue

set DESIGN_NAME "grx930_test_chip"
set BUILD_DIR   "build"
set STD_CELL    "gf180mcu_fd_sc_mcu7t5v0"

# 1. Read design
read_lef gf180mcu_pdk/libs.ref/${STD_CELL}/lef/${STD_CELL}.tlef
read_lef gf180mcu_pdk/libs.ref/${STD_CELL}/lef/${STD_CELL}_combined_m2stub.lef
read_lib gf180mcu_pdk/libs.ref/${STD_CELL}/lib/${STD_CELL}__tt_025C_1v80.lib
read_verilog ${BUILD_DIR}/grx930_test_chip_synth_final.v
link_design $DESIGN_NAME

# 1b. Mark one_/zero_ nets as special
set _block [ord::get_db_block]
foreach _net_name {one_ zero_} {
    set _net [$_block findNet $_net_name]
    if {$_net ne "NULL"} {
        $_net setSpecial
        puts "Marked net $_net_name as special"
    }
}

# 2. Constraints
create_clock -name i_clk -period 20.0 [get_ports i_clk]
set_input_delay  6.0 -clock i_clk [all_inputs]
set_output_delay 6.0 -clock i_clk [all_outputs]
set_false_path -from [get_ports i_rst_n]

# 3. Floorplan
initialize_floorplan -site GF018hv5v_mcu_sc7 -die_area {0 0 3930 5120} -core_area {10 10 3920 5110}

# 3b. Routing tracks
make_tracks Metal1 -x_offset 0.28 -x_pitch 0.56 -y_offset 0.28 -y_pitch 0.56
make_tracks Metal2 -x_offset 0.28 -x_pitch 0.56 -y_offset 0.28 -y_pitch 0.56
make_tracks Metal3 -x_offset 0.28 -x_pitch 0.56 -y_offset 0.28 -y_pitch 0.56
make_tracks Metal4 -x_offset 0.28 -x_pitch 0.56 -y_offset 0.28 -y_pitch 0.56
make_tracks Metal5 -x_offset 0.45 -x_pitch 0.90 -y_offset 0.45 -y_pitch 0.90

# 4. I/O pins
place_pins -hor_layers {Metal3 Metal5} -ver_layers {Metal2 Metal4} -random

# 5. Power
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
global_placement -density 0.60
detailed_placement
improve_placement

# 7. CTS
repair_clock_nets
clock_tree_synthesis -buf_list [list ${STD_CELL}__clkbuf_4 ${STD_CELL}__clkbuf_8] -root_buf ${STD_CELL}__clkbuf_8 -clk_nets i_clk

# 8. Routing
set_routing_layers -signal Metal1-Metal5 -clock Metal3-Metal5
set_global_routing_layer_adjustment Metal1 0.5
set_global_routing_layer_adjustment Metal2 0.5
set_global_routing_layer_adjustment Metal3 0.5
set_global_routing_layer_adjustment Metal4 0.5
set_global_routing_layer_adjustment Metal5 0.3
global_route -congestion_iterations 100

detailed_route -verbose 1

# 9. Report
report_design_area

# 10. Export
write_def ${BUILD_DIR}/grx930_test_chip.def
write_verilog ${BUILD_DIR}/grx930_test_chip_routed.v

puts "PHYSICAL_DESIGN_COMPLETE"
