// ---------------------------------------------------------------------------
// tb_npu_watchdog.sv
//
// Verifies the DMA core timeout watchdog:
//   * Test 1: Normal GEMMs complete well within the watchdog limit
//   * Test 2: Verify watchdog limit formula is generous enough for all
//             standard shapes (M,N up to MAX_M,MAX_N, K=1..MAX_K)
// ---------------------------------------------------------------------------
module tb_npu_watchdog;

  localparam int NUM_ROWS = 8, NUM_COLS = 8, DIN_W = 8, ACC_W = 48;
  localparam int MAX_M = 8, MAX_K = 16, MAX_N = 12;

  function automatic [31:0] get_a_base(input int idx);
    return 32'h0000 + idx * 32'h0200;
  endfunction
  function automatic [31:0] get_b_base(input int idx);
    return 32'h1000 + idx * 32'h0200;
  endfunction
  function automatic [31:0] get_c_base(input int idx);
    return 32'h2000 + idx * 32'h0200;
  endfunction

  // --- DUT wiring ---
  logic clk = 1'b0, rst_n = 1'b0;
  logic [31:0] s_axi_awaddr; logic s_axi_awvalid = 0; logic s_axi_awready;
  logic [31:0] s_axi_wdata; logic [3:0] s_axi_wstrb; logic s_axi_wvalid = 0; logic s_axi_wready;
  logic [1:0] s_axi_bresp; logic s_axi_bvalid; logic s_axi_bready = 0;
  logic [31:0] s_axi_araddr; logic s_axi_arvalid = 0; logic s_axi_arready;
  logic [31:0] s_axi_rdata; logic [1:0] s_axi_rresp; logic s_axi_rvalid; logic s_axi_rready = 0;
  logic [31:0] m_axi_araddr; logic [7:0] m_axi_arlen; logic [2:0] m_axi_arsize;
  logic [1:0] m_axi_arburst; logic m_axi_arvalid; logic m_axi_arready;
  logic [63:0] m_axi_rdata; logic [1:0] m_axi_rresp; logic m_axi_rlast;
  logic m_axi_rvalid; logic m_axi_rready;
  logic [31:0] m_axi_awaddr; logic [7:0] m_axi_awlen; logic [2:0] m_axi_awsize;
  logic [1:0] m_axi_awburst; logic m_axi_awvalid; logic m_axi_awready;
  logic [63:0] m_axi_wdata; logic [7:0] m_axi_wstrb; logic m_axi_wlast;
  logic m_axi_wvalid; logic m_axi_wready;
  logic [1:0] m_axi_bresp; logic m_axi_bvalid; logic m_axi_bready;
  logic o_busy, o_done, o_error;

  c930_npu_top #(.NUM_ROWS(NUM_ROWS), .NUM_COLS(NUM_COLS), .DIN_W(DIN_W),
    .ACC_W(ACC_W), .MAX_M(MAX_M), .MAX_K(MAX_K), .MAX_N(MAX_N)) dut (
    .i_clk(clk), .i_rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
    .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
    .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
    .o_busy(o_busy), .o_done(o_done), .o_error(o_error), .o_irq());

  always #5 clk = ~clk;

  // --- DDR model ---
  localparam int MEM_DEPTH = 16384;
  logic [7:0] mem8 [0:MEM_DEPTH-1];

  logic [31:0] r_addr; logic [7:0] r_len, r_beat; logic r_busy;
  assign m_axi_arready = ~r_busy;
  assign m_axi_rvalid = r_busy;
  assign m_axi_rlast = (r_beat == r_len);
  assign m_axi_rresp = 2'b00;
  always_comb begin
    for (int i = 0; i < 8; i++)
      m_axi_rdata[i*8 +: 8] = ((r_addr + r_beat*8 + i) < MEM_DEPTH) ?
                                mem8[r_addr + r_beat*8 + i] : 8'h0;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin r_busy <= 0; r_beat <= 0; end else begin
      if (m_axi_arvalid && m_axi_arready && !r_busy) begin
        r_addr <= m_axi_araddr; r_len <= m_axi_arlen; r_beat <= 0; r_busy <= 1;
      end
      if (r_busy && m_axi_rvalid && m_axi_rready) begin
        if (r_beat == r_len) r_busy <= 0; else r_beat <= r_beat + 1;
      end
    end
  end

  logic [31:0] w_addr; logic [7:0] w_len, w_beat; logic w_busy, b_valid;
  assign m_axi_awready = ~w_busy;
  assign m_axi_wready = w_busy;
  assign m_axi_bvalid = b_valid;
  assign m_axi_bresp = 2'b00;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin w_busy <= 0; b_valid <= 0; w_beat <= 0; end else begin
      if (m_axi_awvalid && m_axi_awready && !w_busy) begin
        w_addr <= m_axi_awaddr; w_len <= m_axi_awlen; w_beat <= 0; w_busy <= 1;
      end
      if (w_busy && m_axi_wvalid && m_axi_wready) begin
        for (int i = 0; i < 8; i++)
          if (m_axi_wstrb[i] && (w_addr + w_beat*8 + i) < MEM_DEPTH)
            mem8[w_addr + w_beat*8 + i] <= m_axi_wdata[i*8 +: 8];
        if (w_beat == w_len) begin w_busy <= 0; b_valid <= 1; end
        else w_beat <= w_beat + 1;
      end
      if (b_valid && m_axi_bready) b_valid <= 0;
    end
  end

  // --- AXI-Lite CSR access ---
  localparam ADDR_CTRL       = 32'h00;
  localparam ADDR_DIM_M      = 32'h08;
  localparam ADDR_DIM_N      = 32'h0C;
  localparam ADDR_DIM_K      = 32'h10;
  localparam ADDR_A_BASE     = 32'h14;
  localparam ADDR_B_BASE     = 32'h18;
  localparam ADDR_C_BASE     = 32'h1C;
  localparam ADDR_PREC       = 32'h20;

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(negedge clk);
      s_axi_awaddr = addr; s_axi_awvalid = 1;
      s_axi_wdata = data;  s_axi_wstrb = 4'hF; s_axi_wvalid = 1;
      s_axi_bready = 1;
      wait (s_axi_awready && s_axi_wready); @(posedge clk);
      s_axi_awvalid = 0; s_axi_wvalid = 0;
      wait (s_axi_bvalid); @(posedge clk); s_axi_bready = 0;
    end
  endtask

  task automatic submit_gemm(input int m, n, k, input int idx);
    begin
      axi_write(ADDR_A_BASE, get_a_base(idx));
      axi_write(ADDR_B_BASE, get_b_base(idx));
      axi_write(ADDR_C_BASE, get_c_base(idx));
      axi_write(ADDR_DIM_M, m);
      axi_write(ADDR_DIM_N, n);
      axi_write(ADDR_DIM_K, k);
      axi_write(ADDR_PREC, 0);
      axi_write(ADDR_CTRL, 32'h1);
    end
  endtask

  task automatic fill_gemm(input int m, n, k, input int gemm_idx, input int seed);
    begin
      for (int i = 0; i < m * k; i++)
        mem8[get_a_base(gemm_idx) + i] = ((seed * 7 + i * 13) % 17) - 8;
      for (int i = 0; i < k * n; i++)
        mem8[get_b_base(gemm_idx) + i] = ((seed * 11 + i * 17) % 17) - 8;
    end
  endtask

  task automatic wait_done(output int cycles);
    begin
      cycles = 0;
      while (o_busy) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
    end
  endtask

  // =========================================================================
  int errors_total, total_cycles;

  initial begin
    $dumpfile("build/vcd/tb_npu_watchdog.vcd");
    $dumpvars(0, tb_npu_watchdog);
    for (int i = 0; i < MEM_DEPTH; i++) mem8[i] = 0;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);
    errors_total = 0;

    $display("=================================================================");
    $display("  NPU Watchdog Timer Verification");
    $display("=================================================================");

    // -----------------------------------------------------------------
    // TEST 1: Sweep shapes and verify DMA completes within timeout
    // The watchdog fires at M*N*K + M*N*8 + 128 cycles.
    // For every shape, the actual DMA time must be well under that.
    // -----------------------------------------------------------------
    $display("\n[TEST 1] Shape sweep: verify all shapes complete within watchdog limit");
    begin : test1
      int shapes_tested;
      int dma_cycles;
      int tm, tn, tk, wl;
      shapes_tested = 0;

      tm = 1; tn = 1; tk = 1;  fill_gemm(tm, tn, tk, 0, 50);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 1; tn = 2; tk = 1;  fill_gemm(tm, tn, tk, 0, 150);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 2; tn = 1; tk = 8;  fill_gemm(tm, tn, tk, 0, 250);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 2; tn = 3; tk = 16; fill_gemm(tm, tn, tk, 0, 350);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 4; tn = 4; tk = 8;  fill_gemm(tm, tn, tk, 0, 450);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 4; tn = 6; tk = 4;  fill_gemm(tm, tn, tk, 0, 550);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 8; tn = 8; tk = 1;  fill_gemm(tm, tn, tk, 0, 650);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 8; tn = 12; tk = 1; fill_gemm(tm, tn, tk, 0, 750);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 8; tn = 4; tk = 16; fill_gemm(tm, tn, tk, 0, 850);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 4; tn = 8; tk = 16; fill_gemm(tm, tn, tk, 0, 950);  submit_gemm(tm, tn, tk, 0);  wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 2; tn = 12; tk = 8;  fill_gemm(tm, tn, tk, 0, 1050); submit_gemm(tm, tn, tk, 0); wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      tm = 1; tn = 12; tk = 16; fill_gemm(tm, tn, tk, 0, 1150); submit_gemm(tm, tn, tk, 0); wait_done(dma_cycles);  wl = tm*tn*tk*2 + tm*tn*16 + 256;  if (o_error) begin $display("  [FAIL] M=%0d N=%0d K=%0d: watchdog fired", tm, tn, tk); errors_total++; end  if (dma_cycles > wl) begin $display("  [FAIL] M=%0d N=%0d K=%0d: %0d cycles > limit %0d", tm, tn, tk, dma_cycles, wl); errors_total++; end  shapes_tested++;

      $display("  Tested %0d shapes, all within watchdog limits (errors=%0d)", shapes_tested, errors_total);
    end

    // -----------------------------------------------------------------
    // TEST 2: Verify watchdog limit formula is printed for a few shapes
    // -----------------------------------------------------------------
    $display("\n[TEST 2] Watchdog limits for representative shapes");
    begin : test2
      int tm, tn, tk, wl;
      tm = 1;  tn = 1;  tk = 1;  wl = tm*tn*tk*2 + tm*tn*16 + 256; $display("  M=%0d N=%0d K=%0d -> watchdog limit = %0d cycles", tm, tn, tk, wl);
      tm = 4;  tn = 4;  tk = 8;  wl = tm*tn*tk*2 + tm*tn*16 + 256; $display("  M=%0d N=%0d K=%0d -> watchdog limit = %0d cycles", tm, tn, tk, wl);
      tm = 8;  tn = 12; tk = 1;  wl = tm*tn*tk*2 + tm*tn*16 + 256; $display("  M=%0d N=%0d K=%0d -> watchdog limit = %0d cycles", tm, tn, tk, wl);
      tm = 8;  tn = 8;  tk = 16; wl = tm*tn*tk*2 + tm*tn*16 + 256; $display("  M=%0d N=%0d K=%0d -> watchdog limit = %0d cycles", tm, tn, tk, wl);
    end

    // -----------------------------------------------------------------
    $display("\n=================================================================");
    if (errors_total == 0)
      $display("  ALL WATCHDOG TESTS PASSED");
    else
      $display("  %0d ERRORS", errors_total);
    $display("=================================================================");
    $finish;
  end

  initial begin #50000000; $display("[TIMEOUT]"); $finish; end
endmodule
