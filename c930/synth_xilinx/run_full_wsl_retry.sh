#!/bin/bash
# -----------------------------------------------------------------------------
# run_full_wsl_retry.sh -- In-VM retry driver for the full Vivado flow.
#
# This machine's Windows side tears down the WSL utility VM (or its biggest
# process) under host commit-limit pressure, which kills synthesis mid-run.
# A Windows Task Scheduler job (retry_task.cmd) invokes this script every
# few minutes; it is idempotent:
#
#   * exits immediately if the flow is already running (single instance)
#   * exits immediately if the routed checkpoint already exists (done)
#   * heals eth0's MAC when a fresh VM boot races fix-wsl-mac.sh -- the
#     node-locked license HOSTID depends on it, and a wrong MAC makes
#     Vivado refuse to launch with a license error
#   * otherwise launches run_full_wsl.sh once and waits for it
#
# run_synth.tcl and create_and_synth.sh are resumable: a completed synth_1
# is reused, so a VM recycle costs at most the current run.
# -----------------------------------------------------------------------------

REPO=/mnt/c/Users/kubew/grx930/c930
BUILD=$REPO/build/vivado
LOG=$BUILD/retry.log
MAC=00:15:5d:c5:ac:f9
FINAL_DCP=$BUILD/c930_artix7.runs/impl_1/c930_soc_top_routed.dcp
STAMP=$BUILD/.retry_running

mkdir -p "$BUILD" 2>/dev/null

# ---- single instance -------------------------------------------------------
# Validate the stamp against the process's cmdline: a bare kill -0 also passes
# for an unrelated process whose PID was recycled after the old driver died.
stamp_pid=$(cat "$STAMP" 2>/dev/null)
if [ -n "$stamp_pid" ] && grep -q "run_full_wsl_retry" "/proc/$stamp_pid/cmdline" 2>/dev/null; then
    exit 0
fi
rm -f "$STAMP"
echo $$ > "$STAMP"
trap 'rm -f "$STAMP"' EXIT

echo "=== retry driver tick $(date) ===" >> "$LOG"

# ---- already complete? ------------------------------------------------------
if [ -f "$FINAL_DCP" ]; then
    echo "routed checkpoint present -- nothing to do" >> "$LOG"
    exit 0
fi

# ---- flow already running? --------------------------------------------------
if pgrep -f "run_full_wsl.sh" >/dev/null 2>&1 || pgrep -x vivado >/dev/null 2>&1; then
    echo "flow already running -- standing down" >> "$LOG"
    exit 0
fi

# ---- heal the license MAC if this boot lost the fix-wsl-mac.sh race --------
cur=$(cat /sys/class/net/eth0/address 2>/dev/null)
if [ -n "$cur" ] && [ "$cur" != "$MAC" ]; then
    echo "healing MAC: $cur -> $MAC" >> "$LOG"
    wsl.exe -u root -e bash "$REPO/synth_xilinx/heal_mac.sh" >> "$LOG" 2>&1
    sleep 3
    cur=$(cat /sys/class/net/eth0/address 2>/dev/null)
    echo "MAC after heal: $cur" >> "$LOG"
fi

# ---- launch the flow --------------------------------------------------------
echo "launching flow $(date)" >> "$LOG"
bash "$REPO/synth_xilinx/run_full_wsl.sh" >> "$LOG" 2>&1
rc=$?
echo "flow exited rc=$rc $(date)" >> "$LOG"

# create_and_synth.sh pipes vivado through tee, so rc alone is unreliable;
# the routed checkpoint is the only honest success signal.
if [ -f "$FINAL_DCP" ]; then
    echo "FLOW COMPLETE -- routed checkpoint present $(date)" >> "$LOG"
fi
