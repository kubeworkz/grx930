#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# stage_tapeout_config_selftest.sh -- the rung logic and the write path of
# build/stage_tapeout_config.sh, exercised off the box against a fake tree.
#
# Why this exists: the staging job decides which antenna-repair mode the TAPEOUT
# configuration carries, and it can only be run once -- on the box, after the arms
# finish, against the real files. A wrong rung there is a wrong tapeout config with a
# measurement's name on it, so the decision has to be testable before that moment and
# without the box. Everything the job reads is derived from its ROOT, so STAGE_ROOT
# (which this test is the only user of) points it at a fixture tree.
#
# The fixtures are the arm logs' own line shapes, copied from the real ones on disk:
# `[INFO GRT-0012] Found N antenna violations.` from OpenROAD's repair, `Inserted N
# diodes.` / `Inserted N jumpers for N nets.` from its insertions, and the probe's
# `ANT_PROBE_RESULT variant=... rc=...` terminator. The numbers are the measured ones
# (114/3540/5647, 522/8749/0, 1209/0/4036) so a rung's block is checked against the
# values the real run would print, not against round numbers.
#
#   bash build/stage_tapeout_config_selftest.sh
set -u
S=$(cd "$(dirname "$0")" && pwd)
STAGE=$S/stage_tapeout_config.sh
T=$(mktemp -d)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()  { grep -qaF -- "$2" "$1" && ok "$3" || bad "$3 (missing: $2)"; }
hasnt(){ grep -qaF -- "$2" "$1" && bad "$3 (present: $2)" || ok "$3"; }

build_tree() {  # $1 = tree, $2 = rung to fixture ("2" default, "1", "3")
    rm -rf "$1"
    mkdir -p "$1/build" "$1/ws/logs" "$1/ws/template/librelane" "$1/ws/probe/out_pin01" \
             "$1/ws/probe/out" "$1/drt_fast/verdict" "$1/bin"
    # the job sources the evidence set from its own build directory, so the fake tree needs
    # the real include: a fixture that stubs it would not be testing the shared definition
    cp "$S/stage_evidence.sh" "$1/build/stage_evidence.sh"
    printf 'DESIGN_NAME: chip_top\nGRT_ADJUSTMENT: 0.1\n' > "$1/ws/template/librelane/grx930_overrides.yaml"
    printf '#!/bin/sh\n# staged ws_exec.sh\ncd /work/ws/template || exit 1\n' > "$1/ws/ws_exec.sh"
    # an idle box: nothing to wait for, no arm queued
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/docker"
    printf '#!/bin/sh\nexit 1\n' > "$1/bin/pgrep"
    chmod +x "$1/bin/docker" "$1/bin/pgrep"
    refixture "$1" "${2:-2}"
}

# The measurements themselves, in the arm logs' own line shapes. Separate from
# build_tree because a re-measurement must be able to move the rung WITHOUT recreating
# the tree: the point of the reversibility case below is what the job does to the two
# config files it has already edited.
refixture() {  # $1 = tree, $2 = rung to fixture
    local t=$1 rung=${2:-2}
    rm -f "$t/ws/logs/die_diode_flow_chain.log" "$t/drt_fast/verdict/die_diode_flow_arm.md"
    rm -rf "$t/ws/template/librelane/runs"

    # ws/probe/out_pin01/base.log -- the pin engine, unmodified repair (the rung-1 evidence)
    {
        echo 'ANT_PROBE_START variant=base iters=3 margin=10 jumper_only=0 diode_only=0 allow_congestion=1'
        echo '[INFO GRT-0012] Found 2979 antenna violations.'
        echo '[INFO GRT-0302] Inserted 3718 jumpers for 2072 nets.'
        echo '[INFO GRT-0012] Found 1360 antenna violations.'
        echo '[INFO GRT-0015] Inserted 2590 diodes.'
        echo '[INFO GRT-0012] Found 483 antenna violations.'
        echo '[INFO GRT-0015] Inserted 775 diodes.'
        echo '[INFO GRT-0302] Inserted 287 jumpers for 188 nets.'
        echo '[INFO GRT-0012] Found 270 antenna violations.'
        echo '[INFO GRT-0302] Inserted 1642 jumpers for 936 nets.'
        echo '[INFO GRT-0012] Found 114 antenna violations.'
        echo '[INFO GRT-0015] Inserted 175 diodes.'
        echo 'ANT_PROBE_RESULT variant=base rc=0 elapsed_s=816 err=3540'
    } > "$t/ws/probe/out_pin01/base.log"
    # out/diode_only.log -- the shipped engine, restricted to diodes (rung 2)
    {
        echo 'ANT_PROBE_START variant=diode_only iters=3 margin=10 jumper_only=0 diode_only=1'
        echo '[INFO GRT-0012] Found 2979 antenna violations.'
        echo '[INFO GRT-0015] Inserted 5241 diodes.'
        echo '[INFO GRT-0012] Found 1877 antenna violations.'
        echo '[INFO GRT-0015] Inserted 2820 diodes.'
        echo '[INFO GRT-0012] Found 522 antenna violations.'
        echo '[INFO GRT-0015] Inserted 688 diodes.'
        if [ "$rung" != 3 ]; then echo 'ANT_PROBE_RESULT variant=diode_only rc=0 elapsed_s=1375 err=8749'
        else echo 'ANT_PROBE_RESULT variant=diode_only rc=1 elapsed_s=1375 err=GRT-0183'; fi
    } > "$t/ws/probe/out/diode_only.log"
    # out/jumper_only.log -- the arm in flight's mode (the floor)
    {
        echo 'ANT_PROBE_START variant=jumper_only iters=3 margin=10 jumper_only=1 diode_only=0'
        echo '[INFO GRT-0012] Found 2979 antenna violations.'
        echo '[INFO GRT-0302] Inserted 3846 jumpers for 2080 nets.'
        echo '[INFO GRT-0302] Inserted 190 jumpers for 96 nets.'
        echo '[INFO GRT-0012] Found 1209 antenna violations.'
        echo 'ANT_PROBE_RESULT variant=jumper_only rc=0 elapsed_s=2977 err=0'
    } > "$t/ws/probe/out/jumper_only.log"

    if [ "$rung" != 1 ]; then
        # the trap the tag check exists for: the same report path currently holds the
        # arm in flight's harvest, so a tag-blind rung-1 check would read it as evidence
        printf '# The die%s flow\n\nWritten by `build/die_diode_flow_chain.sh` (tag `diejmp01`).\n' "'" > \
            "$t/drt_fast/verdict/die_diode_flow_arm.md"
        echo "[$(date -u)] DIE_DIO_FLOW_COMPLETE tag=diejmp01" > "$t/ws/logs/die_diode_flow_chain.log"
    fi
    if [ "$rung" = 1 ]; then
        # the flow arm reached the router: chain log, its report, and the router's own log
        mkdir -p "$t/ws/logs"
        echo "[$(date -u)] DIE_DIO_FLOW_COMPLETE tag=died26q4" > "$t/ws/logs/die_diode_flow_chain.log"
        printf '# arm\n\nWritten by `build/die_diode_flow_chain.sh` (tag `died26q4`).\n\n| pass | initial route |\n|---|---|\n| 0 | 446,541 |\n' \
            > "$t/drt_fast/verdict/die_diode_flow_arm.md"
        mkdir -p "$t/ws/template/librelane/runs/died26q4/06-openroad-detailedrouting"
        echo '[INFO DRT-0199] Number of violations = 446541' \
            > "$t/ws/template/librelane/runs/died26q4/06-openroad-detailedrouting/openroad-detailedrouting.log"
    fi
}

run_job() {  # $1 tree, $2 = "" (write) | "1" (check) -> stdout
    if [ "${2:-}" = 1 ]; then
        PATH=$1/bin:$PATH STAGE_ROOT=$1 STAGE_WAIT=0 STAGE_CHECK=1 bash "$STAGE" 2>&1
    else
        PATH=$1/bin:$PATH STAGE_ROOT=$1 STAGE_WAIT=0 bash "$STAGE" 2>&1
    fi
}

echo "== rung 2: the diode-only probe completed, rung 1 unconfirmed (today's state) =="
A=$T/rung2; build_tree "$A" 2
OUT=$(run_job "$A" 1); printf '%s\n' "$OUT" > $T/out.rung2
echo "$OUT" | grep -qa 'Rung 2:' && ok "decides rung 2" || bad "decides rung 2"
has $T/out.rung2 'GRT_ANTENNA_REPAIR_DIODE_ONLY: true'  'stages diode-only'
has $T/out.rung2 'GRT_ANTENNA_REPAIR_JUMPER_ONLY: false' 'and clears jumper-only (mutually exclusive)'
has $T/out.rung2 '(none: the launcher is only staged on rung 1)' 'stages no engine pin'
has $T/out.rung2 '114 violations left, 3540 diodes + 5647 jumpers' 'prints the pin engine measurement'
has $T/out.rung2 '522 violations left, 8749 diodes + 0 jumpers'   'prints the diode-only measurement'
has $T/out.rung2 '1209 violations left, 0 diodes + 4036 jumpers'  'prints the jumper-only measurement'
[ "$(grep -ac 'not measured' $T/out.rung2)" -ge 4 ] && ok 'the unrouted arms read "not measured", four of them' \
    || bad "the unrouted arms read \"not measured\" (got $(grep -ac 'not measured' $T/out.rung2))"
has $T/out.rung2 'The report on disk describes tag diejmp01' 'refuses another arm report as its own evidence'
has $T/out.rung2 'NOT CONFIRMED' 'and says the flow arm is unconfirmed'
BEFORE_OVR=$(md5sum < "$A/ws/template/librelane/grx930_overrides.yaml")
BEFORE_WS=$(md5sum < "$A/ws/ws_exec.sh")
hasnt $T/out.rung2 'STAGE_WRITE' 'prints the decision, writes nothing (CHECK)'
[ "$BEFORE_OVR" = "$(md5sum < "$A/ws/template/librelane/grx930_overrides.yaml")" ] && \
  [ "$BEFORE_WS" = "$(md5sum < "$A/ws/ws_exec.sh")" ] && ok 'both files byte-identical after CHECK' \
  || bad 'both files byte-identical after CHECK'

echo "== rung 3: no completed probe, no confirmed arm -> the floor, labelled as such =="
B=$T/rung3; build_tree "$B" 3
OUT=$(run_job "$B" 1); printf '%s\n' "$OUT" > $T/out.rung3
echo "$OUT" | grep -qa 'Rung 3:' && ok "decides rung 3" || bad "decides rung 3"
has $T/out.rung3 'GRT_ANTENNA_REPAIR_DIODE_ONLY: false' 'stages neither restriction as a choice'
has $T/out.rung3 'GRT_ANTENNA_REPAIR_JUMPER_ONLY: true' 'stages the mode that is only the floor'
has $T/out.rung3 'SIGNOFF_COMPROMISE' 'and says so in the block'
has $T/out.rung3 'The report on disk describes tag diejmp01' 'a report naming another tag is not evidence'

echo "== rung 1: the flow arm reached DetailedRouting on the 26Q4 engine =="
C=$T/rung1; build_tree "$C" 1
OUT=$(run_job "$C" 1); printf '%s\n' "$OUT" > $T/out.rung1
echo "$OUT" | grep -qa 'Rung 1:' && ok "decides rung 1" || bad "decides rung 1"
has $T/out.rung1 'GRT_ANTENNA_REPAIR_DIODE_ONLY: false' 'unrestricted repair is the rung-1 repair'
has $T/out.rung1 'GRT_ANTENNA_REPAIR_JUMPER_ONLY: false' 'both restrictions cleared'
has $T/out.rung1 '_LLN_OVERRIDE_OPENROAD=' 'stages the engine pin in the launcher'
has $T/out.rung1 'WS_PATCH_LLN' 'stages the #1023 backport with an escape hatch'
has $T/out.rung1 'librelane_1023_io_patch.py' 'names the patch it applies'
hasnt $T/out.rung1 'SIGNOFF_COMPROMISE' 'does not label the design as compromised'

echo "== the write path: staged once, idempotent, and reversible across rungs =="
OUT=$(run_job "$C" ""); printf '%s\n' "$OUT" > $T/out.write1
grep -qa 'STAGE_WRITE overrides rc=0 launcher rc=0' $T/out.write1 && ok 'writes both files' || bad 'writes both files'
[ "$(grep -ac 'BEGIN MEASURED-STAGING' "$C/ws/template/librelane/grx930_overrides.yaml")" = 1 ] \
    && ok 'one delimited block in the overrides file' || bad 'one delimited block in the overrides file'
[ "$(head -1 "$C/ws/template/librelane/grx930_overrides.yaml")" = 'DESIGN_NAME: chip_top' ] \
    && ok 'the file it edits still starts with the design name' || bad 'the file it edits still starts with the design name'
has "$C/ws/ws_exec.sh" '_LLN_OVERRIDE_OPENROAD=' 'the launcher carries the pin'
[ -f "$C/ws/template/librelane/grx930_overrides.yaml.bak" ] && ok 'keeps one .bak' || bad 'keeps one .bak'
[ ! -d "$C/ws/logs/.stage_tapeout_config.lock" ] && ok 'and releases its lock at exit' || bad 'and releases its lock at exit'
D1=$C/drt_fast/verdict/tapeout_config_staged.yaml.part
D2=$C/drt_fast/verdict/tapeout_config_launcher.sh.part
[ -s "$D1" ] && [ -s "$D2" ] && ok 'dumps both blocks for a host-side mirror' || bad 'dumps both blocks for a host-side mirror'
[ "$(cat "$D1")" = "$(sed -n "/BEGIN MEASURED-STAGING/,/END MEASURED-STAGING/p" "$C/ws/template/librelane/grx930_overrides.yaml")" ] \
    && ok 'the dump is the bytes the flow will read, not a regeneration' || bad 'the dump is the bytes the flow will read, not a regeneration'
W1=$(md5sum < "$C/ws/template/librelane/grx930_overrides.yaml")
OUT=$(run_job "$C" ""); printf '%s\n' "$OUT" > $T/out.write2
grep -qa 'STAGE_WRITE overrides rc=1 launcher rc=1' $T/out.write2 && ok 'a second run changes nothing' \
    || bad 'a second run changes nothing'
[ "$W1" = "$(md5sum < "$C/ws/template/librelane/grx930_overrides.yaml")" ] && ok 'byte-identical after the second run' \
    || bad 'byte-identical after the second run'
refixture "$C" 2   # the same tree, re-measured: rung 1 no longer holds
OUT=$(run_job "$C" ""); printf '%s\n' "$OUT" > $T/out.write3
hasnt "$C/ws/ws_exec.sh" '_LLN_OVERRIDE_OPENROAD=' 'a later rung 2 removes the pin a rung-1 run had staged'
has "$C/ws/template/librelane/grx930_overrides.yaml" 'GRT_ANTENNA_REPAIR_DIODE_ONLY: true' \
    'and the block in the overrides file follows the new rung'
hasnt "$C/ws/template/librelane/grx930_overrides.yaml" 'Rung 1:' 'with the old rung gone, not appended to'

echo "== the evidence moving under the decision: re-read it, or abort loudly =="
G=$T/race; build_tree "$G" 2
OUT=$(PATH=$G/bin:$PATH STAGE_ROOT=$G STAGE_WAIT=0 STAGE_RETRY_SLEEP=1 STAGE_MAX_RETRY=2 \
      STAGE_TEST_TOUCH=$G/ws/probe/out/diode_only.log STAGE_TEST_TOUCH_ONCE=1 bash "$STAGE" 2>&1); RC=$?
printf '%s\n' "$OUT" > $T/out.race1
[ "$RC" = 0 ] && ok 'a single move is re-read, not fatal' || bad "a single move is re-read, not fatal (exit $RC)"
has $T/out.race1 'STAGE_EVIDENCE_CHANGED attempt=1' 'and says it re-read the decision'
has $T/out.race1 'STAGE_WRITE overrides rc=0' 'then writes the block'
O2=$(PATH=$G/bin:$PATH STAGE_ROOT=$G STAGE_WAIT=0 STAGE_RETRY_SLEEP=1 STAGE_MAX_RETRY=2 \
      STAGE_TEST_TOUCH=$G/ws/probe/out/diode_only.log bash "$STAGE" 2>&1); RC2=$?
printf '%s\n' "$O2" > $T/out.race2
[ "$RC2" = 1 ] && ok 'a file that will not settle aborts' || bad "a file that will not settle aborts (exit $RC2)"
has $T/out.race2 'STAGE_EVIDENCE_UNSTABLE' 'and says so by name'

echo "== one decider at a time =="
H=$T/locked; build_tree "$H" 2
mkdir -p "$H/ws/logs/.stage_tapeout_config.lock"; printf '%s' "$$" > "$H/ws/logs/.stage_tapeout_config.lock/pid"
OUT=$(PATH=$H/bin:$PATH STAGE_ROOT=$H STAGE_WAIT=0 bash "$STAGE" 2>&1); RC=$?
[ "$RC" = 1 ] && ok 'a held lock stops the job' || bad "a held lock stops the job (exit $RC)"
echo "$OUT" | grep -qa 'STAGE_LOCK_HELD' && ok 'naming the holder' || bad 'naming the holder'
hasnt "$H/ws/template/librelane/grx930_overrides.yaml" 'MEASURED-STAGING' 'and writing nothing'
sleep 0.2 & DEAD=$!; wait "$DEAD" 2>/dev/null
printf '%s' "$DEAD" > "$H/ws/logs/.stage_tapeout_config.lock/pid"
OUT=$(PATH=$H/bin:$PATH STAGE_ROOT=$H STAGE_WAIT=0 bash "$STAGE" 2>&1); RC=$?
[ "$RC" = 0 ] && ok 'a stale lock is taken over' || bad "a stale lock is taken over (exit $RC)"
has "$H/ws/template/librelane/grx930_overrides.yaml" 'MEASURED-STAGING' 'and the block is written'
[ ! -d "$H/ws/logs/.stage_tapeout_config.lock" ] && ok 'with the lock released at exit' \
    || bad 'with the lock released at exit'

echo "== the refusals =="
E=$T/busy; build_tree "$E" 2
printf '#!/bin/sh\necho die_predrt\n' > "$E/bin/docker"; chmod +x "$E/bin/docker"
OUT=$(PATH=$E/bin:$PATH STAGE_ROOT=$E STAGE_WAIT=0 bash "$STAGE" 2>&1); RC=$?
[ "$RC" = 1 ] && ok 'exits 1 when an arm holds the box' || bad "exits 1 when an arm holds the box (got $RC)"
echo "$OUT" | grep -qa 'STAGE_BUSY' && ok 'and says why' || bad 'and says why'
hasnt "$E/ws/ws_exec.sh" 'MEASURED-STAGING' 'without touching the launcher'
F=$T/noev; build_tree "$F" 2; rm -f "$F/ws/probe/out/jumper_only.log"
OUT=$(PATH=$F/bin:$PATH STAGE_ROOT=$F STAGE_WAIT=0 bash "$STAGE" 2>&1); RC=$?
[ "$RC" = 1 ] && ok 'exits 1 with no probe evidence' || bad "exits 1 with no probe evidence (got $RC)"
echo "$OUT" | grep -qa 'STAGE_ABORT no probe evidence' && ok 'and refuses by name' || bad 'and refuses by name'
hasnt "$F/ws/template/librelane/grx930_overrides.yaml" 'MEASURED-STAGING' 'writing no block at all'

echo
echo "== $PASS passed, $FAIL failed (tree: $T) =="
[ "$FAIL" = 0 ] || exit 1
rm -rf "$T"
exit 0
