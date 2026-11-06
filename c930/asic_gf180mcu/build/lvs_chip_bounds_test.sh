#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_chip_bounds_test.sh -- run the die comparison once with the netlist comparer's ambiguity
# bounds reduced, so a bounded run can be compared with the unbounded one on the same deck.
#
# WHY THIS EXISTS
#
#   build/lvs_chip/probe/sample_stack.gdb put 20/20 stacks inside
#   NetlistCompareCore::derive_node_identities on the pruned tiling run -- the comparer, not the
#   netter, and not the substrate connect phase. The engine's two knobs for that search are
#   `max_depth` (search depth in jumps) and `max_branch_complexity` (accumulated branch options for
#   ambiguous matches). KLayout's reference says both are unlimited from 0.27 on, and that they can
#   be reduced "in cases where runtimes need to be limited at the cost [of] less elaborate matching
#   evaluation". build/lvs_chip/probe/bounds_api.lvs measures the defaults the installed engine
#   actually carries: branch = 18446744073709551615, depth = 500.
#
#   The deck already sets both when named (build/lvs_chip_prune_deck.sh), but a switch that is
#   silently ignored would look exactly like a null result, so each run here names one knob and
#   nothing else. Run two and the comparison is controlled: same deck, same layout, same netlist,
#   same thread count, same mode, one bound different from the default.
#
#   Usage (from c930/asic_gf180mcu):
#     bash build/lvs_chip_bounds_test.sh bounds-depth1  --depth 1
#     bash build/lvs_chip_bounds_test.sh bounds-branch1 --branch 1
#     bash build/lvs_chip_bounds_test.sh bounds-mid --depth 25 --branch 1000 --threads 6
#     bash build/lvs_chip_bounds_test.sh filled-b12300 --branch 12300 \
#         --layout build/lvs_chip/stream_out_filled_metal1.gds
#     bash build/lvs_chip_bounds_test.sh rebased-b12300 --branch 12300 \
#         --layout build/rebased/stream_out_filled.gds \
#         --netlist build/rebased/grx930_test_chip.cdl
#
#   --layout and --netlist default to the canonical build/ pair, so a run against new GDS and CDL
#   can sit beside the old one without either being renamed.
#
#   Each run is a background process whose log is <run>/driver.log; the deck's own log is
#   <run>/klayout.log and the runner's verdict is <run>/verdict.json.
#
#   The die's extracted netlist is ~176 GB (measured: run_chip_stream filled a 301 GB disk with
#   176,599,826,432 bytes before dying on ENOSPC), and the deck writes it in `_finish`, i.e. after
#   the verdict is logged. A directory at the path is not a guard: KLayout's writer renamed it to
#   `extracted.cir.~backup` and wrote a 17 GB file anyway (bounds-branch1), and 26.7 GB in
#   bounds-depth1. The pruned deck now has `write_netlist=false`, which skips both of its
#   `target_netlist` calls, and `--no-extracted-netlist` keeps the runner from naming a target
#   either, so the dump never starts. The port check reads that netlist, so --no-port-check is
#   passed too and the verdict is device-level. The LVS report is still written after the verdict.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
WORK=$HERE/lvs_chip

[ $# -ge 1 ] || { echo "usage: $0 <run-name> [--depth N] [--branch N] [--threads N] [--mode M] [--layout FILE] [--netlist FILE]" >&2; exit 2; }
NAME=$1; shift
DEPTH=""; BRANCH=""; THREADS=8; MODE=tiling; LAYOUT=$WORK/stream_out.gds
NETLIST=$WORK/grx930_test_chip.cdl
while [ $# -gt 0 ]; do
    case "$1" in
        --layout)  LAYOUT=$2; shift 2 ;;
        --layout=*) LAYOUT=${1#*=}; shift ;;
        --netlist) NETLIST=$2; shift 2 ;;
        --netlist=*) NETLIST=${1#*=}; shift ;;
        --depth)   DEPTH=$2; shift 2 ;;
        --depth=*) DEPTH=${1#*=}; shift ;;
        --branch)  BRANCH=$2; shift 2 ;;
        --branch=*) BRANCH=${1#*=}; shift ;;
        --threads) THREADS=$2; shift 2 ;;
        --threads=*) THREADS=${1#*=}; shift ;;
        --mode)    MODE=$2; shift 2 ;;
        --mode=*)  MODE=${1#*=}; shift ;;
        -h|--help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bounds_test: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$DEPTH$BRANCH" ] || { echo "bounds_test: name at least one of --depth / --branch" >&2; exit 2; }
for v in "$DEPTH" "$BRANCH" "$THREADS"; do
    [ -z "$v" ] && continue
    case "$v" in *[!0-9]*) echo "bounds_test: bound/threads must be a non-negative integer (got '$v')" >&2; exit 2 ;; esac
done
case $MODE in tiling|deep|flat) ;; *) echo "bounds_test: --mode must be tiling, deep or flat" >&2; exit 2 ;; esac

[ -f "$LAYOUT" ] && [ -s "$LAYOUT" ] || { echo "bounds_test: no layout at $LAYOUT" >&2; exit 2; }
[ -f "$NETLIST" ] || { echo "bounds_test: no netlist at $NETLIST" >&2; exit 2; }
[ -f "$WORK/deck_pruned/gf180mcu.lvs" ] || { echo "bounds_test: no pruned deck (run build/lvs_chip_prune_deck.sh)" >&2; exit 2; }
grep -q '^max_depth(' "$WORK/deck_pruned/gf180mcu.lvs" || {
    echo "bounds_test: the deck has no max_depth line; the switch would be inert" >&2; exit 2; }
grep -q 'def target_netlist_if_enabled' "$WORK/deck_pruned/gf180mcu.lvs" || {
    echo "bounds_test: the deck has no netlist-dump switch (regenerate it with build/lvs_chip_prune_deck.sh)" >&2
    exit 2; }

RUN=$WORK/$NAME
if [ -e "$RUN/verdict.json" ]; then
    echo "bounds_test: $NAME already has a verdict: $RUN/verdict.json" >&2; exit 2
fi
mkdir -p "$RUN"
# A stale target file from an older run would be renamed to `.~backup` by KLayout's writer; start
# from neither. See the header for why this path is not a guard on its own.
rm -rf "$RUN/extracted.cir" "$RUN/extracted.cir.~backup" 2>/dev/null

sw=()
[ -n "$DEPTH" ]  && sw+=(--switch "max_depth=$DEPTH")
[ -n "$BRANCH" ] && sw+=(--switch "max_branch_complexity=$BRANCH")

echo "bounds_test: $NAME  depth=${DEPTH:-default}  branch=${BRANCH:-default}  threads=$THREADS  mode=$MODE"
echo "bounds_test: layout $LAYOUT"
echo "bounds_test: switches: ${sw[*]:-none}"
nohup setsid bash "$HERE/../tools/klayout_lvs.sh" \
    --layout "$LAYOUT" \
    --netlist "$NETLIST" \
    --out "$RUN" \
    --deck "$WORK/deck_pruned/gf180mcu.lvs" \
    --switch metal_level=5LM --switch "run_mode=$MODE" --switch "threads=$THREADS" \
    "${sw[@]}" --switch write_netlist=false --no-extracted-netlist --no-port-check \
    > "$RUN/driver.log" 2>&1 < /dev/null &
PID=$!
echo "$NAME ${DEPTH:--} ${BRANCH:--} $THREADS $MODE $(basename "$LAYOUT") $(basename "$NETLIST")" > "$RUN/config"
echo "bounds_test: pid $PID  log $RUN/driver.log"
