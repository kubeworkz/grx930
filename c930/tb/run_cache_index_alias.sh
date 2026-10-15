#!/bin/bash
# run_cache_index_alias.sh [RTL_DIR] [OUT_DIR]
#
# Compiles and runs the two cache index/tag alias regressions against RTL_DIR
# (the two cache tops + their controllers and memories) and reports PASS/FAIL.
# Exit status is 0 only if BOTH tests print "RESULT: PASS"; a missing RESULT
# (crash, hang, compile failure) counts as a failure.
#
# Usage:
#   ./run_cache_index_alias.sh                                        # local chip RTL
#   ./run_cache_index_alias.sh ../cache_sim/rtl_before /tmp/before      # pre-fix RTL
#   ./run_cache_index_alias.sh ../cache_sim/rtl_after  /tmp/after       # fixed RTL
#
# Needs iverilog + vvp (4.x/12.0 both fine; the RTL is SystemVerilog, hence -g2012).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RTL=${1:-$HERE/../asic_gf180mcu/openlane2_rtl/src}
OUT=${2:-$HERE/../asic_gf180mcu/build/cache_alias_sim}
mkdir -p "$OUT"

echo "RTL_DIR $RTL"
fail=0

for tb in tb_icache_index_alias tb_dcache_index_alias; do
  case "$tb" in
    tb_icache_*) srcs="riscv_core_icache_top.sv riscv_core_icache_controller.sv riscv_core_icache_memory.sv" ;;
    # The dcache top also pulls in the AMO ALU and mux helpers it uses.
    tb_dcache_*) srcs="riscv_core_dcache_top.sv riscv_core_dcache_controller.sv riscv_core_dcache_memory.sv riscv_core_amo_alu.sv riscv_core_mux3x1.sv riscv_core_mux2x1.sv riscv_core_mux4x1.sv riscv_core_mux_2to1.sv riscv_core_alu.sv riscv_core_64bit_adder.sv" ;;
  esac
  list=""
  for f in $srcs; do
    [ -f "$RTL/$f" ] || { echo "[$tb] MISSING_RTL $RTL/$f"; fail=1; continue 2; }
    list="$list $RTL/$f"
  done

  iverilog -g2012 -o "$OUT/$tb.vvp" $list "$HERE/$tb.sv" > "$OUT/$tb.compile.log" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[$tb] COMPILE_FAILED rc=$rc (see $OUT/$tb.compile.log)"
    grep -a -m3 -E "error|Error" "$OUT/$tb.compile.log"
    fail=1
    continue
  fi

  timeout 300 vvp "$OUT/$tb.vvp" > "$OUT/$tb.run.log" 2>&1
  rc=$?
  res=$(grep -a '^RESULT:' "$OUT/$tb.run.log" | tail -1)
  echo "[$tb] ${res:-NO_RESULT} (vvp rc=$rc)"
  grep -a '^\[FAIL\]' "$OUT/$tb.run.log" | head -6
  case "$res" in
    *"RESULT: PASS"*) : ;;
    *) fail=1 ;;
  esac
done

if [ $fail -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $fail
