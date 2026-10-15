#!/bin/bash
# ---------------------------------------------------------------------------
# run_ooc_c4b.sh -- C4(b)'s three out-of-context runs, on the Arty A7-200T.
#
#   act        c930_npu_act alone at 100 MHz: A-synth's gate.  Either it closes
#              or the report names the path to cut.
#   npu_array  c930_npu_top with the systolic array, the baseline.
#   npu_ptmc   c930_npu_top with PTM-C, so the difference is what the PTA costs
#              -- which is the table in grxcp pta_cpu_integration.md 6.1,
#              measured instead of estimated.
#
# Both NPU runs take the same 100 MHz constraint so their slack is comparable.
# Vivado on this host licences only against a MAC the vSwitch blackholes, so
# WSL has no network while this runs: see synth_xilinx/heal_mac.sh, and put the
# MAC back afterwards.
#
#   bash synth_xilinx/run_ooc_c4b.sh [act|npu_array|npu_ptmc|all]
# ---------------------------------------------------------------------------
set -u

WHICH="${1:-all}"
C930="$(cd "$(dirname "$0")/.." && pwd)"
cd "$C930"

source /mnt/c/Users/kubew/Vivaldo/2026.1/Vivado/settings64.sh 2>/dev/null
export XILINXD_LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"

PART=xc7a200tfbg484-1
PERIOD=10.000

NPU_COMMON="rtl/c930_fp16_mul.sv rtl/c930_bf16_mul.sv rtl/c930_fp_mul.sv \
rtl/c930_fp16_acc.sv rtl/c930_cla_sub.sv rtl/c930_cla_comp.sv rtl/c930_fx_acc.sv \
rtl/c930_npu_act.sv rtl/c930_npu_core.sv rtl/c930_npu_csr.sv rtl/c930_npu_dma.sv \
rtl/c930_npu_top.sv"
NPU_ARRAY="rtl/c930_tensor_pe.sv rtl/c930_systolic_array.sv"
# What the tile and the adders pull in: the FP multipliers and the
# carry-look-ahead comparator and subtractor.
ARITH="rtl/c930_fp16_mul.sv rtl/c930_bf16_mul.sv rtl/c930_fp_mul.sv rtl/c930_fp16_acc.sv rtl/c930_cla_sub.sv rtl/c930_cla_comp.sv rtl/c930_fx_acc.sv"
NPU_PTMC="rtl/pta/c930_fp32_add.sv rtl/pta/c930_ptm_c.sv rtl/pta/c930_pta_cal.sv"

# The shape c930_soc_top instantiates the NPU with, which is the baseline
# pta_cpu_integration.md 6.1 prices against.  The module's own defaults are the
# 6.2 shape and do not synthesize: 262,144 bits of A staging infer no RAM.
SOC_SHAPE="MAX_M=8 MAX_K=16 MAX_N=12 NUM_ROWS=8 NUM_COLS=8 DIN_W=16 ACC_W=48"

run_one () {
    local name="$1" top="$2" defines="$3" generics="$4"; shift 4
    local out="build/ooc_$name"
    mkdir -p "$out"
    echo "===== $name ($top${defines:+, $defines}) $(date +%H:%M:%S)"
    OOC_DEFINES="$defines" OOC_GENERICS="$generics" timeout 7200 vivado -mode batch -nojournal -notrace \
        -source synth_xilinx/ooc_synth.tcl \
        -log "$out/vivado.log" \
        -tclargs "$top" "$PART" "$PERIOD" "$out" "$@" 2>&1 \
      | grep -E "^REPORT |^ERROR" | sed "s/^/[$name] /"
    echo "===== $name exit ${PIPESTATUS[0]} $(date +%H:%M:%S)"
}

case "$WHICH" in
  act)       run_one act       c930_npu_act "" "" rtl/c930_npu_act.sv ;;
  npu_array) run_one npu_array c930_npu_top "" "$SOC_SHAPE" $NPU_COMMON $NPU_ARRAY ;;
  npu_ptmc)  run_one npu_ptmc  c930_npu_top PTM_C "$SOC_SHAPE" $NPU_COMMON $NPU_PTMC ;;
  all)
    run_one act       c930_npu_act ""      ""           rtl/c930_npu_act.sv
    run_one npu_array c930_npu_top ""      "$SOC_SHAPE" $NPU_COMMON $NPU_ARRAY
    run_one npu_ptmc  c930_npu_top PTM_C   "$SOC_SHAPE" $NPU_COMMON $NPU_PTMC
    ;;
  # The PTA's own blocks, which is what section 6.1's table itemises.  The whole
  # NPU with PTM-C does not synthesize on a 5.9 GB VM: it peaked at 6.5 GB and
  # was still short of finishing synthesis after an hour of swapping, where the
  # array build routed in thirteen minutes.  These are the added logic anyway,
  # and they route in minutes.
  tile)      run_one tile      c930_ptm_c   "" "NUM_ROWS=8 NUM_COLS=8 DIN_W=16"                $ARITH rtl/pta/c930_fp32_add.sv rtl/pta/c930_ptm_c.sv ;;
  cal)       run_one cal       c930_pta_cal "" "NUM_ROWS=8 NUM_COLS=8 DIN_W=16"                rtl/pta/c930_pta_cal.sv ;;
  csr)       run_one csr       c930_npu_csr "" "NUM_COLS=8" rtl/c930_npu_csr.sv ;;
  *) echo "usage: $0 [act|npu_array|npu_ptmc|tile|cal|csr|all]"; exit 1 ;;
esac
