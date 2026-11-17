#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
FINAL="$PROD/final"
MAN="$PROD/manifests"

mkdir -p "$FINAL" "$MAN" "$PROD/dft" "$PROD/lvs" "$PROD/drc" "$PROD/sta" "$PROD/foundry" "$PROD/logs"

required=(
  "$FINAL/grx930_test_chip_final.gds"
  "$FINAL/grx930_test_chip.cdl"
  "$FINAL/grx930_test_chip.def"
  "$FINAL/grx930_test_chip.spef"
)

deck_files=(
  "$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc"
  "$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs"
  "$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/metal.rb"
  "$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/via.rb"
)

missing=()
: > "$MAN/input_sha256.txt"
for f in "${required[@]}" "${deck_files[@]}"; do
  if [ -s "$f" ]; then
    sha256sum "$f" >> "$MAN/input_sha256.txt"
  else
    printf 'MISSING %s\n' "$f" >> "$MAN/input_sha256.txt"
    missing+=("$f")
  fi
done

if [ "${#missing[@]}" -eq 0 ]; then
  status="READY_FOR_REVIEW"
else
  status="BLOCKED"
fi

{
  echo "gate=G0"
  echo "status=$status"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "owner=Design lead (unassigned)"
  echo "manifest=$MAN/input_sha256.txt"
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "missing=none"
  else
    echo "missing_count=${#missing[@]}"
    for f in "${missing[@]}"; do echo "missing=$f"; done
  fi
  echo "note=Hashes are evidence only. G0 is not PASS until the design lead and independent reviewer sign the identity and contents."
} > "$MAN/G0_status.txt"

cat "$MAN/G0_status.txt"

if [ "${#missing[@]}" -ne 0 ]; then
  exit 2
fi
