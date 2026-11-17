#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$ROOT/build/production"
G0_STATUS="$PROD/manifests/G0_status.txt"
G0_SIGNOFF="$PROD/manifests/G0_signoff.txt"
G0_MANIFEST="$PROD/manifests/input_sha256.txt"
GDS="$PROD/final/grx930_test_chip_final.gds"
SPEF="$PROD/final/grx930_test_chip.spef"
G2="$PROD/run/g2_lvs.sh"
STATUS="$PROD/lvs/G2_status.txt"
LOG="$PROD/lvs/lvs.log"
REPORT="$PROD/lvs/report.lvsdb"
EXTRACTED="$PROD/lvs/extracted.cir"

[ -s "$G0_STATUS" ] || { echo "SKIP: no G0 status to back up"; exit 3; }
[ ! -e "$GDS" ] || { echo "SKIP: refusing to overwrite existing GDS"; exit 3; }
[ ! -e "$SPEF" ] || { echo "SKIP: refusing to overwrite existing SPEF"; exit 3; }
[ ! -e "$G0_SIGNOFF" ] || { echo "SKIP: refusing to overwrite existing signoff"; exit 3; }
for artifact in "$LOG" "$REPORT" "$EXTRACTED"; do
  [ ! -e "$artifact" ] || { echo "SKIP: refusing to remove existing $artifact"; exit 3; }
done

backup="$(mktemp)"
cp "$G0_STATUS" "$backup"
cleanup() {
  rm -f "$GDS" "$SPEF" "$G0_SIGNOFF"
  cp "$backup" "$G0_STATUS"
  rm -f "$backup"
}
trap cleanup EXIT

printf 'placeholder GDS\n' > "$GDS"
printf 'placeholder SPEF\n' > "$SPEF"
g0_hash=$(sha256sum "$G0_MANIFEST" | awk '{print $1}')
cat > "$G0_STATUS" <<EOF
gate=G0
status=READY_FOR_REVIEW
gds_checks=PASS
no_void=PASS
manifest_sha256=$g0_hash
EOF

run_case() {
  local label="$1"
  local signoff="$2"
  printf '%s\n' "$signoff" > "$G0_SIGNOFF"
  set +e
  bash "$G2" >/dev/null 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 2 ] || { echo "FAIL: $label exit $rc"; exit 1; }
  grep -q 'gate=not-G0' "$STATUS" || { echo "FAIL: $label did not report gate=not-G0"; exit 1; }
  [ ! -e "$LOG" ] && [ ! -e "$REPORT" ] && [ ! -e "$EXTRACTED" ] || {
    echo "FAIL: $label reached Docker"; exit 1; }
  echo "PASS: $label blocked before Docker"
}

run_case "misspelled gate" "$(cat <<EOF
gate=G00
status=SIGNED
signed_by=Test Signer
signed_utc=2026-11-17T00:00:00Z
manifest_sha256=$g0_hash
EOF
)"

run_case "missing gate" "$(cat <<EOF
status=SIGNED
signed_by=Test Signer
signed_utc=2026-11-17T00:00:00Z
manifest_sha256=$g0_hash
EOF
)"
