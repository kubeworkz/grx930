#!/usr/bin/env python3
"""
Generate firmware for the APLIC integration test (SoC Test 10).

CPU0 boots at DDR 0x0000, configures the APLIC (NPU0=prio3/edge,
NPU1=prio2/edge, UART=prio1/level), enables machine external interrupts,
queues a 4x4x4 INT8 all-ones GEMM on NPU0, and spins.  When the GEMM
completes, NPU0's done pulse raises the APLIC o_irq -> CPU0 traps to the
ISR at mtvec=0x100.  The ISR claims the source (expect 1 = NPU0), writes
the claim value to DDR 0xB000, completes the interrupt, and mrets.  The
main line then writes 0xC0FFEE to 0xB004.

Mailboxes (DDR):
    0xB000  claim value observed by the ISR (expect 1)
    0xB004  main-line magic (0xC0FFEE) once the ISR has run
Operands: A@0x8000 = 1, B@0x8400 = 1  (4x4x4 all-ones -> C = 4 at 0x8800)
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

def enc_beq(rs1, rs2, offset):
    """BEQ with byte offset relative to the current instruction."""
    imm = offset & 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (0b000 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63

def enc_jal(rd, offset):
    imm = offset & 0x1FFFFE
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F

def enc_csrrw(rd, csr, rs1):
    return (csr << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0x73

def enc_csrrs(rd, csr, rs1):
    return (csr << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x73

MRET = 0x30200073

MTVEC  = 0x305
MIE    = 0x304
MSTATUS = 0x300

# ---- code emitter ------------------------------------------------------------
code = []
pc = [0]

def emit(instr):
    code.append((pc[0], instr))
    pc[0] += 4

def emit_li(reg, value):
    upper = (value + 0x800) >> 12
    lower = value - (upper << 12)
    emit(enc_lui(reg, upper))
    emit(enc_addi(reg, reg, lower))

def align(addr):
    while pc[0] < addr:
        emit(0x00000013)  # nop

# =============================================================================
# Main line (entry at 0x0000)
# =============================================================================
# x5 = APLIC base
emit_li(5, 0x40004000)

# priorities: NPU0=3, NPU1=2, UART=1
emit_li(6, 3); emit(enc_sw(6, 5, 0x00))
emit_li(6, 2); emit(enc_sw(6, 5, 0x04))
emit_li(6, 1); emit(enc_sw(6, 5, 0x08))
# enable sources 1..3
emit_li(6, 0x0E); emit(enc_sw(6, 5, 0x0C))
# threshold 0
emit(enc_sw(0, 5, 0x10))
# capture modes: src1/src2 edge, src3 level (defaults, explicit)
emit_li(6, 2); emit(enc_sw(6, 5, 0x18)); emit(enc_sw(6, 5, 0x1C))
emit_li(6, 1); emit(enc_sw(6, 5, 0x20))

# stack pointer (ISR uses a 16-byte frame)
emit_li(2, 0x3000)

# mtvec = 0x200 (ISR) -- safe to set before interrupts are enabled
emit_li(6, 0x200)
emit(enc_csrrw(0, MTVEC, 6))

# ---- queue GEMM 4x4x4 INT8 on NPU0 (x10 = NPU0 CSR base) ----
emit_li(10, 0x40000000)
emit_li(11, 4); emit(enc_sw(11, 10, 0x08))   # M
emit_li(11, 4); emit(enc_sw(11, 10, 0x0C))   # N
emit_li(11, 4); emit(enc_sw(11, 10, 0x10))   # K
emit_li(11, 0x8000); emit(enc_sw(11, 10, 0x14))  # A base
emit_li(11, 0x8400); emit(enc_sw(11, 10, 0x18))  # B base
emit_li(11, 0x8800); emit(enc_sw(11, 10, 0x1C))  # C base
emit_li(11, 0);      emit(enc_sw(11, 10, 0x20))  # precision INT8
emit(enc_lw(11, 10, 0x20))                  # read-back barrier
emit_li(11, 1); emit(enc_sw(11, 10, 0x00))  # START

# ---- enable machine external interrupts (after the GEMM is queued) ----
# mie.MEIE = 1  (csrrs)
emit_li(7, 0x800)
emit(enc_csrrs(0, MIE, 7))
# mstatus.MIE = 1 (csrrs)
emit_li(7, 0x8)
emit(enc_csrrs(0, MSTATUS, 7))

# ---- spin until the ISR writes the claim value to 0xB000 ----
emit_li(12, 0xB000)
spin_addr = pc[0]
emit(enc_lw(13, 12, 0))
emit(enc_beq(13, 0, spin_addr - pc[0]))     # branch back if still 0

# ---- done: write magic to 0xB004 then self-loop ----
emit_li(14, 0xB004)
emit_li(15, 0xC0FFEE)
emit(enc_sw(15, 14, 0))
self_addr = pc[0]
emit(enc_jal(0, 0))                         # j self

# =============================================================================
# ISR at 0x200: save, claim, record, complete, restore, mret
# =============================================================================
align(0x200)
isr_addr = pc[0]
assert isr_addr == 0x200
emit(enc_addi(2, 2, -16))                   # sp -= 16
emit(enc_sw(1, 2, 0))                       # save ra
emit(enc_sw(5, 2, 4))                       # save x5
emit(enc_sw(6, 2, 8))                       # save x6
emit(enc_sw(7, 2, 12))                      # save x7
emit_li(5, 0x40004000)
emit(enc_lw(6, 5, 0x14))                    # claim -> x6 (source index)
emit_li(7, 0xB000)
emit(enc_sw(6, 7, 0))                       # record claim at 0xB000
emit(enc_sw(6, 5, 0x14))                    # complete (write source back)
emit(enc_lw(1, 2, 0))                       # restore
emit(enc_lw(5, 2, 4))
emit(enc_lw(6, 2, 8))
emit(enc_lw(7, 2, 12))
emit(enc_addi(2, 2, 16))                    # sp += 16
emit(MRET)

# Pad generously past the ISR's mret: this core fetches speculatively ahead of
# control flow, so any garbage decoded between the mret and its redirect fires
# a spurious illegal-instruction trap back to the ISR.  NOPs keep the
# wrong-path fetch legal until the mret redirect lands.
pad_to = 0x400
while pc[0] < pad_to:
    emit(0x00000013)  # nop

# =============================================================================
# Emit byte-hex file (TB loads it into DDR at 0x0000)
# =============================================================================
end = pc[0]
mem = [0] * end
for addr, instr in code:
    for b in range(4):
        mem[addr + b] = (instr >> (8 * b)) & 0xFF

with open("sw/aplic_ddr_bytes.hex", "w") as f:
    for i, b in enumerate(mem):
        f.write(f"{b:02x} ")
        if i % 16 == 15:
            f.write("\n")

print(f"Firmware: {len(code)} instr, 0x0000-0x{end-4:04X} ({end} bytes)")
print(f"Spin loop at 0x{spin_addr:04X}, ISR at 0x{isr_addr:04X}")
print(f"Written {end} bytes -> sw/aplic_ddr_bytes.hex")
