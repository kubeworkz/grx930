#!/bin/bash
# drt_extend_ws.sh -- the second half of the cap-cost measurement: re-route the
# pre-DRT database with the iterations DRT_OPT_ITERS withheld, and write what they
# actually cost. Launched automatically by watch_drt_curve.sh when the
# detailed-routing step ends with the curve still falling; runnable by hand too.
#
# WHY THIS IS A SEPARATE UNIT, AND WHY IT WAITS ITS TURN
# -----------------------------------------------------
# The cap-cost report (drt_cap_cost.md) prices what the cap left standing using the
# counting the router itself does -- but the iterations past the cap did not run,
# so nothing on disk says what they would have bought. Only a real re-route can
# answer that, and the honest way to do it is the standalone fast loop
# (drt_fast/run_drt.sh) on the step's own input database, because that loop
# reproduces a flow pass exactly: same six `detailed_route` arguments, same
# -or_seed 42, same thread count (drt_fast.tcl:1-17).
#
# It is separate from the watcher because it must not run while anything else is.
# The flow's detailed-routing step has finished, but the flow has not: antenna
# repair, the TrDRC checker, fill, RCX, STA and the KLayout checks are still ahead
# of it. This box has 8 cores and ~15 GB of RAM with no cgroup cap on ws_flow, so
# two routers at once halve both and can walk it into the OOM that killed an
# earlier 6h55m run (build/gate.sh's header). So this waits for the flow container
# to be gone and then passes the same memory/disk gate every chain here uses. The
# measurement is a diagnosis, not a deadline; waiting is free.
#
# WHAT IT WRITES
# --------------
#   drt_cap_cost_measured.md   the measurement: the instrument check against the
#                              flow's own pass-0 curve, the count standing at the
#                              cap, the count after the extension, the difference
#                              (that is what the cap cost), the withheld
#                              iterations' own rate and wall clock, the
#                              extrapolation the un-measured report carried next
#                              to what happened instead, and the limits.
#   drt_extend.log             append-only event log (WAIT / GATE / LAUNCH / ...).
#   drt_extend.<tag>.log       the extension's own router log, captured whole.
#   drt_extend_state.tsv       pass<TAB>iter<TAB>count<TAB>first_seen (the wall
#                              clock), stamped by the poll below.
#   ext_<tag>/drt_verdict.{md,txt}
#                              the same watcher -- log-only mode -- classifying the
#                              extension's own tail, so the verdict on the withheld
#                              iterations comes from the one instrument whose
#                              thresholds were set against v8, not from a second
#                              copy of them here.
#
# VERIFY IT
# ---------
#   bash wafer_space_integration/extend_selftest.sh
#     Stubs docker (no container is launched, nothing is routed) and drives this
#     script end to end: the `/work/...` path form LibreLane writes, the wait, the
#     gate refusal and recovery, the launch command's env delivery, a reproduced
#     call and a confounded one, and the report's numbers. Exits non-zero on drift.
#
# USAGE
#   drt_extend_ws.sh --odb /work/ws/template/librelane/runs/ws_v3/43-.../chip_top.odb \
#                    --tag ws_v3 --flow-state ws/logs/drt_state.tsv
#   drt_extend_ws.sh --help
set -u

SELFDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WS=${EXT_WS:-/home/ubuntu/grx930_ol2/ws}
ROOT=${EXT_ROOT:-${WS%/ws}}
OUT=${EXT_OUT:-$WS/logs}
IMAGE=${EXT_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}
DOCKER=${EXT_DOCKER:-docker}
RUNNER_SCRIPT=${EXT_RUNNER_SCRIPT:-/work/drt_fast/run_drt.sh}

ODB_IN="" TAG="" FLOW_STATE=""
END_ITER=${EXT_END_ITER:-16}
CAP=${EXT_CAP:-}
THREADS=${EXT_THREADS:-8}
MIN_LAYER=${EXT_MIN_LAYER:-Metal1}
MAX_LAYER=${EXT_MAX_LAYER:-Metal5}
NEED_MB=${EXT_NEED_MB:-9000}
MIN_GB=${EXT_MIN_GB:-10}
MOUNT=${EXT_MOUNT:-/home}
WAIT_CONTAINER=${EXT_WAIT_CONTAINER:-ws_flow}
DEADLINE_H=${EXT_DEADLINE_H:-48}
WAIT_S=${EXT_WAIT_S:-300}
GATE_BACKOFF=${EXT_GATE_BACKOFF:-1800}
POLL=${EXT_POLL:-120}
DRY=0
NOWAIT=0

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --odb PATH        the pre-DRT database to route (inside-container form
                    /work/... or the host path; both are accepted)
  --tag NAME        flow run tag this extension belongs to (names the outputs)
  --flow-state FILE the watcher's drt_state.tsv, for the instrument check
                    (default: $OUT/drt_state.tsv)
  --end-iter N      -droute_end_iter for the extension (default 16 = 2x the cap);
                    the extension re-runs iterations 0..N-1, the flow ran 0..cap-1
  --cap N           the cap the flow used, for the report (default: read from the
                    run's resolved.json)
  --wait-container  NAME  wait for this container to be gone (default ws_flow)
  --no-wait         do not wait for it (still refuses while a router is running)
  --deadline-h N    give up waiting after N hours (default 48) and report why
                    (0 = decide now, which is how a dry run on a busy box answers)
  --dry-run         run the gate once, print the command, launch nothing
  --help            this text

Verify the whole path (with docker stubbed) with:
  bash wafer_space_integration/extend_selftest.sh
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --odb) ODB_IN=${2:-}; shift 2 ;;
        --tag) TAG=${2:-}; shift 2 ;;
        --flow-state) FLOW_STATE=${2:-}; shift 2 ;;
        --end-iter) END_ITER=${2:-}; shift 2 ;;
        --cap) CAP=${2:-}; shift 2 ;;
        --wait-container) WAIT_CONTAINER=${2:-}; shift 2 ;;
        --no-wait) NOWAIT=1; shift ;;
        --deadline-h) DEADLINE_H=${2:-}; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

TAG=${TAG:-run}
EXTAG=${EXT_TAG:-ext_$TAG}
NAME=drt_$EXTAG
EVENTS=$OUT/drt_extend.log
EXT_STATE=$OUT/drt_extend_state.tsv
EXT_LOG=$OUT/drt_extend.$EXTAG.log
EXT_INC=$OUT/.drt_extend.$EXTAG.inc
EXT_OUTDIR=$OUT/$EXTAG
REPORT=$OUT/drt_cap_cost_measured.md
[ -n "$FLOW_STATE" ] || FLOW_STATE=$OUT/drt_state.tsv

say() { echo "[$(date -u '+%F %T')] $*" >> "$EVENTS"; }
now() { date -u +%s; }
fmt() { date -u -d "@${1}" '+%F %T' 2>/dev/null || echo "${1}"; }
mb() { awk -v b="${1:-0}" 'BEGIN { printf "%.0f", b/1048576 }'; }

# ------------------------------------------------------------ path forms ----
# LibreLane writes the run tree as the CONTAINER sees it ("/work/ws/..."), and the
# same file sits at a different path on the host. The fast loop needs the
# container form for FAST_ODB (it runs inside the mount); everything measured here
# (existence, size, mtime) needs the host form. One input, both forms, and a hard
# error when the host file is not there -- "not found" must never become a launch
# with an empty FAST_ODB, which would route the default checkpoint and mislabel it.
norm_odb() {
    case "$1" in
        /work/*) ODB_C=$1; ODB_H=$ROOT${1#/work} ;;
        "$ROOT"/*) ODB_H=$1; ODB_C=/work${1#"$ROOT"} ;;
        /*) ODB_H=$1; ODB_C=/work$1 ;;
        *) ODB_H=$1; ODB_C=/work/$1 ;;
    esac
}

docker_running() { "$DOCKER" inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }

# Two routers at once is the one thing this must never do. The check is on what the
# containers are *running*, not their names: the flow's router and every fast-loop
# arm drive a tcl called drt.tcl (or drt_fast.tcl), so an unrelated container
# cannot trip it and a renamed arm cannot slip past it.
router_busy() {
    local hits
    hits=$("$DOCKER" ps --format '{{.Names}} {{.Command}}' 2>/dev/null |
        grep -a -E 'drt\.tcl|drt_fast\.tcl' | grep -av "^$NAME " | head -3)
    [ -n "$hits" ] && { printf '%s\n' "$hits"; return 0; }
    return 1
}

# ---------------------------------------------------------------- parser ----
# The same rule as the watcher's parser, deliberately the same shape: one DRT-0199
# count per optimization iteration, iteration numbering restarting at each
# "Start 0th optimization iteration" (the antenna loop re-routes). \r becomes \n
# first because the progress lines are overwritten in place.
#
# The two readings are checked against each other in the report: the instrument
# check compares this script's extension curve with the flow's, and the flow's came
# from the watcher's parser.
parse_counts() { # $1 log -> "pass iter count"
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

state_get() { awk -F'\t' -v p="$1" -v i="$2" '$1==p && $2==i {print $3; exit}' "$EXT_STATE" 2>/dev/null; }
state_add() { # pass iter count ts -- keyed on (pass,iteration), so a line copied
              # twice by an overlapping capture window cannot double-count one.
    [ -f "$EXT_STATE" ] || : > "$EXT_STATE"
    awk -F'\t' -v p="$1" -v i="$2" '!($1==p && $2==i) {print}' "$EXT_STATE" > "$EXT_STATE.tmp" 2>/dev/null
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$EXT_STATE.tmp"
    sort -n -k1,1 -k2,2 "$EXT_STATE.tmp" > "$EXT_STATE"
    rm -f "$EXT_STATE.tmp"
}

stamp_log() { # $1 log -- record every count seen for the first time
    local ts p i c new=0
    ts=$(now)
    while read -r p i c; do
        [ -n "${p:-}" ] || continue
        if [ -z "$(state_get "$p" "$i")" ]; then
            state_add "$p" "$i" "$c" "$ts"
            new=$((new + 1))
            say "COUNT pass=$p iter=$i violations=$c"
        fi
    done < <(parse_counts "$1")
    [ "$new" -gt 0 ]
}

pass0_counts() { awk -F'\t' '$1==0 {print $3}' "$1" 2>/dev/null; }

# Mean of the per-step gains over the last $1 counts on stdin, in %/iteration --
# the watcher's own "rate into the cap" arithmetic. The tail is what matters: a
# pass's first iteration always drops hard and says nothing about the eighth.
mean_tail_rate() { # $1 = k, counts on stdin
    awk -v k="${1:-3}" '{v[NR]=$1} END { n=NR; s=0; c=0
        for (i=(n-k+1); i<=n; i++) if (i>=2) { s += (v[i]-v[i-1])*100/v[i-1]; c++ }
        if (c>0) printf "%.3f", s/c; else print "0" }'
}

# ------------------------------------------------------------------- main ---
# Arguments first, then the environment: a caller who forgot --odb should be told
# that, not told about a gate path that is missing because the machine is not the
# flow box.
[ -n "$ODB_IN" ] || { echo "--odb is required (see --help)" >&2; exit 1; }
mkdir -p "$OUT"

# --------------------------------------------------------------- the gate ---
# The gate chains use, sourced rather than copied (build/gate.sh's whole point), so
# this borrows memwatch's floors and its MEM_PREFLIGHT line unchanged.
GATE_SH=${EXT_GATE_SH:-$ROOT/build/gate.sh}
LOG=$OUT/drt_extend.log
[ -f "$GATE_SH" ] || { echo "no gate script at $GATE_SH" >&2; exit 1; }
# shellcheck source=/dev/null
. "$GATE_SH"

# The wait loop asks a cheaper question than the gate does, because it may ask it
# a few hundred times: headroom_mb from memwatch's own reader (no preflight.log
# write, no duplicate arithmetic) and gate.sh's free_gb. The authoritative answer
# is still gate()'s, taken once, immediately before the launch -- the same call
# every chain here makes, with the same MEM_PREFLIGHT record.
poll_ready() {
    local h d
    h=$(bash "$MEMWATCH" --headroom 2>/dev/null | sed -n 's/.*headroom_mb=\([0-9]*\).*/\1/p')
    d=$(free_gb "$MOUNT")
    case "${h:-}" in ''|*[!0-9]*) return 1 ;; esac
    case "${d:-}" in ''|*[!0-9]*) return 1 ;; esac
    POLL_NOTE="headroom_mb=$h disk_gb=$d need_mb=$NEED_MB min_gb=$MIN_GB"
    [ "$h" -ge "$NEED_MB" ] && [ "$d" -ge "$MIN_GB" ]
}
POLL_NOTE=""

# ---------------------------------------------------------------- report ----
write_report() { # $1 status line, $2 minutes waited
    local status=$1 waited=$2
    local -a fp=() ep=()
    local p i c ts
    while read -r p i c ts; do [ "${p:-}" = 0 ] && fp+=("$c"); done < <(awk -F'\t' '$1==0' "$FLOW_STATE" 2>/dev/null | sort -n -k2,2)
    while read -r p i c ts; do [ "${p:-}" = 0 ] && ep+=("$c"); done < <(awk -F'\t' '$1==0' "$EXT_STATE" 2>/dev/null | sort -n -k2,2)
    local nf=${#fp[@]} ne=${#ep[@]}
    local cap=${CAP:-unknown} capnote=""
    # One quoted assignment, not a chain of `&&` reassignments: the chain version had
    # a line whose `&&` was missing, so it ran unconditionally and left only its own
    # fragment in the report (caught by reading the generated file, not by the tests).
    case "${CAP:-}" in
        ''|*[!0-9]*) ;;
        *) if [ "$nf" -ne "$CAP" ]; then
               capnote="This run's cap was $CAP, but the flow's capture holds $nf pass-0 counts: the
watcher missed $(($CAP - nf)) of them (it can only stamp what it sees arriving), so \"iteration $((nf - 1))\"
below may not be the iteration the cap stopped at. The comparison itself is unaffected: both curves are
indexed from 0 in the same file."
           fi ;;
    esac
    local atcap=${fp[$((nf-1))]:-?} extlast=${ep[$((ne-1))]:-?}
    local withheld="" pct="" rate_ext="" rate_flow="" capnote2=""
    local mins="" periter="" wallnote="not measured"
    local match=1 diff_at="" cmp="" lim=$nf
    [ "$ne" -lt "$lim" ] && lim=$ne
    for ((i = 0; i < lim; i++)); do
        cmp="$cmp| $i | ${fp[$i]} | ${ep[$i]} |"$'\n'
        [ "$match" = 1 ] && [ "${fp[$i]}" != "${ep[$i]}" ] && { match=0; diff_at=$i; }
    done
    if [ "$nf" -gt 0 ] && [ "$ne" -gt 0 ] && [ "$match" = 1 ]; then
        withheld=$(awk -v a="$atcap" -v b="$extlast" 'BEGIN { print a-b }')
        pct=$(awk -v a="$atcap" -v b="$withheld" 'BEGIN { if (a>0) printf "%.2f", b*100/a; else print "0" }')
        rate_flow=$(pass0_counts "$FLOW_STATE" | mean_tail_rate "${STALL_K:-3}")
        # The withheld iterations' own mean gain: the same arithmetic on the same
        # curve the flow stopped, so the two rates are directly comparable.
        rate_ext=$(pass0_counts "$EXT_STATE" | mean_tail_rate "$((ne - nf + 1))")
    fi
    local extfirst_ts extcap_ts extlast_ts
    extfirst_ts=$(awk -F'\t' '$1==0 {print $4}' "$EXT_STATE" 2>/dev/null | sort -n | head -1)
    extlast_ts=$(awk -F'\t' '$1==0 {print $4}' "$EXT_STATE" 2>/dev/null | sort -n | tail -1)
    extcap_ts=$(awk -F'\t' -v i="$((nf-1))" '$1==0 && $2==i {print $4}' "$EXT_STATE" 2>/dev/null | head -1)
    if [ -n "${extcap_ts:-}" ] && [ -n "${extlast_ts:-}" ] && [ "$extlast_ts" -gt "$extcap_ts" ] && [ "$ne" -gt "$nf" ]; then
        mins=$(awk -v a="$extcap_ts" -v b="$extlast_ts" 'BEGIN { printf "%.1f", (b-a)/60 }')
        periter=$(awk -v a="$mins" -v b="$((ne-nf))" 'BEGIN { printf "%.1f", a/b }')
        wallnote="measured"
    fi

    # The verdict on what the cap cost, in words, decided here and not in the
    # echo stream: this is the sentence the whole file exists to say.
    local costline="" gateread=""
    if [ -z "$withheld" ]; then
        costline="**Not quotable.**"
        gateread="The instrument check did not produce a comparison, so there is no measured cost."
    elif [ "$withheld" = 0 ] && [ "$extlast" = "$atcap" ]; then
        costline="**Nothing: the withheld iterations changed no count at all.**"
        gateread="The count standing at the cap is still the count after $((ne-nf)) more iterations, so the cap did not cost a route here — it cost the wall clock those iterations would have burned to stand still."
    else
        costline="**$withheld violations ($pct % of the count standing at the cap).**"
        if [ "$extlast" = 0 ]; then
            gateread="The extension reached 0, so the cap stopped the pass $(awk -v a="$atcap" 'BEGIN{printf "%d", a}') short of the gate: at this measured rate the withheld iterations were the difference between a failing and a passing TrDRC count."
        else
            gateread="The gate needs 0 and the extension ended at $extlast, so the withheld iterations were still removing violations but did not reach it."
        fi
    fi
    [ -n "$rate_ext" ] && [ -n "$rate_flow" ] && {
        if awk -v r="$rate_ext" 'BEGIN { exit !(r < -0.1) }'; then
            capnote2="The curve was still falling at the cap, and it was still falling $((ne-nf)) iterations later"
            capnote2="$capnote2 ($rate_ext %/iteration against the flow's $rate_flow %/iteration into the cap),"
            capnote2="$capnote2 which is the open question the un-measured report could not answer: more"
            capnote2="$capnote2 iterations do move this count. Whether they reach 0 is a different claim, and the"
            capnote2="$capnote2 extension's own tail verdict below is the one to read for it."
        else
            capnote2="The curve was still falling into the cap ($rate_flow %/iteration) but the withheld"
            capnote2="$capnote2 iterations came down at only $rate_ext %/iteration — a steeper-than-expected"
            capnote2="$capnote2 flattening, so the cap's cost shrinks with every iteration spent."
        fi
    }

    {
        echo "# DRT cap cost, measured — run \`$TAG\`"
        echo
        echo "Written $(date -u '+%F %T') UTC by \`wafer_space_integration/drt_extend_ws.sh\`."
        echo "Asks what \`drt_cap_cost.md\` could only extrapolate: what the iterations past"
        echo "\`DRT_OPT_ITERS=$cap\` would have bought, by running them."
        echo
        echo "* status: $status"
        echo "* input database: \`$ODB_C\` (host \`$ODB_H\`, $(mb "$ODBSZ") MB, $(fmt "${ODBMTIME:-0}"))"
        echo "* extension: \`-droute_end_iter $END_ITER\`, layers $MIN_LAYER-$MAX_LAYER, $THREADS threads,"
        echo "  seed 42 — the fast loop's own arguments (drt_fast.tcl), so this reproduces the flow's"
        echo "  pass 0 instead of approximating it. Container \`$NAME\`, image \`$IMAGE\`."
        echo "* waited ${waited} min for the box to be free before launching"
        echo "* flow curve \`$FLOW_STATE\`, extension curve \`$EXT_STATE\`, router log \`$EXT_LOG\`"
        echo
        echo "## The instrument check"
        echo
        if [ "$lim" -eq 0 ]; then
            echo "**No comparison is possible:** one of the two curves is empty, so nothing below is a"
            echo "measurement."
        elif [ "$match" = 1 ]; then
            echo "The extension reproduced the flow's own pass-0 counts exactly — all $lim iterations it"
            echo "had in common:"
            echo
            echo "| iteration | flow | extension |"
            echo "|---|---|---|"
            printf '%s' "$cmp"
        else
            echo "**The extension did NOT reproduce the flow's curve: iteration $diff_at is ${ep[$diff_at]},"
            echo "the flow's is ${fp[$diff_at]}.** Everything after that point is a different routing problem"
            echo "(a different input database, a different router build, or a different thread count), so the"
            echo "difference below would be an artefact of that, not a cost of the cap. This report"
            echo "deliberately quotes no cost; find the cause first."
            echo
            echo "| iteration | flow | extension |"
            echo "|---|---|---|"
            printf '%s' "$cmp"
        fi
        echo
        echo "## What the cap cost, measured"
        echo
        if [ "$nf" -eq 0 ] || [ "$ne" -eq 0 ]; then
            echo "No counts to price."
        elif [ "$match" = 0 ]; then
            echo "Not quotable: the instrument check above failed."
        else
            echo "* **Standing at the cap:** $atcap violations at iteration $((nf - 1)), the flow's last"
            echo "  pass-0 count ($nf counts, iteration 0 = the initial route)."
            echo "* **After the extension:** $extlast violations at iteration $((ne - 1)) — the $((ne - nf))"
            echo "  iterations the cap withheld."
            echo "* **Measured cost of the cap: $costline**"
            echo "  $gateread"
            [ -n "$capnote2" ] && { echo; echo "$capnote2"; }
            [ -n "$capnote" ] && { echo; echo "$capnote"; }
            echo
            if [ "$wallnote" = measured ]; then
                echo "* **What it took:** $mins min for the $((ne - nf)) withheld iterations = $periter"
                echo "  min/iteration on this die. Whole extension: $(fmt "$extfirst_ts") → $(fmt "$extlast_ts")."
                echo "  Wall clock is poll-granular (${POLL}s) and starts when this script first saw each line."
            else
                echo "* **Wall clock: not measured.** The withheld iterations carry one timestamp — the"
                echo "  capture began after they ran, or the extension ran too short to separate them."
            fi
        fi
        echo
        echo "## Predicted vs measured"
        echo
        if [ -f "$OUT/drt_cap_cost.md" ]; then
            echo "What the un-measured report said, verbatim:"
            echo
            grep -a -A4 'Extrapolation (labelled as one)\|No extrapolation' "$OUT/drt_cap_cost.md" 2>/dev/null |
                sed 's/^/> /'
            echo
        else
            echo "No \`drt_cap_cost.md\` beside this report, so there is nothing to compare against."
            echo
        fi
        if [ -f "$EXT_OUTDIR/drt_verdict.txt" ]; then
            echo "The extension's own tail, classified by the same watcher that read the flow's curve"
            echo "(thresholds set against v8, not re-derived here):"
            echo
            echo '```'
            cat "$EXT_OUTDIR/drt_verdict.txt" 2>/dev/null
            echo '```'
            echo
            echo "Full text: \`$EXT_OUTDIR/drt_verdict.md\`."
        fi
        echo
        echo "## What this measurement is not"
        echo
        echo "* Not a flow result. The fast loop is the standalone experiment harness: it does not create"
        echo "  the flow's non-default routing rules and does not run the antenna-repair passes that"
        echo "  LibreLane interleaves with re-routes. Its ODB is not the submission's."
        echo "* A price for pass 0's iterations only. The step could have gone anywhere after that pass;"
        echo "  that is the flow's question and the flow has answered it (see \`drt_cap_cost.md\`)."
        echo "* One seed, one thread count, one box: run-to-run variation in TritonRoute is not measured,"
        echo "  and it is exactly what would show up as an instrument-check mismatch on a re-run."
    } > "$REPORT"
    say "MEASURED_REPORT $REPORT"
}

norm_odb "$ODB_IN"
[ -f "$ODB_H" ] || { say "FATAL odb_missing host=$ODB_H from=$ODB_IN"; echo "no such file: $ODB_H (from $ODB_IN)" >&2; exit 1; }
ODBSZ=$(stat -c %s "$ODB_H" 2>/dev/null)
ODBMTIME=$(stat -c %Y "$ODB_H" 2>/dev/null)
say "EXTEND_START tag=$TAG odb=$ODB_C end_iter=$END_ITER cap=${CAP:-?} wait=$WAIT_CONTAINER"
if [ "$(mb "${ODBSZ:-0}")" -lt 50 ]; then
    say "ODB_SMALL ${ODBSZ:-0} bytes -- is that really a pre-DRT database?"
    echo "warning: $ODB_H is only $(mb "${ODBSZ:-0}") MB; a pre-DRT database for this design is larger" >&2
fi

# The cap, for the report: passed in by the watcher, else read from the run's own
# resolved.json -- the value LibreLane actually resolved, not the yaml's intent.
if [ -z "$CAP" ]; then
    RES=$WS/template/librelane/runs/$TAG/resolved.json
    if [ -f "$RES" ]; then
        CAP=$(grep -o '"DRT_OPT_ITERS": [0-9]*' "$RES" 2>/dev/null | grep -o '[0-9]*' | head -1)
        [ -n "$CAP" ] && say "CAP_FROM_RESOLVED $CAP ($RES)"
    fi
fi
STALL_K=${EXT_STALL_K:-3}

launch_cmd() {
    echo "$DOCKER run -d --name $NAME --user 0:0 -v $ROOT:/work \\"
    echo "  -e FAST_TAG=$EXTAG -e FAST_ODB=$ODB_C -e FAST_END_ITER=$END_ITER \\"
    echo "  -e FAST_MIN_LAYER=$MIN_LAYER -e FAST_MAX_LAYER=$MAX_LAYER -e FAST_THREADS=$THREADS \\"
    echo "  --entrypoint /bin/sh $IMAGE -c 'exec bash $RUNNER_SCRIPT'"
}

if [ "$DRY" = 1 ]; then
    # One reading, no waiting, no launch: for a box that is busy with the flow now.
    wait_note=""
    [ "$(docker_running "$WAIT_CONTAINER")" = "true" ] && wait_note="$WAIT_CONTAINER is running (the wait would start here)"
    router_busy >/dev/null 2>&1 && wait_note="${wait_note:+$wait_note; }a router is already running"
    poll_ready || true
    if gate "$NEED_MB" drt_extend "$MIN_GB" "$MOUNT"; then gate_note="passes"; else gate_note="would refuse: $GATE_REASON"; fi
    echo "gate: $gate_note ($POLL_NOTE)"
    echo "wait condition: ${wait_note:-box free}"
    echo
    echo "the command it would launch:"
    launch_cmd
    exit 0
fi

# ------------------------------------------------------------------ wait ----
t0=$(now)
code=""
deadline=0
waited_min=0
while :; do
    waited_min=$(( ($(now) - t0) / 60 ))
    if [ "$NOWAIT" = 0 ] && [ "$(docker_running "$WAIT_CONTAINER")" = "true" ]; then
        code="WAITING_FOR_$WAIT_CONTAINER"
    else
        busy=$(router_busy 2>/dev/null)
        if [ -n "$busy" ]; then
            say "BUSY_FOR_OTHER_ROUTER $(printf '%s' "$busy" | tr '\n' ';')"
            code="WAITING_FOR_OTHER_ROUTER"
        elif poll_ready; then
            # The authoritative gate, right before the launch. It can refuse where
            # poll_ready passed -- gate() also tests memwatch's absolute floors, which
            # headroom_mb can mask -- so a refusal here backs off instead of spinning,
            # and (this is the part that is easy to get wrong, and the selftest pins
            # it) the deadline is still checked before that backoff. Otherwise a
            # permanently refusing gate would outlive its own deadline silently.
            if gate "$NEED_MB" drt_extend "$MIN_GB" "$MOUNT"; then
                code="GO"
                break
            fi
            code="WAITING_FOR_${GATE_REASON}"
            say "GATE_REFUSED $GATE_REASON waited=${waited_min}min $POLL_NOTE"
            if [ "$waited_min" -ge "$((DEADLINE_H * 60))" ]; then
                deadline=1
                break
            fi
            sleep "$GATE_BACKOFF"
            continue
        else
            code="WAITING_FOR_HEADROOM"
        fi
    fi
    if [ "$waited_min" -ge "$((DEADLINE_H * 60))" ]; then
        deadline=1
        break
    fi
    say "$code waited=${waited_min}min ${POLL_NOTE:-}"
    sleep "$WAIT_S"
done

if [ "$code" != GO ]; then
    # The reason survives the timeout: "gave up after 48 h" is not useful on its own,
    # "gave up after 48 h still waiting for ws_flow" is, and it is one word of state.
    if [ "${deadline:-0}" = 1 ]; then
        say "NOT_LAUNCHED ${DEADLINE_H}h-deadline code=$code waited=${waited_min}min"
        write_report "**not launched**: still $code when the ${DEADLINE_H} h deadline ran out. The command it would have run is at the end of this file." "$waited_min"
    else
        say "NOT_LAUNCHED $code waited=${waited_min}min"
        write_report "**not launched** ($code) after ${waited_min} min. The command it would have run is at the end of this file." "$waited_min"
    fi
    { echo; echo "## The command this refused to run"; echo; echo '```'; launch_cmd; echo '```'; } >> "$REPORT"
    echo "not launched ($code) after ${waited_min} min; see $REPORT" >&2
    exit 1
fi

# ---------------------------------------------------------------- launch ----
: > "$EXT_INC"
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
# Flag order matters: every `-e` goes BEFORE the image name. Placed after it they
# become part of the container's command line instead of its environment and are
# silently dropped -- drt_fast/grt03_chain.sh does exactly that, and its run came up
# on the defaults (there is no out/gr03; the log's RUN_START line names exp1 and the
# default checkpoint). extend_selftest.sh asks the container what it got, for this.
"$DOCKER" run -d --name "$NAME" --user 0:0 -v "$ROOT:/work" \
    -e FAST_TAG="$EXTAG" -e FAST_ODB="$ODB_C" -e FAST_END_ITER="$END_ITER" \
    -e FAST_MIN_LAYER="$MIN_LAYER" -e FAST_MAX_LAYER="$MAX_LAYER" -e FAST_THREADS="$THREADS" \
    --entrypoint /bin/sh "$IMAGE" -c "exec bash $RUNNER_SCRIPT" >/dev/null
rc=$?
if [ "$rc" != 0 ] || [ "$(docker_running "$NAME")" != "true" ]; then
    say "LAUNCH_FAILED rc=$rc"
    write_report "**the container did not start** (docker run rc=$rc)" "$waited_min"
    echo "launch failed (rc=$rc); see $REPORT" >&2
    exit 1
fi
tstart=$(now)
say "LAUNCHED name=$NAME end_iter=$END_ITER odb=$ODB_C wait=${waited_min}min"
echo "launched $NAME ($END_ITER iterations on $ODB_C); report: $REPORT"

# ------------------------------------------------------------------ wait ----
# Collect while it runs: a count's wall clock is when it first appeared, which is
# only observable live. `--since` keeps each poll from re-reading the whole container
# log; the overlapping window is harmless because the state is keyed by
# (pass, iteration).
prev=$(date -u -d '10 seconds ago' +%FT%T)
while [ "$(docker_running "$NAME")" = "true" ]; do
    sleep "$POLL"
    "$DOCKER" logs --since "$prev" "$NAME" >> "$EXT_INC" 2>/dev/null
    prev=$(date -u -d "$((POLL + 10)) seconds ago" +%FT%T)
    stamp_log "$EXT_INC" || true
done
sleep 2
"$DOCKER" logs "$NAME" > "$EXT_LOG" 2>&1
stamp_log "$EXT_LOG" || true
rm -f "$EXT_INC"
rc=$("$DOCKER" inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null)
tend=$(now)
wall=$(awk -v a="$tstart" -v b="$tend" 'BEGIN { printf "%.1f", (b-a)/60 }')
say "EXTEND_EXIT rc=$rc wall_min=$wall"
grep -a "Number of violations" "$EXT_LOG" 2>/dev/null | tail -2 | tee -a "$EVENTS" >/dev/null

# The tail verdict from the watcher itself, on a copied foreign log with its own
# output directory, so it cannot overwrite the flow's verdict report.
if [ -f "$SELFDIR/watch_drt_curve.sh" ]; then
    mkdir -p "$EXT_OUTDIR"
    WATCH_OUT="$EXT_OUTDIR" bash "$SELFDIR/watch_drt_curve.sh" --log "$EXT_LOG" --once > "$EXT_OUTDIR/watch.out" 2>&1
    say "EXTEND_VERDICT $(cat "$EXT_OUTDIR/drt_verdict.txt" 2>/dev/null | head -1)"
fi

write_report "ran to completion (container exit $rc, $wall min wall clock)" "$waited_min"

# Point the first report at its own measurement, once.
if [ -f "$OUT/drt_cap_cost.md" ] && ! grep -aq 'drt_cap_cost_measured.md' "$OUT/drt_cap_cost.md" 2>/dev/null; then
    {
        echo
        echo "**Measured, not extrapolated:** the extension this report queued has run — see"
        echo "\`drt_cap_cost_measured.md\` (the withheld iterations' counts, their own rate and wall"
        echo "clock, and the instrument check against the curve above)."
    } >> "$OUT/drt_cap_cost.md"
fi
say "EXTEND_COMPLETE report=$REPORT"
echo "measured report: $REPORT"
exit 0
