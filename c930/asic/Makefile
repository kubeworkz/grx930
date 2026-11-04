# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# Makefile — GRX930 ASIC flow for SKY130
#
# Usage:
#   cd c930/asic
#   make gates       # Estimate gate count (no tools needed)
#   make pdk         # Fetch the pinned sky130A once, into $(PDK_ROOT)
#   make synth       # LibreLane, stop after Yosys.Synthesis
#   make mapped      # Stop Yosys.Synthesis after dfflibmap, write the netlist
#   make pnr         # LibreLane, full Classic flow (P&R through sign-off checks)
#   make signoff     # Same flow; the DRC/LVS reports are under the run's step dirs
#   make clean       # Remove build artifacts
#
# The flow is LibreLane 3 in the flow image the GF180 arms use, against a
# sky130A fetched by ciel at the commit the engine itself pins -- see
# run_librelane.sh and librelane/config.yaml. The old hand-driven
# synth_yosys.ys / flow_openroad.tcl pair is not called from here any more: it
# reads PDK paths no sky130A layout has and a 2020-era OpenROAD API.

TOP       = c930_soc_top
BUILD     = build
RTL_DIR   = ../rtl
RV_DIR    = ../rv64imac/RTL

# The PDK root run_librelane.sh fetches into and hands to LibreLane with
# --manual-pdk. SKY130_PDK_ROOT, not PDK_ROOT: the flow image exports
# PDK_ROOT=/workspace/gf180mcu for its own GF180 tree.
SKY130_PDK_ROOT ?= /opt/pdk
LIBRELANE_ARGS ?=
# Extra Yosys `chparam`s for the SoC, space-separated NAME=VALUE (for example
# ENABLE_NPU1=0). run_librelane.sh always puts BOOT_INIT_FILE first and these
# after it in the SYNTH_PARAMETERS the flow reads.
SYNTH_PARAMETERS ?=

# LibreLane writes runs/$(RUN_TAG)/...; RUN_TAG is set by run_librelane.sh when
# unset. `make sim` has to be told which run's netlist to elaborate.
RUN_TAG ?=

.PHONY: all gates synth mapped pdk pnr signoff sim clean

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
# LibreLane
# ============================================================
$(BUILD):
	mkdir -p $(BUILD)

# Idempotent: prints "already present" when the tree is there and complete.
pdk:
	SKY130_PDK_ROOT=$(SKY130_PDK_ROOT) ./run_librelane.sh --fetch-pdk

synth: pdk
	SKY130_PDK_ROOT=$(SKY130_PDK_ROOT) SYNTH_PARAMETERS='$(SYNTH_PARAMETERS)' \
		./run_librelane.sh -T Yosys.Synthesis $(LIBRELANE_ARGS)

# Checkpoint: run Yosys.Synthesis only as far as dfflibmap, then write the
# netlist. The flops are sky130 cells but the combinational network is still
# Yosys `$_` gates, so this is for inspecting/counting the state the ABC
# strategy pass starts from - not a P&R-ready standard-cell netlist.
mapped: pdk
	SKY130_PDK_ROOT=$(SKY130_PDK_ROOT) SKY130_SYNTH_STOP_AFTER_DFFLIBMAP=1 \
		SYNTH_PARAMETERS='$(SYNTH_PARAMETERS)' \
		./run_librelane.sh -T Yosys.Synthesis $(LIBRELANE_ARGS)
	@echo "=== Mapped netlist: librelane/runs/<tag>/final/nl/$(TOP).nl.v ==="

# Synthesis, floorplan, placement, CTS, routing, antenna repair, fill and the
# Magic/Netgen sign-off checks all run inside this one invocation.
pnr: pdk
	SKY130_PDK_ROOT=$(SKY130_PDK_ROOT) SYNTH_PARAMETERS='$(SYNTH_PARAMETERS)' \
		./run_librelane.sh $(LIBRELANE_ARGS)

# The Classic flow's sign-off checkers (Magic DRC, Netgen LVS) are steps in the
# same run, so there is nothing extra to drive here; this target exists to say
# where their reports land.
signoff: pnr
	@echo "=== Sign-off reports ==="
	@find librelane/runs -maxdepth 2 -name '*drc*' -o -maxdepth 2 -name '*lvs*' | tail -20

# ============================================================
# Gate-level simulation using a LibreLane-synthesized netlist
# ============================================================
sim:
	@if [ -z "$(RUN_TAG)" ]; then \
		echo "sim needs RUN_TAG=<tag of a completed run> so it can find the netlist" >&2; \
		exit 2; \
	fi
	@netlist=$$(find librelane/runs/$(RUN_TAG) -name '$(TOP).nl.v' | head -1); \
	if [ -z "$$netlist" ]; then echo "no $(TOP).nl.v under librelane/runs/$(RUN_TAG)" >&2; exit 2; fi; \
	iverilog -o $(BUILD)/$(TOP)_synth.vvp -g2012 "$$netlist" ../tb/tb_c930_soc.sv 2>&1 | tee $(BUILD)/sim_build.log; \
	vvp $(BUILD)/$(TOP)_synth.vvp | tee $(BUILD)/sim.log

# ============================================================
# Clean
# ============================================================
clean:
	rm -rf $(BUILD)
