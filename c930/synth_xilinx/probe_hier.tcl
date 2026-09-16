open_project build/vivado/c930_artix7.xpr
open_run synth_1

set all [get_cells -hierarchical]
puts "TOTAL_CELLS: [llength $all]"

# Find top-level children
set top_kids [filter $all "LEVEL==1"]
puts "TOP_CHILDREN: [llength $top_kids]"
foreach c $top_kids {
    set ref [get_property REF_NAME $c]
    puts "  TOP: $ref -> $c"
}

# Check if there's a design that matches our top module name
puts "CURRENT_DESIGN: [current_design -quiet]"
set designs [get_designs -quiet]
puts "ALL_DESIGNS: $designs"

close_design
close_project
