#!/bin/bash
# build_soc4_verilator_wsl.sh [run [mode]] -- compile (and optionally run)
# the generated Verilator C++ for the 4-core SoC harness with WSL g++.  The
# oss-cad-suite verilator_bin.exe only generates C++; the model itself is a
# Linux ELF, so WSL builds it.  Invoked from c930/.
#   mode: "quad" (default), "suite" or "pta" -- passed to tb_soc4 main().
#   dir:  the directory verilate-soc4 generated into (default build/verilator4;
#         PTM_C=1 puts it in build/ptm_c/verilator4).
set -e

DO_RUN="$1"
MODE="$2"
GEN_DIR="$3"
[ -z "$MODE" ] && MODE="quad"
[ -z "$GEN_DIR" ] && GEN_DIR="build/verilator4"

# Convert the Git-Bash cwd to a WSL-visible path (/c/Users/... -> /mnt/c/...).
C930_WSL="$(cygpath -w "$(pwd)" | sed 's|^\([A-Za-z]\):|/mnt/\L\1|' | tr '\' '/')"

wsl.exe -e bash -c "
set -e
cd '$C930_WSL/$GEN_DIR'
VERI_INC='$C930_WSL/toolchain/oss-cad-suite/share/verilator/include'
g++ -std=c++17 -O1 -pthread -I\"\$VERI_INC\" -I. \
  -c '$C930_WSL/sim/tb_soc4.cc' -o tb_soc4.o
g++ -std=c++17 -O1 -pthread -I\"\$VERI_INC\" -I. \
  -o Vc930_soc4_verilator *.cpp tb_soc4.o \
  \"\$VERI_INC\"/verilated.cpp \"\$VERI_INC\"/verilated_threads.cpp
echo \"[verilator4] build OK\"
if [ \"$DO_RUN\" = \"run\" ]; then
  cd '$C930_WSL'
  ./$GEN_DIR/Vc930_soc4_verilator '$MODE'
fi
" 2>&1 | tail -20
