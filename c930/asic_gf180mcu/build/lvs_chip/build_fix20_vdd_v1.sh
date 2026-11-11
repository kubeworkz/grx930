#!/bin/sh
# Build fix20: remove only the final _076858_ VDD via1.
# fix19 and all earlier artifacts are left untouched.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INPUT="$HERE/rebased_tap_stream_out_filled_stitched_fix19.gds"
EDITED="$HERE/rebased_tap_stream_out_filled_stitched_fix20.gds"
REPORT="$HERE/fix20_vdd_v1_report.json"
TILE="$HERE/fix20_target_tile_y1398.gds"
TILE_JSON="$HERE/fix20_target_tile_y1398.json"

python3 "$HERE/probe/fix20_cut_076858_vdd_v1.py" \
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
