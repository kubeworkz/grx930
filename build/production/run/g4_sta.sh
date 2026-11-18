#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
FINAL="$PROD/final"
STA="$PROD/sta"

mkdir -p "$STA" "$PROD/logs"

DEF="$FINAL/grx930_test_chip.def"
SPEF="$FINAL/grx930_test_chip.spef"
TCL="$STA/sta_mcorner.tcl"
POWER_TCL="$STA/power_ir.tcl"

missing=()
[ -s "$DEF" ] || missing+=("$DEF")
[ -s "$SPEF" ] || missing+=("$SPEF")
[ -s "$TCL" ] || missing+=("$TCL")
[ -s "$POWER_TCL" ] || missing+=("$POWER_TCL")
command -v openroad >/dev/null 2>&1 || missing+=("openroad")

if [ "${#missing[@]}" -ne 0 ]; then
  {
    echo "gate=G4"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=STA/power lead (unassigned)"
    for f in "${missing[@]}"; do echo "missing=$f"; done
    echo "note=No timing, power, IR, EM, crosstalk, or thermal result is claimed."
  } | tee "$STA/G4_status.txt"
  exit 2
fi

set +e
for corner in ss_n40C_4v50 ss_125C_4v50 tt_025C_5v00 ff_n40C_5v50 ff_125C_5v50; do
  CORNER="$corner" openroad -exit "$TCL" \
    > "$STA/${corner}.log" 2>&1
  rc=$?
  echo "$corner exit_code=$rc" >> "$STA/corner_status.txt"
  if [ "$rc" -ne 0 ]; then
    set -e
    {
      echo "gate=G4"
      echo "status=FAILED"
      echo "corner=$corner"
      echo "exit_code=$rc"
      echo "log=$STA/${corner}.log"
    } > "$STA/G4_status.txt"
    cat "$STA/G4_status.txt"
    exit "$rc"
  fi
done
set -e

set +e
openroad -exit "$POWER_TCL" > "$STA/power_ir.log" 2>&1
power_rc=$?
set -e

{
  echo "gate=G4"
  if [ "$power_rc" -eq 0 ]; then echo "status=RAN_REVIEW_REQUIRED"; else echo "status=FAILED"; fi
  echo "power_exit_code=$power_rc"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "corners=ss_n40C_4v50,ss_125C_4v50,tt_025C_5v00,ff_n40C_5v50,ff_125C_5v50"
  echo "note=RUN_REVIEW_REQUIRED is not a timing/power signoff; WNS/TNS/WHS, IR/EM, crosstalk and thermal must be reviewed and signed."
} > "$STA/G4_status.txt"

cat "$STA/G4_status.txt"
exit "$power_rc"
