#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lln_fanout_split_selftest.sh -- what the fanout patch has to get right, checked
# against fixtures instead of a flow run.
#
#   bash ws/tools/lln_fanout_split_selftest.sh
#
# WHY IT EXISTS
#
#   The patch's failure mode is silent. If the image's rsz_timing_postcts.tcl
#   moves its `# Legalize` block, the patcher reports missing-preimage, the flow
#   runs anyway, every net keeps the fanout repair_timing gave it, and the arm
#   that was supposed to answer "does the short count fall once fanout is bounded"
#   answers "no" for a reason that has nothing to do with fanout. So the anchor,
#   the insertion point, the idempotence and the exit codes are all asserted here,
#   where the answer is cheap; the flow run is the thing the harness cannot prove.
#
#   No container and no LibreLane: the fixtures are the two shapes of the step's
#   tcl that matter (a pre-image that matches, one that does not), written under a
#   mktemp tree. LLN_FANOUT_TCL points the patcher at a file and
#   LLN_FANOUT_STORE_GLOB at a glob, which is what makes this runnable anywhere.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH="$HERE/librelane_fanout_split_patch.py"
WRAP="$HERE/lln_fanout_split.sh"

PYP=$(command -v python3 2>/dev/null || true)
if [ -z "${PYP:-}" ]; then
    echo "FANOUT_SPLIT_SELFTEST BLOCKED no python3 on PATH"
    exit 2
fi
for f in "$PATCH" "$WRAP"; do
    [ -f "$f" ] || { echo "FANOUT_SPLIT_SELFTEST BLOCKED missing $f"; exit 2; }
done

TMP=$(mktemp -d) || { echo "FANOUT_SPLIT_SELFTEST BLOCKED no mktemp"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FANOUT_SPLIT_SELFTEST FAIL $*"; }
check() {  # name, rc -- 0 counts a pass
    if [ "$2" = 0 ]; then ok; else bad "$1"; fi
}

# ---- fixtures ---------------------------------------------------------------
# The shape of the real step: repair_timing's if/else, then the legalize the
# insertion has to land before.
cat > "$TMP/rsz.tcl" <<'EOF'
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/resizer.tcl

read_current_odb

if { $::env(PL_RESIZER_FIX_HOLD_FIRST) == 1 } {
    log_cmd repair_timing {*}$hold_args
    log_cmd repair_timing {*}$setup_args
} else {
    log_cmd repair_timing {*}$setup_args
    log_cmd repair_timing {*}$hold_args
}

# Legalize
source $::env(SCRIPTS_DIR)/openroad/common/dpl.tcl

unset_dont_touch_objects

write_views
EOF

# A tcl with the same name but no `# Legalize` block: the image moved under the
# patch, and the only safe answer is missing-preimage.
sed '/^# Legalize$/d' "$TMP/rsz.tcl" > "$TMP/rsz_moved.tcl"

run_patch() {  # tcl-path -> writes $TMP/out and returns the patcher's rc
    LLN_FANOUT_TCL="$1" "$PYP" "$PATCH" > "$TMP/out" 2>&1
    return $?
}

# ---- 1. the anchor is the step's own legalize, and it applies once -----------
run_patch "$TMP/rsz.tcl"
check "apply: exit 0" $?
grep -q 'status=applied' "$TMP/out"; check "apply: status=applied" $?
[ "$(grep -c 'ws fanout split' "$TMP/rsz.tcl")" = 1 ]; check "apply: one marker" $?
[ "$(grep -c 'log_cmd repair_design' "$TMP/rsz.tcl")" = 1 ]; check "apply: one repair_design call" $?
grep -q 'WS_FANOUT_SPLIT' "$TMP/rsz.tcl"; check "apply: pass is opt-in" $?
grep -q 'set_max_transition $::env(MAX_TRANSITION_CONSTRAINT)' "$TMP/rsz.tcl"; check "apply: real slew limit restored" $?
grep -q 'set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT)' "$TMP/rsz.tcl"; check "apply: real cap limit restored" $?
grep -q 'ws_fanout_tail' "$TMP/rsz.tcl"; check "apply: tail measured, not assumed" $?
grep -q 'log_cmd repair_timing' "$TMP/rsz.tcl"; check "apply: step's own repair_timing kept" $?

# The insertion has to be before the legalize, or its buffers are never placed.
MARK_LINE=$(grep -n 'ws fanout split' "$TMP/rsz.tcl" | cut -d: -f1)
DPL_LINE=$(grep -n 'common/dpl.tcl' "$TMP/rsz.tcl" | cut -d: -f1)
[ -n "${MARK_LINE:-}" ] && [ -n "${DPL_LINE:-}" ] && [ "$MARK_LINE" -lt "$DPL_LINE" ]
check "apply: before the legalize" $?

# ---- 2. idempotence ---------------------------------------------------------
BEFORE=$(cksum < "$TMP/rsz.tcl")
run_patch "$TMP/rsz.tcl"
check "rerun: exit 0" $?
grep -q 'status=already-patched' "$TMP/out"; check "rerun: status=already-patched" $?
[ "$(cksum < "$TMP/rsz.tcl")" = "$BEFORE" ]; check "rerun: file unchanged" $?

# ---- 3. every way it can fail to land ---------------------------------------
run_patch "$TMP/rsz_moved.tcl"
[ $? = 2 ]; check "moved anchor: exit 2" $?
grep -q 'status=missing-preimage' "$TMP/out"; check "moved anchor: status=missing-preimage" $?
grep -q 'ws fanout split' "$TMP/rsz_moved.tcl" && bad "moved anchor: file was still edited" || ok

run_patch "$TMP/does_not_exist.tcl"
[ $? = 2 ]; check "missing file: exit 2" $?
grep -q 'status=unreadable' "$TMP/out"; check "missing file: status=unreadable" $?

LLN_FANOUT_STORE_GLOB="$TMP/no-such-store/*/rsz_timing_postcts.tcl" \
    "$PYP" "$PATCH" > "$TMP/out" 2>&1
[ $? = 2 ]; check "no candidate: exit 2" $?
grep -q 'status=not-found' "$TMP/out"; check "no candidate: status=not-found" $?

if [ "$(id -u)" != 0 ]; then
    # pristine copy of the pre-image, then unwritable: the patcher must say
    # read-only rather than report a success it did not get
    cat > "$TMP/rsz_ro.tcl" <<'EOF'
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl

# Legalize
source $::env(SCRIPTS_DIR)/openroad/common/dpl.tcl

write_views
EOF
    chmod 444 "$TMP/rsz_ro.tcl"
    run_patch "$TMP/rsz_ro.tcl"
    [ $? = 2 ]; check "read-only: exit 2" $?
    grep -q 'status=read-only' "$TMP/out"; check "read-only: status=read-only" $?
    chmod 644 "$TMP/rsz_ro.tcl"
else
    echo "FANOUT_SPLIT_SELFTEST note: running as root, the read-only case cannot fail -- skipped"
    ok
    ok
fi

# ---- 4. the pieces the flow actually sources -------------------------------
"$PYP" -m py_compile "$PATCH" 2>/dev/null; check "patcher: compiles" $?
sh -n "$WRAP" 2>/dev/null; check "wrapper: valid sh" $?
grep -q 'librelane_fanout_split_patch.py' "$WRAP"; check "wrapper: names the patcher" $?
grep -q 'WS_FANOUT_SPLIT' "$WRAP"; check "wrapper: says the pass is opt-in" $?
grep -q 'command -v python3' "$WRAP"; check "wrapper: same interpreter lookup as the reset patch" $?
grep -q 'status=no-python' "$WRAP"; check "wrapper: no-python is reported, not silent" $?
bash -n "$HERE/lln_fanout_split_selftest.sh" 2>/dev/null; check "selftest: valid bash" $?

# ---- verdict ---------------------------------------------------------------
if [ "$fail" = 0 ]; then
    echo "FANOUT_SPLIT_SELFTEST pass=$pass fail=0"
    exit 0
fi
echo "FANOUT_SPLIT_SELFTEST pass=$pass fail=$fail"
exit 1
