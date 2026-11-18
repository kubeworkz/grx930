#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROD="$PROJECT_ROOT/build/production"
DFT="$PROD/dft"

mkdir -p "$DFT"

missing=()
command -v dftc >/dev/null 2>&1 || missing+=("dftc")
command -v tetramax >/dev/null 2>&1 || missing+=("tetramax")
[ -s "$DFT/dft_insert.tcl" ] || missing+=("$DFT/dft_insert.tcl")
[ -s "$DFT/atpg.tcl" ] || missing+=("$DFT/atpg.tcl")

if [ "${#missing[@]}" -ne 0 ]; then
  {
    echo "gate=G1"
    echo "status=BLOCKED"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owner=DFT lead (unassigned)"
    for f in "${missing[@]}"; do echo "missing=$f"; done
    echo "note=No DFT insertion or ATPG result is claimed."
  } | tee "$DFT/G1_status.txt"
  exit 2
fi

echo "gate=G1" > "$DFT/G1_status.txt"
echo "status=READY_TO_RUN" >> "$DFT/G1_status.txt"
echo "note=Tool and script presence only; signoff still requires the G1 exit criteria and owner signature." >> "$DFT/G1_status.txt"
cat "$DFT/G1_status.txt"
