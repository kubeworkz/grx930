# Multi-corner GRX930 STA.
# The shell runner sets CORNER to one of:
#   ss_n40C_4v50 ss_125C_4v50 tt_025C_5v00 ff_n40C_5v50 ff_125C_5v50
if {![info exists ::env(CORNER)]} {
  error "CORNER is not set"
}
set corner $::env(CORNER)

set root "c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0"
set lib "$root/lib/gf180mcu_fd_sc_mcu7t5v0__${corner}.lib"
set def "build/production/final/grx930_test_chip.def"
set spef "build/production/final/grx930_test_chip.spef"

if {![file exists $lib]}  { error "missing liberty: $lib" }
if {![file exists $def]}  { error "missing DEF: $def" }
if {![file exists $spef]} { error "missing SPEF: $spef" }

read_lef "$root/lef/gf180mcu_fd_sc_mcu7t5v0.tlef"
read_lef "$root/lef/gf180mcu_fd_sc_mcu7t5v0_combined_clean.lef"
read_liberty $lib
read_def $def
read_spef $spef

create_clock -name i_clk -period 40.0 [get_ports i_clk]
set_input_delay  6.0 -clock i_clk [all_inputs]
set_output_delay 6.0 -clock i_clk [all_outputs]
set_false_path -from [get_ports i_rst_n]

file mkdir build/production/sta
report_checks -path_delay max -format full_clock_expanded -group_count 100 \
  > "build/production/sta/${corner}_setup.rpt"
report_checks -path_delay min -format full_clock_expanded -group_count 100 \
  > "build/production/sta/${corner}_hold.rpt"
report_power > "build/production/sta/${corner}_power.rpt"
