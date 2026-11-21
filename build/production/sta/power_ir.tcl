# Power-grid IR analysis on the frozen routed DEF.
set root "c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0"
set lib "$root/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib"
if {![info exists ::env(DEF)]} {
  error "DEF is not set"
}
set def $::env(DEF)
set spef "build/production/final/grx930_test_chip.spef"

if {![file exists $def]}  { error "missing DEF: $def" }
if {![file exists $spef]} { error "missing SPEF: $spef" }

read_lef "$root/lef/gf180mcu_fd_sc_mcu7t5v0.tlef"
read_lef "$root/lef/gf180mcu_fd_sc_mcu7t5v0_combined_clean.lef"
read_liberty $lib
read_def $def
read_spef $spef

analyze_power_grid -net VDD -corner tt_025C_5v00
check_power_grid -net VDD
analyze_power_grid -net VSS -corner tt_025C_5v00
check_power_grid -net VSS
