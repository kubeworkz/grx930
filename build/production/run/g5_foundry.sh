#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
FINAL="$PROD/final"
FOUNDRY="$PROD/foundry"

mkdir -p "$FOUNDRY" "$PROD/logs"

GDS="$FINAL/grx930_test_chip_final.gds"
CDL="$FINAL/grx930_test_chip.cdl"
VERIFY="$PROJECT_ROOT/c930/asic_gf180mcu/wafer_space_submission/verify_layers.py"

missing=()
[ -s "$GDS" ] || missing+=("$GDS")
[ -s "$CDL" ] || missing+=("$CDL")
[ -s "$VERIFY" ] || missing+=("$VERIFY")

if [ "${#missing[@]}" -ne 0 ]; then
  {
    echo "gate=G5"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=Tape-out manager (unassigned)"
    for f in "${missing[@]}"; do echo "missing=$f"; done
    echo "note=No foundry submission or approval is claimed."
  } | tee "$FOUNDRY/G5_status.txt"
  exit 2
fi

sha256sum "$GDS" "$CDL" > "$FOUNDRY/final_manifest.sha256"
set +e
python3 "$VERIFY" "$GDS" > "$FOUNDRY/layer_check.log" 2>&1
rc=$?
set -e

{
  echo "gate=G5"
  if [ "$rc" -eq 0 ]; then echo "status=RAN_REVIEW_REQUIRED"; else echo "status=FAILED"; fi
  echo "layer_check_exit_code=$rc"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "manifests=$FOUNDRY/final_manifest.sha256"
  echo "note=Layer check is not a foundry review; mask, package/pinout, waiver and silicon qualification signoff remain required."
} > "$FOUNDRY/G5_status.txt"

cat "$FOUNDRY/G5_status.txt"
exit "$rc"
