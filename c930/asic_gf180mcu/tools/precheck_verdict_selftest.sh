#!/bin/bash
# precheck_verdict_selftest.sh -- the parser's verdict logic, exercised off the box against
# fixture logs built from the real ones' line shapes.
#
# Why this exists: the precheck is a multi-hour job that can only be run against the real
# 160 MB die GDS, so the thing CI branches on must be testable without one. Every fixture line
# below is copied from the real logs on the flow box (2026-10-15/16, container ws-precheck2 and
# its two predecessors): the rich log prefix `[HH:MM:SS] LEVEL     message      checker.py:124`,
# the stage banners, `Skipping step 'Check Pad Mask'…`, the deferred block, and the wrapped
# continuation lines that rich produces at 80 columns. The numbers are the measured ones -- 2
# KLayout density errors, 83,777 KLayout DRC errors, 12,772 Magic DRC errors -- so the fixtures
# check the values the real run printed rather than round ones.
#
# Cases H and H2 cover the advisory rule family (see ADVISORY_RULE_SUFFIXES in the tool): a DRC
# tally whose every violation is `*_OFFGRID` is a critical warning rather than a hard blocker,
# while the same tally plus one ordinary rule blocks on that rule. Case I is the counterpart: with
# no tally to split, the log's raw count decides and nothing is reclassified.
#
#   bash tools/precheck_verdict_selftest.sh
#
# Note on the "clear" wording: two clear lines are quoted verbatim from the real log
# (antenna, zero area). The others are the same MetricChecker code path
# (`f"Check for {description} clear."`) with the description taken from the metric names in the
# run's own state_in.json (`klayout__density_error__count`, `magic__drc_error__count`,
# `klayout__drc_error__count`), which is why they read the way they do.
set -u
S=$(cd "$(dirname "$0")" && pwd)
TOOL=$S/precheck_verdict.py
# Prefer python3, but take whichever interpreter actually runs: on Windows the `python3`
# name can be a Microsoft Store stub that fails with a message rather than a version.
PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
[ -n "$PY" ] || { echo "no python3/python on PATH"; exit 1; }

T=$(mktemp -d)
# PRECHECK_VERDICT_KEEP=1 keeps the fixture logs and verdicts for inspection
if [ -z "${PRECHECK_VERDICT_KEEP:-}" ]; then trap 'rm -rf "$T"' EXIT; else echo "fixtures kept in $T"; fi

# jget <verdict.json> <dotted.path> -- print the field as JSON, so strings compare exactly
jget() {
    "$PY" - "$1" "$2" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    node = node[int(part)] if part.isdigit() else node[part]
print(json.dumps(node))
PY
}
# want <file> <path> <expected-json> <label>
want() {
    got=$(jget "$1" "$2" 2>/dev/null)
    if [ "$got" = "$3" ]; then ok "$4"; else bad "$4 (want $3, got $got)"; fi
}
# want_exit <expected> <label>
want_exit() {
    if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2 (want exit $1, got $RC)"; fi
}
run() {  # run <log> [extra args...] -> $T/out.json, $RC
    "$PY" "$TOOL" --log "$1" --quiet "${@:2}" > "$T/out.json" 2>"$T/err.txt"
    RC=$?
}

# ---------------------------------------------------------------- the log preamble
preamble() {
    cat <<'EOF'
[23:38:15] INFO     PDK_ROOT = /workspace/gf180mcu               precheck.py:501
[23:38:15] INFO     PDK = gf180mcuD                              precheck.py:502
[23:38:15] INFO     top_cell: chip_top                           precheck.py:507
[23:38:15] INFO     die_id: GRX93001                             precheck.py:508
[23:38:15] INFO     cob: True                                    precheck.py:509
[23:38:15] INFO     slot: 1x1                                    precheck.py:510
[23:38:15] INFO     threads: 4                                   precheck.py:511
[23:38:15] INFO     workers: 4                                   precheck.py:512
[23:38:15] INFO     Starting a new run of the 'PrecheckFlow'' flow   flow.py:654
                    with the tag 'run2'.                                        
EOF
}

# ================================================================ A: everything passes
echo "== A: a clean run (all 17 stages present, --cob)"
{
    preamble
    cat <<'EOF'
─────────────────────────────── Read the Layout ────────────────────────────────
[23:38:15] VERBOSE  Running 'KLayout.ReadLayout' at                 step.py:1138
2026-10-15 23:38:15 +0000: Memory Usage (423204K) : Reading the layout
[23:38:16] INFO     SHA256 for /host/run1/chip_top.gds:       precheck.py:95
                    764c79babda6299b8ce9a7bf86662ca0c4459c6b404ff               
                    ab4783e94840e068605                                         
───────────────────────────── Check Top-Level Name ─────────────────────────────
[23:38:51] VERBOSE  Running 'KLayout.CheckTopLevel' at              step.py:1138
─────────────────────────────── Check Slot Size ────────────────────────────────
[23:39:05] VERBOSE  Running 'KLayout.CheckSize' at                  step.py:1138
───────────────────────────────── Check Pad Mask ───────────────────────────────
[23:39:14] VERBOSE  Running 'KLayout.CheckPadMask' at               step.py:1138
[23:39:30] INFO     Check Pad Mask clear.                           checker.py:131
───────────────────────────────── Generate ID ──────────────────────────────────
[23:39:31] VERBOSE  Running 'KLayout.GenerateID' at                 step.py:1138
────────────────────────── Render Image (w/ KLayout) ───────────────────────────
[23:39:48] VERBOSE  Running 'KLayout.Render' at                     step.py:1138
──────────────────────────────── Density Check ─────────────────────────────────
[23:40:10] VERBOSE  Running 'KLayout.Density' at                    step.py:1138
─────────────────────────── KLayout Density Checker ────────────────────────────
[23:55:02] VERBOSE  Running 'Checker.KLayoutDensity' at             step.py:1138
[23:55:02] INFO     Check for KLayout density clear.                checker.py:131
─────────────────────────── Find Zero Area Polygons ────────────────────────────
[23:55:03] VERBOSE  Running 'KLayout.ZeroAreaPolygons' at           step.py:1138
────────────────────── KLayout Zero Area Polygons Checker ──────────────────────
[23:57:19] VERBOSE  Running 'Checker.KLayoutZeroAreaPolygons' at    step.py:1138
[23:57:19] INFO     Check for KLayout zero area polygons count       checker.py:131
                    clear.                                                      
──────────────────────────────── Antenna Check ─────────────────────────────────
[23:57:20] VERBOSE  Running 'KLayout.Antenna' at                    step.py:1138
─────────────────────────── KLayout Antenna Checker ────────────────────────────
[00:58:41] VERBOSE  Running 'Checker.KLayoutAntenna' at             step.py:1138
[00:58:41] INFO     Check for KLayout antenna errors clear.         checker.py:131
────────────────────────────── Design Rule Checks ──────────────────────────────
[00:58:42] VERBOSE  Running 'Magic.DRC' at                          step.py:1138
────────────────────────── Magic Design Rule Checker ───────────────────────────
[01:47:04] VERBOSE  Running 'Checker.MagicDRC' at                   step.py:1138
[01:47:04] INFO     Check for Magic DRC clear.                      checker.py:131
───────────────────────── Design Rule Check (KLayout) ──────────────────────────
[01:47:05] VERBOSE  Running 'KLayout.DRC' at                        step.py:1138
───────────────────────── KLayout Design Rule Checker ──────────────────────────
[01:47:30] VERBOSE  Running 'Checker.KLayoutDRC' at                 step.py:1138
[01:47:30] INFO     Check for KLayout DRC clear.                    checker.py:131
─────────────────────────────── Write the Layout ───────────────────────────────
[01:47:31] VERBOSE  Running 'KLayout.WriteLayout' at                step.py:1138
PrecheckFlow' - Stage 17 - Write the Layout ━━━━━━━━━━━━━━━━━━━━━ 17/17 0:09:16
[01:47:40] INFO     Precheck successfully completed.            precheck.py:622
EOF
} > "$T/pass.log"
run "$T/pass.log"
want_exit 0 "A: exit code is 0"
want "$T/out.json" result '"pass"' "A: result is pass"
want "$T/out.json" summary.stages_run 17 "A: 17 stages present"
want "$T/out.json" summary.stages_missing '[]' "A: no stage missing"
want "$T/out.json" summary.blocking_failed '[]' "A: no blocking gate failed"
want "$T/out.json" gates.4.status '"pass"' "A: KLayout DRC gate passes"
want "$T/out.json" run.top_cell '"chip_top"' "A: top cell parsed"
want "$T/out.json" artifact.sha256 '"764c79babda6299b8ce9a7bf86662ca0c4459c6b404ffab4783e94840e068605"' \
     "A: artifact checksum parsed"
want "$T/out.json" run.date '"2026-10-15 23:38:15"' "A: run date taken from the subprocess lines"
want "$T/out.json" skipped_steps '[]' "A: nothing skipped"

# ================================================================ B: the real run2 outcome
# deferred density + KLayout DRC failures, Magic DRC as a metric, pad mask skipped,
# messages wrapped across lines exactly as rich wrapped them.
echo "== B: the measured run2 outcome (density 2, KLayout DRC 83777, Magic 12772)"
{
    preamble
    cat <<'EOF'
─────────────────────────────── Read the Layout ────────────────────────────────
[23:38:15] VERBOSE  Running 'KLayout.ReadLayout' at                 step.py:1138
[23:38:16] INFO     SHA256 for /host/run1/chip_top.gds:       precheck.py:95
                    764c79babda6299b8ce9a7bf86662ca0c4459c6b404ff               
                    ab4783e94840e068605                                         
───────────────────────────── Check Top-Level Name ─────────────────────────────
[23:38:51] VERBOSE  Running 'KLayout.CheckTopLevel' at              step.py:1138
─────────────────────────────── Check Slot Size ────────────────────────────────
[23:39:05] VERBOSE  Running 'KLayout.CheckSize' at                  step.py:1138
[23:39:14] INFO     Skipping step 'Check Pad Mask'…            sequential.py:370
───────────────────────────────── Generate ID ──────────────────────────────────
[23:39:14] VERBOSE  Running 'KLayout.GenerateID' at                 step.py:1138
────────────────────────── Render Image (w/ KLayout) ───────────────────────────
[23:39:31] VERBOSE  Running 'KLayout.Render' at                     step.py:1138
──────────────────────────────── Density Check ─────────────────────────────────
[23:42:41] VERBOSE  Running 'KLayout.Density' at                    step.py:1138
2026-10-15 23:44:27 +0000: Memory Usage (1022560K) : COMP ratio: 20.182089165610375 %
─────────────────────────── KLayout Density Checker ────────────────────────────
[00:02:03] VERBOSE  Running 'Checker.KLayoutDensity' at             step.py:1138
[00:02:03] ERROR    2 KLayout density errors found. - deferred    checker.py:124
─────────────────────────── Find Zero Area Polygons ────────────────────────────
[00:02:03] VERBOSE  Running 'KLayout.ZeroAreaPolygons' at           step.py:1138
────────────────────── KLayout Zero Area Polygons Checker ──────────────────────
[00:04:19] VERBOSE  Running 'Checker.KLayoutZeroAreaPolygons' at    step.py:1138
[00:04:19] INFO     Check for KLayout zero area polygons count       checker.py:131
                    clear.                                                      
──────────────────────────────── Antenna Check ─────────────────────────────────
[00:04:19] VERBOSE  Running 'KLayout.Antenna' at                    step.py:1138
─────────────────────────── KLayout Antenna Checker ────────────────────────────
[01:08:41] VERBOSE  Running 'Checker.KLayoutAntenna' at             step.py:1138
[01:08:41] INFO     Check for KLayout antenna errors clear.         checker.py:131
────────────────────────────── Design Rule Checks ──────────────────────────────
[01:08:41] VERBOSE  Running 'Magic.DRC' at                          step.py:1138
────────────────────────── Magic Design Rule Checker ───────────────────────────
[01:57:04] VERBOSE  Running 'Checker.MagicDRC' at                   step.py:1138
[01:57:04] WARNING  12772 Magic DRC errors found.                 checker.py:122
───────────────────────── Design Rule Check (KLayout) ──────────────────────────
[01:57:15] VERBOSE  Running 'KLayout.DRC' at                        step.py:1138
───────────────────────── KLayout Design Rule Checker ──────────────────────────
[11:12:10] VERBOSE  Running 'Checker.KLayoutDRC' at                 step.py:1138
[11:12:10] ERROR    83777 KLayout DRC errors found. - deferred    checker.py:124
─────────────────────────────── Write the Layout ───────────────────────────────
[11:12:10] VERBOSE  Running 'KLayout.WriteLayout' at                step.py:1138
PrecheckFlow' - Stage 17 - Write the Layout ━━━━━━━━━━━━━━━━━━━━━ 17/17 10:58:17
[11:12:25] ERROR    The precheck failed with the following       precheck.py:618
                    exception:                                                  
                    One or more deferred errors were                           
                    encountered:                                                
                    2 KLayout density errors found.                             
                    83777 KLayout DRC errors found.                             
EOF
} > "$T/fail.log"
run "$T/fail.log"
want_exit 1 "B: exit code is 1"
want "$T/out.json" result '"fail"' "B: result is fail"
want "$T/out.json" summary.blocking_failed '["density", "klayout_drc"]' "B: the two blocking gates"
want "$T/out.json" gates.0.status '"fail"' "B: density gate fails"
want "$T/out.json" gates.0.count 2 "B: density counted 2"
want "$T/out.json" gates.1.status '"pass"' "B: zero-area gate passes"
want "$T/out.json" gates.2.status '"pass"' "B: antenna gate passes"
want "$T/out.json" gates.3.status '"warn"' "B: Magic DRC is a warning, not a gate"
want "$T/out.json" gates.3.blocking 'false' "B: Magic DRC marked non-blocking"
want "$T/out.json" gates.4.count 83777 "B: KLayout DRC counted 83777"
want "$T/out.json" failure.mode '"deferred"' "B: failure classified as deferred"
want "$T/out.json" failure.items.1.gate '"klayout_drc"' "B: deferred item mapped to its gate"
want "$T/out.json" skipped_steps '["Check Pad Mask"]' "B: the skipped step is recorded"
want "$T/out.json" summary.stages_missing '[]' "B: the scan measured every stage"
# the skipped step sits where the flow would have run it: stage 4, between Slot Size and
# Generate ID
want "$T/out.json" stages.3.status '"skipped"' "B: the skipped stage is marked skipped"
want "$T/out.json" stages.3.name '"Check Pad Mask"' "B: the skipped stage keeps its name"
want "$T/out.json" run.clock_end '"11:12:25"' "B: the run's last timestamp is parsed"
"$PY" - "$T/out.json" <<'PY' && ok "B: wrapped lines were re-joined" || bad "B: no wrapped lines rejoined"
import json, sys
doc = json.load(open(sys.argv[1]))
sys.exit(0 if doc["run"]["wrapped_lines_rejoined"] >= 5 else 1)
PY
"$PY" - "$T/out.json" <<'PY' && ok "B: duration across midnight is positive" || bad "B: wall clock across midnight wrong"
import json, sys
doc = json.load(open(sys.argv[1]))
sys.exit(0 if doc["run"]["wall_seconds"] and doc["run"]["wall_seconds"] > 9 * 3600 else 1)
PY

# ================================================================ C: a hard abort (stage 2)
echo "== C: the first attempt's failure -- top-level name mismatch aborts the flow"
{
    cat <<'EOF'
[22:36:44] INFO     PDK_ROOT = /workspace/gf180mcu               precheck.py:501
[22:36:44] INFO     PDK = gf180mcuD                              precheck.py:502
[22:36:44] INFO     top_cell: chip_top_template                  precheck.py:507
[22:36:44] INFO     die_id: GRX93001                             precheck.py:508
[22:36:44] INFO     cob: True                                    precheck.py:509
[22:36:44] INFO     slot: 1x1                                    precheck.py:510
[22:36:44] INFO     threads: 4                                   precheck.py:511
[22:36:44] INFO     workers: 4                                   precheck.py:512
─────────────────────────────── Read the Layout ────────────────────────────────
[22:36:44] VERBOSE  Running 'KLayout.ReadLayout' at                 step.py:1138
[22:36:45] INFO     SHA256 for /host/chip_top_template.gds:    precheck.py:95
                    764c79babda6299b8ce9a7bf86662ca0c4459c6b404ff               
                    ab4783e94840e068605                                         
───────────────────────────── Check Top-Level Name ─────────────────────────────
[22:36:59] VERBOSE  Running 'KLayout.CheckTopLevel' at              step.py:1138
[Error] Top-level cell name 'chip_top' does not match expected name             
'chip_top_template'!                                                            
[22:37:02] ERROR    Subprocess had a non-zero exit.                 step.py:1383
[22:37:02] ERROR    Last 1 line(s):                                 step.py:1388
                    [Error] Top-level cell name 'chip_top' does not             
                    match expected name 'chip_top_template'!                    
PrecheckFlow' - Stage 2 - Check Top-Level Name ━                    1/17 0:00:17
[22:37:02] ERROR    The precheck failed with the following       precheck.py:618
                    exception:                                                  
                    Check Top-Level Name: subprocess (1,                        
                    ['/nix/store/5pg1p37fxc5pyi40lfgay9s953yp3qd                
                    h-devshell-dir/bin/python3',                                
                    '/workspace/scripts/klayout/check_top.py',                   
                    '/workspace/runs/RUN_2026-10-15_22-36-44/01-               
                    klayout-readlayout/chip_top_template.gds',                   
                    '--top', 'chip_top_template']) failed                       
EOF
} > "$T/abort.log"
run "$T/abort.log"
want_exit 2 "C: exit code is 2 (incomplete, not a gate failure)"
want "$T/out.json" result '"incomplete"' "C: result is incomplete"
want "$T/out.json" failure.mode '"hard"' "C: failure classified as a hard abort"
want "$T/out.json" failure.stage '"Check Top-Level Name"' "C: the stage that aborted is named"
want "$T/out.json" failure.rc 1 "C: subprocess return code captured"
want "$T/out.json" stages.1.status '"fail"' "C: stage 2 marked failed"
want "$T/out.json" summary.blocking_failed '[]' "C: no gate failed -- it never got there"
"$PY" - "$T/out.json" <<'PY' && ok "C: the stages it never reached are listed missing" || bad "C: missing stages not reported"
import json, sys
doc = json.load(open(sys.argv[1]))
missing = doc["summary"]["stages_missing"]
sys.exit(0 if "Design Rule Check (KLayout)" in missing and "Density Check" in missing else 1)
PY

# ================================================================ D: a hard abort at the mask
echo "== D: the pad-mask abort (the CoB gate every submission passes through)"
{
    preamble
    cat <<'EOF'
─────────────────────────────── Read the Layout ────────────────────────────────
[18:36:10] VERBOSE  Running 'KLayout.ReadLayout' at                 step.py:1138
───────────────────────────── Check Top-Level Name ─────────────────────────────
[18:36:40] VERBOSE  Running 'KLayout.CheckTopLevel' at              step.py:1138
─────────────────────────────── Check Slot Size ────────────────────────────────
[18:36:55] VERBOSE  Running 'KLayout.CheckSize' at                  step.py:1138
───────────────────────────────── Check Pad Mask ───────────────────────────────
[18:37:04] VERBOSE  Running 'KLayout.CheckPadMask' at               step.py:1138
PrecheckFlow' - Stage 4 - Check Pad Mask ━                          3/17 0:00:54
[18:46:02] ERROR    The precheck failed with the following       precheck.py:618
                    exception:                                                  
                    Check Pad Mask: subprocess (1,                              
                    ['/nix/store/5pg1p37fxc5pyi40lfgay9s953yp3qd                
                    h-devshell-dir/bin/python3', ...                            
                    'output=/workspace/runs/run1/04-klayout-chec                
                    kpadmask/masked.gds']) failed                                
EOF
} > "$T/mask.log"
run "$T/mask.log"
want_exit 2 "D: exit code is 2"
want "$T/out.json" failure.stage '"Check Pad Mask"' "D: the mask stage is named"
want "$T/out.json" stages.3.status '"fail"' "D: the mask stage is marked failed"

# ================================================================ E: not a precheck log
echo "== E: a log with no stages is 'unparsed', never a silent pass"
printf 'hello\nthis is not a precheck log\n' > "$T/nothing.log"
run "$T/nothing.log"
want_exit 3 "E: exit code is 3 (no verdict)"
want "$T/out.json" result '"unparsed"' "E: result is unparsed"

# ================================================================ F: run-dir mode
echo "== F: --run-dir picks up the step metrics and the per-rule report tallies"
# the DRC report deliberately sits outside reports/ -- that is how it comes back when a wrapper
# did not copy reports/ out of the container and it had to be recovered by hand
mkdir -p "$T/run/06-klayout-density/reports" "$T/run/drc_peek"
cat > "$T/run/flow.log" <<'EOF'
SHA256 for /host/run1/chip_top.gds: 764c79babda6299b8ce9a7bf86662ca0c4459c6b404ffab4783e94840e068605
Running 'KLayout.Density' at 'runs/run2/06-klayout-density'…
Skipping step 'Check Pad Mask'…
Running 'KLayout.DRC' at 'runs/run2/14-klayout-drc'…
EOF
cat > "$T/run/06-klayout-density/state_in.json" <<'EOF'
{"gds": "/workspace/runs/run2/04-klayout-generateid/chip_top.gds",
 "metrics": {"klayout__density_error__count": 2, "klayout__zero_area_polygons__count": 0,
             "klayout__antenna_error__count": 0, "magic__drc_error__count": 12772}}
EOF
cat > "$T/run/06-klayout-density/reports/density.klayout.json" <<'EOF'
{"DCF.1b": 1, "PL.8": 1, "total": 2}
EOF
cat > "$T/run/drc_peek/drc.klayout.json" <<'EOF'
{"metal1_OFFGRID": 22418, "contact_OFFGRID": 22268, "total": 83777}
EOF
# discovery: no --log, the run dir's own precheck_ws.log is found
run_dir_only() {
    "$PY" "$TOOL" --run-dir "$1" --quiet > "$T/out.json" 2>"$T/err.txt"
    RC=$?
}
cp "$T/fail.log" "$T/run/precheck_ws.log"
run_dir_only "$T/run"
want_exit 1 "F: exit code is 1"
want "$T/out.json" metrics.klayout__density_error__count 2 "F: step metrics read"
want "$T/out.json" metrics.magic__drc_error__count 12772 "F: Magic metric read"
want "$T/out.json" gates.0.rules_total 2 "F: density rule tally summed"
want "$T/out.json" gates.4.rules.metal1_OFFGRID 22418 "F: top DRC rule tally read"
want "$T/out.json" gates.4.rules_count 2 "F: DRC rule count"
want "$T/out.json" reports.1.total 83777 "F: a report outside reports/ is still listed"
want "$T/out.json" reports.1.gate '"klayout_drc"' "F: the recovered report is attributed"
# the flow logs the step's display name here, not its id -- checked against the real flow.log
want "$T/out.json" summary.flow_skips_seen '["Check Pad Mask"]' "F: flow.log skips read"
want "$T/out.json" summary.gates.density '"fail"' "F: gate statuses summarised"
# the tally here is a 3-key slice (2 OFFGRID rules + total), not a complete one: 44,686 of the
# 83,777 items are attributed and the rest must stay blocking, because an unattributed item is one
# the split cannot vouch for
want "$T/out.json" gates.4.status '"fail"' "F: a truncated tally stays conservative"
want "$T/out.json" gates.4.advisory_count 44686 "F: the advisory share is still counted"
want "$T/out.json" gates.4.blocking_count 39091 "F: the unattributed rest still blocks"

# ================================================================ G: --expect (CI usage)
echo "== G: --expect turns the verdict into an assertion"
"$PY" "$TOOL" --log "$T/fail.log" --quiet --expect fail > /dev/null 2>&1; RC=$?
want_exit 0 "G: --expect fail matches the parsed verdict"
"$PY" "$TOOL" --log "$T/fail.log" --quiet --expect pass > /dev/null 2>&1; RC=$?
want_exit 1 "G: --expect pass against a failure exits 1"
"$PY" "$TOOL" --log "$T/pass.log" --quiet --expect pass > /dev/null 2>&1; RC=$?
want_exit 0 "G: --expect pass matches a clean run"

# ================================================================ H: the advisory rule family
echo "== H: the advisory *_OFFGRID family warns; the rules that are not it still block"
# What separates this from F is *completeness*: these tallies' rules sum to their own total, which
# is what makes the split exact rather than a lower bound. The numbers are the measured ones --
# 22,418 metal1_OFFGRID + 22,268 contact_OFFGRID, and 1,265 M1.2a (the largest non-OFFGRID rule in
# the real run2 report) -- so the fixtures check the values the run printed rather than round ones.
#
# The log is the real run2 shape with the density failure taken out, so the only deferred item left
# is the DRC count; that is the case where the reclassification decides the verdict by itself.
# DRC count in the log must equal the tally total, or the tally is partial and F's rule applies.
mkdrc_log() {  # mkdrc_log <dir> <drc-total>
    mkdir -p "$1/drc_peek"
    # the count appears twice -- on the checker's own verdict line and again inside the deferred
    # block the flow prints at the end -- and both have to move together, or the fixture describes
    # two different runs
    sed -e 's/^\[00:02:03\] ERROR    2 KLayout density errors found\. - deferred/[00:02:03] INFO     Check for KLayout density clear./' \
        -e '/^ *2 KLayout density errors found\. *$/d' \
        -e "s/^\(\[11:12:10\] ERROR    \)[0-9]*\( KLayout DRC errors found\. - deferred\)/\1$2\2/" \
        -e "s/^ *[0-9]* KLayout DRC errors found\. *$/$2 KLayout DRC errors found./" \
        "$T/fail.log" > "$1/precheck_ws.log"
}
mkdrc_log "$T/run_h" 44686
cat > "$T/run_h/drc_peek/drc.klayout.json" <<'EOF'
{"metal1_OFFGRID": 22418, "contact_OFFGRID": 22268, "total": 44686}
EOF
run_dir_only "$T/run_h"
want_exit 0 "H: a DRC gate whose whole count is advisory does not fail the run"
want "$T/out.json" result '"pass"' "H: result is pass"
want "$T/out.json" summary.blocking_failed '[]' "H: no blocking gate failed"
want "$T/out.json" gates.4.status '"warn"' "H: the DRC gate is a warning"
want "$T/out.json" gates.4.advisory_count 44686 "H: the advisory share is reported"
want "$T/out.json" gates.4.blocking_count 0 "H: nothing left blocking"
want "$T/out.json" summary.gates.klayout_drc '"warn"' "H: the summary agrees"
# the flow's own exception is still in the JSON: the reclassification reinterprets it, it does not
# erase it
want "$T/out.json" failure.mode '"deferred"' "H: the raw failure block is kept"
"$PY" - "$T/out.json" <<'PY' && ok "H: the warning names the family and the count" || bad "H: no warning emitted"
import json, sys
doc = json.load(open(sys.argv[1]))
sys.exit(0 if any("OFFGRID" in w and "44686" in w for w in doc["summary"]["warnings"]) else 1)
PY
# ...and one real rule in the same tally puts it straight back to blocking
mkdrc_log "$T/run_h2" 45951
cat > "$T/run_h2/drc_peek/drc.klayout.json" <<'EOF'
{"metal1_OFFGRID": 22418, "contact_OFFGRID": 22268, "M1.2a": 1265, "total": 45951}
EOF
run_dir_only "$T/run_h2"
want_exit 1 "H2: a real rule alongside the advisory family still fails the run"
want "$T/out.json" result '"fail"' "H2: result is fail"
want "$T/out.json" summary.blocking_failed '["klayout_drc"]' "H2: the DRC gate blocks again"
want "$T/out.json" gates.4.status '"fail"' "H2: the DRC gate is a failure"
want "$T/out.json" gates.4.advisory_count 44686 "H2: the advisory share is unchanged"
want "$T/out.json" gates.4.blocking_count 1265 "H2: only the real rule blocks"
want "$T/out.json" gates.4.rules_attributed 45951 "H2: the tally is complete"

# ================================================================ I: no tally, no reclassification
echo "== I: without a tally the log's own count decides (no silent warning)"
run "$T/fail.log"
want "$T/out.json" gates.4.status '"fail"' "I: the DRC gate still fails from the log alone"
want "$T/out.json" gates.4.blocking_count 83777 "I: the whole count stays blocking"
want "$T/out.json" gates.4.advisory_count 'null' "I: nothing is claimed as advisory"
want "$T/out.json" summary.warnings '[]' "I: no warning is invented"

echo
printf 'precheck_verdict_selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
