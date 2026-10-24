#!/bin/bash
# drt_disk_guard.sh -- keep the flow volume from filling under the DRT
# antenna-repair loop, while that loop is still producing route databases.
#
# WHY THIS FILE EXISTS
#
#   Step `06-openroad-detailedrouting` writes one `drt-run-N/chip_top.odb` per
#   route pass -- ~400-420 MB each on the die -- and the step contains a loop
#   that keeps adding passes while `repair_antennas` is still inserting diodes
#   (up to `DRT_ANTENNA_REPAIR_ITERS`, 10 here). On run `died26q4` the volume was
#   at 90 % used with 16 GB free when pass 5 of a possible 11 was running: five
#   more passes plus the fill stage and stream-out is more than the volume has,
#   and the failure mode is not clean. LibreLane writes the ODB at the end of a
#   pass, so a full volume lands *mid-pass* as a truncated write hours into
#   work that cannot be resumed past it.
#
#   Nothing in the flow watches disk for this: `gate.sh` gates a chain BEFORE it
#   launches (GATE_MIN_GB, 6 GB), and `drt_extend_ws.sh` gates before an
#   extension, but nothing runs while the step itself is in flight. That gap is
#   what this guard fills. It is a separate process on purpose: `watch_drt_curve.sh`
#   is already running on the live arm and restarts only when relaunched, so a
#   guard bolted into it would not be watching the run that needed it.
#
# WHAT IT DOES, IN ORDER (one evaluation per POLL, default 300 s)
#
#   1. reads free GB on MOUNT (gate.sh's `free_gb`, the same function every chain
#      gates with -- one definition of "free space" on this box, not a second one);
#   2. if free < SOFT_GB, removes the OLDEST prunable `chip_top.odb` files until
#      free >= TARGET_GB or there is nothing left to prune, and writes what it
#      removed to `ws/logs/drt_disk_guard_pruned.md` BEFORE removing it, so a pass
#      that has been pruned can still be identified afterwards;
#   3. if free is still < HARD_GB, the volume cannot carry another pass, so it
#      stops the flow (`docker kill $CONTAINER`) rather than let a route be
#      truncated into a corrupt ODB. GUARD_STOP=0 turns that into a logged
#      request instead -- the stop is the only irreversible action here.
#
# WHAT IS PRUNABLE, AND WHAT IS NEVER TOUCHED
#
#   Prunable: `drt-run-<N>/chip_top.odb` inside the step dir of TAG, oldest
#   first. These are intermediates: each pass reads the previous one at startup
#   and never again, and the pass's own verdict (violation count, wall clock,
#   DRC report) lives in its log and its `chip_top.drc` (2.6 MB, kept).
#
#   Never touched, and the guard refuses to run at all if it cannot name them:
#     * the newest `drt-run-*` -- it is the pass in flight or the one just
#       written, and `write_db` may still be flushing it;
#     * the one before it (KEEP_LAST=1) -- the rollback point if the newest is
#       bad;
#     * `drt-run-0` -- the only route this design has produced that is not
#       hopeless (75,455 violations against ~1.03 M later), so its ODB is
#       evidence, not an intermediate;
#     * any `chip_top.odb` named by the step's `state_in.json`/`state_out.json`;
#     * anything outside `runs/<TAG>/06-openroad-detailedrouting/drt-run-*/` --
#       the step-04 (repairantennas) database that DRT consumes is the input of
#       every pass and lives in another step dir entirely;
#     * `*.drc`, metrics, logs, and every other file: only the ODB is pruned.
#
#   The step tree is root-owned (the flow runs `--user 0:0`), so a host `rm`
#   cannot remove those files. When the directory is not host-writable the guard
#   removes them with a one-shot root container on the same bind mount --
#   `docker run --rm --user 0:0 -v $ROOT:/work --entrypoint rm $IMAGE -f ...`,
#   measured at 0.68 s on this box. NOT `docker exec $CONTAINER`: exec is broken
#   on the flow's container here (`openat etc/group: path escapes from parent`,
#   measured 2026-10-23), and a fallback that cannot run is worse than none --
#   the guard would log GUARD_PRUNE_FAILED and go straight to the hard floor.
#   `reclaim_disk.sh` already removes root-owned flow files this way. Never sudo.
#
# USAGE
#
#   Chains do not call this directly -- they source `build/disk_guard.sh` and call
#   `disk_guard_start`, so the arm they launch is guarded from the moment its
#   container is up and the guard is stopped when the chain exits (including on
#   an early abort). A by-hand launch is the same command the helper issues:
#
#   nohup bash build/drt_disk_guard.sh > /dev/null 2>&1 &      # the guard
#   tail -f ws/logs/drt_disk_guard.log
#   ONE_SHOT=1 DRY=1 bash build/drt_disk_guard.sh              # report, change nothing
#
#   TAG=died26q4            the run tag whose step dir is guarded
#   STEP=*-openroad-detailedrouting   the step dir, matched as a glob inside
#                           runs/<tag> (the die arm's is `06-...`; ws_chain's is
#                           not 06, so the number is discovered, not assumed)
#   PIDFILE=<path>          one guard per tag; a live pid there refuses a second
#   MOUNT=/                 the volume the flow writes (df's own mount)
#   SOFT_GB=12              prune below this
#   TARGET_GB=14            prune until at least this (or exhausted)
#   HARD_GB=4               stop the flow below this, after pruning
#   POLL=300                seconds between evaluations
#   KEEP_LAST=1             completed passes to keep besides run-0
#   CONTAINER=die_predrt    the flow's container
#   GUARD_STOP=1            0 = log GUARD_STOP_REQUEST and do not kill
#   DRY=1                   log WOULD_PRUNE / WOULD_STOP, change nothing
#   GUARD_FORCE_DOCKER=1    take the docker-exec path even on a writable dir
#                           (the selftest's hook for the root-owned case)
#   ONE_SHOT=1              one evaluation, then exit (0 ok, 2 stopped)
#
#   Exit: 0 = nothing needed or pruned, 2 = flow stopped, 0 also = already running
#   for this tag (the second copy says GUARD_ALREADY_RUNNING and does nothing).
#
# WHAT IT DOES NOT COVER
#
#   * One evaluation per POLL, so a write that fills the volume inside one poll
#     window is not stopped -- the margin above HARD_GB is what covers that, not
#     a guarantee.
#   * Only route ODBs are pruned. Docker's own usage, the fill stage's output and
#     the step-04 repair database are outside what this file is willing to touch.
#   * A `docker kill` is irreversible for the step: the arm has to be relaunched.
#     GUARD_STOP=0 records the request instead, for anyone who would rather have a
#     corrupt ODB than a stopped arm.
#   * It stops itself when its container has been gone for two polls. That is the
#     one case a chain's EXIT trap cannot cover -- a chain killed with -9 never
#     reaches it -- and nothing can grow the step tree once the container is gone.
#     Two polls, not one, so a docker hiccup is not read as the end of an arm.
#
# VERIFY IT
#
#   bash build/drt_disk_guard_selftest.sh
#     Builds a fake step tree and drives every branch through the real code
#     path: above the soft floor (no prune), below it (oldest-first prune, the
#     protected set intact, map written), prune exhausted with the flow alive,
#     the docker-exec branch (host cannot write the dir), below the hard floor
#     with GUARD_STOP=1 (kill named correctly) and with GUARD_STOP=0 (request
#     only), DRY (nothing removed), and a numeric-unreadable df (no action taken
#     on a number it could not read). `docker` is stubbed; no container is
#     touched and nothing outside the temp dir is written.
#
#     Its last section asks whether this file is still STARTED: every chain in
#     build/disk_guard.sh's registry must source the helper, start it after its
#     own launch and stop it on every way out, and a chain that starts a flow
#     container without being wired or exempted fails it. That check is run
#     against three deliberately unwired copies as well, so it cannot rot into a
#     pass -- and it runs in CI (build/chain_selftests.sh, row `disk-guard`), so a
#     chain edit that drops the guard fails the push rather than the next arm.
set -u

B=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=${ROOT:-/home/ubuntu/grx930_ol2}
TAG=${TAG:-died26q4}
# Matched as a glob inside runs/$TAG, not a fixed step number: the die arm's DRT
# is step 06, ws_chain's is not, and a guard that silently watches a directory
# that never appears protects nothing. Resolved on every evaluation, so a step
# dir created hours after the arm starts is picked up.
STEP=${STEP:-*-openroad-detailedrouting}
MOUNT=${MOUNT:-/}
SOFT_GB=${SOFT_GB:-12}
TARGET_GB=${TARGET_GB:-14}
HARD_GB=${HARD_GB:-4}
POLL=${POLL:-300}
KEEP_LAST=${KEEP_LAST:-1}
CONTAINER=${CONTAINER:-die_predrt}
PRUNE_IMAGE=${PRUNE_IMAGE:-ghcr.io/wafer-space/gf180mcu-precheck}
GUARD_STOP=${GUARD_STOP:-1}
DRY=${DRY:-0}
ONE_SHOT=${ONE_SHOT:-0}
LOG=${LOG:-$ROOT/ws/logs/drt_disk_guard.log}
MAP=${MAP:-$ROOT/ws/logs/drt_disk_guard_pruned.md}
RUN=$ROOT/ws/template/librelane/runs/$TAG
PIDFILE=${PIDFILE:-$ROOT/ws/logs/drt_disk_guard.$TAG.pid}
S=""
resolve_step() { find "$RUN" -maxdepth 1 -type d -name "$STEP" 2>/dev/null | sort -V | head -1; }

say() { local m; m="$(date -u '+%F %T') $*"; printf '%s\n' "$m"; [ -n "$LOG" ] && printf '%s\n' "$m" >> "$LOG"; }

# free_gb is gate.sh's, not a second copy of `df` -- the chains gate on that
# number, so the guard has to be reading the same one.
# shellcheck source=gate.sh
. "$B/gate.sh"

# The selftest drives the thresholds by pinning the reading; the real path is
# always gate.sh's df. GUARD_FREE_GB exists for that and nothing else.
guard_free_gb() {
  if [ -n "${GUARD_FREE_GB:-}" ]; then printf '%s\n' "$GUARD_FREE_GB"; return; fi
  free_gb "$MOUNT"
}

is_num() { case ${1:-} in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# The image a one-shot root removal runs in: the flow's own, so it is already
# present and is the image that wrote these files. Resolved once, not per prune.
flow_image() {
  [ -n "${FLOW_IMG_CACHE:-}" ] && { printf '%s\n' "$FLOW_IMG_CACHE"; return; }
  FLOW_IMG_CACHE=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null)
  [ -n "$FLOW_IMG_CACHE" ] || FLOW_IMG_CACHE=$PRUNE_IMAGE
  printf '%s\n' "$FLOW_IMG_CACHE"
}

# Container-side path: the flow's tree is mounted at /work.
ctr_path() { printf '/work/%s\n' "${1#"$ROOT"/}"; }

all_runs() { find "$S" -maxdepth 1 -type d -name 'drt-run-*' 2>/dev/null | sort -V; }

newest_run() { all_runs | tail -1; }

# The protected set is a list of directories, one per line. Named here once and
# used by both the pruner and the selftest's assertions.
protected_runs() {
  local -a runs=()
  mapfile -t runs < <(all_runs)
  local n=${#runs[@]} i
  [ "$n" -eq 0 ] && return 0
  printf '%s\n' "${runs[$((n - 1))]}"                       # the pass in flight / just written
  for ((i = 2; i <= KEEP_LAST + 1; i++)); do
    [ $((n - i)) -ge 0 ] && printf '%s\n' "${runs[$((n - i))]}"
  done
  local r
  for r in "${runs[@]}"; do
    [ "$(basename "$r")" = drt-run-0 ] && printf '%s\n' "$r"
  done
  # Any database the step's own state files name. Cheap to check, and it is the
  # difference between "a guess about which pass is resumable" and the flow's
  # own answer.
  local j p
  for j in "$S/state_in.json" "$S/state_out.json"; do
    [ -f "$j" ] || continue
    while IFS= read -r p; do
      # $STEP unquoted: it is a glob, and a quoted expansion in a case pattern is
      # matched literally (`*-openroad-detailedrouting` would then only match a
      # directory named with a star in it).
      case $p in */$STEP/drt-run-*/chip_top.odb) printf '%s\n' "$(dirname "${p#/work/}")" | sed "s|^|$ROOT/|" ;; esac
    done < <(grep -o '"[^"]*chip_top\.odb"' "$j" 2>/dev/null | tr -d '"')
  done
}

# Oldest first, so the pass that has been superseded longest goes first.
prunable() {
  local -A prot=()
  local d
  while IFS= read -r d; do [ -n "$d" ] && prot[$d]=1; done < <(protected_runs)
  local r
  while IFS= read -r r; do
    [ -n "${prot[$r]:-}" ] && continue
    [ -f "$r/chip_top.odb" ] && printf '%s\n' "$r/chip_top.odb"
  done < <(all_runs)
}

size_mb() { local b; b=$(stat -c %s "$1" 2>/dev/null) || return 1; is_num "$b" || return 1; echo $((b / 1000000)); }

map_row() {  # $1 file, $2 free before, $3 free after
  if [ ! -f "$MAP" ]; then
    {
      printf '# Route databases pruned by build/drt_disk_guard.sh\n\n'
      printf 'These are `drt-run-N/chip_top.odb` intermediates removed to keep the flow volume\n'
      printf 'from filling under the antenna-repair loop. The pass itself is not lost: its\n'
      printf 'violation count is in the step log (the `DRT-0199` line) and its DRC report is\n'
      printf 'still beside where the ODB was. `run-0`, the newest pass and the pass before it\n'
      printf 'are never pruned.\n\n'
      printf '| removed (UTC) | database | size | free before -> after |\n'
      printf '|---|---|---|---|\n'
    } > "$MAP"
  fi
  printf '| %s | `%s` | %s MB | %s G -> %s G |\n' \
    "$(date -u '+%F %T')" "${1#"$S"/}" "$(size_mb "$1")" "$2" "$3" >> "$MAP"
}

prune_one() {  # $1 = odb path; 0 = it is gone
  local f=$1 dir img
  [ -f "$f" ] || return 1
  case $f in "$S"/drt-run-*/chip_top.odb) ;; *) say "GUARD_REFUSE outside_step_dir $f"; return 1 ;; esac
  dir=$(dirname "$f")
  # Belt and braces: evaluate() already intercepts DRY, so reaching here with
  # DRY set would be a caller bug -- and a caller bug must not be a deletion.
  [ "$DRY" = 1 ] && return 1
  if [ -w "$dir" ] && [ "${GUARD_FORCE_DOCKER:-0}" != 1 ]; then
    rm -f -- "$f" || { say "GUARD_PRUNE_FAILED host $f"; return 1; }
  else
    img=$(flow_image)
    docker run --rm --user 0:0 -v "$ROOT:/work" --entrypoint rm "$img" -f "$(ctr_path "$f")" >/dev/null 2>&1 \
      || { say "GUARD_PRUNE_FAILED docker_run image=$img $f"; return 1; }
  fi
  [ -f "$f" ] && { say "GUARD_PRUNE_FAILED still_present $f"; return 1; }
  return 0
}

stop_flow() {  # $1 free GB
  if [ "$DRY" = 1 ]; then say "WOULD_STOP free_gb=$1 hard=$HARD_GB container=$CONTAINER"; return 2; fi
  if [ "$GUARD_STOP" != 1 ]; then
    say "GUARD_STOP_REQUEST free_gb=$1 hard=$HARD_GB container=$CONTAINER (GUARD_STOP=0, not stopping)"
    return 0
  fi
  say "GUARD_STOPPED free_gb=$1 hard=$HARD_GB container=$CONTAINER -- nothing left to prune and the volume cannot carry another pass"
  docker kill "$CONTAINER" >/dev/null 2>&1 || say "GUARD_STOP_FAILED docker kill $CONTAINER"
  return 2
}

evaluate() {
  local free before n=0 f mb=0
  S=$(resolve_step)
  [ -z "$S" ] && say "GUARD_WAIT step_dir_absent run=$RUN step=$STEP"
  free=$(guard_free_gb)
  if ! is_num "$free"; then
    # An unreadable figure is not "enough disk": the same rule gate.sh states.
    say "GUARD_DISK_UNREADABLE mount=$MOUNT -- no action taken on a number it could not read"
    return 0
  fi
  local -a cands=()
  mapfile -t cands < <(prunable)
  local prunable_mb=0
  for f in "${cands[@]}"; do [ -n "$f" ] && prunable_mb=$((prunable_mb + $(size_mb "$f" 2>/dev/null || echo 0))); done
  say "GUARD_STATE tag=$TAG free_gb=$free soft=$SOFT_GB target=$TARGET_GB hard=$HARD_GB prunable=${#cands[@]} prunable_mb=$prunable_mb step_dir=${S:-absent}"
  before=$free

  if [ "$free" -lt "$SOFT_GB" ] && [ "${#cands[@]}" -gt 0 ]; then
    for f in "${cands[@]}"; do
      [ -z "$f" ] && continue
      free=$(guard_free_gb)
      is_num "$free" || break
      [ "$free" -ge "$TARGET_GB" ] && break
      mb=$(size_mb "$f" 2>/dev/null || echo 0)
      if [ "$DRY" = 1 ]; then
        # Said once, and nothing else: a dry run that also logged GUARD_PRUNE ok
        # and wrote the removal map would be unreadable as a dry run.
        say "WOULD_PRUNE $f size_mb=$mb free_gb=$free"
        n=$((n + 1)); continue
      fi
      # The map row goes in only after the file is actually gone: written first,
      # a failed removal would leave the map claiming a database it did not
      # remove (measured on the probe tree before this was moved).
      if prune_one "$f"; then
        n=$((n + 1))
        map_row "$f" "$before" "$((before + mb))"; before=$((before + mb))
        say "GUARD_PRUNE ok $f size_mb=$mb free_gb_now=$(guard_free_gb)"
      fi
    done
    free=$(guard_free_gb)
    is_num "$free" || free=0
    if [ "$DRY" = 1 ]; then
      say "GUARD_PRUNE_DRY would_prune=$n free_gb=$free target=$TARGET_GB"
    else
      if [ "$free" -lt "$TARGET_GB" ] && [ "${#cands[@]}" -gt 0 ]; then
        say "GUARD_PRUNE_EXHAUSTED pruned=$n free_gb=$free target=$TARGET_GB -- nothing prunable is left"
      fi
      say "GUARD_PRUNE_DONE pruned=$n free_gb=$free"
    fi
  fi

  if [ "$free" -lt "$HARD_GB" ]; then stop_flow "$free"; return $?; fi
  return 0
}

# One guard per tag. A chain starts it and stops it, so a second copy is either
# a double-start (the helper sources are idempotent, but a hand launch is not) or
# a stale pidfile from a chain killed with -9. Both are answered here rather than
# by two guards pruning the same volume. ONE_SHOT is exempt: a one-shot run is a
# report, not a supervisor, and it must work while the supervisor is up.
if [ "$ONE_SHOT" != 1 ]; then
  if [ -s "$PIDFILE" ]; then
    p=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "${p:-}" ] && kill -0 "$p" 2>/dev/null; then
      say "GUARD_ALREADY_RUNNING tag=$TAG pid=$p -- this tag is already guarded"
      exit 0
    fi
    say "GUARD_PIDFILE_STALE tag=$TAG pid=${p:-none} -- starting anyway"
  fi
  printf '%s\n' "$$" > "$PIDFILE"
  trap 'exit 0' TERM INT
  trap 'rc=$?; [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"; exit "$rc"' EXIT
fi
say "GUARD_START tag=$TAG run=$RUN step=$STEP mount=$MOUNT soft=$SOFT_GB target=$TARGET_GB hard=$HARD_GB poll=$POLL container=$CONTAINER stop=$GUARD_STOP dry=$DRY one_shot=$ONE_SHOT pidfile=$PIDFILE"

if [ "$ONE_SHOT" = 1 ]; then evaluate; exit $?; fi
GONE=0
while :; do
  evaluate; rc=$?
  [ "$rc" = 2 ] && { say "GUARD_EXIT stopped -- relaunch after the next arm starts"; exit 2; }
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    GONE=0
  else
    GONE=$((GONE + 1))
    if [ "$GONE" -ge 2 ]; then
      say "GUARD_EXIT container_gone name=$CONTAINER -- nothing can write the step tree now, retiring"
      exit 0
    fi
    say "GUARD_CONTAINER_ABSENT name=$CONTAINER poll=$GONE/2"
  fi
  # `sleep & wait`: bash runs a trap as soon as the signal arrives while it is in
  # `wait`, but a plain `sleep 300` defers the TERM until the sleep returns -- so
  # a chain stopping its guard would wait out the whole poll interval (measured on
  # the first version of the helper: "still alive after 5s" with POLL=300).
  sleep "$POLL" & sp=$!
  wait "$sp" 2>/dev/null || true
done
