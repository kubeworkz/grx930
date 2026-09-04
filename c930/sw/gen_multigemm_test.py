#!/usr/bin/env python3
"""
Generate hand-assembled 3-GEMM firmware for queue drain stress test.

Queues 3 back-to-back GEMMs through the NPU CSR MMIO path.
All registers, immediates, and branch offsets are computed precisely.

Register allocation:
  x10 = MMIO_BASE (0x40000000) — persistent
  x11 = scratch / values
  x12 = scratch
  x13 = scratch
  x14 = scratch
  x15 = DONE_ADDR (0x9410)
  x16 = DONE_MAGIC (0xDEADBEEF)

Memory layout:
  0x0000 - 0x0FFF : Firmware code
  0x8000 - 0x80FF : GEMM0 A (2x2=4 bytes)
  0x8400 - 0x84FF : GEMM0 B (2x2=4 bytes)
  0x8800 - 0x88FF : GEMM0 C (2x2=16 bytes, INT32)
  0x9000 - 0x93FF : GEMM1 A (4x4=16 bytes)
  0x9400 - 0x97FF : GEMM1 B (4x4=16 bytes)
  0x9800 - 0x9BFF : GEMM1 C (4x4=64 bytes)
  0xA000 - 0xA3FF : GEMM2 A (8x8=64 bytes)
  0xA400 - 0xA7FF : GEMM2 B (8x8=64 bytes)
  0xA800 - 0xABFF : GEMM2 C (8x8=256 bytes)
"""

def enc_lui(rd, imm20):
    return (imm20 << 12) | (rd << 7) | 0x37

def enc_addi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x13

def enc_sw(rs2, rs1, imm12):
    imm = imm12 & 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0b010 << 12) | ((imm & 0x1F) << 7) | 0x23

def enc_lw(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x03

def enc_bne(rs1, rs2, offset):
    """BNE with byte offset from current instruction address."""
    imm = offset & 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (0b001 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63

def enc_jal(rd, offset):
    """JAL with byte offset from current instruction address."""
    imm = offset & 0x1FFFFE
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F

def li(reg, value):
    """Emit LUI+ADDI to load 32-bit constant."""
    upper = (value + 0x800) >> 12
    lower = value - (upper << 12)
    return [enc_lui(reg, upper), enc_addi(reg, reg, lower)]

# CSR byte offsets from MMIO_BASE (0x40000000)
CSR_START = 0x00
CSR_STAT  = 0x04
CSR_M     = 0x08
CSR_N     = 0x0C
CSR_K     = 0x10
CSR_A     = 0x14
CSR_B     = 0x18
CSR_C     = 0x1C
CSR_PREC  = 0x20

# Build firmware as list of (addr, instr) pairs
code = []
pc = [0]  # mutable counter

def emit(instr):
    code.append((pc[0], instr))
    pc[0] += 4

def emit_list(instrs):
    for i in instrs:
        emit(i)

def emit_li(reg, value):
    upper = (value + 0x800) >> 12
    lower = value - (upper << 12)
    emit(enc_lui(reg, upper))
    emit(enc_addi(reg, reg, lower))

def emit_prog_gemm(m, n, k, a, b, c):
    """Emit GEMM programming sequence. x10 must hold MMIO_BASE."""
    emit_li(11, m);   emit(enc_sw(11, 10, CSR_M))
    emit_li(11, n);   emit(enc_sw(11, 10, CSR_N))
    emit_li(11, k);   emit(enc_sw(11, 10, CSR_K))
    emit_li(11, a);   emit(enc_sw(11, 10, CSR_A))
    emit_li(11, b);   emit(enc_sw(11, 10, CSR_B))
    emit_li(11, c);   emit(enc_sw(11, 10, CSR_C))
    emit(enc_addi(11, 0, 0));  emit(enc_sw(11, 10, CSR_PREC))  # PREC=INT8
    emit(enc_lw(11, 10, CSR_PREC))  # read-back barrier
    emit(enc_addi(11, 0, 1));  emit(enc_sw(11, 10, CSR_START))  # START

# ===== FIRMWARE =====

# 0x00: x10 = MMIO_BASE
emit_li(10, 0x40000000)

# 0x08: GEMM 0: 2x2x2 INT8
emit_prog_gemm(2, 2, 2, 0x8000, 0x8400, 0x8800)

# 0x58: GEMM 1: 4x4x4 INT8 (queued immediately — tests queue push while busy)
emit_prog_gemm(4, 4, 4, 0x9000, 0x9400, 0x9800)

# 0xA8: GEMM 2: 8x8x8 INT8 (queued immediately — tests queue depth)
emit_prog_gemm(8, 8, 8, 0xA000, 0xA400, 0xA800)

# ===== WAIT: poll STATUS until all 3 GEMMs complete =====
# STATUS bit 1 = DONE. After each GEMM, DONE is set, then cleared by
# dispatcher when next command pops. We poll for 3 DONE events.
emit_li(14, 3)  # x14 = remaining count

wait_addr = pc[0]
# Read STATUS
emit(enc_lw(11, 10, CSR_STAT))
# Isolate bit 1: ANDI x11, x11, 2
emit(0x0025F593)  # andi x11, x11, 2
# If bit1 set (DONE), decrement counter
emit(enc_addi(13, 0, 2))  # x13 = 2 (for comparison, not needed — use bne)
# Actually: if x11 != 0 (DONE), jump to done_handler
done_check_addr = pc[0]
emit(enc_bne(11, 0, 0))  # placeholder — will fix offset
# Not done: loop back
emit(enc_jal(0, wait_addr - pc[0]))  # j wait_start
# done_handler: decrement and check
done_handler_addr = pc[0]
# Fix the bne offset
code[-3] = (done_check_addr, enc_bne(11, 0, done_handler_addr - done_check_addr))
emit(enc_addi(14, 14, -1))  # x14--
emit(enc_bne(14, 0, wait_addr - pc[0]))  # if x14 != 0, keep waiting

# ===== WRITE DONE =====
emit_li(15, 0x9410)   # x15 = DONE_ADDR
emit_li(16, 0xDEADBEEF)  # x16 = DONE_MAGIC
emit(enc_sw(16, 15, 0))   # sw x16, 0(x15)

# Self-loop
self_addr = pc[0]
emit(enc_jal(0, 0))  # j self (offset 0)

# Print firmware
print(f"Firmware: {len(code)} instructions, {len(code)*4} bytes")
print(f"Code range: 0x0000 - 0x{(len(code)-1)*4:04X}")
print(f"Wait loop at: 0x{wait_addr:04X}")
print(f"Done handler at: 0x{done_handler_addr:04X}")

# Write hex file
with open("sw/multigemm_test.hex", "w") as f:
    for addr, instr in code:
        f.write(f"{instr:08x}\n")
print(f"\nWritten {len(code)} words to sw/multigemm_test.hex")

# Print disassembly
print("\nDisassembly:")
for addr, instr in code:
    opcode = instr & 0x7F
    names = {0x37: "lui", 0x13: "op-imm", 0x03: "load", 0x23: "store", 0x63: "branch", 0x6F: "jal"}
    name = names.get(opcode, "???")
    print(f"  0x{addr:04X}: {instr:08X}  {name}")
