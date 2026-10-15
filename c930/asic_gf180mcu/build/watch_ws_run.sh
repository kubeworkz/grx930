#!/bin/bash
# watch_ws_run.sh -- host side: a step-level heartbeat for a wafer.space flow run,
# plus a FINAL block with the landing. Detached on purpose, so the record
# survives the SSH session that started the run:
#
#   ssh box 'setsid nohup env WS_TAG=ws_v3 /home/ubuntu/grx930_ol2/build/watch_ws_run.sh >/dev/null 2>&1 &'
#
# Why it exists next to ws_chain.sh: the chain reports the container's exit code
# and a log tail, which is not enough here. A LibreLane run carries its own
# exit code in the chain log (WS_EXIT) and in runs/<tag>/error.log, `docker
# inspect` reports ExitCode=0 for a failed flow because ws_exec.sh ends on
# `echo`, and the interesting question is always *which step* it stopped at --
# so this file records the step directory progression, whether a step was
# skipped, and the error line that ended it.
#
#   WS_TAG=ws_v3        run tag under template/librelane/runs
#   WS_CONT=ws_flow     container name to watch
set -u
W=/home/ubuntu/grx930_ol2/ws
TAG=${WS_TAG:-ws_v1}
CONT=${WS_CONT:-ws_flow}
R=$W/template/librelane/runs/$TAG
L=$W/logs/$TAG.watch.log
# ws_chain.sh appends to one shared log for every tag (LOG=$WS/ws_chain.log), and
# writes the per-tag container log only after the container exits -- so the FINAL
# block reads the container's own stream with `docker logs` rather than that file.
CHAIN=$W/ws_chain.log
mkdir -p "$W/logs"
clog() { docker logs "$CONT" 2>&1; }
say() { echo "[$(date -u +%FT%TZ)] $*" >> "$L"; }
step_now() { ls -1d "$R"/[0-9]* 2>/dev/null | tail -1 | sed 's#.*/##'; }

say "WATCH_START tag=$TAG container=$CONT"
while [ "$(docker inspect -f '{{.State.Running}}' "$CONT" 2>/dev/null)" = "true" ]; do
    say "running step=$(step_now) free_gb=$(df -h / | awk 'NR==2{print $4}') run_mb=$(du -sm "$R" 2>/dev/null | awk '{print $1}')"
    sleep 300
done

{
    echo "==================== FINAL @ $(date -u +%FT%TZ) ===================="
    docker inspect "$CONT" --format 'running={{.State.Running}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} start={{.State.StartedAt}} end={{.State.FinishedAt}}' 2>&1
    echo "--- steps reached: $(ls -1d "$R"/[0-9]* 2>/dev/null | wc -l)"
    ls -1d "$R"/[0-9]* 2>/dev/null | sed 's#.*/##' | tail -25
    echo "--- the queued question: was the post-GPL repair skipped, and where did the flow go?"
    clog | grep -a "Skipping step" | tail -8
    clog | grep -aE "RepairDesignPostGPL|OpenROAD.CTS|DetailedPlacement|GlobalRouting" | tail -12
    echo "--- chain log tail"
    tail -12 "$CHAIN" 2>/dev/null
    echo "--- runs/$TAG/error.log"
    cat "$R/error.log" 2>/dev/null
    echo "--- flow.log ERROR lines"
    grep -a "ERROR" "$R/flow.log" 2>/dev/null | tail -10
    echo "--- warnings of note in the flow"
    clog | grep -aE "WARNING" | grep -av "STA-1140" | tail -8
    echo "--- layout / netlist artifacts"
    find "$R" -name '*.gds*' -o -name '*.oas' -o -name '*.spef' 2>/dev/null | head
    echo "--- disk"
    df -h / | tail -1
} >> "$L" 2>&1
say "WATCH_FINAL_WRITTEN"
