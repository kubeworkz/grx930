#!/bin/bash
# grt03c_chain.sh -- arm SLOTCORE-0.3: flow segment -> geometry gate -> fast DRT.
#
# Serialized behind whatever DRT run is currently on the box (drt_core, the
# 0.0 arm) because 8 cores and 15 GB do not carry two DRT processes: the DRT
# process alone peaked at 4-8 GB in the earlier arms.
#
# Baselines to compare against (2 iterations each, same six DRT arguments):
#   fat core,  0.0  exp1:   iter0  1,081,775 | iter1 405,529 | iter2 387,049
#   slot core, 0.0  core:   iter0 20% = 207,648  (fat core at 20% = 190,579)
set -u
D=/home/ubuntu/grx930_ol2/drt_fast
B=/home/ubuntu/grx930_ol2/build
RUNS=/home/ubuntu/grx930_ol2/openlane2_rtl/runs
RUN=$RUNS/slotcore_v1
IMG=ghcr.io/efabless/openlane2:2.3.10
LOG=$D/grt03c_chain.log
say() { echo "[$(date -u)] $*" | tee -a $LOG; }
ps_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
. "$B/gate.sh"   # free_gb + the disk/memory gate, defined once for every chain

# -e before the image: after it, docker passes the flags to the container.
probe() {
  docker run --rm --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
    -e FAST_ODB="$1" --entrypoint /bin/sh $IMG \
    -c "openroad -exit -no_splash /work/drt_fast/place_probe2.tcl" 2>&1 \
    | grep -aE "DIE_UM|CORE_UM|INSTS|UTIL_PCT"
}

say "GRT03C_CHAIN_START"

# Disk + memory gate, both defined in gate.sh (sourced above). This arm ends in a
# fast DRT that peaks at 6.4-7.0 GB (measured): refuse up front rather than OOM
# hours in.
gate 8000 grt03c_chain || { say "ABORT_$GATE_REASON"; exit 1; }

# Serialize: never two DRT/flow processes on this box at once.
while [ "$(ps_running drt_core)" = "true" ]; do
  say "WAIT_FOR_DRT_CORE"
  sleep 300
done
# Capture the 0.0 arm's log before the container is removed: its iteration
# curve is the baseline this arm is compared against.
docker logs drt_core > $D/logs/core_drt.log 2>&1
grep -aE "Completing [0-9]+% with|Start [0-9]+(st|th|nd|rd) optimization iteration" \
  $D/logs/core_drt.log | tail -16 | tee -a $LOG
docker rm -f drt_core >/dev/null 2>&1

docker rm -f ol2_grt03c >/dev/null 2>&1
docker run -d --name ol2_grt03c --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
  --entrypoint /bin/sh $IMG /work/build/slotcore_grt03_exec.sh >/dev/null
say "ARM_GRT03C_LAUNCHED (slotcore_v1 from GlobalRouting, GRT_ADJUSTMENT=0.3)"
while [ "$(ps_running ol2_grt03c)" = "true" ]; do sleep 30; done
docker logs ol2_grt03c > $D/logs/grt03c.container.log 2>&1
say "ol2_grt03c_EXIT rc=$(docker inspect -f '{{.State.ExitCode}}' ol2_grt03c 2>/dev/null)"
docker rm -f ol2_grt03c >/dev/null 2>&1
tail -3 $B/grt03c_flow.log | tee -a $LOG

F=$(find "$RUN" -path '*openroad-repairantennas*' -name '*.odb' \
      -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
say "GRT03C_CKPT $F"
if [ -z "$F" ]; then
  say "GRT03C_NO_CKPT"
  df -h /home | tail -1 | tee -a $LOG
  say "GRT03C_CHAIN_COMPLETE"
  exit 0
fi
cp -f "$F" $D/ckpt/pre_drt_slotcore03.odb
say "GRT03C_CKPT_MB $(stat -c %s $D/ckpt/pre_drt_slotcore03.odb | awk '{printf "%.0f", $1/1048576}')"

# Did 0.3 take effect, and is GRT still clean at this utilization?
GR=$(ls -1dt $RUN/*-openroad-globalrouting/ 2>/dev/null | head -1)
say "GRT03C_GRT_STEP $GR"
grep -ah "Global adjustment" $GR/*.log 2>/dev/null | head -2 | tee -a $LOG
grep -ah "Total wirelength" $GR/*.log 2>/dev/null | tail -2 | tee -a $LOG
grep -ah -A9 "Final congestion report" $GR/*.log 2>/dev/null | tail -11 | tee -a $LOG

P=$(probe /work/drt_fast/ckpt/pre_drt_slotcore03.odb)
echo "$P" | tee -a $LOG
if echo "$P" | grep -qaE "CORE_UM 304[0-9]"; then
  say "GRT03C_GATE_PASS (core 3048x4238)"
  docker rm -f drt_core03 >/dev/null 2>&1
  docker run -d --name drt_core03 --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
    -e FAST_TAG=core03 -e FAST_ODB=/work/drt_fast/ckpt/pre_drt_slotcore03.odb \
    -e FAST_END_ITER=2 \
    -e FAST_MIN_LAYER=Metal1 -e FAST_MAX_LAYER=Metal5 -e FAST_THREADS=8 \
    --entrypoint /bin/sh $IMG -c "exec bash /work/drt_fast/run_drt.sh" >/dev/null
  say "DRT_CORE03_LAUNCHED"
  while [ "$(ps_running drt_core03)" = "true" ]; do sleep 60; done
  docker logs drt_core03 > $D/logs/core03_drt.log 2>&1
  say "DRT_CORE03_DONE rc=$(docker inspect -f '{{.State.ExitCode}}' drt_core03 2>/dev/null)"
  grep -aE "Completing [0-9]+% with|Start [0-9]+(st|th|nd|rd) optimization iteration" \
    $D/logs/core03_drt.log | tail -14 | tee -a $LOG
else
  say "GRT03C_GATE_FAIL (core not 3048x4238 -- override did not take; DRT skipped)"
  grep -a -iE "error|invalid" $B/grt03c_flow.log | head -5 | tee -a $LOG
fi

df -h /home | tail -1 | tee -a $LOG
say "GRT03C_CHAIN_COMPLETE"
