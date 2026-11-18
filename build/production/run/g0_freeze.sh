#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
FINAL="$PROD/final"
MAN="$PROD/manifests"

mkdir -p "$FINAL" "$MAN" "$PROD/dft" "$PROD/lvs" "$PROD/drc" "$PROD/sta" "$PROD/foundry" "$PROD/logs"

# Exact plan inputs: the rebased CDL/DEF are used in place; no copies are
# accepted as substitutes. The final GDS and extracted SPEF are the frozen
# production artifacts.
GDS="$FINAL/grx930_test_chip_final.gds"
CDL="$PROJECT_ROOT/c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl"
DEF="$PROJECT_ROOT/build/lvs_chip/rebased_grx930_test_chip.def"
SPEF="$FINAL/grx930_test_chip.spef"
BASE="$PROJECT_ROOT/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds"
CHECK="$PROJECT_ROOT/build/production/run/gds_checks.rb"
DEF_CHECK="$PROJECT_ROOT/build/production/run/def_gds_checks.rb"

required=("$GDS" "$CDL" "$DEF" "$SPEF" "$BASE" "$CHECK" "$DEF_CHECK")

deck_files=(
  "$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc"
  "$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs"
  "$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/metal.rb"
  "$PROJECT_ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/via.rb"
)

missing=()
: > "$MAN/input_sha256.txt"
for f in "${required[@]}" "${deck_files[@]}"; do
  if [ -s "$f" ]; then
    sha256sum "$f" >> "$MAN/input_sha256.txt"
  else
    printf 'MISSING %s\n' "$f" >> "$MAN/input_sha256.txt"
    missing+=("$f")
  fi
done

failures=()
no_void="NOT_RUN"
gds_checks="NOT_RUN"
def_gds_checks="NOT_RUN"

if [ -s "$GDS" ]; then
  final_hash="$(sha256sum "$GDS" | awk '{print $1}')"
  void_gds=(
    "$PROJECT_ROOT/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
    "$PROJECT_ROOT/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_with_seal.gds"
  )
  no_void="PASS"
  for v in "${void_gds[@]}"; do
    if [ -s "$v" ] && [ "$final_hash" = "$(sha256sum "$v" | awk '{print $1}')" ]; then
      no_void="FAIL"
      failures+=("final GDS hash matches VOID artifact $v")
    fi
  done
  if [ -s "$BASE" ] && [ "$final_hash" = "$(sha256sum "$BASE" | awk '{print $1}')" ]; then
    no_void="FAIL"
    failures+=("final GDS is the unmodified fix16 base")
  fi
fi

if [ -s "$GDS" ] && [ -s "$BASE" ] && [ -s "$CHECK" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    gds_checks="BLOCKED_NO_DOCKER"
    failures+=("docker unavailable for GDS identity checks")
  else
    HOST_ROOT="$PROJECT_ROOT"
    if command -v cygpath >/dev/null 2>&1; then
      HOST_ROOT="$(cygpath -m "$PROJECT_ROOT")"
    fi
    set +e
    MSYS_NO_PATHCONV=1 docker run --rm \
      -v "$HOST_ROOT:/work" -w /work \
      --entrypoint klayout ghcr.io/efabless/openlane2:2.3.10 -b \
      -r /work/build/production/run/gds_checks.rb \
      -rd gds=/work/build/production/final/grx930_test_chip_final.gds \
      -rd base=/work/build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds \
      -rd def=/work/build/lvs_chip/rebased_grx930_test_chip.def \
      -rd topcell=grx930_test_chip \
      -rd expected_die_w=3932 \
      -rd expected_die_h=5122 \
      -rd expected_drops=8168 \
      -rd report=/work/build/production/manifests/gds_checks.txt \
      > "$MAN/gds_checks.log" 2>&1
    check_rc=$?
    set -e
    if [ "$check_rc" -eq 0 ]; then
      gds_checks="PASS"
    else
      gds_checks="FAIL"
      failures+=("GDS identity/ECO check exited $check_rc")
    fi
  fi
fi

if [ -s "$GDS" ] && [ -s "$DEF" ] && [ -s "$DEF_CHECK" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    def_gds_checks="BLOCKED_NO_DOCKER"
    failures+=("docker unavailable for DEF/GDS consistency checks")
  else
    HOST_ROOT="$PROJECT_ROOT"
    if command -v cygpath >/dev/null 2>&1; then
      HOST_ROOT="$(cygpath -m "$PROJECT_ROOT")"
    fi
    set +e
    MSYS_NO_PATHCONV=1 docker run --rm \
      -v "$HOST_ROOT:/work" -w /work \
      --entrypoint klayout ghcr.io/efabless/openlane2:2.3.10 -b \
      -r /work/build/production/run/def_gds_checks.rb \
      -rd gds=/work/build/production/final/grx930_test_chip_final.gds \
      -rd def=/work/build/lvs_chip/rebased_grx930_test_chip.def \
      -rd topcell=grx930_test_chip \
      -rd expected_drops=8168 \
      -rd report=/work/build/production/manifests/def_gds_checks.txt \
      > "$MAN/def_gds_checks.log" 2>&1
    def_rc=$?
    set -e
    if [ "$def_rc" -eq 0 ]; then
      def_gds_checks="PASS"
    else
      def_gds_checks="FAIL"
      failures+=("DEF/GDS routed-geometry or ECO check exited $def_rc")
    fi
  fi
fi

if [ "${#missing[@]}" -eq 0 ] && [ "${#failures[@]}" -eq 0 ]; then
  status="READY_FOR_REVIEW"
else
  status="BLOCKED"
fi

{
  echo "gate=G0"
  echo "status=$status"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "owner=Design lead (unassigned)"
  echo "manifest=$MAN/input_sha256.txt"
  echo "cdl=$CDL"
  echo "def=$DEF"
  echo "gds=$GDS"
  echo "die_source=DEF DIEAREA; GDS content bbox must fit inside it"
  echo "spef=$SPEF"
  echo "base=$BASE"
  echo "no_void=$no_void"
  echo "gds_checks=$gds_checks"
  echo "def_gds_checks=$def_gds_checks"
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "missing=none"
  else
    echo "missing_count=${#missing[@]}"
    for f in "${missing[@]}"; do echo "missing=$f"; done
  fi
  if [ "${#failures[@]}" -eq 0 ]; then
    echo "failures=none"
  else
    echo "failure_count=${#failures[@]}"
    for f in "${failures[@]}"; do echo "failure=$f"; done
  fi
  echo "note=Hashes and GDS checks are evidence only. G0 is not PASS until the design lead and independent reviewer sign the identity and contents."
} > "$MAN/G0_status.txt"
manifest_hash=$(sha256sum "$MAN/input_sha256.txt" | awk '{print $1}')
echo "manifest_sha256=$manifest_hash" >> "$MAN/G0_status.txt"

cat "$MAN/G0_status.txt"

if [ "${#missing[@]}" -ne 0 ] || [ "${#failures[@]}" -ne 0 ]; then
  exit 2
fi
