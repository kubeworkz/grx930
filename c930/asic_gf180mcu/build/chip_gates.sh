#!/usr/bin/env bash
# chip_gates.sh -- every chip gate this repo has, in one command, for the flow
# box and for CI alike.
#
# WHY THIS FILE EXISTS
#
#   These checks have to run in two places: on this box before a push, and in CI
#   on every push. Written down in both places they drift -- one side grows a
#   gate the other never gets, or keeps a spelling the other fixed -- and the
#   copy a person reads becomes the wrong copy. So the list lives here and
#   nowhere else:
#
#     .github/workflows/build-gf180mcu.yml   is one step, `bash c930/asic_gf180mcu/build/chip_gates.sh`,
#                                            plus the toolchain and the log upload
#     .githooks/pre-push                     runs this same file, on the pushes that can break a gate
#
#   That property is checkable rather than asserted -- the workflow names no gate
#   command at all:
#
#     grep -nE 'make sim|check_rom|run_adapter_lint|run_cache_index_alias|run_tag_width_guard|run_cache_split_lockstep|dcache_mmio_hold|script_exec_bit' \
#       .github/workflows/build-gf180mcu.yml
#
# THE GATES, IN THE ORDER THEY MUST RUN
#
#   script-exec-bit       every shell script tracked in the index is mode 100755,
#                         so a Linux checkout can run it as ./x.sh. About the tree
#                         rather than the design, seconds rather than minutes, and
#                         the one check the box cannot make for itself: this git
#                         has core.filemode=false, so chmod +x here changes
#                         nothing git records and only a checkout that reads the
#                         mode finds the fault. (build/script_exec_bit.sh)
#   boot-from-rom         the chip powers up from its own ROM at 0x0001_0000 =
#                         CORE_RESET_PC, with no SRAM preload, and reaches the
#                         firmware's UART banner -- on the tree the OL2 flow reads
#                         (openlane2_rtl/src). The ROM, the reset PC and the
#                         SRAM/ROM split, together.
#   rom-disabled-control  the same sim with -DROM_DISABLE must FAIL. Without it
#                         the gate above is not evidence about the ROM; this is
#                         also the one gate whose PASS is a non-zero exit, so it
#                         is the one row in the table with `expect=fail`.
#   rom-drift             the checked-in ROM is what tools/gen_bootrom.py emits
#                         from the checked-in firmware hex. A stale ROM is
#                         invisible to every other gate and ships as the
#                         firmware in the silicon.
#   adapter-lint          chip_core_grx930.sv elaborates against the template's
#                         1x1 pad ring and its pad map is live (PAD_MAP.md). A
#                         pad-count or port-name mistake here costs a whole
#                         LibreLane run on the server.
#   cache-index-alias     the index/tag split decomposes fill addresses (both
#                         caches), i.e. the pre-fix literal selects are gone.
#   cache-tag-guard       the tag-width guard fires on a hardcoded 52 and stays
#                         silent on the derived default -- the negative control
#                         for the gate above.
#   cache-split-lockstep  every hand-maintained copy of the cache sources still
#                         carries the same derived split, so fixing one tree and
#                         forking the others cannot pass.
#   mmio-hold             an MMIO load's data survives a frozen pipeline
#                         (doc/dcache_mmio_read_hold.md).
#
# EVERY GATE RUNS, ALWAYS
#
#   A failing gate does not stop the next one. One exit status for the run, every
#   verdict in the report -- which is what the workflow's per-step `if: always()`
#   bought before, and what makes a pasted report tell the whole story instead of
#   the first failure only.
#
# WHERE THE LOGS GO
#
#   c930/asic_gf180mcu/build/<gate>.log holds each gate's own output, so the
#   question after a failure ("what did it actually say?") has an answer on the
#   box and in the uploaded CI artifact, at the same paths.
#
# USAGE
#
#   bash c930/asic_gf180mcu/build/chip_gates.sh                     # all nine
#   bash c930/asic_gf180mcu/build/chip_gates.sh --list               # names only
#   bash c930/asic_gf180mcu/build/chip_gates.sh --only mmio-hold     # one of them
#
# EXIT STATUS
#
#   0 only when every gate ran and passed. A gate whose tool is missing reports
#   BLOCKED, which is a failure: a gate that could not run must never read as one
#   that passed. 2 is a usage error (unknown flag or gate name).
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)          # c930/asic_gf180mcu/build -> repo root
LOGDIR="$ROOT/c930/asic_gf180mcu/build"

# name | working dir | command | expect(pass|fail) | evidence pattern | tools
#
# The three c930/tb scripts are run as `bash <script>`, not `./<script>`, and that
# is not a style choice even though the script-exec-bit gate above now keeps every
# tracked .sh at 100755: naming the interpreter is the stronger half of the pair.
# It holds where the mode cannot -- a noexec mount, a copy out of a zip, a runner
# that checked the tree out before the mode was fixed -- and it is what made these
# three run on the runner that did have them at 100644. The gate is the other
# half: it keeps the mode right for the person who types ./run_cache_index_alias.sh
# at a prompt, which is what these scripts' own usage lines tell them to do. (The
# 100644 index is what made CI answer "Permission denied" three steps wide on the
# revision before that fix; the history is in build/script_exec_bit.sh.)
#
# The pattern is the literal line that has to be in the gate's own log for its
# verdict to count: an exit status alone cannot tell a gate that checked something
# from one that died on the way in, and `make sim` prints the testbench's RESULT
# line, which is why the boot gates quote it rather than trusting `make`'s rc.
# Matched with grep -F, so a pattern containing regex metacharacters -- `[PASS]
# tb_dcache_mmio_hold` -- is the line itself and not a character class.
GATES=$(cat <<'EOF'
script-exec-bit|c930/asic_gf180mcu|bash build/script_exec_bit.sh|pass|OVERALL: PASS|bash git
boot-from-rom|c930/asic_gf180mcu|make sim SIM_PLUSARGS=+NO_PRELOAD|pass|RESULT: PASS|iverilog vvp make
rom-disabled-control|c930/asic_gf180mcu|make sim SIM_PLUSARGS=+NO_PRELOAD SIM_DEFS=-DROM_DISABLE|fail|RESULT: FAIL|iverilog vvp make
rom-drift|c930/asic_gf180mcu|make check_rom|pass|ROM in sync|python
adapter-lint|c930/asic_gf180mcu|sh wafer_space_integration/run_adapter_lint.sh|pass|RESULT: PASS|iverilog vvp
cache-index-alias|c930/tb|bash run_cache_index_alias.sh|pass|OVERALL: PASS|iverilog vvp
cache-tag-guard|c930/tb|bash run_tag_width_guard.sh|pass|OVERALL: PASS|iverilog vvp
cache-split-lockstep|c930/tb|bash run_cache_split_lockstep.sh|pass|OVERALL: PASS|bash git
mmio-hold|c930|make dcache_mmio_hold|pass|[PASS] tb_dcache_mmio_hold|iverilog vvp make
EOF
)

# The lockstep gate covers five hand-maintained copies of the cache sources. The
# FPGA copy cannot be in a checkout -- .gitignore line 38, `rv64imac/*` -- so when
# the tree is absent the gate has to be told that a checkout is what it is looking
# at; on this box the tree is here, and the same command then checks all five.
# Either way the strongest check the tree allows is the one that runs, and CI
# (a checkout) gets the counted SKIP instead of a permanent red.
#
# Exported once, so the command in the table above stays free of env prefixes.
if [ -d "$ROOT/rv64imac/FPGA/src" ]; then
  unset CACHE_LOCKSTEP_GITIGNORED_ABSENT || true
else
  export CACHE_LOCKSTEP_GITIGNORED_ABSENT=1
fi

only=()
list_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) list_only=1; shift ;;
    --only)
      [ $# -ge 2 ] || { echo "chip_gates: --only needs a gate name (see --list)" >&2; exit 2; }
      only+=( "$2" ); shift 2 ;;
    # The header, up to the first line of code -- so it cannot go stale and stop
    # half way through a sentence.
    -h|--help) sed -n '2,/^set -u$/p' "$0"; exit 0 ;;
    *) echo "chip_gates: unknown argument: $1 (try --list or --help)" >&2; exit 2 ;;
  esac
done

in_only() {  # name -> 0 when this run was asked for that gate
  local n
  for n in ${only[@]+"${only[@]}"}; do [ "$n" = "$1" ] && return 0; done
  return 1
}

if [ $list_only -eq 1 ]; then
  while IFS='|' read -r name _rest; do [ -n "$name" ] && echo "$name"; done < <(printf '%s\n' "$GATES")
  exit 0
fi

# An unknown --only is a usage error, not a silent no-op run that exits 0: the
# whole point of asking for a gate by name is that it ran. Checked over the names
# that were ASKED for, against the table -- asking whether each table row was
# requested is the same test backwards, and errors on the gates you left out.
if [ ${#only[@]} -gt 0 ]; then
  for want in "${only[@]}"; do
    found=0
    while IFS='|' read -r name _rest; do
      [ "$name" = "$want" ] && { found=1; break; }
    done < <(printf '%s\n' "$GATES")
    [ $found -eq 1 ] || { echo "chip_gates: no such gate: $want (see --list)" >&2; exit 2; }
  done
fi

missing_tools() {  # "tool tool ..." -> prints the ones not on PATH, then goes
  local t
  for t in $1; do command -v "$t" >/dev/null 2>&1 || printf '%s ' "$t"; done
}

annotate() {  # message -- a GitHub error annotation when there is a GitHub to read it
  [ "${GITHUB_ACTIONS:-}" = true ] && echo "::error::$1"
  return 0
}

# ROOT comes from this file's own path, so it only means anything when the file
# is where it lives. A copy parked elsewhere would otherwise resolve to a
# directory with nothing to gate and fail gate by gate for reasons that look like
# gate failures -- say it once, here, with the path that was computed.
if [ ! -d "$ROOT/c930/asic_gf180mcu" ] || [ ! -d "$ROOT/c930/tb" ]; then
  echo "chip_gates: ROOT resolved to '$ROOT', which is not this repository." >&2
  echo "            This script is c930/asic_gf180mcu/build/chip_gates.sh inside the repo;" >&2
  echo "            run it from there (a copy somewhere else has nothing to gate)." >&2
  exit 2
fi
mkdir -p "$LOGDIR" || { echo "chip_gates: cannot create $LOGDIR" >&2; exit 2; }

echo "ROOT      $ROOT"
echo "IVERILOG  $( { iverilog -V 2>/dev/null || echo 'not found'; } | head -1)"
echo "GATES     $LOGDIR/<gate>.log"
[ -n "${CACHE_LOCKSTEP_GITIGNORED_ABSENT:-}" ] && \
  echo "NOTE      rv64imac/FPGA/src is absent (a checkout): the lockstep gate will report it as a counted SKIP"
echo

fail=0
pass=0
blocked=0
ran=0
rows=""

while IFS='|' read -r name dir cmd expect pattern tools; do
  [ -n "$name" ] || continue
  if [ ${#only[@]} -gt 0 ] && ! in_only "$name"; then continue; fi
  ran=$((ran + 1))

  lack=$(missing_tools "$tools")
  if [ -n "$lack" ]; then
    echo "GATE $name: BLOCKED (not on PATH: ${lack% })"
    annotate "$name is BLOCKED: missing ${lack% }"
    rows="${rows}| $name | BLOCKED (missing ${lack% }) |
"
    blocked=$((blocked + 1)); fail=1
    continue
  fi

  log="$LOGDIR/$name.log"
  ( cd "$ROOT/$dir" && eval "$cmd" ) > "$log" 2>&1
  rc=$?
  # -F, not a regex: the patterns are the literal lines that have to be in the
  # log, and `[PASS] tb_dcache_mmio_hold` as a regex is a character class that
  # matches neither -- a gate reporting FAIL over a log that passed, which is how
  # this cost a run.
  evidence=$(grep -aF -- "$pattern" "$log" | tail -1 || true)
  # The lockstep gate says in its own log how much of itself it could check; that
  # belongs in the verdict, not in a log nobody opens.
  note=$(grep -a '^SKIPPED' "$log" | head -1 || true)

  if [ "$expect" = fail ]; then
    # This gate's PASS is the sim failing, and failing for its own reason: the
    # evidence line has to be there too, or a crash would read as a clean control.
    if [ $rc -ne 0 ] && [ -n "$evidence" ]; then
      echo "GATE $name: PASS (must fail, and did: $evidence)"
      rows="${rows}| $name | must fail, and did: $evidence |
"
      pass=$((pass + 1))
    else
      echo "GATE $name: FAIL (expected the command to FAIL with '$pattern' in $name.log; rc=$rc, evidence: ${evidence:-none})"
      annotate "$name: the ROM control did not fail as required (rc=$rc) -- the boot PASS above is not the ROM's"
      rows="${rows}| $name | FAIL: expected failure, rc=$rc, evidence: ${evidence:-none} |
"
      fail=1
    fi
  else
    if [ $rc -eq 0 ] && [ -n "$evidence" ]; then
      echo "GATE $name: PASS ($evidence${note:+ -- $note})"
      rows="${rows}| $name | $evidence${note:+ $note} |
"
      pass=$((pass + 1))
    else
      echo "GATE $name: FAIL (rc=$rc, expected '$pattern' in $name.log, evidence: ${evidence:-none})"
      annotate "$name failed (rc=$rc): $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
      rows="${rows}| $name | FAIL (rc=$rc, no '$pattern') |
"
      fail=1
    fi
  fi

  if [ $fail -ne 0 ] && [ -f "$log" ]; then
    echo "      log: $log -- last 6 lines:"
    tail -6 "$log" | sed 's/^/      | /'
  fi
done < <(printf '%s\n' "$GATES")

verdict=$([ $fail -eq 0 ] && echo PASS || echo FAIL)
[ $fail -ne 0 ] && echo
echo "CHIP GATES: $verdict -- $pass passed, $((ran - pass - blocked)) failed, $blocked blocked (of $ran run)"

# The same table CI posts: to the step summary when there is one, and to a file
# beside the logs always, so a box run leaves the artifact a CI run leaves too.
{
  echo "## Chip gates"
  echo
  echo "| gate | evidence |"
  echo "|---|---|"
  printf '%s' "$rows"
  echo
  echo "CHIP GATES: **$verdict** -- $pass passed, $((ran - pass - blocked)) failed, $blocked blocked"
} > "$LOGDIR/chip_gates_summary.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$LOGDIR/chip_gates_summary.md" >> "$GITHUB_STEP_SUMMARY"
fi
echo "SUMMARY   $LOGDIR/chip_gates_summary.md"

exit $fail
