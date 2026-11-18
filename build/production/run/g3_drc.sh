#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
FINAL="$PROD/final"
DRC="$PROD/drc"

mkdir -p "$DRC" "$PROD/logs"

GDS="$FINAL/grx930_test_chip_final.gds"
DECK="$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc"
IMAGE="ghcr.io/efabless/openlane2:2.3.10"

if [ ! -s "$GDS" ] || [ ! -s "$DECK" ]; then
  {
    echo "gate=G3"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=Physical verification lead (unassigned)"
    [ -s "$GDS" ] || echo "missing=$GDS"
    [ -s "$DECK" ] || echo "missing=$DECK"
    echo "note=Full-deck DRC not run."
  } | tee "$DRC/G3_status.txt"
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
  -r /work/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc \
  -rd input=/work/build/production/final/grx930_test_chip_final.gds \
  -rd report=/work/build/production/drc/all_decks.lyrdb \
  -rd topcell=grx930_test_chip \
  -rd variant=gf180mcuD \
  -rd metal_level=5LM \
  -rd run_mode=deep \
  -rd threads=8 \
  -rd decks=all \
  > "$DRC/all_decks.log" 2>&1
rc=$?
set -e

{
  echo "gate=G3"
  if [ "$rc" -eq 0 ]; then echo "status=RAN_REVIEW_REQUIRED"; else echo "status=FAILED"; fi
  echo "exit_code=$rc"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "log=$DRC/all_decks.log"
  echo "report=$DRC/all_decks.lyrdb"
  echo "note=A run exit code is not a clean-DRC verdict; zero unwaived findings and owner signature are required."
} > "$DRC/G3_status.txt"

cat "$DRC/G3_status.txt"
exit "$rc"
