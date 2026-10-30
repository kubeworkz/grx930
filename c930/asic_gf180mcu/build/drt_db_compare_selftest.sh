#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# drt_db_compare_selftest.sh -- proves build/drt_db_compare_chain.sh's post-launch
# path with docker STUBBED: the launch arguments it builds, the harvest, the row it
# assembles, the report it rewrites, and the warning it owes when a router log has
# nothing to harvest. It launches no container and routes nothing, so it costs
# seconds instead of the hours one real arm costs.
#
# WHY IT EXISTS
#
#   The chain was written and staged for an unattended four-arm run. Its launch path
#   had two defects that only a real arm -- hours later, with the box busy -- would
#   have exposed:
#
#     * `local a=$1 db=$2 or=$3 dblog=$a`: `$a` is unset at that point under `set -u`,
#       so the first arm died with `a: unbound variable` after the gate had already
#       said OK. The four-arm run would have produced four... nothing.
#     * `${OR:-pinned (image openroad)}${OR:+26Q4-...}` for the engine cell: with OR
#       set, BOTH branches expand, so the cell read
#       `/work/ws/tools/openroad_26q4.sh26Q4-407-geb14e40b7b (wrapper)`.
#
#   Both were found by running a copy of this file against the chain before the chain
#   reached an arm. That is the argument for keeping it: the chain's own selftest
#   exists so the next edit to it is checked in seconds, not in hours of router time.
#
# WHAT IS REAL AND WHAT IS FAKE
#
#   Real: the databases, the probe/`state_in.json` provenance checks (they are the
#   chain's contract with the runs that produced each database), gate.sh + memwatch,
#   the watcher's log-only verdict call. Fake: docker only -- every verb the chain
#   uses is stubbed and recorded, so the assertions can prove what the chain ASKED
#   for without a container existing.
#
#   bash build/drt_db_compare_selftest.sh
#   DRTDC_SELFTEST_KEEP=1 bash build/drt_db_compare_selftest.sh   # leave the sandbox
set -u
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=${DRTDC_SELFTEST_ROOT:-/home/ubuntu/grx930_ol2}
CHAIN=$HERE/drt_db_compare_chain.sh
T=${DRTDC_SELFTEST_TMP:-/tmp/drt_db_compare_selftest.$$}
pass=0; fail=0

has() {  # file pattern message
    if grep -aq -- "$2" "$1" 2>/dev/null; then pass=$((pass+1)); echo "  ok   $3"
    else fail=$((fail+1)); echo "  FAIL $3"; fi
}
hasnt() {
    if grep -aq -- "$2" "$1" 2>/dev/null; then fail=$((fail+1)); echo "  FAIL $3"
    else pass=$((pass+1)); echo "  ok   $3"; fi
}
cleanup() { [ "${DRTDC_SELFTEST_KEEP:-0}" = 1 ] || rm -rf "$T"; }
trap cleanup EXIT
rm -rf "$T"
[ -f "$CHAIN" ] || { echo "no chain at $CHAIN"; exit 2; }
[ -f "$ROOT/build/drt_db_compare_chain.sh" ] || echo "note: the staged copy is not at $ROOT (real-input checks will speak for themselves)"

# mklog TAG INITIAL IT1 IT2 IT3 PEAK_MB START END > sandbox/<tag>.log
# Line shapes copied from the real router logs (drt_fast/logs/die02_drt.log): the
# `Completing 100% with` series is what the chain harvests (as die_drt_chain.sh
# does), DRT-0199 is the router's own total, DRT-0267 the memory record.
mklog() {
    local f=$1 tag=$2 init=$3 i1=$4 i2=$5 i3=$6 peak=$7 start=$8 end=$9
    { printf 'RUN_START %s tag=%s odb=/work/x.odb iter=3 layers=Metal1-Metal5 threads=8\n' "$start" "$tag"
      printf 'DIE_DRT_START tag=%s end_iter=3 threads=8\n' "$tag"
      for v in "$init" "$i1" "$i2" "$i3"; do
          printf '    Completing 100%% with %s violations.\n' "$v"
          printf '[INFO DRT-0199]   Number of violations = %s.\n' "$v"
      done
      printf '[INFO DRT-0267] cpu time = 03:00:00, elapsed time = 00:25:37, memory = 8055.25 (MB), peak = %s.00 (MB)\n' "$peak"
      printf 'RUN_END %s rc=0\n' "$end"; } > "$f"
}

# sandbox CASE ARMS -> builds CASE/, prints its path; the stub docker and the
# synthetic per-arm logs are laid out inside it.
sandbox() {
    local case=$1
    local d=$T/$case
    mkdir -p "$d/bin" "$d/root/drt_fast/logs"
    ln -s "$ROOT/ws" "$d/root/ws"
    ln -s "$ROOT/build" "$d/root/build"
    sed -e "s|^ROOT=.*|ROOT=$d/root|" \
        -e "s|^LOG=\$WS/logs/drt_db_compare.log|LOG=$d/compare.log|" \
        "$CHAIN" > "$d/chain.sh"
    { echo '#!/bin/bash'
      echo "echo \"\$*\" >> $d/calls"
      echo 'case "$*" in'
      echo '  inspect*-f*Running*) echo false; exit 0 ;;'
      echo '  inspect*-f*ExitCode*) echo 0; exit 0 ;;'
      echo '  logs*)'
      echo "     tag=\$(echo \"\$*\" | awk '{print \$2}')"
      echo '     tag=${tag#drtdc_}'   # the chain names containers drtdc_<arm>, the logs <arm>.log
      echo "     [ -f $d/\$tag.log ] && cat $d/\$tag.log"
      echo '     exit 0 ;;'
      echo 'esac'
      echo 'exit 0'; } > "$d/bin/docker"
    chmod +x "$d/bin/docker"
    echo "$d"
}

# ---------------------------------------------------------------- case 1: two arms
D=$(sandbox ok)
mklog "$D/jmp.log"     jmp      446541 303874 296214 125994 8101 2026-10-14T16:00:00Z 2026-10-14T17:30:00Z
mklog "$D/pin26q4.log" pin26q4  612345 401234 355678 301234 9123 2026-10-14T17:31:00Z 2026-10-14T19:05:00Z
echo "case 1: two arms, synthetic router logs"
PATH="$D/bin:$PATH" DRTDC_ARMS="jmp pin26q4" bash "$D/chain.sh" > "$D/run.out" 2>&1
rc=$?
MD=$D/root/drt_fast/verdict/die_drt_db_compare.md
TSV=$D/root/drt_fast/verdict/die_drt_db_compare.tsv
[ "$rc" = 0 ] && { pass=$((pass+1)); echo "  ok   the chain runs to completion (rc=0)"; } \
              || { fail=$((fail+1)); echo "  FAIL the chain exited rc=$rc"; sed -n '1,20p' "$D/run.out"; }

has  "$D/compare.log" "ARM_LAUNCHED jmp container=drtdc_jmp"            "arm 1 is launched through run_arm (no unbound variable under set -u)"
has  "$D/compare.log" "initial=446541 it1=303874 it2=296214 it3=125994" "the harvest reads the router's own iteration series"
has  "$D/compare.log" "it1=401234"                                      "arm 2 is harvested too"
has  "$D/compare.log" "ARM_DB jmp path="                                "arm 1 records its database path before launching"
has  "$D/compare.log" "PROVENANCE_OK jmp state_in.json"                 "arm 1's database is checked against the flow's state_in.json"
hasnt "$D/compare.log" "ARM_HARVEST_EMPTY"                              "no empty-harvest warning when the log has the series"

has  "$D/calls" "run -d --name drtdc_jmp"                               "the container name follows the arm"
has  "$D/calls" "FAST_ODB=/work/ws/probe/out_pin01/base/base.odb"       "arm 2 routes the pin's database, not some other one"
has  "$D/calls" "-e DIE_DRT_OR=/work/ws/tools/openroad_26q4.sh"         "arm 2 asks for the engine that wrote that database"
has  "$D/calls" "-e FAST_END_ITER=3"                                    "the iteration budget reaches the driver"
has  "$D/calls" "-v $D/root:/work"                                      "the workspace mount is the arm's own ROOT"
has  "$D/calls" "inspect -f {{.State.Running}} drtdc_pin26q4"           "the chain waits on the container it started"

has  "$D/compare.log" "ARM_REPORT_UPDATED"                              "the report is rewritten after each arm"
has  "$TSV" "jmp|"                                                      "the tsv carries the arm's row"
has  "$TSV" "446,541|303,874|296,214|125,994"                           "the row carries the harvested numbers, thousands-separated"
has  "$TSV" "|26Q4-407-geb14e40b7b (wrapper)|"                          "the engine cell names the wrapper"
hasnt "$TSV" "openroad_26q4.sh26Q4"                                     'the engine cell is not the concatenation of both ${OR} branches'
has  "$MD"  "27,758"                                                    "the report carries the flow arm's reference curve (27,758)"
has  "$MD"  "| \`jmp\` |"                                               "the report's arm table has the arm row"
has  "$MD"  "harvested with the same functions"                         "the report says where the reference numbers came from"
has  "$MD"  "ANT_PROBE_WROTE /work/ws/probe/out_pin01/base/base.odb"    "the provenance evidence is quoted verbatim in the report"

# ------------------------------------------- case 2: a log with nothing to harvest
D2=$(sandbox empty)
echo "case 2: one arm whose router log has no iteration series"
PATH="$D2/bin:$PATH" DRTDC_ARMS="pindiode" bash "$D2/chain.sh" > "$D2/run.out" 2>&1
rc2=$?
[ "$rc2" = 0 ] && { pass=$((pass+1)); echo "  ok   an unharvestable log does not kill the chain"; } \
               || { fail=$((fail+1)); echo "  FAIL rc=$rc2 on the empty-log case"; }
has "$D2/compare.log" "ARM_HARVEST_EMPTY pindiode" "and the log says so, naming the arm and its log"
has "$D2/compare.log" "no 'Completing 100% with' line" "with the reason spelled out"

echo
echo "drt_db_compare_selftest: $pass passed, $fail failed"
[ "${DRTDC_SELFTEST_KEEP:-0}" = 1 ] && echo "sandbox kept at $T"
[ "$fail" = 0 ] || exit 1
exit 0
