#!/bin/sh
# Build the ZN route from the accepted fix59 base.
# The default output is fix71: it keeps the clean fix35 LVS topology,
# trims/widens the ZN island, applies only the approved 60 dbu local M2
# notch, and removes the ZN M3/M4/V3/V4 DRC violations. The selected fix70
# route additionally requires calling connect_zn_to_b.py with
# --with-extension.
# Usage: ./build_connect.sh [input.gds] [output.gds] [report.json]
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
REL=${HERE#"$ROOT"/}
DOCKER_WORK="/work/$REL"
IMAGE=ghcr.io/efabless/openlane2:2.3.10
INPUT=${1:-"$DOCKER_WORK/rebased_tap_stream_out_filled_stitched_fix59.gds"}
OUTPUT=${2:-"$DOCKER_WORK/rebased_tap_stream_out_filled_stitched_fix71.gds"}
REPORT=${3:-"$DOCKER_WORK/fix71_report.json"}
run_py() { docker run --rm -v "$ROOT:/work" -w "$DOCKER_WORK" --entrypoint python3 "$IMAGE" "$@"; }
run_py "$DOCKER_WORK/probe/connect_zn_to_b.py" --gds "$INPUT" --check-only
run_py "$DOCKER_WORK/probe/connect_zn_to_b.py" --gds "$INPUT" --out "$OUTPUT" --report "$REPORT"
