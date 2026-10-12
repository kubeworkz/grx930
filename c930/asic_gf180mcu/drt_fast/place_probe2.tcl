read_db $::env(FAST_ODB)
set block [[[ord::get_db] getChip] getBlock]
set d [$block getDieArea]
puts "DIE_UM [expr {([$d xMax]-[$d xMin])/2000.0}] x [expr {([$d yMax]-[$d yMin])/2000.0}]"
set ca [$block getCoreArea]
puts "CORE_UM [expr {([$ca xMax]-[$ca xMin])/2000.0}] x [expr {([$ca yMax]-[$ca yMin])/2000.0}]"
puts "ROWS [llength [$block getRows]]"
set tot 0.0; set n 0
array set hxb {}
array set hyb {}
for {set b 0} {$b<26} {incr b} { set hxb($b) 0; set hyb($b) 0 }
foreach inst [$block getInsts] {
  set m [$inst getMaster]
  set tot [expr {$tot + [$m getWidth]*[$m getHeight]}]
  incr n
  set bb [$inst getBBox]
  set x [expr {(([$bb xMin] + [$bb xMax])/2)/2000.0}]
  set y [expr {(([$bb yMin] + [$bb yMax])/2)/2000.0}]
  set bx [expr {int($x/393)}]
  set by [expr {int($y/256)}]
  if { ![info exists hxb($bx)] } { set hxb($bx) 0 }
  if { ![info exists hyb($by)] } { set hyb($by) 0 }
  incr hxb($bx); incr hyb($by)
}
set coreA [expr {([$ca xMax]-[$ca xMin])*([$ca yMax]-[$ca yMin])/4000000.0}]
set cellA [expr {$tot/4000000.0}]
puts "INSTS $n CELL_AREA_UM2 [format %.0f $cellA] CORE_AREA_UM2 [format %.0f $coreA] UTIL_PCT [format %.1f [expr {100*$cellA/$coreA}]]"
set lx ""
for {set b 0} {$b<20} {incr b} { append lx " [expr {$hxb($b)+0}]" }
puts "x_hist(393um):$lx"
set ly ""
for {set b 0} {$b<20} {incr b} { append ly " [expr {$hyb($b)+0}]" }
puts "y_hist(256um):$ly"
puts "PLACE_PROBE_END"
