#!/bin/bash
# run_fpga_cache_lockstep.sh [RTL_DIR] [FPGA_DIR]
#
# Keeps the seven cache sources the FPGA flow shares with rv64imac/RTL in
# step: both caches' controller, memory and top, plus riscv_core_top.
#
# The two generations are deliberately different implementations -- the FPGA
# copies carry no L2-coherence or fill-address plumbing, and size a cache
# block differently -- so whole-file equality is not the invariant, and a
# check that demanded it would be wrong the day it was written. What must not
# drift silently is the index/tag split: a literal 63:12 / 11:5 select aliases
# 2**(7-INDEX_WIDTH) tag entries onto one data line, so a fill can leave a
# foreign tag VALID and a later HIT serves the wrong line.
#
# Three legs per pair:
#
#   surface    every `define line, the INDEX_WIDTH/TAG_WIDTH parameter
#              defaults, the derived tag width (TAG_W) and its guard, and
#              every .INDEX_WIDTH(...) / .TAG_WIDTH(...) override are
#              textually identical across the pair.  The core tops are the
#              one exception: the RTL top names ICACHE_INDEX_WIDTH /
#              DCACHE_INDEX_WIDTH where the FPGA top writes the same value
#              out literally, so for that pair each side's declared defaults
#              are substituted before the comparison.
#   literals   neither copy carries the buggy literal selects in code
#              (63:12, 11:5, 11 -: and friends).  Comments may cite them --
#              the headers do -- so comments are stripped first.
#   anchor     the six cache files still carry the canonical derived forms
#              (define TAG / define <CACHE>_INDEX / localparam TAG_W), and
#              riscv_core_top still derives its TAG_WIDTH override
#              (64 - 5 - ...), so a pair jointly edited back to a literal
#              form is caught as well.
#
# The older cache generations (RTL/caches, atomic_dcaches, the branch-
# prediction tree) have their own copies and regressions
# (run_cache_index_alias_legacy.sh); this check covers the files the FPGA
# flow shares.
#
# Exit status 0 only when every pair passes every leg.  Text only: bash,
# grep, sed, sort, cmp, diff -- no simulator.
#
# Usage:
#   ./run_fpga_cache_lockstep.sh                    # the repo's two trees
#   ./run_fpga_cache_lockstep.sh RTL_DIR FPGA_DIR   # e.g. a drifted scratch copy
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RTL=${1:-$ROOT/rv64imac/RTL}
FPGA=${2:-$ROOT/rv64imac/FPGA/src}

NAMES="riscv_core_dcache_controller riscv_core_dcache_memory riscv_core_dcache_top
       riscv_core_icache_controller riscv_core_icache_memory riscv_core_icache_top
       riscv_core_top"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cache_lockstep.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# The cache sources use // comments only; stripping them keeps a re-worded
# comment (or the header notes that cite the old literals) from failing the
# check.
nocmt() { sed -E 's@//.*@@' "$1"; }

lines_surface() {
  nocmt "$1" | tr -d '\r' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' \
    | grep -E '^`define |^parameter (INDEX_WIDTH|TAG_WIDTH)|TAG_W\b' || true
}

overrides() {
  nocmt "$1" | tr -d '\r' \
    | grep -oE '\.(INDEX_WIDTH|TAG_WIDTH)[[:space:]]*\([^)]*\)' \
    | sed -E 's/[[:space:]]*\(/(/; s/[[:space:]]+/ /g' || true
}

# Every `parameter int NAME = N` in the pair becomes a sed rule NAME -> N, so
# the core tops' named widths and the FPGA top's literals compare.  Only
# riscv_core_top declares any (the cache files declare INDEX_WIDTH/TAG_WIDTH
# without a type, and those must stay symbolic).
width_subst() {
  grep -hoE 'parameter[[:space:]]+int[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[0-9]+' "$@" 2>/dev/null \
    | sed -E 's/.*int[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*([0-9]+)/s|\1|\2|g/'
}

literals() {
  nocmt "$1" | tr -d '\r' \
    | grep -nE '\[11[[:space:]]*:[[:space:]]*5\]|\[11[[:space:]]*[-+]|\[63[[:space:]]*:[[:space:]]*12\]|\[63[[:space:]]*[-+]' || true
}

fail=0
echo "RTL_DIR  $RTL"
echo "FPGA_DIR $FPGA"

for name in $NAMES; do
  r="$RTL/$name.sv"
  f="$FPGA/$name.sv"
  pairfail=0
  missing=""
  [ -f "$r" ] || missing="$missing $r"
  [ -f "$f" ] || missing="$missing $f"
  if [ -n "$missing" ]; then
    echo "[$name] MISSING:$missing"
    fail=1
    continue
  fi

  # ---- surface: the declaration lines --------------------------------------
  lines_surface "$r" | sort > "$WORK/rtl.lines"
  lines_surface "$f" | sort > "$WORK/fpga.lines"
  if ! cmp -s "$WORK/rtl.lines" "$WORK/fpga.lines"; then
    echo "[$name] SURFACE-DIFF lines (- rtl, + fpga):"
    diff -u "$WORK/rtl.lines" "$WORK/fpga.lines" | sed -n '3,$p' | sed 's/^/    /'
    pairfail=1
  fi

  # ---- surface: the instantiation overrides --------------------------------
  subst=""
  if [ "$name" = riscv_core_top ]; then
    width_subst "$r" "$f" > "$WORK/subst.sed"
    subst="$WORK/subst.sed"
  fi
  if [ -n "$subst" ]; then
    overrides "$r" | sed -f "$subst" | sort > "$WORK/rtl.ovr"
    overrides "$f" | sed -f "$subst" | sort > "$WORK/fpga.ovr"
  else
    overrides "$r" | sort > "$WORK/rtl.ovr"
    overrides "$f" | sort > "$WORK/fpga.ovr"
  fi
  if ! cmp -s "$WORK/rtl.ovr" "$WORK/fpga.ovr"; then
    echo "[$name] SURFACE-DIFF overrides (- rtl, + fpga):"
    diff -u "$WORK/rtl.ovr" "$WORK/fpga.ovr" | sed -n '3,$p' | sed 's/^/    /'
    pairfail=1
  fi

  # ---- literals ------------------------------------------------------------
  for side in rtl fpga; do
    case "$side" in rtl) file=$r ;; fpga) file=$f ;; esac
    hits=$(literals "$file")
    if [ -n "$hits" ]; then
      echo "[$name] LITERAL ($side):"
      printf '%s\n' "$hits" | sed 's/^/    /'
      pairfail=1
    fi
  done

  # ---- anchors: the canonical derived forms must still be there ------------
  if [ "$name" = riscv_core_top ]; then
    for side in rtl fpga; do
      case "$side" in rtl) file=$r ;; fpga) file=$f ;; esac
      bad=$(overrides "$file" | sed -f "$WORK/subst.sed" | grep -E '^\.TAG_WIDTH\(' | grep -vE '^\.TAG_WIDTH\(64 - 5 - ' || true)
      if [ -n "$bad" ]; then
        echo "[$name] ANCHOR fail ($side): TAG_WIDTH override not derived from the split:"
        printf '%s\n' "$bad" | sed 's/^/    /'
        pairfail=1
      fi
    done
  else
    case "$name" in
      *dcache*) want_idx='`define DCACHE_INDEX 5 +: INDEX_WIDTH' ;;
      *icache*) want_idx='`define ICACHE_INDEX 5 +: INDEX_WIDTH' ;;
    esac
    for side in rtl fpga; do
      case "$side" in rtl) file=$r ;; fpga) file=$f ;; esac
      for want in '`define TAG ADDR_WIDTH-1 : 5+INDEX_WIDTH' "$want_idx"; do
        if ! lines_surface "$file" | grep -qxF "$want"; then
          echo "[$name] ANCHOR fail ($side): missing: $want"
          pairfail=1
        fi
      done
      case "$name" in
        *_controller)
          want='localparam TAG_W = ADDR_WIDTH - 5 - INDEX_WIDTH ;'
          if ! lines_surface "$file" | grep -qxF "$want"; then
            echo "[$name] ANCHOR fail ($side): missing: $want"
            pairfail=1
          fi
          ;;
      esac
    done
  fi

  if [ $pairfail -eq 0 ]; then
    echo "[$name] PASS (surface, literals, anchors)"
  else
    fail=1
  fi
done

if [ $fail -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $fail
