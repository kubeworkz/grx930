#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# C930 SoC ECP5 synthesis + place-and-route resource/Fmax/latch report.
#
# Uses the vendored oss-cad-suite under c930/toolchain/ (portable, no install).
# Tools are invoked via `cmd` because the oss-cad-suite binaries are MSYS2
# builds and Git Bash's own runtime conflicts with them (direct exec -> 127).
#
# Usage:
#   bash synth/run_synth.sh          real design: yosys + nextpnr P&R.
#                                    The dcache is EBR-mapped (8 DP16KD) so the
#                                    full design fits ECP5-85F (~66K LUTs).
#   bash synth/run_synth.sh fit      cache-shrunk variant (chparam INDEX_WIDTH
#                                    7->3) + nextpnr P&R (kept as a comparison;
#                                    no longer needed to fit).
#
# Outputs (under c930/build/synth/):
#   synth.log / fit.log  yosys log: latch warnings + LUT/FF/BRAM/DSP stats
#   ecp5.json / fit.json post-synthesis netlists
#   pnr.log              nextpnr-ecp5 log: placement, routing, max-frequency
# -----------------------------------------------------------------------------
set -euo pipefail

MODE="${1:-synth}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OSS="$HERE/../toolchain/oss-cad-suite"
OUT="$HERE/../build/synth"

if [ ! -x "$OSS/bin/yosys.exe" ]; then
    echo "ERROR: oss-cad-suite not found at $OSS" >&2
    echo "  Download https://github.com/YosysHQ/oss-cad-suite-build/releases" >&2
    echo "  and extract it into c930/toolchain/oss-cad-suite" >&2
    exit 1
fi

# cmd needs the oss-cad-suite bin/lib dirs on PATH to find its DLLs.
export PATH="$OSS/bin:$OSS/lib:$PATH"
mkdir -p "$OUT"

cd "$HERE/.."   # c930/ -- keep all paths relative (cmd and bash agree)

if [ "$MODE" = "fit" ]; then
    FLOW=synth/synth_fit.ys
    JSON=fit.json
    LOG=fit.log
    DDRSTUB=synth/c930_ddr_stub.sv
    NOTE="fit-test (caches shrunk to 8 lines via chparam; DDR placeholder)"
else
    FLOW=synth/synth.ys
    JSON=ecp5.json
    LOG=synth.log
    DDRSTUB=synth/c930_ddr_stub.sv
    NOTE="real design (DDR placeholder stub)"
fi

# yosys does not expand wildcards itself and its scripts are line-oriented
# (one command per line): emit all files on a single read_verilog line, then
# append the checked-in flow body.
{
    echo -n "read_verilog -sv "
    for f in ../rv64imac/RTL/*.sv rtl/*.sv; do
        [ "$f" = "rtl/c930_ddr.sv" ] && continue   # behavioral 64KB array -> synth stub
        echo -n "$f "
    done
    echo -n " $DDRSTUB "
    echo
    echo
    cat "$FLOW"
} > "build/synth/run_$MODE.ys"

echo "== yosys synth_ecp5 (c930_soc_top) [$NOTE] =="
cmd //c "yosys -ql build/synth/$LOG build/synth/run_$MODE.ys"

echo "== nextpnr-ecp5 P&R (ECP5-85F placeholder) =="
cmd //c "nextpnr-ecp5 -l build/synth/pnr.log --json build/synth/$JSON --lpf synth/ecp5_85f.lpf --85k --package CABGA381 --speed 8 --textcfg build/synth/ecp5.config"

echo
echo "===================== REPORT ($MODE) ====================="
echo "== LATCHES (from yosys log) =="
if grep -iE "latch" "build/synth/$LOG"; then
    echo "(latches above are inferred storage -- real silicon hazard, see RTL)"
else
    echo "none reported"
fi
echo
echo "== RESOURCES (post-map stats) =="
grep -E "Number of cells|LUT|FF |BRAM|DSP" "build/synth/$LOG" | grep -vE "\\\\\$abc|GND|VCC" | head -20
echo
echo "== FMAX (nextpnr-ecp5 timing report) =="
grep -iE "max frequency|fmax" build/synth/pnr.log | tail -6
echo
echo "Logs: build/synth/$LOG  ${MODE/fit/pnr}.log"
echo "==========================================================="
