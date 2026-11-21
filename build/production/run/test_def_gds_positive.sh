#!/usr/bin/env bash
# Controls for def_gds_checks.rb. The full-chip positive is a synthetic DEF/GDS
# pair with matching Metal1-Metal5 geometry, 8,168 approved 2x2 ECO vias, and
# the matching Via1/Via2 cut arrays on GDS 35/0 and 38/0; it must return zero
# XOR and the exact via counts. The windowed positive feeds a base pair and the
# 8,168-site window list, and must report one clean, non-empty window per site
# with no delta outside them. Two negatives must fail: a GDS that omits two cut
# arrays, and the windowed pair with site 0 moved +5 um. The row-300 exclusion
# box is retired with the old floorplan, so no row-300 fixture is generated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIX="$ROOT/build/production/fixtures/def_gds_positive"
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
  local gds="$1" def="$2" report="$3" log="$4"
  shift 4
  set +e
  MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$HOST_ROOT:/work" -w /work \
    --entrypoint klayout "$IMAGE" -b \
    -r /work/build/production/run/def_gds_checks.rb \
    -rd "gds=$gds" \
    -rd "def=$def" \
    -rd topcell=grx930_test_chip \
    -rd expected_drops=8168 \
    -rd "report=$report" \
    "$@" \
    > "$log" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

FIXW=/work/build/production/fixtures/def_gds_positive
POS_REPORT="$FIX/def_gds_checks.positive.txt"
pos_rc=$(run_checker "$FIXW/positive.gds" "$FIXW/positive.def" \
  "$FIXW/def_gds_checks.positive.txt" "$FIX/def_gds_checks.positive.log")
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
grep -qx 'FAILURES=' "$POS_REPORT" || { echo "FAIL: report lists failures"; fail=1; }
[ "$fail" -eq 0 ] || exit 1

# Windowed path: (final - base) must equal the DEF delta inside every site
# window, and nothing new may lie outside the 8,168 windows.
WIN_REPORT="$FIX/def_gds_checks.windowed.txt"
win_rc=$(run_checker "$FIXW/windowed_final.gds" "$FIXW/windowed_final.def" \
  "$FIXW/def_gds_checks.windowed.txt" "$FIX/def_gds_checks.windowed.log" \
  -rd "base=$FIXW/windowed_base.gds" \
  -rd "base_def=$FIXW/windowed_base.def" \
  -rd "sites=$FIXW/windowed_sites.csv")
[ -s "$WIN_REPORT" ] || { echo "FAIL: windowed run wrote no report (exit $win_rc)"; cat "$FIX/def_gds_checks.windowed.log"; exit 1; }
echo "--- windowed positive control ---"
grep -E '^(WINDOWS|WINDOWS_WITH_DELTA|WINDOW_FAILURES|FAILURES)=' "$WIN_REPORT"
[ "$win_rc" -eq 0 ] || { echo "FAIL: checker exited $win_rc on a clean windowed pair"; exit 1; }
grep -qx 'WINDOWS=8168' "$WIN_REPORT" || { echo "FAIL: windowed run did not report 8,168 windows"; exit 1; }
grep -qx 'WINDOWS_WITH_DELTA=8168' "$WIN_REPORT" || { echo "FAIL: some window has no new geometry"; exit 1; }
grep -qx 'WINDOW_FAILURES=0' "$WIN_REPORT" || { echo "FAIL: windowed run reports failed windows"; exit 1; }
pass_windows=$(grep -c '^WINDOW .* PASS$' "$WIN_REPORT" || true)
[ "$pass_windows" -eq 8168 ] || { echo "FAIL: $pass_windows windows passed, expected 8,168"; exit 1; }
for metal in Metal1 Metal2 Metal3 Metal4 Metal5; do
  grep -qx "XOR_${metal}_DBU2=0" "$WIN_REPORT" || { echo "FAIL: windowed XOR_${metal}_DBU2 is not zero"; exit 1; }
  grep -qx "OUTSIDE_WINDOWS_${metal}_DBU2=0" "$WIN_REPORT" || { echo "FAIL: ${metal} GDS delta outside the windows"; exit 1; }
  grep -qx "OUTSIDE_WINDOWS_DEF_${metal}_DBU2=0" "$WIN_REPORT" || { echo "FAIL: ${metal} DEF delta outside the windows"; exit 1; }
done
for via in "$V1" "$V2"; do
  grep -qx "GDS_${via}_CUTS=$CUTS" "$WIN_REPORT" || { echo "FAIL: windowed GDS ${via} cut count is not $CUTS"; exit 1; }
  grep -qx "XOR_${via}_CUT_DBU2=0" "$WIN_REPORT" || { echo "FAIL: windowed XOR_${via}_CUT_DBU2 is not zero"; exit 1; }
done
for short in Via1_2X2 Via2_2X2; do
  grep -qx "OUTSIDE_WINDOWS_${short}_CUT_DBU2=0" "$WIN_REPORT" || { echo "FAIL: ${short} cuts outside the windows"; exit 1; }
done
grep -qx 'FAILURES=' "$WIN_REPORT" || { echo "FAIL: windowed report lists failures"; exit 1; }
echo "PASS: 8,168/8,168 windows clean and no delta outside them"

# Shifted-site negative: one window moves +5 um, so that site's new geometry
# lies outside every window and the run must fail.
SFT_REPORT="$FIX/def_gds_checks.windowed_shift.txt"
sft_rc=$(run_checker "$FIXW/windowed_final.gds" "$FIXW/windowed_final.def" \
  "$FIXW/def_gds_checks.windowed_shift.txt" "$FIX/def_gds_checks.windowed_shift.log" \
  -rd "base=$FIXW/windowed_base.gds" \
  -rd "base_def=$FIXW/windowed_base.def" \
  -rd "sites=$FIXW/windowed_sites_shift.csv")
[ -s "$SFT_REPORT" ] || { echo "FAIL: shifted-site run wrote no report (exit $sft_rc)"; cat "$FIX/def_gds_checks.windowed_shift.log"; exit 1; }
echo "--- windowed shifted-site control ---"
grep -E '^(WINDOWS|WINDOWS_WITH_DELTA|WINDOW_FAILURES|FAILURES)=' "$SFT_REPORT"
grep '^WINDOW .* FAIL$' "$SFT_REPORT" || true
[ "$sft_rc" -ne 0 ] || { echo "FAIL: checker accepted a window list shifted off the geometry"; exit 1; }
grep -qx 'WINDOWS=8168' "$SFT_REPORT" || { echo "FAIL: shifted run lost windows"; exit 1; }
grep -qx 'WINDOWS_WITH_DELTA=8167' "$SFT_REPORT" || { echo "FAIL: the moved window was not reported empty"; exit 1; }
grep -qx 'WINDOW_FAILURES=1' "$SFT_REPORT" || { echo "FAIL: expected exactly one failed window"; exit 1; }
for metal in Metal1 Metal2 Metal3; do
  area=$(sed -n "s/^OUTSIDE_WINDOWS_${metal}_DBU2=//p" "$SFT_REPORT" | tail -1)
  def_area=$(sed -n "s/^OUTSIDE_WINDOWS_DEF_${metal}_DBU2=//p" "$SFT_REPORT" | tail -1)
  [ -n "$area" ] && [ "$area" -gt 0 ] || { echo "FAIL: ${metal} delta outside the windows was not detected"; exit 1; }
  [ "$def_area" = "$area" ] || { echo "FAIL: ${metal} GDS and DEF disagree outside the windows ($area vs $def_area)"; exit 1; }
done
for short in Via1_2X2 Via2_2X2; do
  area=$(sed -n "s/^OUTSIDE_WINDOWS_${short}_CUT_DBU2=//p" "$SFT_REPORT" | tail -1)
  [ -n "$area" ] && [ "$area" -gt 0 ] || { echo "FAIL: ${short} cuts outside the windows were not detected"; exit 1; }
done
echo "PASS: the shifted window list fails with one empty window and outside geometry"

MIS_REPORT="$FIX/def_gds_checks.mismatch.txt"
mis_rc=$(run_checker "$FIXW/positive_missing_cuts.gds" "$FIXW/positive.def" \
  "$FIXW/def_gds_checks.mismatch.txt" "$FIX/def_gds_checks.mismatch.log")
[ -s "$MIS_REPORT" ] || { echo "FAIL: mismatch run wrote no report (exit $mis_rc)"; exit 1; }
echo "--- missing-cut control ---"
cat "$MIS_REPORT"
[ "$mis_rc" -ne 0 ] || { echo "FAIL: checker accepted a GDS with missing cut arrays"; exit 1; }
for via in "$V1" "$V2"; do
  area=$(sed -n "s/^XOR_${via}_CUT_DBU2=//p" "$MIS_REPORT" | tail -1)
  [ -n "$area" ] && [ "$area" -gt 0 ] || { echo "FAIL: missing ${via} cuts were not detected"; exit 1; }
done

echo "PASS: matching pair is clean; the windowed pair is clean; the shifted-site and missing-cut pairs fail"
