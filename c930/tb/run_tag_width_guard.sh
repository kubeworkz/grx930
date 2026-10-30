#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# run_tag_width_guard.sh [RTL_DIR] [OUT_DIR]
#
# Negative control for the cache controllers' tag-width guard. Asserts:
#   A. INDEX_WIDTH=4, TAG_WIDTH omitted -> the top's derived default satisfies
#      the guard: no diagnostic, sim reaches the end (exit 0).
#   B. INDEX_WIDTH=4, TAG_WIDTH=52 (the pre-fix hardcoded value) -> the guard
#      fires and says so, i.e. it is not dead code.
# Exit status 0 only if BOTH hold.
#
# Needs iverilog + vvp, same set of RTL files as run_cache_index_alias.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RTL=${1:-$HERE/../asic_gf180mcu/openlane2_rtl/src}
OUT=${2:-$HERE/../asic_gf180mcu/build/cache_alias_sim}
mkdir -p "$OUT"

srcs="riscv_core_icache_top.sv riscv_core_icache_controller.sv riscv_core_icache_memory.sv \
      riscv_core_dcache_top.sv riscv_core_dcache_controller.sv riscv_core_dcache_memory.sv \
      riscv_core_amo_alu.sv riscv_core_mux3x1.sv riscv_core_mux2x1.sv riscv_core_mux4x1.sv \
      riscv_core_mux_2to1.sv riscv_core_alu.sv riscv_core_64bit_adder.sv"
list=""
for f in $srcs; do
  [ -f "$RTL/$f" ] || { echo "MISSING_RTL $RTL/$f"; exit 1; }
  list="$list $RTL/$f"
done

fail=0

# ---- A: derived default must be silent --------------------------------------
iverilog -g2012 -o "$OUT/tb_guard_default.vvp" $list "$HERE/tb_cache_tag_width_guard.sv" \
  > "$OUT/tb_guard_default.compile.log" 2>&1 || {
    echo "[A] COMPILE_FAILED (see $OUT/tb_guard_default.compile.log)"; tail -5 "$OUT/tb_guard_default.compile.log"; exit 1; }
timeout 120 vvp "$OUT/tb_guard_default.vvp" > "$OUT/tb_guard_default.run.log" 2>&1
rc=$?
if grep -aq "TAG_WIDTH=" "$OUT/tb_guard_default.run.log"; then
  echo "[A] FAIL guard fired on the derived default: $(grep -a 'TAG_WIDTH=' "$OUT/tb_guard_default.run.log" | head -2)"
  fail=1
elif ! grep -aq "GUARD_CONTROL_DONE" "$OUT/tb_guard_default.run.log"; then
  echo "[A] FAIL no completion marker (vvp rc=$rc)"; tail -5 "$OUT/tb_guard_default.run.log"; fail=1
else
  echo "[A] PASS derived default silent, sim completed (vvp rc=$rc)"
fi

# ---- B: explicit wrong TAG_WIDTH must trip the guard -----------------------
iverilog -g2012 -DWRONG_TAG_WIDTH -o "$OUT/tb_guard_wrong.vvp" $list "$HERE/tb_cache_tag_width_guard.sv" \
  > "$OUT/tb_guard_wrong.compile.log" 2>&1 || {
    echo "[B] COMPILE_FAILED (see $OUT/tb_guard_wrong.compile.log)"; tail -5 "$OUT/tb_guard_wrong.compile.log"; exit 1; }
timeout 120 vvp "$OUT/tb_guard_wrong.vvp" > "$OUT/tb_guard_wrong.run.log" 2>&1
if grep -aq "TAG_WIDTH=" "$OUT/tb_guard_wrong.run.log"; then
  echo "[B] PASS guard fired: $(grep -a 'TAG_WIDTH=' "$OUT/tb_guard_wrong.run.log" | head -2 | tr '\n' ' ')"
else
  echo "[B] FAIL guard did NOT fire on TAG_WIDTH=52 at INDEX_WIDTH=4 (dead check)"; fail=1
fi

if [ $fail -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $fail
