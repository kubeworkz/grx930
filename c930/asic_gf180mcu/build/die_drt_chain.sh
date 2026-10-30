#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# die_drt_chain.sh -- host side: measure the DIE's own detailed-routing cost at
# the landed GRT_ADJUSTMENT (0.1) in the fast DRT loop, so the price the landing
# comment pays stops being an extrapolation from the slot core.
#
# The question it answers: the overrides file pays for 0.1 with "the DRT half of
# the sweep" -- 344,494 violations at 0.1 against 0.2's 254,201, both measured on
# the SLOT CORE (12.93 mm2, no pad ring). The layout that ships is the die
# (pad ring, 332,661 cells, 243,780 routed nets), and that price was the one
# number the landing could not quote for it. There is also no die-side 0.2 to
# subtract: GRT at 0.2 aborts on this layout (GRT-0183, deterministic), so 0.1 is
# the only arm that reaches DRT and this is its number, not a delta.
#
# Phase A: the pre-DRT database. die_predrt_exec.sh resumes ws_v3's frozen
#          step-36 state into a FRESH run tag and runs the Chip flow from
#          GlobalRouting to STAMidPNR-3 with the staged configs. The chain then
#          reads the ODB path out of the last step's state_out.json -- literally
#          the database DetailedRouting would read -- and gates on the GRT step's
#          own log naming "Global adjustment: 10%", so a silently different knob
#          can never be launched into hours of DRT.
# Phase B: the fast DRT loop. drt_fast/run_drt.sh with the same six arguments
#          every sweep arm used (2 iterations, Metal1-Metal5, 8 threads,
#          -or_seed 42), in the pre-check image -- the image that wrote the
#          database and runs the flow's own DRT step.
#
#   nohup bash build/die_drt_chain.sh > /dev/null 2>&1 &
#   tail -f ws/logs/die_drt_chain.log
set -u
ROOT=/home/ubuntu/grx930_ol2
B=$ROOT/build
WS=$ROOT/ws
D=$ROOT/drt_fast
IMG=ghcr.io/wafer-space/gf180mcu-precheck
TAG=${DIE_TAG:-die01}
PREDRT_OVERRIDE=${DIE_PREDRT_OVERRIDE:-}
# The engine arm: PREDRT_OR swaps the OpenROAD every step runs (LibreLane's
# _LLN_OVERRIDE_OPENROAD hook), PREDRT_STOP moves the stopping point, and
# DIE_PHASE_A_ONLY stops this chain after the pre-DRT database is recorded --
# used by the engine-pin arm, where the thing being tested is the flow getting
# past the antenna repair and into the router, not the fast DRT loop.
PREDRT_OR=${PREDRT_OR:-}
PREDRT_STOP=${PREDRT_STOP:-}
# PREDRT_PATCH_LLN=1023 asks the container to backport LibreLane #1023 before the
# flow starts (ws/tools/librelane_1023_io_patch.py). The engine pin needs it: with
# the 26Q4 build in place, step 01 COMPLETES and then dies in its own finalization
# with `[ERROR STA-0107] ..._p_Scene is not the name of a scene` (measured: run
# diepin02, 2026-10-14 01:48, whose run tree stops at 01-openroad-globalrouting).
# Without this forwarding, that arm cannot be expressed through this chain at all.
PREDRT_PATCH_LLN=${PREDRT_PATCH_LLN:-}
PHASE_A_ONLY=${DIE_PHASE_A_ONLY:-0}
PREDRT_MIN_GB=${PREDRT_MIN_GB:-12}
TARGET_ADJ=${DIE_ADJ_EXPECT:-Global adjustment: 10%}
RUN=$ROOT/ws/template/librelane/runs/$TAG
LOG=$WS/logs/die_drt_chain.log
PREDRT_CLOG=$WS/logs/predrt_$TAG.container.log
DRT_LOG=$D/logs/${TAG}_drt.log
OUT=$D/verdict/die_drt_at01.md
WATCH_OUTDIR=$D/verdict/${TAG}_watch
say() { echo "[$(date -u)] $*" | tee -a "$LOG"; }
ps_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }

# The arm's own decision point, for a chain that launched it detached. The line is
# written the moment the container is up (below) and `EXIT rc=..` at exit, so a
# parent can tell "not launched yet" from "refused" without reading this log against
# a clock -- that difference is what decides whether a second arm may be started.
# Unset when the chain is run by hand; then this writes nothing.
ARM_STATE=${DIE_ARM_STATE:-}
arm_state() {  # $1 = one line, e.g. "LAUNCHED tag=died26q4"
    [ -n "$ARM_STATE" ] || return 0
    # Append to the marker itself, never through a temp-and-mv: the move consumes
    # the temp, so the second call (the EXIT trap) would replace the file and drop
    # the LAUNCHED line the parent is waiting for. A short append is one write; a
    # half-written line simply does not match until the next poll.
    printf '%s\n' "$1" >> "$ARM_STATE" 2>/dev/null || true
}

# One EXIT handler, because bash keeps only one per signal: the disk guard is
# stopped on every way out of this chain -- the phase-A failure paths, the GRT
# gate refusal, DIE_PHASE_A_ONLY, and the normal end -- while the arm's decision
# marker is still written for the parent that launched it.
on_exit() {
    local rc=$?
    curve_guard_stop "$TAG" >/dev/null 2>&1 || true
    disk_guard_stop "$TAG" >/dev/null 2>&1 || true
    if [ -n "${ARM_STATE:-}" ]; then arm_state "EXIT rc=$rc"; fi
    # `exit`, not `return`: the last statement of a function is not the chain's
    # exit status, and an arm that failed must not report rc=0 because the marker
    # line happened to succeed.
    exit "$rc"
}
trap on_exit EXIT

. "$B/gate.sh"        # free_gb + the disk/memory gate, defined once for every chain
. "$B/disk_guard.sh"  # start/stop the DRT disk guard (DISK_GUARD=0 disables both)
. "$B/curve_guard.sh" # start/stop the DRT wall-clock + regression guard

# The same readings the sweep chain harvests with, so the numbers are the same
# numbers: `Completing 100% with` is the per-iteration summary (initial route
# first), `DRT-0199` is the router's own post-iteration total (the value every
# table so far has quoted), DRT-0267 is the peak-memory record.
finals()   { grep -aE "Completing 100% with" "$1" 2>/dev/null | grep -oE '[0-9]+ violations' | grep -oE '[0-9]+'; }
total_viol(){ grep -aE '^\[INFO DRT-0199\]' "$1" 2>/dev/null | grep -oE '= [0-9]+' | grep -oE '[0-9]+' | tail -1; }
peak_mem() { grep -aE '^\[INFO DRT-0267\]' "$1" 2>/dev/null | grep -oE 'peak = [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1; }
tot_of()   { grep -aoE '^Total +[0-9]+ +[0-9]+ +[0-9.]+% +[0-9]+ / +[0-9]+ / +[0-9]+' | tail -1 | grep -oE '[0-9]+$'; }
wall_of() {
    local s e ds de
    s=$(grep -aE '^RUN_START' "$1" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1)
    e=$(grep -aE '^RUN_END'   "$1" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1)
    [ -n "${s:-}" ] && [ -n "${e:-}" ] || { printf '?'; return; }
    ds=$(date -u -d "$s" +%s 2>/dev/null); de=$(date -u -d "$e" +%s 2>/dev/null)
    [ -n "${ds:-}" ] && [ -n "${de:-}" ] || { printf '?'; return; }
    printf '%d:%02d:%02d' $(( (de-ds)/3600 )) $(( ((de-ds)%3600)/60 )) $(( (de-ds)%60 ))
}
commas() {
    local n=${1:-} o=''
    [ "$n" -eq "$n" ] 2>/dev/null || { printf '%s' "$n"; return; }
    while [ ${#n} -gt 3 ]; do o=",${n: -3}$o"; n="${n%???}"; done
    printf '%s' "$n$o"
}
mb_of() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b/1048576 }'; }

say "DIE_DRT_CHAIN_START tag=$TAG target='$TARGET_ADJ' override='${PREDRT_OVERRIDE:-none}'"
say "CONFIG_SHA256 $(sha256sum "$ROOT/ws/template/librelane/grx930_overrides.yaml" 2>/dev/null | awk '{print $1}')"
say "DISK_GB_FREE $(free_gb /)"

# One job at a time is the whole reason this is a chain and not two commands:
# the box (8 cores / 15 GB) cannot carry two routers, and this design has an OOM
# in its history. Nothing running is a precondition, not a preference.
# The gate above is the safety mechanism (memwatch's preflight against this job's
# measured need); the busy check is policy on top of it. DIE_ALLOW_CONCURRENT=1
# relaxes only the policy, and says what it ran alongside, for the case where the
# other container is a measured-light job -- e.g. the antenna-repair probe, which
# peaks at 2 GiB RSS on one core, against a box with ~14 GB available.
if [ -n "$(docker ps --format '{{.Names}}')" ] && [ "${DIE_ALLOW_CONCURRENT:-0}" != 1 ]; then
    say "BUSY_OTHER_CONTAINER $(docker ps --format '{{.Names}}' | tr '\n' ' ') -- refusing"
    exit 1
fi
[ "${DIE_ALLOW_CONCURRENT:-0}" = 1 ] && say "CONCURRENT_ALLOWED running alongside: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"

# ---------------------------------------------------------------- phase A ---
# DIE_ODB_C skips phase A and uses an already-produced pre-DRT database (e.g.
# when only phase B failed, or when the driver itself was the thing to fix): the
# GRT gate below still runs against the run tree that database came from.
PREDRT_SKIPPED=0
if [ -n "${DIE_ODB_C:-}" ]; then
    PREDRT_SKIPPED=1
    A0=0
    A1=0
    say "PHASE_A_SKIPPED (DIE_ODB_C given) db=$DIE_ODB_C"
else
gate 9000 die_predrt "$PREDRT_MIN_GB" / || { say "ABORT_$GATE_REASON"; exit 1; }
docker rm -f die_predrt >/dev/null 2>&1
docker run -d --name die_predrt --user 0:0 -e HOME=/root -v "$ROOT:/work" \
    -e PREDRT_TAG="$TAG" -e PREDRT_OVERRIDE="$PREDRT_OVERRIDE" \
    -e PREDRT_OR="$PREDRT_OR" -e PREDRT_STOP="$PREDRT_STOP" \
    -e PREDRT_PATCH_LLN="$PREDRT_PATCH_LLN" \
    $IMG /work/ws/die_predrt_exec.sh >/dev/null
if [ "$(ps_running die_predrt)" != "true" ]; then
    say "PREDRT_NOT_RUNNING $(docker inspect -f 'status={{.State.Status}} rc={{.State.ExitCode}}' die_predrt 2>&1 | head -1)"
fi
A0=$(date -u +%s)
say "PREDRT_LAUNCHED tag=$TAG"
arm_state "LAUNCHED tag=$TAG container=die_predrt"
# Guarded from the moment the container is up, not from the moment step 06
# appears: the step dir is hours away and the guard resolves it per poll, so it
# is already watching when the antenna-repair loop starts writing route databases.
disk_guard_start "$TAG" die_predrt
# Phase A is where the DIE's flow arm runs DetailedRouting when PREDRT_STOP is set
# to it (die_diode_flow_chain.sh launches this chain that way), so the curve guard
# bounds that pass too. On an arm that stops before routing it never arms: it
# acts only after the log has shown a DRT-0195.
curve_guard_start "$TAG" die_predrt
while [ "$(ps_running die_predrt)" = "true" ]; do sleep 60; done
A1=$(date -u +%s)
RC=$(docker inspect -f '{{.State.ExitCode}}' die_predrt 2>/dev/null)
# The container is gone, so the guard has nothing left to bound; stop it before
# the harvest and report the one line it left (none when the arm stopped before
# the router started).
curve_guard_stop "$TAG"
say "DRT_CURVE_GUARD $(curve_guard_verdict "$TAG")"
docker logs die_predrt > "$PREDRT_CLOG" 2>&1
say "PREDRT_EXIT rc=$RC"
if [ "$RC" != 0 ]; then
    say "PREDRT_FAILED rc=$RC -- no DRT"
    grep -aE "ERROR|Error:|error:" "$PREDRT_CLOG" | tail -8 | tee -a "$LOG"
    exit 1
fi
fi

# The GRT gate: what the step actually resolved, not what the file said it would.
GRT_DIR=$(ls -1d "$RUN"/*-openroad-globalrouting 2>/dev/null | head -1)
ACT=$(grep -ahoE 'Global adjustment: [0-9]+%' "$GRT_DIR"/*.log 2>/dev/null | tail -1)
say "GRT adj=${ACT:-none} step=$(basename "${GRT_DIR:-none}")"
if [ "${ACT:-}" != "$TARGET_ADJ" ]; then
    say "GRT_GATE_FAIL wanted '$TARGET_ADJ' got '${ACT:-none}' -- DRT skipped, this arm would be a different datum"
    exit 1
fi
# The flow's own record of the arm: the variable the composite is gated by.
RUN_ANT=$(grep -o '"RUN_ANTENNA_REPAIR": [a-z]*' "$RUN/resolved.json" 2>/dev/null | head -1 | grep -o '[a-z]*$')
say "RESOLVED RUN_ANTENNA_REPAIR=${RUN_ANT:-none}"
GRT_ITERS=$(grep -acE 'Start extra iteration' "$GRT_DIR"/*.log 2>/dev/null | head -1)
GRT_WIRE=$(grep -ahoE 'Total wirelength: [0-9]+' "$GRT_DIR"/*.log 2>/dev/null | grep -oE '[0-9]+' | head -1)
GRT_OVL=$(grep -ah -A9 'Final congestion report' "$GRT_DIR"/*.log 2>/dev/null | tot_of)
grep -aE 'Start extra iteration|GRT-0183|GRT-0115|Total wirelength|Global routing runtime' "$GRT_DIR"/*.log 2>/dev/null | tail -5 | tee -a "$LOG"
grep -ah -A9 'Final congestion report' "$GRT_DIR"/*.log 2>/dev/null | tail -9 | tee -a "$LOG"
say "GRT_READOUT iters=$GRT_ITERS wire=$GRT_WIRE overflow=$GRT_OVL"

# The pre-DRT database: the ODB the last executed step's state_out names. This
# is the only path that must not be guessed -- DetailedRouting reads this exact
# file, and an STA step is a pass-through, so the state is how the flow itself
# records which ODB is current.
LAST_DIR=""
if [ -n "${DIE_ODB_C:-}" ]; then
    ODB_C=$DIE_ODB_C
else
    LAST_DIR=$(ls -1d "$RUN"/*-openroad-stamidpnr-3 2>/dev/null | head -1)
    [ -n "$LAST_DIR" ] || { say "NO_STA3_DIR -- cannot locate the pre-DRT database"; exit 1; }
    ODB_C=$(grep -o '"odb": "[^"]*"' "$LAST_DIR/state_out.json" 2>/dev/null | head -1 | cut -d'"' -f4)
fi
case "${ODB_C:-}" in
    *"/runs/$TAG/"*) ;;
    *) say "ODB_GATE_FAIL '${ODB_C:-none}' is not inside runs/$TAG"; exit 1 ;;
esac
ODB_H=$ROOT${ODB_C#/work}
[ -f "$ODB_H" ] || { say "ODB_MISSING $ODB_H"; exit 1; }
ODBSZ=$(stat -c %s "$ODB_H")
say "PRE_DRT_DB $ODB_C host=$ODB_H bytes=$ODBSZ mtime=$(date -u -d "@$(stat -c %Y "$ODB_H")" +%FT%TZ)"

if [ "$PHASE_A_ONLY" = 1 ]; then
    say "PHASE_A_ONLY_COMPLETE tag=$TAG outdb=$ODB_C or='${PREDRT_OR:-pinned}' stop='${PREDRT_STOP:-OpenROAD.STAMidPNR-3}'"
    say "STEPS $(ls -1 "$RUN" | tr '\n' ' ')"
    say "ANTENNA_REPAIR $(grep -aE 'Antenna Repair|GRT-0012|GRT-0015|GRT-0302' "$RUN"/*-openroad-repairantennas/*/*.log 2>/dev/null | tail -6 | tr '\n' '|')"
    say "DIE_DRT_CHAIN_COMPLETE (phase A only)"
    exit 0
fi

# ---------------------------------------------------------------- phase B ---
gate 10000 "drt_$TAG" 12 / || { say "ABORT_DRT_$GATE_REASON"; exit 1; }
docker rm -f "drt_$TAG" >/dev/null 2>&1
docker run -d --name "drt_$TAG" --user 0:0 -v "$ROOT:/work" \
    -e FAST_TAG="$TAG" -e FAST_ODB="$ODB_C" \
    -e FAST_END_ITER=2 -e FAST_MIN_LAYER=Metal1 -e FAST_MAX_LAYER=Metal5 -e FAST_THREADS=8 \
    $IMG /work/ws/die_drt_exec.sh >/dev/null
if [ "$(ps_running "drt_$TAG")" != "true" ]; then
    say "DRT_NOT_RUNNING $(docker inspect -f 'status={{.State.Status}} rc={{.State.ExitCode}}' "drt_$TAG" 2>&1 | head -1)"
fi
say "DRT_LAUNCHED name=drt_$TAG odb=$ODB_C"
while [ "$(ps_running "drt_$TAG")" = "true" ]; do sleep 60; done
RC=$(docker inspect -f '{{.State.ExitCode}}' "drt_$TAG" 2>/dev/null)
docker logs "drt_$TAG" > "$DRT_LOG" 2>&1
DRT_WALL=$(wall_of "$DRT_LOG")
DRT_FINAL=$(total_viol "$DRT_LOG")
say "DRT_EXIT rc=$RC wall=$DRT_WALL final=${DRT_FINAL:-?} log=$DRT_LOG"
if [ "$RC" != 0 ]; then
    say "DRT_FAILED rc=$RC -- no report written; router log $DRT_LOG"
    grep -aE "ERROR|Error:" "$DRT_LOG" | tail -8 | tee -a "$LOG"
    exit 1
fi
grep -aE 'Start [0-9]+(st|nd|rd|th) optimization iteration|Completing 100% with' "$DRT_LOG" | tail -6 | tee -a "$LOG"

# The tail verdict from the one instrument whose thresholds were set against v8,
# in log-only mode and its own output directory so it cannot overwrite another run's.
if [ -f "$WS/watch_drt_curve.sh" ]; then
    mkdir -p "$WATCH_OUTDIR"
    WATCH_OUT="$WATCH_OUTDIR" bash "$WS/watch_drt_curve.sh" --log "$DRT_LOG" --once \
        > "$WATCH_OUTDIR/watch.out" 2>&1
    say "DRT_VERDICT $(head -1 "$WATCH_OUTDIR/drt_verdict.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------- report ----
INIT=$(finals "$DRT_LOG" | sed -n 1p)
IT1=$(finals "$DRT_LOG" | sed -n 2p)
IT2=$(finals "$DRT_LOG" | sed -n 3p)
DRT_MEM=$(peak_mem "$DRT_LOG")
PREDRT_MIN=$(( (A1 - A0) / 60 ))
STEP_RUNTIMES=$(for d in "$RUN"/*/; do
    [ -f "$d/runtime.txt" ] || continue
    echo "| $(basename "$d") | $(cat "$d/runtime.txt") |"
done)
{
    echo "# The die's own DRT at GRT_ADJUSTMENT 0.1 — measured, 2 iterations"
    echo
    echo "Written $(date -u '+%F %T') UTC by \`build/die_drt_chain.sh\` (tag \`$TAG\`)."
    echo "It answers the one question the 0.1 landing left open: the overrides file pays"
    echo "for 0.1 with \"the DRT half of the sweep\" — 344,494 violations at 0.1 against"
    echo "0.2's 254,201 — but both of those were the **slot core**. The layout that ships"
    echo "is the die. There is no die-side 0.2 counterfactual to subtract: GRT at 0.2"
    echo "aborts on this layout (\`GRT-0183\`, deterministic), so 0.1 is the only arm that"
    echo "reaches routing and this is its number."
    echo
    echo "## The measurement"
    echo
    echo "* **Database** \`$ODB_C\` — host \`$ODB_H\`, $(mb_of "$ODBSZ") MB, written"
    echo "  $(date -u -d "@$(stat -c %Y "$ODB_H")" '+%F %T') UTC. This is the file the flow's"
    echo "  own \`OpenROAD.DetailedRouting\` step would read:"
    if [ -n "$LAST_DIR" ]; then
        echo "  the chain takes it from the \`state_out.json\` of the last executed pre-DRT"
        echo "  step (\`$(basename "$LAST_DIR")\`), where LibreLane records the current ODB."
    else
        echo "  it is the ODB the pre-DRT run tree records as current at its last pre-DRT"
        echo "  step, passed to this chain as \`DIE_ODB_C\` because only the DRT half was re-run."
    fi
    echo "* **Instrument** \`drt_fast/run_drt.sh\` → \`drt_fast/die_drt.tcl\`: 2 iterations,"
    echo "  \`-or_seed 42\`, 8 threads, Metal1–Metal5 — the same protocol the slot-core arms"
    echo "  ran, with the layer range stated via \`set_routing_layers\` because THIS build"
    echo "  answers the deprecated \`-bottom_routing_layer\` with \`[ERROR DRT-0509] ..."
    echo "  deprecated\` and aborts (measured on this chain's first attempt, 2026-10-13 23:01,"
    echo "  rc=1 after 2 s). \`set_routing_layers\` is the replacement DRT-0509 names and what"
    echo "  LibreLane's own GPL/GRT scripts do from RT_MIN_LAYER/RT_MAX_LAYER. The \`detailed_route\`"
    echo "  call itself is the flow's own (\`scripts/openroad/drt.tcl\`: no layer flags). Run in"
    echo "  \`ghcr.io/wafer-space/gf180mcu-precheck\` — the image that wrote the database and"
    echo "  that the flow's DRT step runs in, so the router build is not a variable either."
    echo "* **Pre-DRT arm** $(if [ -n "$PREDRT_OVERRIDE" ]; then echo "\`-c $PREDRT_OVERRIDE\` — the antenna-repair composite is skipped (see below); everything else is the staged config, and the run's resolved.json records \`RUN_ANTENNA_REPAIR: ${RUN_ANT:-?}\`"; else echo "the staged config, unmodified (\`RUN_ANTENNA_REPAIR: ${RUN_ANT:-?}\`)"; fi)."
    echo "* **GRT arm proof** (the chain refuses to launch DRT without it): the step's log"
    echo "  says \`$ACT\`, $GRT_ITERS extra iteration(s), overflow \`${GRT_OVL:-?}\`"
    echo "  (demand / max / total of the final congestion report), wire \`$GRT_WIRE\` µm."
    echo "  That is the landed file's own value, resolved by the flow."
    echo
    echo "| iteration | violations |"
    echo "|---|---|"
    echo "| initial route | $(commas "${INIT:-?}") |"
    echo "| iter 1 | $(commas "${IT1:-?}") |"
    echo "| **iter 2 (DRT-0199)** | **$(commas "${DRT_FINAL:-?}")** |"
    echo
    echo "* **Wall clock** \`RUN_START\` → \`RUN_END\`: $DRT_WALL; peak memory"
    echo "  $(commas "${DRT_MEM:-?}") MB; container exit rc=$RC."
    if [ -n "${IT2:-}" ] && [ "${IT2:-}" != "${DRT_FINAL:-}" ]; then
        echo "* Cross-check: the router's own \`Completing 100% with\` summary for the last"
        echo "  iteration reads $(commas "${IT2:-?}") — the \`DRT-0199\` value, $(commas "${DRT_FINAL:-?}"), is the one every"
        echo "  earlier table quotes (same 10-violation offset on the slot core)."
    fi
    echo "* **Violation report** \`drt_fast/out/$TAG/$TAG.drc\`, log \`drt_fast/logs/${TAG}_drt.log\`."
    if [ "$PREDRT_SKIPPED" = 1 ]; then
        echo "* **Phase A** was not re-run (\`DIE_ODB_C\` given); step runtimes as the flow"
        echo "  recorded them in \`runs/$TAG\`:"
    else
        echo "* **Phase A** (GRT → antenna repair → STA-3 on the frozen ws_v3 state) took"
        echo "  $PREDRT_MIN min; step runtimes as the flow recorded them:"
    fi
    echo
    echo "| step | runtime |"
    echo "|---|---|"
    printf '%s\n' "$STEP_RUNTIMES"
    echo
    echo
    if [ -n "$PREDRT_OVERRIDE" ]; then
        echo "## Why the pre-DRT database carries no antenna diodes"
        echo
        echo "The unmodified resume (tag \`die01\`, these same scripts, 2026-10-13) reaches"
        echo "GlobalRouting cleanly at 0.1 — 8 extra iterations, wire 39,459,512 µm, 0 overflow —"
        echo "and then dies inside \`OpenROAD.RepairAntennas\` → \`OpenROAD.DiodeInsertion\`,"
        echo "which runs \`scripts/openroad/antenna_repair.tcl\`:"
        echo "\`repair_antennas gf180mcu_fd_sc_mcu7t5v0__antenna -iterations 3 -ratio_margin 10"
        echo "-allow_congestion\`. After 3,846 jumpers (2,080 nets) and 2,522 diodes it hits"
        echo "\`[ERROR GRT-0183] Net _167563_: heap underflow during 3D maze routing\` — the same"
        echo "fatal no-path this build turns into an abort, now inside the repair's own global"
        echo "router pass (#10711 only makes it recoverable). Evidence:"
        echo "\`ws/logs/predrt_die01.container.log\`,"
        echo "\`ws/template/librelane/runs/die01/04-openroad-repairantennas/1-openroad-diodeinsertion/openroad-diodeinsertion.log\`."
        echo "So on this build the die cannot insert antenna diodes at 0.1 at all — the second"
        echo "instance of the pin predating #10711/#11093, and the reason this measurement uses the"
        echo "post-GlobalRouting database with the composite skipped (\`RUN_ANTENNA_REPAIR\` is the"
        echo "flow's own gating variable for it). What the missing diodes would have cost DRT is not"
        echo "measured — no diode-inserted die database exists — so it is recorded as a limitation,"
        echo "not assumed small."
        echo
    fi
    echo "## What it is compared with — and what it is not"
    echo
    echo "* Same instrument, slot core (3048×4238 µm): 418,633 / 344,494 / 254,201 /"
    echo "  191,578 at iteration 2 for GRT_ADJUSTMENT 0.0 / 0.1 / 0.2 / 0.3. The 0.2 → 0.1"
    echo "  give-back cost the slot core +90,293 violations (×1.36). The die's number above"
    echo "  is that same trade measured where it matters, and it is the only arm available:"
    echo "  0.2 does not complete GRT here."
    echo "  One instrument difference, stated: the sweep's arms passed the layer range as"
    echo "  \`-bottom/‑top_routing_layer\` flags in the openlane2 build; this arm states the same"
    echo "  Metal1–Metal5 range via \`set_routing_layers\`. Same range (the die's log prints the"
    echo "  tech's routing layers), one different code path."
    echo "* **Not a flow result.** The fast loop runs pass 0 of the flow's DRT step only."
    echo "  The flow's \`DRT_OPT_ITERS: 8\` cap, its interleaved antenna-repair re-routes and"
    echo "  its \`Checker.TrDRC\` (threshold 0) are not in this number; this is the curve a"
    echo "  flow DRT would start from, so the flow's own verdict will be read against it."
    echo "* **One seed, one thread count, one box.** Run-to-run variation in TritonRoute is"
    echo "  not measured here; 2 iterations is the protocol's endpoint (the slot-core table's"
    echo "  endpoint too), not a converged route."
} > "$OUT"
say "REPORT_WRITTEN $OUT"
say "DIE_DRT_CHAIN_COMPLETE"
echo "die DRT report: $OUT"
exit 0
