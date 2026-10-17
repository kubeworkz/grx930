#!/bin/bash
# lvs_check_selftest.sh -- the LVS gate's own test: does it still tell the three answers apart?
#
#   bash build/lvs_check_selftest.sh      # 0 = the gate holds, 1 = it drifted
#
# WHY THIS EXISTS
#
#   build/lvs_check.sh exists for one reason: "we have no verdict" and "the verdict is bad" must
#   never look the same coming out of a tapeout gate. That property is invisible from a green run
#   -- a gate that answers CANNOT-RUN for everything still passes nothing, and a gate that answers
#   PASS for everything passes the day it matters. So every status is provoked here on purpose,
#   from reports derived from the real committed evidence, and the command that has to produce the
#   verdict is the file the table actually runs.
#
# WHAT IT COVERS
#
#   family (the committed shape)
#     pass          all fixtures green, with and without the pinned deck present
#     mismatch (1)  one fixture's devices disagree; one fixture's ports disagree
#     cannot-run(2) one fixture skipped its port check; a family with no fixtures in it
#     stale  (1)    the deck on disk is not the deck the family records
#   single report (what a chip run produces)
#     pass          green report, whose own layout/netlist hashes are checked
#     mismatch (1)  devices disagree; ports disagree with the missing port named; a report about
#                   different inputs than the ones on disk (a stale green)
#     cannot-run(2) no report; unreadable report; a report missing a field; a report whose port
#                   check was skipped; a report that records no hash for an input it is judged
#                   against
#   wiring
#     the gate passes those statuses through, and chip_gates.sh still lists the gate
#
#   No docker, no PDK, no layout of our own: every input is a file this test writes, derived from
#   the committed evidence. Runs in about a second.
set -u
S=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$S/../../.." && pwd)

# Relative paths for everything handed to the interpreter: a native Windows python cannot open an
# MSYS `/c/...` path, and the judge is run by this script directly as well as through the gate.
REL_TOOLS=c930/asic_gf180mcu/tools/lvs_verdict.py
REL_GATE=c930/asic_gf180mcu/build/lvs_check.sh
FAMILY=$S/lvs/lvs_fixtures_verdict.json

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

# Everything lives under the repo and is reached by a relative path: a native Windows python cannot
# open an MSYS `/c/...` or `/tmp/...` path, and this test runs on the same box as the gate.
REL=c930/asic_gf180mcu/build/lvs_selftest.tmp
T=$ROOT/$REL
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
cd "$ROOT" || exit 1

[ -f "$FAMILY" ] || { echo "the committed family evidence is missing: $FAMILY"; exit 1; }
[ -f "$ROOT/$REL_TOOLS" ] || { echo "the judge is missing: $REL_TOOLS"; exit 1; }
[ -f "$ROOT/$REL_GATE" ] || { echo "the gate is missing: $REL_GATE"; exit 1; }

# run <label> <want-rc> <want-substring> <args...>
# The status is captured from the command itself, not from the `tr` that cleans the output: a
# pipeline's status is its last stage's, which would have made every case here look like a pass.
run() {
    local label=$1 want=$2 substr=$3; shift 3
    local out rc
    out=$("$PY" "$REL_TOOLS" "$@" 2>&1); rc=$?
    out=$(printf '%s' "$out" | tr -d '\r')
    if [ "$rc" != "$want" ]; then bad "$label: rc=$rc, wanted $want (out: $out)"; return; fi
    case "$out" in
        *"$substr"*) ok "$label (rc=$rc) -- $out" ;;
        *) bad "$label: rc=$want but the line does not say '$substr': $out" ;;
    esac
}

# The gate as the table runs it, whose statuses must be the judge's own.
run_gate() {
    local label=$1 want=$2 substr=$3; shift 3
    local out rc
    out=$(bash "$REL_GATE" "$@" 2>&1); rc=$?
    out=$(printf '%s' "$out" | tr -d '\r')
    if [ "$rc" != "$want" ]; then bad "$label: rc=$rc, wanted $want (out: $out)"; return; fi
    case "$out" in
        *"$substr"*) ok "$label (rc=$rc)" ;;
        *) bad "$label: rc=$want but the line does not say '$substr': $out" ;;
    esac
}

# The deck the family records a hash for: the pinned copy when the fetcher has run here, the PDK
# install otherwise. Absent on a CI checkout, where the judge says so and decides on the evidence's
# own content -- that path is its own case below.
DECK=$REL/../.lvs_pin/gf180mcu.lvs
[ -f "$ROOT/$DECK" ] || DECK=c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs

# The reports under test, all derived from the committed family so they differ in one field. The
# single-report fixtures are built from the family's first entry plus the shared deck, which is
# exactly what a chip run's shape looks like.
"$PY" - "$FAMILY" "$REL" <<'PY'
import copy, json, sys

family_path, rel = sys.argv[1], sys.argv[2]
base = json.load(open(family_path))

def write(name, mutate):
    d = copy.deepcopy(base)
    mutate(d)
    json.dump(d, open(f"{rel}/{name}", "w"), indent=2, sort_keys=True)

write("family_green.json", lambda d: None)
def one_bad_devices(d):
    d["fixtures"][0]["devices"]["verdict"] = "mismatch"
    d["fixtures"][0]["verdict"] = "mismatch"
    d["summary"]["match"] -= 1
    d["summary"]["mismatch"] += 1
write("family_bad_devices.json", one_bad_devices)
def one_bad_ports(d):
    fx = d["fixtures"][1]
    fx["ports"]["verdict"] = "fail"
    fx["ports"]["missing_in_layout"] = ["I1_default_GX"]
    fx["verdict"] = "mismatch"
    d["summary"]["match"] -= 1
    d["summary"]["mismatch"] += 1
write("family_bad_ports.json", one_bad_ports)
def one_skipped(d):
    d["fixtures"][2]["ports"]["checked"] = False
write("family_skipped_ports.json", one_skipped)
write("family_empty.json", lambda d: d.update(fixtures=[], summary={"total": 0, "match": 0, "mismatch": 0}))
write("family_wrong_deck.json", lambda d: d["deck"].update(sha256="0" * 64))

# The single-report shape, from the family's first fixture.
entry = base["fixtures"][0]
single = {
    "verdict": entry["verdict"],
    "devices": entry["devices"],
    "ports": dict(entry["ports"]),
    "inputs": {
        "deck": {"sha256": base["deck"]["sha256"]},
        "layout": {"sha256": entry["inputs"]["layout"]},
        "netlist": {"sha256": entry["inputs"]["netlist"]},
    },
}
def write_single(name, mutate):
    d = copy.deepcopy(single)
    mutate(d)
    json.dump(d, open(f"{rel}/{name}", "w"), indent=2, sort_keys=True)

write_single("single_green.json", lambda d: None)
write_single("single_bad_devices.json", lambda d: d["devices"].update(verdict="mismatch"))
def single_bad_ports(d):
    d["ports"]["verdict"] = "fail"
    d["ports"]["missing_in_layout"] = ["I1_default_GX"]
write_single("single_bad_ports.json", single_bad_ports)
write_single("single_skipped_ports.json", lambda d: d["ports"].update(checked=False))
write_single("single_no_layout_hash.json", lambda d: d["inputs"]["layout"].pop("sha256", None))
open(f"{rel}/garbage.json", "w").write("{not json at all\n")
open(f"{rel}/other_layout.gds", "wb").write(b"a layout that is not the one the evidence describes\n")
PY
[ $? -eq 0 ] && ok "fixture reports derived from the committed family" || bad "could not build fixtures"

echo "== the family shape (what the gate judges by default) =="
run "a green family, deck not given" 0 "LVS: PASS family=" --report "$REL/family_green.json"
if [ -f "$ROOT/$DECK" ]; then
    run "a green family with the deck it records, on disk" 0 "LVS: PASS family=" \
        --report "$REL/family_green.json" --deck "$DECK"
else
    na "no pinned or installed deck here, so the family's deck-hash branch is not exercised"
fi
run "one fixture's devices disagree" 1 "fixtures:" --report "$REL/family_bad_devices.json"
run "one fixture's ports disagree, and the missing port is named" 1 "missing I1_default_GX" \
    --report "$REL/family_bad_ports.json"
run "one fixture skipped its port check" 2 "skip the port comparison" --report "$REL/family_skipped_ports.json"
run "a family with no fixtures in it" 2 "no fixtures in it" --report "$REL/family_empty.json"
run "a family about a different deck" 1 "not about the deck on disk" \
    --report "$REL/family_wrong_deck.json" --deck "$REL/other_layout.gds"

echo "== the single-report shape (what a chip run produces) =="
run "a green report, inputs not given" 0 "LVS: PASS" --report "$REL/single_green.json"
run "a report about different inputs is a mismatch" 1 "not about the inputs on disk" \
    --report "$REL/single_green.json" --layout "$REL/other_layout.gds"
run "a report that records no hash cannot be tied to its input" 2 "records no layout hash" \
    --report "$REL/single_no_layout_hash.json" --layout "$REL/other_layout.gds"
run "devices disagree" 1 "devices: mismatch" --report "$REL/single_bad_devices.json"
run "ports disagree, and the missing port is named" 1 "I1_default_GX" --report "$REL/single_bad_ports.json"
run "a skipped port check is not evidence" 2 "skips the port comparison" --report "$REL/single_skipped_ports.json"
run "no report at all" 2 "no report at" --report "$REL/absent.json"
run "a report that is not JSON" 2 "not readable JSON" --report "$REL/garbage.json"

echo "== the gate the table runs =="
run_gate "the gate passes a green family's status through" 0 "LVS: PASS family=" --report "$REL/family_green.json"
run_gate "a checkout with no PDK inputs stays a pass, and says it was not tied to them" 0 \
    "not on disk here" --report "$REL/family_green.json" \
    --deck "$REL/absent_deck.lvs" --layout "$REL/absent.gds" --netlist "$REL/absent.cdl"
run_gate "and a mismatch's" 1 "LVS: MISMATCH" --report "$REL/family_bad_ports.json"
run_gate "and cannot-run's" 2 "LVS: CANNOT-RUN" --report "$REL/absent.json"

echo "== the wiring =="
listed=$(bash "$S/chip_gates.sh" --list 2>/dev/null | grep -c '^lvs-fixture$')
[ "$listed" = 1 ] && ok "chip_gates.sh still lists the lvs-fixture gate" \
                 || bad "lvs-fixture is not in the gate table (--list says $listed)"
row=$(grep -c '^lvs-fixture|' "$S/chip_gates.sh")
[ "$row" = 1 ] && ok "the table row is there exactly once" || bad "$row lvs-fixture rows in the table"
grep -q 'build/lvs_check.sh' "$S/chip_gates.sh" \
    && ok "the row runs this gate" || bad "the row does not run build/lvs_check.sh"
manifest=$(grep -c '^[^#[:space:]]' "$S/lvs_fixtures.tsv")
[ "$manifest" -ge 10 ] && ok "the fixture manifest still names $manifest fixtures" \
                       || bad "the fixture manifest names only $manifest fixtures"

echo
echo "LVS_CHECK_SELFTEST pass=$PASS fail=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
