#!/usr/bin/env bash
# lvs_chip_probe_deck.sh -- a copy of the pruned deck with a log line in front of every phase
# boundary, so the silent part of the chip run stops being silent.
#
# WHY THIS EXISTS
#
#   Two full chip runs have now spent hours in a phase that prints nothing. Measured, from the
#   runs' own logs:
#
#     build/lvs_chip/pruned_tiling_attempt1.klayout.log   tiling
#         00:06:20  Starting GF180MCU LVS runset
#         00:21:42  SKIP device extraction (efuse -- the last extraction include)
#         (nothing for 2 h 52 min, ~100 % CPU, 4.5 of 5.8 GiB, until Docker Desktop died)
#     build/lvs_chip/run_chip_stream/klayout.log          deep
#         03:43:58  the same line, the same silence after it
#
#   The next line the deck itself would print is 'Starting GF180 LVS comparison section'. It never
#   appeared, so the time is spent between the last `%include` and that banner -- that is,
#   in substrate_connections.lvs and in the deck's own comparison prologue (`align`,
#   make_top_level_pins, simplify, combine_devices, purge_nets, purge, max_res, min_caps), none of
#   which logs anything. Which of those statements it is cannot be read off the source; it has to
#   be measured. This script makes the copy that measures it.
#
# WHAT IT MEASURED (2026-10-19, tiling, --threads 4)
#
#   Not the substrate section. All ten of its statements finish in under a second (worst:
#   sub.andnot(isosub) 0.8 s), and the banner is printed 4 s after the efuse skip, 13 min 28 s into
#   the run -- against two 1-thread runs that never printed it in 2 h 51 min and 1 h 46 min. The
#   run then sits in `align`, the first statement after the banner, which is where it was still
#   working when the measurement was written down. See Claude outputs/stream_out_fix.md §4c.
#
# WHAT IT WRITES
#
#   build/lvs_chip/deck_probe/   deck_pruned plus one `logger.info('PROBE: ...')` line before each
#                                of the statements named above, and one after substrate_connections
#                                and after each of them, so a phase is bounded by the markers that
#                                surround it. Nothing else changes: the markers only print.
#
#   Run it the same way as the pruned deck:
#     bash build/lvs_chip_probe_deck.sh
#     bash build/lvs_chip_check.sh --no-reconstruct --mode deep \
#          --deck build/lvs_chip/deck_probe/gf180mcu.lvs
#
#   This copy is for diagnosis, not for a verdict: it is not the vendor deck and not the pruned
#   one. A run through it answers "where did the hours go", and its netlist still has to be
#   checked -- a deck that only prints cannot change a verdict, but the rule file it runs is
#   nevertheless one more thing that has been edited, so a PASS from it is not the chip's PASS.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$HERE/lvs_chip/deck_pruned
DST=$HERE/lvs_chip/deck_probe

[ -f "$SRC/gf180mcu.lvs" ] || {
    echo "probe: CANNOT-RUN no pruned deck at $SRC/gf180mcu.lvs -- run build/lvs_chip_prune_deck.sh first" >&2
    exit 2
}

PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "probe: CANNOT-RUN no python3/python on PATH" >&2; exit 2; }

rm -rf "$DST"
mkdir -p "$DST/rule_decks" || exit 2
cp "$SRC/gf180mcu.lvs" "$DST/gf180mcu.lvs" || exit 2
cp "$SRC"/rule_decks/*.lvs "$DST/rule_decks/" || exit 2

"$PY" - "$DST" <<'PY' || exit 2
"""Insert PROBE markers as their own lines around each named statement."""
import os
import sys

dst = sys.argv[1]

# (file, the statement's own line, label). The line is matched on its stripped text and must
# appear exactly once: a marker that lands inside a comment (which is what happened when this was
# a substring insert) or next to two calls would make the probe lie about what it measured.
plan = [
    # substrate_connections.lvs: the whole file, statement by statement.
    ('rule_decks/substrate_connections.lvs', '(sub_iso, sub_regular) = sub.andnot(isosub)', 'sub.andnot(isosub)'),
    ('rule_decks/substrate_connections.lvs', 'connect(sub, sub_iso)', 'connect(sub, sub_iso)'),
    ('rule_decks/substrate_connections.lvs', 'connect(sub, sub_regular)', 'connect(sub, sub_regular)'),
    ('rule_decks/substrate_connections.lvs', 'connect(sub_iso, isosub)', 'connect(sub_iso, isosub)'),
    ('rule_decks/substrate_connections.lvs', "connect_global(sub_regular, 'SUB')", 'connect_global(sub SUB)'),
    ('rule_decks/substrate_connections.lvs', '(ptap_iso, ptap_regular) = ptap.andnot(isosub)', 'ptap.andnot(isosub)'),
    ('rule_decks/substrate_connections.lvs', 'connect(ptap, ptap_iso)', 'connect(ptap, ptap_iso)'),
    ('rule_decks/substrate_connections.lvs', 'connect(ptap, ptap_regular)', 'connect(ptap, ptap_regular)'),
    ('rule_decks/substrate_connections.lvs', 'connect(ptap_iso, isosub)', 'connect(ptap_iso, isosub)'),
    ('rule_decks/substrate_connections.lvs', "connect_global(ptap_regular, 'SUB')", 'connect_global(ptap SUB)'),
    # the deck's own comparison prologue, in source order.
    ('gf180mcu.lvs', 'align', 'align'),
    ('gf180mcu.lvs', 'netlist.make_top_level_pins if TOP_LVL_PINS', 'netlist.make_top_level_pins'),
    ('gf180mcu.lvs', 'schematic.make_top_level_pins if TOP_LVL_PINS', 'schematic.make_top_level_pins'),
    ('gf180mcu.lvs', 'netlist.simplify if SIMPLIFY', 'netlist.simplify'),
    ('gf180mcu.lvs', 'schematic.simplify if SIMPLIFY', 'schematic.simplify'),
    ('gf180mcu.lvs', 'netlist.combine_devices if COMBINE', 'netlist.combine_devices'),
    ('gf180mcu.lvs', 'schematic.combine_devices if COMBINE', 'schematic.combine_devices'),
    ('gf180mcu.lvs', 'netlist.purge_nets if PURGE_NETS', 'netlist.purge_nets'),
    ('gf180mcu.lvs', 'netlist.purge if PURGE', 'netlist.purge'),
    ('gf180mcu.lvs', 'max_res(1e7)', 'max_res'),
    ('gf180mcu.lvs', 'min_caps(1e-16)', 'min_caps'),
    ('gf180mcu.lvs', 'result = compare', 'compare'),
]

files = {}
for path, stmt, label in plan:
    full = os.path.join(dst, path)
    if full not in files:
        with open(full, encoding='utf-8') as fh:
            files[full] = fh.read().split('\n')
    lines = files[full]
    hits = [i for i, line in enumerate(lines) if line.strip() == stmt]
    if len(hits) != 1:
        sys.exit(f"probe: CANNOT-RUN {stmt!r} matches {len(hits)} lines in {path}, expected 1")
    i = hits[0]
    indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
    marker = [
        f"{indent}logger.info('PROBE: before {label}')",
        f"{indent}$probe_t0 = Time.now",
    ]
    done = [
        f"{indent}logger.info(\"PROBE: after {label} #{{(Time.now - $probe_t0).round(1)}} s\")",
    ]
    lines[i:i] = marker
    # the statement is now at i + len(marker)
    after = i + len(marker) + 1
    lines[after:after] = done
    files[full] = lines

counted = {}
for full, lines in files.items():
    with open(full, 'w', encoding='utf-8', newline='') as fh:
        fh.write('\n'.join(lines))
    counted[os.path.relpath(full, dst)] = sum(1 for line in lines if "logger.info('PROBE: before" in line)

print(f"deck_probe: {sum(counted.values())} markers inserted")
for path in sorted(counted):
    print(f"deck_probe:   {path}  {counted[path]}")
PY

# A probe whose markers are not in the file would look exactly like a fast run.
markers=$(grep -c "logger.info('PROBE: before" "$DST/gf180mcu.lvs" "$DST"/rule_decks/substrate_connections.lvs | awk -F: '{s+=$2} END {print s+0}')
if [ "$markers" != 22 ]; then
    echo "probe: FAIL $markers markers in the copy, expected 22 (12 in the deck, 10 in substrate_connections)" >&2
    exit 1
fi

echo "deck_probe: $DST/gf180mcu.lvs"
echo "  run: bash build/lvs_chip_check.sh --no-reconstruct --mode deep --deck build/lvs_chip/deck_probe/gf180mcu.lvs"
