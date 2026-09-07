#!/usr/bin/env python3
"""
Generate hand-assembled 4-core firmware for the SoC quad-core test.

All four harts boot: CPU0 from DDR 0x0000, CPU1/2/3 parked in the boot ROM
(0x10020/0x10040/0x10060) polling the per-core RELEASE registers
(0x4000_0FF4/8/C) and jumping to whatever worker address is written there.
The handoff is chained purely through those UNCACHED MMIO registers:

    CPU0 (0x0000): HART_ID@0x9000 -> GEMM0 -> verify -> write 0xFF4 = 0x4000
                   (release CPU1) -> poll 0xFFC until 0x7777 (CPU3 done)
                   -> DONE magic 0xFACEFEED @ 0x9400
    CPU1 (0x4000): HART_ID@0x9100 -> GEMM1 -> verify -> write 0xFF8 = 0x4800
                   (release CPU2)
    CPU2 (0x4800): HART_ID@0x9200 -> GEMM2 -> verify -> write 0xFFC = 0x5000
                   (release CPU3)
    CPU3 (0x5000): HART_ID@0x9300 -> GEMM3 -> verify -> write 0xFFC = 0x7777
                   (CPU3-done signal to CPU0)

Why MMIO and not DDR done-flags: the D-caches have no cross-core coherency,
so a core polling another core's freshly-written DDR flag can sit on a stale
cached line forever.  All handoff reads/writes therefore go through the
uncached MMIO bridge (RELEASE registers), which is exactly what the boot-ROM
park loops already use.  Chaining also guarantees EXACTLY ONE core programs
the shared NPU CSR at a time (the CSR register file is shared and
last-writer-wins; two cores in their dims/base setup window simultaneously
would corrupt command snapshots).

Memory map:
  0x0000 - 0x03FF : CPU0 firmware
  0x4000 - 0x47FF : CPU1 firmware
  0x4800 - 0x4FFF : CPU2 firmware
  0x5000 - 0x57FF : CPU3 firmware
  0x8000/0x8400/0x8800 : GEMM0 A / B / C   (4x4x4, all-1s -> C = 4)
  0xA000/0xA400/0xA800 : GEMM1 A / B / C   (3x3x3, all-2s -> C = 12)
  0xB000/0xB400/0xB800 : GEMM2 A / B / C   (3x3x3, all-3s -> C = 27)
  0xD000/0xD400/0xD800 : GEMM3 A / B / C   (4x4x4, all-4s -> C = 64)
  0x9000-0x900F : CPU0 status (hartid @+0 / err mask @+4)
  0x9100-0x910F : CPU1 status
  0x9200-0x920F : CPU2 status
  0x9300-0x930F : CPU3 status
  0x9400        : CPU0 DONE magic
"""

MMIO_BASE = 0x40000000
HART_ID_ADDR = 0x40000FF0
REL1_ADDR = 0x40000FF4
REL2_ADDR = 0x40000FF8
REL3_ADDR = 0x40000FFC
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

    def wait_npu_idle(self, mbase_reg, scratch):
        """Poll STATUS.busy until 0. mbase_reg must hold MMIO_BASE."""
        loop = self.pc
        self.emit(enc_lw(scratch, mbase_reg, CSR_STAT))
        self.emit(enc_andi(scratch, scratch, 1))
        self.emit(enc_bne(scratch, 0, loop - self.pc))

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

    def write_release(self, rel_addr, entry):
        """Write worker entry address to the release register at rel_addr."""
        self.emit_li(11, entry)
        self.emit_li(13, rel_addr)          # full addr (offset doesn't fit imm12)
        self.emit(enc_sw(11, 13, 0))

    def poll_release_eq(self, rel_addr, expected):
        """Poll the release register at rel_addr until it reads expected.
        The expected value is loaded into x16 with li -- a compare via
        addi -expected would fail for values that don't fit a signed 12-bit
        immediate (e.g. 0x7777)."""
        self.emit_li(13, rel_addr)
        self.emit_li(16, expected)
        loop = self.pc
        self.emit(enc_lw(14, 13, 0))
        self.emit(enc_bne(14, 16, loop - self.pc))

    def hartid_to_slot(self, slot_hartid):
        """Read HART_ID (full addr in x13) and store at slot_hartid."""
        self.emit_li(13, HART_ID_ADDR)
        self.emit(enc_lw(11, 13, 0))
        self.emit_li(12, slot_hartid)
        self.emit(enc_sw(11, 12, 0))

    def verify_c(self, c_base, count, expected, mask_addr):
        """Verify all C words == expected; error mask (bit i) -> mask_addr.
        Fixed layout (offsets deterministic -- see gen_dualcore_test.py)."""
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
        self.emit_li(19, mask_addr)
        self.emit(enc_sw(18, 19, 0))
        self.emit(enc_jal(0, 20))       # skip mismatch -> loop+56
        # mismatch: mask |= 1 << index; then jump back to ok
        self.emit(enc_addi(19, 0, 1))
        self.emit(enc_sll(19, 19, 17))
        self.emit(enc_or(18, 18, 19))
        self.emit(enc_jal(0, ok - self.pc))


# =========================================================================
# CPU0 main (0x0000) -- primary
# =========================================================================
p0 = Prog(0x0000)
p0.emit(enc_addi(0, 0, 0))                       # nop: skip/fetch-ahead slip buffer
p0.emit_li(10, MMIO_BASE)                       # x10 = MMIO base
p0.hartid_to_slot(0x9000)                        # HART_ID -> 0x9000

# GEMM0: 4x4x4 INT8 (all-1s -> C = 4)
p0.prog_gemm(4, 4, 4, 0x8000, 0x8400, 0x8800)
p0.wait_npu_idle(10, 14)
p0.verify_c(0x8800, 16, 4, 0x9004)

# Release CPU1 (chain: only after CPU0's own GEMM is verified)
p0.write_release(REL1_ADDR, 0x4000)

# Wait for CPU3 to signal completion (0xFFC becomes 0x7777)
p0.poll_release_eq(REL3_ADDR, 0x7777)

# DONE magic -> 0x9400
p0.emit_li(12, 0x9400)
p0.emit_li(11, 0xFACEFEED)
p0.emit(enc_sw(11, 12, 0))
p0.emit(enc_jal(0, 0))                          # self-loop

# =========================================================================
# CPU1 worker (0x4000)
# =========================================================================
p1 = Prog(0x4000)
p1.emit(enc_addi(0, 0, 0))                       # nop slip buffer
p1.emit_li(10, MMIO_BASE)
p1.hartid_to_slot(0x9100)
p1.prog_gemm(3, 3, 3, 0xA000, 0xA400, 0xA800)
p1.wait_npu_idle(10, 14)
p1.verify_c(0xA800, 9, 12, 0x9104)
p1.write_release(REL2_ADDR, 0x4800)              # release CPU2
p1.emit(enc_jal(0, 0))

# =========================================================================
# CPU2 worker (0x4800)
# =========================================================================
p2 = Prog(0x4800)
p2.emit(enc_addi(0, 0, 0))                       # nop slip buffer
p2.emit_li(10, MMIO_BASE)
p2.hartid_to_slot(0x9200)
p2.prog_gemm(3, 3, 3, 0xB000, 0xB400, 0xB800)
p2.wait_npu_idle(10, 14)
p2.verify_c(0xB800, 9, 27, 0x9204)
p2.write_release(REL3_ADDR, 0x5000)              # release CPU3
p2.emit(enc_jal(0, 0))

# =========================================================================
# CPU3 worker (0x5000)
# =========================================================================
p3 = Prog(0x5000)
p3.emit(enc_addi(0, 0, 0))                       # nop slip buffer
p3.emit_li(10, MMIO_BASE)
p3.hartid_to_slot(0x9300)
p3.prog_gemm(4, 4, 4, 0xD000, 0xD400, 0xD800)
p3.wait_npu_idle(10, 14)
p3.verify_c(0xD800, 16, 64, 0x9304)
p3.write_release(REL3_ADDR, 0x7777)              # signal CPU0 (all done)
p3.emit(enc_jal(0, 0))

# =========================================================================
# Merge into byte array and write hex
# =========================================================================
progs = [p0, p1, p2, p3]
nbytes = 0x6000  # pad past all code (code ends ~0x5180)
mem = [0] * nbytes
for p in progs:
    for addr, instr in p.code:
        for b in range(4):
            mem[addr + b] = (instr >> (8 * b)) & 0xFF

with open("sw/quadcore_ddr_bytes.hex", "w") as f:
    for i, b in enumerate(mem):
        f.write(f"{b:02x} ")
        if i % 16 == 15:
            f.write("\n")

for p in progs:
    print(f"firmware @0x{p.base:04X}: {len(p.code)} instr, ends 0x{p.pc-4:04X}")
print(f"Total: {nbytes} bytes -> sw/quadcore_ddr_bytes.hex")
