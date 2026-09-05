#!/usr/bin/env python
"""Add Test 6: Dual-NPU different-shape stress test.

NPU0: 4x4x4 INT8 all 1s -> C[m][n] = 4 for all elements (16 elements)
NPU1: 2x3x2 INT8 all 1s -> C[m][n] = 2 for all elements (6 elements)
Both NPUs share DDR through the DMA arbiter, testing concurrent DMA
arbitration with asymmetric shapes.
"""

TB_FILE = 'tb/tb_c930_soc_full.sv'

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

def bne(rs1, rs2, imm13):
    imm = imm13 & 0x1FFF
    return (((imm>>12)&1)<<31) | (((imm>>5)&0x3F)<<25) | (rs2<<20) | (rs1<<15) | (0b001<<12) | (((imm>>1)&0xF)<<8) | (((imm>>11)&1)<<7) | 0b1100011

def jal(rd, imm21):
    imm = imm21 & 0x1FFFFF
    return (((imm>>20)&1)<<31) | (((imm>>1)&0x3FF)<<21) | (((imm>>11)&1)<<20) | (((imm>>12)&0xFF)<<12) | (rd<<7) | 0b1101111

def add(rd, rs1, rs2):
    return (0b0000000<<25) | (rs2<<20) | (rs1<<15) | (0b000<<12) | (rd<<7) | 0b0110011

def slli(rd, rs1, shamt):
    return (0b0000000<<25) | ((shamt&0x1F)<<20) | (rs1<<15) | (0b001<<12) | (rd<<7) | 0b0010011

x0=0; x1=1; x2=2; x10=10; x11=11; x12=12; x13=13; x14=14; x15=15; x16=16

def load32(val, reg):
    lo12 = val & 0xFFF
    hi20 = (val - lo12 + 0x1000) >> 12 if lo12 >= 0x800 else val >> 12
    return [lui(reg, hi20), addi(reg, reg, lo12)]

# ============================================================================
# Firmware generation
# ============================================================================
fw = []

# Setup: x10 = NPU0 base, x14 = NPU1 base
fw += load32(0x40000000, x10)
fw += load32(0x40000040, x14)

# Configure NPU0: 4x4x4 INT8
# DIM_M=4, DIM_N=4, DIM_K=4, A@0x8000, B@0x8020, C@0x8040, PREC=0
fw += [addi(x11,x0,4), sw(x11,x10,0x08)]   # DIM_M=4
fw += [addi(x11,x0,4), sw(x11,x10,0x0C)]   # DIM_N=4
fw += [addi(x11,x0,4), sw(x11,x10,0x10)]   # DIM_K=4
fw += load32(0x8000, x11); fw += [sw(x11,x10,0x14)]   # A_BASE
fw += load32(0x8020, x11); fw += [sw(x11,x10,0x18)]   # B_BASE
fw += load32(0x8040, x11); fw += [sw(x11,x10,0x1C)]   # C_BASE
fw += [addi(x11,x0,0), sw(x11,x10,0x20)]   # PREC=0 (INT8)
fw += [lw(x11,x10,0x20)]                     # flush pipeline
fw += [addi(x11,x0,1), sw(x11,x10,0x00)]    # START

# Configure NPU1: 2x3x2 INT8
# DIM_M=2, DIM_N=3, DIM_K=2, A@0x8100, B@0x8120, C@0x8140, PREC=0
fw += [addi(x11,x0,2), sw(x11,x14,0x08)]   # DIM_M=2
fw += [addi(x11,x0,3), sw(x11,x14,0x0C)]   # DIM_N=3
fw += [addi(x11,x0,2), sw(x11,x14,0x10)]   # DIM_K=2
fw += load32(0x8100, x11); fw += [sw(x11,x14,0x14)]   # A_BASE
fw += load32(0x8120, x11); fw += [sw(x11,x14,0x18)]   # B_BASE
fw += load32(0x8140, x11); fw += [sw(x11,x14,0x1C)]   # C_BASE
fw += [addi(x11,x0,0), sw(x11,x14,0x20)]   # PREC=0 (INT8)
fw += [lw(x11,x14,0x20)]                     # flush pipeline
fw += [addi(x11,x0,1), sw(x11,x14,0x00)]    # START

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

print(f"Firmware: {len(fw)} instructions")

# ============================================================================
# Expected results
# ============================================================================

# NPU0: 4x4x4, A=all 1s, B=all 1s, K=4
# C[m][n] = sum(A[m][k]*B[k][n] for k in 0..3) = sum(1*1)*4 = 4
np0_m, np0_n, np0_k = 4, 4, 4
np0_c_base = 0x8040
np0_expected = {}
for m in range(np0_m):
    for n in range(np0_n):
        val = np0_k  # all-ones dot product of length K
        np0_expected[(m, n)] = val
        print(f"  NPU0 C[{m}][{n}] = {val}")

# NPU1: 2x3x2, A=all 1s, B=all 1s, K=2
# C[m][n] = sum(A[m][k]*B[k][n] for k in 0..1) = sum(1*1)*2 = 2
np1_m, np1_n, np1_k = 2, 3, 2
np1_c_base = 0x8140
np1_expected = {}
for m in range(np1_m):
    for n in range(np1_n):
        val = np1_k  # all-ones dot product of length K
        np1_expected[(m, n)] = val
        print(f"  NPU1 C[{m}][{n}] = {val}")

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

# Build firmware lines
fw_lines = '\n'.join(f'        fw[{i:2d}] = 32\'h{inst:08X};' for i, inst in enumerate(fw))

# Build NPU0 verification block (4x4 = 16 elements)
np0_verify_lines = []
for m in range(np0_m):
    for n in range(np0_n):
        addr = np0_c_base + (m * np0_n + n) * 4
        exp = np0_expected[(m, n)]
        np0_verify_lines.append(f"""      // NPU0 C[{m}][{n}]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h{addr:04X}]; c1 = dut.u_ddr.mem[32'h{addr+1:04X}];
        c2 = dut.u_ddr.mem[32'h{addr+2:04X}]; c3 = dut.u_ddr.mem[32'h{addr+3:04X}];
        if ({{c3, c2, c1, c0}} !== 32'd{exp}) begin
          $error("  [FAIL] NPU0 C[{m}][{n}] = 0x%08h (expect 0x%08h)", {{c3, c2, c1, c0}}, 32'd{exp});
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[{m}][{n}] = %0d OK", $signed({{c3, c2, c1, c0}}));
        end
      end""")
np0_verify_block = '\n'.join(np0_verify_lines)

# Build NPU1 verification block (2x3 = 6 elements)
np1_verify_lines = []
for m in range(np1_m):
    for n in range(np1_n):
        addr = np1_c_base + (m * np1_n + n) * 4
        exp = np1_expected[(m, n)]
        np1_verify_lines.append(f"""      // NPU1 C[{m}][{n}]
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h{addr:04X}]; c1 = dut.u_ddr.mem[32'h{addr+1:04X}];
        c2 = dut.u_ddr.mem[32'h{addr+2:04X}]; c3 = dut.u_ddr.mem[32'h{addr+3:04X}];
        if ({{c3, c2, c1, c0}} !== 32'd{exp}) begin
          $error("  [FAIL] NPU1 C[{m}][{n}] = 0x%08h (expect 0x%08h)", {{c3, c2, c1, c0}}, 32'd{exp});
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[{m}][{n}] = %0d OK", $signed({{c3, c2, c1, c0}}));
        end
      end""")
np1_verify_block = '\n'.join(np1_verify_lines)

new_test = f"""    // =========================================================================
    // Test 6: Dual-NPU different-shape stress test
    //
    // Runs independent GEMMs on NPU0 (CSR at 0x4000_0000) and NPU1
    // (CSR at 0x4000_0040) simultaneously with different shapes.
    // Both share DDR through the DMA arbiter, testing concurrent DMA
    // arbitration with asymmetric operand sizes.
    //
    //   NPU0: 4x4x4 INT8 all 1s -> C[m][n] = 4 (16 elements verified)
    //   NPU1: 2x3x2 INT8 all 1s -> C[m][n] = 2 (6 elements verified)
    // =========================================================================
    $display("\\n========================================");
    $display("  TEST 6: Dual-NPU different shapes (4x4x4 + 2x3x2)");
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

      // Load dual-NPU firmware
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

      // Preload A for NPU0: 4x4 = 16 bytes, all 1s
      begin
        for (int i = 0; i < 16; i++) ddr_write_byte(32'h8000 + i, 8'd1);
      end
      // Preload B for NPU0: 4x4 = 16 bytes, all 1s
      begin
        for (int i = 0; i < 16; i++) ddr_write_byte(32'h8020 + i, 8'd1);
      end
      // Preload A for NPU1: 2x2 = 4 bytes, all 1s
      begin
        for (int i = 0; i < 4; i++) ddr_write_byte(32'h8100 + i, 8'd1);
      end
      // Preload B for NPU1: 2x3 = 6 bytes, all 1s
      begin
        for (int i = 0; i < 6; i++) ddr_write_byte(32'h8120 + i, 8'd1);
      end

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
              $display("  [PASS] Dual-NPU: both GEMMs completed in %0d cycles", mg_cnt);
              disable wait_dual;
            end
          end
        end
      end

      // Verify NPU0 result: 4x4x4 -> all C = 4
      $display("  [TB] Verifying NPU0 (4x4x4) C matrix...");
{np0_verify_block}

      // Verify NPU1 result: 2x3x2 -> all C = 2
      $display("  [TB] Verifying NPU1 (2x3x2) C matrix...");
{np1_verify_block}

      total_errs = total_errs + mg_errs;
    end"""

new_content = content[:idx_start] + '\n' + new_test + '\n\n' + content[idx_start:]
with open(TB_FILE, 'w') as f:
    f.write(new_content)

print(f'Inserted Test 6 before summary ({len(fw)} fw insns, {np0_m*np0_n} + {np1_m*np1_n} = {np0_m*np0_n + np1_m*np1_n} C elements verified)')
