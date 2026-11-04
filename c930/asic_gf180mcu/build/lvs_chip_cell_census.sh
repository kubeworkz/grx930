#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_chip_cell_census.sh -- extract the die's standard cells one at a time and weight each result by
# how often the DEF places it, to say which cell types lose transistors.
#
# WHY THIS EXISTS
#
#   build/lvs_chip_census.sh measured the die: extraction delivers 171,109 devices where the
#   schematic CDL has 691,010, and the deck's combine pass only takes that to 128,798. The shortfall
#   is therefore upstream of the comparison and outside the combine, but the die netlist is flat and
#   has no per-cell breakdown, so it cannot name the cells responsible.
#
#   Each standard cell is a leaf cell, so it can be cut out of the streamed die and extracted on its
#   own. Doing that for every placed type and multiplying by the DEF's placement count gives a
#   per-cell reconciliation of the die: sum(placements x extracted) says what the die should have
#   delivered if every cell extracts as well in place as it does in isolation, and comparing each
#   cell with its own .SUBCKT in the CDL says whether the cell itself is short.
#
#   Counts come from the same censused deck, in the same tiling mode, as the die run
#   (build/lvs_chip_census.sh), before and after `combine_devices`. That matters: a cell that
#   extracts full but collapses under combine is a different defect from one that never extracts.
#
#   Usage (from c930/asic_gf180mcu):
#     bash build/lvs_chip_cell_census.sh              # the 12 most-placed types (95.7 % of devices)
#     bash build/lvs_chip_cell_census.sh --cells 20
#     bash build/lvs_chip_cell_census.sh --all        # all 34 placed types
#     bash build/lvs_chip_cell_census.sh --all --jobs 4   # four cells at a time (default 4)
#
#   Writes build/lvs_chip/cell_census/{<cell>.gds,<cell>.cdl,population.tsv} and
#   build/lvs_chip/evidence_cell_census/{cell_census.tsv,cell-<short>/...}. The per-cell runs reuse
#   build/lvs_chip_census.sh, so each one has its own klayout.log and census.txt.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=$HERE/lvs_chip
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
IMAGE=${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}
DEF=$WORK/../grx930_test_chip.def
CDL=$WORK/grx930_test_chip.cdl
GDS=$WORK/stream_out.gds

N=12
ALL=0
THREADS=1
JOBS=4

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --cells)   N=$2; shift 2 ;;
        --cells=*) N=${1#*=}; shift ;;
        --all)     ALL=1; shift ;;
        --threads) THREADS=$2; shift 2 ;;
        --threads=*) THREADS=${1#*=}; shift ;;
        --jobs)    JOBS=$2; shift 2 ;;
        --jobs=*)  JOBS=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "cell_census: unknown argument: $1" >&2; exit 2 ;;
    esac
done
case $N in ''|*[!0-9]*) echo "cell_census: --cells must be a positive integer" >&2; exit 2 ;; esac
case $JOBS in ''|*[!0-9]*) echo "cell_census: --jobs must be a positive integer" >&2; exit 2 ;; esac

PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "cell_census: no python3/python on PATH" >&2; exit 2; }

for f in "$DEF" "$CDL" "$GDS"; do
    [ -f "$f" ] || { echo "cell_census: missing $f" >&2; exit 2; }
done
[ -f "$WORK/deck_pruned/gf180mcu.lvs" ] || {
    echo "cell_census: no pruned deck (run build/lvs_chip_prune_deck.sh)" >&2; exit 2; }

OUT=$WORK/cell_census
EV=$WORK/evidence_census
SUMMARY=$WORK/evidence_cell_census
mkdir -p "$OUT" "$EV" "$SUMMARY"

# --- the placed population ---------------------------------------------------------------------
# placements from COMPONENTS, device cards from the cell's own .SUBCKT in the same CDL the die is
# compared against. Both are read with the same conventions as tools/lvs_chip/cell_lvs.py.
"$PY" - "$DEF" "$CDL" "$OUT/population.tsv" <<'PY' || exit 2
import collections, re, sys

def comps(path):
    out, section = [], False
    for line in open(path, errors='replace'):
        s = line.strip()
        if s.startswith('COMPONENTS'):
            section = True; continue
        if s.startswith('END COMPONENTS'):
            break
        if not section:
            continue
        m = re.match(r"-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)", s)
        if m:
            out.append(m.group(2))
    return out

def cdl_devices(path):
    dev, cur = collections.Counter(), None
    for line in open(path, errors='replace'):
        s = line.strip()
        m = re.match(r"\.SUBCKT\s+(\S+)", s, re.I)
        if m:
            cur = m.group(1); continue
        if re.match(r"\.ENDS", s, re.I):
            cur = None; continue
        if cur and re.match(r"[MmRrCcDdQq]", s):
            dev[cur] += 1
    return dev

place = collections.Counter(comps(sys.argv[1]))
dev = cdl_devices(sys.argv[2])
missing = sorted(set(place) - set(dev))
if missing:
    sys.exit(f"cell_census: {len(missing)} placed cells have no .SUBCKT: {missing[:3]}")
with open(sys.argv[3], 'w', newline='') as fh:
    fh.write("cell\tplacements\tcdl_devices\n")
    for cell, n in place.most_common():
        fh.write(f"{cell}\t{n}\t{dev[cell]}\n")
print(f"cell_census: {sum(place.values())} placements over {len(place)} types, "
      f"{sum(n * dev[c] for c, n in place.items())} devices expected from DEF x CDL")
PY

SELECTED=()
while IFS=$'\t' read -r cell places devices; do
    [ "$cell" = cell ] && continue
    SELECTED+=("$cell")
    [ $ALL -eq 0 ] && [ ${#SELECTED[@]} -ge "$N" ] && break
done < "$OUT/population.tsv"
[ ${#SELECTED[@]} -gt 0 ] || { echo "cell_census: empty population" >&2; exit 2; }

echo "cell_census: cutting ${#SELECTED[@]} cell types out of ${GDS#"$ROOT"/}"

# --- cut each cell and its .SUBCKT ---------------------------------------------------------------
MOUNT=$ROOT
if command -v cygpath >/dev/null 2>&1; then MOUNT=$(cygpath -m "$ROOT"); fi
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) echo "cell_census: $1 is outside the repository" >&2; return 2 ;; esac; }
CELLS=$(printf '%s,' "${SELECTED[@]}"); CELLS=${CELLS%,}

MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" -w /work "$IMAGE" \
    python3 "$(rel "$HERE/../tools/lvs_chip/cell_lvs.py")" \
    --gds "$(rel "$GDS")" --cdl "$(rel "$CDL")" --cells "$CELLS" --out "$(rel "$OUT")" \
    2>&1 | sed 's/^/cell_census:   /'
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "cell_census: cutting failed" >&2; exit 2; }

# --- one census run per cell ---------------------------------------------------------------------
i=0
for cell in "${SELECTED[@]}"; do
    i=$((i + 1))
    short=${cell##*__}
    name=cell-$short
    if [ -f "$EV/$name/census.txt" ]; then
        echo "cell_census: [$i/${#SELECTED[@]}] $short already censused"
        continue
    fi
    echo "cell_census: [$i/${#SELECTED[@]}] $short"
    # One deck copy per cell: build/lvs_chip_census.sh rewrites its deck directory before each run,
    # so sharing one across parallel cells would race.
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
    bash "$HERE/lvs_chip_census.sh" "$name" \
        --layout "$OUT/$cell.gds" --netlist "$OUT/$cell.cdl" --topcell "$cell" \
        --deck-out "$WORK/deck_cell_$short" \
        --threads "$THREADS" > "$SUMMARY/$name.driver.log" 2>&1 &
done
wait

bad=0
for cell in "${SELECTED[@]}"; do
    name=cell-${cell##*__}
    if [ ! -f "$EV/$name/census.txt" ]; then
        echo "cell_census: ${cell##*__} produced no census (see ${SUMMARY##"$ROOT"/}/$name.driver.log)" >&2
        tail -5 "$SUMMARY/$name.driver.log" >&2
        bad=1
    fi
done
[ $bad -eq 0 ] || exit 2

# --- reconcile -----------------------------------------------------------------------------------
# Weighted rows: what this cell type contributes to the die if it extracts as it does in isolation.
"$PY" - "$OUT/population.tsv" "$EV" "$SUMMARY/cell_census.tsv" <<'PY'
import os, sys

pop, ev, out = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
for line in open(pop):
    p = line.rstrip('\n').split('\t')
    if p[0] == 'cell':
        continue
    cell, places, cdl = p[0], int(p[1]), int(p[2])
    short = cell.split('__')[-1]
    pre = post = None
    path = os.path.join(ev, 'cell-' + short, 'census.txt')
    if os.path.exists(path):
        for l in open(path):
            f = l.split()
            if 'layout' not in f or 'flat' not in f:
                continue
            dev = [t for t in f if t.startswith('devices=')]
            if not dev:
                continue
            n = int(dev[0].split('=')[1])
            if 'pre-combine' in f:
                pre = n
            if 'post-combine' in f:
                post = n
    rows.append((cell, places, cdl, pre, post))

rows.sort(key=lambda r: -r[1])
w = ['%-34s %7s %6s %6s %6s %8s %9s %8s' %
     ('cell', 'places', 'cdl', 'pre', 'post', 'd_pre', 'w_cdl', 'w_pre')]
tp = tc = tpre = tpost = 0
for cell, places, cdl, pre, post in rows:
    if pre is None:
        w.append('%-34s %7d %6d %6s %6s %8s %9d %8s' % (cell.split('__')[-1], places, cdl, '-', '-', '-', places * cdl, '-'))
        tp += places; tc += places * cdl
        continue
    w.append('%-34s %7d %6d %6d %6d %+8d %9d %8d' %
             (cell.split('__')[-1], places, cdl, pre, post, pre - cdl, places * cdl, places * pre))
    tp += places; tc += places * cdl; tpre += places * pre; tpost += places * post
w.append('%-34s %7d %6s %6s %6s %8s %9d %8d' % ('TOTAL', tp, '', '', '', '', tc, tpre))
text = '\n'.join(w) + '\n'
open(out, 'w', newline='').write(text)
print(text, end='')
print(f"weighted: CDL {tc}, extracted pre-combine {tpre}, post-combine {tpost}; "
      f"die measured 171,109 pre / 128,798 post")
PY
