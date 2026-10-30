# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# antenna_probe.tcl -- run OpenROAD's own repair_antennas on the die's pre-repair
# database, with the argument list LibreLane's antenna_repair.tcl builds from its
# four config variables (GRT_ANTENNA_REPAIR_ITERS / _MARGIN / _JUMPER_ONLY /
# _DIODE_ONLY, plus GRT_ALLOW_CONGESTION). Same binary, same command, same database
# as the flow's OpenROAD.DiodeInsertion step -- the difference is only that this
# driver catches the error and writes down what it got, so a fatal abort is a datum
# instead of the end of a 30-minute flow resume.
set out $::env(ANT_OUT)
file mkdir $out
set v $::env(ANT_VARIANT)
puts "ANT_PROBE_START variant=$v iters=$::env(ANT_ITERS) margin=$::env(ANT_MARGIN) jumper_only=$::env(ANT_JUMPER_ONLY) diode_only=$::env(ANT_DIODE_ONLY) allow_congestion=$::env(ANT_ALLOW_CONG) cell=$::env(ANT_DIODE_CELL)"
puts "ANT_PROBE_DB $::env(ANT_ODB)"
read_db $::env(ANT_ODB)
set arg_list [list $::env(ANT_DIODE_CELL) -iterations $::env(ANT_ITERS) -ratio_margin $::env(ANT_MARGIN)]
if {$::env(ANT_ALLOW_CONG) eq "1"} { lappend arg_list -allow_congestion }
if {$::env(ANT_JUMPER_ONLY) eq "1"} { lappend arg_list -jumper_only }
if {$::env(ANT_DIODE_ONLY) eq "1"} { lappend arg_list -diode_only }
puts "ANT_PROBE_CMD repair_antennas $arg_list"
set t0 [clock seconds]
set rc [catch {eval repair_antennas $arg_list} err]
set el [expr {[clock seconds] - $t0}]
puts "ANT_PROBE_RESULT variant=$v rc=$rc elapsed_s=$el err=$err"
if {$rc == 0} {
    write_db $out/$v.odb
    puts "ANT_PROBE_WROTE $out/$v.odb"
}
puts "ANT_PROBE_END variant=$v rc=$rc"
