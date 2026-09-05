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

SOC_FULL_RTL := $(SOC_RTL) \
  rtl/c930_axi_crossbar.sv \
  rtl/c930_axi_dma_arb.sv \
  rtl/c930_axi_cache_adapter.sv \
  rtl/c930_bootrom.sv \
  rtl/c930_uart.sv

OUT_NPU    := $(BUILD_DIR)/tb_c930_npu.vvp
OUT_SOC    := $(BUILD_DIR)/tb_c930_soc.vvp
OUT_SOC_FULL := $(BUILD_DIR)/tb_c930_soc_full.vvp

.PHONY: all sw soc soc_full npu hazard synth synth-fit wave clean bringup

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

# Byte-addressed hex for DDR $readmemh (converts word hex to little-endian bytes)
DDR_BYTES_HEX := sw/npu_ddr_bytes.hex
$(DDR_BYTES_HEX): $(SW_HEX)
	$(PYTHON) -c "words=[l.strip() for l in open('$<') if l.strip()]; f=open('$@','w'); [f.write(f'{(int(w,16)>>(i*8))&0xff:02x}\n') for w in words for i in range(4)]; f.close(); print(f'Converted {len(words)} words to {len(words)*4} bytes')"

sw: $(SW_HEX) $(DDR_BYTES_HEX)

# ---------------------------------------------------------------------------
# Board bring-up firmware (Arty A7-100T + DDR3L)
# ---------------------------------------------------------------------------
BRINGUP_ELF := sw/npu_bringup.elf
BRINGUP_HEX := sw/npu_bringup.hex

$(BRINGUP_ELF): sw/start_bringup.S sw/npu_bringup.c sw/link_bringup.ld
	$(GCC) -march=rv64ima -mabi=lp64 -Os -ffreestanding -nostdlib \
	  -fno-builtin -T sw/link_bringup.ld -Wl,--build-id=none \
	  -o $@ sw/start_bringup.S sw/npu_bringup.c

$(BRINGUP_HEX): $(BRINGUP_ELF) sw/bin2hex.py
	$(OBJCOPY) -O binary $< sw/npu_bringup.bin
	$(PYTHON) sw/bin2hex.py sw/npu_bringup.bin $(BRINGUP_HEX)

bringup: $(BRINGUP_HEX)
	@echo "Firmware built: $(BRINGUP_HEX)"
	@echo "Flash via JTAG: openocd -f openocd.cfg -c 'init; halt; load_image $(BRINGUP_HEX) 0 bin; resume; exit'"
	@echo "Read results:   openocd -c 'init; halt; md32 0x9490 1; md32 0x9500 1; exit'"
	@echo "Expected: PHASE=0xFF RESULT=0xBEEF0002 (all tests passed)"

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

$(OUT_SOC_FULL): $(SOC_FULL_RTL) $(CORE_RTL) tb/tb_c930_soc_full.sv
	$(IVERILOG) $(GFLAGS) -o $@ $(CORE_RTL) $(SOC_FULL_RTL) tb/tb_c930_soc_full.sv

soc_full: $(OUT_SOC_FULL)
	$(VVP) $(OUT_SOC_FULL)

wave: soc
	@echo "Waveform written to $(BUILD_DIR)/tb_c930_soc.vcd (open with GTKWave)"

# ---------------------------------------------------------------------------
# Vivado synthesis + implementation (Xilinx Artix-7 / Arty A7-200T)
# ---------------------------------------------------------------------------
vivado_synth:
	@mkdir -p build/vivado
	@bash synth_xilinx/create_and_synth.sh

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

# GRXCP integration reference test (boots firmware, reports NPU status)
VERIL_GRXCP_TB := sim/tb_grxcp_ref.cc
VERIL_GRXCP_OUT := $(BUILD_DIR)/grxcp_ref

verilate-grxcp: $(SW_HEX)
	@mkdir -p $(VERIL_GRXCP_OUT)
	$(VERILATOR) $(VERILATOR_FLAGS) \
	  --Mdir $(VERIL_GRXCP_OUT) \
	  $(VERIL_TOP) $(VERIL_GRXCP_TB) $(CORE_RTL) $(VERIL_RTL)

# Verilator vs Icarus timing comparison
VERIL_TIMING_TB := sim/tb_timing_compare.cc
VERIL_TIMING_OUT := $(BUILD_DIR)/timing_compare

verilate-timing: $(SW_HEX)
	@mkdir -p $(VERIL_TIMING_OUT)
	$(VERILATOR) $(VERILATOR_FLAGS) \
	  --Mdir $(VERIL_TIMING_OUT) \
	  $(VERIL_TOP) $(VERIL_TIMING_TB) $(CORE_RTL) $(VERIL_RTL)

# ---------------------------------------------------------------------------
# NPU tiling library test
# ---------------------------------------------------------------------------
TILE_SW_ELF := sw/npu_tile_test.elf
TILE_SW_BIN := sw/npu_tile_test.bin
TILE_SW_HEX := sw/npu_tile_prog.hex
OUT_TILE    := $(BUILD_DIR)/tb_npu_tile.vvp

$(TILE_SW_ELF): sw/start.S sw/npu_tile_test.c sw/npu_tile.c sw/npu_tile.h sw/link_tile.ld
	$(GCC) -march=rv64ima -mabi=lp64 -Os -ffreestanding -nostdlib \
	  -fno-builtin -T sw/link_tile.ld -Wl,--build-id=none \
	  -o $@ sw/start.S sw/npu_tile_test.c sw/npu_tile.c

$(TILE_SW_BIN): $(TILE_SW_ELF)
	$(OBJCOPY) -O binary $< $@

$(TILE_SW_HEX): $(TILE_SW_BIN) sw/bin2hex.py
	$(PYTHON) sw/bin2hex.py $(TILE_SW_BIN) $(TILE_SW_HEX)

tile_sw: $(TILE_SW_HEX)

$(OUT_TILE): $(SOC_RTL) $(CORE_RTL) tb/tb_npu_tile.sv $(TILE_SW_HEX)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(GFLAGS) -o $@ $(CORE_RTL) $(SOC_RTL) tb/tb_npu_tile.sv

tile_test: $(OUT_TILE)
	$(VVP) $(OUT_TILE)

# ---------------------------------------------------------------------------
# Standalone NPU DPI shim for grxcp (pure C, no Verilator dependency)
# ---------------------------------------------------------------------------
HOST_CC     ?= gcc
NPU_DPI_OBJ := $(BUILD_DIR)/npu_dpi_shim.o
NPU_DPI_LIB := $(BUILD_DIR)/libnpu_dpi_shim.a

$(NPU_DPI_OBJ): sim/npu_dpi_shim.c sim/npu_dpi_shim.h
	@mkdir -p $(BUILD_DIR)
	$(HOST_CC) -c -Wall -Wextra -fPIC -o $@ sim/npu_dpi_shim.c

$(NPU_DPI_LIB): $(NPU_DPI_OBJ)
	rcs $@ $<

npu-shim: $(NPU_DPI_LIB)
	@echo "Built $(NPU_DPI_LIB)"
	@echo "Link with: -L$(BUILD_DIR) -lnpu_dpi_shim"
	@echo "Include:   sim/npu_dpi_shim.h"

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(SW_ELF) $(SW_BIN) $(SW_HEX)
	rm -f $(TILE_SW_ELF) $(TILE_SW_BIN) $(TILE_SW_HEX)
