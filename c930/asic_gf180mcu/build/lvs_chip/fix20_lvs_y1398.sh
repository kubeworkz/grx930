#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPORT_DIR="$HERE/fix20_tile_b12300_y1398"
mkdir -p "$REPORT_DIR"

export LVS_INPUT="$HERE/fix20_target_tile_y1398.gds"
export LVS_REPORT="$REPORT_DIR/report.lvsdb"
exec "$HERE/fix16_lvs.sh"
