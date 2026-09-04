#!/usr/bin/env python
"""Replace Test 4 in tb_c930_soc_full.sv with mixed-precision varying-shape test.

Queues 3 GEMMs with different precisions AND asymmetric shapes:
  GEMM0: INT8  3x5x8,  all 1s  -> C[0][0] = 8   (INT32 0x00000008)
  GEMM1: FP16  7x3x8,  all 1.0 -> C[0][0] = 8.0 (FP32 0x41000000)
  GEMM2: BF16  2x12x8, all 1.0 -> C[0][0] = 8.0 (FP32 0x41000000)

This stress-tests:
  - Mixed-precision CSR dispatch (PREC=0/2/3 in rapid succession)
  - DMA element packing (1B INT8 vs 2B FP16/BF16)
  - Asymmetric shapes (M, N non-power-of-2, non-multiple of 8)
  - Bank switching across different operand sizes
  - Cross-GEMM prefetch with mixed element counts
"""

TB_FILE = 'tb/tb_c930_soc_full.sv'

# --- Encode RISC-V instructions ---
def lui(rd, imm20):
    return (imm20 << 12) | (rd << 7) | 0b0110111

def addi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0b0010011

def sw(rs2, rs1, imm12):
    imm = imm12 & 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | ((imm & 0x1F) << 7) | 0b0100011

def lw(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0b0000011

def andi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0b0010011

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

def jal(rd, imm21):
    imm = imm21 & 0x1FFFFF
    b20   = (imm >> 20) & 1
    b101  = (imm >> 1) & 0x3FF
    b11   = (imm >> 11) & 1
    b1912 = (imm >> 12) & 0xFF
    return (b20 << 31) | (b101 << 21) | (b11 << 20) | (b1912 << 12) | (rd << 7) | 0b1101111

# Register aliases
x0  = 0
x10 = 10  # a0 = MMIO_BASE
x11 = 11  # a1 = temp
x15 = 15  # a5 = DONE_ADDR
x16 = 16  # a6 = DONE_MAGIC

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

# Build firmware
fw = []

# --- Helper: emit a GEMM config sequence ---
def emit_gemm(dim_m, dim_n, dim_k, a_lo12, a_hi20, b_lo12, b_hi20,
              c_lo12, c_hi20, prec, label):
    """Emit 10 instructions: DIM_M, DIM_N, DIM_K, A_BASE, B_BASE, C_BASE, PREC, barrier, START."""
    global fw
    base = len(fw)
    # Helper: emit lui+addi to load a 32-bit address
    def load_addr(val, reg, msg):
        lo12 = val & 0xFFF
        hi20 = (val - lo12) & 0xFFFFF  # adjust hi if lo is sign-extended
        if lo12 >= 0x800:
            hi20 = ((val + 0x1000) - ((lo12 - 0x1000) & 0xFFF)) & 0xFFFFF
            # For lui+addi with signed addi: lui(hi) + addi(lo) where lo is sign-extended
            # If lo >= 0x800: addi encodes as negative, so effective = (hi<<12) + sign_ext(lo)
            # We want (hi<<12) + sign_ext(lo) == val
            # sign_ext(lo) = lo - 0x1000 (when lo >= 0x800)
            # So hi<<12 = val - (lo - 0x1000) = val - lo + 0x1000
            hi20 = (val - lo12 + 0x1000) >> 12
        else:
            hi20 = val >> 12
        fw.append(lui(reg, hi20))
        fw.append(addi(reg, reg, lo12))

    # DIM_M
    fw.append(lui(x11, 0))
    fw.append(addi(x11, x11, dim_m))
    fw.append(sw(x11, x10, OFF_DIM_M))

    # DIM_N
    fw.append(lui(x11, 0))
    fw.append(addi(x11, x11, dim_n))
    fw.append(sw(x11, x10, OFF_DIM_N))

    # DIM_K
    fw.append(lui(x11, 0))
    fw.append(addi(x11, x11, dim_k))
    fw.append(sw(x11, x10, OFF_DIM_K))

    # A_BASE
    load_addr(a_addr, x11, f'{label} A')
    fw.append(sw(x11, x10, OFF_A_BASE))

    # B_BASE
    load_addr(b_addr, x11, f'{label} B')
    fw.append(sw(x11, x10, OFF_B_BASE))

    # C_BASE
    load_addr(c_addr, x11, f'{label} C')
    fw.append(sw(x11, x10, OFF_C_BASE))

    # PREC
    fw.append(lui(x11, 0))
    fw.append(addi(x11, x11, prec))
    fw.append(sw(x11, x10, OFF_PREC))

    # Barrier (read PREC back)
    fw.append(lw(x11, x10, OFF_PREC))

    # START
    fw.append(addi(x11, x0, 1))
    fw.append(sw(x11, x10, OFF_START))

    return base

# --- Setup ---
fw.append(lui(x10, 0x40000))   # MMIO_BASE
fw.append(addi(x10, x10, 0))

# --- GEMM 0: INT8, 3x5x8, all 1s ---
# A: 3*8=24B @0x8000, B: 8*5=40B @0x8200, C: 3*5=15*4=60B @0x8400
a_addr, b_addr, c_addr = 0x8000, 0x8200, 0x8400
emit_gemm(3, 5, 8, a_addr & 0xFFF, a_addr >> 12,
          b_addr & 0xFFF, b_addr >> 12,
          c_addr & 0xFFF, c_addr >> 12,
          0, "GEMM0")  # PREC=0 INT8

# --- GEMM 1: FP16, 7x3x8, all 1.0 ---
# A: 7*8=56 elem *2B=112B @0x8800, B: 8*3=24 elem *2B=48B @0x8A00, C: 7*3=21*4=84B @0x8C00
a_addr, b_addr, c_addr = 0x8800, 0x8A00, 0x8C00
emit_gemm(7, 3, 8, a_addr & 0xFFF, a_addr >> 12,
          b_addr & 0xFFF, b_addr >> 12,
          c_addr & 0xFFF, c_addr >> 12,
          2, "GEMM1")  # PREC=2 FP16

# --- GEMM 2: BF16, 2x12x8, all 1.0 ---
# A: 2*8=16 elem *2B=32B @0x9000, B: 8*12=96 elem *2B=192B @0x9200, C: 2*12=24*4=96B @0x9400
a_addr, b_addr, c_addr = 0x9000, 0x9200, 0x9400
emit_gemm(2, 12, 8, a_addr & 0xFFF, a_addr >> 12,
          b_addr & 0xFFF, b_addr >> 12,
          c_addr & 0xFFF, c_addr >> 12,
          3, "GEMM2")  # PREC=3 BF16

# --- Two-phase poll ---
fw.append(lw(x11, x10, OFF_PREC))        # barrier read
fw.append(lw(x11, x10, OFF_STATUS))       # STATUS
fw.append(andi(x11, x11, 2))             # DONE bit
fw.append(beq(x11, x0, -8))              # poll done: offset = -8 bytes = 2 instr * -4
fw.append(lw(x11, x10, OFF_STATUS))       # STATUS
fw.append(andi(x11, x11, 1))             # BUSY bit
fw.append(bne(x11, x0, -8))              # poll busy

# --- Write DONE_MAGIC ---
fw.append(lui(x15, 0x9))                  # DONE_ADDR=0x9410
fw.append(addi(x15, x15, 0x410))
fw.append(lui(x16, 0xDEADC))             # DONE_MAGIC=0xDEADBEEF
fw.append(addi(x16, x16, 0xEEF))
fw.append(sw(x16, x15, 0))
fw.append(jal(x0, 0))                    # self-loop

print(f"Firmware: {len(fw)} instructions")

# --- Verify addresses ---
for i, inst in enumerate(fw):
    print(f"  fw[{i:2d}] = 32'h{inst:08X}")

# --- Read and patch testbench ---
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

# --- FP16 1.0 = 0x3C00, BF16 1.0 = 0x3F80 ---
new_test4 = r"""    // =========================================================================
    // Test 4: Mixed-precision varying-shape queue drain
    //
    // Queues 3 GEMMs with different precisions AND asymmetric shapes:
    //   GEMM0: INT8  3x5x8,  all 1s  -> C[0][0] = 8   (INT32 0x00000008)
    //   GEMM1: FP16  7x3x8,  all 1.0 -> C[0][0] = 8.0 (FP32 0x41000000)
    //   GEMM2: BF16  2x12x8, all 1.0 -> C[0][0] = 8.0 (FP32 0x41000000)
    // =========================================================================
    $display("\n========================================");
    $display("  TEST 4: Mixed-precision varying-shape (INT8+FP16+BF16)");
    $display("========================================");
    begin
      int mg_errs;
      mg_errs = 0;

      // Reload NPU firmware from hex file
      begin
        int fw_fd;
        logic [7:0] fw_byte;
        int fw_addr;
        fw_fd = $fopen("sw/npu_ddr_bytes.hex", "r");
        if (fw_fd != 0) begin
          fw_addr = 0;
          while (!$feof(fw_fd) && fw_addr < MEM_BYTES) begin
            if ($fscanf(fw_fd, "%2h", fw_byte) == 1) begin
              ddr_write_byte(fw_addr[31:0], fw_byte);
              fw_addr = fw_addr + 1;
            end
          end
          $fclose(fw_fd);
          $display("  [TB] Reloaded %0d firmware bytes into DDR", fw_addr);
        end
      end

      // Mixed-precision varying-shape firmware
      begin
        logic [31:0] fw [0:FONT_COUNT];
"""

# Generate firmware lines
fw_lines = []
fw_lines.append('        // --- Setup ---')
fw_lines.append(f'        fw[0]  = 32\'h{fw[0]:08X};  // lui  x10, 0x40000 (MMIO_BASE)')
fw_lines.append(f'        fw[1]  = 32\'h{fw[1]:08X};  // addi x10, x10, 0')

# GEMM0 comments
fw_lines.append(f'        // --- GEMM 0: INT8 3x5x8 A@0x8000 B@0x8200 C@0x8400 PREC=0 ---')
fw_lines.append(f'        fw[2]  = 32\'h{fw[2]:08X};  // lui  x11, 0')
fw_lines.append(f'        fw[3]  = 32\'h{fw[3]:08X};  // addi x11, x11, 3    DIM_M=3')
fw_lines.append(f'        fw[4]  = 32\'h{fw[4]:08X};  // sw   x11, 0x08(x10)')
fw_lines.append(f'        fw[5]  = 32\'h{fw[5]:08X};  // lui  x11, 0')
fw_lines.append(f'        fw[6]  = 32\'h{fw[6]:08X};  // addi x11, x11, 5    DIM_N=5')
fw_lines.append(f'        fw[7]  = 32\'h{fw[7]:08X};  // sw   x11, 0x0C(x10)')
fw_lines.append(f'        fw[8]  = 32\'h{fw[8]:08X};  // lui  x11, 0')
fw_lines.append(f'        fw[9]  = 32\'h{fw[9]:08X};  // addi x11, x11, 8    DIM_K=8')
fw_lines.append(f'        fw[10] = 32\'h{fw[10]:08X}; // sw   x11, 0x10(x10)')
fw_lines.append(f'        fw[11] = 32\'h{fw[11]:08X}; // lui  x11, 0x8')
fw_lines.append(f'        fw[12] = 32\'h{fw[12]:08X}; // addi x11, x11, 0    A=0x8000 (3*8=24B)')
fw_lines.append(f'        fw[13] = 32\'h{fw[13]:08X}; // sw   x11, 0x14(x10)')
fw_lines.append(f'        fw[14] = 32\'h{fw[14]:08X}; // lui  x11, 0x8')
fw_lines.append(f'        fw[15] = 32\'h{fw[15]:08X}; // addi x11, x11, 0x200 B=0x8200 (8*5=40B)')
fw_lines.append(f'        fw[16] = 32\'h{fw[16]:08X}; // sw   x11, 0x18(x10)')
fw_lines.append(f'        fw[17] = 32\'h{fw[17]:08X}; // lui  x11, 0x8')
fw_lines.append(f'        fw[18] = 32\'h{fw[18]:08X}; // addi x11, x11, 0x400 C=0x8400')
fw_lines.append(f'        fw[19] = 32\'h{fw[19]:08X}; // sw   x11, 0x1C(x10)')
fw_lines.append(f'        fw[20] = 32\'h{fw[20]:08X}; // lui  x11, 0')
fw_lines.append(f'        fw[21] = 32\'h{fw[21]:08X}; // addi x11, x11, 0    PREC=0 (INT8)')
fw_lines.append(f'        fw[22] = 32\'h{fw[22]:08X}; // sw   x11, 0x20(x10)')
fw_lines.append(f'        fw[23] = 32\'h{fw[23]:08X}; // lw   x11, 0x20(x10) barrier')
fw_lines.append(f'        fw[24] = 32\'h{fw[24]:08X}; // addi x11, x0, 1')
fw_lines.append(f'        fw[25] = 32\'h{fw[25]:08X}; // sw   x11, 0x00(x10) START')

# GEMM1
fw_lines.append(f'        // --- GEMM 1: FP16 7x3x8 A@0x8800 B@0x8A00 C@0x8C00 PREC=2 ---')
for i in range(26, 50):
    comment = ""
    if i == 26: comment = "// lui  x11, 0"
    elif i == 27: comment = "// addi x11, x11, 7    DIM_M=7"
    elif i == 28: comment = "// sw   x11, 0x08(x10)"
    elif i == 29: comment = "// lui  x11, 0"
    elif i == 30: comment = "// addi x11, x11, 3    DIM_N=3"
    elif i == 31: comment = "// sw   x11, 0x0C(x10)"
    elif i == 32: comment = "// lui  x11, 0"
    elif i == 33: comment = "// addi x11, x11, 8    DIM_K=8"
    elif i == 34: comment = "// sw   x11, 0x10(x10)"
    elif i == 35: comment = "// lui  x11, 0x9"
    elif i == 36: comment = "// addi x11, x11, 0x800 A=0x8800 (7*8*2=112B)"
    elif i == 37: comment = "// sw   x11, 0x14(x10)"
    elif i == 38: comment = "// lui  x11, 0x9"
    elif i == 39: comment = "// addi x11, x11, 0xA00 B=0x8A00 (8*3*2=48B)"
    elif i == 40: comment = "// sw   x11, 0x18(x10)"
    elif i == 41: comment = "// lui  x11, 0x9"
    elif i == 42: comment = "// addi x11, x11, 0xC00 C=0x8C00"
    elif i == 43: comment = "// sw   x11, 0x1C(x10)"
    elif i == 44: comment = "// lui  x11, 0"
    elif i == 45: comment = "// addi x11, x11, 2    PREC=2 (FP16)"
    elif i == 46: comment = "// sw   x11, 0x20(x10)"
    elif i == 47: comment = "// lw   x11, 0x20(x10) barrier"
    elif i == 48: comment = "// addi x11, x0, 1"
    elif i == 49: comment = "// sw   x11, 0x00(x10) START"
    fw_lines.append(f'        fw[{i:2d}] = 32\'h{fw[i]:08X}; {comment}')

# GEMM2
fw_lines.append(f'        // --- GEMM 2: BF16 2x12x8 A@0x9000 B@0x9200 C@0x9400 PREC=3 ---')
for i in range(50, 74):
    comment = ""
    if i == 50: comment = "// lui  x11, 0"
    elif i == 51: comment = "// addi x11, x11, 2    DIM_M=2"
    elif i == 52: comment = "// sw   x11, 0x08(x10)"
    elif i == 53: comment = "// lui  x11, 0"
    elif i == 54: comment = "// addi x11, x11, 12   DIM_N=12"
    elif i == 55: comment = "// sw   x11, 0x0C(x10)"
    elif i == 56: comment = "// lui  x11, 0"
    elif i == 57: comment = "// addi x11, x11, 8    DIM_K=8"
    elif i == 58: comment = "// sw   x11, 0x10(x10)"
    elif i == 59: comment = "// lui  x11, 0x9"
    elif i == 60: comment = "// addi x11, x11, 0    A=0x9000 (2*8*2=32B)"
    elif i == 61: comment = "// sw   x11, 0x14(x10)"
    elif i == 62: comment = "// lui  x11, 0x9"
    elif i == 63: comment = "// addi x11, x11, 0x200 B=0x9200 (8*12*2=192B)"
    elif i == 64: comment = "// sw   x11, 0x18(x10)"
    elif i == 65: comment = "// lui  x11, 0x9"
    elif i == 66: comment = "// addi x11, x11, 0x400 C=0x9400"
    elif i == 67: comment = "// sw   x11, 0x1C(x10)"
    elif i == 68: comment = "// lui  x11, 0"
    elif i == 69: comment = "// addi x11, x11, 3    PREC=3 (BF16)"
    elif i == 70: comment = "// sw   x11, 0x20(x10)"
    elif i == 71: comment = "// lw   x11, 0x20(x10) barrier"
    elif i == 72: comment = "// addi x11, x0, 1"
    elif i == 73: comment = "// sw   x11, 0x00(x10) START"
    fw_lines.append(f'        fw[{i:2d}] = 32\'h{fw[i]:08X}; {comment}')

# Poll + done
poll_start = 74
fw_lines.append(f'        // --- Two-phase poll: wait done_latch, then wait DMA idle ---')
fw_lines.append(f'        fw[{poll_start}]   = 32\'h{fw[poll_start]:08X};  // lw   x11, 0x20(x10) barrier read')
fw_lines.append(f'        fw[{poll_start+1}] = 32\'h{fw[poll_start+1]:08X};  // lw   x11, 0x04(x10) STATUS')
fw_lines.append(f'        fw[{poll_start+2}] = 32\'h{fw[poll_start+2]:08X};  // andi x11, x11, 2    DONE bit')
fw_lines.append(f'        fw[{poll_start+3}] = 32\'h{fw[poll_start+3]:08X};  // beq  x11, x0, -8   poll done')
fw_lines.append(f'        fw[{poll_start+4}] = 32\'h{fw[poll_start+4]:08X};  // lw   x11, 0x04(x10) STATUS')
fw_lines.append(f'        fw[{poll_start+5}] = 32\'h{fw[poll_start+5]:08X};  // andi x11, x11, 1    BUSY bit')
fw_lines.append(f'        fw[{poll_start+6}] = 32\'h{fw[poll_start+6]:08X};  // bne  x11, x0, -8   poll busy')

done_start = 81
fw_lines.append(f'        // --- Write DONE_MAGIC ---')
fw_lines.append(f'        fw[{done_start}]   = 32\'h{fw[done_start]:08X};  // lui  x15, 0x9')
fw_lines.append(f'        fw[{done_start+1}] = 32\'h{fw[done_start+1]:08X};  // addi x15, x15, 0x410 DONE_ADDR=0x9410')
fw_lines.append(f'        fw[{done_start+2}] = 32\'h{fw[done_start+2]:08X};  // lui  x16, 0xDEADC')
fw_lines.append(f'        fw[{done_start+3}] = 32\'h{fw[done_start+3]:08X};  // addi x16, x16, 0xEEF DONE_MAGIC=0xDEADBEEF')
fw_lines.append(f'        fw[{done_start+4}] = 32\'h{fw[done_start+4]:08X};  // sw   x16, 0(x15)')
fw_lines.append(f'        fw[{done_start+5}] = 32\'h{fw[done_start+5]:08X};  // jal  x0, 0  self-loop')

fw_block = '\n'.join(fw_lines)

# Fix the FONT_COUNT placeholder
new_test4_body = new_test4.replace('FONT_COUNT', str(len(fw) - 1))
new_test4_body += fw_block

new_test4_body += r"""
        for (int i = 0; i < """ + str(len(fw)) + r"""; i++) begin
          ddr_write_byte(i*4 + 0, fw[i][7:0]);
          ddr_write_byte(i*4 + 1, fw[i][15:8]);
          ddr_write_byte(i*4 + 2, fw[i][23:16]);
          ddr_write_byte(i*4 + 3, fw[i][31:24]);
        end
        $display("  [TB] Mixed-precision firmware loaded (%0d bytes)", """ + str(len(fw)) + r"""*4);
      end

      // --- Preload A/B operands ---
      // GEMM 0: INT8 3x5x8 all 1s
      //   A=24B @0x8000, B=40B @0x8200
      begin
        for (int i = 0; i < 24; i++)
          ddr_write_byte(32'h8000 + i, 8'd1);
        for (int i = 0; i < 40; i++)
          ddr_write_byte(32'h8200 + i, 8'd1);
        $display("  [TB] GEMM0: INT8 3x5x8 all 1s (C[0][0] expect 0x00000008)");
      end
      // GEMM 1: FP16 7x3x8 all 1.0
      //   A=112B @0x8800, B=48B @0x8A00
      //   FP16 1.0 = 0x3C00 (little-endian: byte 0=0x00, byte 1=0x3C)
      begin
        for (int i = 0; i < 56; i++) begin
          ddr_write_byte(32'h8800 + i*2 + 0, 8'h00);  // FP16 1.0 LSB
          ddr_write_byte(32'h8800 + i*2 + 1, 8'h3C);  // FP16 1.0 MSB
        end
        for (int i = 0; i < 24; i++) begin
          ddr_write_byte(32'h8A00 + i*2 + 0, 8'h00);
          ddr_write_byte(32'h8A00 + i*2 + 1, 8'h3C);
        end
        $display("  [TB] GEMM1: FP16 7x3x8 all 1.0 (C[0][0] expect 0x41000000)");
      end
      // GEMM 2: BF16 2x12x8 all 1.0
      //   A=32B @0x9000, B=192B @0x9200
      //   BF16 1.0 = 0x3F80 (little-endian: byte 0=0x80, byte 1=0x3F)
      begin
        for (int i = 0; i < 16; i++) begin
          ddr_write_byte(32'h9000 + i*2 + 0, 8'h80);  // BF16 1.0 LSB
          ddr_write_byte(32'h9000 + i*2 + 1, 8'h3F);  // BF16 1.0 MSB
        end
        for (int i = 0; i < 96; i++) begin
          ddr_write_byte(32'h9200 + i*2 + 0, 8'h80);
          ddr_write_byte(32'h9200 + i*2 + 1, 8'h3F);
        end
        $display("  [TB] GEMM2: BF16 2x12x8 all 1.0 (C[0][0] expect 0x41000000)");
      end

      // Initialize DONE_ADDR to 0
      ddr_write_byte(32'h9410, 8'h00);
      ddr_write_byte(32'h9411, 8'h00);
      ddr_write_byte(32'h9412, 8'h00);
      ddr_write_byte(32'h9413, 8'h00);

      // Reset CPU and boot
      rst_n = 1'b0;
      repeat(10) @(posedge clk);
      rst_n = 1'b1;

      // Wait for DONE_MAGIC at DDR[0x9410]
      begin : wait_varying
        int mg_cnt;
        mg_cnt = 0;
        forever begin
          @(posedge clk);
          mg_cnt = mg_cnt + 1;
          if (mg_cnt > 500_000) begin
            $error("  [FAIL] Mixed-precision TIMEOUT after %0d cycles", mg_cnt);
            mg_errs = mg_errs + 1;
            disable wait_varying;
          end
          begin
            logic [7:0] b0, b1, b2, b3;
            b0 = dut.u_ddr.mem[32'h9410];
            b1 = dut.u_ddr.mem[32'h9411];
            b2 = dut.u_ddr.mem[32'h9412];
            b3 = dut.u_ddr.mem[32'h9413];
            if ({b3, b2, b1, b0} == 32'hDEADBEEF) begin
              $display("  [PASS] Mixed-precision: all 3 GEMMs completed in %0d cycles", mg_cnt);
              disable wait_varying;
            end
          end
        end
      end

      // Verify C results
      begin
        logic [7:0] c0, c1, c2, c3;
        // GEMM 0: INT8 3x5x8 all-1s -> C[0][0] = K = 8 (INT32)
        c0 = dut.u_ddr.mem[32'h8400];
        c1 = dut.u_ddr.mem[32'h8401];
        c2 = dut.u_ddr.mem[32'h8402];
        c3 = dut.u_ddr.mem[32'h8403];
        $display("  [TB] GEMM0 INT8 (3x5x8)  C[0][0] = 0x%08h (expect 0x00000008)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'd8) begin
          $error("  [FAIL] GEMM0 INT8 C[0][0] wrong");
          mg_errs = mg_errs + 1;
        end
        // GEMM 1: FP16 7x3x8 all-1.0 -> C[0][0] = 8.0 (FP32 = 0x41000000)
        c0 = dut.u_ddr.mem[32'h8C00];
        c1 = dut.u_ddr.mem[32'h8C01];
        c2 = dut.u_ddr.mem[32'h8C02];
        c3 = dut.u_ddr.mem[32'h8C03];
        $display("  [TB] GEMM1 FP16 (7x3x8)  C[0][0] = 0x%08h (expect 0x41000000)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'h41000000) begin
          $error("  [FAIL] GEMM1 FP16 C[0][0] wrong");
          mg_errs = mg_errs + 1;
        end
        // GEMM 2: BF16 2x12x8 all-1.0 -> C[0][0] = 8.0 (FP32 = 0x41000000)
        c0 = dut.u_ddr.mem[32'h9400];
        c1 = dut.u_ddr.mem[32'h9401];
        c2 = dut.u_ddr.mem[32'h9402];
        c3 = dut.u_ddr.mem[32'h9403];
        $display("  [TB] GEMM2 BF16 (2x12x8) C[0][0] = 0x%08h (expect 0x41000000)", {c3, c2, c1, c0});
        if ({c3, c2, c1, c0} != 32'h41000000) begin
          $error("  [FAIL] GEMM2 BF16 C[0][0] wrong");
          mg_errs = mg_errs + 1;
        end
      end
      total_errs = total_errs + mg_errs;
    end"""

new_content = content[:idx_start] + new_test4_body + content[idx_end:]
with open(TB_FILE, 'w') as f:
    f.write(new_content)

print(f'Replaced Test 4: chars {idx_start}-{idx_end}')
print(f'New file: {len(new_content)} chars')
