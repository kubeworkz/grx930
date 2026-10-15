# Standalone TritonRoute driver for the DIE's pre-DRT database, for the router
# build the ws flow runs (the pre-check image's OpenROAD). It differs from
# drt_fast.tcl in exactly the place that build forced, and states why in its own
# log so the difference is a measurement, not a memory:
#
#   * no -bottom_routing_layer/-top_routing_layer: this build answers them with
#     `[ERROR DRT-0509] -bottom_routing_layer is deprecated. Use set_routing_layers
#     command instead.` and aborts the run (measured: the first die02 arm,
#     2026-10-13 23:01, rc=1 after 2 s). LibreLane's own drt.tcl passes no layer
#     flags either; the range is stated with set_routing_layers -- the
#     substitution DRT-0509 names, and what the flow's own GPL/GRT scripts do
#     from RT_MIN_LAYER/RT_MAX_LAYER (grx930: Metal1-Metal5, the whole 5-layer
#     stack). The tech's routing layers are printed below, so the log carries the
#     range as data.
#   * everything else is drt_fast.tcl: read the self-contained ODB, the same
#     detailed_route flags, -or_seed 42, write the ODB.
set out "$::env(FAST_OUT)"
file mkdir $out
puts "DIE_DRT_START tag=$::env(FAST_TAG) end_iter=$::env(FAST_END_ITER) threads=$::env(FAST_THREADS)"
read_db $::env(FAST_ODB)
set tech [ord::get_db_tech]
puts "DIE_DRT_TECH [$tech getName]"
foreach l [$tech getLayers] {
    if {[$l getType] ne "ROUTING"} { continue }
    if {[catch {set lvl [$l getRoutingLevel]} e]} { set lvl "?" }
    puts "DIE_DRT_LAYER [$l getName] level=$lvl"
}
set_routing_layers -signal $::env(FAST_MIN_LAYER)-$::env(FAST_MAX_LAYER) \
                   -clock  $::env(FAST_MIN_LAYER)-$::env(FAST_MAX_LAYER)
set_thread_count $::env(FAST_THREADS)
detailed_route \
    -output_drc $out/$::env(FAST_TAG).drc \
    -droute_end_iter $::env(FAST_END_ITER) \
    -or_seed 42 \
    -verbose 1
write_db $out/$::env(FAST_TAG).odb
puts "DIE_DRT_DONE"
