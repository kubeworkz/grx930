## -------------------------------------------------------------------
## gen_bitstream.tcl -- Generate bitstream + .bin from routed checkpoint
##
## Usage: vivado -mode batch -source synth_xilinx/gen_bitstream.tcl
## -------------------------------------------------------------------

set proj_dir  "[file dirname [info script]]/../build/vivado"
set run_dir   "$proj_dir/c930_artix7.runs/impl_1"
set dcp       "$run_dir/c930_soc_top_routed.dcp"

if {![file exists $dcp]} {
    puts "ERROR: Routed checkpoint not found at $dcp"
    exit 1
}

# ---- Suppress DRC for simulation-only TB preload ports ----
# i_tb_wr_*, i_tb_rd_addr, o_tb_rd_data have no board pins (they exist
# only for iverilog testbench preload).  Vivado requires every I/O to
# have IOSTANDARD + LOC for bitstream; downgrade to warning.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

puts "INFO: Opening routed checkpoint..."
open_checkpoint $dcp

# ---- Set SPI x4 for flash .bin generation ----
set_property BITSTREAM.Config.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# ---- Generate bitstream ----
puts "INFO: Generating bitstream..."
write_bitstream -force "$proj_dir/c930_soc_top.bit"
puts "INFO: Bitstream written to $proj_dir/c930_soc_top.bit"

# ---- Generate .bin for quad-SPI flash ----
# Nexys Video uses a quad-SPI flash (MT25QL128 or similar).
# The .bin file is what Vivado Hardware Manager flashes via "Add Configuration Memory Device".
# Bitstream is padded to 4-byte boundary and the .bin includes the SPI flash header.
puts "INFO: Generating flash .bin file..."
write_cfgmem -format BIN -interface SPIx4 -size 16 \
    -loadbit "up 0x0 $proj_dir/c930_soc_top.bit" \
    -force -file "$proj_dir/c930_soc_top.bin"
puts "INFO: Flash .bin written to $proj_dir/c930_soc_top.bin"

# ---- Also write a .ltx probe file (for ILA if added later) ----
# write_debug_probes "$proj_dir/c930_soc_top.ltx"

close_project
puts "INFO: Done. Files at $proj_dir/"
