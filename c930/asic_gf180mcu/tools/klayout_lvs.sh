#!/bin/bash
# klayout_lvs.sh -- run the GF180MCU KLayout LVS deck on a layout/schematic pair, from the host.
#
# Why this exists: the deck cannot produce a verdict through its own documented interface. Its
# comparison section reads `flag_missing_ports`, which is assigned nowhere in the deck, in the
# `rule_decks/` it includes, or at upstream `main`; `check_ports` defaults to true, so any default
# invocation dies before reporting. The PDK's `run_lvs.py` has no switch to disable it.
# tools/klayout_lvs.py (run inside the flow image) turns that one switch off and performs the port
# comparison itself -- see its docstring for the evidence.
#
# Two environment facts this wrapper encodes, both measured on this box:
#   * the deck must run **in place**: KLayout expands `# %include rule_decks/...` relative to the
#     deck's directory, so a copy without `rule_decks` beside it extracts nothing and compares two
#     empty netlists;
#   * `pmap` is missing from the flow images and the deck's logger dies without it -- handled
#     inside the image by the runner.
#
#   bash tools/klayout_lvs.sh                              # the PDK's own nfet_05v0 fixture
#   bash tools/klayout_lvs.sh --fixture pfet_05v0          # any fixture under testing/unit/mos_devices
#   bash tools/klayout_lvs.sh --layout A.gds --netlist A.cdl --out D
#   bash tools/klayout_lvs.sh --fixture pfet_05v0 --implicit-connect   # that fixture's PDK config
#   bash tools/klayout_lvs.sh --no-port-check              # device comparison alone
#   bash tools/klayout_lvs.sh --switch poly_res=2k         # any extra deck switch, repeatable
#   bash tools/klayout_lvs.sh --deck /elsewhere/gf180mcu.lvs           # a fetched/other deck
#       (the deck must sit beside its rule_decks/ -- see above; build/lvs_fetch_pdk_subset.sh
#        materialises a pinned copy of both for CI)
#
# The per-fixture switches live in build/lvs_fixtures.tsv, taken from the PDK's own regression
# config; nothing in this wrapper decides them.
#
# All paths must live inside this repository: that is the tree docker mounts at /work.
# Exit codes are the runner's: 0 match, 1 mismatch, 2 could not run. LVS_IMAGE overrides the image.
set -u
S=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$S/../../.." && pwd)
LVS=$S/../libs.tech/klayout/tech/lvs
FIXTURES=$LVS/testing/unit/mos_devices
IMAGE=${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}

usage() {
    sed -n '9,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

FIXTURE=nfet_05v0
LAYOUT=""
NETLIST=""
OUT=""
TOPCELL=""
DECK=${LVS_DECK:-$LVS/gf180mcu.lvs}
PORT_ARGS=()
SWITCH_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --fixture)      FIXTURE=$2; shift 2 ;;
        --fixture=*)    FIXTURE=${1#*=}; shift ;;
        --layout)       LAYOUT=$2; shift 2 ;;
        --layout=*)     LAYOUT=${1#*=}; shift ;;
        --netlist)      NETLIST=$2; shift 2 ;;
        --netlist=*)    NETLIST=${1#*=}; shift ;;
        --out)          OUT=$2; shift 2 ;;
        --out=*)        OUT=${1#*=}; shift ;;
        --topcell)      TOPCELL=$2; shift 2 ;;
        --topcell=*)    TOPCELL=${1#*=}; shift ;;
        --deck)         DECK=$2; shift 2 ;;
        --deck=*)       DECK=${1#*=}; shift ;;
        --no-port-check) PORT_ARGS+=(--no-port-check); shift ;;
        --implicit-connect) PORT_ARGS+=(--implicit-connect); shift ;;
        --switch)       SWITCH_ARGS+=(--switch "$2"); shift 2 ;;
        --switch=*)     SWITCH_ARGS+=(--switch "${1#*=}"); shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$LAYOUT" ]  || LAYOUT=$FIXTURES/layout/$FIXTURE.gds.gz
[ -n "$NETLIST" ] || NETLIST=$FIXTURES/netlist/$FIXTURE.cdl
[ -n "$OUT" ]     || OUT=$S/../lvs_runs/$FIXTURE

command -v docker >/dev/null 2>&1 || { echo "SETUP  docker not found on PATH" >&2; exit 2; }

# Canonical absolute path, whether or not the leaf exists. The parent must exist, except for an
# output path: `--create-dir` is passed only for --out, so a typo'd --deck cannot leave a trail of
# empty directories behind it (and cannot look like a PDK that is merely empty).
abspath() {
    local p=$1 create=${2:-} d
    case "$p" in /*) ;; *) p=$PWD/$p ;; esac
    d=$(dirname "$p")
    if [ ! -d "$d" ]; then
        [ "$create" = --create-dir ] || { echo "no such directory: $d" >&2; return 1; }
        mkdir -p "$d" || return 1
    fi
    printf '%s/%s' "$(cd "$d" && pwd)" "$(basename "$p")"
}
LAYOUT=$(abspath "$LAYOUT") || exit 2
NETLIST=$(abspath "$NETLIST") || exit 2
OUT=$(abspath "$OUT" --create-dir) || exit 2
DECK=$(abspath "$DECK") || exit 2
[ -f "$DECK" ] || { echo "SETUP  deck not found: $DECK" >&2; exit 2; }
[ -d "$(dirname "$DECK")/rule_decks" ] || {
    echo "SETUP  $(dirname "$DECK")/rule_decks is missing: this deck expands '# %include' and" >&2
    echo "       would extract nothing, then compare two empty netlists" >&2
    exit 2
}
RUNNER=$(abspath "$S/klayout_lvs.py")

MOUNT=$ROOT
if command -v cygpath >/dev/null 2>&1; then MOUNT=$(cygpath -m "$ROOT"); fi

# Host path -> /work/... The tree is mounted at /work, so anything outside it cannot be passed in.
ctr() {
    case "$1" in
        "$ROOT"/*) printf '/work/%s' "${1#"$ROOT"/}" ;;
        *) echo "path is outside this repository (not mounted in the container): $1" >&2; return 2 ;;
    esac
}

C_LAYOUT=$(ctr "$LAYOUT") || exit 2
C_NETLIST=$(ctr "$NETLIST") || exit 2
C_OUT=$(ctr "$OUT") || exit 2
C_DECK=$(ctr "$DECK") || exit 2
C_RUNNER=$(ctr "$RUNNER") || exit 2

echo "image   $IMAGE"
echo "deck    ${DECK#"$ROOT"/}"
echo "layout  ${LAYOUT#"$ROOT"/}"
echo "netlist ${NETLIST#"$ROOT"/}"
echo "out     ${OUT#"$ROOT"/}"

ARGS=("$C_RUNNER" --deck "$C_DECK" --layout "$C_LAYOUT" --netlist "$C_NETLIST" --out "$C_OUT")
[ -n "$TOPCELL" ] && ARGS+=(--topcell "$TOPCELL")
ARGS+=("${SWITCH_ARGS[@]+"${SWITCH_ARGS[@]}"}")
ARGS+=("${PORT_ARGS[@]+"${PORT_ARGS[@]}"}")

mkdir -p "$OUT"
MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" -w /work "$IMAGE" python3 "${ARGS[@]}"
