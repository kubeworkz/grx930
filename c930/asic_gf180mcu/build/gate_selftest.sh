#!/bin/bash
# gate_selftest.sh -- the shared gate's own test: does it still behave, and are
# the chains still calling it instead of growing their own copy?
#
#   bash build/gate_selftest.sh      # 0 = the gate holds, 1 = it drifted
#
# WHY THIS EXISTS
#
#   gate.sh is the one place the disk floor and the memory gate are defined, and
#   the point of it is that six chains no longer carry their own copy of either.
#   That property is invisible and easy to lose: nothing complains if a chain
#   grows a `df -BG` line again, calls memwatch directly, or asks its gate and
#   then ignores the answer. A gate that cannot notice a full disk is worse than
#   no gate, because its log still says it checked. Each of those is a check here,
#   and every one that fails is a FAIL line and a non-zero exit -- this is meant to
#   be run after any edit to gate.sh, memwatch.sh or a *_chain.sh.
#
# WHAT IT COVERS
#
#   0  the wiring gate.sh ships: where MEMWATCH resolves, that GATE_MIN_GB is a
#      number, and the real `df` path -- including a mount `df` cannot read, which
#      must refuse rather than pass.
#   1  every branch: disk below/at the floor, MIN_GB 0 as print-only, a memory
#      refusal, MEMWATCH_FORCE, GATE_REASON being cleared, the logged line shape,
#      the mount a call site actually asks about.
#   2  every gate call site in every *_chain.sh, executed AS DELIVERED: the chain
#      must source gate.sh, must not read the disk itself or call memwatch
#      directly, must check the answer, and must refuse and name a reason when the
#      box cannot carry the job.
#   3  six whole chains, run end to end with the box stubbed to refuse and a stub
#      docker first on PATH: each chain must stop where its design says, leave the
#      gate's state lines and a named refusal in its own log, and launch NOTHING.
#
# WHAT IT DOES NOT DO
#
#   It never runs the real memwatch and never runs a real container. Both are
#   stubs, MEMWATCH_ROOT points at this test's own temp dir, and every path a chain
#   writes to -- its own D/B/ROOT/WS/LOG/OUT and the volume it hands docker -- is
#   redirected into that temp dir. That matters more in phase 3 than anywhere else:
#   one of the failures this test hunts is a chain that ignores its gate, and the
#   failing run must not be able to reach the campaign tree. The `diff` check after
#   each run proves the copy differs from the delivered chain in those destination
#   lines and nowhere else. Safe to run on the box while chains are running; needs
#   only `df`, `diff` and `mktemp`.
#
# WHAT IT CANNOT SEE
#
#   The refusal verdict itself is memwatch's, so a stub stands in for it: what is
#   under test here is the wiring around the decision. memwatch's own floors are
#   exercised live -- see its header, and `bash build/memwatch.sh --status`.
set -u
BUILD=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/gate_selftest.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

BOX=/home/ubuntu/grx930_ol2
STUB_CALLS=$TMP/preflight-calls.log
STUB_MOUNTS=$TMP/df-mounts.log
export STUB_CALLS STUB_MOUNTS
export MEMWATCH_ROOT=$TMP/audit      # never the box's mem_audit/, whatever happens

# The two real ledgers, captured before anything runs so the closing checks are
# comparisons rather than assertions of good intentions.
REAL_PREFLIGHT=$BOX/mem_audit/preflight.log
REAL_PREFLIGHT_LINES=0
[ -f "$REAL_PREFLIGHT" ] && REAL_PREFLIGHT_LINES=$(wc -l < "$REAL_PREFLIGHT")
CAMPAIGN="$BOX/drt_fast/core_chain.log $BOX/drt_fast/both_chain.log
$BOX/drt_fast/grt03c_chain.log $BOX/drt_fast/grt_sweep_chain.log
$BOX/drt_fast/verdict/grt_sweep.md $BOX/ws/ws_chain.log $BOX/ws/ws_synth_chain.log"
digest() { local f; for f in $1; do [ -f "$f" ] && md5sum "$f"; done; }
CAMPAIGN_BEFORE=$(digest "$CAMPAIGN")

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
na()   { skip=$((skip+1)); printf '  --   %s\n' "$1"; }
chk()  { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1: expected [$2] got [$3]"; fi
}

# ---- the stub: it answers like memwatch, logs the same shape, records the call --
cat > "$TMP/memwatch-stub.sh" <<'SH'
#!/bin/bash
set -u
case "${1:-}" in
  --headroom)
    printf 'memavail_mb=1000 swapfree_mb=2000 headroom_mb=3000 psi_some=0.00 live_alert=none\n' ;;
  --preflight)
    need=0; tag=none; log=""
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --need) need=${2:-0}; shift 2 ;;
        --tag)  tag=${2:-};   shift 2 ;;
        --log)  log=${2:-};   shift 2 ;;
        *)      shift ;;
      esac
    done
    printf 'need_mb=%s tag=%s log=%s\n' "$need" "$tag" "$log" >> "${STUB_CALLS:-/dev/null}"
    verdict=OK; why=""
    [ "${STUB_MODE:-go}" = refuse ] && { verdict=REFUSE; why="headroom 3000 MB < need ${need} MB"; }
    printf 'MEM_PREFLIGHT headroom_mb=3000 (memavail_mb=1000 + swapfree_mb=2000) psi_some_avg10=0.00 need_mb=%s\n' "$need"
    # The one line memwatch appends to the CALLER's log, in the caller's format:
    # that line is the whole reason a chain log can be read afterwards.
    printf '%s MEM_PREFLIGHT tag=%s headroom_mb=3000 need_mb=%s verdict=%s %s\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$tag" "$need" "$verdict" "$why" >> "${log:-/dev/null}" 2>/dev/null
    if [ "$verdict" = REFUSE ]; then
      if [ "${MEMWATCH_FORCE:-0}" = 1 ]; then
        printf 'MEM_PREFLIGHT FORCED past the refusal because MEMWATCH_FORCE=1\n'
        exit 0
      fi
      printf 'MEM_PREFLIGHT REFUSE: %s\n' "$why"
      exit 1
    fi
    printf 'MEM_PREFLIGHT OK -- starting\n' ;;
esac
exit 0
SH

# The same logging shape as a chain's own `say`, so what the gate writes here is
# what it would write on the box.
say() { echo "[selftest] $*" | tee -a "$LOG"; }
LOG=$TMP/chain.log; : > "$LOG"

STUB_FREE_GB=34
export STUB_MODE=go

echo "GATE_SELFTEST start (build=$BUILD)"

# ======================= 0. the wiring, as gate.sh ships it ==================
. "$BUILD/gate.sh"

# ${VAR:-} throughout, not $VAR: under `set -u` a renamed or deleted helper
# variable would kill this script with a bash error instead of a FAIL line, and a
# FAIL line is what says which part of the contract moved.
chk "MEMWATCH resolves beside gate.sh" "$BUILD/memwatch.sh" "${MEMWATCH:-unset}"
[ -f "${MEMWATCH:-}" ] && ok "and that file exists" || bad "MEMWATCH points at no file: ${MEMWATCH:-unset}"
case "${GATE_MIN_GB:-}" in
  ''|*[!0-9]*) bad "GATE_MIN_GB is not a positive integer: ${GATE_MIN_GB:-unset}" ;;
  *) [ "$GATE_MIN_GB" -gt 0 ] && ok "GATE_MIN_GB = $GATE_MIN_GB" || bad "GATE_MIN_GB = 0" ;;
esac

# The real df, before free_gb is stubbed: the gate's one host dependency, and a
# mount it cannot read must refuse rather than pass.
gb=$(free_gb /)
case "$gb" in ''|*[!0-9]*) bad "free_gb / is not an integer: [$gb]" ;; *) ok "free_gb / = $gb (real df)" ;; esac
if [ -d /home ]; then
  gbh=$(free_gb /home)
  case "$gbh" in ''|*[!0-9]*) bad "free_gb /home is not an integer: [$gbh]" ;;
                *) ok "free_gb /home = $gbh (real df)" ;; esac
else
  na "no /home here: free_gb's default mount would refuse on this host, as documented"
fi
: > "$LOG"
disk_gate 6 "$TMP/not-a-mount"; rc=$?
chk "a mount df cannot read refuses" 1 "$rc"
grep -q "GATE_DISK_UNREADABLE" "$LOG" && ok "and says GATE_DISK_UNREADABLE" || bad "no GATE_DISK_UNREADABLE line"

# ================== 1. the branches, with free_gb and memwatch stubbed =======
# free_gb is redefined the way the box's df answers, and the mount it was asked
# for is recorded too, because "which filesystem" is as much a part of the gate as
# the number is.
MEMWATCH=$TMP/memwatch-stub.sh
free_gb() { printf '%s\n' "${1:-/home}" >> "$STUB_MOUNTS"; printf '%s' "${STUB_FREE_GB}"; }

STUB_FREE_GB=3
: > "$STUB_CALLS"; : > "$LOG"
gate 8000 core_chain; rc=$?
chk "disk below the floor refuses" 1 "$rc"
chk "  and names DISK_LOW" DISK_LOW "${GATE_REASON:-}"
chk "  and never asks memwatch" 0 "$(wc -l < "$STUB_CALLS" | tr -d ' ')"
grep -q "DISK_GB_FREE 3" "$LOG" && ok "  and logs DISK_GB_FREE 3" || bad "  DISK_GB_FREE missing from the log"

STUB_FREE_GB=6
: > "$STUB_CALLS"; : > "$LOG"
gate 8000 core_chain; rc=$?
chk "disk exactly at the floor goes" 0 "$rc"
chk "  with no stale GATE_REASON" "" "${GATE_REASON:-}"
chk "  and asks memwatch exactly once" 1 "$(wc -l < "$STUB_CALLS" | tr -d ' ')"
grep -q "DISK_GB_FREE 6" "$LOG" && ok "  and logs the figure it decided on" || bad "  DISK_GB_FREE missing"
grep -q "MEM_PREFLIGHT tag=core_chain" "$LOG" && ok "  and the verdict is in the log" || bad "  no MEM_PREFLIGHT line"

STUB_FREE_GB=0
: > "$LOG"
gate 8000 both_chain 0; rc=$?
chk "MIN_GB 0 is print-only, even at 0 GB free" 0 "$rc"
grep -q "DISK_GB_FREE 0" "$LOG" && ok "  and still logs the figure" || bad "  the print-only site logged nothing"

STUB_FREE_GB=34
export STUB_MODE=refuse
: > "$STUB_CALLS"; : > "$LOG"
gate 8000 grt_sweep_0.1; rc=$?
chk "a memory refusal refuses" 1 "$rc"
chk "  and names MEM_LOW" MEM_LOW "${GATE_REASON:-}"
chk "  need/tag/log reach memwatch verbatim" "need_mb=8000 tag=grt_sweep_0.1 log=$LOG" "$(tail -1 "$STUB_CALLS")"

: > "$LOG"
export MEMWATCH_FORCE=1
gate 8000 ws_synth; rc=$?
unset MEMWATCH_FORCE
chk "MEMWATCH_FORCE=1 goes anyway" 0 "$rc"
# The force is memwatch's decision to record, in its own ledger; what matters
# here is that the gate obeyed it and went ahead on a REFUSE verdict.
grep -q "verdict=REFUSE" "$LOG" && ok "  and went ahead on a verdict=REFUSE" \
  || bad "  the refusal it was forced past is not in the log"

: > "$LOG"
export STUB_MODE=go
gate 8000 core_chain; rc=$?
chk "a later go clears GATE_REASON" "" "${GATE_REASON:-}"

: > "$LOG"
mem_gate 8000 grt_sweep_0.1 "adj=0.1" >/dev/null
chk "mem_gate LABEL lands in the headroom line" \
  "MEM_HEADROOM adj=0.1 memavail_mb=1000 swapfree_mb=2000 headroom_mb=3000 psi_some=0.00 live_alert=none" \
  "$(grep 'MEM_HEADROOM adj=0.1' "$LOG" | tail -1 | sed 's/^\[selftest\] //')"
: > "$LOG"
mem_gate 8000 grt_sweep_0.1 >/dev/null
chk "mem_gate with no label adds no stray space" \
  "MEM_HEADROOM memavail_mb=1000 swapfree_mb=2000 headroom_mb=3000 psi_some=0.00 live_alert=none" \
  "$(grep 'MEM_HEADROOM' "$LOG" | tail -1 | sed 's/^\[selftest\] //')"

: > "$STUB_MOUNTS"; : > "$LOG"
STUB_FREE_GB=11
gate 9000 ws_chain 10 /; rc=$?
chk "ws_chain's own floor and mount: 11 GB vs 10 goes" 0 "$rc"
chk "  and df was asked about /" "/" "$(cat "$STUB_MOUNTS")"
STUB_FREE_GB=9
gate 9000 ws_chain 10 /; rc=$?
chk "  9 GB against that 10 GB floor refuses" 1 "$rc"
: > "$STUB_MOUNTS"
STUB_FREE_GB=34
gate 8000 core_chain; rc=$?
chk "  while a site that names none uses /home" "/home" "$(cat "$STUB_MOUNTS")"

# ============ 2. the chains still use it, and still obey the answer ==========
# The drift this file exists to catch: a chain that grows its own gate back, or
# asks the shared one and then ignores what it was told. The box is stubbed to
# refuse, so a site that reaches its arm here is a site that ignores a refusal.
export STUB_MODE=refuse
run_site() { eval "$1"; }
sites=0
for f in "$BUILD"/*_chain.sh; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  grep -q 'gate\.sh' "$f" && ok "$name sources gate.sh" || bad "$name does not source gate.sh"
  n=$(grep -cE '^[[:space:]]*gate[[:space:]]' "$f")
  [ "$n" -ge 1 ] && ok "$name has $n gate site(s)" || bad "$name has no gate call"
  if grep -qE 'df +-BG' "$f"; then bad "$name reads the disk itself (df -BG) instead of free_gb"
  else ok "$name leaves df to the shared gate"; fi
  if grep -q 'memwatch\.sh --' "$f"; then bad "$name calls memwatch directly"
  else ok "$name reaches memwatch only through the gate"; fi

  while IFS=: read -r ln line; do
    sites=$((sites+1))
    # The variables a site names are the ones its chain has already set by that
    # line -- the site is run as delivered, not as a copy with its arguments
    # flattened. ADJ/CAP/CAP_MB are grt_sweep's, TAG and PREDRT_MIN_GB are
    # die_drt_chain.sh's, ANT_MIN_GB is antenna_probe_chain.sh's, and
    # NEED_MB/MIN_GB/A are drt_db_compare_chain.sh's (`A` is its arm, bound by the
    # loop the site sits in). Without them a site whose argument is a variable dies
    # of `set -u` here and reads as a chain that ignores its gate -- which is how
    # the die_predrt sites read when this test was first wired into CI.
    ADJ=0.1; CAP=8g; CAP_MB=8192; STUB_FREE_GB=99
    TAG=die01; PREDRT_MIN_GB=12; ANT_MIN_GB=6; NEED_MB=10000; MIN_GB=12; A=arm1
    case "$line" in
      *'||'*) ok "$name:$ln checks the answer" ;;
      *)      bad "$name:$ln calls gate and ignores the answer" ;;
    esac
    # The site runs inside a one-iteration loop. Some refusals are `continue` (the
    # arm sweeps iterate their arms), and `continue` outside a loop is a bash error
    # that would read as a refusal from a site that is in fact correct. The loop
    # makes the site's own control flow legal.
    #
    # The witness is then the log line rather than the exit status, because a site
    # whose refusal is `continue` exits 0 outside its chain. The question that can
    # be answered from here is the one that matters: when the gate says no, does
    # the chain say so, in its own log, naming the reason? `ABORT_$GATE_REASON`
    # (ws_chain), `ABORT_DRT_$GATE_REASON` (die_drt_chain) and `ARM_ABORT $A
    # $GATE_REASON` (drt_db_compare_chain) all do; a bare `ABORT` does not, and a
    # site that ignores the answer writes nothing at all -- which is the drift this
    # phase is here to catch. GATE_REASON itself is set in the subshell that ran the
    # site, so the reason is looked for in the line, not in this shell's variable.
    LOG=$TMP/$name.$ln.refuse.log; : > "$LOG"
    ( for _ in 1; do run_site "$line"; done ) >/dev/null 2>&1; rc=$?
    refusal=$(grep -aE '(ARM_)?ABORT' "$LOG" | tail -1)
    case "$refusal" in
      *MEM_LOW*|*DISK_LOW*)
        ok "$name:$ln refuses, and names the reason: ${refusal#\[selftest\] }" ;;
      *)
        bad "$name:$ln leaves no refusal naming DISK_LOW or MEM_LOW (rc=$rc, last ABORT line: ${refusal:-none}) -- the chain would go ahead on a refusal, or refuse without saying why" ;;
    esac
    LOG=$TMP/$name.$ln.go.log; : > "$LOG"
    STUB_MODE=go
    ( for _ in 1; do run_site "$line"; done ) >/dev/null 2>&1; rc=$?
    chk "  and goes when it can" 0 "$rc"
    export STUB_MODE=refuse
  done < <(grep -nE '^[[:space:]]*gate[[:space:]]' "$f")
done
echo "  --   $sites gate site(s) across the chains"

# ======== 3. whole chains, refused: they stop, and nothing is launched =======
# The five chains leave through their gate and the sweep leaves through its arms.
# Every destination a chain writes to is redirected into $TMP -- its D/B/ROOT/WS,
# its LOG and OUT, and the volume it hands docker -- because the failing run this
# phase is looking for is a chain that ignores its refusal, and that run must not
# be able to touch the campaign tree. The diff check after each run is what keeps
# this honest: if the copy differs in anything but those destinations, the run
# stopped being a test of the delivered chain and says so.
mkdir -p "$TMP/root/build" "$TMP/root/drt_fast/logs" "$TMP/root/drt_fast/ckpt" \
         "$TMP/root/ws/logs" "$TMP/root/ws/template/asic_core" "$TMP/bin"
cp -f "$BUILD/gate.sh" "$BUILD/memwatch.sh" "$TMP/root/build/"
cat > "$TMP/bin/docker" <<SH
#!/bin/sh
printf 'docker %s\n' "\$*" >> "$TMP/docker.calls"
exit 0
SH
chmod +x "$TMP/bin/docker"
# A healthy disk, so that what refuses here is the MEMORY gate whose refusal path
# a chain actually takes. The real df path is phase 0's business; this keeps phase
# 3 deterministic on every host instead of refusing at the disk on one and at
# memory on another.
cat > "$TMP/bin/df" <<'SH'
#!/bin/sh
printf 'Avail\n34G\n'
SH
chmod +x "$TMP/bin/df"
export MEMWATCH=$TMP/memwatch-stub.sh
unset GATE_MIN_GB    # a stray one in the caller's environment is not what we test

chain_log_sample=$BOX/drt_fast/core_chain.log   # only to say whether this is the box

chain_run() {  # chain_run <chain> <expected rc> <expected refusal lines> <expected reason>
  local name=$1 want=$2 aborts=$3 wantwhy=$4 src="$BUILD/$1" copy="$TMP/root/run.$1" log rc got reason launches odd
  log="$TMP/root/$1.log"
  sed -e "s|^B=/home/ubuntu/grx930_ol2/build|B=$TMP/root/build|" \
      -e "s|^D=/home/ubuntu/grx930_ol2/drt_fast|D=$TMP/root/drt_fast|" \
      -e "s|^ROOT=/home/ubuntu/grx930_ol2|ROOT=$TMP/root|" \
      -e "s|^WS=.*|WS=$TMP/root/ws|" \
      -e "s|^LOG=.*|LOG=$log|" \
      -e "s|^OUT=.*|OUT=$TMP/root/$1.out|" \
      -e "s|-v /home/ubuntu/grx930_ol2:/work|-v $TMP/root:/work|g" \
      "$src" > "$copy"
  : > "$log"; : > "$TMP/docker.calls"
  PATH=$TMP/bin:$PATH bash "$copy" > "$copy.stdout" 2>&1; rc=$?

  chk "$name stops with rc=$want when the box refuses" "$want" "$rc"
  got=$(grep -cE '(ARM_)?ABORT_[A-Z_]*' "$log" | tr -d ' ')
  chk "  refusal lines in its own log" "$aborts" "$got"
  reason=$(grep -oE '(ARM_)?ABORT_[A-Z_]*' "$log" | head -1)
  chk "  and they name" "$wantwhy" "${reason:-none}"
  grep -q 'MEM_HEADROOM' "$log" && grep -q 'DISK_GB_FREE' "$log" \
    && grep -q 'verdict=REFUSE' "$log" \
    && ok "  and the state it decided from is in that log" \
    || bad "  the gate's state lines are missing from the chain log"
  launches=$(grep -cE '^docker (run|rm|stop|start|create|kill|exec)' "$TMP/docker.calls" | tr -d ' ')
  chk "  containers, or containers' state, it touched" 0 "$launches"
  # Both sides of the volume line are allowed: the original mount and the scratch
  # one. Everything else must be identical to the delivered chain.
  odd=$(diff "$src" "$copy" | grep -E '^[<>]' \
        | grep -vE '^[<>] (B|D|ROOT|WS|LOG|OUT)=|^[<>] .*docker .*-v [^ ]*:/work' | wc -l | tr -d ' ')
  chk "  lines that differ from the delivered chain (destinations only)" 0 "$odd"
}

chain_run core_chain.sh 1 1 ABORT_MEM_LOW
chain_run both_chain.sh 1 1 ABORT_MEM_LOW
chain_run grt03c_chain.sh 1 1 ABORT_MEM_LOW
chain_run grt_sweep_chain.sh 0 2 ARM_ABORT_MEM_LOW   # an arm failing never aborts the sweep
chain_run ws_chain.sh 1 1 ABORT_MEM_LOW
chain_run ws_synth_chain.sh 1 1 ABORT_MEM_LOW
echo "  --   6 whole chains run with the box refusing (stub docker, everything written into $TMP)"

# ============ 4. neither real ledger may have moved, in any phase ===========
if [ -f "$REAL_PREFLIGHT" ]; then
  now=$(wc -l < "$REAL_PREFLIGHT")
  [ "$now" = "$REAL_PREFLIGHT_LINES" ] \
    && ok "the real mem_audit/preflight.log is untouched ($now lines)" \
    || bad "the real preflight.log changed: $REAL_PREFLIGHT_LINES -> $now"
else
  na "no $REAL_PREFLIGHT on this host, so that ledger cannot be checked from here"
fi
if [ "$(digest "$CAMPAIGN")" = "$CAMPAIGN_BEFORE" ] && [ -n "$CAMPAIGN_BEFORE" ]; then
  ok "the campaign logs and grt_sweep.md are byte-identical after running the chains"
elif [ -z "$CAMPAIGN_BEFORE" ]; then
  na "no $chain_log_sample here, so the campaign logs cannot be checked from here"
else
  bad "a campaign log changed while the chains were being run"
fi

echo
if [ "$fail" = 0 ]; then
  echo "GATE_SELFTEST pass=$pass fail=0 skipped=$skip"
else
  printf 'GATE_SELFTEST FAIL pass=%s fail=%s skipped=%s\n' "$pass" "$fail" "$skip"
fi
[ "$fail" = 0 ]
