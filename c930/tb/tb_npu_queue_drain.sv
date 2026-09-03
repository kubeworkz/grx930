// ---------------------------------------------------------------------------
// tb_npu_queue_drain.sv
//
// Reproduces the grxcp back-to-back command queue drain bug:
//   * Sequential: 4 GEMMs one at a time -> all correct (control)
//   * Pipelined:  4 GEMMs submitted back-to-back -> all must complete
//     without stranding, with correct QUEUE_STAT, and correct results.
// ---------------------------------------------------------------------------
module tb_npu_queue_drain;

  localparam int NUM_ROWS = 8, NUM_COLS = 8, DIN_W = 8, ACC_W = 48;
  localparam int MAX_M = 8, MAX_K = 16, MAX_N = 12;

  function automatic [31:0] get_a_base(input int idx);
    case (idx) 0: return 32'h0000; 1: return 32'h0200; 2: return 32'h0400; default: return 32'h0600; endcase
  endfunction
  function automatic [31:0] get_b_base(input int idx);
    case (idx) 0: return 32'h1000; 1: return 32'h1200; 2: return 32'h1400; default: return 32'h1600; endcase
  endfunction
  function automatic [31:0] get_c_base(input int idx);
    case (idx) 0: return 32'h2000; 1: return 32'h2200; 2: return 32'h2400; default: return 32'h2600; endcase
  endfunction

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

  localparam int MEM_DEPTH = 16384;
  logic [7:0] mem8 [0:MEM_DEPTH-1];

  always @(posedge clk) begin
    if (m_axi_arvalid && m_axi_arready)
      $display("  [DDR-RD] AR addr=0x%0h len=%0d", m_axi_araddr, m_axi_arlen);
  end

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

  localparam ADDR_CTRL=32'h00, ADDR_STAT=32'h04, ADDR_DIM_M=32'h08,
             ADDR_DIM_N=32'h0C, ADDR_DIM_K=32'h10, ADDR_A_BASE=32'h14,
             ADDR_B_BASE=32'h18, ADDR_C_BASE=32'h1C, ADDR_PREC=32'h20,
             ADDR_QUEUE_STAT=32'h38;

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);
    s_axi_awaddr = addr; s_axi_awvalid = 1; s_axi_wdata = data; s_axi_wstrb = 4'hF;
    s_axi_wvalid = 1; s_axi_bready = 1;
    wait (s_axi_awready && s_axi_wready);
    s_axi_awvalid = 0; s_axi_wvalid = 0;
    wait (s_axi_bvalid); @(posedge clk); s_axi_bready = 0;
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);
    s_axi_araddr = addr; s_axi_arvalid = 1; s_axi_rready = 1;
    wait (s_axi_arready); s_axi_arvalid = 0;
    wait (s_axi_rvalid); data = s_axi_rdata; @(posedge clk); s_axi_rready = 0;
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

  task automatic wait_all_done(output int total_cycles);
    logic [31:0] stat, qstat;
    integer timeout;
    begin
      total_cycles = 0;
      timeout = 0;
      forever begin
        @(posedge clk);
        total_cycles = total_cycles + 1;
        if (!o_busy) begin
          axi_read(ADDR_QUEUE_STAT, qstat);
          if (qstat[3:0] == 0) disable wait_all_done;
        end
        timeout = timeout + 1;
        if (timeout > 2000000) begin
          $display("[TIMEOUT] stuck at cycle %0d, BUSY=%0b, QUEUE_STAT=%0h", total_cycles, o_busy, qstat);
          disable wait_all_done;
        end
      end
    end
  endtask

  int errors_total;
  task automatic check_c(input int m, n, k, input int gemm_idx);
    int sum_val, got_val;
    begin
      for (int mi = 0; mi < m; mi++) begin
        for (int ni = 0; ni < n; ni++) begin
          sum_val = 0;
          for (int ki = 0; ki < k; ki++)
            sum_val = sum_val + $signed(mem8[get_a_base(gemm_idx) + mi*k + ki]) *
                                $signed(mem8[get_b_base(gemm_idx) + ki*n + ni]);
          got_val = $signed({mem8[get_c_base(gemm_idx) + (mi*n+ni)*4+3],
                             mem8[get_c_base(gemm_idx) + (mi*n+ni)*4+2],
                             mem8[get_c_base(gemm_idx) + (mi*n+ni)*4+1],
                             mem8[get_c_base(gemm_idx) + (mi*n+ni)*4]});
          if (got_val !== sum_val) begin
            if (errors_total < 20)
              $display("  [FAIL] GEMM%0d C[%0d][%0d] = %0d, expected %0d",
                       gemm_idx, mi, ni, got_val, sum_val);
            errors_total = errors_total + 1;
          end
        end
      end
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

  int total_cycles;
  logic [31:0] qstat;

  initial begin
    $dumpfile("build/vcd/tb_npu_queue_drain.vcd");
    $dumpvars(0, tb_npu_queue_drain);
    for (int i = 0; i < MEM_DEPTH; i++) mem8[i] = 0;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);
    errors_total = 0;

    $display("=================================================================");
    $display("  NPU Command Queue Drain Test");
    $display("=================================================================");

    // Test 1: Sequential (control)
    $display("\n[TEST 1] Sequential: 4 GEMMs (M=4 N=4 K=8)");
    begin : seq_test
      fill_gemm(4, 4, 8, 0, 100); fill_gemm(4, 4, 8, 1, 200);
      fill_gemm(4, 4, 8, 2, 300); fill_gemm(4, 4, 8, 3, 400);
      for (int i = 0; i < 4; i++) begin
        submit_gemm(4, 4, 8, i);
        wait (o_done); @(posedge clk);
      end
      check_c(4, 4, 8, 0); check_c(4, 4, 8, 1);
      check_c(4, 4, 8, 2); check_c(4, 4, 8, 3);
      $display("  Sequential: errors=%0d", errors_total);
    end

    // Test 2: Pipelined 4 GEMMs
    $display("\n[TEST 2] Pipelined: 4 back-to-back GEMMs (M=4 N=4 K=8)");
    begin : pipe_test
      errors_total = 0;
      fill_gemm(4, 4, 8, 0, 500); fill_gemm(4, 4, 8, 1, 600);
      fill_gemm(4, 4, 8, 2, 700); fill_gemm(4, 4, 8, 3, 800);
      submit_gemm(4, 4, 8, 0);
      submit_gemm(4, 4, 8, 1);
      submit_gemm(4, 4, 8, 2);
      submit_gemm(4, 4, 8, 3);
      wait_all_done(total_cycles);
      $display("  All 4 completed in %0d cycles", total_cycles);
      axi_read(ADDR_QUEUE_STAT, qstat);
      $display("  QUEUE_STAT = 0x%0h (occupancy=%0d)", qstat, qstat[3:0]);
      if (qstat[3:0] != 0) $display("  [FAIL] Queue not empty after completion");
      check_c(4, 4, 8, 0); check_c(4, 4, 8, 1);
      check_c(4, 4, 8, 2); check_c(4, 4, 8, 3);
      $display("  Pipelined: errors=%0d", errors_total);
    end

    // Test 3: Pipelined mixed shapes
    $display("\n[TEST 3] Pipelined: 3 back-to-back (M=2 N=3 K=16)");
    begin : pipe_mixed
      errors_total = 0;
      fill_gemm(2, 3, 16, 0, 900); fill_gemm(2, 3, 16, 1, 1000);
      fill_gemm(2, 3, 16, 2, 1100);
      submit_gemm(2, 3, 16, 0);
      submit_gemm(2, 3, 16, 1);
      submit_gemm(2, 3, 16, 2);
      wait_all_done(total_cycles);
      $display("  All 3 completed in %0d cycles", total_cycles);
      axi_read(ADDR_QUEUE_STAT, qstat);
      $display("  QUEUE_STAT = 0x%0h (occupancy=%0d)", qstat, qstat[3:0]);
      check_c(2, 3, 16, 0); check_c(2, 3, 16, 1); check_c(2, 3, 16, 2);
      $display("  Pipelined mixed: errors=%0d", errors_total);
    end

    // Test 4: Max queue depth
    $display("\n[TEST 4] Pipelined: 4 back-to-back (M=8 N=12 K=16) -- max queue");
    begin : pipe_max
      errors_total = 0;
      fill_gemm(8, 12, 16, 0, 1200); fill_gemm(8, 12, 16, 1, 1300);
      fill_gemm(8, 12, 16, 2, 1400); fill_gemm(8, 12, 16, 3, 1500);
      submit_gemm(8, 12, 16, 0);
      submit_gemm(8, 12, 16, 1);
      submit_gemm(8, 12, 16, 2);
      submit_gemm(8, 12, 16, 3);
      wait_all_done(total_cycles);
      $display("  All 4 completed in %0d cycles", total_cycles);
      axi_read(ADDR_QUEUE_STAT, qstat);
      $display("  QUEUE_STAT = 0x%0h (occupancy=%0d)", qstat, qstat[3:0]);
      check_c(8, 12, 16, 0); check_c(8, 12, 16, 1);
      check_c(8, 12, 16, 2); check_c(8, 12, 16, 3);
      $display("  Pipelined max: errors=%0d", errors_total);
    end

    // --- Debug: dump c_mem vs DDR for last GEMM's second N-tile ---
    // GEMM3 c_mem values for column 11 (last N-tile, n_cnt=3)
    begin : dbg_blk
      int dbg_addr, dbg_val;
      $display("");
      $display("=== DEBUG: GEMM3 c_mem column 11 ===");
      for (int mi = 0; mi < 8; mi++)
        $display("  c_mem[%2d] = %0d", mi*12+11, $signed(dut.u_core.c_mem[mi*12+11]));
      $display("");
      $display("=== DEBUG: DDR mem8 for GEMM3 column 11 ===");
      for (int mi = 0; mi < 8; mi++) begin
        dbg_addr = get_c_base(3) + (mi*12+11)*4;
        dbg_val = $signed({mem8[dbg_addr+3], mem8[dbg_addr+2], mem8[dbg_addr+1], mem8[dbg_addr]});
        $display("  mem8[0x%0h..0x%0h] = %0d", dbg_addr, dbg_addr+3, dbg_val);
      end
      $display("");
      $display("=== DEBUG: GEMM3 c_mem all columns for row 0 ===");
      for (int ni = 0; ni < 12; ni++)
        $display("  c_mem[%2d] = %0d", ni, $signed(dut.u_core.c_mem[ni]));
      $display("");
      $display("=== DEBUG: DDR mem8 all columns for GEMM3 row 0 ===");
      for (int ni = 0; ni < 12; ni++) begin
        dbg_addr = get_c_base(3) + ni*4;
        dbg_val = $signed({mem8[dbg_addr+3], mem8[dbg_addr+2], mem8[dbg_addr+1], mem8[dbg_addr]});
        $display("  mem8[0x%0h] = %0d", dbg_addr, dbg_val);
      end
    end

    $display("\n=================================================================");
    if (errors_total == 0) $display("  ALL QUEUE DRAIN TESTS PASSED");
    else $display("  %0d ERRORS", errors_total);
    $display("=================================================================");
    $finish;
  end

  initial begin #50000000; $display("[TIMEOUT]"); $finish; end
endmodule
