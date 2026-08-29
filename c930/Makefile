# C930 NPU + SoC build & simulation with Icarus Verilog.
#
# Targets:
#   make            build the C driver image and run the full SoC test (default)
#   make sw         compile sw/npu_test.c -> sw/npu_prog.hex
#   make soc        build + run the end-to-end SoC testbench (tb_c930_soc)
#   make npu        build + run the standalone NPU testbench (tb_c930_npu)
#   make hazard     build + run the hazard-unit flush/stall unit test
#   make wave       simulate the SoC and print the waveform location
#   make synth      ECP5 synthesis resource/latch report (oss-cad-suite; real design)
#   make synth-fit   ECP5 synthesis + P&R Fmax (cache-shrunk fit test)
#   make clean      remove build artifacts and the VCD dump

IVERILOG ?= iverilog
VVP      ?= vvp
GFLAGS   ?= -g2012 -Wall
PYTHON   ?= python

BUILD_DIR := build

# ---------------------------------------------------------------------------
# RISC-V GNU toolchain (bare-metal, downloaded under c930/toolchain/)
# ---------------------------------------------------------------------------
TC      := toolchain/xpack-riscv-none-elf-gcc-15.2.0-1/bin
GCC     := $(TC)/riscv-none-elf-gcc.exe
OBJCOPY := $(TC)/riscv-none-elf-objcopy.exe

SW_ELF := sw/npu_test.elf
SW_BIN := sw/npu_test.bin
SW_HEX := sw/npu_prog.hex

# ---------------------------------------------------------------------------
# Source lists
# ---------------------------------------------------------------------------
CORE_RTL := $(wildcard ../rv64imac/RTL/*.sv)

NPU_RTL := \
  rtl/c930_fp16_mul.sv \
  rtl/c930_bf16_mul.sv \
  rtl/c930_fp16_acc.sv \
  rtl/c930_cla_sub.sv \
  rtl/c930_cla_comp.sv \
  rtl/c930_fx_acc.sv \
  rtl/c930_tensor_pe.sv \
  rtl/c930_systolic_array.sv \
  rtl/c930_npu_core.sv \
  rtl/c930_npu_csr.sv \
  rtl/c930_npu_dma.sv \
  rtl/c930_npu_top.sv

SOC_RTL := $(NPU_RTL) \
  rtl/c930_ddr.sv \
  rtl/c930_mmio_bridge.sv \
  rtl/c930_soc_top.sv

OUT_NPU := $(BUILD_DIR)/tb_c930_npu.vvp
OUT_SOC := $(BUILD_DIR)/tb_c930_soc.vvp

.PHONY: all sw soc npu hazard synth synth-fit wave clean

all: sw soc

# ---------------------------------------------------------------------------
# C driver image
# ---------------------------------------------------------------------------
$(SW_ELF): sw/start.S sw/npu_test.c sw/link.ld
	$(GCC) -march=rv64ima -mabi=lp64 -Os -ffreestanding -nostdlib \
	  -fno-builtin -T sw/link.ld -Wl,--build-id=none \
	  -o $@ sw/start.S sw/npu_test.c

$(SW_BIN): $(SW_ELF)
	$(OBJCOPY) -O binary $< $@

$(SW_HEX): $(SW_BIN) sw/bin2hex.py
	$(PYTHON) sw/bin2hex.py $(SW_BIN) $(SW_HEX)

sw: $(SW_HEX)

# ---------------------------------------------------------------------------
# Standalone NPU testbench
# ---------------------------------------------------------------------------
$(OUT_NPU): $(NPU_RTL) tb/tb_c930_npu.sv
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(GFLAGS) -o $@ $(NPU_RTL) tb/tb_c930_npu.sv

npu: $(OUT_NPU)
	$(VVP) $(OUT_NPU)

# ---------------------------------------------------------------------------
# Hazard-unit unit test (flush deferral under stalls)
# ---------------------------------------------------------------------------
OUT_HAZARD := $(BUILD_DIR)/tb_hazard_csrflush.vvp

$(OUT_HAZARD): $(CORE_RTL) tb/tb_hazard_csrflush.sv
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(GFLAGS) -o $@ $(CORE_RTL) tb/tb_hazard_csrflush.sv

hazard: $(OUT_HAZARD)
	$(VVP) $(OUT_HAZARD)

# ---------------------------------------------------------------------------
# Full SoC testbench (core + NPU + DDR + MMIO)
# ---------------------------------------------------------------------------
$(OUT_SOC): $(SOC_RTL) $(CORE_RTL) tb/tb_c930_soc.sv $(SW_HEX)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(GFLAGS) -o $@ $(CORE_RTL) $(SOC_RTL) tb/tb_c930_soc.sv

soc: $(OUT_SOC)
	$(VVP) $(OUT_SOC)

wave: soc
	@echo "Waveform written to $(BUILD_DIR)/tb_c930_soc.vcd (open with GTKWave)"

# ---------------------------------------------------------------------------
# ECP5 synthesis resource/latch report for the REAL design (vendored
# oss-cad-suite). The full netlist is ~424K LUTs (dcache byte-strobe write
# muxes demote to fabric), far over the ECP5-85F fabric, so this target is
# yosys-only -- see synth-fit for a P&R/Fmax estimate.
# ---------------------------------------------------------------------------
synth:
	@bash synth/run_synth.sh

# Cache-shrunk fit test (chparam INDEX_WIDTH 7->4) + nextpnr P&R for an Fmax
# estimate of the logic fabric (core + NPU + bridge + DMA).
synth-fit:
	@bash synth/run_synth.sh fit

# ---------------------------------------------------------------------------
# Verilator cycle-accurate RTL simulation
# ---------------------------------------------------------------------------
OSS_DIR ?= toolchain/oss-cad-suite
VERILATOR := $(OSS_DIR)/bin/verilator_bin.exe
VERILATOR_FLAGS := --cc --exe -Wall -Wno-DECLFILENAME -Wno-fatal \
  -Wno-EOFNEWLINE -Wno-REDEFMACRO --threads 0 -I../rv64imac/RTL --top-module c930_soc_verilator
# Use sim/c930_ddr_verilator.sv (flat 1D byte array) instead of
# synth/c930_ddr_stub.sv (2D banked array that won't init in Verilator).
VERIL_RTL := $(NPU_RTL) \
  rtl/c930_mmio_bridge.sv \
  rtl/c930_soc_top.sv \
  sim/c930_ddr_verilator.sv
VERIL_TB := sim/tb_verilator.cc
VERIL_TOP := sim/c930_soc_verilator.sv
VERIL_OUT := $(BUILD_DIR)/verilator

verilate: $(SW_HEX)
	@mkdir -p $(VERIL_OUT)
	$(VERILATOR) $(VERILATOR_FLAGS) \
	  --Mdir $(VERIL_OUT) \
	  $(VERIL_TOP) $(VERIL_TB) $(CORE_RTL) $(VERIL_RTL)

verilate-run: verilate
	$(VERIL_OUT)/Vc930_soc_verilator

# Standalone NPU DPI wrapper for grxcp backend testing
NPU_DPI_RTL := $(NPU_RTL) rtl/c930_npu_top.sv
NPU_DPI_SRC := sim/c930_npu_dpi.sv sim/npu_dpi.cc sim/npu_dpi_test.cc
NPU_DPI_OUT := $(BUILD_DIR)/npu_dpi

verilate-npu: $(SW_HEX)
	@mkdir -p $(NPU_DPI_OUT)
	$(VERILATOR) $(VERILATOR_FLAGS) \
	  --top-module c930_npu_dpi \
	  --Mdir $(NPU_DPI_OUT) \
	  $(NPU_DPI_SRC) $(NPU_DPI_RTL)

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(SW_ELF) $(SW_BIN) $(SW_HEX)
