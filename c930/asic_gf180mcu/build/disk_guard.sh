#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# disk_guard.sh -- start and stop the DRT disk guard from a chain, written ONCE
# and sourced by every chain that launches a flow arm.
#
# WHY THIS FILE EXISTS
#
#   `drt_disk_guard.sh` keeps the flow volume from filling under the antenna-repair
#   loop (it prunes superseded `drt-run-N/chip_top.odb` files, and stops the flow
#   before a route is written into a full disk). It is a separate process because
#   the arm it watches runs for days and must be guarded while it runs, not at
#   launch time.
#
#   That "start it, and be sure it stops" pair is the same problem `gate.sh` solved
#   for the disk/memory floors: copied into each chain it is six copies of one
#   decision, and the failure is quiet -- an arm running with no guard still looks
#   healthy right up to the moment the ODB write is truncated. So the launch line,
#   the pidfile convention and the stop are here once:
#
#     * one guard per run tag (`ws/logs/drt_disk_guard.<tag>.pid`), and a second
#       `disk_guard_start` for the same tag is a no-op that says so;
#     * START is idempotent, so a parent chain and its child can both ask;
#     * STOP is safe on a guard that already retired, and removes a stale pidfile;
#     * DISK_GUARD=0 disables both, which is how the selftests run the real chains
#       without spawning a poller.
#
# USAGE (in a chain, after `say`, ROOT and WS are defined)
#
#   . $ROOT/build/disk_guard.sh
#   disk_guard_start "$TAG" die_predrt     # the moment the container is up
#   disk_guard_stop  "$TAG"                # on the way out, including aborts
#
#   The caller's own `say` is used (bash resolves it when the function runs, not
#   at source time), so this must be sourced after `say` exists -- the same
#   contract gate.sh states.
#
# A missing guard script is REPORTED, not fatal: the arm is the work, the guard is
# protection against a full volume, and refusing to run a three-day arm because
# its guard is absent would be the worse trade. DISK_GUARD_MISSING in a chain log
# is the signal to install it.
#
# VERIFY IT
#
#   bash build/drt_disk_guard_selftest.sh    -- cases 13-16 drive start/stop/
#   idempotency/stale-pidfile through this file with the real guard script in a
#   temp ROOT, and prove that a second start does not produce a second process.
DG_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DISK_GUARD=${DISK_GUARD:-1}
DG_ROOT=${DG_ROOT:-${ROOT:-/home/ubuntu/grx930_ol2}}
DG_WS=${WS:-$DG_ROOT/ws}
DG_SCRIPT=${DG_SCRIPT:-$DG_DIR/drt_disk_guard.sh}
DG_LOG=${DG_LOG:-$DG_WS/logs/drt_disk_guard.log}
DG_NOHUP=${DG_NOHUP:-$DG_WS/logs/drt_disk_guard.nohup}

disk_guard_pidfile() { printf '%s\n' "$DG_WS/logs/drt_disk_guard.$1.pid"; }

disk_guard_pid() {  # $1 = tag -> prints the live pid, or nothing
  local pf p
  pf=$(disk_guard_pidfile "$1")
  [ -s "$pf" ] || return 0
  p=$(cat "$pf" 2>/dev/null)
  case "${p:-}" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$p" 2>/dev/null || return 0
  printf '%s\n' "$p"
}

disk_guard_start() {  # disk_guard_start <tag> [container]
  local tag=${1:?tag} con=${2:-die_predrt} pf p
  pf=$(disk_guard_pidfile "$tag")
  if [ "$DISK_GUARD" != 1 ]; then say "DISK_GUARD_DISABLED tag=$tag (DISK_GUARD=0)"; return 0; fi
  if [ ! -f "$DG_SCRIPT" ]; then say "DISK_GUARD_MISSING $DG_SCRIPT -- the arm runs unguarded"; return 1; fi
  p=$(disk_guard_pid "$tag")
  if [ -n "$p" ]; then say "DISK_GUARD_ALREADY_RUNNING tag=$tag pid=$p"; return 0; fi
  [ -s "$pf" ] && say "DISK_GUARD_STALE_PIDFILE tag=$tag pid=$(cat "$pf" 2>/dev/null || echo none)"
  mkdir -p "$DG_WS/logs"
  # setsid where it exists: the guard outlives this shell's session. Where it does
  # not (a developer's Git Bash), plain nohup still detaches it -- and the guard is
  # stopped by pid, never by pattern (a pattern would also match the chain's own
  # log lines).
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup env TAG="$tag" CONTAINER="$con" ROOT="$DG_ROOT" \
        LOG="$DG_LOG" PIDFILE="$pf" \
        bash "$DG_SCRIPT" >> "$DG_NOHUP" 2>&1 < /dev/null &
  else
    nohup env TAG="$tag" CONTAINER="$con" ROOT="$DG_ROOT" \
        LOG="$DG_LOG" PIDFILE="$pf" \
        bash "$DG_SCRIPT" >> "$DG_NOHUP" 2>&1 < /dev/null &
  fi
  sleep 2
  p=$(disk_guard_pid "$tag")
  if [ -n "$p" ]; then
    say "DISK_GUARD_STARTED tag=$tag pid=$p container=$con"
    return 0
  fi
  say "DISK_GUARD_START_FAILED tag=$tag -- see $DG_LOG and $DG_NOHUP"
  return 1
}

disk_guard_stop() {  # disk_guard_stop <tag>
  local tag=${1:?tag} pf p i
  pf=$(disk_guard_pidfile "$tag")
  if [ "$DISK_GUARD" != 1 ]; then return 0; fi
  p=$(disk_guard_pid "$tag")
  if [ -z "$p" ]; then
    [ -s "$pf" ] && rm -f "$pf"
    say "DISK_GUARD_STOPPED tag=$tag (not running)"
    return 0
  fi
  kill "$p" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
  # Backstop, and it is safe: the guard holds no state that needs flushing (the
  # removal map is appended one row per removal, no temp files), so a SIGKILL can
  # lose a log line but never a decision or a half-written record.
  if kill -0 "$p" 2>/dev/null; then
    kill -9 "$p" 2>/dev/null; sleep 1
    if kill -0 "$p" 2>/dev/null; then
      say "DISK_GUARD_STOP_FAILED tag=$tag pid=$p still alive after SIGTERM and SIGKILL"
      return 1
    fi
    rm -f "$pf"
    say "DISK_GUARD_STOPPED tag=$tag pid=$p (SIGKILL, after 5s of SIGTERM)"
    return 0
  fi
  rm -f "$pf"
  say "DISK_GUARD_STOPPED tag=$tag pid=$p"
  return 0
}

disk_guard_status() {  # disk_guard_status <tag>
  local p
  p=$(disk_guard_pid "${1:?tag}")
  if [ -n "$p" ]; then say "DISK_GUARD tag=$1 pid=$p running"; else say "DISK_GUARD tag=$1 not running"; fi
}
