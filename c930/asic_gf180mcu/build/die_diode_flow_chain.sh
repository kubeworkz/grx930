#!/bin/bash
# die_diode_flow_chain.sh -- host side: run the die's FLOW END TO END on a
# diode-repaired database, and measure the flow's own DetailedRouting step (step
# 06) on it. This is the arm that replaces the one the die currently has -- a
# flow that could only reach detailed routing with the antenna repair restricted
# to jumpers (1209 violations left, no diodes at all).
#
# WHY THIS ARM EXISTS
#
#   runs/diejmp01 is the proof that the die cannot complete its antenna repair on
#   the image's pinned OpenROAD (dcf36133): the composite's own global-router pass
#   finds a no-path, and that build turns every no-path into an abort
#   (`[ERROR GRT-0183] ... heap underflow during 3D maze routing`). The arm in
#   flight therefore carries `GRT_ANTENNA_REPAIR_JUMPER_ONLY=true` -- 1209 antenna
#   violations unresolved and no diodes in the database (die_to_drt_antenna_and_pin
#   .md §2, §4.2). The OpenROAD 26Q4 line completes the SAME repair on the SAME
#   database instead: measured by the probe, 2979 -> 114 violations left, 3540
#   diodes + 5647 jumpers inserted (ws/probe/out_pin01/base.log). This chain is
#   that repair inside the flow, followed by the flow's own DRT on the database
#   it produces.
#
# THE TWO THINGS IT NEEDS, BOTH CHECKED
#
#   * the engine       PREDRT_OR=/work/ws/tools/openroad_engine.sh
#                      One path per chain, resolved per HOST by the dispatcher: on
#                      x86_64 it execs ws/tools/openroad_26q4.sh (OpenROAD
#                      26Q4-407-geb14e40b7b, the commit extracted from
#                      openroad/debian12:26Q4-407-geb14e40b7b); on aarch64 it execs
#                      ws/tools/openroad_arm64.sh, because that image publishes amd64
#                      only and the pinned wrapper there is a 127 in the arm's first
#                      minute. It was named directly here until 2026-10-26; see
#                      "WHICH ENGINE RAN" below for what that changes on arm64.
#   * the backport     PREDRT_PATCH_LLN=1023 -> ws/tools/librelane_1023_io_patch.py
#                      REQUIRED at step level, and this is measured, not assumed:
#                      without it the pin arm dies as step 01 FINISHES --
#                      `[ERROR STA-0107] _70aee23fd3100000_p_Scene is not the name
#                      of a scene` (run diepin02, 2026-10-14 01:48; its run tree
#                      stops at 01-openroad-globalrouting). die_predrt_exec.sh
#                      refuses to start the arm if the patch did not apply, so a
#                      silent fall back to the unpatched LibreLane is impossible.
#
# WHICH ENGINE RAN, AND WHAT THE ARM THEREFORE MEASURES
#
#   The dispatcher's choice is a property of the HOST, so one chain is two arms:
#
#     x86_64   the pinned 26Q4 build -- the arm this header describes, whose
#              antenna repair COMPLETES (2979 -> 114 violations left, 3540 diodes
#              + 5647 jumpers).
#     aarch64  the pre-check image's own OpenROAD (dcf36133, the SAME commit the
#              x86 image ships) under `stdbuf -oL`. It has neither of the two
#              no-path recoveries the die needs, so that arm is the OBSERVABILITY
#              arm -- does the flow reach the router, and what does the router do
#              -- and it cannot complete the repair; ws/tools/openroad_arm64.sh
#              carries the measurement behind that statement.
#
#   The class is read from the engine's own `-version` line (the pinned build names
#   itself there, the image's own is a bare commit hash), the way every other log
#   in this project identifies the engine, and it is printed wherever the engine is
#   named: `ARM_ENGINE class=`, `PLAN engine_class=`, and the report's `* engine:`
#   line -- which quotes the version the ARM's own container logged rather than
#   asserting the pin. Nothing here refuses an arm64 run: the arm is measurable and
#   observable there, and an equivalence that was not measured is not evidence.
#
# THE ARM IS THE UNMODIFIED FLOW
#
#   No GRT_ANTENNA_REPAIR_* override (DIE_DIO_OVERRIDE can add one): the staged
#   config as it ships, so the only difference from the pinned-engine arm is the
#   engine. The interesting variant is one word away --
#     DIE_DIO_OVERRIDE='GRT_ANTENNA_REPAIR_DIODE_ONLY=true'
#   which is the 8749-diode, no-jumper repair the probe measured at 522 violations
#   left, and which the fast-loop comparison routes as its `pindiode` arm.
#
# IT QUEUES BEHIND THE FAST-LOOP COMPARISON
#
#   Like every other chain here it runs one router at a time and WAITS for the box.
#   It additionally waits for build/drt_db_compare_chain.sh to be gone: that chain
#   is ahead of this one by operator choice, it spends hours waiting for the same
#   free box, and two "wait for no container" loops without this hand-off would
#   simply race for whichever moment the box empties first. DIE_DIO_WAIT=0 refuses
#   instead of waiting.
#
# THE ARM IS NOT RE-LAUNCHED ON A CLOCK
#
#   The arm is started detached (it has to be: it waits for the box and then runs
#   for days), so the only safe way to tell whether it started is the arm's own
#   decision. `die_drt_chain.sh` records `LAUNCHED tag=...` in `DIE_ARM_STATE` at
#   the moment its container is up, and this chain waits for that line -- not for a
#   fixed sleep and a grep of the chain log, which is how it used to work: at 45 s a
#   slow gate looked like a refusal, and the retry then ran `docker rm -f
#   die_predrt` out from under an arm that was already routing. A retry is now
#   started only when the previous arm is GONE without the line. If it is alive and
#   has not decided within DIE_DIO_LAUNCH_WAIT (2700 s), the chain aborts rather
#   than race it -- no second copy, ever, over a live arm.
#
#   nohup bash build/die_diode_flow_chain.sh > /dev/null 2>&1 &
#   tail -f ws/logs/die_diode_flow_chain.log
#
#   bash build/die_launch_selftest.sh   -- the handshake above, pinned from both
#   ends against stub arms and a stub docker; run it after touching either chain.
#
#   DIE_DIO_PLAN=1     ... launch nothing, print the resolved arm and its checks
#   DIE_DIO_HARVEST=1  ... re-harvest the logs on disk and rewrite the report,
#                          launching nothing. Pointed at the arm in flight
#                          (`DIE_DIO_TAG=diejmp01`) this is the harvester's own
#                          test: it must reproduce that arm's published pass-0
#                          curve 446,541 / 303,874 / 296,214 / 125,994 ... 27,758,
#                          and its pass-1 restart at 854,844.
set -u
ROOT=/home/ubuntu/grx930_ol2
B=$ROOT/build
WS=$ROOT/ws
D=$ROOT/drt_fast
IMG=ghcr.io/wafer-space/gf180mcu-precheck
# The engine: the chain names the DISPATCHER, which resolves per host (see the
# header). ENGINE_26Q4 / ENGINE_A64 are only what it can resolve TO -- named here so
# the PLAN can say which of the two files are on this box instead of leaving it to a
# 127 inside the arm's container.
ENGINE=/work/ws/tools/openroad_engine.sh
ENGINE_26Q4=/work/ws/tools/openroad_26q4.sh
ENGINE_A64=/work/ws/tools/openroad_arm64.sh
PATCH=/work/ws/tools/librelane_1023_io_patch.py
TAG=${DIE_DIO_TAG:-died26q4}
STATE=${DIE_DIO_STATE:-/work/ws/template/librelane/runs/ws_v3/36-openroad-stamidpnr-2/state_out.json}
OVERRIDE=${DIE_DIO_OVERRIDE:-}
STOP=${DIE_DIO_STOP:-OpenROAD.DetailedRouting}
WAIT=${DIE_DIO_WAIT:-1}
MAX_WAIT_H=${DIE_DIO_MAX_WAIT_H:-36}
ATTEMPTS=${DIE_DIO_ATTEMPTS:-6}
# How long one attempt may stay alive without a decision before the chain gives up
# instead of starting a second arm over it, and how long to wait between attempts
# that DID exit without launching.
LAUNCH_WAIT=${DIE_DIO_LAUNCH_WAIT:-2700}
RETRY_WAIT=${DIE_DIO_RETRY_WAIT:-300}
PLAN=${DIE_DIO_PLAN:-0}
HARVEST=${DIE_DIO_HARVEST:-0}
WATCH_EXTEND=${DIE_DIO_WATCH_EXTEND:-0}
LOG=$WS/logs/die_diode_flow_chain.log
CHAINLOG=$WS/logs/die_drt_chain.log
# The arm's decision marker: cleared per attempt, appended by the child
# (`arm_state` in die_drt_chain.sh) with `LAUNCHED tag=...` or, at exit, `EXIT rc=..`.
MARK=$WS/logs/die_drt_chain.$TAG.launch
# The arm script. Overridable only so the wait below can be exercised against a
# stub child (a real arm takes days); nothing in normal use sets it.
CHILD=${DIE_DIO_CHILD:-$B/die_drt_chain.sh}
RUN=$WS/template/librelane/runs/$TAG
STEPDIR=$RUN/06-openroad-detailedrouting
REPAIR=$RUN/04-openroad-repairantennas
FLOG=$WS/logs/predrt_$TAG.log
CLOG=$WS/logs/predrt_$TAG.container.log
OUT=$D/verdict/die_diode_flow_arm.md
say() { echo "[$(date -u)] $*" | tee -a "$LOG"; }
. "$B/gate.sh"
mkdir -p "$D/verdict"

# ---- harvest ------------------------------------------------------------------
# The series is the router's OWN post-iteration total, `[INFO DRT-0199] Number of
# violations = N`, because that is what every published table in this project
# quotes (die_to_drt_antenna_and_pin.md §4.2, drt_fast/verdict/die_drt_at01.md).
# The `Completing 100% with N violations` line is a *different* series -- it runs
# slightly below, by 10 for the late iterations and by ~25,000 for the initial
# route (measured: 446,541 against 421,043 on the same iteration) -- so harvesting
# the wrong one silently invents a curve. This file's first version did exactly
# that, and the HARVEST test against the arm in flight is what caught it.
# `curve_of` splits the series into PASSES at the step's own boundaries: `Complete
# detail routing` ends a pass, and the `repair_antennas` + GRT-0015 diode lines
# that follow it belong to the NEXT pass, which is how the flow's antenna loop reads.
peak_mem()  { grep -aE '\[INFO DRT-0267\]' "$1" 2>/dev/null | grep -oE 'peak = [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1; }
# The router's DRT-0267 records (and so the memory figure) are written to the STEP's
# own log, not to the flow's console output -- searching the console log alone is how
# this report first printed `?` for a peak that is in the file next to it.
mem_source() {
    local f
    for f in "$STEPDIR/openroad-detailedrouting.log" "$CLOG" "$FLOG"; do
        [ -s "${f:-}" ] || continue
        grep -aqE '\[INFO DRT-0267\]' "$f" && { printf '%s' "$f"; return; }
    done
}
last_total() { grep -aE '\[INFO DRT-0199\]' "$1" 2>/dev/null | grep -oE '= [0-9]+' | grep -oE '[0-9]+' | tail -1; }
commas() {
    local n=${1:-} o=''
    case "$n" in ''|*[!0-9]*) printf '%s' "${n:-?}"; return ;; esac
    while [ ${#n} -gt 3 ]; do o=",${n: -3}$o"; n="${n%???}"; done
    printf '%s%s' "$n" "$o"
}
curve_of() {  # $1 = log -> one line per pass: pass|series|last|antenna|diodes|jumpers
    grep -aE 'Number of violations = |Inserted [0-9]+ diodes|Inserted [0-9]+ jumpers|Found [0-9]+ antenna violations|Complete detail routing|\+ repair_antennas' "$1" 2>/dev/null |
    awk '
      # The number always FOLLOWS its keyword, and the lines carry more numbers
      # after it (jumpers \"for 2072 nets\"), so take the first numeric field after
      # the keyword rather than stripping everything to digits.
      function after(line, kw,   n, a, b) {
          n=split(line, a, kw); split(a[n], b, /[^0-9]+/); return b[1]
      }
      /Number of violations = / { v=after($0, "= "); series = (series == "" ? v : series " " v); last=v; next }
      /Found [0-9]+ antenna/ { af=after($0, "Found "); next }
      /Inserted [0-9]+ diodes/ { di=after($0, "Inserted "); next }
      /Inserted [0-9]+ jumpers/ { ju=after($0, "Inserted "); next }
      /repair_antennas|Complete detail routing/ {
          if (series != "") { printf "%d|%s|%s|%s|%s|%s\n", pass, series, last, af, di, ju; pass++ }
          series=""; last=""; af=""; di=""; ju=""; next }
      END { if (series != "") printf "%d|%s|%s|%s|%s|%s\n", pass, series, last, af, di, ju }
    '
}
spaced() { tr ' ' '\n' <<< "${1:-}" | grep -E '^[0-9]+$' | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta' | tr '\n' ' ' | sed 's/ $//' ; }
source_log() {  # the most complete log this arm left
    for f in "$CLOG" "$FLOG" "$STEPDIR/openroad-detailedrouting.log"; do
        [ -s "${f:-}" ] && { printf '%s' "$f"; return; }
    done
}

# Which engine an arm ran, from the engine's own `-version` line -- the identifier
# every chain in this project records it by. `unknown` is a class of its own: a log
# that never got written must not be rounded to one of the two builds, because the
# two are not interchangeable (see the header).
engine_class() {  # $1 = a -version line -> pinned | image | unknown
    case "${1:-}" in
        "")     printf 'unknown' ;;
        *26Q4*) printf 'pinned' ;;
        *)      printf 'image' ;;
    esac
}
# Ask the engine what it is, in the container, the way the arm's own log will record
# it. `--rm` and unnamed on purpose: the arm's own busy check is `docker ps`, and it
# must not see this one -- it is gone before the arm is launched.
# The trailing trim is not cosmetic-only: the engines do not agree on the tail of
# their version line (the image's own build prints one with a trailing space), and
# the string is carried into `PLAN engine_version='...'` and the report, where a
# stray space reads like a broken quote.
engine_probe() {
    docker run --rm -e HOME=/root -v "$ROOT:/work" "$IMG" \
        /bin/sh -c "\"${ENGINE}\" -version 2>&1 | head -1" </dev/null 2>&1 \
        | tr -d '\r' | sed 's/[[:space:]]*$//' | tail -1
}
# The engine line the ARM's own container wrote (ws/die_predrt_exec.sh records
# `PREDRT openroad_override=<path> <version>`): what actually ran, not what this
# host would resolve today -- the report is also rewritten by DIE_DIO_HARVEST=1,
# days later, against logs written by an arm that has since exited. Empty when the
# arm never reached the flow.
arm_engine_line() {
    grep -ahoE '^PREDRT openroad_override=[^ ]+ .*$' "${CLOG:-}" "${FLOG:-}" 2>/dev/null | tail -1
}

# ---- modes that launch nothing -------------------------------------------------
if [ "$PLAN" = 1 ]; then
    say "PLAN tag=$TAG arm='flow end to end, DetailedRouting on a diode-repaired die'"
    say "PLAN engine=$ENGINE (dispatcher) backport=$PATCH stop=$STOP override='${OVERRIDE:-none (the staged config, unmodified)}'"
    say "PLAN state=$STATE host=${ROOT}${STATE#/work}"
    [ -f "${ROOT}${STATE#/work}" ] && say "PLAN state_ok $(stat -c %s "${ROOT}${STATE#/work}") bytes" || say "PLAN state_MISSING"
    [ -f "${ROOT}${PATCH#/work}" ] && say "PLAN patch_ok $(wc -l < "${ROOT}${PATCH#/work}") lines" || say "PLAN patch_MISSING"
    [ -f "${ROOT}${ENGINE#/work}" ] && say "PLAN wrapper_ok ${ROOT}${ENGINE#/work}" || say "PLAN wrapper_MISSING"
    # Both files the dispatcher can pick from. Only one of them is reachable per
    # host, and a missing one is a 127 inside the arm's container: name which are
    # there rather than discovering it from the arm's death.
    for E2 in "$ENGINE_26Q4" "$ENGINE_A64"; do
        E2B=$(basename "$E2" .sh)
        if [ -f "${ROOT}${E2#/work}" ]; then say "PLAN wrapper_${E2B}_ok ${ROOT}${E2#/work}"
        else say "PLAN wrapper_${E2B}_MISSING ${E2}"; fi
    done
    say "PLAN launch: DIE_TAG=$TAG DIE_PREDRT_OVERRIDE='$OVERRIDE' PREDRT_OR=$ENGINE PREDRT_PATCH_LLN=1023 PREDRT_STOP=$STOP DIE_PHASE_A_ONLY=1 bash $B/die_drt_chain.sh"
    # The engine's own answer, and the class it implies. Read in the container, not
    # on the host: the dispatcher runs there, and `uname -m` on the host is the one
    # thing that would answer a different question.
    EP=$(engine_probe)
    say "PLAN engine_version='${EP:-none}' engine_class=$(engine_class "$EP")"
    say "PLAN disk_gb_free $(free_gb /) mem $(bash "$B/memwatch.sh" --headroom)"
    say "PLAN_DONE (launched nothing)"
    exit 0
fi

if [ "$HARVEST" = 1 ]; then
    say "HARVEST tag=$TAG (launching nothing; rewriting $OUT from the logs on disk)"
else
    say "DIE_DIO_FLOW_START tag=$TAG arm='flow -> DetailedRouting on a diode-repaired die'"
    say "DIE_DIO_FLOW_ARM engine=$ENGINE backport=1023 stop=$STOP override='${OVERRIDE:-none}' attempts=$ATTEMPTS wait=$WAIT"
fi

# ---- wait for the box, and for the chain that is ahead of this one -------------
if [ "$HARVEST" != 1 ]; then
    # The shared gate, before the wait and the launch. The arm gates itself for its
    # phase A (die_drt_chain.sh: 9000 MB against a 12 GB floor), but a refusal there
    # arrives after this chain has launched it, and arrives in the ARM's log -- this
    # chain would see "exited without launching", retry, and report the retries as if
    # the arm had failed. Asking first costs one memwatch call and names the reason
    # in this chain's own log. Every other *_chain.sh in build/ does the same, and
    # gate_selftest.sh checks that it still does.
    gate 9000 die_diode_flow 12 / || { say "ARM_ABORT_$GATE_REASON"; exit 1; }
    W0=$(date -u +%s); WAITED=0
    while :; do
        RUNNING=$(docker ps --format '{{.Names}}' | tr '\n' ' ')
        # trailing anchor, not a bare substring: the ssh wrapper that LAUNCHES a chain
        # has that chain's path inside a much longer cmdline, and an orphaned wrapper
        # (which this box produces when a session is dropped mid-command) would
        # otherwise read as "a chain is still ahead of me" for the whole wait budget.
        # Measured: the first launch of this file logged ahead='2000938 2308524 ', where
        # 2308524 was the wrapper, not a chain.
        AHEAD=$(pgrep -f 'build/drt_db_compare_chain.sh$' 2>/dev/null | tr '\n' ' ')
        [ -z "$RUNNING" ] && [ -z "$AHEAD" ] && break
        if [ "$WAIT" != 1 ]; then say "ARM_BUSY running='${RUNNING:-none}' ahead='${AHEAD:-none}' -- refusing (DIE_DIO_WAIT=0)"; exit 1; fi
        if [ $(( ($(date -u +%s) - W0) / 3600 )) -ge "$MAX_WAIT_H" ]; then
            say "ARM_ABORT wait_timeout_${MAX_WAIT_H}h running='${RUNNING:-none}' ahead='${AHEAD:-none}'"; exit 1
        fi
        [ "$WAITED" = 0 ] && { say "WAIT_BEGIN running='${RUNNING:-none}' ahead='${AHEAD:-none}'"; WAITED=1; }
        sleep 120
    done
    [ "$WAITED" = 1 ] && say "WAIT_END after $(( ($(date -u +%s) - W0) / 60 ))m"

    # Launch through the project's own pre-DRT chain (its GRT gate, its pre-DRT
    # database discovery and its repair evidence are all reused, not reimplemented)
    # and retry only when it EXITED without starting a container.
    #
    # The decision comes from the arm itself: `arm_state` writes `LAUNCHED tag=...`
    # into $MARK at the moment its container is up. Waiting on a clock instead (the
    # previous 45 s + grep) cannot distinguish "slow gate" from "refused", and its
    # retry would `docker rm -f die_predrt` a healthy arm. So the rule is: while the
    # child is alive, wait; retry only when it is gone with no LAUNCHED line; and if
    # it is alive without a decision past LAUNCH_WAIT, abort rather than race it.
    # Which engine the dispatcher resolves to on THIS host, probed once, before the
    # first attempt: an arm64 arm and a pinned x86 arm are not the same measurement,
    # and this chain's log has to say which one it started rather than leaving it to
    # whoever reads the report afterwards. One `-version` container, ~1 s, at a
    # moment the box is known free -- the retry loop below starts the real one next,
    # and its `docker ps` gate would refuse if this one were still up (it is not:
    # the call is synchronous).
    EP=$(engine_probe)
    ENGINE_CLASS=$(engine_class "$EP")
    say "ARM_ENGINE engine=$ENGINE class=$ENGINE_CLASS version='${EP:-none}'"

    attempt=0; launched=0
    while [ "$attempt" -lt "$ATTEMPTS" ]; do
        attempt=$((attempt+1))
        : > "$MARK"
        A0=$(date -u +%s)
        DIE_TAG="$TAG" DIE_PREDRT_OVERRIDE="$OVERRIDE" PREDRT_OR="$ENGINE" PREDRT_PATCH_LLN=1023 \
            PREDRT_STOP="$STOP" DIE_PHASE_A_ONLY=1 DIE_ARM_STATE="$MARK" \
            nohup setsid bash "$CHILD" >/dev/null 2>&1 </dev/null &
        say "ARM_LAUNCHED attempt=$attempt tag=$TAG via=$CHILD engine=$ENGINE class=$ENGINE_CLASS patch=1023 stop=$STOP override='${OVERRIDE:-none}'"
        L0=$(date -u +%s)
        while :; do
            # The child's line is `LAUNCHED tag=<tag> container=die_predrt`, so match the
            # tag as a token, not the whole line: an exact-line test here never fires.
            if grep -aqE "^LAUNCHED tag=$TAG( |$)" "$MARK" 2>/dev/null; then
                launched=1; break
            fi
            # Absence has to be seen twice before it means anything. Between the
            # `&` above and its exec, the child still carries the launching shell's
            # cmdline, so pgrep cannot see it yet -- and on a contended machine that
            # window is wide enough to be sampled. CI, 2026-10-22: a 50 s arm was
            # declared missing on the first poll, relaunched, and the run logged two
            # launches for one arm, which is the exact failure this loop exists to
            # prevent. A child that exited stays exited; a child that is starting
            # appears. The marker is re-read while the confirmation waits, because
            # the child can decide and exit inside those two seconds.
            if ! pgrep -f "$CHILD\$" >/dev/null 2>&1; then
                sleep 2
                if grep -aqE "^LAUNCHED tag=$TAG( |$)" "$MARK" 2>/dev/null; then
                    launched=1; break
                fi
                if ! pgrep -f "$CHILD\$" >/dev/null 2>&1; then
                    LAST=$(tail -1 "$MARK" 2>/dev/null)
                    say "ARM_RETRY attempt=$attempt -- the pre-DRT chain exited without launching (marker: ${LAST:-none}; see $CHAINLOG)"
                    break
                fi
            fi
            if [ $(( $(date -u +%s) - L0 )) -ge "$LAUNCH_WAIT" ]; then
                say "ARM_ABORT launch_wait_timeout_${LAUNCH_WAIT}s attempt=$attempt -- the chain is alive and has not launched; refusing to start a second arm over it (marker: $(tail -1 "$MARK" 2>/dev/null || echo none); see $CHAINLOG)"
                exit 1
            fi
            sleep 10
        done
        [ "$launched" = 1 ] && break
        # No backoff after the last attempt: the abort below is the answer, and a
        # five-minute sleep in front of it is five minutes nobody asked for.
        [ "$attempt" -ge "$ATTEMPTS" ] && break
        say "ARM_RETRY_BACKOFF ${RETRY_WAIT}s before attempt $((attempt+1))"
        sleep "$RETRY_WAIT"
    done
    if [ "$launched" != 1 ]; then
        say "ARM_ABORT not_launched after $ATTEMPTS attempts"; exit 1
    fi
    say "ARM_CONTAINER_UP $(docker ps --format '{{.Names}}' | tr '\n' ' ')"

    # Watch the step from the moment its directory exists: the project's own
    # instrument, log-only, its own output directory, extension OFF (the box queue
    # here is long enough already; the deeper run can be asked for deliberately).
    WATCHED=0
    while :; do
        if [ "$WATCHED" = 0 ] && [ -d "$STEPDIR" ]; then
            WATCH_CONTAINER=die_predrt WATCH_EXTEND="$WATCH_EXTEND" \
                nohup setsid bash "$WS/watch_drt_curve.sh" --tag "$TAG" \
                >> "$WS/logs/drt_watch_$TAG.nohup" 2>&1 </dev/null &
            WATCHED=1
            say "WATCHER_STARTED tag=$TAG extend=$WATCH_EXTEND"
        fi
        C=$(docker ps --format '{{.Names}}' | grep -c '^die_predrt$' || true)
        [ "$C" = 0 ] && ! pgrep -f 'build/die_drt_chain.sh$' >/dev/null 2>&1 && break
        sleep 120
    done
    A1=$(date -u +%s)
    ARM_WALL_MIN=$(( (A1-A0)/60 ))
    say "ARM_DONE wall=${ARM_WALL_MIN}m container_rc=$(docker inspect -f '{{.State.ExitCode}}' die_predrt 2>/dev/null || echo gone)"
fi

# ---- the report ---------------------------------------------------------------
SRC=$(source_log)
# What engine this arm ran, read from the arm's OWN logs -- not from this host's
# dispatcher, which may be a different machine than the one that wrote them (the
# report is also rewritten by DIE_DIO_HARVEST=1) and resolves for the host it is
# asked on, not for the arm. The class decides the two things below that are only
# true of the pinned engine.
ARM_ENGINE_REC=$(arm_engine_line)
ARM_ENGINE_VERSION=$(printf '%s\n' "${ARM_ENGINE_REC:-}" | cut -d' ' -f3- | sed 's/[[:space:]]*$//')
ARM_ENGINE_CLASS=$(engine_class "$ARM_ENGINE_VERSION")
mkdir -p "$D/verdict"
{
    printf '# The die'"'"'s flow, end to end, on a diode-repaired database\n\n'
    printf 'Written %s UTC by `build/die_diode_flow_chain.sh` (tag `%s`).\n' "$(date -u '+%F %T')" "$TAG"
    case "$ARM_ENGINE_CLASS" in
        image)  printf 'It is the same frozen state every pre-DRT arm resumes from, run with\n'
                printf 'the flow'"'"'s antenna repair UNRESTRICTED -- but on the engine that cannot\n'
                printf 'complete it (see the engine line below), so read it as the observation\n'
                printf 'arm: what the flow and the router do on this database.\n\n' ;;
        *)      printf 'It is the arm the die did not have: the same frozen state every pre-DRT arm\n'
                printf 'resumes from, run with the flow'"'"'s antenna repair able to COMPLETE, and then\n'
                printf 'routed by the flow'"'"'s own `OpenROAD.DetailedRouting` step.\n\n' ;;
    esac
    printf '## The arm\n\n'
    printf '* resume state `%s` — the same `ws_v3` step-36 state `diejmp01` and every\n' "$STATE"
    printf '  probe consumed, so the database the router sees is the only variable this arm\n'
    printf '  shares with them.\n'
    printf '* steps: `OpenROAD.GlobalRouting` → antenna repair → `OpenROAD.STA*` →\n'
    printf '  `OpenROAD.DetailedRouting` (`PREDRT_STOP=%s`).\n' "$STOP"
    # The engine as the ARM's own container logged it -- not as this host would
    # resolve it today, and (on arm64) not the pinned build at all. The class picks
    # which of the three paragraphs is true, so no log of this chain claims the pin
    # for an arm that ran the image's own engine.
    printf '* engine: `%s`%s\n' "$ENGINE" "${ARM_ENGINE_VERSION:+ (as the arm logged it: $ARM_ENGINE_VERSION)}"
    case "$ARM_ENGINE_CLASS" in
        pinned) printf '  OpenROAD 26Q4, the build whose FastRoute recovery completes the\n'
                printf '  repair the pinned build aborts (GRT-0183).\n' ;;
        image)  printf '  the pre-check image'"'"'s own build under stdbuf -oL: this is the\n'
                printf '  OBSERVABILITY arm, not the repair arm. The pinned 26Q4 engine\n'
                printf '  publishes amd64 only, so nothing on this host can complete the\n'
                printf '  antenna repair (ws/tools/openroad_arm64.sh) -- the router numbers\n'
                printf '  below are the router'"'"'s own, on the database this flow produced.\n' ;;
        *)      printf '  no engine line in the arm'"'"'s logs (PREDRT openroad_override=), so\n'
                printf '  this report cannot say which engine ran -- see the failure\n'
                printf '  section below.\n' ;;
    esac
    printf '* LibreLane backport `#1023` applied in-container (`%s`); without it this arm\n' "$PATCH"
    printf '  dies as step 01 finishes (`[ERROR STA-0107] ..._p_Scene is not the name of a\n'
    printf '  scene`, measured on run `diepin02`).\n'
    printf '* antenna-repair config: %s\n' "${OVERRIDE:-the staged file, unmodified -- no GRT_ANTENNA_REPAIR_* override}"
    printf '* wall (launch → exit): %s min; the repaired database and the routed result are\n' "${ARM_WALL_MIN:-?}"
    printf '  under `runs/%s/`.\n\n' "$TAG"

    printf '## What the antenna repair produced — the point of the arm\n\n'
    if [ -d "$REPAIR" ]; then
        printf '```\n'
        grep -ahoE '\[INFO GRT-(0012|0015|0302)\][^|]*' "$REPAIR"/*/*.log 2>/dev/null | tail -12 | sed 's/^/  /'
        printf '```\n\n'
        printf 'Compare the jumper-only arm, whose repair could not finish on the pinned build:\n'
        printf '1209 antenna violations left and 0 diodes (die_to_drt_antenna_and_pin.md §2).\n\n'
    else
        printf 'No repair step directory at `%s` — the flow did not get that far; see the\n' "$REPAIR"
        printf 'failure section below.\n\n'
    fi

    printf '## The flow'"'"'s DetailedRouting on that database\n\n'
    if grep -aqE 'Completing 100% with' "${SRC:-/dev/null}" 2>/dev/null; then
        REACHED=1
        printf 'Source log: `%s`\n\n' "$SRC"
        printf '| pass | initial route | per-iteration series | last (DRT-0199) | antenna found → diodes/jumpers inserted BEFORE this pass |\n'
        printf '|---|---|---|---|---|\n'
        curve_of "$SRC" | while IFS='|' read -r p series last af di ju; do
            afs=$(spaced "${af:-}"); [ -n "$afs" ] || afs="none"
            printf '| %s | %s | %s | %s | %s |\n' "$p" "$(commas "$(printf '%s' "$series" | awk '{print $1}')")" \
                "$(spaced "$series")" "$(commas "$last")" \
                "$afs found → $(commas "${di:-0}") diodes / $(commas "${ju:-0}") jumpers"
        done
        MEMS=$(mem_source)
        printf '\n* peak memory `%s` MB (from `%s`); the step'"'"'s own `runtime.txt` says `%s`.\n' \
            "$(commas "$(peak_mem "${MEMS:-$SRC}")")" "${MEMS:-$SRC}" "$(cat "$STEPDIR/runtime.txt" 2>/dev/null || echo 'not written yet')"
        printf '* the router'"'"'s final total (`DRT-0199`) is `%s`.\n\n' "$(commas "$(last_total "$SRC")")"
    else
        REACHED=0
        printf '**The flow did not reach detailed routing.** The arm'"'"'s result is the\n'
        printf 'failure, quoted exactly, because "the backport is sufficient end to end" is the\n'
        printf 'thing this arm was built to test:\n\n```\n'
        grep -aE 'ERROR|Error:|STA-0107|GRT-0183|Traceback' "${SRC:-/dev/null}" 2>/dev/null | tail -12 | sed 's/^/  /'
        printf '```\n\nRun tree: `%s`\n\n' "$(ls -1 "$RUN" 2>/dev/null | tr '\n' ' ')"
    fi

    printf '## Compared with the arm in flight (jumper-only, pinned build)\n\n'
    printf '| arm | engine | pre-DRT database | DRT pass 0 | pass 0 last | pass 1 (after the step'"'"'s own repair) |\n'
    printf '|---|---|---|---|---|---|\n'
    printf '| `diejmp01` | pinned `dcf36133` | jumper-only, 1209 antenna violations left, 0 diodes | 446,541 → 303,874 → 296,214 → 125,994 → … | **27,758** (5:45:12, peak 9,065 MB) | 854,844 → 513,688 → 473,460 → 415,213 → … (the step put 4,013 diodes into the ROUTED database and restarted) |\n'
    # This row is about THIS arm, so its engine cell is the same fact as the
    # `* engine:` bullet above and is read from the same class. It was written as a
    # bare "26Q4 pin" until 2026-10-26, which made it the one line of an arm64 report
    # that still claimed the pin -- on the arm that ran the image's own build it was
    # wrong in the engine cell AND in the database cell (that repair does not
    # complete).
    case "$ARM_ENGINE_CLASS" in
        pinned) OUR_ENGINE="26Q4 pin" ;;
        image)  OUR_ENGINE="the image's own build" ;;
        *)      OUR_ENGINE="unknown" ;;
    esac
    case "$ARM_ENGINE_CLASS" in
        pinned) OUR_DB="the flow's own completed repair" ;;
        image)  OUR_DB="the repair this build makes before GRT-0183 (see above)" ;;
        *)      OUR_DB="the repair, as far as it got (see above)" ;;
    esac
    # ... and the three routing columns pointed at "the table above", which does not
    # exist on an arm that stopped before the router.
    if [ "${REACHED:-0}" = 1 ]; then
        OUR_D0="see the table above"; OUR_D1="see above"; OUR_D2="see above"
    else
        OUR_D0="none — the flow stopped in the repair (see above)"; OUR_D1="none"; OUR_D2="none"
    fi
    printf '| `%s` | %s | %s | %s | %s | %s |\n\n' "$TAG" "$OUR_ENGINE" "$OUR_DB" "$OUR_D0" "$OUR_D1" "$OUR_D2"

    printf '## What this does and does not establish\n\n'
    printf '* This arm differs from the pinned arm in TWO ways — the engine and the repair the\n'
    printf '  engine makes possible — because the pinned build cannot run the repair at all.\n'
    printf '  The engine half is isolated separately and cheaply by the fast-loop comparison\n'
    printf '  (`drt_fast/verdict/die_drt_db_compare.md`), which routes the same database under\n'
    printf '  both builds.\n'
    printf '* One run, one seed, one box. The step log is block-buffered and lags the flow log\n'
    printf '  while it runs; both are complete at exit, which is why this report is written\n'
    printf '  after the container is gone.\n'
    printf '* If the flow stopped before DetailedRouting, this report says so with the exact\n'
    printf '  error rather than an empty table — that would mean the #1023 backport is not\n'
    printf '  sufficient end to end, which is itself the finding.\n'
    printf '* Logs: `%s`, `%s`, `%s`; chain log `%s`.\n' "$CLOG" "$FLOG" "$CHAINLOG" "$LOG"
} > "$OUT"

say "REPORT_WRITTEN $OUT"
say "DIE_DIO_FLOW_COMPLETE tag=$TAG"
exit 0
