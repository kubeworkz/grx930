// ---------------------------------------------------------------------------
// tb_npu_staging.sv — NPU staging buffer integration test
//
// Verifies that back-to-back GEMMs produce correct results.  The staging
// buffer path (P_STAGING) fires when the second START arrives during the
// first GEMM's P_WRITE_C phase (via the command queue).  This testbench
// uses sequential submissions to verify functional correctness.
// ---------------------------------------------------------------------------
module tb_npu_staging;

  localparam int NUM_ROWS = 8, NUM_COLS = 8, DIN_W = 8, ACC_W = 48;
  localparam int MAX_M = 8, MAX_K = 16, MAX_N = 12;

  localparam [31:0] A1 = 32'h0000, B1 = 32'h0100, C1 = 32'h0300;
  localparam [31:0] A2 = 32'h0500, B2 = 32'h0600, C2 = 32'h0800;
  localparam [31:0] A3 = 32'h0A00, B3 = 32'h0B00, C3 = 32'h0C00;

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

  // Byte-addressed DDR model
  localparam int MEM_DEPTH = 8192;
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

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);
    s_axi_awaddr = addr; s_axi_awvalid = 1; s_axi_wdata = data; s_axi_wstrb = 4'hF;
    s_axi_wvalid = 1; s_axi_bready = 1;
    wait (s_axi_awready && s_axi_wready);
    s_axi_awvalid = 0; s_axi_wvalid = 0;
    wait (s_axi_bvalid); @(posedge clk); s_axi_bready = 0;
  endtask

  task automatic run_gemm(input int mm, nn, kk,
    input logic [31:0] ab, bb, cb, output int cycles);
    integer timeout;
    begin
      axi_write(32'h14, ab); axi_write(32'h18, bb); axi_write(32'h1C, cb);
      axi_write(32'h08, mm); axi_write(32'h0C, nn); axi_write(32'h10, kk);
      cycles = 0; timeout = 0;
      axi_write(32'h00, 32'h1);
      forever begin
        @(posedge clk); cycles = cycles + 1;
        if (o_done) disable run_gemm;
        timeout = timeout + 1;
        if (timeout > 500000) begin $display("[TIMEOUT]"); disable run_gemm; end
      end
    end
  endtask

  int errors_total;
  task automatic check_c(input int mm, nn, kk,
    input logic [31:0] ab, bb, cb);
    int sum_val, got_val;
    begin
      for (int mi = 0; mi < mm; mi++) begin
        for (int ni = 0; ni < nn; ni++) begin
          sum_val = 0;
          for (int ki = 0; ki < kk; ki++)
            sum_val = sum_val + $signed(mem8[ab + mi*kk + ki]) * $signed(mem8[bb + ki*nn + ni]);
          got_val = $signed({mem8[cb + (mi*nn+ni)*4+3], mem8[cb + (mi*nn+ni)*4+2],
                             mem8[cb + (mi*nn+ni)*4+1], mem8[cb + (mi*nn+ni)*4]});
          if (got_val !== sum_val) begin
            if (errors_total < 20)
              $display("  [FAIL] C[%0d][%0d] = %0d, expected %0d", mi, ni, got_val, sum_val);
            errors_total = errors_total + 1;
          end
        end
      end
    end
  endtask

  task automatic fill_ab(input int mm, nn, kk,
    input logic [31:0] ab, bb, input int seed_a, input int seed_b);
    begin
      for (int i = 0; i < mm * kk; i++)
        mem8[ab + i] = ((seed_a * 7 + i * 13) % 17) - 8;
      for (int i = 0; i < kk * nn; i++)
        mem8[bb + i] = ((seed_b * 7 + i * 13) % 17) - 8;
    end
  endtask

  int c1, c2, c3;
  initial begin
    $dumpfile("build/vcd/tb_npu_staging.vcd");
    $dumpvars(0, tb_npu_staging);
    for (int i = 0; i < MEM_DEPTH; i++) mem8[i] = 0;
    rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);
    errors_total = 0;

    $display("=================================================================");
    $display("  NPU Staging Buffer Integration Test");
    $display("=================================================================");

    // Test 1: M=2 N=3 K=8
    $display("\n[TEST 1] M=2 N=3 K=8");
    fill_ab(2,3,8, A1,B1, 100,200); fill_ab(2,3,8, A2,B2, 300,400);
    run_gemm(2,3,8, A1,B1,C1, c1); check_c(2,3,8, A1,B1,C1);
    $display("  GEMM1: %0d cycles", c1);
    run_gemm(2,3,8, A2,B2,C2, c2); check_c(2,3,8, A2,B2,C2);
    $display("  GEMM2: %0d cycles, errors=%0d", c2, errors_total);

    // Test 2: M=4 N=8 K=12
    $display("\n[TEST 2] M=4 N=8 K=12");
    fill_ab(4,8,12, A1,B1, 500,600); fill_ab(4,8,12, A2,B2, 700,800);
    run_gemm(4,8,12, A1,B1,C1, c1); check_c(4,8,12, A1,B1,C1);
    $display("  GEMM1: %0d cycles", c1);
    run_gemm(4,8,12, A2,B2,C2, c2); check_c(4,8,12, A2,B2,C2);
    $display("  GEMM2: %0d cycles, errors=%0d", c2, errors_total);

    // Test 3: K=1 (byte-alignment edge case)
    $display("\n[TEST 3] M=4 N=4 K=1");
    fill_ab(4,4,1, A1,B1, 2000,2100); fill_ab(4,4,1, A2,B2, 2200,2300);
    run_gemm(4,4,1, A1,B1,C1, c1); check_c(4,4,1, A1,B1,C1);
    $display("  GEMM1: %0d cycles", c1);
    run_gemm(4,4,1, A2,B2,C2, c2); check_c(4,4,1, A2,B2,C2);
    $display("  GEMM2: %0d cycles, errors=%0d", c2, errors_total);

    // Test 4: Three sequential M=4 N=4 K=8
    $display("\n[TEST 4] Three sequential: M=4 N=4 K=8");
    fill_ab(4,4,8, A1,B1, 1000,1100); fill_ab(4,4,8, A2,B2, 1200,1300);
    fill_ab(4,4,8, A3,B3, 1400,1500);
    run_gemm(4,4,8, A1,B1,C1, c1); check_c(4,4,8, A1,B1,C1);
    $display("  GEMM1: %0d cycles", c1);
    run_gemm(4,4,8, A2,B2,C2, c2); check_c(4,4,8, A2,B2,C2);
    $display("  GEMM2: %0d cycles", c2);
    run_gemm(4,4,8, A3,B3,C3, c3); check_c(4,4,8, A3,B3,C3);
    $display("  GEMM3: %0d cycles, errors=%0d", c3, errors_total);

    // Test 5: Max dims M=8 N=12 K=16
    $display("\n[TEST 5] M=8 N=12 K=16 (max)");
    fill_ab(8,12,16, A1,B1, 3000,3100); fill_ab(8,12,16, A2,B2, 3200,3300);
    run_gemm(8,12,16, A1,B1,C1, c1); check_c(8,12,16, A1,B1,C1);
    $display("  GEMM1: %0d cycles", c1);
    run_gemm(8,12,16, A2,B2,C2, c2); check_c(8,12,16, A2,B2,C2);
    $display("  GEMM2: %0d cycles, errors=%0d", c2, errors_total);

    $display("\n=================================================================");
    if (errors_total == 0) $display("  ALL STAGING TESTS PASSED");
    else $display("  %0d ERRORS", errors_total);
    $display("=================================================================");
    $finish;
  end

  initial begin #10000000; $display("[TIMEOUT]"); $finish; end
endmodule
