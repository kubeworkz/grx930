#!/bin/bash
# both_chain.sh -- two routing experiments, serialized on the 8-core box.
#
#   arm CORE  : slot-core floorplan (CORE_AREA 441 441 3489 4679, 12.92 mm2,
#               the pad-ring channel edge) vs the 33.4%-util baseline.
#               Predicted: ~-20 % wirelength (area 0.648x, WL ~ sqrt), peak
#               local density 61 % -> ~65 % (target cap) -- DRT outcome is the
#               real question, not the wirelength.
#   arm GRT03 : stock GRT_ADJUSTMENT=0.3 on the baseline layout, isolating the
#               guide-headroom variable.
#
# Each arm: OL2 flow to the antennas checkpoint -> geometry probe gate -> fast
# DRT loop (2 iterations, same 6 DRT arguments as the baseline).
# Baselines to beat (2.3.10, GRT_ADJUSTMENT=0.0, 33.4 % util):
#   iter0 1,081,775 | iter1 405,529 | iter2 387,049 | GRT wirelength 24,215,167 um
set -u
D=/home/ubuntu/grx930_ol2/drt_fast
B=/home/ubuntu/grx930_ol2/build
RL=/home/ubuntu/grx930_ol2/openlane2_rtl
RUNS=$RL/runs
V8=$RUNS/RUN_2026-09-30_23-41-23
IMG=ghcr.io/efabless/openlane2:2.3.10
LOG=$D/both_chain.log
say() { echo "[$(date -u)] $*" | tee -a $LOG; }
ps_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
free_gb() { df -BG --output=avail /home | tail -1 | tr -dc '0-9'; }

probe() {
  docker run --rm --user 0:0 -v /home/ubuntu/grx930_ol2:/work -e FAST_ODB="$1" \
    --entrypoint /bin/sh $IMG -c "openroad -exit /work/drt_fast/place_probe2.tcl" 2>&1 \
    | grep -aE "DIE_UM|CORE_UM|INSTS|UTIL_PCT"
}

run_drt() { # $1 tag  $2 ckpt(in-container)  $3 logfile
  docker rm -f drt_$1 >/dev/null 2>&1
  docker run -d --name drt_$1 --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
    --entrypoint /bin/sh $IMG \
    -e FAST_TAG=$1 -e FAST_ODB=$2 -e FAST_END_ITER=2 \
    -e FAST_MIN_LAYER=Metal1 -e FAST_MAX_LAYER=Metal5 -e FAST_THREADS=8 \
    -c "exec bash /work/drt_fast/run_drt.sh" >/dev/null
  while [ "$(ps_running drt_$1)" = "true" ]; do sleep 60; done
  docker logs drt_$1 > $D/logs/$3 2>&1
  say "DRT_$1_DONE rc=$(docker inspect -f '{{.State.ExitCode}}' drt_$1 2>/dev/null)"
  grep -a "Number of violations" $D/logs/$3 | tail -3 | tee -a $LOG
}

wait_flow() { # $1 container name
  while [ "$(ps_running $1)" = "true" ]; do sleep 30; done
  docker logs $1 > $D/logs/$1.container.log 2>&1
  say "$1_EXIT rc=$(docker inspect -f '{{.State.ExitCode}}' $1 2>/dev/null)"
}

say "BOTH_CHAIN_START"

# ---- newor2 (26Q3 A/B): keep the initial route, then free the box -----------
# The initial-route curve is the decisive part of that A/B (it already shows
# 26Q3 is not the fix); its optimization iterations are expendable next to the
# floorplan experiment the user asked for.
while [ "$(ps_running drt_newor2)" = "true" ]; do
  if docker logs drt_newor2 2>&1 | grep -qa "1st optimization iteration"; then
    say "NEWOR2_ITER0_DONE"
    docker stop -t 20 drt_newor2 >/dev/null 2>&1
    sleep 5
    docker logs drt_newor2 > $D/logs/newor2.log 2>&1
    grep -a "Number of violations" $D/logs/newor2.log | head -11 | tee -a $LOG
    break
  fi
  sleep 30
done

# ---- wait for the disk compressor, then check headroom ---------------------
while [ -f $D/compress.running ]; do sleep 30; done
say "DISK_GB_FREE $(free_gb)"

# ============================ arm CORE ======================================
docker rm -f ol2_core >/dev/null 2>&1
docker run -d --name ol2_core --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
  --entrypoint /bin/sh $IMG /work/build/core_exec.sh >/dev/null
say "ARM_CORE_LAUNCHED (CORE_AREA [441,441,3489,4679], -T OpenROAD.RepairAntennas)"
wait_flow ol2_core
tail -4 $B/core_flow.log | tee -a $LOG

RUN=$RUNS/slotcore_v1
if [ ! -d "$RUN" ]; then RUN=$(ls -1dt $RUNS/*/ 2>/dev/null | head -1); fi
F=$(ls -t $RUN/*-openroad-repairantennas/*.odb 2>/dev/null | head -1)
say "CORE_CKPT $F"
if [ -n "$F" ]; then
  cp -f "$F" $D/ckpt/pre_drt_slotcore.odb
  say "CORE_CKPT_MB $(stat -c %s $D/ckpt/pre_drt_slotcore.odb | awk '{printf "%.0f", $1/1048576}')"
  P=$(probe /work/drt_fast/ckpt/pre_drt_slotcore.odb)
  echo "$P" | tee -a $LOG
  grep -ah "Total wirelength" $RUN/*-openroad-globalrouting/*.log 2>/dev/null | tail -2 | tee -a $LOG
  grep -ah -A9 "Final congestion report" $RUN/*-openroad-globalrouting/*.log 2>/dev/null | tail -10 | tee -a $LOG
  if echo "$P" | grep -qaE "CORE_UM 304[0-9]"; then
    say "CORE_GATE_PASS (core 3048x4238)"
    run_drt core /work/drt_fast/ckpt/pre_drt_slotcore.odb core_drt.log
  else
    say "CORE_GATE_FAIL (core not 3048x4238 -- override did not take; DRT skipped)"
  fi
else
  say "CORE_NO_CKPT (flow produced no antennas ODB)"
fi

# ============================ arm GRT03 =====================================
docker rm -f ol2_grt03b >/dev/null 2>&1
docker run -d --name ol2_grt03b --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
  --entrypoint /bin/sh $IMG /work/build/grt03b_exec.sh >/dev/null
say "ARM_GRT03_LAUNCHED (resume v8 from GlobalRouting, GRT_ADJUSTMENT=0.3, stop at RepairAntennas)"
wait_flow ol2_grt03b
tail -4 $B/grt03b_flow.log | tee -a $LOG

F2=$(ls -t $V8/*-openroad-repairantennas/*.odb 2>/dev/null | head -1)
say "GRT03_CKPT $F2"
if [ -n "$F2" ]; then
  cp -f "$F2" $D/ckpt/pre_drt_grt03.odb
  P2=$(probe /work/drt_fast/ckpt/pre_drt_grt03.odb)
  echo "$P2" | tee -a $LOG
  GR=$(ls -1dt $V8/*-openroad-globalrouting/ 2>/dev/null | head -1)
  grep -ah -E "Global adjustment" $GR/*.log 2>/dev/null | head -2 | tee -a $LOG
  grep -ah "Total wirelength" $GR/*.log 2>/dev/null | tail -2 | tee -a $LOG
  grep -ah -A9 "Final congestion report" $GR/*.log 2>/dev/null | tail -10 | tee -a $LOG
  run_drt gr03b /work/drt_fast/ckpt/pre_drt_grt03.odb gr03b_drt.log
else
  say "GRT03_NO_CKPT"
fi

df -h /home | tail -1 | tee -a $LOG
say "BOTH_CHAIN_COMPLETE"
