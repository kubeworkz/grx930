#!/bin/bash
# ---------------------------------------------------------------------------
# build_core_objs.sh -- compile and link the core bench, inside WSL.
#
# Split out of build_core_verilator_wsl.sh because it used to be a here-string
# nested in a double-quoted `wsl.exe -e bash -c "..."`, where every quote and
# dollar needed escaping and a parallel loop was not worth writing.  This runs
# as a file instead, so it is ordinary shell.
#
# Verilator generates ~68 C++ files for this model and the old link line handed
# all of them to one g++, serially: about fifteen minutes on this host, and the
# same fifteen for a one-line change to the bench.  One object per file, four at
# a time, skipping sources that have not moved, makes a bench-only change a
# single compile.  Four rather than nproc: this VM has 5.9 GB and cc1plus on the
# generated model is not small (see the WSL service timeout in c930/doc).
#
#   bash sim/build_core_objs.sh <out_dir> <sim_dir> <veri_inc> [cdefs ...]
# ---------------------------------------------------------------------------
set -e

OUT="$1"; SIM="$2"; VERI_INC="$3"; shift 3
CDEFS="$*"

cd "$OUT"

CXXFLAGS="-std=c++17 -O2 -pthread -I$VERI_INC -I."

# The bench and the C reference model.  Always recompiled: they are one file each
# and the defines can change without the file doing so.
# shellcheck disable=SC2086
g++ $CXXFLAGS $CDEFS -I"$SIM" -c "$SIM/tb_core_verilator.cc" -o tb_core_verilator.o
# shellcheck disable=SC2086
gcc -O2 $CDEFS -I"$SIM" -c "$SIM/pta_tile_model.c" -o pta_tile_model.o

# The generated model plus Verilator's runtime, in parallel, incrementally.
# The object is named after the source's basename, so *.cpp.o collects them.
compile_one() {
  src="$1"
  obj="$(basename "$src").o"
  if [ -f "$obj" ] && [ "$obj" -nt "$src" ]; then
    return 0
  fi
  g++ $CXXFLAGS -c "$src" -o "$obj"
}
export -f compile_one
export CXXFLAGS

printf '%s\n' *.cpp "$VERI_INC/verilated.cpp" "$VERI_INC/verilated_threads.cpp" \
  | xargs -P 4 -I{} bash -c 'compile_one "$1"' _ {}

# shellcheck disable=SC2086
g++ $CXXFLAGS -o tb_core_verilator *.cpp.o tb_core_verilator.o pta_tile_model.o
echo '[verilator_core] build OK'
