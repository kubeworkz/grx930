# Makefile — GRX930 test chip for wafer.space GF180MCU shuttle
#
# Targets wafer.space 1×1 slot (3.93mm × 5.12mm, 12.92 mm² core)
#
# Usage:
#   cd c930/asic_gf180mcu
#   make gates       # Estimate gate count (no tools needed)
#   make synth       # Yosys synthesis → GF180MCU
#   make pnr         # OpenROAD place & route
#   make signoff     # DRC + LVS check
#   make submit      # Prepare wafer.space submission package
#   make sim         # Chip-level boot test (RTL, iverilog) — fails if the chip does not boot
#   make sim_gate    # The same test on the synthesised netlist (needs the PDK cell models)
#   make fw          # Rebuild the boot firmware image (RISC-V toolchain)
#   make clean       # Remove build artifacts

TOP       = grx930_test_chip
BUILD     = build
RTL_DIR   = ../rtl
RV_DIR    = ../rv64imac/RTL

# GF180MCU PDK (set in environment)
PDK_ROOT ?= /usr/local/share/pdk/gf180mcu

.PHONY: all gates synth pnr signoff submit sim sim_gate fw rom check_rom clean

all: gates

# ============================================================
# Gate count estimation
# ============================================================
gates:
	@echo "=== GRX930 Test Chip Gate Count Estimation ==="
	@echo "Target: wafer.space 1×1 slot (12.92 mm² core)"
	@echo ""
	@echo "Components:"
	@echo "  RV64IMAC core (no AMO):    ~800K gates"
	@echo "  2KB I-cache:               ~30K gates"
	@echo "  2KB D-cache:               ~30K gates"
	@echo "  64KB SRAM (on-chip):       ~200K gates (or SRAM macros)"
	@echo "  UART (16550):              ~5K gates"
	@echo "  Boot ROM:                  ~2K gates"
	@echo "  Bus fabric:                ~10K gates"
	@echo "  GPIO/heartbeat:            ~1K gates"
	@echo "  ─────────────────────────────────"
	@echo "  TOTAL:                     ~155K gates"
	@echo ""
	@echo "Area estimate (GF180MCU 7t 5V, 8k-14k cells/mm2):"
	@echo "  Logic:  11-19 mm² (depends on utilization)"
	@echo "  SRAM:   2.9 mm² (64KB, 128 macros)"
	@echo "  Routing: x1.3 overhead"
	@echo "  TOTAL:  18-29 mm² (needs 1×1 slot, 12.92 mm² core)"

# ============================================================
# Yosys synthesis
# ============================================================
$(BUILD):
	mkdir -p $(BUILD)

synth: $(BUILD)
	yosys -s synth_gf180mcu.ys 2>&1 | tee $(BUILD)/synth.log
	@echo "=== Synthesis complete ==="
	@echo "Output: $(BUILD)/grx930_test_chip_synth.v"

# ============================================================
# OpenROAD physical design
# ============================================================
pnr: synth
	PDK_ROOT=$(PDK_ROOT) openroad -exit flow_openroad_gf180mcu.tcl 2>&1 | tee $(BUILD)/pnr.log
	@echo "=== Physical design complete ==="
	@echo "Output: $(BUILD)/grx930_test_chip_routed.gds"

# ============================================================
# Signoff (DRC + LVS)
# ============================================================
signoff: pnr
	@echo "=== Running DRC ==="
	magic -noconsole -dnull \
		-c "tech read $(PDK_ROOT)/gf180mcu_fd_sc_mcu7t5v0/gf180mcu_fd_sc_mcu7t5v0.tech" \
		-c "gds read $(BUILD)/grx930_test_chip_routed.gds" \
		-c "drc list" \
		-c "quit" 2>&1 | tee $(BUILD)/drc.log
	@echo "=== Running LVS ==="
	netgen -script lvs_gf180mcu.tcl 2>&1 | tee $(BUILD)/lvs.log
	@echo "=== Signoff complete ==="

# ============================================================
# wafer.space submission package
# ============================================================
submit: signoff
	@echo "=== Preparing wafer.space submission ==="
	mkdir -p $(BUILD)/submission
	cp $(BUILD)/grx930_test_chip_routed.gds $(BUILD)/submission/
	cp $(BUILD)/grx930_test_chip_routed.v   $(BUILD)/submission/
	cp $(BUILD)/grx930_test_chip_routed.spef $(BUILD)/submission/
	cp pad_ring.cfg                          $(BUILD)/submission/
	cp $(BUILD)/drc.log                      $(BUILD)/submission/
	cp $(BUILD)/lvs.log                      $(BUILD)/submission/
	@echo ""
	@echo "=== Submission package ready ==="
	@echo "Directory: $(BUILD)/submission/"
	@echo ""
	@echo "Files to submit to wafer.space:"
	@echo "  1. grx930_test_chip_routed.gds  — Final GDS"
	@echo "  2. grx930_test_chip_routed.v    — Gate-level netlist"
	@echo "  3. grx930_test_chip_routed.spef — Parasitics"
	@echo "  4. pad_ring.cfg                  — Pad configuration"
	@echo "  5. drc.log                       — DRC report (must be clean)"
	@echo "  6. lvs.log                       — LVS report (must be clean)"
	@echo ""
	@echo "Submit at: https://wafer.space"
	@echo "Slot: 1×1 (full) — $8,000 standard / $7,000 early bird"
	@echo "Deadline: 16 December 2026 (GDS submission)"

# ============================================================
# Chip-level simulation: does the chip boot?
# ============================================================
# The chip boots from grx930_test_chip_rom (1 KB, base 0x0001_0000 -- the same
# address CORE_RESET_PC holds), so the test needs no preload: it is a real
# power-on boot, and the ROM image is generated from ../sw/test_chip_boot.hex by
# tools/gen_bootrom.py (the `rom` target below).
#
# The testbench (../tb/tb_grx930_test_chip.sv) checks the UART banner
# "GRX930 OK", the SRAM store/load-back pair, and the heartbeat counter. It
# reports "RESULT: PASS" or "RESULT: FAIL" and exits non-zero on failure, which
# this target propagates.
#
# The testbench can still preload the 2 KB SRAM image directly (dut.u_sram.mem)
# as it did before the ROM existed; that image is now irrelevant to booting
# (execution never reaches SRAM 0x0) but it is kept as an extra state: the
# target passes both with and without it because the ROM is the boot source.
#
# The RTL used is the tapeout tree (openlane2_rtl/src, what the OL2 flow reads),
# not ../rv64imac/RTL. The two now carry the same cache index/tag and MMIO-hold
# fixes (see ../../doc/cache_index_tag_all_trees.md), but this test is meant to
# gate exactly the tree the OL2 flow reads, so it names that tree explicitly.
#
# SIM_CLK_FREQ only scales the UART divisor, so a low value is a pure
# simulation-speed choice (the logic is identical to the 50 MHz part).
SIM_IVERILOG  ?= iverilog
SIM_VVP       ?= vvp
SIM_RTL_DIR   ?= openlane2_rtl/src
SIM_CLK_FREQ  ?= 2000000
# Extra vvp plusargs, e.g. SIM_PLUSARGS=+NO_PRELOAD (skip the SRAM preload: the
# chip must still boot from ROM) or SIM_PLUSARGS=+FW=...
SIM_PLUSARGS  ?=
# Extra iverilog defines. The ROM's negative control is
#   make sim SIM_PLUSARGS=+NO_PRELOAD SIM_DEFS=-DROM_DISABLE
# which zeroes the constant ROM, so an empty SRAM has no code anywhere and the
# target must FAIL (proving the PASS above comes from the ROM).
SIM_DEFS      ?=
# c930_bootrom.sv and bootrom_wrapper.sv are not in grx930_test_chip's hierarchy
# (the OL2 run drops them as unused), but iverilog still elaborates an unused
# module's initial block, and that $readmemh would report a missing boot.hex for
# a ROM the chip does not instantiate. Left out of the list for that reason.
SIM_UNUSED_ROM := $(SIM_RTL_DIR)/c930_bootrom.sv $(SIM_RTL_DIR)/bootrom_wrapper.sv
SIM_RTL        := $(filter-out $(SIM_UNUSED_ROM),$(wildcard $(SIM_RTL_DIR)/*.sv))

sim: $(BUILD)
	@echo "=== Boot test: $(TOP) with $(words $(SIM_RTL)) RTL files + ../tb/tb_grx930_test_chip.sv ==="
	@$(SIM_IVERILOG) -g2012 $(SIM_DEFS) -Ptb_grx930_test_chip.CLK_FREQ=$(SIM_CLK_FREQ) \
		-o $(BUILD)/$(TOP)_boot.vvp $(SIM_RTL) ../tb/tb_grx930_test_chip.sv || { \
		echo "FAIL: compile error"; exit 1; }
	@$(SIM_VVP) $(BUILD)/$(TOP)_boot.vvp $(SIM_PLUSARGS) > $(BUILD)/sim.log 2>&1 || { \
		cat $(BUILD)/sim.log; echo "FAIL: simulation aborted (see $(BUILD)/sim.log)"; exit 1; }
	@cat $(BUILD)/sim.log
	@grep -q "RESULT: PASS" $(BUILD)/sim.log || { \
		echo "FAIL: no 'RESULT: PASS' in $(BUILD)/sim.log"; exit 1; }
	@echo "=== Boot test PASSED (log: $(BUILD)/sim.log) ==="

# The same test against the synthesised netlist. Two things are needed beyond
# `make synth`, neither of which this repo provides:
#   * the PDK's Verilog cell models ($(PDK_ROOT)/gf180mcu_fd_sc_mcu7t5v0/*.v, or
#     yosys' techlibs/common/simcells.v for any $ cells left in the netlist):
#     the netlist instantiates gf180mcu_fd_sc_mcu7t5v0__* cells, so without them
#     iverilog cannot elaborate it;
#   * a netlist a simulator can parse. `write_verilog` can emit hierarchical
#     references such as `if (x) \u_cpu.u_dcache.DATA_MEM[3][7] <= ...`, which no
#     Verilog simulator accepts -- the checked-in build from Sept 18 does exactly
#     that from line 193461 -- so `make synth` needs a fully flattened, mapped
#     netlist (memory_map + techmap) before write_verilog for this to work.
# The target reports these instead of dying inside iverilog, and does not depend
# on `synth` so the messages are reachable without a PDK installed.
sim_gate:
	@test -f $(BUILD)/$(TOP)_synth.v || { \
		echo "FAIL: $(BUILD)/$(TOP)_synth.v missing — run 'make synth' first"; \
		echo "      (needs yosys and the GF180MCU liberty; or use 'make sim' for RTL, which needs neither)"; \
		exit 1; }
	@CELLS="$$(ls $(PDK_ROOT)/gf180mcu_fd_sc_mcu7t5v0/*.v 2>/dev/null | head -1)"; \
	if [ -z "$$CELLS" ]; then \
		echo "FAIL: no PDK cell models under $(PDK_ROOT)/gf180mcu_fd_sc_mcu7t5v0/"; \
		echo "      A cell-level netlist needs them (or simcells.v for \$$-cells) to simulate."; \
		echo "      Use 'make sim' for the RTL boot test, which needs no PDK."; \
		exit 1; \
	fi
	@$(SIM_IVERILOG) -g2012 -Ptb_grx930_test_chip.CLK_FREQ=$(SIM_CLK_FREQ) \
		-o $(BUILD)/$(TOP)_synth.vvp $(BUILD)/$(TOP)_synth.v \
		$(PDK_ROOT)/gf180mcu_fd_sc_mcu7t5v0/*.v ../tb/tb_grx930_test_chip.sv || { \
		echo "FAIL: compile error (cell models present but netlist not simulatable)"; exit 1; }
	@$(SIM_VVP) $(BUILD)/$(TOP)_synth.vvp $(SIM_PLUSARGS) > $(BUILD)/sim_gate.log 2>&1 || { \
		cat $(BUILD)/sim_gate.log; echo "FAIL: gate-level simulation aborted"; exit 1; }
	@cat $(BUILD)/sim_gate.log
	@grep -q "RESULT: PASS" $(BUILD)/sim_gate.log || { echo "FAIL: no 'RESULT: PASS' in $(BUILD)/sim_gate.log"; exit 1; }
	@echo "=== Gate-level boot test PASSED ==="

# Rebuild the boot firmware image from ../sw/test_chip_boot.S (needs a RISC-V
# toolchain; the checked-in ../sw/test_chip_boot.hex is the current build) and
# then regenerate the ROM the chip actually boots from. Both steps belong
# together: a hex newer than the generated ROM .sv is the exact failure mode
# that would put stale firmware in silicon.
fw:
	sh ../sw/build_test_chip_fw.sh ../sw/test_chip_boot.hex
	$(MAKE) rom

# Regenerate grx930_test_chip_rom.sv from ../sw/test_chip_boot.hex (python only,
# no toolchain). This is the ROM that ships in the layout; the module is pure
# constant logic, so it synthesises like any other gate (see the file header for
# why it is not a memory with initial contents).
ROM_HEX ?= ../sw/test_chip_boot.hex
ROM_SRC ?= $(SIM_RTL_DIR)/grx930_test_chip_rom.sv
rom:
	@test -f $(ROM_HEX) || { \
		echo "FAIL: $(ROM_HEX) missing -- it is gitignored; 'make fw' builds it (needs a RISC-V toolchain)"; exit 1; }
	python tools/gen_bootrom.py $(ROM_HEX) $(ROM_SRC)
	@$(MAKE) --no-print-directory check_rom

# Drift check: does the checked-in ROM match what the generator would emit from
# the current hex? Catches a hand-edited ROM and a stale one, without needing
# the RISC-V toolchain (`fw` does the update).
check_rom:
	@python tools/gen_bootrom.py $(ROM_HEX) $(BUILD)/rom_expect.sv >/dev/null || { \
		echo "FAIL: generator could not read $(ROM_HEX)"; exit 1; }
	@diff -q $(ROM_SRC) $(BUILD)/rom_expect.sv >/dev/null && \
		echo "=== ROM in sync with $(ROM_HEX) ===" || { \
		echo "FAIL: $(ROM_SRC) differs from a fresh generation -- run 'make rom'"; \
		diff $(ROM_SRC) $(BUILD)/rom_expect.sv | head -20; exit 1; }



# ============================================================
# Clean
# ============================================================
clean:
	rm -rf $(BUILD)
