#!/bin/bash
set -e
cd /mnt/c/Users/kubew/grx930/c930/build/verilator
VERI_INC=/mnt/c/Users/kubew/grx930/c930/toolchain/oss-cad-suite/share/verilator/include

echo "Compiling generated C++..."
g++ -std=c++17 -O0 -g -pthread \
  -I"$VERI_INC" -I. \
  -c /mnt/c/Users/kubew/grx930/c930/sim/tb_verilator.cc -o tb_verilator.o

echo "Linking..."
g++ -std=c++17 -O0 -g -pthread \
  -I"$VERI_INC" -I. \
  -o Vc930_soc_verilator \
  *.cpp tb_verilator.o \
  "$VERI_INC"/verilated.cpp \
  "$VERI_INC"/verilated_threads.cpp

echo "Build OK: $(ls -la Vc930_soc_verilator)"
