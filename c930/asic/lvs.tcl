# lvs.tcl — Netgen LVS script for GRX930 → SKY130
#
# Usage:
#   cd c930/asic
#   netgen -script lvs.tcl
#
# Compares the routed Verilog (layout) against the synthesis output (schematic)
# to verify they match electrically.

# ── Configuration ──────────────────────────────────────────────
set BUILD_DIR "build"
set DESIGN    "c930_soc_top"

# Layout netlist (from OpenROAD routing)
set LAYOUT_FILE "${BUILD_DIR}/c930_soc_routed.v"

# Schematic netlist (from Yosys synthesis)
set SCHEMATIC_FILE "${BUILD_DIR}/c930_soc_synth.v"

# Output report
set REPORT_FILE "${BUILD_DIR}/lvs_report.json"

# ── Setup ──────────────────────────────────────────────────────
puts "=== Netgen LVS: ${DESIGN} ==="
puts "Layout:     ${LAYOUT_FILE}"
puts "Schematic:  ${SCHEMATIC_FILE}"

# Read both netlists
read_netlist $SCHEMATIC_FILE -cell ${DESIGN}
read_netlist $LAYOUT_FILE -cell ${DESIGN} -top

# ── Comparison ─────────────────────────────────────────────────
# Compare circuits
compare_circuits ${DESIGN} ${DESIGN}

# ── Report ─────────────────────────────────────────────────────
# Write JSON report
report_json $REPORT_FILE

# Print summary
puts "=== LVS Summary ==="
puts "Circuits compared: ${DESIGN}"
puts "Report written to: ${REPORT_FILE}"

# Check result
if {[compare_result] == 0} {
    puts "✅ LVS PASSED — netlists match"
    exit 0
} else {
    puts "⚠️ LVS FAILED — netlists do not match"
    exit 1
}
