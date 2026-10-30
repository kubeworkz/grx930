#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# build_test_chip_fw.sh [OUT_HEX] -- build the grx930_test_chip boot firmware.
#
# Toolchain: riscv64-unknown-elf-gcc (or riscv64-linux-gnu-gcc / riscv-none-elf-gcc);
# override with CROSS_COMPILE. Flags follow this repo's other pure-assembly
# firmware (c930/Makefile, mul_store_test.S): -nostdlib -ffreestanding
# -Wl,--build-id=none -Ttext=0 -x assembler-with-cpp. The chip's core is RV64IMAC
# and the source is .option norvc, so every instruction is 4 bytes.
#
# Output: sw/test_chip_boot.hex by default -- one 32-bit little-endian word per
# line at consecutive addresses from 0, which is what sw/bin2hex.py writes and
# what the classic testbenches here read with $readmemh.
#
# The image must fit the chip's 2 KB SRAM below the firmware's runtime data: the
# magic word at 0x400 and the stack at 0x700, so the script fails past 0x3F0.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/test_chip_boot.hex}
BIN=${OUT%.hex}.bin
ELF=${OUT%.hex}.elf

if [ -n "${CROSS_COMPILE:-}" ]; then
  CC="${CROSS_COMPILE}gcc"
else
  CC=""
  for c in riscv64-unknown-elf-gcc riscv64-linux-gnu-gcc riscv-none-elf-gcc; do
    if command -v "$c" >/dev/null 2>&1; then CC=$c; break; fi
  done
fi
if [ -z "$CC" ] || ! command -v "$CC" >/dev/null 2>&1; then
  echo "ERROR: no RISC-V toolchain found (riscv64-unknown-elf-gcc," >&2
  echo "       riscv64-linux-gnu-gcc, riscv-none-elf-gcc; or set CROSS_COMPILE)." >&2
  echo "       The checked-in $OUT is current for sw/test_chip_boot.S." >&2
  exit 127
fi
# Ask the compiler driver for its own binutils: deriving the name from the CC
# filename breaks when only gcc is symlinked (e.g. riscv64-unknown-elf-gcc ->
# riscv64-linux-gnu-gcc has no riscv64-unknown-elf-objcopy), and a plain host
# objcopy then fails with "Unable to recognise the format".
tool() {
  t=$("$CC" -print-prog-name="$1" 2>/dev/null || true)
  if [ -n "$t" ] && command -v "$t" >/dev/null 2>&1; then echo "$t"; return 0; fi
  t=$("$CC" -dumpmachine)-"$1"
  if command -v "$t" >/dev/null 2>&1; then echo "$t"; return 0; fi
  return 1
}
OBJCOPY=$(tool objcopy)
if [ -z "$OBJCOPY" ]; then
  echo "ERROR: no working objcopy for $CC" >&2
  exit 127
fi
SIZE=$(tool size || true)
OD=$(tool objdump || true)

# -no-pie: the linux-gnu cross toolchain defaults to PIE, which cannot place
# PT_PHDR over an image linked at 0 ("PHDR segment not covered by LOAD segment").
CFLAGS="-march=rv64ima -mabi=lp64 -mcmodel=medany -mno-relax -nostdlib \
        -ffreestanding -fno-builtin -no-pie -Wl,--build-id=none -Ttext=0"

echo "== assembling with $CC =="
"$CC" $CFLAGS -o "$ELF" -x assembler-with-cpp "$HERE/test_chip_boot.S"

echo "== size =="
[ -n "$SIZE" ] && "$SIZE" "$ELF" || true
[ -n "$OD" ] && "$OD" -h "$ELF" | grep -A1 "\.text" | head -3 || true

"$OBJCOPY" -O binary "$ELF" "$BIN"
python3 "$HERE/bin2hex.py" "$BIN" "$OUT"

BYTES=$(wc -c < "$BIN")
WORDS=$(wc -l < "$OUT")
echo "== image: $BYTES bytes, $WORDS words -> $OUT =="
if [ "$BYTES" -gt $((0x3F0)) ]; then
  echo "ERROR: image is $BYTES bytes, into the runtime data at 0x400" >&2
  exit 1
fi
[ -n "$OD" ] && "$OD" -d "$ELF" | sed -n '5,30p' || true
echo "OK: $OUT"
