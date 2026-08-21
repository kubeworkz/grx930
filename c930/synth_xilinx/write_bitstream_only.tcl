## ---------------------------------------------------------------------------
## write_bitstream_only.tcl  --  Run ONLY the write_bitstream step.
##
## Use when the routed design (impl_1) already exists and the full
## run_synth.tcl flow is not needed. Single Vivado invocation -> minimal time
## and memory (useful on memory-constrained WSL hosts where the two-pass
## `make bitstream` can lose the VM in the impl -> bitstream gap).
##
##   vivado -mode batch -source write_bitstream_only.tcl
## ---------------------------------------------------------------------------

set proj_dir  "[file dirname [info script]]/../build/vivado"
set proj_name "c930_artix7"

open_project "$proj_dir/$proj_name.xpr"

set impl_status [get_property STATUS [get_runs impl_1]]
puts "INFO: impl_1 status: $impl_status"

if {![string match -nocase "*write_bitstream*" $impl_status]} {
    puts "INFO: Running write_bitstream..."
    launch_runs impl_1 -to_step write_bitstream -jobs 2
    wait_on_run impl_1
    set impl_status [get_property STATUS [get_runs impl_1]]
    puts "INFO: impl_1 status after: $impl_status"
}

if {[string match "*ERROR*" $impl_status]} {
    puts "ERROR: write_bitstream failed!"
    exit 1
}

puts "INFO: Bitstream generated."
close_project
