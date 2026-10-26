#!/bin/bash
# die_launch_selftest.sh -- the die arm's launch handshake: does the parent wait
# for the arm's own decision, and can it start a second arm over a live one?
#
#   bash build/die_launch_selftest.sh      # 0 = the handshake holds, 1 = it drifted
#
# WHY THIS EXISTS
#
#   die_diode_flow_chain.sh starts die_drt_chain.sh detached and then has to answer
#   one question: did it start, or did it refuse? The first version answered it with
#   `sleep 45` and a grep of the chain log, which cannot tell a slow gate from a
#   refusal -- and its retry runs `docker rm -f die_predrt`, i.e. it kills an arm
#   that is already routing. The answer is now the arm's own: `arm_state` writes
#   `LAUNCHED tag=...` into DIE_ARM_STATE the moment the container is up. This test
#   pins that handshake from BOTH ends -- the producer (the real die_drt_chain.sh)
#   and the consumer (the parent's wait) -- because they have to agree on the line
#   and a mismatch there is silent: the parent waits out its whole budget and then
#   reports "never launched" for an arm that did. That exact mismatch was written
#   here once (`grep -x` against a line carrying `container=...`) and the 50 s arm
#   below is what caught it.
#
# WHAT IT COVERS
#
#   1  an arm that decides at 50 s -- longer than the old 45 s check: the parent
#      waits for the decision, launches once, and never retries;
#   2  an arm that exits without deciding: retried, and the run stops after its
#      attempts instead of looping;
#   3  an arm that is alive and undecided: exactly one launch, no retry, a named
#      abort -- the case the 45 s rule got wrong, and the one that costs hours;
#   4  the real die_drt_chain.sh writes the marker in the form the parent reads,
#      and records its exit, with its phase A run against a stub docker;
#   5  the two together: the parent reads that marker and does not retry;
#   6  the staged copies differ from the delivered chains only in the destination
#      lines this test rewrites.
#
# WHAT IT DOES NOT DO
#
#   It never launches a container (docker is a stub first on PATH and every call is
#   recorded), never runs the real memwatch, and writes nothing outside its own
#   temp tree. The chains are staged the way gate_selftest.sh stages them: the
#   destination lines are rewritten into $TMP and a diff at the end proves nothing
#   else changed. Safe to run on the box while an arm is in flight.
#
# WHAT IT CANNOT SEE
#
#   Whether a *real* gate is slow enough to matter -- that is why the wait exists,
#   not something a fixture can prove. And the arm's own phases after the launch:
#   those are die_drt_chain.sh's business and its logs'.
set -u
BUILD=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/die_launch_selftest.XXXXXX") || exit 1
R=$TMP/root
STUB_CALLS=$TMP/docker.calls
export STUB_CALLS
cleanup() {
    # Case 3 leaves an undecided arm behind on purpose (that is the point); it must
    # not outlive the test. Only this test's own fake arms match this pattern.
    local p
    for p in $(pgrep -f "^bash $R/children/" 2>/dev/null); do kill "$p" 2>/dev/null; done
    # KEEP=1 leaves the tree behind and says where: the staged logs are the point
    # of half of this, and reading one is how a failing case is diagnosed.
    if [ "${DIE_LAUNCH_SELFTEST_KEEP:-0}" = 1 ]; then
        echo
        echo "kept: $TMP"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1: expected [$2] got [$3]"; fi; }

mkdir -p "$R"/build "$R"/ws/logs "$R"/drt_fast/verdict "$R"/bin "$R"/children
# Both sourced helpers the chains use, so `.` succeeds and the wiring under test is
# the delivered one. Both guards are disabled in every case here (DISK_GUARD=0 /
# CURVE_GUARD=0): this test is about the launch handshake, and a poller left behind
# by a fixture would outlive it.
cp -f "$BUILD/gate.sh" "$R/build/"
cp -f "$BUILD/disk_guard.sh" "$R/build/"
cp -f "$BUILD/curve_guard.sh" "$R/build/"

# ---- the stubs -------------------------------------------------------------
# docker: never a real container. `inspect` answers what the chains read -- not
# running, exit 0 -- and `ps` is empty, so the busy check passes. Every call is
# recorded, which is how the "launched nothing" checks below are made.
cat > "$R/bin/docker" <<'SH'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$STUB_CALLS"
case "$1" in
  inspect)
    case "$*" in
      *State.Running*)  echo false ;;
      *State.ExitCode*) echo 0 ;;
      *)                echo gone ;;
    esac ;;
esac
exit 0
SH
chmod +x "$R/bin/docker"

# memwatch: gate.sh honours $MEMWATCH, so the real one is never reached and this
# box's memory is not what phase 4 is testing.
cat > "$TMP/memwatch-stub.sh" <<'SH'
#!/bin/bash
case "${1:-}" in
  --headroom)  printf 'memavail_mb=9000 swapfree_mb=9000 headroom_mb=18000 psi_some=0.00 live_alert=none\n' ;;
  --preflight) printf 'MEM_PREFLIGHT OK -- starting\n' ;;
esac
exit 0
SH
chmod +x "$TMP/memwatch-stub.sh"
export MEMWATCH=$TMP/memwatch-stub.sh

# ---- the chains under test, staged ----------------------------------------
# One sed line, not a rewrite: both chains derive B/WS/D/LOG/OUT from ROOT, so the
# delivered text differs from the copy in `ROOT=` and nothing else.
stage() { # stage <src> <dst>
    sed -e "s|^ROOT=/home/ubuntu/grx930_ol2|ROOT=$R|" "$1" > "$2"
    chmod +x "$2"
}
stage "$BUILD/die_diode_flow_chain.sh" "$R/build/die_diode_flow_chain.sh"
stage "$BUILD/die_drt_chain.sh"        "$R/build/die_drt_chain.sh"
odd=$(diff "$BUILD/die_diode_flow_chain.sh" "$R/build/die_diode_flow_chain.sh" | grep -E '^[<>]' \
      | grep -vE '^[<>] ROOT=' | wc -l | tr -d ' ')
chk "parent staged by destination line only" 0 "$odd"
odd=$(diff "$BUILD/die_drt_chain.sh" "$R/build/die_drt_chain.sh" | grep -E '^[<>]' \
      | grep -vE '^[<>] ROOT=' | wc -l | tr -d ' ')
chk "arm chain staged by destination line only" 0 "$odd"

# ---- the fake arms ---------------------------------------------------------
# 50 s: longer than the old 45 s check, shorter than any real gate. Writes the
# line the real arm writes, from the marker path the parent hands it.
cat > "$R/children/slow.sh" <<'SH'
#!/bin/bash
sleep 50
printf 'LAUNCHED tag=%s container=die_predrt\n' "$DIE_TAG" >> "$DIE_ARM_STATE.tmp"
mv -f "$DIE_ARM_STATE.tmp" "$DIE_ARM_STATE"
exit 0
SH
# Exits without deciding: the one case a retry is right for.
cat > "$R/children/refuse.sh" <<'SH'
#!/bin/bash
sleep 2
exit 1
SH
# Alive, undecided, never will be.
cat > "$R/children/hang.sh" <<'SH'
#!/bin/bash
sleep 3600
SH
chmod +x "$R/children/"*.sh

clog() { cat "$R/ws/logs/die_diode_flow_chain.log" 2>/dev/null; }
run_chain() { # run_chain <tag> [ENV=V ...]; TMO bounds a run that must be stopped
    local tag=$1; shift
    : > "$R/ws/logs/die_diode_flow_chain.log"
    : > "$STUB_CALLS"
    timeout "${TMO:-180}" env "$@" PATH="$R/bin:$PATH" DIE_DIO_TAG="$tag" \
        DIE_DIO_WATCH_EXTEND=0 bash "$R/build/die_diode_flow_chain.sh" \
        > "$TMP/$tag.out" 2>&1
}

# ---- 1. a slow decision is waited for, not guessed -------------------------
# Stopped after the decision: the watch loop afterwards is entitled to follow a
# real `build/die_drt_chain.sh` on this box, which a stub run has no business in.
t0=$(date +%s)
TMO=80 run_chain dtestA DIE_DIO_CHILD="$R/children/slow.sh" DIE_DIO_LAUNCH_WAIT=120 \
    DIE_DIO_RETRY_WAIT=2 DIE_DIO_ATTEMPTS=2
rcA=$?
tA=$(( $(date +%s) - t0 ))
chk "1: launches / retries for a 50 s arm" "1 0" \
    "$(clog | grep -c ARM_LAUNCHED) $(clog | grep -c 'ARM_RETRY attempt=')"
chk "1: the marker carried the decision" 1 \
    "$(grep -cE '^LAUNCHED tag=dtestA ' "$R/ws/logs/die_drt_chain.dtestA.launch" 2>/dev/null)"
chk "1: went on to the container" 1 "$(clog | grep -c ARM_CONTAINER_UP)"
case "$rcA" in 0|124) ok "1: waited ${tA}s for the arm's own answer" ;;
    *) bad "1: unexpected exit $rcA after ${tA}s" ;; esac
chk "1: it launched no container itself" 0 "$(grep -cE '^docker (run|rm|stop|create)' "$STUB_CALLS")"

# ---- 2. an arm that refused is the one thing worth retrying ---------------
TMO=120 run_chain dtestB DIE_DIO_CHILD="$R/children/refuse.sh" DIE_DIO_LAUNCH_WAIT=60 \
    DIE_DIO_RETRY_WAIT=2 DIE_DIO_ATTEMPTS=2
rcB=$?
chk "2: stops with rc=1" 1 "$rcB"
chk "2: launches / retries" "2 2" \
    "$(clog | grep -c ARM_LAUNCHED) $(clog | grep -c 'ARM_RETRY attempt=')"
chk "2: and says why" 1 "$(clog | grep -c 'ARM_ABORT not_launched')"
grep -q 'marker: none' "$R/ws/logs/die_diode_flow_chain.log" \
    && ok "2: the refusal quotes the empty marker" \
    || bad "2: the retry line does not say what the marker held"

# ---- 3. a live, undecided arm is never raced ------------------------------
TMO=90 run_chain dtestC DIE_DIO_CHILD="$R/children/hang.sh" DIE_DIO_LAUNCH_WAIT=15 \
    DIE_DIO_RETRY_WAIT=2 DIE_DIO_ATTEMPTS=3
rcC=$?
chk "3: stops with rc=1" 1 "$rcC"
chk "3: exactly one launch" 1 "$(clog | grep -c ARM_LAUNCHED)"
chk "3: no retry" 0 "$(clog | grep -c 'ARM_RETRY attempt=')"
chk "3: aborts instead" 1 "$(clog | grep -c 'launch_wait_timeout_15s')"
chk "3: and launched no container" 0 "$(grep -cE '^docker (run|rm|stop|create)' "$STUB_CALLS")"

# ---- 4. the producer: the real arm chain writes the line the parent reads --
# A run tree just complete enough for phase A: the GRT gate wants a step log with
# the expected adjustment and resolved.json, the pre-DRT lookup wants an STA step
# and the database it names, and then DIE_PHASE_A_ONLY stops it before DRT.
TAGD=dtestD
RUN=$R/ws/template/librelane/runs/$TAGD
mkdir -p "$RUN/37-openroad-globalrouting" "$RUN/40-openroad-stamidpnr-2" \
         "$RUN/41-openroad-stamidpnr-3"
printf '\nGlobal adjustment: 10%%\n' > "$RUN/37-openroad-globalrouting/openroad-globalrouting.log"
printf '{"RUN_ANTENNA_REPAIR": false}\n' > "$RUN/resolved.json"
: > "$RUN/40-openroad-stamidpnr-2/chip_top.odb"
printf '{"odb": "/work/ws/template/librelane/runs/%s/40-openroad-stamidpnr-2/chip_top.odb"}\n' \
    "$TAGD" > "$RUN/41-openroad-stamidpnr-3/state_out.json"
MARK=$R/ws/logs/die_drt_chain.$TAGD.launch
: > "$MARK"
: > "$STUB_CALLS"
DIE_TAG=$TAGD DIE_PHASE_A_ONLY=1 DIE_ARM_STATE="$MARK" PREDRT_MIN_GB=0 \
    DISK_GUARD=0 CURVE_GUARD=0 PREDRT_STOP=OpenROAD.DetailedRouting PATH="$R/bin:$PATH" \
    bash "$R/build/die_drt_chain.sh" > "$TMP/dtestD.arm.out" 2>&1
rcD=$?
chk "4: the real arm chain completes its phase A" 0 "$rcD"
chk "4: marker says LAUNCHED in the form the parent matches" 1 \
    "$(grep -cE '^LAUNCHED tag=dtestD container=die_predrt$' "$MARK")"
chk "4: and records its own exit" 1 "$(grep -cE '^EXIT rc=0$' "$MARK")"
chk "4: the chain log agrees" 1 "$(grep -c "PREDRT_LAUNCHED tag=$TAGD" "$R/ws/logs/die_drt_chain.log")"
# The disk guard is wired in, and wired in at the right moment: after the arm's
# container is up (that is when the step tree can start growing), and before the
# chain settles into waiting on it. DISK_GUARD=0 makes the proof cheap -- the call
# site still runs and says so -- without leaving a poller behind.
chk "4: the guard is started from the arm chain" 1 \
    "$(grep -c "DISK_GUARD_DISABLED tag=$TAGD" "$R/ws/logs/die_drt_chain.log")"
chk "4: and after the container is up, not before" 1 \
    "$(awk '/PREDRT_LAUNCHED tag='"$TAGD"'/ {l=NR} /DISK_GUARD_DISABLED tag='"$TAGD"'/ {d=NR} END {print (d>l && l>0) ? 1 : 0}' "$R/ws/logs/die_drt_chain.log")"
# The curve guard is held to the same contract: started at the arm's container,
# after it is up, and disabled by its own switch for this fixture.
chk "4: the curve guard is started from the arm chain" 1 \
    "$(grep -c "CURVE_GUARD_DISABLED tag=$TAGD" "$R/ws/logs/die_drt_chain.log")"
chk "4: and after the container is up, not before" 1 \
    "$(awk '/PREDRT_LAUNCHED tag='"$TAGD"'/ {l=NR} /CURVE_GUARD_DISABLED tag='"$TAGD"'/ {d=NR} END {print (d>l && l>0) ? 1 : 0}' "$R/ws/logs/die_drt_chain.log")"

# ---- 5. the consumer reads that marker, end to end ------------------------
# PREDRT_MIN_GB=0 in the parent's environment, inherited by the arm: the real 12 GB
# disk floor is the arm's business and this box is 94 % full, so with the default
# the arm would refuse at the gate before it ever writes a marker -- which is the
# gate working, and not what this case is asking.
t0=$(date +%s)
TMO=40 run_chain "$TAGD" DIE_DIO_CHILD="$R/build/die_drt_chain.sh" PREDRT_MIN_GB=0 \
    DISK_GUARD=0 CURVE_GUARD=0 DIE_DIO_LAUNCH_WAIT=120 DIE_DIO_RETRY_WAIT=2 DIE_DIO_ATTEMPTS=2
tE=$(( $(date +%s) - t0 ))
chk "5: real arm launches / retries" "1 0" \
    "$(clog | grep -c ARM_LAUNCHED) $(clog | grep -c 'ARM_RETRY attempt=')"
chk "5: and the parent went on" 1 "$(clog | grep -c ARM_CONTAINER_UP)"
ok "5: parent and arm agreed in ${tE}s"

# ---- 6. nothing reached the box ------------------------------------------
chk "6: no stub container was ever left behind" 0 \
    "$(grep -cE '^docker (start|stop|kill|exec)' "$STUB_CALLS")"

echo
if [ "$fail" = 0 ]; then
    echo "DIE_LAUNCH_SELFTEST pass=$pass fail=0"
else
    printf 'DIE_LAUNCH_SELFTEST FAIL pass=%s fail=%s\n' "$pass" "$fail"
fi
[ "$fail" = 0 ]
