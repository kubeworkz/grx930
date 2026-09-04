#!/usr/bin/env python3
"""Generate minimal D-cache stress test firmware that fits in ONE 32-byte I-cache line."""

def enc_lui(rd, imm20):
    return (imm20 << 12) | (rd << 7) | 0x37

def enc_addi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x13

def enc_lw(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x03

def enc_bne(rs1, rs2, offset):
    imm = offset & 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (0b001 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63

def enc_sw(rs2, rs1, imm12):
    imm = imm12 & 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b010 << 12) | ((imm & 0x1F) << 7) | 0x23

# 8 instructions, all in first cache line (0x00-0x1F):
# 0x00: lui  x10, 0
# 0x04: addi x10, x10, 0x100
# 0x08: lw   x15, 0(x10)       # x15 = mem[0x100] (should be 1)
# 0x0C: addi x14, x0, 1
# 0x10: bne  x15, x14, +0x10   # fail -> 0x20 (outside cache line, CPU hangs)
# 0x14: lui  x17, 0x12345
# 0x18: addi x17, x17, 0x678
# 0x1C: sw   x17, 0(x10)       # mem[0x100] = 0x12345678 (PASS!)

fw = [
    enc_lui(10, 0),
    enc_addi(10, 10, 0x100),
    enc_lw(15, 10, 0),
    enc_addi(14, 0, 1),
    enc_bne(15, 14, 0x10),
    enc_lui(17, 0x12345),
    enc_addi(17, 17, 0x678),
    enc_sw(17, 10, 0),
]

for i, w in enumerate(fw):
    print(f"  [{i*4:2d}] 0x{w:08x}")

with open("sw/dcache_test.hex", "w") as f:
    for w in fw:
        f.write(f"{w:08x}\n")
print(f"\nWritten {len(fw)} words to sw/dcache_test.hex")
