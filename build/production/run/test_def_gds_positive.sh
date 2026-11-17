#!/usr/bin/env bash
# Positive control for def_gds_checks.rb: a synthetic DEF/GDS pair with matching
# Metal1-Metal5 geometry and all 8,168 approved 2x2 ECO vias must return zero
# XOR and the exact via counts. The negative control remains the audit DEF
# against the fix16 GDS, which must fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIX="$ROOT/build/production/fixtures/def_gds_positive"
REPORT="$FIX/def_gds_checks.positive.txt"
IMAGE="${KLAYOUT_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker unavailable"
  exit 3
fi

mkdir -p "$FIX"
HOST_ROOT="$ROOT"
if command -v cygpath >/dev/null 2>&1; then
  HOST_ROOT="$(cygpath -m "$ROOT")"
fi

MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$HOST_ROOT:/work" -w /work \
  --entrypoint klayout "$IMAGE" -b \
  -r /work/build/production/run/make_def_gds_positive_fixture.rb \
  -rd out_dir=/work/build/production/fixtures/def_gds_positive \
  > "$FIX/make_fixture.log" 2>&1

set +e
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$HOST_ROOT:/work" -w /work \
  --entrypoint klayout "$IMAGE" -b \
  -r /work/build/production/run/def_gds_checks.rb \
  -rd gds=/work/build/production/fixtures/def_gds_positive/positive.gds \
  -rd def=/work/build/production/fixtures/def_gds_positive/positive.def \
  -rd topcell=grx930_test_chip \
  -rd expected_drops=8168 \
  -rd report=/work/build/production/fixtures/def_gds_positive/def_gds_checks.positive.txt \
  > "$FIX/def_gds_checks.positive.log" 2>&1
rc=$?
set -e

[ -s "$REPORT" ] || { echo "FAIL: checker wrote no report (exit $rc)"; cat "$FIX/def_gds_checks.positive.log"; exit 1; }
cat "$REPORT"
[ "$rc" -eq 0 ] || { echo "FAIL: checker exited $rc on a matching pair"; exit 1; }

fail=0
for metal in Metal1 Metal2 Metal3 Metal4 Metal5; do
  grep -qx "XOR_${metal}_DBU2=0" "$REPORT" || { echo "FAIL: XOR_${metal}_DBU2 is not zero"; fail=1; }
done
grep -qx 'ECO_Via1_2X2_0_60_10_60_H_V=8168' "$REPORT" || { echo "FAIL: Via1 2x2 count is not 8168"; fail=1; }
grep -qx 'ECO_Via2_2X2_0_60_10_60_V_H=8168' "$REPORT" || { echo "FAIL: Via2 2x2 count is not 8168"; fail=1; }
grep -qx 'EXPECTED_DROPS=8168' "$REPORT" || { echo "FAIL: expected drop count is not 8168"; fail=1; }
grep -qx 'ROW300_Via2_2X2_0_60_10_60_V_H=0' "$REPORT" || { echo "FAIL: row-300 Via2 count is not zero"; fail=1; }
grep -qx 'FAILURES=' "$REPORT" || { echo "FAIL: report lists failures"; fail=1; }
[ "$fail" -eq 0 ] || exit 1

echo "PASS: matching DEF/GDS XOR is zero and all 8,168 2x2 ECO vias are found"
