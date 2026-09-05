#!/usr/bin/env python
"""Add Test 7: Dual-NPU non-trivial data test.

NPU0: 3x4x2 INT8 with specific weights/activations
  A = [[ 1, -2], [ 3,  1], [-1,  2]]
  B = [[ 2, -1,  1,  3], [ 1,  2, -1,  0]]
  C = [[ 0, -5,  3,  3], [ 7, -1,  2,  9], [ 0,  5, -3, -3]]

NPU1: 2x2x3 INT8 convolution kernel
  A = [[1, 2, 3], [4, 5, 6]]
  B = [[1, 0], [0, 1], [1, 1]]  (3ch depthwise-separable conv)
  C = [[ 4,  5], [10, 11]]

Both NPUs execute simultaneously, all 16 C elements verified.
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

def jal(rd, imm21):
    imm = imm21 & 0x1FFFFF
    return (((imm>>20)&1)<<31) | (((imm>>1)&0x3FF)<<21) | (((imm>>11)&1)<<20) | (((imm>>12)&0xFF)<<12) | (rd<<7) | 0b1101111

x0=0; x2=2; x3=3; x10=10; x11=11; x14=14; x15=15; x16=16

def load32(val, reg):
    lo12 = val & 0xFFF
    hi20 = (val - lo12 + 0x1000) >> 12 if lo12 >= 0x800 else val >> 12
    return [lui(reg, hi20), addi(reg, reg, lo12)]

def int8_2complement(val):
    """Return unsigned byte representation of a signed int8 value."""
    return val & 0xFF

# ============================================================================
# Data layout (all INT8, row-major)
# ============================================================================
# NPU0: M=3, N=4, K=2
#   A[3x2] @ 0x8800 (6 bytes)
#   B[2x4] @ 0x8820 (8 bytes)
#   C[3x4] @ 0x8840 (12 x 4 bytes = 48 bytes)
NP0_M, NP0_N, NP0_K = 3, 4, 2
NP0_A_BASE = 0x8800
NP0_B_BASE = 0x8820
NP0_C_BASE = 0x8840

# A: [[ 1, -2], [ 3,  1], [-1,  2]]
NP0_A = [[1, -2], [3, 1], [-1, 2]]
# B: [[ 2, -1,  1,  3], [ 1,  2, -1,  0]]
NP0_B = [[2, -1, 1, 3], [1, 2, -1, 0]]

# NPU1: M=2, N=2, K=3
#   A[2x3] @ 0x8900 (6 bytes)
#   B[3x2] @ 0x8920 (6 bytes)
#   C[2x2] @ 0x8940 (4 x 4 bytes = 16 bytes)
NP1_M, NP1_N, NP1_K = 2, 2, 3
NP1_A_BASE = 0x8900
NP1_B_BASE = 0x8920
NP1_C_BASE = 0x8940

# A: [[1, 2, 3], [4, 5, 6]]
NP1_A = [[1, 2, 3], [4, 5, 6]]
# B: [[1, 0], [0, 1], [1, 1]]  (conv kernel)
NP1_B = [[1, 0], [0, 1], [1, 1]]

# Compute expected C
NP0_C = [[sum(NP0_A[m][k] * NP0_B[k][n] for k in range(NP0_K)) for n in range(NP0_N)] for m in range(NP0_M)]
NP1_C = [[sum(NP1_A[m][k] * NP1_B[k][n] for k in range(NP1_K)) for n in range(NP1_N)] for m in range(NP1_M)]

print("NPU0 C:")
for m in range(NP0_M):
    for n in range(NP0_N):
        print(f"  C[{m}][{n}] = {NP0_C[m][n]}")
print("NPU1 C:")
for m in range(NP1_M):
    for n in range(NP1_N):
        print(f"  C[{m}][{n}] = {NP1_C[m][n]}")

# ============================================================================
# Firmware: configure both NPUs, poll, write DONE_MAGIC
# ============================================================================
fw = []

# x10 = NPU0 base, x14 = NPU1 base
fw += load32(0x40000000, x10)
fw += load32(0x40000040, x14)

# Configure NPU0: 3x4x2 INT8
fw += [addi(x11,x0,NP0_M), sw(x11,x10,0x08)]   # DIM_M
fw += [addi(x11,x0,NP0_N), sw(x11,x10,0x0C)]   # DIM_N
fw += [addi(x11,x0,NP0_K), sw(x11,x10,0x10)]   # DIM_K
fw += load32(NP0_A_BASE, x11); fw += [sw(x11,x10,0x14)]  # A_BASE
fw += load32(NP0_B_BASE, x11); fw += [sw(x11,x10,0x18)]  # B_BASE
fw += load32(NP0_C_BASE, x11); fw += [sw(x11,x10,0x1C)]  # C_BASE
fw += [addi(x11,x0,0), sw(x11,x10,0x20)]        # PREC=0 (INT8)
fw += [lw(x11,x10,0x20)]                          # flush
fw += [addi(x11,x0,1), sw(x11,x10,0x00)]         # START

# Configure NPU1: 2x2x3 INT8
fw += [addi(x11,x0,NP1_M), sw(x11,x14,0x08)]   # DIM_M
fw += [addi(x11,x0,NP1_N), sw(x11,x14,0x0C)]   # DIM_N
fw += [addi(x11,x0,NP1_K), sw(x11,x14,0x10)]   # DIM_K
fw += load32(NP1_A_BASE, x11); fw += [sw(x11,x14,0x14)]  # A_BASE
fw += load32(NP1_B_BASE, x11); fw += [sw(x11,x14,0x18)]  # B_BASE
fw += load32(NP1_C_BASE, x11); fw += [sw(x11,x14,0x1C)]  # C_BASE
fw += [addi(x11,x0,0), sw(x11,x14,0x20)]        # PREC=0 (INT8)
fw += [lw(x11,x14,0x20)]                          # flush
fw += [addi(x11,x0,1), sw(x11,x14,0x00)]         # START

# Poll NPU0 done (STATUS & 2)
p0 = len(fw)
fw += [lw(x11,x10,0x04)]
fw += [andi(x11,x11,2)]
fw += [beq(x11,x0,(p0-len(fw))*4)]

# Poll NPU1 done
p1 = len(fw)
fw += [lw(x11,x14,0x04)]
fw += [andi(x11,x11,2)]
fw += [beq(x11,x0,(p1-len(fw))*4)]

# Write DONE_MAGIC to DDR[0x9410]
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

# Build firmware lines for testbench
fw_lines = '\n'.join(f'        fw[{i:2d}] = 32\'h{inst:08X};' for i, inst in enumerate(fw))

# Build A/B data preload lines for NPU0
np0_a_bytes = []
for m in range(NP0_M):
    for k in range(NP0_K):
        np0_a_bytes.append(int8_2complement(NP0_A[m][k]))

np0_b_bytes = []
for k in range(NP0_K):
    for n in range(NP0_N):
        np0_b_bytes.append(int8_2complement(NP0_B[k][n]))

np0_a_lines = '\n'.join(
    f'        ddr_write_byte(32\'h{NP0_A_BASE+i:04X}, 8\'h{b:02X});  // A[{i//NP0_K}][{i%NP0_K}] = {NP0_A[i//NP0_K][i%NP0_K]}'
    for i, b in enumerate(np0_a_bytes))
np0_b_lines = '\n'.join(
    f'        ddr_write_byte(32\'h{NP0_B_BASE+i:04X}, 8\'h{b:02X});  // B[{i//NP0_N}][{i%NP0_N}] = {NP0_B[i//NP0_N][i%NP0_N]}'
    for i, b in enumerate(np0_b_bytes))

# Build A/B data preload lines for NPU1
np1_a_bytes = []
for m in range(NP1_M):
    for k in range(NP1_K):
        np1_a_bytes.append(int8_2complement(NP1_A[m][k]))

np1_b_bytes = []
for k in range(NP1_K):
    for n in range(NP1_N):
        np1_b_bytes.append(int8_2complement(NP1_B[k][n]))

np1_a_lines = '\n'.join(
    f'        ddr_write_byte(32\'h{NP1_A_BASE+i:04X}, 8\'h{b:02X});  // A[{i//NP1_K}][{i%NP1_K}] = {NP1_A[i//NP1_K][i%NP1_K]}'
    for i, b in enumerate(np1_a_bytes))
np1_b_lines = '\n'.join(
    f'        ddr_write_byte(32\'h{NP1_B_BASE+i:04X}, 8\'h{b:02X});  // B[{i//NP1_N}][{i%NP1_N}] = {NP1_B[i//NP1_N][i%NP1_N]}'
    for i, b in enumerate(np1_b_bytes))

# Build NPU0 C verification block
np0_verify_lines = []
for m in range(NP0_M):
    for n in range(NP0_N):
        addr = NP0_C_BASE + (m * NP0_N + n) * 4
        exp = NP0_C[m][n]
        np0_verify_lines.append(f"""      // NPU0 C[{m}][{n}] = {exp}
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h{addr:04X}]; c1 = dut.u_ddr.mem[32'h{addr+1:04X}];
        c2 = dut.u_ddr.mem[32'h{addr+2:04X}]; c3 = dut.u_ddr.mem[32'h{addr+3:04X}];
        if ({{c3, c2, c1, c0}} !== 32'h{exp & 0xFFFFFFFF:08X}) begin
          $error("  [FAIL] NPU0 C[{m}][{n}] = %0d (expect {exp})", $signed({{c3, c2, c1, c0}}));
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU0 C[{m}][{n}] = %0d OK", $signed({{c3, c2, c1, c0}}));
        end
      end""")
np0_verify_block = '\n'.join(np0_verify_lines)

# Build NPU1 C verification block
np1_verify_lines = []
for m in range(NP1_M):
    for n in range(NP1_N):
        addr = NP1_C_BASE + (m * NP1_N + n) * 4
        exp = NP1_C[m][n]
        np1_verify_lines.append(f"""      // NPU1 C[{m}][{n}] = {exp}
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h{addr:04X}]; c1 = dut.u_ddr.mem[32'h{addr+1:04X}];
        c2 = dut.u_ddr.mem[32'h{addr+2:04X}]; c3 = dut.u_ddr.mem[32'h{addr+3:04X}];
        if ({{c3, c2, c1, c0}} !== 32'h{exp & 0xFFFFFFFF:08X}) begin
          $error("  [FAIL] NPU1 C[{m}][{n}] = %0d (expect {exp})", $signed({{c3, c2, c1, c0}}));
          mg_errs = mg_errs + 1;
        end else begin
          $display("  [TB] NPU1 C[{m}][{n}] = %0d OK", $signed({{c3, c2, c1, c0}}));
        end
      end""")
np1_verify_block = '\n'.join(np1_verify_lines)

new_test = f"""    // =========================================================================
    // Test 7: Dual-NPU non-trivial data test
    //
    // NPU0: 3x4x2 INT8 with signed weights/activations
    //   A = [[ 1, -2], [ 3,  1], [-1,  2]]
    //   B = [[ 2, -1,  1,  3], [ 1,  2, -1,  0]]
    //   C = [[ 0, -5,  3,  3], [ 7, -1,  2,  9], [ 0,  5, -3, -3]]
    //
    // NPU1: 2x2x3 INT8 convolution kernel
    //   A = [[1, 2, 3], [4, 5, 6]]
    //   B = [[1, 0], [0, 1], [1, 1]]
    //   C = [[ 4,  5], [10, 11]]
    //
    // Both NPUs execute simultaneously. All 16 C elements verified.
    // Includes negative values to exercise signed INT8 multiply-accumulate.
    // =========================================================================
    $display("\\n========================================");
    $display("  TEST 7: Dual-NPU non-trivial data (3x4x2 + 2x2x3)");
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

      // Preload NPU0 A: 3x2 = 6 bytes (signed INT8)
{np0_a_lines}
      // Preload NPU0 B: 2x4 = 8 bytes (signed INT8)
{np0_b_lines}

      // Preload NPU1 A: 2x3 = 6 bytes (signed INT8)
{np1_a_lines}
      // Preload NPU1 B: 3x2 = 6 bytes (signed INT8)
{np1_b_lines}

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

      // Verify NPU0 result: 3x4x2 with signed weights
      $display("  [TB] Verifying NPU0 (3x4x2) C matrix (signed INT8)...");
{np0_verify_block}

      // Verify NPU1 result: 2x2x3 convolution kernel
      $display("  [TB] Verifying NPU1 (2x2x3) C matrix (conv kernel)...");
{np1_verify_block}

      total_errs = total_errs + mg_errs;
    end"""

new_content = content[:idx_start] + '\n' + new_test + '\n\n' + content[idx_start:]
with open(TB_FILE, 'w') as f:
    f.write(new_content)

total_c = NP0_M * NP0_N + NP1_M * NP1_N
print(f'Inserted Test 7 ({len(fw)} fw insns, {total_c} C elements, signed INT8)')
