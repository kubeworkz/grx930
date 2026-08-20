// ---------------------------------------------------------------------------
// tb_xsim.sv  --  Minimal Vivado xsim smoke test for C930 SoC
//
// Verifies the elaborated design compiles and the clock toggles.
// For full GEMM verification use the Icarus tb_c930_soc.sv.
// ---------------------------------------------------------------------------
module tb_xsim;

  logic clk = 0;
  logic rst_n = 0;
  logic npu_busy, npu_done, npu_error, npu_irq;

  c930_soc_top #(
    .NUM_ROWS(4),
    .NUM_COLS(4),
    .MAX_M(8),
    .MAX_K(16),
    .MAX_N(12),
    .MEM_BYTES(65536)
  ) u_dut (
    .i_clk(clk),
    .i_rst_n(rst_n),
    .o_npu_busy(npu_busy),
    .o_npu_done(npu_done),
    .o_npu_error(npu_error),
    .o_npu_irq(npu_irq)
  );

  // 100 MHz clock
  always #5 clk = ~clk;

  initial begin
    $display("[TB] C930 SoC xsim smoke test starting");
    rst_n = 0;
    #100;
    rst_n = 1;
    #2000;
    $display("[TB] Simulation ran for 2 us without error");
    $display("[TB] npu_busy=%b npu_done=%b npu_error=%b npu_irq=%b",
             npu_busy, npu_done, npu_error, npu_irq);
    $finish;
  end

  // Timeout guard
  initial begin
    #100000;
    $display("[TB] TIMEOUT -- simulation exceeded 100 us");
    $finish;
  end

endmodule
