#!/bin/bash
# build_grx930_verilator.sh -- server-side Verilator build of the GRX930 SoC
# single-core harness (c930_soc_verilator.sv), mirroring the Windows
# Makefile's verilate-soc4 filelist but with the smaller single-core wrapper.
#
#   Usage: ./build_grx930_verilator.sh [clean]
#
# Produces: build/verilator_soc/Vc930_soc_verilator
set -e

# Repo root (script lives in c930/sim)
C930_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$C930_DIR/build/verilator_soc"
VERILATOR="${VERILATOR:-/home/ubuntu/tools/verilator/bin/verilator}"
JOBS="${JOBS:-8}"

cd "$C930_DIR"

if [ "$1" = "clean" ]; then
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Source lists (mirror c930/Makefile)
# ---------------------------------------------------------------------------
CORE_RTL=$(ls ../rv64imac/RTL/*.sv)

NPU_RTL="\
  rtl/c930_fp16_mul.sv \
  rtl/c930_bf16_mul.sv \
  rtl/c930_fp_mul.sv \
  rtl/c930_fp16_acc.sv \
  rtl/c930_cla_sub.sv \
  rtl/c930_cla_comp.sv \
  rtl/c930_fx_acc.sv \
  rtl/c930_tensor_pe.sv \
  rtl/c930_systolic_array.sv \
  rtl/c930_npu_core.sv \
  rtl/c930_npu_csr.sv \
  rtl/c930_npu_dma.sv \
  rtl/c930_npu_top.sv"

SOC_FULL_RTL="$NPU_RTL \
  rtl/c930_ddr.sv \
  rtl/c930_mmio_bridge.sv \
  rtl/c930_soc_top.sv \
  rtl/c930_l2.sv \
  rtl/c930_axi_crossbar.sv \
  rtl/c930_axi_dma_arb.sv \
  rtl/c930_axi_cache_adapter.sv \
  rtl/c930_bootrom.sv \
  rtl/c930_uart.sv \
  rtl/c930_aplic.sv \
  rtl/c930_mmio_arb.sv"

# ---------------------------------------------------------------------------
# Verilate
# ---------------------------------------------------------------------------
echo "[grx930] Verilating c930_soc_verilator ..."
"$VERILATOR" --cc --exe --build \
  -Wall -Wno-DECLFILENAME -Wno-fatal \
  -Wno-EOFNEWLINE -Wno-REDEFMACRO -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-WIDTH -Wno-CASEX \
  --threads 1 --Mdir "$BUILD_DIR" \
  -I../rv64imac/RTL \
  --top-module c930_soc_verilator \
  sim/c930_soc_verilator.sv \
  sim/tb_uart_echo.cc \
  $CORE_RTL $SOC_FULL_RTL \
  -CFLAGS "-O1 -std=c++17" \
  -LDFLAGS "-pthread"

echo "[grx930] Build OK: $BUILD_DIR/Vc930_soc_verilator"
ls -la "$BUILD_DIR/Vc930_soc_verilator"