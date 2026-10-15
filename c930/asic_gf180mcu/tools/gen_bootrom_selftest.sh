#!/bin/sh
# gen_bootrom_selftest.sh -- prove the committed boot ROM is a reproducible build
# product of the committed firmware hex, so a clone can rebuild it without guessing.
#
#   sh tools/gen_bootrom_selftest.sh                    # check the committed ROM
#   GEN_BOOTROM_REGEN=1 sh tools/gen_bootrom_selftest.sh
#                                                       # regenerate in place with
#                                                       # the generator's defaults,
#                                                       # then run the same checks
#
# WHAT IT PROVES
#   * c930/asic_gf180mcu/openlane2_rtl/src/grx930_test_chip_rom.sv is a
#     byte-for-byte reproduction of tools/gen_bootrom.py run on the committed
#     c930/sw/test_chip_boot.hex -- the ROM in the tapeout RTL is the firmware the
#     boot test preloads, not a hand-edited file that has drifted from it;
#   * the generator's defaults (no arguments) are exactly those two paths, resolved
#     relative to the script, so a clone needs no arguments and no particular
#     working directory;
#   * the output is a FUNCTION of the input: changing one hex word changes the ROM
#     (a generator that ignored its input, or read some other file, would still
#     pass the identity check above and fails here);
#   * the committed file's header names the generator and the hex it came from,
#     and the path it names resolves;
#   * ROM line 0 in the committed file packs the hex's first eight words
#     little-endian, word j at bits [32*j +: 32] -- content, not just provenance;
#   * an image larger than the 1 KB ROM is REFUSED (non-zero exit, both sizes
#     named) rather than silently truncated: firmware that grows past 32 lines must
#     stop the build, not boot partial code;
#   * the check is not vacuous -- edit any byte of the committed ROM and the
#     identity check above fails (that is how it was verified in the first place).
#
# WHAT IT DOES NOT PROVE
#   That the ROM boots. That is the simulation (make sim SIM_PLUSARGS=+NO_PRELOAD)
#   and its -DROM_DISABLE negative control, plus the flow that consumes the netlist.
#   This file is only about reproducibility.
#
# WHEN TO RUN IT
#   After any change to the firmware (.S or .hex), to gen_bootrom.py, or to the
#   committed ROM. Seconds, no toolchain, no PDK -- python3 only.
set -u

# Every python here runs with bytecode caching off: the check imports the
# generator by path, and __pycache__/ is not ignored in this repo, so a check that
# left one behind would dirty `git status` on every run.
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GF=$(cd -- "$HERE/.." && pwd)                       # c930/asic_gf180mcu
GEN=$HERE/gen_bootrom.py
HEX=$GF/../sw/test_chip_boot.hex
ROM=$GF/openlane2_rtl/src/grx930_test_chip_rom.sv

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
chk() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

# --- interpreter --------------------------------------------------------------
# python3 first, but on Windows the Store alias is a stub that prints a message
# and exits non-zero, so each candidate has to answer a real question first.
PY=""
for c in ${PYTHON:-} python3 python3.13 python3.12 python; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1 &&
       "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PY=$c
        break
    fi
done
[ -n "$PY" ] || { echo "SELFTEST: no usable python3 (set PYTHON=/path/to/python3)"; exit 2; }
echo "SELFTEST python=$PY ($("$PY" --version 2>&1))"

# --- the three files this is about -------------------------------------------
for f in "$GEN" "$HEX" "$ROM"; do
    if [ -f "$f" ]; then ok "present: ${f#$GF/}"; else bad "missing: ${f#$GF/}"; fi
done
if [ ! -f "$GEN" ] || [ ! -f "$HEX" ] || [ ! -f "$ROM" ]; then
    echo "SELFTEST: cannot continue without all three files"
    exit 2
fi

T=$(mktemp -d) || { echo "SELFTEST: mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT

if [ "${GEN_BOOTROM_REGEN:-0}" = 1 ]; then
    # The documented regeneration step: the generator's own defaults, in place.
    echo "--- regenerating the committed ROM in place (GEN_BOOTROM_REGEN=1) ---"
    if "$PY" "$GEN"; then ok "gen_bootrom.py ran with no arguments"; else bad "gen_bootrom.py failed with no arguments"; fi
fi

# --- byte-for-byte reproduction ----------------------------------------------
echo "--- regenerate from the committed hex and compare ---"
if "$PY" "$GEN" "$HEX" "$T/rom.sv" > "$T/gen.log" 2>&1; then
    ok "generator exit 0 on the committed hex"
else
    bad "generator failed on the committed hex"
    sed 's/^/     /' "$T/gen.log"
fi
if [ -f "$T/rom.sv" ] && cmp -s "$T/rom.sv" "$ROM"; then
    ok "regeneration is byte-identical to the committed ROM"
else
    bad "regeneration DIFFERS from the committed ROM"
    diff -u "$ROM" "$T/rom.sv" 2>&1 | head -20 | sed 's/^/     /'
fi
if [ -f "$T/rom.sv" ]; then
    echo "     committed $(md5sum "$ROM" 2>/dev/null | awk '{print $1}')  regenerated $(md5sum "$T/rom.sv" 2>/dev/null | awk '{print $1}')  (md5)"
fi

# --- the output must depend on the input -------------------------------------
echo "--- a changed input must change the output ---"
if sed '1s/.*/deadbeef/' "$HEX" > "$T/mod.hex" 2>/dev/null &&
   [ "$(wc -l < "$T/mod.hex")" -eq "$(wc -l < "$HEX")" ]; then
    if "$PY" "$GEN" "$T/mod.hex" "$T/mod_rom.sv" >/dev/null 2>&1 && ! cmp -s "$T/mod_rom.sv" "$ROM"; then
        ok "changing hex word 0 changes the ROM (output is a function of the input)"
    else
        bad "the ROM did not change when the hex did -- is the generator reading its input?"
    fi
else
    bad "could not build the modified-hex fixture"
fi

# --- defaults, header provenance, line-0 content -----------------------------
echo "--- defaults, header provenance, line-0 content ---"
"$PY" - "$GEN" "$HEX" "$ROM" <<'PY'
import importlib.util
import os
import sys

gen, hexf, rom = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("gen_bootrom", gen)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
rc = 0


def rep(name, got, want):
    global rc
    same = os.path.realpath(got) == os.path.realpath(want)
    print("%s %s (%s)" % ("PASS" if same else "FAIL", name, got))
    if not same:
        rc = 1


rep("DEFAULT_HEX is the committed hex", m.DEFAULT_HEX, hexf)
rep("DEFAULT_OUT is the committed ROM", m.DEFAULT_OUT, rom)

txt = open(rom, encoding="utf-8").read()
header = txt.splitlines()[:12]

if any("gen_bootrom.py" in l for l in header):
    print("PASS the ROM header names its generator")
else:
    print("FAIL the ROM header does not name tools/gen_bootrom.py")
    rc = 1

named = [l for l in header if ".hex" in l]
if named:
    rel = named[0].split("from")[-1].split(".hex")[0].strip() + ".hex"
    target = os.path.normpath(os.path.join(os.path.dirname(rom), rel))
    if os.path.isfile(target):
        print("PASS the hex the header names resolves (%s)" % target)
    else:
        print("FAIL the hex the header names does not resolve (%s)" % target)
        rc = 1
else:
    print("FAIL the ROM header does not name the hex it came from")
    rc = 1

words = m.read_hex(hexf)
val = 0
for j, w in enumerate(words[:8]):
    val |= w << (32 * j)
needle = "5'd0: rom_line = 256'h%064x;" % val
if needle in txt:
    print("PASS ROM line 0 packs the hex's first 8 words little-endian (%s)" % needle)
else:
    print("FAIL ROM line 0 does not pack the hex's first 8 words (expected %s)" % needle)
    rc = 1

sys.exit(rc)
PY
chk $? "generator defaults, header provenance and line-0 content"

# --- firmware that outgrows the ROM is refused -------------------------------
echo "--- an oversized image must be refused, not truncated ---"
"$PY" - "$HEX" "$T/big.hex" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
words = [l.strip() for l in open(src) if l.strip()]
with open(dst, "w") as f:                       # 257 words > 32 lines x 8 words
    f.write("\n".join((words * 8)[:257]) + "\n")
PY
if "$PY" "$GEN" "$T/big.hex" "$T/big.sv" > "$T/big.log" 2>&1; then
    bad "the generator accepted a 257-word image for a 256-word ROM"
else
    ok "the generator refused the 257-word image (non-zero exit)"
fi
if grep -q "ERROR" "$T/big.log" 2>/dev/null && grep -q "1024" "$T/big.log" 2>/dev/null; then
    ok "the refusal names both sizes ($(head -1 "$T/big.log"))"
else
    bad "the refusal does not name both sizes: $(head -1 "$T/big.log")"
fi
if [ -f "$T/big.sv" ]; then bad "a partial output was written anyway ($T/big.sv)"; else ok "no partial output left behind"; fi

echo
echo "gen_bootrom_selftest: $pass passed, $fail failed"
if [ "$fail" != 0 ]; then
    echo "SELFTEST rc=1"
    exit 1
fi
echo "committed ROM is reproducible from the committed hex:"
echo "  $ROM"
echo "SELFTEST rc=0"
exit 0
