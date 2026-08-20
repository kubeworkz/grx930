## ---------------------------------------------------------------------------
## run_synth.tcl  --  Vivado batch synthesis + implementation + timing
##
## Usage:  vivado -mode batch -source synth_xilinx/run_synth.tcl
##
## This script assumes the project was already created by create_project.tcl.
## It runs synthesis, implementation, and generates timing/area reports.
## ---------------------------------------------------------------------------

set proj_dir  "[file dirname [info script]]/../build/vivado"
set proj_name "c930_artix7"

# Check for synth_only argument
set synth_only 0
if {[lsearch -exact $tcl.argv "synth_only"] >= 0} {
    set synth_only 1
    puts "INFO: Running synthesis only (no implementation)"
}

# ---- Open project ----
open_project "$proj_dir/$proj_name.xpr"

# ---- Reset runs if they exist ----
if {[llength [get_runs synth_1]] > 0} { reset_run synth_1 }
if {[llength [get_runs impl_1]]  > 0} { reset_run impl_1 }

# ---- Synthesis ----
puts "INFO: Running synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "INFO: Synthesis status: $synth_status"

if {[string match "*ERROR*" $synth_status]} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# If synth_only mode, stop here
if {$synth_only} {
    puts "INFO: Synthesis complete (synth_only mode)."
    close_project
    exit 0
}

# ---- Post-synthesis reports ----
open_run synth_1
puts "INFO: Post-synthesis utilization:"
report_utilization -file "$proj_dir/post_synth_utilization.rpt"
puts "INFO: Post-synthesis timing:"
report_timing_summary -file "$proj_dir/post_synth_timing.rpt"

# Print Fmax to console
set wns [get_property STATS.WNS [get_runs synth_1]]
set fmax [expr {1000.0 / (10.0 - $wns)}]
puts "INFO: Post-synthesis estimated Fmax = ${fmax} MHz (WNS = ${wns} ns)"

# ---- Implementation (place + route) ----
puts "INFO: Running implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "INFO: Implementation status: $impl_status"

if {[string match "*ERROR*" $impl_status]} {
    puts "ERROR: Implementation failed!"
    exit 1
}

# ---- Post-implementation reports ----
open_run impl_1
puts "INFO: Post-implementation utilization:"
report_utilization -file "$proj_dir/post_impl_utilization.rpt"
puts "INFO: Post-implementation timing:"
report_timing_summary -file "$proj_dir/post_impl_timing.rpt"
report_timing -sort_by group -max_paths 100 -path_type summary \
    -file "$proj_dir/post_impl_timing_paths.rpt"
puts "INFO: Post-implementation DRC:"
report_drc -file "$proj_dir/post_impl_drc.rpt"

# Print Fmax to console
set wns [get_property STATS.WNS [get_runs impl_1]]
set fmax [expr {1000.0 / (10.0 - $wns)}]
puts "INFO: Post-implementation Fmax = ${fmax} MHz (WNS = ${wns} ns)"

# ---- Generate bitstream (optional) ----
# Check for bitstream argument
if {[lsearch -exact $tcl.argv "bitstream"] >= 0} {
    launch_runs impl_1 -to_step write_bitstream
    wait_on_run impl_1
    puts "INFO: Bitstream generated"
}

puts "INFO: Done. Reports at $proj_dir/"
close_project
