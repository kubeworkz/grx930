#!/bin/bash
# run_cache_split_lockstep.sh [ROOT]
#
# Holds *every* hand-maintained copy of the rv64imac cache sources to one
# derived index/tag split.  Supersedes the earlier FPGA-pair check
# (run_fpga_cache_lockstep.sh), which covered only the two trees the FPGA flow
# shares; the FPGA tree is one of the trees below, and the tops leg here is
# strictly stronger than that check's cross-pair override comparison.
#
# Why: a literal 11:5 / 63:12 select over an INDEX_WIDTH-wide data array aliases
# 2**(7-INDEX_WIDTH) tag entries onto one data line, so a fill can leave a
# foreign tag VALID and a later HIT serves the wrong line.  The split has to be
# derived, and it has to be derived *the same way* in all 31 files, because the
# trees are hand-maintained copies of each other: fixing one and forking the
# others is how the defect survives.
#
# Copies checked (27 cache sources + 4 core tops):
#
#   required (tracked in git, so a clone has them)
#     rv64imac/RTL                                     dcache+icache controller/memory/top   <- reference
#     rv64imac/RTL/caches                              dcache+icache controller/memory/top
#     rv64imac/RTL/caches/atomic_dcaches               dcache controller/memory/top
#     rv64imac/FPGA/src                                dcache+icache controller/memory/top + core top
#     rv64imac/RTL/riscv_core_top.sv                   core top (named widths)
#     rv64imac/RTL/Branch_Predicition/TOP WITH BRANCH PREDICTION/riscv_core_top.sv
#                                                      core top (dcache only)
#
#   optional (the tapeout tree is untracked in git; absent -> SKIP, not a failure)
#     c930/asic_gf180mcu/openlane2_rtl/src             dcache+icache controller/memory/top + core top
#
# Whole-file equality is not the invariant and never was: these generations are
# deliberately different implementations (the FPGA copies carry no L2-coherence
# or fill-address plumbing and size the cache block differently), so only the
# split surface is locked.  Four legs:
#
#   surface   every `define declaration, the INDEX_WIDTH/TAG_WIDTH parameter
#             defaults, the derived TAG_W line and every .INDEX_WIDTH(...) /
#             .TAG_WIDTH(...) override are textually identical in every copy of
#             a given file (compared against rv64imac/RTL, the live tree).
#             Additions and value changes show up here; the cache tops' two
#             override pairs each are what carry the split into the controller
#             and the memory.
#   literals  no copy carries the buggy literal selects in code (63:12, 11:5,
#             11 -: ...).  The file headers cite them, so comments are stripped.
#   anchors   the canonical derived forms are present by name, per file kind:
#             `define TAG ADDR_WIDTH-1 : 5+INDEX_WIDTH, the per-cache INDEX
#             define, the block/byte offsets, localparam TAG_W =
#             ADDR_WIDTH - 5 - INDEX_WIDTH, the controller's TAG_WIDTH-vs-TAG_W
#             $error guard, and the tops' derived TAG_WIDTH default.  This is
#             what catches every copy drifting together, reference included.
#   tops      one derived override pair per cache-top instantiation in each core
#             top: .INDEX_WIDTH(7) then .TAG_WIDTH(64 - 5 - 7), with named
#             widths substituted from the file's own `parameter int` defaults,
#             so the RTL/tapeout form (ICACHE_INDEX_WIDTH = 7) and the
#             FPGA/Branch-Prediction literal form reduce to the same pair.  A
#             stale .TAG_WIDTH(20), a missing override, or an instantiation
#             without a pair fails.  The anchored default of 7 is deliberate:
#             re-targeting the caches at another width means updating this check
#             too, which is the wanted friction.
#
# Text only (bash, awk, grep, sort, cmp, diff) -- no simulator.  The behavioural
# regressions stay in run_cache_index_alias.sh (present generation),
# run_cache_index_alias_legacy.sh (older generations) and run_tag_width_guard.sh.
#
# Exit status 0 only when every present copy passes every leg.  A missing
# required tree or file fails; an absent optional tree is reported as SKIP.
#
# Usage:
#   ./run_cache_split_lockstep.sh                 # the repo's trees
#   ./run_cache_split_lockstep.sh ROOT            # e.g. a drifted scratch copy
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${1:-$(cd "$HERE/../.." && pwd)}

REF_TREE="rv64imac/RTL"
REQ_TREES=( "rv64imac/RTL" "rv64imac/RTL/caches" "rv64imac/RTL/caches/atomic_dcaches" "rv64imac/FPGA/src" )
OPT_TREES=( "c930/asic_gf180mcu/openlane2_rtl/src" )
DCACHE_FILES=( riscv_core_dcache_controller.sv riscv_core_dcache_memory.sv riscv_core_dcache_top.sv )
ICACHE_FILES=( riscv_core_icache_controller.sv riscv_core_icache_memory.sv riscv_core_icache_top.sv )
REQ_TOPS=( "rv64imac/RTL/riscv_core_top.sv"
           "rv64imac/RTL/Branch_Predicition/TOP WITH BRANCH PREDICTION/riscv_core_top.sv"
           "rv64imac/FPGA/src/riscv_core_top.sv" )
OPT_TOPS=( "c930/asic_gf180mcu/openlane2_rtl/src/riscv_core_top.sv" )
LIT_RE='\[11[[:space:]]*:[[:space:]]*5\]|\[11[[:space:]]*[-+]|\[63[[:space:]]*:[[:space:]]*12\]|\[63[[:space:]]*[-+]'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cache_split.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/empty.sed"

# Normalized text of a file: comments stripped so a re-worded header (or the
# notes that cite the old literals) cannot fail a leg, CRLF removed (the older
# trees carry it) and whitespace collapsed, so the two alignment styles in
# these files -- dcache writes one space, icache pads -- compare equal.  Done in
# one awk pass; a per-line pipeline of sed/tr/sed costs a process per element
# and this runs over 31 files.
norm() {  # file
  awk '{ sub(/\/\/.*/, ""); sub(/\r$/, ""); gsub(/^[ \t]+/, ""); gsub(/[ \t]+$/, ""); gsub(/[ \t]+/, " "); print }' "$1"
}
surfacelines() {  # normalized-file
  grep -E '^`define |^parameter (INDEX_WIDTH|TAG_WIDTH) |^localparam TAG_W ' "$1" | sort || true
}
width_subst() {  # file -> sed script mapping each declared `parameter int NAME = N` to N
  norm "$1" \
    | grep -oE 'parameter int [A-Za-z_][A-Za-z0-9_]* = [0-9]+' \
    | sed -E 's/parameter int ([A-Za-z_][A-Za-z0-9_]*) = ([0-9]+)/s|\1|\2|g/' || true
}
overrides() {  # file substfile -> normalized, substituted override list
  norm "$1" | grep -oE '\.(INDEX_WIDTH|TAG_WIDTH)[[:space:]]*\([^)]*\)' \
    | sed -E 's/[[:space:]]*\(/(/; s/[[:space:]]+/ /g; s/\( /(/; s/ \)/)/' \
    | sed -f "$2" || true
}

# The canonical derived forms, by file kind.  These are what catches all copies
# drifting together (the surface leg alone would not, since it compares them to
# each other through the reference tree).  Each row is a whole normalized line
# (`=`) or a substring of one (`~`, for the guard message, whose tail carries
# the computed values).
anchors_of() {  # cache layer -> one required row per line, on stdout
  echo '=`define TAG ADDR_WIDTH-1 : 5+INDEX_WIDTH'
  if [ "$1" = dcache ]; then
    echo '=`define DCACHE_INDEX 5 +: INDEX_WIDTH'
    echo '=`define DCACHE_BLOCK_OFFSET 4:3'
    echo '=`define DCACHE_BYTE_OFFSET 2:0'
  else
    echo '=`define ICACHE_INDEX 5 +: INDEX_WIDTH'
    echo '=`define ICACHE_BLOCK_OFFSET 4:2'
    echo '=`define ICACHE_BYTE_OFFSET 1:0'
  fi
  case "$2" in
    controller)
      echo '=parameter INDEX_WIDTH = 7,'
      echo '=parameter TAG_WIDTH = 52,'
      echo '=localparam TAG_W = ADDR_WIDTH - 5 - INDEX_WIDTH ;'
      echo '=`define OFFSET 5'
      echo '=initial if (TAG_WIDTH != TAG_W)'
      echo "~\$error(\"$1 TAG_WIDTH=%0d"
      ;;
    memory)
      echo '=parameter INDEX_WIDTH = 7,'
      echo '=parameter TAG_WIDTH = 52,'
      ;;
    top)
      echo '=parameter INDEX_WIDTH = 7,'
      echo '=parameter TAG_WIDTH = ADDR_WIDTH - 5 - INDEX_WIDTH,'
      ;;
  esac
}

# One pass: every required row must appear in the normalized copy, as a whole
# line (`=`) or as a substring of one (`~`).
missing_lines() {  # required-file normalized-file -> prints the absent ones
  awk 'NR == FNR { kind[++n] = substr($0, 1, 1); want[n] = substr($0, 2); next }
       { for (i = 1; i <= n; i++) {
           if (kind[i] == "=") { if ($0 == want[i]) seen[i] = 1 }
           else if (index($0, want[i]) > 0) seen[i] = 1
         } }
       END { for (i = 1; i <= n; i++)
               if (!seen[i]) print (kind[i] == "=" ? "" : "(substring) ") want[i] }' "$1" "$2"
}

fail=0
echo "ROOT      $ROOT"
echo "REFERENCE $REF_TREE"

# --------------------------------------------------------------------------
# the cache sources: surface vs the reference tree, literals, anchors
# --------------------------------------------------------------------------
check_cache_tree() {  # tree required(1/0)
  local tree=$1 req=$2 dir="$ROOT/$1"
  if [ ! -d "$dir" ]; then
    if [ "$req" = 1 ]; then echo "TREE $tree: MISSING (required)"; fail=1
    else echo "TREE $tree: SKIP (absent optional untracked tree)"; fi
    return
  fi

  local -a files=( "${DCACHE_FILES[@]}" )
  case "$tree" in *atomic_dcaches) ;; *) files+=( "${ICACHE_FILES[@]}" ) ;; esac

  local treefail=0 name f ref cache layer
  for name in "${files[@]}"; do
    f="$dir/$name"
    ref="$ROOT/$REF_TREE/$name"
    if [ ! -f "$f" ]; then echo "  $name: MISSING"; treefail=1; continue; fi
    if [ ! -f "$ref" ]; then echo "  $name: REFERENCE-MISSING ($REF_TREE/$name)"; treefail=1; continue; fi

    case "$name" in riscv_core_dcache_*) cache=dcache ;; *) cache=icache ;; esac
    case "$name" in *controller.sv) layer=controller ;; *memory.sv) layer=memory ;; *) layer=top ;; esac

    local ffail=0 hits
    norm "$f" > "$WORK/copy.norm"

    surfacelines "$WORK/copy.norm" > "$WORK/copy.s"
    if ! cmp -s "$WORK/ref.$name.s" "$WORK/copy.s"; then
      echo "  $name: SURFACE-DIFF vs $REF_TREE (- ref, + this copy):"
      diff -u "$WORK/ref.$name.s" "$WORK/copy.s" | sed -n '3,$p' | sed 's/^/      /'
      ffail=1
    fi

    # The cache tops pass the split down to their controller and memory
    # (.INDEX_WIDTH(INDEX_WIDTH), .TAG_WIDTH(TAG_WIDTH) twice each); those
    # overrides are part of the surface, so a stale .TAG_WIDTH(52) there is
    # caught the same way a stale define is.
    overrides "$f" "$WORK/empty.sed" | sort > "$WORK/copy.ovr"
    if ! cmp -s "$WORK/ref.$name.ovr" "$WORK/copy.ovr"; then
      echo "  $name: OVERRIDE-DIFF vs $REF_TREE (- ref, + this copy):"
      diff -u "$WORK/ref.$name.ovr" "$WORK/copy.ovr" | sed -n '3,$p' | sed 's/^/      /'
      ffail=1
    fi

    hits=$(grep -nE "$LIT_RE" "$WORK/copy.norm" || true)
    if [ -n "$hits" ]; then
      echo "  $name: LITERAL select back in code:"
      printf '%s\n' "$hits" | sed 's/^/      /'
      ffail=1
    fi

    missing=$(missing_lines "$WORK/anchors.$cache.$layer" "$WORK/copy.norm")
    if [ -n "$missing" ]; then
      echo "  $name: ANCHOR missing:"
      printf '%s\n' "$missing" | sed 's/^/      /'
      ffail=1
    fi

    if [ $ffail -eq 0 ]; then echo "  $name: PASS (surface, overrides, literals, anchors)"
    else treefail=1; fi
  done

  if [ $treefail -eq 0 ]; then echo "TREE $tree: PASS"; else echo "TREE $tree: FAIL"; fail=1; fi
}

# --------------------------------------------------------------------------
# the core tops: one derived override pair per cache-top instantiation
# --------------------------------------------------------------------------
check_top() {  # top_path required(1/0)
  local top=$1 req=$2 f="$ROOT/$1"
  if [ ! -f "$f" ]; then
    if [ "$req" = 1 ]; then echo "TOP $top: MISSING (required)"; fail=1
    else echo "TOP $top: SKIP (absent optional untracked tree)"; fi
    return
  fi

  local fail_top=0 normf="$WORK/top.norm"
  norm "$f" > "$normf"

  # The FPGA tree's top is module riscv_core_top_2 (its own fork of the same
  # source), so only the riscv_core_top prefix is required here.
  grep -qE '^module riscv_core_top([[:space:](_]|$)' "$normf" \
    || { echo "  module riscv_core_top* not found"; fail_top=1; }

  width_subst "$f" > "$WORK/top.subst.sed"
  overrides "$f" "$WORK/top.subst.sed" > "$WORK/top.ovr"
  overrides "$f" "$WORK/empty.sed" > "$WORK/top.raw"

  local npairs=$(( $(wc -l < "$WORK/top.ovr") / 2 ))
  local ninst
  ninst=$(grep -cE '^riscv_core_(i|d)cache_top([[:space:]#(]|$)' "$normf")

  msg=$(awk '
    { n++; L[n] = $0 }
    END {
      if (n == 0) { print "no .INDEX_WIDTH/.TAG_WIDTH override at all"; exit 1 }
      if (n % 2) { print "odd override count (" n "): expected .INDEX_WIDTH/.TAG_WIDTH pairs"; exit 1 }
      bad = 0
      for (i = 1; i <= n; i += 2) {
        if (L[i] != ".INDEX_WIDTH(7)") { print "index width is not 7: " L[i]; bad = 1 }
        if (L[i+1] != ".TAG_WIDTH(64 - 5 - 7)") { print "tag width is not derived from the split: " L[i+1]; bad = 1 }
      }
      if (bad) exit 1
    }' "$WORK/top.ovr")
  if [ -n "$msg" ]; then
    echo "  OVERRIDES: $msg"
    echo "    as written:"
    sed 's/^/      /' "$WORK/top.raw"
    fail_top=1
  fi
  if [ "$npairs" != "$ninst" ]; then
    echo "  OVERRIDES: $npairs derived pair(s) for $ninst cache-top instantiation(s)"
    fail_top=1
  fi

  local hits
  hits=$(grep -nE "$LIT_RE" "$normf" || true)
  if [ -n "$hits" ]; then
    echo "  LITERAL select back in code:"
    printf '%s\n' "$hits" | sed 's/^/      /'
    fail_top=1
  fi

  if [ $fail_top -eq 0 ]; then
    echo "TOP $top: PASS ($ninst instantiation(s), $npairs derived pair(s), literals)"
  else
    echo "TOP $top: FAIL"; fail=1
  fi
}

# --------------------------------------------------------------------------
# precompute: the reference surfaces and the anchor sets
# --------------------------------------------------------------------------
for name in "${DCACHE_FILES[@]}" "${ICACHE_FILES[@]}"; do
  if [ -f "$ROOT/$REF_TREE/$name" ]; then
    norm "$ROOT/$REF_TREE/$name" > "$WORK/ref.norm"
    surfacelines "$WORK/ref.norm" > "$WORK/ref.$name.s"
    overrides "$ROOT/$REF_TREE/$name" "$WORK/empty.sed" | sort > "$WORK/ref.$name.ovr"
  else
    : > "$WORK/ref.$name.s"
    : > "$WORK/ref.$name.ovr"
  fi
done
for cache in dcache icache; do
  for layer in controller memory top; do
    anchors_of "$cache" "$layer" > "$WORK/anchors.$cache.$layer"
  done
done

echo
for t in "${REQ_TREES[@]}"; do check_cache_tree "$t" 1; done
for t in "${OPT_TREES[@]}"; do check_cache_tree "$t" 0; done
for t in "${REQ_TOPS[@]}"; do check_top "$t" 1; done
for t in "${OPT_TOPS[@]}"; do check_top "$t" 0; done

echo
if [ $fail -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
exit $fail
