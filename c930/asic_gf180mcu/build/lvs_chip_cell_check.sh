#!/usr/bin/env bash
# lvs_chip_cell_check.sh -- LVS a handful of the artifact's own cells, in seconds.
#
# WHY THIS EXISTS
#
#   build/lvs_chip_check.sh answers the whole chip, and on this box that is hours: the deck walks
#   every tile for every device class. The cell question is separate, and it is the one the shipped
#   artifact failed outright -- its standard cells were LEF abstracts on a LEF/DEF layer index, so
#   any deck read zero transistors from them. Cutting one cell out of the stream-out and letting the
#   same deck compare it against the same library netlist answers that question in seconds.
#
#   The chip run is still the one that proves connectivity; this one proves that the cells the chip
#   run will flatten are real, and that their drawn W/L is the library's.
#
# WHAT IT COMPARES
#
#   Devices only (`--no-port-check`). A standard cell drawn alone has no pin labels for its body
#   terminals, so the deck reports the well nets as difference in *ports* while the transistors
#   themselves are identical -- measured on clkinv_1: layout VSS VDD I ZN SUB against schematic
#   I ZN VDD VNW VPW VSS. At chip level the CDL binds VNW to VDD and VPW to VSS, and the chip run
#   is where that binding is checked; here the port check would only restate the cut-out's shape.
#
#   With `--old` it runs the same comparison on `wafer_space_submission/grx930_test_chip_final.gds`
#   -- the September artifact -- so "before" and "after" are the same command on two files, rather
#   than a claim about two files.
#
#   bash build/lvs_chip_cell_check.sh            # the stream-out, 3 cells
#   bash build/lvs_chip_cell_check.sh --old      # the shipped artifact, for the "before" row
#   bash build/lvs_chip_cell_check.sh --cells A,B
#
# Exit status: 0 every cell matched, 1 a cell mismatched, 2 could not run.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
TOOLS=$ROOT/c930/asic_gf180mcu/tools
WORK=$HERE/lvs_chip
CDL=$WORK/grx930_test_chip.cdl
STREAM=$WORK/stream_out.gds
ARTIFACT=$ROOT/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds
CELLS=gf180mcu_fd_sc_mcu7t5v0__clkinv_1,gf180mcu_fd_sc_mcu7t5v0__nand2_1,gf180mcu_fd_sc_mcu7t5v0__dffq_1
GDS=$STREAM
TAG=stream

while [ $# -gt 0 ]; do
    case "$1" in
        --old)    GDS=$ARTIFACT; TAG=artifact; shift ;;
        --cells)  CELLS=$2; shift 2 ;;
        --cells=*) CELLS=${1#*=}; shift ;;
        -h|--help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "lvs_chip_cell_check: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

[ -f "$GDS" ] || { echo "LVS-CELL: CANNOT-RUN no $GDS" >&2; exit 2; }
[ -f "$CDL" ] || { echo "LVS-CELL: CANNOT-RUN no $CDL" >&2; exit 2; }

MOUNT=$ROOT
command -v cygpath >/dev/null 2>&1 && MOUNT=$(cygpath -m "$ROOT")
C=/work/c930/asic_gf180mcu
CTR_GDS=${GDS#"$ROOT"/}
OUT=$WORK/cell_lvs_$TAG

echo "== cutting cells out of ${CTR_GDS}"
MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" -w /work \
    "${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}" python3 \
    "$C/tools/lvs_chip/cell_lvs.py" --gds "/work/$CTR_GDS" --cdl "$C/build/lvs_chip/grx930_test_chip.cdl" \
    --cells "$CELLS" --out "$C/build/lvs_chip/cell_lvs_$TAG" || {
    echo "LVS-CELL: CANNOT-RUN the cut-out failed" >&2; exit 2; }

fail=0
for cell in ${CELLS//,/ }; do
    echo "== ${cell}"
    out=$(bash "$TOOLS/klayout_lvs.sh" --layout "$OUT/$cell.gds" --netlist "$OUT/$cell.cdl" \
              --topcell "$cell" --out "$OUT/run_${cell##*__}" \
              --switch metal_level=5LM --no-port-check 2>&1)
    rc=$?
    echo "$out" | grep -E '^(devices|verdict)'
    # The harness's own exit status is the verdict; the netlist it extracted is the evidence.
    if [ $rc -ne 0 ] || ! echo "$out" | grep -q '^verdict  *MATCH'; then
        fail=1
        extra=$(grep -c '^M' "$OUT/run_${cell##*__}/extracted.cir" 2>/dev/null)
        echo "   $cell: ${extra:-0} transistor cards extracted"
    fi
done

if [ $fail = 0 ]; then
    echo "LVS-CELL: PASS on $GDS (${CELLS//,/ })"
    exit 0
fi
echo "LVS-CELL: MISMATCH on $GDS"
exit 1
