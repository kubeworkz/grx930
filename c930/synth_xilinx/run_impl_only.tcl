## run_impl_only.tcl -- Re-run implementation with updated XDC constraints
## Usage: vivado -mode batch -source synth_xilinx/run_impl_only.tcl

set proj_dir  "[file dirname [info script]]/../build/vivado"
set proj_name "c930_artix7"

open_project "$proj_dir/$proj_name.xpr"

# Force re-run implementation (XDC changed, need fresh place+route)
puts "INFO: Resetting impl_1 for fresh run with updated XDC..."
reset_run impl_1

puts "INFO: Launching implementation..."
launch_runs impl_1 -jobs 1
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "INFO: Implementation status: $impl_status"

if {[string match "*ERROR*" $impl_status]} {
    puts "ERROR: Implementation failed!"
    exit 1
}

# Post-implementation reports
open_run impl_1
puts "INFO: Post-implementation utilization:"
report_utilization -file "$proj_dir/post_impl_utilization.rpt"
puts "INFO: Post-implementation timing:"
report_timing_summary -file "$proj_dir/post_impl_timing.rpt"
report_timing -sort_by group -max_paths 100 -path_type summary -file "$proj_dir/post_impl_timing_paths.rpt"

# DRC
puts "INFO: Post-implementation DRC:"
report_drc -file "$proj_dir/post_impl_drc.rpt"

# Print Fmax
set wns [get_property STATS.WNS [get_runs impl_1]]
if {$wns ne "" && $wns ne "N/A"} {
    set fmax [expr {1000.0 / (10.0 - $wns)}]
    puts "INFO: Routed Fmax = ${fmax} MHz (WNS = ${wns} ns at 100 MHz sys_clk)"
}

# Write bitstream
puts "INFO: Writing bitstream..."
write_bitstream -force "$proj_dir/c930_soc_top.bit"
puts "INFO: Done. Bitstream at $proj_dir/c930_soc_top.bit"

close_project
