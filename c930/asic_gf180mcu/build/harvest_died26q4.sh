#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# harvest_died26q4.sh -- wait for the diode-flow arm to exit, then freeze what it produced
# into one file. The arm's own chain writes drt_fast/verdict/die_diode_flow_arm.md at exit,
# but that report carries the pre-DRT repair lines and the DRT curve; the numbers the antenna
# waiver needs (the router's own antenna pass on the routed database, and the final count) are
# in the step's log, so they are extracted here too.
#
# Launch: setsid nohup bash build/harvest_died26q4.sh >/dev/null 2>&1 < /dev/null &
# Output: drt_fast/verdict/died26q4_post_route.txt
set -u
cd /home/ubuntu/grx930_ol2 || exit 1

while pgrep -f 'build/die_diode_flow_chain\.sh$' >/dev/null; do sleep 120; done

OUT=drt_fast/verdict/died26q4_post_route.txt
STEP=ws/template/librelane/runs/died26q4/06-openroad-detailedrouting
{
    echo "harvested $(date -u +%FT%TZ) tag=died26q4"
    echo
    echo "== chain tail =="
    tail -8 ws/logs/die_diode_flow_chain.log
    echo
    echo "== DRT curve =="
    grep -aoE 'Start [0-9]+th optimization iteration|Completing 100% with [0-9]+ violations|Number of violations = [0-9]+' \
        ws/logs/predrt_died26q4.log | tail -90
    echo
    echo "== antenna lines inside the DRT step =="
    grep -ahoE '\[INFO GRT-(0012|0015|0302)\].*' "$STEP"/*.log 2>/dev/null | tail -20
    echo
    echo "== post-route antenna reports =="
    find ws/template/librelane/runs/died26q4 -path '*checkantennas*' -name 'antenna_summary.rpt' \
        -printf '%s %p\n' 2>/dev/null | tail -4
    echo
    echo "== runtime =="
    cat "$STEP/runtime.txt" 2>/dev/null
    echo
    echo "== container =="
    docker inspect -f 'status={{.State.Status}} rc={{.State.ExitCode}} oom={{.State.OOMKilled}}' die_predrt 2>/dev/null
} > "$OUT" 2>&1
echo DONE >> "$OUT"
