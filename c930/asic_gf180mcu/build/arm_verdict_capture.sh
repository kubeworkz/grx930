#!/bin/bash
# arm_verdict_capture.sh -- wait for both fast-DRT arms, write their comparison.
#
# The two arms are hours apart (arm 1 held drt_core from 00:50, arm 2 is
# serialized behind it by grt03c_chain.sh), so the verdict has to be captured by
# something that outlives the shell that launched it. This writes
# drt_fast/verdict/arm_compare.md and a DONE marker; nothing here touches a
# running container.
#
#   nohup bash build/arm_verdict_capture.sh > /dev/null 2>&1 &
#
# Two bugs in the first version, both fixed here, both worth remembering:
#
#  1. `finals | grep -oE '[0-9]+'` takes the FIRST digit run on the line, which
#     in "    Completing 100% with 1096857 violations." is the progress
#     percentage, not the count. Every arm-1/arm-2 cell in the first report came
#     out as "100\n1096857". Extract the number immediately before " violations".
#  2. The arm-2 wait was a 420-minute budget counted from the moment arm 1's log
#     appeared (04:02), but arm 2's log is written by grt03c_chain.sh only after
#     its DRT container exits -- and arm 2 had to wait out arm 1's whole window,
#     then run 8.6 h of flow, then 1.4 h of DRT. The deadline expired at 11:02,
#     nine minutes before the log landed at 11:11, and the report was written
#     with arm 2 as "? ? ?". Wait on both logs with one long shared budget
#     instead, and never count one arm's wait against the other's.
set -u
D=/home/ubuntu/grx930_ol2/drt_fast
OUT=$D/verdict
mkdir -p "$OUT"
LOG=$OUT/verdict.log
say() { echo "[$(date -u)] $*" >> "$LOG"; }

# Progress lines look like:
#   [INFO DRT-0195] Start 1st optimization iteration.
#       Completing 20% with 207648 violations.
curve() { grep -aE "Completing [0-9]+% with|Start [0-9]+(st|th|nd|rd) optimization iteration" "$1" 2>/dev/null; }
# The violation count of every 100% line, in order: initial route, iter 1, iter 2.
finals() { grep -aE "Completing 100% with" "$1" 2>/dev/null | grep -oE 'with [0-9]+ violations' | grep -oE '[0-9]+'; }
# detailed_route's own authoritative post-run count.
total_viol() { grep -aE "^\[INFO DRT-0199\]" "$1" 2>/dev/null | grep -oE '[0-9]+' | tail -1; }
# Peak resident memory of the run, MB.
peak_mem() { grep -aE "^\[INFO DRT-0267\]" "$1" 2>/dev/null | grep -oE 'peak = [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1; }

# The wirelength lines look like:
#   [INFO GRT-0018] Total wirelength: 24301804 um
# so anchor on the "Total wirelength: <n> um" form. A bare `grep -oE '[0-9]+'`
# takes "0018" off the GRT-0018 tag first -- the same first-digit-run trap as the
# violation counts, and it is how the wirelength column first came out as 0018.
wire_of() { grep -aoE 'Total wirelength: [0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+'; }

# Per-step wall clock. A step dir may hold runtime.txt directly or one level down
# (e.g. 45-openroad-repairantennas/1-diodeinsertion/runtime.txt).
step_runtime() {  # $1 = run dir, $2 = step ordinal
  local d r
  for d in "$1"/$2-*/; do
    [ -d "$d" ] || continue
    for r in "$d"runtime.txt "$d"*/runtime.txt; do
      [ -f "$r" ] && { cat "$r"; return; }
    done
  done
  printf '?'
}

# Thousands separators, so 1096857 does not have to be counted by eye in a table.
commas() {
  local n=${1:-} out=''
  [ "$n" -eq "$n" ] 2>/dev/null || { printf '%s' "$n"; return; }
  while [ ${#n} -gt 3 ]; do out=",${n: -3}$out"; n="${n%???}"; done
  printf '%s' "$n$out"
}

# GRT's own wirelength estimate: the log whose "Global adjustment:" matches.
grt_wire() {  # $1 = run dir, $2 = "0%" | "30%"
  for f in "$1"/*-openroad-globalrouting/openroad-globalrouting.log; do
    [ -e "$f" ] || continue
    if grep -qa "Global adjustment: $2" "$f" 2>/dev/null; then
      wire_of "$f" | head -1
      return
    fi
  done
  echo "?"
}
# Wirelength after antenna-diode insertion: the diode log that repeats the GRT
# estimate also carries its own post-insertion value, which the template logs
# last. Pairing on the repeated value avoids having to know the step number.
postdiode() {  # $1 = run dir, $2 = the GRT estimate value
  for f in "$1"/*-repairantennas/*/diodeinsertion.log; do
    [ -e "$f" ] || continue
    if grep -qa "Total wirelength: $2 um" "$f" 2>/dev/null; then
      wire_of "$f" | sort -n | tail -1
      return
    fi
  done
  echo "?"
}

say "CAPTURE_START (waiting for logs/core_drt.log and logs/core03_drt.log)"

# One shared, generous budget for BOTH logs (24 h at 1-minute polls). arm 2
# cannot start until arm 1's window closes, so the two waits are not independent.
i=0
while { [ ! -f "$D/logs/core_drt.log" ] || [ ! -f "$D/logs/core03_drt.log" ]; } && [ $i -lt 1440 ]; do
  i=$((i+1)); sleep 60
done
say "ARM1_LOG $([ -f "$D/logs/core_drt.log" ] && echo ready || echo TIMEOUT)"
say "ARM2_LOG $([ -f "$D/logs/core03_drt.log" ] && echo ready || echo TIMEOUT)"

C1=$D/logs/core_drt.log
C2=$D/logs/core03_drt.log
FAT=/home/ubuntu/grx930_ol2/openlane2_rtl/runs/RUN_2026-09-30_23-41-23
SLOT=/home/ubuntu/grx930_ol2/openlane2_rtl/runs/slotcore_v1

# The two arms consume the endpoint of the same flow with only this variable
# changed, so the committed arm-1 checkpoint must be the same size as the 0.0 GRT
# step's output and the arm-2 one as the 0.3 step's -- check, do not assume.
A1ODB=$(stat -c %s $D/ckpt/pre_drt_slotcore.odb 2>/dev/null)
A2ODB=$(stat -c %s $D/ckpt/pre_drt_slotcore03.odb 2>/dev/null)

{
  echo "# Fast-DRT arm verdicts — slot core 3048x4238 (12.93 mm2), 2 iterations"
  echo
  echo "Same six detailed_route arguments in every row; the only difference between"
  echo "arm 1 and arm 2 is \`GRT_ADJUSTMENT\`, i.e. the guides they route against."
  echo "Captured $(date -u) by \`build/arm_verdict_capture.sh\`."
  echo
  echo "| arm | core | GRT_ADJUSTMENT | iter0 (initial route) | iter1 | iter2 |"
  echo "|---|---|---|---|---|---|"
  printf '| baseline | fat (whole die, 33.4%%) | 0.0 | 1,081,775 | 405,529 | 387,049 |\n'
  printf '| arm 1 | slot (12.93 mm2) | 0.0 | %s | %s | %s |\n' \
    "$(commas "$(finals "$C1" | sed -n '1p')")" "$(commas "$(finals "$C1" | sed -n '2p')")" \
    "$(commas "$(finals "$C1" | sed -n '3p')")"
  printf '| arm 2 | slot (12.93 mm2) | 0.3 | %s | %s | %s |\n' \
    "$(commas "$(finals "$C2" | sed -n '1p')")" "$(commas "$(finals "$C2" | sed -n '2p')")" \
    "$(commas "$(finals "$C2" | sed -n '3p')")"
  echo
  echo "Final count as detailed_route itself reports it (\`DRT-0199\`), which is the"
  echo "number to quote — it can differ slightly from the last \`Completing 100%\` line:"
  echo
  echo "| arm | DRT-0199 violations | GRT wirelength (um) | after diode insertion (um) | peak mem (MB) |"
  echo "|---|---|---|---|---|"
  W0=$(grt_wire "$SLOT" "0%"); W3=$(grt_wire "$SLOT" "30%")
  printf '| arm 1 (0.0) | %s | %s | %s | %s |\n' \
    "$(commas "$(total_viol "$C1")")" "$(commas "${W0:-?}")" \
    "$(commas "$(postdiode "$SLOT" "${W0:-x}")")" "$(commas "$(peak_mem "$C1")")"
  printf '| arm 2 (0.3) | %s | %s | %s | %s |\n' \
    "$(commas "$(total_viol "$C2")")" "$(commas "${W3:-?}")" \
    "$(commas "$(postdiode "$SLOT" "${W3:-x}")")" "$(commas "$(peak_mem "$C2")")"
  echo
  echo "## arm 1 — slot core, GRT_ADJUSTMENT 0.0"
  echo '```'
  curve "$C1" | tail -32
  echo '```'
  echo
  echo "## arm 2 — slot core, GRT_ADJUSTMENT 0.3"
  echo '```'
  curve "$C2" | tail -32
  echo '```'
  echo
  echo "## Was 0.3 affordable? (from grt03c_chain.log)"
  echo '```'
  grep -ah "Global adjustment\|Total wirelength\|GATE_PASS\|GATE_FAIL\|NO_CKPT" "$D/grt03c_chain.log" 2>/dev/null | tail -6
  grep -ah -A9 "Final congestion report" "$D/grt03c_chain.log" 2>/dev/null | tail -11
  echo '```'
  echo
  echo "## Did the two arms differ only by the adjustment?"
  echo '```'
  echo "arm 1 input $D/ckpt/pre_drt_slotcore.odb   $(commas "${A1ODB:-?}") bytes"
  echo "  0.0 GRT step output  $SLOT/41-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb"
  echo "arm 2 input $D/ckpt/pre_drt_slotcore03.odb $(commas "${A2ODB:-?}") bytes"
  echo "  0.3 GRT step output  $SLOT/45-openroad-repairantennas/1-diodeinsertion/grx930_test_chip.odb"
  echo '```'
  echo
  echo "## Decision rule"
  echo "Whichever arm reaches the lower iteration-2 plateau wins the"
  echo "\`GRT_ADJUSTMENT\` value in wafer_space_integration/grx930_overrides.yaml."
  echo
  echo "**Outcome: arm 2 (0.3) wins the primary criterion by 2.19x** —"
  echo "191,578 against 418,633, and its plateau is still falling (-7.8 % per"
  echo "iteration) where arm 1's has nearly stopped (-3.9 %). Arm 1 cannot close"
  echo "that gap: at -3.9 % per iteration it would need ~20 more iterations"
  echo "(~18 h at its own ~55 min/iteration) even if the rate held, and DRT's"
  echo "improvement rate decelerates."
  echo
  echo "**But the guard clause written into the rule does not discriminate.** It"
  echo "fires on \`\"extra iterations to remove overflow\"\`, and that line appears in"
  echo "BOTH logs — the 0.0 arm logs it too, and clears its overflow, finishing with"
  echo "0 on every layer and 12.18 % usage. The discriminating line is"
  echo "\`WARNING GRT-0115 Global routing finished with overflow\`, which shows up"
  echo "ONLY at 0.3: 15,155 unresolved overflow across M1-M5. So read strictly, the"
  echo "guard says \"0.3 unaffordable, move the lever to placement\"."
  echo
  echo "**Why 0.3 is kept anyway.** The reservation is what *produces* the overflow:"
  echo "GRT is told each edge has ~34 % less capacity, so it exceeds its own budget"
  echo "by construction and spreads demand onto M3/M4 (usage 12.3 %->24.9 % and"
  echo "6.9 %->19.9 % of true capacity). \`GRT_ALLOW_CONGESTION: true\` makes that"
  echo "informational, not an error. The thing the guard was guarding against is"
  echo "\"does reserving capacity pay out at DRT?\", and the measured answer is yes,"
  echo "by 2.19x, in 2.3x less wall clock. The guard predicted the mechanism"
  echo "correctly and mis-scored it."
  echo
  echo "**Cost that is NOT addressed:** wirelength +18.2 % (24.30 M -> 28.73 M um)."
  echo "That is GRT's estimate against GRT's estimate, so the delta is sound but the"
  echo "absolute level is not: on this design GRT over-estimates routed wire by ~25 %"
  echo "(v8: GRT 24.3 M vs 19.4 M measured). Neither arm reaches a routed result, so"
  echo "the true routed-wire penalty is unmeasured. 0.3 is a starting point, not a"
  echo "settled optimum — the knee is somewhere in 0.1-0.3."
  echo
  echo "**Nor is 0.3 net-faster end to end: the flow tail that feeds DRT is far slower.**"
  echo "Per-step \`runtime.txt\` on the same run tag, 0.0's steps 38-41 against 0.3's 42-45:"
  echo
  echo "| step | 0.0 | 0.3 |"
  echo "|---|---|---|"
  printf '| globalrouting | %s | %s |\n' "$(step_runtime "$SLOT" 38)" "$(step_runtime "$SLOT" 42)"
  printf '| checkantennas | %s | %s |\n' "$(step_runtime "$SLOT" 39)" "$(step_runtime "$SLOT" 43)"
  printf '| repairantennas (diode insertion) | %s | %s |\n' "$(step_runtime "$SLOT" 41)" "$(step_runtime "$SLOT" 45)"
  echo
  echo "So the DRT saving (3:06:08 -> 1:20:31) is partly given back and the segment"
  echo "costs ~+3:45 net. GRT spends over an hour instead of three minutes iterating on"
  echo "a graph it has been told is over budget, and antenna repair spends 4.4 h instead"
  echo "of 9 min fixing what those guides left — the pre-DRT ODB is 7.7 % larger"
  echo "(203,851,717 -> 219,661,871 B), i.e. more diodes. This bounds the verdict rather"
  echo "than reversing it — 418,633 violations is not a viable endpoint at any speed, and"
  echo "0.3 is the only arm trending toward zero — but it makes the 0.1/0.2 arm the"
  echo "higher-value next run: a smaller reservation that keeps most of the violation win"
  echo "should also keep the tail cheap."
} > "$OUT/arm_compare.md"

say "COMPARE_WRITTEN $OUT/arm_compare.md"
touch "$OUT/DONE"
