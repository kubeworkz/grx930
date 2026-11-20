# dangling_nets.tcl -- count nets that carry pins but no routing, and nets with < 2 terminals.
#
# net_compare.py answers whether two netlists agree on a partition of pins. It cannot see a net
# whose pins are connected on paper but never routed, because the DEF still declares the net.
# This pass reads the OpenDB database itself:
#
#   * unrouted -- a SIGNAL net with two or more iterms/bterms and no Wire and no SWire. Its pins
#     are unconnected in the layout even though the netlist says they are one net.
#   * short    -- any net with fewer than two terminals. It cannot be a connection; on the audit
#     DEF these are the one-ended and zero-ended nodes.
#
# Power and ground nets are excluded from the unrouted test (they are SPECIALNETS, carried as
# SWires, and their absence is PDN's question, not routing's); they are still counted for the
# terminal test, where they always pass.
#
#     DANGLING_ODB=ODB DANGLING_REPORT=REPORT.tsv openroad -no_init -exit dangling_nets.tcl
#
# Prints one DANGLING_SUMMARY line to stdout and writes one UNROUTED/SHORT line per finding to
# REPORT.tsv. Exit status 0 when both counts are zero, 1 when either is non-zero, 2 on misuse.

# OpenROAD accepts exactly one script argument, so the paths come from the environment.
if {![info exists ::env(DANGLING_ODB)] || ![info exists ::env(DANGLING_REPORT)]} {
    puts stderr "usage: DANGLING_ODB=ODB DANGLING_REPORT=REPORT.tsv openroad -no_init -exit dangling_nets.tcl"
    exit 2
}
set odb_path $::env(DANGLING_ODB)
set report_path $::env(DANGLING_REPORT)

if {![file exists $odb_path]} {
    puts stderr "dangling_nets: no $odb_path"
    exit 2
}
read_db $odb_path
set block [ord::get_db_block]
if {$block eq "NULL"} {
    puts stderr "dangling_nets: no block after read_db $odb_path"
    exit 2
}

set nets [$block getNets]
set signal 0
set unrouted {}
set short {}
set abutted {}

foreach net $nets {
    set name [$net getName]
    set bterms [$net getBTerms]
    set iterms [$net getITerms]
    set terms [expr {[llength $bterms] + [llength $iterms]}]
    if {$terms < 2} {
        lappend short [list $name $terms]
        continue
    }
    set sigtype [$net getSigType]
    if {[string toupper $sigtype] ne "SIGNAL"} {
        continue
    }
    incr signal
    set wires [llength [$net getSWires]]
    if {[$net getWire] ne "NULL"} {
        incr wires
    }
    if {$wires != 0} {
        continue
    }
    # A pad port is its IO cell's PAD pin, placed coincident with the top-level port; the
    # connection is by abutment, so there is no signal wire and never should be one. Count it
    # separately rather than reporting every pad as an open. A pad net that also reaches core
    # logic (more than one iterm) is not excluded.
    set pad_abutment 0
    if {[llength $bterms] == 1 && [llength $iterms] == 1} {
        set inst [[lindex $iterms 0] getInst]
        if {[string match "gf180mcu_fd_io__*" [[$inst getMaster] getName]]} {
            set pad_abutment 1
        }
    }
    if {$pad_abutment} {
        lappend abutted [list $name $terms]
    } else {
        lappend unrouted [list $name $terms]
    }
}

set fh [open $report_path w]
puts $fh "# dangling_nets: nets with pins but no routing, and nets with fewer than two terminals"
puts $fh "# odb: $odb_path"
foreach rec $unrouted {
    lassign $rec name terms
    puts $fh "UNROUTED\t$name\t$terms"
}
foreach rec $short {
    lassign $rec name terms
    puts $fh "SHORT\t$name\t$terms"
}
foreach rec $abutted {
    lassign $rec name terms
    puts $fh "PAD_ABUTMENT\t$name\t$terms"
}
close $fh

set nu [llength $unrouted]
set ns [llength $short]
set na [llength $abutted]
puts "DANGLING_SUMMARY odb=$odb_path nets=[llength $nets] signal_nets=$signal unrouted=$nu short=$ns pad_abutment=$na report=$report_path"
if {$nu == 0 && $ns == 0} {
    puts "DANGLING_VERDICT CLEAN"
    exit 0
}
puts "DANGLING_VERDICT FAIL unrouted=$nu short=$ns pad_abutment=$na"
exit 1
