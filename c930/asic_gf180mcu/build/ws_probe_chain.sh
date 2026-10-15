#!/bin/bash
# ws_probe_chain.sh -- host side: run the isolated step-31 probe and record
# whether the capped repair gets past the point that killed ws_v2.
#
# Launch it detached, because it outlives the SSH session that starts it:
#
#   ssh box 'setsid nohup env PROBE_TAG=ws_v3_probe /home/ubuntu/grx930_ol2/build/ws_probe_chain.sh >/dev/null 2>&1 &'
#
# It answers one question with the probe's own logs: how many buffers does the
# capped post-GPL repair insert now, and does the detailed placement after it
# pass? The comparison baseline is in the run that failed -- RSZ-0038 inserted
# 97,969 buffers in 17,652 nets, and DPL-0036 aborted the flow.
set -u
ROOT=/home/ubuntu/grx930_ol2
WS=$ROOT/ws
IMG=ghcr.io/wafer-space/gf180mcu-precheck
TAG=${PROBE_TAG:-ws_v3_probe}
STATETAG=${PROBE_STATE_TAG:-ws_v2}
R=$WS/template/librelane/runs/$TAG
LOG=$WS/logs/$TAG.chain.log
mkdir -p "$WS/logs"
say() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
running() { docker inspect -f '{{.State.Running}}' ws_probe 2>/dev/null; }

say "PROBE_CHAIN_START tag=$TAG state_tag=$STATETAG"
[ -f "$WS/template/librelane/runs/$STATETAG/30-openroad-stamidpnr/state_out.json" ] \
    || { say "ABORT_NO_STATE"; exit 1; }
# The disk/memory gate the other chains share; this job is one OpenROAD at
# ~4.5 GB RSS and writes one run tree, so the floor is the same as ws_chain's.
if [ -f "$ROOT/build/gate.sh" ]; then
    . "$ROOT/build/gate.sh"
    gate 9000 ws_probe 10 / || { say "ABORT_$GATE_REASON"; exit 1; }
fi

docker rm -f ws_probe >/dev/null 2>&1
docker run -d --name ws_probe --user 0:0 -e HOME=/root \
    -v "$ROOT":/work -e "PROBE_TAG=$TAG" -e "PROBE_STATE_TAG=$STATETAG" \
    "$IMG" /work/ws/probe_step31.sh >/dev/null || { say "ABORT_DOCKER_RUN"; exit 1; }
say "PROBE_LAUNCHED"

while [ "$(running)" = "true" ]; do
    RSZ=$(grep -ah -m1 "RSZ-0038" "$R"/31-*/openroad-repairdesignpostgpl.log 2>/dev/null | tail -1 | tr -d '\r')
    STEP=$(ls -1 "$R" 2>/dev/null | tail -1)
    say "running step=${STEP:-none} rsz0038=${RSZ:-not-yet}"
    sleep 120
done

# ---- what the probe produced ----------------------------------------------
BUF=$(grep -aho "Inserted [0-9]* buffers in [0-9]* nets" "$R"/31-*/openroad-repairdesignpostgpl.log 2>/dev/null | tail -1)
DPLPASS=$(grep -acE "DPL-00(3[0-9]|[45][0-9])" "$R"/31-*/openroad-repairdesignpostgpl.log 2>/dev/null)
{
    echo "==================== FINAL @ $(date -u +%FT%TZ) ===================="
    docker inspect ws_probe --format 'running={{.State.Running}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} start={{.State.StartedAt}} end={{.State.FinishedAt}}' 2>&1
    echo "--- VERDICT"
    echo "buffers inserted : ${BUF:-none found}"
    echo "DPL error lines  : ${DPLPASS:-0}  (0 = detailed placement did not complain)"
    echo "run error.log    : $(cat "$R"/error.log 2>/dev/null || echo '<absent>')"
    echo "--- probe stdout (head 12 / tail 30)"
    docker logs ws_probe 2>&1 | head -12
    docker logs ws_probe 2>&1 | tail -30
    echo "--- probe run tree"
    ls -1 "$R" 2>/dev/null
    echo "--- step 31 log: the numbers that matter"
    grep -anE "RSZ-003[3-9]|RSZ-0042|DPL-003[0-9]|repair_design -|detailed_placement -|Area \|" \
        "$R"/31-*/openroad-repairdesignpostgpl.log 2>/dev/null | tail -20
    echo "--- step 31 log: last 20 lines"
    tail -20 "$R"/31-*/openroad-repairdesignpostgpl.log 2>/dev/null
    echo "--- density before/after, if the step wrote metrics"
    grep -o "\"design__instance__utilization[a-z_]*\": [0-9.]*" "$R"/31-*/state_out.json 2>/dev/null | head -6
    echo "--- disk"
    df -h / | tail -1
} >> "$LOG" 2>&1
say "PROBE_CHAIN_COMPLETE"
