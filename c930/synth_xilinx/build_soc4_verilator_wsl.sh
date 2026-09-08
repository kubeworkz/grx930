#!/bin/bash
# build_soc4_verilator_wsl.sh [run [mode]] -- compile (and optionally run)
# the generated Verilator C++ for the 4-core SoC harness with WSL g++.  The
# oss-cad-suite verilator_bin.exe only generates C++; the model itself is a
# Linux ELF, so WSL builds it.  Invoked from c930/.
#   mode: "quad" (default) or "suite" -- passed through to tb_soc4 main().
set -e

DO_RUN="$1"
MODE="$2"
[ -z "$MODE" ] && MODE="quad"

# Convert the Git-Bash cwd to a WSL-visible path (/c/Users/... -> /mnt/c/...).
C930_WSL="$(cygpath -w "$(pwd)" | sed 's|^\([A-Za-z]\):|/mnt/\L\1|' | tr '\' '/')"

wsl.exe -e bash -c "
set -e
cd '$C930_WSL/build/verilator4'
VERI_INC='$C930_WSL/toolchain/oss-cad-suite/share/verilator/include'
g++ -std=c++17 -O1 -pthread -I\"\$VERI_INC\" -I. \
  -c '$C930_WSL/sim/tb_soc4.cc' -o tb_soc4.o
g++ -std=c++17 -O1 -pthread -I\"\$VERI_INC\" -I. \
  -o Vc930_soc4_verilator *.cpp tb_soc4.o \
  \"\$VERI_INC\"/verilated.cpp \"\$VERI_INC\"/verilated_threads.cpp
echo \"[verilator4] build OK\"
if [ \"$DO_RUN\" = \"run\" ]; then
  cd '$C930_WSL'
  ./build/verilator4/Vc930_soc4_verilator '$MODE'
fi
" 2>&1 | tail -20
