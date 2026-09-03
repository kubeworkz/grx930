// ---------------------------------------------------------------------------
// tb_npu_small_n_pipelined.sv
//
// Reproduces the N < NUM_COLS pipelined edge case where columns 1..nc-1
// get wrong values when 2+ GEMMs are pipelined with N < NUM_COLS.
// ---------------------------------------------------------------------------
module tb_npu_small_n_pipelined;

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

  localparam ADDR_CTRL=32'h00, ADDR_DIM_M=32'h08, ADDR_DIM_N=32'h0C,
             ADDR_DIM_K=32'h10, ADDR_A_BASE=32'h14, ADDR_B_BASE=32'h18,
             ADDR_C_BASE=32'h1C, ADDR_PREC=32'h20, ADDR_QUEUE_STAT=32'h38;

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
    logic [31:0] qstat;
    integer timeout;
    begin
      total_cycles = 0; timeout = 0;
      forever begin
        @(posedge clk); total_cycles = total_cycles + 1;
        if (!o_busy) begin
          axi_read(ADDR_QUEUE_STAT, qstat);
          if (qstat[3:0] == 0) disable wait_all_done;
        end
        timeout = timeout + 1;
        if (timeout > 2000000) begin
          $display("[TIMEOUT]"); disable wait_all_done;
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

  initial begin
    $dumpfile("build/vcd/tb_npu_small_n_pipelined.vcd");
    $dumpvars(0, tb_npu_small_n_pipelined);
    for (int i = 0; i < MEM_DEPTH; i++) mem8[i] = 0;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);
    errors_total = 0;

    $display("=================================================================");
    $display("  Small-N Pipelined Test");
    $display("=================================================================");

    // Test 1: Sequential (control) - M=2 N=3 K=16
    $display("\n[Test 1] Sequential: 2 GEMMs (M=2 N=3 K=16)");
    begin : seq_test
      fill_gemm(2, 3, 16, 0, 100); fill_gemm(2, 3, 16, 1, 200);
      for (int i = 0; i < 2; i++) begin
        submit_gemm(2, 3, 16, i);
        wait (o_done); @(posedge clk);
      end
      check_c(2, 3, 16, 0); check_c(2, 3, 16, 1);
      $display("  Sequential: errors=%0d", errors_total);
    end

    // Test 2: Pipelined - 2 GEMMs with N=3 back-to-back
    $display("\n[Test 2] Pipelined: 2 back-to-back (M=2 N=3 K=16)");
    begin : pipe_test
      errors_total = 0;
      fill_gemm(2, 3, 16, 0, 300); fill_gemm(2, 3, 16, 1, 400);
      submit_gemm(2, 3, 16, 0);
      submit_gemm(2, 3, 16, 1);
      wait_all_done(total_cycles);
      $display("  All completed in %0d cycles", total_cycles);
      check_c(2, 3, 16, 0); check_c(2, 3, 16, 1);
      $display("  Pipelined 2-GEMM: errors=%0d", errors_total);
    end

    // Test 3: Pipelined - 3 GEMMs with N=3
    $display("\n[Test 3] Pipelined: 3 back-to-back (M=2 N=3 K=16)");
    begin : pipe3_test
      errors_total = 0;
      fill_gemm(2, 3, 16, 0, 500); fill_gemm(2, 3, 16, 1, 600);
      fill_gemm(2, 3, 16, 2, 700);
      submit_gemm(2, 3, 16, 0);
      submit_gemm(2, 3, 16, 1);
      submit_gemm(2, 3, 16, 2);
      wait_all_done(total_cycles);
      $display("  All completed in %0d cycles", total_cycles);
      check_c(2, 3, 16, 0); check_c(2, 3, 16, 1); check_c(2, 3, 16, 2);
      $display("  Pipelined 3-GEMM: errors=%0d", errors_total);
    end

    // Test 4: Mixed shapes - GEMM0: M=4 N=8 K=8, GEMM1: M=2 N=3 K=16
    $display("\n[Test 4] Pipelined mixed: (M=4 N=8 K=8) + (M=2 N=3 K=16)");
    begin : pipe_mixed
      errors_total = 0;
      fill_gemm(4, 8, 8, 0, 700); fill_gemm(2, 3, 16, 1, 800);
      submit_gemm(4, 8, 8, 0);
      submit_gemm(2, 3, 16, 1);
      wait_all_done(total_cycles);
      $display("  All completed in %0d cycles", total_cycles);
      check_c(4, 8, 8, 0); check_c(2, 3, 16, 1);
      $display("  Pipelined mixed: errors=%0d", errors_total);
    end

    // Test 5: Large-N followed by small-N (reproduces stress test iter5)
    // Shapes: {6,8,10} + {4,12,8} + {2,3,16} + {1,1,1}
    $display("\n[Test 5] Pipelined: large-N then small-N (repro iter5)");
    begin : pipe_repro
      errors_total = 0;
      fill_gemm(6, 8, 10, 0, 1500); fill_gemm(4, 12, 8, 1, 1526);
      fill_gemm(2, 3, 16, 2, 1552); fill_gemm(1, 1, 1, 3, 1578);
      submit_gemm(6, 8, 10, 0);
      submit_gemm(4, 12, 8, 1);
      submit_gemm(2, 3, 16, 2);
      submit_gemm(1, 1, 1, 3);
      wait_all_done(total_cycles);
      $display("  All completed in %0d cycles", total_cycles);
      check_c(6, 8, 10, 0); check_c(4, 12, 8, 1);
      check_c(2, 3, 16, 2); check_c(1, 1, 1, 3);
      $display("  Pipelined repro: errors=%0d", errors_total);
    end

    $display("\n=================================================================");
    if (errors_total == 0) $display("  ALL SMALL-N PIPELINED TESTS PASSED");
    else $display("  %0d ERRORS", errors_total);
    $display("=================================================================");
    $finish;
  end

  initial begin #50000000; $display("[TIMEOUT]"); $finish; end
endmodule
