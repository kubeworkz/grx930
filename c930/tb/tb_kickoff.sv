// -----------------------------------------------------------------------------
// tb_kickoff.sv
//
// Boots the full C930 SoC with the SYNTH DDR stub (synth/c930_ddr_stub.sv),
// whose embedded boot image runs the tiny NPU GEMM kick-off firmware
// (sw/npu_boot.c). The core programs a fixed 2x4x2 GEMM over MMIO, the NPU
// DMA fetches A/B from the stub, computes C, and bursts it back to 0x120.
//
// This verifies the exact design that goes into the bitstream: same stub,
// same image, same RTL -- so a board programmed with the generated .bit must
// light LD4 (busy) then LD5/LD7 (done/irq) and leave LD6 (error) dark.
//
// The DUT runs with CLK_DIV=2 (the exact bitstream configuration): the tb
// clock is the 100 MHz board oscillator and the core sees a 50 MHz clock.
//
// Compile with the stub REPLACING the behavioral c930_ddr.sv:
//   iverilog -g2012 -o build/tb_kickoff.vvp \
//     ../rv64imac/RTL/*.sv \
//     rtl/c930_npu_core.sv rtl/c930_systolic_array.sv rtl/c930_tensor_pe.sv \
//     rtl/c930_npu_csr.sv rtl/c930_npu_dma.sv rtl/c930_npu_top.sv \
//     rtl/c930_mmio_bridge.sv rtl/c930_soc_top.sv \
//     synth/c930_ddr_stub.sv tb/tb_kickoff.sv
// -----------------------------------------------------------------------------
module tb_kickoff;

  localparam int NUM_ROWS = 4;   // systolic rows
  localparam int NUM_COLS = 4;   // systolic cols
  localparam int MAX_M    = 8;
  localparam int MAX_K    = 16;
  localparam int MAX_N    = 12;
  localparam int MEM_BYTES = 65536;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic o_npu_busy, o_npu_done, o_npu_error, o_npu_irq;

  c930_soc_top #(
    .NUM_ROWS  (NUM_ROWS),
    .NUM_COLS  (NUM_COLS),
    .MAX_M     (MAX_M),
    .MAX_K     (MAX_K),
    .MAX_N     (MAX_N),
    .MEM_BYTES (MEM_BYTES),
    .CLK_DIV   (2)   // bitstream config: 100 MHz board clock -> 50 MHz core
  ) dut (
    .i_clk        (clk),
    .i_rst_n      (rst_n),
    .o_npu_busy   (o_npu_busy),
    .o_npu_done   (o_npu_done),
    .o_npu_error  (o_npu_error),
    .o_npu_irq    (o_npu_irq)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // LED-edge sampling: busy seen, done seen, error seen
  // ---------------------------------------------------------------------------
  logic seen_busy  = 1'b0;
  logic seen_done  = 1'b0;
  logic seen_error = 1'b0;

  always @(posedge clk) begin
    if (o_npu_busy)  seen_busy  <= 1'b1;
    if (o_npu_done)  seen_done  <= 1'b1;
    if (o_npu_error) seen_error <= 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Boot + watchdog + verification
  // ---------------------------------------------------------------------------
  int c00, c01, c10, c11;

  initial begin
    $display("[KICK] booting C930 with stub-embedded NPU kick-off firmware");

    repeat (30) @(posedge clk);
    rst_n = 1'b1;

    // Watchdog: the boot + MMIO programming + 2x4x2 GEMM takes a few thousand
    // cycles; 200K is far more than enough and keeps the sim quick.
    repeat (200000) @(posedge clk);

    // C = A(2x4) x B(4x2) = {1,2; 5,6}, written by the NPU DMA to 0x120.
    // 0x120 -> line 9, words 0..3 (32-bit INT32, little-endian). The stub is
    // bank-interleaved (8 banks x 16 lines x 32b), so word w of line 9 lives
    // in mem[w][9].
    c00 = $signed(dut.u_ddr.mem[0][9]);
    c01 = $signed(dut.u_ddr.mem[1][9]);
    c10 = $signed(dut.u_ddr.mem[2][9]);
    c11 = $signed(dut.u_ddr.mem[3][9]);

    if (seen_error) $fatal(1, "[KICK FAIL] o_npu_error asserted");
    if (!seen_busy) $fatal(1, "[KICK FAIL] NPU never went busy (firmware did not start the GEMM)");
    if (!seen_done) $fatal(1, "[KICK FAIL] NPU never signaled done");
    if (c00 != 1 || c01 != 2 || c10 != 5 || c11 != 6)
      $fatal(1, "[KICK FAIL] C={%0d,%0d,%0d,%0d}, expected {1,2,5,6}", c00, c01, c10, c11);

    $display("[KICK PASS] busy=%0d done=%0d error=%0d irq=%0d", seen_busy, seen_done, seen_error, o_npu_irq);
    $display("[KICK] C={%0d,%0d,%0d,%0d} (expected {1,2,5,6})", c00, c01, c10, c11);
    $display("[KICK] LED map: LD4=busy(%0d) LD5=done(%0d) LD6=error(%0d) LD7=irq(%0d)",
             seen_busy, seen_done, seen_error, o_npu_irq);
    $finish;
  end

endmodule
