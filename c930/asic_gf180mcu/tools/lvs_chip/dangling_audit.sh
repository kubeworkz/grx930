#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# dangling_audit.sh -- run dangling_nets.tcl with the committed, hash-pinned manifest.
#
# The audit itself lives in tools/lvs_chip/dangling_nets.tcl and reads the ODB through OpenROAD.
# This wrapper exists so the pin is not optional: it hashes tools/lvs_chip/dangling_manifest.tsv,
# refuses when that hash is not the one in dangling_manifest.tsv.sha256, and passes both to the
# audit. A run that cannot prove which manifest it used is not a run this repo accepts.
#
#     bash build/lvs_chip/dangling_audit.sh --odb ODB --report REPORT.tsv
#     bash build/lvs_chip/dangling_audit.sh --odb ODB --report REPORT.tsv --manifest OTHER.tsv
#
# Exit status is the audit's: 0 nothing fails, 1 something does, 2 could not run (no docker, no
# ODB, manifest hash or format refused).
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
MANIFEST=$ROOT/c930/asic_gf180mcu/tools/lvs_chip/dangling_manifest.tsv
AUDIT=$ROOT/c930/asic_gf180mcu/tools/lvs_chip/dangling_nets.tcl
IMAGE=${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}
ODB=""
REPORT=""

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --odb)       ODB=$2; shift 2 ;;
        --odb=*)     ODB=${1#*=}; shift ;;
        --report)    REPORT=$2; shift 2 ;;
        --report=*)  REPORT=${1#*=}; shift ;;
        --manifest)  MANIFEST=$2; shift 2 ;;
        --manifest=*) MANIFEST=${1#*=}; shift ;;
        --image)     IMAGE=$2; shift 2 ;;
        --image=*)   IMAGE=${1#*=}; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "dangling_audit: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$ODB" ] && [ -n "$REPORT" ] || { usage >&2; exit 2; }
[ -f "$ODB" ] || { echo "dangling_audit: no ODB at $ODB" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "dangling_audit: docker is not on PATH" >&2; exit 2; }

# The pin: the manifest's own hash must be the one committed beside it.
[ -f "$MANIFEST" ] || { echo "dangling_audit: no manifest at $MANIFEST" >&2; exit 2; }
[ -f "$MANIFEST.sha256" ] || {
    echo "dangling_audit: $MANIFEST.sha256 is missing; commit the hash with the manifest" >&2
    exit 2
}
SHA=$(sha256sum "$MANIFEST" | cut -d' ' -f1)
if ! grep -q -- "$SHA" "$MANIFEST.sha256"; then
    echo "dangling_audit: $MANIFEST hashes to $SHA, which is not in $MANIFEST.sha256" >&2
    echo "  update the manifest's evidence and its .sha256 together, in one commit" >&2
    exit 2
fi

abspath() {
    local p=$1 d
    case "$p" in /*) ;; *) p=$PWD/$p ;; esac
    d=$(dirname "$p")
    [ -d "$d" ] || { echo "dangling_audit: no such directory: $d" >&2; return 1; }
    printf '%s/%s' "$(cd "$d" && pwd)" "$(basename "$p")"
}
ODB=$(abspath "$ODB") || exit 2
REPORT=$(abspath "$REPORT") || exit 2
mkdir -p "$(dirname "$REPORT")" || exit 2

# The repository is mounted at /work. An ODB or report outside it gets its own mount, because the
# audit is often pointed at a scratch database and the report belongs beside that database.
MOUNTS=(-v "$ROOT:/work")
ctr() {
    case "$1" in
        "$ROOT"/*) printf '/work/%s' "${1#"$ROOT"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}
if [ "${ODB#"$ROOT"/}" = "$ODB" ]; then
    MOUNTS+=(-v "$(dirname "$ODB"):/odb")
    C_ODB=/odb/$(basename "$ODB")
else
    C_ODB=$(ctr "$ODB")
fi
if [ "${REPORT#"$ROOT"/}" = "$REPORT" ]; then
    MOUNTS+=(-v "$(dirname "$REPORT"):/out")
    C_REPORT=/out/$(basename "$REPORT")
else
    C_REPORT=$(ctr "$REPORT")
fi
if [ "${MANIFEST#"$ROOT"/}" = "$MANIFEST" ]; then
    MOUNTS+=(-v "$(dirname "$MANIFEST"):/manifest")
    C_MANIFEST=/manifest/$(basename "$MANIFEST")
else
    C_MANIFEST=$(ctr "$MANIFEST")
fi

echo "dangling_audit: odb ${ODB#"$ROOT"/}  manifest ${MANIFEST#"$ROOT"/}  sha256 $SHA"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp "${MOUNTS[@]}" \
    -e "DANGLING_ODB=$C_ODB" -e "DANGLING_REPORT=$C_REPORT" \
    -e "DANGLING_MANIFEST=$C_MANIFEST" -e "DANGLING_MANIFEST_SHA256=$SHA" \
    --entrypoint openroad "$IMAGE" -no_init -exit /work/c930/asic_gf180mcu/tools/lvs_chip/dangling_nets.tcl
