#!/bin/bash
# Build the C930 SoC Verilator model.
# Requires: verilator_bin.exe (oss-cad-suite) + g++ (WSL or MSYS2)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OSS="$HERE/toolchain/oss-cad-suite"
VLINC="$OSS/share/verilator/include"
BUILD="$HERE/build/verilator"

# RTL sources (same list as Makefile)
CORE_RTL=$(ls "$HERE"/../rv64imac/RTL/*.sv 2>/dev/null)
NPU_RTL=$(ls "$HERE"/rtl/*.sv 2>/dev/null)
SOC_STUB="$HERE/synth/c930_ddr_stub.sv"

# Step 1: Verilate (C++ generation)
echo "=== Verilating ==="
rm -rf "$BUILD"
mkdir -p "$BUILD"

VERILATOR_ROOT="$OSS/share/verilator" "$OSS/bin/verilator_bin.exe" \
  --cc --exe -Wno-fatal \
  -Wno-DECLFILENAME -Wno-EOFNEWLINE -Wno-UNUSED -Wno-WIDTH \
  -Wno-UNOPTFLAT -Wno-UNDRIVEN -Wno-STMTDLY -Wno-LATCH \
  -Wno-COMBDLY -Wno-BLKANDNBLK -Wno-MODDUP -Wno-PINMISSING \
  -Wno-MULTIDRIVEN -Wno-CASEX -Wno-CASEINCOMPLETE \
  -I"$HERE"/../rv64imac/RTL \
  --top-module c930_soc_verilator \
  --Mdir "$BUILD" \
  "$HERE/sim/c930_soc_verilator.sv" \
  "$HERE/sim/tb_verilator.cc" \
  $CORE_RTL $NPU_RTL "$SOC_STUB"

# Step 2: Compile with g++
echo "=== Compiling ==="
cd "$BUILD"

# Fix the generated Makefile to use Linux paths
sed -i "s|C:/Users/kubew/grx930/c930/toolchain/oss-cad-suite/share/verilator|$VLINC|g" Vc930_soc_verilator.mk 2>/dev/null || true

# Direct g++ compilation (bypass the broken Makefile)
GXX="${GXX:-g++}"
VERILATOR_INCLUDE="$VLINC"

echo "Compiling verilated C++..."
$GXX -std=c++17 -O2 \
  -I"$VERILATOR_INCLUDE" \
  -I"$VERILATOR_INCLUDE/vltstd" \
  -DVERILATOR=1 -DVM_COVERAGE=0 -DVM_SC=0 -DVM_TIMING=0 \
  -DVM_TRACE=0 -DVM_TRACE_FST=0 -DVM_TRACE_VCD=0 -DVM_TRACE_SAIF=0 -DVM_VPI=0 \
  -faligned-new -fcf-protection=none \
  -Wno-bool-operation -Wno-int-in-bool-context -Wno-shadow \
  -Wno-sign-compare -Wno-subobject-linkage -Wno-tautological-compare \
  -Wno-uninitialized -Wno-unused-but-set-parameter -Wno-unused-but-set-variable \
  -Wno-unused-parameter -Wno-unused-variable \
  -c Vc930_soc_verilator.cpp -o Vc930_soc_verilator.o

$GXX -std=c++17 -O2 \
  -I"$VERILATOR_INCLUDE" \
  -I"$VERILATOR_INCLUDE/vltstd" \
  -DVERILATOR=1 -DVM_COVERAGE=0 -DVM_SC=0 -DVM_TIMING=0 \
  -DVM_TRACE=0 -DVM_TRACE_FST=0 -DVM_TRACE_VCD=0 -DVM_TRACE_SAIF=0 -DVM_VPI=0 \
  -faligned-new -fcf-protection=none \
  -Wno-bool-operation -Wno-int-in-bool-context -Wno-shadow \
  -Wno-sign-compare -Wno-subobject-linkage -Wno-tautological-compare \
  -Wno-uninitialized -Wno-unused-but-set-parameter -Wno-unused-but-set-variable \
  -Wno-unused-parameter -Wno-unused-variable \
  -c "$HERE/sim/tb_verilator.cc" -o tb_verilator.o

echo "Linking..."
$GXX -o Vc930_soc_verilator \
  Vc930_soc_verilator.o __ALL.o tb_verilator.o \
  -lpthread

echo "=== Build complete: $BUILD/Vc930_soc_verilator ==="
