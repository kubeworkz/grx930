#!/usr/bin/env python
"""Add Test 5: 6 back-to-back GEMMs of increasing size to stress command queue.

CMD_QUEUE_DEPTH = 4, so we queue 4 GEMMs (fill queue), poll to drain,
then queue 2 more (second drain cycle). This exercises:
  - Queue fill-to-capacity and backpressure
  - DMA dispatch ordering across different GEMM shapes
  - Bank switching with increasing operand sizes
  - Two complete fill/drain cycles

GEMMs (all INT8, all 1s, K=4):
  GEMM0: 2x2x4  → C[0][0] = 4
  GEMM1: 3x3x4  → C[0][0] = 4
  GEMM2: 4x4x4  → C[0][0] = 4
  GEMM3: 5x3x4  → C[0][0] = 4
  GEMM4: 3x6x4  → C[0][0] = 4
  GEMM5: 6x6x4  → C[0][0] = 4
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

def beq(rs1, rs2, imm13):
    imm = imm13 & 0x1FFF
    return (((imm>>12)&1)<<31) | (((imm>>5)&0x3F)<<25) | (rs2<<20) | (rs1<<15) | (0b000<<12) | (((imm>>1)&0xF)<<8) | (((imm>>11)&1)<<7) | 0b1100011

def bne(rs1, rs2, imm13):
    imm = imm13 & 0x1FFF
    return (((imm>>12)&1)<<31) | (((imm>>5)&0x3F)<<25) | (rs2<<20) | (rs1<<15) | (0b001<<12) | (((imm>>1)&0xF)<<8) | (((imm>>11)&1)<<7) | 0b1100011

def jal(rd, imm21):
    imm = imm21 & 0x1FFFFF
    return (((imm>>20)&1)<<31) | (((imm>>1)&0x3FF)<<21) | (((imm>>11)&1)<<20) | (((imm>>12)&0xFF)<<12) | (rd<<7) | 0b1101111

# === Register aliases ===
x0=0; x10=10; x11=11; x15=15; x16=16

# CSR offsets
OFF_START=0x00; OFF_STATUS=0x04; OFF_DIM_M=0x08; OFF_DIM_N=0x0C
OFF_DIM_K=0x10; OFF_A_BASE=0x14; OFF_B_BASE=0x18; OFF_C_BASE=0x1C
OFF_PREC=0x20

# GEMM shapes and data layout
# All INT8, all 1s, K=4. C[0][0] = K = 4 for all.
gemms = [
    (2, 2, 4, 0x8000, 0x8040, 0x8080),  # GEMM0: 2x2x4
    (3, 3, 4, 0x8100, 0x8140, 0x8180),  # GEMM1: 3x3x4
    (4, 4, 4, 0x8200, 0x8240, 0x8280),  # GEMM2: 4x4x4
    (5, 3, 4, 0x8300, 0x8340, 0x8380),  # GEMM3: 5x3x4
    (3, 6, 4, 0x8400, 0x8440, 0x8480),  # GEMM4: 3x6x4
    (6, 6, 4, 0x8500, 0x8540, 0x8580),  # GEMM5: 6x6x4
]

def load_addr_32(val, reg):
    """Load a 32-bit address into reg using lui+addi."""
    lo12 = val & 0xFFF
    if lo12 >= 0x800:
        hi20 = (val - lo12 + 0x1000) >> 12
    else:
        hi20 = val >> 12
    return [lui(reg, hi20), addi(reg, reg, lo12)]

# Build firmware
fw = []

# Setup MMIO_BASE
fw += load_addr_32(0x40000000, x10)

# Write PREC=0 (INT8) and barrier
fw += [addi(x11, x0, 0), sw(x11, x10, OFF_PREC), lw(x11, x10, OFF_PREC)]

# --- Batch 1: Queue GEMMs 0-3 (fills 4-deep queue) ---
gemm_labels = []
for i, (m, n, k, a, b, c) in enumerate(gemms[:4]):
    gemm_labels.append(len(fw))
    fw += [addi(x11, x0, m), sw(x11, x10, OFF_DIM_M)]
    fw += [addi(x11, x0, n), sw(x11, x10, OFF_DIM_N)]
    fw += [addi(x11, x0, k), sw(x11, x10, OFF_DIM_K)]
    fw += load_addr_32(a, x11); fw += [sw(x11, x10, OFF_A_BASE)]
    fw += load_addr_32(b, x11); fw += [sw(x11, x10, OFF_B_BASE)]
    fw += load_addr_32(c, x11); fw += [sw(x11, x10, OFF_C_BASE)]
    fw += [addi(x11, x0, 1), sw(x11, x10, OFF_START)]

# --- Poll 1: Wait for all 4 to complete ---
poll1_start = len(fw)
fw += [lw(x11, x10, OFF_STATUS)]
fw += [andi(x11, x11, 2)]
fw += [beq(x11, x0, -8)]          # poll done
fw += [lw(x11, x10, OFF_STATUS)]
fw += [andi(x11, x11, 1)]
fw += [bne(x11, x0, -8)]          # poll busy

# --- Batch 2: Queue GEMMs 4-5 ---
for i, (m, n, k, a, b, c) in enumerate(gemms[4:]):
    gemm_labels.append(len(fw))
    fw += [addi(x11, x0, m), sw(x11, x10, OFF_DIM_M)]
    fw += [addi(x11, x0, n), sw(x11, x10, OFF_DIM_N)]
    fw += [addi(x11, x0, k), sw(x11, x10, OFF_DIM_K)]
    fw += load_addr_32(a, x11); fw += [sw(x11, x10, OFF_A_BASE)]
    fw += load_addr_32(b, x11); fw += [sw(x11, x10, OFF_B_BASE)]
    fw += load_addr_32(c, x11); fw += [sw(x11, x10, OFF_C_BASE)]
    fw += [addi(x11, x0, 1), sw(x11, x10, OFF_START)]

# --- Poll 2: Wait for GEMMs 4-5 to complete ---
poll2_start = len(fw)
fw += [lw(x11, x10, OFF_STATUS)]
fw += [andi(x11, x11, 2)]
fw += [beq(x11, x0, -8)]
fw += [lw(x11, x10, OFF_STATUS)]
fw += [andi(x11, x11, 1)]
fw += [bne(x11, x0, -8)]

# --- Write DONE_MAGIC ---
fw += load_addr_32(0x9410, x15)
fw += [lui(x16, 0xDEADC), addi(x16, x16, 0xEEF)]
fw += [sw(x16, x15, 0)]
fw += [jal(x0, 0)]  # self-loop

print(f"Firmware: {len(fw)} instructions, {len(fw)*4} bytes")
for i, inst in enumerate(fw):
    print(f"  fw[{i:3d}] = 32'h{inst:08X}")

# === Read and patch testbench ===
with open(TB_FILE, 'r') as f:
    content = f.read()

# Insert Test 5 BEFORE the summary, which is after Test 4's end
summary_marker = '    // Summary'
idx_insert = content.find(summary_marker)
if idx_insert == -1:
    print('ERROR: summary marker not found')
    exit(1)

# Find the blank line before summary
idx_start = content.rfind('\n', 0, idx_insert)
idx_end = idx_insert

# Build firmware instruction lines
fw_lines = []
for i, inst in enumerate(fw):
    fw_lines.append(f'        fw[{i:3d}] = 32\'h{inst:08X};')
fw_block = '\n'.join(fw_lines)

# Build C verification lines
c_checks = []
for gi, (m, n, k, a, b, c_base) in enumerate(gemms):
    lo = c_base
    c_checks.append(f'        // GEMM{gi}: {m}x{n}x{k} -> C[0][0] = {k}')
    c_checks.append(f'        c0 = dut.u_ddr.mem[32\'h{lo:04X}]; c1 = dut.u_ddr.mem[32\'h{lo+1:04X}];')
    c_checks.append(f'        c2 = dut.u_ddr.mem[32\'h{lo+2:04X}]; c3 = dut.u_ddr.mem[32\'h{lo+3:04X}];')
    c_checks.append(f'        $display("  [TB] GEMM{gi} ({m}x{n}x{k}) C[0][0] = 0x%08h (expect 0x000000{0x04:02X})", {{c3, c2, c1, c0}});')
    c_checks.append(f'        if ({{c3, c2, c1, c0}} != 32\'d{k}) begin')
    c_checks.append(f'          $error("  [FAIL] GEMM{gi} ({m}x{n}x{k}) C[0][0] wrong"); mg_errs = mg_errs + 1;')
    c_checks.append(f'        end')
c_check_block = '\n'.join(c_checks)

# Build data preload lines
preload_lines = []
for gi, (m, n, k, a_base, b_base, c_base) in enumerate(gemms):
    a_bytes = m * k
    b_bytes = k * n
    preload_lines.append(f'      // GEMM{gi}: {m}x{n}x{k} all 1s -- A={a_bytes}B @0x{a_base:04X}, B={b_bytes}B @0x{b_base:04X}')
    preload_lines.append(f'      begin')
    preload_lines.append(f'        for (int i = 0; i < {a_bytes}; i++)')
    preload_lines.append(f'          ddr_write_byte(32\'h{a_base:04X} + i, 8\'d1);')
    preload_lines.append(f'        for (int i = 0; i < {b_bytes}; i++)')
    preload_lines.append(f'          ddr_write_byte(32\'h{b_base:04X} + i, 8\'d1);')
    preload_lines.append(f'      end')
preload_block = '\n'.join(preload_lines)

new_test = (
    '    // =========================================================================\n'
    '    // Test 5: 6-GEMM queue stress test (fill queue to capacity, drain twice)\n'
    '    //\n'
    '    // CMD_QUEUE_DEPTH = 4. Queue 4 GEMMs (fill queue), poll to drain,\n'
    '    // then queue 2 more (second drain cycle). Exercises:\n'
    '    //   - Queue fill-to-capacity and backpressure\n'
    '    //   - DMA dispatch ordering across different shapes\n'
    '    //   - Bank switching with increasing operand sizes\n'
    '    //   - Two complete fill/drain cycles\n'
    '    //\n'
    '    // GEMMs (all INT8, all 1s, K=4):\n'
    '    //   GEMM0: 2x2x4  GEMM1: 3x3x4  GEMM2: 4x4x4\n'
    '    //   GEMM3: 5x3x4  GEMM4: 3x6x4  GEMM5: 6x6x4\n'
    '    //   All C[0][0] = K = 4\n'
    '    // =========================================================================\n'
    '    $display("\\n========================================");\n'
    '    $display("  TEST 5: 6-GEMM queue stress (fill+drain x2)");\n'
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
    '      // Load queue-stress firmware\n'
    '      begin\n'
    '        logic [31:0] fw [0:@@FW_LAST@@];\n'
    '@@FW_BLOCK@@\n'
    '        for (int i = 0; i < @@FW_LEN@@; i++) begin\n'
    '          ddr_write_byte(i*4 + 0, fw[i][7:0]);\n'
    '          ddr_write_byte(i*4 + 1, fw[i][15:8]);\n'
    '          ddr_write_byte(i*4 + 2, fw[i][23:16]);\n'
    '          ddr_write_byte(i*4 + 3, fw[i][31:24]);\n'
    '        end\n'
    '        $display("  [TB] Queue-stress firmware loaded (%0d bytes)", @@FW_LEN@@*4);\n'
    '      end\n'
    '\n'
    '      // Preload A/B operands\n'
    '@@PRELOAD_BLOCK@@\n'
    '\n'
    '      // Initialize DONE_ADDR to 0\n'
    '      ddr_write_byte(32\'h9410, 8\'h00);\n'
    '      ddr_write_byte(32\'h9411, 8\'h00);\n'
    '      ddr_write_byte(32\'h9412, 8\'h00);\n'
    '      ddr_write_byte(32\'h9413, 8\'h00);\n'
    '\n'
    '      // Reset CPU and boot\n'
    '      rst_n = 1\'b0;\n'
    '      repeat(10) @(posedge clk);\n'
    '      rst_n = 1\'b1;\n'
    '\n'
    '      // Wait for DONE_MAGIC\n'
    '      begin : wait_stress\n'
    '        int mg_cnt;\n'
    '        mg_cnt = 0;\n'
    '        forever begin\n'
    '          @(posedge clk);\n'
    '          mg_cnt = mg_cnt + 1;\n'
    '          if (mg_cnt > 1_000_000) begin\n'
    '            $error("  [FAIL] Queue-stress TIMEOUT after %0d cycles", mg_cnt);\n'
    '            mg_errs = mg_errs + 1;\n'
    '            disable wait_stress;\n'
    '          end\n'
    '          begin\n'
    '            logic [7:0] b0, b1, b2, b3;\n'
    '            b0 = dut.u_ddr.mem[32\'h9410];\n'
    '            b1 = dut.u_ddr.mem[32\'h9411];\n'
    '            b2 = dut.u_ddr.mem[32\'h9412];\n'
    '            b3 = dut.u_ddr.mem[32\'h9413];\n'
    '            if ({b3, b2, b1, b0} == 32\'hDEADBEEF) begin\n'
    '              $display("  [PASS] Queue-stress: all 6 GEMMs completed in %0d cycles", mg_cnt);\n'
    '              disable wait_stress;\n'
    '            end\n'
    '          end\n'
    '        end\n'
    '      end\n'
    '\n'
    '      // Verify C[0][0] for all 6 GEMMs\n'
    '      begin\n'
    '        logic [7:0] c0, c1, c2, c3;\n'
    '@@C_CHECK_BLOCK@@\n'
    '      end\n'
    '      total_errs = total_errs + mg_errs;\n'
    '    end'
)

new_test = new_test.replace('@@FW_LAST@@', str(len(fw) - 1))
new_test = new_test.replace('@@FW_LEN@@', str(len(fw)))
new_test = new_test.replace('@@FW_BLOCK@@', fw_block)
new_test = new_test.replace('@@PRELOAD_BLOCK@@', preload_block)
new_test = new_test.replace('@@C_CHECK_BLOCK@@', c_check_block)

new_content = content[:idx_start] + '\n' + new_test + '\n\n' + content[idx_start:]
with open(TB_FILE, 'w') as f:
    f.write(new_content)

print(f'Inserted Test 5 before summary at char {idx_insert}')
print(f'New file: {len(new_content)} chars')
