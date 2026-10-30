#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvs_refresh_evidence.sh -- re-run the LVS fixture family against the pinned PDK and compare the
# result with the committed evidence, so a stale verdict cannot sit in the tree unnoticed.
#
# WHY THIS EXISTS
#
#   build/lvs/lvs_fixtures_verdict.json is what the `lvs-fixture` gate judges, and nothing on a
#   checkout can re-run the thing it describes: the PDK is not tracked. So the only way the
#   evidence can go stale is quietly -- a deck revision moves, the harness grows a switch, a
#   fixture is replaced -- and the gate would keep passing on a report about files nobody has any
#   more. This script runs every fixture in build/lvs_fixtures.tsv with the switches that file
#   names, judges each with the same judge the gate uses, and answers one question: does the
#   committed evidence still describe what the harness produces today?
#
#     CURRENT   the fresh family is the committed one, field for field (exit 0)
#     STALE     it is not; the fields that differ are printed, and the fresh aggregate is left in
#               --out for a human to look at and commit (exit 1). Pass --update to accept it.
#     UPDATED   --update was given: the committed file has been replaced by the fresh one (exit 0)
#     BROKEN    at least one fixture in the family did not come back green (exit 1). This never
#               updates anything: a family that cannot reproduce itself is a finding about the
#               pin, the switches or the PDK, and overwriting the evidence would erase it.
#     SWITCHES  a manifest line does not carry what the pin's config asks for that fixture, so
#               nothing was run (exit 1). This is a finding about the manifest, not a stale
#               family: --update must not be able to accept it, and it is checked before the first
#               docker run rather than after half an hour of them.
#     PARTIAL   --only was used, so a subset ran; nothing is compared or updated (exit 0)
#     CANNOT-RUN the harness or the pin is not usable (exit 2)
#
#   Comparison covers what decides a green -- per fixture the verdict, the device counts, the port
#   comparison and the two input hashes, plus the shared deck hash and the switch sets -- and not
#   the reports' own paths, which differ by construction.
#
#   Before any of that, the switch column itself is checked against the PDK: every line must carry
#   exactly the `test_switches` entry the pin's `testing/unit/<category>/config/default.yaml` has
#   for that fixture (tools/lvs_switch_check.py). Without it a manifest could ask for a switch the
#   PDK does not, run green anyway, and refresh the evidence about a device nobody configured.
#
# EXIT STATUS: 0 current/updated/partial, 1 stale, broken or switches, 2 cannot run.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
HARNESS=$ROOT/c930/asic_gf180mcu/tools/klayout_lvs.sh
JUDGE=$ROOT/c930/asic_gf180mcu/tools/lvs_verdict.py
FAMILY=$ROOT/c930/asic_gf180mcu/tools/lvs_family.py

PIN=$HERE/.lvs_pin
MANIFEST=$HERE/lvs_fixtures.tsv
IMAGE=${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}
COMMITTED=$HERE/lvs/lvs_fixtures_verdict.json
OUT=$HERE/lvs_run/family
UPDATE=0
ONLY=""

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --pin)       PIN=$2; shift 2 ;;
        --pin=*)     PIN=${1#*=}; shift ;;
        --manifest)  MANIFEST=$2; shift 2 ;;
        --manifest=*) MANIFEST=${1#*=}; shift ;;
        --image)     IMAGE=$2; shift 2 ;;
        --image=*)   IMAGE=${1#*=}; shift ;;
        --committed) COMMITTED=$2; shift 2 ;;
        --committed=*) COMMITTED=${1#*=}; shift ;;
        --out)       OUT=$2; shift 2 ;;
        --out=*)     OUT=${1#*=}; shift ;;
        --only)      ONLY=$2; shift 2 ;;
        --only=*)    ONLY=${1#*=}; shift ;;
        --update)    UPDATE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "lvs_refresh_evidence: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

command -v docker >/dev/null 2>&1 || { echo "SETUP  docker is not on PATH" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "SETUP  no fixture manifest at $MANIFEST" >&2; exit 2; }

# python3 on Linux, python on the Windows box -- the same probe as every other script here.
PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "SETUP  no python3/python on PATH" >&2; exit 2; }

DECK=$PIN/gf180mcu.lvs
[ -f "$DECK" ] || {
    echo "SETUP  $DECK is missing: run build/lvs_fetch_pdk_subset.sh --into ${PIN#"$ROOT"/} first" >&2
    exit 2
}
[ -d "$PIN/rule_decks" ] || {
    echo "SETUP  $PIN/rule_decks is missing (the deck cannot extract without it)" >&2
    exit 2
}

# The pin the aggregate records, from what the fetcher wrote rather than from a second copy of it.
PIN_REF="unrecorded"
PIN_REPO="unrecorded"
if [ -f "$PIN/PIN.txt" ]; then
    PIN_REPO=$(sed -n 's/^repo *//p' "$PIN/PIN.txt" | head -1)
    PIN_REF=$(sed -n 's/^ref *//p' "$PIN/PIN.txt" | head -1)
fi

# The switch column is a claim about the PDK, not a local preference, so it is checked against the
# pin before anything runs -- and before the previous output is deleted, so a failed check leaves
# the last real run where it was. Half an hour of docker is the wrong place to discover that a
# line was edited, and a fresh aggregate must never be built from a switch the PDK does not ask
# for: that would make the evidence green about a device nobody configured.
SWITCHES=$ROOT/c930/asic_gf180mcu/tools/lvs_switch_check.py
"$PY" "$SWITCHES" --pin "$PIN" --manifest "$MANIFEST"
switch_rc=$?
if [ $switch_rc -eq 1 ]; then
    echo "LVS-EVIDENCE: SWITCHES -- the manifest disagrees with the pin's config; no fixture was run" >&2
    exit 1
elif [ $switch_rc -ne 0 ]; then
    echo "LVS-EVIDENCE: CANNOT-RUN the switches could not be checked (rc=$switch_rc)" >&2
    exit 2
fi
rm -rf "$OUT"
mkdir -p "$OUT/runs"

# The aggregate is built from the lines that actually ran: with --only that is a subset, and a
# builder pointed at the whole manifest would refuse the runs it was not asked for (measured: a
# `--only 'res_devices/*'` iteration died on "no usable report for" the other fixtures) instead of
# reporting PARTIAL. The filtered manifest is written beside the runs so the aggregate records
# exactly the fixture list it was built from.
RUN_MANIFEST=$MANIFEST
if [ -n "$ONLY" ]; then
    RUN_MANIFEST=$OUT/manifest.tsv
    while IFS=$(printf '\t') read -r name _rest; do
        [ -n "$name" ] || continue
        case "$name" in
            \#*) continue ;;
            $ONLY)
                if [ -n "$_rest" ]; then printf '%s\t%s\n' "$name" "$_rest"
                else printf '%s\n' "$name"
                fi
                ;;
        esac
    done < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST") > "$RUN_MANIFEST"
fi

echo "pin      ${PIN#"$ROOT"/} ($PIN_REPO@${PIN_REF:0:12})"
echo "image    $IMAGE"
[ -n "$ONLY" ] && echo "only     $ONLY (a subset: nothing will be compared or updated)"

ran=0
skipped=0
while IFS=$(printf '\t') read -r name switches; do
    [ -n "$name" ] || continue
    case "$name" in
        \#*) continue ;;
    esac
    category=${name%%/*}
    fixture=${name##*/}
    if [ -n "$ONLY" ]; then
        case "$name" in
            $ONLY) ;;
            *) skipped=$((skipped + 1)); continue ;;
        esac
    fi

    run=$OUT/runs/${category}__${fixture}
    args=(--deck "$DECK"
          --layout "$PIN/testing/unit/$category/layout/$fixture.gds.gz"
          --netlist "$PIN/testing/unit/$category/netlist/$fixture.cdl"
          --out "$run")
    # The manifest's switches, one --switch per key=value. Nothing is implied here: what is not in
    # the manifest is not passed, which is why the manifest is the thing a reviewer reads.
    if [ -n "$switches" ]; then
        old_ifs=$IFS; IFS=','
        for kv in $switches; do
            [ -n "$kv" ] && args+=(--switch "$kv")
        done
        IFS=$old_ifs
    fi

    mkdir -p "$run"
    bash "$HARNESS" "${args[@]}" > "$run/harness.out" 2>&1
    harness_rc=$?
    ran=$((ran + 1))

    if [ ! -f "$run/verdict.json" ]; then
        printf '  %-42s CANNOT-RUN (harness rc=%s; see %s)\n' "$name" "$harness_rc" "${run#"$ROOT"/}/harness.out"
        echo "LVS-EVIDENCE: CANNOT-RUN $name produced no verdict" >&2
        echo "  harness log tail:" >&2
        tail -4 "$run/harness.out" | sed 's/^/    /' >&2
        exit 2
    fi

    line=$("$PY" "$JUDGE" --report "$run/verdict.json" --deck "$DECK" \
               --layout "$PIN/testing/unit/$category/layout/$fixture.gds.gz" \
               --netlist "$PIN/testing/unit/$category/netlist/$fixture.cdl" 2>&1)
    judge_rc=$?
    printf '  %-42s %s\n' "$name" "$line"
    printf '%s\n' "$line" > "$run/judge.txt"
    # A fixture that will not run (as opposed to one that mismatches) stops the refresh: there is
    # nothing to compare, and calling it STALE would send somebody to edit evidence over a
    # harness problem.
    if [ $judge_rc -eq 2 ]; then
        echo "LVS-EVIDENCE: CANNOT-RUN $name could not be judged: $line" >&2
        exit 2
    fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST")

[ -n "$ONLY" ] && echo "  --   $ran ran, $skipped skipped by --only"
if [ -n "$ONLY" ] && [ "$ran" -eq 0 ]; then
    echo "LVS-EVIDENCE: CANNOT-RUN --only '$ONLY' matched no line of $(basename "$MANIFEST")" >&2
    exit 2
fi

"$PY" "$FAMILY" build --manifest "$RUN_MANIFEST" --runs "$OUT/runs" --out "$OUT/verdict.json" \
    --pin "$PIN_REPO@$PIN_REF" || {
    echo "LVS-EVIDENCE: CANNOT-RUN the aggregate could not be built from $OUT/runs" >&2
    exit 2
}

# The gate's own judge, on the family: "the fresh evidence is green" then means exactly what a
# green gate means, entry by entry.
"$PY" "$JUDGE" --report "$OUT/verdict.json" --deck "$DECK"
family_rc=$?
if [ $family_rc -ne 0 ]; then
    echo "LVS-EVIDENCE: BROKEN the fresh family is not green (judge rc=$family_rc); see ${OUT#"$ROOT"/}"
    exit 1
fi

if [ -n "$ONLY" ]; then
    echo "LVS-EVIDENCE: PARTIAL -- $ran fixture(s) ran and are green; nothing compared (--only $ONLY)"
    exit 0
fi

if [ ! -f "$COMMITTED" ]; then
    echo "LVS-EVIDENCE: STALE -- there is no committed evidence at ${COMMITTED#"$ROOT"/}"
    echo "              the fresh family is green: ${OUT#"$ROOT"/}/verdict.json"
    if [ "$UPDATE" = 1 ]; then
        cp "$OUT/verdict.json" "$COMMITTED"
        echo "LVS-EVIDENCE: UPDATED -- ${COMMITTED#"$ROOT"/} now holds the fresh family; commit it"
        exit 0
    fi
    exit 1
fi

verdict=$("$PY" "$FAMILY" compare "$COMMITTED" "$OUT/verdict.json" 2>&1)
cmp_rc=$?

if [ "$verdict" = "SAME" ]; then
    echo "LVS-EVIDENCE: CURRENT -- $(basename "$COMMITTED") is what the harness produces today"
    exit 0
fi

case "$verdict" in
    DIFF\ *) ;;
    *)
        echo "LVS-EVIDENCE: CANNOT-RUN the families could not be compared: $verdict"
        exit 2
        ;;
esac
if [ $cmp_rc -eq 0 ]; then
    echo "LVS-EVIDENCE: STALE (the comparison reported no difference but did not match)"
    exit 1
fi

echo "LVS-EVIDENCE: STALE -- the committed family and a fresh run disagree"
echo "              fields that differ: ${verdict#DIFF }"
echo "              fresh family:       ${OUT#"$ROOT"/}/verdict.json"
echo "              per-fixture runs:   ${OUT#"$ROOT"/}/runs/*/"

if [ "$UPDATE" = 1 ]; then
    cp "$OUT/verdict.json" "$COMMITTED"
    echo "LVS-EVIDENCE: UPDATED -- ${COMMITTED#"$ROOT"/} now holds the fresh family; commit it"
    exit 0
fi
echo "              re-run with --update to accept it, then commit the file"
exit 1
