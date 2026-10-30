#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_chip_probe_deck.sh -- a copy of the pruned deck whose phase boundaries write to their own file.
#
# WHY THIS EXISTS, AND WHY IT CHANGED
#
#   A chip run reaches the comparison section and then prints nothing for hours. The first version
#   of this script put `logger.info('PROBE: before X')` in front of each statement of the
#   comparison prologue and read the answer off the deck's own log. That answer does not exist:
#   in build/lvs_chip/run_chip_stream/klayout.log the last line is
#
#     2026-10-19 16:19:29 +0000: ... : Starting GF180 LVS comparison section
#
#   and the very next marker the deck writes -- `PROBE: before align` -- never appeared, although
#   the only statement between them is `connect_implicit('*') if IMPLICIT_CONNECT` and the same
#   log says `Selected IMPLICIT_CONNECT option: false`. Either the statement was skipped and the
#   marker after it went missing, or the log's writes are not reaching the file. A marker that can
#   be lost cannot bound a phase, and "the wall is align" was read off the source order, not off a
#   measurement. This version stops depending on the logger.
#
#   probe() below opens its own file, sets sync, writes one line and flushes. A marker that is
#   absent from that file means the statement before it had not returned when the run stopped, and
#   the last line present names that statement. The path is -rd probe_log=<file> if given, else
#   probe.log in the report's directory, else ./lvs_probe.log.
#
# WHAT IT WRITES
#
#   build/lvs_chip/deck_probe/   deck_pruned plus, around every statement of the comparison
#                                prologue and every statement of substrate_connections.lvs, a
#                                flushed `before`/`after <elapsed> s` pair -- and one marker on
#                                the comparison banner itself, and one around connect_implicit.
#                                Under -rd net_only=true the banner also dumps the extracted
#                                netlist and returns, because the deck's own NET_ONLY return is
#                                after `align` and would wait for the aligner. Nothing else
#                                changes: the markers only write.
#
#   Run it the same way as the pruned deck:
#     bash build/lvs_chip_probe_deck.sh
#     bash build/lvs_chip_check.sh --no-reconstruct --mode deep --threads 4 \
#          --deck build/lvs_chip/deck_probe/gf180mcu.lvs
#   then read build/lvs_chip/run_chip_stream/probe.log while it runs, not only after.
#
#   This copy is for diagnosis, not for a verdict: it is not the vendor deck and not the pruned
#   one. A run through it answers "where did the hours go", and its netlist still has to be
#   checked -- a deck that only writes markers cannot change a verdict, but the rule file it runs
#   is nevertheless one more thing that has been edited, so a PASS from it is not the chip's PASS.
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
"""Insert the flushed-probe helper and its markers as their own lines."""
import os
import sys

dst = sys.argv[1]

SINK = r'''

#=== PROBE SINK (inserted by build/lvs_chip_probe_deck.sh) =====================================
# The deck's own logger is not trusted to bound a phase: a marker written through it was the one
# line missing from the last chip run's log. This file is opened by the deck, synced and flushed
# per line, so `before X` with no `after X` means X had not returned.
$plog_path = if $probe_log && !$probe_log.to_s.empty?
  $probe_log.to_s
elsif $report && !$report.to_s.empty?
  File.join(File.dirname($report.to_s), 'probe.log')
else
  File.expand_path('lvs_probe.log')
end
$plog_io = File.open($plog_path, 'a')
$plog_io.sync = true
def probe(msg)
  $plog_io.puts("#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S')} #{msg}")
  $plog_io.flush
end
probe("deck start input=#{$input} topcell=#{$topcell} report=#{$report}")
#=== end of probe sink ==========================================================================
'''

# (file, the statement's own line, label). The line is matched on its stripped text and must
# appear exactly once: a marker that lands inside a comment or next to two calls would make the
# probe lie about what it measured.
plan = [
    # The one statement between the comparison banner and the first named step, and the reason
    # this version exists.
    ('gf180mcu.lvs', "connect_implicit('*') if IMPLICIT_CONNECT", 'connect_implicit'),
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


def lines_of(rel):
    full = os.path.join(dst, rel)
    if full not in files:
        with open(full, encoding='utf-8') as fh:
            files[full] = fh.read().split('\n')
    return full, files[full]


def insert_after(rel, anchor, text, what):
    full, lines = lines_of(rel)
    hits = [i for i, line in enumerate(lines) if line.strip() == anchor]
    if len(hits) != 1:
        sys.exit(f"probe: CANNOT-RUN {what} anchor {anchor!r} matches {len(hits)} lines in {rel}, expected 1")
    lines[hits[0] + 1:hits[0] + 1] = text


# The helper, immediately after the runset's own "starting" line so it is defined before any
# marker and before source() reads the layout.
insert_after('gf180mcu.lvs',
             'logger.info("Starting running GF180MCU Klayout LVS runset on #{$input}")',
             SINK.split('\n'), 'the probe sink')

# One marker on the banner, so the last silent stretch before the prologue is bounded too -- and,
# with -rd net_only=true, the netlist dump the offline bench needs. The deck's own NET_ONLY return
# sits after `align`, so --net-only on the pruned deck waits for the aligner to return before it
# writes a netlist, i.e. it waits for exactly the thing under measurement. This block writes it
# before that, and only under the switch, so a normal run's behaviour is unchanged.
insert_after('gf180mcu.lvs',
             "logger.info('Starting GF180 LVS comparison section')",
             ["probe('comparison section')",
              "if $net_only",
              "  netlist",
              "  probe('netlist written before align')",
              "  return",
              "end"], 'the comparison banner')

for rel, stmt, label in plan:
    full, lines = lines_of(rel)
    hits = [i for i, line in enumerate(lines) if line.strip() == stmt]
    if len(hits) != 1:
        sys.exit(f"probe: CANNOT-RUN {stmt!r} matches {len(hits)} lines in {rel}, expected 1")
    i = hits[0]
    indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
    before = [
        f"{indent}probe('before {label}')",
        f"{indent}$probe_t0 = Time.now",
    ]
    after = [
        f"{indent}probe(\"after {label} #{{(Time.now - $probe_t0).round(1)}} s\")",
    ]
    lines[i:i] = before
    at = i + len(before) + 1
    lines[at:at] = after
    files[full] = lines

for full, lines in files.items():
    # Only the deck itself gets the end marker: substrate_connections.lvs is included mid-run, so
    # an end marker in it would claim the deck had finished while extraction was still going.
    if os.path.basename(full) == 'gf180mcu.lvs':
        if lines and lines[-1] != '':
            lines.append('')
        lines.append("probe('deck end')")
    with open(full, 'w', encoding='utf-8', newline='') as fh:
        fh.write('\n'.join(lines))

print(f"deck_probe: {len(plan)} statements bounded by flushed markers")
PY

# A probe whose markers are not in the file would look exactly like a fast run, and a sink that is
# missing would make every marker a NameError inside the deck instead of a measurement.
markers=$(grep -ho "probe('before " "$DST/gf180mcu.lvs" "$DST"/rule_decks/substrate_connections.lvs | wc -l | tr -d ' ')
[ "$markers" = 23 ] || {
    echo "probe: FAIL $markers 'before' markers in the copy, expected 23 (13 in the deck, 10 in substrate_connections)" >&2
    exit 1
}
grep -q '^def probe(msg)' "$DST/gf180mcu.lvs" || {
    echo "probe: FAIL the probe sink is not in the deck" >&2; exit 1; }
grep -q '^probe(.comparison section.)$' "$DST/gf180mcu.lvs" || {
    echo "probe: FAIL the comparison-banner marker is not in the deck" >&2; exit 1; }

echo "deck_probe: $DST/gf180mcu.lvs"
echo "  markers: 23 statements + the comparison banner, written to <report dir>/probe.log"
echo "  run: bash build/lvs_chip_check.sh --no-reconstruct --mode deep --threads 4 \\"
echo "         --deck build/lvs_chip/deck_probe/gf180mcu.lvs"
