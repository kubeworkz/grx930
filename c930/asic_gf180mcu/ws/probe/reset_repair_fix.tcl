# reset_repair_fix.tcl -- the repair_design half of the reset fix, applied to the
# die's own post-antenna-repair database (the one the -8.6457 ns / -0.0640 ns pair
# was measured on).
#
# WHY THIS RUN EXISTS
#
#   Two passes could bound the reset's fanout. CTS can be pointed at a net list
#   (`clock_tree_synthesis -clk_nets`, what ws/tools/librelane_reset_cts_patch.py
#   now wires into a fresh arm) but it is a clock-tree pass, so on an already
#   routed database it is being used out of position. `repair_design` is the pass
#   whose job this is, and it is the one that was off in the flow
#   (RUN_POST_GPL_DESIGN_REPAIR: false, RUN_POST_GRT_DESIGN_REPAIR: stock false),
#   which is why the only thing that ever touched the reset was repair_timing's
#   load splitting: `[INFO RSZ-0045] Inserted 2954 buffers, 133 to split loads.`
#   -- one buffer ahead of the same 2,132 loads.
#
# WHAT IS CONSTRAINED
#
#   `repair_design` fixes whatever violates the limits it is given. Given this
#   design's real SDC it would repair 79,417 max-slew and 7,036 max-cap violations
#   as well, which is the explosion class the post-GPL position is declined for
#   (+79.9 % area, DPL abort -- grx930_overrides.yaml). This run therefore loads
#   `repair_sdc.tcl`: chip_top.sdc with the design-wide transition and capacitance
#   limits raised, and the fanout limit left at MAX_FANOUT_CONSTRAINT (10). The
#   violation set is then fanout only -- the reset nets -- and the run answers one
#   question: does repair_design bound the fanout it is asked to fix, or does it
#   re-drive the load like load splitting does?
#
#   The post-repair STA is NOT measured under this SDC: the corner run reads the
#   original chip_top.sdc, so all 79,417 slew violations are still reported as
#   violations. Only the repair's target set is narrowed here, and that is stated
#   in the artefact rather than hidden in it.
#
# Read-only for the flow: everything goes to ws/probe/resetfix/ (FIX_OUT_*).

source /work/ws/repro_sta/env_cts.tcl

# ---- reset cone, reported the same way before and after -----------------------
# Follow the reset from the input pad through buffers, exactly as
# ws/tools/librelane_reset_cts_patch.py's ws_reset_cone_nets does: the reset
# distribution continues through buffers and stops at gates.
# Output nets of a cell. `-filter direction==out` matches nothing (see
# ws_net_loads above), so the pin direction is read per pin.
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

# Loads on a net, counted pin by pin. `get_pins -filter "direction==in"` matches
# nothing in OpenSTA (the property value is `input`), and the first version of this
# probe reported every reset net as `loads=0` because of it -- a probe that cannot
# see the load cannot see the fix either.
proc ws_net_loads {net} {
    set n 0
    foreach pin [get_pins -quiet -of_objects [get_nets $net]] {
        if { [string match "in*" [string tolower [get_property $pin direction]]] } { incr n }
    }
    return $n
}

proc reset_report {tag} {
    set nets [reset_cone]
    set over 0
    set worst ""
    set worstn 0
    foreach net $nets {
        set loads [ws_net_loads $net]
        if { $loads > 0 } {
            puts "RESETNET $tag net=[get_name $net] loads=$loads"
        }
        if { $loads > $::env(MAX_FANOUT_CONSTRAINT) } { incr over }
        if { $loads > $worstn } { set worstn $loads; set worst [get_name $net] }
    }
    puts "RESET_SUMMARY $tag nets=[llength $nets] over_limit=$over worst=$worst worst_loads=$worstn"
}

# ---- read the database --------------------------------------------------------
read_lef $::env(TECH_LEF)
foreach l $::env(CELL_LEFS)  { read_lef $l }
foreach l $::env(PAD_LEFS)   { read_lef $l }
foreach l $::env(MACRO_LEFS) { read_lef $l }
read_liberty $::env(FIX_LIB)
read_liberty $::env(FIX_PAD_LIB)
foreach l $::env(FIX_MACRO_LIBS) { read_liberty $l }
read_db $::env(FIX_ODB)
puts "FIX: odb = $::env(FIX_ODB)"
puts "FIX: instances = [llength [get_cells *]]"

source /work/ws/probe/repair_sdc.tcl
puts "FIX: limits -- fanout=$::env(MAX_FANOUT_CONSTRAINT) (transition/capacitance raised in repair_sdc.tcl)"

# Per-net (or per-pin) fanout limits are NOT expressible on this build:
# `set_max_fanout <v> [get_nets <net>]` and `set_max_fanout <v> [get_pins <pin>]`
# both answer `[ERROR STA-0100] unsupported object type ...` (measured 2026-10-27).
# The fanout limit is therefore the design-wide MAX_FANOUT_CONSTRAINT from
# repair_sdc.tcl -- the same limit the flow's SDC sets for every net -- and the
# scoping comes from the other two limits being raised, which leaves fanout as the
# only thing this repair has to fix.

reset_report before

puts "FIX: repair_design -verbose -max_wire_length 0 -slew_margin 0 -cap_margin 0"
repair_design -verbose -max_wire_length 0 -slew_margin 0 -cap_margin 0

# The flow's own repair_design.tcl legalizes right after the repair (`source
# scripts/openroad/common/dpl.tcl`: filler removal, then `detailed_placement
# -max_displacement {1500 500}`, then check_placement). Without it the inserted
# buffers sit wherever the repair put them and an STA on that database charges
# overlap parasitics -- a property of the run, not of the design.
#
# Both parts of that call are load-bearing and were measured: the positional form
# `detailed_placement -max_displacement 1500 500` is refused
# (`[ERROR STA-0564] positional arguments not supported`), and the fillers the DB
# already contains have to come out first or DPL has no room to legalize into.
puts "FIX: remove_fillers; detailed_placement -max_displacement {1500 500}"
remove_fillers
detailed_placement -max_displacement {1500 500}
estimate_parasitics -placement

set buffers_added [llength [get_cells -quiet -hierarchical "split_*"]]
puts "FIX: split_* cells present after = $buffers_added"

reset_report after

write_db $::env(FIX_OUT_ODB)
write_def $::env(FIX_OUT_DEF)
puts "FIX: wrote $::env(FIX_OUT_ODB) and $::env(FIX_OUT_DEF)"
puts FIX_DONE
