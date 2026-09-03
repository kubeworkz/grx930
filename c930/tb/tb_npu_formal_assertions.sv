// ---------------------------------------------------------------------------
// tb_npu_formal_assertions.sv
//
// Simulation-based assertion testbench for NPU DMA watchdog properties.
// Uses immediate assertions (Icarus-compatible) to verify:
//   1. Core watchdog fires within watchdog_limit cycles for hanging shapes
//   2. DDR timeout fires within DDR_TIMEOUT_CYCLES of accepted AR
//   3. No false o_error on normal completion
//   4. After o_error, DMA returns to P_IDLE within bounded time
//   5. Watchdog limit matches the formula
//
// Known-hanging shapes (from simulation): M=8, N=12, K=1
// The watchdog must catch these before the DMA hangs forever.
// ---------------------------------------------------------------------------
module tb_npu_formal_assertions;

  localparam int NUM_ROWS = 8, NUM_COLS = 8, DIN_W = 8, ACC_W = 48;
  localparam int MAX_M = 8, MAX_K = 16, MAX_N = 12;
  localparam int DDR_TIMEOUT = 1024;

  // ---- DUT wiring ----
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

  // ---- DDR model ----
  localparam int MEM_DEPTH = 16384;
  logic [7:0] mem8 [0:MEM_DEPTH-1];
  logic ddr_hang;  // when set, DDR never responds

  logic [31:0] r_addr; logic [7:0] r_len, r_beat; logic r_busy;
  int r_busy_cnt;
  assign m_axi_arready = ~r_busy;
  assign m_axi_rvalid = r_busy & ~ddr_hang;
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
        if (r_busy_cnt > 2048) begin r_busy <= 0; r_beat <= 0; end
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

  // ---- AXI-Lite CSR access ----
  localparam ADDR_CTRL   = 32'h00;
  localparam ADDR_STATUS = 32'h04;
  localparam ADDR_DIM_M  = 32'h08;
  localparam ADDR_DIM_N  = 32'h0C;
  localparam ADDR_DIM_K  = 32'h10;
  localparam ADDR_A_BASE = 32'h14;
  localparam ADDR_B_BASE = 32'h18;
  localparam ADDR_C_BASE = 32'h1C;
  localparam ADDR_PREC   = 32'h20;

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
      axi_write(ADDR_A_BASE, 32'h0000 + gemm_idx * 32'h0200);
      axi_write(ADDR_B_BASE, 32'h1000 + gemm_idx * 32'h0200);
      axi_write(ADDR_C_BASE, 32'h2000 + gemm_idx * 32'h0200);
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
        mem8[32'h0000 + gemm_idx * 32'h0200 + i] = ((seed * 7 + i * 13) % 17) - 8;
      for (int i = 0; i < k * n; i++)
        mem8[32'h1000 + gemm_idx * 32'h0200 + i] = ((seed * 11 + i * 17) % 17) - 8;
    end
  endtask

  // ---- Hierarchical references to DMA internals ----
  wire [2:0]  dma_phase         = dut.u_dma.phase;
  wire        dma_launched      = dut.u_dma.launched;
  wire        dma_watchdog_active = dut.u_dma.watchdog_active;
  wire [31:0] dma_watchdog_cnt    = dut.u_dma.watchdog_cnt;
  wire [31:0] dma_watchdog_limit  = dut.u_dma.watchdog_limit;
  wire        dma_o_core_start    = dut.u_dma.o_core_start;
  wire        dma_i_core_done     = dut.u_dma.i_core_done;
  wire [15:0] dma_i_dim_m         = dut.u_dma.i_dim_m;
  wire [15:0] dma_i_dim_n         = dut.u_dma.i_dim_n;
  wire [15:0] dma_i_dim_k         = dut.u_dma.i_dim_k;
  wire        dma_ddr_timeout_active = dut.u_dma.ddr_timeout_active;
  wire        dma_start_input       = dut.start;
  wire        dma_staging_load_a    = dut.u_dma.staging_load_a;
  wire        dma_staging_ready     = dut.u_dma.staging_ready;
  wire [31:0] dma_dk                = dut.u_dma.dk;
  wire [31:0] dma_dn                = dut.u_dma.dn;
  wire [31:0] dma_staging_total     = dut.u_dma.staging_total;
  wire [15:0] dma_staging_cnt       = dut.u_dma.staging_cnt;

  localparam [2:0] P_IDLE   = 3'd0;
  localparam [2:0] P_READ_A = 3'd1;
  localparam [2:0] P_READ_B = 3'd2;
  localparam [2:0] P_LAUNCH = 3'd3;
  localparam [2:0] P_WRITE_C= 3'd4;
  localparam [2:0] P_DONE   = 3'd5;
  localparam [2:0] P_STAGING= 3'd6;

  // =========================================================================
  int assertions_failed, assertions_passed;

  // ---- Tracking registers for immediate assertions ----
  int core_start_cycle;       // cycle when o_core_start fires
  int error_return_cycle;     // cycle when o_error first asserts
  reg  core_start_seen;       // flag: a core start has been observed
  reg  error_seen;            // flag: o_error has been observed
  reg  o_error_prev;          // previous o_error value for edge detect
  reg  watchdog_fired;        // flag: o_error due to watchdog (not DDR)
  reg  ddr_timeout_fired;     // flag: o_error due to DDR timeout
  reg  [31:0] prev_watchdog_cnt;     // previous watchdog_cnt for monotonic check
  reg         prev_ddr_timeout_active; // previous ddr_timeout_active
  reg         prev_watchdog_active;   // previous watchdog_active for monotonic gating
  reg         prev_staging_load_a;    // previous staging_load_a for edge detect

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      core_start_cycle <= 0; error_return_cycle <= 0;
      core_start_seen <= 0; error_seen <= 0;
      o_error_prev <= 0; watchdog_fired <= 0; ddr_timeout_fired <= 0;
      prev_watchdog_cnt <= 0; prev_ddr_timeout_active <= 0; prev_watchdog_active <= 0;
      prev_staging_load_a <= 1;
    end else begin
      o_error_prev <= o_error;
      prev_watchdog_cnt <= dma_watchdog_cnt;
      prev_ddr_timeout_active <= dma_ddr_timeout_active;
      prev_watchdog_active <= dma_watchdog_active;
      prev_staging_load_a <= dma_staging_load_a;

      // Track core start events
      if (dma_o_core_start && dma_launched && dma_watchdog_active) begin
        core_start_cycle <= $time / 10;
        core_start_seen <= 1;
        watchdog_fired <= 0;
        ddr_timeout_fired <= 0;
      end

      // Track o_error rising edge
      if (o_error && !o_error_prev) begin
        error_return_cycle <= $time / 10;
        error_seen <= 1;
        // Classify the error source
        if (dma_watchdog_active)
          watchdog_fired <= 1;
        else if (dma_ddr_timeout_active || prev_ddr_timeout_active)
          ddr_timeout_fired <= 1;
      end

      // Disarm tracking on normal completion
      if (o_done && !o_error && dma_i_core_done) begin
        core_start_seen <= 0;
      end
    end
  end

  // ---- ASSERTION A: When watchdog fires, it's within watchdog_limit+4 of core start ----
  wire watchdog_edge = o_error && !o_error_prev;
  wire [31:0] cycles_since_core_start = ($time / 10) - core_start_cycle;

  always @(posedge clk) begin
    if (rst_n && watchdog_edge && core_start_seen && dma_watchdog_active) begin
      if (cycles_since_core_start > dma_watchdog_limit + 4) begin
        $error("[ASSERTION A FAIL] o_error fired %0d cycles after core start, limit=%0d",
               cycles_since_core_start, dma_watchdog_limit + 4);
        assertions_failed = assertions_failed + 1;
      end
    end
  end

  // ---- ASSERTION B: On normal completion, watchdog was disarmed ----
  always @(posedge clk) begin
    if (rst_n && o_done && !o_error && dma_i_core_done) begin
      if (dma_watchdog_active) begin
        $error("[ASSERTION B FAIL] Watchdog still active on normal completion");
        assertions_failed = assertions_failed + 1;
      end
    end
  end

  // ---- ASSERTION C: After o_error, phase returns to P_IDLE within 2048 cycles ----
  wire [31:0] cycles_after_error = ($time / 10) - error_return_cycle;

  always @(posedge clk) begin
    if (rst_n && error_seen && dma_phase == P_IDLE && cycles_after_error > 0 && cycles_after_error < 2048) begin
      // PIdle reached after error — this is good, check bound
    end
    if (rst_n && error_seen && dma_phase != P_IDLE && error_return_cycle > 0) begin
      if (cycles_after_error > 2048) begin
        $error("[ASSERTION C FAIL] DMA did not return to P_IDLE within 2048 cycles of o_error");
        assertions_failed = assertions_failed + 1;
        error_seen <= 0;  // don't re-check
      end
    end
  end

  // ---- ASSERTION D: Watchdog limit matches formula when loaded in P_IDLE ----
  wire [31:0] expected_limit = dma_i_dim_m * dma_i_dim_n * dma_i_dim_k * 2 +
                               dma_i_dim_m * dma_i_dim_n * 16 + 256;

  always @(posedge clk) begin
    if (rst_n && dma_phase == P_IDLE && dma_start_input) begin
      // Check on the next cycle when the limit is loaded
      @(posedge clk);
      if (dma_watchdog_limit !== expected_limit) begin
        $error("[ASSERTION D FAIL] watchdog_limit=%0d, expected=%0d",
               dma_watchdog_limit, expected_limit);
        assertions_failed = assertions_failed + 1;
      end
    end
  end

  // ---- ASSERTION E: watchdog_cnt is monotonically decreasing while active ----
  always @(posedge clk) begin
    // Only check monotonicity when watchdog was continuously active
    // (skip the first cycle after arming, when cnt loads the limit)
    if (rst_n && dma_watchdog_active && prev_watchdog_active &&
        dma_watchdog_cnt > 1 && !dma_i_core_done) begin
      if (dma_watchdog_cnt != prev_watchdog_cnt - 1) begin
        $error("[ASSERTION E FAIL] watchdog_cnt not monotonic: %0d -> %0d",
               prev_watchdog_cnt, dma_watchdog_cnt);
        assertions_failed = assertions_failed + 1;
      end
    end
  end

  // ---- ASSERTION F: staging_total == dk*dn throughout B staging ----
  // Continuous check: while in P_STAGING with staging_load_a=0 (B phase),
  // staging_total must equal dk*dn.  The previous bug set it to
  // next_dk * next_dn (the NEXT queued GEMM's dimensions) instead.
  // We check on the cycle AFTER the A→B transition to allow the NBA
  // (staging_total <= dk*dn) to settle.
  reg staging_b_check;   // 1 cycle after A→B transition, gate the check
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      staging_b_check <= 0;
    else if (dma_phase == P_STAGING && prev_staging_load_a && !dma_staging_load_a)
      staging_b_check <= 1;   // A→B just happened, check next cycle
    else if (dma_phase != P_STAGING || dma_staging_load_a)
      staging_b_check <= 0;   // exit B staging or leave P_STAGING
  end

  always @(posedge clk) begin
    if (rst_n && staging_b_check && dma_phase == P_STAGING && !dma_staging_load_a) begin
      if (dma_staging_total !== dma_dk * dma_dn) begin
        $error("[ASSERTION F FAIL] staging_total=%0d, expected dk*dn=%0d*%0d=%0d",
               dma_staging_total, dma_dk, dma_dn, dma_dk * dma_dn);
        assertions_failed = assertions_failed + 1;
      end
    end
  end

  // ---- ASSERTION G: staging_cnt never exceeds staging_total in P_STAGING ----
  always @(posedge clk) begin
    if (rst_n && dma_phase == P_STAGING && dma_staging_cnt > dma_staging_total) begin
      $error("[ASSERTION G FAIL] staging_cnt=%0d > staging_total=%0d",
             dma_staging_cnt, dma_staging_total);
      assertions_failed = assertions_failed + 1;
    end
  end

  // =========================================================================
  // Main test sequence
  // =========================================================================
  initial begin
    $dumpfile("build/vcd/tb_npu_formal_assertions.vcd");
    $dumpvars(0, tb_npu_formal_assertions);
    for (int i = 0; i < MEM_DEPTH; i++) mem8[i] = 0;
    rst_n = 0; ddr_hang = 0;
    assertions_failed = 0;
    assertions_passed = 0;
    core_start_cycle = 0;
    error_return_cycle = 0;

    repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

    $display("=================================================================");
    $display("  NPU DMA Formal Assertion Verification (Simulation)");
    $display("=================================================================");

    // -----------------------------------------------------------------
    // TEST 1: Normal GEMM — no false o_error (Assertions B, E)
    // -----------------------------------------------------------------
    $display("\n[TEST 1] Normal GEMM: no false o_error, watchdog disarms on completion");
    begin : test1
      int dma_cycles;
      fill_gemm(4, 4, 8, 0, 100);
      submit_gemm(4, 4, 8, 0);
      // Wait for completion
      dma_cycles = 0;
      while (o_busy && dma_cycles < 50000) begin
        @(posedge clk); dma_cycles = dma_cycles + 1;
      end
      if (o_error) begin
        $display("  [FAIL] False o_error on normal GEMM (Assertion B)");
        assertions_failed = assertions_failed + 1;
      end else begin
        $display("  [PASS] Normal GEMM completed in %0d cycles, no false error", dma_cycles);
        assertions_passed = assertions_passed + 1;
      end
    end

    // -----------------------------------------------------------------
    // TEST 2: Shape M=8 N=12 K=1 — check watchdog fires OR core completes
    //         If the core hangs, watchdog fires within watchdog_limit+4.
    //         If the core completes normally, no false o_error.
    // -----------------------------------------------------------------
    $display("\n[TEST 2] Shape M=8 N=12 K=1: verify watchdog bound");
    begin : test2
      int expected_limit;
      int cycles_to_complete;

      expected_limit = 8 * 12 * 1 * 2 + 8 * 12 * 16 + 256;  // = 2048
      core_start_cycle = 0;  // reset tracking
      error_seen = 0;

      fill_gemm(8, 12, 1, 0, 200);
      submit_gemm(8, 12, 1, 0);

      // Wait for completion (o_busy goes low) OR error
      cycles_to_complete = 0;
      while (o_busy && !o_error && cycles_to_complete < expected_limit + 500) begin
        @(posedge clk); cycles_to_complete = cycles_to_complete + 1;
      end

      if (o_error) begin
        $display("  [PASS] Watchdog fired after %0d cycles (limit=%0d)",
                 cycles_to_complete, expected_limit);
        if (cycles_to_complete <= expected_limit + 4) begin
          $display("  [PASS] Within watchdog_limit+4 bound (Assertion A)");
          assertions_passed = assertions_passed + 1;
        end else begin
          $display("  [FAIL] Exceeded watchdog_limit+4 bound (Assertion A)");
          assertions_failed = assertions_failed + 1;
        end
        repeat(64) @(posedge clk);
      end else if (!o_busy) begin
        $display("  [PASS] Engine completed normally in %0d cycles (no hang)", cycles_to_complete);
        assertions_passed = assertions_passed + 1;
      end else begin
        $display("  [FAIL] Engine still busy after %0d cycles", cycles_to_complete);
        assertions_failed = assertions_failed + 1;
      end

      if (dma_phase != P_IDLE) begin
        $display("  [FAIL] DMA not in P_IDLE");
        assertions_failed = assertions_failed + 1;
      end else begin
        $display("  [PASS] DMA in P_IDLE");
        assertions_passed = assertions_passed + 1;
      end

      begin : clear_err2
        logic [31:0] status;
        axi_read(ADDR_STATUS, status);
      end
    end

    // -----------------------------------------------------------------
    // TEST 3: Recovery GEMM after watchdog timeout
    // -----------------------------------------------------------------
    $display("\n[TEST 3] Recovery: normal GEMM after watchdog timeout");
    begin : test3
      int dma_cycles;
      fill_gemm(2, 3, 4, 0, 300);
      submit_gemm(2, 3, 4, 0);
      dma_cycles = 0;
      while (o_busy && dma_cycles < 50000) begin
        @(posedge clk); dma_cycles = dma_cycles + 1;
      end
      if (o_error) begin
        $display("  [FAIL] o_error on recovery GEMM");
        assertions_failed = assertions_failed + 1;
      end else begin
        $display("  [PASS] Recovery GEMM completed in %0d cycles", dma_cycles);
        assertions_passed = assertions_passed + 1;
      end
    end

    // -----------------------------------------------------------------
    // TEST 4: Shape M=8 N=8 K=1 — check watchdog fires OR core completes
    // -----------------------------------------------------------------
    $display("\n[TEST 4] Shape M=8 N=8 K=1: verify watchdog bound");
    begin : test4
      int expected_limit;
      int cycles_to_complete;

      expected_limit = 8 * 8 * 1 * 2 + 8 * 8 * 16 + 256;  // = 1408
      core_start_cycle = 0;
      error_seen = 0;

      fill_gemm(8, 8, 1, 0, 400);
      submit_gemm(8, 8, 1, 0);

      cycles_to_complete = 0;
      while (o_busy && !o_error && cycles_to_complete < expected_limit + 500) begin
        @(posedge clk); cycles_to_complete = cycles_to_complete + 1;
      end

      if (o_error) begin
        $display("  [PASS] Watchdog fired after %0d cycles (limit=%0d)",
                 cycles_to_complete, expected_limit);
        if (cycles_to_complete <= expected_limit + 4) begin
          $display("  [PASS] Within watchdog_limit+4 bound (Assertion A)");
          assertions_passed = assertions_passed + 1;
        end else begin
          $display("  [FAIL] Exceeded watchdog_limit+4 bound (Assertion A)");
          assertions_failed = assertions_failed + 1;
        end
        repeat(64) @(posedge clk);
      end else if (!o_busy) begin
        $display("  [PASS] Engine completed normally in %0d cycles (no hang)", cycles_to_complete);
        assertions_passed = assertions_passed + 1;
      end else begin
        $display("  [FAIL] Engine still busy after %0d cycles", cycles_to_complete);
        assertions_failed = assertions_failed + 1;
      end

      repeat(16) @(posedge clk);
      begin : clear_err4
        logic [31:0] status;
        axi_read(ADDR_STATUS, status);
      end
    end

    // -----------------------------------------------------------------
    // TEST 5: DDR timeout — o_error within DDR_TIMEOUT_CYCLES
    // -----------------------------------------------------------------
    $display("\n[TEST 5] DDR timeout: o_error within %0d cycles", DDR_TIMEOUT);
    begin : test5
      int cycles_before_error;
      ddr_hang = 1;

      core_start_cycle = 0;
      fill_gemm(4, 4, 8, 0, 500);
      submit_gemm(4, 4, 8, 0);

      cycles_before_error = 0;
      while (!o_error && cycles_before_error < DDR_TIMEOUT + 200) begin
        @(posedge clk); cycles_before_error = cycles_before_error + 1;
      end

      if (!o_error) begin
        $display("  [FAIL] DDR timeout o_error never fired");
        assertions_failed = assertions_failed + 1;
      end else begin
        $display("  [PASS] DDR timeout o_error fired after %0d cycles (limit=%0d)",
                 cycles_before_error, DDR_TIMEOUT);
        assertions_passed = assertions_passed + 1;
      end

      ddr_hang = 0;
      repeat(3000) @(posedge clk);
      if (dma_phase != P_IDLE) begin
        $display("  [FAIL] DMA not in P_IDLE after DDR timeout");
        assertions_failed = assertions_failed + 1;
      end else begin
        $display("  [PASS] DMA returned to P_IDLE after DDR timeout");
        assertions_passed = assertions_passed + 1;
      end
    end

    // -----------------------------------------------------------------
    // TEST 6: Multi-GEMM back-to-back — exercises P_STAGING path
    // Verifies staging_total == dk*dn (Assertion F) across queued GEMMs.
    // Uses M=8 to give PF2 enough P_WRITE_C time to complete.
    // -----------------------------------------------------------------
    $display("\n[TEST 6] Multi-GEMM back-to-back: staging_total invariant");
    begin : test6
      int dma_cycles;
      // M=8 gives ~32-beat P_WRITE_C, enough for PF2 to prefetch
      // the next GEMM's A+B (typically <16 beats).
      fill_gemm(8, 8, 8, 0, 600);
      fill_gemm(4, 4, 16, 1, 700);
      fill_gemm(2, 6, 8, 2, 800);
      submit_gemm(8, 8, 8, 0);
      submit_gemm(4, 4, 16, 1);
      submit_gemm(2, 6, 8, 2);
      dma_cycles = 0;
      while (o_busy && dma_cycles < 200000) begin
        @(posedge clk); dma_cycles = dma_cycles + 1;
      end
      if (o_error) begin
        $display("  [FAIL] o_error during multi-GEMM staging");
        assertions_failed = assertions_failed + 1;
      end else begin
        $display("  [PASS] Multi-GEMM completed in %0d cycles, staging invariant held", dma_cycles);
        assertions_passed = assertions_passed + 1;
      end
    end

    // -----------------------------------------------------------------
    // TEST 7: Large→small shape sequence — the original bug scenario
    // GEMM0 (large M for long P_WRITE_C) → GEMM1 (tiny) → GEMM2
    // The original bug: staging_total = next_dk*next_dn instead of dk*dn
    // -----------------------------------------------------------------
    $display("\n[TEST 7] Large→small shape: staging_total with shrinking GEMMs");
    begin : test7
      int dma_cycles;
      fill_gemm(8, 8, 8, 0, 900);
      fill_gemm(2, 3, 16, 1, 1000);
      fill_gemm(4, 4, 8, 2, 1100);
      submit_gemm(8, 8, 8, 0);
      submit_gemm(2, 3, 16, 1);
      submit_gemm(4, 4, 8, 2);
      dma_cycles = 0;
      while (o_busy && dma_cycles < 200000) begin
        @(posedge clk); dma_cycles = dma_cycles + 1;
      end
      if (o_error) begin
        $display("  [FAIL] o_error during large→small staging");
        assertions_failed = assertions_failed + 1;
      end else begin
        $display("  [PASS] Large→small completed in %0d cycles, staging invariant held", dma_cycles);
        assertions_passed = assertions_passed + 1;
      end
    end

    // -----------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------
    $display("\n=================================================================");
    $display("  ASSERTION SUMMARY");
    $display("    Assertions passed: %0d", assertions_passed);
    $display("    Assertions failed: %0d", assertions_failed);
    if (assertions_failed == 0)
      $display("  ALL ASSERTIONS PASSED");
    else
      $display("  %0d ASSERTIONS FAILED", assertions_failed);
    $display("=================================================================");
    $finish;
  end

  initial begin #50000000; $display("[TIMEOUT]"); $finish; end
endmodule
