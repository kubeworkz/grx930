// -----------------------------------------------------------------------------
// tb_c930_soc_full.sv
//
// End-to-end test of the GRX930 SoC with AXI4 crossbar.
// CPU boots from boot ROM, jumps to DDR firmware (npu_ddr.hex) which
// programs the NPU via MMIO and runs GEMM shapes.
//
// DDR is preloaded with the firmware at offset 0x1000 via $readmemh.
// Boot ROM contains a jump to 0x1000 (the DDR code entry point).
// The testbench monitors o_npu_done / o_npu_error for pass/fail.
// UART TX is also monitored for firmware printf output.
// -----------------------------------------------------------------------------
module tb_c930_soc_full;

  localparam int NUM_ROWS = 8;
  localparam int NUM_COLS = 8;
  localparam int MAX_M    = 8;
  localparam int MAX_K    = 16;
  localparam int MAX_N    = 12;
  localparam int MEM_BYTES = 65536;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  logic o_npu_busy, o_npu_done, o_npu_error, o_npu_irq;
  logic o_uart_txd;
  logic i_uart_rxd = 1'b1;

  int total_errs;

  // =========================================================================
  // DUT
  // =========================================================================
  c930_soc_top #(
    .NUM_ROWS       (NUM_ROWS),
    .NUM_COLS       (NUM_COLS),
    .MAX_M          (MAX_M),
    .MAX_K          (MAX_K),
    .MAX_N          (MAX_N),
    .MEM_BYTES      (MEM_BYTES),
    .DDR_INIT_FILE  ("sw/npu_ddr_bytes.hex")
  ) dut (
    .i_clk       (clk),
    .i_rst_n     (rst_n),
    .o_npu_busy  (o_npu_busy),
    .o_npu_done  (o_npu_done),
    .o_npu_error (o_npu_error),
    .o_npu_irq   (o_npu_irq),
    .o_uart_txd  (o_uart_txd),
    .i_uart_rxd  (i_uart_rxd)
  );

  always #5 clk = ~clk;

  // =========================================================================
  // UART TX monitor (captures bytes from o_uart_txd at 115200 baud)
  // =========================================================================
  localparam int BAUD_DIV = 868;
  logic        uart_busy;
  logic [3:0]  uart_bit_cnt;
  logic [3:0]  uart_bit_idx;
  logic [7:0]  uart_sr;
  logic        uart_prev_txd;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      uart_busy    <= 1'b0;
      uart_bit_cnt <= '0;
      uart_bit_idx <= '0;
      uart_sr      <= '0;
      uart_prev_txd <= 1'b1;
    end else begin
      uart_prev_txd <= o_uart_txd;
      if (!uart_busy) begin
        if (uart_prev_txd && !o_uart_txd) begin
          uart_busy    <= 1'b1;
          uart_bit_cnt <= '0;
          uart_bit_idx <= 4'd7;
        end
      end else begin
        if (uart_bit_idx == 0 && uart_bit_cnt == 4'd8) begin
          $write("%c", uart_sr);
          uart_busy <= 1'b0;
        end else begin
          if (uart_bit_cnt < BAUD_DIV - 1)
            uart_bit_cnt <= uart_bit_cnt + 1;
          else begin
            uart_bit_cnt <= '0;
            uart_sr[uart_bit_idx] <= o_uart_txd;
            uart_bit_idx <= uart_bit_idx - 1;
          end
        end
      end
    end
  end

  // =========================================================================
  // Main test: boot firmware, wait for NPU completion
  // =========================================================================
  initial begin
    $dumpfile("build/tb_c930_soc_full.vcd");
    $dumpvars(0, tb_c930_soc_full);
    total_errs = 0;

    // Release preload port
    force dut.u_ddr.i_tb_wr_en = 1'b0;

    // Reset
    rst_n = 1'b0;
    repeat(20) @(posedge clk);
    rst_n = 1'b1;

    $display("\n========================================");
    $display("  GRX930 Full SoC Test");
    $display("  Boot ROM → DDR firmware → NPU GEMM");
    $display("========================================");

    // Wait for CPU to boot and firmware to run
    // The firmware programs the NPU and waits for completion
    begin : wait_npu
      int poll_cnt;
      poll_cnt = 0;
      forever begin
        @(posedge clk);
        poll_cnt = poll_cnt + 1;

        if (o_npu_done) begin
          $display("\n  [PASS] NPU GEMM completed (o_npu_done) after %0d cycles", poll_cnt);
          disable wait_npu;
        end
        if (o_npu_error) begin
          $error("  [FAIL] NPU reported error after %0d cycles", poll_cnt);
          total_errs = total_errs + 1;
          disable wait_npu;
        end
        if (poll_cnt > 200_000) begin
          $error("[TIMEOUT] NPU did not complete in %0d cycles", poll_cnt);
          total_errs = total_errs + 1;
          disable wait_npu;
        end
      end
    end

    // Wait a bit for UART output to settle
    repeat(1000) @(posedge clk);

    // Summary
    $display("\n========================================");
    if (total_errs == 0)
      $display("  FULL-SOC TEST PASSED");
    else
      $error("  FAILED: %0d total errors", total_errs);
    $display("========================================\n");

    #100;
    $finish;
  end

endmodule
