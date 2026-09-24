#!/bin/bash
# ---------------------------------------------------------------------------
# build_core_verilator_wsl.sh -- generate the core bench's C++ on Windows and
# build it with WSL g++, the way synth_xilinx/build_soc4_verilator_wsl.sh does
# for the four-core SoC.  sim/tb_core_verilator.cc documents the verilator
# command but not that the vendored verilator_bin.exe only *generates*: the
# model is a Linux ELF, so WSL compiles it.
#
#   bash sim/build_core_verilator_wsl.sh [run [args ...]]
#   bash sim/build_core_verilator_wsl.sh PTM_C=1 run --pta engine
#
# Invoked from c930/.  The binary lands in build/verilator_core (or
# build/ptm_c/verilator_core) as tb_core_verilator.
# ---------------------------------------------------------------------------
set -e

PTM_C=0
if [ "${1:-}" = "PTM_C=1" ]; then PTM_C=1; shift; fi
DO_RUN="${1:-}"
[ "$DO_RUN" = "run" ] && shift || true

C930="$(cd "$(dirname "$0")/.." && pwd)"
cd "$C930"

if [ "$PTM_C" = 1 ]; then
  OUT=build/ptm_c/verilator_core
  ARRAY="rtl/pta/c930_fp32_add.sv rtl/pta/c930_ptm_c.sv rtl/pta/c930_pta_cal.sv"
  DEFS="+define+PTM_C"
  CDEFS="-DPTM_C"
else
  OUT=build/verilator_core
  ARRAY="rtl/c930_tensor_pe.sv rtl/c930_systolic_array.sv"
  DEFS=""
  CDEFS=""
fi

# The Makefile's NPU_RTL less the CSR, DMA and top, which the bench drives the
# core without.
CORE_RTL="rtl/c930_fp16_mul.sv rtl/c930_bf16_mul.sv rtl/c930_fp_mul.sv \
rtl/c930_fp16_acc.sv rtl/c930_cla_sub.sv rtl/c930_cla_comp.sv rtl/c930_fx_acc.sv \
rtl/c930_npu_act.sv rtl/c930_npu_core.sv"

mkdir -p "$OUT"
# The vendored binary looks for its own share/ tree unless told where it is.
VERILATOR_ROOT=toolchain/oss-cad-suite/share/verilator \
toolchain/oss-cad-suite/bin/verilator_bin.exe \
  --cc --exe -O3 --top-module c930_npu_core -GMAX_N=12 \
  -Wall -Wno-DECLFILENAME -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  $DEFS --Mdir "$OUT" $CORE_RTL $ARRAY sim/tb_core_verilator.cc

C930_WSL="$(cygpath -w "$(pwd)" 2>/dev/null | sed 's|^\([A-Za-z]\):|/mnt/\L\1|' | tr '\\' '/')"
[ -z "$C930_WSL" ] && C930_WSL="$(pwd)"

wsl.exe -e bash -c "
set -e
cd '$C930_WSL/$OUT'
VERI_INC='$C930_WSL/toolchain/oss-cad-suite/share/verilator/include'
g++ -std=c++17 -O2 -pthread $CDEFS -I\"\$VERI_INC\" -I. -I'$C930_WSL/sim' \
  -c '$C930_WSL/sim/tb_core_verilator.cc' -o tb_core_verilator.o
gcc -O2 $CDEFS -I'$C930_WSL/sim' -c '$C930_WSL/sim/pta_tile_model.c' -o pta_tile_model.o
g++ -std=c++17 -O2 -pthread -I\"\$VERI_INC\" -I. \
  -o tb_core_verilator *.cpp tb_core_verilator.o pta_tile_model.o \
  \"\$VERI_INC\"/verilated.cpp \"\$VERI_INC\"/verilated_threads.cpp
echo '[verilator_core] build OK'
"

if [ "$DO_RUN" = "run" ] || [ -n "${1:-}" ]; then
  wsl.exe -e bash -c "cd '$C930_WSL' && ./$OUT/tb_core_verilator $*"
fi
