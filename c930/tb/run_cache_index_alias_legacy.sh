#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# run_cache_index_alias_legacy.sh <tree-dir> <caches|atomic|fpga> [out-dir]
#
# Compiles and runs the generation-appropriate cache index/tag regressions
# against the older rv64imac cache trees (the ones without the MMIO /
# cache-invalidation ports):
#
#   caches : rv64imac/RTL/caches                (dcache + icache, no AMO ports)
#   atomic : rv64imac/RTL/caches/atomic_dcaches (dcache with AMO ports only)
#   fpga   : rv64imac/FPGA/src                  (dcache with AMO ports + icache)
#
# Checks, in order:
#   1. tb_dcache_index_alias_legacy  RESULT: PASS   (alias at INDEX_WIDTH=4)
#   2. tb_icache_index_alias_legacy  RESULT: PASS   (skipped for "atomic")
#   3. tag-width guard A: derived default is silent
#   4. tag-width guard B: an explicit stale TAG_WIDTH=52 fires $error for
#      every controller present (1 for "atomic", 2 otherwise)
#
# Two simulators:
#   SIM=iverilog  (default) -- fast, but Icarus rejects the legacy memories:
#       they index packed multi-dimensional arrays with variable indices
#       ("All but the final index in a chain of indices must be a constant"),
#       which fails identically on the pre-fix sources; those files were never
#       Icarus-compilable.  Only the guard checks can run here.
#   SIM=verilator -- Verilator 5 (repo toolchain, oss-cad-suite) handles the
#       packed arrays, so the alias regressions run for real.  The Windows
#       verilator_bin generates C++; the build+run happen in WSL with g++:
#        -DVERILATOR   host for wsl.exe       (default: wsl.exe)
#        -DVERILATOR_BIN / -DVLROOT           (defaults under
#                                              <repo>/c930/toolchain/oss-cad-suite)
#
# Exit status 0 only if every check holds; a missing RESULT (crash, hang,
# compile failure) counts as a failure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=${1:?usage: $0 <tree-dir> <caches|atomic|fpga> [out-dir]}
CASE=${2:?usage: $0 <tree-dir> <caches|atomic|fpga> [out-dir]}
OUT=${3:-$HERE/../asic_gf180mcu/build/cache_alias_sim}
mkdir -p "$OUT"
fail=0
SIM=${SIM:-iverilog}

SUITE=${SUITE:-$HERE/../toolchain/oss-cad-suite}
VERILATOR_BIN=${VERILATOR_BIN:-$SUITE/bin/verilator_bin.exe}
VLROOT=${VLROOT:-$SUITE/share/verilator}

to_wsl() {  # C:\dir -> /mnt/c/dir
  cygpath -w "$1" 2>/dev/null | sed -e 's#\\#/#g' -e 's#^\([A-Za-z]\):#/mnt/\L\1#'
}

case "$CASE" in
  caches) dcache_srcs="riscv_core_dcache_top.sv riscv_core_dcache_controller.sv riscv_core_dcache_memory.sv"
          dcache_defs=""
          want_icache=1; guard_defs="" ;;
  atomic) dcache_srcs="riscv_core_dcache_top.sv riscv_core_dcache_controller.sv riscv_core_dcache_memory.sv riscv_core_amo_alu.sv riscv_core_mux_2to1.sv"
          dcache_defs="-DAMO_GEN"
          want_icache=0; guard_defs="-DNO_ICACHE" ;;
  fpga)   dcache_srcs="riscv_core_dcache_top.sv riscv_core_dcache_controller.sv riscv_core_dcache_memory.sv riscv_core_amo_alu.sv riscv_core_mux_2to1.sv"
          dcache_defs="-DAMO_GEN"
          want_icache=1; guard_defs="" ;;
  *) echo "unknown case '$CASE' (use caches|atomic|fpga)"; exit 2 ;;
esac
icache_srcs="riscv_core_icache_top.sv riscv_core_icache_controller.sv riscv_core_icache_memory.sv"

echo "TREE $TREE  CASE $CASE  SIM $SIM"

require() {  # require <files...>: every file must be in TREE
  for f in "$@"; do
    [ -f "$TREE/$f" ] || { echo "MISSING_RTL $TREE/$f"; exit 1; }
  done
}

# ---- 1/2. alias regressions -------------------------------------------------
alias_one() {  # alias_one <tb> <defs> <srcs> <tag>
  local tb=$1 defs=$2 srcs=$3 tag=$4
  local list="" f
  for f in $srcs; do list="$list $TREE/$f"; done
  local rc res

  if [ "$SIM" = verilator ]; then
    local mdir="$OUT/vobj_$tag"
    rm -rf "$mdir"
    [ -x "$VERILATOR_BIN" ] || { echo "[$tag] MISSING $VERILATOR_BIN"; fail=1; return; }
    # verilator_bin needs VERILATOR_ROOT explicitly (only the perl wrapper sets it)
    local vlrw
    vlrw=$(cygpath -w "$VLROOT" 2>/dev/null | sed 's#\\#/#g')
    # shellcheck disable=SC2086
    VERILATOR_ROOT="$vlrw" "$VERILATOR_BIN" --cc --exe --main --timing --top-module "$tb" \
      --Mdir "$mdir" -o "${tb}_sim" -Wno-fatal -Wno-lint $defs ${EXTRA_DEFS:-} \
      $list "$HERE/$tb.sv" > "$OUT/$tb.compile.log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "[$tag] VERILATOR_GEN_FAILED rc=$rc (see $OUT/$tb.compile.log)"
      grep -a -m3 -E "%Error|Error" "$OUT/$tb.compile.log"; fail=1; return
    fi
    local wdir wroot
    wdir=$(to_wsl "$mdir"); wroot=$(to_wsl "$VLROOT")
    timeout 900 wsl.exe -e bash -lc "cd '$wdir' && rm -f *.d && make -f V$tb.mk -j4 VERILATOR_ROOT='$wroot' && ./${tb}_sim" \
      > "$OUT/$tb.run.log" 2>&1
    rc=$?
  else
    # shellcheck disable=SC2086
    iverilog -g2012 $defs ${EXTRA_DEFS:-} -o "$OUT/$tb.vvp" $list "$HERE/$tb.sv" > "$OUT/$tb.compile.log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "[$tag] COMPILE_FAILED rc=$rc (see $OUT/$tb.compile.log)"
      grep -a -m3 -E "error|Error" "$OUT/$tb.compile.log"; fail=1; return
    fi
    timeout 300 vvp "$OUT/$tb.vvp" > "$OUT/$tb.run.log" 2>&1
    rc=$?
  fi

  res=$(grep -a '^RESULT:' "$OUT/$tb.run.log" | tail -1)
  echo "[$tag] ${res:-NO_RESULT} (sim rc=$rc)"
  grep -a '^\[FAIL\]' "$OUT/$tb.run.log" | head -6
  case "$res" in *"RESULT: PASS"*) : ;; *) fail=1 ;; esac
}

alias_one tb_dcache_index_alias_legacy "$dcache_defs" "$dcache_srcs" dcache
if [ "$want_icache" = 1 ]; then
  alias_one tb_icache_index_alias_legacy "" "$icache_srcs" icache
else
  echo "[icache] skipped (no icache copy in this tree)"
fi

# ---- 3/4. tag-width guard A/B (controllers only; no memories) ---------------
require riscv_core_dcache_controller.sv
ctrl_srcs="$TREE/riscv_core_dcache_controller.sv"
[ "$want_icache" = 1 ] && ctrl_srcs="$ctrl_srcs $TREE/riscv_core_icache_controller.sv"

run_guard() {  # run_guard <a|b> <extra-defs>
  local which=$1 extra=$2
  local vvp="$OUT/tb_guard_legacy_$which.vvp"
  rm -f "$vvp"
  # shellcheck disable=SC2086
  iverilog -g2012 $guard_defs $extra -o "$vvp" $ctrl_srcs "$HERE/tb_cache_tag_width_guard_legacy.sv" \
    > "$OUT/tb_guard_legacy_$which.compile.log" 2>&1 || {
      echo "[guard $which] COMPILE_FAILED (see $OUT/tb_guard_legacy_$which.compile.log)"
      tail -5 "$OUT/tb_guard_legacy_$which.compile.log"; fail=1; return 1; }
  [ -f "$vvp" ] || { echo "[guard $which] COMPILE produced no image"; fail=1; return 1; }
  timeout 120 vvp "$vvp" > "$OUT/tb_guard_legacy_$which.run.log" 2>&1
  return 0
}

if run_guard a ""; then
  if grep -aq "TAG_WIDTH=" "$OUT/tb_guard_legacy_a.run.log"; then
    echo "[guard A] FAIL derived default tripped the guard: $(grep -a 'TAG_WIDTH=' "$OUT/tb_guard_legacy_a.run.log" | head -2)"
    fail=1
  elif ! grep -aq "GUARD_CONTROL_DONE" "$OUT/tb_guard_legacy_a.run.log"; then
    echo "[guard A] FAIL no completion marker"; fail=1
  else
    echo "[guard A] PASS derived default silent"
  fi
fi

if run_guard b "-DWRONG_TAG_WIDTH"; then
  want=1; [ "$want_icache" = 1 ] && want=2
  got=$(grep -ac "TAG_WIDTH=" "$OUT/tb_guard_legacy_b.run.log")
  if [ "$got" -ge "$want" ]; then
    echo "[guard B] PASS guard fired for $got/$want controller(s)"
  else
    echo "[guard B] FAIL guard fired for only $got/$want controller(s) (dead check)"
    fail=1
  fi
fi

if [ $fail -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $fail
