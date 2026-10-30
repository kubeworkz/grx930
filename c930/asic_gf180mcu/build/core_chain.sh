#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# core_chain.sh -- arm CORE: slot-core floorplan vs the 33.4%-util baseline.
#
#   CORE_AREA 441 441 3489 4679 (3048 x 4238 = 12.92 mm2, the pad-ring channel
#   edge from pad_ring.cfg section 1) with DIE_AREA unchanged -> utilization
#   33.4 % -> 51.6 %. Then the same fast DRT loop (2 iterations, same 6 DRT
#   arguments) and the same violation-checkpoint comparison.
#
# Baseline to beat (2.3.10, CORE_AREA unset, 33.4 % util):
#   GRT wirelength 24,215,167 um | iter0 1,081,775 | iter1 405,529 | iter2 387,049
# Arm GRT03 (stock GRT_ADJUSTMENT=0.3 on the fat layout) was dropped on evidence:
# GRT logged "Global adjustment: 30%" then "Running extra iterations to remove
# overflow" -- the overflow regime that made DRT diverge historically -- and it
# filled the 150 GB volume before it produced a congestion report.
set -u
D=/home/ubuntu/grx930_ol2/drt_fast
B=/home/ubuntu/grx930_ol2/build
RUNS=/home/ubuntu/grx930_ol2/openlane2_rtl/runs
IMG=ghcr.io/efabless/openlane2:2.3.10
LOG=$D/core_chain.log
say() { echo "[$(date -u)] $*" | tee -a $LOG; }
ps_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
. "$B/gate.sh"   # free_gb + the disk/memory gate, defined once for every chain

probe() {
  docker run --rm --user 0:0 -v /home/ubuntu/grx930_ol2:/work -e FAST_ODB="$1" \
    --entrypoint /bin/sh $IMG -c "openroad -exit /work/drt_fast/place_probe2.tcl" 2>&1 \
    | grep -aE "DIE_UM|CORE_UM|INSTS|UTIL_PCT"
}

say "CORE_CHAIN_START"

# Disk + memory gate, both defined in gate.sh (sourced above). The DRT arm this
# chain ends with peaks at 6.4-7.0 GB (measured across the sweep arms), and the
# historical failure was a 7-hour run that died at "OOM at 60 % iter 0, swap
# exhausted". Refuse to start rather than discover it hours in.
gate 8000 core_chain || { say "ABORT_$GATE_REASON"; exit 1; }

# ---- arm CORE: flow to the antennas checkpoint ------------------------------
docker rm -f ol2_core >/dev/null 2>&1
docker run -d --name ol2_core --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
  --entrypoint /bin/sh $IMG /work/build/core_exec.sh >/dev/null
say "ARM_CORE_LAUNCHED (config.json + core_area_cfg.json, -T OpenROAD.RepairAntennas)"
while [ "$(ps_running ol2_core)" = "true" ]; do sleep 30; done
docker logs ol2_core > $D/logs/ol2_core.log 2>&1
say "ol2_core_EXIT rc=$(docker inspect -f '{{.State.ExitCode}}' ol2_core 2>/dev/null)"
docker rm -f ol2_core >/dev/null 2>&1   # drop the ~3 GB PDK copy in its layer
tail -3 $B/core_flow.log | tee -a $LOG

RUN=$RUNS/slotcore_v1
if [ ! -d "$RUN" ]; then RUN=$(ls -1dt $RUNS/*/ 2>/dev/null | head -1); fi
# The antennas ODB sits one level deeper than the step dir
# (41-openroad-repairantennas/1-diodeinsertion/*.odb); the previous
# $RUN/*-openroad-repairantennas/*.odb glob missed it and the chain reported
# CORE_NO_CKPT after a run that had in fact completed. Take the newest
# recursively so a re-run that appends higher ordinals still resolves.
F=$(find "$RUN" -path '*openroad-repairantennas*' -name '*.odb' \
      -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
say "CORE_CKPT $F"
if [ -z "$F" ]; then say "CORE_NO_CKPT (flow produced no antennas ODB)"; df -h /home | tail -1 | tee -a $LOG; say "CORE_CHAIN_COMPLETE"; exit 0; fi

cp -f "$F" $D/ckpt/pre_drt_slotcore.odb
say "CORE_CKPT_MB $(stat -c %s $D/ckpt/pre_drt_slotcore.odb | awk '{printf "%.0f", $1/1048576}')"
P=$(probe /work/drt_fast/ckpt/pre_drt_slotcore.odb)
echo "$P" | tee -a $LOG
grep -ah "Total wirelength" $RUN/*-openroad-globalrouting/*.log 2>/dev/null | tail -2 | tee -a $LOG
grep -ah -A9 "Final congestion report" $RUN/*-openroad-globalrouting/*.log 2>/dev/null | tail -10 | tee -a $LOG
GREP_U=$(grep -aho '"design__instance__utilization": [0-9.]*' $RUN/*-openroad-globalrouting/state_out.json 2>/dev/null | tail -1)
say "CORE_UTIL_METRIC $GREP_U"

if echo "$P" | grep -qaE "CORE_UM 304[0-9]"; then
  say "CORE_GATE_PASS (core 3048x4238)"
  # Re-check memory here, not just at the top: the flow arm above just ran for
  # over an hour, and this is the arm that actually needs 6-7 GB. MIN_GB 0 --
  # this arm's disk figure is reported, never a refusal, as before.
  gate 8000 core_chain_drt 0 || { say "ABORT_$GATE_REASON (DRT arm)"; exit 1; }
  docker rm -f drt_core >/dev/null 2>&1
  # -e must come BEFORE the image name: docker treats everything after the
  # image as the container command, so place-after-image made /bin/sh try to
  # run "FAST_TAG=core" as a file (env never reached run_drt.sh).
  docker run -d --name drt_core --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
    -e FAST_TAG=core -e FAST_ODB=/work/drt_fast/ckpt/pre_drt_slotcore.odb -e FAST_END_ITER=2 \
    -e FAST_MIN_LAYER=Metal1 -e FAST_MAX_LAYER=Metal5 -e FAST_THREADS=8 \
    --entrypoint /bin/sh $IMG \
    -c "exec bash /work/drt_fast/run_drt.sh" >/dev/null
  say "DRT_CORE_LAUNCHED"
  while [ "$(ps_running drt_core)" = "true" ]; do sleep 60; done
  docker logs drt_core > $D/logs/core_drt.log 2>&1
  say "DRT_CORE_DONE rc=$(docker inspect -f '{{.State.ExitCode}}' drt_core 2>/dev/null)"
  grep -a "Number of violations" $D/logs/core_drt.log | tail -4 | tee -a $LOG
  grep -a "Total wire length" $D/logs/core_drt.log | tail -6 | tee -a $LOG
else
  say "CORE_GATE_FAIL (core not 3048x4238 -- override did not take; DRT skipped)"
  grep -a -iE "error|invalid" $B/core_flow.log | head -5 | tee -a $LOG
fi

df -h /home | tail -1 | tee -a $LOG
say "CORE_CHAIN_COMPLETE"
