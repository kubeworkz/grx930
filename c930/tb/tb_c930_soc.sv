// -----------------------------------------------------------------------------
// tb_c930_soc.sv
//
// End-to-end SoC test: boots the RV64IMAC core with the C driver (npu_test.c),
// which programs the NPU over MMIO and launches a GEMM. The INT8 A/B operand
// tables are linked at fixed DDR addresses in the image, so the NPU's AXI4 DMA
// fetches them from DDR autonomously and burst-writes C back. The testbench
// waits for the completion magic, then reads A/B/C back from the DDR model and
// verifies C against a reference GEMM.
//
// Image format: sw/npu_prog.hex, one 32-bit little-endian word per line.
//
// Run (from c930/):
//   iverilog -g2012 -Wall -o build/tb_c930_soc.vvp \
//       ../rv64imac/RTL/*.sv \
//       rtl/c930_tensor_pe.sv rtl/c930_systolic_array.sv rtl/c930_npu_core.sv \
//       rtl/c930_npu_csr.sv rtl/c930_npu_dma.sv rtl/c930_npu_top.sv \
//       rtl/c930_ddr.sv rtl/c930_mmio_bridge.sv rtl/c930_soc_top.sv \
//       tb/tb_c930_soc.sv
//   vvp build/tb_c930_soc.vvp
// -----------------------------------------------------------------------------
module tb_c930_soc;

  localparam int M = 2;
  localparam int N = 6;
  localparam int K = 8;

  localparam int A_ADDR    = 32'h9000;
  localparam int B_ADDR    = 32'h9100;
  localparam int C_ADDR    = 32'h9200;
  localparam int DONE_ADDR = 32'h9300;

  // The image now spans the NPU operand tables linked at 0x9000/0x9100, so the
  // loader must cover well past B_ADDR (0x9100 + K*N bytes).
  localparam int MEM_BYTES = 65536;
  localparam int IMG_WORDS = 16384;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  logic o_npu_busy, o_npu_done, o_npu_error, o_npu_irq;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  c930_soc_top #(
    .NUM_ROWS  (4),
    .NUM_COLS  (4),
    .MAX_M     (8),
    .MAX_K     (16),
    .MAX_N     (12),
    .MEM_BYTES (MEM_BYTES)
  ) dut (
    .i_clk        (clk),
    .i_rst_n      (rst_n),
    .o_npu_busy   (o_npu_busy),
    .o_npu_done   (o_npu_done),
    .o_npu_error  (o_npu_error),
    .o_npu_irq    (o_npu_irq)
  );

  // ---------------------------------------------------------------------------
  // Clock
  // ---------------------------------------------------------------------------
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Image loading + stimulus
  // ---------------------------------------------------------------------------
  logic [31:0] img [0:IMG_WORDS-1];

  task automatic load_image();
    int i;
    $display("[TEST] loading sw/npu_prog.hex");
    for (i = 0; i < IMG_WORDS; i++) img[i] = 32'h0;
    $readmemh("sw/npu_prog.hex", img);

    for (i = 0; i < MEM_BYTES; i++) dut.u_ddr.mem[i] = 8'h0;

    for (i = 0; i < IMG_WORDS; i++) begin
      dut.u_ddr.mem[4*i + 0] = img[i][7:0];
      dut.u_ddr.mem[4*i + 1] = img[i][15:8];
      dut.u_ddr.mem[4*i + 2] = img[i][23:16];
      dut.u_ddr.mem[4*i + 3] = img[i][31:24];
    end
  endtask

  // Poll the DDR for the completion magic written by the C program.
  task automatic wait_done(output int found);
    int timeout = 0;
    found = 0;
    while (!found && timeout < 2000000) begin
      @(posedge clk);
      timeout = timeout + 1;
      if (dut.u_ddr.mem[DONE_ADDR + 3] == 8'hDE &&
          dut.u_ddr.mem[DONE_ADDR + 2] == 8'hAD &&
          dut.u_ddr.mem[DONE_ADDR + 1] == 8'hBE &&
          dut.u_ddr.mem[DONE_ADDR + 0] == 8'hEF)
        found = 1;
    end
    $display("[TEST] completion magic %0s after %0d cycles",
             found ? "found" : "NOT found", timeout);
  endtask


  // ---------------------------------------------------------------------------
  // Reference check (reads A/B/C back from the DDR model)
  // ---------------------------------------------------------------------------
  task automatic check_gemm();
    int errors = 0;
    int sum;
    int got;

    for (int mi = 0; mi < M; mi++) begin
      for (int ni = 0; ni < N; ni++) begin
        sum = 0;
        for (int ki = 0; ki < K; ki++) begin
          int av = $signed(dut.u_ddr.mem[A_ADDR + mi*K + ki]);
          int bv = $signed(dut.u_ddr.mem[B_ADDR + ki*N + ni]);
          sum = sum + av * bv;
        end

        // C is stored as little-endian INT32 words.
        got = $signed({dut.u_ddr.mem[C_ADDR + (mi*N+ni)*4 + 3],
                       dut.u_ddr.mem[C_ADDR + (mi*N+ni)*4 + 2],
                       dut.u_ddr.mem[C_ADDR + (mi*N+ni)*4 + 1],
                       dut.u_ddr.mem[C_ADDR + (mi*N+ni)*4 + 0]});

        if (got != sum) begin
          $display("[FAIL] C[%0d][%0d] = %0d, expected %0d", mi, ni, got, sum);
          errors = errors + 1;
        end
      end
    end

    if (errors != 0)
      $fatal(1, "[FAIL] GEMM: %0d mismatches", errors);
    $display("[PASS] GEMM M=%0d N=%0d K=%0d verified (C read back from DDR)", M, N, K);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  initial begin
    // $dumpfile("build/tb_c930_soc.vcd");
    // $dumpvars(0, tb_c930_soc);
    $timeformat(-9, 0, " ns", 8);

    rst_n = 1'b0;
    load_image();

    repeat (8) @(posedge clk);
    rst_n = 1'b1;

    fork
      begin : watchdog
        #20000000;  // 20 ms
        $display("[FAIL] watchdog timeout");
        $fatal(1, "timeout");
      end
      begin : main_flow
        int found;
        wait_done(found);
        $monitoroff;
        if (!found)
          $fatal(1, "CPU never signaled completion");
        if (o_npu_error)
          $fatal(1, "NPU reported an error");
        repeat (4) @(posedge clk);   // let the final stores settle
        check_gemm();
        $display("[PASS] all SoC NPU tests passed");
        $finish;
      end
    join
  end

endmodule
