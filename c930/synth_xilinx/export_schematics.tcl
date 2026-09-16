# =============================================================================
# export_schematics.tcl — Export gate-level netlists + reports
#
# Uses open_run (requires project context) to preserve RTL hierarchy.
# =============================================================================

set proj_dir "/mnt/c/Users/kubew/grx930-build/c930/build/vivado/c930_artix7"
set outdir "/mnt/c/Users/kubew/grx930-build/c930/build/schematics"
file mkdir $outdir

# --- Open the existing project (preserves run links and hierarchy) ---
puts "Opening project..."
open_project "$proj_dir.xpr"

# --- Open the SYNTHESIS run (has RTL hierarchy) ---
puts "Opening synth run..."
open_run synth_1

set ncells [llength [get_cells -hierarchical]]
puts "Synth design loaded. $ncells hierarchical cells."

# --- Subsystems to export ---
set subsys {
    {"01_soc_top"       "c930_soc_top"}
    {"02_cpu_subsys"    "c930_soc_top/u_cpu"}
    {"03_npu0"          "c930_soc_top/u_npu"}
    {"04_npu0_core"     "c930_soc_top/u_npu/u_core"}
    {"05_npu0_array"    "c930_soc_top/u_npu/u_core/u_array"}
    {"06_npu0_pe"       "c930_soc_top/u_npu/u_core/u_array/u_pe"}
    {"07_npu0_fp_acc"   "c930_soc_top/u_npu/u_core/u_array/u_pe/u_fp16_acc"}
    {"08_npu0_act"      "c930_soc_top/u_npu/u_core/u_act"}
    {"09_npu1"          "c930_soc_top/u_npu1"}
    {"10_crossbar"      "c930_soc_top/u_crossbar"}
    {"11_dma_arb_core"  "c930_soc_top/u_core1_arb"}
    {"12_dma_arb_npu"   "c930_soc_top/u_dma_arb"}
    {"13_l2_cache"      "c930_soc_top/u_l2"}
    {"14_bootrom"       "c930_soc_top/u_bootrom"}
    {"15_uart"          "c930_soc_top/u_uart"}
    {"16_aplic"         "c930_soc_top/u_aplic"}
}

puts "\n=== Exporting subsystem netlists (synth) ==="

foreach entry $subsys {
    lassign $entry label hpath

    set cells [get_cells $hpath -quiet]
    if {[llength $cells] == 0} {
        puts "SKIP $label ($hpath) -- not found"
        continue
    }

    set base "$outdir/$label"
    set nsub [llength [get_cells -hierarchical -of_objects $cells]]
    puts "\[$nsub cells\] $label"

    catch {
        report_utilization -cell $hpath -file "$base\_util.rpt"
        puts "  -> util.rpt"
    }

    catch {
        report_timing -through [get_cells "$hpath/*"] -file "$base\_timing.rpt" -max_paths 10
        puts "  -> timing.rpt"
    }

    catch {
        write_verilog -mode funcsim -force "$base\_struct.v" [get_cells $hpath]
        puts "  -> struct.v"
    }

    catch {
        write_verilog -mode port -force "$base\_gatelevel.v" [get_cells $hpath]
        puts "  -> gatelevel.v"
    }

    catch {
        write_edif -force "$base\_netlist.edf" [get_cells $hpath]
        puts "  -> netlist.edf"
    }
}

# Full design
catch {
    write_verilog -mode funcsim -force "$outdir/00_full_structural.v"
    puts "-> 00_full_structural.v"
}
catch {
    write_verilog -mode port -force "$outdir/00_full_gatelevel.v"
    puts "-> 00_full_gatelevel.v"
}
catch {
    write_edif -force "$outdir/00_full_netlist.edf"
    puts "-> 00_full_netlist.edf"
}

# Hierarchy dump
set fp [open "$outdir/00_hierarchy.txt" w]
puts $fp "=== RTL Hierarchy (synth, open_run) ==="
set prev_lvl 0
foreach c [get_cells -hierarchical -filter "LEVEL<=4"] {
    set lvl [get_property LEVEL $c]
    set ref [get_property REF_NAME $c]
    set nm [get_property NAME $c]
    set indent ""
    for {set i 0} {$i < $lvl} {incr i} { append indent "  " }
    puts $fp "${indent}${ref} -> ${nm}"
}
close $fp
puts "-> 00_hierarchy.txt"

close_design

# --- Now open IMPL run for timing/power ---
puts "\n=== Opening impl run for timing/power ==="
open_run impl_1

report_timing_summary -file "$outdir/00_timing_summary.rpt"
puts "-> 00_timing_summary.rpt"

report_utilization -file "$outdir/00_utilization.rpt"
puts "-> 00_utilization.rpt"

catch {
    report_power -file "$outdir/00_power.rpt"
    puts "-> 00_power.rpt"
}

catch {
    report_clocks -file "$outdir/00_clocks.rpt"
    puts "-> 00_clocks.rpt"
}

catch {
    report_clock_interaction -delay_type min_max -file "$outdir/00_clock_interaction.rpt"
    puts "-> 00_clock_interaction.rpt"
}

catch {
    report_drc -file "$outdir/00_drc.rpt"
    puts "-> 00_drc.rpt"
}

close_design
close_project

puts "\n=== DONE. Output: $outdir ==="
puts "\nFor VISUAL schematics, open Vivado GUI and:"
puts "  1. Open the project: $proj_dir.xpr"
puts "  2. Run synthesis (or use existing synth_1)"
puts "  3. Window -> Schematic"
puts "  4. Navigate to any module, File -> Export -> Schematic -> PDF"
