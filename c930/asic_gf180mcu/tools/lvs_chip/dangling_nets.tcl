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
# A short net is not automatically a defect, so the test is on what the single pin *is*:
#
#   * a dangling INPUT (or INOUT) pin, or a top-level port with no driver, is a failure -- that
#     is a pin nothing drives;
#   * an empty net (no pins at all) is a failure -- a leftover that can be deleted;
#   * an unused OUTPUT is allowed only when the manifest names it, with class `unused-output`;
#   * a knowingly spare top-level input is allowed only when the manifest names it, with class
#     `spare-port` (or `spare-input`).
#
# The manifest is the pin: without it every short net fails. With it, the file's sha256 must equal
# DANGLING_MANIFEST_SHA256, every manifest row must still exist in the database, and any short net
# it does not name still fails. A new dangling output therefore stops the flow until somebody adds
# it to the manifest and bumps the hash.
#
#     DANGLING_ODB=ODB DANGLING_REPORT=REPORT.tsv openroad -no_init -exit dangling_nets.tcl
#     DANGLING_ODB=ODB DANGLING_REPORT=REPORT.tsv \
#       DANGLING_MANIFEST=manifest.tsv DANGLING_MANIFEST_SHA256=<sha256> \
#       openroad -no_init -exit dangling_nets.tcl
#
# Prints one DANGLING_SUMMARY line to stdout and writes FAIL/ALLOWED lines per finding to
# REPORT.tsv. Exit status 0 when nothing fails, 1 when anything does, 2 on misuse.

# OpenROAD accepts exactly one script argument, so the paths come from the environment.
if {![info exists ::env(DANGLING_ODB)] || ![info exists ::env(DANGLING_REPORT)]} {
    puts stderr "usage: DANGLING_ODB=ODB DANGLING_REPORT=REPORT.tsv openroad -no_init -exit dangling_nets.tcl"
    exit 2
}
set odb_path $::env(DANGLING_ODB)
set report_path $::env(DANGLING_REPORT)
set manifest_path ""
set manifest_sha ""
if {[info exists ::env(DANGLING_MANIFEST)]} { set manifest_path $::env(DANGLING_MANIFEST) }
if {[info exists ::env(DANGLING_MANIFEST_SHA256)]} { set manifest_sha $::env(DANGLING_MANIFEST_SHA256) }

if {![file exists $odb_path]} {
    puts stderr "dangling_nets: no $odb_path"
    exit 2
}

# The manifest: net -> class. Reading it before the database means a missing file or a wrong hash
# fails in seconds, not after the ODB is read.
array set allowed {}
array set allowed_terms {}
array set seen {}
if {$manifest_path ne ""} {
    if {![file exists $manifest_path]} {
        puts stderr "dangling_nets: no manifest $manifest_path"
        exit 2
    }
    if {[catch {exec sha256sum $manifest_path} hout]} {
        puts stderr "dangling_nets: cannot hash $manifest_path: $hout"
        exit 2
    }
    set computed [lindex $hout 0]
    if {$manifest_sha ne "" && $computed ne $manifest_sha} {
        puts stderr "dangling_nets: manifest hash $computed does not match the pinned $manifest_sha"
        exit 2
    }
    set fh [open $manifest_path r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set f [split $line "\t"]
        if {[llength $f] < 4} {
            puts stderr "dangling_nets: manifest line is not net<TAB>terms<TAB>pin<TAB>class: $line"
            exit 2
        }
        set allowed([lindex $f 0]) [lindex $f 3]
        set allowed_terms([lindex $f 0]) [lindex $f 1]
    }
    close $fh
    puts "DANGLING_MANIFEST $manifest_path sha256=$computed rows=[array size allowed]"
}

read_db $odb_path
set block [ord::get_db_block]
if {$block eq "NULL"} {
    puts stderr "dangling_nets: no block after read_db $odb_path"
    exit 2
}

set nets [$block getNets]
set signal 0
set failing {}
set allowed_out {}
set allowed_spare {}
set abutted {}

foreach net $nets {
    set name [$net getName]
    set bterms [$net getBTerms]
    set iterms [$net getITerms]
    set terms [expr {[llength $bterms] + [llength $iterms]}]
    if {$terms < 2} {
        if {$terms == 0} {
            lappend failing [list $name 0 EMPTY "no pins"]
            continue
        }
        if {[llength $bterms]} {
            set dir [string toupper [$bterms getIoType]]
            set pin [$bterms getName]
        } else {
            set dir [string toupper [[$iterms getMTerm] getIoType]]
            set pin [[$iterms getMTerm] getName]
        }
        set cls ""
        if {[info exists allowed($name)]} {
            set cls $allowed($name)
            set seen($name) 1
            if {$allowed_terms($name) ne "$terms"} {
                lappend failing [list $name $terms MANIFEST-STALE "manifest says $allowed_terms($name) terminals"]
                continue
            }
        }
        if {$dir eq "INPUT" || $dir eq "INOUT" || $dir eq "FEEDTHRU"} {
            if {$cls eq "spare-port" || $cls eq "spare-input"} {
                lappend allowed_spare [list $name $terms $pin]
            } else {
                lappend failing [list $name $terms DANGLING-INPUT "$pin is $dir and nothing drives it"]
            }
        } elseif {$dir eq "OUTPUT"} {
            if {$cls eq "unused-output"} {
                lappend allowed_out [list $name $terms $pin]
            } else {
                lappend failing [list $name $terms UNLISTED-OUTPUT "$pin is unused and not in the manifest"]
            }
        } else {
            lappend failing [list $name $terms UNKNOWN-DIRECTION "$pin has direction $dir"]
        }
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
        lappend failing [list $name $terms UNROUTED "$terms terminals, no wire"]
    }
}

# A manifest row that no longer describes the database is as stale as a hash that does not match:
# a typo'd name would otherwise silently allow nothing while the real net failed.
set stale 0
foreach name [array names allowed] {
    if {![info exists seen($name)]} {
        incr stale
        lappend failing [list $name "" MANIFEST-ABSENT "manifest names a net the database does not have"]
    }
}

set fh [open $report_path w]
puts $fh "# dangling_nets: nets with pins but no routing, and nets with fewer than two terminals"
puts $fh "# odb: $odb_path"
puts $fh "# manifest: $manifest_path sha256 [expr {$manifest_path ne "" ? $computed : "none"}]"
foreach rec $failing {
    lassign $rec name terms kind why
    puts $fh "FAIL\t$name\t$terms\t$kind\t$why"
}
foreach rec $allowed_out {
    lassign $rec name terms pin
    puts $fh "ALLOWED\t$name\t$terms\tunused-output\t$pin"
}
foreach rec $allowed_spare {
    lassign $rec name terms pin
    puts $fh "ALLOWED\t$name\t$terms\tspare-port\t$pin"
}
foreach rec $abutted {
    lassign $rec name terms
    puts $fh "PAD_ABUTMENT\t$name\t$terms"
}
close $fh

set nf [llength $failing]
set no [llength $allowed_out]
set ns [llength $allowed_spare]
set na [llength $abutted]
puts "DANGLING_SUMMARY odb=$odb_path nets=[llength $nets] signal_nets=$signal failing=$nf allowed_outputs=$no allowed_spares=$ns stale_manifest=$stale pad_abutment=$na report=$report_path"
if {$nf == 0} {
    puts "DANGLING_VERDICT CLEAN"
    exit 0
}
puts "DANGLING_VERDICT FAIL failing=$nf allowed_outputs=$no allowed_spares=$ns stale_manifest=$stale"
exit 1
