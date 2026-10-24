#!/usr/bin/env bash
# chain_selftests.sh -- the selftests behind the chains and the gates, in one
# command, for CI on every push.
#
# WHY THESE ARE NOT IN chip_gates.sh
#
#   chip_gates.sh is the one definition of the design gates, and it is run in two
#   places: CI, and .githooks/pre-push -- which, on this checkout, is Git Bash on
#   Windows. These are shell harnesses written for a Linux box: die_launch_selftest.sh
#   needs a pgrep and a coreutils timeout, and several of them put a stub `docker`
#   and a stub `memwatch` first on PATH. Git Bash has no pgrep and a `timeout.exe`
#   that is not coreutils', so running them there answers BLOCKED for a reason that
#   says nothing about the chains. So the split is by platform, not by importance:
#   chip_gates.sh is what runs everywhere, this is what runs where the harnesses
#   work -- a Linux checkout. CI is that checkout; the workflow job is
#   `chain-selftests` in .github/workflows/build-gf180mcu.yml.
#
# WHAT THEY ARE
#
#   Each *_selftest.sh next to the script it guards -- die_diode_flow_chain.sh,
#   die_drt_chain.sh, gate.sh, drt_disk_guard.sh (with disk_guard.sh, the helper
#   the chains call), drt_extend_ws.sh, stage_tapeout_config.sh,
#   stage_tapeout_watch.sh, lvs_check.sh, tools/lvs_switch_check.py and
#   tools/lvs_chip/net_compare.py. None of them routes anything or launches a
#   container: docker is a stub first on PATH and every call is recorded, which is
#   what makes "it launched nothing" an assertion rather than a hope. What they
#   check is the part that has no other witness -- that each chain still calls the
#   shared gate instead of growing its own, that it refuses and names the reason
#   when the box cannot carry the job, that the die arm announces its own launch
#   with the line its parent waits for, that every arm-starter still starts the DRT
#   disk guard (and stops it on every way out), that the reports are rewritten from
#   the logs actually on disk, and that every staged copy differs from the delivered
#   file only in the destinations the test rewrote.
#
#   They are here because the failure they catch is not a wrong number -- it is a
#   chain that launches nothing, or launches a second arm over a live one, hours
#   into an unattended run. `bash build/die_launch_selftest.sh` found exactly that
#   on 2026-10-22; the point of wiring it in is that the next edit to a chain is
#   answered on the push, not on the box after the arm has been waited for.
#
# THE ONE THAT IS NOT HERE
#
#   build/drt_db_compare_selftest.sh. Its fixtures are the campaign's own databases
#   and their run trees under ws/, which no checkout contains (runs/ is ignored),
#   so on a clean tree it can only report that the inputs are absent -- 19 of its
#   25 assertions. It stays a box test: `bash build/drt_db_compare_selftest.sh` in
#   c930/asic_gf180mcu/ on the box, where those inputs are.
#
# WHAT THE EVIDENCE PATTERN IS
#
#   chip_gates.sh matches a literal line with grep -F. That does not work here: every
#   one of these harnesses prints its case count, so the green line changes with
#   every case added ("gate_selftest: pass=149"). The pattern is therefore a regex,
#   read with grep -E, and every one of them is anchored at the start of the line and
#   requires zero failures with at least one case -- `pass=[1-9][0-9]* fail=0`,
#   `[1-9][0-9]* passed, 0 failed`. The FAIL lines print `GATE_SELFTEST FAIL pass=9`
#   and `== 44 passed, 9 failed`, so neither can match. The exit status alone is not
#   enough -- a harness that dies on the way in exits non-zero too -- and the count
#   is the point: it is the difference between "checked 149 things" and "checked
#   nothing and said so".
#
# WHERE THE LOGS GO
#
#   c930/asic_gf180mcu/build/chain_selftests/<test>.log, so "what did it actually
#   say?" has the same answer on the box and in the uploaded CI artifact, and
#   c930/asic_gf180mcu/build/chain_selftests_summary.md -- beside that directory, not
#   in it, the way chip_gates_summary.md sits beside its logs -- for the table the
#   step summary also gets. The upload paths in the workflow name that file, so its
#   location is part of the contract, not a detail.
#
# A BOX RUN IS THE SAME RUN
#
#   bash c930/asic_gf180mcu/build/chain_selftests.sh                 # all nine
#   bash c930/asic_gf180mcu/build/chain_selftests.sh --list          # names only
#   bash c930/asic_gf180mcu/build/chain_selftests.sh --only gate-wiring
#   CHAIN_SELFTEST_TIMEOUT=600 bash ...                    # per test, seconds
#
#   Safe to run on the box while an arm is in flight, in the sense the harnesses
#   themselves are: nothing outside a mktemp tree is written and no container is
#   touched. The exception is die_launch_selftest.sh's 50 s slow-arm case, which is
#   deliberate and is most of this script's run time (about two minutes of the three).
#
# EXIT STATUS
#
#   0 only when every test ran and passed -- as with chip_gates.sh, a test whose
#   tools are missing reports BLOCKED, which is a failure: a test that could not run
#   must never read as one that passed. 2 is a usage error or a non-Linux host.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)          # c930/asic_gf180mcu/build -> repo root
LOGDIR="$ROOT/c930/asic_gf180mcu/build/chain_selftests"
SUMMARY="$ROOT/c930/asic_gf180mcu/build/chain_selftests_summary.md"
CST_TIMEOUT=${CHAIN_SELFTEST_TIMEOUT:-300}

# name | working dir | command | evidence regex | tools
TESTS=$(cat <<'EOF'
die-launch-handshake|c930/asic_gf180mcu|bash build/die_launch_selftest.sh|^DIE_LAUNCH_SELFTEST pass=[1-9][0-9]* fail=0|bash pgrep timeout
gate-wiring|c930/asic_gf180mcu|bash build/gate_selftest.sh|^GATE_SELFTEST pass=[1-9][0-9]* fail=0|bash df
disk-guard|c930/asic_gf180mcu|bash build/drt_disk_guard_selftest.sh|^DISK_GUARD_SELFTEST pass=[1-9][0-9]* fail=0|bash
drt-extend|c930/asic_gf180mcu|bash wafer_space_integration/extend_selftest.sh|^extend_selftest: [1-9][0-9]* passed, 0 failed|bash
stage-tapeout-watch|c930/asic_gf180mcu|bash build/stage_tapeout_watch_selftest.sh|^== [1-9][0-9]* passed, 0 failed|bash
stage-tapeout-config|c930/asic_gf180mcu|bash build/stage_tapeout_config_selftest.sh|^== [1-9][0-9]* passed, 0 failed|bash
lvs-gate-statuses|c930/asic_gf180mcu|bash build/lvs_check_selftest.sh|^LVS_CHECK_SELFTEST pass=[1-9][0-9]* fail=0|bash python3
lvs-switches|c930/asic_gf180mcu|bash build/lvs_switch_check_selftest.sh|^LVS_SWITCH_CHECK_SELFTEST pass=[1-9][0-9]* fail=0|bash python3
lvs-net-compare|c930/asic_gf180mcu|bash build/lvs_chip_net_compare_selftest.sh|^net_compare_selftest: [1-9][0-9]* passed, 0 failed|bash python3
EOF
)

only=()
list_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) list_only=1; shift ;;
    --only)
      [ $# -ge 2 ] || { echo "chain_selftests: --only needs a test name (see --list)" >&2; exit 2; }
      only+=( "$2" ); shift 2 ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0"; exit 0 ;;
    *) echo "chain_selftests: unknown argument: $1 (try --list or --help)" >&2; exit 2 ;;
  esac
done

in_only() {  # name -> 0 when this run was asked for that test
  local n
  for n in ${only[@]+"${only[@]}"}; do [ "$n" = "$1" ] && return 0; done
  return 1
}

if [ $list_only -eq 1 ]; then
  while IFS='|' read -r name _rest; do [ -n "$name" ] && echo "$name"; done < <(printf '%s\n' "$TESTS")
  exit 0
fi

if [ ${#only[@]} -gt 0 ]; then
  for want in "${only[@]}"; do
    found=0
    while IFS='|' read -r name _rest; do
      [ "$name" = "$want" ] && { found=1; break; }
    done < <(printf '%s\n' "$TESTS")
    [ $found -eq 1 ] || { echo "chain_selftests: no such test: $want (see --list)" >&2; exit 2; }
  done
fi

# Not a platform check for its own sake: every harness here assumes Linux (/proc
# through pgrep, coreutils' timeout, a `docker` stub reachable through PATH), and on
# anything else the answer would be nine BLOCKED lines that look like nine broken
# chains. Say what is true once, and stop.
if [ "$(uname -s 2>/dev/null)" != Linux ]; then
  cat >&2 <<EOF
chain_selftests: these harnesses need Linux (pgrep, coreutils timeout); this host is '$(uname -s 2>/dev/null)'.
                 Run them in CI, or on the box -- not in the Windows checkout. chip_gates.sh is the
                 definition that runs everywhere, including .githooks/pre-push.
EOF
  exit 2
fi

missing_tools() {  # "tool tool ..." -> prints the ones not on PATH
  local t
  for t in $1; do command -v "$t" >/dev/null 2>&1 || printf '%s ' "$t"; done
}

annotate() {  # message -- a GitHub error annotation when there is a GitHub to read it
  [ "${GITHUB_ACTIONS:-}" = true ] && echo "::error::$1"
  return 0
}

# ROOT comes from this file's own path, so it only means anything when the file is
# where it lives. A copy parked elsewhere would fail test by test for reasons that
# look like test failures.
if [ ! -d "$ROOT/c930/asic_gf180mcu/build" ]; then
  echo "chain_selftests: ROOT resolved to '$ROOT', which is not this repository." >&2
  echo "                 This script is c930/asic_gf180mcu/build/chain_selftests.sh inside it." >&2
  exit 2
fi
mkdir -p "$LOGDIR" || { echo "chain_selftests: cannot create $LOGDIR" >&2; exit 2; }

echo "ROOT      $ROOT"
echo "LOGS      $LOGDIR/<test>.log"
echo "TIMEOUT   ${CST_TIMEOUT}s per test (CHAIN_SELFTEST_TIMEOUT)"
echo

fail=0; pass=0; blocked=0; ran=0
rows=""

while IFS='|' read -r name dir cmd pattern tools; do
  [ -n "$name" ] || continue
  if [ ${#only[@]} -gt 0 ] && ! in_only "$name"; then continue; fi
  ran=$((ran + 1))

  lack=$(missing_tools "$tools")
  if [ -n "$lack" ]; then
    echo "TEST $name: BLOCKED (not on PATH: ${lack% })"
    annotate "$name is BLOCKED: missing ${lack% }"
    rows="${rows}| $name | BLOCKED (missing ${lack% }) |
"
    blocked=$((blocked + 1)); fail=1
    continue
  fi

  log="$LOGDIR/$name.log"
  t0=$(date -u +%s)
  ( cd "$ROOT/$dir" && timeout --kill-after=10 "$CST_TIMEOUT" bash -c "$cmd" ) > "$log" 2>&1
  rc=$?
  t1=$(date -u +%s)
  secs=$((t1 - t0))
  # -E, anchored, zero-failures-and-at-least-one-case: see the header for why this
  # is a regex here and a literal in chip_gates.sh.
  evidence=$(grep -aE -- "$pattern" "$log" | tail -1 || true)

  if [ $rc -eq 0 ] && [ -n "$evidence" ]; then
    echo "TEST $name: PASS in ${secs}s ($evidence)"
    rows="${rows}| $name | PASS in ${secs}s: $evidence |
"
    pass=$((pass + 1))
  elif [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    echo "TEST $name: FAIL (timed out after ${CST_TIMEOUT}s; rc=$rc)"
    annotate "$name timed out after ${CST_TIMEOUT}s"
    rows="${rows}| $name | FAIL: timed out after ${CST_TIMEOUT}s |
"
    fail=1
  else
    echo "TEST $name: FAIL (rc=$rc, expected '$pattern' in $name.log, evidence: ${evidence:-none})"
    annotate "$name failed (rc=$rc): $(grep -aE '^ *FAIL|FAIL ' "$log" 2>/dev/null | head -3 | tr '\n' ' ')"
    rows="${rows}| $name | FAIL (rc=$rc, no matching verdict line) |
"
    fail=1
  fi

  if [ $fail -ne 0 ] && [ -f "$log" ]; then
    echo "      log: $log -- last 6 lines:"
    tail -6 "$log" | sed 's/^/      | /'
  fi
done < <(printf '%s\n' "$TESTS")

verdict=$([ $fail -eq 0 ] && echo PASS || echo FAIL)
[ $fail -ne 0 ] && echo
echo "CHAIN SELFTESTS: $verdict -- $pass passed, $((ran - pass - blocked)) failed, $blocked blocked (of $ran run)"

{
  echo "## Chain selftests"
  echo
  echo "| test | evidence |"
  echo "|---|---|"
  printf '%s' "$rows"
  echo
  echo "CHAIN SELFTESTS: **$verdict** -- $pass passed, $((ran - pass - blocked)) failed, $blocked blocked"
  echo
  echo 'Not run here: `drt_db_compare_selftest.sh` (its fixtures are the campaign'\''s'
  echo 'own databases under ws/, which no checkout contains).'
} > "$SUMMARY"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"
fi
echo "SUMMARY   $SUMMARY"

exit $fail
