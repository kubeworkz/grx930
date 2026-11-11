#!/bin/sh
# Build fix19: remove only the bottom _083692_ via1 that lands on the M1 VSS
# rail.  fix18 and all earlier artifacts are left untouched.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INPUT="$HERE/rebased_tap_stream_out_filled_stitched_fix18.gds"
EDITED="$HERE/rebased_tap_stream_out_filled_stitched_fix19.gds"
REPORT="$HERE/fix19_vss_v1_report.json"
TILE="$HERE/fix19_target_tile_y1398.gds"
TILE_JSON="$HERE/fix19_target_tile_y1398.json"

python3 "$HERE/probe/fix19_cut_083692_vss_v1.py" \
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
