#!/bin/sh
# Build fix21: add the missing V4 at the A2/_076858_ M4-M5 crossing.
# fix20 and all earlier artifacts are left untouched.  LVS is not run here.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INPUT="$HERE/rebased_tap_stream_out_filled_stitched_fix20.gds"
EDITED="$HERE/rebased_tap_stream_out_filled_stitched_fix21.gds"
REPORT="$HERE/fix21_v4_bridge_report.json"
TILE="$HERE/fix21_target_tile_y1398.gds"
TILE_JSON="$HERE/fix21_target_tile_y1398.json"

python3 "$HERE/probe/fix21_add_a2_v4.py" \
  --gds "$INPUT" \
  --out "$EDITED" \
  --report "$REPORT" \
  --topcell grx930_test_chip

python3 "$HERE/probe/crop_hier_top.py" \
  --gds "$EDITED" \
  --out "$TILE" \
  --json "$TILE_JSON" \
  --topcell grx930_test_chip \
  --box-um 1600 1398 3050 3100
