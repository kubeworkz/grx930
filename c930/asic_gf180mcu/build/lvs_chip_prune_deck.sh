#!/usr/bin/env bash
# lvs_chip_prune_deck.sh -- make a deck copy that does not pay for device classes the die has no
# geometry for, and prove the skip on the run's own log.
#
# WHY THIS EXISTS
#
#   The vendor deck extracts a device class by handing the tiling processor its body region ('R'),
#   its contacts ('C') and its bulk ('W'). When the body is empty the class cannot produce a
#   device -- but the processor still walks every tile and every contact in it, and on the
#   grx930 die that costs hours per class. Measured from the log of the unmodified run
#   (build/lvs_chip/run_chip_stream_attempt1/klayout.log, timestamps are the deck's own):
#
#       03:21:50  Extracting PPOLYF_U NWELL device
#       03:27:34  Extracting PPOLYF_S_DW device as PPOLYF_S          (+6 min)
#       07:12:49  Extracting PPOLYF_U_1K_DW device as PPOLYF_U_1K     (+223 min)
#       08:14:33  Extracting PPOLYF_U_1K_6p0 NWELL device             (+61 min)
#
#   and the same run's own layer report says why those bodies are empty: `res_mk has 0 polygons`,
#   `resistor has 0 polygons`, `cap_mk`, `mos_cap_mk`, `efuse_mk`, `drc_bjt`, `diode_mk` -- all 0.
#   The die is a standard-cell design; it has no poly resistors, no MIM, no eFuse and no diodes.
#   The extracted netlist is therefore unchanged by skipping those calls, and this script makes
#   that skip measurable rather than argued: the guard logs the body region's polygon count in the
#   LVS log itself, next to the deck's own `res_mk has N polygons` line.
#
# WHAT IT WRITES
#
#   build/lvs_chip/deck_pruned/   a copy of gf180mcu.lvs and rule_decks/ (184 KiB, not the 79 MiB
#                                 `testing/` fixtures) with three mechanical changes:
#                                   * a `guarded_extract_devices` definition inserted after the
#                                     logger, which skips a call whose 'R' region is empty and
#                                     logs the count;
#                                   * every `extract_devices(` in the *_extraction.lvs files
#                                     renamed to `guarded_extract_devices(` (151 call sites);
#                                   * one `threads(($threads || 1).to_i)` line after the run_mode
#                                     `case` (so it reaches every mode), because the deck never
#                                     sets the engine's thread count and the chip runs are
#                                     single-core (~100 % of one core for hours) on a 6-core VM.
#                                     `threads` is a DSL directive -- measured, not assumed:
#                                     build/lvs_chip/probe/lvs_dsl_probe.lvs answers `threads? true`.
#                                     Measured effect: the same tiled work that outlived 3 h on
#                                     one core reaches the comparison in 13 min on four. With no
#                                     switch the value is 1, so the default behaviour is the
#                                     vendor's.
#                                 Nothing else in the deck is touched -- not the derivations, not
#                                 the connectivity, not the comparison.
#
#   The copy is generated, not committed: `git diff` on the tree stays clean and the three
#   changes above are the whole of it.
#
#   bash build/lvs_chip_prune_deck.sh
#   bash build/lvs_chip_check.sh --no-reconstruct --deck build/lvs_chip/deck_pruned/gf180mcu.lvs
#   bash build/lvs_chip_check.sh --no-reconstruct --deck build/lvs_chip/deck_pruned/gf180mcu.lvs \
#        --threads 3
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
SRC=$ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs
DST=$HERE/lvs_chip/deck_pruned

[ -f "$SRC/gf180mcu.lvs" ] || { echo "prune: CANNOT-RUN no deck at $SRC/gf180mcu.lvs" >&2; exit 2; }

# The Store flavour of `python3` is a stub that only prints a message; take the first
# interpreter that actually runs, as build/lvs_check.sh does.
PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "prune: CANNOT-RUN no python3/python on PATH" >&2; exit 2; }

rm -rf "$DST"
mkdir -p "$DST/rule_decks" || exit 2
cp "$SRC/gf180mcu.lvs" "$DST/gf180mcu.lvs" || exit 2
cp "$SRC"/rule_decks/*.lvs "$DST/rule_decks/" || exit 2

# The guard. Ruby methods cannot see the script's locals, so the logger is taken by reference into
# a global; that is the only reason the global exists.
read -r -d '' GUARD <<'RUBY'
#=== EMPTY-BODY GUARD (inserted by build/lvs_chip_prune_deck.sh) ===============================
#
#   A device class whose body region 'R' is empty cannot produce a device. In tiling mode the
#   processor still intersects every tile's contacts for it, and on this die one such call cost
#   223 minutes (build/lvs_chip/run_chip_stream_attempt1/klayout.log). This wrapper measures the
#   body and returns without calling the extractor when it is empty, so the skip is a number in
#   the log -- the same log that reports `res_mk has 0 polygons` -- and not an assumption.
#
$lvs_logger = logger

def guarded_extract_devices(*args)
  layers = args[1]
  body = layers.is_a?(Hash) ? layers['R'] : nil
  # `RBA::Region` has `is_empty?`, not `empty?` (measured: a probe region answers
  # respond_to?(:empty?) -> false, and an earlier guard written against `empty?` silently
  # forwarded every call -- 0 skips in a 20-minute run).
  if body && body.respond_to?(:is_empty?) && body.is_empty?
    $lvs_logger.info("SKIP device extraction: body region 'R' has 0 polygons, so no device can be extracted")
    return
  end
  extract_devices(*args)
end
#=== end of guard =============================================================================
RUBY

# Insert the guard after the logger setup (before the FILE SETUP banner) so that the `%include`s
# below, which are inlined into this file, resolve the renamed calls to it.
"$PY" - "$DST/gf180mcu.lvs" "$GUARD" <<'PY' || exit 2
import sys
path, guard = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
anchor = "#================================================\n#----------------- FILE SETUP -------------------"
if anchor not in text:
    sys.exit("prune: CANNOT-RUN the deck has no FILE SETUP banner to insert the guard before")
if 'EMPTY-BODY GUARD' in text:
    sys.exit("prune: the guard is already in the deck")
text = text.replace(anchor, guard.rstrip() + "\n\n" + anchor, 1)
open(path, 'w', encoding='utf-8', newline='').write(text)
PY

# Threads. The deck never says how many threads to use, so the engine uses one; this is a
# performance setting, so with no switch it stays 1. The call goes after the run_mode `case` so it
# applies to `deep` and `flat` too: the tiling runs are where it was measured (13 min to the
# comparison instead of >3 h, Claude outputs/stream_out_fix.md section 4c), and deep mode is the
# mode where a hierarchical netlist might make `align` tractable, so it must not be the one mode
# the switch cannot reach.
THREADS_BLOCK='
#=== LVS THREADS (inserted by build/lvs_chip_prune_deck.sh) =======================================
threads(($threads || 1).to_i) if respond_to?(:threads)
#=== end of LVS threads ==========================================================================
'
"$PY" - "$DST/gf180mcu.lvs" "$THREADS_BLOCK" <<'PY' || exit 2
import sys
path, block = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
anchor = "  logger.info('flat  mode is enabled.')\nend\n"
if text.count(anchor) != 1:
    sys.exit("prune: CANNOT-RUN the deck's run_mode case end was not found exactly once")
text = text.replace(anchor, anchor + block, 1)
open(path, 'w', encoding='utf-8', newline='').write(text)
PY

# Rename the call sites. Only the extraction files call extract_devices; the derivations and the
# connectivity setup must keep the deck's own calls untouched.
calls=0
for f in "$DST"/rule_decks/*_extraction.lvs; do
    n=$(grep -c 'extract_devices(' "$f" || true)
    "$PY" - "$f" <<'PY' || exit 2
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
# `guarded_extract_devices(` must not be renamed twice; the negative lookbehind is not needed
# because the source has no guarded call yet, but the pass is idempotent by construction.
t = t.replace('extract_devices(', 'guarded_extract_devices(')
open(p, 'w', encoding='utf-8', newline='').write(t)
PY
    calls=$((calls + n))
done

# A rename that did not take, or a deck that kept a bare call next to an empty body, would look
# exactly like a fast run. Check both before saying the copy is usable.
left=$(grep -c '^\s*extract_devices(' "$DST"/rule_decks/*_extraction.lvs 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
guarded=$(grep -ho 'guarded_extract_devices(' "$DST"/rule_decks/*_extraction.lvs | wc -l | tr -d ' ')
if [ "$left" != 0 ] || [ "$guarded" != "$calls" ]; then
    echo "prune: FAIL $left bare call(s) left, $guarded guarded of $calls renamed" >&2
    exit 1
fi
grep -q 'def guarded_extract_devices' "$DST/gf180mcu.lvs" || {
    echo "prune: FAIL the guard is not in the deck" >&2; exit 1; }
grep -q '^threads(($threads || 1).to_i)' "$DST/gf180mcu.lvs" || {
    echo "prune: FAIL the threads line is not in the deck" >&2; exit 1; }

echo "deck_pruned: $calls extraction call sites guarded, 0 left bare"
echo "deck_pruned: threads from -rd threads=<n> for every run mode (default 1)"
echo "deck_pruned: $DST/gf180mcu.lvs"
echo "  run: bash build/lvs_chip_check.sh --no-reconstruct --deck build/lvs_chip/deck_pruned/gf180mcu.lvs"
