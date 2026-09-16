# Quick schematic export — paste into Vivado Tcl Console
# Prerequisites: Vivado GUI open with c930_artix7.xpr project
# This generates per-subsystem utilization + timing reports

set outdir "build/schematics"
file mkdir $outdir

# Open synth (hierarchy preserved)
open_run synth_1

# Export netlist per subsystem
foreach {label hpath} {
    01_soc_top       c930_soc_top
    02_cpu           c930_soc_top/u_cpu
    03_npu_top       c930_soc_top/u_npu
    04_npu_core      c930_soc_top/u_npu/u_core
    05_systolic      c930_soc_top/u_npu/u_core/u_array
    06_pe            c930_soc_top/u_npu/u_core/u_array/u_pe
    07_fp_acc        c930_soc_top/u_npu/u_core/u_array/u_pe/u_fp16_acc
    08_npu_act       c930_soc_top/u_npu/u_core/u_act
    09_crossbar      c930_soc_top/u_crossbar
    10_l2            c930_soc_top/u_l2
    11_dma_arb       c930_soc_top/u_dma_arb
    12_core1_arb     c930_soc_top/u_core1_arb
    13_bootrom       c930_soc_top/u_bootrom
    14_uart          c930_soc_top/u_uart
    15_aplic         c930_soc_top/u_aplic
} {
    set cells [get_cells $hpath -quiet]
    if {[llength $cells] == 0} {
        puts "SKIP $label ($hpath) -- not found"
        continue
    }
    
    puts "Exporting $label..."
    
    # Utilization report
    catch {report_utilization -cell $hpath -file "$outdir/${label}_util.rpt"}
    
    # Timing report (top 10 paths through this subsystem)
    catch {report_timing -through [get_cells "$hpath/*"] -file "$outdir/${label}_timing.rpt" -max_paths 10}
    
    # Structural Verilog
    catch {write_verilog -mode funcsim -force "$outdir/${label}_struct.v" [get_cells $hpath]}
    
    # Gate-level Verilog
    catch {write_verilog -mode port -force "$outdir/${label}_gatelevel.v" [get_cells $hpath]}
    
    # EDIF netlist
    catch {write_edif -force "$outdir/${label}_netlist.edf" [get_cells $hpath]}
    
    puts "  -> $label exported (util, timing, struct.v, gatelevel.v, netlist.edf)"
}

puts "\n=== All subsystems exported to $outdir ==="
puts "For visual schematics:"
puts "  1. Window -> Schematic (opens gate-level viewer)"
puts "  2. Navigate hierarchy by double-clicking modules"
puts "  3. File -> Export -> Schematic -> PDF"
