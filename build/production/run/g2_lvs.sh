#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
FINAL="$PROD/final"
LVS="$PROD/lvs"
MAN="$PROD/manifests"

mkdir -p "$LVS" "$PROD/logs"

block_g2() {
  local note="$1"
  shift
  {
    echo "gate=G2"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=Physical verification lead (unassigned)"
    for line in "$@"; do echo "$line"; done
    echo "note=$note"
  } | tee "$LVS/G2_status.txt"
  exit 2
}

GDS="$FINAL/grx930_test_chip_final.gds"
SPEF="$FINAL/grx930_test_chip.spef"
CDL="$PROJECT_ROOT/c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl"
DEF="$PROJECT_ROOT/build/lvs_chip/eco_drop_2x2/stage6/eco_routed.def"
DECK="$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs"
IMAGE="${KLAYOUT_IMAGE:-grx930/klayout-lvs-pmap:local}"

if [ ! -s "$GDS" ] || [ ! -s "$SPEF" ] || [ ! -s "$CDL" ] || [ ! -s "$DEF" ] || [ ! -s "$DECK" ]; then
  {
    echo "gate=G2"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=Physical verification lead (unassigned)"
    [ -s "$GDS" ] || echo "missing=$GDS"
    [ -s "$SPEF" ] || echo "missing=$SPEF"
    [ -s "$CDL" ] || echo "missing=$CDL"
    [ -s "$DEF" ] || echo "missing=$DEF"
    [ -s "$DECK" ] || echo "missing=$DECK"
    echo "note=Full-chip LVS not run; G0 frozen inputs are incomplete. SPEF is a G0 gate input, not an LVS deck input."
  } | tee "$LVS/G2_status.txt"
  exit 2
fi

G0_STATUS="$MAN/G0_status.txt"
G0_SIGNOFF="$MAN/G0_signoff.txt"
G0_MANIFEST="$MAN/input_sha256.txt"

[ -s "$G0_STATUS" ] || block_g2 "G0 status is missing; no LVS run was started." "missing=$G0_STATUS"
[ -s "$G0_MANIFEST" ] || block_g2 "G0 manifest is missing; no LVS run was started." "missing=$G0_MANIFEST"

g0_state=$(grep '^status=' "$G0_STATUS" | tail -1 | cut -d= -f2-)
[ "$g0_state" = "READY_FOR_REVIEW" ] || block_g2 "G0 is not READY; no LVS run was started." "g0_status=$g0_state"
grep -qx 'gds_checks=PASS' "$G0_STATUS" || block_g2 "G0 GDS identity/ECO checks did not pass; no LVS run was started." "gds_checks=not-pass"
grep -qx 'def_gds_checks=PASS' "$G0_STATUS" || block_g2 "G0 DEF/GDS routed-geometry or ECO check did not pass; no LVS run was started." "def_gds_checks=not-pass"
grep -qx 'no_void=PASS' "$G0_STATUS" || block_g2 "G0 no-VOID check did not pass; no LVS run was started." "no_void=not-pass"

g0_hash=$(sha256sum "$G0_MANIFEST" | awk '{print $1}')
status_hash=$(grep '^manifest_sha256=' "$G0_STATUS" | tail -1 | cut -d= -f2-)
[ "$g0_hash" = "$status_hash" ] || block_g2 "G0 status does not match the current manifest; no LVS run was started." "manifest_sha256_mismatch=status"

[ -s "$G0_SIGNOFF" ] || block_g2 "G0 is not signed; no LVS run was started." "missing=$G0_SIGNOFF"
grep -qx 'gate=G0' "$G0_SIGNOFF" || block_g2 "G0 signoff has no exact gate=G0 line; no LVS run was started." "gate=not-G0"
signed_status=$(grep '^status=' "$G0_SIGNOFF" | tail -1 | cut -d= -f2-)
signed_by=$(grep '^signed_by=' "$G0_SIGNOFF" | tail -1 | cut -d= -f2-)
signed_utc=$(grep '^signed_utc=' "$G0_SIGNOFF" | tail -1 | cut -d= -f2-)
signed_hash=$(grep '^manifest_sha256=' "$G0_SIGNOFF" | tail -1 | cut -d= -f2-)
[ "$signed_status" = "SIGNED" ] || block_g2 "G0 signoff is not SIGNED; no LVS run was started." "g0_signoff=$signed_status"
[ -n "$signed_by" ] || block_g2 "G0 signoff has no signer; no LVS run was started." "signed_by=empty"
case "$signed_by" in
  *Gridworkz*) ;;
  *) block_g2 "G0 signoff is not from a Gridworkz signatory; no LVS run was started." "signed_by=not-Gridworkz" ;;
esac
[ -n "$signed_utc" ] || block_g2 "G0 signoff has no timestamp; no LVS run was started." "signed_utc=empty"
[ "$g0_hash" = "$signed_hash" ] || block_g2 "G0 signoff does not match the current manifest; no LVS run was started." "manifest_sha256_mismatch=signoff"

for f in "$GDS" "$SPEF" "$CDL" "$DEF"; do
  actual=$(sha256sum "$f" | awk '{print $1}')
  # sha256sum on this host prefixes the path field with '*' (binary marker).
  expected=$(awk -v target="$f" '{ path=$2; sub(/^\*/, "", path); if (path == target) {print $1; exit} }' "$G0_MANIFEST")
  [ -n "$expected" ] || block_g2 "G0 manifest has no hash for a frozen input; no LVS run was started." "missing_manifest_hash=$f"
  [ "$actual" = "$expected" ] || block_g2 "A frozen input changed after G0; no LVS run was started." "manifest_hash_mismatch=$f"
done

if ! command -v docker >/dev/null 2>&1; then
  echo "gate=G2" > "$LVS/G2_status.txt"
  echo "status=BLOCKED" >> "$LVS/G2_status.txt"
  echo "missing=docker" >> "$LVS/G2_status.txt"
  exit 2
fi

# The unmodified deck calls pmap. The local image adds a pmap-compatible
# diagnostic shim. This single probe covers both image availability and pmap.
if ! docker run --rm --entrypoint sh "$IMAGE" -lc 'command -v pmap >/dev/null' >/dev/null 2>&1; then
  {
    echo "gate=G2"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=Physical verification lead (unassigned)"
    echo "missing=pmap-capable image $IMAGE"
    echo "note=Build it with: docker build -t $IMAGE -f build/production/run/Dockerfile.klayout-lvs build/production/run"
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
