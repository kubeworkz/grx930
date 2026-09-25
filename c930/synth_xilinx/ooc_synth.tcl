# ---------------------------------------------------------------------------
# ooc_synth.tcl -- out-of-context synthesis, place and route of one module,
# for a real utilization and Fmax number rather than an estimate.
#
# Out of context because the question is what the block costs and how fast it
# closes, not how it pins out: no I/O buffers are inserted, so the report is the
# logic, and a clock constraint on the port is honoured as a clock.
#
#   vivado -mode batch -source ooc_synth.tcl -tclargs <top> <part> <period_ns> \
#          <out_dir> <file> [<file> ...]
#
# Prints REPORT lines the caller greps, and writes the full reports next to the
# checkpoint.  Exits non-zero if synthesis or routing fails, so a caller that
# only looks at the exit code is not misled by a half-finished run.
# ---------------------------------------------------------------------------

if {$argc < 5} {
  puts "ERROR: usage: <top> <part> <period_ns> <out_dir> <file> \[<file> ...\]"
  exit 1
}

set top     [lindex $argv 0]
set part    [lindex $argv 1]
set period  [lindex $argv 2]
set out_dir [lindex $argv 3]
set files   [lrange $argv 4 end]

file mkdir $out_dir

puts "REPORT top=$top part=$part period=${period}ns"

foreach f $files {
  if {![file exists $f]} {
    puts "ERROR: no such file: $f"
    exit 1
  }
  read_verilog -sv $f
}

# The clock, as a constraint rather than a comment.  set_input_delay on the rest
# would only make the numbers prettier: an out-of-context block's inputs come
# from registers in the parent, and this asks what the block itself can do.
set xdc [file join $out_dir ooc.xdc]
set fh [open $xdc w]
puts $fh "create_clock -period $period -name clk \[get_ports i_clk\]"
close $fh
read_xdc $xdc

# Defines come through the environment, so the positional arguments stay files.
set defargs {}
if {[info exists ::env(OOC_DEFINES)] && $::env(OOC_DEFINES) ne ""} {
  foreach d $::env(OOC_DEFINES) {
    lappend defargs -verilog_define $d
  }
  puts "REPORT defines=$::env(OOC_DEFINES)"
}

# Parameters likewise: an out-of-context run has to be given the shape the
# parent instantiates, or it synthesizes the module's defaults -- which here are
# the section 6.2 shape, whose A staging buffer is 262,144 bits and infers no RAM.
if {[info exists ::env(OOC_GENERICS)] && $::env(OOC_GENERICS) ne ""} {
  foreach g $::env(OOC_GENERICS) {
    lappend defargs -generic $g
  }
  puts "REPORT generics=$::env(OOC_GENERICS)"
}

if {[catch {synth_design -top $top -part $part -mode out_of_context {*}$defargs} err]} {
  puts "ERROR: synth_design failed: $err"
  exit 2
}

report_utilization -file [file join $out_dir synth_util.rpt]
puts "REPORT stage=synth"
puts "REPORT synth_luts=[llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]"
puts "REPORT synth_ffs=[llength [get_cells -hier -filter {REF_NAME =~ FD*}]]"
puts "REPORT synth_dsp=[llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]"
puts "REPORT synth_bram=[llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]"

opt_design
place_design
phys_opt_design
if {[catch {route_design} err]} {
  puts "ERROR: route_design failed: $err"
  exit 3
}

write_checkpoint -force [file join $out_dir ${top}_routed.dcp]
report_utilization -file [file join $out_dir routed_util.rpt]
report_timing_summary -file [file join $out_dir routed_timing.rpt]
report_timing -max_paths 10 -nworst 10 -delay_type max \
  -file [file join $out_dir routed_paths.rpt]

# The numbers, on stdout, so a log is enough to read the answer.
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set period_f [expr {double($period)}]
puts "REPORT routed_wns=$wns"
if {$wns < 0} {
  puts "REPORT routed_fmax_mhz=[format %.2f [expr {1000.0 / ($period_f - $wns)}]]"
  puts "REPORT meets_timing=no"
} else {
  puts "REPORT routed_fmax_mhz=[format %.2f [expr {1000.0 / ($period_f - $wns)}]]"
  puts "REPORT meets_timing=yes"
}

foreach {name pattern} {luts LUT* ffs FD* dsp DSP* bram RAMB* carry CARRY*} {
  puts "REPORT routed_$name=[llength [get_cells -hier -filter "REF_NAME =~ $pattern"]]"
}

# What the worst path actually is, since "it missed" is not actionable.
set p [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
if {$p ne ""} {
  puts "REPORT worst_from=[get_property STARTPOINT_PIN $p]"
  puts "REPORT worst_to=[get_property ENDPOINT_PIN $p]"
  puts "REPORT worst_logic_ns=[get_property DATAPATH_DELAY $p]"
  puts "REPORT worst_levels=[get_property LOGIC_LEVELS $p]"
}

puts "REPORT done=1"
exit 0
