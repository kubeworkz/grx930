#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# build.sh -- Verilate c930_npu_top (npu_web_top.sv) once, then compile the
# generated model natively (g++) and as WebAssembly (em++): the transcript
# test for both, and a browser module exporting npu_web.h's calls.
# Usage: c930/sim/web/build.sh OUT_DIR       (needs verilator, g++, em++)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
C930=$(cd "$HERE/../.." && pwd)
OUT=$1; mkdir -p "$OUT/web"
VROOT=$(verilator --getenv VERILATOR_ROOT)
verilator --version

# The NPU's sources, as the Makefile's NPU_RTL lists them.
NPU_RTL="rtl/c930_fp16_mul.sv rtl/c930_bf16_mul.sv rtl/c930_fp_mul.sv rtl/c930_fp16_acc.sv
  rtl/c930_cla_sub.sv rtl/c930_cla_comp.sv rtl/c930_fx_acc.sv rtl/c930_tensor_pe.sv
  rtl/c930_systolic_array.sv rtl/c930_npu_act.sv rtl/c930_npu_core.sv rtl/c930_npu_csr.sv
  rtl/c930_npu_dma.sv rtl/c930_npu_top.sv"

echo "== verilate"
( cd "$C930" && verilator --cc --no-timing -O3 -Wno-fatal -Wno-lint -Wno-style \
    --top-module npu_web_top -Irtl/pta --Mdir "$OUT/obj" $NPU_RTL "$HERE/npu_web_top.sv" )

SRCS="$(ls "$OUT"/obj/*.cpp) $VROOT/include/verilated.cpp $VROOT/include/verilated_dpi.cpp $VROOT/include/verilated_threads.cpp"
INC="-I$OUT/obj -I$VROOT/include -I$VROOT/include/vltstd -I$HERE"

echo "== native"
g++ -std=c++17 -O2 $INC -o "$OUT/npu_web_test" $SRCS "$HERE/npu_web.cc" "$HERE/npu_web_test.cc" -lpthread

echo "== WebAssembly"
em++ --version | head -1
# Verilator's runtime knows each CPU's spin-wait hint but not WebAssembly's;
# the model is single-threaded and never spins, so the no-op it offers is right.
EMFLAGS="-std=c++17 -O2 -sALLOW_MEMORY_GROWTH=1 -DVL_IGNORE_UNKNOWN_ARCH"
em++ $EMFLAGS $INC -sEXIT_RUNTIME=1 -o "$OUT/npu_web_test.js" $SRCS "$HERE/npu_web.cc" "$HERE/npu_web_test.cc"
FUNCS='["_npu_web_reset","_npu_web_csr_write","_npu_web_csr_read","_npu_web_mem_write32","_npu_web_mem_read32","_npu_web_run","_npu_web_step","_npu_web_cycles","_npu_web_pins"]'
em++ $EMFLAGS -O3 $INC -sMODULARIZE=1 -sEXPORT_NAME=NpuWeb -sENVIRONMENT=web,worker,node \
  -sEXPORTED_FUNCTIONS="$FUNCS" -sEXPORTED_RUNTIME_METHODS=ccall,cwrap \
  -o "$OUT/web/npu_web.js" $SRCS "$HERE/npu_web.cc"

echo "== sizes"
( cd "$OUT/web" && for f in *; do printf '%-16s %9d bytes   gzip %9d\n' "$f" "$(wc -c < "$f")" "$(gzip -9c "$f" | wc -c)"; done )
