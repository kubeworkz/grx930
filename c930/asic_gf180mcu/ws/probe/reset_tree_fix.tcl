# reset_tree_fix.tcl -- the CTS half, applied on top of the repaired die database.
#
# repair_design bound the reset from 2,132 loads to 172 (three levels, +12,139
# buffers) but did not reach MAX_FANOUT_CONSTRAINT = 10: its fanout repair splits
# by its own budget, not to the limit. CTS is the pass that does reach it -- the
# flow's own sink-clustering stop criterion made 4,266 sinks into 164 leaves in
# the core run.
#
# So this is the two halves of the fix in the order the flow applies them once the
# patch is in: CTS trees the reset before it can ever get this large, and
# repair_design is what bounds a database that already has it. Here the second has
# run first, because this database is the die's existing one.
#
# Same buffers and root as the flow's CTS (grx930_overrides' CTS_CLK_BUFFERS /
# CTS_ROOT_BUFFER defaults), so the tree is the one the flow builds.

source /work/ws/repro_sta/env_cts.tcl

read_lef $::env(TECH_LEF)
foreach l $::env(CELL_LEFS)  { read_lef $l }
foreach l $::env(PAD_LEFS)   { read_lef $l }
foreach l $::env(MACRO_LEFS) { read_lef $l }
read_liberty $::env(FIX_LIB)
read_liberty $::env(FIX_PAD_LIB)
foreach l $::env(FIX_MACRO_LIBS) { read_liberty $l }
read_db $::env(FIX_ODB)
puts "TREE: odb = $::env(FIX_ODB)  instances = [llength [get_cells *]]"

proc ws_net_loads {net} {
    set n 0
    foreach pin [get_pins -quiet -of_objects [get_nets $net]] {
        if { [string match "in*" [string tolower [get_property $pin direction]]] } { incr n }
    }
    return $n
}

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
        puts "TREE_PAD inst=$name master=$master"
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

proc reset_report {tag} {
    set worstn 0
    set worst ""
    set over 0
    set nets 0
    foreach net [reset_cone] {
        incr nets
        set loads [ws_net_loads $net]
        puts "RESET_CONE $tag net=[get_name $net] loads=$loads"
        if { $loads > $::env(MAX_FANOUT_CONSTRAINT) } { incr over }
        if { $loads > $worstn } { set worstn $loads; set worst [get_name $net] }
    }
    puts "RESET_SUMMARY $tag nets=$nets over_limit=$over worst=$worst worst_loads=$worstn"
}

reset_report before

set names [list]
foreach net [reset_cone] {
    if { [ws_net_loads $net] > $::env(MAX_FANOUT_CONSTRAINT) } { lappend names [get_name $net] }
}
puts "TREE: CTS nets = $names"
if { [llength $names] } {
    clock_tree_synthesis -clk_nets $names \
        -buf_list {gf180mcu_fd_sc_mcu7t5v0__clkbuf_2 gf180mcu_fd_sc_mcu7t5v0__clkbuf_4 gf180mcu_fd_sc_mcu7t5v0__clkbuf_8} \
        -root_buf gf180mcu_fd_sc_mcu7t5v0__clkbuf_16 \
        -sink_clustering_enable
    puts "TREE: clock_tree_synthesis done"
}

reset_report after

write_db $::env(FIX_OUT_ODB)
write_def $::env(FIX_OUT_DEF)
puts "TREE: wrote $::env(FIX_OUT_ODB) and $::env(FIX_OUT_DEF)"
puts TREE_DONE
