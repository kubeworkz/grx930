# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# Probe: count overlapping standard-cell/macro instances in the placement.
# Hypothesis: the DPL-0036 recovery in step 44 left diode/instances
# overlapping, which would explain millions of DRT shorts + capped
# DRT-0225 pin-access failures independent of GRT guide quality.
read_db /work/openlane2_rtl/runs/RUN_2026-09-24_04-18-20/50-openroad-globalrouting/grx930_test_chip.odb

proc bx {b m} {
    foreach m2 {xMin getXMin} {
        if {![catch {$b $m2} v]} { return $v }
    }
    error "no x accessor"
}

set block [ord::get_db_block]
set insts [$block getInsts]
set n [llength $insts]
puts "TOTAL_INSTS=$n"

set buckets [dict create]
set overlaps 0
set shown 0
set B 50000 ;# 50 um buckets at 1000 dbu/um

foreach inst $insts {
    set b [$inst getBBox]
    if {[catch {set x1 [bx $b xMin]} e]} {
        puts "API_FAIL: $e ; raw=[$b]"
        puts "rawbox=$b"
        exit 1
    }
    set y1 [$b yMin]
    set x2 [$b xMax]
    set y2 [$b yMax]
    set g1x [expr {int(floor(double($x1)/$B))}]
    set g1y [expr {int(floor(double($y1)/$B))}]
    set g2x [expr {int(floor(double($x2)/$B))}]
    set g2y [expr {int(floor(double($y2)/$B))}]
    set name [$inst getName]
    set hit 0
    for {set gx $g1x} {$gx <= $g2x} {incr gx} {
        for {set gy $g1y} {$gy <= $g2y} {incr gy} {
            set key "$gx:$gy"
            if {![dict exists $buckets $key]} { continue }
            foreach e [dict get $buckets $key] {
                lassign $e oname ox1 oy1 ox2 oy2
                if {$x1 < $ox2 && $ox1 < $x2 && $y1 < $oy2 && $oy1 < $y2} {
                    incr overlaps
                    incr hit
                    if {$shown < 40} {
                        puts "OVERLAP: $name <-> $oname"
                        incr shown
                    }
                }
            }
        }
    }
    for {set gx $g1x} {$gx <= $g2x} {incr gx} {
        for {set gy $g1y} {$gy <= $g2y} {incr gy} {
            dict lappend buckets "$gx:$gy" [list $name $x1 $y1 $x2 $y2]
        }
    }
    if {$hit > 0 && $shown <= 40} {
        # already printed pairs
    }
}

puts "TOTAL_OVERLAP_PAIRS=$overlaps"
exit 0
