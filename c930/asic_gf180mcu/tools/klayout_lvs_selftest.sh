#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# klayout_lvs_selftest.sh -- prove the LVS verdict discriminates before believing any green.
#
# Why this exists: a "Congratulations! Netlists match" line is worth nothing until something is
# able to make it say otherwise on the same pair. This runs the PDK's own nfet_05v0 fixture four
# ways -- as shipped, with one MOSFET removed from the schematic, with one top-level port renamed,
# and with the layout missing -- and requires: match, device mismatch, port mismatch with the
# devices still matching, and a setup error. The third arm is the one that justifies doing the port
# check ourselves: the deck's own `check_ports` path cannot run (undefined `flag_missing_ports`),
# so without it a renamed port would sail through as a match.
#
#   bash tools/klayout_lvs_selftest.sh
#
# Keeps its runs under lvs_runs/selftest/ unless KEEP=1 is set. Each arm starts a container; the
# three LVS arms take a minute or two each on this box.
set -u
S=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$S/../../.." && pwd)
FIXTURES=$S/../libs.tech/klayout/tech/lvs/testing/unit/mos_devices
FIX=nfet_05v0
IMAGE=${LVS_IMAGE:-ghcr.io/efabless/openlane2:2.3.10}
W=$S/../lvs_runs/selftest
MOUNT=$ROOT
command -v cygpath >/dev/null 2>&1 && MOUNT=$(cygpath -m "$ROOT")

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

in_image() { MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" -w /work "$IMAGE" "$@"; }
# jcheck <verdict.json> <python expression over d> <label>
jcheck() {
    local got
    got=$(in_image python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("OK" if (lambda d: eval(sys.argv[2]))(d) else "NO")' "/work/${1#"$ROOT"/}" "$2" 2>/dev/null)
    if [ "$got" = "OK" ]; then ok "$3"; else bad "$3 (expression: $2)"; fi
}

rm -rf "$W"; mkdir -p "$W"

echo "== arm A: the fixture as shipped must MATCH =="
bash "$S/klayout_lvs.sh" --out "$W/green"
rc=$?
[ $rc -eq 0 ] && ok "exit 0" || bad "exit $rc (wanted 0)"
J=$W/green/verdict.json
[ -f "$J" ] && ok "verdict.json written" || bad "no verdict.json"
jcheck "$J" 'd["verdict"]=="match"' "verdict is match"
jcheck "$J" 'd["devices"]["verdict"]=="match"' "device comparison matched"
jcheck "$J" 'd["devices"]["instances_extracted"]>0' "the extracted netlist has devices in it"
jcheck "$J" 'd["ports"]["missing_in_layout"]==[]' "every schematic port exists in the layout"
jcheck "$J" 'd["ports"]["checked_by"]=="klayout_lvs.py" and d["ports"]["deck_variable_defined"] is False' "port check is ours, because the deck's is dead"

echo "== arm B: one MOSFET deleted from the schematic must MISMATCH =="
# Drop one whole device statement: its `M` line and the `+` continuations that belong to it.
awk 'BEGIN{dropped=0; skip=0}
     skip && /^\+/ {next}
     { if (!dropped && /^M/) {dropped=1; skip=1; next} skip=0; print }' \
    "$FIXTURES/netlist/$FIX.cdl" > "$W/broken_devices.cdl"
NDEL=$(( $(grep -c '^M' "$FIXTURES/netlist/$FIX.cdl") - $(grep -c '^M' "$W/broken_devices.cdl") ))
[ "$NDEL" -eq 1 ] && ok "exactly one device statement removed" || bad "$NDEL device statements removed"
bash "$S/klayout_lvs.sh" --netlist "$W/broken_devices.cdl" --out "$W/red_devices" > "$W/red_devices.out" 2>&1
rc=$?
[ $rc -eq 1 ] && ok "exit 1" || bad "exit $rc (wanted 1)"
jcheck "$W/red_devices/verdict.json" 'd["verdict"]=="mismatch" and d["devices"]["verdict"]=="mismatch"' "verdict and devices both mismatch"

echo "== arm C: one top-level port renamed must MISMATCH on ports, not on devices =="
sed 's/I1_default_G\b/I1_default_GX/g' "$FIXTURES/netlist/$FIX.cdl" > "$W/renamed_port.cdl"
grep -q 'I1_default_GX' "$W/renamed_port.cdl" && ok "port renamed in the schematic" || bad "port rename did not apply"
bash "$S/klayout_lvs.sh" --netlist "$W/renamed_port.cdl" --out "$W/red_ports" > "$W/red_ports.out" 2>&1
rc=$?
[ $rc -eq 1 ] && ok "exit 1" || bad "exit $rc (wanted 1)"
jcheck "$W/red_ports/verdict.json" 'd["ports"]["verdict"]=="fail" and "I1_default_GX" in d["ports"]["missing_in_layout"]' "the renamed port is reported missing in the layout"
jcheck "$W/red_ports/verdict.json" 'd["devices"]["verdict"]=="match"' "the device comparison still matches, so only the port check catches this"

echo "== arm D: a missing layout is a setup error, not a verdict =="
bash "$S/klayout_lvs.sh" --layout "$W/does_not_exist.gds" --out "$W/missing" > "$W/missing.out" 2>&1
rc=$?
[ $rc -eq 2 ] && ok "exit 2" || bad "exit $rc (wanted 2)"
[ -f "$W/missing/verdict.json" ] && bad "a verdict was written without a layout" || ok "no verdict written"

echo
echo "passed $PASS, failed $FAIL  (runs in ${W#"$ROOT"/})"
[ "${KEEP:-0}" = 1 ] || rm -rf "$W"
[ $FAIL -eq 0 ]
