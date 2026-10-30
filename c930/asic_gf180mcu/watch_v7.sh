#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# Watcher for OL2 DRT step 53 (container ol2_grx930_v7).
# stdout of the log is 4 KB-block-buffered: "Completing X%" lines appear in
# bursts. This loop watches for NEW flushed lines, appends them (with a
# timestamp header) to $ALERT, and rewrites $HEART every 60 s.
# Exits when v7_status.txt is no longer V7_RUNNING or after 30 h.
B=/home/ubuntu/grx930_ol2/build
R=/home/ubuntu/grx930_ol2/openlane2_rtl/runs/RUN_2026-09-24_04-18-20
L="$R/53-openroad-detailedrouting/openroad-detailedrouting.log"
ALERT="$B/v7_alert.txt"
HEART="$B/v7_heartbeat.txt"
START=$(date -u +%s)
lastM=-1
echo "WATCH_START $(date -u '+%F %T') log=$L" > "$HEART"

while true; do
  now=$(date -u +%s)
  st=$(cat "$B/v7_status.txt" 2>/dev/null)
  if [ "$st" != "V7_RUNNING" ]; then
    echo "WATCH_END $(date -u '+%F %T') reason=status:$st" >> "$HEART"
    break
  fi
  if [ $((now - START)) -gt 108000 ]; then
    echo "WATCH_END $(date -u '+%F %T') reason=30h_cap" >> "$HEART"
    break
  fi

  if [ -f "$L" ]; then
    # all interesting lines, in file order
    m=$(tr '\r' '\n' < "$L" | grep -ac 'Completing\|DRT-0199' 2>/dev/null || true)
    m=${m:-0}
    if [ "$lastM" -lt 0 ]; then
      lastM=$m
    elif [ "$m" -gt "$lastM" ]; then
      {
        echo "NEW_LINES $(date -u '+%F %T') total=$m"
        tr '\r' '\n' < "$L" | grep -a 'Completing\|DRT-0199' | tail -n +$((lastM + 1))
        echo "END_LINES"
      } >> "$ALERT"
      lastM=$m
    fi

    {
      date -u '+HB_TIME %F %T'
      echo "STATUS $st"
      ls -la "$L" | awk '{print "LOG_BYTES", $5, $6, $7, $8}'
      echo "MATCHED_LINES $m"
      tr '\r' '\n' < "$L" | grep -a 'Completing' | tail -1 | sed 's/^/LAST_COMPLETING /'
      free -m | sed -n '3p' | awk '{print "SWAP_USED_MB", $3, "SWAP_FREE_MB", $4}'
      df -h / | tail -1 | awk '{print "DISK_AVAIL", $4, "DISK_USEPCT", $5}'
      docker stats --no-stream --format 'DOCKER {{.Name}} CPU={{.CPUPerc}} MEM={{.MemUsage}}' ol2_grx930_v7 2>/dev/null || echo "DOCKER container_gone"
    } > "$HEART.tmp" && mv "$HEART.tmp" "$HEART"
  fi
  sleep 60
done
