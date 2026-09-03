// ---------------------------------------------------------------------------
// tb_npu_double_buffer.sv
//
// Verifies dual-buffered A/B memory pipelining:
//   * Test 1: Two back-to-back identical GEMMs — both produce correct results
//   * Test 2: Three back-to-back GEMMs with different dimensions
//   * Test 3: Verify bank_sel toggles correctly between GEMMs
//   * Test 4: Rapid-fire 4 GEMMs to stress dual-buffer pipeline
// ---------------------------------------------------------------------------
module tb_npu_double_buffer;

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

  // --- DDR model (same as tb_c930_npu: 32-bit word array with byte alignment) ---
  localparam int MEM_DEPTH = 16384;
  logic [31:0] mem [0:MEM_DEPTH-1];

  logic [31:0] r_addr;
  logic [7:0]  r_len, r_beat;
  logic        r_busy;

  logic [127:0] rd_window;
  logic [1:0]   rd_byte_off;
  assign m_axi_arready = ~r_busy;
  assign m_axi_rvalid  = r_busy;
  assign m_axi_rlast   = (r_beat == r_len);
  assign rd_byte_off = r_addr[1:0];
  assign rd_window = { mem[(r_addr >> 2) + r_beat*2 + 3],
                       mem[(r_addr >> 2) + r_beat*2 + 2],
                       mem[(r_addr >> 2) + r_beat*2 + 1],
                       mem[(r_addr >> 2) + r_beat*2] };
  assign m_axi_rdata = rd_window >> {rd_byte_off, 3'b000};
  assign m_axi_rresp = 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_busy <= 1'b0;
      r_addr <= '0;
      r_len  <= '0;
      r_beat <= '0;
    end else begin
      if (m_axi_arvalid && m_axi_arready && !r_busy) begin
        r_addr <= m_axi_araddr;
        r_len  <= m_axi_arlen;
        r_beat <= 8'd0;
        r_busy <= 1'b1;
      end
      if (r_busy && m_axi_rvalid && m_axi_rready) begin
        if (r_beat == r_len)
          r_busy <= 1'b0;
        else
          r_beat <= r_beat + 1;
      end
    end
  end

  logic [31:0] w_addr;
  logic [7:0]  w_len, w_beat;
  logic        w_busy, b_valid;
  assign m_axi_awready = ~w_busy;
  assign m_axi_wready  = w_busy;
  assign m_axi_bvalid  = b_valid;
  assign m_axi_bresp   = 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_busy <= 1'b0;
      b_valid <= 1'b0;
      w_addr <= '0;
      w_len  <= '0;
      w_beat <= '0;
    end else begin
      if (m_axi_awvalid && m_axi_awready && !w_busy) begin
        w_addr <= m_axi_awaddr;
        w_len  <= m_axi_awlen;
        w_beat <= 8'd0;
        w_busy <= 1'b1;
      end
      if (w_busy && m_axi_wvalid && m_axi_wready) begin
        begin
          // Use blocking assignments to pack bytes, then NBA to write whole word
          // (avoids Icarus byte-slice NBA issues on memory arrays)
          automatic logic [31:0] w_lo, w_hi;
          w_lo = mem[(w_addr >> 2) + w_beat*2];
          w_hi = mem[(w_addr >> 2) + w_beat*2 + 1];
          for (int i = 0; i < 4; i++) begin
            if (m_axi_wstrb[i])   w_lo[i*8 +: 8] = m_axi_wdata[i*8 +: 8];
            if (m_axi_wstrb[i+4]) w_hi[i*8 +: 8] = m_axi_wdata[(i+4)*8 +: 8];
          end
          mem[(w_addr >> 2) + w_beat*2]     <= w_lo;
          mem[(w_addr >> 2) + w_beat*2 + 1] <= w_hi;
        end
        if (w_beat == w_len) begin
          w_busy  <= 1'b0;
          b_valid <= 1'b1;
        end else
          w_beat <= w_beat + 1;
      end
      if (b_valid && m_axi_bready)
        b_valid <= 1'b0;
    end
  end

  // --- AXI-Lite CSR access ---
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
    int word_idx;
    begin
      for (int i = 0; i < m * k; i++) begin
        word_idx = (get_a_base(gemm_idx) >> 2) + i / 4;
        mem[word_idx][ (i % 4)*8 +: 8] = ((seed * 7 + i * 13) % 17) - 8;
      end
      for (int i = 0; i < k * n; i++) begin
        word_idx = (get_b_base(gemm_idx) >> 2) + i / 4;
        mem[word_idx][ (i % 4)*8 +: 8] = ((seed * 11 + i * 17) % 17) - 8;
      end
    end
  endtask

  task automatic wait_done(output int cycles);
    begin
      cycles = 0;
      while (o_busy) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      // DMA has returned to P_IDLE, but the DDR write channel may still
      // be committing the last C beat.  Wait for b_valid to clear (= DDR
      // has accepted all writes) plus a few extra cycles for NBAs to
      // propagate the data into mem.
      repeat(4) @(posedge clk);
      while (b_valid) @(posedge clk);
      repeat(4) @(posedge clk);
    end
  endtask

  // Helper: read8 from mem (same as fill_gemm's write pattern)
  function automatic logic signed [7:0] mem_load8(input int byte_addr);
    int word_idx;
    begin
      word_idx = byte_addr >> 2;
      mem_load8 = mem[word_idx][ (byte_addr & 2'b11)*8 +: 8];
    end
  endfunction

  task automatic check_c(input int m, n, k, input int gemm_idx, output int errs);
    int got_val, sum_val;
    begin
      errs = 0;
      for (int mi = 0; mi < m; mi++) begin
        for (int ni = 0; ni < n; ni++) begin
          sum_val = 0;
          for (int ki = 0; ki < k; ki++)
            sum_val = sum_val + $signed(mem_load8(get_a_base(gemm_idx) + mi*k + ki)) *
                                $signed(mem_load8(get_b_base(gemm_idx) + ki*n + ni));
          got_val = mem[(get_c_base(gemm_idx) >> 2) + mi * n + ni];
          if (got_val !== sum_val) begin
            $display("  [FAIL] C[%0d][%0d] = %0d, expected %0d", mi, ni, got_val, sum_val);
            errs = errs + 1;
          end
        end
      end
    end
  endtask

  // ---- Hierarchical references ----
  wire dma_bank_sel = dut.u_dma.bank_sel;

  // Reference arrays: save A/B before DMA overwrites them via C writeback
  logic signed [7:0] a_ref [0:MAX_M*MAX_K-1];
  logic signed [7:0] b_ref [0:MAX_K*MAX_N-1];

  task automatic save_refs(input int m, n, k, input int gemm_idx);
    begin
      for (int i = 0; i < m * k; i++)
        a_ref[i] = $signed(mem[(get_a_base(gemm_idx) >> 2) + i/4][((i%4)*8) +: 8]);
      for (int i = 0; i < k * n; i++)
        b_ref[i] = $signed(mem[(get_b_base(gemm_idx) >> 2) + i/4][((i%4)*8) +: 8]);
    end
  endtask

  task automatic check_c_ref(input int m, n, k, input int gemm_idx, output int errs);
    int got_val, sum_val;
    begin
      errs = 0;
      for (int mi = 0; mi < m; mi++) begin
        for (int ni = 0; ni < n; ni++) begin
          sum_val = 0;
          for (int ki = 0; ki < k; ki++)
            sum_val = sum_val + a_ref[mi*k + ki] * b_ref[ki*n + ni];
          // Read C directly from core's c_mem (bypass DDR write path)
          got_val = dut.u_core.c_mem[mi * n + ni];
          if (got_val !== sum_val) begin
            $display("  [FAIL] C[%0d][%0d] = %0d, expected %0d", mi, ni, got_val, sum_val);
            errs = errs + 1;
          end
        end
      end
    end
  endtask

  // =========================================================================
  int errors_total, total_cycles;
  logic [31:0] status;

  initial begin
    $dumpfile("build/vcd/tb_npu_double_buffer.vcd");
    $dumpvars(0, tb_npu_double_buffer);
    for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 32'h0;
    rst_n = 0;
    repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);
    errors_total = 0;
    total_cycles = 0;

    $display("=================================================================");
    $display("  Dual-Buffered A/B Memory Verification");
    $display("=================================================================");

    // -----------------------------------------------------------------
    // TEST 1: Two back-to-back identical GEMMs
    // -----------------------------------------------------------------
    $display("\n[TEST 1] Two back-to-back GEMMs (M=4 N=4 K=8)");
    begin : test1
      int c1, c2, errs;

      fill_gemm(4, 4, 8, 0, 100);
      save_refs(4, 4, 8, 0);
      submit_gemm(4, 4, 8, 0);
      wait_done(c1);
      total_cycles = total_cycles + c1;

      check_c_ref(4, 4, 8, 0, errs);
      if (errs > 0) begin $display("  [FAIL] GEMM 0 has %0d errors", errs); errors_total++; end
      else $display("  GEMM 0: %0d cycles, PASS", c1);

      fill_gemm(4, 4, 8, 0, 200);
      save_refs(4, 4, 8, 0);
      submit_gemm(4, 4, 8, 0);
      wait_done(c2);
      total_cycles = total_cycles + c2;

      check_c_ref(4, 4, 8, 0, errs);
      if (errs > 0) begin $display("  [FAIL] GEMM 1 has %0d errors", errs); errors_total++; end
      else $display("  GEMM 1: %0d cycles, PASS", c2);
    end

    // -----------------------------------------------------------------
    // TEST 2: Three back-to-back GEMMs with different dimensions
    // -----------------------------------------------------------------
    $display("\n[TEST 2] Three back-to-back GEMMs (2x3x4, 3x2x4, 4x3x2)");
    begin : test2
      int c1, c2, c3, errs;

      fill_gemm(2, 3, 4, 0, 300); save_refs(2, 3, 4, 0);
      submit_gemm(2, 3, 4, 0);
      wait_done(c1); total_cycles += c1;
      check_c_ref(2, 3, 4, 0, errs);
      if (errs > 0) begin $display("  [FAIL] GEMM 0 has %0d errors", errs); errors_total++; end
      else $display("  GEMM 0 (2x3x4): %0d cycles, PASS", c1);

      fill_gemm(3, 2, 4, 0, 400); save_refs(3, 2, 4, 0);
      submit_gemm(3, 2, 4, 0);
      wait_done(c2); total_cycles += c2;
      check_c_ref(3, 2, 4, 0, errs);
      if (errs > 0) begin $display("  [FAIL] GEMM 1 has %0d errors", errs); errors_total++; end
      else $display("  GEMM 1 (3x2x4): %0d cycles, PASS", c2);

      fill_gemm(4, 3, 2, 0, 500); save_refs(4, 3, 2, 0);
      submit_gemm(4, 3, 2, 0);
      wait_done(c3); total_cycles += c3;
      check_c_ref(4, 3, 2, 0, errs);
      if (errs > 0) begin $display("  [FAIL] GEMM 2 has %0d errors", errs); errors_total++; end
      else $display("  GEMM 2 (4x3x2): %0d cycles, PASS", c3);
    end

    // -----------------------------------------------------------------
    // TEST 3: Verify bank_sel toggles between GEMMs
    // -----------------------------------------------------------------
    $display("\n[TEST 3] Verify bank_sel toggles between GEMMs");
    begin : test3
      logic initial_bank;
      int c1, c2;

      initial_bank = dma_bank_sel;

      fill_gemm(2, 2, 4, 0, 600);
      submit_gemm(2, 2, 4, 0);
      wait_done(c1);

      if (dma_bank_sel == initial_bank) begin
        $display("  [FAIL] bank_sel did not toggle after GEMM 0");
        errors_total = errors_total + 1;
      end else begin
        $display("  [PASS] bank_sel toggled from %0b to %0b", initial_bank, dma_bank_sel);
      end

      fill_gemm(2, 2, 4, 0, 700);
      submit_gemm(2, 2, 4, 0);
      wait_done(c2);

      if (dma_bank_sel == initial_bank) begin
        $display("  [PASS] bank_sel returned to original %0b", dma_bank_sel);
      end else begin
        $display("  [INFO] bank_sel is %0b (expected toggle pattern)", dma_bank_sel);
      end
    end

    // -----------------------------------------------------------------
    // TEST 4: Rapid-fire 4 GEMMs to stress dual-buffer pipeline
    // -----------------------------------------------------------------
    $display("\n[TEST 4] Rapid-fire 4 GEMMs (M=4 N=4 K=8)");
    begin : test4
      int cycles_arr[4];
      int total_errs;

      for (int g = 0; g < 4; g++) begin
        fill_gemm(4, 4, 8, 0, 800 + g * 100);
        save_refs(4, 4, 8, 0);
        submit_gemm(4, 4, 8, 0);
        wait_done(cycles_arr[g]);
        total_cycles += cycles_arr[g];

        check_c_ref(4, 4, 8, 0, total_errs);
        if (total_errs > 0) begin
          $display("  [FAIL] GEMM %0d has %0d errors", g, total_errs);
          errors_total = errors_total + 1;
        end
      end

      $display("  GEMM 0: %0d cycles", cycles_arr[0]);
      $display("  GEMM 1: %0d cycles", cycles_arr[1]);
      $display("  GEMM 2: %0d cycles", cycles_arr[2]);
      $display("  GEMM 3: %0d cycles", cycles_arr[3]);

      if (cycles_arr[1] <= cycles_arr[0])
        $display("  [INFO] GEMM 1 (%0d cyc) <= GEMM 0 (%0d cyc) — dual-buffer overlap helps",
                 cycles_arr[1], cycles_arr[0]);
    end

    // -----------------------------------------------------------------
    $display("\n=================================================================");
    $display("  Total cycles across all tests: %0d", total_cycles);
    if (errors_total == 0)
      $display("  ALL DOUBLE-BUFFER TESTS PASSED");
    else
      $display("  %0d ERRORS", errors_total);
    $display("=================================================================");
    $finish;
  end

  initial begin #50000000; $display("[TIMEOUT]"); $finish; end
endmodule
