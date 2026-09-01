// -----------------------------------------------------------------------------
// tb_npu_tile.sv - Testbench for the NPU tiling library.
//
// Tests single-tile GEMMs that fit within MAX_M/N/K to verify the basic NPU
// path works through the tile test firmware. The tiling tests (M/N/K exceeding
// MAX) are separate and can be run with a longer timeout.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_npu_tile;

  localparam int NUM_ROWS  = 8;
  localparam int NUM_COLS  = 8;
  localparam int MAX_M     = 8;
  localparam int MAX_K     = 16;
  localparam int MAX_N     = 12;
  localparam int MEM_BYTES = 65536;
  localparam int IMG_WORDS = 4096;

  localparam int A_ADDR     = 32'h1000;
  localparam int B_ADDR     = 32'h2000;
  localparam int C_ADDR     = 32'h3000;
  localparam int DIMS_ADDR  = 32'h9400;
  localparam int DONE_ADDR  = 32'h9410;
  localparam int PHASE_ADDR = 32'h9490;
  localparam int DIAG_ADDR  = 32'h9480;
  localparam int DONE_MAGIC = 32'hDEADBEEF;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  logic o_npu_busy, o_npu_done, o_npu_error, o_npu_irq;
  always #5 clk = ~clk;

  c930_soc_top #(
    .NUM_ROWS  (NUM_ROWS), .NUM_COLS  (NUM_COLS),
    .MAX_M     (MAX_M), .MAX_K     (MAX_K), .MAX_N     (MAX_N),
    .MEM_BYTES (MEM_BYTES)
  ) dut (
    .i_clk(clk), .i_rst_n(rst_n),
    .o_npu_busy(o_npu_busy), .o_npu_done(o_npu_done),
    .o_npu_error(o_npu_error), .o_npu_irq(o_npu_irq)
  );

  function automatic logic [31:0] ddr_read32(input int byte_addr);
    return {dut.u_ddr.mem[byte_addr+3], dut.u_ddr.mem[byte_addr+2],
            dut.u_ddr.mem[byte_addr+1], dut.u_ddr.mem[byte_addr+0]};
  endfunction

  task automatic ddr_write32(input int byte_addr, input logic [31:0] val);
    dut.u_ddr.mem[byte_addr+0] = val[7:0];
    dut.u_ddr.mem[byte_addr+1] = val[15:8];
    dut.u_ddr.mem[byte_addr+2] = val[23:16];
    dut.u_ddr.mem[byte_addr+3] = val[31:24];
  endtask

  logic [31:0] img [0:IMG_WORDS-1];
  task automatic load_image();
    int i;
    $display("[TILE-TEST] loading sw/npu_tile_prog.hex");
    for (i = 0; i < IMG_WORDS; i++) img[i] = 32'h0;
    $readmemh("sw/npu_tile_prog.hex", img);
    for (i = 0; i < MEM_BYTES; i++) dut.u_ddr.mem[i] = 8'h0;
    for (i = 0; i < IMG_WORDS; i++) begin
      dut.u_ddr.mem[4*i+0] = img[i][7:0];
      dut.u_ddr.mem[4*i+1] = img[i][15:8];
      dut.u_ddr.mem[4*i+2] = img[i][23:16];
      dut.u_ddr.mem[4*i+3] = img[i][31:24];
    end
  endtask

  function automatic logic [31:0] lcg(input logic [31:0] x);
    logic [63:0] t;
    t = x;
    t = t * 6364136223846793005 + 1442695040888963407;
    lcg = t[63:32] ^ t[31:0];
  endfunction

  task automatic fill_ab(input int m, n, k, input int seed);
    logic [31:0] s;
    s = seed;
    for (int i = 0; i < m * k; i++) begin
      s = lcg(s);
      dut.u_ddr.mem[A_ADDR + i] = s[7:0];
    end
    s = seed ^ 32'hBADF00D;
    for (int i = 0; i < k * n; i++) begin
      s = lcg(s);
      dut.u_ddr.mem[B_ADDR + i] = s[7:0];
    end
  endtask

  function automatic int sw_gemm_elem(input int row, col, m, n, k);
    automatic int sum = 0;
    for (int p = 0; p < k; p++)
      sum = sum + $signed(dut.u_ddr.mem[A_ADDR + row * k + p])
                 * $signed(dut.u_ddr.mem[B_ADDR + p * n + col]);
    sw_gemm_elem = sum;
  endfunction

  integer pass_count, fail_count;
  integer mismatches, found;
  logic [31:0] npu_val, ref_val;

  task automatic run_test(input int m, n, k, input int test_id, input int seed);
    mismatches = 0;
    $display("[TILE-TEST] Test %0d: M=%0d N=%0d K=%0d (seed %0d)", test_id, m, n, k, seed);

    fill_ab(m, n, k, seed);

    for (int i = 0; i < m * n * 4; i++)
      dut.u_ddr.mem[C_ADDR + i] = 8'h0;

    ddr_write32(DIMS_ADDR + 0, m);
    ddr_write32(DIMS_ADDR + 4, n);
    ddr_write32(DIMS_ADDR + 8, k);
    ddr_write32(DIMS_ADDR + 12, 0);
    ddr_write32(DONE_ADDR, 32'h0);

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;

    found = 0;
    for (int t = 0; t < 3_000_000; t++) begin
      @(posedge clk);
      if (ddr_read32(DONE_ADDR) === DONE_MAGIC)
        found = 1;
    end

    if (!found) begin
      $display("[TILE-TEST]   FAIL: timeout (PHASE=%h DIAG=%h)",
               ddr_read32(PHASE_ADDR), ddr_read32(DIAG_ADDR));
      fail_count = fail_count + 1;
    end else begin
      for (int i = 0; i < m; i++) begin
        for (int j = 0; j < n; j++) begin
          npu_val = ddr_read32(C_ADDR + (i * n + j) * 4);
          ref_val = sw_gemm_elem(i, j, m, n, k);
          if (npu_val !== ref_val) begin
            if (mismatches < 3)
              $display("[TILE-TEST]   MISMATCH C[%0d][%0d]: NPU=%0d REF=%0d",
                       i, j, $signed(npu_val), $signed(ref_val));
            mismatches = mismatches + 1;
          end
        end
      end

      if (mismatches === 0) begin
        $display("[TILE-TEST]   PASS (%0d elements)", m * n);
        pass_count = pass_count + 1;
      end else begin
        $display("[TILE-TEST]   FAIL: %0d mismatches / %0d elements", mismatches, m * n);
        fail_count = fail_count + 1;
      end
    end
  endtask

  initial begin
    pass_count = 0; fail_count = 0;
    load_image();

    $display("");
    $display("=============================================================");
    $display(" NPU Tiling Library Test (single-tile path)");
    $display("=============================================================");

    run_test(1, 1, 1, 1, 1001);
    run_test(3, 4, 8, 2, 1002);
    run_test(8, 12, 16, 3, 1003);

    $display("");
    $display("=============================================================");
    $display(" RESULTS: %0d passed, %0d failed", pass_count, fail_count);
    $display("=============================================================");

    if (fail_count > 0) $finish(1);
    $finish;
  end

endmodule
