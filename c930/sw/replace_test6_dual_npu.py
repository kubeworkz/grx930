#!/usr/bin/env python
"""Add Test 6: Dual-NPU simultaneous GEMM test.

Runs independent GEMMs on NPU0 (CSR at 0x4000_0000) and NPU1 (CSR at 0x4000_0040)
simultaneously. Both NPUs share DDR through the DMA arbiter.

NPU0: 2x2x2 INT8 all 1s -> C[0][0] = 2
NPU1: 2x2x2 INT8 all 1s -> C[0][0] = 2
"""

TB_FILE = 'tb/tb_c930_soc_full.sv'

# RISC-V encoders
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

x0=0; x10=10; x11=11; x14=14; x15=15; x16=16

def load32(val, reg):
    lo12 = val & 0xFFF
    hi20 = (val - lo12 + 0x1000) >> 12 if lo12 >= 0x800 else val >> 12
    return [lui(reg, hi20), addi(reg, reg, lo12)]

fw = []

# Setup: x10 = NPU0 base, x14 = NPU1 base
fw += load32(0x40000000, x10)
fw += load32(0x40000040, x14)

# Configure NPU0: 2x2x2 INT8
# DIM_M=2, DIM_N=2, DIM_K=2, A@0x8000, B@0x8080, C@0x8100, PREC=0
fw += [addi(x11,x0,2), sw(x11,x10,0x08)]
fw += [addi(x11,x0,2), sw(x11,x10,0x0C)]
fw += [addi(x11,x0,2), sw(x11,x10,0x10)]
fw += load32(0x8000, x11); fw += [sw(x11,x10,0x14)]
fw += load32(0x8080, x11); fw += [sw(x11,x10,0x18)]
fw += load32(0x8100, x11); fw += [sw(x11,x10,0x1C)]
fw += [addi(x11,x0,0), sw(x11,x10,0x20)]
fw += [lw(x11,x10,0x20)]
fw += [addi(x11,x0,1), sw(x11,x10,0x00)]

# Configure NPU1: 2x2x2 INT8
# DIM_M=2, DIM_N=2, DIM_K=2, A@0x8200, B@0x8280, C@0x8300, PREC=0
fw += [addi(x11,x0,2), sw(x11,x14,0x08)]
fw += [addi(x11,x0,2), sw(x11,x14,0x0C)]
fw += [addi(x11,x0,2), sw(x11,x14,0x10)]
fw += load32(0x8200, x11); fw += [sw(x11,x14,0x14)]
fw += load32(0x8280, x11); fw += [sw(x11,x14,0x18)]
fw += load32(0x8300, x11); fw += [sw(x11,x14,0x1C)]
fw += [addi(x11,x0,0), sw(x11,x14,0x20)]
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
fw += [lui(x16,0xDEADC), addi(x16,x16,0xEEF), sw(x16,x15,0)]  # 0xDEADC000 + (-273) = 0xDEADBEEF
fw += [jal(x0,0)]

print(f"Firmware: {len(fw)} instructions")

# Read and patch testbench
with open(TB_FILE, 'r') as f:
    content = f.read()

summary_marker = '    // Summary'
idx_insert = content.find(summary_marker)
if idx_insert == -1:
    print('ERROR: summary marker not found'); exit(1)

# Find blank line before summary
idx_start = content.rfind('\n', 0, idx_insert)

# Build firmware lines
fw_lines = '\n'.join(f'        fw[{i:2d}] = 32\'h{inst:08X};' for i, inst in enumerate(fw))

new_test = f"""    // =========================================================================
    // Test 6: Dual-NPU simultaneous GEMM
    //
    // Runs independent GEMMs on NPU0 (CSR at 0x4000_0000) and NPU1
    // (CSR at 0x4000_0040) simultaneously. Both share DDR through the
    // DMA arbiter, testing concurrent DMA arbitration.
    //
    //   NPU0: 2x2x2 INT8 all 1s -> C[0][0] = 2
    //   NPU1: 2x2x2 INT8 all 1s -> C[0][0] = 2
    // =========================================================================
    $display("\\n========================================");
    $display("  TEST 6: Dual-NPU simultaneous GEMM");
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

      // Preload A/B for NPU0: 2x2x2 all 1s
      begin
        for (int i = 0; i < 4; i++) ddr_write_byte(32'h8000 + i, 8'd1);
        for (int i = 0; i < 4; i++) ddr_write_byte(32'h8080 + i, 8'd1);
      end
      // Preload A/B for NPU1: 2x2x2 all 1s
      begin
        for (int i = 0; i < 4; i++) ddr_write_byte(32'h8200 + i, 8'd1);
        for (int i = 0; i < 4; i++) ddr_write_byte(32'h8280 + i, 8'd1);
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

      // Verify NPU0 result
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8100]; c1 = dut.u_ddr.mem[32'h8101];
        c2 = dut.u_ddr.mem[32'h8102]; c3 = dut.u_ddr.mem[32'h8103];
        $display("  [TB] NPU0 (2x2x2) C[0][0] = 0x%08h (expect 0x00000002)", {{c3, c2, c1, c0}});
        if ({{c3, c2, c1, c0}} != 32'd2) begin
          $error("  [FAIL] NPU0 C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
      end
      // Verify NPU1 result
      begin
        logic [7:0] c0, c1, c2, c3;
        c0 = dut.u_ddr.mem[32'h8300]; c1 = dut.u_ddr.mem[32'h8301];
        c2 = dut.u_ddr.mem[32'h8302]; c3 = dut.u_ddr.mem[32'h8303];
        $display("  [TB] NPU1 (2x2x2) C[0][0] = 0x%08h (expect 0x00000002)", {{c3, c2, c1, c0}});
        if ({{c3, c2, c1, c0}} != 32'd2) begin
          $error("  [FAIL] NPU1 C[0][0] wrong"); mg_errs = mg_errs + 1;
        end
      end
      total_errs = total_errs + mg_errs;
    end"""

new_content = content[:idx_start] + '\n' + new_test + '\n\n' + content[idx_start:]
with open(TB_FILE, 'w') as f:
    f.write(new_content)

print(f'Inserted Test 6 before summary')
