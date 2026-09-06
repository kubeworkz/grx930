#!/usr/bin/env python3
"""
Generate hand-assembled dual-core firmware for the SoC dual-core test.

CPU0 (primary, resets to 0x0000 in DDR):
  1. Read HART_ID (0x4000_0FF0), store at 0x9100 (expect 0)
  2. Queue GEMM A: 4x4x4 INT8, A@0x8000 B@0x8400 C@0x8800 (all-1s -> C = 4)
  3. Wait for NPU idle (STATUS.busy == 0)
  4. Verify all 16 C elements == 4; error mask -> 0x9104
  5. Write CORE1_RELEASE (0x4000_0FF4) = 0x4000 (CPU1 worker entry)
  6. Wait for CPU1 to run (STATUS busy 0->1) and finish (busy 1->0)
  7. Write DONE_MAGIC 0xDEADBEEF -> 0x9300
  8. Self-loop

CPU1 (secondary, boot ROM parks at 0x10020 polling RELEASE, jumps to 0x4000):
  1. Read HART_ID, store at 0x9108 (expect 1)
  2. Wait for NPU idle (CPU0's GEMM A must drain first)
  3. Queue GEMM B: 3x3x3 INT8, A@0xA000 B@0xA400 C@0xA800 (all-2s -> C = 12)
  4. Wait for NPU idle
  5. Verify all 9 C elements == 12; error mask -> 0x910C
  6. Write 0xCAFE -> 0x9200 (completion mailbox; TB reads DDR directly)
  7. Self-loop

Memory map:
  0x0000 - 0x03FF : CPU0 firmware
  0x4000 - 0x43FF : CPU1 firmware
  0x8000         : GEMM A operands (A 4x4, B 4x4)
  0x8800         : GEMM A C (16 words)
  0x9100/0x9104  : CPU0 HART_ID / error mask
  0x9108/0x910C  : CPU1 HART_ID / error mask
  0x9200         : CPU1 completion mailbox
  0x9300         : CPU0 DONE magic
  0xA000         : GEMM B operands (A 3x3, B 3x3)
  0xA800         : GEMM B C (9 words)
"""

MMIO_BASE = 0x40000000
HART_ID_ADDR = 0x40000FF0
RELEASE_ADDR = 0x40000FF4
CSR_START, CSR_STAT, CSR_M, CSR_N, CSR_K, CSR_A, CSR_B, CSR_C, CSR_PREC = \
    0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20


def enc_lui(rd, imm20):        return (imm20 << 12) | (rd << 7) | 0x37
def enc_addi(rd, rs1, imm12):  return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x13
def enc_andi(rd, rs1, imm12):  return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0x13
def enc_lw(rd, rs1, imm12):    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x03
def enc_sw(rs2, rs1, imm12):
    imm = imm12 & 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b010 << 12) | ((imm & 0x1F) << 7) | 0x23
def enc_beq(rs1, rs2, offset):
    imm = offset & 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b000 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63
def enc_bne(rs1, rs2, offset):
    imm = offset & 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b001 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63
def enc_jal(rd, offset):
    imm = offset & 0x1FFFFE
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F
def enc_sll(rd, rs1, rs2):     return (rs2 << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0x33
def enc_or(rd, rs1, rs2):      return (rs2 << 20) | (rs1 << 15) | (0b110 << 12) | (rd << 7) | 0x33


def li(reg, value):
    upper = (value + 0x800) >> 12
    lower = value - (upper << 12)
    return [enc_lui(reg, upper), enc_addi(reg, reg, lower)]


class Prog:
    """Tiny assembler with a base address; emits (addr, instr) pairs."""
    def __init__(self, base):
        self.base = base
        self.code = []
        self.pc = base

    def emit(self, instr):
        self.code.append((self.pc, instr))
        self.pc += 4

    def emit_list(self, instrs):
        for i in instrs:
            self.emit(i)

    def emit_li(self, reg, value):
        self.emit_list(li(reg, value))

    def patch(self, at, instr):
        for i, (a, _) in enumerate(self.code):
            if a == at:
                self.code[i] = (at, instr)
                return
        raise ValueError(f"no instruction at 0x{at:X}")

    def wait_npu_idle(self, mbase_reg, scratch):
        """Poll STATUS.busy until 0. x10 must hold MMIO_BASE."""
        loop = self.pc
        self.emit(enc_lw(scratch, mbase_reg, CSR_STAT))
        self.emit(enc_andi(scratch, scratch, 1))
        self.emit(enc_bne(scratch, 0, loop - self.pc))

    def wait_npu_busy(self, mbase_reg, scratch):
        """Poll STATUS.busy until 1 (another core's GEMM started)."""
        loop = self.pc
        self.emit(enc_lw(scratch, mbase_reg, CSR_STAT))
        self.emit(enc_andi(scratch, scratch, 1))
        self.emit(enc_beq(scratch, 0, loop - self.pc))

    def prog_gemm(self, m, n, k, a, b, c):
        """Program one INT8 GEMM via MMIO. x10 = MMIO_BASE."""
        self.emit_li(11, m);   self.emit(enc_sw(11, 10, CSR_M))
        self.emit_li(11, n);   self.emit(enc_sw(11, 10, CSR_N))
        self.emit_li(11, k);   self.emit(enc_sw(11, 10, CSR_K))
        self.emit_li(11, a);   self.emit(enc_sw(11, 10, CSR_A))
        self.emit_li(11, b);   self.emit(enc_sw(11, 10, CSR_B))
        self.emit_li(11, c);   self.emit(enc_sw(11, 10, CSR_C))
        self.emit(enc_addi(11, 0, 0));  self.emit(enc_sw(11, 10, CSR_PREC))  # INT8
        self.emit(enc_lw(11, 10, CSR_PREC))  # read-back barrier
        self.emit(enc_addi(11, 0, 1));  self.emit(enc_sw(11, 10, CSR_START))

    def verify_c(self, c_base, count, expected, mask_addr):
        """Verify all C words == expected; error mask (bit i) -> mask_addr.
        Registers: x15 ptr, x16 expected, x17 index, x18 mask, x19 scratch.

        Fixed layout (offsets are deterministic, no patching needed):
          loop+0:  lw   x20, 0(x15)
          loop+4:  bne  x20, x16, mismatch   (+36 -> loop+40)
          loop+8:  addi x15, x15, 4          (ok)
          loop+12: addi x17, x17, 1
          loop+16: addi x19, x17, -count
          loop+20: bne  x19, x0, loop
          loop+24: lui  x19, mask_hi
          loop+28: addi x19, x19, mask_lo
          loop+32: sw   x18, 0(x19)
          loop+36: jal  x0, skip             (+20 -> loop+56)
          loop+40: addi x19, x0, 1           (mismatch)
          loop+44: sll  x19, x19, x17
          loop+48: or   x18, x18, x19
          loop+52: jal  x0, ok               (-44 -> loop+8)
          loop+56: (skip -- next instr)"""
        self.emit_li(15, c_base)
        self.emit_li(16, expected)
        self.emit_li(17, 0)            # index
        self.emit_li(18, 0)            # mask
        loop = self.pc
        self.emit(enc_lw(20, 15, 0))
        self.emit(enc_bne(20, 16, 36))  # -> mismatch block at loop+40
        ok = self.pc                    # loop+8
        self.emit(enc_addi(15, 15, 4))
        self.emit(enc_addi(17, 17, 1))
        self.emit(enc_addi(19, 17, -count))
        self.emit(enc_bne(19, 0, loop - self.pc))
        # done: store mask, then skip the mismatch block
        self.emit_li(19, mask_addr)
        self.emit(enc_sw(18, 19, 0))
        done = self.pc                  # loop+36
        self.emit(enc_jal(0, 20))       # skip mismatch -> loop+56
        # mismatch: mask |= 1 << index; then jump back to ok
        self.emit(enc_addi(19, 0, 1))
        self.emit(enc_sll(19, 19, 17))
        self.emit(enc_or(18, 18, 19))
        self.emit(enc_jal(0, ok - self.pc))
        return done


# =========================================================================
# CPU0 main (0x0000)
# =========================================================================
p0 = Prog(0x0000)
p0.emit(enc_addi(0, 0, 0))                       # nop: this core can skip/fetch-ahead instr 0 after reset
p0.emit_li(10, MMIO_BASE)                       # x10 = MMIO base

# HART_ID self-check value -> 0x9100
# NOTE: HART_ID_ADDR - MMIO_BASE = 0xFF0 does NOT fit a signed 12-bit
# I-immediate (it would sign-extend to -16 and read 0x3FFF_FFF0), so the
# full 32-bit address is loaded into x13 instead.
p0.emit_li(13, HART_ID_ADDR)
p0.emit(enc_lw(11, 13, 0))
p0.emit_li(12, 0x9100)
p0.emit(enc_sw(11, 12, 0))

# GEMM A: 4x4x4 INT8 (all-1s -> C = 4)
p0.prog_gemm(4, 4, 4, 0x8000, 0x8400, 0x8800)
p0.wait_npu_idle(10, 14)

# Verify C[0..15] == 4 -> mask at 0x9104
p0.verify_c(0x8800, 16, 4, 0x9104)

# Release CPU1: RELEASE = 0x4000 (full address in x13: +0xFF4 doesn't
# fit a signed 12-bit I-immediate)
p0.emit_li(11, 0x4000)
p0.emit_li(13, RELEASE_ADDR)
p0.emit(enc_sw(11, 13, 0))

# Wait for CPU1's GEMM: busy 0->1, then 1->0
p0.wait_npu_busy(10, 14)
p0.wait_npu_idle(10, 14)

# DONE magic -> 0x9300
p0.emit_li(12, 0x9300)
p0.emit_li(11, 0xDEADBEEF)
p0.emit(enc_sw(11, 12, 0))
p0.emit(enc_jal(0, 0))                          # self-loop

# =========================================================================
# CPU1 worker (0x4000)
# =========================================================================
p1 = Prog(0x4000)
p1.emit(enc_addi(0, 0, 0))                       # nop: skip-protect (jalr-target line fill can slip too)
p1.emit_li(10, MMIO_BASE)

# HART_ID self-check value -> 0x9108 (full address in x13, see CPU0)
p1.emit_li(13, HART_ID_ADDR)
p1.emit(enc_lw(11, 13, 0))
p1.emit_li(12, 0x9108)
p1.emit(enc_sw(11, 12, 0))

# Wait for CPU0's GEMM A to drain
p1.wait_npu_idle(10, 14)

# GEMM B: 3x3x3 INT8 (all-2s -> C = 12)
p1.prog_gemm(3, 3, 3, 0xA000, 0xA400, 0xA800)
p1.wait_npu_idle(10, 14)

# Verify C[0..8] == 12 -> mask at 0x910C
p1.verify_c(0xA800, 9, 12, 0x910C)

# Completion mailbox -> 0x9200
p1.emit_li(12, 0x9200)
p1.emit_li(11, 0xCAFE)
p1.emit(enc_sw(11, 12, 0))
p1.emit(enc_jal(0, 0))                          # self-loop

# =========================================================================
# Merge into byte array and write hex
# =========================================================================
end0 = p0.pc
end1 = p1.pc
nbytes = end1 + 0x400  # pad past CPU1 code
mem = [0] * nbytes
for addr, instr in p0.code:
    for b in range(4):
        mem[addr + b] = (instr >> (8 * b)) & 0xFF
for addr, instr in p1.code:
    for b in range(4):
        mem[addr + b] = (instr >> (8 * b)) & 0xFF

with open("sw/dualcore_ddr_bytes.hex", "w") as f:
    for i, b in enumerate(mem):
        f.write(f"{b:02x} ")
        if i % 16 == 15:
            f.write("\n")

print(f"CPU0 firmware: {len(p0.code)} instr, 0x0000-0x{end0-4:04X}")
print(f"CPU1 firmware: {len(p1.code)} instr, 0x4000-0x{end1-4:04X}")
print(f"Total: {nbytes} bytes -> sw/dualcore_ddr_bytes.hex")