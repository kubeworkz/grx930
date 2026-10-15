#!/bin/bash
# watch_drt_curve.sh -- watch a LibreLane OpenROAD.DetailedRouting step's own
# iteration curve and write the verdict automatically: CONVERGING / STALLED /
# DIVERGED / CLEAN. Runs on the flow box (host side, reading the mounted run
# tree); nothing here is needed inside the container.
#
#   nohup ws/watch_drt_curve.sh --tag ws_v4 > ws/logs/drt_watch.nohup 2>&1 &
#   ws/watch_drt_curve.sh --log <file> --once          # analyze a finished log
#   ws/watch_drt_curve.sh --selftest                   # fixtures, no run needed
#
# Why this exists
# ---------------
# `DRT_OPT_ITERS: 8` in grx930_overrides.yaml bounds ONE detailed_route pass, so
# that a run reaches a routing verdict in hours instead of days (the default 64
# is ~28 h on this design at the measured ~26 min/iteration, and the one
# unbounded run this design has, v8, sat in DRT for 10.6 days). That cap is a
# decision, and a decision needs an instrument: this is it. It reads the curve
# the router writes itself, in the run's own log, and says what it is doing.
#
# The thing that is easy to get wrong: the DRT *step* is not one routing job.
# `librelane/scripts/openroad/drt.tcl:85-121` runs `detailed_route` once
# (`drt-run-0`), then loops on `check_antennas` / `repair_antennas` and re-runs
# the whole route (`drt-run-1`, ...) while diodes are being inserted, up to
# `DRT_ANTENNA_REPAIR_ITERS` times -- 10 here, and every pass gets a fresh
# `-droute_end_iter` budget. So the step's cost is bounded by
# (1 + DRT_ANTENNA_REPAIR_ITERS) x (initial route + DRT_OPT_ITERS iterations),
# not by DRT_OPT_ITERS alone, and this script therefore segments the log into
# passes and classifies each pass on its own.
#
# What it reads
# -------------
# Every pass writes, per optimization iteration, one authoritative line:
#
#   [INFO DRT-0195] Start 3rd optimization iteration.
#   [INFO DRT-0199]   Number of violations = 278169.
#   [INFO DRT-0267] cpu time = ..., elapsed time = 01:25:39, memory = ...
#
# `DRT-0199` is the count to use: it is the post-iteration total TritonRoute
# reports itself, where the `Completing 100% with N violations` progress line is
# a slightly different number for the same iteration (v8 iteration 0:
# 1,040,718 vs 1,081,775) and is the line an earlier script parsed by accident
# (build/arm_verdict_capture.sh, bug 1 in its header). Progress lines are
# overwritten with \r, so the parser maps \r to \n before matching; a line split
# by an in-flight write is simply re-read on the next poll, which is why the
# parser is run over the whole file and not over a byte-offset delta.
#
# The rules, and where they come from
# -----------------------------------
# The only full-length curve this design has is v8 (fat core, GRT 0.0,
# build/v8_flow.log, 27 counts). It is the instrument every threshold is set
# against:
#
#   iteration   0        1        2        4        8        12       16        17       25
#   violations  1,081,775 405,529  387,049  266,147  254,306  242,556  237,089   649,172  711,100
#
#   * CLEAN     -- the iteration's count is 0; the TrDRC gate
#                  (ERROR_ON_TR_DRC, threshold 0) can pass.
#   * CONVERGING-- still falling faster than the stall rate. Not a final answer,
#                  but the report is still written (a curve with no verdict on it
#                  is a curve nobody can act on) -- that is the state every run
#                  starts in and the one the tapeout layout's 0.2 arm is in,
#                  measured at -65.3 % then -4.3 % per iteration.
#   * DIVERGED  -- a count at or above WATCH_SPIKE_X (2.0) x the best count seen
#                  in the pass. v8's jump at iteration 17 is 2.74x its own
#                  minimum (237,089 -> 649,172) and the run never came back
#                  below 417k, so a single reading that far above the best is not
#                  noise. A milder regression is only called when two
#                  consecutive counts each sit at or above WATCH_REGRESS_X (1.25)
#                  x the best -- one bad iteration is not a verdict.
#   * STALLED   -- the mean gain over the last WATCH_STALL_K (3) iterations is
#                  under WATCH_STALL_PCT (1 %) per iteration while the best count
#                  is still above WATCH_STALL_FLOOR (1000). This is the honest
#                  reading of v8 iterations 6-16 (-1.0 %, -0.9 %, -0.8 %, ...
#                  -0.5 %): a plateau at 250k cannot reach a gate of 0, however
#                  many of its 64 iterations are spent. It is a flag by default,
#                  because the antenna passes that follow CAN move the count --
#                  that is what they are for.
#
# (CONVERGING is the default state: something is still coming down.)
#
# What it does about it
# ---------------------
# Default is flag-only: write the report, keep watching, touch nothing. With
# `--kill` (or WATCH_KILL=1) it stops the step when the verdict is DIVERGED
# (WATCH_KILL_ON selects `diverged`, `stalled` or `both`). The stop is surgical:
# SIGTERM to the `openroad` process whose command line names the detailed-routing
# script, so LibreLane raises the step error and writes its own logs; the
# container and the chain script survive and can report the verdict. Falling back
# to `docker stop` needs WATCH_KILL_HARD=1 -- SIGTERM to the OpenROAD process is
# the one that leaves a consistent run tree.
#
# Output (WATCH_OUT, default the ws/logs directory next to the run tree):
#   drt_verdict.md    the report: verdict, per-iteration curve with wall clock,
#                     the rule that fired with its numbers, what it means for the
#                     gate, and what is left unmeasured.
#   drt_verdict.txt   one line, machine-readable, for a chain script to pick up.
#   drt_watch.log     append-only event log.
#   drt_state.tsv     per-iteration first-seen timestamps (the wall-clock measure).
#   drt_cap_cost.md   written when the step finishes (runtime.txt appears) or with
#                     `--finalize`: the per-pass curve, the measured per-iteration
#                     wall clock on this die against the core-only baseline, the count
#                     standing at the cap, a labelled extrapolation, and the exact
#                     fast-loop command that measures the iterations the cap withheld.
#
# Closing the loop automatically: the extrapolation in that report is the one thing
# in it that is not a measurement, and it is the one thing the run can measure for
# itself. So when the step finishes with the tail still falling faster than this
# instrument's own stall rate, this script hands
# the pre-DRT database to `drt_extend_ws.sh` (setsid, own log), which waits for the
# flow container to exit, passes the same gate every chain here uses, runs the fast
# loop past the cap, and writes `drt_cap_cost_measured.md`. Nothing else launches it
# and nobody has to be watching. WATCH_EXTEND=0 (or --no-extend) turns it off;
# WATCH_EXTEND_ITERS sets the extension's -droute_end_iter (16 = 2x the usual cap).
#
# Tuning (env, defaults): WATCH_POLL=60 s, WATCH_SPIKE_X=2.0, WATCH_REGRESS_X=1.25,
# WATCH_STALL_K=3, WATCH_STALL_PCT=1.0, WATCH_STALL_FLOOR=1000, WATCH_DEADLINE_H=24
# (IDLE hours -- hours without a new count -- not wall clock, so a watcher started
# with the flow outlives the hours of placement and CTS before the router starts),
# WATCH_CONTAINER=ws_flow, WATCH_RUNS=..., WATCH_OUT=..., WATCH_KILL=0,
# WATCH_KILL_ON=diverged|stalled|both, WATCH_KILL_HARD=0,
# WATCH_EXIT_ON_VERDICT=0|1, WATCH_EXTEND=1, WATCH_EXTEND_ITERS=16,
# WATCH_EXTEND_PCT=<STALL_PCT> (how fast the tail has to be falling to buy the
# extension), WATCH_EXTEND_DEADLINE_H=48,
# WATCH_RUNNER=<drt_extend_ws.sh beside this file>.
#
# Exit code with WATCH_EXIT_ON_VERDICT=1 (for a foreground chain):
#   0 CONVERGING at the end of watching, 2 STALLED, 3 DIVERGED, 4 CLEAN.
set -u

WS=${WATCH_WS:-/home/ubuntu/grx930_ol2/ws}
RUNS=${WATCH_RUNS:-$WS/template/librelane/runs}
OUT=${WATCH_OUT:-$WS/logs}
CONTAINER=${WATCH_CONTAINER:-ws_flow}

TAG=""
LOGFILE=""
ONCE=0
FINALIZE=0
SELFTEST=0
KILL=${WATCH_KILL:-0}
KILL_ON=${WATCH_KILL_ON:-diverged}
KILL_HARD=${WATCH_KILL_HARD:-0}
POLL=${WATCH_POLL:-60}
SPIKE_X=${WATCH_SPIKE_X:-2.0}
REGRESS_X=${WATCH_REGRESS_X:-1.25}
STALL_K=${WATCH_STALL_K:-3}
STALL_PCT=${WATCH_STALL_PCT:-1.0}
STALL_FLOOR=${WATCH_STALL_FLOOR:-1000}
DEADLINE_H=${WATCH_DEADLINE_H:-24}
EXIT_ON_VERDICT=${WATCH_EXIT_ON_VERDICT:-0}
EXTEND=${WATCH_EXTEND:-1}
EXTEND_ITERS=${WATCH_EXTEND_ITERS:-16}
EXTEND_DEADLINE_H=${WATCH_EXTEND_DEADLINE_H:-48}
EXTEND_PCT=${WATCH_EXTEND_PCT:-$STALL_PCT}
SELFDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUNNER=${WATCH_RUNNER:-$SELFDIR/drt_extend_ws.sh}

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --tag NAME     run tag to watch        (default: newest run dir under $RUNS)
  --log FILE     analyze this log file instead of searching the run tree
  --once         parse once, write the report, exit
  --finalize     also write the cap-cost report at the end (implied when the
                 step finishes while watching); exits after it
  --no-extend    do not queue the fast-loop extension when the step finishes
                 (WATCH_EXTEND=0)
  --kill         arm the kill (WATCH_KILL=1)
  --selftest     run the built-in fixtures and exit (no run needed)
  --help         this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG=${2:-}; shift 2 ;;
        --log) LOGFILE=${2:-}; shift 2 ;;
        --once) ONCE=1; shift ;;
        --finalize) FINALIZE=1; ONCE=1; shift ;;
        --no-extend) EXTEND=0; shift ;;
        --kill) KILL=1; shift ;;
        --selftest) SELFTEST=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

EVENTS=$OUT/drt_watch.log
REPORT=$OUT/drt_verdict.md
STATUS=$OUT/drt_verdict.txt
STATE=$OUT/drt_state.tsv

say() { echo "[$(date -u '+%F %T')] $*" >> "$EVENTS"; }
now() { date -u +%s; }
fmt() { date -u -d "@${1}" '+%F %T' 2>/dev/null || echo "${1}"; }

# ---------------------------------------------------------------- parser ----
# Emits "<pass> <iteration> <count>" for every DRT-0199 count, pass 0 = the first
# `Start 0th optimization iteration`, pass N = the Nth re-route the antenna loop
# asked for. Iteration numbering restarts inside each pass, like the router's own.
parse_curve() {
    tr '\r' '\n' < "$1" 2>/dev/null | awk '
        /Start 0th optimization iteration/ { if (seen0) pass++; seen0 = 1; iter = 0; next }
        /DRT-0199/ {
            if (match($0, /Number of violations = [0-9]+/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/.*= /, "", s)
                printf "%d %d %s\n", pass + 0, iter + 0, s
                iter++
            }
        }'
}

# Which step log to read: the newest run tree's detailed-routing step log. The
# file is named after the step (`openroad-detailedrouting.log`), but the search
# does not depend on that: it takes any *.log under a `*-openroad-detailedrouting`
# dir that actually carries DRT-0199 lines, newest first.
find_log() {
    local run step f
    if [ -n "$TAG" ]; then
        run=$RUNS/$TAG
    else
        run=$(ls -dt "$RUNS"/*/ 2>/dev/null | head -1)
        run=${run%/}
    fi
    [ -n "${run:-}" ] && [ -d "$run" ] || return 1
    for step in $(ls -dt "$run"/*-openroad-detailedrouting/ 2>/dev/null); do
        for f in "$step"openroad-detailedrouting.log "$step"*.log; do
            [ -f "$f" ] || continue
            grep -aq 'DRT-0199' "$f" 2>/dev/null && { printf '%s\n' "$f"; return 0; }
        done
    done
    return 1
}

# ------------------------------------------------------------------ state ---
# drt_state.tsv: pass<TAB>iter<TAB>count<TAB>first_seen_epoch. Only ever grows;
# a re-read of an old log does not restamp rows it already knows.
state_get() {  # $1 pass, $2 iter -> count or empty
    awk -F'\t' -v p="$1" -v i="$2" '$1==p && $2==i {print $3; exit}' "$STATE" 2>/dev/null
}
state_seen() { # $1 pass, $2 iter -> timestamp or empty
    awk -F'\t' -v p="$1" -v i="$2" '$1==p && $2==i {print $4; exit}' "$STATE" 2>/dev/null
}
state_add() {  # $1 pass, $2 iter, $3 count, $4 ts
    [ -f "$STATE" ] || : > "$STATE"
    awk -F'\t' -v p="$1" -v i="$2" \
        '!($1==p && $2==i) {print}' "$STATE" > "$STATE.tmp" 2>/dev/null
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STATE.tmp"
    sort -n -k1,1 -k2,2 "$STATE.tmp" > "$STATE"
    rm -f "$STATE.tmp"
}

# ------------------------------------------------------------- classifier ---
gain_pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (a > 0) printf "%.3f", (b - a) * 100.0 / a; else print "0" }'; }

# classify <count>... -> "VERDICT best last n last_gain meanK_gain"
classify() {
    local -a v=("$@")
    local n=${#v[@]}
    [ "$n" -gt 0 ] || { echo "NO_DATA 0 0 0 0 0"; return; }
    local best=${v[0]} last=${v[$((n - 1))]} i g sum=0 k steps=0
    for i in "${v[@]}"; do [ "$i" -lt "$best" ] && best=$i; done
    local lastgain=0 meangain=0
    if [ "$n" -ge 2 ]; then
        lastgain=$(gain_pct "${v[$((n - 2))]}" "$last")
        k=$STALL_K; [ "$k" -gt $((n - 1)) ] && k=$((n - 1))
        for ((i = n - k; i < n; i++)); do
            g=$(gain_pct "${v[$((i - 1))]}" "${v[$i]}")
            sum=$(awk -v a="$sum" -v b="$g" 'BEGIN { print a + b }')
            steps=$((steps + 1))
        done
        [ "$steps" -gt 0 ] && meangain=$(awk -v a="$sum" -v b="$steps" 'BEGIN { printf "%.3f", a / b }')
    fi

    local verdict=CONVERGING
    if [ "$last" -eq 0 ]; then
        verdict=CLEAN
    else
        if awk -v l="$last" -v b="$best" -v x="$SPIKE_X" 'BEGIN { exit !(l >= x * b) }'; then
            verdict=DIVERGED
        elif [ "$n" -ge 3 ]; then
            # The last TWO readings, not the last two before the last: a 1.25x-2x
            # regression is only a verdict if it failed to come back.
            if awk -v a="${v[$((n - 2))]}" -v l="$last" -v m="$best" -v x="$REGRESS_X" \
                'BEGIN { exit !(a >= x * m && l >= x * m) }'; then
                verdict=DIVERGED
            fi
        fi
        if [ "$verdict" = CONVERGING ] && [ $((n - 1)) -ge "$STALL_K" ] && [ "$best" -gt "$STALL_FLOOR" ] \
            && awk -v g="$meangain" -v s="$STALL_PCT" 'BEGIN { exit !(g > -s) }'; then
            verdict=STALLED
        fi
    fi
    echo "$verdict $best $last $n $lastgain $meangain"
}

# ----------------------------------------------------------------- report ---
write_report() {  # $1 verdict, $2 pass, $3 best, $4 last, $5 n, $6 lastgain, $7 meangain, $8 log, $9 killnote
    local verdict=$1 pass=$2 best=$3 last=$4 n=$5 lastgain=$6 meangain=$7 log=$8 killnote=${9:-}
    # The caption must not claim a run tree the log does not belong to: a foreign
    # log (the fast loop, an OL2 run) is named by its own file.
    local tag
    if [ -n "$TAG" ]; then
        tag=$TAG
    else
        case "$log" in
            "$RUNS"/*/*) tag=$(basename "$(dirname "$(dirname "$log")")") ;;
            *) tag=$(basename "$log" .log) ;;
        esac
    fi
    local iters=$((n - 1))
    local cap="unknown (no resolved.json belongs to this log)"
    if [ -n "${RESOLVED:-}" ] && [ -f "$RESOLVED" ]; then
        cap=$(grep -o '"DRT_OPT_ITERS": [0-9]*' "$RESOLVED" 2>/dev/null | grep -o '[0-9]*' | head -1)
        cap="DRT_OPT_ITERS=${cap:-?} (this run's cap; each pass in the step gets a fresh budget of it)"
    fi
    local gate="ERROR_ON_TR_DRC is True with threshold 0 (see Claude outputs/slew_violation_sources.md)"
    {
        echo "# DRT iteration curve — verdict: $verdict"
        echo
        echo "Watched by \`wafer_space_integration/watch_drt_curve.sh\` ($(date -u '+%F %T') UTC)."
        echo "Run tag \`$tag\`; log \`$log\`; iteration budget $cap; gate: $gate."
        [ -n "$killnote" ] && echo && echo "**Action taken:** $killnote"
        echo
        echo "| pass | iteration | violations | change vs prev (%) | first seen (UTC) | wall since prev |"
        echo "|---|---|---|---|---|---|"
        echo "| | | | negative = fewer violations than the previous iteration | | |"
        local p i c ts prev prev_ts
        prev=""; prev_ts=""
        while read -r p i c ts; do
            [ -n "$p" ] || continue
            local g="—" w="—"
            if [ -n "$prev" ]; then
                g=$(gain_pct "$prev" "$c")
                case "$g" in -*) ;; *) g="+$g" ;; esac
            fi
            local pts=$ts
            if [ -n "$prev_ts" ] && [ -n "$ts" ]; then
                w=$(awk -v a="$prev_ts" -v b="$ts" 'BEGIN { printf "%d:%02d", (b-a)/60, (b-a)%60 }')
            fi
            echo "| $p | $i | $c | $g | $(fmt "$ts") | $w |"
            prev=$c; prev_ts=$ts
        done < <(awk -F'\t' -v p="$pass" '$1==p {print}' "$STATE" 2>/dev/null | sort -n -k2,2)
        echo
        echo "**Verdict: $verdict** — best $best, last $last after $iters optimization"
        echo "iterations; last step $(gain_pct "$prev" "$last") %, mean of the last $STALL_K steps $meangain %."
        case "$verdict" in
            DIVERGED) echo
                echo "The router went back up: $last is $(awk -v l="$last" -v b="$best" 'BEGIN { printf "%.2f", l / b }')x the best count"
                echo "this pass has reached ($best). In the only full-length run on this design that is what"
                echo "happened at iteration 17 (237,089 -> 649,172, 2.74x) and it never recovered. Nothing"
                echo "useful is left in this pass; the count has to come down by re-planning, not by iterating." ;;
            STALLED) echo
                echo "The curve has plateaued above the gate: mean gain $meangain %/iteration, best $best."
                echo "The gate needs 0. v8's plateau behaved the same way (-1.0 %, -0.9 %, -0.8 %, ... -0.5 % per"
                echo "iteration) and ended at 237,089 after 16 iterations -- it never approached zero. Read this"
                echo "as \"more iterations will not close this\". The antenna-repair passes inside this same step"
                echo "CAN move the count (that is what they are for); this flag is per pass, not final." ;;
            CLEAN) echo
                echo "Clean: the last iteration reported no violations. The TrDRC gate can pass." ;;
            *) echo
                echo "Still falling: $(gain_pct "$prev" "$last") % on the last step, mean $meangain % over the"
                echo "last $STALL_K. No verdict against the gate yet -- an interim reading, not a result: the"
                echo "router is still removing violations and the ultimate question is whether it reaches 0." ;;
        esac
        echo
        echo "## What this report does not say"
        echo
        echo "* It is the router's own count, not sign-off: \`Checker.TrDRC\`, KLayout DRC and the rest of"
        echo "  the flow are downstream of this step."
        echo "* Wall clock per iteration is poll-granular ($POLL s) and starts when this script first saw"
        echo "  the line, not when the router emitted it."
        echo "* A stall at pass 0 is not a verdict on the step: passes after it follow antenna repair."
    } > "$REPORT"
    printf 'VERDICT %s tag=%s pass=%s best=%s last=%s n=%s last_gain_pct=%s mean_gain_pct=%s kill=%s ts=%s\n' \
        "$verdict" "$tag" "$pass" "$best" "$last" "$n" "$lastgain" "$meangain" \
        "${killnote:+yes}" "$(date -u '+%F %T')" > "$STATUS"
    say "REPORT verdict=$verdict pass=$pass best=$best last=$last n=$n"
}

# --------------------------------------------------------------- finalize ---
# The cap-cost report. Written when the DRT step is over (LibreLane writes the
# step's runtime.txt at the end, pass or fail), or on `--finalize` by hand.
#
# The question it answers is the one the cap created: what did stopping pass 0 at
# DRT_OPT_ITERS actually cost, measured on THIS die? Three parts, and they are
# kept apart because only the first is a measurement:
#
#   1. the count standing at the cap (measured), and the marginal rate into it;
#   2. the die-size factor: this run's measured per-iteration wall clock against
#      the core-only baseline (26:05 / 25:25 min at 12.93 mm2, drt_fast arm 0.2) --
#      which is the number the "~4 h" figure in grx930_overrides.yaml was a floor for;
#   3. an extrapolation, labelled as one, plus the command that replaces it with a
#      measurement: the fast loop on this step's OWN input ODB (read from the DRT
#      step's state_in.json, so it is the exact database LibreLane routed) with a
#      larger -droute_end_iter. Iterations past the cap did not run, so nothing on
#      disk says what they would have bought -- that is how the cap is paid for.
# ------------------------------------------------------------- extension ----
# The one part of the cap-cost report that is not a measurement is its
# extrapolation, and the run can measure that part for itself -- but only once the
# step is over and only when there is something to measure. The condition lives in
# one function so `--selftest` can exercise it without a run and without waiting
# for a step to finish.
#
#   extend_worthy <pass-0 counts...>
#     sets EXTEND_RATE (the tail rate, %/iteration) and EXTEND_WHY (the reason not
#     to); returns 0 when the iterations past the cap are worth buying.
#
# The threshold is the classifier's own: a pass whose tail is inside STALL_PCT
# (1 %/iteration) is already reported as STALLED -- twelve more iterations of
# -0.9 %/iteration cannot arrive at a gate of 0, and saying so is arithmetic, not
# a measurement. So the extension is bought exactly when the flow's own instrument
# says the curve is still coming down, and skipped (with the reason printed in the
# report, never silently) when it says the curve has plateaued. v8's plateau is the
# case that drew this line: -0.89 %/iteration at its cap of 8.
extend_worthy() {
    local -a v=("$@")
    local n=${#v[@]}
    EXTEND_RATE=""
    [ "$n" -ge 2 ] || { EXTEND_WHY="only $n pass-0 count(s) were captured"; return 1; }
    local last=${v[$((n - 1))]}
    [ "$last" -gt 0 ] || { EXTEND_WHY="the pass already read 0 violations"; return 1; }
    EXTEND_RATE=$(printf '%s\n' "${v[@]}" | awk -v k="$STALL_K" '{c[NR]=$1}
        END { n=NR; s=0; m=0
              for (i=(n-k+1); i<=n; i++) if (i>=2) { s += (c[i]-c[i-1])*100/c[i-1]; m++ }
              if (m>0) printf "%.3f", s/m; else print "0" }')
    if awk -v r="$EXTEND_RATE" -v s="$EXTEND_PCT" 'BEGIN { exit !(r < -s) }'; then
        EXTEND_WHY=""
        return 0
    fi
    EXTEND_WHY="the tail rate is $EXTEND_RATE %/iteration over the last $STALL_K steps -- at or inside the $EXTEND_PCT %/iteration that this same instrument calls a plateau, so more iterations are not the question"
    return 1
}

# Hands the step's own input database to the extension runner and returns
# immediately: the runner detaches itself (its own session), waits for the flow
# container to leave the box, passes the gate, routes, and writes
# drt_cap_cost_measured.md. Nothing here waits for it -- that is the point of
# closing the loop: the step is over, the measurement does not need an operator.
launch_extension() {
    if [ ! -f "$RUNNER" ]; then
        say "EXTEND_SKIP no runner at $RUNNER"
        echo "Not launched: no runner at \`$RUNNER\` (set WATCH_RUNNER)."
        return 1
    fi
    local log=$OUT/drt_extend.nohup pid detach
    # setsid, so the runner gets its own session and outlives this watcher and the
    # shell that started it (the box has it; a machine without it falls back to
    # nohup, which is enough to run the selftest off-box).
    detach=setsid
    command -v setsid >/dev/null 2>&1 || detach=""
    $detach nohup bash "$RUNNER" --odb "$FIN_ODB_C" --tag "${TAG:-run}" \
        --flow-state "$STATE" --end-iter "$EXTEND_ITERS" --cap "${FIN_CAP:-}" \
        --out "$OUT" --deadline-h "$EXTEND_DEADLINE_H" \
        >> "$log" 2>&1 < /dev/null &
    pid=$!
    say "EXTEND_LAUNCHED pid=$pid end_iter=$EXTEND_ITERS odb=$FIN_ODB_C runner=$RUNNER"
    echo "Queued now (pid $pid, detached):"
    echo
    echo '```'
    echo "$RUNNER --odb $FIN_ODB_C --tag ${TAG:-run} --flow-state $STATE \\"
    echo "  --end-iter $EXTEND_ITERS --cap ${FIN_CAP:-none} --out $OUT --deadline-h $EXTEND_DEADLINE_H"
    echo '```'
    echo
    echo "It waits for \`$CONTAINER\` to exit (and re-checks the chains' own memory/disk"
    echo "gate) before it routes, so it cannot fight the flow for the box. Its log is"
    echo "\`$log\`; when it finishes it writes \`$OUT/drt_cap_cost_measured.md\` and appends a"
    echo "pointer to this file."
}

finalize() {  # $1 = reason
    local reason=$1
    local rep=$OUT/drt_cap_cost.md
    local step=${STEPDIR:-}
    local runtime="still running (or never started)"
    local cap="unknown"
    [ -n "$RESOLVED" ] && [ -f "$RESOLVED" ] &&
        cap=$(grep -o '"DRT_OPT_ITERS": [0-9]*' "$RESOLVED" 2>/dev/null | grep -o '[0-9]*' | head -1)
    cap=${cap:-unknown}
    FIN_CAP=$cap
    [ -n "$step" ] && [ -f "$step/runtime.txt" ] && runtime=$(cat "$step/runtime.txt")

    # The DRT step's own input ODB: the authoritative pre-DRT database. LibreLane
    # records that path as the CONTAINER sees it ("\`/work/ws/...\`") and the same
    # file is at the host path ${WS%/ws}/ws/... -- so existence and size have to be
    # checked on the translated path. Checking the container form with -f on the
    # host reports "not found" for every real run, which is how the first version of
    # this report would have priced a database it never located (and handed the
    # extension an empty FAST_ODB, i.e. the default checkpoint).
    local odb="" odb_host="" odbsz=""
    if [ -n "$step" ] && [ -f "$step/state_in.json" ]; then
        odb=$(grep -o '"[^"]*\.odb"' "$step/state_in.json" 2>/dev/null | head -1 | tr -d '"')
        case "$odb" in
            /work/*) odb_host=${WS%/ws}${odb#/work} ;;
            *) odb_host=$odb ;;
        esac
        [ -n "$odb" ] && [ -n "$odb_host" ] && [ -f "$odb_host" ] && odbsz=$(stat -c %s "$odb_host" 2>/dev/null)
    fi

    {
        echo "# DRT cap cost on the assembled die — run ${TAG:-?}"
        echo
        echo "Written $(date -u '+%F %T') UTC by \`wafer_space_integration/watch_drt_curve.sh\` (reason: $reason)."
        echo
        echo "* step: \`${step:-not found}\`"
        echo "* step runtime: $runtime"
        echo "* log: \`${LOG:-none}\`"
        echo "* cap: \`DRT_OPT_ITERS=$cap\`"$([ -n "$RESOLVED" ] && echo " (from \`$RESOLVED\`)")
        echo "* gate: \`Checker.TrDRC\` / \`ERROR_ON_TR_DRC: true\` at threshold 0 — the count has to reach 0"
        echo
        echo "## The curve, per pass"
        echo
        echo "The step re-routes: pass 0 is the capped route, later passes follow antenna repair."
        echo "Each pass gets its own full \`DRT_OPT_ITERS\` budget."
        echo
        echo "| pass | iterations | first | last | best |"
        echo "|---|---|---|---|---|"
        awk -F'\t' '{n[$1]++; if (n[$1]==1) f[$1]=$3; l[$1]=$3; if (!(($1) in b) || $3<b[$1]) b[$1]=$3}
            END { for (p in n) printf "| %s | %d | %s | %s | %s |\n", p, n[p], f[p], l[p], b[p] }' \
            "$STATE" 2>/dev/null | sort -n -k2,2
        echo
        echo "### Pass 0, iteration by iteration (wall clock measured by this watcher)"
        echo
        echo "| iteration | violations | change vs prev (%) | wall since prev |"
        echo "|---|---|---|---|"
        local p i c ts prev prev_ts
        prev=""; prev_ts=""
        while read -r p i c ts; do
            [ -n "$p" ] || continue
            local g="—" w="—"
            if [ -n "$prev" ]; then
                g=$(gain_pct "$prev" "$c")
                case "$g" in -*) ;; *) g="+$g" ;; esac
                [ -n "$prev_ts" ] && w=$(awk -v a="$prev_ts" -v b="$ts" 'BEGIN { printf "%d:%02d", (b-a)/60, (b-a)%60 }')
            fi
            echo "| $i | $c | $g | $w |"
            prev=$c; prev_ts=$ts
        done < <(awk -F'\t' '$1==0 {print}' "$STATE" 2>/dev/null | sort -n -k2,2)
        echo
        echo "## What the cap cost"
        echo
        local pass0 best last nsteps rate recent first_ts last_ts total_min wc_known=0
        # No `sort` here: this is a list of counts, one field per line, and
        # `sort -n -k2,2` on single-field lines has no second key at all -- GNU
        # sort then reorders the list arbitrarily, which made "last" print the
        # FIRST count of the pass and the mean rate come out positive. state.tsv
        # is already written in (pass, iteration) order; file order is the curve.
        pass0=$(awk -F'\t' '$1==0 {print $3}' "$STATE" 2>/dev/null)
        if [ -z "$pass0" ]; then
            echo "No pass-0 curve was captured, so there is nothing to price."
        else
            set -- $pass0
            local n=$# prevv="" sum=0 steps=0
            best=$1; last=$1
            for v in "$@"; do
                [ "$v" -lt "$best" ] && best=$v
                last=$v
                [ -n "$prevv" ] && { g=$(gain_pct "$prevv" "$v"); sum=$(awk -v a="$sum" -v b="$g" 'BEGIN{print a+b}'); steps=$((steps+1)); }
                prevv=$v
            done
            nsteps=$((n - 1))
            rate=$(awk -v a="$sum" -v b="$nsteps" 'BEGIN{ if (b>0) printf "%.3f", a/b; else print "0" }')
            # The tail rate: mean gain over the last STALL_K steps, which is the only
            # part of the curve that says anything about iteration cap+1.
            recent=$(printf '%s\n' $pass0 | awk -v k="$STALL_K" '{v[NR]=$1}
                END { n=NR; s=0; c=0
                      for (i=(n-k+1); i<=n; i++) if (i>=2) { s += (v[i]-v[i-1])*100/v[i-1]; c++ }
                      if (c>0) printf "%.3f", s/c; else print "0" }')
            first_ts=$(awk -F'\t' '$1==0 {print $4}' "$STATE" 2>/dev/null | sort -n | head -1)
            last_ts=$(awk -F'\t' '$1==0 {print $4}' "$STATE" 2>/dev/null | sort -n | tail -1)
            # Minutes as a float: a short capture is still a capture, and an
            # integer would round it to 0 and then be mistaken for "never seen".
            total_min=$(awk -v a="$first_ts" -v b="$last_ts" 'BEGIN{ printf "%.1f", (b-a)/60 }')
            # What the extension has to work from, in one place: it is launched from
            # here, and it needs the same numbers this report prints.
            FIN_NS=$nsteps
            FIN_RATE=$recent
            FIN_MIN=$total_min
            FIN_WORTH=0
            if [ -n "$odb_host" ] && [ -n "$odbsz" ]; then FIN_ODB_C=$odb; FIN_ODB_H=$odb_host; FIN_ODBSZ=$odbsz; fi
            FIN_VERDICT=$(classify $pass0)
            FIN_VERDICT=${FIN_VERDICT%% *}
            echo "* **Standing at the cap:** $last violations after $nsteps optimization iterations"
            echo "  (best $best), against a gate of 0. That number is the measurement; everything below is"
            echo "  what it would take to move it, and how much of that the cap withheld."
            if [ "$nsteps" -lt 2 ]; then
                echo "  **Only the initial route was captured for pass 0.** Either the watcher started after"
                echo "  the step (it can only stamp what it saw arriving), or these lines are not one pass —"
                echo "  a pass begins at every 'Start 0th optimization iteration'. Price this curve only if"
                echo "  the step's log really shows one 0th."
            fi
            echo "* **Rate into the cap:** $recent %/iteration over the last $STALL_K steps, $rate % over"
            echo "  the whole pass. The tail is the one that matters -- a pass's first iteration always"
            echo "  drops hard (the initial route is naive) and says nothing about the 8th."
            if [ "${last_ts:-0}" -gt "${first_ts:-0}" ]; then
                echo "* **Wall clock on this die:** ${total_min} min for $nsteps iterations ="
                echo "  $(awk -v a="$total_min" -v b="$nsteps" 'BEGIN{ printf "%.1f", a/b }') min/iteration, against 26:05 / 25:25 min"
                echo "  measured for the same two iterations on the bare 12.93 mm2 core (drt_fast arm 0.2)."
                echo "  That per-iteration figure is the die-size factor the cap multiplies: the \"~4 h\" in"
                echo "  \`grx930_overrides.yaml\` was a floor, and this is the measurement."
                wc_known=1
            else
                echo "* **Wall clock on this die: not measured.** The whole curve carries one timestamp —"
                echo "  the watcher was started after the router did its work (or this is a foreign log), so"
                echo "  the per-iteration times mean nothing here. The counts above are unaffected; the"
                echo "  die-size factor is not available from this report."
                wc_known=0
            fi
            if awk -v r="$recent" 'BEGIN{ exit !(r < -0.1 && r > -90) }'; then
                local iters_more hours_more
                iters_more=$(awk -v l="$last" -v r="$recent" 'BEGIN{ printf "%.0f", log(1000/l)/log(1+r/100) }')
                hours_more=$(awk -v l="$last" -v r="$recent" -v m="$total_min" -v n="$nsteps" \
                    'BEGIN{ if (n>0) printf "%.1f", (log(1000/l)/log(1+r/100))*m/n/60; else print "?" }')
                echo "* **Extrapolation (labelled as one):** at the tail rate of $recent %/iteration, a geometric"
                echo "  decay from $last reaches 1000 violations after ~$iters_more more iterations."
                [ "$wc_known" = 1 ] && echo "  That is ~$hours_more h of this die's own router time — **if** the rate held."
                if awk -v i="$iters_more" 'BEGIN{ exit !(i > 100) }'; then
                    echo "  That is not a run, it is a rewrite of the routing problem: a plateau decaying this"
                    echo "  slowly does not arrive at a gate of 0 by iterating, which is exactly what the only"
                    echo "  full-length run here showed (v8 spent 10.6 days, reached 237,089 and then diverged at"
                    echo "  iteration 17). Honest reading: the cap withheld iterations that were not going to arrive."
                elif [ "$wc_known" = 1 ] && awk -v h="$hours_more" 'BEGIN{ exit !(h > 48) }'; then
                    echo "  That is longer than the flow itself: the cap did not withhold a route, it declined to"
                    echo "  buy days of a curve that is barely moving. The extension below measures the first"
                    echo "  8 of those iterations rather than trusting this arithmetic for all $iters_more."
                else
                    echo "  That is bounded and short enough to be worth measuring directly — hence the command"
                    echo "  below instead of this arithmetic."
                fi
            else
                echo "* **No extrapolation:** the tail rate ($recent %/iteration) is flat or rising, so more"
                echo "  iterations are not expected to move this count at all. On the measured evidence the cap"
                echo "  cost nothing here — a flat tail is what v8 showed for ten iterations before it diverged."
            fi
        fi

        # Should the withheld iterations be bought? One condition, decided once and
        # printed into the report whichever way it goes -- a loop that silently skips
        # the measurement is worse than no loop, because the report then reads as if
        # there were nothing left to measure.
        EXTEND_SKIP=""
        EXTEND_GO=0
        if [ "$EXTEND" != 1 ]; then
            EXTEND_SKIP="WATCH_EXTEND=0 (switched off for this run)"
        elif [ -z "${FIN_ODB_C:-}" ]; then
            EXTEND_SKIP="the step's state_in.json named no pre-DRT ODB that exists on this host, so there is nothing to re-route"
        elif [ -z "${FIN_NS:-}" ] || [ "${FIN_NS:-0}" -lt 1 ]; then
            EXTEND_SKIP="no usable pass-0 curve was captured (one count is not a curve -- see the wall-clock note above)"
        elif [ -n "$step" ] && [ ! -f "$step/runtime.txt" ]; then
            EXTEND_SKIP="the step has not finished (no runtime.txt), so the count at the cap is still moving"
        elif [ "${FIN_VERDICT:-}" = DIVERGED ]; then
            EXTEND_SKIP="pass 0 diverged: the withheld iterations are not the question, re-planning is"
        elif extend_worthy $pass0; then
            EXTEND_GO=1
        else
            EXTEND_SKIP="$EXTEND_WHY"
        fi
        [ "$EXTEND_GO" = 1 ] || say "EXTEND_SKIP $EXTEND_SKIP"

        echo
        echo "## Measuring what the cap withheld"
        echo
        echo "Iterations $([ "$cap" = unknown ] && echo 'past the cap' || echo "$((cap + 1)) and up") did not run, so no file on this box"
        echo "says what they would have bought. The measurement is the standalone fast loop on the"
        echo "**same input database** LibreLane routed, with a larger cap and the same six"
        echo "\`detailed_route\` arguments (it reproduces a flow's first iterations exactly — the"
        echo "0.2 arm's first three points match the flow run's):"
        echo
        if [ -n "$odb" ] && [ -n "$odbsz" ]; then
            echo "* pre-DRT ODB (from \`$step/state_in.json\`): \`$odb\`"
            echo "  ($odbsz bytes on the host, at \`$odb_host\`)"
        else
            echo "* pre-DRT ODB: **not found** — \`$step/state_in.json\` was missing, named no .odb,"
            echo "  or named one that is not on this host (\`${odb:-none}\` -> \`${odb_host:-none}\`)."
        fi
        echo
        echo '```'
        echo "bash $RUNNER --odb ${odb:-<pre-DRT.odb>} --tag ${TAG:-run} --flow-state $STATE \\"
        echo "  --end-iter $EXTEND_ITERS"
        echo '```'
        echo
        echo "That runner composes the container itself (\`docker run ... -e FAST_ODB=$odb\` with"
        echo "-e flags before the image name, which \`drt_fast/grt03_chain.sh\` gets wrong), waits for"
        echo "the flow container to exit, passes the chains' own gate, and stamps the withheld"
        echo "iterations as they arrive so their wall clock is measured rather than inferred."
        echo
        echo "$EXTEND_ITERS is 2x the cap on purpose: it is the smallest run that shows whether the curve"
        echo "was still falling at $cap (the open question) and it is bounded at roughly 2x this step's own"
        echo "pass-0 time. Run it only when nothing else is routing — it wants all 8 cores, and two"
        echo "routers at once halve both."
        echo
        echo "## Closing the loop (automatic)"
        echo
        if [ "$EXTEND_GO" = 1 ]; then
            echo "The step is over and the tail was still coming down faster than the $EXTEND_PCT %/iteration"
            echo "that the classifier calls a plateau ($FIN_RATE %/iteration over the last"
            echo "$STALL_K counts), so the extension is queued now, detached — nobody has to keep a"
            echo "terminal open. It waits for \`$CONTAINER\` to leave the box, re-checks the same"
            echo "memory/disk gate every chain here uses, then runs $EXTEND_ITERS iterations of the fast"
            echo "loop on the database above and writes \`$OUT/drt_cap_cost_measured.md\`."
            echo
            launch_extension
        else
            echo "Not launched: $EXTEND_SKIP."
            echo
            echo "The measurement is still there to take, by hand, with the same wait and the same"
            echo "gate — the runner is what enforces them:"
            echo
            echo '```'
            echo "bash $RUNNER --odb ${odb:-<pre-DRT.odb>} --tag ${TAG:-run} --flow-state $STATE \\"
            echo "  --end-iter $EXTEND_ITERS"
            echo '```'
        fi
        echo
        echo "## What this report cannot say"
        echo
        echo "* Wall clock is poll-granular ($POLL s) and is stamped when the watcher first sees a line, not"
        echo "  when the router emitted it."
        if [ -n "$step" ] && [ ! -f "$step/runtime.txt" ]; then
            echo "* The step had not finished when this was written, so the last pass may still be growing."
        fi
        echo "* A curve captured by a watcher started after the router began has no per-iteration wall"
        echo "  clocks at all: the first poll stamps every line that already existed with one timestamp."
        echo "  Check drt_watch.log's WATCH_START against the step's runtime before quoting column 4."
        echo "* Pass 0's count at the cap is not a sign-off number: \`Checker.TrDRC\` and the KLayout checks"
        echo "  downstream own that, and antenna repair between passes can move the count afterwards."
        echo "* The fast loop does not create the flow's non-default routing rules; if the template sets"
        echo "  NON_DEFAULT_RULES the extension measures a slightly different routing problem."
    } > "$rep"
    say "FINALIZE reason=$reason report=$rep"
}

# ------------------------------------------------------------------- stop ---
# The surgical stop: SIGTERM the OpenROAD whose command line names the detailed
# routing script. The PID is matched again immediately before the kill, so a
# recycled PID cannot be hit. `docker exec` is not usable on this box
# ("openat etc/group: path escapes from parent"), which is why the process is
# addressed from the host -- it is visible there, as a child of the container.
stop_step() {
    local pid cmd
    # Bracket the first character of both patterns: a plain `grep openroad`
    # matches the grep process's own command line, and the ssh command that
    # launched this script may name these words too.
    pid=$(ps -eo pid,args 2>/dev/null | grep -a '[o]penroad' | grep -a '[d]rt\.tcl' | awk '{print $1}' | head -1)
    if [ -n "$pid" ]; then
        cmd=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$cmd" in
            *drt.tcl*)
                say "KILL pid=$pid (SIGTERM, command line names drt.tcl)"
                kill -TERM "$pid" 2>/dev/null || say "KILL_FAILED pid=$pid"
                sleep 5
                if kill -0 "$pid" 2>/dev/null; then
                    say "KILL pid=$pid still alive after SIGTERM; leaving it (set WATCH_KILL_HARD=1 for docker stop)"
                    [ "$KILL_HARD" = 1 ] && { docker stop "$CONTAINER" >> "$EVENTS" 2>&1; say "KILL docker stop $CONTAINER"; }
                else
                    say "KILL pid=$pid gone"
                fi
                echo "SIGTERM to the detailed-routing OpenROAD process (pid $pid)"
                return 0 ;;
            *) say "KILL_ABORT pid=$pid no longer names drt.tcl" ;;
        esac
    fi
    if [ "$KILL_HARD" = 1 ]; then
        docker stop "$CONTAINER" >> "$EVENTS" 2>&1 && say "KILL docker stop $CONTAINER"
        echo "docker stop $CONTAINER"
        return 0
    fi
    say "KILL_ABORT no OpenROAD process found with drt.tcl in its command line"
    echo "kill requested but no detailed-routing OpenROAD process was found"
}

# ------------------------------------------------------------------- poll ---
# One pass over the log: stamp new rows, then classify the newest pass that has
# data. Prints eight fields, in this order -- the order is the contract with the
# caller and it is easy to get wrong: the first version appended the pass index
# after classify's six fields while the caller read the second field as the pass,
# and the arithmetic in the report then ran on a float ("syntax error: invalid
# arithmetic operator (error token is \".000\")"). The local selftest did not
# catch it because it never ran the report path; the box test did.
#
#   VERDICT pass best last n last_gain_pct mean_gain_pct new_rows
#
# new_rows > 0 means this poll saw a count it had not stored before, which is
# when the report is rewritten.
analyze() {  # $1 log
    local log=$1
    local ts
    ts=$(now)
    local p i c
    local maxp=0 new=0
    while read -r p i c; do
        [ -n "${p:-}" ] || continue
        if [ -z "$(state_seen "$p" "$i")" ]; then
            state_add "$p" "$i" "$c" "$ts"
            new=$((new + 1))
            say "COUNT pass=$p iter=$i violations=$c"
        fi
        [ "$p" -ge "$maxp" ] && maxp=$p
    done < <(parse_curve "$log")
    # The pass with the most recent activity: the highest pass that has any row.
    local rows cls
    rows=$(awk -F'\t' -v p="$maxp" '$1==p {print $3}' "$STATE" 2>/dev/null)
    [ -n "$rows" ] || { printf 'NO_DATA 0 0 0 0 0 0 %s\n' "$new"; return 1; }
    # shellcheck disable=SC2086
    cls=$(classify $rows)
    set -- $cls
    printf '%s %s %s %s %s %s %s %s\n' "$1" "$maxp" "$2" "$3" "$4" "$5" "$6" "$new"
}

# ---------------------------------------------------------------- selftest ---
# Fixtures are real numbers from this design's own runs, so the thresholds are
# tested against the curves they were set from, not against invented ones.
selftest() {
    local fails=0 cases=0
    check() { # $1 name, $2 expected, $3.. values
        local name=$1 exp=$2; shift 2
        local got; got=$(classify "$@")
        local verdict=${got%% *}
        cases=$((cases + 1))
        if [ "$verdict" = "$exp" ]; then
            echo "PASS $name -> $verdict ($got)"
        else
            echo "FAIL $name -> $verdict, expected $exp ($got)"
            fails=$((fails + 1))
        fi
    }
    # v8, the only full-length curve on this design (fat core, GRT 0.0).
    V8="1081775 405529 387049 278169 266147 261189 258601 256296 254306 252998 247107 244082 \
242556 240818 239075 238336 237089 649172 473371 453722 446023 437446 431226 427339 417431 711100"
    # The same curve through its plateau (iterations 0-8): stalled, and correctly so.
    V8_HEAD="1081775 405529 387049 278169 266147 261189 258601 256296 254306"
    # The tapeout layout's own measured arms (slot core 12.93 mm2, fast loop).
    SLOT02="764679 265661 254201"
    SLOT03="659733 207748 191575"
    # shellcheck disable=SC2086
    check "v8 full (diverges at iteration 17)" DIVERGED $V8
    # shellcheck disable=SC2086
    check "v8 through iteration 8 (plateau)" STALLED $V8_HEAD
    # shellcheck disable=SC2086
    check "slot core, GRT 0.2 (still falling)" CONVERGING $SLOT02
    # shellcheck disable=SC2086
    check "slot core, GRT 0.3 (still falling)" CONVERGING $SLOT03
    check "clean tail" CLEAN 10 3 2 1 0
    check "single reading at 2x the best" DIVERGED 1000 900 800 1700
    check "two readings at 1.25x the best" DIVERGED 1000 900 1200 1300
    check "one mild bad iteration is not a verdict" CONVERGING 1000 900 950 800
    check "no data" NO_DATA

    # The automatic extension's one condition. It reads the same curve the report
    # prices, so the cases are the same curves: the tapeout layout's own pass 0 is
    # what the 0.2 arm measured, and v8's plateau is the curve that says "do not
    # buy more iterations".
    ext() { # $1 name, $2 yes|no, rest = counts
        local name=$1 want=$2; shift 2
        cases=$((cases + 1))
        if extend_worthy "$@"; then got=yes; else got=no; fi
        if [ "$got" = "$want" ]; then
            echo "PASS extend $name -> $got (rate=${EXTEND_RATE:-n/a}${EXTEND_WHY:+ why=$EXTEND_WHY})"
        else
            echo "FAIL extend $name -> $got, expected $want (why=${EXTEND_WHY:-none})"
            fails=$((fails + 1))
        fi
        EXTEND_WHY=""
    }
    # shellcheck disable=SC2086
    ext "slot core, GRT 0.2 (-65.3 % then -4.3 %)" yes $SLOT02
    # v8 through its plateau: 254,306 at iteration 8 and -1.0 %/-0.9 %/-0.8 % into it.
    ext "v8's plateau at the cap" no 278169 266147 261189 258601 256296 254306
    ext "a single count is not a curve" no 254201
    ext "a clean pass needs no extension" no 660000 0
    ext "a flat tail buys nothing" no 300000 289000 288000 287500 287400 287350
    ext "a dead-flat pair" no 254201 254201

    # The parser: real line shapes, \r-overwritten progress, two passes in one
    # log (what the antenna-repair loop does), and a split line mid-file.
    local fix=$OUT/.selftest_drt.log
    printf '[INFO DRT-0195] Start 0th optimization iteration.\r    Completing 100%% with 660000 violations.\r[INFO DRT-0199]   Number of violations = 659733.\n[INFO DRT-0195] Start 1st optimization iteration.\r    Completing 100%% with 207748 violations.\r[INFO DRT-0199]   Number of violations = 207748.\n[INFO] Running antenna repair iteration 1…\n[INFO DRT-0195] Start 0th optimization iteration.\r[INFO DRT-0199]   Number of violations = 190000.\n[INFO DRT-0199]   Number of violations = 191575.\n' > "$fix"
    local got; got=$(parse_curve "$fix" | tr '\n' ';')
    cases=$((cases + 1))
    if [ "$got" = "0 0 659733;0 1 207748;1 0 190000;1 1 191575;" ]; then
        echo "PASS parser (two passes, CR progress lines) -> $got"
    else
        echo "FAIL parser -> $got"
        fails=$((fails + 1))
    fi
    rm -f "$fix"

    echo
    echo "selftest: $((cases - fails))/$cases passed"
    [ "$fails" -eq 0 ]
}

# The selftest touches no run and no live directory: it gets its own scratch
# output, so it is safe to run on a box that is mid-flow (and on any machine).
if [ "$SELFTEST" = 1 ]; then
    OUT=$(mktemp -d)
    EVENTS=$OUT/drt_watch.log; STATE=$OUT/drt_state.tsv
    REPORT=$OUT/drt_verdict.md;  STATUS=$OUT/drt_verdict.txt
    selftest; rc=$?
    rm -rf "$OUT"
    exit $rc
fi

mkdir -p "$OUT"

# ------------------------------------------------------------------- main ---
TAG_GIVEN=0
[ -n "$TAG" ] && TAG_GIVEN=1
RESOLVED=""
if [ -z "$TAG" ]; then
    TAG=$(basename "$(ls -dt "$RUNS"/*/ 2>/dev/null | head -1)" 2>/dev/null)
    TAG=${TAG%/}
fi
[ -n "$TAG" ] && [ -f "$RUNS/$TAG/resolved.json" ] && RESOLVED=$RUNS/$TAG/resolved.json

# A log from somewhere else (the fast loop, an OL2 run, a fixture) must not be
# captioned with this run's resolved.json -- that would print the wrong iteration
# budget in the report.
if [ -n "$LOGFILE" ] && [ -n "$RESOLVED" ]; then
    case "$LOGFILE" in
        "$RUNS/$TAG"/*) ;;
        *) RESOLVED="" ;;
    esac
fi
# A foreign log is not "run <newest tag>": drop the auto-derived tag so the
# report names the log itself instead of a run it has nothing to do with. An
# explicit --tag is always kept.
if [ -n "$LOGFILE" ] && [ "$TAG_GIVEN" = 0 ]; then
    TAG=""
fi

if [ -n "$LOGFILE" ]; then
    LOG=$LOGFILE
else
    if ! LOG=$(find_log); then
        echo "$(date -u '+%F %T') no detailed-routing log under $RUNS/${TAG:-*}/ yet" | tee -a "$EVENTS"
        [ "$ONCE" = 1 ] && exit 1
        LOG=""
    fi
fi

say "WATCH_START tag=${TAG:-?} log=${LOG:-pending} poll=${POLL}s spike_x=$SPIKE_X stall_k=$STALL_K/$STALL_PCT% kill=$KILL on=$KILL_ON"

# The deadline is an IDLE timeout, not a wall clock: it counts the hours since the
# last new count, so a watcher started with the flow (hours before the router
# starts) is not retired while it waits for the step to appear.
lastact=0
final=NONE
while :; do
    if [ -z "${LOG:-}" ] || [ ! -f "$LOG" ]; then
        if LOG=$(find_log); then
            STEPDIR=$(dirname "$LOG")
            say "LOG_FOUND $LOG"
        else
            LOG=""
        fi
    fi
    [ -n "${LOG:-}" ] && [ -z "${STEPDIR:-}" ] && STEPDIR=$(dirname "$LOG")
    if [ -n "${LOG:-}" ] && [ -f "$LOG" ]; then
        out=$(analyze "$LOG")
        set -- $out
        # analyze's contract: 0 VERDICT pass best last n last_gain mean_gain new_rows
        verdict=$1; pass=$2; best=$3; last=$4; n=$5; lg=$6; mg=$7; new=${8:-0}
        [ "$lastact" = 0 ] && lastact=$(now)
        [ "$new" -gt 0 ] && lastact=$(now)
        if [ "$verdict" = NO_DATA ]; then
            echo "$(date -u '+%F %T') no DRT-0199 counts in $LOG"
            say "NO_DATA $LOG"
            [ "$ONCE" = 1 ] && exit 1
        else
            changed=0
            [ "$verdict" != "$final" ] && changed=1
            if [ "$changed" = 1 ]; then
                if [ "$final" = NONE ]; then
                    say "VERDICT_FIRST $verdict (pass=$pass best=$best last=$last n=$n)"
                else
                    say "VERDICT_CHANGE $final -> $verdict (pass=$pass best=$best last=$last n=$n)"
                fi
            fi
            # Rewrite the report when the curve moved, when the verdict changed, or
            # when asked once by hand -- an unchanged curve does not need a new file.
            if [ "$new" -gt 0 ] || [ "$changed" = 1 ] || [ "$ONCE" = 1 ]; then
                killnote=""
                case "$verdict" in
                    STALLED|DIVERGED)
                        case "$KILL_ON" in
                            both) armed=1 ;;
                            stalled) [ "$verdict" = STALLED ] && armed=1 || armed=0 ;;
                            *) [ "$verdict" = DIVERGED ] && armed=1 || armed=0 ;;
                        esac
                        if [ "$KILL" = 1 ] && [ "$armed" = 1 ]; then
                            killnote=$(stop_step)
                        fi
                        ;;
                esac
                write_report "$verdict" "$pass" "$best" "$last" "$n" "$lg" "$mg" "$LOG" "$killnote"
            fi
            final=$verdict
            if [ "$EXIT_ON_VERDICT" = 1 ] && [ "$verdict" != CONVERGING ]; then
                case "$verdict" in
                    CLEAN) exit 4 ;;
                    STALLED) exit 2 ;;
                    DIVERGED) exit 3 ;;
                esac
            fi
        fi
    fi
    if [ "$ONCE" = 1 ]; then break; fi
    # The step is over when LibreLane writes its runtime.txt (it writes it at step
    # end, pass or fail). That is when the cap-cost report is final -- and when
    # this watcher's job ends: the router will not emit another iteration.
    if [ -n "${STEPDIR:-}" ] && [ -f "$STEPDIR/runtime.txt" ]; then
        say "STEP_DONE $STEPDIR runtime=$(cat "$STEPDIR/runtime.txt" 2>/dev/null)"
        finalize "the detailed-routing step finished (runtime $(cat "$STEPDIR/runtime.txt" 2>/dev/null))"
        break
    fi
    # Nothing new for this long means the step is over (or never started): stop,
    # the report on disk is the verdict.
    if [ "$lastact" -gt 0 ] && [ "$(($(now) - lastact))" -gt "$((DEADLINE_H * 3600))" ]; then
        say "WATCH_END no new count for ${DEADLINE_H}h (last verdict $final)"
        [ -n "${STEPDIR:-}" ] && finalize "no new count for ${DEADLINE_H}h (the step may still be running)"
        break
    fi
    # The container being gone is the other end condition: the run is over. This
    # test is deliberately not gated on having found a log -- a watcher started
    # with the chain must retire when the flow dies, even if the flow died before
    # detailed routing ever started (there would be no log to notice otherwise).
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
        say "WATCH_END container $CONTAINER is gone (last verdict $final)"
        if [ -n "${LOG:-}" ]; then
            write_report "$final" "${pass:-0}" "${best:-0}" "${last:-0}" "${n:-0}" "${lg:-0}" "${mg:-0}" "$LOG" ""
            finalize "the flow container $CONTAINER is gone"
        fi
        break
    fi
    sleep "$POLL"
done

# `--finalize` by hand: the step may be long finished (or the run dead), and the
# curve is in the state file, so the cost report can be produced at any time.
# (A hand --finalize queues the extension too, under the same conditions -- the
# step being over is what the condition tests, not who asked.)
if [ "$FINALIZE" = 1 ] && [ "$SELFTEST" = 0 ]; then
    finalize "requested by hand (--finalize)"
    echo "cap cost report: $OUT/drt_cap_cost.md"
fi

[ "$EXIT_ON_VERDICT" = 1 ] && { case "$final" in CLEAN) exit 4 ;; STALLED) exit 2 ;; DIVERGED) exit 3 ;; *) exit 0 ;; esac; }
exit 0
