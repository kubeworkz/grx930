# ====================================================================
# export_schematic_pdfs.tcl
# Run inside Vivado GUI's Tcl Console (not batch mode).
# Opens the routed design and exports per-subsystem schematic PDFs.
#
# Usage:
#   1. Open Vivado GUI: vivado build/vivado/c930_artix7.xpr
#   2. Window → Tcl Console (or View → Tcl Console)
#   3. paste this entire script and press Enter
# ====================================================================

set outdir [file normalize "build/schematics"]
file mkdir $outdir

puts "=== C930 SoC Schematic Export ==="

# --- Step 1: Open the synth design (preserves hierarchy) ---
if {[llength [get_designs -quiet synth_1]] == 0} {
    puts "Opening synth_1..."
    open_run synth_1
} else {
    current_design synth_1
    puts "Using existing synth_1"
}

# --- Step 2: Open Vivado's schematic viewer ---
puts "Opening schematic viewer..."
start_gui

# --- Step 3: Navigate to top level and capture ---
# Vivado will display the top-level schematic
puts ""
puts "=== Instructions ==="
puts "The Schematic window is now open at the top level."
puts ""
puts "To export PDFs for each subsystem:"
puts "  1. In the schematic window, double-click a module to descend"
puts "  2. File → Export → Schematic → PDF"
puts "  3. Save to: $outdir/<subsystem>.pdf"
puts ""
puts "Subsystem shortcuts (type these in Tcl Console to jump):"
puts "  highlight_objects [get_cells c930_soc_top/u_cpu]"
puts "  highlight_objects [get_cells c930_soc_top/u_npu]"
puts "  highlight_objects [get_cells c930_soc_top/u_crossbar]"
puts "  highlight_objects [get_cells c930_soc_top/u_l2]"
puts ""
puts "Or use the automated export below (blocks GUI but exports all):"
puts "  Type: source build/export_schem_auto.tcl"
puts ""

# --- Step 4: Automated batch export (optional) ---
# Uncomment below to auto-export all subsystems as PDFs
# WARNING: This takes ~5 min and uses the GUI

set subsys_list {
    {01_soc_top       c930_soc_top              "SoC Top Level"}
    {02_cpu           c930_soc_top/u_cpu        "CPU Core"}
    {03_npu_top       c930_soc_top/u_npu        "NPU Top"}
    {04_npu_core      c930_soc_top/u_npu/u_core "NPU Core"}
    {05_array         c930_soc_top/u_npu/u_core/u_array "Systolic Array"}
    {06_pe            c930_soc_top/u_npu/u_core/u_array/u_pe "Tensor PE"}
    {07_fp16_acc      c930_soc_top/u_npu/u_core/u_array/u_pe/u_fp16_acc "FP16 Accumulator"}
    {08_npu_act       c930_soc_top/u_npu/u_core/u_act "Activation Unit"}
    {09_crossbar      c930_soc_top/u_crossbar   "AXI Crossbar"}
    {10_l2            c930_soc_top/u_l2         "L2 Cache"}
    {11_dma_arb       c930_soc_top/u_dma_arb    "DMA Arbiter"}
    {12_core1_arb     c930_soc_top/u_core1_arb  "Core1 Arbiter"}
    {13_bootrom       c930_soc_top/u_bootrom    "Boot ROM"}
    {14_uart          c930_soc_top/u_uart       "UART"}
    {15_aplic         c930_soc_top/u_aplic      "APLIC Interrupt Ctrl"}
    {16_bus           c930_soc_top/u_bus        "SoC Bus"}
}

puts "\n=== Auto-export commands (paste individually) ==="
foreach entry $subsys_list {
    lassign $entry label hpath desc
    puts "  # $desc"
    puts "  set cells \[get_cells $hpath -quiet\]"
    puts "  if {\[llength \$cells\] > 0} {"
    puts "    highlight_objects \$cells"
    puts "    puts \"Export $label: navigate down and File → Export → Schematic → PDF\""
    puts "  }"
    puts ""
}

puts "\n=== Done. Schematic window is open. ==="
