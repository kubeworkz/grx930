#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# stage1_readiness_selftest.sh -- deterministic checks for stage1_readiness.sh.
#
# The gate has three numeric floors and one evidence contract. The selftest
# injects a synthetic /proc/meminfo and stubs df, so the exact boundaries are
# tested rather than the memory and disk of whatever host runs this script:
#
#   * 12 GiB pre-DRT: 12,288 MiB passes, 12,287 MiB fails
#   * 8 GiB DRT arm: 8,192 MiB passes, 8,191 MiB fails
#   * 150 GiB volume: 150 GiB passes, 149 GiB fails
#   * a failed gate still writes status=FAIL and the reason before exiting 1
#
# No container, flow step, or real disk/memory probe is used. The test writes
# only inside its temporary directory and exits non-zero if any assertion fails.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/stage1_readiness.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/stage1_readiness_selftest.XXXXXX") || exit 1
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
chk() {  # chk LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1: expected [$2] got [$3]"; fi
}
field() {  # field FILE KEY -> value after the first '='
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}
has() {  # has FILE STRING LABEL
    if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 -- missing: $2"; fi
}
exists() {  # exists FILE LABEL
    if [ -e "$1" ]; then ok "$2"; else bad "$2 -- absent: $1"; fi
}

mkdir -p "$T/bin" "$T/volume"
cat > "$T/bin/df" <<'SH'
#!/bin/sh
# The gate passes `-Pk -- <volume>`; the fixture ignores the arguments.
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 200000000 1000 %s 1%% /fixture\n' "${STUB_AVAIL_KB:-157286400}"
SH
chmod +x "$T/bin/df"

meminfo() {  # meminfo FILE AVAILABLE_KB
    cat > "$1" <<EOF
MemTotal: 16777216 kB
MemFree: $2 kB
MemAvailable: $2 kB
SwapTotal: 0 kB
SwapFree: 0 kB
EOF
}

run_gate() {  # run_gate NAME MEMINFO AVAILABLE_KB -> exit code
    local name=$1 mem=$2 avail_kb=$3
    : > "$T/$name.out"
    STUB_AVAIL_KB="$avail_kb" PATH="$T/bin:$PATH" \
        bash "$SCRIPT" --meminfo "$mem" --volume "$T/volume" \
        --record "$T/$name.txt" > "$T/$name.out" 2>&1
    printf '%s' "$?"
}

echo '=== 1. 12 GiB pre-DRT boundary: exactly 12,288 MiB ==='
meminfo "$T/mem-12288" 12582912
rc=$(run_gate pre-drt-boundary "$T/mem-12288" 157286400)
chk '12 GiB exactly exits 0' 0 "$rc"
chk '12 GiB exactly pre-DRT PASS' PASS "$(field "$T/pre-drt-boundary.txt" mem.pre_drt)"
chk '12 GiB exactly DRT-arm PASS' PASS "$(field "$T/pre-drt-boundary.txt" mem.drt_arm)"
chk '150 GiB exactly disk PASS' PASS "$(field "$T/pre-drt-boundary.txt" disk)"
chk 'all three floors status PASS' PASS "$(field "$T/pre-drt-boundary.txt" status)"

echo
echo '=== 2. 12 GiB pre-DRT boundary: one MiB below fails ==='
meminfo "$T/mem-12287" 12581888
rc=$(run_gate pre-drt-low "$T/mem-12287" 157286400)
chk '12 GiB minus one MiB exits 1' 1 "$rc"
chk '12 GiB minus one MiB pre-DRT FAIL' FAIL "$(field "$T/pre-drt-low.txt" mem.pre_drt)"
chk '12 GiB minus one MiB DRT-arm still PASS' PASS "$(field "$T/pre-drt-low.txt" mem.drt_arm)"
has "$T/pre-drt-low.txt" 'pre_drt_below_12288MiB' 'pre-DRT reason recorded'

echo
echo '=== 3. 8 GiB DRT-arm boundary: exactly 8,192 MiB ==='
meminfo "$T/mem-8192" 8388608
rc=$(run_gate drt-boundary "$T/mem-8192" 157286400)
chk '8 GiB exactly exits 1 (pre-DRT is below its own floor)' 1 "$rc"
chk '8 GiB exactly DRT-arm PASS' PASS "$(field "$T/drt-boundary.txt" mem.drt_arm)"
chk '8 GiB exactly pre-DRT FAIL' FAIL "$(field "$T/drt-boundary.txt" mem.pre_drt)"
chk '8 GiB exactly status FAIL' FAIL "$(field "$T/drt-boundary.txt" status)"

echo
echo '=== 4. 8 GiB DRT-arm boundary: one MiB below fails ==='
meminfo "$T/mem-8191" 8387584
rc=$(run_gate drt-low "$T/mem-8191" 157286400)
chk '8 GiB minus one MiB exits 1' 1 "$rc"
chk '8 GiB minus one MiB DRT-arm FAIL' FAIL "$(field "$T/drt-low.txt" mem.drt_arm)"
has "$T/drt-low.txt" 'drt_arm_below_8192MiB' 'DRT-arm reason recorded'

echo
echo '=== 5. 150 GiB volume boundary: exactly 150 GiB ==='
meminfo "$T/mem-pass" 16777216
rc=$(run_gate volume-boundary "$T/mem-pass" 157286400)
chk '150 GiB exactly exits 0' 0 "$rc"
chk '150 GiB exactly disk PASS' PASS "$(field "$T/volume-boundary.txt" disk)"
chk '150 GiB exactly available_gb 150' 150 "$(field "$T/volume-boundary.txt" disk.available_gb)"

echo
echo '=== 6. 150 GiB volume boundary: just below fails ==='
rc=$(run_gate volume-low "$T/mem-pass" 157286399)
chk '149 GiB exits 1' 1 "$rc"
chk '149 GiB disk FAIL' FAIL "$(field "$T/volume-low.txt" disk)"
chk '149 GiB available_gb 149' 149 "$(field "$T/volume-low.txt" disk.available_gb)"
has "$T/volume-low.txt" 'volume_below_150GiB' 'volume reason recorded'

echo
echo '=== 7. failure-record path ==='
exists "$T/pre-drt-low.txt" 'failure record exists after exit 1'
chk 'failure record status FAIL' FAIL "$(field "$T/pre-drt-low.txt" status)"
chk 'failure record preserves available MiB' 12287 "$(field "$T/pre-drt-low.txt" mem.available_mb)"
has "$T/pre-drt-low.out" 'STAGE1_READINESS FAIL' 'failure is reported on stderr/stdout'

echo
if [ "$FAIL" -eq 0 ]; then
    printf 'STAGE1_READINESS_SELFTEST pass=%s fail=0\n' "$PASS"
else
    printf 'STAGE1_READINESS_SELFTEST FAIL pass=%s fail=%s\n' "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ]
