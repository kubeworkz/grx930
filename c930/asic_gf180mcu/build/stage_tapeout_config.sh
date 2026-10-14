#!/bin/bash
# stage_tapeout_config.sh -- host side: make the die's TAPEOUT configuration a
# measured decision, by reading the arm results and writing them next to the knobs.
#
# WHY THIS EXISTS
#
#   The staged file (ws/template/librelane/grx930_overrides.yaml) leaves the
#   antenna-repair composite at its default -- on, unrestricted -- and its own
#   comments record why that cannot work on the engine the image ships: the repair's
#   own global-router pass hits `[ERROR GRT-0183] ... heap underflow during 3D maze
#   routing` and the pinned build turns that into an abort (line ~372 of that file,
#   and die_to_drt_antenna_and_pin.md §2). A tapeout run launched from it therefore
#   cannot finish. The repair modes that CAN finish have since been measured, and
#   this job is what puts the measurement into the configuration instead of leaving
#   it in a report nobody reads at launch time.
#
# THE DECISION, AND WHAT EACH RUNG NEEDS AS EVIDENCE
#
#   Rung 1  unmodified repair on the PIN engine -> fewest antenna violations left
#           (114 against 522 and 1209), and it is the flow as designed.
#           Requires: the flow arm (build/die_diode_flow_chain.sh, tag died26q4)
#           to have REACHED DetailedRouting -- its own report naming that tag with
#           a pass-0 row, and its chain log saying DIE_DIO_FLOW_COMPLETE. Staged
#           with the engine pin (_LLN_OVERRIDE_OPENROAD) and the LibreLane #1023
#           backport, without which that arm dies at step 01 (run diepin02).
#   Rung 2  diode-only repair on the SHIPPED engine (probe rc=0, 522 violations
#           left, 8749 diodes). Requires: ws/probe/out/diode_only.log rc=0.
#           Chosen when rung 1 was not confirmed: it needs no engine pin and no
#           backport, at the cost of 522 unresolved antenna violations against 114.
#   Rung 3  jumper-only (the arm in flight proved this reaches DRT, at 1209
#           unresolved and no diodes). Requires: none -- it is the floor, and the
#           block is marked SIGNOFF_COMPROMISE so nobody reads it as a choice.
#
#   The job REFUSES to write anything it cannot back with a measurement (the probe
#   logs are the minimum), and records "not measured" rather than a plausible
#   number for anything the arms have not produced. It never touches a file while
#   an arm that reads it is queued or running: the queued flow arm reads this exact
#   overrides file at launch, and editing it under that arm would silently change
#   the arm's identity.
#
# WHAT IT WRITES (idempotent, delimited, sha256 recorded before and after)
#
#   * ws/template/librelane/grx930_overrides.yaml -- a `MEASURED-STAGING` block:
#     the repair-mode knobs, the three measured repair outcomes, the DRT cost of
#     each database where measured, and the engine/backport provenance.
#   * ws/ws_exec.sh -- a `MEASURED-STAGING` block staging the engine pin and the
#     #1023 backport, RUNG 1 ONLY, with escape hatches (WS_OPENROAD=none,
#     WS_PATCH_LLN=0). Written on rung 1, removed on the other rungs.
#   * a .bak beside each file, once, and ws/logs/stage_tapeout_config.log.
#
#   nohup bash build/stage_tapeout_config.sh > /dev/null 2>&1 &
#   tail -f ws/logs/stage_tapeout_config.log
#
# EXIT CODES, because build/stage_tapeout_watch.sh drives this job in a loop:
#   0  decided and acted (STAGE_WRITE says whether the file changed: rc=0 wrote, rc=1
#      already matched). STAGE_DECISION/STAGE_FINGERPRINT in the log name the decision and
#      the evidence it was made from.
#   1  refused or aborted: busy box (STAGE_WAIT=0), no probe evidence, another instance
#      holds the lock, the evidence would not settle, or the wait timed out. Nothing was
#      written, so the caller should try again later rather than record the evidence as
#      handled.
#
# The evidence set this job reads and the fingerprint it re-checks before writing live in
# build/stage_evidence.sh, shared with the watcher.
#
# The measurements move on their own -- an arm finishes, a probe variant lands -- so this
# job is run again by build/stage_tapeout_watch.sh whenever the fingerprint changes. Run it
# on its own only to force a decision at a specific moment.
#
#   STAGE_CHECK=1 bash build/stage_tapeout_config.sh   # decide and print, write nothing
#
#   STAGE_ROOT=<dir>  points the whole job at another tree. Only the selftest uses it:
#                     every path below is derived from ROOT, so a fake tree under /tmp
#                     exercises all three rungs and the write path without the box.
set -u
ROOT=${STAGE_ROOT:-/home/ubuntu/grx930_ol2}
B=$ROOT/build
WS=$ROOT/ws
D=$ROOT/drt_fast
OVR=$WS/template/librelane/grx930_overrides.yaml
LAUNCHER=$WS/ws_exec.sh
PATCH=/work/ws/tools/librelane_1023_io_patch.py
OR26=/work/ws/tools/openroad_26q4.sh
FLOW_TAG=${STAGE_FLOW_TAG:-died26q4}
LOG=$WS/logs/stage_tapeout_config.log
CHECK=${STAGE_CHECK:-0}
WAIT=${STAGE_WAIT:-1}
MAX_WAIT_H=${STAGE_MAX_WAIT_H:-48}
BMARK='MEASURED-STAGING'
RETRY_SLEEP=${STAGE_RETRY_SLEEP:-30}
MAX_RETRY=${STAGE_MAX_RETRY:-4}
LOCK=$WS/logs/.stage_tapeout_config.lock
# No gate.sh here on purpose: this job launches no router and takes no measurement,
# so the disk/memory gates have nothing to protect. It only writes two files.
say() { echo "[$(date -u)] $*" | tee -a "$LOG"; }
mkdir -p "$WS/logs"
# The evidence set and its fingerprint, shared with build/stage_tapeout_watch.sh so the two
# cannot disagree about what counts as "the measurements" (see that file's header).
[ -f "$B/stage_evidence.sh" ] || { say "STAGE_ABORT missing $B/stage_evidence.sh"; exit 1; }
. "$B/stage_evidence.sh"

# ---- one decider at a time -------------------------------------------------------
# stage_tapeout_watch.sh re-runs this job whenever the evidence moves, and a human may also
# invoke it, so two instances meeting at the same idle box is a real possibility. They would
# not corrupt the file (each write is a whole-file cat of stripped+block) but they could
# interleave a strip and a write and leave the block describing one rung while the other
# instance's decision is logged last. The lock makes the second one refuse instead.
release_lock() { [ -d "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"; return 0; }
acquire_lock() {
    local p
    if mkdir "$LOCK" 2>/dev/null; then printf '%s' "$$" > "$LOCK/pid"; return 0; fi
    p=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then say "STAGE_LOCK_HELD pid=$p"; return 1; fi
    say "STAGE_LOCK_STALE pid=${p:-unreadable} -- taking it"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || return 1
    printf '%s' "$$" > "$LOCK/pid"
    return 0
}

# ---- evidence ------------------------------------------------------------------
probe_stat() {  # $1 log -> rc|violations_left|diodes|jumpers  (sums the insertions)
    local log=$1 rc left di ju
    rc=$(grep -aoE 'ANT_PROBE_RESULT.*rc=[0-9]+' "$log" 2>/dev/null | grep -oE 'rc=[0-9]+' | tail -1 | cut -d= -f2)
    left=$(grep -aoE 'Found [0-9]+ antenna violations' "$log" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    di=$(grep -aoE 'Inserted [0-9]+ diodes' "$log" 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
    ju=$(grep -aoE 'Inserted [0-9]+ jumpers' "$log" 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
    printf '%s|%s|%s|%s' "${rc:-?}" "${left:-?}" "${di:-?}" "${ju:-?}"
}
arm_row() {  # $1 arm -> "initial|iter1|iter2|iter3|peak|wall|rc" from the fast-loop tsv
    local f=$D/verdict/die_drt_db_compare.tsv row
    [ -f "$f" ] || { printf 'not measured'; return; }
    row=$(awk -F'|' -v a="$1" '$1==a {print $4"|"$5"|"$6"|"$7"|"$8"|"$9"|"$10}' "$f" | tail -1)
    [ -n "$row" ] && printf '%s' "$(printf '%s' "$row" | tr -d ',')" || printf 'not measured'
}
flow_reached() {  # 1 = the unmodified-repair arm reached DetailedRouting, 0 = not
    # Three independent facts, all of them about THIS tag: the chain finished an arm
    # by that name, the report (which the chain rewrites from the logs either way,
    # success or failure) names that tag, and the report has a pass-0 row -- a table
    # row only exists if the router's own `Completing 100% with` line did. A report
    # naming another tag is the trap here: the same file currently holds the
    # jumper-only arm's harvest, and a tag-blind check would read it as this arm's.
    local rep=$D/verdict/die_diode_flow_arm.md f
    grep -aq "DIE_DIO_FLOW_COMPLETE tag=$FLOW_TAG" "$WS/logs/die_diode_flow_chain.log" 2>/dev/null || return 1
    [ -f "$rep" ] || return 1
    grep -aqF "(tag \`$FLOW_TAG\`)" "$rep" || return 1
    grep -aqE '^\| 0 \|' "$rep" || return 1
    # and the router really iterated, in whichever log the arm left
    for f in "$WS/logs/predrt_$FLOW_TAG.container.log" "$WS/logs/predrt_$FLOW_TAG.log" \
             "$WS/template/librelane/runs/$FLOW_TAG/06-openroad-detailedrouting/openroad-detailedrouting.log"; do
        grep -aqsE '\[INFO DRT-0199\]' "$f" && return 0
    done
    return 1
}
flow_failure() {  # the quoted reason the arm did not reach DRT, for the block
    local log=$WS/logs/predrt_$FLOW_TAG.log out
    [ -f "$log" ] || { printf 'no %s on disk (the arm has not launched yet)' "predrt_$FLOW_TAG.log"; return; }
    out=$(grep -aE 'ERROR|Error:|STA-0107|GRT-0183' "$log" 2>/dev/null | tail -2 | tr '\n' ' ')
    [ -n "$out" ] && printf '%s' "$out" || printf 'the arm left no ERROR line (see its report)'
}
report_tag() {  # the tag the report on disk describes -- it is rewritten for EVERY arm
    local rep=$D/verdict/die_diode_flow_arm.md
    [ -f "$rep" ] || { printf 'no report on disk'; return; }
    grep -aom1 -E '\(tag `[^`]+`\)' "$rep" 2>/dev/null | tr -d '()`' || printf 'a report that names no tag'
}
jmp_flow_baseline() {  # the flow-confirmed jumper-only datum, measured not remembered
    local log=$WS/logs/predrt_diejmp01.log left first last di
    [ -f "$log" ] || { printf 'not measured'; return; }
    # The arm's repair step is the only pre-DRT log that carries GRT-0012's running
    # count, and its LAST one is the count the arm finished with (1209) -- the same
    # number the probe's jumper_only variant reported from the same database. The
    # glob must stay OUTSIDE the quotes: "$WS/template/..."/*/*.log expands, a fully
    # quoted glob does not and grep then fails on a literal `*` (this block printed
    # `?` for exactly that reason in its first CHECK run).
    left=$(grep -ahoE 'Found [0-9]+ antenna violations' "$WS"/template/librelane/runs/diejmp01/04-openroad-repairantennas/*/*.log 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    first=$(grep -aE '\[INFO DRT-0199\]' "$log" 2>/dev/null | grep -oE '= [0-9]+' | grep -oE '[0-9]+' | head -1)
    last=$(grep -aE '\[INFO DRT-0199\]' "$log" 2>/dev/null | grep -oE '= [0-9]+' | grep -oE '[0-9]+' | tail -1)
    # and what the DRT step's own, unrestricted repair did to the routed database
    di=$(grep -ahoE 'Inserted [0-9]+ diodes' "$log" 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
    printf 'violations left %s, DRT pass 0 %s -> %s, and the DRT step itself inserted %s diodes' \
        "${left:-?}" "${first:-?}" "${last:-?}" "${di:-?}"
}

decide() {
    local rc
    if flow_reached; then
        RUNG=1; RUNG_WHY="the flow arm's own report names tag $FLOW_TAG with a pass-0 row and its chain log says DIE_DIO_FLOW_COMPLETE"
    elif [ "$(probe_stat "$WS/probe/out/diode_only.log" | cut -d'|' -f1)" = 0 ]; then
        RUNG=2; RUNG_WHY="rung 1 unconfirmed; the diode-only probe completed (rc=0). Arm reason: $(flow_failure)"
    else
        RUNG=3; RUNG_WHY="no other mode is backed by a measurement that completed; this is the floor, not a choice"
    fi
    case "$RUNG" in
        1) DIODE=false; JUMPER=false; PIN=1 ;;
        2) DIODE=true;  JUMPER=false; PIN=0 ;;
        3) DIODE=false; JUMPER=true;  PIN=0 ;;
    esac
}

stage_block() {  # $1 = "yaml" | "launcher" -> the block on stdout
    local kind=$1 stamp
    stamp=$(date -u '+%F %T')
    if [ "$kind" = yaml ]; then
        printf '# ==== BEGIN %s (generated %s UTC by build/stage_tapeout_config.sh) ====\n' "$BMARK" "$stamp"
        printf '# The antenna-repair configuration for the die, and the measurements it is made\n'
        printf '# from. Rung %s: %s\n' "$RUNG" "$RUNG_WHY"
        printf '#\n'
        printf '# Measured repair outcomes on the die'"'"'s pre-repair database (ws/probe/):\n'
        printf '#   unmodified on the 26Q4 engine : %s violations left, %s diodes + %s jumpers  (out_pin01/base.log, rc=%s)\n' \
            "$(probe_stat "$WS/probe/out_pin01/base.log" | cut -d'|' -f2)" "$(probe_stat "$WS/probe/out_pin01/base.log" | cut -d'|' -f3)" \
            "$(probe_stat "$WS/probe/out_pin01/base.log" | cut -d'|' -f4)" "$(probe_stat "$WS/probe/out_pin01/base.log" | cut -d'|' -f1)"
        printf '#   diode-only on the shipped engine: %s violations left, %s diodes + %s jumpers  (out/diode_only.log, rc=%s)\n' \
            "$(probe_stat "$WS/probe/out/diode_only.log" | cut -d'|' -f2)" "$(probe_stat "$WS/probe/out/diode_only.log" | cut -d'|' -f3)" \
            "$(probe_stat "$WS/probe/out/diode_only.log" | cut -d'|' -f4)" "$(probe_stat "$WS/probe/out/diode_only.log" | cut -d'|' -f1)"
        printf '#   jumper-only on the shipped engine: %s violations left, %s diodes + %s jumpers  (out/jumper_only.log, rc=%s)\n' \
            "$(probe_stat "$WS/probe/out/jumper_only.log" | cut -d'|' -f2)" "$(probe_stat "$WS/probe/out/jumper_only.log" | cut -d'|' -f3)" \
            "$(probe_stat "$WS/probe/out/jumper_only.log" | cut -d'|' -f4)" "$(probe_stat "$WS/probe/out/jumper_only.log" | cut -d'|' -f1)"
        printf '#\n'
        printf '# What each of those databases costs the router (fast loop, 3 iterations, 8 threads,\n'
        printf '# -or_seed 42, Metal1-Metal5 -- build/drt_db_compare_chain.sh; not measured = not run):\n'
        printf '#   jumper-only database     : %s\n' "$(arm_row jmp)"
        printf '#   unmodified on 26Q4       : %s\n' "$(arm_row pin26q4)"
        printf '#   diode-only database      : %s\n' "$(arm_row pindiode)"
        printf '#   unmodified, pinned engine: %s\n' "$(arm_row pinpinned)"
        printf '#   (initial|iter1|iter2|iter3|peak_mb|wall|rc)\n'
        if flow_reached; then
            printf '#   The flow arm (unmodified repair, 26Q4 engine): CONFIRMED at DetailedRouting --\n'
            printf '#   the arm report is drt_fast/verdict/die_diode_flow_arm.md (tag %s).\n' "$FLOW_TAG"
        else
            printf '#   The flow arm (unmodified repair, 26Q4 engine): NOT CONFIRMED -- it has not reached\n'
            printf '#   DetailedRouting. The report on disk describes %s. Quoted reason: %s\n' \
                "$(report_tag)" "$(flow_failure)"
        fi
        printf '#   The arm in flight, jumper-only, for reference: %s\n' "$(jmp_flow_baseline)"
        printf '# The knobs themselves: steps/common_variables.py:433-443 declares both as\n'
        printf '# `Variable(..., bool, default=False)`, and openroad/common/io.tcl:706\n'
        printf '# `append_if_flag` turns a set one into `-diode_only` / `-jumper_only`; the two are\n'
        printf '# mutually exclusive by declaration, which is why exactly one is true below.\n'
        printf '#\n'
        printf '# The fence is on the PRE-DRT composite only. The DetailedRouting step runs its OWN\n'
        printf '# antenna repair from a separate pair (DRT_ANTENNA_REPAIR_JUMPER_ONLY / _DIODE_ONLY,\n'
        printf '# steps/openroad.py:1968-1976, scripts/openroad/drt.tcl:107-108), and that stays\n'
        printf '# unrestricted: measured, it ran on the routed die and put 4,013 diodes in it\n'
        printf '# (die_to_drt_antenna_and_pin.md, section 4.2).\n'
        printf '#\n'
        if [ "$PIN" = 1 ]; then
            printf '# Engine: the repair above completes only on the 26Q4 build, staged for the flow in\n'
            printf '# ws/ws_exec.sh by this same run:\n'
            printf '#   _LLN_OVERRIDE_OPENROAD=%s   (OpenROAD 26Q4-407-geb14e40b7b)\n' "$OR26"
            printf '#   plus the LibreLane #1023 backport (%s). Without it the pin\n' "$PATCH"
            printf '#   arm dies at step 01'"'"'s finalization with `[ERROR STA-0107] ..._p_Scene is not\n'
            printf '#   the name of a scene` (run diepin02, 2026-10-14 01:48).\n'
        else
            printf '# Engine: unchanged -- the image'"'"'s own OpenROAD. This mode completes without the\n'
            printf '# pin, which is why it is what a run staged from here uses until rung 1 is confirmed.\n'
        fi
        if [ "$RUNG" = 3 ]; then
            printf '# SIGNOFF_COMPROMISE: this configuration carries antenna violations into signoff.\n'
        fi
        printf '#\n'
        printf '# Evidence files and their md5, so a later reader can tell whether this block is\n'
        printf '# describing the same measurements:\n'
        md5sum "$WS/probe/out_pin01/base.log" "$WS/probe/out/diode_only.log" "$WS/probe/out/jumper_only.log" 2>/dev/null | sed 's/^/#   /'
        [ -f "$D/verdict/die_drt_db_compare.tsv" ] && md5sum "$D/verdict/die_drt_db_compare.tsv" | sed 's/^/#   /'
        [ -f "$D/verdict/die_diode_flow_arm.md" ] && md5sum "$D/verdict/die_diode_flow_arm.md" | sed 's/^/#   /'
        printf 'GRT_ANTENNA_REPAIR_DIODE_ONLY: %s\n' "$DIODE"
        printf 'GRT_ANTENNA_REPAIR_JUMPER_ONLY: %s\n' "$JUMPER"
        printf '# ==== END %s ====\n' "$BMARK"
    else
        printf '# ==== BEGIN %s (generated %s UTC by build/stage_tapeout_config.sh) ====\n' "$BMARK" "$stamp"
        printf '# The engine pin and the LibreLane #1023 backport, staged because the die'"'"'s antenna\n'
        printf '# repair completes only on the 26Q4 build (GRT-0183 aborts it on the shipped one) and\n'
        printf '# because that build cannot finish step 01 without the backport. Evidence: %s\n' "$RUNG_WHY"
        printf '# Escape hatches: WS_OPENROAD=none uses the image'"'"'s own OpenROAD (the unrestricted\n'
        printf '# repair then aborts -- see the MEASURED-STAGING block in grx930_overrides.yaml);\n'
        printf '# WS_PATCH_LLN=0 skips the backport.\n'
        printf 'if [ "${WS_OPENROAD:-pin}" != none ]; then\n'
        printf '    _LLN_OVERRIDE_OPENROAD="${WS_OPENROAD:-%s}"\n' "$OR26"
        printf '    export _LLN_OVERRIDE_OPENROAD\n'
        printf '    echo "WS_EXEC: openroad override=$_LLN_OVERRIDE_OPENROAD ($("$_LLN_OVERRIDE_OPENROAD" -version 2>&1 | head -1))"\n'
        printf 'fi\n'
        printf 'if [ "${WS_PATCH_LLN:-1023}" = 1023 ]; then\n'
        printf '    PYP=$(command -v python3 2>/dev/null || true)\n'
        printf '    [ -n "$PYP" ] || PYP=$(ls -1 /nix/store/*-python3-*/bin/python3* 2>/dev/null | head -1)\n'
        printf '    "$PYP" %s > /work/ws/logs/patch_lln_1023.log 2>&1 || true\n' "$PATCH"
        printf '    if grep -qE "^PATCH_LLN status=(applied|already-patched)" /work/ws/logs/patch_lln_1023.log; then\n'
        printf '        echo "WS_EXEC: $(grep -E "^PATCH_LLN status=" /work/ws/logs/patch_lln_1023.log | tail -1)"\n'
        printf '    else\n'
        printf '        echo "WS_EXEC: REFUSING -- the #1023 backport did not apply; this engine needs it" >&2\n'
        printf '        tail -5 /work/ws/logs/patch_lln_1023.log >&2\n'
        printf '        exit 1\n'
        printf '    fi\n'
        printf 'fi\n'
        printf '# ==== END %s ====\n' "$BMARK"
    fi
}

# The block carries its generation time, so a byte comparison would rewrite the file
# on every run and churn the config hash other instruments record. Compare with the
# timestamp normalised away instead, and leave the file untouched when only it differs.
norm() { sed -E 's/\(generated [0-9-]+ [0-9:]+ UTC/\(generated <stamp>/' "$1"; }

# Strip any previous block of ours and append the new one, only if it changed.
install_block() {  # $1 file $2 kind -> 0 written, 1 unchanged, 2 file missing
    local f=$1 kind=$2 tmp old new
    [ -f "$f" ] || return 2
    tmp=$(mktemp); old=$(mktemp); new=$(mktemp)
    awk -v b="$BMARK" 'index($0, "BEGIN " b) {skip=1} !skip {print} index($0, "END " b) {skip=0}' "$f" > "$tmp"
    # drop trailing blank lines the previous block may have left
    awk 'BEGIN{n=0} {l[NR]=$0} END{for(i=NR;i>0;i--) if (l[i] ~ /[^ \t]/) {last=i; break}; for(i=1;i<=last;i++) print l[i]}' "$tmp" > "$old"
    cp "$old" "$new"; stage_block "$kind" >> "$new"
    if [ "$kind" = launcher ] && [ "$PIN" != 1 ]; then
        # Nothing to stage in the launcher on the other rungs: the block is removed
        # (so a rung 2/3 tapeout cannot inherit a pin from an earlier rung 1 run).
        if diff -q <(norm "$old") <(norm "$f") >/dev/null 2>&1; then return 1; fi
        [ -f "$f.bak" ] || cp "$f" "$f.bak"
        cat "$old" > "$f"
        return 0
    fi
    if diff -q <(norm "$new") <(norm "$f") >/dev/null 2>&1; then return 1; fi
    [ -f "$f.bak" ] || cp "$f" "$f.bak"
    cat "$new" > "$f"
    return 0
}

# ---- decide --------------------------------------------------------------------
if [ "$CHECK" != 1 ]; then
    say "STAGE_START flow_tag=$FLOW_TAG wait=$WAIT"
    # Wait for the arms AND for the box: the queued flow arm reads $OVR at launch,
    # so nothing may be written while it is queued or running.
    W0=$(date -u +%s); WAITED=0
    while :; do
        RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
        AHEAD=$(pgrep -f 'build/(drt_db_compare_chain|die_diode_flow_chain)\.sh$' 2>/dev/null | tr '\n' ' ')
        [ -z "$RUNNING" ] && [ -z "$AHEAD" ] && break
        if [ "$WAIT" != 1 ]; then say "STAGE_BUSY running='${RUNNING:-none}' ahead='${AHEAD:-none}' -- refusing (STAGE_WAIT=0)"; exit 1; fi
        if [ $(( ($(date -u +%s) - W0) / 3600 )) -ge "$MAX_WAIT_H" ]; then
            say "STAGE_ABORT wait_timeout_${MAX_WAIT_H}h running='${RUNNING:-none}' ahead='${AHEAD:-none}'"; exit 1
        fi
        [ "$WAITED" = 0 ] && { say "STAGE_WAIT_BEGIN running='${RUNNING:-none}' ahead='${AHEAD:-none}'"; WAITED=1; }
        sleep 120
    done
    [ "$WAITED" = 1 ] && say "STAGE_WAIT_END after $(( ($(date -u +%s) - W0) / 60 ))m"
fi

if [ ! -s "$WS/probe/out_pin01/base.log" ] || [ ! -s "$WS/probe/out/diode_only.log" ] || [ ! -s "$WS/probe/out/jumper_only.log" ]; then
    say "STAGE_ABORT no probe evidence to stage from (ws/probe/out*/*.log) -- nothing is measured, nothing is written"
    exit 1
fi

# ---- decide, and confirm the evidence did not move under the decision -------------
# The arms write these files while they run, so a decision can be made from a set of files
# that changed while it was being made -- the block would then quote numbers from two
# different states of the world. Recompute the fingerprint the decision was made from and
# re-decide if it moved; a file that will not settle is an abort, not a coin flip.
ATTEMPT=0
while :; do
    FP_DECIDED=$(stage_evidence_fingerprint)
    decide
    [ "$CHECK" = 1 ] && break
    if [ -n "${STAGE_TEST_TOUCH:-}" ]; then
        # test hook (selftest only): move an evidence file between the decision and the
        # confirmation, which is what a file still being written looks like from here.
        printf 'stage_test_touch\n' >> "$STAGE_TEST_TOUCH"
        [ -n "${STAGE_TEST_TOUCH_ONCE:-}" ] && STAGE_TEST_TOUCH=''
    fi
    FP_NOW=$(stage_evidence_fingerprint)
    [ "$FP_DECIDED" = "$FP_NOW" ] && break
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -ge "$MAX_RETRY" ]; then
        say "STAGE_EVIDENCE_UNSTABLE after $ATTEMPT attempts (fingerprint $FP_DECIDED -> $FP_NOW) -- writing nothing"
        exit 1
    fi
    say "STAGE_EVIDENCE_CHANGED attempt=$ATTEMPT ($FP_DECIDED -> $FP_NOW) -- re-reading the decision"
    sleep "$RETRY_SLEEP"
done
say "STAGE_DECISION rung=$RUNG diode_only=$DIODE jumper_only=$JUMPER pin_engine=$PIN"
say "STAGE_RUNG_WHY $RUNG_WHY"
say "STAGE_FINGERPRINT $FP_DECIDED"

if [ "$CHECK" = 1 ]; then
    echo "---------- grx930_overrides.yaml block ----------"
    stage_block yaml
    echo "---------- ws_exec.sh block ----------"
    [ "$PIN" = 1 ] && stage_block launcher || echo "(none: the launcher is only staged on rung 1)"
    say "STAGE_CHECK_DONE (wrote nothing)"
    exit 0
fi

if ! acquire_lock; then
    say "STAGE_ABORT another instance is deciding (lock $LOCK) -- nothing written"
    exit 1
fi
trap 'release_lock' EXIT INT TERM

BEFORE_OVR=$(sha256sum "$OVR" | awk '{print $1}')
BEFORE_WS=$(sha256sum "$LAUNCHER" | awk '{print $1}')
install_block "$OVR" yaml; rc_ovr=$?
install_block "$LAUNCHER" launcher; rc_ws=$?
say "STAGE_WRITE overrides rc=$rc_ovr launcher rc=$rc_ws (0 written, 1 unchanged, 2 missing)"

# The staged file is the operative config and it lives only on this box. The repository's
# own copy (wafer_space_integration/grx930_overrides.yaml) is where a re-stage would read
# from, so it would drop this block without a word. Dumping the exact bytes written to a
# path a host-side sync can pick up makes that mirroring a copy rather than a retyping.
# Extracted from the file, not regenerated, so the dump is what the flow will read.
sed -n "/BEGIN $BMARK/,/END $BMARK/p" "$OVR" > "$D/verdict/tapeout_config_staged.yaml.part"
say "STAGE_DUMP $D/verdict/tapeout_config_staged.yaml.part $(wc -l < "$D/verdict/tapeout_config_staged.yaml.part") lines"
if [ "$PIN" = 1 ]; then
    sed -n "/BEGIN $BMARK/,/END $BMARK/p" "$LAUNCHER" > "$D/verdict/tapeout_config_launcher.sh.part"
    say "STAGE_DUMP $D/verdict/tapeout_config_launcher.sh.part $(wc -l < "$D/verdict/tapeout_config_launcher.sh.part") lines"
    say "STAGE_NOTE mirror that block into wafer_space_integration/grx930_overrides.yaml, or the next re-stage drops it"
fi
say "STAGE_SHA256 overrides $BEFORE_OVR -> $(sha256sum "$OVR" | awk '{print $1}')"
say "STAGE_SHA256 launcher $BEFORE_WS -> $(sha256sum "$LAUNCHER" | awk '{print $1}')"
say "STAGE_COMPLETE rung=$RUNG block_in=$(basename "$OVR")"
release_lock
# The arm the block constrains reads this file at LAUNCH ('the staged file, unmodified').
# A re-run of it after this point is therefore a different experiment, not a repeat: it
# would carry the repair mode staged here. The arm's own CONFIG_SHA256 line (die_drt_chain)
# is what tells the two apart, and DIE_DIO_OVERRIDE is how to pin the mode explicitly.
say "STAGE_NOTE build/die_diode_flow_chain.sh re-run after this reads the staged mode; its CONFIG_SHA256 line, not its header, says which"
exit 0
