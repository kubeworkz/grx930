# Makefile — GRX930 ASIC flow for SKY130
#
# Usage:
#   cd c930/asic
#   make gates       # Estimate gate count (no tools needed)
#   make synth       # Yosys synthesis → SKY130
#   make pnr         # OpenROAD place & route
#   make signoff     # DRC + LVS check
#   make clean       # Remove build artifacts

TOP       = c930_soc_top
BUILD     = build
RTL_DIR   = ../rtl
RV_DIR    = ../rv64imac/RTL

# SKY130 PDK (set in environment)
PDK_ROOT ?= /usr/local/share/pdk/sky130A

.PHONY: all gates synth pnr signoff clean

all: gates

# ============================================================
# Gate count estimation (no tools needed)
# ============================================================
gates:
	@echo "=== GRX930 Gate Count Estimation ==="
	python estimate_gates.py --sky130

gates-json:
	python estimate_gates.py --json > $(BUILD)/gate_estimate.json

# ============================================================
# Yosys synthesis
# ============================================================
$(BUILD):
	mkdir -p $(BUILD)

synth: $(BUILD)
	yosys -s synth_yosys.ys 2>&1 | tee $(BUILD)/synth.log
	@echo "=== Synthesis complete ==="
	@echo "Output: $(BUILD)/c930_soc_synth.v"

# ============================================================
# OpenROAD physical design
# ============================================================
pnr: synth
	PDK_ROOT=$(PDK_ROOT) openroad -exit flow_openroad.tcl 2>&1 | tee $(BUILD)/pnr.log
	@echo "=== Physical design complete ==="
	@echo "Output: $(BUILD)/c930_soc_routed.gds"

# ============================================================
# Signoff (DRC + LVS)
# ============================================================
signoff: pnr
	@echo "=== Running DRC ==="
	magic -noconsole -dnull \
		-c "tech read $(PDK_ROOT)/sky130_fd_sc.tech" \
		-c "gds read $(BUILD)/c930_soc_routed.gds" \
		-c "drc list" \
		-c "quit" 2>&1 | tee $(BUILD)/drc.log
	@echo "=== Running LVS ==="
	netgen -script lvs.tcl 2>&1 | tee $(BUILD)/lvs.log
	@echo "=== Signoff complete ==="

# ============================================================
# Gate-level simulation
# ============================================================
sim: synth
	iverilog -o $(BUILD)/$(TOP)_synth.vvp \
		$(BUILD)/c930_soc_synth.v \
		../tb/tb_c930_soc.sv
	vvp $(BUILD)/$(TOP)_synth.vvp | tee $(BUILD)/sim.log

# ============================================================
# Clean
# ============================================================
clean:
	rm -rf $(BUILD)
