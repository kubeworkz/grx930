#!/bin/bash
# ---------------------------------------------------------------------------
# create_and_synth.sh  --  Create Vivado project and run synth for full SoC
#
# Target: Arty A7-200T (xc7a200tfbg484-1)
# Includes: CPU (RV64IMAC), NPU, AXI crossbar, cache adapters, boot ROM,
#           UART, DDR stub, MMIO bridge
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_DIR/build/vivado"
LOG_FILE="$BUILD_DIR/vivado_synth.log"

# Source Vivado settings (adjust path for your installation)
if [ -f "$HOME/Xilinx/Vivado/2026.1/settings64.sh" ]; then
    source "$HOME/Xilinx/Vivado/2026.1/settings64.sh"
elif [ -f "/opt/Xilinx/Vivado/2026.1/settings64.sh" ]; then
    source "/opt/Xilinx/Vivado/2026.1/settings64.sh"
elif [ -f "/c/Xilinx/Vivado/2026.1/settings64.sh" ]; then
    source "/c/Xilinx/Vivado/2026.1/settings64.sh"
elif [ -f "/mnt/c/Xilinx/Vivado/2026.1/settings64.sh" ]; then
    source "/mnt/c/Xilinx/Vivado/2026.1/settings64.sh"
else
    echo "ERROR: Vivado settings64.sh not found. Install Vivado 2026.1 or adjust path."
    exit 1
fi

export XILINXD_LICENSE_FILE="${HOME}/.Xilinx/Xilinx.lic"

mkdir -p "$BUILD_DIR"

echo "=========================================="
echo "  C930 Full SoC - Vivado Synthesis"
echo "  Target: xc7a200tfbg484-1 (Arty A7-200T)"
echo "=========================================="

# Step 1: Create project (if not exists)
if [ ! -f "$BUILD_DIR/c930_artix7.xpr" ]; then
    echo "[1/3] Creating Vivado project..."
    cd "$REPO_DIR"
    vivado -mode batch -source "$SCRIPT_DIR/create_project.tcl" \
        -log "$BUILD_DIR/create_project.log" \
        -journal "$BUILD_DIR/create_project.jou" 2>&1 | tee -a "$LOG_FILE"
else
    echo "[1/3] Project already exists, skipping creation."
fi

# Step 2: Run synthesis
echo "[2/3] Running synthesis + implementation..."
cd "$REPO_DIR"
vivado -mode batch -source "$SCRIPT_DIR/run_synth.tcl" \
    -log "$BUILD_DIR/synth_impl.log" \
    -journal "$BUILD_DIR/synth_impl.jou" 2>&1 | tee -a "$LOG_FILE"

# Step 3: Print summary
echo ""
echo "[3/3] Synthesis complete. Reports at: $BUILD_DIR/"
echo "  - post_synth_utilization.rpt"
echo "  - post_synth_timing.rpt"
echo "  - post_impl_utilization.rpt"
echo "  - post_impl_timing.rpt"
echo "  - post_impl_drc.rpt"

# Print key metrics
if [ -f "$BUILD_DIR/post_impl_utilization.rpt" ]; then
    echo ""
    echo "--- Utilization Summary ---"
    grep -A 20 "Slice Logic" "$BUILD_DIR/post_impl_utilization.rpt" | head -25
fi

if [ -f "$BUILD_DIR/post_impl_timing.rpt" ]; then
    echo ""
    echo "--- Timing Summary ---"
    grep -E "WNS|TNS|WPWS|Fmax" "$BUILD_DIR/post_impl_timing.rpt" | head -5
fi
