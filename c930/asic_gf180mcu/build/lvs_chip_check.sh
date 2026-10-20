#!/usr/bin/env bash
# lvs_chip_check.sh -- LVS for the die itself (plan S2), on the artifact we actually have.
#
# WHY THIS EXISTS
#
#   `grx930_test_chip_final.gds` cannot be LVS'd as it stands, and the reason is not the harness:
#   its standard cells are LEF abstracts -- pin rectangles, wells and a boundary, with no comp,
#   no poly and no contact anywhere in the file -- and its layer numbers are a LEF/DEF index
#   scheme (Metal1=5/0 ... Metal5=13/0, Pwell=1, Nwell=2) rather than the PDK's (comp 22/0,
#   poly2 30/0, metal1 34/0 ...). The deck reads the PDK's numbers, so it reads nothing:
#   "Total no. of polygons in the design is 0", and the comparison that follows is between an
#   empty netlist and the schematic. See tools/lvs_chip/probe_identify_layers.py, which derives
#   the die's own numbering from the DEF via cells, and tools/lvs_chip/compare_cells.py, which
#   matches the die's cell contents against the LEF's pin and obstruction rectangles.
#
#   This script writes the file the flow should have written (tools/lvs_chip/stream_out.py): the
#   DEF's placements, the routing the die already had, the PDK library's real cell layouts, and
#   the PDK's layer numbers. Three defects go with it, all measured by tools/lvs_chip/stream_check.py
#   on the shipped file: cells are abstracts (229/229), the numbers are the LEF scheme (0/5 device
#   layers), and 30,130 of 53,745 cells sit where the DEF does not put them (N exact, FS one
#   3.92 um row high, FN and S elsewhere) -- plus 195 instances of cells the design never places
#   (`filltie` among them). The routed gate-level netlist becomes a device-level CDL with power
#   bound (tools/lvs_chip/mk_chip_cdl.py). What the deck then answers is "does the die's routing
#   agree with the routed netlist" -- everything inside the cells is the library's, not the die's.
#
# INPUTS IT NEEDS
#
#   * the die, the routed netlist, and a PDK install with the deck:
#       wafer_space_submission/grx930_test_chip_final.gds
#       build/grx930_test_chip_routed.v
#       gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/{cdl,gds}/      (gds/ is not in every install)
#   * docker + the flow image, as tools/klayout_lvs.sh requires.
#
# WHAT IT COSTS
#
#   The stream-out is minutes and ~60 MB of GDS plus ~7 M polygons; the deck's extraction of that
#   is the expensive part, and it runs in `tiling` mode because `deep` was killed by memory at
#   158 min (exit 137) with the container at 3.6 of its 5.8 GiB. Tiling measures 2.3-2.4 GiB and
#   survives; it is still hours on one core, which is why this is not a gate and does not run in
#   CI (see doc/lvs_plan.md §5). The run directory is build/lvs_chip/run_chip_stream, and
#   build/lvs_chip_collect.sh waits for it and puts the gate's verdict beside the report.
#
#   bash build/lvs_chip_check.sh                 # stream out, check it, then judge (hours)
#   bash build/lvs_chip_check.sh --no-reconstruct  # judge the stream_out.gds already there
#   bash build/lvs_chip_check.sh --net-only        # extract the layout and stop (a timing probe)
#   bash build/lvs_chip_check.sh --deck <copy of gf180mcu.lvs>   # another deck, e.g. the pruned one
#                                                  # from build/lvs_chip_prune_deck.sh
#   bash build/lvs_chip_check.sh --mode deep        # keep the hierarchy (see below)
#   bash build/lvs_chip_check.sh --threads 3        # tiled work on 3 cores (pruned deck only)
#
# RUN MODE, AND WHY IT IS A CHOICE
#
#   `tiling` bounds memory -- it extracts 500 um tiles with 10 um borders -- but the netlist the
#   tiling processor returns is flat, so the comparison is a flat-vs-flat match of ~500 k devices
#   against a schematic the deck first has to flatten. Measured on this die with the pruned deck:
#   every extraction class finished by 15 min (build/lvs_chip/pruned_tiling_attempt1.klayout.log,
#   00:06:20 -> 00:21:42), and the run then spent 2 h 51 min with no further log line before Docker
#   Desktop died under it (03:13:20Z).
#
#   Threads are what moved that wall, and they are why `--threads` exists. The deck configures
#   `tiles(500.um)` and never says how many threads to use, so the engine uses one; the pruned deck
#   adds `threads(($threads || 1).to_i)` beside it (the DSL really has it: build/lvs_chip/probe/
#   lvs_dsl_probe.lvs answers `threads? true`). The same tiled work that outlived three hours on one
#   core reaches the comparison banner in 13 min 28 s on four (build/lvs_chip/run_chip_stream/
#   klayout.log, 2026-10-19), and Claude outputs/stream_out_fix.md §4c carries the timing. Without
#   the switch the count is 1, i.e. the vendor deck's behaviour.
#
#   `deep` keeps the layout hierarchy: the 53,745 placements reference 34 library cells, so the
#   layout netlist is 34 cells plus a top level, and the comparison stays hierarchical like the
#   schematic. That is what makes it the mode to try when the flat compare does not converge. It
#   costs memory for the top-level routing derivations instead, which is why it is not the
#   default: the first deep attempt (unpruned deck, on the reconstruction) was killed at 158 min
#   with the container at 3.6 of its 5.8 GiB.
#
# Exit status is build/lvs_check.sh's: 0 PASS, 1 MISMATCH, 2 CANNOT-RUN.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
TOOLS=$ROOT/c930/asic_gf180mcu/tools
WORK=$HERE/lvs_chip
STREAM=$WORK/stream_out.gds
CDL=$WORK/grx930_test_chip.cdl
RUN=$WORK/run_chip_stream
# Paths as the image sees them (tools/klayout_lvs.sh mounts the repository root on /work).
C=/work/c930/asic_gf180mcu
ARTIFACT=$C/wafer_space_submission/grx930_test_chip_final.gds

RECONSTRUCT=1
NET_ONLY=0
DECK=""
MODE=tiling
THREADS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-reconstruct) RECONSTRUCT=0; shift ;;
        --net-only)       NET_ONLY=1; shift ;;
        --deck)           DECK=$2; shift 2 ;;
        --deck=*)         DECK=${1#*=}; shift ;;
        --mode)           MODE=$2; shift 2 ;;
        --mode=*)         MODE=${1#*=}; shift ;;
        --threads)        THREADS=$2; shift 2 ;;
        --threads=*)      THREADS=${1#*=}; shift ;;
        -h|--help)        sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "lvs_chip_check: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done
case $MODE in
    tiling|deep|flat) ;;
    *) echo "lvs_chip_check: --mode must be tiling, deep or flat (got '$MODE')" >&2; exit 2 ;;
esac

PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "LVS-CHIP: CANNOT-RUN no python3/python on PATH" >&2; exit 2; }

# The generators run inside the image (klayout.db, and /work paths), like every other tool here.
# The script's own path is translated from the host's to the mount's: `$TOOLS` is a host path, and
# passing it through (`MSYS_NO_PATHCONV=1` keeps MSYS from rewriting it) names a file the container
# does not have. Its arguments are already container paths, which is why only argv[0] is mapped.
run_in_image() {
    local mount=$ROOT script inside
    command -v cygpath >/dev/null 2>&1 && mount=$(cygpath -m "$ROOT")
    script=$1; shift
    case $script in
        "$ROOT"/*) inside=/work${script#"$ROOT"} ;;
        *)         inside=$script ;;
    esac
    MSYS_NO_PATHCONV=1 docker run --rm -v "$mount:/work" -w /work \
        "${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}" python3 "$inside" "$@"
}

if [ "$RECONSTRUCT" = 1 ]; then
    echo "== stream-out: DEF placements, library layouts, PDK numbers"
    run_in_image "$TOOLS/lvs_chip/stream_out.py" || {
        echo "LVS-CHIP: CANNOT-RUN the stream-out failed" >&2; exit 2; }
    echo "== stream check: would the deck read that file"
    run_in_image "$TOOLS/lvs_chip/stream_check.py" \
        --gds "$C/build/lvs_chip/stream_out.gds" \
        --def "$C/build/grx930_test_chip.def" \
        --lib "$C/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds" \
        --routing-compare "$ARTIFACT" || {
        echo "LVS-CHIP: CANNOT-RUN the stream check refused the file" >&2; exit 2; }
    echo "== netlist: routed Verilog -> device-level CDL"
    run_in_image "$TOOLS/lvs_chip/mk_chip_cdl.py" || {
        echo "LVS-CHIP: CANNOT-RUN the CDL conversion failed" >&2; exit 2; }
fi

[ -f "$STREAM" ] || { echo "LVS-CHIP: CANNOT-RUN no $STREAM" >&2; exit 2; }
[ -f "$CDL" ]   || { echo "LVS-CHIP: CANNOT-RUN no $CDL" >&2; exit 2; }

# The deck's answer for the whole die needs its netter, and on this design that has not returned
# (see doc/lvs_plan.md S2: 9 h in `tiling`, 30 min in `deep`, one core busy, 4.5 GiB resident).
# This is the check that does not need it: the routed DEF and the CDL, compared as a partition of
# pins, in seconds. It is not a substitute for the deck -- it says nothing about geometry, and the
# deck is what reads the GDS -- but it is the top level's connectivity answered, and it is run
# before the deck so that a connectivity defect is visible while the deck is still thinking.
echo "== connectivity: routed DEF vs the CDL the deck reads (tools/lvs_chip/net_compare.py)"
run_in_image "$TOOLS/lvs_chip/net_compare.py" \
    --def "$C/build/grx930_test_chip.def" --cdl "$C/build/lvs_chip/grx930_test_chip.cdl" \
    --json "$C/build/lvs_chip/net_compare.json"
CONN_RC=$?
echo "   net_compare exit=$CONN_RC (0 MATCH, 1 MISMATCH, 2 CANNOT-RUN); this does not decide the run"

echo "== deck: running the chip through tools/klayout_lvs.sh (this is the long part)"
# See RUN MODE in the header: tiling bounds memory but compares flat; deep keeps the hierarchy
# and is the mode to reach for when the flat compare does not converge.
extra=()
[ "$NET_ONLY" = 1 ] && extra+=(--switch net_only=true)
# `threads` only exists in the pruned/probe decks (build/lvs_chip_prune_deck.sh inserts the call);
# on the vendor deck the switch is inert, which is why it is not passed unless asked for.
if [ -n "$THREADS" ]; then
    case $THREADS in
        ''|*[!0-9]*) echo "lvs_chip_check: --threads takes a positive integer (got '$THREADS')" >&2; exit 2 ;;
    esac
    extra+=(--switch "threads=$THREADS")
    echo "threads: $THREADS"
fi
# --deck names another copy of the deck; build/lvs_chip_prune_deck.sh generates the one that skips
# device classes the die has no geometry for (its header carries the measurement). The default is
# the harness's own deck, the vendored PDK one.
deck_args=()
[ -n "$DECK" ] && deck_args+=(--deck "$DECK") && echo "deck: $DECK"
bash "$TOOLS/klayout_lvs.sh" --layout "$STREAM" --netlist "$CDL" --out "$RUN" \
     --switch metal_level=5LM --switch run_mode="$MODE" \
     "${deck_args[@]+"${deck_args[@]}"}" "${extra[@]+"${extra[@]}"}"
rc=$?

if [ "$NET_ONLY" = 1 ] && [ ! -f "$RUN/verdict.json" ]; then
    # net_only produces an extracted netlist and no comparison; the harness calls that CANNOT-RUN,
    # which is correct for a verdict and wrong for a timing probe.
    echo "LVS-CHIP: extraction-only run finished (rc=$rc); see $RUN/extracted.cir"
    exit 0
fi

echo "== judge: the repo's LVS gate on the report it just made"
exec bash "$HERE/lvs_check.sh" --report "$RUN/verdict.json" \
     --layout "$STREAM" --netlist "$CDL" --out "$RUN"
