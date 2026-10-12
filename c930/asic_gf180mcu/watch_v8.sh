#!/bin/bash
# v8 watcher - fresh Option B run (ol2_grx930_v8).
#   * heartbeat every 60 s            -> $HEART
#   * GRT gate: when a NEW-RUN globalrouting log shows the final congestion
#     report (GRT-0096), dump the report + computed max layer % + GRT-0115
#     flag to $ALERT once per step. Gate: total <= 90%, layers <= 100%.
#   * DRT fast-abort: append newly flushed Completing / iteration lines.
#     Contract: first "Completing 20%" must be < 50,000 violations.
# Exits on V8_DONE / V8_FAILED / *_FAILED status or after 44 h.
# NOTE: never pkill this script from an ssh command that contains its own
# name (the pattern matches the remote shell itself and kills the session).

B=/home/ubuntu/grx930_ol2/build
RUNS=/home/ubuntu/grx930_ol2/openlane2_rtl/runs
OLD=RUN_2026-09-24_04-18-20
ALERT=$B/v8_alert.txt
HEART=$B/v8_heartbeat.txt
EVAL=$B/v8_evaluated.txt
START=$(date -u +%s)
lastM=-1
echo "WATCH8_START $(date -u '+%F %T')" > "$ALERT"

while true; do
  now=$(date -u +%s)
  st=$(cat "$B/v8_status.txt" 2>/dev/null)
  case "$st" in
    V8_DONE*|V8_FAILED*|VOLARE_FAILED*|CD_FAILED*|RTL_MISMATCH*)
      echo "WATCH8_END $(date -u '+%F %T') reason=$st" >> "$ALERT"
      break;;
  esac
  if [ $((now - START)) -gt 158400 ]; then
    echo "WATCH8_END $(date -u '+%F %T') reason=44h_cap" >> "$ALERT"
    break
  fi

  # newest run dir, but ignore the old campaign run until OL2 creates the new one
  RUN=$(ls -dt $RUNS/RUN_* 2>/dev/null | head -1)
  case "$RUN" in *"$OLD"*) RUN="" ;; esac

  DL=""
  if [ -n "$RUN" ]; then
    # ---- GRT gate: evaluate each completed GRT step exactly once ----
    for d in "$RUN"/*-openroad-globalrouting; do
      [ -d "$d" ] || continue
      L="$d/openroad-globalrouting.log"
      [ -f "$L" ] || continue
      grep -aq 'GRT-0096' "$L" 2>/dev/null || continue
      grep -qxF "$d" "$EVAL" 2>/dev/null && continue
      MAXP=$(tr '\r' '\n' < "$L" | awk '
        /GRT-0096/{f=1}
        f { while (match($0,/[0-9]+\.[0-9][0-9]%/)) {
              p=substr($0,RSTART,RLENGTH-1)+0; if (p>mx) mx=p;
              $0=substr($0,RSTART+RLENGTH) } }
        END{print mx+0}')
      OV=0; grep -aq 'GRT-0115' "$L" && OV=1
      {
        echo "GRT_FINAL $(date -u '+%F %T') step=$(basename "$d")"
        tr '\r' '\n' < "$L" | awk '/GRT-0096/{f=1} f && /%/{print}' | head -25
        [ "$OV" = 1 ] && echo "HAS_GRT0115_OVERFLOW_WARNING"
        echo "GRT_VERDICT MAX_LAYER_PCT=$MAXP GRT0115=$OV GATE='total<=90 AND layers<=100 AND no-0115'"
        echo "GRT_FINAL_END"
      } >> "$ALERT"
      echo "$d" >> "$EVAL"
    done

    # ---- DRT: newly flushed progress lines ----
    DL=$(ls -t "$RUN"/*-openroad-detailedrouting/openroad-detailedrouting.log 2>/dev/null | head -1)
    if [ -n "$DL" ]; then
      m=$(tr '\r' '\n' < "$DL" | grep -ac 'Completing\|DRT-0195\|DRT-0199' 2>/dev/null); m=${m:-0}
      if [ "$lastM" -lt 0 ]; then
        lastM=$m
      elif [ "$m" -gt "$lastM" ]; then
        {
          echo "DRT_NEW $(date -u '+%F %T') total=$m"
          tr '\r' '\n' < "$DL" | grep -a 'Completing\|DRT-0195\|DRT-0199' | tail -n +$((lastM + 1))
          echo "DRT_NEW_END"
        } >> "$ALERT"
        lastM=$m
      fi
    fi
  fi

  {
    date -u '+HB %F %T'
    echo "STATUS ${st:-unset}"
    echo "RUN ${RUN:-pending}"
    [ -n "$RUN" ] && ls -dt "$RUN"/[0-9]*-*/ 2>/dev/null | head -3 | sed 's|/*$||; s|.*/||; s/^/STEP /'
    [ -n "$DL" ] && ls -la "$DL" 2>/dev/null | awk '{print "DRT_LOG_BYTES", $5}'
    free -m | sed -n '3p' | awk '{print "SWAP_MB", $3}'
    df -h / | tail -1 | awk '{print "DISK", $4, $5}'
    docker stats --no-stream --format 'DOCKER {{.Name}} CPU={{.CPUPerc}} MEM={{.MemUsage}}' ol2_grx930_v8 2>/dev/null \
      || echo "DOCKER v8_absent"
  } > "$HEART.tmp" 2>/dev/null && mv "$HEART.tmp" "$HEART"

  sleep 60
done
