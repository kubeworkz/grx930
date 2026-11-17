#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
FINAL="$PROD/final"
LVS="$PROD/lvs"

mkdir -p "$LVS" "$PROD/logs"

GDS="$FINAL/grx930_test_chip_final.gds"
SPEF="$FINAL/grx930_test_chip.spef"
CDL="$PROJECT_ROOT/c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl"
DECK="$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs"
IMAGE="${KLAYOUT_IMAGE:-grx930/klayout-lvs-pmap:local}"

if [ ! -s "$GDS" ] || [ ! -s "$SPEF" ] || [ ! -s "$CDL" ] || [ ! -s "$DECK" ]; then
  {
    echo "gate=G2"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=Physical verification lead (unassigned)"
    [ -s "$GDS" ] || echo "missing=$GDS"
    [ -s "$SPEF" ] || echo "missing=$SPEF"
    [ -s "$CDL" ] || echo "missing=$CDL"
    [ -s "$DECK" ] || echo "missing=$DECK"
    echo "note=Full-chip LVS not run; G0 frozen inputs are incomplete. SPEF is a G0 gate input, not an LVS deck input."
  } | tee "$LVS/G2_status.txt"
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "gate=G2" > "$LVS/G2_status.txt"
  echo "status=BLOCKED" >> "$LVS/G2_status.txt"
  echo "missing=docker" >> "$LVS/G2_status.txt"
  exit 2
fi

# The unmodified deck calls pmap. The local image adds a pmap-compatible
# diagnostic shim; verify the image and command before starting the deck.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  {
    echo "gate=G2"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=Physical verification lead (unassigned)"
    echo "missing=local image $IMAGE"
    echo "note=Build it with: docker build -t $IMAGE -f build/production/run/Dockerfile.klayout-lvs build/production/run"
  } | tee "$LVS/G2_status.txt"
  exit 2
fi
if ! docker run --rm --entrypoint sh "$IMAGE" -lc 'command -v pmap >/dev/null' >/dev/null 2>&1; then
  {
    echo "gate=G2"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=Physical verification lead (unassigned)"
    echo "missing=pmap in $IMAGE"
    echo "note=Unmodified LVS deck requires pmap; no LVS run was started."
  } | tee "$LVS/G2_status.txt"
  exit 2
fi

HOST_ROOT="$PROJECT_ROOT"
if command -v cygpath >/dev/null 2>&1; then
  HOST_ROOT="$(cygpath -m "$PROJECT_ROOT")"
fi

set +e
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$HOST_ROOT:/work" -w /work \
  --entrypoint klayout "$IMAGE" -b \
  -r /work/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs \
  -rd combine=false \
  -rd check_ports=false \
  -rd top_lvl_pins=true \
  -rd run_mode=tiling \
  -rd verbose=false \
  -rd metal_level=5LM \
  -rd input=/work/build/production/final/grx930_test_chip_final.gds \
  -rd schematic=/work/c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl \
  -rd topcell=grx930_test_chip \
  -rd report=/work/build/production/lvs/report.lvsdb \
  -rd target_netlist=/work/build/production/lvs/extracted.cir \
  > "$LVS/lvs.log" 2>&1
rc=$?
set -e

{
  echo "gate=G2"
  if [ "$rc" -eq 0 ]; then echo "status=RAN_REVIEW_REQUIRED"; else echo "status=FAILED"; fi
  echo "exit_code=$rc"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "log=$LVS/lvs.log"
  echo "report=$LVS/report.lvsdb"
  echo "extracted=$LVS/extracted.cir"
  echo "note=A run exit code is not a signoff verdict; the LVS report and owner signature are required."
} > "$LVS/G2_status.txt"

cat "$LVS/G2_status.txt"
exit "$rc"
