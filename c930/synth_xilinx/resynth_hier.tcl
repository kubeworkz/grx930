# Re-synthesize with hierarchy preserved for schematic export
open_project build/vivado/c930_artix7.xpr
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
puts "FLATTEN: [get_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY [get_runs synth_1]]"
reset_run synth_1
launch_runs synth_1 -jobs 6
wait_on_run synth_1
puts "SYNTH_STATUS: [get_property STATUS [get_runs synth_1]]"
close_project
