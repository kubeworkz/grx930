#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# drt_curve_guard.sh -- stop a detailed-routing pass that has stopped paying for
# itself: one iteration still running past its wall-clock budget, a whole pass
# over its budget, a count that gives back a quarter of the best route this pass
# already found, or a plateau that keeps paying hours for a fraction of a percent.
#
# WHY THIS FILE EXISTS
#
#   `DRT_OPT_ITERS: 8` bounds an iteration COUNT, and that cap is right for a step
#   whose default is 64. It cannot bound COST, because an iteration's cost is not
#   a constant. On v8 (fat core, GRT 0.0) the same step printed 34-minute
#   iterations early and 16-27-hour iterations later, and the step sat in
#   `OpenROAD.DetailedRouting` for 10.6 days over 26 iterations. Eight iterations
#   at late-run cost is still two and a half days per pass -- and the step
#   contains up to `1 + DRT_ANTENNA_REPAIR_ITERS` passes, each with a fresh
#   budget. That is the arithmetic that turns "months" into a plausible reading
#   of a step nobody bounded.
#
#   It cannot bound DIRECTION either. v8's best route was iteration 16
#   (237,089 violations) and iteration 17 was 649,172 -- 2.74x worse in one step
#   -- after which it never recovered (711,100 at 25). Those iterations did not
#   fail to converge; they walked away from the answer. And the ODB the step
#   writes at the end is the LAST one, not the best one, so the 10.6 days ended
#   with a database 3x worse than one it had already produced.
#
#   watch_drt_curve.sh already says what a curve is doing (converging / stalled /
#   diverged / clean) and can SIGTERM the router at WATCH_KILL=1, but it is
#   flag-only by default and it reports. Nothing STOPS a run on the two measured
#   ways a DRT pass burns days. That is this file.
#
# WHAT IT DOES (one evaluation per POLL, default 120 s)
#
#   1. reads the new bytes of the step's own log since the previous evaluation
#      and takes three markers out of them, in the router's own vocabulary:
#        `[INFO DRT-0195] Start 0th optimization iteration.`   -> a pass begins
#        `[INFO DRT-0195] Start Nth optimization iteration.`   -> iteration N
#        `[INFO DRT-0199]   Number of violations = N.`         -> its result
#      Only complete lines are consumed (a half-written line is re-read on the
#      next poll), and the byte offset lives in STATE, so a 50 MB log is not
#      re-read every two minutes. Events are de-duplicated by identity as well as
#      by offset, because a line straddling a poll is deliberately parsed twice.
#   2. an evaluation stops the container (`docker kill`) on the first of:
#        * ITER_BUDGET_S -- an iteration, or the initial route, is STILL RUNNING
#                           after this long. Measured: 26:05 and 25:25 per
#                           optimization iteration at GRT_ADJUSTMENT 0.2;
#                           v8's late ones were 16-27 h.
#        * PASS_BUDGET_S -- this pass has been routing for longer than this.
#                           Measured: 38 min initial + 8 x 26 min = ~4 h, so 8 h
#                           is 2x the capped pass and still a fifth of a day.
#        * REGRESSION    -- a count in THIS pass is more than REGRESS_PCT above the
#                           best this pass has already seen. Measured: v8's
#                           237,089 -> 649,172 is +174 %. A new pass is exempt,
#                           because a re-route after diode insertion legitimately
#                           starts above the previous pass's best.
#        * STALL         -- STALL_ITERS consecutive iterations each improved the
#                           best by less than STALL_BP basis points (25 bp =
#                           0.25 %). At 250k violations that is 625 violations
#                           per iteration, under 1,500/hour at the measured
#                           iteration cost.
#        * NO_PROGRESS   -- an OPEN iteration whose log has produced no new bytes
#                           for STALL_LOG_S. This is the hang INSIDE one
#                           iteration, which no count-based rule can see: on
#                           diecg01 iteration 1 printed `Completing 90%` and then
#                           nothing for two hours, and only the 2 h wall clock was
#                           left to catch it. It is the only rule that acts before
#                           the work has finished, so it is also the only one that
#                           can save the hours the ceiling would spend waiting.
#      It never acts before the log has shown a DRT-0195, so it cannot kill a flow
#      still in synthesis, placement, CTS or the pre-DRT antenna repair.
#   3. it writes the reason and the numbers it decided on to VERDICT, so a chain
#      can report `DRT_CURVE_GUARD stopped reason=...` after the container is gone
#      instead of guessing why the arm ended early.
#
# WHAT IT IS NOT
#
#   * Not a convergence gate. It never calls a route good or bad; `CLEAN` is the
#     only judgement it makes and that is the router's own zero.
#   * Not a replacement for watch_drt_curve.sh. That one describes the curve and
#     harvests the per-pass verdict; this one bounds it. They read the same log
#     and neither reads the other's output.
#   * Not free. A stop loses the pass: the flow writes the ODB at the END of a
#     pass and there is no per-iteration checkpoint to fall back to, so the best
#     iteration's database is not on disk. That is the same trade
#     drt_disk_guard.sh makes when it kills a flow that cannot write another
#     pass -- and it is why GUARD_STOP=0 and DRY=1 exist.
#   * Not a bound on the step's total. With `DRT_ANTENNA_REPAIR_ITERS: 10` the
#     worst case is 11 passes x PASS_BUDGET_S = 88 h, against 11 x ~28 h = ~13
#     days at the default iteration count. Each pass after the first is genuine
#     work (diodes were inserted), so a total budget would cut the antenna loop
#     rather than a runaway, and the loop already exits when it stops inserting.
#
# USAGE
#
#   Chains do not call this directly -- they source `build/curve_guard.sh` and
#   call `curve_guard_start`, so the arm they launch is guarded from the moment
#   its container is up and the guard is stopped when the chain exits (including
#   on an early abort). A by-hand launch is the same command the helper issues:
#
#   nohup bash build/drt_curve_guard.sh > /dev/null 2>&1 &   # the guard
#   tail -f ws/logs/drt_curve_guard.log
#   ONE_SHOT=1 bash build/drt_curve_guard.sh                # one evaluation
#   ONE_SHOT=1 DRY=1 bash build/drt_curve_guard.sh          # report, stop nothing
#
#   TAG=ws_v1               the run tag whose step dir is watched
#   STEP=*-openroad-detailedrouting   the step dir, matched as a glob inside
#                           runs/<tag> and resolved to the NEWEST match (a re-run
#                           appends higher ordinals); the log read is that dir's
#                           `openroad-detailedrouting.log`
#   CONTAINER=ws_flow       the container to stop
#   POLL=120                seconds between evaluations
#   ITER_BUDGET_S=7200      an iteration still running after this is stopped
#   PASS_BUDGET_S=28800     a pass still routing after this is stopped
#   REGRESS_PCT=25          a count this far above the pass's best stops it
#   STALL_ITERS=3           consecutive sub-STALL_BP iterations that stop it
#                           (0 disables the plateau rule, which is what a
#                           deliberate asymptote measurement wants)
#   STALL_BP=25             the plateau threshold, in basis points (25 = 0.25 %)
#   STALL_LOG_S=1800        an OPEN iteration with no new log bytes for this long
#                           is stopped (0 disables; see the buffer caveat below)
#   GUARD_STOP=1            0 = log CURVE_STOP_REQUEST and do not kill
#   DRY=1                   log WOULD_STOP, change nothing
#   ONE_SHOT=1              one evaluation, then exit (0 ok, 2 stopped)
#   CURVE_NOW=<epoch>       the clock, for the selftest only
#   LOG, STATE, VERDICT, PIDFILE   where it writes (defaults under ws/logs)
#
#   Exit: 0 = nothing needed or still watching, 2 = the run was stopped, and 0
#   also = already running for this tag (the second copy says
#   CURVE_GUARD_ALREADY_RUNNING and does nothing).
#
# WHAT IT DOES NOT COVER
#
#   * One evaluation per POLL, so an iteration that overruns between two polls is
#     caught up to POLL late -- which is why ITER_BUDGET_S is ~4.6x the measured
#     iteration and not a tight bound.
#   * The wall clock is the guard's own, not the router's: an iteration's cost is
#     measured between the two polls that saw its start and its count, so the
#     figure in the log is accurate to +/- POLL and is described that way.
#   * Progress is only as timely as the engine's stdout buffer. OpenROAD's logger
#     writes through a fully-buffered stdout, so a log can sit unchanged for hours
#     while the router works: measured on diecg01, 182 lines arrived in a single
#     03:40:48 flush after 42 minutes of silence -- which is also why iteration 0
#     and the start of iteration 1 shared one flush and reported `wall_s=0`.
#     `stdbuf -oL` cannot fix it here: the image's libstdbuf.so wants GLIBC_2.38
#     and the pinned binary runs on the Debian extraction's libc. So NO_PROGRESS
#     arms itself only after a flush has been SEEN landing while an iteration was
#     already open from a previous poll -- proof that output arrives between
#     polls. Until then it says CURVE_NO_PROGRESS_UNOBSERVED once and leaves the
#     pass to the wall-clock budgets. A batched log therefore cannot stop a
#     healthy run: the rule that fires on silence is off until silence means
#     something.
#   * `docker kill` is irreversible for the step: the arm has to be relaunched.
#   * It retires when its container has been gone for two polls. That is the one
#     case a chain's EXIT trap cannot cover -- a chain killed with -9 never
#     reaches it -- and nothing can grow the log once the container is gone. Two
#     polls, not one, so a docker hiccup is not read as the end of an arm.
#
# VERIFY IT
#
#   bash build/drt_curve_guard_selftest.sh
#     Drives every branch through the real code path with a synthetic step log
#     and a stubbed `docker`: arming, a normal descent, the regression stop, the
#     in-flight iteration budget, the no-progress stop and its two guards (a
#     batched log must NOT stop, and STALL_LOG_S=0 must disable it), the pass
#     budget, the plateau rule (and that
#     STALL_ITERS=0 turns it off), a new pass resetting the best, GUARD_STOP=0,
#     DRY, a log truncated under the guard, a half-written line not being parsed,
#     and the container-gone retirement. It also checks that every chain which
#     launches a flow DRT container is wired to this guard, and proves that check
#     fails on deliberately unwired copies. It runs in CI
#     (build/chain_selftests.sh, row `drt-curve-guard`).
set -u

B=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=${ROOT:-/home/ubuntu/grx930_ol2}
TAG=${TAG:-ws_v1}
STEP=${STEP:-*-openroad-detailedrouting}
RUN=${RUN:-$ROOT/ws/template/librelane/runs/$TAG}
CONTAINER=${CONTAINER:-ws_flow}
LOG=${LOG:-$ROOT/ws/logs/drt_curve_guard.log}
STATE=${STATE:-$ROOT/ws/logs/drt_curve_guard.$TAG.state}
VERDICT=${VERDICT:-$ROOT/ws/logs/drt_curve_guard.$TAG.verdict}
PIDFILE=${PIDFILE:-$ROOT/ws/logs/drt_curve_guard.$TAG.pid}
POLL=${POLL:-120}
ITER_BUDGET_S=${ITER_BUDGET_S:-7200}
PASS_BUDGET_S=${PASS_BUDGET_S:-28800}
REGRESS_PCT=${REGRESS_PCT:-25}
STALL_ITERS=${STALL_ITERS:-3}
STALL_BP=${STALL_BP:-25}
STALL_LOG_S=${STALL_LOG_S:-1800}
GUARD_STOP=${GUARD_STOP:-1}
DRY=${DRY:-0}
ONE_SHOT=${ONE_SHOT:-0}

mkdir -p -- "$(dirname -- "$LOG")" "$(dirname -- "$STATE")" 2>/dev/null || true
CHUNK=$(mktemp 2>/dev/null) || CHUNK=/tmp/drt_curve_guard.$$
trap 'rm -f "$CHUNK" "$CHUNK.part" 2>/dev/null' EXIT

say() { local m; m="$(date -u '+%F %T') $*"; printf '%s\n' "$m"; printf '%s\n' "$m" >> "$LOG"; }

is_num() { case ${1:-} in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# The clock. CURVE_NOW exists so the selftest can drive days of wall clock
# through the real code path without sleeping; the real path is date.
now() { if is_num "${CURVE_NOW:-}"; then printf '%s\n' "$CURVE_NOW"; else date -u +%s; fi; }

# ---------------------------------------------------------------- state ------
OFF=0; PASS=1; ITER=0; COUNT=0; BEST=0; PASS_START=0; LAST_MARK=0
STALL=0; ARMED=0; DONE=0; PASS_COUNTS=0; LAST_COUNT_ITER=-1; ITER_OPEN=0
LAST_GROW=0; PROGRESS_OK=0; NOPROG_SAID=""
WAIT_SAID=""; ABSENT_SAID=""; LOG_SEEN=""

load_state() {
  [ -f "$STATE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case $k in
      OFF|PASS|ITER|COUNT|BEST|PASS_START|LAST_MARK|STALL|ARMED|DONE|PASS_COUNTS|LAST_COUNT_ITER|ITER_OPEN|LAST_GROW|PROGRESS_OK)
        printf -v "$k" '%s' "$v" ;;
      WAIT_SAID|ABSENT_SAID|LOG_SEEN|NOPROG_SAID) printf -v "$k" '%s' "${v:-}" ;;
    esac
  done < "$STATE"
  # A corrupted state file must not turn into arithmetic the shell refuses to
  # do, and must never read as "already stopped".
  is_num "$OFF" || OFF=0
  is_num "$PASS" || PASS=1
  is_num "$ITER" || ITER=0
  is_num "$COUNT" || COUNT=0
  is_num "$BEST" || BEST=0
  is_num "$PASS_START" || PASS_START=0
  is_num "$LAST_MARK" || LAST_MARK=0
  is_num "$STALL" || STALL=0
  is_num "$ARMED" || ARMED=0
  is_num "$DONE" || DONE=0
  is_num "$PASS_COUNTS" || PASS_COUNTS=0
  is_num "$LAST_COUNT_ITER" || LAST_COUNT_ITER=-1
  is_num "$ITER_OPEN" || ITER_OPEN=0
  is_num "$LAST_GROW" || LAST_GROW=0
  is_num "$PROGRESS_OK" || PROGRESS_OK=0
}

save_state() {
  {
    printf 'OFF=%s\n' "$OFF"
    printf 'PASS=%s\n' "$PASS"
    printf 'ITER=%s\n' "$ITER"
    printf 'COUNT=%s\n' "$COUNT"
    printf 'BEST=%s\n' "$BEST"
    printf 'PASS_START=%s\n' "$PASS_START"
    printf 'LAST_MARK=%s\n' "$LAST_MARK"
    printf 'STALL=%s\n' "$STALL"
    printf 'ARMED=%s\n' "$ARMED"
    printf 'DONE=%s\n' "$DONE"
    printf 'PASS_COUNTS=%s\n' "$PASS_COUNTS"
    printf 'LAST_COUNT_ITER=%s\n' "$LAST_COUNT_ITER"
    printf 'ITER_OPEN=%s\n' "$ITER_OPEN"
    printf 'LAST_GROW=%s\n' "$LAST_GROW"
    printf 'PROGRESS_OK=%s\n' "$PROGRESS_OK"
    printf 'NOPROG_SAID=%s\n' "${NOPROG_SAID:-}"
    printf 'WAIT_SAID=%s\n' "${WAIT_SAID:-}"
    printf 'ABSENT_SAID=%s\n' "${ABSENT_SAID:-}"
    printf 'LOG_SEEN=%s\n' "${LOG_SEEN:-}"
  } > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"
  return 0
}

write_verdict() { printf '%s %s\n' "$(date -u '+%F %T')" "$*" > "$VERDICT" 2>/dev/null; }

# ---------------------------------------------------------------- inputs -----
# Newest match, not the oldest: a re-run on an existing tag appends a step dir
# with a higher ordinal, and watching the superseded one would guard a log that
# has stopped growing.
resolve_step() { ls -1d "$RUN"/*-openroad-detailedrouting 2>/dev/null | sort -V | tail -1; }

resolve_log() {  # $1 = step dir
  local f=$1/openroad-detailedrouting.log
  [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  return 1
}

# Emits one token per marker, in the order they appear, and advances OFF past
# the last complete line. A trailing line without a newline is left for the next
# poll: parsing half of `= 4210` as `= 421` would set a best the router never had.
parse_new() {
  local size partial
  EVENTS=()
  [ -f "$CURVE_LOG" ] || return 1
  size=$(stat -c %s "$CURVE_LOG" 2>/dev/null) || return 1
  is_num "$size" || return 1
  if [ "$size" -lt "$OFF" ]; then
    say "CURVE_LOG_TRUNCATED path=$CURVE_LOG size=$size offset=$OFF -- re-reading from 0 and forgetting the curve it described"
    OFF=0; PASS=1; ITER=0; COUNT=0; BEST=0; PASS_START=0; LAST_MARK=0; STALL=0
    ARMED=0; DONE=0; PASS_COUNTS=0; LAST_COUNT_ITER=-1; ITER_OPEN=0
    LAST_GROW=0; PROGRESS_OK=0; NOPROG_SAID=""
  fi
  [ "$size" -eq "$OFF" ] && return 0
  tail -c +$((OFF + 1)) "$CURVE_LOG" > "$CHUNK" 2>/dev/null || return 1
  # A line is complete at `\n` OR `\r`: the router terminates its progress with
  # carriage returns and its markers with newlines, so both end a record. Testing
  # only for `\n` held every `Start Nth` back until the following count arrived,
  # which made every iteration's measured wall clock 0 and hid an iteration that
  # was still running (found by case 3 of the selftest).
  lastb=$(tail -c 1 "$CHUNK" 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' \n')
  case ${lastb:-} in
    10|13) OFF=$size ;;
    *)    partial=$(tail -n 1 "$CHUNK" | wc -c)
          sed '$d' "$CHUNK" > "$CHUNK.part" 2>/dev/null && mv "$CHUNK.part" "$CHUNK"
          OFF=$((size - partial)) ;;
  esac
  # `tr '\r' '\n'`: the router writes its progress with carriage returns, so a
  # line boundary is either. awk emits P (pass start), "I <n>" (iteration start)
  # and "C <n>" (post-iteration count) rather than the text, so the shell never
  # grep-parses a 50 MB file again.
  mapfile -t EVENTS < <(tr '\r' '\n' < "$CHUNK" | awk '
    /Start [0-9]+(st|nd|rd|th) optimization iteration/ {
      if (match($0, /Start [0-9]+/)) {
        n = substr($0, RSTART + 6, RLENGTH - 6)
        if (n + 0 == 0) print "P"; else print "I " n
      }
      next
    }
    /DRT-0199/ { if (match($0, /= [0-9]+/)) print "C " substr($0, RSTART + 2, RLENGTH - 2) }')
  return 0
}

# ---------------------------------------------------------------- stop -------
stop_now() {  # $1 reason, $2 detail, $3 at=completed|inflight
  local reason=$1 detail=${2:-} at=${3:-completed}
  local msg
  WALL=${WALL:-0}
  msg="reason=$reason at=$at pass=$PASS iter=$ITER count=$COUNT best=$BEST wall_s=$WALL elapsed_s=$((NOW - PASS_START)) container=$CONTAINER $detail"
  DONE=1
  if [ "$DRY" = 1 ]; then
    say "WOULD_STOP $msg"
    save_state
    return 2
  fi
  if [ "$GUARD_STOP" != 1 ]; then
    say "CURVE_STOP_REQUEST $msg (GUARD_STOP=0, not stopping)"
    write_verdict "REQUEST $msg"
    save_state
    return 0
  fi
  say "CURVE_STOPPED $msg"
  write_verdict "STOPPED $msg"
  docker kill "$CONTAINER" >/dev/null 2>&1 || say "CURVE_STOP_FAILED docker kill $CONTAINER"
  save_state
  return 2
}

# ------------------------------------------------------------- evaluation ----
evaluate() {
  local s n wall elapsed v off_before silent
  NOW=$(now)
  S=$(resolve_step)
  if [ -z "${S:-}" ]; then
    # Said once per state, not every poll: the die arm spends hours before this
    # directory exists, and 200 identical lines would bury the one that matters.
    if [ "${WAIT_SAID:-}" != absent ]; then
      say "CURVE_WAIT step_dir_absent run=$RUN step=$STEP"; WAIT_SAID=absent
    fi
    save_state
    return 0
  fi
  [ "${WAIT_SAID:-}" = absent ] && { WAIT_SAID=""; say "CURVE_STEP_PRESENT step=$S"; }

  if ! CURVE_LOG=$(resolve_log "$S"); then
    if [ "${ABSENT_SAID:-}" != "$S" ]; then
      say "CURVE_LOG_ABSENT step=$S -- no openroad-detailedrouting.log yet"; ABSENT_SAID=$S
    fi
    save_state
    return 0
  fi
  [ "${ABSENT_SAID:-}" = "$S" ] && ABSENT_SAID=""
  if [ "${LOG_SEEN:-}" != "$CURVE_LOG" ]; then
    # A different log is a different curve: start from 0 rather than inherit an
    # offset that happens to fit.
    [ -n "${LOG_SEEN:-}" ] && say "CURVE_LOG_CHANGED from=$LOG_SEEN to=$CURVE_LOG -- resetting the curve"
    LOG_SEEN=$CURVE_LOG; OFF=0; ARMED=0; DONE=0; PASS=1; ITER=0; COUNT=0; BEST=0
    PASS_START=0; LAST_MARK=0; STALL=0; PASS_COUNTS=0; LAST_COUNT_ITER=-1
    LAST_GROW=0; PROGRESS_OK=0; NOPROG_SAID=""
  fi

  off_before=$OFF
  parse_new || { save_state; return 0; }
  # Growth is the liveness signal, and it is only honest when it can arrive
  # between polls: this engine's stdout is block-buffered (see the header), so a
  # flush that carries `Start Nth` AND its progress AND its count proves nothing
  # about silence. A flush landing while an iteration was ALREADY open from a
  # previous poll does prove it, and that is the only thing that arms NO_PROGRESS.
  if [ "$OFF" -ne "$off_before" ]; then
    LAST_GROW=$NOW
    if [ "$ARMED" = 1 ] && [ "$ITER_OPEN" = 1 ]; then PROGRESS_OK=1; fi
  fi

  local e
  for e in ${EVENTS[@]+"${EVENTS[@]}"}; do
    [ "$DONE" = 1 ] && break
    case $e in
      P)
        # De-duplicated by identity: a pass start is only real once this pass has
        # produced a count. A re-read of the same line (a line straddling a poll)
        # therefore cannot bump the pass number.
        if [ "$ARMED" = 1 ] && [ "$PASS_COUNTS" -eq 0 ] && [ "$PASS_START" -ne 0 ]; then
          continue
        fi
        if [ "$ARMED" = 0 ]; then ARMED=1; else PASS=$((PASS + 1)); fi
        ITER=0; COUNT=0; BEST=0; STALL=0; PASS_COUNTS=0; LAST_COUNT_ITER=-1
        PASS_START=$NOW; LAST_MARK=$NOW
        # `Start 0th` IS the initial route starting, so the pass start opens an
        # iteration: only an open iteration is ever stopped for running too long.
        ITER_OPEN=1
        say "CURVE_PASS pass=$PASS started=${NOW}"
        ;;
      I*)
        n=${e#I }
        is_num "$n" || continue
        [ "$ARMED" = 1 ] || continue
        [ "$n" = "$ITER" ] && continue          # re-read of the same start line
        [ "$n" -lt "$ITER" ] && continue         # older line, already accounted
        ITER=$n; LAST_MARK=$NOW; ITER_OPEN=1
        say "CURVE_ITER pass=$PASS iter=$ITER started=${NOW}"
        ;;
      C*)
        v=${e#C }
        is_num "$v" || continue
        [ "$ARMED" = 1 ] || continue
        # Same iteration, same count: a re-read. Never count it twice -- that
        # would look like a plateau and could stop a healthy run.
        if [ "$ITER" = "$LAST_COUNT_ITER" ] && [ "$v" = "$COUNT" ]; then continue; fi
        wall=$((NOW - LAST_MARK))
        elapsed=$((NOW - PASS_START))
        WALL=$wall
        ITER_OPEN=0
        say "CURVE_COUNT pass=$PASS iter=$ITER count=$v best=$BEST wall_s=$wall elapsed_s=$elapsed"
        LAST_COUNT_ITER=$ITER; PASS_COUNTS=$((PASS_COUNTS + 1))

        if [ "$v" -eq 0 ]; then
          COUNT=$v; BEST=$v
          say "CURVE_CLEAN pass=$PASS iter=$ITER"
          write_verdict "CLEAN pass=$PASS iter=$ITER count=0"
          DONE=1; break
        fi

        # Wall clock first: a count that arrives after the budget means the next
        # iteration starts from the same spent pass.
        if [ "$elapsed" -gt "$PASS_BUDGET_S" ]; then
          COUNT=$v; stop_now PASS_BUDGET "budget_s=$PASS_BUDGET_S" completed; break
        fi
        # A COMPLETED iteration over the budget is recorded, not punished: it
        # already finished, so the pass may still be worth keeping. The budget
        # stops an iteration that is still RUNNING (the in-flight check below),
        # which is the measured failure mode -- 16-27 h, not 2.5 h.
        if [ "$wall" -gt "$ITER_BUDGET_S" ]; then
          say "CURVE_ITER_SLOW pass=$PASS iter=$ITER wall_s=$wall budget_s=$ITER_BUDGET_S (completed, not stopped)"
        fi

        # Regression, within this pass only. A new pass re-routes after diode
        # insertion and legitimately starts above the previous pass's best.
        if [ "$BEST" -gt 0 ] && [ $((v * 100)) -gt $((BEST * (100 + REGRESS_PCT))) ]; then
          COUNT=$v
          stop_now REGRESSION "regress_pct=$REGRESS_PCT prev_best=$BEST" completed; break
        fi

        COUNT=$v
        if [ "$BEST" -eq 0 ]; then
          BEST=$v; STALL=0
        elif [ "$v" -lt "$BEST" ]; then
          if [ $(((BEST - v) * 10000)) -lt $((BEST * STALL_BP)) ]; then
            STALL=$((STALL + 1))
          else
            STALL=0
          fi
          BEST=$v
        else
          STALL=$((STALL + 1))
        fi
        if [ "$STALL_ITERS" -gt 0 ] && [ "$STALL" -ge "$STALL_ITERS" ]; then
          stop_now STALL "stall_iters=$STALL_ITERS stall_bp=$STALL_BP" completed; break
        fi
        ;;
    esac
  done

  if [ "$DONE" != 1 ] && [ "$ARMED" = 1 ]; then
    elapsed=$((NOW - PASS_START))
    if [ "$elapsed" -gt "$PASS_BUDGET_S" ]; then
      stop_now PASS_BUDGET "budget_s=$PASS_BUDGET_S" inflight
    elif [ "$ITER_OPEN" = 1 ]; then
      # Only an OPEN iteration is judged on these clocks. Between a count and the
      # next `Start`, the step is doing something else (antenna check/repair
      # inside the step's own loop), and that is not an iteration overrunning --
      # stopping it there would kill a pass for doing the repair it was asked to
      # do. PASS_BUDGET is the bound that covers that gap.
      silent=$((NOW - LAST_MARK))
      if [ "$STALL_LOG_S" -gt 0 ] && [ "$LAST_GROW" -gt 0 ] \
         && [ $((NOW - LAST_GROW)) -gt "$STALL_LOG_S" ]; then
        if [ "$PROGRESS_OK" = 1 ]; then
          # The router was seen emitting between polls in this run, and has now
          # stopped: this is the intra-iteration hang, caught while the work is
          # still unpaid for rather than at the wall-clock ceiling.
          WALL=$silent
          stop_now NO_PROGRESS "stall_log_s=$STALL_LOG_S silent_s=$((NOW - LAST_GROW))" inflight
        elif [ "${NOPROG_SAID:-}" != 1 ]; then
          NOPROG_SAID=1
          say "CURVE_NO_PROGRESS_UNOBSERVED pass=$PASS iter=$ITER silent_s=$((NOW - LAST_GROW)) stall_log_s=$STALL_LOG_S -- no flush has ever arrived mid-iteration in this run, so this log cannot distinguish a stall from its own buffer; the wall-clock budgets still bound the pass"
        fi
      fi
      if [ "$DONE" != 1 ] && [ "$silent" -gt "$ITER_BUDGET_S" ]; then
        WALL=$silent
        stop_now ITER_BUDGET "budget_s=$ITER_BUDGET_S iter_running_s=$WALL" inflight
      fi
    fi
  fi

  say "CURVE_STATE tag=$TAG pass=$PASS iter=$ITER count=$COUNT best=$BEST stall=$STALL armed=$ARMED done=$DONE offset=$OFF progress_ok=$PROGRESS_OK last_grow=$LAST_GROW log=$CURVE_LOG"
  save_state
  return 0
}

# One guard per tag. A chain starts it and stops it, so a second copy is either a
# double-start or a stale pidfile from a chain killed with -9. Both are answered
# here rather than by two guards stopping the same container. ONE_SHOT is exempt:
# a one-shot run is an evaluation, not a supervisor.
if [ "$ONE_SHOT" != 1 ]; then
  if [ -s "$PIDFILE" ]; then
    p=$(cat "$PIDFILE" 2>/dev/null)
    if is_num "${p:-}" && kill -0 "$p" 2>/dev/null; then
      say "CURVE_GUARD_ALREADY_RUNNING tag=$TAG pid=$p -- this tag is already guarded"
      exit 0
    fi
    say "CURVE_PIDFILE_STALE tag=$TAG pid=${p:-none} -- starting anyway"
  fi
  printf '%s\n' "$$" > "$PIDFILE"
  trap 'rm -f "$CHUNK" "$CHUNK.part" 2>/dev/null; [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"; exit 0' TERM INT
  trap 'rc=$?; [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"; rm -f "$CHUNK" "$CHUNK.part" 2>/dev/null; exit "$rc"' EXIT
fi

load_state
say "CURVE_GUARD_START tag=$TAG run=$RUN step=$STEP container=$CONTAINER poll=$POLL iter_budget_s=$ITER_BUDGET_S pass_budget_s=$PASS_BUDGET_S regress_pct=$REGRESS_PCT stall_iters=$STALL_ITERS stall_bp=$STALL_BP stall_log_s=$STALL_LOG_S stop=$GUARD_STOP dry=$DRY one_shot=$ONE_SHOT"

if [ "$ONE_SHOT" = 1 ]; then evaluate; exit $?; fi

GONE=0
while :; do
  evaluate; rc=$?
  [ "$rc" = 2 ] && { say "CURVE_EXIT stopped -- relaunch after the next arm starts"; exit 2; }
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    GONE=0
  else
    GONE=$((GONE + 1))
    if [ "$GONE" -ge 2 ]; then
      say "CURVE_EXIT container_gone name=$CONTAINER -- nothing can grow the log now, retiring"
      exit 0
    fi
    say "CURVE_CONTAINER_ABSENT name=$CONTAINER poll=$GONE/2"
  fi
  # `sleep & wait`: bash runs a trap as soon as the signal arrives while it is in
  # `wait`, but a plain `sleep` defers the TERM until the sleep returns, so a
  # chain stopping its guard would wait out the whole poll interval.
  sleep "$POLL" & sp=$!
  wait "$sp" 2>/dev/null || true
done
