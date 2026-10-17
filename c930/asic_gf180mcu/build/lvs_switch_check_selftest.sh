#!/bin/bash
# lvs_switch_check_selftest.sh -- does the switch check still fail when the manifest and the PDK
# disagree, and only then?
#
#   bash build/lvs_switch_check_selftest.sh      # 0 = the check holds, 1 = it drifted
#
# WHY THIS EXISTS
#
#   tools/lvs_switch_check.py exists to make one claim true: the switch column of
#   build/lvs_fixtures.tsv is the PDK's, not ours. A check that says PASS for everything would
#   make that claim unfalsifiable and the evidence no stronger than before, so every way the two
#   can disagree is provoked here on purpose -- a switch the manifest drops, one it invents, one
#   whose value moved, one on a fixture the config does not name -- and each must come back as a
#   MISMATCH naming the fixture and the key.
#
#   The other half is the failure mode that matters more: a config this reader cannot parse must
#   be CANNOT-RUN, never a pass. A YAML dialect it does not implement (a flow mapping, a third
#   level, tab indentation) is exactly the change upstream that would otherwise turn the check
#   into decoration.
#
# WHAT IT COVERS
#
#   the checker, on a synthetic pin of the PDK's shape
#     pass (0)      switches in a different order than the config; quoted and bare scalars; a
#                   fixture listed with no switches at all; a trailing comment after a value
#     mismatch (1)  a switch dropped from a manifest line; one invented; one with another value;
#                   a switch on a fixture the config does not name
#     cannot-run(2) a config file missing; a flow mapping; a second top-level key; a third level;
#                   tab indentation; a manifest line that is not key=value; a duplicate fixture;
#                   a manifest with no fixtures in it
#   the refresh, on a pin whose config disagrees
#     it stops with SWITCHES (1) before any fixture runs -- no runs directory is created -- and
#     --update does not let it through, nor does --only point it away from the disagreement
#   the real pin, when this box has one
#     51/51 agree
#
#   No docker pull: the refresh cases never reach a fixture, which is the property being tested.
#   Runs in about a second.
set -u
S=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$S/../../.." && pwd)

REL_TOOL=c930/asic_gf180mcu/tools/lvs_switch_check.py
REL_REFRESH=c930/asic_gf180mcu/build/lvs_refresh_evidence.sh

# The Store flavour of `python3` on Windows is a stub; take whichever interpreter actually runs.
PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "no python3/python on PATH"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
na()  { SKIP=$((SKIP+1)); printf '  --   %s\n' "$1"; }

# Relative paths: a native Windows python cannot open an MSYS `/c/...` path, so everything this
# test writes and hands back is under the repo.
REL=c930/asic_gf180mcu/build/lvs_switch_selftest.tmp
T=$ROOT/$REL
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
cd "$ROOT" || exit 1

[ -f "$ROOT/$REL_TOOL" ] || { echo "the checker is missing: $REL_TOOL"; exit 1; }

# check <label> <want-rc> <want-substring> <manifest> <pin>
# The status is captured from the checker itself, not from the `tr` that cleans its output.
check() {
    local label=$1 want=$2 substr=$3 manifest=$4 pin=$5
    local out rc
    out=$("$PY" "$REL_TOOL" --manifest "$manifest" --pin "$pin" 2>&1); rc=$?
    out=$(printf '%s' "$out" | tr -d '\r')
    if [ "$rc" != "$want" ]; then bad "$label: rc=$rc, wanted $want (out: $out)"; return; fi
    case "$out" in
        *"$substr"*) ok "$label (rc=$rc) -- $out" ;;
        *) bad "$label: rc=$want but the line does not say '$substr': $out" ;;
    esac
}

# A pin of the PDK's shape: one config per category, `test_switches:` at column 0, fixtures at two
# spaces, switches at four, comments of their own, and the PDK's habit of writing `name :`.
P=$REL/pin
mkdir -p "$P/testing/unit/mos_devices/config" "$P/testing/unit/mimcap_devices/config"
cat > "$P/testing/unit/mos_devices/config/default.yaml" <<'YAML'
# SPDX-FileCopyrightText: Copyright 2026 GlobalFoundries PDK Authors
# SPDX-License-Identifier: Apache License 2.0
test_switches:
  nfet_05v0:
    combine: true
  nfet_05v0_dn :
    combine: true
    consider_dn_dw_features: true
    implicit_connect: true
  pfet_05v0:
    combine: true
    implicit_connect: true   # the digits never join without it
  nfet_03v3:
    combine: true
YAML
cat > "$P/testing/unit/mimcap_devices/config/default.yaml" <<'YAML'
test_switches:
  cap_mim_2f0fF_B_5LM_2p0:
    mim_option: "B"
    metal_level: "5LM"
    mim_cap: "2"
YAML

# The manifests, one per case. Tabs, as the real file has.
printf '%s\t%s\n' \
    mos_devices/nfet_05v0        'combine=true' \
    mos_devices/nfet_05v0_dn     'consider_dn_dw_features=true,combine=true,implicit_connect=true' \
    mos_devices/pfet_05v0        'combine=true,implicit_connect=true' \
    mimcap_devices/cap_mim_2f0fF_B_5LM_2p0 'mim_option=B,metal_level=5LM,mim_cap=2' \
    > "$REL/good.tsv"

grep -v '^mos_devices/nfet_05v0_dn' "$REL/good.tsv" > "$REL/dropped.tsv"
printf 'mos_devices/nfet_05v0_dn\t%s\n' 'combine=true,implicit_connect=true' >> "$REL/dropped.tsv"

sed 's/^mos_devices\/pfet_05v0\t.*/mos_devices\/pfet_05v0\tcombine=true,implicit_connect=true,metal_top=6K/' \
    "$REL/good.tsv" > "$REL/invented.tsv"
sed 's/^\(mimcap_devices[^\t]*\t.*\)mim_cap=2/\1mim_cap=1.5/' "$REL/good.tsv" > "$REL/value.tsv"
printf 'mos_devices/nfet_06v0\tcombine=true\n' > "$REL/noentry.tsv"
printf 'mos_devices/nfet_05v0\tcombine\n' > "$REL/malformed.tsv"
printf 'mos_devices/nfet_05v0\tcombine=true\nmos_devices/nfet_05v0\tcombine=true\n' > "$REL/dup.tsv"
printf '# nothing here but a comment\n' > "$REL/empty.tsv"
printf 'res_devices/nwell\tcombine=true\n' > "$REL/nocategory.tsv"

echo "== the checker, on a pin of the PDK's shape =="
check "the manifest's switch sets are the config's" 0 "PASS 4/4" "$REL/good.tsv" "$P"
check "a switch the manifest drops" 1 \
    "nfet_05v0_dn: the config sets consider_dn_dw_features=true, the manifest does not" \
    "$REL/dropped.tsv" "$P"
check "a switch the manifest invents" 1 \
    "pfet_05v0: manifest asks metal_top=6K, the config sets no metal_top" \
    "$REL/invented.tsv" "$P"
check "a switch whose value moved" 1 "manifest asks '1.5', the config says '2'" \
    "$REL/value.tsv" "$P"
check "a switch on a fixture the config does not name" 1 \
    "nfet_06v0: manifest asks combine=true, the config sets no combine" \
    "$REL/noentry.tsv" "$P"

echo "== a config it cannot read is not agreement =="
check "a manifest line that is not key=value" 2 "is not key=value" "$REL/malformed.tsv" "$P"
check "the same fixture twice" 2 "appears twice" "$REL/dup.tsv" "$P"
check "a manifest with no fixtures in it" 2 "no fixtures named" "$REL/empty.tsv" "$P"
check "a category with no config file" 2 "the pin has no" "$REL/nocategory.tsv" "$P"

mkdir -p "$REL/bad_pin/testing/unit/flow_devices/config"
printf 'test_switches: {nfet_05v0: {combine: true}}\n' \
    > "$REL/bad_pin/testing/unit/flow_devices/config/default.yaml"
printf 'flow_devices/nfet_05v0\tcombine=true\n' > "$REL/flow.tsv"
check "a flow mapping the reader does not implement" 2 "only 'test_switches:'" "$REL/flow.tsv" "$REL/bad_pin"

mkdir -p "$REL/two_keys_pin/testing/unit/flow_devices/config"
printf 'test_switches:\n  nfet_05v0:\n    combine: true\nscaling: 2\n' \
    > "$REL/two_keys_pin/testing/unit/flow_devices/config/default.yaml"
check "a second top-level key" 2 "only 'test_switches:'" "$REL/flow.tsv" "$REL/two_keys_pin"

mkdir -p "$REL/deep_pin/testing/unit/flow_devices/config"
printf 'test_switches:\n  nfet_05v0:\n    combine: true\n      nested: true\n' \
    > "$REL/deep_pin/testing/unit/flow_devices/config/default.yaml"
check "a third level" 2 "unexpected indentation" "$REL/flow.tsv" "$REL/deep_pin"

mkdir -p "$REL/tab_pin/testing/unit/flow_devices/config"
printf 'test_switches:\n\tnfet_05v0:\n\t\tcombine: true\n' \
    > "$REL/tab_pin/testing/unit/flow_devices/config/default.yaml"
check "tab indentation" 2 "tab indentation" "$REL/flow.tsv" "$REL/tab_pin"

# The refresh has to stop at the same place, for the same reason -- and it must not be possible to
# walk past that with --update (which accepts a stale family) or --only (which narrows what runs).
echo "== the refresh, on a pin whose config disagrees =="
if ! command -v docker >/dev/null 2>&1; then
    na "no docker on PATH, so the refresh's own check (which runs after its docker probe) is not exercised"
else
    R=$REL/fake_pin
    mkdir -p "$R/rule_decks"
    : > "$R/gf180mcu.lvs"
    printf 'repo  example/pdk\nref   %s\n' "$(printf 'a%.0s' $(seq 1 40))" > "$R/PIN.txt"
    mkdir -p "$R/testing/unit/mos_devices/config"
    printf 'test_switches:\n  nfet_05v0:\n    combine: true\n    implicit_connect: true\n' \
        > "$R/testing/unit/mos_devices/config/default.yaml"

    refresh() {
        local label=$1 want=$2 substr=$3; shift 3
        local out rc
        out=$(bash "$REL_REFRESH" --pin "$R" --manifest "$REL/refresh.tsv" --out "$REL/out" "$@" 2>&1)
        rc=$?
        out=$(printf '%s' "$out" | tr -d '\r')
        if [ "$rc" != "$want" ]; then bad "$label: rc=$rc, wanted $want (out: $out)"; return; fi
        case "$out" in
            *"$substr"*) ok "$label (rc=$rc)" ;;
            *) bad "$label: rc=$want but the line does not say '$substr': $out" ;;
        esac
        case "$out" in
            *"LVS: PASS"*) bad "$label: a fixture ran before the check stopped it" ;;
            *) [ -d "$REL/out" ] && bad "$label: the check ran after the output directory was made" \
                                  || ok "$label: no fixture ran and no output was created" ;;
        esac
    }

    printf 'mos_devices/nfet_05v0\tcombine=true\n' > "$REL/refresh.tsv"
    refresh "a manifest line that drops the config's implicit_connect" 1 "LVS-SWITCHES: MISMATCH"
    refresh "and --update does not accept it" 1 "LVS-EVIDENCE: SWITCHES" --update
    refresh "and --only does not look away from it" 1 "LVS-EVIDENCE: SWITCHES" --only 'mos_devices/*'
fi

# The real pin, when the fetcher has run on this box. On a CI checkout it has not, and the synthetic
# pin above is the whole test.
echo "== the real pin, when there is one =="
if [ -f "$S/.lvs_pin/testing/unit/mos_devices/config/default.yaml" ]; then
    check "every line of the real manifest agrees with the real pin" 0 "PASS 51/51" \
        "$S/lvs_fixtures.tsv" "$S/.lvs_pin"
    # The negative case on the real thing: the committed manifest with one switch taken off one
    # diode, which is the edit a person would make while "fixing" a mismatch.
    sed 's#^diode_devices/diode_nd2ps_03v3_dn	.*#diode_devices/diode_nd2ps_03v3_dn#' \
        "$S/lvs_fixtures.tsv" > "$REL/real_tampered.tsv"
    check "the real manifest with one diode's switch removed" 1 \
        "diode_nd2ps_03v3_dn: the config sets consider_dn_dw_features=true, the manifest does not" \
        "$REL/real_tampered.tsv" "$S/.lvs_pin"
else
    na "no fetched pin here (build/.lvs_pin), so the real manifest is not checked in this run"
fi

echo
echo "LVS_SWITCH_CHECK_SELFTEST pass=$PASS fail=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
