#!/usr/bin/env bash
# Positive control for def_gds_checks.rb: a synthetic DEF/GDS pair with matching
# Metal1-Metal5 geometry, all 8,168 approved 2x2 ECO vias, and the matching
# Via1/Via2 cut arrays on GDS 35/0 and 38/0 must return zero XOR and the exact
# via counts. A second GDS with two cut arrays removed must fail the cut check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIX="$ROOT/build/production/fixtures/def_gds_positive"
POS_GDS="$FIX/positive.gds"
MIS_GDS="$FIX/positive_missing_cuts.gds"
POS_REPORT="$FIX/def_gds_checks.positive.txt"
MIS_REPORT="$FIX/def_gds_checks.mismatch.txt"
IMAGE="${KLAYOUT_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}"
V1="Via1_2X2_0_60_10_60_H_V"
V2="Via2_2X2_0_60_10_60_V_H"
CUTS=32672 # 4 cuts x 8,168 drops

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

run_checker() {
  local gds="$1" report="$2" log="$3"
  set +e
  MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$HOST_ROOT:/work" -w /work \
    --entrypoint klayout "$IMAGE" -b \
    -r /work/build/production/run/def_gds_checks.rb \
    -rd "gds=$gds" \
    -rd def=/work/build/production/fixtures/def_gds_positive/positive.def \
    -rd topcell=grx930_test_chip \
    -rd expected_drops=8168 \
    -rd "report=$report" \
    > "$log" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

pos_rc=$(run_checker \
  /work/build/production/fixtures/def_gds_positive/positive.gds \
  /work/build/production/fixtures/def_gds_positive/def_gds_checks.positive.txt \
  "$FIX/def_gds_checks.positive.log")
[ -s "$POS_REPORT" ] || { echo "FAIL: checker wrote no report (exit $pos_rc)"; cat "$FIX/def_gds_checks.positive.log"; exit 1; }
cat "$POS_REPORT"
[ "$pos_rc" -eq 0 ] || { echo "FAIL: checker exited $pos_rc on a matching pair"; exit 1; }

fail=0
for metal in Metal1 Metal2 Metal3 Metal4 Metal5; do
  grep -qx "XOR_${metal}_DBU2=0" "$POS_REPORT" || { echo "FAIL: XOR_${metal}_DBU2 is not zero"; fail=1; }
done
for via in "$V1" "$V2"; do
  grep -qx "ECO_${via}=8168" "$POS_REPORT" || { echo "FAIL: ${via} count is not 8168"; fail=1; }
  grep -qx "GDS_${via}_CUTS=$CUTS" "$POS_REPORT" || { echo "FAIL: GDS ${via} cut count is not $CUTS"; fail=1; }
  grep -qx "XOR_${via}_CUT_DBU2=0" "$POS_REPORT" || { echo "FAIL: XOR_${via}_CUT_DBU2 is not zero"; fail=1; }
done
grep -qx 'EXPECTED_DROPS=8168' "$POS_REPORT" || { echo "FAIL: expected drop count is not 8168"; fail=1; }
grep -qx "ROW300_${V2}=0" "$POS_REPORT" || { echo "FAIL: row-300 Via2 count is not zero"; fail=1; }
grep -qx 'FAILURES=' "$POS_REPORT" || { echo "FAIL: report lists failures"; fail=1; }
[ "$fail" -eq 0 ] || exit 1

mis_rc=$(run_checker \
  /work/build/production/fixtures/def_gds_positive/positive_missing_cuts.gds \
  /work/build/production/fixtures/def_gds_positive/def_gds_checks.mismatch.txt \
  "$FIX/def_gds_checks.mismatch.log")
[ -s "$MIS_REPORT" ] || { echo "FAIL: mismatch run wrote no report (exit $mis_rc)"; exit 1; }
echo "--- missing-cut control ---"
cat "$MIS_REPORT"
[ "$mis_rc" -ne 0 ] || { echo "FAIL: checker accepted a GDS with missing cut arrays"; exit 1; }
for via in "$V1" "$V2"; do
  area=$(sed -n "s/^XOR_${via}_CUT_DBU2=//p" "$MIS_REPORT" | tail -1)
  [ -n "$area" ] && [ "$area" -gt 0 ] || { echo "FAIL: missing ${via} cuts were not detected"; exit 1; }
done

echo "PASS: matching DEF/GDS XOR is zero, all 8,168 2x2 ECO vias have their GDS cuts, and a missing cut array is detected"
