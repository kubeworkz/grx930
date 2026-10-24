#!/bin/bash
# drt_disk_guard_selftest.sh -- every branch of build/drt_disk_guard.sh, through
# the real script, with `docker` stubbed and the free-space reading pinned.
#
# The guard's job is to act on two numbers (free GB, and which run dirs are
# safe to remove). Both are injected rather than measured here -- GUARD_FREE_GB
# pins the reading, GUARD_FORCE_DOCKER exercises the root-only removal path --
# so the assertions are about the decisions and the protected set, not about df
# or about this box. No container is touched; nothing outside the temp dir is
# written. Exits non-zero on the first drifted contract.
#
# Section 19 is a different question, and the one CI needs: is the guard still
# WIRED into the chains that launch an arm? A guard that behaves correctly and is
# never started protects nothing, and losing its one start line breaks no other
# test in this repository. It is checked against a deliberately unwired copy too
# (three of them), so the check itself cannot drift into a pass.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/drt_disk_guard.sh
T=$(mktemp -d)
# Kill any guard this test started (by pidfile only, never by pattern) before the
# tree goes away, so a fixture cannot leave a poller behind on the developer's box.
cleanup() {
  local pf p
  for pf in "$T"/root/ws/logs/drt_disk_guard.*.pid; do
    [ -f "$pf" ] || continue
    p=$(cat "$pf" 2>/dev/null)
    case ${p:-} in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null ;; esac
  done
  chmod -R u+w "$T" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/bin" "$T/logs"
FAIL=0; PASS=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*"; }
has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 -- missing: $2"; fi; }
hasnt() { if [ -f "$1" ] && grep -qF -- "$2" "$1"; then bad "$3 -- unexpected: $2"; else ok "$3"; fi; }
exists() { if [ -e "$1" ]; then ok "$2"; else bad "$2 -- absent: $1"; fi; }
gone()   { if [ -e "$1" ]; then bad "$2 -- still present: $1"; else ok "$2"; fi; }

# docker stub: records every call, performs the rm the guard asks for (mapping
# the container's /work back onto the fake ROOT), and does not kill anything.
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
printf 'DOCKER %s\n' "$*" >> "$STUB_LOG"
case ${1:-} in
  inspect) printf 'stub-image\n'; exit 0 ;;
  run)
    [ "${STUB_FAIL:-0}" = 1 ] && { echo "stub: refusing to run" >&2; exit 1; }
    # --entrypoint rm IMAGE -f /work/... : perform the removal the guard asked
    # for, mapping the container's /work back onto the fake ROOT.
    prev=""
    for a in "$@"; do
      if [ "$prev" = -f ]; then rm -f "${a/#\/work/$STUB_ROOT}" 2>/dev/null || true; fi
      prev=$a
    done
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker"

mktree() {  # mktree <n-runs>  -> runs drt-run-0 .. drt-run-<n-1>
  rm -rf "$T/root"; mkdir -p "$T/root/ws/template/librelane/runs/T/06-openroad-detailedrouting" "$T/root/ws/logs"
  local i d
  for ((i = 0; i < $1; i++)); do
    d=$T/root/ws/template/librelane/runs/T/06-openroad-detailedrouting/drt-run-$i
    mkdir -p "$d"
    printf 'drc\n' > "$d/chip_top.drc"
    head -c 1048576 /dev/zero > "$d/chip_top.odb"
    touch -d "2026-10-2$i 0$i:00:00" "$d"
  done
}

run_guard() {  # run_guard <env...> -> exit code; output in $T/out.log
  : > "$T/out.log"
  # PATH is quoted: an unquoted one word-splits on any "Program Files" in it,
  # and the failure is an exit 127 with an empty log that looks like a bad script.
  env "PATH=$T/bin:$PATH" ROOT=$T/root TAG=T LOG=$T/logs/guard.log MAP=$T/logs/map.md \
      STUB_LOG=$T/logs/docker.log STUB_ROOT=$T/root ONE_SHOT=1 \
      "$@" bash "$SCRIPT" > "$T/out.log" 2>&1
  echo $?
}

R=$T/root/ws/template/librelane/runs/T/06-openroad-detailedrouting

echo "=== 1. above the soft floor: no prune, no stop ==="
mktree 6; rm -f "$T/logs/map.md" "$T/logs/docker.log"
rc=$(run_guard GUARD_FREE_GB=20)
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc, wanted 0"
has "$T/out.log" "GUARD_STATE tag=T free_gb=20" "state line names the reading"
# 6 runs: newest (5), the one before it (4) and run-0 are protected -> 1,2,3 prunable.
has "$T/out.log" "prunable=3" "prunable set is the three superseded passes"
hasnt "$T/out.log" "GUARD_PRUNE ok" "nothing pruned above the soft floor"
for i in 0 1 2 3 4 5; do exists "$R/drt-run-$i/chip_top.odb" "run-$i odb kept"; done
[ -f "$T/logs/map.md" ] && bad "map written with nothing pruned" || ok "no map when nothing pruned"

echo
echo "=== 2. below the soft floor: oldest-first prune, protected set intact ==="
mktree 6; rm -f "$T/logs/map.md"
rc=$(run_guard GUARD_FREE_GB=10)
[ "$rc" = 0 ] && ok "exit 0 (above the hard floor)" || bad "exit $rc, wanted 0"
for i in 1 2 3; do gone "$R/drt-run-$i/chip_top.odb" "run-$i (superseded) pruned"; done
for i in 0 4 5; do exists "$R/drt-run-$i/chip_top.odb" "run-$i (protected) kept"; done
exists "$R/drt-run-1/chip_top.drc" "run-1 drc report kept (only the ODB is pruned)"
has "$T/out.log" "GUARD_PRUNE_DONE pruned=3" "three prunes counted"
has "$T/out.log" "GUARD_PRUNE_EXHAUSTED" "target unreachable is said out loud"
has "$T/logs/map.md" '`drt-run-1/chip_top.odb`' "map records what was removed"
has "$T/logs/map.md" '`drt-run-3/chip_top.odb`' "map records the last one too"
[ -f "$T/logs/docker.log" ] && bad "used docker although the dir was writable" || ok "host rm used when the dir is writable"

echo
echo "=== 3. below the hard floor: stops the flow (named container) ==="
mktree 6; rm -f "$T/logs/docker.log"
rc=$(run_guard GUARD_FREE_GB=3)
[ "$rc" = 2 ] && ok "exit 2 (stopped)" || bad "exit $rc, wanted 2"
has "$T/out.log" "GUARD_STOPPED free_gb=3 hard=4 container=die_predrt" "stop recorded with the numbers"
has "$T/logs/docker.log" "DOCKER kill die_predrt" "docker kill named the flow container"

echo
echo "=== 4. below the hard floor, GUARD_STOP=0: request only ==="
mktree 6; rm -f "$T/logs/docker.log"
rc=$(run_guard GUARD_FREE_GB=3 GUARD_STOP=0)
[ "$rc" = 0 ] && ok "exit 0 (requested, not stopped)" || bad "exit $rc, wanted 0"
has "$T/out.log" "GUARD_STOP_REQUEST" "stop request logged"
hasnt "$T/logs/docker.log" "kill" "nothing was killed"

echo
echo "=== 5. DRY=1: reports, changes nothing ==="
mktree 6; rm -f "$T/logs/map.md"
rc=$(run_guard GUARD_FREE_GB=10 DRY=1)
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
has "$T/out.log" "WOULD_PRUNE" "dry run says what it would remove"
has "$T/out.log" "GUARD_PRUNE_DRY would_prune=3" "dry run counts what it would remove, once"
hasnt "$T/out.log" "GUARD_PRUNE ok" "dry run does not claim to have pruned"
[ -f "$T/logs/map.md" ] && bad "dry run wrote the removal map" || ok "dry run writes no removal map"
for i in 1 2 3; do exists "$R/drt-run-$i/chip_top.odb" "run-$i untouched in DRY"; done
rc=$(run_guard GUARD_FREE_GB=2 DRY=1)
has "$T/out.log" "WOULD_STOP" "dry run says it would stop the flow"

echo
echo "=== 6. root-owned tree: removal goes through a one-shot root container ==="
mktree 6; rm -f "$T/logs/docker.log"
rc=$(run_guard GUARD_FREE_GB=10 GUARD_FORCE_DOCKER=1)
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
has "$T/logs/docker.log" "DOCKER run --rm --user 0:0 -v $T/root:/work --entrypoint rm stub-image -f /work/ws/template/librelane/runs/T/06-openroad-detailedrouting/drt-run-1/chip_top.odb" \
  "one-shot root container on the same mount, container path not host path"
hasnt "$T/logs/docker.log" "exec" "docker exec is not used (it is broken on the flow's container)"
gone "$R/drt-run-1/chip_top.odb" "run-1 removed through the container"

echo
echo "=== 7. unreadable free space: no action on a number it cannot read ==="
mktree 6
rc=$(run_guard GUARD_FREE_GB=abc)
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
has "$T/out.log" "GUARD_DISK_UNREADABLE" "unreadable reading is refused, not treated as plenty"
for i in 1 2 3; do exists "$R/drt-run-$i/chip_top.odb" "run-$i kept when the reading is garbage"; done

echo
echo "=== 8. run-0 is never the one that goes, even as the only pass ==="
mktree 1
rc=$(run_guard GUARD_FREE_GB=2)
[ "$rc" = 2 ] && ok "exit 2 (stopped rather than prune run-0)" || bad "exit $rc, wanted 2"
exists "$R/drt-run-0/chip_top.odb" "run-0 odb kept (the only non-hopeless route)"

echo
echo "=== 9. a database named by state_in.json is protected ==="
mktree 6
cat > "$R/state_in.json" <<EOF
{ "odb": "/work/ws/template/librelane/runs/T/06-openroad-detailedrouting/drt-run-2/chip_top.odb" }
EOF
rc=$(run_guard GUARD_FREE_GB=10)
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
exists "$R/drt-run-2/chip_top.odb" "run-2 kept (the step's own state names it)"
gone "$R/drt-run-1/chip_top.odb" "run-1 pruned"
gone "$R/drt-run-3/chip_top.odb" "run-3 pruned"

echo
echo "=== 10. KEEP_LAST=2 keeps one more completed pass ==="
mktree 6
rc=$(run_guard GUARD_FREE_GB=10 KEEP_LAST=2)
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
for i in 0 3 4 5; do exists "$R/drt-run-$i/chip_top.odb" "run-$i kept with KEEP_LAST=2"; done
for i in 1 2; do gone "$R/drt-run-$i/chip_top.odb" "run-$i pruned with KEEP_LAST=2"; done

echo
echo "=== 11. no step dir at all: waits instead of failing ==="
rm -rf "$T/root"; mkdir -p "$T/root/ws/logs"
rc=$(run_guard GUARD_FREE_GB=20)
[ "$rc" = 0 ] && ok "exit 0 with no step dir" || bad "exit $rc"
has "$T/out.log" "step_dir_absent" "says the step dir is not there yet"

echo
echo "=== 12. a failed removal is reported and is not put in the map ==="
mktree 6; rm -f "$T/logs/map.md"
rc=$(run_guard GUARD_FREE_GB=10 GUARD_FORCE_DOCKER=1 STUB_FAIL=1)
[ "$rc" = 0 ] && ok "exit 0 (still above the hard floor)" || bad "exit $rc"
has "$T/out.log" "GUARD_PRUNE_FAILED docker_run" "failed removal is named with its cause"
for i in 1 2 3; do exists "$R/drt-run-$i/chip_top.odb" "run-$i kept when removal failed"; done
[ -f "$T/logs/map.md" ] && bad "map claims a removal that did not happen" || ok "no map rows for removals that failed"


echo
echo "=== 13-17. the sourced helper: start, idempotency, status, stop, stale pidfile ==="
# A smaller driver that sources disk_guard.sh exactly as a chain does (say/ROOT/WS
# defined first) and then issues one call. GUARD_FREE_GB is pinned well above the
# soft floor so a test poller can never prune the fixture tree.
cat > "$T/drv.sh" <<'SH'
#!/bin/bash
set -u
ROOT=${ROOT:?}; WS=$ROOT/ws; LOG=$ROOT/drv.log
say() { echo "[drv] $*" | tee -a "$LOG"; }
. "$HELPER"
case ${1:-} in
  start)  disk_guard_start "$2" die_predrt ;;
  stop)   disk_guard_stop "$2" ;;
  status) disk_guard_status "$2" ;;
esac
SH
chmod +x "$T/drv.sh"
HELPER=$HERE/disk_guard.sh
PF=$T/root/ws/logs/drt_disk_guard.T.pid
clear_guards() {  # kill whatever this section left, by pidfile only
  local pf p
  for pf in "$T"/root/ws/logs/drt_disk_guard.*.pid; do
    [ -f "$pf" ] || continue
    p=$(cat "$pf" 2>/dev/null)
    case "${p:-}" in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null ;; esac
    rm -f "$pf"
  done
  sleep 1
}
mktree 3; rm -f "$T/drv.log" "$T/root/ws/logs/drt_disk_guard.log"
chk() { if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1: expected [$2] got [$3]"; fi; }
# "Exactly one guard" is counted from the guard's own log, not from the process
# table: on the flow box a real guard for the live arm runs the same script path, so
# `pgrep -f` counts it too (measured: "expected [1] got [2]" on the box while an arm
# was in flight). A second copy would announce itself with a second GUARD_START.
starts() { grep -c 'GUARD_START tag=T ' "$T/root/ws/logs/drt_disk_guard.log" 2>/dev/null || true; }
# env assignments first, the command last: `env A=1 start T bash ...` would try to
# run `start` and is exactly how this section was written the first time.
drv() { env "PATH=$T/bin:$PATH" ROOT=$T/root HELPER=$HELPER DG_SCRIPT=$SCRIPT \
          GUARD_FREE_GB=99 POLL=${DPOLL:-60} bash "$T/drv.sh" "$@" 2>&1; }

out=$(drv start T die_predrt)
chk "13: start says what it started" 1 "$(printf '%s' "$out" | grep -c 'DISK_GUARD_STARTED tag=T')"
[ -s "$PF" ] && ok "13: pidfile written" || bad "13: no pidfile at $PF"
P1=$(cat "$PF" 2>/dev/null || echo none)
kill -0 "$P1" 2>/dev/null && ok "13: guard pid $P1 is alive" || bad "13: guard pid $P1 is not alive"
chk "13: exactly one guard started" 1 "$(starts)"

out=$(drv start T die_predrt)
chk "14: second start is a no-op" 1 "$(printf '%s' "$out" | grep -c 'DISK_GUARD_ALREADY_RUNNING tag=T')"
chk "14: the pidfile did not change" "$P1" "$(cat "$PF" 2>/dev/null)"
chk "14: no second guard was started" 1 "$(starts)"

out=$(drv status T)
chk "15: status reports it running" 1 "$(printf '%s' "$out" | grep -c "DISK_GUARD tag=T pid=$P1 running")"

out=$(drv stop T)
chk "16: stop says what it stopped" 1 "$(printf '%s' "$out" | grep -c "DISK_GUARD_STOPPED tag=T pid=$P1")"
kill -0 "$P1" 2>/dev/null && bad "16: pid $P1 survived the stop" || ok "16: guard process is gone"
[ -f "$PF" ] && bad "16: pidfile left behind" || ok "16: pidfile removed"
out=$(drv stop T)
chk "16: stopping again is safe" 1 "$(printf '%s' "$out" | grep -c 'DISK_GUARD_STOPPED tag=T (not running)')"

printf '999999\n' > "$PF"
out=$(drv start T die_predrt)
chk "17: a stale pidfile is said out loud, not obeyed" 1 "$(printf '%s' "$out" | grep -c 'DISK_GUARD_STALE_PIDFILE tag=T')"
chk "17: and the guard starts anyway" 1 "$(printf '%s' "$out" | grep -c 'DISK_GUARD_STARTED tag=T')"
clear_guards

out=$(DISK_GUARD=0 drv start T die_predrt)
chk "17b: DISK_GUARD=0 disables the start" 1 "$(printf '%s' "$out" | grep -c 'DISK_GUARD_DISABLED tag=T')"
[ -s "$PF" ] && bad "17b: pidfile written with the guard disabled" || ok "17b: nothing started"

out=$(env "PATH=$T/bin:$PATH" ROOT=$T/root HELPER=$HELPER DG_SCRIPT=$T/nope.sh \
        GUARD_FREE_GB=99 bash "$T/drv.sh" start T die_predrt 2>&1)
chk "17c: a missing guard script is named" 1 "$(printf '%s' "$out" | grep -c 'DISK_GUARD_MISSING')"

clear_guards

echo
echo "=== 18. a guard whose container is gone retires itself ==="
# The stub answers `docker ps` with nothing -- the state after a chain is killed
# without reaching its EXIT trap. Two polls, so a docker hiccup is not read as the
# end of an arm; POLL=1 makes the pair quick.
mktree 3; rm -f "$T/root/ws/logs/drt_disk_guard.log"
# No assertion on DISK_GUARD_STARTED: at POLL=1 the guard can retire inside the
# helper's own 2 s post-launch check, which made this case a race (it failed on the
# box for that reason). GUARD_START in the log is written before the first poll and
# is the honest proof that it ran.
DPOLL=1 drv start T die_predrt >/dev/null 2>&1
has "$T/root/ws/logs/drt_disk_guard.log" "GUARD_START tag=T " "18: it started"
P2=$(cat "$PF" 2>/dev/null || echo none)
sleep 4
has "$T/root/ws/logs/drt_disk_guard.log" "GUARD_CONTAINER_ABSENT name=die_predrt poll=1/2" \
  "18: the first absent poll is said, not acted on"
has "$T/root/ws/logs/drt_disk_guard.log" "GUARD_EXIT container_gone name=die_predrt" \
  "18: the second retires it"
kill -0 "$P2" 2>/dev/null && bad "18: pid $P2 outlived its container" || ok "18: guard process is gone"
[ -f "$PF" ] && bad "18: pidfile left behind" || ok "18: pidfile removed"

clear_guards

echo
echo "=== 19. the wiring: every flow arm starts this guard, and stops it ==="
# WHY THIS SECTION EXISTS
#   The guard is only protection if the chain that launches the arm starts it, and
#   that is one line apiece. The day one is lost -- a rewritten launch block, a new
#   arm copied from an older chain -- nothing else in this repository fails: the arm
#   runs, writes a pass every forty minutes, and the first symptom is the truncated
#   ODB this whole file exists to prevent. So the wiring is asserted here, on every
#   push (build/chain_selftests.sh registers this file), rather than trusted to
#   review.
#
# WHICH CHAINS ARE ARMS, AND WHY THE OTHERS ARE NOT
#   The guard watches `runs/<tag>/*-openroad-detailedrouting/` and touches nothing
#   anywhere else, so the arms are the chains that run the flow TO routing:
#
#     die_drt_chain.sh   resumes the flow at GRT, and is the die's full-flow arm
#                        when PREDRT_STOP is pushed past DRT; its phase-B fast loop
#                        is the instrument this guard's thresholds were measured on.
#     ws_chain.sh        the full Chip flow, no step limit, through routing.
#
#   Every other chain that starts a container is exempt for a stated reason, not
#   by omission: ws_synth_chain.sh pins WS_LIMIT=Checker.YosysSynthChecks (one run
#   tree, no route passes); drt_db_compare_chain.sh runs the fast loop, whose
#   databases are under drt_fast/, outside the tree this guard touches;
#   ws_probe_chain.sh and antenna_probe_chain.sh run one-step probes with their own
#   entry scripts; the OL2 chains (both/core/grt03c/grt_sweep) write into
#   openlane2_rtl/runs, which no guard watches; die_diode_flow_chain.sh starts no
#   container of its own -- it starts die_drt_chain.sh, which guards itself.
#
#   The tripwire at the end is for the NEXT arm: a chain that starts a flow
#   container and appears in neither list fails here, so a new arm is wired or
#   exempted on purpose instead of inheriting this pass.
GUARD_ARMS="die_drt_chain.sh:die_predrt ws_chain.sh:ws_flow"
GUARD_EXEMPT="ws_synth_chain.sh drt_db_compare_chain.sh ws_probe_chain.sh antenna_probe_chain.sh die_diode_flow_chain.sh both_chain.sh core_chain.sh grt03c_chain.sh grt_sweep_chain.sh"

# The check is a function because it is run twice from different trees: once on
# the delivered chains, and once on copies whose wiring was removed. It writes its
# findings to a log and returns 0/1, so the negative runs can be read without
# their FAIL lines counting against the suite.
GW_OUT=""; GW_BAD=0
# The findings are written with the suite's own prefixes so they can be replayed
# through ok/bad (and read the same way in CI), and FAIL is counted here -- the
# caller's return status comes from GW_BAD, so a check that cannot count is a
# check that always passes.
sayf() {
  if [ "$1" = FAIL ]; then
    GW_BAD=$((GW_BAD + 1)); printf 'FAIL %s\n' "$2" >> "$GW_OUT"
  else
    printf 'ok   %s\n' "$2" >> "$GW_OUT"
  fi
}
fnbody() {  # fnbody <function> <file> -- its definition, one-liner or braced block
  awk -v fn="$1" '
    !inb && index($0, fn "()") == 1 {
      print
      if (index($0, "}") > 0) exit
      inb = 1; next
    }
    inb { print; if ($0 ~ /^}/) exit }
  ' "$2"
}
guard_wiring_check() {  # guard_wiring_check <build dir> <log>
  GW_OUT=$2; : > "$GW_OUT"; GW_BAD=0
  local dir=$1 f arm con spec n startln launchln waitln tagvar sline stopln
  local trap_ok trap_before tln tline h body found=0 count=0

  for spec in $GUARD_ARMS; do
    arm=${spec%%:*}; con=${spec##*:}; f=$dir/$arm
    count=$((count + 1))
    if [ ! -f "$f" ]; then
      sayf FAIL "$arm is in the guard registry but is not on disk -- a chain was renamed or removed and its guard went with it"
      continue
    fi
    # 1. the helper is sourced at all. Without it the two calls below are
    #    `command not found`, which the chain ignores (it is a subshell line that
    #    nobody checks) -- the arm then runs unguarded and its log looks normal.
    if grep -qE '^[[:space:]]*\.[[:space:]]+[^#]*disk_guard\.sh' "$f"; then
      sayf ok "$arm sources disk_guard.sh"
    else
      sayf FAIL "$arm no longer sources disk_guard.sh -- the arm would run with no guard at all"
    fi

    # 2. exactly one start, on its own run tag, naming the container it launched.
    n=$(grep -cE '^[[:space:]]*disk_guard_start[[:space:]]' "$f" || true)
    startln=$(grep -nE '^[[:space:]]*disk_guard_start[[:space:]]' "$f" | head -1 | cut -d: -f1)
    startln=${startln:-0}
    if [ "$n" -eq 1 ]; then
      sayf ok "$arm starts it once"
    else
      sayf FAIL "$arm starts the guard $n time(s), wanted exactly 1"
    fi
    [ "$startln" -gt 0 ] || continue

    sline=$(sed -n "${startln}p" "$f")
    if printf '%s\n' "$sline" | grep -qE "disk_guard_start[[:space:]]+\"?\\\$[A-Za-z_][A-Za-z0-9_]*\"?[[:space:]]+$con([[:space:]]|$)"; then
      sayf ok "$arm starts it on $con"
    else
      sayf FAIL "$arm's start does not name the container it launches ($con): $sline"
    fi
    tagvar=$(printf '%s\n' "$sline" | sed -n 's/.*disk_guard_start[[:space:]]*"\{0,1\}\$\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p')
    if [ -n "$tagvar" ] && grep -qE "^[[:space:]]*$tagvar=" "$f"; then
      sayf ok "$arm uses the run tag it launched ($tagvar)"
    else
      sayf FAIL "$arm's start does not use a tag variable the chain sets (found: ${tagvar:-none})"
    fi

    # 3. the start is after the launch and before the chain blocks on the
    #    container. Started earlier it can see no container and retire itself on the
    #    second poll; started later (after the wait loop) it never runs at all.
    launchln=$(grep -nE "^[[:space:]]*docker run -d --name \"?$con\"?([[:space:]]|$)" "$f" | head -1 | cut -d: -f1)
    launchln=${launchln:-0}
    if [ "$launchln" -gt 0 ] && [ "$startln" -gt "$launchln" ]; then
      sayf ok "$arm starts it after the launch (line $startln > $launchln)"
    else
      sayf FAIL "$arm starts it at line $startln, not after its own launch (line ${launchln:-absent})"
    fi
    waitln=$(grep -nE '^[[:space:]]*while[[:space:]].*(ps_running|running)' "$f" | head -1 | cut -d: -f1)
    waitln=${waitln:-0}
    if [ "$waitln" -gt 0 ]; then
      if [ "$startln" -lt "$waitln" ]; then
        sayf ok "$arm starts it before it blocks on the container (line $startln < $waitln)"
      else
        sayf FAIL "$arm starts it at line $startln, after the wait loop at $waitln -- it never runs"
      fi
    fi

    # 4. every exit path stops it: an EXIT trap installed BEFORE the start whose
    #    handler calls disk_guard_stop (or an inline trap that does). The trap has
    #    to be in place first: a trap installed after a failing start leaves the
    #    guard polling a tag nobody will stop.
    trap_ok=0; trap_before=0
    while IFS=: read -r tln tline; do
      [ -n "$tln" ] || continue
      h=$(printf '%s\n' "$tline" | sed -n 's/.*trap[[:space:]]\+\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]\+EXIT.*/\1/p')
      if [ -n "$h" ]; then
        body=$(fnbody "$h" "$f")
        if printf '%s\n' "$body" | grep -q 'disk_guard_stop'; then
          trap_ok=1; [ "$tln" -lt "$startln" ] && trap_before=1
        fi
      else
        case $tline in
          *disk_guard_stop*) trap_ok=1; [ "$tln" -lt "$startln" ] && trap_before=1 ;;
        esac
      fi
    done < <(grep -nE '^[[:space:]]*trap[[:space:]].*EXIT' "$f")
    if [ "$trap_ok" = 1 ]; then
      sayf ok "$arm has an EXIT trap that stops the guard"
    else
      sayf FAIL "$arm has no EXIT trap calling disk_guard_stop -- an abort leaves the guard polling with the container still up"
    fi
    if [ "$trap_before" = 1 ]; then
      sayf ok "$arm installs that trap before it starts the guard (line $startln)"
    else
      sayf FAIL "$arm starts the guard at line $startln with the stop trap not yet installed"
    fi

    # 5. the stop names the same tag the start did. A stop for a different tag is
    #    a stop that quietly does nothing (helper: "not running"), and the guard
    #    outlives the chain.
    stopln=$(grep -n 'disk_guard_stop' "$f" | head -1 | cut -d: -f1)
    if [ -n "${tagvar:-}" ] && grep -qF "disk_guard_stop \"\$$tagvar\"" "$f"; then
      sayf ok "$arm stops the same tag it started (\$$tagvar, line ${stopln:-?})"
    else
      sayf FAIL "$arm stops a tag other than the one it started (\$${tagvar:-?})"
    fi
  done

  # 6. the tripwire: a chain that starts a flow container and is in neither list.
  for f in "$dir"/*_chain.sh; do
    [ -e "$f" ] || continue
    arm=$(basename "$f")
    case " $GUARD_ARMS " in *" $arm:"*) continue ;; esac
    case " $GUARD_EXEMPT " in *" $arm "*) continue ;; esac
    if grep -q 'docker run -d' "$f" && grep -qE 'ws/(ws|die_predrt|die_drt)_exec\.sh' "$f"; then
      sayf FAIL "$arm starts a flow container and is neither wired to the guard (GUARD_ARMS) nor exempted (GUARD_EXEMPT with a reason)"
      found=1
    fi
  done
  [ "$found" = 1 ] || sayf ok "no unclassified flow arm: $count arm(s) wired, $(printf '%s\n' $GUARD_EXEMPT | wc -l) chain(s) exempt by name"

  [ "$GW_BAD" -eq 0 ]
}

replay() {  # replay <log> -- the findings, counted as this suite's own assertions
  local l
  while IFS= read -r l; do
    case $l in
      'ok   '*) ok "${l#'ok   '}" ;;
      'FAIL '*) bad "${l#'FAIL '}" ;;
    esac
  done < "$1"
}

echo "  -- the delivered chains --"
if guard_wiring_check "$HERE" "$T/wire.live.log"; then live=0; else live=1; fi
replay "$T/wire.live.log"

# The check has to be able to fail, or it is a comment with a pass line. Three
# trees are built that are wrong in the three ways this wiring actually goes
# wrong, and each must be refused for its own stated reason.
NEG=$T/wire
rm -rf "$NEG"; mkdir -p "$NEG"
neg_case() {  # neg_case <label> <dir> <phrase the log must name>
  if guard_wiring_check "$2" "$T/wire.neg.log"; then
    bad "$1 -- the check passed a tree it should have failed"
  elif grep -qF -- "$3" "$T/wire.neg.log"; then
    ok "$1 -- caught, and named: $3"
  else
    bad "$1 -- refused for some other reason (no '$3' in the log: $(grep -a '^FAIL' "$T/wire.neg.log" | head -1))"
  fi
}

# a) the source line gone, everything else intact
mkdir -p "$NEG/a"; cp "$HERE/ws_chain.sh" "$NEG/a/"
grep -v '^\.[[:space:]]*"\$B/disk_guard\.sh"' "$HERE/die_drt_chain.sh" > "$NEG/a/die_drt_chain.sh"
neg_case "19a: a chain that dropped its source line" "$NEG/a" "no longer sources disk_guard.sh"

# b) the start gone: the chain still sources and still stops, so only a call count
#    can tell it apart from a wired chain
mkdir -p "$NEG/b"; cp "$HERE/die_drt_chain.sh" "$NEG/b/"
grep -v '^disk_guard_start[[:space:]]' "$HERE/ws_chain.sh" > "$NEG/b/ws_chain.sh"
neg_case "19b: a chain that dropped its start" "$NEG/b" "starts the guard 0 time(s)"

# c) a new arm, copied from an old chain, that nobody wired
mkdir -p "$NEG/c"; cp "$HERE/die_drt_chain.sh" "$HERE/ws_chain.sh" "$NEG/c/"
cat > "$NEG/c/new_flow_chain.sh" <<'SH'
#!/bin/bash
set -u
ROOT=/home/ubuntu/grx930_ol2
TAG=${NEW_TAG:-new01}
say() { echo "$*"; }
docker run -d --name new_flow --user 0:0 -v "$ROOT:/work" img /work/ws/ws_exec.sh >/dev/null
SH
neg_case "19c: a new flow arm that was never wired" "$NEG/c" "neither wired to the guard"

echo
if [ "$FAIL" = 0 ]; then echo "SELFTEST_PASS"; else echo "SELFTEST_FAIL"; fi
# The counted line is what build/chain_selftests.sh reads. `SELFTEST_PASS` alone is
# not enough evidence for CI: a harness that dies on the way in exits non-zero, but
# the count is the difference between "checked fifty things" and "checked nothing
# and said so" -- the rule chain_selftests.sh states for every row it carries.
echo "DISK_GUARD_SELFTEST pass=$PASS fail=$FAIL"
exit "$FAIL"
