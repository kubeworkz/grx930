#!/usr/bin/env python
"""Replace Test 4 in tb_c930_soc_full.sv with mixed-precision varying-shape test
that verifies ALL 21 C elements of GEMM1 via CPU D-cache reads.

Phase 1: CPU boots GEMM firmware → queues 3 GEMMs → polls completion
Phase 2: CPU boots verification firmware → reads all 21 C elements via LW →
          compares with expected 0x41000000 → writes pass/fail vector

Memory map:
  DDR[0x000-0x0FF]:  Firmware (Phase 1 or Phase 2, loaded per boot)
  DDR[0x100-0x11F]:  Verification buffer (Phase 2 writes, testbench reads)
  DDR[0x8000+]:      GEMM data (A/B/C matrices, untouched across boots)

GEMMs:
  GEMM0: INT8  3x5x8,  all 1s  -> C[0][0] = 8   (INT32)
  GEMM1: FP16  7x3x8,  all 1.0 -> C[m][n] = 8.0 (FP32 0x41000000) for all 21
  GEMM2: BF16  2x12x8, all 1.0 -> C[0][0] = 8.0 (FP32 0x41000000)
"""

TB_FILE = 'tb/tb_c930_soc_full.sv'

# === RISC-V instruction encoders ===
def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0b0110111

def addi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0b0010011

def sw(rs2, rs1, imm12):
    imm = imm12 & 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | ((imm & 0x1F) << 7) | 0b0100011

def lw(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0b0000011

def andi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0b0010011

def or_reg(rd, rs1, rs2):
    return (0b0000000 << 25) | (rs2 << 20) | (rs1 << 15) | (0b110 << 12) | (rd << 7) | 0b0110011

def sll_reg(rd, rs1, rs2):
    return (0b0000000 << 25) | (rs2 << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0b0110011

def beq(rs1, rs2, imm13):
    imm = imm13 & 0x1FFF
    b12  = (imm >> 12) & 1
    b11  = (imm >> 11) & 1
    b101 = (imm >> 5) & 0x3F
    b41  = (imm >> 1) & 0xF
    return (b12 << 31) | (b101 << 25) | (rs2 << 20) | (rs1 << 15) | (0b000 << 12) | (b41 << 8) | (b11 << 7) | 0b1100011

def bne(rs1, rs2, imm13):
    imm = imm13 & 0x1FFF
    b12  = (imm >> 12) & 1
    b11  = (imm >> 11) & 1
    b101 = (imm >> 5) & 0x3F
    b41  = (imm >> 1) & 0xF
    return (b12 << 31) | (b101 << 25) | (rs2 << 20) | (rs1 << 15) | (0b001 << 12) | (b41 << 8) | (b11 << 7) | 0b1100011

def blt(rs1, rs2, imm13):
    """BLT: branch if rs1 < rs2 (signed)."""
    imm = imm13 & 0x1FFF
    b12  = (imm >> 12) & 1
    b11  = (imm >> 11) & 1
    b101 = (imm >> 5) & 0x3F
    b41  = (imm >> 1) & 0xF
    return (b12 << 31) | (b101 << 25) | (rs2 << 20) | (rs1 << 15) | (0b100 << 12) | (b41 << 8) | (b11 << 7) | 0b1100011

def jal(rd, imm21):
    imm = imm21 & 0x1FFFFF
    b20   = (imm >> 20) & 1
    b101  = (imm >> 1) & 0x3FF
    b11   = (imm >> 11) & 1
    b1912 = (imm >> 12) & 0xFF
    return (b20 << 31) | (b101 << 21) | (b11 << 20) | (b1912 << 12) | (rd << 7) | 0b1101111

# === Register aliases ===
x0  = 0
x10 = 10  # a0 = MMIO_BASE / temp
x11 = 11  # a1 = temp
x12 = 12  # a2 = col counter
x13 = 13  # a3 = row counter
x14 = 14  # a4 = expected value
x15 = 15  # a5 = error mask / DONE_ADDR
x16 = 16  # a6 = element index / DONE_MAGIC
x17 = 17  # a7 = temp
x18 = 18  # s0 = loaded C value
x19 = 19  # s1 = temp
x20 = 20  # s2 = NUM_ROWS (7)
x21 = 21  # s3 = NUM_COLS (3)

# CSR offsets
OFF_START  = 0x00
OFF_STATUS = 0x04
OFF_DIM_M  = 0x08
OFF_DIM_N  = 0x0C
OFF_DIM_K  = 0x10
OFF_A_BASE = 0x14
OFF_B_BASE = 0x18
OFF_C_BASE = 0x1C
OFF_PREC   = 0x20

# ====================================================================
# Phase 1: GEMM firmware (87 instructions)
# ====================================================================
def load_addr(val, reg):
    """Return lui+addi pair to load a 32-bit value."""
    lo12 = val & 0xFFF
    if lo12 >= 0x800:
        hi20 = (val - lo12 + 0x1000) >> 12
    else:
        hi20 = val >> 12
    return [lui(reg, hi20), addi(reg, reg, lo12)]

fw1 = []

# Setup
fw1 += load_addr(0x40000000, x10)  # MMIO_BASE

# --- GEMM 0: INT8 3x5x8, PREC=0 ---
fw1 += [lui(x11, 0), addi(x11, x11, 3), sw(x11, x10, OFF_DIM_M)]
fw1 += [lui(x11, 0), addi(x11, x11, 5), sw(x11, x10, OFF_DIM_N)]
fw1 += [lui(x11, 0), addi(x11, x11, 8), sw(x11, x10, OFF_DIM_K)]
fw1 += load_addr(0x8000, x11); fw1 += [sw(x11, x10, OFF_A_BASE)]
fw1 += load_addr(0x8200, x11); fw1 += [sw(x11, x10, OFF_B_BASE)]
fw1 += load_addr(0x8400, x11); fw1 += [sw(x11, x10, OFF_C_BASE)]
fw1 += [lui(x11, 0), addi(x11, x11, 0), sw(x11, x10, OFF_PREC)]  # PREC=0
fw1 += [lw(x11, x10, OFF_PREC)]  # barrier
fw1 += [addi(x11, x0, 1), sw(x11, x10, OFF_START)]

# --- GEMM 1: FP16 7x3x8, PREC=2 ---
fw1 += [lui(x11, 0), addi(x11, x11, 7), sw(x11, x10, OFF_DIM_M)]
fw1 += [lui(x11, 0), addi(x11, x11, 3), sw(x11, x10, OFF_DIM_N)]
fw1 += [lui(x11, 0), addi(x11, x11, 8), sw(x11, x10, OFF_DIM_K)]
fw1 += load_addr(0x8800, x11); fw1 += [sw(x11, x10, OFF_A_BASE)]
fw1 += load_addr(0x8A00, x11); fw1 += [sw(x11, x10, OFF_B_BASE)]
fw1 += load_addr(0x8C00, x11); fw1 += [sw(x11, x10, OFF_C_BASE)]
fw1 += [lui(x11, 0), addi(x11, x11, 2), sw(x11, x10, OFF_PREC)]  # PREC=2
fw1 += [lw(x11, x10, OFF_PREC)]
fw1 += [addi(x11, x0, 1), sw(x11, x10, OFF_START)]

# --- GEMM 2: BF16 2x12x8, PREC=3 ---
fw1 += [lui(x11, 0), addi(x11, x11, 2), sw(x11, x10, OFF_DIM_M)]
fw1 += [lui(x11, 0), addi(x11, x11, 12), sw(x11, x10, OFF_DIM_N)]
fw1 += [lui(x11, 0), addi(x11, x11, 8), sw(x11, x10, OFF_DIM_K)]
fw1 += load_addr(0x9000, x11); fw1 += [sw(x11, x10, OFF_A_BASE)]
fw1 += load_addr(0x9200, x11); fw1 += [sw(x11, x10, OFF_B_BASE)]
fw1 += load_addr(0x9400, x11); fw1 += [sw(x11, x10, OFF_C_BASE)]
fw1 += [lui(x11, 0), addi(x11, x11, 3), sw(x11, x10, OFF_PREC)]  # PREC=3
fw1 += [lw(x11, x10, OFF_PREC)]
fw1 += [addi(x11, x0, 1), sw(x11, x10, OFF_START)]

# --- Two-phase poll ---
fw1 += [lw(x11, x10, OFF_PREC)]         # barrier
fw1 += [lw(x11, x10, OFF_STATUS)]
fw1 += [andi(x11, x11, 2)]
fw1 += [beq(x11, x0, -8)]               # poll done
fw1 += [lw(x11, x10, OFF_STATUS)]
fw1 += [andi(x11, x11, 1)]
fw1 += [bne(x11, x0, -8)]               # poll busy

# --- Write DONE_MAGIC ---
fw1 += load_addr(0x9410, x15)
fw1 += [lui(x16, 0xDEADC), addi(x16, x16, 0xEEF)]
fw1 += [sw(x16, x15, 0)]
fw1 += [jal(x0, 0)]  # self-loop (will be replaced by Phase 2)

print(f"Phase 1 firmware: {len(fw1)} instructions, {len(fw1)*4} bytes")

# ====================================================================
# Phase 2: Verification firmware (reads all 21 C elements via D-cache)
# ====================================================================
fw2 = []

# Load base address of GEMM1 C matrix
fw2 += load_addr(0x8C00, x10)   # x10 = 0x8C00 (C[0][0] address)

# Expected FP32 value: 8.0 = 0x41000000
fw2 += [lui(x14, 0x41000)]       # x14 = 0x41000000

# Initialize counters and error mask
fw2 += [addi(x15, x0, 0)]       # x15 = error mask (bit i = element i wrong)
fw2 += [addi(x16, x0, 0)]       # x16 = element index (0..20)
fw2 += [addi(x13, x0, 0)]       # x13 = row counter (0..6)
fw2 += [addi(x20, x0, 7)]       # x20 = NUM_ROWS = 7
fw2 += [addi(x21, x0, 3)]       # x21 = NUM_COLS = 3

# Row loop (instruction 8 = row_loop label)
row_loop = len(fw2)
fw2 += [addi(x12, x0, 0)]       # x12 = col counter (0..2)

# Col loop (instruction 9 = col_loop label)
fw2 += [lw(x18, x10, 0)]        # x18 = C[row][col]

# Calculate branch offset: col_loop is at index 9, beq target is next (index 13)
next_idx = len(fw2) + 4  # 4 instructions ahead (beq, addi, sll, or)
beq_offset = (next_idx - len(fw2)) * 4  # byte offset in forward direction
fw2 += [beq(x18, x14, beq_offset)]      # if match, skip mismatch handling

# Mismatch: set bit in error mask
fw2 += [addi(x19, x0, 1)]       # x19 = 1
fw2 += [sll_reg(x19, x19, x16)] # x19 = 1 << element_index
fw2 += [or_reg(x15, x15, x19)]  # error_mask |= bit

# Next element
col_loop = 9  # instruction index of col_loop
next_instr = len(fw2)
fw2 += [addi(x10, x10, 4)]      # advance address by 4 bytes
fw2 += [addi(x16, x16, 1)]      # advance element index
fw2 += [addi(x12, x12, 1)]      # advance col counter

# blt x12, x21, col_loop
col_loop_offset = (col_loop - len(fw2)) * 4  # negative byte offset
fw2 += [blt(x12, x21, col_loop_offset)]

# Advance row
fw2 += [addi(x13, x13, 1)]      # advance row counter
# blt x13, x20, row_loop
row_loop_offset = (row_loop - len(fw2)) * 4  # negative byte offset
fw2 += [blt(x13, x20, row_loop_offset)]

# Write verification buffer at DDR[0x100]
fw2 += [lui(x10, 0), addi(x10, x10, 0x100)]
fw2 += [sw(x15, x10, 0)]        # error mask
fw2 += [sw(x16, x10, 4)]        # element count (21)

# Write DONE_MAGIC
fw2 += load_addr(0x9410, x15)
fw2 += [lui(x16, 0xDEADC), addi(x16, x16, 0xEEF)]
fw2 += [sw(x16, x15, 0)]

# Self-loop
fw2 += [jal(x0, 0)]

print(f"Phase 2 firmware: {len(fw2)} instructions, {len(fw2)*4} bytes")
assert len(fw2) * 4 <= 256, f"Phase 2 firmware too large: {len(fw2)*4} bytes > 256"

# Verify branch offsets
print(f"  beq offset: {beq_offset} bytes ({beq_offset//4} instr)")
print(f"  col_loop blt offset: {col_loop_offset} bytes ({col_loop_offset//4} instr)")
print(f"  row_loop blt offset: {row_loop_offset} bytes ({row_loop_offset//4} instr)")

# Print Phase 2 firmware for debugging
for i, inst in enumerate(fw2):
    print(f"  fw2[{i:2d}] = 32'h{inst:08X}")

# ====================================================================
# Read and patch testbench
# ====================================================================
with open(TB_FILE, 'r') as f:
    content = f.read()

start_marker = '    // =========================================================================\n    // Test 4:'
end_marker = '      total_errs = total_errs + mg_errs;\n    end'

idx_start = content.find(start_marker)
idx_end = content.find(end_marker, idx_start)

if idx_start == -1 or idx_end == -1:
    print(f'ERROR: markers not found start={idx_start} end={idx_end}')
    exit(1)

idx_end += len(end_marker)

# Build firmware instruction lines for Phase 1
fw1_comments = {
    0: "lui  x10, 0x40000 (MMIO_BASE)",
    1: "addi x10, x10, 0",
    2: "lui  x11, 0", 3: "addi x11, x11, 3    DIM_M=3", 4: "sw   x11, 0x08(x10)",
    5: "lui  x11, 0", 6: "addi x11, x11, 5    DIM_N=5", 7: "sw   x11, 0x0C(x10)",
    8: "lui  x11, 0", 9: "addi x11, x11, 8    DIM_K=8", 10: "sw   x11, 0x10(x10)",
}
gemm0_labels = {11: "lui  x11, 0x8", 12: "addi x11, x11, 0    A=0x8000",
                13: "sw   x11, 0x14(x10)", 14: "lui  x11, 0x8",
                15: "addi x11, x11, 0x200 B=0x8200", 16: "sw   x11, 0x18(x10)",
                17: "lui  x11, 0x8", 18: "addi x11, x11, 0x400 C=0x8400",
                19: "sw   x11, 0x1C(x10)", 20: "lui  x11, 0",
                21: "addi x11, x11, 0    PREC=0 (INT8)", 22: "sw   x11, 0x20(x10)",
                23: "lw   x11, 0x20(x10) barrier", 24: "addi x11, x0, 1",
                25: "sw   x11, 0x00(x10) START"}
fw1_comments.update(gemm0_labels)

gemm1_labels = {26: "lui  x11, 0", 27: "addi x11, x11, 7    DIM_M=7", 28: "sw   x11, 0x08(x10)",
                29: "lui  x11, 0", 30: "addi x11, x11, 3    DIM_N=3", 31: "sw   x11, 0x0C(x10)",
                32: "lui  x11, 0", 33: "addi x11, x11, 8    DIM_K=8", 34: "sw   x11, 0x10(x10)",
                35: "lui  x11, 0x9", 36: "addi x11, x11, 0x800 A=0x8800 (7*8*2=112B)",
                37: "sw   x11, 0x14(x10)", 38: "lui  x11, 0x9",
                39: "addi x11, x11, 0xA00 B=0x8A00 (8*3*2=48B)", 40: "sw   x11, 0x18(x10)",
                41: "lui  x11, 0x9", 42: "addi x11, x11, 0xC00 C=0x8C00",
                43: "sw   x11, 0x1C(x10)", 44: "lui  x11, 0",
                45: "addi x11, x11, 2    PREC=2 (FP16)", 46: "sw   x11, 0x20(x10)",
                47: "lw   x11, 0x20(x10) barrier", 48: "addi x11, x0, 1",
                49: "sw   x11, 0x00(x10) START"}
fw1_comments.update(gemm1_labels)

gemm2_labels = {50: "lui  x11, 0", 51: "addi x11, x11, 2    DIM_M=2", 52: "sw   x11, 0x08(x10)",
                53: "lui  x11, 0", 54: "addi x11, x11, 12   DIM_N=12", 55: "sw   x11, 0x0C(x10)",
                56: "lui  x11, 0", 57: "addi x11, x11, 8    DIM_K=8", 58: "sw   x11, 0x10(x10)",
                59: "lui  x11, 0x9", 60: "addi x11, x11, 0    A=0x9000 (2*8*2=32B)",
                61: "sw   x11, 0x14(x10)", 62: "lui  x11, 0x9",
                63: "addi x11, x11, 0x200 B=0x9200 (8*12*2=192B)", 64: "sw   x11, 0x18(x10)",
                65: "lui  x11, 0x9", 66: "addi x11, x11, 0x400 C=0x9400",
                67: "sw   x11, 0x1C(x10)", 68: "lui  x11, 0",
                69: "addi x11, x11, 3    PREC=3 (BF16)", 70: "sw   x11, 0x20(x10)",
                71: "lw   x11, 0x20(x10) barrier", 72: "addi x11, x0, 1",
                73: "sw   x11, 0x00(x10) START"}
fw1_comments.update(gemm2_labels)

poll_labels = {74: "lw   x11, 0x20(x10) barrier read",
               75: "lw   x11, 0x04(x10) STATUS", 76: "andi x11, x11, 2    DONE bit",
               77: "beq  x11, x0, -8   poll done", 78: "lw   x11, 0x04(x10) STATUS",
               79: "andi x11, x11, 1    BUSY bit", 80: "bne  x11, x0, -8   poll busy"}
fw1_comments.update(poll_labels)

done_labels = {81: "lui  x15, 0x9", 82: "addi x15, x15, 0x410 DONE_ADDR=0x9410",
               83: "lui  x16, 0xDEADC", 84: "addi x16, x16, 0xEEF DONE_MAGIC=0xDEADBEEF",
               85: "sw   x16, 0(x15)", 86: "jal  x0, 0  self-loop"}
fw1_comments.update(done_labels)

# Build Phase 2 comments
fw2_comments = {
    0: "lui  x10, 0x9", 1: "addi x10, x10, 0xC00   x10 = 0x8C00 (GEMM1 C base)",
    2: "lui  x14, 0x41000  x14 = 0x41000000 (FP32 8.0)",
    3: "addi x15, x0, 0    error mask = 0", 4: "addi x16, x0, 0    element index = 0",
    5: "addi x13, x0, 0    row counter = 0", 6: "addi x20, x0, 7    NUM_ROWS",
    7: "addi x21, x0, 3    NUM_COLS",
    8: "addi x12, x0, 0    row_loop: col counter = 0",
    9: "lw   x18, 0(x10)   col_loop: load C[row][col]",
    10: "beq  x18, x14, +16 if match, skip mismatch",
    11: "addi x19, x0, 1    mismatch: bit = 1",
    12: "sll  x19, x19, x16 shift by element index",
    13: "or   x15, x15, x19 set bit in error mask",
    14: "addi x10, x10, 4   next: advance address",
    15: "addi x16, x16, 1   advance element index",
    16: "addi x12, x12, 1   advance col counter",
    17: "blt  x12, x21, col_loop if col < 3, loop",
    18: "addi x13, x13, 1   advance row counter",
    19: "blt  x13, x20, row_loop if row < 7, loop",
    20: "lui  x10, 0", 21: "addi x10, x10, 0x100  verify buffer address",
    22: "sw   x15, 0(x10)   store error mask",
    23: "sw   x16, 4(x10)   store element count",
    24: "lui  x15, 0x9", 25: "addi x15, x15, 0x410 DONE_ADDR=0x9410",
    26: "lui  x16, 0xDEADC", 27: "addi x16, x16, 0xEEF DONE_MAGIC",
    28: "sw   x16, 0(x15)", 29: "jal  x0, 0  self-loop",
}

# Generate firmware lines
def gen_fw_lines(fw, comments, var_name="fw"):
    lines = []
    for i, inst in enumerate(fw):
        cmt = comments.get(i, "")
        lines.append(f'        {var_name}[{i:2d}] = 32\'h{inst:08X};  // {cmt}')
    return '\n'.join(lines)

fw1_block = gen_fw_lines(fw1, fw1_comments, "fw")
fw2_block = gen_fw_lines(fw2, fw2_comments, "vfw")

# Build the template using tokens to avoid f-string brace conflicts
# Python-substituted values use @@TOKEN@@ markers
new_test4_body = (
    '    // =========================================================================\n'
    '    // Test 4: Mixed-precision varying-shape queue drain + full C verification\n'
    '    //\n'
    '    // Phase 1: CPU boots GEMM firmware -> queues 3 GEMMs -> polls completion\n'
    '    // Phase 2: CPU boots verification firmware -> reads all 21 C elements of\n'
    '    //          GEMM1 via D-cache LW -> compares with expected FP32 8.0\n'
    '    //\n'
    '    //   GEMM0: INT8  3x5x8,  all 1s  -> C[0][0] = 8   (INT32)\n'
    '    //   GEMM1: FP16  7x3x8,  all 1.0 -> C[m][n] = 8.0 (FP32 0x41000000) ALL 21\n'
    '    //   GEMM2: BF16  2x12x8, all 1.0 -> C[0][0] = 8.0 (FP32 0x41000000)\n'
    '    // =========================================================================\n'
    '    $display("\\n========================================");\n'
    '    $display("  TEST 4: Mixed-precision + full C verification");\n'
    '    $display("========================================");\n'
    '    begin\n'
    '      int mg_errs;\n'
    '      mg_errs = 0;\n'
    '\n'
    '      // Reload NPU firmware from hex file\n'
    '      begin\n'
    '        int fw_fd;\n'
    '        logic [7:0] fw_byte;\n'
    '        int fw_addr;\n'
    '        fw_fd = $fopen("sw/npu_ddr_bytes.hex", "r");\n'
    '        if (fw_fd != 0) begin\n'
    '          fw_addr = 0;\n'
    '          while (!$feof(fw_fd) && fw_addr < MEM_BYTES) begin\n'
    '            if ($fscanf(fw_fd, "%2h", fw_byte) == 1) begin\n'
    '              ddr_write_byte(fw_addr[31:0], fw_byte);\n'
    '              fw_addr = fw_addr + 1;\n'
    '            end\n'
    '          end\n'
    '          $fclose(fw_fd);\n'
    '          $display("  [TB] Reloaded %0d firmware bytes into DDR", fw_addr);\n'
    '        end\n'
    '      end\n'
    '\n'
    '      // ---- Phase 1: GEMM firmware ----\n'
    '      begin\n'
    '        logic [31:0] fw [0:@@FW1_LAST@@];\n@@FW1_BLOCK@@'
    '        for (int i = 0; i < @@FW1_LEN@@; i++) begin\n'
    '          ddr_write_byte(i*4 + 0, fw[i][7:0]);\n'
    '          ddr_write_byte(i*4 + 1, fw[i][15:8]);\n'
    '          ddr_write_byte(i*4 + 2, fw[i][23:16]);\n'
    '          ddr_write_byte(i*4 + 3, fw[i][31:24]);\n'
    '        end\n'
    '        $display("  [TB] Phase 1 GEMM firmware loaded (%0d bytes)", @@FW1_LEN@@*4);\n'
    '      end\n'
    '\n'
    '      // --- Preload A/B operands ---\n'
    '      // GEMM 0: INT8 3x5x8 all 1s - A=24B @0x8000, B=40B @0x8200\n'
    '      begin\n'
    '        for (int i = 0; i < 24; i++)\n'
    '          ddr_write_byte(32\'h8000 + i, 8\'d1);\n'
    '        for (int i = 0; i < 40; i++)\n'
    '          ddr_write_byte(32\'h8200 + i, 8\'d1);\n'
    '        $display("  [TB] GEMM0: INT8 3x5x8 all 1s (C[0][0] expect 0x00000008)");\n'
    '      end\n'
    '      // GEMM 1: FP16 7x3x8 all 1.0 - A=112B @0x8800, B=48B @0x8A00\n'
    '      begin\n'
    '        for (int i = 0; i < 56; i++) begin\n'
    '          ddr_write_byte(32\'h8800 + i*2 + 0, 8\'h00);\n'
    '          ddr_write_byte(32\'h8800 + i*2 + 1, 8\'h3C);\n'
    '        end\n'
    '        for (int i = 0; i < 24; i++) begin\n'
    '          ddr_write_byte(32\'h8A00 + i*2 + 0, 8\'h00);\n'
    '          ddr_write_byte(32\'h8A00 + i*2 + 1, 8\'h3C);\n'
    '        end\n'
    '        $display("  [TB] GEMM1: FP16 7x3x8 all 1.0 (C[0][0] expect 0x41000000)");\n'
    '      end\n'
    '      // GEMM 2: BF16 2x12x8 all 1.0 - A=32B @0x9000, B=192B @0x9200\n'
    '      begin\n'
    '        for (int i = 0; i < 16; i++) begin\n'
    '          ddr_write_byte(32\'h9000 + i*2 + 0, 8\'h80);\n'
    '          ddr_write_byte(32\'h9000 + i*2 + 1, 8\'h3F);\n'
    '        end\n'
    '        for (int i = 0; i < 96; i++) begin\n'
    '          ddr_write_byte(32\'h9200 + i*2 + 0, 8\'h80);\n'
    '          ddr_write_byte(32\'h9200 + i*2 + 1, 8\'h3F);\n'
    '        end\n'
    '        $display("  [TB] GEMM2: BF16 2x12x8 all 1.0 (C[0][0] expect 0x41000000)");\n'
    '      end\n'
    '\n'
    '      // Initialize DONE_ADDR to 0\n'
    '      ddr_write_byte(32\'h9410, 8\'h00);\n'
    '      ddr_write_byte(32\'h9411, 8\'h00);\n'
    '      ddr_write_byte(32\'h9412, 8\'h00);\n'
    '      ddr_write_byte(32\'h9413, 8\'h00);\n'
    '\n'
    '      // Reset CPU and boot Phase 1\n'
    '      rst_n = 1\'b0;\n'
    '      repeat(10) @(posedge clk);\n'
    '      rst_n = 1\'b1;\n'
    '\n'
    '      // Wait for DONE_MAGIC from Phase 1\n'
    '      begin : wait_phase1\n'
    '        int mg_cnt;\n'
    '        mg_cnt = 0;\n'
    '        forever begin\n'
    '          @(posedge clk);\n'
    '          mg_cnt = mg_cnt + 1;\n'
    '          if (mg_cnt > 500_000) begin\n'
    '            $error("  [FAIL] Phase 1 TIMEOUT after %0d cycles", mg_cnt);\n'
    '            mg_errs = mg_errs + 1;\n'
    '            disable wait_phase1;\n'
    '          end\n'
    '          begin\n'
    '            logic [7:0] b0, b1, b2, b3;\n'
    '            b0 = dut.u_ddr.mem[32\'h9410];\n'
    '            b1 = dut.u_ddr.mem[32\'h9411];\n'
    '            b2 = dut.u_ddr.mem[32\'h9412];\n'
    '            b3 = dut.u_ddr.mem[32\'h9413];\n'
    '            if ({b3, b2, b1, b0} == 32\'hDEADBEEF) begin\n'
    '              $display("  [PASS] Phase 1: all 3 GEMMs completed in %0d cycles", mg_cnt);\n'
    '              disable wait_phase1;\n'
    '            end\n'
    '          end\n'
    '        end\n'
    '      end\n'
    '\n'
    '      // Quick C[0][0] check for GEMM0 and GEMM2 (Phase 1 readback)\n'
    '      begin\n'
    '        logic [7:0] c0, c1, c2, c3;\n'
    '        c0 = dut.u_ddr.mem[32\'h8400]; c1 = dut.u_ddr.mem[32\'h8401];\n'
    '        c2 = dut.u_ddr.mem[32\'h8402]; c3 = dut.u_ddr.mem[32\'h8403];\n'
    '        $display("  [TB] GEMM0 INT8 (3x5x8)  C[0][0] = 0x%08h (expect 0x00000008)", {c3, c2, c1, c0});\n'
    '        if ({c3, c2, c1, c0} != 32\'d8) begin\n'
    '          $error("  [FAIL] GEMM0 INT8 C[0][0] wrong"); mg_errs = mg_errs + 1;\n'
    '        end\n'
    '        c0 = dut.u_ddr.mem[32\'h9400]; c1 = dut.u_ddr.mem[32\'h9401];\n'
    '        c2 = dut.u_ddr.mem[32\'h9402]; c3 = dut.u_ddr.mem[32\'h9403];\n'
    '        $display("  [TB] GEMM2 BF16 (2x12x8) C[0][0] = 0x%08h (expect 0x41000000)", {c3, c2, c1, c0});\n'
    '        if ({c3, c2, c1, c0} != 32\'h41000000) begin\n'
    '          $error("  [FAIL] GEMM2 BF16 C[0][0] wrong"); mg_errs = mg_errs + 1;\n'
    '        end\n'
    '      end\n'
    '\n'
    '      // ---- Phase 2: Verification firmware (reads all 21 C elements via D-cache) ----\n'
    '      // Reload NPU firmware (CPU needs I-cache to boot, but DDR contents preserved)\n'
    '      begin\n'
    '        int fw_fd;\n'
    '        logic [7:0] fw_byte;\n'
    '        int fw_addr;\n'
    '        fw_fd = $fopen("sw/npu_ddr_bytes.hex", "r");\n'
    '        if (fw_fd != 0) begin\n'
    '          fw_addr = 0;\n'
    '          while (!$feof(fw_fd) && fw_addr < MEM_BYTES) begin\n'
    '            if ($fscanf(fw_fd, "%2h", fw_byte) == 1) begin\n'
    '              ddr_write_byte(fw_addr[31:0], fw_byte);\n'
    '              fw_addr = fw_addr + 1;\n'
    '            end\n'
    '          end\n'
    '          $fclose(fw_fd);\n'
    '        end\n'
    '      end\n'
    '\n'
    '      // Load Phase 2 verification firmware into DDR[0x000]\n'
    '      begin\n'
    '        logic [31:0] vfw [0:@@FW2_LAST@@];\n@@FW2_BLOCK@@'
    '        for (int i = 0; i < @@FW2_LEN@@; i++) begin\n'
    '          ddr_write_byte(i*4 + 0, vfw[i][7:0]);\n'
    '          ddr_write_byte(i*4 + 1, vfw[i][15:8]);\n'
    '          ddr_write_byte(i*4 + 2, vfw[i][23:16]);\n'
    '          ddr_write_byte(i*4 + 3, vfw[i][31:24]);\n'
    '        end\n'
    '        $display("  [TB] Phase 2 verification firmware loaded (%0d bytes)", @@FW2_LEN@@*4);\n'
    '      end\n'
    '\n'
    '      // Clear DONE_MAGIC so Phase 2 can detect its own completion\n'
    '      ddr_write_byte(32\'h9410, 8\'h00);\n'
    '      ddr_write_byte(32\'h9411, 8\'h00);\n'
    '      ddr_write_byte(32\'h9412, 8\'h00);\n'
    '      ddr_write_byte(32\'h9413, 8\'h00);\n'
    '\n'
    '      // Clear verification buffer\n'
    '      ddr_write_byte(32\'h0100, 8\'h00);\n'
    '      ddr_write_byte(32\'h0101, 8\'h00);\n'
    '      ddr_write_byte(32\'h0102, 8\'h00);\n'
    '      ddr_write_byte(32\'h0103, 8\'h00);\n'
    '\n'
    '      // Reset CPU and boot Phase 2\n'
    '      rst_n = 1\'b0;\n'
    '      repeat(10) @(posedge clk);\n'
    '      rst_n = 1\'b1;\n'
    '\n'
    '      // Wait for DONE_MAGIC from Phase 2\n'
    '      begin : wait_phase2\n'
    '        int mg_cnt;\n'
    '        mg_cnt = 0;\n'
    '        forever begin\n'
    '          @(posedge clk);\n'
    '          mg_cnt = mg_cnt + 1;\n'
    '          if (mg_cnt > 500_000) begin\n'
    '            $error("  [FAIL] Phase 2 TIMEOUT after %0d cycles", mg_cnt);\n'
    '            mg_errs = mg_errs + 1;\n'
    '            disable wait_phase2;\n'
    '          end\n'
    '          begin\n'
    '            logic [7:0] b0, b1, b2, b3;\n'
    '            b0 = dut.u_ddr.mem[32\'h9410];\n'
    '            b1 = dut.u_ddr.mem[32\'h9411];\n'
    '            b2 = dut.u_ddr.mem[32\'h9412];\n'
    '            b3 = dut.u_ddr.mem[32\'h9413];\n'
    '            if ({b3, b2, b1, b0} == 32\'hDEADBEEF) begin\n'
    '              $display("  [PASS] Phase 2: verification complete in %0d cycles", mg_cnt);\n'
    '              disable wait_phase2;\n'
    '            end\n'
    '          end\n'
    '        end\n'
    '      end\n'
    '\n'
    '      // Read verification buffer at DDR[0x100] and check all 21 elements\n'
    '      begin\n'
    '        logic [7:0] v0, v1, v2, v3;\n'
    '        logic [31:0] err_mask;\n'
    '        v0 = dut.u_ddr.mem[32\'h0100];\n'
    '        v1 = dut.u_ddr.mem[32\'h0101];\n'
    '        v2 = dut.u_ddr.mem[32\'h0102];\n'
    '        v3 = dut.u_ddr.mem[32\'h0103];\n'
    '        err_mask = {v3, v2, v1, v0};\n'
    '        $display("  [TB] GEMM1 C verification: error mask = 0x%08h (%0d failures)",\n'
    '                 err_mask, $countones(err_mask));\n'
    '        if (err_mask == 32\'h0000000) begin\n'
    '          $display("  [PASS] GEMM1: all 21 C elements verified correct (FP32 8.0)");\n'
    '        end else begin\n'
    '          // Decode which elements failed\n'
    '          for (int idx = 0; idx < 21; idx++) begin\n'
    '            if (err_mask[idx]) begin\n'
    '              $error("  [FAIL] GEMM1 C[%0d][%0d] wrong (elem %0d)", idx/3, idx%3, idx);\n'
    '            end\n'
    '          end\n'
    '          mg_errs = mg_errs + 1;\n'
    '        end\n'
    '      end\n'
    '\n'
    '      total_errs = total_errs + mg_errs;\n'
    '    end'
)

# Substitute tokens
new_test4_body = new_test4_body.replace('@@FW1_LAST@@', str(len(fw1) - 1))
new_test4_body = new_test4_body.replace('@@FW1_LEN@@', str(len(fw1)))
new_test4_body = new_test4_body.replace('@@FW1_BLOCK@@', fw1_block + chr(10))
new_test4_body = new_test4_body.replace('@@FW2_LAST@@', str(len(fw2) - 1))
new_test4_body = new_test4_body.replace('@@FW2_LEN@@', str(len(fw2)))
new_test4_body = new_test4_body.replace('@@FW2_BLOCK@@', fw2_block + chr(10))

new_content = content[:idx_start] + new_test4_body + content[idx_end:]
with open(TB_FILE, 'w') as f:
    f.write(new_content)

print(f'Replaced Test 4: chars {idx_start}-{idx_end}')
print(f'New file: {len(new_content)} chars')
