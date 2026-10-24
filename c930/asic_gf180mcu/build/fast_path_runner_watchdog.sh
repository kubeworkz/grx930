#!/usr/bin/env bash
# fast_path_runner_watchdog.sh -- keep the push fast path's runner up, and say so.
#
# WHAT THIS WATCHES
#
#   The `gates-push` job in .github/workflows/build-gf180mcu.yml runs
#   c930/asic_gf180mcu/build/chip_gates.sh on the self-hosted runner
#   `grx930-wsl-runner` (labels self-hosted, Linux, X64, grx930-gates) inside the
#   Ubuntu WSL distro on this machine. That job is the only reason a push gets a
#   chip-gate verdict in about a minute instead of whenever the hosted queue moves.
#
#   It is also one machine. It goes away on a reboot, on `wsl --shutdown`, if the
#   listener is killed, or if the runner is up but disconnected -- and when it
#   does, nothing says so: the hosted `gates` job still covers every push, hours
#   later, so the push is verified and the delay looks like "CI is slow again".
#   That silence is what this script exists to break. Per run it does three
#   things: find out whether the fast path is up, put it back if it is not, and
#   tell the person at the keyboard when it had to.
#
# WHAT ONE RUN DOES
#
#   1. The local check: is the listener process alive inside the distro? Cheap,
#      and it needs no network.
#   2. Every GH_CHECK_EVERY-th cycle of the loop (default 12), and always when the
#      listener is gone or the run is manual, the GitHub check:
#      `gh api .../actions/runners`. GitHub's view is the one the workflow
#      schedules against, so it is the one that counts. A listener can be alive and
#      disconnected, which only this check sees.
#   3. If it is down: start it, wait up to RESTORE_WAIT seconds, and ask GitHub
#      again. Being back is announced, not assumed; not being back is announced
#      louder, written to an ALERT file, and exits 1.
#
#   And never two of them. One runner directory is one agent id, so it gets one
#   listener session; two are not extra capacity. They share _work and _diag, so
#   they write the same job's page log and both accept the same job. Measured on
#   2026-10-23/24 -- two run.sh sessions started 15 hours apart, `Set up job`
#   failing with `The file .../_diag/pages/...._1.log already exists`, and the
#   artifact upload coming back `403 Forbidden: job is completed`. So before a
#   start this script stops the sessions already in the directory, it holds a
#   start lock so two watchdogs cannot start at once, and it counts listeners
#   afterwards; a start that somehow produces two stops both and starts one. A
#   listener that is alive but not online is replaced, not joined.
#
#   The announcement is a Windows balloon notification, because the failure mode
#   being fixed is silence, and a log line nobody opens is silence.
#
# SURVIVING A REBOOT
#
#   A logon item in the user's Startup folder runs this with --loop. That is
#   deliberate rather than a systemd unit: a unit needs root, and this machine
#   already shows what a unit buys -- the other runner is one, and it starts with
#   the distro, but the distro itself only starts when something asks it to. A
#   logon trigger is the part that actually matters here, and the loop is what
#   covers everything a logon trigger never sees: a killed listener, a stopped
#   runner, a distro that went down mid-session.
#
#   Install (no administrator rights needed):
#
#     bash c930/asic_gf180mcu/build/fast_path_runner_watchdog.sh --install
#
#   which writes grx930-fast-path-watchdog.vbs into the Startup folder. Delete
#   that file to uninstall; the runner keeps running either way.
#
# USAGE
#
#   bash fast_path_runner_watchdog.sh              # one check, put it back if down
#   bash fast_path_runner_watchdog.sh --loop       # check every $INTERVAL seconds
#   bash fast_path_runner_watchdog.sh --status     # report, change nothing
#   bash fast_path_runner_watchdog.sh --install    # put the logon item in place
#
#   Everything below can be overridden from the environment: REPO, RUNNER_NAME,
#   DISTRO, WSL_USER, RUNNER_DIR, INTERVAL, GH_CHECK_EVERY, RESTORE_WAIT, STATE,
#   NOTIFY (0 to run silent).
#
# EXIT STATUS
#
#   0 the fast path is up -- possibly because this run started it
#   1 the fast path is down and this run could not bring it back
#   2 a usage or configuration error, because a run that could not check must not
#     read as a run that checked and found nothing
set -u

REPO=${REPO:-kubeworkz/grx930}
RUNNER_NAME=${RUNNER_NAME:-grx930-wsl-runner}
DISTRO=${DISTRO:-Ubuntu}
WSL_USER=${WSL_USER:-kubew}
RUNNER_DIR=${RUNNER_DIR:-/home/kubew/actions-runner-grx930}
INTERVAL=${INTERVAL:-120}                 # --loop period, seconds
GH_CHECK_EVERY=${GH_CHECK_EVERY:-12}      # ask GitHub every Nth cycle even if alive
RESTORE_WAIT=${RESTORE_WAIT:-90}          # seconds to wait for a restarted runner
STATE=${STATE:-$HOME/.grx930-fast-path-watchdog}
LOG=${LOG:-$STATE/watchdog.log}
ALERT=${ALERT:-$STATE/ALERT}
NOTIFY=${NOTIFY:-1}

usage() {
  cat >&2 <<'EOF'
usage: fast_path_runner_watchdog.sh [--loop | --status | --install]

  (no flag)   one check; start the runner if it is down; notify on a change
  --loop      the same every INTERVAL seconds; what the logon item runs
  --status    say what it sees and change nothing
  --install   write the Startup-folder logon item that runs --loop
EOF
}

# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

mkdir -p "$STATE" 2>/dev/null || {
  echo "watchdog: cannot create $STATE -- nothing here can be recorded" >&2
  exit 2
}

log() {   # log MESSAGE...
  [ "${MODE:-}" = loop ] || printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*"
  printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true
}

# The log is read by people, and an unbounded one stops being read.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

notify() {  # notify LEVEL TITLE BODY
  local level=$1 title=$2 body=$3
  [ "$NOTIFY" = 1 ] || return 0
  command -v powershell >/dev/null 2>&1 || return 0
  # Through the environment and stdin, so that nothing in a message can be read
  # as PowerShell: a title with a quote in it must not become a syntax error.
  WATCHDOG_LEVEL="$level" WATCHDOG_TITLE="$title" WATCHDOG_BODY="$body" \
    powershell -NoProfile -Command - >/dev/null 2>&1 <<'PS'
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = if ($env:WATCHDOG_LEVEL -eq 'info') { [System.Drawing.SystemIcons]::Information } else { [System.Drawing.SystemIcons]::Warning }
$n.Visible = $true
$n.ShowBalloonTip(12000, $env:WATCHDOG_TITLE, $env:WATCHDOG_BODY, [System.Windows.Forms.ToolTipIcon]::Warning)
Start-Sleep -Seconds 3
$n.Dispose()
PS
}

# Git Bash rewrites arguments that look like absolute paths, and every wsl.exe
# call below passes one: /home/kubew/... would arrive in the distro as
# C:/Program Files/Git/home/kubew/... The same class of surprise as the GIT_DIR
# one that hit build/script_exec_bit.sh, neutralised the same way -- at the
# boundary, once, rather than per call as each one is remembered.
export MSYS_NO_PATHCONV=1

in_distro() {  # in_distro SHELL_COMMAND
  wsl.exe -d "$DISTRO" -u "$WSL_USER" -e bash -c "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# how many listeners are in the runner directory
# ---------------------------------------------------------------------------
#
# The question this script asks first is not "is a listener alive" but "how many
# are there". A second one is invisible from GitHub -- both register as the same
# agent id and both read `online` -- and it breaks jobs in ways that look like
# something else entirely, so it is counted rather than assumed away.
#
# A session is run.sh -> run-helper.sh -> bin/Runner.Listener, all in one process
# group (run.sh is started with setsid, so its pid is the group). Stopping only
# the listener is not enough: run.sh loops on run-helper.sh, so the directory can
# grow a new listener a second later, beside whatever is started next.

listener_table() {  # "<pgid> <pid> <ppid>" per listener; "?" if the distro did not answer
  # The [R] is not decoration. `ps` lists the command lines of the very processes
  # running this command -- this shell, the grep, the awk -- and this shell's
  # command line contains the pattern it is about to grep for. A plain
  # `Runner.Listener` therefore matches the shell that is looking for it, and a
  # dead runner reads as alive: measured on 2026-10-15, when the watchdog missed
  # both runner processes being killed, restarted nothing, and GitHub was right
  # while this script was wrong. A bracket expression stops the pattern matching
  # its own text: [R]unner matches the literal `Runner` in the runner's command
  # line and not the `[R]unner` written here. `$RUNNER_DIR` is left unexpanded in
  # the command that reaches the distro for the same reason -- one more string in
  # that shell's command line that is not the path being looked for.
  #
  # The sentinel is the other half. Empty output has two meanings -- "no listener"
  # and "the distro said nothing at all" -- and reading the second as the first is
  # how a second listener gets started beside a live one. wsl.exe calls to this
  # machine failed with Wsl/Service/0x8007274c twice on 2026-10-15 while
  # everything else was fine, so a run that gets no answer is reported as that.
  local out
  out=$(in_distro "ps -eo pgid=,pid=,ppid=,args= | grep -E '$RUNNER_DIR/bin/[R]unner.Listener' | awk '{print \$1, \$2, \$3}'; echo __TABLE_END__") \
    || { printf '?\n'; return 1; }
  case "$out" in
    *__TABLE_END__) : ;;
    *)              printf '?\n'; return 1 ;;
  esac
  printf '%s\n' "$out" | sed -e '/^__TABLE_END__$/d' -e 's/[[:space:]][[:space:]]*/ /g' \
                            -e 's/^ //' -e 's/ $//' -e '/^$/d'
}

table_state() {  # alive | dead | unknown, from a listener_table
  case "$1" in '?') echo unknown ;; '') echo dead ;; *) echo alive ;; esac
}

table_count() {  # 0, 1, 2, ... or "?" -- from a listener_table
  case "$1" in
    '?') echo '?' ;;
    '')  echo 0 ;;
    *)   printf '%s\n' "$1" | wc -l | tr -d ' ' ;;
  esac
}

table_pids() {  # the listener pids from a listener_table, on one line
  [ "$1" = '?' ] && { printf '?\n'; return; }
  printf '%s\n' "$1" | awk 'NF {printf "%s ", $2}' | sed -e 's/ $//' -e '/^$/d'
}

signal_tree() {  # signal_tree SIGNAL -- signal every listener and up to two ancestors
  # The ancestors are the listener's own parent chain, not a process group: this
  # machine also runs a second, unrelated runner (/home/kubew/actions-runner, a
  # service unit), and nothing here may use a `kill -TERM -PGID` that guessed at
  # the wrong group. Three hops is Run.sh -> run-helper.sh -> Runner.Listener; the
  # walk stops at pid 1, or as soon as a parent is already gone.
  in_distro "
    ps -eo pid=,ppid=,args= | grep -E '$RUNNER_DIR/bin/[R]unner.Listener' | awk '{print \$1}' |
    while read -r l; do
      p=\$l
      for _ in 1 2 3; do
        [ \"\${p:-0}\" -gt 1 ] || break
        kill -$1 \"\$p\" 2>/dev/null
        p=\$(ps -o ppid= -p \"\$p\" 2>/dev/null | tr -d ' ')
        [ -n \"\${p:-}\" ] || break
      done
    done
    echo __TABLE_END__
  " >/dev/null 2>&1
}

stop_listeners() {  # stop_listeners REASON -- 0 once the directory holds no listener
  local reason=$1 t i
  t=$(listener_table) || { log "cannot read the listener table -- not stopping anything blind"; return 1; }
  [ -z "$t" ] && return 0
  log "stopping $(table_count "$t") listener session(s) in $RUNNER_DIR ($reason): $(printf '%s' "$t" | tr '\n' ';')"
  signal_tree TERM
  for i in $(seq 1 20); do
    sleep 1
    t=$(listener_table) || return 1
    [ -z "$t" ] && return 0
  done
  log "still there after 20s of TERM -- sending KILL: $(printf '%s' "$t" | tr '\n' ';')"
  signal_tree KILL
  for i in $(seq 1 10); do
    sleep 1
    t=$(listener_table) || return 1
    [ -z "$t" ] && return 0
  done
  log "FAIL: a listener in $RUNNER_DIR survived TERM and KILL -- refusing to start a second one beside it"
  return 1
}

github_status() {  # online | offline | absent | unknown
  command -v gh >/dev/null 2>&1 || { echo unknown; return; }
  local s
  s=$(gh api "repos/$REPO/actions/runners" \
        --jq "[.runners[] | select(.name==\"$RUNNER_NAME\") | .status] | first // \"absent\"" 2>/dev/null) \
    || { echo unknown; return; }
  case "$s" in
    online|offline|absent) echo "$s" ;;
    *)                     echo unknown ;;
  esac
}

distro_answers() {
  # `true`, not a runner command: this asks whether the distro is there at all,
  # which is a different question with a different answer.
  wsl.exe -d "$DISTRO" -e true >/dev/null 2>&1
}

start_one_run() {  # the start itself, with no claim about what happened
  # The `sleep 3` is load-bearing, not politeness. Started with no grace at all
  # (`... &` and then the session ending at once), run.sh never even reaches its
  # own log file: measured on 2026-10-15, run.log's mtime did not move and nothing
  # was running ten seconds later, while the same command with three seconds in
  # the session left a process that was still there 37s later with GitHub reading
  # the runner online. WSL tears the session's processes down when the initiating
  # wsl.exe exits; three seconds is what it takes for setsid to have really
  # detached. Without this, this script would report a runner it never started.
  in_distro "cd '$RUNNER_DIR' && setsid nohup ./run.sh >> run.log 2>&1 < /dev/null & sleep 3" >/dev/null 2>&1
  sleep 2
}

start_runner() {  # start exactly one session; 0 only when exactly one is running
  local t n
  start_one_run
  t=$(listener_table) || { log "cannot read the listener table after a start -- not claiming a restore"; return 1; }
  n=$(table_count "$t")
  [ "$n" = 1 ] && { log "started one listener in $RUNNER_DIR (pid $(table_pids "$t"))"; return 0; }
  if [ "$n" != 0 ] && [ "$n" != '?' ]; then
    # A start of its own cannot make two. This means something else started one at
    # the same moment -- a hand-run ./run.sh, or a second watchdog that lost the
    # lock -- and both of them are the state this script exists to prevent, so
    # both go and exactly one comes back.
    log "DUPLICATE after starting: $n listeners in $RUNNER_DIR ($(printf '%s' "$t" | tr '\n' ';')) -- clearing them and starting one"
    stop_listeners "a start produced $n listeners" || return 1
    start_one_run
    t=$(listener_table) || return 1
    n=$(table_count "$t")
    [ "$n" = 1 ] && { log "now exactly one listener in $RUNNER_DIR (pid $(table_pids "$t"))"; return 0; }
  fi
  if [ "$n" = 0 ]; then
    log "started ./run.sh in $RUNNER_DIR but no listener came up -- see $RUNNER_DIR/run.log"
  else
    log "started ./run.sh in $RUNNER_DIR but $n listeners are up"
  fi
  return 1
}

github_busy() {  # 0 when the runner is in the middle of a job
  # A duplicate is worth clearing, a job that is running is not worth killing
  # mid-flight: the pair heals on the first idle cycle instead. This is only
  # called on the paths that are about to stop something, so it costs one API
  # call on the rare cycle, not one per cycle.
  command -v gh >/dev/null 2>&1 || return 1
  [ "$(gh api "repos/$REPO/actions/runners" \
        --jq "[.runners[] | select(.name==\"$RUNNER_NAME\") | .busy] | first // false" 2>/dev/null)" = true ]
}

wait_online() {  # wait_online SECONDS
  local deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(github_status)" = online ] && return 0
    sleep 5
  done
  return 1
}

state_note() { printf '%s\n' "$1" > "$STATE/last_state" 2>/dev/null || true; }
state_last() { cat "$STATE/last_state" 2>/dev/null || echo none; }

# One starter at a time, and one loop per machine. A manual run, the logon loop and
# anything else that calls this can all decide at the same moment that the runner
# is down, and each of them starting a session is the duplicate the rest of this
# script is against. mkdir is the atomic part, and it is a directory rather than a
# pid file on purpose: the pids this shell sees belong to the Git installation it
# came from, so `ps -p` cannot see a loop started by another one. Measured
# 2026-10-24: two loops running at once, 15196 from C:\Program Files\Git and 8448
# from a bundled Git, each unable to see the other's pid -- which is one more way
# to end up with two listeners in one runner directory.
lock_acquire() {  # lock_acquire NAME PATIENCE -- 0 held, 1 not held after PATIENCE s
  local name=$1 patience=$2 dir="$STATE/$1.lock" other since age waited=0
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' $$ > "$dir/pid" 2>/dev/null || true
      date +%s > "$dir/since" 2>/dev/null || true
      return 0
    fi
    other=$(cat "$dir/pid" 2>/dev/null || true)
    since=$(cat "$dir/since" 2>/dev/null || true)
    case "$other" in ''|*[!0-9]*) other=0 ;; esac
    case "$since" in ''|*[!0-9]*) since=$(date -r "$dir" +%s 2>/dev/null || echo 0) ;; esac
    case "$since" in ''|*[!0-9]*) since=0 ;; esac
    age=$(( $(date +%s) - since ))
    # Only the age decides. "The pid is not running" is not evidence here: a pid in
    # another Git installation reads as dead, and taking that lock away from a live
    # loop is exactly the race this exists to prevent. A lock young enough to be
    # held is respected even when its pid looks dead; an old one is abandoned,
    # because nobody is coming back for it.
    if [ "$since" != 0 ] && [ "$age" -gt 300 ]; then
      log "taking over a $name lock nobody can still be holding (pid ${other:-?}, age ${age}s)"
      rm -rf "$dir" 2>/dev/null || true
      continue
    fi
    [ "$waited" -ge "$patience" ] && return 1
    sleep 2
    waited=$(( waited + 2 ))
  done
}
lock_release() { rm -rf "$STATE/$1.lock" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# one check
# ---------------------------------------------------------------------------

alert_down() {  # alert_down WHY GITHUB_STATE -- the failure a log alone would hide
  {
    printf 'The push fast path is down and this watchdog could not restore it.\n\n'
    printf 'runner:       %s (%s)\n' "$RUNNER_NAME" "$REPO"
    printf 'what was seen: %s\n' "$1"
    printf 'GitHub says:  %s\n' "$2"
    printf 'log:          %s\n\n' "$LOG"
    printf 'To start it by hand, in the distro -- note the trailing sleep, without\n'
    printf 'which WSL tears the new process down with the session that started it:\n'
    printf '  cd %s && setsid nohup ./run.sh >> run.log 2>&1 < /dev/null & sleep 3\n' "$RUNNER_DIR"
  } > "$ALERT" 2>/dev/null || true
  notify error "$RUNNER_NAME is DOWN" "It reads '$2' and could not be restarted. Pushes still get a hosted verdict, hours later. See $LOG."
}

check_once() {  # 0 up (possibly restarted here), 1 down
  local tbl lstate n gh_state was why
  tbl=$(listener_table) || tbl='?'
  lstate=$(table_state "$tbl")
  n=$(table_count "$tbl")
  was=$(state_last)

  # --- two listeners, asked before anything about GitHub ---------------------
  # They read 'online' -- that is exactly the state that broke the 24 Oct push --
  # so the online check below would pass and report a fast path that cannot
  # finish a job. This is healed first, and never by starting a third.
  if [ "$n" != '?' ] && [ "$n" -gt 1 ]; then
    log "DUPLICATE: $n listeners in $RUNNER_DIR for one agent id -- this is what makes a job's page log collide and its artifact upload 403"
    if github_busy; then
      log "a job is running on $RUNNER_NAME, so nothing is stopped mid-job; this heals on the first idle cycle"
      state_note online
      return 0
    fi
    if ! lock_acquire start 120; then
      log "another watchdog holds the start lock -- leaving the duplicate to it"
      return 0
    fi
    if stop_listeners "two listeners for one agent id" && start_runner && wait_online "$RESTORE_WAIT"; then
      lock_release start
      log "healed: one listener in $RUNNER_DIR and $RUNNER_NAME reads 'online'"
      notify warn "$RUNNER_NAME had two listeners" "Two run.sh sessions in $RUNNER_DIR shared _work and _diag. Both were stopped and one started; jobs in that window failed at 'Set up job' or on their artifact upload."
      state_note online
      rm -f "$ALERT" 2>/dev/null || true
      return 0
    fi
    lock_release start
    gh_state=$(github_status)
    state_note down
    alert_down "two listeners were in $RUNNER_DIR and reducing them to one did not bring $RUNNER_NAME back online" "$gh_state"
    return 1
  fi

  if [ "$lstate" = unknown ]; then
    # The distro did not answer. That is not the runner being dead, and starting a
    # second listener next to a live one is worse than waiting a cycle, so the only
    # thing that happens here is a question to GitHub.
    gh_state=$(github_status)
    if [ "$gh_state" = online ]; then
      log "cannot tell: $DISTRO did not answer and GitHub reads 'online' -- not restarting anything, looking again next cycle"
      return 0
    fi
    why="$DISTRO did not answer"
    log "$DISTRO did not answer and GitHub reads '$gh_state' -- trying to reach it"
  elif [ "$lstate" = alive ]; then
    # Most cycles of the loop stop here: a live listener is cheap to confirm and
    # asks nothing of GitHub or the network. It is not treated as proof -- a
    # listener can be alive and disconnected -- which is why every
    # GH_CHECK_EVERY-th cycle, and every manual run, asks GitHub anyway.
    if [ "$MODE" = loop ] && [ $(( CYCLE % GH_CHECK_EVERY )) -ne 1 ]; then
      log "ok: one listener alive in $DISTRO, pid $(table_pids "$tbl") (GitHub not asked this cycle)"
      return 0
    fi
    gh_state=$(github_status)
    if [ "$gh_state" = unknown ]; then
      # The API did not answer, and from here that is indistinguishable from the
      # runner being disconnected -- but it is also what a network blip looks like
      # on a listener that is running a job. Replacing on that guess would kill the
      # job to fix the network, so nothing is replaced on a guess; the next cycle
      # asks again. This is the same rule the 'unknown' listener state follows.
      log "the listener is alive in $DISTRO but GitHub did not answer -- not replacing it on a guess"
      return 0
    fi
    if [ "$gh_state" = online ]; then
      if [ "$was" = down ]; then
        log "back online: $RUNNER_NAME reads '$gh_state' (it was down at the last check)"
        notify info "$RUNNER_NAME is back" "The push fast path is up again: pushes get a chip-gate verdict in about a minute."
      else
        log "ok: $RUNNER_NAME is online (one listener, pid $(table_pids "$tbl"))"
      fi
      state_note online
      rm -f "$ALERT" 2>/dev/null || true
      return 0
    fi
  else
    gh_state=$(github_status)
    # A dead listener is down whatever GitHub currently believes. GitHub only
    # marks a runner offline once its heartbeats stop arriving, so for a minute or
    # two after a kill the API still says online -- and reporting "online" for a
    # process that is not running is exactly the kind of quiet lie this script is
    # here to prevent. The process is the earlier signal and the cheaper thing to
    # believe, so it is believed first.
    why="the listener was not running in $DISTRO"
    log "$why (GitHub reads '$gh_state') -- starting it"
  fi

  # Reached without a `why` set only from the alive-but-not-online path above.
  [ -n "${why:-}" ] || why="the listener was alive but GitHub did not read it online"

  # Here either the listener is gone, or it is alive while GitHub does not see it
  # online. Both are the fast path being down.
  state_note down

  if [ "$gh_state" = absent ]; then
    log "FAIL: $REPO has no runner called $RUNNER_NAME -- starting one cannot create it"
    {
      printf 'The push fast path is down and starting a runner cannot fix this one.\n\n'
      printf 'repo:        %s\n' "$REPO"
      printf 'runner name: %s (GitHub says this repo has no such runner)\n\n' "$RUNNER_NAME"
      printf 'It has to be registered again; see the header of this script, and the\n'
      printf 'runner directory on the machine: %s\n' "$RUNNER_DIR"
    } > "$ALERT" 2>/dev/null || true
    notify error "$RUNNER_NAME is not registered" "$REPO has no runner by that name. Pushes still get a hosted verdict, hours later. It needs registering again, not starting."
    return 1
  fi

  if ! distro_answers; then
    # Seen for real on 2026-10-15: a wsl.exe call failed with
    # Wsl/Service/0x8007274c while GitHub and everything else were fine, and the
    # next call worked. That is the WSL service, not this runner, and it must not
    # be reported as "the runner would not start".
    log "$DISTRO did not answer -- waiting 15s (this is the WSL service, not the runner)"
    sleep 15
    if ! distro_answers; then
      log "FAIL: $DISTRO still does not answer; nothing here can reach the runner"
      {
        printf 'The push fast path is down and this watchdog cannot reach the distro.\n\n'
        printf 'distro:      %s\n' "$DISTRO"
        printf 'runner:      %s (%s), GitHub says %s\n' "$RUNNER_NAME" "$REPO" "$gh_state"
        printf 'log:         %s\n\n' "$LOG"
        printf 'This one is WSL, not the runner: try `wsl -d %s -e true` from a shell.\n' "$DISTRO"
      } > "$ALERT" 2>/dev/null || true
      notify error "$DISTRO is not answering" "The push fast path is down because this watchdog cannot reach WSL at all. Pushes still get a hosted verdict, hours later."
      return 1
    fi
    log "$DISTRO is answering again -- continuing"
  fi

  # One starter at a time, and never a start beside a survivor. Reaching this
  # point with the listener alive means it is alive and disconnected, so it is
  # replaced rather than joined -- a second listener beside it is exactly the
  # duplicate this script spends the rest of its length undoing.
  if ! lock_acquire start 120; then
    # Not started, and not yet a failure: another run may be starting it right now.
    # What this run says has to depend on what it can see, not on hope.
    tbl=$(listener_table) || tbl='?'
    gh_state=$(github_status)
    if [ "$(table_count "$tbl")" = 1 ] && [ "$gh_state" = online ]; then
      log "another watchdog is starting $RUNNER_NAME; it is online now -- nothing to do"
      state_note online
      return 0
    fi
    log "another watchdog has held the start lock for 120s and no listener is online"
    alert_down "another run has held the start lock for 120s; this one refused to start a second listener beside it" "$gh_state"
    return 1
  fi
  tbl=$(listener_table) || tbl='?'
  if [ "$tbl" = '?' ]; then
    lock_release start
    log "cannot read the listener table -- not starting anything blind"
    return 0
  fi
  # The lock may have been held by another run that has since restored it. Taking
  # over a runner that is already up and online is not a restore, it is a second
  # restart -- so the question is asked again now that this run owns the dir.
  if [ "$(table_count "$tbl")" = 1 ] && [ "$(github_status)" = online ]; then
    lock_release start
    log "another watchdog restored $RUNNER_NAME while this one waited for the start lock -- nothing to do"
    state_note online
    return 0
  fi
  if [ "$(table_count "$tbl")" != 0 ]; then
    if github_busy; then
      lock_release start
      log "a job is running on $RUNNER_NAME -- not stopping it; the listener is replaced on an idle cycle"
      state_note online
      return 0
    fi
    if ! stop_listeners "$why"; then
      lock_release start
      alert_down "a listener in $RUNNER_DIR would not stop, and starting another beside it is the duplicate" "$gh_state"
      return 1
    fi
  fi

  if start_runner; then
    lock_release start
    if wait_online "$RESTORE_WAIT"; then
      log "restored: $RUNNER_NAME is online again ($why; GitHub read '$gh_state' at the time)"
      notify warn "$RUNNER_NAME was down" "$why and GitHub said '$gh_state'. This watchdog started it and it is online again; pushes in that window waited on the hosted queue."
      state_note online
      rm -f "$ALERT" 2>/dev/null || true
      return 0
    fi
    log "FAIL: the listener is running in $DISTRO but GitHub still reads '$gh_state' after ${RESTORE_WAIT}s ($why)"
  else
    lock_release start
    log "FAIL: no single listener in $DISTRO:$RUNNER_DIR ($why; GitHub reads '$gh_state', which may be stale)"
  fi

  # Reached when the runner is not back, whichever way it did not come back: the
  # FAIL line above records which way, and the alert puts the same in a file and
  # on screen, because a failure only in a log is the silence this is for.
  alert_down "$why" "$gh_state"
  return 1
}

# ---------------------------------------------------------------------------
# the logon item
# ---------------------------------------------------------------------------

install_logon_item() {
  local startup vbs bash_win script_win script_posix
  # cygpath -u on the way in, cygpath -w on the way out: %APPDATA% arrives as
  # C:\Users\..., and a Windows path used as a bash path is not a path at all --
  # it is a file name made of backslashes, written somewhere nobody looks. The
  # line that goes into the .vbs has to be the Windows form, because WScript reads
  # it; this shell's writes have to be the bash form. Git Bash already carries
  # %APPDATA%, so nothing is asked of cmd for it.
  #
  # The fallback uses `cmd /c` and not `cmd //c`, and that is the whole reason this
  # comment exists. `//c` is the spelling that works in an ordinary Git Bash,
  # because MSYS rewrites it to `/c`; but this script exports MSYS_NO_PATHCONV=1
  # (for the wsl.exe paths above), which switches that rewriting off, so cmd is
  # handed a literal `//c`, does not recognise it as a switch, and opens an
  # INTERACTIVE cmd that waits on stdin forever. Measured on 2026-10-15: `--install`
  # hung with no output until it was killed, and the trace stopped on this line.
  startup_src=${APPDATA:-}
  [ -n "$startup_src" ] || startup_src=$(cmd /c "echo %APPDATA%" 2>/dev/null | tr -d '\r')
  startup=$(cygpath -u "$startup_src" 2>/dev/null)
  [ -n "$startup" ] || { echo "watchdog: cannot resolve %APPDATA%" >&2; exit 2; }
  startup="$startup/Microsoft/Windows/Start Menu/Programs/Startup"
  [ -d "$startup" ] || { echo "watchdog: no Startup folder at $startup" >&2; exit 2; }
  vbs="$startup/grx930-fast-path-watchdog.vbs"
  bash_win='C:\Program Files\Git\usr\bin\bash.exe'
  [ -x "/c/Program Files/Git/usr/bin/bash.exe" ] || {
    echo "watchdog: Git's bash.exe is not at $bash_win" >&2; exit 2; }
  # Two forms of the same file, because the two halves of the line need different
  # ones: CreateProcess is given bash.exe, so that is a Windows path, while the
  # argument is read by bash, so that is the /c/... form it can actually open.
  # A Windows path handed to bash here is "No such file or directory" at every
  # logon, which is the quiet kind of broken this script is against.
  script_posix="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  script_win=$(cygpath -w "$script_posix" 2>/dev/null)
  [ -n "$script_win" ] || { echo "watchdog: cannot resolve this script's Windows path" >&2; exit 2; }

  # A .vbs rather than a .cmd, because WScript runs it with window style 0: a
  # logon should not open a console window that somebody then has to close. Both
  # paths are quoted because either can contain a space, and each of those quotes
  # is doubled because doubling is how a VBScript string literal escapes a quote.
  # The line written here is:
  #
  #   s.Run """C:\Program Files\Git\usr\bin\bash.exe"" -lc ""/c/.../script.sh --loop""", 0, False
  {
    printf 'Set s = CreateObject("WScript.Shell")\r\n'
    printf 's.Run """%s"" -lc ""%s --loop""", 0, False\r\n' "$bash_win" "$script_posix"
  } > "$vbs" || { echo "watchdog: cannot write $vbs" >&2; exit 2; }

  echo "installed: $vbs"
  echo "it runs:   \"$bash_win\" -lc \"$script_posix --loop\"  (hidden, every ${INTERVAL}s)"
  echo "uninstall: delete that file -- the runner itself keeps running either way"
  echo
  echo "--- what just went into the Startup folder ---"
  cat "$vbs"
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

MODE=once
CYCLE=1
case "${1:-}" in
  "")          MODE=once ;;
  --loop)      MODE=loop ;;
  --status)    MODE=status ;;
  --install)   install_logon_item; exit 0 ;;
  -h|--help)   usage; exit 0 ;;
  *)           usage; exit 2 ;;
esac

case "$MODE" in
  status)
    tbl=$(listener_table) || tbl='?'
    lstate=$(table_state "$tbl")
    n=$(table_count "$tbl")
    gh_state=$(github_status)
    printf 'runner:  %s in distro %s (%s)\n  GitHub says:     %s\n  listeners:       %s  (pid %s)\n  log:             %s\n' \
      "$RUNNER_NAME" "$DISTRO" "$REPO" "$gh_state" "$n" "$(table_pids "$tbl")" "$LOG"
    # GitHub alone is not the answer. A runner that just died still reads online
    # until its heartbeats lapse, so a status built on it reported "online" with
    # nobody listening -- measured on 2026-10-15, and it exited 0 while the fast
    # path was dead. The listeners are the thing that has to be there, so they are
    # what decides; "unknown" is not a pass either. And more than one is not a
    # pass: two share one _work/_diag, which is a fast path that breaks jobs rather
    # than one that runs them.
    if [ "$n" != '?' ] && [ "$n" -gt 1 ]; then
      echo "  TWO LISTENERS for one agent id in $RUNNER_DIR -- their jobs collide. Run without --status to heal it." >&2
    fi
    [ "$lstate" = alive ] && [ "$n" = 1 ] && exit 0
    exit 1
    ;;
  once)
    check_once
    ;;
  loop)
    # One loop per machine: a second would race the first to start the same
    # listener, and the loser's "could not restore" would be a lie. The guard is a
    # directory, not the old pid file, because two loops can come from two Git
    # installations whose pids cannot be checked from one another -- and on
    # 2026-10-24 two such loops were running at once (15196 and 8448).
    if ! lock_acquire loop 0; then
      other=$(cat "$STATE/loop.lock/pid" 2>/dev/null || echo ?)
      echo "watchdog: already looping as pid $other -- this one exits" >&2
      exit 0
    fi
    trap 'lock_release loop' EXIT INT TERM
    log "loop started: every ${INTERVAL}s, GitHub asked every ${GH_CHECK_EVERY} cycles, notify=$NOTIFY"
    while :; do
      check_once || true
      CYCLE=$(( CYCLE + 1 ))
      sleep "$INTERVAL"
    done
    ;;
esac
