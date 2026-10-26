#!/bin/bash
# curve_guard.sh -- start and stop the DRT curve guard from a chain, written ONCE
# and sourced by every chain that launches a flow DRT container.
#
# WHY THIS FILE EXISTS
#
#   `drt_curve_guard.sh` stops a detailed-routing pass that has stopped paying
#   for itself: an iteration still running hours after the measured cost, a pass
#   over its wall-clock budget, a count that gives back a quarter of the best
#   route the pass already found, or a plateau that keeps buying fractions of a
#   percent. It is a separate process because the pass it watches runs for hours
#   to days and must be bounded while it runs, not at launch time.
#
#   That "start it, and be sure it stops" pair is the same problem `disk_guard.sh`
#   solved for the disk guard: copied into each chain it is six copies of one
#   decision, and the failure is quiet -- an arm running with no bound still looks
#   healthy right up to the iteration that takes 20 hours. So the launch line, the
#   pidfile convention and the stop are here once:
#
#     * one guard per run tag (`ws/logs/drt_curve_guard.<tag>.pid`), and a second
#       `curve_guard_start` for the same tag is a no-op that says so;
#     * START is idempotent, so a parent chain and its child can both ask;
#     * STOP is safe on a guard that already retired, and removes a stale pidfile;
#     * CURVE_GUARD=0 disables both, which is how the selftests run the real
#       chains without spawning a poller.
#
# USAGE (in a chain, after `say`, ROOT and WS are defined)
#
#   . $ROOT/build/curve_guard.sh
#   curve_guard_start "$TAG" ws_flow      # the moment the container is up
#   curve_guard_stop  "$TAG"              # on the way out, including aborts
#   curve_guard_verdict "$TAG"            # the one line it left, for the report
#
#   The caller's own `say` is used (bash resolves it when the function runs, not
#   at source time), so this must be sourced after `say` exists -- the same
#   contract gate.sh and disk_guard.sh state.
#
#   Budgets are the caller's environment if it sets them (ITER_BUDGET_S,
#   PASS_BUDGET_S, REGRESS_PCT, STALL_ITERS, STALL_BP, CURVE_POLL, GUARD_STOP,
#   DRY); otherwise the guard's own measured defaults apply and this file forwards
#   nothing. There is one copy of each default, in drt_curve_guard.sh.
#
# A missing guard script is REPORTED, not fatal: the arm is the work, this is
# protection against a step that burns days, and refusing to run a three-day arm
# because its guard is absent would be the worse trade. CURVE_GUARD_MISSING in a
# chain log is the signal to install it.
#
# VERIFY IT
#
#   bash build/drt_curve_guard_selftest.sh -- cases 12-15 drive start/stop/
#   idempotency/verdict through this file with the real guard script in a temp
#   ROOT, and prove that a second start does not produce a second process.
CG_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CURVE_GUARD=${CURVE_GUARD:-1}
CG_ROOT=${CG_ROOT:-${ROOT:-/home/ubuntu/grx930_ol2}}
CG_WS=${WS:-$CG_ROOT/ws}
CG_SCRIPT=${CG_SCRIPT:-$CG_DIR/drt_curve_guard.sh}
CG_LOG=${CG_LOG:-$CG_WS/logs/drt_curve_guard.log}
CG_NOHUP=${CG_NOHUP:-$CG_WS/logs/drt_curve_guard.nohup}

curve_guard_pidfile() { printf '%s\n' "$CG_WS/logs/drt_curve_guard.$1.pid"; }
curve_guard_state()   { printf '%s\n' "$CG_WS/logs/drt_curve_guard.$1.state"; }
curve_guard_verdictfile() { printf '%s\n' "$CG_WS/logs/drt_curve_guard.$1.verdict"; }

curve_guard_pid() {  # $1 = tag -> prints the live pid, or nothing
  local pf p
  pf=$(curve_guard_pidfile "$1")
  [ -s "$pf" ] || return 0
  p=$(cat "$pf" 2>/dev/null)
  case "${p:-}" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$p" 2>/dev/null || return 0
  printf '%s\n' "$p"
}

curve_guard_start() {  # curve_guard_start <tag> [container]
  local tag=${1:?tag} con=${2:-ws_flow} pf p
  local -a envs
  pf=$(curve_guard_pidfile "$tag")
  if [ "$CURVE_GUARD" != 1 ]; then say "CURVE_GUARD_DISABLED tag=$tag (CURVE_GUARD=0)"; return 0; fi
  if [ ! -f "$CG_SCRIPT" ]; then say "CURVE_GUARD_MISSING $CG_SCRIPT -- the arm runs with no wall-clock or regression bound"; return 1; fi
  p=$(curve_guard_pid "$tag")
  if [ -n "$p" ]; then say "CURVE_GUARD_ALREADY_RUNNING tag=$tag pid=$p"; return 0; fi
  [ -s "$pf" ] && say "CURVE_GUARD_STALE_PIDFILE tag=$tag pid=$(cat "$pf" 2>/dev/null || echo none)"
  mkdir -p "$CG_WS/logs"
  envs=(TAG="$tag" CONTAINER="$con" ROOT="$CG_ROOT" LOG="$CG_LOG" PIDFILE="$pf"
        STATE="$(curve_guard_state "$tag")" VERDICT="$(curve_guard_verdictfile "$tag")")
  [ -n "${ITER_BUDGET_S:-}" ] && envs+=(ITER_BUDGET_S="$ITER_BUDGET_S")
  [ -n "${PASS_BUDGET_S:-}" ] && envs+=(PASS_BUDGET_S="$PASS_BUDGET_S")
  [ -n "${REGRESS_PCT:-}" ]   && envs+=(REGRESS_PCT="$REGRESS_PCT")
  [ -n "${STALL_ITERS:-}" ]   && envs+=(STALL_ITERS="$STALL_ITERS")
  [ -n "${STALL_BP:-}" ]      && envs+=(STALL_BP="$STALL_BP")
  # The intra-iteration no-progress bound. Passed through for the same reason as
  # the others: a chain that pins it (0 to disable, or a value justified by its
  # own flush cadence) must be the value the guard actually runs with.
  [ -n "${STALL_LOG_S:-}" ]   && envs+=(STALL_LOG_S="$STALL_LOG_S")
  [ -n "${CURVE_POLL:-}" ]    && envs+=(POLL="$CURVE_POLL")
  [ -n "${GUARD_STOP:-}" ]    && envs+=(GUARD_STOP="$GUARD_STOP")
  [ -n "${DRY:-}" ]           && envs+=(DRY="$DRY")
  # setsid where it exists: the guard outlives this shell's session. Where it
  # does not (a developer's Git Bash), plain nohup still detaches it -- and the
  # guard is stopped by pid, never by pattern (a pattern would also match the
  # chain's own log lines).
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup env "${envs[@]}" bash "$CG_SCRIPT" >> "$CG_NOHUP" 2>&1 < /dev/null &
  else
    nohup env "${envs[@]}" bash "$CG_SCRIPT" >> "$CG_NOHUP" 2>&1 < /dev/null &
  fi
  # The guard writes its pidfile as soon as it is up; two seconds is enough for a
  # bash start on this box and is the same wait disk_guard.sh uses.
  sleep 2
  p=$(curve_guard_pid "$tag")
  if [ -n "$p" ]; then
    say "CURVE_GUARD_STARTED tag=$tag pid=$p container=$con"
    return 0
  fi
  say "CURVE_GUARD_START_FAILED tag=$tag -- see $CG_LOG and $CG_NOHUP"
  return 1
}

curve_guard_stop() {  # curve_guard_stop <tag>
  local tag=${1:?tag} pf p i
  pf=$(curve_guard_pidfile "$tag")
  if [ "$CURVE_GUARD" != 1 ]; then return 0; fi
  p=$(curve_guard_pid "$tag")
  if [ -z "$p" ]; then
    [ -s "$pf" ] && rm -f "$pf"
    say "CURVE_GUARD_STOPPED tag=$tag (not running)"
    return 0
  fi
  kill "$p" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
  # Backstop, and it is safe: the guard's state is written whole (temp + mv) at
  # the end of every evaluation and its pull-up is the last evaluation, so a
  # SIGKILL can lose a poll but never a decision or a half-written state file.
  if kill -0 "$p" 2>/dev/null; then
    kill -9 "$p" 2>/dev/null; sleep 1
    if kill -0 "$p" 2>/dev/null; then
      say "CURVE_GUARD_STOP_FAILED tag=$tag pid=$p still alive after SIGTERM and SIGKILL"
      return 1
    fi
    rm -f "$pf"
    say "CURVE_GUARD_STOPPED tag=$tag pid=$p (SIGKILL, after 5s of SIGTERM)"
    return 0
  fi
  rm -f "$pf"
  say "CURVE_GUARD_STOPPED tag=$tag pid=$p"
  return 0
}

curve_guard_verdict() {  # curve_guard_verdict <tag> -> the one line the guard left
  local vf
  vf=$(curve_guard_verdictfile "${1:?tag}")
  if [ -s "$vf" ]; then cat "$vf"; else printf 'none\n'; fi
}

curve_guard_status() {  # curve_guard_status <tag>
  local p
  p=$(curve_guard_pid "${1:?tag}")
  if [ -n "$p" ]; then say "CURVE_GUARD tag=$1 pid=$p running"; else say "CURVE_GUARD tag=$1 not running"; fi
}
