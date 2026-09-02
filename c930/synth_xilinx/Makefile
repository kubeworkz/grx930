# ---------------------------------------------------------------------------
# Makefile  --  Vivado batch synthesis + implementation for C930 SoC
#
# Targets:
#   make project   Create Vivado project
#   make synth     Run synthesis only (fast, gives LUT/FF/DSP counts)
#   make impl      Run synthesis + implementation + timing (full P&R)
#   make bitstream Generate bitstream (after impl)
#   make clean     Remove build artifacts
#
# Prerequisites:
#   - Xilinx Vivado (tested with 2023.2+)
#   - 'vivado' must be on PATH (source Xilinx settings64.sh first)
#
# Quick start:
#   source /opt/Xilinx/Vivado/2023.2/settings64.sh
#   cd c930/synth_xilinx
#   make impl        # full flow, ~15-30 min on 8-core machine
# ---------------------------------------------------------------------------

VIVADO   ?= vivado
PROJ_DIR := ../build/vivado
PROJ_NAME := c930_artix7

.PHONY: all project synth impl bitstream reports clean

all: yosys

# ---- Create project ----
project: $(PROJ_DIR)/$(PROJ_NAME).xpr

$(PROJ_DIR)/$(PROJ_NAME).xpr: create_project.tcl arty_a7_100t.xdc
	@mkdir -p $(PROJ_DIR)
	$(VIVADO) -mode batch -source create_project.tcl -log $(PROJ_DIR)/create_project.log -journal $(PROJ_DIR)/create_project.jou

# ---- Synthesis only (fast, ~5 min) ----
synth: $(PROJ_DIR)/$(PROJ_NAME).xpr
	$(VIVADO) -mode batch -source run_synth.tcl -tclargs synth_only -log $(PROJ_DIR)/synth.log -journal $(PROJ_DIR)/synth.jou
	@echo "=== Post-synthesis reports ==="
	@cat $(PROJ_DIR)/post_synth_timing.rpt | grep -A 2 "Design Timing Summary" || true
	@echo "---"
	@cat $(PROJ_DIR)/post_synth_utilization.rpt | grep -A 20 "Slice Logic" || true

# ---- Full implementation (synth + place + route, ~15-30 min) ----
# Use USE_DDR3L=1 for Arty A7-100T with MIG DDR3L controller
impl: $(PROJ_DIR)/$(PROJ_NAME).xpr
	$(VIVADO) -mode batch -source run_synth.tcl -tclargs "" -log $(PROJ_DIR)/impl.log -journal $(PROJ_DIR)/impl.jou

# ---- Full implementation with DDR3L (Arty A7-100T) ----
# Requires MIG IP: run `vivado -source mig_7series_arty_a7_100t.tcl` first
impl-ddr3l: $(PROJ_DIR)/$(PROJ_NAME).xpr
	$(VIVADO) -mode batch -source run_synth.tcl -tclargs "" -log $(PROJ_DIR)/impl_ddr3l.log -journal $(PROJ_DIR)/impl_ddr3l.jou
	@echo "=== Post-implementation timing ==="
	@cat $(PROJ_DIR)/post_impl_timing.rpt | grep -A 2 "Design Timing Summary" || true
	@echo "---"
	@cat $(PROJ_DIR)/post_impl_utilization.rpt | grep -A 20 "Slice Logic" || true

# ---- Yosys Xilinx resource estimate (no Vivado needed) ----
yosys:
	bash run_yosys_xilinx.sh

# ---- Generate bitstream ----
bitstream: impl
	$(VIVADO) -mode batch -source run_synth.tcl -tclargs bitstream -log $(PROJ_DIR)/bitstream.log -journal $(PROJ_DIR)/bitstream.jou

# ---- Show reports ----
reports:
	@echo "=== Utilization ==="
	@cat $(PROJ_DIR)/post_impl_utilization.rpt 2>/dev/null || cat $(PROJ_DIR)/post_synth_utilization.rpt 2>/dev/null
	@echo ""
	@echo "=== Timing ==="
	@cat $(PROJ_DIR)/post_impl_timing.rpt 2>/dev/null || cat $(PROJ_DIR)/post_synth_timing.rpt 2>/dev/null

# ---- Clean ----
clean:
	rm -rf $(PROJ_DIR)
	rm -rf .Xil
	rm -f *.log *.jou
