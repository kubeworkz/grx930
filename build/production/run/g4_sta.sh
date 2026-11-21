#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
FINAL="$PROD/final"
STA="$PROD/sta"

mkdir -p "$STA" "$PROD/logs"

DEF="$PROJECT_ROOT/build/lvs_chip/eco_drop_2x2/stage6/eco_routed.def"
SPEF="$FINAL/grx930_test_chip.spef"
TCL="$STA/sta_mcorner.tcl"
POWER_TCL="$STA/power_ir.tcl"
PDK_MANIFEST="$PROD/manifests/g4_pdk_sha256.txt"
PDK_REL="c930/asic_gf180mcu/gf180mcu_pdk"
PDK_CELL_REL="$PDK_REL/libs.ref/gf180mcu_fd_sc_mcu7t5v0"
PDK_EXPECTED=(
  "$PDK_CELL_REL/lef/gf180mcu_fd_sc_mcu7t5v0.tlef"
  "$PDK_CELL_REL/lef/gf180mcu_fd_sc_mcu7t5v0_combined_clean.lef"
  "$PDK_CELL_REL/lib/gf180mcu_fd_sc_mcu7t5v0__ss_n40C_4v50.lib"
  "$PDK_CELL_REL/lib/gf180mcu_fd_sc_mcu7t5v0__ss_125C_4v50.lib"
  "$PDK_CELL_REL/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib"
  "$PDK_CELL_REL/lib/gf180mcu_fd_sc_mcu7t5v0__ff_n40C_5v50.lib"
  "$PDK_CELL_REL/lib/gf180mcu_fd_sc_mcu7t5v0__ff_125C_5v50.lib"
  "$PDK_REL/.config/nodeinfo.json"
)

missing=()
[ -s "$DEF" ] || missing+=("$DEF")
[ -s "$SPEF" ] || missing+=("$SPEF")
[ -s "$TCL" ] || missing+=("$TCL")
[ -s "$POWER_TCL" ] || missing+=("$POWER_TCL")
[ -s "$PDK_MANIFEST" ] || missing+=("$PDK_MANIFEST")
command -v openroad >/dev/null 2>&1 || missing+=("openroad")
command -v sha256sum >/dev/null 2>&1 || missing+=("sha256sum")

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

pdk_preflight_fail() {
  local reason="$1"
  {
    echo "gate=G4"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=STA/power lead (unassigned)"
    echo "pdk_manifest=$PDK_MANIFEST"
    echo "pdk_hashes=FAIL"
    echo "reason=$reason"
    echo "log=$STA/g4_pdk_sha256.log"
    echo "note=PDK input verification failed; no G4 timing or power run was started."
  } | tee "$STA/G4_status.txt"
  if [ -f "$STA/g4_pdk_sha256.log" ]; then
    cat "$STA/g4_pdk_sha256.log"
  fi
  exit 2
}

if ! (cd "$PROJECT_ROOT" && sha256sum --strict -c "$PDK_MANIFEST" > "$STA/g4_pdk_sha256.log" 2>&1); then
  pdk_preflight_fail "checksum_or_format"
fi

actual_pdk_paths="$(
  awk '{
    path=$2
    sub(/^\*/, "", path)
    print path
  }' "$PDK_MANIFEST" | LC_ALL=C sort
)"
expected_pdk_paths="$(printf '%s\n' "${PDK_EXPECTED[@]}" | LC_ALL=C sort)"
if [ "$actual_pdk_paths" != "$expected_pdk_paths" ]; then
  {
    echo "manifest_paths=FAIL"
    echo "expected_entries=${#PDK_EXPECTED[@]}"
    echo "manifest_entries=$(printf '%s\n' "$actual_pdk_paths" | sed '/^$/d' | wc -l)"
    echo "note=PDK manifest entries do not match the eight expected paths"
  } >> "$STA/g4_pdk_sha256.log"
  pdk_preflight_fail "manifest_paths"
fi

set +e
for corner in ss_n40C_4v50 ss_125C_4v50 tt_025C_5v00 ff_n40C_5v50 ff_125C_5v50; do
  CORNER="$corner" DEF="$DEF" SPEF="$SPEF" openroad -exit "$TCL" \
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
DEF="$DEF" SPEF="$SPEF" openroad -exit "$POWER_TCL" > "$STA/power_ir.log" 2>&1
power_rc=$?
set -e

{
  echo "gate=G4"
  if [ "$power_rc" -eq 0 ]; then echo "status=RAN_REVIEW_REQUIRED"; else echo "status=FAILED"; fi
  echo "power_exit_code=$power_rc"
  echo "pdk_hashes=PASS"
  echo "pdk_manifest=$PDK_MANIFEST"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "corners=ss_n40C_4v50,ss_125C_4v50,tt_025C_5v00,ff_n40C_5v50,ff_125C_5v50"
  echo "note=RUN_REVIEW_REQUIRED is not a timing/power signoff; WNS/TNS/WHS, IR/EM, crosstalk and thermal must be reviewed and signed."
} > "$STA/G4_status.txt"

cat "$STA/G4_status.txt"
exit "$power_rc"
