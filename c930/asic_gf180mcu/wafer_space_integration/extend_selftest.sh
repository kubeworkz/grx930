#!/bin/bash
# extend_selftest.sh -- drives the automatic cap-cost extension end to end with
# docker (and memwatch) stubbed: no container is launched, nothing is routed, and
# nothing is written outside a temp dir.
#
# What it is for
# --------------
# watch_drt_curve.sh decides *whether* to buy the withheld iterations and hands the
# step's own input database to drt_extend_ws.sh; the runner waits for the box,
# passes the chains' gate, launches the fast loop, stamps the curve as it arrives,
# and writes the measurement. Every one of those is a place where a plausible-looking
# script can do the right thing to the wrong file -- and the wrong file is silent:
# the report still appears, still has numbers in it, and they are about a different
# database or a different run. So the fixtures here are the shapes the real run
# produced (the /work/... path LibreLane writes, the two forms of the same file, a
# container that comes up on defaults because its -e flags landed after the image),
# and the assertions are on the text of the reports.
#
# The docker stub is deliberately CLI-shaped: it reads flags the way the CLI does,
# so `-e` AFTER the image name is recorded as a command argument, not an env var.
# That is what makes the env-delivery check real -- drt_fast/grt03_chain.sh has that
# bug today, and its run came up on FAST_ODB's default checkpoint.
#
# Run it after touching watch_drt_curve.sh, drt_extend_ws.sh or build/gate.sh.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUNNER=$HERE/drt_extend_ws.sh
WATCHER=$HERE/watch_drt_curve.sh
REPO=$(cd "$HERE/.." && pwd)
TMP=$(mktemp -d)
# EXTEND_SELFTEST_KEEP=1 leaves the scratch tree behind and prints where: the
# generated reports are the point of half of this, and reading one is how you
# check a change to their wording.
if [ "${EXTEND_SELFTEST_KEEP:-0}" = 1 ]; then
    trap 'echo; echo "kept: $TMP"' EXIT
else
    trap 'rm -rf "$TMP"' EXIT
fi

ROOT=$TMP/root
WS=$ROOT/ws
mkdir -p "$ROOT/build" "$ROOT/drt_fast" "$WS/logs" "$TMP/state"
cp "$REPO/build/gate.sh" "$ROOT/build/gate.sh"

# The memwatch the gate finds beside gate.sh, stubbed: the local machine's own
# memory is not what is under test, and a real preflight would make these cases
# depend on whatever else is running here.
cat > "$ROOT/build/memwatch.sh" <<'STUB'
#!/bin/bash
case "${1:-}" in
  --headroom)  echo "memavail_mb=9000 swapfree_mb=9000 headroom_mb=18000 psi_some=0.00 live_alert=none" ;;
  --preflight) if [ -f "$STUB_STATE/refuse_preflight" ]; then
                   echo "MEM_PREFLIGHT REFUSE: headroom 18000 MB < need 999999999 MB"
                   exit 1
               fi
               echo "MEM_PREFLIGHT OK -- starting" ;;
esac
exit 0
STUB

# The docker stub: flags before the image are the environment, everything from the
# image on is the command -- including, in the bug it exists to catch, `-e` flags a
# caller put on the wrong side.
cat > "$TMP/docker" <<'STUB'
#!/bin/bash
T=${STUB_TMP:-/tmp}
S=$T/state
mkdir -p "$S"
case "${1:-}" in
  inspect)
      case "${3:-}" in
        *Running*)
            if [ "${4:-}" = ws_flow ]; then
                [ -f "$S/flow_gone" ] && echo false || echo true
            else
                [ -f "$S/${4:-}.running" ] && echo true || echo false
            fi ;;
        *ExitCode*) echo 0 ;;
      esac
      exit 0 ;;
  ps)
      [ -f "$S/busy" ] && echo "drt_busy /nix/store/xxx-openroad/bin/openroad /work/drt_fast/drt_fast.tcl"
      exit 0 ;;
  rm) exit 0 ;;
  logs)
      if [ "${2:-}" = "--since" ]; then
          n=$(( $(cat "$S/poll" 2>/dev/null || echo 0) + 1 ))
          echo "$n" > "$S/poll"
          head -n $((n * 10)) "$T/fixture.log" 2>/dev/null
          [ "$n" -ge 3 ] && rm -f "$S"/drt_*.running
      else
          cat "$T/fixture.log" 2>/dev/null
      fi
      exit 0 ;;
  run)
      : > "$T/run.env"; : > "$T/run.cmd"; : > "$T/run.name"
      seen=0; wantname=0
      for a in "$@"; do
          case "$a" in ghcr.io/*) seen=1; echo "$a" >> "$T/run.cmd"; continue ;; esac
          if [ "$seen" = 0 ]; then
              case "$a" in
                FAST_*=*) echo "$a" >> "$T/run.env" ;;
                --name) wantname=1 ;;
                *) [ "$wantname" = 1 ] && { echo "$a" >> "$T/run.name"; wantname=0; } ;;
              esac
          else
              echo "$a" >> "$T/run.cmd"
          fi
      done
      name=$(cat "$T/run.name" 2>/dev/null)
      [ -n "$name" ] && touch "$S/$name.running"
      exit 0 ;;
esac
exit 0
STUB

export STUB_TMP=$TMP STUB_STATE=$TMP/state
DOCKER=$TMP/docker
chmod +x "$DOCKER" "$ROOT/build/memwatch.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
# `grep -e` so a pattern that starts with -- (every option name in an argv list,
# which is exactly what the watcher handoff test asserts on) is read as a pattern
# and not as a grep option.
has() { if grep -aqF -e "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (no '$2' in $1)"; fi; }
hasnt() { if grep -aqF -e "$2" "$1" 2>/dev/null; then bad "$3 ('$2' is in $1)"; else ok "$3"; fi; }

# The real line shape the router writes, with \r-overwritten progress, one count per
# optimization iteration.
make_log() { # $1 file, rest = counts
    local f=$1; shift
    local i=0 c
    : > "$f"
    for c in "$@"; do
        printf '[INFO DRT-0195] Start %dth optimization iteration.\r    Completing 100%% with %s violations.\r[INFO DRT-0199]   Number of violations = %s.\n' \
            "$i" "$c" "$c" >> "$f"
        i=$((i + 1))
    done
}

write_state() { # $1 file, rest = pass-0 counts (one row each, fake timestamps)
    local f=$1; shift
    local i=0 c
    : > "$f"
    for c in "$@"; do
        printf '0\t%s\t%s\t%s\n' "$i" "$c" "$((1700000000 + i * 600))" >> "$f"
        i=$((i + 1))
    done
}

# The flow's pass 0 as the tapeout layout stands: the cap of 8, tail still coming
# down fast (-65 %, -8.5 %, -6.9 %, -5.5 % per iteration), so the extension is worth
# buying. The withheld iterations continue the decay rather than fixing it.
FLOW="1240000 480000 402000 355000 318000 291000 271000 256000"
WITHHELD="248000 241500 236000 231400 227600 220000 211000 201000"
ALL="$FLOW $WITHHELD"
ODB_C=/work/ws/template/librelane/runs/ws_v3/43-openroad-detailedrouting/chip_top.odb
ODB_H=$WS/template/librelane/runs/ws_v3/43-openroad-detailedrouting/chip_top.odb
mkdir -p "$(dirname "$ODB_H")"
# Sparse and big enough to pass the runner's "is that really a pre-DRT database"
# check; nothing reads its contents.
truncate -s 60M "$ODB_H"

run_extend() { # $1 = out dir (case), rest = runner args
    local out=$1; shift
    EXT_DOCKER=$DOCKER EXT_ROOT=$ROOT EXT_WS=$WS EXT_OUT=$out \
        EXT_POLL=1 EXT_NEED_MB=1 EXT_MIN_GB=0 EXT_MOUNT=$ROOT \
        EXT_GATE_SH=$ROOT/build/gate.sh EXT_WAIT_S=1 EXT_GATE_BACKOFF=1 \
        bash "$RUNNER" "$@"
}

case_name=0
# A fresh output dir and a fresh stub state: the container's poll counter is reset
# so every case sees the curve arrive across polls (as the real one does), and the
# flow container is present unless a case says otherwise -- that is the default a
# runner started at step end actually meets.
next_case() {
    case_name=$((case_name + 1)); OUT=$TMP/case$case_name; mkdir -p "$OUT"
    rm -f "$TMP"/state/*.running "$TMP"/state/poll "$TMP"/state/busy "$TMP"/state/flow_gone
    touch "$TMP/state/flow_gone"
}

# ---------------------------------------------------------------- case 1 -----
# The reproduced call: same database, same arguments, so the extension's first
# eight counts are the flow's and the withheld eight are its own. This is the case
# the report exists for.
next_case
write_state "$TMP/flow_state.tsv" $FLOW
make_log "$TMP/fixture.log" $ALL
run_extend "$OUT" --odb "$ODB_C" --tag ws_v3 --flow-state "$TMP/flow_state.tsv" \
    --end-iter 16 --deadline-h 1 --wait-container ws_flow > "$TMP/case$case_name.out" 2>&1
rc=$?
chk "case 1: the run completes" 0 "$rc"
REP=$OUT/drt_cap_cost_measured.md

# The path forms: the input arrived as the container sees it, and the host form is
# what was checked. Getting this wrong is the bug this test was written for.
has "$OUT/drt_extend.log" "EXTEND_START tag=ws_v3 odb=$ODB_C" "case 1: the container path is what reaches the run"
has "$REP" "$ODB_C" "case 1: the report names the container path"
has "$REP" "$ODB_H" "case 1: the report names the host path"
hasnt "$TMP/case$case_name.out" "no such file" "case 1: the host file was found"

# The launch: env before the image, command after it.
has "$TMP/run.env" "FAST_ODB=$ODB_C" "case 1: FAST_ODB reached the container's environment"
has "$TMP/run.env" "FAST_END_ITER=16" "case 1: FAST_END_ITER reached the container's environment"
has "$TMP/run.env" "FAST_TAG=ext_ws_v3" "case 1: FAST_TAG reached the container's environment"
has "$TMP/run.cmd" "exec bash /work/drt_fast/run_drt.sh" "case 1: the command is the fast-loop runner"
hasnt "$TMP/run.cmd" "FAST_ODB=" "case 1: no -e flag landed on the wrong side of the image name"

# The measurement itself.
has "$REP" "reproduced the flow's own pass-0 counts exactly" "case 1: the instrument check passes"
has "$REP" "**Measured cost of the cap: **55000 violations (21.48 % of the count standing at the cap).**" \
    "case 1: the withheld iterations' measured cost"
has "$REP" "What it took:" "case 1: the withheld iterations' wall clock is measured"
# The status line carries the container's own exit code. It read empty until the one
# call site that spelled `docker` instead of the $DOCKER seam was fixed -- this
# assertion is what keeps that from coming back unnoticed.
has "$REP" "container exit 0" "case 1: the container's exit code reaches the report"
has "$REP" "## Predicted vs measured" "case 1: the report is compared against the extrapolation"
has "$REP" "still falling" "case 1: the report distinguishes a falling curve from a plateau"
has "$OUT/ext_ws_v3/drt_verdict.txt" "VERDICT CONVERGING" "case 1: the extension's tail verdict comes from the watcher"

# ---------------------------------------------------------------- case 2 -----
# The confounded call: the extension did not reproduce the flow's pass 0, so no
# difference may be quoted. A report that quotes one anyway is the failure mode.
next_case
make_log "$TMP/fixture.log" 1240000 480000 402000 349000 318000 291000 271000 256000 $WITHHELD
run_extend "$OUT" --odb "$ODB_C" --tag ws_v3 --flow-state "$TMP/flow_state.tsv" \
    --end-iter 16 --deadline-h 1 > /dev/null 2>&1
REP=$OUT/drt_cap_cost_measured.md
has "$REP" "did NOT reproduce the flow's curve" "case 2: a mismatch is called a mismatch"
has "$REP" "Not quotable" "case 2: no cost is quoted from a confounded pair"

# ---------------------------------------------------------------- case 3 -----
# The box is still busy with the flow: the extension must not launch, and it must
# say so in the report rather than looking like a measurement that had not run yet.
next_case
rm -f "$TMP/state/flow_gone"          # the flow is still running: the wait case
run_extend "$OUT" --odb "$ODB_C" --tag ws_v3 --flow-state "$TMP/flow_state.tsv" \
    --end-iter 16 --deadline-h 0 > /dev/null 2>&1
rc=$?
REP=$OUT/drt_cap_cost_measured.md
chk "case 3: a busy box is a non-zero exit" 1 "$rc"
has "$REP" "not launched" "case 3: the no-launch is reported"
has "$REP" "## The command this refused to run" "case 3: the refused command is kept for a human"
has "$OUT/drt_extend.log" "NOT_LAUNCHED 0h-deadline code=WAITING_FOR_ws_flow" "case 3: the event log says what it was still waiting for"
has "$REP" "still WAITING_FOR_ws_flow" "case 3: and so does the report"

# ---------------------------------------------------------------- case 4 -----
# The flow is gone but something else is routing: 8 cores and two routers is the
# state this script exists to prevent, so it waits rather than sharing.
next_case
touch "$TMP/state/busy"
run_extend "$OUT" --odb "$ODB_C" --tag ws_v3 --flow-state "$TMP/flow_state.tsv" \
    --end-iter 16 --deadline-h 0 > /dev/null 2>&1
REP=$OUT/drt_cap_cost_measured.md
has "$OUT/drt_extend.log" "BUSY_FOR_OTHER_ROUTER" "case 4: another router is detected"
has "$OUT/drt_extend.log" "NOT_LAUNCHED 0h-deadline code=WAITING_FOR_OTHER_ROUTER" "case 4: and it does not launch into it"
hasnt "$OUT/drt_extend.log" "LAUNCHED name=drt_ext_ws_v3" "case 4: no container was launched"

# ---------------------------------------------------------------- case 5 -----
# The gate refuses at the launch point even though the cheap poll passed -- the
# case that would spin forever if the backoff forgot its deadline.
next_case
touch "$TMP/state/refuse_preflight"
run_extend "$OUT" --odb "$ODB_C" --tag ws_v3 --flow-state "$TMP/flow_state.tsv" \
    --end-iter 16 --deadline-h 0 > /dev/null 2>&1
REP=$OUT/drt_cap_cost_measured.md
has "$OUT/drt_extend.log" "GATE_REFUSED MEM_LOW" "case 5: the authoritative gate gets its say"
has "$OUT/drt_extend.log" "NOT_LAUNCHED 0h-deadline" "case 5: and its deadline is still honoured"
has "$OUT/drt_extend.log" "code=WAITING_FOR_MEM_LOW" "case 5: with the reason it was waiting on"
rm -f "$TMP/state/refuse_preflight"

# ---------------------------------------------------------------- case 6 -----
# A database that is not there: refuse, do not launch with an empty FAST_ODB (which
# would route the fast loop's default checkpoint and label it as this step's).
next_case
run_extend "$OUT" --odb /work/ws/template/librelane/runs/ws_v3/nope/chip_top.odb --tag ws_v3 \
    --end-iter 16 --deadline-h 0 > "$TMP/case6.out" 2>&1
rc=$?
chk "case 6: a missing database is a hard error" 1 "$rc"
has "$TMP/case6.out" "no such file" "case 6: and it says which file"
has "$OUT/drt_extend.log" "FATAL odb_missing" "case 6: recorded in the event log"

# The interface itself: a caller who forgot the database is told that, and not to
# look at a gate path that is missing because this is not the flow box.
EXT_WS=$WS EXT_ROOT=$ROOT EXT_OUT=$OUT bash "$RUNNER" > "$TMP/case6b.out" 2>&1
chk "case 6b: no --odb is a hard error" 1 "$?"
has "$TMP/case6b.out" "--odb is required" "case 6b: and the message names the argument"
hasnt "$TMP/case6b.out" "no gate script" "case 6b: it does not complain about the gate first"

# ---------------------------------------------------------------- case 7 -----
# A cap that the capture does not cover: the report has to say that the iteration
# it calls "the cap" may not be the one the flow stopped at, because a watcher can
# only stamp counts it sees arriving.
next_case
make_log "$TMP/fixture.log" $ALL
run_extend "$OUT" --odb "$ODB_C" --tag ws_v3 --flow-state "$TMP/flow_state.tsv" \
    --cap 16 --end-iter 16 --deadline-h 1 > /dev/null 2>&1
REP=$OUT/drt_cap_cost_measured.md
has "$REP" "the flow's capture holds 8 pass-0 counts" "case 7: a short capture is disclosed, not hidden"
has "$REP" "DRT_OPT_ITERS=16" "case 7: and the cap quoted is the one it was told"

# ----------------------------------------------------------------- watcher ---
# The watcher's half: when the step finishes with the tail still falling it queues
# the runner itself, with the step's own database and cap, detached. The runner is
# stubbed here -- case 1-6 above are the runner's own test.
RUNS=$WS/template/librelane/runs
TAG=ws_v3
STEP=$RUNS/$TAG/43-openroad-detailedrouting
mkdir -p "$STEP"
printf '{"DRT_OPT_ITERS": 8}' > "$RUNS/$TAG/resolved.json"
echo "0:00:00" > "$STEP/runtime.txt"
printf '{\n    "odb": "%s",\n    "nl": "/work/x.v"\n}\n' "$ODB_C" > "$STEP/state_in.json"
make_log "$STEP/openroad-detailedrouting.log" $FLOW

cat > "$TMP/stub_runner.sh" <<'STUB'
#!/bin/bash
rm -f "$STUB_STATE/runner.argv"
printf '%s\n' "$@" >> "$STUB_STATE/runner.argv"
STUB

watch_case() { # $1 = out dir, rest = extra env assignments
    local out=$1; shift
    env "$@" WATCH_WS=$WS WATCH_RUNS=$RUNS WATCH_OUT=$out WATCH_RUNNER=$TMP/stub_runner.sh \
        WATCH_CONTAINER=ws_flow STUB_STATE=$TMP/state \
        bash "$WATCHER" --tag $TAG --log "$STEP/openroad-detailedrouting.log" --finalize > "$out/watcher.out" 2>&1
}

next_case
rm -f "$TMP/state/runner.argv"
watch_case "$OUT"
rc=$?
chk "watcher: a finished step finalizes cleanly" 0 "$rc"
has "$OUT/drt_cap_cost.md" "## Closing the loop (automatic)" "watcher: the report carries the extension decision"
has "$OUT/drt_cap_cost.md" "Queued now (pid " "watcher: the extension was queued"
has "$OUT/drt_watch.log" "EXTEND_LAUNCHED" "watcher: recorded in the event log"
chk "watcher: the runner was actually started" 0 "$([ -f "$TMP/state/runner.argv" ] && echo 0 || echo 1)"
has "$TMP/state/runner.argv" "--odb" "watcher: with the pre-DRT database"
has "$TMP/state/runner.argv" "$ODB_C" "watcher: the step's own database path"
has "$TMP/state/runner.argv" "--end-iter" "watcher: and the iteration count"
has "$TMP/state/runner.argv" "16" "watcher: 2x the cap"
has "$TMP/state/runner.argv" "--cap" "watcher: and the cap the flow used"

# The plateaus: v8's own curve is what says "do not buy more iterations", and the
# report has to say it out loud rather than look like it forgot.
next_case
make_log "$STEP/openroad-detailedrouting.log" 278169 266147 261189 258601 256296 254306
rm -f "$TMP/state/runner.argv"
watch_case "$OUT"
has "$OUT/drt_cap_cost.md" "Not launched:" "watcher: a plateau is not extended"
has "$OUT/drt_cap_cost.md" "calls a plateau" "watcher: and the reason is the classifier's own threshold"
chk "watcher: and nothing was launched" 1 "$([ -f "$TMP/state/runner.argv" ] && echo 0 || echo 1)"

# The switch, for a run whose operator wants the report and nothing else.
next_case
make_log "$STEP/openroad-detailedrouting.log" $FLOW
rm -f "$TMP/state/runner.argv"
watch_case "$OUT" WATCH_EXTEND=0
has "$OUT/drt_cap_cost.md" "Not launched: WATCH_EXTEND=0" "watcher: WATCH_EXTEND=0 is honoured"
chk "watcher: and launches nothing" 1 "$([ -f "$TMP/state/runner.argv" ] && echo 0 || echo 1)"

echo
echo "extend_selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
