#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# stage_tapeout_watch_selftest.sh -- the watcher's trigger, debounce, refusal and bound
# logic, exercised against a fixture tree with a stubbed staging job.
#
# What it is protecting: the watcher's whole job is to notice that the block has gone stale,
# and its two failure modes are opposite and both silent -- acting when nothing changed
# (churning the config the tapeout reads, and the file's hash with it) and not acting when
# something did (leaving a block that quotes a `not measured` for an arm that has run). So
# the cases below drive real fingerprint changes, a real refusal, a missing block and a
# file that is still being written, and check both the status it reports and whether the job
# was called at all.
#
#   bash build/stage_tapeout_watch_selftest.sh
set -u
S=$(cd "$(dirname "$0")" && pwd)
WATCH=$S/stage_tapeout_watch.sh
T=$(mktemp -d)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { grep -qaF -- "$2" "$1" && ok "$3" || bad "$3 (missing: $2)"; }
hasnt(){ grep -qaF -- "$2" "$1" && bad "$3 (present: $2)" || ok "$3"; }
lastcycle() { grep -a 'WATCH_CYCLE ' "$T/ws/logs/stage_tapeout_watch.log" 2>/dev/null | tail -1; }
lc()   { case "$(lastcycle)" in *"$2"*) ok "$1" ;; *) bad "$1 -- last cycle was: $(lastcycle)" ;; esac; }
calls(){ if [ -f "$T/drt_fast/verdict/stub.calls" ]; then wc -l < "$T/drt_fast/verdict/stub.calls"; else echo 0; fi; }
wlog() { printf '%s\n' "$T/ws/logs/stage_tapeout_watch.log"; }
stlog(){ printf '%s\n' "$T/ws/logs/stage_tapeout_config.log"; }

mk_fixture() {
    rm -rf "$T"
    mkdir -p "$T/build" "$T/ws/logs" "$T/ws/probe/out" "$T/ws/probe/out_pin01" \
             "$T/ws/template/librelane" "$T/drt_fast/verdict"
    cp "$S/stage_evidence.sh" "$T/build/stage_evidence.sh"
    # the evidence, in the shapes the block quotes
    printf 'ANT_PROBE_RESULT variant=base rc=0\n[INFO GRT-0012] Found 114 antenna violations.\n' > "$T/ws/probe/out_pin01/base.log"
    printf 'ANT_PROBE_RESULT variant=diode_only rc=0\n[INFO GRT-0012] Found 522 antenna violations.\n' > "$T/ws/probe/out/diode_only.log"
    printf 'ANT_PROBE_RESULT variant=jumper_only rc=0\n[INFO GRT-0012] Found 1209 antenna violations.\n' > "$T/ws/probe/out/jumper_only.log"
    printf 'arm|database\n' > "$T/drt_fast/verdict/die_drt_db_compare.tsv"
    printf 'tag `diejmp01`\n' > "$T/drt_fast/verdict/die_diode_flow_arm.md"
    printf 'DIE_DIO_FLOW_COMPLETE tag=diejmp01\n' > "$T/ws/logs/die_diode_flow_chain.log"
    printf 'DESIGN_NAME: chip_top\n' > "$T/ws/template/librelane/grx930_overrides.yaml"

    # the stubbed job: same contract as build/stage_tapeout_config.sh, no docker, no arms
    cat > "$T/build/stub_job.sh" <<'STUB'
#!/bin/bash
set -u
ROOT=${STAGE_ROOT:-/home/ubuntu/grx930_ol2}
B=$ROOT/build; WS=$ROOT/ws; D=$ROOT/drt_fast
OVR=$WS/template/librelane/grx930_overrides.yaml
. "$B/stage_evidence.sh"
printf 'called\n' >> "$D/verdict/stub.calls"
case "${STUB_MODE:-staged}" in
    refuse) exit 1 ;;
esac
# The stub finds the fingerprint it rendered already in the file the way the real job
# does: by comparing what it would write against what is there.
fp=$(stage_evidence_fingerprint)
rc=0
if grep -aqF "# stub fingerprint $fp" "$OVR" 2>/dev/null; then rc=1; fi
if [ "${STUB_MODE:-staged}" != noblock ]; then
    sed -i '/BEGIN MEASURED-STAGING/,/END MEASURED-STAGING/d' "$OVR"
    printf '# ==== BEGIN MEASURED-STAGING (generated %s UTC by the stub job) ====\n# stub fingerprint %s\nGRT_ANTENNA_REPAIR_DIODE_ONLY: true\n# ==== END MEASURED-STAGING ====\n' \
        "$(date -u '+%F %T')" "$fp" >> "$OVR"
fi
[ "${STUB_MODE:-staged}" = unchanged ] && rc=1
{
    printf 'STAGE_WRITE overrides rc=%s launcher rc=1 (0 written, 1 unchanged, 2 missing)\n' "$rc"
    printf 'STAGE_DECISION rung=2 diode_only=true jumper_only=false pin_engine=0\n'
    printf 'STAGE_FINGERPRINT %s\n' "$fp"
} >> "$WS/logs/stage_tapeout_config.log"
exit 0
STUB
    chmod +x "$T/build/stub_job.sh"
}

once() {  # $1 = STUB_MODE (optional)
    STAGE_ROOT=$T STAGE_WATCH_JOB=$T/build/stub_job.sh STAGE_WATCH_EVERY=1 \
        STUB_MODE=${1:-staged} bash "$WATCH" --once 2>&1
}
cycle_rc() { STAGE_ROOT=$T STAGE_WATCH_JOB=$T/build/stub_job.sh STAGE_WATCH_EVERY=1 STUB_MODE=${1:-staged} bash "$WATCH" --once >/dev/null 2>&1; echo $?; }

echo "== no block at all: act at once, and record what it acted on =="
mk_fixture
once > /dev/null
lc 'reports the job ran' 'status=staged'
[ "$(calls)" = 1 ] && ok 'called the job once' || bad "called the job once (got $(calls))"
has "$T/drt_fast/verdict/tapeout_config_stage.state" 'last_fingerprint ' 'records the fingerprint it handled'
has $(wlog) 'no MEASURED-STAGING block' 'says the block was missing, not that evidence changed'
[ -f "$T/drt_fast/verdict/tapeout_config_stage_history.md" ] && ok 'writes the history table' || bad 'writes the history table'
has "$T/drt_fast/verdict/tapeout_config_stage_history.md" '| staged | no MEASURED-STAGING block' 'with a row naming the trigger'
has "$T/drt_fast/verdict/tapeout_config_stage_history.md" '| 2 |' 'and the rung the job reported'
FP1=$(grep -a '^last_fingerprint ' "$T/drt_fast/verdict/tapeout_config_stage.state" | cut -d' ' -f2)

echo "== nothing changed: stay quiet, and do not touch the config =="
BEFORE=$(md5sum < "$T/ws/template/librelane/grx930_overrides.yaml")
once > /dev/null
lc 'reports the block current' 'status=current'
[ "$(calls)" = 1 ] && ok 'does not call the job again' || bad "does not call the job again (got $(calls))"
[ "$BEFORE" = "$(md5sum < "$T/ws/template/librelane/grx930_overrides.yaml")" ] && ok 'config byte-identical' \
    || bad 'config byte-identical'

echo "== an arm measurement lands: a probe log grows =="
printf '[INFO GRT-0015] Inserted 8749 diodes.\n' >> "$T/ws/probe/out/diode_only.log"
once > /dev/null
lc 're-stages' 'status=staged'
has $(wlog) 'evidence changed' 'and names the trigger'
[ "$(calls)" = 2 ] && ok 'called the job again' || bad "called the job again (got $(calls))"
FP2=$(grep -a '^last_fingerprint ' "$T/drt_fast/verdict/tapeout_config_stage.state" | cut -d' ' -f2)
[ "$FP1" != "$FP2" ] && ok 'the recorded fingerprint moved' || bad 'the recorded fingerprint moved'

echo "== a new variant's log appears =="
mkdir -p "$T/ws/probe/out_pin01b"
printf 'ANT_PROBE_RESULT variant=base rc=0\n' > "$T/ws/probe/out_pin01b/base.log"
once > /dev/null
lc 're-stages on the new file' 'status=staged'
[ "$(calls)" = 3 ] && ok 'called the job again' || bad "called the job again (got $(calls))"

# Two changes: one before the reads (so the fingerprint is not the recorded one) and one
# between them (the hook), which is what a file being appended to mid-cycle looks like.
printf '[INFO GRT-0015] Inserted 175 diodes.\n' >> "$T/ws/probe/out/jumper_only.log"
C0=$(calls)
FPB=$(grep -a '^last_fingerprint ' "$T/drt_fast/verdict/tapeout_config_stage.state" | cut -d' ' -f2)
STAGE_ROOT=$T STAGE_WATCH_JOB=$T/build/stub_job.sh STAGE_WATCH_EVERY=1 \
    STAGE_WATCH_TEST_TOUCH=$T/ws/probe/out/diode_only.log bash "$WATCH" --once > /dev/null 2>&1
lc 'reports the evidence moving' 'status=unstable'
[ "$(calls)" = "$C0" ] && ok 'does not call the job with a moving file' || bad "does not call the job with a moving file (got $(calls))"
[ "$FPB" = "$(grep -a '^last_fingerprint ' "$T/drt_fast/verdict/tapeout_config_stage.state" | cut -d' ' -f2)" ] \
    && ok 'records nothing, so the change is still outstanding' || bad 'records nothing, so the change is still outstanding'
once > /dev/null
lc 'then acts once it settles' 'status=staged'
C0=$(calls)

echo "== the job refuses (busy box): do not record it as handled =="
BEFORE_FP=$(grep -a '^last_fingerprint ' "$T/drt_fast/verdict/tapeout_config_stage.state" | cut -d' ' -f2)
printf '[INFO GRT-0012] Found 522 antenna violations.\n' >> "$T/ws/probe/out/jumper_only.log"
RP=$(cycle_rc refuse)
[ "$RP" = 0 ] && ok 'a refusal is not the watcher failing' || bad "a refusal is not the watcher failing (exit $RP)"
lc 'reports the refusal' 'status=refused'
has $(wlog) 'not recorded; retried next cycle' 'and says it will retry'
[ "$BEFORE_FP" = "$(grep -a '^last_fingerprint ' "$T/drt_fast/verdict/tapeout_config_stage.state" | cut -d' ' -f2)" ] \
    && ok 'leaves the recorded fingerprint alone' || bad 'leaves the recorded fingerprint alone'
once > /dev/null
lc 'and the same change lands on the next cycle' 'status=staged'

echo "== a fresh watcher finds the block already correct: adopt it, do not churn =="
rm -f "$T/drt_fast/verdict/tapeout_config_stage.state"
CF=$(calls)
once unchanged > /dev/null
lc 'reports nothing to change' 'status=unchanged'
[ "$(calls)" -gt "$CF" ] && ok 'it did ask the job' || bad 'it did ask the job'
has "$T/drt_fast/verdict/tapeout_config_stage.state" 'last_fingerprint ' 'and adopts that fingerprint as handled'

BEFORE_FP2=$(grep -a '^last_fingerprint ' "$T/drt_fast/verdict/tapeout_config_stage.state" | cut -d' ' -f2)
echo "== the job runs but leaves no block: that is an error, not a success =="
sed -i '/BEGIN MEASURED-STAGING/,/END MEASURED-STAGING/d' "$T/ws/template/librelane/grx930_overrides.yaml"
cycle_rc noblock > /dev/null
lc 'reports the missing block as an error' 'status=error'
has $(wlog) 'still has no block' 'and says why'
[ "$BEFORE_FP2" = "$(grep -a '^last_fingerprint ' "$T/drt_fast/verdict/tapeout_config_stage.state" | cut -d' ' -f2)" ] \
    && ok 'records nothing, so the evidence stays outstanding' || bad 'records nothing, so the evidence stays outstanding'

echo "== the block deleted: restore it without waiting for a debounce cycle =="
mk_fixture
once > /dev/null
# The debounce is one STAGE_WATCH_EVERY sleep, so measure both kinds of cycle at EVERY=5
# and compare them: an absolute threshold would only be measuring how fast a subshell
# starts on the machine this test happens to run on.
printf '[INFO GRT-0012] Found 700 antenna violations.\n' >> "$T/ws/probe/out_pin01/base.log"
T0=$(date -u +%s)
STAGE_ROOT=$T STAGE_WATCH_JOB=$T/build/stub_job.sh STAGE_WATCH_EVERY=5 bash "$WATCH" --once > /dev/null 2>&1
T_CHANGE=$(( $(date -u +%s) - T0 ))
sed -i '/BEGIN MEASURED-STAGING/,/END MEASURED-STAGING/d' "$T/ws/template/librelane/grx930_overrides.yaml"
T0=$(date -u +%s)
STAGE_ROOT=$T STAGE_WATCH_JOB=$T/build/stub_job.sh STAGE_WATCH_EVERY=5 bash "$WATCH" --once > /dev/null 2>&1
T_MISSING=$(( $(date -u +%s) - T0 ))
lc 'the block is acted on, not skipped' 'status=staged'
[ $(( T_CHANGE - T_MISSING )) -ge 4 ] \
    && ok "a missing block skips the debounce (${T_MISSING}s against ${T_CHANGE}s for a change)" \
    || bad "a missing block skips the debounce (${T_MISSING}s against ${T_CHANGE}s for a change)"
lc 're-stages it' 'status=staged'
has "$T/ws/template/librelane/grx930_overrides.yaml" 'BEGIN MEASURED-STAGING' 'the block is back'

echo "== one instance, and a stale lock =="
mkdir -p "$T/ws/logs/.stage_tapeout_watch.lock"
printf '%s' "$$" > "$T/ws/logs/.stage_tapeout_watch.lock/pid"
C0=$(calls)
RP=$(cycle_rc staged)
[ "$RP" = 1 ] && ok 'a second watcher exits 1' || bad "a second watcher exits 1 (exit $RP)"
has $(wlog) 'WATCH_LOCKED' 'and says the lock is held'
[ "$(calls)" = "$C0" ] && ok 'without calling the job' || bad 'without calling the job'
sleep 0.2 & DEAD=$!; wait "$DEAD" 2>/dev/null
printf '%s' "$DEAD" > "$T/ws/logs/.stage_tapeout_watch.lock/pid"
CB=$(grep -ac 'WATCH_CYCLE ' $(wlog))
RP=$(cycle_rc staged)
[ "$RP" = 0 ] && ok 'a stale lock is taken over' || bad "a stale lock is taken over (exit $RP)"
has $(wlog) 'WATCH_LOCK_STALE' 'and says so'
[ "$(grep -ac 'WATCH_CYCLE ' $(wlog))" -gt "$CB" ] && ok 'and a cycle runs anyway' \
    || bad "and a cycle runs anyway (cycles: $CB -> $(grep -ac 'WATCH_CYCLE ' $(wlog)))"
[ ! -d "$T/ws/logs/.stage_tapeout_watch.lock" ] && ok 'and the lock is released on exit' \
    || bad 'and the lock is released on exit'

echo "== the deadline is a loud exit, not a silence =="
STAGE_ROOT=$T STAGE_WATCH_JOB=$T/build/stub_job.sh STAGE_WATCH_EVERY=1 STAGE_WATCH_HOURS=1 \
    STAGE_WATCH_START=$(( $(date -u +%s) - 7200 )) bash "$WATCH" > /dev/null 2>&1
RP=$?
[ "$RP" = 1 ] && ok 'exits 1 at the deadline' || bad "exits 1 at the deadline (exit $RP)"
has $(wlog) 'WATCH_DEADLINE' 'and says the block stops being re-staged there'

echo
echo "== $PASS passed, $FAIL failed (tree: $T) =="
[ "$FAIL" = 0 ] || exit 1
rm -rf "$T"
exit 0
