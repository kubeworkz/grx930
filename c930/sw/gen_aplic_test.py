#!/usr/bin/env python3
"""
Generate firmware for the APLIC integration test (SoC Test 10).

CPU0 boots at DDR 0x0000 and:
  1. Configures the APLIC: NPU0=prio3/edge, NPU1=prio2/edge, UART=prio1/level.
  2. Enables the UART RX-data IRQ (IRQ_EN bit1 at 0x4000_1010).
  3. Queues a 4x4x4 INT8 all-ones GEMM on NPU0 and a 2x3x2 INT8 GEMM on NPU1.
  4. With MIE still 0, polls both NPU STAT registers until done and the UART
     STATUS register until an RX byte has arrived -- so ALL THREE sources are
     pending (edge bits latched, UART level high) before interrupts fire.
  5. Enables MEIE + MIE.  The APLIC o_irq stays high while any source is
     pending, so the CPU traps repeatedly: the first claim MUST return source
     1 (NPU0, priority 3), then 2 (NPU1, priority 2), then 3 (UART, priority
     1).  The ISR records each claim into a DDR array and completes.
  6. After 3 claims, verifies the order [1,2,3] and writes 0x0C0FFEE to
     0xB000 (or 0x0BADF00D on a priority-encoder failure).

Mailboxes (DDR):
    0xB000  main-line magic (0x0C0FFEE = priority order OK)
    0xB010  ISR claim counter
    0xB100  claims[0] (expect 1 = NPU0, highest priority)
    0xB104  claims[1] (expect 2 = NPU1)
    0xB108  claims[2] (expect 3 = UART, lowest priority)

Operands:
    NPU0: 4x4x4 all-1s -> C = 4 at 0x8800
    NPU1: A[2x2] = [[1,2],[3,4]] @0x9000, B[2x3] = all-1s @0x9100
          -> C = [[3,3,3],[7,7,7]] at 0x9200
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

def enc_branch(rs1, rs2, offset, funct3):
    imm = offset & 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63

def enc_beq(rs1, rs2, offset):
    return enc_branch(rs1, rs2, offset, 0b000)

def enc_bne(rs1, rs2, offset):
    return enc_branch(rs1, rs2, offset, 0b001)

def enc_jal(rd, offset):
    imm = offset & 0x1FFFFE
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F

def enc_csrrw(rd, csr, rs1):
    return (csr << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0x73

def enc_csrrs(rd, csr, rs1):
    return (csr << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x73

def enc_andi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0x13

def enc_slli(rd, rs1, shamt):
    return ((shamt & 0x3F) << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0x13

def enc_add(rd, rs1, rs2):
    return (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33

MRET = 0x30200073

MTVEC  = 0x305
MIE    = 0x304
MSTATUS = 0x300

# ---- code emitter ------------------------------------------------------------
code = []      # (addr, instr)
fixups = []    # (code_index, 'beq'|'bne', rs1, rs2, target_label)
labels = {}    # name -> addr
pc = [0]

def emit(instr):
    code.append((pc[0], instr))
    pc[0] += 4

def emit_li(reg, value):
    upper = (value + 0x800) >> 12
    lower = value - (upper << 12)
    emit(enc_lui(reg, upper))
    emit(enc_addi(reg, reg, lower))

def emit_branch_to(rs1, rs2, op, label):
    fixups.append((len(code), op, rs1, rs2, label))
    emit(0)  # placeholder, patched after all addresses are known

def emit_label(name):
    labels[name] = pc[0]

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
# capture modes: src1/src2 edge, src3 level (explicit)
emit_li(6, 2); emit(enc_sw(6, 5, 0x18)); emit(enc_sw(6, 5, 0x1C))
emit_li(6, 1); emit(enc_sw(6, 5, 0x20))

# stack pointer (ISR uses a 32-byte frame)
emit_li(2, 0x3000)

# mtvec = 0x400 (ISR) -- safe before interrupts are enabled
emit_li(6, 0x400)
emit(enc_csrrw(0, MTVEC, 6))

# UART RX-data IRQ enable (bit1 of IRQ_EN at 0x4000_1010)
emit_li(6, 0x2)
emit_li(7, 0x40001010)
emit(enc_sw(6, 7, 0))

# ---- queue GEMM 4x4x4 INT8 all-ones on NPU0 (x10 = NPU0 CSR base) ----
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

# ---- queue GEMM 2x3x2 INT8 on NPU1 (x10 = NPU1 CSR base) ----
emit_li(10, 0x40000040)
emit_li(11, 2); emit(enc_sw(11, 10, 0x08))   # M
emit_li(11, 3); emit(enc_sw(11, 10, 0x0C))   # N
emit_li(11, 2); emit(enc_sw(11, 10, 0x10))   # K
emit_li(11, 0x9000); emit(enc_sw(11, 10, 0x14))  # A base
emit_li(11, 0x9100); emit(enc_sw(11, 10, 0x18))  # B base
emit_li(11, 0x9200); emit(enc_sw(11, 10, 0x1C))  # C base
emit_li(11, 0);      emit(enc_sw(11, 10, 0x20))  # precision INT8
emit(enc_lw(11, 10, 0x20))                  # read-back barrier
emit_li(11, 1); emit(enc_sw(11, 10, 0x00))  # START

# ---- wait for BOTH NPUs to complete (MIE still 0: APLIC pending latches) ----
emit_li(10, 0x40000000)
emit_label("wait_npu0")
emit(enc_lw(11, 10, 0x04))                  # STAT
emit(enc_andi(12, 11, 0x2))                 # done bit
emit_branch_to(12, 0, "beq", "wait_npu0")
emit_li(10, 0x40000040)
emit_label("wait_npu1")
emit(enc_lw(11, 10, 0x04))                  # STAT
emit(enc_andi(12, 11, 0x2))                 # done bit
emit_branch_to(12, 0, "beq", "wait_npu1")

# ---- wait for the UART RX byte (STATUS bit1 = RX empty; 0 = data available) ----
emit_li(10, 0x40001000)
emit_label("wait_uart")
emit(enc_lw(11, 10, 0x08))                  # STATUS
emit(enc_andi(12, 11, 0x2))                 # rx_empty
emit_branch_to(12, 0, "bne", "wait_uart")

# ---- pre-arm wait3 registers BEFORE enabling MIE.  This core can capture
# mepc one-to-two instructions AHEAD of the MIE enable and mret skips over
# whatever sat between, so no register setup may follow the enable (the wait3
# pointer below used to sit there and silently read address 0 -> deadlock).
emit_li(12, 0xB010)

# ---- enable machine external interrupts: all three sources are pending ----
emit_li(7, 0x800)
emit(enc_csrrs(0, MIE, 7))                  # mie.MEIE = 1
emit_li(7, 0x8)
emit(enc_csrrs(0, MSTATUS, 7))              # mstatus.MIE = 1
# NOP slip-buffer: let the interrupt mepc capture / fetch-ahead land inside
# these NOPs or the wait3 body (re-runnable), never on a skipped setup.
emit(0x00000013); emit(0x00000013); emit(0x00000013)

# ---- spin until the ISR has claimed all three sources ----
emit_label("wait3")
emit(enc_lw(13, 12, 0))                     # cnt
emit_li(14, 3)
emit_branch_to(13, 14, "bne", "wait3")

# ---- verify the claim ORDER: [1, 2, 3] by priority ----
emit_li(12, 0xB100)
emit(enc_lw(13, 12, 0))                     # claims[0]
emit_li(14, 1)
emit_branch_to(13, 14, "bne", "fail")
emit(enc_lw(13, 12, 4))                     # claims[1]
emit_li(14, 2)
emit_branch_to(13, 14, "bne", "fail")
emit(enc_lw(13, 12, 8))                     # claims[2]
emit_li(14, 3)
emit_branch_to(13, 14, "bne", "fail")

# pass: magic 0x0C0FFEE at 0xB000, self-loop
emit_li(14, 0xB000)
emit_li(15, 0x0C0FFEE)
emit(enc_sw(15, 14, 0))
emit_label("self")
emit(enc_jal(0, 0))                         # j self

# =============================================================================
# ISR at 0x400: save, claim, record, drain UART (source 3), complete, restore
# =============================================================================
align(0x400)
isr_addr = pc[0]
assert isr_addr == 0x400
emit(enc_addi(2, 2, -32))                   # sp -= 32
emit(enc_sw(1, 2, 0))                       # save ra
emit(enc_sw(5, 2, 4))                       # save x5
emit(enc_sw(6, 2, 8))                       # save x6
emit(enc_sw(7, 2, 12))                      # save x7
emit(enc_sw(8, 2, 16))                      # save x8
emit_li(5, 0x40004000)
emit(enc_lw(6, 5, 0x14))                    # claim -> x6 (source index)
# record claim: claims[cnt] = x6, cnt++
emit_li(7, 0xB010)
emit(enc_lw(8, 7, 0))                       # x8 = cnt
emit(enc_slli(8, 8, 2))                     # cnt * 4
emit_li(7, 0xB100)
emit(enc_add(8, 7, 8))                      # &claims[cnt]
emit(enc_sw(6, 8, 0))
emit_li(7, 0xB010)
emit(enc_lw(8, 7, 0))
emit(enc_addi(8, 8, 1))
emit(enc_sw(8, 7, 0))                       # cnt++
# if claim != 3 (UART), skip the RX drain
emit(enc_addi(7, 6, -3))
emit_branch_to(7, 0, "bne", "isr_complete")
emit_li(7, 0x40001004)
emit(enc_lw(0, 7, 0))                       # dummy read drains RX FIFO
# complete (write claimed source back)
emit_label("isr_complete")
emit(enc_sw(6, 5, 0x14))
emit(enc_lw(1, 2, 0))                       # restore
emit(enc_lw(5, 2, 4))
emit(enc_lw(6, 2, 8))
emit(enc_lw(7, 2, 12))
emit(enc_lw(8, 2, 16))
emit(enc_addi(2, 2, 32))                    # sp += 32
emit(MRET)

# =============================================================================
# Fail path: bad magic 0x0BADF00D at 0xB000, self-loop
# =============================================================================
emit_label("fail")
emit_li(14, 0xB000)
emit_li(15, 0x0BADF00D)
emit(enc_sw(15, 14, 0))
emit(enc_jal(0, 0))                         # j self

# Pad generously past the ISR's mret: this core fetches speculatively ahead of
# control flow, so any garbage decoded between the mret and its redirect fires
# a spurious illegal-instruction trap back to the ISR.  NOPs keep the
# wrong-path fetch legal until the mret redirect lands.
pad_to = 0x600
while pc[0] < pad_to:
    emit(0x00000013)  # nop

# =============================================================================
# Patch branch fixups now that every label's address is known
# =============================================================================
for (code_idx, op, rs1, rs2, label) in fixups:
    src_addr = code[code_idx][0]
    target = labels[label]
    code[code_idx] = (src_addr, enc_branch(rs1, rs2, target - src_addr,
                                           0b001 if op == "bne" else 0b000))

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
print(f"ISR at 0x{isr_addr:04X}, fail at 0x{labels['fail']:04X}, self at 0x{labels['self']:04X}")
print(f"Written {end} bytes -> sw/aplic_ddr_bytes.hex")