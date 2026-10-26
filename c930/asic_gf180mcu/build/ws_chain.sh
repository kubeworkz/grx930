#!/bin/bash
# ws_chain.sh -- host side: run the wafer.space template flow for grx930 in the
# pre-check image and leave the run tree behind. Runs on the flow box
# (ubuntu@49.13.6.8), like drt_fast/*_chain.sh.
#
#   WS_TAG=ws_v1              fresh run tag (never reuse one: a reused tag comes
#                             back with its old netlist)
#   WS_LIMIT=Checker.LintWarnings   optional: stop after a step. Use it for the
#                             first run, which only proves the config loads and
#                             the RTL parses with the pad ring in place.
#
# The image's entrypoint (scripts/dev-shell) wraps the command in the nix
# LibreLane shell, which is the whole point of using this image: LibreLane >= 3
# plus the gf180mcuD PDK, no nix on the host.
set -u
ROOT=/home/ubuntu/grx930_ol2
WS=$ROOT/ws
IMG=ghcr.io/wafer-space/gf180mcu-precheck
LOG=$WS/ws_chain.log
TAG=${WS_TAG:-ws_v1}
say() { echo "[$(date -u)] $*" | tee -a $LOG; }
ps_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
. "$ROOT/build/gate.sh"        # free_gb + the disk/memory gate, defined once for every chain
. "$ROOT/build/disk_guard.sh"  # start/stop the DRT disk guard (DISK_GUARD=0 disables both)
. "$ROOT/build/curve_guard.sh" # start/stop the DRT wall-clock + regression guard

# The guards are stopped on every way out, including the gate refusal below: a
# guard left running after an aborted chain would prune the next arm's tree
# unasked, and a curve guard would stop a container it no longer owns.
on_exit() {
  local rc=$?
  curve_guard_stop "$TAG" >/dev/null 2>&1 || true
  disk_guard_stop "$TAG" >/dev/null 2>&1 || true
  exit "$rc"
}
trap on_exit EXIT

say "WS_CHAIN_START tag=$TAG limit=${WS_LIMIT:-none}"

# Gate, shared with the other chains (gate.sh). Mount and floor are passed
# explicitly here because this chain's run tree is on /, not /home, and 10 GB was
# its own measured floor -- the two places it differs are now arguments in one
# line rather than a copy of the block that could quietly lose them.
# ws_flow runs the full Chip flow (pad ring, ws_ip macros and the 370k-cell core,
# through synthesis and on to detailed routing) with NO cgroup memory cap, so the
# box is the only limit and an OOM here would be the kernel's choice; 9000 MB is
# the measured DRT peak (6.4-7.0 GB) plus margin for the pad ring and its
# synthesis.
gate 9000 ws_chain 10 / || { say "ABORT_$GATE_REASON"; exit 1; }
test -d $WS/template/asic_core || { say "ABORT_NOT_STAGED (run the staging step first)"; exit 1; }

docker rm -f ws_flow >/dev/null 2>&1
docker run -d --name ws_flow --user 0:0 -e HOME=/root \
  -v $ROOT:/work -e "WS_TAG=$TAG" -e "WS_LIMIT=${WS_LIMIT:-}" \
  $IMG /work/ws/ws_exec.sh >/dev/null
say "WS_FLOW_LAUNCHED"
# The step number is discovered by the guards (runs/<tag>/*-openroad-detailedrouting),
# because this flow's DRT is not step 06 in every tag.
disk_guard_start "$TAG" ws_flow
# The bound on the step itself: the iteration cap bounds how MANY iterations run,
# this bounds what they COST and stops a pass whose count gives back a quarter of
# its best. Both guards watch the same step from the moment the container is up,
# so each is already in place when the router starts hours later.
curve_guard_start "$TAG" ws_flow

# The routing verdict is written automatically from here on. watch_drt_curve.sh
# waits for the detailed-routing step to appear (its deadline is IDLE hours, not
# wall clock, so it survives the placement/CTS hours before the router starts),
# rewrites logs/drt_verdict.md on every new iteration, and retires itself when
# the container is gone. Flag-only by default: arming the kill is a deliberate
# act (WATCH_KILL=1 in this chain's environment) and even then it only ever
# SIGTERMs the OpenROAD whose command line names the routing script.
if [ -x $WS/watch_drt_curve.sh ]; then
  nohup env WATCH_KILL=${WATCH_KILL:-0} bash $WS/watch_drt_curve.sh --tag "$TAG" \
      >> $WS/logs/drt_watch.nohup 2>&1 &
  say "DRT_WATCHER_STARTED tag=$TAG kill=${WATCH_KILL:-0} pid=$!"
else
  say "DRT_WATCHER_MISSING (stage wafer_space_integration/watch_drt_curve.sh to $WS/)"
fi

while [ "$(ps_running ws_flow)" = "true" ]; do sleep 30; done
# The container is gone, so nothing can grow the step tree any more; stop the guards
# before the harvest rather than at exit, and leave the trap as the abort net.
curve_guard_stop "$TAG"
say "DRT_CURVE_GUARD $(curve_guard_verdict "$TAG")"
disk_guard_stop "$TAG"
docker logs ws_flow > $WS/logs/ws_flow.$TAG.log 2>&1
say "WS_FLOW_EXIT rc=$(docker inspect -f '{{.State.ExitCode}}' ws_flow 2>/dev/null)"
# The watcher's last verdict, if the run reached detailed routing at all.
[ -f $WS/logs/drt_verdict.txt ] && say "DRT_VERDICT $(cat $WS/logs/drt_verdict.txt)" \
  || say "DRT_VERDICT none (the flow never reached detailed routing)"
say "WS_FLOW_LOG_MB $(stat -c %s $WS/logs/ws_flow.$TAG.log | awk '{printf "%.1f", $1/1048576}')"
tail -6 $WS/logs/ws_flow.$TAG.log | tee -a $LOG
grep -aE "ERROR|Fatal|error:" $WS/logs/ws_flow.$TAG.log | head -8 | tee -a $LOG
RUN=$(ls -1dt $WS/template/librelane/runs/*/ 2>/dev/null | head -1)
say "WS_RUN_DIR ${RUN:-none}"
[ -n "$RUN" ] && { ls -1 "$RUN" | tail -8 | tee -a $LOG; }
df -h / | tail -1 | tee -a $LOG
say "WS_CHAIN_COMPLETE"
