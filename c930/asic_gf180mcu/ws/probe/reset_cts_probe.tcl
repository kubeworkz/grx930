# reset_cts_probe.tcl -- can CTS build a tree on the reset net?
#
# The question the flow cannot answer today: `clock_tree_synthesis` takes a net
# list (`-clk_nets`), and LibreLane hands it `$::env(CLOCK_NET)` -- one clock. If
# CTS accepted the reset net too, the 2,126-load buffer the post-CTS resizer
# leaves behind (`split25` on the die, `net25` in its DEF) would never be built:
# CTS would tree the reset with bounded fanout before the resizer ever sees it.
#
# Whether it *can* is not documented either way, and the difference is the whole
# design of the fix: CTS picks sinks from the net's sequential loads, and a flop's
# reset pin is not its clock pin.
#
# FIRST RUN, AND WHAT IT TAUGHT (2026-10-27): passing the reset net to
# `-clk_nets` needs a name that is IN the database. The reset net is unnamed in
# this database -- `get_nets` hands back a synthetic handle
# (`_9898872097ab0000_p_Net`) and CTS answers `[ERROR CTS-0056] Error when
# finding -clk_nets in DB` on it, which says nothing about sinks: the lookup
# failed before sink discovery. So this version finds the net by its DRIVER
# (`rst_n_pad/Y`), names it, and only then asks CTS.
#
# Read-only for the flow: everything is written under ws/probe/.

source /work/ws/repro_sta/env_cts.tcl

set odb $::env(PROBE_ODB)
puts "PROBE: odb      = $odb"
puts "PROBE: scripts  = $::env(SCRIPTS_DIR)"

read_lef $::env(TECH_LEF)
foreach l $::env(CELL_LEFS)  { read_lef $l }
foreach l $::env(PAD_LEFS)   { read_lef $l }
foreach l $::env(MACRO_LEFS) { read_lef $l }
read_liberty $::env(PROBE_LIB)
read_liberty $::env(PROBE_PAD_LIB)
foreach l $::env(PROBE_MACRO_LIBS) { read_liberty $l }
read_db $odb

set block [ord::get_db_block]
puts "PROBE: instances = [llength [get_cells *]]"

# Find the reset pad: the input pad whose instance name carries rst.
set reset_pad ""
foreach inst [$block getInsts] {
    set name [$inst getName]
    set mast [string tolower [[$inst getMaster] getName]]
    if { [string match "*rst*" $name] && [string match "*in_c*" $mast] } {
        puts "PROBE_PAD inst=$name master=$mast"
        set reset_pad $inst
    }
}
if { $reset_pad == "" } {
    puts "PROBE_RESULT no_reset_pad"
    exit 0
}

set yterm [$reset_pad findITerm "Y"]
set net [$yterm getNet]
if { $net == "NULL" } {
    puts "PROBE_RESULT pad_y_has_no_net"
    exit 0
}
set before [llength [$net getITerms]]
set netname [$net getName]
puts "PROBE: reset net found by driver: name='$netname' pins=$before"
# The rerun after the first probe: the net IS named (i_chip_core.rst_n) -- sta's
# `get_nets -hierarchical` reported a synthetic handle, which is what CTS-0056 was
# really about (a name lookup that never reached sink discovery). So pass the
# database's own name; no rename needed.

set seq 0
foreach it [$net getITerms] {
    set m [string tolower [[[$it getInst] getMaster] getName]]
    if { [string match "*dff*" $m] || [string match "*dlatch*" $m] } { incr seq }
}
puts "PROBE: sequential loads on the net = $seq of $before"

puts "PROBE: buffers = clkbuf_2/4/8, root clkbuf_16 (the flow's CTS_CLK_BUFFERS/CTS_ROOT_BUFFER)"
set rc [catch {
    clock_tree_synthesis \
        -clk_nets $netname \
        -buf_list {gf180mcu_fd_sc_mcu7t5v0__clkbuf_2 gf180mcu_fd_sc_mcu7t5v0__clkbuf_4 gf180mcu_fd_sc_mcu7t5v0__clkbuf_8} \
        -root_buf gf180mcu_fd_sc_mcu7t5v0__clkbuf_16 \
        -sink_clustering_enable
} msg]
puts "PROBE: clock_tree_synthesis rc=$rc msg=$msg"
if { $rc == 0 } { report_cts }

set after [llength [$net getITerms]]
puts "PROBE_RESULT target=$netname pins_before=$before pins_after=$after sequential_loads=$seq"
foreach c {clkbuf_regs clkload delaybuf} {
    set n [llength [get_cells -quiet ${c}*]]
    puts "PROBE_INS $c $n"
}
write_db /work/ws/probe/out_cts_probe.odb
puts PROBE_DONE
