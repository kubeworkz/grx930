#!/usr/bin/env python
"""Add Test 8: Dual-NPU mixed-precision test.

NPU0: FP16 3x3x4
  A = [[1.0, 0.5, 1.0], [2.0, 1.0, 0.5], [1.0, 1.0, 2.0]]
  B = [[1.0, 2.0, 0.5, 1.0], [0.5, 1.0, 1.0, 0.5], [1.0, 0.5, 2.0, 1.0]]
  C (FP32): [[2.25, 3.0, 3.0, 2.25], [3.0, 5.25, 3.0, 3.0], [3.5, 4.0, 5.5, 3.5]]

NPU1: INT8 2x5x4
  A = [[ 1,  2, -1,  3,  0], [ 2, -1,  1,  0,  3]]
  B = [[ 1,  0,  2,  1], [ 0,  1,  1,  0], [ 1,  1,  0,  2], [ 0,  2,  1,  1], [ 1,  0,  0,  1]]
  C (INT32): [[ 0,  7,  7,  2], [ 6,  0,  3,  7]]

Both NPUs execute simultaneously. All 20 C elements verified.
"""

import struct

TB_FILE = 'tb/tb_c930_soc_full.sv'

# --- FP16/FP32 helpers ---
def f16_to_hex(val):
    return struct.unpack('<H', struct.pack('<e', val))[0]

def f32_to_hex(val):
    return struct.unpack('<I', struct.pack('<f', val))[0]

def f16_bytes(val):
    h = f16_to_hex(val)
    return [h & 0xFF, (h >> 8) & 0xFF]

def f32_bytes(val):
    w = f32_to_hex(val)
    return [w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF]

def int8_byte(val):
    return val & 0xFF

# --- RISC-V encoders ---
def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0b0110111

def addi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0b0010011

def sw(rs2, rs1, imm12):
    imm = imm12 & 0xFFF
    return ((imm>>5)<<25) | (rs2<<20) | (rs1<<15) | (0b010<<12) | ((imm&0x1F)<<7) | 0b0100011

def lw(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0b0000011

def andi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0b0010011

def beq(rs1, rs2, imm13):
    imm = imm13 & 0x1FFF
    return (((imm>>12)&1)<<31) | (((imm>>5)&0x3F)<<25) | (rs2<<20) | (rs1<<15) | (0b000<<12) | (((imm>>1)&0xF)<<8) | (((imm>>11)&1)<<7) | 0b1100011

def jal(rd, imm21):
    imm = imm21 & 0x1FFFFF
    return (((imm>>20)&1)<<31) | (((imm>>1)&0x3FF)<<21) | (((imm>>11)&1)<<20) | (((imm>>12)&0xFF)<<12) | (rd<<7) | 0b1101111

x0=0; x2=2; x10=10; x11=11; x14=14; x15=15; x16=16

def load32(val, reg):
    lo12 = val & 0xFFF
    hi20 = (val - lo12 + 0x1000) >> 12 if lo12 >= 0x800 else val >> 12
    return [lui(reg, hi20), addi(reg, reg, lo12)]

# ============================================================================
# Data definitions
# ============================================================================

# NPU0: FP16 3x3x4
# PREC=2 (FP16)
NP0_M, NP0_N, NP0_K = 3, 4, 3
NP0_PREC = 2
NP0_A_BASE = 0x9000
NP0_B_BASE = 0x9020
NP0_C_BASE = 0x9040

NP0_A = [[1.0, 0.5, 1.0],
          [2.0, 1.0, 0.5],
          [1.0, 1.0, 2.0]]
NP0_B = [[1.0, 2.0, 0.5, 1.0],
          [0.5, 1.0, 1.0, 0.5],
          [1.0, 0.5, 2.0, 1.0]]

# NPU1: INT8 2x5x4
# PREC=0 (INT8)
NP1_M, NP1_N, NP1_K = 2, 4, 5
NP1_PREC = 0
NP1_A_BASE = 0x9100
NP1_B_BASE = 0x9120
NP1_C_BASE = 0x9140

NP1_A = [[ 1,  2, -1,  3,  0],
          [ 2, -1,  1,  0,  3]]
NP1_B = [[ 1,  0,  2,  1],
          [ 0,  1,  1,  0],
          [ 1,  1,  0,  2],
          [ 0,  2,  1,  1],
          [ 1,  0,  0,  1]]

# Compute expected C
NP0_C = [[sum(NP0_A[m][k]*NP0_B[k][n] for k in range(NP0_K)) for n in range(NP0_N)] for m in range(NP0_M)]
NP1_C = [[sum(NP1_A[m][k]*NP1_B[k][n] for k in range(NP1_K)) for n in range(NP1_N)] for m in range(NP1_M)]

print("NPU0 C (FP32):")
for m in range(NP0_M):
    for n in range(NP0_N):
        hex32 = f32_to_hex(NP0_C[m][n])
        print(f"  C[{m}][{n}] = {NP0_C[m][n]:.2f} -> 0x{hex32:08X}")

print("NPU1 C (INT32):")
for m in range(NP1_M):
    for n in range(NP1_N):
        print(f"  C[{m}][{n}] = {NP1_C[m][n]}")

# ============================================================================
# Firmware
# ============================================================================
fw = []

# x10 = NPU0 base, x14 = NPU1 base
fw += load32(0x40000000, x10)
fw += load32(0x40000040, x14)

# Configure NPU0: FP16 3x3x4 (PREC=2)
fw += [addi(x11,x0,NP0_M), sw(x11,x10,0x08)]   # DIM_M
fw += [addi(x11,x0,NP0_N), sw(x11,x10,0x0C)]   # DIM_N
fw += [addi(x11,x0,NP0_K), sw(x11,x10,0x10)]   # DIM_K
fw += load32(NP0_A_BASE, x11); fw += [sw(x11,x10,0x14)]
fw += load32(NP0_B_BASE, x11); fw += [sw(x11,x10,0x18)]
fw += load32(NP0_C_BASE, x11); fw += [sw(x11,x10,0x1C)]
fw += [addi(x11,x0,NP0_PREC), sw(x11,x10,0x20)]  # PREC=2 (FP16)
fw += [lw(x11,x10,0x20)]
fw += [addi(x11,x0,1), sw(x11,x10,0x00)]         # START

# Configure NPU1: INT8 2x5x4 (PREC=0)
fw += [addi(x11,x0,NP1_M), sw(x11,x14,0x08)]
fw += [addi(x11,x0,NP1_N), sw(x11,x14,0x0C)]
fw += [addi(x11,x0,NP1_K), sw(x11,x14,0x10)]
fw += load32(NP1_A_BASE, x11); fw += [sw(x11,x14,0x14)]
fw += load32(NP1_B_BASE, x11); fw += [sw(x11,x14,0x18)]
fw += load32(NP1_C_BASE, x11); fw += [sw(x11,x14,0x1C)]
fw += [addi(x11,x0,NP1_PREC), sw(x11,x14,0x20)]  # PREC=0 (INT8)
fw += [lw(x11,x14,0x20)]
fw += [addi(x11,x0,1), sw(x11,x14,0x00)]

# Poll NPU0 done
p0 = len(fw)
fw += [lw(x11,x10,0x04)]
fw += [andi(x11,x11,2)]
fw += [beq(x11,x0,(p0-len(fw))*4)]

# Poll NPU1 done
p1 = len(fw)
fw += [lw(x11,x14,0x04)]
fw += [andi(x11,x11,2)]
fw += [beq(x11,x0,(p1-len(fw))*4)]

# Write DONE_MAGIC
fw += load32(0x9410, x15)
fw += [lui(x16,0xDEADC), addi(x16,x16,0xEEF), sw(x16,x15,0)]
fw += [jal(x0,0)]

print(f"Firmware: {len(fw)} instructions ({len(fw)*4} bytes)")

# ============================================================================
# Build testbench patch
# ============================================================================

with open(TB_FILE, 'r') as f:
    content = f.read()

summary_marker = '    // Summary'
idx_insert = content.find(summary_marker)
if idx_insert == -1:
    print('ERROR: summary marker not found'); exit(1)

idx_start = content.rfind('\n', 0, idx_insert)

# Firmware lines
fw_lines = '\n'.join(f'        fw[{i:2d}] = 32\'h{inst:08X};' for i, inst in enumerate(fw))

# --- NPU0 A data preload (FP16, 3x3 = 9 elements = 18 bytes) ---
np0_a_lines = []
for m in range(NP0_M):
    for k in range(NP0_K):
        b0, b1 = f16_bytes(NP0_A[m][k])
        addr = NP0_A_BASE + (m * NP0_K + k) * 2
        np0_a_lines.append(f'        ddr_write_byte(32\'h{addr:04X}, 8\'h{b0:02X});  // A[{m}][{k}] low')
        np0_a_lines.append(f'        ddr_write_byte(32\'h{addr+1:04X}, 8\'h{b1:02X});  // A[{m}][{k}] high')

# --- NPU0 B data preload (FP16, 3x4 = 12 elements = 24 bytes) ---
np0_b_lines = []
for k in range(NP0_K):
    for n in range(NP0_N):
        b0, b1 = f16_bytes(NP0_B[k][n])
        addr = NP0_B_BASE + (k * NP0_N + n) * 2
        np0_b_lines.append(f'        ddr_write_byte(32\'h{addr:04X}, 8\'h{b0:02X});  // B[{k}][{n}] low')
        np0_b_lines.append(f'        ddr_write_byte(32\'h{addr+1:04X}, 8\'h{b1:02X});  // B[{k}][{n}] high')

# --- NPU1 A data preload (INT8, 2x5 = 10 bytes) ---
np1_a_lines = []
for m in range(NP1_M):
    for k in range(NP1_K):
        b = int8_byte(NP1_A[m][k])
        addr = NP1_A_BASE + m * NP1_K + k
        np1_a_lines.append(f'        ddr_write_byte(32\'h{addr:04X}, 8\'h{b:02X});  // A[{m}][{k}] = {NP1_A[m][k]}')

# --- NPU1 B data preload (INT8, 5x4 = 20 bytes) ---
np1_b_lines = []
for k in range(NP1_K):
    for n in range(NP1_N):
        b = int8_byte(NP1_B[k][n])
        addr = NP1_B_BASE + k * NP1_N + n
        np1_b_lines.append(f'        ddr_write_byte(32\'h{addr:04X}, 8\'h{b:02X});  // B[{k}][{n}] = {NP1_B[k][n]}')

# --- NPU0 C verification (FP32, 3x4 = 12 elements) ---
np0_verify_lines = []
for m in range(NP0_M):
    for n in range(NP0_N):
        addr = NP0_C_BASE + (m * NP0_N + n) * 4
        hex32 = f32_to_hex(NP0_C[m][n])
        np0_verify_lines.append(f"""      // NPU0 C[{m}][{n}] = {NP0_C[m][n]:.2f}
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h{addr:04X}]; c1 = dut.u_ddr.mem[32'h{addr+1:04X}];
        c2 = dut.u_ddr.mem[32'h{addr+2:04X}]; c3 = dut.u_ddr.mem[32'h{addr+3:04X}];
        if ({{c3, c2, c1, c0}} !== 32'h{hex32:08X}) begin
          $error("  [FAIL] NPU0 C[{m}][{n}] = 0x%08h (expect 0x{hex32:08X})", {{c3, c2, c1, c0}});
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[{m}][{n}] = 0x%08h (expect {NP0_C[m][n]:.2f})", {{c3, c2, c1, c0}});
        end
      end""")
np0_verify_block = '\n'.join(np0_verify_lines)

# --- NPU1 C verification (INT32, 2x4 = 8 elements) ---
np1_verify_lines = []
for m in range(NP1_M):
    for n in range(NP1_N):
        addr = NP1_C_BASE + (m * NP1_N + n) * 4
        exp = NP1_C[m][n]
        exp_hex = exp & 0xFFFFFFFF
        np1_verify_lines.append(f"""      // NPU1 C[{m}][{n}] = {exp}
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h{addr:04X}]; c1 = dut.u_ddr.mem[32'h{addr+1:04X}];
        c2 = dut.u_ddr.mem[32'h{addr+2:04X}]; c3 = dut.u_ddr.mem[32'h{addr+3:04X}];
        if ({{c3, c2, c1, c0}} !== 32'h{exp_hex:08X}) begin
          $error("  [FAIL] NPU1 C[{m}][{n}] = %0d (expect {exp})", $signed({{c3, c2, c1, c0}}));
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[{m}][{n}] = %0d OK", $signed({{c3, c2, c1, c0}}));
        end
      end""")
np1_verify_block = '\n'.join(np1_verify_lines)

new_test = f"""    // =========================================================================
    // Test 8: Dual-NPU mixed-precision (FP16 + INT8)
    //
    // NPU0: FP16 3x3x4 — values {1.0, 0.5, 2.0}
    //   A = [[1.0, 0.5, 1.0], [2.0, 1.0, 0.5], [1.0, 1.0, 2.0]]
    //   B = [[1.0, 2.0, 0.5, 1.0], [0.5, 1.0, 1.0, 0.5], [1.0, 0.5, 2.0, 1.0]]
    //   C (FP32) = [[2.25, 3.0, 3.0, 2.25], [3.0, 5.25, 3.0, 3.0], [3.5, 4.0, 5.5, 3.5]]
    //
    // NPU1: INT8 2x5x4 — includes negative weights
    //   A = [[ 1,  2, -1,  3,  0], [ 2, -1,  1,  0,  3]]
    //   B = [[ 1,  0,  2,  1], [ 0,  1,  1,  0], [ 1,  1,  0,  2], [ 0,  2,  1,  1], [ 1,  0,  0,  1]]
    //   C (INT32) = [[ 0,  7,  7,  2], [ 6,  0,  3,  7]]
    //
    // Both NPUs execute simultaneously with different precisions.
    // NPU0 uses FP16->FP32 accumulate, NPU1 uses INT8->INT32 accumulate.
    // =========================================================================
    $display("\\n========================================");
    $display("  TEST 8: Dual-NPU mixed-precision (FP16 3x3x4 + INT8 2x5x4)");
    $display("========================================");
    begin
      int mg_errs;
      mg_errs = 0;

      // Reload NPU firmware
      begin
        int fw_fd; logic [7:0] fw_byte; int fw_addr;
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
        end
      end

      // Load firmware
      begin
        logic [31:0] fw [0:{len(fw)-1}];
{fw_lines}

        for (int i = 0; i < {len(fw)}; i++) begin
          ddr_write_byte(i*4 + 0, fw[i][7:0]);
          ddr_write_byte(i*4 + 1, fw[i][15:8]);
          ddr_write_byte(i*4 + 2, fw[i][23:16]);
          ddr_write_byte(i*4 + 3, fw[i][31:24]);
        end
      end

      // Preload NPU0 A (FP16 3x3 = 18 bytes)
{chr(10).join(np0_a_lines)}
      // Preload NPU0 B (FP16 3x4 = 24 bytes)
{chr(10).join(np0_b_lines)}

      // Preload NPU1 A (INT8 2x5 = 10 bytes)
{chr(10).join(np1_a_lines)}
      // Preload NPU1 B (INT8 5x4 = 20 bytes)
{chr(10).join(np1_b_lines)}

      // Clear DONE_ADDR
      ddr_write_byte(32'h9410, 8'h00);
      ddr_write_byte(32'h9411, 8'h00);
      ddr_write_byte(32'h9412, 8'h00);
      ddr_write_byte(32'h9413, 8'h00);

      // Reset CPU and boot
      rst_n = 1'b0;
      repeat(10) @(posedge clk);
      rst_n = 1'b1;

      // Wait for DONE_MAGIC
      begin : wait_dual
        int mg_cnt;
        mg_cnt = 0;
        forever begin
          @(posedge clk);
          mg_cnt = mg_cnt + 1;
          if (mg_cnt > 500_000) begin
            $error("  [FAIL] Dual-NPU TIMEOUT");
            mg_errs = mg_errs + 1;
            disable wait_dual;
          end
          begin
            logic [7:0] b0, b1, b2, b3;
            b0 = dut.u_ddr.mem[32'h9410];
            b1 = dut.u_ddr.mem[32'h9411];
            b2 = dut.u_ddr.mem[32'h9412];
            b3 = dut.u_ddr.mem[32'h9413];
            if ({{b3, b2, b1, b0}} == 32'hDEADBEEF) begin
              $display("  [PASS] Dual-NPU mixed-precision: both completed in %0d cycles", mg_cnt);
              disable wait_dual;
            end
          end
        end
      end

      // Verify NPU0 result: FP16 3x3x4 -> FP32 C
      $display("  [TB] Verifying NPU0 (FP16 3x3x4) C matrix...");
{np0_verify_block}

      // Verify NPU1 result: INT8 2x5x4 -> INT32 C
      $display("  [TB] Verifying NPU1 (INT8 2x5x4) C matrix...");
{np1_verify_block}

      total_errs = total_errs + mg_errs;
    end"""

new_content = content[:idx_start] + '\n' + new_test + '\n\n' + content[idx_start:]
with open(TB_FILE, 'w') as f:
    f.write(new_content)

total_c = NP0_M * NP0_N + NP1_M * NP1_N
print(f'Inserted Test 8 ({len(fw)} fw insns, {total_c} C elements, FP16+INT8)')
