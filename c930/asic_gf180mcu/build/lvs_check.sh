#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_check.sh -- the LVS row of the tapeout gate table.
#
# WHY THIS EXISTS
#
#   tools/klayout_lvs.sh produces an LVS verdict; nothing yet decides whether that verdict may be
#   called green in a run somebody is going to read. That decision is this file, and the point of
#   it is that "no report" and "the report says mismatch" must not look the same: a gate that
#   cannot tell them apart will one day pass a tapeout because the report was simply absent.
#
# WHAT IT JUDGES BY DEFAULT
#
#   build/lvs/lvs_fixtures_verdict.json -- the committed family evidence: one aggregate over the
#   fixtures in build/lvs_fixtures.tsv, from the PDK run that gave this repo its first green LVS
#   (doc/lvs_plan.md §6). Every fixture in it must be green, and none may have skipped the port
#   check; a single bad entry fails the gate and is named in the log.
#
#   It lives under build/ rather than lvs_runs/ because lvs_runs/ is gitignored: CI has to judge
#   the same evidence the box judged. Regenerate it with build/lvs_refresh_evidence.sh; the README
#   beside it records the provenance.
#
#   When the inputs exist on this machine their sha256 is compared with the hashes the evidence
#   recorded -- the deck for a family (one file for all fixtures), deck/layout/netlist for a single
#   report -- so evidence about different inputs is a MISMATCH rather than a pass. On a checkout
#   with no PDK install those paths do not exist; the judge says so and the evidence's own content
#   still decides, because that is the artifact under review there.
#
# --live IS THE MODE FOR A REAL DESIGN
#
#   `--live` runs tools/klayout_lvs.sh first and judges what it just produced. That needs docker
#   and a PDK install, so it is not the table's row (CI has neither); it is what S2/S4 of
#   doc/lvs_plan.md call when there is a chip to check:
#
#     bash build/lvs_check.sh --live --layout <gds> --netlist <cdl> [--topcell NAME]
#
# EXIT STATUS (the judge's, untouched)
#
#   0  PASS        devices match, ports pass, and the report is about the inputs on disk
#   1  MISMATCH    the netlists or the ports disagree -- or the report is about other inputs
#   2  CANNOT-RUN  no report, unreadable report, or a report with the port check skipped
#
#   build/chip_gates.sh turns any non-zero status into a failed gate and shows the status in its
#   table, so 1 and 2 stay distinguishable in the run summary as well as in this log.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
TOOLS=$ROOT/c930/asic_gf180mcu/tools
PDK_LVS=$ROOT/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs
FIXTURES=$PDK_LVS/testing/unit/mos_devices

REPORT=$HERE/lvs/lvs_fixtures_verdict.json
LAYOUT=$FIXTURES/layout/nfet_05v0.gds.gz
NETLIST=$FIXTURES/netlist/nfet_05v0.cdl
DECK=$PDK_LVS/gf180mcu.lvs
TOPCELL=""
LIVE=0
OUT=$HERE/lvs_run

usage() {
    sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --live)      LIVE=1; shift ;;
        --report)    REPORT=$2; shift 2 ;;
        --report=*)  REPORT=${1#*=}; shift ;;
        --layout)    LAYOUT=$2; shift 2 ;;
        --layout=*)  LAYOUT=${1#*=}; shift ;;
        --netlist)   NETLIST=$2; shift 2 ;;
        --netlist=*) NETLIST=${1#*=}; shift ;;
        --deck)      DECK=$2; shift 2 ;;
        --deck=*)    DECK=${1#*=}; shift ;;
        --topcell)   TOPCELL=$2; shift 2 ;;
        --topcell=*) TOPCELL=${1#*=}; shift ;;
        --out)       OUT=$2; shift 2 ;;
        --out=*)     OUT=${1#*=}; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "lvs_check: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

# The Store flavour of `python3` on Windows is a stub that fails with a message; take the first
# interpreter that actually runs, the same probe tools/precheck_verdict_selftest.sh uses.
PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
if [ -z "$PY" ]; then
    # Not a verdict, and not a pass: this gate cannot see the report it was given.
    echo "LVS: CANNOT-RUN no python3/python on PATH, so the report cannot be judged"
    exit 2
fi

if [ "$LIVE" = 1 ]; then
    echo "live     running the harness first (needs docker and the PDK install)"
    [ -f "$TOOLS/klayout_lvs.sh" ] || { echo "LVS: CANNOT-RUN no harness at $TOOLS/klayout_lvs.sh"; exit 2; }
    live_args=(--out "$OUT")
    [ -n "$LAYOUT" ]  && live_args+=(--layout "$LAYOUT")
    [ -n "$NETLIST" ] && live_args+=(--netlist "$NETLIST")
    [ -n "$TOPCELL" ] && live_args+=(--topcell "$TOPCELL")
    bash "$TOOLS/klayout_lvs.sh" "${live_args[@]}"
    rc=$?
    if [ $rc -ne 0 ] && [ ! -f "$OUT/verdict.json" ]; then
        # The harness itself could not produce a report (missing input, docker absent, deck
        # error). That is CANNOT-RUN, not a mismatch, and the harness's own log says why.
        echo "LVS: CANNOT-RUN the harness produced no report (rc=$rc)"
        exit 2
    fi
    REPORT=$OUT/verdict.json
fi

# Hash-check the evidence against the inputs when they are here; the judge skips absent ones. A
# family shares one deck and has per-fixture layouts/netlists, so only the deck applies to it --
# build/lvs_fetch_pdk_subset.sh is what ties those per-fixture files to the pin.
family=0
[ -f "$REPORT" ] && grep -q '"kind": "family"' "$REPORT" && family=1
hash_args=()
if [ -f "$DECK" ]; then
    hash_args+=(--deck "$DECK")
else
    echo "note     the deck is not on disk here, so the evidence was not tied to one"
fi
want=1
if [ $family = 0 ]; then
    want=3
    [ -f "$LAYOUT" ]  && hash_args+=(--layout "$LAYOUT")
    [ -f "$NETLIST" ] && hash_args+=(--netlist "$NETLIST")
fi

# A CI checkout has no PDK install, so there is nothing to tie the evidence to there. Its own
# content still decides -- and this line is why a green from that run cannot be read as a
# hash-checked one. Printed before the verdict, so the verdict stays the line the table quotes.
if [ ${#hash_args[@]} -lt $want ]; then
    echo "note     $((want - ${#hash_args[@]}))/$want input(s) not on disk here: the evidence is judged"
    echo "note     on its own contents, not tied to the files it describes"
fi

"$PY" "$TOOLS/lvs_verdict.py" --report "$REPORT" "${hash_args[@]+"${hash_args[@]}"}"
