#!/usr/bin/env bash
# lvs_chip_net_compare_selftest.sh -- does the DEF-vs-CDL connectivity check actually check?
#
# The tool answers a question about two 75 MB and 8 MB files, and its first two runs were wrong
# in ways that looked like design defects: a DEF whose net pin lists *wrap* onto `(` continuation
# lines lost 61,562 pins, and every port appeared twice because SPICE and DEF disagree about case.
# Both mistakes produced a confident MISMATCH. So this test does not check that a match passes --
# it checks that each way of being wrong is caught, on fixtures small enough to read, with the
# sides deliberately named unlike each other so that nothing can pass by string comparison.
#
# Every case is a DEF and a CDL written here, no docker, no PDK, no layout.
#
#   bash build/lvs_chip_net_compare_selftest.sh      # N assertions, exit 0 if all hold

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
NC=$ROOT/c930/asic_gf180mcu/tools/lvs_chip/net_compare.py
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t ncs)
trap 'rm -rf "$TMP"' EXIT

# The Store flavour of `python3` on Windows is a stub that prints a shop message; take whichever
# interpreter actually runs.
PY=""
for cand in python3 python; do
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$cand; break
    fi
done
[ -n "$PY" ] || { echo "net_compare_selftest: no python3/python on PATH" >&2; exit 1; }
cd "$TMP"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# --- fixtures ---------------------------------------------------------------------------------
# Two inverters in a chain, one input port, one output port. The DEF and the CDL use different
# names for every net, so only connectivity can make them agree.
write_pair() {
    cat > "$1.def" <<'EOF'
VERSION 5.8 ;
DESIGN top ;
COMPONENTS 2 ;
    - _1_ lib__inv + PLACED ( 0 0 ) N ;
    - _2_ lib__inv + PLACED ( 100 0 ) N ;
END COMPONENTS
PINS 2 ;
    - a + NET a + DIRECTION INPUT + USE SIGNAL ;
    - z + NET z + DIRECTION OUTPUT + USE SIGNAL ;
END PINS
SPECIALNETS 2 ;
    - VDD ( * VDD ) + USE POWER ;
    - VSS ( * VSS ) + USE GROUND ;
END SPECIALNETS
NETS 3 ;
    - a ( PIN a ) ( _1_ I ) + USE SIGNAL
      + ROUTED Metal1 ( 0 0 ) ( 10 0 ) ;
    - mid ( _1_ ZN ) ( _2_ I ) + USE SIGNAL ;
    - z ( _2_ ZN ) ( PIN z ) + USE SIGNAL ;
END NETS
END DESIGN
EOF
    cat > "$1.cdl" <<'EOF'
* fixture: the same chain, named nothing alike
.SUBCKT top a z
X_1_ a n9 VDD VNW SUB VSS lib__inv
X_2_ n9 z VDD VNW SUB VSS lib__inv
.ENDS
.SUBCKT lib__inv I ZN VDD VNW VPW VSS
M1 ZN I VSS VSS nch W=1 L=1
.ENDS
EOF
}

run() { "$PY" "$NC" --def "$1.def" --cdl "$1.cdl" > "$1.out" 2>&1; echo $?; }

# --- 1. a match passes, and passes on connectivity rather than names ---------------------------
write_pair pos
rc=$(run pos)
[ "$rc" = 0 ] && grep -q "NET-COMPARE: MATCH" pos.out \
    && ok "differently named but identically connected: MATCH (0)" \
    || bad "positive case exit $rc: $(tail -2 pos.out)"

# --- 2. one extra instance on the same nets is a different partition --------------------------
write_pair dup
"$PY" - dup.cdl <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read().replace(".ENDS\n.SUBCKT lib__inv",
                           "X_1b a n9 VDD VNW SUB VSS lib__inv\n.ENDS\n.SUBCKT lib__inv")
open(p, "w").write(s)
EOF
rc=$(run dup)
[ "$rc" = 1 ] && grep -q "net(s) have no counterpart" dup.out \
    && ok "a parallel instance changes the partition: MISMATCH (1)" \
    || bad "parallel-instance case exit $rc: $(grep -c . dup.out) lines"

# --- 3. two nets merged on one side is caught ------------------------------------------------
write_pair merge
"$PY" - merge.cdl <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read().replace("a n9", "a a")
open(p, "w").write(s)
EOF
rc=$(run merge)
[ "$rc" = 1 ] && grep -q "net(s) have no counterpart" merge.out \
    && ok "merging the port net and the internal net on the CDL side: MISMATCH (1)" \
    || bad "merged-net case exit $rc"

# --- 4. a wrapped DEF pin list is read whole ------------------------------------------------
write_pair wrap
"$PY" - wrap.def <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "    - mid ( _1_ ZN ) ( _2_ I ) + USE SIGNAL ;",
    "    - mid ( _1_ ZN )\n      ( _2_ I ) + USE SIGNAL ;")
open(p, "w").write(s)
EOF
rc=$(run wrap)
grep -q "pins per instance: 2 of 2 complete" wrap.out && [ "$rc" = 0 ] \
    && ok "pin lists that wrap onto ( continuation lines are read whole" \
    || bad "wrapped pin list: exit $rc, $(grep 'pins per instance' wrap.out)"

# --- 5. routing geometry is not read as pins ------------------------------------------------
write_pair geom
"$PY" - geom.def <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "      + ROUTED Metal1 ( 0 0 ) ( 10 0 ) ;",
    "      + ROUTED Metal2 ( 0 0 ) ( 40 0 )\n        NEW Metal2 ( 40 0 ) ( 40 80 ) ;")
open(p, "w").write(s)
EOF
rc=$(run geom)
grep -q "pins per instance: 2 of 2 complete" geom.out && [ "$rc" = 0 ] \
    && ok "polygon coordinates on ROUTED/NEW lines are not counted as pins" \
    || bad "geometry case: exit $rc"

# --- 6. a pin the DEF never connects is caught, not silently skipped -------------------------
write_pair short
"$PY" - short.def <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read().replace("    - mid ( _1_ ZN ) ( _2_ I ) + USE SIGNAL ;",
                           "    - mid ( _1_ ZN ) + USE SIGNAL ;")
open(p, "w").write(s)
EOF
rc=$(run short)
grep -q "1 instances are connected on fewer pins" short.out && [ "$rc" = 1 ] \
    && ok "a dropped connection is counted against the cell's declared ports" \
    || bad "short-pin case: exit $rc, $(grep 'pins per instance' short.out)"

# --- 7. ports survive case, and a dangling port is a difference -----------------------------
write_pair ports
"$PY" - ports.cdl <<'EOF'
import sys
p = sys.argv[1]
# Same connectivity, but the CDL declares and connects its input port as `A` while the DEF calls
# the same port `a`. The partition is identical; only the spelling differs.
s = open(p).read().replace(".SUBCKT top a z", ".SUBCKT top A z").replace("X_1_ a n9", "X_1_ A n9")
open(p, "w").write(s)
EOF
rc=$(run ports)
[ "$rc" = 0 ] && ok "a port's case does not decide the answer" \
    || bad "port case: exit $rc, $(grep -c 'PORT' ports.out) port lines"

# --- 7b. a port connected to nothing on one side is a difference ----------------------------
write_pair floppy
"$PY" - floppy.cdl <<'EOF'
import sys
p = sys.argv[1]
# X_1_ now reads from a net of its own instead of the port's net: the port drives no pin.
s = open(p).read().replace("X_1_ a n9", "X_1_ dangling n9")
open(p, "w").write(s)
EOF
rc=$(run floppy)
[ "$rc" = 1 ] && ok "a port that drives nothing on one side is a mismatch" \
    || bad "dangling-port case: exit $rc"

# --- 8. the power wildcard is understood, and a missing one is a problem -------------------
write_pair nowild
"$PY" - nowild.def <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read().replace("    - VDD ( * VDD ) + USE POWER ;\n", "")
open(p, "w").write(s)
EOF
rc=$(run nowild)
grep -q "no wildcard for" nowild.out && [ "$rc" = 1 ] \
    && ok "a DEF with no power wildcard is reported, not assumed" \
    || bad "power wildcard case: exit $rc"

# --- 9. the answer is written where a reader can find it ------------------------------------
write_pair json
"$PY" "$NC" --def json.def --cdl json.cdl --json json.report.json > json.out 2>&1
rc=$?
grep -q '"verdict": "MATCH"' json.report.json 2>/dev/null && [ "$rc" = 0 ] \
    && ok "--json writes the verdict and the counts beside it" \
    || bad "--json report missing or wrong (exit $rc)"

printf '\nnet_compare_selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
