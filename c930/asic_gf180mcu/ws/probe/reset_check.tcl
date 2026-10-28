# reset_check.tcl -- what the reset distribution looks like in a database, before
# or after a repair. Read-only: prints, writes nothing.
#
#   CHECK_ODB=/work/ws/.../chip_top.odb openroad -exit /work/ws/probe/reset_check.tcl
#
# Reports three things:
#   1. the input pads found (the reset is reached through one of them);
#   2. every net in the reset's own cone -- the pad's net and the nets its buffers
#      re-drive -- with its load count, so a single 2,132-load buffer is visible as
#      a line rather than inferred from a timing report;
#   3. the 15 highest-fanout nets in the whole design, as a control: if the reset
#      is fixed but the top of this list still shows four-digit fanouts, the repair
#      did something else.
#
# The load count is per pin (`get_property direction` starts with "in"), not
# `-filter direction==in`: OpenSTA's value is `input`, and the filter version
# matches nothing, i.e. reports every net as compliant.

source /work/ws/repro_sta/env_cts.tcl

read_lef $::env(TECH_LEF)
foreach l $::env(CELL_LEFS)  { read_lef $l }
foreach l $::env(PAD_LEFS)   { read_lef $l }
foreach l $::env(MACRO_LEFS) { read_lef $l }
read_liberty $::env(FIX_LIB)
read_liberty $::env(FIX_PAD_LIB)
foreach l $::env(FIX_MACRO_LIBS) { read_liberty $l }
read_db $::env(CHECK_ODB)

proc ws_net_loads {net} {
    set n 0
    foreach pin [get_pins -quiet -of_objects [get_nets $net]] {
        if { [string match "in*" [string tolower [get_property $pin direction]]] } { incr n }
    }
    return $n
}

# Output nets of a cell, again without a `direction==out` filter (same reason).
proc ws_out_nets {cell} {
    set nets [list]
    foreach pin [get_pins -quiet -of_objects $cell] {
        if { [string match "out*" [string tolower [get_property $pin direction]]] } {
            foreach net [get_nets -quiet -of_objects $pin] { lappend nets $net }
        }
    }
    return $nets
}

proc reset_cone {} {
    set queue [list]
    foreach inst [get_cells -quiet *] {
        set name [get_name $inst]
        if { ![string match -nocase "*rst*" $name] } { continue }
        set master [get_property $inst ref_name]
        if { ![string match -nocase "*in_c*" $master] && ![string match -nocase "*in_s*" $master] } { continue }
        puts "CHECK_PAD inst=$name master=$master"
        foreach pin [get_pins -quiet "$name/Y"] {
            foreach net [get_nets -quiet -of_objects $pin] {
                if { [lsearch -exact $queue $net] < 0 } { lappend queue $net }
            }
        }
    }
    set seen [list]
    set nets [list]
    while { [llength $queue] } {
        set net [lindex $queue 0]
        set queue [lrange $queue 1 end]
        if { [lsearch -exact $seen $net] >= 0 } { continue }
        lappend seen $net
        lappend nets $net
        foreach cell [get_cells -quiet -of_objects [get_nets $net]] {
            set mast [string tolower [get_property $cell ref_name]]
            if { ![string match "*buf*" $mast] } { continue }
            foreach onet [ws_out_nets $cell] {
                if { [lsearch -exact $seen $onet] < 0 } { lappend queue $onet }
            }
        }
    }
    return $nets
}

puts "CHECK: odb = $::env(CHECK_ODB)"
puts "CHECK: instances = [llength [get_cells *]]  nets = [llength [get_nets *]]"

set limit $::env(MAX_FANOUT_CONSTRAINT)
set cone [reset_cone]
set over 0
set worstn 0
set worst ""
foreach net $cone {
    set loads [ws_net_loads $net]
    puts "CHECK_CONE net=[get_name $net] loads=$loads"
    if { $loads > $limit } { incr over }
    if { $loads > $worstn } { set worstn $loads; set worst [get_name $net] }
}
puts "CHECK_CONE_SUMMARY nets=[llength $cone] over_limit=$over worst=$worst worst_loads=$worstn limit=$limit"

# Control: the whole design's fanout tail.
set all [list]
foreach net [get_nets -quiet *] {
    lappend all [list [ws_net_loads $net] [get_name $net]]
}
set top [lsort -integer -decreasing -index 0 $all]
set shown 0
foreach row $top {
    if { $shown >= 15 } { break }
    puts "CHECK_TOP loads=[lindex $row 0] net=[lindex $row 1]"
    incr shown
}
puts "CHECK_DONE"
