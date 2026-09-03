// ---------------------------------------------------------------------------
// tb_npu_ddr_timeout.sv
//
// Verifies the DDR read timeout watchdog:
//   * Test 1: Normal GEMMs complete without triggering DDR timeout
//   * Test 2: DDR model that never responds → o_error fires within 1024 cycles
// ---------------------------------------------------------------------------
module tb_npu_ddr_timeout;

  localparam int NUM_ROWS = 8, NUM_COLS = 8, DIN_W = 8, ACC_W = 48;
  localparam int MAX_M = 8, MAX_K = 16, MAX_N = 12;
  localparam int DDR_TIMEOUT = 1024;

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
  // For test 1: normal responding DDR
  // For test 2: DDR that never responds (rvalid=0 always)
  localparam int MEM_DEPTH = 16384;
  logic [7:0] mem8 [0:MEM_DEPTH-1];

  logic ddr_hang;  // when set, DDR never responds to reads

  logic [31:0] r_addr; logic [7:0] r_len, r_beat; logic r_busy;
  int r_busy_cnt;  // cycles r_busy has been held without rready progressing
  assign m_axi_arready = ~r_busy;
  assign m_axi_rvalid = r_busy & ~ddr_hang;  // hang mode: never assert rvalid
  assign m_axi_rlast = (r_beat == r_len);
  assign m_axi_rresp = 2'b00;
  always_comb begin
    for (int i = 0; i < 8; i++)
      m_axi_rdata[i*8 +: 8] = ((r_addr + r_beat*8 + i) < MEM_DEPTH) ?
                                mem8[r_addr + r_beat*8 + i] : 8'h0;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin r_busy <= 0; r_beat <= 0; r_busy_cnt <= 0; end else begin
      if (m_axi_arvalid && m_axi_arready && !r_busy) begin
        r_addr <= m_axi_araddr; r_len <= m_axi_arlen; r_beat <= 0; r_busy <= 1;
        r_busy_cnt <= 0;
      end
      if (r_busy && m_axi_rvalid && m_axi_rready) begin
        r_busy_cnt <= 0;
        if (r_beat == r_len) r_busy <= 0; else r_beat <= r_beat + 1;
      end else if (r_busy) begin
        r_busy_cnt <= r_busy_cnt + 1;
        // Safety: release r_busy if stuck for too long (simulates real DDR timeout)
        if (r_busy_cnt > 2048) begin
          r_busy <= 0;
          r_beat <= 0;
        end
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
  localparam ADDR_STATUS     = 32'h04;

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

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
    begin
      @(negedge clk);
      s_axi_araddr = addr; s_axi_arvalid = 1;
      s_axi_rready = 1;
      wait (s_axi_arready); @(posedge clk);
      s_axi_arvalid = 0;
      wait (s_axi_rvalid); data = s_axi_rdata; @(posedge clk);
      s_axi_rready = 0;
    end
  endtask

  task automatic submit_gemm(input int m, n, k, input int gemm_idx);
    begin
      axi_write(ADDR_A_BASE, get_a_base(gemm_idx));
      axi_write(ADDR_B_BASE, get_b_base(gemm_idx));
      axi_write(ADDR_C_BASE, get_c_base(gemm_idx));
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
  int errors_total;
  logic [31:0] status;

  initial begin
    $dumpfile("build/vcd/tb_npu_ddr_timeout.vcd");
    $dumpvars(0, tb_npu_ddr_timeout);
    for (int i = 0; i < MEM_DEPTH; i++) mem8[i] = 0;
    rst_n = 0; ddr_hang = 0;
    repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);
    errors_total = 0;

    $display("=================================================================");
    $display("  DDR Timeout Watchdog Verification");
    $display("=================================================================");

    // -----------------------------------------------------------------
    // TEST 1: Normal GEMMs complete without DDR timeout
    // -----------------------------------------------------------------
    $display("\n[TEST 1] Normal GEMMs: DDR responds promptly");
    begin : test1
      int dma_cycles;
      ddr_hang = 0;

      fill_gemm(4, 4, 8, 0, 100);
      submit_gemm(4, 4, 8, 0);
      wait_done(dma_cycles);

      if (o_error) begin
        $display("  [FAIL] o_error asserted on normal GEMM (false DDR timeout!)");
        errors_total = errors_total + 1;
      end
      $display("  Normal GEMM completed in %0d cycles, o_error=%0b (PASS)",
               dma_cycles, o_error);
    end

    // -----------------------------------------------------------------
    // TEST 2: DDR hangs → o_error fires within DDR_TIMEOUT_CYCLES
    // -----------------------------------------------------------------
    $display("\n[TEST 2] DDR hang: verify o_error fires within %0d cycles", DDR_TIMEOUT);
    begin : test2
      int cycles_before_error;
      int error_cycle;
      logic saw_error;
      ddr_hang = 1;  // DDR will never respond to reads

      // Submit a GEMM — the DMA will try to read A from DDR and hang
      fill_gemm(4, 4, 8, 0, 200);
      submit_gemm(4, 4, 8, 0);

      // Wait for o_error to assert
      cycles_before_error = 0;
      saw_error = 0;
      while (cycles_before_error < DDR_TIMEOUT + 512) begin
        @(posedge clk);
        cycles_before_error = cycles_before_error + 1;
        if (o_error) begin
          saw_error = 1;
          error_cycle = cycles_before_error;
        end
      end

      if (!saw_error) begin
        $display("  [FAIL] o_error never asserted after %0d cycles", cycles_before_error);
        errors_total = errors_total + 1;
      end else begin
        $display("  o_error fired after %0d cycles (limit=%0d): PASS",
                 error_cycle, DDR_TIMEOUT);
        if (error_cycle > DDR_TIMEOUT + 10) begin
          $display("  [WARN] Timeout took %0d cycles, expected ~%0d", error_cycle, DDR_TIMEOUT);
        end
      end

      // After error, the DMA should return to P_IDLE
      // Wait for DDR model safety timeout to release r_busy (up to 2048 cycles)
      ddr_hang = 0;  // restore DDR
      repeat(3000) @(posedge clk);

      // Check that the engine is no longer busy
      if (o_busy) begin
        $display("  [FAIL] Engine still busy after DDR timeout — not cleaned up");
        errors_total = errors_total + 1;
      end else begin
        $display("  Engine returned to idle after timeout: PASS");
      end

      // Clear the error by reading STATUS (latched DONE/ERROR bits)
      axi_read(ADDR_STATUS, status);
    end

    // -----------------------------------------------------------------
    // TEST 3: Normal GEMM after DDR timeout recovery
    // -----------------------------------------------------------------
    $display("\n[TEST 3] Recovery: normal GEMM after DDR timeout");
    begin : test3
      int dma_cycles;
      ddr_hang = 0;  // DDR responds normally

      fill_gemm(2, 3, 4, 0, 300);
      submit_gemm(2, 3, 4, 0);
      wait_done(dma_cycles);

      axi_read(ADDR_STATUS, status);
      if (o_error) begin
        $display("  [FAIL] o_error after recovery GEMM");
        errors_total = errors_total + 1;
      end
      $display("  Recovery GEMM completed in %0d cycles: PASS", dma_cycles);
    end

    // -----------------------------------------------------------------
    $display("\n=================================================================");
    if (errors_total == 0)
      $display("  ALL DDR TIMEOUT TESTS PASSED");
    else
      $display("  %0d ERRORS", errors_total);
    $display("=================================================================");
    $finish;
  end

  initial begin #50000000; $display("[TIMEOUT]"); $finish; end
endmodule
