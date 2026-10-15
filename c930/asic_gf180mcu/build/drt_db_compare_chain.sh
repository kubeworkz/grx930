#!/bin/bash
# drt_db_compare_chain.sh -- host side: route the die's GRT-derived databases
# through the fast DRT loop, one database per arm, so that what differs between
# two arms' curves is the database (and, for one arm, the engine) and nothing
# else.
#
# WHY
#
#   The die reached detailed routing with the jumper-only antenna repair, which
#   left 1209 antenna violations unresolved and inserted no diodes -- and
#   drt_fast/verdict/die_drt_at01.md records the cost of that as its own
#   limitation, in its own words: "What the missing diodes would have cost DRT is
#   not measured -- no diode-inserted die database exists -- so it is recorded as
#   a limitation, not assumed small." The antenna probe has since produced the
#   databases that did not exist then (ws/probe/out/diode_only, 8749 diodes, no
#   jumpers, 522 violations left; ws/probe/out_pin01/base, 3540 diodes + 5647
#   jumpers, 114 left). This chain routes them, with the same router, at the same
#   iteration budget, on the same box. It is the measurement that limitation
#   named, turned into numbers.
#
# THE CONTROL ARM IS THE POINT
#
#   Arm 1 is the flow arm's OWN DRT input, byte for byte: ws/probe/out/jumper_only
#   and runs/diejmp01/04-openroad-repairantennas/1-openroad-diodeinsertion/chip_top.odb
#   are the same 246,613,739 bytes with the same md5 (5f1d05cad06803b60dc085d987425705).
#   The flow's DRT step and this fast loop run the same router flags -- the step
#   log says `[INFO ORD-0030] Using 8 thread(s).` and its COMMANDS carry
#   `detailed_route -droute_end_iter 8 -or_seed 42 -verbose 1 -output_drc ...`,
#   which is exactly what drt_fast/die_drt.tcl issues (LibreLane itself passes no
#   layer flags; the Metal1-Metal5 range is stated with set_routing_layers in
#   both). So arm 1's first iterations must reproduce the flow arm's own pass-0
#   numbers -- 446,541 / 303,874 / 296,214 -- and that agreement is what licenses
#   reading every other arm against the flow's curve. If it does not agree, that
#   disagreement is the finding and the other arms are read only against each
#   other, because the instrument would then be measuring itself.
#
# ARMS (DRTDC_ARMS selects a subset; they run in this order, by information value)
#
#   1 jmp       the flow arm's DRT input: jumper-only repair, 1209 violations
#               left, 0 diodes -- under the build that wrote it (the pin). The
#               control, and the jumper-only arm's own curve through this loop.
#   2 pin26q4   probe/out_pin01/base.odb: 3540 diodes + 5647 jumpers, 114 left,
#               written by the 26Q4 build -- under the wrapper for that same
#               commit (ws/tools/openroad_26q4.sh). The question as asked: what
#               does the PIN's diode-repaired database route like?
#   3 pindiode  probe/out/diode_only.odb: 8749 diodes, no jumpers, 522 left,
#               written by the pinned build -- under the pinned build. One
#               variable against arm 1: diodes instead of jumpers, same engine,
#               same base GRT database (die01/01-openroad-globalrouting).
#   4 pinpinned the same database as arm 2 under the PINNED build. If the
#               cross-build read is accepted, arm 1 vs 4 isolates the repair and
#               arm 2 vs 4 isolates the engine; a refusal is itself a datum,
#               which is why this arm is here rather than assumed either way.
#
# WHAT IS DELIBERATELY NOT HERE
#
#   * the flow's in-step `repair_antennas` + re-route loop. Step 06's own antenna
#     stage put 4013 diodes into the ALREADY-ROUTED database and restarted the
#     router at 854,844 (flow log, pass `drt-run-1`). That is a different
#     question -- diodes placed on a routed layout -- and this chain measures
#     pass 0 per database, which is the number the repair choice is judged by
#     before any of that happens.
#   * `DRT_OPT_ITERS 8`. DRTDC_ITERS defaults to 3: four curve points, enough to
#     line up with the flow's own first four (446,541 / 303,874 / 296,214 /
#     125,994) and to see the shape of the tail. Each extra iteration is 25-55
#     minutes per arm on this design.
#
# ONE ROUTER AT A TIME
#
#   Measured: these arms peak at 8.1 GB (die02 fast loop, DRT-0267) and the full
#   flow step peaks at 12.2 GB, on a 15.6 GB box that has an OOM in its history.
#   So the chain WAITS for the box rather than refusing (DRTDC_WAIT=0 refuses,
#   DRTDC_MAX_WAIT_H bounds the wait), logs what it is waiting behind, and
#   re-gates -- disk and memory, via build/gate.sh -- before every single arm.
#
#   nohup bash build/drt_db_compare_chain.sh > /dev/null 2>&1 &
#   tail -f ws/logs/drt_db_compare.log
#
#   DRTDC_SELFTEST=1 bash build/drt_db_compare_chain.sh
#       verifies every database, its provenance and both engines, launches no
#       router (the engines are still exercised with `docker run --rm` -version,
#       because an engine that cannot start is a failure worth finding before an
#       unattended run rather than two hours into one).
set -u
ROOT=/home/ubuntu/grx930_ol2
B=$ROOT/build
WS=$ROOT/ws
D=$ROOT/drt_fast
IMG=ghcr.io/wafer-space/gf180mcu-precheck
OR26=/work/ws/tools/openroad_26q4.sh
ITERS=${DRTDC_ITERS:-3}
THREADS=${DRTDC_THREADS:-8}
NEED_MB=${DRTDC_NEED_MB:-10000}
MIN_GB=${DRTDC_MIN_GB:-12}
WAIT=${DRTDC_WAIT:-1}
MAX_WAIT_H=${DRTDC_MAX_WAIT_H:-24}
ARMS=${DRTDC_ARMS:-"jmp pin26q4 pindiode pinpinned"}
SELFTEST=${DRTDC_SELFTEST:-0}
LOG=$WS/logs/drt_db_compare.log
VERD=$D/verdict
TSV=$VERD/die_drt_db_compare.tsv
PROV=$VERD/die_drt_db_compare.prov.txt
OUT=$VERD/die_drt_db_compare.md
FLOWLOG=$WS/logs/predrt_diejmp01.log
say() { echo "[$(date -u)] $*" | tee -a "$LOG"; }
ps_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
. "$B/gate.sh"
mkdir -p "$VERD" "$D/logs"

# ---- the databases, and the evidence for what each one is ---------------------
JMPDB=$ROOT/ws/template/librelane/runs/diejmp01/04-openroad-repairantennas/1-openroad-diodeinsertion/chip_top.odb
JMPSTATE=$ROOT/ws/template/librelane/runs/diejmp01/06-openroad-detailedrouting/state_in.json
PINDB=$ROOT/ws/probe/out_pin01/base/base.odb
DIODEDB=$ROOT/ws/probe/out/diode_only/diode_only.odb
PLOG_PIN=$ROOT/ws/probe/out_pin01/base.log
PLOG_PIN_CLOG=$ROOT/ws/logs/antenna_probe.pin01.container.log
PLOG_DIODE=$ROOT/ws/probe/out/diode_only.log
JMP_MD5_EXPECT=5f1d05cad06803b60dc085d987425705

arm_db() { case "$1" in
    jmp)                echo "$JMPDB" ;;
    pin26q4|pinpinned)  echo "$PINDB" ;;
    pindiode)           echo "$DIODEDB" ;;
esac; }
arm_engine() { case "$1" in pin26q4) echo "$OR26" ;; *) echo "" ;; esac; }
arm_desc() { case "$1" in
    jmp)       echo "flow arm's DRT input: jumper-only repair, 1209 antenna violations left, 0 diodes (pinned build wrote it)" ;;
    pin26q4)   echo "probe base: 3540 diodes + 5647 jumpers, 114 left, written by 26Q4-407-geb14e40b7b" ;;
    pindiode)  echo "probe diode_only: 8749 diodes, 0 jumpers, 522 left, written by the pinned build" ;;
    pinpinned) echo "the pin's database (same file as pin26q4), read by the pinned build" ;;
esac; }

# Harvest with the same semantics as build/die_drt_chain.sh, so the numbers are
# comparable to every table already written: `Completing 100% with` is the
# per-iteration series (initial route first), DRT-0199 is the router's own
# post-iteration total, DRT-0267 is the memory record.
finals()   { grep -aE "Completing 100% with" "$1" 2>/dev/null | grep -oE '[0-9]+ violations' | grep -oE '[0-9]+'; }
totals()   { grep -aE '^\[INFO DRT-0199\]' "$1" 2>/dev/null | grep -oE '= [0-9]+' | grep -oE '[0-9]+'; }
peak_mem() { grep -aE '^\[INFO DRT-0267\]' "$1" 2>/dev/null | grep -oE 'peak = [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1; }
wall_of() {
    local s e
    s=$(grep -aE '^RUN_START' "$1" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1)
    e=$(grep -aE '^RUN_END'   "$1" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1)
    [ -n "${s:-}" ] && [ -n "${e:-}" ] || { printf '?'; return; }
    local ds de
    ds=$(date -u -d "$s" +%s 2>/dev/null); de=$(date -u -d "$e" +%s 2>/dev/null)
    [ -n "${ds:-}" ] && [ -n "${de:-}" ] || { printf '?'; return; }
    printf '%d:%02d:%02d' $(( (de-ds)/3600 )) $(( ((de-ds)%3600)/60 )) $(( (de-ds)%60 ))
}
commas() {
    local n=${1:-} o=''
    case "$n" in ''|*[!0-9]*) printf '%s' "${n:-?}"; return ;; esac
    while [ ${#n} -gt 3 ]; do o=",${n: -3}$o"; n="${n%???}"; done
    printf '%s%s' "$n" "$o"
}
mb_of() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b/1048576 }'; }

# ---- provenance: what each file is, checked against the run that made it -------
# The claim "this database carries diodes inserted by repair X under engine Y" is
# not taken on trust: the log that recorded the repair is required to name the
# exact file, and its own command line and result are carried into the report.
provenance() {  # provenance ARM DB -> writes lines to $PROV, returns 1 on a failed check
    local a=$1 db=$2 n
    case "$a" in
    jmp)
        n=$(grep -oE '"odb": "[^"]*"' "$JMPSTATE" 2>/dev/null | head -1 | cut -d'"' -f4)
        n=${n#/work}
        if [ "$n" != "${db#$ROOT}" ]; then
            say "PROVENANCE_FAIL jmp state_in.json names '${n:-none}', arm uses '${db#$ROOT}'"
            return 1
        fi
        {
            printf '\n### jmp -- the flow arm'"'"'s own DRT input\n\n'
            printf '* Required by the flow to be the database its DetailedRouting step reads, and it is:\n'
            printf '  `06-openroad-detailedrouting/state_in.json` names this exact path.\n'
            printf '* Engine: the pinned build (`openroad` on PATH, the image LibreLane runs) -- the build that wrote it.\n'
        } >> "$PROV"
        say "PROVENANCE_OK jmp state_in.json=$(basename "$JMPSTATE") odb=${db#$ROOT}"
        ;;
    pin26q4|pinpinned)
        grep -aq "ANT_PROBE_WROTE /work${db#$ROOT}" "$PLOG_PIN" || {
            say "PROVENANCE_FAIL $a $PLOG_PIN does not name /work${db#$ROOT} as written"; return 1; }
        {
            printf '\n### %s -- probe `base` (26Q4 build)\n\n' "$a"
            printf '* The probe'"'"'s own record (`ws/probe/out_pin01/base.log`):\n\n'
            printf '```\n'
            grep -aE '^ANT_PROBE_(CMD|RESULT|WROTE)' "$PLOG_PIN" | sed 's/^/  /'
            printf '```\n\n'
            printf '* The engine that wrote it (`ws/logs/antenna_probe.pin01.container.log`):\n\n'
            printf '```\n'
            grep -aE '^ANT_DRIVER' "$PLOG_PIN_CLOG" | sed 's/^/  /'
            printf '```\n'
        } >> "$PROV"
        say "PROVENANCE_OK $a probe_log=$(basename "$PLOG_PIN") engine=$(grep -aoE '26Q4-[0-9]+-g[0-9a-f]+' "$PLOG_PIN_CLOG" | head -1)"
        ;;
    pindiode)
        grep -aq 'ANT_PROBE_WROTE /work'"${db#$ROOT}" "$PLOG_DIODE" || {
            say "PROVENANCE_FAIL $a $PLOG_DIODE does not name /work${db#$ROOT} as written"; return 1; }
        {
            printf '\n### pindiode -- probe `diode_only` (pinned build)\n\n'
            printf '* The probe'"'"'s own record (`ws/probe/out/diode_only.log`):\n\n'
            printf '```\n'
            grep -aE '^ANT_PROBE_(CMD|RESULT|WROTE)' "$PLOG_DIODE" | sed 's/^/  /'
            printf '```\n\n'
            printf '* Engine: the pinned build. The pin run (`antenna_probe.pin01.container.log`)\n'
            printf '  ran `variants=base` only -- `-diode_only` appears in no run but the\n'
            printf '  pinned one, whose log is the file above.\n'
        } >> "$PROV"
        say "PROVENANCE_OK $a probe_log=$(basename "$PLOG_DIODE")"
        ;;
    *)
        return 1 ;;
    esac
}

# ---- the arms each run through this loop --------------------------------------
# Every arm is the same command with a different FAST_ODB (and, for one, a
# different engine), so no arm can differ from another by its instrument.
run_arm() {
    # `dblog=$a` on the same `local` line as `a=$1` is an unbound variable under
    # `set -u` -- one local name, one assignment; measured the hard way, by the
    # stub test in /tmp before this chain reached an arm for real.
    local a=$1 db=$2 or=$3
    local odb_in=/work${db#$ROOT}
    docker rm -f "drtdc_$a" >/dev/null 2>&1
    docker run -d --name "drtdc_$a" --user 0:0 -e HOME=/root -v "$ROOT:/work" \
        -e FAST_TAG="$a" -e FAST_ODB="$odb_in" \
        -e FAST_END_ITER="$ITERS" -e FAST_MIN_LAYER=Metal1 -e FAST_MAX_LAYER=Metal5 \
        -e FAST_THREADS="$THREADS" \
        ${or:+-e DIE_DRT_OR="$or"} \
        $IMG /work/ws/die_drt_exec.sh >/dev/null
    if [ "$(ps_running "drtdc_$a")" != "true" ]; then
        say "ARM_NOT_RUNNING $a $(docker inspect -f 'status={{.State.Status}} rc={{.State.ExitCode}}' "drtdc_$a" 2>&1 | head -1)"
    fi
    say "ARM_LAUNCHED $a container=drtdc_$a odb=$odb_in engine=${or:-pinned} iters=$ITERS threads=$THREADS"
    while [ "$(ps_running "drtdc_$a")" = "true" ]; do sleep 60; done
    local rc wall init i1 i2 i3 peak
    rc=$(docker inspect -f '{{.State.ExitCode}}' "drtdc_$a" 2>/dev/null)
    docker logs "drtdc_$a" > "$A_LOG" 2>&1
    wall=$(wall_of "$A_LOG")
    init=$(finals "$A_LOG" | sed -n 1p); i1=$(finals "$A_LOG" | sed -n 2p)
    i2=$(finals "$A_LOG" | sed -n 3p); i3=$(finals "$A_LOG" | sed -n 4p)
    peak=$(peak_mem "$A_LOG")
    say "ARM_EXIT $a rc=$rc wall=$wall initial=${init:-?} it1=${i1:-?} it2=${i2:-?} it3=${i3:-?} peak_mb=${peak:-?} log=$A_LOG"
    [ "$rc" != 0 ] && { say "ARM_FAILED $a rc=$rc"; grep -aE "ERROR|Error:|error:" "$A_LOG" | tail -6 | tee -a "$LOG"; }
    # The project's own tail verdict, in log-only mode and its own output dir, so
    # no arm can overwrite another's.
    mkdir -p "$VERD/${a}_watch"
    WATCH_OUT="$VERD/${a}_watch" bash "$WS/watch_drt_curve.sh" --log "$A_LOG" --once \
        > "$VERD/${a}_watch/watch.out" 2>&1
    return $rc
}

write_report() {
    local now
    now=$(date -u '+%F %T')
    {
        printf '# The die'"'"'s detailed routing, reached from four databases\n\n'
        printf 'Written %s UTC by `build/drt_db_compare_chain.sh`. It answers, with numbers,\n' "$now"
        printf 'the limitation `drt_fast/verdict/die_drt_at01.md` recorded in its own words:\n'
        printf '"What the missing diodes would have cost DRT is not measured -- no diode-inserted\n'
        printf 'die database exists -- so it is recorded as a limitation, not assumed small."\n\n'
        printf '## Instrument\n\n'
        printf '* `drt_fast/run_drt.sh` -> `drt_fast/die_drt.tcl`: **%s iterations**, `-or_seed 42`,\n' "$ITERS"
        printf '  %s threads, Metal1-Metal5 stated with `set_routing_layers`, `write_db` to\n' "$THREADS"
        printf '  `drt_fast/out/<arm>/`. Run in `%s` -- the image that wrote these\n' "$IMG"
        printf '  databases and the image the flow'"'"'s own DRT step runs in.\n'
        printf '* The flow'"'"'s step 06 runs the same router the same way (`[INFO ORD-0030] Using 8\n'
        printf '  thread(s).`, `detailed_route -droute_end_iter 8 -or_seed 42 -verbose 1`), which is\n'
        printf '  why arm 1 -- the flow arm'"'"'s own input database, byte for byte -- is the control.\n\n'
        printf '## The arms\n\n'
        printf '| arm | database | engine | initial route | iter 1 | iter 2 | iter 3 | peak MB | wall | rc |\n'
        printf '|---|---|---|---|---|---|---|---|---|---|\n'
        awk -F'|' 'NR>1 {
            printf "| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n",
                   $1, $2, $3, $4, $5, $6, $7, $8, $9, $10 }' "$TSV" 2>/dev/null
        printf '\n`initial route` and `iter N` are the router'"'"'s own `Completing 100%% with`\n'
        printf 'series -- the same series `die_drt_chain.sh` harvests. The router'"'"'s\n'
        printf 'post-iteration `DRT-0199` totals are in each arm'"'"'s log (they run ~10 violations\n'
        printf 'below the `Completing` line, the offset already documented for the slot core).\n\n'
        printf '## What each arm is\n\n'
        for a in $ARMS; do printf '* `%s` -- %s\n' "$a" "$(arm_desc "$a")"; done
        printf '\n## Reference: the flow arm'"'"'s own curve (the number this compares against)\n\n'
        printf '`runs/diejmp01`, step `06-openroad-detailedrouting`, from its own log\n'
        printf '(`ws/logs/predrt_diejmp01.log`), harvested with the same functions:\n\n'
        printf '| pass | initial route | iter 1 | iter 2 | iter 3 | ... | last | wall | peak MB |\n'
        printf '|---|---|---|---|---|---|---|---|---|\n'
        printf '| 0 (`drt-run-0`, `DRT_OPT_ITERS 8`, the jumper-only database) | 446,541 | 303,874 | 296,214 | 125,994 | 87,358 / 62,880 / 47,342 / 36,748 / 27,758 | **27,758** | 5:45:12 | 9,065 |\n'
        printf '| 1 (`drt-run-1`, after the step'"'"'s own `repair_antennas` put 4,013 diodes into the ROUTED database) | 854,844 | 513,688 | 473,460 | 415,213 | (in flight) | -- | -- | 12,255 |\n\n'
        printf 'The second row is why this chain stops at pass 0: the flow'"'"'s step repairs\n'
        printf 'antennas ON A ROUTED database and restarts the router, which is a different\n'
        printf 'question from "which repair gives the router a better database to start from".\n\n'
        printf '## Provenance\n\n'
        printf 'Every database is checked against the log of the run that produced it before its\n'
        printf 'arm runs -- the flow'"'"'s `state_in.json` for arm 1, the probe'"'"'s `ANT_PROBE_WROTE`\n'
        printf 'and `ANT_DRIVER` lines for the others -- and the evidence is kept here verbatim:\n'
        cat "$PROV" 2>/dev/null
        printf '\n## How to read this\n\n'
        printf '* A **lower** initial route on a diode-bearing database is not automatically\n'
        printf '  "better": the diodes are extra terminals to connect and extra obstruction, and\n'
        printf '  the violation count is DRC, not antenna. What the diodes buy is antenna\n'
        printf '  legality (1209 left -> 522 / 114), and this chain prices the routing side of\n'
        printf '  that trade -- which is the number the 0.1 landing could not quote.\n'
        printf '* One seed, one thread count, one box, %s iterations -- not the flow'"'"'s 8, and not a\n' "$ITERS"
        printf '  converged route. Run-to-run variation in TritonRoute is not measured here.\n'
        printf '* The engines are named per arm because two arms read a database with the build\n'
        printf '  that wrote it and one does not; `pinpinned` exists to make that difference\n'
        printf '  measurable rather than assumed.\n'
        printf '* Arm logs: `drt_fast/logs/<arm>_drt.log`. Routed databases: `drt_fast/out/<arm>/`.\n'
    } > "$OUT"
}

# ---- selftest: everything except the router -----------------------------------
if [ "$SELFTEST" = 1 ]; then
    say "SELFTEST_START arms='$ARMS' iters=$ITERS threads=$THREADS"
    for A in $ARMS; do
        DB=$(arm_db "$A")
        [ -f "$DB" ] || { say "SELFTEST_DB_MISSING $A $DB"; continue; }
        E=$(arm_engine "$A"); E=${E:-pinned}
        provenance "$A" "$DB" || say "SELFTEST_PROVENANCE_FAIL $A"
        say "SELFTEST_DB $A $(stat -c %s "$DB") bytes md5=$(md5sum "$DB" | awk '{print $1}') engine=$E"
    done
    if [ "$(md5sum "$JMPDB" | awk '{print $1}')" = "$JMP_MD5_EXPECT" ]; then
        say "SELFTEST_CONTROL_IDENTITY ok $JMP_MD5_EXPECT (flow DRT input == probe jumper_only)"
    else
        say "SELFTEST_CONTROL_IDENTITY changed -- the control is no longer the flow arm's database"
    fi
    say "SELFTEST_ENGINE_PINNED $(docker run --rm $IMG /bin/sh -c 'openroad -version 2>&1 | head -1' </dev/null 2>&1 | tail -1)"
    say "SELFTEST_ENGINE_26Q4 $(docker run --rm -e HOME=/root -v "$ROOT:/work" $IMG /bin/sh -c '/work/ws/tools/openroad_26q4.sh -version 2>&1 | head -1' </dev/null 2>&1 | tail -1)"
    say "SELFTEST_DONE (no router launched)"
    exit 0
fi

# ---- the run ------------------------------------------------------------------
say "DRT_DB_COMPARE_START arms='$ARMS' iters=$ITERS threads=$THREADS need_mb=$NEED_MB min_gb=$MIN_GB wait=$WAIT"
say "FLOW_ARM_REF $FLOWLOG"
[ -f "$TSV" ] || printf 'arm|database|engine|initial|iter1|iter2|iter3|peak_mb|wall|rc\n' > "$TSV"

for A in $ARMS; do
    DB=$(arm_db "$A")
    OR=$(arm_engine "$A")
    if [ -z "${DB:-}" ]; then say "ARM_SKIP unknown_arm=$A"; continue; fi
    A_LOG=$D/logs/${A}_drt.log
    if [ ! -f "$DB" ]; then say "ARM_ABORT $A db_missing $DB"; continue; fi
    provenance "$A" "$DB" || { say "ARM_ABORT $A provenance_failed"; continue; }
    DBSZ=$(stat -c %s "$DB"); DBM5=$(md5sum "$DB" | awk '{print $1}')
    say "ARM_DB $A path=${DB#$ROOT} bytes=$DBSZ md5=$DBM5 mtime=$(date -u -d "@$(stat -c %Y "$DB")" +%FT%TZ)"
    if [ "$A" = jmp ] && [ "$DBM5" != "$JMP_MD5_EXPECT" ]; then
        say "ARM_NOTE $A control md5 differs from the recorded 5f1d05cad06803b60dc085d987425705 -- the flow comparison is no longer byte-exact"
    fi

    # Wait for the box instead of refusing: it carries one 8-12 GB router at a
    # time, and whatever is running (the flow arm, an extend arm, a repair probe)
    # has a claim on it that this chain does not get to preempt.
    W0=$(date -u +%s); WAITED=0
    while :; do
        RUNNING=$(docker ps --format '{{.Names}}' | tr '\n' ' ')
        [ -z "$RUNNING" ] && break
        if [ "$WAIT" != 1 ]; then say "ARM_BUSY $A running='$RUNNING' -- refusing (DRTDC_WAIT=0)"; continue 2; fi
        if [ $(( ($(date -u +%s) - W0) / 3600 )) -ge "$MAX_WAIT_H" ]; then
            say "ARM_ABORT $A wait_timeout_${MAX_WAIT_H}h running='$RUNNING'"; continue 2
        fi
        [ "$WAITED" = 0 ] && { say "WAIT_BEGIN $A running='$RUNNING'"; WAITED=1; }
        sleep 120
    done
    [ "$WAITED" = 1 ] && say "WAIT_END $A after $(( ($(date -u +%s) - W0) / 60 ))m"
    gate "$NEED_MB" "drtdc_$A" "$MIN_GB" / || { say "ARM_ABORT $A $GATE_REASON"; continue; }

    run_arm "$A" "$DB" "$OR"; rc=$?
    INIT=$(finals "$A_LOG" | sed -n 1p); I1=$(finals "$A_LOG" | sed -n 2p)
    I2=$(finals "$A_LOG" | sed -n 3p); I3=$(finals "$A_LOG" | sed -n 4p)
    PEAK=$(peak_mem "$A_LOG"); WALL=$(wall_of "$A_LOG")
    # A silent '?' in every column would look like a router that produced nothing.
    # Say so instead, and name the log to read.
    [ -n "${INIT:-}" ] || say "ARM_HARVEST_EMPTY $A -- no 'Completing 100% with' line in $A_LOG"
    [ -n "${PEAK:-}" ] || say "ARM_HARVEST_NO_PEAK $A -- no DRT-0267 memory line in $A_LOG"
    # One label, one assignment: `${OR:-a}${OR:+b}` with OR set appends the other
    # branch's text as well, which is how the first stub test produced the cell
    # "/work/ws/tools/openroad_26q4.sh26Q4-407-geb14e40b7b (wrapper)".
    ENG="pinned (image openroad)"
    [ -n "$OR" ] && ENG="26Q4-407-geb14e40b7b (wrapper)"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$A" "$(arm_desc "$A") ($(mb_of "$DBSZ") MB, md5 ${DBM5:0:8})" \
        "$ENG" \
        "$(commas "${INIT:-?}")" "$(commas "${I1:-?}")" "$(commas "${I2:-?}")" "$(commas "${I3:-?}")" \
        "${PEAK:-?}" "$WALL" "$rc" >> "$TSV"
    write_report
    say "ARM_REPORT_UPDATED $OUT"
done

# The flow arm's own tail, as evidence for the reference table, at the end of
# the chain's own run -- so the comparison is read against the flow's numbers as
# they stood when the arms finished, not as they were remembered.
{
    printf '\n### The flow arm'"'"'s curve and antenna stage, as the log stands at report time\n\n'
    printf '```\n'
    grep -aE 'DRT-0199|GRT-0012|GRT-0015|Complete detail routing|^\+ repair_antennas' "$FLOWLOG" 2>/dev/null | sed 's/^[[:space:]]*/  /'
    printf '```\n'
} >> "$PROV"
write_report
say "DRT_DB_COMPARE_COMPLETE report=$OUT"
exit 0
