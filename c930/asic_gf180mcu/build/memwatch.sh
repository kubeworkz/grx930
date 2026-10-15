#!/bin/bash
# memwatch.sh -- always-on memory tripwire for the flow box.
#
# WHY THIS EXISTS (all measured on this box, 2026-10-12)
#
#   * The one recorded memory failure is a single line: PLAN_B_netlist_rework.md
#     step 1, "OOM at 60% iter 0, swap exhausted, 6h55m". A 7-hour run died and
#     there is no record of how close it was before that, or what the peak was.
#   * Chasing it after the fact is why the box now runs FOUR swapfiles (28 GiB of
#     swap for 15.25 GiB of RAM).
#   * It is not a hypothetical: /proc/vmstat showed 32.0 M pages swapped in and
#     39.4 M pages swapped out in 22 h of uptime (121 GB in / 150 GB out), and
#     /proc/pressure/memory had accumulated 1903 s of memory stall. The runs here
#     are memory-bound and nobody could say for which run, or when.
#   * dmesg is NOT readable (kernel.dmesg_restrict=1, "Operation not permitted"),
#     so the kernel's OOM messages are unavailable to this user. That rules out
#     the obvious sensor and is why this reads cgroups and PSI instead.
#
# WHAT IT RECORDS, AND WHY ONE SAMPLE A MINUTE IS ENOUGH
#
#   The numbers that matter are kernel high-water marks, so they are exact
#   regardless of the sampling interval:
#
#     per container (cgroup v2)  memory.peak (peak RSS), memory.swap.peak,
#                                memory.max (the cap), memory.current,
#                                memory.swap.current, memory.events
#                                (oom / oom_kill / max / high)
#     host                       MemAvailable, SwapFree, pswpin/pswpout rate,
#                                /proc/pressure/memory some+full avg10
#
#   Sampling supplies the trajectory (what was happening in the minutes before a
#   failure); the kernel supplies the peaks. Timestamps line a sample up with the
#   flow's own step log, which is what turns "OOM at 60%" into "here is the curve".
#
#   On container exit it writes a per-run summary, so a run's memory story
#   outlives its container -- which the chain scripts delete with `docker rm -f`
#   moments after it stops.
#
# USAGE
#
#   bash build/memwatch.sh --tick            # one sample (the cron entry)
#   bash build/memwatch.sh --status          # human readable right now
#   bash build/memwatch.sh --headroom        # one line: headroom + live alert
#   bash build/memwatch.sh --summary NAME    # one run's memory story
#   bash build/memwatch.sh --all             # every run summary, newest last
#   bash build/memwatch.sh --preflight --need 8000 --tag core_chain --log LOG
#                                            # gate a launcher: 0 = go, 1 = refuse
#
# THE PRE-FLIGHT GATE, AND WHY IT IS THE POINT
#
#   Recording an OOM afterwards is not enough. PLAN_B's failure cost 6h55m before
#   anything noticed, so the launchers ask before they start -- but they ask
#   through gate.sh, which is where the disk gate and this one now live together
#   (six chains used to carry their own copy of both, and a copy is a threshold
#   waiting to drift):
#
#     . $B/gate.sh
#     gate 8000 core_chain || { say "ABORT_$GATE_REASON"; exit 1; }
#
#   gate.sh calls --headroom for the logged reading and --preflight for the
#   decision. This script stays the thing that measures, and it can still be run
#   by hand -- the two lines below are what that call site does:
#
#     bash $B/memwatch.sh --preflight --need 8000 --tag core_chain --log "$LOG" \
#       || { say "ABORT_MEM_LOW"; exit 1; }
#
#   It prints the headroom (MemAvailable + SwapFree), the current memory pressure
#   and the newest alert -- the last one as CONTEXT, never as a blocker, because a
#   stale OOM must not freeze the box forever -- appends one line to the caller's
#   log and to mem_audit/preflight.log, and refuses when the job cannot fit:
#     * MemAvailable below the critical floor, or
#     * SwapFree below the critical floor (this is the historical failure mode), or
#     * MemAvailable + SwapFree below the declared --need.
#   --need should be the job's measured peak plus margin (the fast DRT arms peak at
#   6.4-7.0 GB; the wafer.space synthesis was OOM-killed at a 4 GB cap and runs
#   under 8 GB). MEMWATCH_FORCE=1 proceeds anyway and records that it did, so a
#   conservative threshold can never wedge an unattended chain permanently.
#
# Install (no root needed -- user crontab):
#   ( crontab -l 2>/dev/null; echo "* * * * * bash /home/ubuntu/grx930_ol2/build/memwatch.sh --tick >/dev/null 2>&1" ) | crontab -
#
# Alerts go to mem_audit/alerts.log, with the newest also left in
# mem_audit/ALERT so anyone landing on the box can see it in one `ls`.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# MEMWATCH_ROOT moves the whole audit dir, so the live-alert path can be
# exercised in a scratch directory instead of planting a fake alert on the box.
ROOT=${MEMWATCH_ROOT:-/home/ubuntu/grx930_ol2/mem_audit}
SAMPLES=$ROOT/samples.log
ALERTS=$ROOT/alerts.log
RUNS=$ROOT/runs
STATE=$ROOT/state
MAXLOG=$((20 * 1024 * 1024))   # rotate; this tripwire must never cost the disk
MODE=${1:-}
CONTAINER=""
NEED_MB=0
GATE_TAG=""
GATE_LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tick|--status|--all) MODE=$1; shift ;;
    --preflight)           MODE=--preflight; shift ;;
    --summary)             MODE=--summary; shift; CONTAINER=${1:-}; [ $# -gt 0 ] && shift ;;
    --need)                NEED_MB=${2:-0}; shift; [ $# -gt 0 ] && shift ;;
    --tag)                 GATE_TAG=${2:-}; shift; [ $# -gt 0 ] && shift ;;
    --log)                 GATE_LOG=${2:-}; shift; [ $# -gt 0 ] && shift ;;
    *)                     shift ;;
  esac
done

# ---- tripwire thresholds. Tune here; W = warn, C = critical. ----
W_MEMAVAIL_MB=1024 ; C_MEMAVAIL_MB=512
W_SWAPFREE_MB=2048 ; C_SWAPFREE_MB=512
W_PSI=20           ; C_PSI=50
W_CAP_PCT=90                       # container at/over this % of its cap
W_SWAPOUT_MB_MIN=100               # sustained swap-out rate

# Dense sampling. One host sample a minute is enough for the trajectory, but a
# container's cgroup is DESTROYED the moment its last process exits (measured:
# /sys/fs/cgroup/system.slice/docker-<id>.scope is gone as soon as the container
# is not running), taking memory.peak and memory.events with it. So while a run is
# live, a tick keeps sampling for ~DENSE_N * DENSE seconds instead of returning
# after one pass, which puts the kernel's high-water mark inside the window even
# for a run that dies early. A death inside ~5 s is still only recoverable from
# docker's own OOMKilled flag -- which is why summarize() alerts on that too.
DENSE=5
DENSE_N=11

mkdir -p "$ROOT" "$RUNS" "$STATE" 2>/dev/null || exit 0
ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
mb() { awk -v v="${1:-0}" 'BEGIN{printf "%.0f", v/1024}'; }      # /proc/meminfo is in kB
mb_b() { awk -v v="${1:-0}" 'BEGIN{printf "%.0f", v/1048576}'; }  # cgroup v2 is in bytes

alert() {  # alert <key> <level 1|2> <message>   -- logs only when escalating
  # NB: the path must be built on its own line. Inside a single `local` the words
  # are all expanded before any assignment, so `local key=$1 f="...$key"` reads an
  # unset key and dies under set -u (that is how this failed the first time).
  local key=$1 lvl=$2 msg=$3
  local f="$STATE/lvl.$key" last=0
  [ -f "$f" ] && last=$(cat "$f" 2>/dev/null || echo 0)
  case "${last:-0}" in ''|*[!0-9]*) last=0;; esac
  [ "$last" -ge "$lvl" ] && return
  echo "$lvl" > "$f"
  local w; [ "$lvl" = 2 ] && w=CRIT || w=WARN
  printf '%s LEVEL=%s %s\n' "$(ts)" "$w" "$msg" >> "$ALERTS"
  printf '%s LEVEL=%s %s\n' "$(ts)" "$w" "$msg" > "$ROOT/ALERT"
}
normal() {  # normal <key> -- reset so a recurrence is logged again
  local f="$STATE/lvl.$1"
  if [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null || echo 0)" != 0 ]; then
    echo 0 > "$f"; printf '%s RECOVERED %s\n' "$(ts)" "$1" >> "$ALERTS"
    [ -f "$ROOT/ALERT" ] && grep -q "$1" "$ROOT/ALERT" 2>/dev/null && rm -f "$ROOT/ALERT"
  fi
}
peak() {  # peak <file> <key> <value> -- keep the max in a k=v file
  local f=$1 k=$2 v=$3 cur=0
  [ -f "$f" ] && cur=$(awk -F= -v k="$k" '$1==k{print $2}' "$f" 2>/dev/null | tail -1)
  case "${cur:-0}" in ''|*[!0-9.-]*) cur=0;; esac
  awk -v c="$cur" -v v="$v" 'BEGIN{exit !(v>c)}' && {
    grep -v "^$k=" "$f" 2>/dev/null > "$f.tmp" || true
    echo "$k=$v" >> "$f.tmp"; mv -f "$f.tmp" "$f"
  }
}
peek() { awk -F= -v k="$2" '$1==k{print $2}' "$1" 2>/dev/null | tail -1; }
setkv() {  # setkv <file> <key> <value> -- last write wins, no growth
  local f=$1 k=$2 v=$3
  grep -v "^$k=" "$f" 2>/dev/null > "$f.tmp" || true
  echo "$k=$v" >> "$f.tmp"; mv -f "$f.tmp" "$f"
}
isnum() { case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
show() { [ -n "${1:-}" ] && mb_b "$1" || echo unknown; }   # peaks are bytes
cgfile() { cat "$1/$2" 2>/dev/null; }
cgevent() { awk -v k="$1" '$1==k{print $2}' <<<"$(cat "$2/memory.events" 2>/dev/null)"; }

cgdir() {  # cgdir <name> <id> -- the container's cgroup v2 dir, or nothing
  local pid path d
  pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null)
  if [ -n "${pid:-}" ] && [ "$pid" != 0 ] && [ -r "/proc/$pid/cgroup" ]; then
    path=$(awk -F: '$1=="0"{print $3}' "/proc/$pid/cgroup" 2>/dev/null | head -1)
    [ -n "$path" ] && [ -r "/sys/fs/cgroup$path/memory.current" ] && { printf '/sys/fs/cgroup%s' "$path"; return; }
  fi
  for d in "/sys/fs/cgroup/system.slice/docker-$2.scope" "/sys/fs/cgroup/docker/$2" \
           "/sys/fs/cgroup/system.slice/docker-$1.scope"; do
    [ -d "$d" ] && { printf '%s' "$d"; return; }
  done
}
runenv() {  # the run tag a launcher passed, for mapping container -> run
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | awk -F= '/^(WS_TAG|FAST_TAG|SWEEP_ADJ)=/{printf "%s=%s ", $1, $2}'
}

rotate() {
  [ -f "$SAMPLES" ] && [ "$(stat -c %s "$SAMPLES" 2>/dev/null || echo 0)" -gt "$MAXLOG" ] \
    && mv -f "$SAMPLES" "$SAMPLES.1"
}

host_sample() {
  local mt ma st sf pi po ps pf pst pft load l1
  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo);    ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo);  sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  pi=$(awk '$1=="pswpin"{print $2}' /proc/vmstat);    po=$(awk '$1=="pswpout"{print $2}' /proc/vmstat)
  ps=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
  pf=$(awk '/^full/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
  pst=$(awk '/^some/{print $5}' /proc/pressure/memory 2>/dev/null | sed 's/total=//')
  pft=$(awk '/^full/{print $5}' /proc/pressure/memory 2>/dev/null | sed 's/total=//')
  load=$(cut -d' ' -f1 /proc/loadavg)
  printf 'HOST %s memtotal_mb=%s memavail_mb=%s swaptotal_mb=%s swapfree_mb=%s pswpin=%s pswpout=%s psi_some_avg10=%s psi_full_avg10=%s psi_some_total_us=%s psi_full_total_us=%s load1=%s\n' \
    "$(ts)" "$(mb "$mt")" "$(mb "$ma")" "$(mb "$st")" "$(mb "$sf")" "$pi" "$po" \
    "${ps:--}" "${pf:--}" "${pst:--}" "${pft:--}" "$load" >> "$SAMPLES"

  # swap-out rate, pages -> MB/min
  local now prev po_prev t_prev rate
  now=$(date -u +%s)
  prev=0; po_prev=0; t_prev=0
  if [ -f "$STATE/host.rate" ]; then
    prev=$(peek "$STATE/host.rate" po); t_prev=$(peek "$STATE/host.rate" t)
  fi
  case "${prev:-0}" in ''|*[!0-9]*) prev=0;; esac
  case "${t_prev:-0}" in ''|*[!0-9]*) t_prev=0;; esac
  if [ "$t_prev" -gt 0 ] && [ "$now" -gt "$t_prev" ]; then
    rate=$(awk -v a="$po" -v b="$prev" -v dt="$((now - t_prev))" 'BEGIN{printf "%.1f", (a-b)*4/1024*60/dt}')
    if awk -v r="$rate" -v w="$W_SWAPOUT_MB_MIN" 'BEGIN{exit !(r>w)}'; then
      alert swapout 1 "host swapping out ${rate} MB/min (MemAvailable $(mb "$ma") MB, SwapFree $(mb "$sf") MB)"
    else
      normal swapout
    fi
  fi
  printf 't=%s\npo=%s\n' "$now" "$po" > "$STATE/host.rate"

  # capacity tripwires
  if [ "$(mb "$ma")" -lt "$C_MEMAVAIL_MB" ]; then alert memavail 2 "MemAvailable $(mb "$ma") MB (< ${C_MEMAVAIL_MB})"
  elif [ "$(mb "$ma")" -lt "$W_MEMAVAIL_MB" ]; then alert memavail 1 "MemAvailable $(mb "$ma") MB (< ${W_MEMAVAIL_MB})"
  else normal memavail; fi
  if [ "$(mb "$sf")" -lt "$C_SWAPFREE_MB" ]; then alert swapfree 2 "SwapFree $(mb "$sf") MB of $(mb "$st") MB -- swap exhaustion imminent"
  elif [ "$(mb "$sf")" -lt "$W_SWAPFREE_MB" ]; then alert swapfree 1 "SwapFree $(mb "$sf") MB of $(mb "$st") MB"
  else normal swapfree; fi
  if [ "${ps:--}" != "-" ]; then
    if awk -v p="$ps" -v c="$C_PSI" 'BEGIN{exit !(p>c)}'; then alert psi 2 "memory pressure some avg10=${ps}% (> ${C_PSI}) -- runs are stalling on memory"
    elif awk -v p="$ps" -v w="$W_PSI" 'BEGIN{exit !(p>w)}'; then alert psi 1 "memory pressure some avg10=${ps}% (> ${W_PSI})"
    else normal psi; fi
  fi
}

container_sample() {  # container_sample <name>
  local name=$1 id dir status etag
  id=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null) || return
  [ -n "${id:-}" ] || return
  status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
  dir=$(cgdir "$name" "$id")
  local pf="$RUNS/$name.peaks"
  [ -f "$pf" ] || { printf 'name=%s\nid=%s\n' "$name" "$id" > "$pf"; }

  if [ "$status" = running ] && [ -n "$dir" ] && [ -r "$dir/memory.current" ]; then
    local cur max swc swp ev_oom ev_kill ev_max ev_high pct
    cur=$(cgfile "$dir" memory.current);       max=$(cgfile "$dir" memory.max)
    swc=$(cgfile "$dir" memory.swap.current);  swp=$(cgfile "$dir" memory.swap.peak)
    ev_oom=$(cgevent oom "$dir"); ev_kill=$(cgevent oom_kill "$dir")
    ev_max=$(cgevent max "$dir"); ev_high=$(cgevent high "$dir")
    local rp; rp=$(cgfile "$dir" memory.peak)
    isnum "$rp" && peak "$pf" peak_rss_bytes "$rp"
    isnum "${swp:-}" && peak "$pf" peak_swap_bytes "$swp"
    isnum "${swc:-}" && peak "$pf" peak_swap_bytes "$swc"
    isnum "${max:-}" && [ "$max" != max ] && setkv "$pf" cap_bytes "$max"
    printf 'CONTAINER %s name=%s status=running rss_mb=%s peak_rss_mb=%s cap_mb=%s swap_mb=%s peak_swap_mb=%s oom=%s oom_kill=%s max_events=%s high_events=%s\n' \
      "$(ts)" "$name" "$(mb_b "${cur:-0}")" "$(mb_b "$(peek "$pf" peak_rss_bytes)")" \
      "$([ -n "${max:-}" ] && [ "${max:-}" != max ] && mb_b "$max" || echo none)" \
      "$(mb_b "${swc:-0}")" "$(mb_b "${swp:-${swc:-0}}")" "${ev_oom:-0}" "${ev_kill:-0}" "${ev_max:-0}" "${ev_high:-0}" >> "$SAMPLES"

    # newly seen OOM kill -> the alert this whole script exists for
    local seen="$STATE/oomkill.$name" last=0
    [ -f "$seen" ] && last=$(cat "$seen" 2>/dev/null || echo 0)
    case "${last:-0}" in ''|*[!0-9]*) last=0;; esac
    if [ "${ev_kill:-0}" -gt "$last" ]; then
      etag=$(runenv "$name")
      alert "oomkill.$name" 2 "OOM KILL in container $name (run=${etag:-none}) after ${ev_kill} oom events; peak RSS $(mb_b "$(peek "$pf" peak_rss_bytes)") MB, cap $([ -n "${max:-}" ] && [ "$max" != max ] && mb_b "$max" || echo none) MB, peak swap $(mb_b "$(peek "$pf" peak_swap_bytes)") MB"
    fi
    echo "${ev_kill:-0}" > "$seen"

    # approaching the cgroup cap
    if [ -n "${max:-}" ] && [ "$max" != max ] && [ "$max" -gt 0 ]; then
      pct=$(awk -v c="${cur:-0}" -v m="$max" 'BEGIN{printf "%.0f", c*100/m}')
      if [ "$pct" -ge "$W_CAP_PCT" ]; then
        alert "cap.$name" 1 "container $name at ${pct}% of its $(mb_b "$max") MB cap (peak $(mb_b "$(peek "$pf" peak_rss_bytes)") MB)"
      else normal "cap.$name"; fi
    fi
  else
    printf 'CONTAINER %s name=%s status=%s\n' "$(ts)" "$name" "${status:-gone}" >> "$SAMPLES"
  fi

  # write the run's memory story once the container is done
  if [ "$status" != running ] && [ ! -f "$STATE/done.$name" ]; then
    summarize "$name" "$pf" "$status"
    echo done > "$STATE/done.$name"
  fi
}

summarize() {  # summarize <name> <peaks-file> <status>
  local name=$1 pf=$2 status=$3 id exit_code oomkilled started finished etag img
  id=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null)
  exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name" 2>/dev/null)
  oomkilled=$(docker inspect -f '{{.State.OOMKilled}}' "$name" 2>/dev/null)
  started=$(docker inspect -f '{{.State.StartedAt}}' "$name" 2>/dev/null)
  finished=$(docker inspect -f '{{.State.FinishedAt}}' "$name" 2>/dev/null)
  etag=$(runenv "$name"); img=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null)
  local cap rss swp kill
  cap=$(peek "$pf" cap_bytes); rss=$(peek "$pf" peak_rss_bytes); swp=$(peek "$pf" peak_swap_bytes)
  kill=$(cat "$STATE/oomkill.$name" 2>/dev/null || echo 0)
  case "${cap:-}" in ''|*[!0-9]*) cap=0;; esac
  case "${kill:-}" in ''|*[!0-9]*) kill=0;; esac
  # unmeasured is NOT the same as zero: a container that died between samples
  # leaves no cgroup behind, and reporting that as 0 MB would be a lie.
  isnum "${rss:-}" || rss=""
  isnum "${swp:-}" || swp=""
  local verdict=clean
  if [ "${oomkilled:-false}" = true ] || [ "$kill" -gt 0 ]; then verdict=OOM_KILLED
  elif [ "$cap" != 0 ] && [ -n "$rss" ] && [ "$rss" -ge "$cap" ]; then verdict=HIT_CAP
  elif [ -n "$swp" ] && [ "$swp" -gt 0 ]; then verdict=SWAPPED
  elif [ -z "$rss" ]; then verdict=UNMEASURED
  fi
  {
    printf '# run memory summary: %s\n' "$name"
    printf 'image=%s run=%s\n' "${img:-?}" "${etag:-none}"
    printf 'started=%s finished=%s\n' "${started:-?}" "${finished:-?}"
    printf 'peak_rss_mb=%s\npeak_swap_mb=%s\ncap_mb=%s\n' "$(show "$rss")" "$(show "$swp")" \
      "$([ "$cap" != 0 ] && mb_b "$cap" || echo none)"
    printf 'cgroup_oom_kills=%s\ndocker_oomkilled=%s\nexit_code=%s\nverdict=%s\n' \
      "$kill" "${oomkilled:-?}" "${exit_code:-?}" "$verdict"
    if [ "$verdict" = UNMEASURED ]; then
      printf 'note=the container started and stopped between samples, so the cgroup -- and with it the kernel high-water marks -- was already gone.\n'
    fi
    if [ -z "${exit_code:-}" ]; then
      printf 'note=the container had already been removed (docker rm -f), so only the peaks sampled while it ran survive: nothing here is inferred, and "?" means unrecorded rather than zero.\n'
    fi
  } > "$RUNS/$name.summary" 2>/dev/null
  printf '%s %-10s run=%-12s peak_rss=%-8s peak_swap=%-8s cap=%-7s oom_kills=%s exit=%s verdict=%s\n' \
    "$(ts)" "$name" "${etag:-none}" "$(show "$rss")" "$(show "$swp")" \
    "$([ "$cap" != 0 ] && mb_b "$cap" || echo none)" "$kill" "${exit_code:-?}" "$verdict" >> "$RUNS/summary.log"
  # the post-mortem alert: fires even when no sample ever landed while it ran
  if [ "$verdict" = OOM_KILLED ]; then
    alert "oomkill.$name" 2 "OOM KILLED container $name (run=${etag:-none}) exit=${exit_code:-?} docker_oomkilled=${oomkilled:-?} cgroup_oom_kills=$kill peak_rss=$(show "$rss") MB cap=$([ "$cap" != 0 ] && mb_b "$cap" || echo none) MB"
  fi
}

summarize_removed() {  # containers that are gone entirely: summarize from peaks
  local f n
  for f in "$RUNS"/*.peaks; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .peaks)
    [ -f "$STATE/done.$n" ] && continue
    docker inspect "$n" >/dev/null 2>&1 || { summarize "$n" "$f" gone; echo done > "$STATE/done.$n"; }
  done
}

tick() {
  # one tick at a time (cron can fire while a dense tick is still running)
  # A global, not a local: the EXIT trap fires after tick() has returned, so a
  # local would already be out of scope (that is how the lock leaked).
  LOCKDIR=$STATE/lock.d
  if [ -d "$LOCKDIR" ]; then
    [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +3 2>/dev/null)" ] && rm -rf "$LOCKDIR" || exit 0
  fi
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
  trap 'rm -rf "$LOCKDIR"' EXIT

  local c i=0 running=0
  rotate
  host_sample

  running=$(docker ps -q 2>/dev/null | wc -l)
  if [ "${running:-0}" -gt 0 ]; then
    while [ "$i" -lt "$DENSE_N" ]; do
      for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do container_sample "$c"; done
      i=$((i + 1))
      [ "$i" -lt "$DENSE_N" ] && sleep "$DENSE"
    done
  fi
  # anything not running (finished, or never started) gets its one pass + summary
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] && continue
    container_sample "$c"
  done
  summarize_removed
}

status() {
  echo "=== host (now) ==="
  awk '/^MemTotal:|^MemAvailable:|^SwapTotal:|^SwapFree:/{printf "  %-16s %s MB\n", $1, int($2/1024)}' /proc/meminfo
  [ -r /proc/pressure/memory ] && sed 's/^/  PSI /' /proc/pressure/memory
  echo "  swap io since boot: in $(awk '$1=="pswpin"{printf "%.1f", $2*4/1048576}' /proc/vmstat) GB, out $(awk '$1=="pswpout"{printf "%.1f", $2*4/1048576}' /proc/vmstat) GB"
  echo
  echo "=== containers ==="
  docker ps -a --format '  {{.Names}} {{.Status}}' 2>/dev/null || echo "  none"
  echo
  echo "=== peaks recorded (mem_audit/runs) ==="
  if [ -f "$RUNS/summary.log" ]; then tail -8 "$RUNS/summary.log" | sed 's/^/  /'
  else for f in "$RUNS"/*.peaks; do [ -f "$f" ] || continue
    printf '  %-12s peak_rss=%s MB peak_swap=%s MB cap=%s MB\n' "$(basename "$f" .peaks)" \
      "$(mb_b "$(peek "$f" peak_rss_bytes)")" "$(mb_b "$(peek "$f" peak_swap_bytes)")" \
      "$(mb_b "$(peek "$f" cap_bytes)")"; done; fi
  echo
  echo "=== newest alerts ==="
  [ -f "$ALERTS" ] && tail -6 "$ALERTS" | sed 's/^/  /' || echo "  none"
  [ -f "$ROOT/ALERT" ] && { echo; echo "=== LIVE ALERT ==="; sed 's/^/  /' "$ROOT/ALERT"; } || true
}

# The launchers' one-liner: what the box looks like right now, for a chain log.
# gate.sh's mem_gate() is the call site -- it says this, then asks preflight()
# below -- so every chain records the same shape and the line greps the same way
# in all of them. The alert is reported as CONTEXT, never as a reason to refuse:
# a stale OOM must not freeze the box, and the gate below is what decides.
headroom() {
  local ma sf psi alert
  ma=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  sf=$(awk '/^SwapFree:/{print int($2/1024)}' /proc/meminfo)
  psi=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
  alert=none
  if [ -s "$ROOT/ALERT" ]; then alert=$(tail -1 "$ROOT/ALERT" | cut -d' ' -f2-); fi
  printf 'memavail_mb=%s swapfree_mb=%s headroom_mb=%s psi_some=%s live_alert=%s\n' \
    "$ma" "$sf" "$((ma + sf))" "${psi:--}" "$alert"
}

preflight() {  # preflight <need_mb> <tag> <log> -- 0 = go, 1 = refuse
  local need=${1:-0} tag=${2:-} log=${3:-}
  isnum "$need" || need=0
  local ma sf head psi why="" ok=0
  ma=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  sf=$(awk '/^SwapFree:/{print int($2/1024)}' /proc/meminfo)
  psi=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | sed 's/avg10=//')
  head=$((ma + sf))
  printf 'MEM_PREFLIGHT headroom_mb=%s (memavail_mb=%s + swapfree_mb=%s) psi_some_avg10=%s need_mb=%s\n' \
    "$head" "$ma" "$sf" "${psi:--}" "$need"
  if [ -f "$ALERTS" ]; then printf 'MEM_LAST_ALERT %s\n' "$(tail -1 "$ALERTS")"; fi
  if [ -f "$ROOT/ALERT" ]; then printf 'MEM_ALERT_MARKER %s\n' "$(cat "$ROOT/ALERT")"; fi
  [ "$ma" -lt "$C_MEMAVAIL_MB" ] && { ok=1; why="MemAvailable ${ma} MB < ${C_MEMAVAIL_MB} MB"; }
  [ "$sf" -lt "$C_SWAPFREE_MB" ] && { ok=1; why="$why SwapFree ${sf} MB < ${C_SWAPFREE_MB} MB"; }
  [ "$head" -lt "$need" ] && { ok=1; why="$why headroom ${head} MB < need ${need} MB"; }
  local verdict=OK; [ "$ok" = 1 ] && verdict=REFUSE
  why=${why# }   # the conditions accumulate with a leading separator
  printf '%s preflight tag=%s need_mb=%s headroom_mb=%s memavail_mb=%s swapfree_mb=%s psi_some=%s verdict=%s %s\n' \
    "$(ts)" "${tag:-none}" "$need" "$head" "$ma" "$sf" "${psi:--}" "$verdict" "$why" \
    >> "$ROOT/preflight.log" 2>/dev/null
  [ -n "$log" ] && printf '%s MEM_PREFLIGHT tag=%s headroom_mb=%s need_mb=%s verdict=%s %s\n' \
    "$(ts)" "${tag:-none}" "$head" "$need" "$verdict" "$why" >> "$log" 2>/dev/null
  if [ "$ok" = 0 ]; then printf 'MEM_PREFLIGHT OK -- starting\n'; return 0; fi
  if [ "${MEMWATCH_FORCE:-0}" = 1 ]; then
    printf 'MEM_PREFLIGHT REFUSE: %s\nMEM_PREFLIGHT FORCED past the refusal because MEMWATCH_FORCE=1\n' "$why"
    printf '%s preflight FORCED tag=%s need_mb=%s headroom_mb=%s %s\n' "$(ts)" "${tag:-none}" "$need" "$head" "$why" \
      >> "$ROOT/preflight.log" 2>/dev/null
    return 0
  fi
  printf 'MEM_PREFLIGHT REFUSE: %s\nMEM_PREFLIGHT the box cannot carry this job; see: bash build/memwatch.sh --status\n' "$why"
  return 1
}

case "$MODE" in
  --tick)      tick ;;
  --preflight) preflight "$NEED_MB" "$GATE_TAG" "$GATE_LOG" ;;
  --status)    status ;;
  --headroom)  headroom ;;
  --summary)   [ -n "$CONTAINER" ] && cat "$RUNS/$CONTAINER.summary" 2>/dev/null || \
                 { echo "usage: memwatch.sh --summary <container>"; ls "$RUNS" 2>/dev/null; } ;;
  --all)       [ -f "$RUNS/summary.log" ] && cat "$RUNS/summary.log" || echo "no runs recorded yet" ;;
  *)         sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
