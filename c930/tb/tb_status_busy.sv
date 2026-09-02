// tb_status_busy.sv — Prove RTL drives STATUS.BUSY
//
// Boots the C930 SoC, loads the NPU test firmware, and monitors
// the CSR block's i_busy signal during the first GEMM execution.
// Uses the same structure as tb_c930_soc.sv but with busy probing.

`timescale 1ns/1ps

module tb_status_busy;

  logic clk, rst_n;
  initial clk = 0;
  always #10 clk = ~clk;

  logic npu_busy_out, npu_done_out, npu_error_out, npu_irq_out;

  c930_soc_top #(
    .MAX_M(8), .MAX_K(16), .MAX_N(12)
  ) dut (
    .i_clk     (clk),
    .i_rst_n   (rst_n),
    .o_npu_busy(npu_busy_out),
    .o_npu_done(npu_done_out),
    .o_npu_error(npu_error_out),
    .o_npu_irq (npu_irq_out)
  );

  // ---- Load firmware ----
  localparam IMG_WORDS = 4096;
  localparam MEM_BYTES = 65536;
  logic [31:0] img [0:IMG_WORDS-1];

  initial begin
    $readmemh("sw/npu_prog.hex", img);
    for (int i = 0; i < MEM_BYTES; i++)
      dut.u_ddr.mem[i] = 8'h0;
    for (int i = 0; i < IMG_WORDS; i++) begin
      dut.u_ddr.mem[4*i + 0] = img[i][7:0];
      dut.u_ddr.mem[4*i + 1] = img[i][15:8];
      dut.u_ddr.mem[4*i + 2] = img[i][23:16];
      dut.u_ddr.mem[4*i + 3] = img[i][31:24];
    end
  end

  // ---- Fill A/B for first GEMM (M=4 N=4 K=8 INT8, all ones -> C=8) ----
  initial begin
    for (int i = 0; i < 32; i++) begin
      dut.u_ddr.mem[32'h8000 + i] = 8'h01;  // A
      dut.u_ddr.mem[32'h8400 + i] = 8'h01;  // B
    end
  end

  // ---- Monitor i_busy ----
  integer pass, fail;
  integer busy_high;
  integer done_seen;

  initial begin
    pass = 0; fail = 0;
    busy_high = 0;
    done_seen = 0;

    $dumpfile("build/waves/status_busy.vcd");
    $dumpvars(0, tb_status_busy);

    rst_n = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;

    $display("[TEST] Booting SoC, monitoring i_busy...");
    $display("[TEST] i_busy = %0d (before boot)", dut.u_npu.u_csr.i_busy);

    // Monitor for up to 500K cycles (or until GEMM done)
    begin : monitor_loop
      integer cyc;
      for (cyc = 0; cyc < 500000; cyc = cyc + 1) begin
        @(posedge clk);

        if (dut.u_npu.u_csr.i_busy)
          busy_high = busy_high + 1;

        if (dut.u_npu.u_csr.done_latch && !done_seen) begin
          done_seen = 1;
          $display("[TEST] done_latch=1 at cycle %0d", cyc);
          $display("[TEST] i_busy = %0d (after GEMM)", dut.u_npu.u_csr.i_busy);
          $display("[TEST] i_cycle_count = %0d", dut.u_npu.u_csr.i_cycle_count);
        end

        if (done_seen && !dut.u_npu.u_csr.i_busy) begin
          $display("[TEST] GEMM complete, i_busy back to 0 at cycle %0d", cyc);
          disable monitor_loop;
        end
      end
    end

    $display("");
    $display("[TEST] i_busy high cycles: %0d", busy_high);
    $display("[TEST] done_latch: %0d", dut.u_npu.u_csr.done_latch);
    $display("[TEST] i_cycle_count: %0d", dut.u_npu.u_csr.i_cycle_count);

    if (busy_high > 0) begin
      $display("  [PASS] RTL drove i_busy=1 for %0d cycles", busy_high);
      pass++;
    end else begin
      $display("  [FAIL] RTL never drove i_busy=1");
      fail++;
    end

    if (done_seen) begin
      $display("  [PASS] GEMM completed (done_latch=1)");
      pass++;
    end else begin
      $display("  [FAIL] GEMM did not complete in 500K cycles");
      fail++;
    end

    // Check C result
    #1;
    $display("[TEST] C[0][0] = %0d (expected 8)",
             $signed(dut.u_ddr.mem[32'h8800] |
                    (dut.u_ddr.mem[32'h8801] << 8) |
                    (dut.u_ddr.mem[32'h8802] << 16) |
                    (dut.u_ddr.mem[32'h8803] << 24)));
    if ($signed(dut.u_ddr.mem[32'h8800] |
               (dut.u_ddr.mem[32'h8801] << 8) |
               (dut.u_ddr.mem[32'h8802] << 16) |
               (dut.u_ddr.mem[32'h8803] << 24)) == 8) begin
      $display("  [PASS] GEMM result correct"); pass++;
    end else begin
      $display("  [FAIL] GEMM result wrong"); fail++;
    end

    $display("");
    $display("=== RESULT: %0d passed, %0d failed ===", pass, fail);
    if (fail == 0) $display("[PASS] All tests passed - STATUS.BUSY confirmed in RTL");
    else $display("[FAIL] Some tests failed");
    $finish;
  end

  // Watchdog
  initial begin
    #200000000;
    $display("[TIMEOUT] Simulation exceeded 10M cycles");
    $finish;
  end

endmodule
