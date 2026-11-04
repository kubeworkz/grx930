#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_chip_row_census.sh -- lay one standard cell out as an abutting row / stacked grid and census the
# extraction, to separate adjacency from the stream-out's placement anchor.
#
# WHY THIS EXISTS
#
#   build/lvs_chip_cell_census.sh showed every placed cell extracts its own device count exactly, and
#   build/lvs_chip/probe/die_geometry_census.py showed the die carries all of their geometry, yet the
#   die extracts 171,109 devices instead of 691,010 with a 1.94:1 PFET skew. This builds the neighbour
#   case with nothing else changed: copies of one cell at its LEF pitch (7.28 x 3.92 um for mux2_1),
#   in a row (horizontal adjacency only) and in 16x16 grids (both axes), and censuses each.
#
#   The grids come in two anchoring flavours. `raw` is what tools/lvs_chip/stream_out.py does --
#   KLayout's Trans mirrors about the origin, so an FS copy placed at a row's DEF y lands one row low.
#   `anchor` keeps each oriented copy inside its w x h row box (`FS` at +h, `S` at +w,+h, `FN` at
#   +w), which is what the September artifact does and what the DEF's row bottoms require. The row
#   probe is what showed that the difference, not adjacency, reproduces the die's loss.
#
#   Usage (from c930/asic_gf180mcu):
#     bash build/lvs_chip_row_census.sh            # build what is missing, run what is missing, print
#     bash build/lvs_chip_row_census.sh --rebuild  # rebuild the layouts, keep existing runs
#
#   Writes build/lvs_chip/row_census/<layout>.gds and build/lvs_chip/evidence_census/row-<name>/.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=$HERE/lvs_chip
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
IMAGE=${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}
M=gf180mcu_fd_sc_mcu7t5v0__mux2_1
D=gf180mcu_fd_sc_mcu7t5v0__dffq_1
OUT=$WORK/row_census
CDLS=$WORK/cell_census
JOBS=3
REBUILD=0

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
    case "$1" in
        --rebuild) REBUILD=1; shift ;;
        --jobs)    JOBS=$2; shift 2 ;;
        --jobs=*)  JOBS=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "row_census: unknown argument: $1" >&2; exit 2 ;;
    esac
done

PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "row_census: no python3/python on PATH" >&2; exit 2; }
for f in "$CDLS/$M.gds" "$CDLS/$M.cdl" "$CDLS/$D.gds" "$CDLS/$D.cdl"; do
    [ -f "$f" ] || { echo "row_census: missing $f (run build/lvs_chip_cell_census.sh --all)" >&2; exit 2; }
done
mkdir -p "$OUT"

MOUNT=$ROOT
if command -v cygpath >/dev/null 2>&1; then MOUNT=$(cygpath -m "$ROOT"); fi
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) echo "row_census: $1 is outside the repository" >&2; return 2 ;; esac; }

# name | cell | probe arguments (beyond --gds/--cell/--out) | expected devices
LAYOUTS="
mux2_row_abut|$M|--count 256 --pitch-x-um 7.28|3072
mux2_row_gap|$M|--count 256 --pitch-x-um 7.28 --gap-um 1.0|3072
dffq_row_abut|$D|--count 128 --pitch-x-um 16.24|3072
mux2_grid_n|$M|--grid 16x16 --pitch-x-um 7.28 --pitch-y-um 3.92|3072
mux2_grid_fs|$M|--grid 16x16 --pitch-x-um 7.28 --pitch-y-um 3.92 --row-orients N,FS|3072
mux2_grid_fs_anchor|$M|--grid 16x16 --pitch-x-um 7.28 --pitch-y-um 3.92 --row-orients N,FS --def-anchors|3072
"
while IFS='|' read -r name cell args expected; do
    [ -n "$name" ] || continue
    if [ $REBUILD -eq 1 ] || [ ! -s "$OUT/$name.gds" ]; then
        echo "row_census: building $name"
        MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" -w /work "$IMAGE" \
            python3 "$(rel "$HERE/lvs_chip/probe/row_probe.py")" \
            --gds "$(rel "$CDLS/$cell.gds")" --cell "$cell" $args \
            --out "$(rel "$OUT/$name.gds")" 2>&1 | sed 's/^/row_census:   /' \
            || { echo "row_census: building $name failed" >&2; exit 2; }
    fi
    [ -f "$OUT/$name.gds" ] || { echo "row_census: no $OUT/$name.gds" >&2; exit 2; }
    [ -f "$WORK/evidence_census/row-$name/census.txt" ] && continue
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
    ( bash "$HERE/lvs_chip_census.sh" "row-$name" --stage pre-align \
        --layout "build/lvs_chip/row_census/$name.gds" --netlist "build/lvs_chip/cell_census/$cell.cdl" \
        --topcell row_probe --threads 1 --deck-out "build/lvs_chip/deck_row_$name" \
        > "$OUT/row-$name.log" 2>&1 ) &
done <<< "$LAYOUTS"
wait

# Report. Expected devices come from the layout row above (placements x the cell's own extracted
# count, which build/lvs_chip_cell_census.sh has already shown equals its CDL count).
"$PY" - "$WORK/evidence_census" "$OUT/report.tsv" <<PY
import os, sys
ev, out = sys.argv[1], sys.argv[2]
rows = [l.split('|') for l in """$LAYOUTS""".strip().splitlines()]
w = ['%-22s %6s %6s %6s %6s' % ('layout', 'expect', 'dev', 'pfet', 'nfet')]
bad = 0
for name, _cell, _args, expected in rows:
    p = os.path.join(ev, 'row-' + name, 'census.txt')
    dev = pf = nf = '-'
    if os.path.exists(p):
        for l in open(p):
            if 'pre-align layout flat' in l:
                dev = l.split('devices=')[1].split()[0]
            if 'pre-align layout classes' in l:
                for t in l.split():
                    if t.startswith('pfet_05v0='):
                        pf = t.split('=')[1]
                    if t.startswith('nfet_05v0='):
                        nf = t.split('=')[1]
    if str(dev) != expected:
        bad += 1
    w.append('%-22s %6s %6s %6s %6s' % (name, expected, dev, pf, nf))
text = '\n'.join(w) + '\n'
open(out, 'w', newline='').write(text)
print(text, end='')
print(f"row_census: {bad} layout(s) differ from placements x cell devices")
PY
