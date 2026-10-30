#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# drt_curve_guard_selftest.sh -- drive build/drt_curve_guard.sh through every
# branch that can stop a run, and prove the ones that must not stop one do not.
#
# WHY THIS EXISTS
#
#   The guard's failure modes are asymmetric and both are expensive. A guard that
#   never fires leaves a pass running for days, which is the thing it was built to
#   prevent. A guard that fires on a healthy run kills a pass that was about to
#   converge, and -- because the flow writes its ODB only at the END of a pass --
#   throws the whole database away. Neither shows up in a log that looks green, so
#   every threshold is exercised here against a synthetic curve that carries the
#   numbers this project actually measured.
#
# WHAT IT DRIVES
#
#   * the arm: a `DRT-0195 Start 0th` plus the initial route's `DRT-0199`;
#   * a descent that must NOT stop (1,081,775 -> 237,089, the v8 shape);
#   * the regression stop on 237,089 -> 649,172 (+174 %, v8's own collapse);
#   * an iteration still running past ITER_BUDGET_S (the 16-27 h failure);
#   * an iteration that stops printing mid-route, stopped as NO_PROGRESS before
#     the wall clock is anywhere near due -- and the two cases where it must NOT
#     fire: a BATCHED log (8 KB stdout blocks, which look identical to a stall)
#     and STALL_LOG_S=0;
#   * a pass past PASS_BUDGET_S, both on a count and while still in flight;
#   * the plateau rule at 0.01 %/iteration, and that STALL_ITERS=0 turns it off;
#   * a NEW pass starting above the old pass's best, which must NOT stop;
#   * the hours-long antenna repair between two passes, which must NOT be read as
#     one iteration running too long (only an OPEN iteration is judged on that
#     clock) while the pass budget still bounds it;
#   * GUARD_STOP=0 (request only) and DRY=1 (would stop);
#   * a log truncated under the guard, and a half-written `= 42` that must not be
#     read as the iteration's count;
#   * retirement when the container is gone;
#   * the start/stop helper (one process per tag, stale pidfile, verdict);
#   * that every chain launching a flow DRT container is wired to the guard, and
#     that the same check fails on deliberately unwired copies.
#
#   Nothing here touches a real container or the campaign tree: `docker` is a stub
#   first on PATH, every path is rewritten under a mktemp ROOT, and the guard's
#   clock is pinned with CURVE_NOW so a day of wall time costs nothing.
#
#   bash build/drt_curve_guard_selftest.sh
#
# Exit 0 only when every case passed. Runs in CI as row `drt-curve-guard` of
# build/chain_selftests.sh.
set -u
export MSYS_NO_PATHCONV=1

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
G=$HERE/drt_curve_guard.sh
H=$HERE/curve_guard.sh
T=$(mktemp -d) || { echo "drt_curve_guard_selftest: cannot create a temp dir" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

R=$T/root
WS=$R/ws
STEPDIR=$WS/template/librelane/runs/T/06-openroad-detailedrouting
LOG=$STEPDIR/openroad-detailedrouting.log
GL=$WS/logs/drt_curve_guard.log
mkdir -p "$WS/logs" "$STEPDIR" "$T/bin"
: > "$LOG"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }
has() {  # has <file> <literal>
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$(basename "$1"): has '$2'"; else bad "$(basename "$1"): missing '$2'"; fi
}
hasnt() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$(basename "$1"): has '$2' (must not)"; else ok "$(basename "$1"): no '$2'"; fi
}
killed() {  # killed <n> -- exactly n docker kill calls recorded
  local n=0
  [ -f "$T/docker.log" ] && n=$(grep -c 'DOCKER kill' "$T/docker.log" || true)
  if [ "$n" = "$1" ]; then ok "docker kill calls = $n"; else bad "docker kill calls = $n, wanted $1"; fi
}

# The stub that makes "it stopped the run" and "it touched nothing" assertions
# instead of claims. `ps` answers with DOCKER_PS, or with nothing (the retired
# case); everything else -- kill included -- only gets recorded.
cat > "$T/bin/docker" <<'STUB'
#!/bin/bash
{ printf 'DOCKER'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${DOCKER_LOG:-/dev/null}"
case ${1:-} in ps) [ -n "${DOCKER_PS:-}" ] && printf '%s\n' "$DOCKER_PS"; exit 0 ;; esac
exit 0
STUB
chmod +x "$T/bin/docker"
# The stub is first on PATH for the WHOLE script, not just for an individual
# evaluation: the guard the start/stop helper launches inherits this environment,
# and a real `docker ps` against a stopped daemon blocks long enough to look like
# a guard that ignores SIGTERM (measured on the first version of this harness).
export PATH="$T/bin:$PATH"
export DOCKER_LOG=$T/docker.log

# One evaluation through the real script. Every case below is a sequence of
# these with a clock it chooses, which is why the wall-clock branches are
# deterministic rather than dependent on a sleep.
GLEN=0
g() {  # g <epoch> [VAR=VAL ...]
  local t=$1; shift
  GLEN=$((GLEN + 1))
  GLOG=$T/eval.$GLEN.log
  env ONE_SHOT=1 CURVE_NOW="$t" ROOT="$R" TAG=T CONTAINER=T "$@" \
    bash "$G" > "$GLOG" 2>&1
  rc=$?
}

reset_all() {
  rm -f "$GL" "$WS/logs/drt_curve_guard.T.state" "$WS/logs/drt_curve_guard.T.verdict" "$T/docker.log"
  : > "$LOG"
  GLEN=0
}

# The router's own lines, from the fixtures the other harnesses use: DRT-0195 and
# DRT-0199 end a line, the progress line ends with a carriage return.
mark() {  # mark <iteration>
  if [ "$1" = 0 ]; then
    printf '[INFO DRT-0195] Start 0th optimization iteration.\r' >> "$LOG"
  else
    printf '[INFO DRT-0195] Start %dth optimization iteration.\r' "$1" >> "$LOG"
  fi
}
result() { printf '    Completing 100%% with %s violations.\r[INFO DRT-0199]   Number of violations = %s.\n' "$1" "$1" >> "$LOG"; }
# A mid-iteration progress line: bytes the guard does not parse (no marker), which
# is exactly what a liveness test needs -- it proves the router is printing
# without moving the curve.
prog() { printf '    Completing %s%% with %s violations.\r' "$1" "$2" >> "$LOG"; }
step() { mark "$1"; result "$2"; }

T0=1700000000
VERDICT=$WS/logs/drt_curve_guard.T.verdict

# --------------------------------------------------------------- 1. no step ---
rm -f "$T/docker.log"
mv "$STEPDIR" "$T/step_away"
g "$T0"
has "$GL" "CURVE_WAIT step_dir_absent"
killed 0
mv "$T/step_away" "$STEPDIR"

# ------------------------------------------------------------ 2. no log yet ---
rm -f "$T/docker.log"
mv "$LOG" "$T/log_away" 2>/dev/null || true
g "$T0"
has "$GL" "CURVE_LOG_ABSENT"
killed 0
[ -f "$T/log_away" ] && mv "$T/log_away" "$LOG"
: > "$LOG"

# ------------------------------------------------- 3. arm and a real descent ---
# v8's first three points: 1,081,775 -> 237,089, then the collapse in case 4.
reset_all
mark 0; result 1081775
g "$T0"
has "$GL" "CURVE_PASS pass=1"
has "$GL" "CURVE_COUNT pass=1 iter=0 count=1081775 best=0"
killed 0

mark 1
g "$T0"
has "$GL" "CURVE_ITER pass=1 iter=1"
result 237089
g $((T0 + 1565))
has "$GL" "CURVE_COUNT pass=1 iter=1 count=237089 best=1081775 wall_s=1565"
killed 0

# ------------------------------------------------------ 4. the regression stop --
# 237,089 -> 649,172 in one iteration is +174 %. This is the 2.74x collapse that
# ended v8, and the reason a count is not allowed to run unwatched.
mark 2
g $((T0 + 1565))
result 649172
g $((T0 + 3130))
has "$GL" "CURVE_STOPPED reason=REGRESSION"
has "$GL" "prev_best=237089"
killed 1
has "$VERDICT" "STOPPED reason=REGRESSION"

# ------------------------------------ 5. an iteration still running too long ---
reset_all
step 0 1000000
g "$T0" ITER_BUDGET_S=600
mark 1
g "$T0" ITER_BUDGET_S=600
g $((T0 + 601)) ITER_BUDGET_S=600
has "$GL" "CURVE_STOPPED reason=ITER_BUDGET at=inflight"
killed 1
# A COMPLETED iteration over the budget is recorded, not punished: it already
# finished and the pass may still be worth finishing.
reset_all
step 0 1000000
g "$T0" ITER_BUDGET_S=600
mark 1
g "$T0" ITER_BUDGET_S=600
result 900000
g $((T0 + 601)) ITER_BUDGET_S=600
has "$GL" "CURVE_ITER_SLOW"
hasnt "$GL" "CURVE_STOPPED"
killed 0

# -------------------------------------- 5b. an iteration that stops printing ---
# The gap no count-based rule can see: iteration 1 printed its deciles and then
# went silent while the router still held the core. On diecg01 that silence began
# at `Completing 90%` and lasted two hours, and the only thing left to catch it was
# ITER_BUDGET_S at its ceiling. Here the same shape is stopped in 30 minutes.
reset_all
step 0 1000000
g "$T0" ITER_BUDGET_S=7200 STALL_LOG_S=1800
mark 1
g "$T0" ITER_BUDGET_S=7200 STALL_LOG_S=1800
prog 10 900000
g $((T0 + 120)) ITER_BUDGET_S=7200 STALL_LOG_S=1800
prog 20 800000
g $((T0 + 240)) ITER_BUDGET_S=7200 STALL_LOG_S=1800
hasnt "$GL" "CURVE_STOPPED"
# 1,801 s after the last byte -- a fifth of the wall-clock budget -- with the
# iteration nowhere near its 7,200 s ceiling.
g $((T0 + 2041)) ITER_BUDGET_S=7200 STALL_LOG_S=1800
has "$GL" "CURVE_STOPPED reason=NO_PROGRESS at=inflight"
has "$GL" "stall_log_s=1800 silent_s=1801"
has "$VERDICT" "STOPPED reason=NO_PROGRESS"
killed 1

# --------------------------------- 5c. a BATCHED log is not a silent router -----
# OpenROAD writes through a fully-buffered stdout, so a healthy log can sit
# unchanged for hours: on diecg01, 182 lines arrived in one flush after 42 minutes
# of nothing, and iteration 0's count and iteration 1's start carried the same
# timestamp (`wall_s=0`). This is that shape -- every flush carries a start, none
# arrives mid-iteration -- and it must NOT be stopped, or the guard kills a
# healthy pass on every arm.
reset_all
step 0 1000000
g "$T0" ITER_BUDGET_S=7200 STALL_LOG_S=1800
mark 1
g $((T0 + 1000)) ITER_BUDGET_S=7200 STALL_LOG_S=1800
g $((T0 + 6000)) ITER_BUDGET_S=7200 STALL_LOG_S=1800
hasnt "$GL" "CURVE_STOPPED"
has "$GL" "CURVE_NO_PROGRESS_UNOBSERVED"
killed 0

# ------------------------------------------ 5d. and STALL_LOG_S=0 turns it off --
reset_all
step 0 1000000
g "$T0" STALL_LOG_S=0
mark 1
g "$T0" STALL_LOG_S=0
prog 10 900000
g $((T0 + 120)) STALL_LOG_S=0
g $((T0 + 2041)) STALL_LOG_S=0
hasnt "$GL" "CURVE_STOPPED"
killed 0

# ------------------------------------------------------- 6. the pass budget ----
# In flight: nothing has come out of the pass since it started.
reset_all
step 0 1000000
g "$T0" PASS_BUDGET_S=900 ITER_BUDGET_S=600
g $((T0 + 901)) PASS_BUDGET_S=900 ITER_BUDGET_S=600
has "$GL" "CURVE_STOPPED reason=PASS_BUDGET at=inflight"
killed 1
# Completed: the count itself arrives after the pass has spent its budget.
reset_all
step 0 1000000
g "$T0" PASS_BUDGET_S=900 ITER_BUDGET_S=600
mark 1
g "$T0" PASS_BUDGET_S=900 ITER_BUDGET_S=600
result 900000
g $((T0 + 950)) PASS_BUDGET_S=900 ITER_BUDGET_S=600
has "$GL" "CURVE_STOPPED reason=PASS_BUDGET at=completed"
killed 1

# ------------------------------------------------------------ 7. the plateau --
# 0.01 % per iteration: at 250k violations that is 25 violations for 26 minutes.
reset_all
step 0 1000000
g "$T0"
for i in 1 2 3; do
  mark "$i"
  g $((T0 + i * 10))
  result $((1000000 - i * 100))
  g $((T0 + i * 10 + 5))
done
has "$GL" "CURVE_STOPPED reason=STALL"
killed 1

# ------------------------------------------- 8. ... and how to turn it off -----
# A deliberate asymptote measurement (the 0.2 vs 0.3 falsifier) must be able to
# run a flat curve without being stopped; STALL_ITERS=0 is that switch.
reset_all
step 0 1000000
g "$T0" STALL_ITERS=0
for i in 1 2 3; do
  mark "$i"
  g $((T0 + i * 10)) STALL_ITERS=0
  result $((1000000 - i * 100))
  g $((T0 + i * 10 + 5)) STALL_ITERS=0
done
hasnt "$GL" "CURVE_STOPPED"
killed 0

# --------------------------------------------------- 9. a new pass is exempt ---
# After diode insertion the router re-routes and legitimately starts ABOVE the
# previous pass's best. A best carried across passes would kill that arm.
reset_all
step 0 500000
g "$T0"
mark 1
g "$T0"
result 250000
g $((T0 + 10))
step 0 260000
g $((T0 + 20))
has "$GL" "CURVE_PASS pass=2"
hasnt "$GL" "CURVE_STOPPED"
killed 0

# ------------------ 9b. the gap between passes is not an overrunning iteration --
# The step runs its own antenna check/repair between passes, and that can take
# hours with no DRT-0195 in the log. Only an OPEN iteration may be judged on the
# iteration clock; reading that gap as a 20-hour iteration would kill a pass for
# doing the repair it was asked to do. The pass budget is what covers the gap.
reset_all
step 0 500000
g "$T0" ITER_BUDGET_S=600 PASS_BUDGET_S=28800
mark 1
g "$T0" ITER_BUDGET_S=600 PASS_BUDGET_S=28800
result 400000
g $((T0 + 60)) ITER_BUDGET_S=600 PASS_BUDGET_S=28800
g $((T0 + 3600)) ITER_BUDGET_S=600 PASS_BUDGET_S=28800
hasnt "$GL" "CURVE_STOPPED"
killed 0
mark 1
g $((T0 + 3700)) ITER_BUDGET_S=600 PASS_BUDGET_S=28800
has "$GL" "CURVE_ITER pass=1 iter=1"
hasnt "$GL" "CURVE_STOPPED"
killed 0
# ... and a gap that outlasts the whole pass is still stopped, by the pass budget.
# The iteration is closed first: with one open, the no-progress rule would own
# this stop (7 h of silence on an open iteration is a stall, and naming it that
# is the point of case 5b). What is under test here is the repair gap.
result 390000
g $((T0 + 3800)) ITER_BUDGET_S=600 PASS_BUDGET_S=28800
g $((T0 + 29000)) ITER_BUDGET_S=600 PASS_BUDGET_S=28800
has "$GL" "CURVE_STOPPED reason=PASS_BUDGET at=inflight"
killed 1

# ----------------------------------------- 10. request only, and a dry run -----
reset_all
step 0 100
g "$T0" GUARD_STOP=0
mark 1
g "$T0" GUARD_STOP=0
result 200
g $((T0 + 10)) GUARD_STOP=0
has "$GL" "CURVE_STOP_REQUEST reason=REGRESSION"
has "$VERDICT" "REQUEST reason=REGRESSION"
killed 0
reset_all
step 0 100
g "$T0" DRY=1
mark 1
g "$T0" DRY=1
result 200
g $((T0 + 10)) DRY=1
has "$GL" "WOULD_STOP reason=REGRESSION"
killed 0

# ------------------------------------------------------ 11. log truncated -----
# A rewritten log is a new curve, not an offset that happens to fit.
reset_all
step 0 500000
g "$T0"
mark 1
g "$T0"
result 400000
g $((T0 + 10))
: > "$LOG"
step 0 900000
g $((T0 + 20))
has "$GL" "CURVE_LOG_TRUNCATED"
has "$GL" "count=900000"
killed 0

# ------------------------------------------- 12. a half-written count line -----
# `= 42` from `= 421043` would set a best the router never had. The guard must
# hold the line back until its newline arrives.
reset_all
mark 0
g "$T0"
printf '[INFO DRT-0199]   Number of violations = 42' >> "$LOG"
g $((T0 + 10))
if grep -qE 'CURVE_COUNT .*count=42([^0-9]|$)' "$GL"; then bad "the partial line was parsed as count=42"; else ok "the partial line was held back"; fi
hasnt "$GL" "CURVE_COUNT"
printf '1043.\n' >> "$LOG"
g $((T0 + 20))
has "$GL" "CURVE_COUNT pass=1 iter=0 count=421043"
killed 0

# ------------------------------------------- 13. it retires with its container --
R3=$T/root3
mkdir -p "$R3/ws/logs" "$R3/ws/template/librelane/runs/T/06-openroad-detailedrouting"
rm -f "$T/docker.log"
ROOT="$R3" TAG=T CONTAINER=T POLL=1 bash "$G" >> "$T/loop.log" 2>&1 &
lp=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "$lp" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$lp" 2>/dev/null; then
  bad "the guard was still running with its container gone"
  kill -9 "$lp" 2>/dev/null
else
  wait "$lp" 2>/dev/null
  ok "the guard retired (exit $?)"
fi
has "$R3/ws/logs/drt_curve_guard.log" "CURVE_EXIT container_gone"
killed 0

# ------------------------------------------------------ 14. start/stop helper --
# A fresh ROOT with no run tree: the guard waits and cannot act, so this case is
# about the pidfile contract only.
R4=$T/root4
mkdir -p "$R4/ws/logs"
say() { printf '%s\n' "$*" >> "$T/helper.log"; }
(
  ROOT=$R4 WS=$R4/ws
  # shellcheck source=curve_guard.sh
  . "$H"
  curve_guard_start T T
  p1=$(curve_guard_pid T)
  curve_guard_start T T          # idempotent: same process, not a second one
  p2=$(curve_guard_pid T)
  [ -n "$p1" ] && [ "$p1" = "$p2" ] && echo "HELPER one pid $p1" || echo "HELPER pid mismatch '$p1' vs '$p2'"
  [ "$(grep -c 'CURVE_GUARD_ALREADY_RUNNING' "$T/helper.log" || true)" = 1 ] \
    && echo "HELPER idempotent" || echo "HELPER not idempotent"
  curve_guard_stop T
  [ -z "$(curve_guard_pid T)" ] && echo "HELPER stopped" || echo "HELPER still running"
  curve_guard_stop T
  echo "HELPER verdict $(curve_guard_verdict T)"
) > "$T/helper.out" 2>&1
has "$T/helper.out" "HELPER one pid"
has "$T/helper.out" "HELPER idempotent"
has "$T/helper.out" "HELPER stopped"
has "$T/helper.out" "HELPER verdict none"
has "$T/helper.log" "CURVE_GUARD_STOPPED tag=T (not running)"

# --------------------------------------------------------------- 15. wiring ---
# The guard is only worth having if the chains that run a flow DRT start it. The
# registry is deliberately written out here rather than inferred: a chain's
# `docker run --name` can name a fast loop that must NOT be guarded, and guessing
# from it is how an exemption becomes a silent gap.
wiring() {  # wiring <build dir> -- prints one line per failure, 0 = wired
  local dir=$1 f c nbad=0
  while read -r f c; do
    [ -n "$f" ] || continue
    [ -f "$dir/$f" ] || { printf '%s: missing\n' "$f"; nbad=$((nbad + 1)); continue; }
    grep -qE '^[[:space:]]*\.[[:space:]]+.*curve_guard\.sh' "$dir/$f" \
      || { printf '%s: does not source curve_guard.sh\n' "$f"; nbad=$((nbad + 1)); }
    grep -qE "^[[:space:]]*curve_guard_start[[:space:]]+\"?\\\$[A-Za-z_][A-Za-z0-9_]*\"?[[:space:]]+$c([[:space:]]|$)" "$dir/$f" \
      || { printf '%s: does not curve_guard_start the container it launches (%s)\n' "$f" "$c"; nbad=$((nbad + 1)); }
    grep -qE '^[[:space:]]*curve_guard_stop[[:space:]]' "$dir/$f" \
      || { printf '%s: never stops the guard\n' "$f"; nbad=$((nbad + 1)); }
    grep -q 'curve_guard_stop' <(sed -n '/^on_exit()/,/^}/p' "$dir/$f" 2>/dev/null) \
      || { printf '%s: the EXIT trap does not stop the guard\n' "$f"; nbad=$((nbad + 1)); }
  done <<'REG'
ws_chain.sh ws_flow
die_drt_chain.sh die_predrt
REG
  [ "$nbad" = 0 ]
}

if wiring "$HERE" > "$T/wiring.out" 2>&1; then ok "every flow-DRT chain is wired to the curve guard"; else
  bad "a flow-DRT chain is not wired: $(tr '\n' ' ' < "$T/wiring.out")"
fi

mkdir -p "$T/neg"
for mut in nostart nostop nosource; do
  mkdir -p "$T/neg/$mut"
  cp "$HERE/ws_chain.sh" "$T/neg/$mut/ws_chain.sh"
  cp "$HERE/die_drt_chain.sh" "$T/neg/$mut/die_drt_chain.sh"
  case $mut in
    nostart)  sed -i '/^[[:space:]]*curve_guard_start[[:space:]]/d' "$T/neg/$mut/ws_chain.sh" ;;
    nostop)   sed -i '/^[[:space:]]*curve_guard_stop[[:space:]]/d' "$T/neg/$mut/ws_chain.sh" ;;
    nosource) sed -i '/curve_guard\.sh/d' "$T/neg/$mut/ws_chain.sh" ;;
  esac
done
for mut in nostart nostop nosource; do
  if ! wiring "$T/neg/$mut" > "$T/neg/$mut.out" 2>&1; then ok "the wiring check catches a chain with no $mut"; else
    bad "the wiring check passed a chain with no $mut"
  fi
done

echo
echo "DRT_CURVE_GUARD_SELFTEST pass=$pass fail=$fail"
[ "$fail" = 0 ]
