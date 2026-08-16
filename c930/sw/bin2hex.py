#!/usr/bin/env python3
"""Convert a raw binary image to one 32-bit little-endian hex word per line.

The RV64IMAC core fetches 4-byte little-endian instructions from DDR starting
at address 0. Each output line is the little-endian 32-bit word at that offset.
"""
import sys

def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <in.bin> <out.hex>", file=sys.stderr)
        return 1
    with open(argv[1], "rb") as f:
        data = f.read()
    data += b"\x00" * ((4 - len(data) % 4) % 4)
    with open(argv[2], "w") as f:
        for i in range(0, len(data), 4):
            word = int.from_bytes(data[i:i + 4], "little")
            f.write(f"{word:08x}\n")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
