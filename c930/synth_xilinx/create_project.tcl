## ---------------------------------------------------------------------------
## create_project.tcl  --  Create a Vivado project for the C930 SoC
##
## Usage:  vivado -mode batch -source synth_xilinx/create_project.tcl
## ---------------------------------------------------------------------------

set proj_name "c930_artix7"
set proj_dir  "[file dirname [info script]]/../build/vivado"
set part      "xc7a200tfbg484-1"

# ---- Create project ----
create_project $proj_name $proj_dir -part $part -force

# ---- Add RTL sources ----
# Core RTL (top-level .sv only; subdirectories excluded as in the ECP5 flow)
set core_rtl_dir "[file dirname [info script]]/../../rv64imac/RTL"
foreach f [glob -nocomplain "$core_rtl_dir/*.sv"] {
    add_files -norecurse $f
}

# NPU + SoC RTL (all top-level c930/rtl/*.sv except the behavioral DDR model)
set npu_rtl_dir "[file dirname [info script]]/../rtl"
foreach f [glob -nocomplain "$npu_rtl_dir/*.sv"] {
    if {[string match "*c930_ddr.sv" $f] || [string match "*c930_ddr3l.sv" $f]} {
        continue    ;# behavioral DDR model and DDR3L MIG wrapper excluded
    }
    add_files -norecurse $f
}

# Synth-only DDR stub (tiny BRAM; same module name c930_ddr, replaces behavioral model)
add_files -norecurse "[file dirname [info script]]/../synth/c930_ddr_stub.sv"

# ---- Constraints ----
add_files -fileset constrs_1 -norecurse "[file dirname [info script]]/xc7a200t_clock.xdc"

# ---- Top module ----
set_property top c930_soc_top [current_fileset]

# ---- SystemVerilog ----
set_property file_type SystemVerilog [get_files *.sv]

# ---- Synthesis settings ----
# Enable Verilog 2005 + SystemVerilog
set_property verilog_define {SYNTHESIS=1} [current_fileset]

puts "INFO: Project created at $proj_dir"
puts "INFO: Part = $part"
puts "INFO: Top  = c930_soc_top"
