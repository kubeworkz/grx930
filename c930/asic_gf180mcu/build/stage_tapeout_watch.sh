#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# stage_tapeout_watch.sh -- host side: keep the staged tapeout configuration describing the
# CURRENT measurements, by re-running build/stage_tapeout_config.sh whenever the evidence
# its block quotes moves.
#
# WHY THIS EXISTS
#
#   The staging job can only run at moments when no arm is holding the box, and the
#   measurements do not all land at once: the pin's repair is a probe datum today, the
#   flow arm that confirms it end to end is queued behind two other chains, and the
#   fast-loop cost columns fill in one row per arm. A job that runs once therefore leaves a
#   block that was right when it was written and is wrong later -- quoting a `not measured`
#   for an arm that has since run, or a rung-2 repair mode after the pin was confirmed. The
#   block is read by whoever launches the tapeout, so "right when written" is not a property
#   worth having. This watcher is what makes it "right now".
#
# THE TRIGGER IS THE EVIDENCE, NOT A CLOCK
#
#   The file set and its fingerprint are defined once, in build/stage_evidence.sh, and are
#   the same set the block quotes. Nothing else is watched: the router's own `predrt_*.log`
#   is excluded on purpose, because it grows by megabytes a minute for the 14 hours an arm
#   routes and would turn this into a busy loop (that file's header says which lines of the
#   block therefore refresh on the next real trigger instead).
#
# WHAT IT DOES WITH A CHANGE
#
#   Runs the job with STAGE_WAIT=0, so the "is the box free" question stays in one place:
#   the job refuses (exit 1) if a container or a chain is running, and this watcher simply
#   tries again on the next cycle. A refusal does NOT record the fingerprint, so the same
#   change is retried until it lands.
#
#   When the job succeeds, the fingerprint it confirmed (its own STAGE_FINGERPRINT line) is
#   recorded in drt_fast/verdict/tapeout_config_stage.state and a row is appended to
#   drt_fast/verdict/tapeout_config_stage_history.md: time, trigger, rung, whether the file
#   changed, the fingerprint and the block's sha256. That history is the audit trail for
#   "does the block describe the measurements on disk right now".
#
# DEBOUNCE
#
#   A change must read the same twice, one cycle apart, before it is acted on. The probe
#   logs and the TSV are written by jobs that hold them briefly mid-write, and a block
#   quoting a half-written file is exactly the kind of number this whole pair exists to
#   avoid. A MISSING block is acted on immediately instead: absence is unambiguous, and not
#   acting would leave the tapeout config with no measurement in it at all.
#
# BOUNDS, SO IT CANNOT GO QUIET ON ITS OWN
#
#   STAGE_WATCH_EVERY=300   seconds between cycles (busy-box retries included)
#   STAGE_WATCH_HOURS=168   0 = watch forever; a deadline is a loud WATCH_DEADLINE + exit 1,
#                           never a silent stop
#   one instance only, enforced with ws/logs/.stage_tapeout_watch.lock and a live-pid check
#
#   nohup setsid bash build/stage_tapeout_watch.sh > /dev/null 2>&1 &
#   tail -f ws/logs/stage_tapeout_watch.log
#
#   bash build/stage_tapeout_watch.sh --once       one decision cycle, one log line (used by
#                                                  a human to see where it stands)
#   bash build/stage_tapeout_watch.sh --selftest   fixtures and a stubbed job, no docker and
#                                                  no real config touched
#
# STAGE_ROOT / STAGE_WATCH_JOB point it at another tree and another job; only the selftest
# uses them. STAGE_WATCH_TEST_TOUCH=<file> appends a line to that file between the two
# debounce reads, which is how the selftest proves a moving file is refused; it is a test
# hook, never set in normal use.
set -u
ROOT=${STAGE_ROOT:-/home/ubuntu/grx930_ol2}
B=$ROOT/build
WS=$ROOT/ws
D=$ROOT/drt_fast
JOB=${STAGE_WATCH_JOB:-$B/stage_tapeout_config.sh}
JLOG=$WS/logs/stage_tapeout_config.log
OVR=$WS/template/librelane/grx930_overrides.yaml
BMARK='MEASURED-STAGING'
EVERY=${STAGE_WATCH_EVERY:-300}
HOURS=${STAGE_WATCH_HOURS:-168}
START=${STAGE_WATCH_START:-$(date -u +%s)}
LOG=$WS/logs/stage_tapeout_watch.log
STATE=$D/verdict/tapeout_config_stage.state
HIST=$D/verdict/tapeout_config_stage_history.md
LOCK=$WS/logs/.stage_tapeout_watch.lock
MODE=${1:-watch}
CYCLE=; G_REASON=; G_RC=; G_RUNG=; G_FP=; F=
mkdir -p "$WS/logs" "$D/verdict"
say() { echo "[$(date -u)] $*" | tee -a "$LOG"; }
ts() { date -u '+%F %T'; }

[ -f "$B/stage_evidence.sh" ] || { say "WATCH_ABORT missing $B/stage_evidence.sh"; exit 1; }
. "$B/stage_evidence.sh"

state_get() { grep -a "^$1 " "$STATE" 2>/dev/null | tail -1 | cut -d' ' -f2-; }
state_put() {  # $1 key, $2 value: one line per key, rewritten in place
    local t
    t=$(mktemp)
    grep -av "^$1 " "$STATE" 2>/dev/null > "$t" || true
    printf '%s %s\n' "$1" "$2" >> "$t"
    cat "$t" > "$STATE"; rm -f "$t"
}
block_present() { [ -f "$OVR" ] && grep -aq "BEGIN $BMARK" "$OVR"; }
block_sha() { sed -n "/BEGIN $BMARK/,/END $BMARK/p" "$OVR" 2>/dev/null | sha256sum | cut -d' ' -f1; }

# ---- the job, run the way the watcher needs it -----------------------------------
# The job is called with STAGE_WAIT=0: whether the box is free is its question to answer,
# and its answer (exit 1, nothing written) is this watcher's cue to try again later. The
# fingerprint it reports is the one it confirmed -- that, not the watcher's own reading, is
# what gets recorded as handled, so a job that re-decided mid-run is still tracked exactly.
act() {
    local out rc
    out=$(STAGE_ROOT="$ROOT" STAGE_WAIT=0 bash "$JOB" 2>&1); rc=$?
    G_RC=$rc
    G_WRITE=$(grep -a 'STAGE_WRITE overrides' "$JLOG" 2>/dev/null | tail -1)
    G_RUNG=$(grep -a 'STAGE_DECISION rung=' "$JLOG" 2>/dev/null | tail -1 | sed -E 's/.*rung=([0-9]).*/\1/')
    [ -n "${G_RUNG:-}" ] || G_RUNG='?'
    G_FP=$(grep -a 'STAGE_FINGERPRINT ' "$JLOG" 2>/dev/null | tail -1 | awk '{print $NF}')
    [ -n "${G_FP:-}" ] || G_FP=$F
    [ "$rc" != 0 ] && [ -n "$out" ] && printf '%s\n' "$out" >> "$LOG"
    return "$rc"
}

history_row() {  # $1 status, $2 reason, $3 rung, $4 fingerprint, $5 block sha
    [ -f "$HIST" ] || {
        printf '# Staged tapeout configuration -- every re-stage, and what triggered it\n\n' > "$HIST"
        printf 'Written by `build/stage_tapeout_watch.sh` around every run of\n' >> "$HIST"
        printf '`build/stage_tapeout_config.sh`. The fingerprint is over the evidence files the\n' >> "$HIST"
        printf 'block quotes (`build/stage_evidence.sh`); the triggering condition is in the row, so\n' >> "$HIST"
        printf 'a reader can tell a real measurement landing from the block having been deleted.\n\n' >> "$HIST"
        printf '| when (UTC) | result | trigger | rung | fingerprint | block sha256 |\n' >> "$HIST"
        printf '|---|---|---|---|---|---|\n' >> "$HIST"
    }
    printf '| %s | %s | %s | %s | `%s` | `%s` |\n' "$(ts)" "$1" "$2" "$3" "$4" "${5:0:16}" >> "$HIST"
}

# ---- one decision cycle ----------------------------------------------------------
cycle() {
    local f f2 last reason
    f=$(stage_evidence_fingerprint); F=$f
    last=$(state_get last_fingerprint)
    if block_present && [ "$f" = "$last" ]; then
        CYCLE=current; G_REASON="block matches the evidence"
        return 0
    fi
    if block_present; then
        reason="evidence changed"
        sleep "$EVERY"
        [ -n "${STAGE_WATCH_TEST_TOUCH:-}" ] && printf 'watch_test_touch\n' >> "$STAGE_WATCH_TEST_TOUCH"
        f2=$(stage_evidence_fingerprint)
        if [ "$f2" != "$f" ]; then
            CYCLE=unstable; G_REASON="evidence moved between the two reads ($f -> $f2)"
            return 0
        fi
    else
        reason="no $BMARK block in $(basename "$OVR")"
    fi

    if act; then
        CYCLE=current   # the job ran to a decision; refined below by what it wrote
    else
        case "$G_RC" in
            1) CYCLE=refused ;;
            *) CYCLE=error ;;
        esac
    fi
    case "$CYCLE" in
        current)
            if ! block_present; then
                # The job reported success but there is still no block: recording the
                # fingerprint now would tell the next cycle that this evidence is handled,
                # which is the one thing this watcher must never say wrongly.
                CYCLE=error; G_REASON="the job ran (rc=0) but $OVR still has no block"
                return 0
            fi
            case "$G_WRITE" in
                *"overrides rc=0"*) CYCLE=staged ;;
                *) CYCLE=unchanged ;;
            esac
            G_REASON=$reason
            state_put last_fingerprint "${G_FP:-$f}"
            state_put last_fingerprint_at "$(ts)"
            state_put last_rung "$G_RUNG"
            state_put stages "$(( $(state_get stages | grep -E '^[0-9]+$' || echo 0) + 1 ))"
            history_row "$CYCLE" "$reason" "$G_RUNG" "${G_FP:-$f}" "$(block_sha)"
            ;;
        *)
            G_REASON="$reason -- job rc=${G_RC:-?} (not recorded; retried next cycle)"
            ;;
    esac
    return 0
}

# ---- single instance ----------------------------------------------------------------
release_lock() { [ -d "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"; return 0; }
acquire_lock() {
    local p
    if mkdir "$LOCK" 2>/dev/null; then printf '%s' "$$" > "$LOCK/pid"; return 0; fi
    p=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then say "WATCH_LOCKED pid=$p"; return 1; fi
    say "WATCH_LOCK_STALE pid=${p:-unreadable} -- taking it"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || return 1
    printf '%s' "$$" > "$LOCK/pid"
    return 0
}

if [ "$MODE" = selftest ]; then
    exec bash "$B/stage_tapeout_watch_selftest.sh"
fi

if ! acquire_lock; then
    say "WATCH_ABORT another watcher holds $LOCK -- nothing done"
    exit 1
fi
trap 'release_lock' EXIT INT TERM

if [ "$MODE" = --once ]; then
    cycle
    say "WATCH_CYCLE status=$CYCLE fingerprint=${G_FP:-$F} reason='${G_REASON:-}' job_rc=${G_RC:-none} rung=${G_RUNG:-none}"
    exit 0
fi

say "WATCH_START every=${EVERY}s hours=${HOURS} job=$JOB"
# A line for every change of state, and one an hour otherwise: a box that stays busy for the
# 14 hours an arm routes would otherwise print a refusal every five minutes, which buries the
# lines that matter -- and a watcher that has silently stopped is worse than a noisy one.
PREV=; REPEAT=0
while :; do
    if [ "$HOURS" != 0 ] && [ $(( ($(date -u +%s) - START) / 3600 )) -ge "$HOURS" ]; then
        say "WATCH_DEADLINE ${HOURS}h reached -- the block is no longer being re-staged here; relaunch to keep it current"
        exit 1
    fi
    cycle
    if [ "$CYCLE" = "$PREV" ]; then REPEAT=$((REPEAT + 1)); else REPEAT=0; fi
    if [ "$CYCLE" != "$PREV" ] || [ $((REPEAT % 12)) = 0 ]; then
        say "WATCH_CYCLE status=$CYCLE repeated=$REPEAT fingerprint=${G_FP:-$F} reason='${G_REASON:-}' job_rc=${G_RC:-none} rung=${G_RUNG:-none}"
    fi
    PREV=$CYCLE
    sleep "$EVERY"
done
