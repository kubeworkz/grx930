#!/bin/bash
# drt_driver_check.sh -- the DRT runner opens the driver script it was asked for,
# and that script is the one its image can actually load.
#
# WHY THIS EXISTS
#
#   drt_fast/ has two driver scripts and a runner that chooses between them, and
#   nothing used to check that the choice still pointed at a file. Every way that
#   breaks is silent until the run: a renamed die_drt.tcl, a FAST_TCL left on the
#   old path, a default that drifts to the variant the sweep arm's router cannot
#   read. The runner prints RUN_START and hands the path to OpenROAD, so the
#   failure arrives hours into a queued job as `couldn't read file` -- or worse,
#   as a driver that loads and aborts two seconds later with DRT-0509, which looks
#   like a router bug rather than a mis-selection. The question is answerable in
#   under a second, on any machine, without a router.
#
# WHY THERE ARE TWO DRIVERS AT ALL
#
#   drt_fast.tcl is the sweep arm's: it states the layer range with
#   detailed_route's -bottom_routing_layer/-top_routing_layer. die_drt.tcl is for
#   the pre-check image's router build, which answers those flags with
#   `[ERROR DRT-0509] -bottom_routing_layer is deprecated` and aborts; it states
#   the range with set_routing_layers instead, and prints the tech's routing layers
#   so the log carries the range as data. That difference is why the second file
#   exists, so it is checked in both directions: the arm that needs the flags keeps
#   them, and the arm that must not pass them does not.
#
# THE SEAM THIS USES
#
#   run_drt.sh already takes the router from FAST_OPENROAD and the driver from
#   FAST_TCL, both documented in its own header. So a stub stands in for OpenROAD
#   and records the argv it was handed: what is under test is the selection, not
#   the router, and neither a database nor an image is needed. The one thing this
#   check has to translate is the default driver's container path: /work is this
#   workspace, so /work/<x> is c930/asic_gf180mcu/<x> in a checkout, which is the
#   bind mount the chains pass as `-v ...:/work`. The translation is asserted, not
#   assumed -- arm [C] requires the translated path to be this repo's
#   drt_fast.tcl.
#
# THE ARMS
#
#   [A] both drivers exist, are non-empty, and are two files (not one copied)
#   [B] the content contract, read from CODE only: die_drt.tcl's own header names
#       the deprecated flags in prose, so a grep over the whole file would fire on
#       the explanation -- comment lines are stripped first
#   [C] the default selection, end to end through the real runner: the argv the
#       router receives is `-exit -no_splash /work/drt_fast/drt_fast.tcl`, that
#       path resolves under /work to this repo's drt_fast.tcl, and RUN_END says
#       rc=0. Changing the default is a decision, and this is where it is recorded
#   [D] FAST_TCL is taken verbatim: an absolute path reaches the router unchanged,
#       and a bare name is NOT joined to the runner's $D -- the trap behind
#       `FAST_TCL=die_drt.tcl` meaning something other than it reads
#   [E] a renamed driver is a red line in about a second: FAST_TCL naming a file
#       that is not there makes the runner exit 2 and print RUN_END rc=2, which is
#       the reproduction of the failure this gate exists to move forward
#   [F] the router's exit status is the runner's: 7 in, 7 out. A runner that
#       swallowed it would report a failed route as a completed one
#   [G] the audit tests itself on fixtures: die_drt.tcl missing, the two drivers
#       identical, and die_drt.tcl carrying the deprecated flags must each be
#       refused, while an intact pair passes. Without this arm the others could be
#       passing because the audit matches nothing
#
# WHAT THIS DOES NOT PROVE
#
#   That either script routes anything, or that the image's OpenROAD is the build
#   that answers DRT-0509 -- that was measured on the box, and die_drt.tcl's header
#   carries the date and the rc. It proves which file the runner opens, that the
#   file exists where the runner will look for it, and that the file is the variant
#   its own image accepts.
#
# USAGE
#
#   bash c930/asic_gf180mcu/build/drt_driver_check.sh
#
# EXIT STATUS
#
#   0 only when every arm holds. 1 when an arm fails, 2 when the tree this file
#   lives in cannot be resolved: a check that could not run must never read as one
#   that ran and passed.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
REPO=$(CDPATH= cd -- "$HERE/../../.." && pwd) || exit 2
WS=$REPO/c930/asic_gf180mcu                    # what the chains bind-mount at /work
DRT=$WS/drt_fast
RUNNER=$DRT/run_drt.sh
MOUNT_ROOT=/work

if [ ! -f "$RUNNER" ] || [ ! -d "$WS" ]; then
  printf 'drt_driver_check: this file must live in c930/asic_gf180mcu/build/ of the repo it checks (resolved %s)\n' "$REPO" >&2
  exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/drt_driver_check.XXXXXX") || { echo 'drt_driver_check: mktemp failed' >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '[%s] PASS %s\n' "$1" "$2"; }
bad() { fail=$((fail + 1)); printf '[%s] FAIL %s\n' "$1" "$2"; }
chk() { if [ "$3" = "$4" ]; then ok "$1" "$2 (= $4)"; else bad "$1" "$2: expected [$3] got [$4]"; fi; }

# ---------------------------------------------------------------------------
# the stand-in router
# ---------------------------------------------------------------------------

# One argv element per line, so a path with a space stays one argument here too.
# It resolves a /work path the way the container's bind mount would, so "the
# driver is not there" is a real filesystem answer rather than a flag this check
# set to make itself pass.
STUB=$TMP/openroad-stub
cat > "$STUB" <<'SH'
#!/bin/bash
set -u
for a in "$@"; do printf '%s\n' "$a"; done > "${STUB_ARGS:?}"
last=${!#}
resolved=$last
case $last in
  /work/*) resolved="${STUB_WORK:?}/${last#/work/}" ;;
esac
[ -e "$resolved" ] || { printf 'STUB: no such driver script: %s (resolved %s)\n' "$last" "$resolved" >&2; exit 2; }
exit "${STUB_RC:-0}"
SH
chmod +x "$STUB" || { echo 'drt_driver_check: cannot make the stub executable' >&2; exit 2; }

ARGV=$TMP/argv.txt
OUT=""
RC=0

# run_runner <cwd> [VAR=value ...] -> the runner's combined output in $OUT and its
# status in $RC. The assignments are on that one command in a subshell, so no arm
# can leak FAST_TCL or STUB_RC into the next one, and $ARGV is cleared first so an
# arm that never reaches the router cannot read the previous arm's argv.
run_runner() {
  local dir=$1
  shift
  : > "$ARGV"
  OUT=$( cd "$dir" && env "$@" STUB_ARGS="$ARGV" STUB_WORK="$WS" FAST_OPENROAD="$STUB" bash "$RUNNER" 2>&1 )
  RC=$?
}

# ---------------------------------------------------------------------------
# the audit of the two files (arms [A], [B], and the fixtures in [G])
# ---------------------------------------------------------------------------

# code_of <file> -- the lines that run, comment lines removed. die_drt.tcl's own
# header names the deprecated flags in prose; only code counts as passing them.
code_of() { grep -v -E '^[[:space:]]*#' "$1"; }

sha_of() {  # a content id, without needing sha256sum on PATH everywhere
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else cksum "$1"; fi
}

# audit_drivers <dir> -> the report on stdout, rc 0 when the pair is intact.
# AUDIT_A and AUDIT_B keep the two questions apart, so the arms can fail
# independently and say which one moved.
AUDIT_A=0
AUDIT_B=0
audit_drivers() {
  local d=$1 a=$1/drt_fast.tcl b=$1/die_drt.tcl
  local present=0
  # Reset on entry, not just at the end: the verdicts are globals so each caller
  # can name the question that moved, and a body that only ever sets them to 1
  # would carry the real tree's failure into every fixture below it -- the audit
  # would then report an intact fixture as broken because something else was.
  AUDIT_A=0
  AUDIT_B=0

  if [ -s "$a" ]; then printf 'DRIVER    drt_fast.tcl: present (%s bytes)\n' "$(wc -c < "$a" | tr -d ' ')"
  else printf 'DRIVER    drt_fast.tcl: MISSING or empty\n'; present=1; fi
  if [ -s "$b" ]; then printf 'DRIVER    die_drt.tcl: present (%s bytes)\n' "$(wc -c < "$b" | tr -d ' ')"
  else printf 'DRIVER    die_drt.tcl: MISSING or empty -- the pre-check image needs it, and FAST_TCL names it\n'; present=1; fi

  if [ $present -eq 0 ]; then
    if [ "$(sha_of "$a")" = "$(sha_of "$b")" ]; then
      printf 'DRIVER    the two drivers are the same content: one was copied over the other\n'; present=1
    else
      printf 'DRIVER    the two drivers are distinct files\n'
    fi
  fi

  # The sweep arm's driver states the range with the layer flags; its router
  # accepts them, so losing them changes what that arm measures.
  if [ -s "$a" ]; then
    if code_of "$a" | grep -q -- '-bottom_routing_layer' && code_of "$a" | grep -q -- '-top_routing_layer'; then
      printf 'CONTRACT  drt_fast.tcl passes both layer flags (the sweep arm needs them)\n'
    else
      printf 'CONTRACT  drt_fast.tcl no longer passes both layer flags: it is the sweep arm'"'"'s driver\n'; AUDIT_B=1
    fi
  fi

  # The pre-check image's driver must pass neither deprecrated flag, and must state
  # the range the way that build accepts instead -- the substitution DRT-0509 names.
  if [ -s "$b" ]; then
    if code_of "$b" | grep -qE -- '-bottom_routing_layer|-top_routing_layer'; then
      printf 'CONTRACT  die_drt.tcl passes a deprecated layer flag: that build answers DRT-0509 and aborts\n'; AUDIT_B=1
    else
      printf 'CONTRACT  die_drt.tcl passes neither deprecated layer flag\n'
    fi
    if code_of "$b" | grep -q -- 'set_routing_layers'; then
      printf 'CONTRACT  die_drt.tcl states the range with set_routing_layers\n'
    else
      printf 'CONTRACT  die_drt.tcl names no layer range: set_routing_layers is gone\n'; AUDIT_B=1
    fi
  fi

  AUDIT_A=$present
  [ $present -eq 0 ] && [ "$AUDIT_B" -eq 0 ]
}

# ---------------------------------------------------------------------------
# [A] + [B] on the real tree
# ---------------------------------------------------------------------------
printf 'DRT_DRIVER_CHECK repo=%s\n\n' "$REPO"
if audit_drivers "$DRT" > "$TMP/audit.txt"; then :; fi
cat "$TMP/audit.txt"
if [ "$AUDIT_A" -eq 0 ]; then ok A "both drivers are present, non-empty and distinct"; else bad A "the driver pair in $DRT is not intact"; fi
if [ "$AUDIT_B" -eq 0 ]; then ok B "the content contract holds on the real tree"; else bad B "the content contract is broken: one of the drivers lost what its image needs"; fi

# ---------------------------------------------------------------------------
# [C] the default selection, through the real runner
# ---------------------------------------------------------------------------
run_runner "$TMP"
chk C "the runner exits 0 on a driver that is there" 0 "$RC"
chk C "the argv the router receives" "-exit -no_splash $MOUNT_ROOT/drt_fast/drt_fast.tcl" \
  "$(tr '\n' ' ' < "$ARGV" | sed 's/ $//')"

# The default is in container coordinates; translate it through the bind mount and
# require the file it names to be this tree's drt_fast.tcl.
selected=$(tail -1 "$ARGV")
case "$selected" in
  "$MOUNT_ROOT"/*)
    translated="$WS/${selected#"$MOUNT_ROOT"/}"
    if [ -f "$translated" ]; then ok C "the default resolves under /work to a real file ($translated)"
    else bad C "the default names $selected, which is not $translated -- hours in, that is 'couldn't read file'"; fi
    # -ef where the shell has it: the same inode is the question, not the spelling.
    if [ -f "$translated" ] && [ "$translated" -ef "$DRT/drt_fast.tcl" ]; then
      ok C "and it is this repo's drt_fast.tcl"
    else
      bad C "and it is NOT this repo's drt_fast.tcl: the default has drifted from the sweep arm's driver"
    fi
    ;;
  *) bad C "the default driver is not under $MOUNT_ROOT, so the bind-mount translation means nothing: $selected" ;;
esac
case "$(printf '%s\n' "$OUT" | grep '^RUN_END' || true)" in
  *"rc=0") ok C "and the runner tells the chain rc=0 in RUN_END" ;;
  *)       bad C "RUN_END does not say rc=0: $(printf '%s' "$OUT" | grep '^RUN_END' || echo '<no RUN_END line>')" ;;
esac

# ---------------------------------------------------------------------------
# [D] FAST_TCL is verbatim
# ---------------------------------------------------------------------------
run_runner "$TMP" FAST_TCL="$DRT/die_drt.tcl"
chk D "an absolute FAST_TCL reaches the router unchanged" "$DRT/die_drt.tcl" "$(tail -1 "$ARGV")"
chk D "  and the runner exits 0 for it" 0 "$RC"

: > "$TMP/die_drt.tcl"
run_runner "$TMP" FAST_TCL=die_drt.tcl
chk D "a bare name is not joined to the runner's \$D (it is relative to the caller's cwd)" "die_drt.tcl" "$(tail -1 "$ARGV")"

# ---------------------------------------------------------------------------
# [E] a rename is a red line in about a second
# ---------------------------------------------------------------------------
run_runner "$TMP" FAST_TCL="$MOUNT_ROOT/drt_fast/die_drt_renamed.tcl"
chk E "a driver name that does not exist makes the router refuse" 2 "$RC"
case "$(printf '%s\n' "$OUT" | grep '^RUN_END' || true)" in
  *"rc=2") ok E "and the runner hands that status on in RUN_END" ;;
  *)       bad E "RUN_END does not carry the refusal: $(printf '%s' "$OUT" | grep '^RUN_END' || echo '<no RUN_END line>')" ;;
esac

# ---------------------------------------------------------------------------
# [F] the router's status is the runner's
# ---------------------------------------------------------------------------
run_runner "$TMP" STUB_RC=7
chk F "the runner exits with the router's status" 7 "$RC"
case "$(printf '%s\n' "$OUT" | grep '^RUN_END' || true)" in
  *"rc=7") ok F "and says rc=7 in RUN_END" ;;
  *)       bad F "RUN_END does not carry 7: $(printf '%s' "$OUT" | grep '^RUN_END' || echo '<no RUN_END line>')" ;;
esac

# ---------------------------------------------------------------------------
# [G] the audit tests itself
# ---------------------------------------------------------------------------
# Built from text, not copied from the tree. An arm that copies the real drivers
# stops testing the audit the moment the real tree is the thing that is broken --
# it would report "the audit is not the rule it claims" about a fixture that was
# never intact. These four say what the rule is, in isolation from the tree.
mkdir -p "$TMP/fx-ok" "$TMP/fx-missing" "$TMP/fx-copied" "$TMP/fx-flags" || bad G "cannot build the fixtures"
cat > "$TMP/fx-ok/drt_fast.tcl" <<'TCL'
# fixture: the sweep arm's shape -- states the range with the layer flags
detailed_route -bottom_routing_layer $::env(FAST_MIN_LAYER) \
               -top_routing_layer    $::env(FAST_MAX_LAYER)
TCL
cat > "$TMP/fx-ok/die_drt.tcl" <<'TCL'
# fixture: the pre-check image's shape. This comment names -bottom_routing_layer
# and -top_routing_layer on purpose: the audit must read code, not prose.
set_routing_layers -signal $::env(FAST_MIN_LAYER)-$::env(FAST_MAX_LAYER)
detailed_route -output_drc out.drc
TCL
cp -f "$TMP/fx-ok/drt_fast.tcl" "$TMP/fx-missing/"
cp -f "$TMP/fx-ok/drt_fast.tcl" "$TMP/fx-copied/"
cp -f "$TMP/fx-ok/drt_fast.tcl" "$TMP/fx-copied/die_drt.tcl"
cp -f "$TMP/fx-ok/drt_fast.tcl" "$TMP/fx-ok/die_drt.tcl" "$TMP/fx-flags/"
printf '\ndetailed_route -bottom_routing_layer Metal1 -top_routing_layer Metal5\n' >> "$TMP/fx-flags/die_drt.tcl"

if audit_drivers "$TMP/fx-ok" >/dev/null 2>&1; then ok G "an intact pair passes"
else bad G "an intact pair was refused -- the audit is not the rule it claims"; fi
if audit_drivers "$TMP/fx-missing" >/dev/null 2>&1; then bad G "a missing die_drt.tcl was accepted -- the rename this gate exists for would pass"
else ok G "a missing die_drt.tcl is refused"; fi
if audit_drivers "$TMP/fx-copied" >/dev/null 2>&1; then bad G "the same file copied twice was accepted -- the two drivers must stay distinct"
else ok G "one driver copied over the other is refused"; fi
if audit_drivers "$TMP/fx-flags" >/dev/null 2>&1; then bad G "die_drt.tcl with the deprecated flags was accepted -- the pre-check image would abort 2s in"
else ok G "die_drt.tcl with the deprecated flags is refused"; fi

# ---------------------------------------------------------------------------
# the verdict
# ---------------------------------------------------------------------------
printf '\nARMS      %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf 'OVERALL: PASS\n'
  exit 0
fi
printf 'OVERALL: FAIL\n'
printf '  %s arm(s) failed. The driver the runner opens, or the driver file itself, is not the one\n' "$fail"
printf '  its image can load -- a rename, a FAST_TCL left on an old path, or one variant drifting\n'
printf '  into the other arm'"'"'s flags. Every one of those costs a queued run, not a test.\n'
exit 1
