#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_chip_census.sh -- attribute the die's device shortfall between extraction and the deck's
# `combine_devices` pass by counting both netlists on either side of that call.
#
# WHY THIS EXISTS
#
#   evidence_bounds/12300/xref.txt: at comparison time the layout netlist carries 128,798 devices
#   and the schematic 691,010 -- 18.6 % -- and the loss is not uniform (PFET 24.4 %, NFET 12.8 %,
#   while the schematic is exactly 1:1). Both sides ran with combine=true (tools/klayout_lvs.py
#   DECK_SWITCHES forces it; the deck's own default is false), so the report cannot say whether
#   extraction never produced those devices or `combine_devices` merged them away.
#
#   The deck calls `netlist.combine_devices` / `schematic.combine_devices` once, between `align`
#   and `compare`. A census immediately before and after that call separates the two explanations
#   on one extraction pass, from the same GDS and CDL, with every other switch identical to the
#   12300 run: pre-combine = what extraction delivered, post-combine = what the comparer was given.
#
# WHAT IT DOES
#
#   * copies build/lvs_chip/deck_pruned/ to build/lvs_chip/deck_census/ and inserts a census block
#     around the COMBINE_DEVICE section plus `exit!(0)` after it, so the run stops before the
#     comparison: no lvsdb, no 176 GB netlist dump, no comparer;
#   * counts devices per circuit and per device class, hierarchically and flattened, on both
#     netlists, before and after combine;
#   * writes build/lvs_chip/evidence_census/<name>/{klayout.log,census.txt,config}.
#
#   The run uses the pruned deck because that is what the 12300 run used; `--deck-src` can point at
#   any other deck directory that has gf180mcu.lvs beside rule_decks/.
#
#   bash build/lvs_chip_census.sh die-combine --threads 8
#   bash build/lvs_chip_census.sh die-pre-align --stage pre-align --threads 8
#   bash build/lvs_chip_census.sh smoke --layout build/lvs_chip/probe/clkinv_probe.gds \
#        --netlist build/lvs_chip/probe/clkinv_probe.cdl --topcell clkinv_probe --threads 1
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=$HERE/lvs_chip
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
IMAGE=${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}

NAME=die-combine
THREADS=8
COMBINE=true
STAGE=combine
LAYOUT=$WORK/stream_out.gds
SCHEMATIC=$WORK/grx930_test_chip.cdl
TOPCELL=grx930_test_chip
DECK_SRC=$WORK/deck_pruned
DECK=$WORK/deck_census
OUTROOT=$WORK/evidence_census

# The Store flavour of `python3` is a stub that only prints a message; take the first interpreter
# that actually runs, as build/lvs_chip_prune_deck.sh does.
PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "census: no python3/python on PATH" >&2; exit 2; }

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --threads)    THREADS=$2; shift 2 ;;
        --threads=*)  THREADS=${1#*=}; shift ;;
        --combine)    COMBINE=$2; shift 2 ;;
        --combine=*)  COMBINE=${1#*=}; shift ;;
        --stage)      STAGE=$2; shift 2 ;;
        --stage=*)    STAGE=${1#*=}; shift ;;
        --layout)     LAYOUT=$2; shift 2 ;;
        --layout=*)   LAYOUT=${1#*=}; shift ;;
        --netlist)    SCHEMATIC=$2; shift 2 ;;
        --netlist=*)  SCHEMATIC=${1#*=}; shift ;;
        --topcell)    TOPCELL=$2; shift 2 ;;
        --topcell=*)  TOPCELL=${1#*=}; shift ;;
        --deck-src)   DECK_SRC=$2; shift 2 ;;
        --deck-src=*) DECK_SRC=${1#*=}; shift ;;
        --deck-out)   DECK=$2; shift 2 ;;
        --deck-out=*) DECK=${1#*=}; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "census: unknown argument: $1" >&2; exit 2 ;;
        *)            NAME=$1; shift ;;
    esac
done

case $COMBINE in true|false) ;; *) echo "census: --combine must be true or false" >&2; exit 2 ;; esac
# --deck-out may be given the same relative form as --layout/--out.
case "$DECK" in /*|[A-Za-z]:*) ;; *) DECK=$WORK/${DECK#build/lvs_chip/} ;; esac
case $STAGE in combine|pre-align) ;; *) echo "census: --stage must be combine or pre-align" >&2; exit 2 ;; esac
case $THREADS in ''|*[!0-9]*) echo "census: --threads must be a positive integer" >&2; exit 2 ;; esac

# Relative paths are taken from c930/asic_gf180mcu (the directory the other build scripts use).
for v in LAYOUT SCHEMATIC DECK_SRC OUTROOT; do
    eval "p=\$$v"
    case "$p" in /*|[A-Za-z]:*) ;; *) eval "$v=\$WORK/${p#build/lvs_chip/}";; esac
done
[ -f "$LAYOUT" ]    || { echo "census: no layout at $LAYOUT" >&2; exit 2; }
[ -f "$SCHEMATIC" ] || { echo "census: no schematic at $SCHEMATIC" >&2; exit 2; }
[ -f "$DECK_SRC/gf180mcu.lvs" ] || { echo "census: no deck at $DECK_SRC/gf180mcu.lvs (run build/lvs_chip_prune_deck.sh)" >&2; exit 2; }
[ -d "$DECK_SRC/rule_decks" ]   || { echo "census: $DECK_SRC/rule_decks is missing: the deck expands '# %include'" >&2; exit 2; }

RUN=$OUTROOT/$NAME
if [ -e "$RUN/klayout.log" ]; then
    echo "census: $NAME already has a log: $RUN/klayout.log (pick another name)" >&2; exit 2
fi
mkdir -p "$RUN/bin" "$OUTROOT"

# The deck's logger shells out to `pmap`, which the flow images do not ship; klayout_lvs.py shims it
# the same way. Without it the deck dies before the layout is read.
printf '#!/bin/sh\necho "1234567 000"\n' > "$RUN/bin/pmap"
chmod +x "$RUN/bin/pmap"

# --- the census deck -------------------------------------------------------------------------
rm -rf "$DECK"
mkdir -p "$DECK/rule_decks" || exit 2
cp "$DECK_SRC/gf180mcu.lvs" "$DECK/gf180mcu.lvs" || exit 2
cp "$DECK_SRC"/rule_decks/*.lvs "$DECK/rule_decks/" || exit 2
grep -q 'def target_netlist_if_enabled' "$DECK/gf180mcu.lvs" || {
    echo "census: $DECK_SRC was not made by build/lvs_chip_prune_deck.sh (no netlist-dump switch)" >&2; exit 2; }

read -r -d '' CENSUS <<'RUBY'
#=== DEVICE CENSUS (inserted by build/lvs_chip_census.sh) =====================================
#
#   Counts devices on both netlists immediately before and after the deck's `combine_devices`
#   call. `combine` merges devices; a count that collapses here is the merge, a count that is
#   already low here is extraction. Flattened and hierarchical counts are both printed because the
#   deck's netlists may still be hierarchical at this point (align precedes, flattening is the
#   comparer's job), and only the flattened count is comparable with the schematic's 691,010 in
#   evidence_bounds/12300/xref.txt. The run exits after the post-census: no comparison, no lvsdb,
#   no extracted netlist.
def device_census(label, layout_nl, schematic_nl)
  [['layout', layout_nl], ['schematic', schematic_nl]].each do |side, nl|
    next unless nl
    ncirc = 0
    raw = 0
    subs = 0
    nl.each_circuit do |c|
      ncirc += 1
      c.each_device { raw += 1 }
      c.each_subcircuit { subs += 1 }
    end
    puts "CENSUS #{label} #{side} hierarchy circuits=#{ncirc} devices=#{raw} subcircuits=#{subs} top_circuits=#{nl.top_circuit_count}"
    begin
      flat = nl.flatten
    rescue StandardError => e
      puts "CENSUS #{label} #{side} FLATTEN-FAILED #{e.class}: #{e.message}"
      $stdout.flush
      next
    end
    fcirc = 0
    fdev = 0
    fnets = 0
    best = nil
    bestd = -1
    flat.each_circuit do |c|
      fcirc += 1
      d = 0
      c.each_device { d += 1 }
      fdev += d
      c.each_net { fnets += 1 }
      if d > bestd
        bestd = d
        best = c
      end
    end
    puts "CENSUS #{label} #{side} flat circuits=#{fcirc} devices=#{fdev} nets=#{fnets}"
    if best && bestd > 0
      h = Hash.new(0)
      best.each_device do |dv|
        name = dv.respond_to?(:device_class) && dv.device_class ? dv.device_class.name : '?'
        h[name] += 1
      end
      puts "CENSUS #{label} #{side} classes(top=#{best.name}) " +
           h.sort_by { |k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')

      # Net census by name. Fragment counts are the point: one VDD net in the CDL against N
      # fragments in the layout is the supply partition, and it is invisible in the total.
      names = Hash.new { |hash, k| hash[k] = [0, 0] }
      zero_terms = 0
      net_count = 0
      big = []
      best.each_net do |n|
        net_count += 1
        tc = n.terminal_count
        zero_terms += 1 if tc == 0
        nm = n.name.to_s
        nm = '(unnamed)' if nm.empty?
        entry = names[nm]
        entry[0] += 1
        entry[1] += tc
        big << [tc, nm]
      end
      puts "CENSUS #{label} #{side} netnames nets=#{net_count} zero-terminal=#{zero_terms} " +
           "distinct=#{names.size}"
      ranked = names.sort_by { |nm, v| [-v[0], nm] }.first(8)
      puts "CENSUS #{label} #{side} netnames-top " +
           ranked.map { |nm, v| "#{nm}=#{v[0]}nets/#{v[1]}term" }.join(' ')
      %w[VDD VSS VNW VPW SUB].each do |supply|
        v = names[supply]
        next if v[0].zero?
        puts "CENSUS #{label} #{side} supply #{supply} nets=#{v[0]} terminals=#{v[1]}"
      end
      # The largest nets by terminal count, not by fragment count. A supply that merged into the
      # substrate global is one net with hundreds of thousands of terminals and does not appear in
      # the by-name list above unless the deck gave it that name; this says where the bodies went.
      big.sort_by! { |tc, _| -tc }
      puts "CENSUS #{label} #{side} big-nets " +
           big.first(6).map { |tc, nm| "#{nm.length > 44 ? nm[0, 44] + '…' : nm}=#{tc}term" }.join(' ')
    end
    $stdout.flush
  end
end
#=== end device census ========================================================================

RUBY

read -r -d '' POST <<'RUBY'

device_census('post-combine', netlist, schematic)
$stdout.flush
exit!(0)
RUBY

if [ "$STAGE" = combine ]; then
    "$PY" - "$DECK/gf180mcu.lvs" "$CENSUS" "$POST" <<'PY' || exit 2
import sys
path, pre, post = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding='utf-8', newline='').read()
anchor = ("## COMBINE_DEVICE\n"
          "netlist.combine_devices if COMBINE\n"
          "schematic.combine_devices if COMBINE\n")
if 'DEVICE CENSUS' in text:
    sys.exit("census: the deck already carries a census block")
if text.count(anchor) != 1:
    sys.exit(f"census: the COMBINE_DEVICE section was not found exactly once ({text.count(anchor)})")
replacement = (pre.rstrip() + "\n\ndevice_census('pre-combine', netlist, schematic)\n\n"
               + anchor + post.rstrip() + "\n")
text = text.replace(anchor, replacement, 1)
open(path, 'w', encoding='utf-8', newline='').write(text)
PY
    grep -q "device_census('pre-combine'"  "$DECK/gf180mcu.lvs" || { echo "census: pre-census call not inserted" >&2; exit 2; }
    grep -q "device_census('post-combine'" "$DECK/gf180mcu.lvs" || { echo "census: post-census call not inserted" >&2; exit 2; }
else
    # Before `align`, so that a collapse here is extraction's and a collapse at the combine census
    # is the aligner's. `flatten` on the pre-align hierarchical netlist multiplies instances, which
    # is the number that must be compared with the schematic's 691,010.
    "$PY" - "$DECK/gf180mcu.lvs" "$CENSUS" <<'PY' || exit 2
import sys
path, pre = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8', newline='').read()
anchor = "#=== FLATTEN CELLS ===\nalign\n"
if 'DEVICE CENSUS' in text:
    sys.exit("census: the deck already carries a census block")
if text.count(anchor) != 1:
    sys.exit(f"census: the align anchor was not found exactly once ({text.count(anchor)})")
replacement = (pre.rstrip() +
               "\n\ndevice_census('pre-align', netlist, schematic)\n$stdout.flush\nexit!(0)\n\n"
               + anchor)
text = text.replace(anchor, replacement, 1)
open(path, 'w', encoding='utf-8', newline='').write(text)
PY
    grep -q "device_census('pre-align'" "$DECK/gf180mcu.lvs" || { echo "census: pre-align call not inserted" >&2; exit 2; }
fi
grep -q '^exit!(0)$' "$DECK/gf180mcu.lvs" || { echo "census: early exit not inserted" >&2; exit 2; }

# --- run ------------------------------------------------------------------------------------
rel() { case "$1" in "$ROOT"/*) printf '/work/%s' "${1#"$ROOT"/}" ;; *) echo "census: $1 is outside this repository (not mounted)" >&2; return 2 ;; esac; }
MOUNT=$ROOT
if command -v cygpath >/dev/null 2>&1; then MOUNT=$(cygpath -m "$ROOT"); fi

C_DECK=$(rel "$DECK/gf180mcu.lvs")   || exit 2
C_LAYOUT=$(rel "$LAYOUT")            || exit 2
C_SCHEM=$(rel "$SCHEMATIC")          || exit 2
C_RUN=$(rel "$RUN")                  || exit 2
C_BIN=$(rel "$RUN/bin")              || exit 2

echo "census: $NAME  stage=$STAGE  combine=$COMBINE  threads=$THREADS"
echo "census: deck     ${DECK#"$ROOT"/}"
echo "census: layout   ${LAYOUT#"$ROOT"/}"
echo "census: netlist  ${SCHEMATIC#"$ROOT"/}"
echo "census: out      ${RUN#"$ROOT"/}"
echo "census: stage=$STAGE combine=$COMBINE threads=$THREADS topcell=$TOPCELL deck=$(sha256sum "$DECK/gf180mcu.lvs" | cut -c1-16)" > "$RUN/config"

# The image puts klayout and its libraries on a long Nix PATH, so prepend the shim there inside the
# container instead of replacing PATH on the docker command line.
MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" -w /work \
    "$IMAGE" sh -c 'PATH="$1:$PATH"; export PATH; shift; exec "$@"' sh "$C_BIN" \
    klayout -b -r "$C_DECK" \
    -rd "input=$C_LAYOUT" -rd "schematic=$C_SCHEM" -rd "topcell=$TOPCELL" \
    -rd metal_level=5LM -rd run_mode=tiling -rd "threads=$THREADS" \
    -rd "combine=$COMBINE" -rd top_lvl_pins=true -rd check_ports=false \
    -rd write_netlist=false -rd "report=$C_RUN/report.lvsdb" \
    > "$RUN/klayout.log" 2>&1
RC=$?
grep '^CENSUS ' "$RUN/klayout.log" > "$RUN/census.txt" || true

echo "census: klayout exit $RC; $(wc -l < "$RUN/census.txt") census lines in ${RUN#"$ROOT"/}/census.txt"
sed -n '1,40p' "$RUN/census.txt"
if [ "$(wc -l < "$RUN/census.txt")" -eq 0 ]; then
    echo "census: no census output; last lines of the log:" >&2
    tail -20 "$RUN/klayout.log" >&2
    exit 2
fi
exit 0
