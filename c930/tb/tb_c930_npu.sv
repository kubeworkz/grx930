// -----------------------------------------------------------------------------
// tb_c930_npu.sv
//
// Self-checking testbench for c930_npu_top:
//   * Programs DIMs and A/B/C base addresses over the AXI4-Lite CSR.
//   * A/B operands live in a simple AXI4 slave memory model; the NPU's DMA
//     master burst-reads them and burst-writes C back autonomously.
//   * Test 1: deterministic 1x2x2 GEMM (hand-computed result).
//   * Test 2: explicit edge cases (K=1, K as an exact multiple of NUM_ROWS,
//             M=1, N-tiling, max dims).
//   * Test 3: randomized M/N/K sweep with deterministic per-case seeds.
//
// Run with iverilog:
//   iverilog -g2012 -o tb_c930_npu.vvp \
//       c930/rtl/c930_tensor_pe.sv c930/rtl/c930_systolic_array.sv \
//       c930/rtl/c930_npu_core.sv c930/rtl/c930_npu_csr.sv \
//       c930/rtl/c930_npu_dma.sv c930/rtl/c930_npu_top.sv \
//       c930/tb/tb_c930_npu.sv
//   vvp tb_c930_npu.vvp
// -----------------------------------------------------------------------------
module tb_c930_npu;

  localparam int NUM_ROWS = 4;   // systolic rows (reduction per pass)
  localparam int NUM_COLS = 4;   // systolic cols (output width)
  localparam int DIN_W    = 8;
  localparam int ACC_W    = 48;
  localparam int MAX_M    = 8;
  localparam int MAX_K    = 16;
  localparam int MAX_N    = 12;  // > NUM_COLS so the sweep exercises N-tiling

  // DDR regions (byte addresses, word-aligned)
  localparam [31:0] A_BASE = 32'h0000;
  localparam [31:0] B_BASE = 32'h0100;
  localparam [31:0] C_BASE = 32'h0200;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  // AXI4-Lite (CSR)
  logic [31:0] s_axi_awaddr  = '0;
  logic        s_axi_awvalid = 1'b0;
  logic        s_axi_awready;
  logic [31:0] s_axi_wdata   = '0;
  logic [3:0]  s_axi_wstrb   = '0;
  logic        s_axi_wvalid  = 1'b0;
  logic        s_axi_wready;
  logic [1:0]  s_axi_bresp;
  logic        s_axi_bvalid;
  logic        s_axi_bready  = 1'b0;
  logic [31:0] s_axi_araddr  = '0;
  logic        s_axi_arvalid = 1'b0;
  logic        s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0]  s_axi_rresp;
  logic        s_axi_rvalid;
  logic        s_axi_rready  = 1'b0;

  // AXI4 full master (DMA) <-> memory model
  logic [31:0] m_axi_araddr;
  logic [7:0]  m_axi_arlen;
  logic [2:0]  m_axi_arsize;
  logic [1:0]  m_axi_arburst;
  logic        m_axi_arvalid;
  logic        m_axi_arready;
  logic [31:0] m_axi_rdata;
  logic [1:0]  m_axi_rresp;
  logic        m_axi_rlast;
  logic        m_axi_rvalid;
  logic        m_axi_rready;
  logic [31:0] m_axi_awaddr;
  logic [7:0]  m_axi_awlen;
  logic [2:0]  m_axi_awsize;
  logic [1:0]  m_axi_awburst;
  logic        m_axi_awvalid;
  logic        m_axi_awready;
  logic [31:0] m_axi_wdata;
  logic [3:0]  m_axi_wstrb;
  logic        m_axi_wlast;
  logic        m_axi_wvalid;
  logic        m_axi_wready;
  logic [1:0]  m_axi_bresp;
  logic        m_axi_bvalid;
  logic        m_axi_bready;

  logic o_busy, o_done, o_error, o_irq;

  // Local operand / reference storage
  logic signed [DIN_W-1:0] a_tb  [0:MAX_M*MAX_K-1];
  logic signed [DIN_W-1:0] b_tb  [0:MAX_K*MAX_N-1];
  int                      c_ref [0:MAX_M*MAX_N-1];

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  c930_npu_top #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (DIN_W),
    .ACC_W    (ACC_W),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N)
  ) dut (
    .i_clk         (clk),
    .i_rst_n       (rst_n),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .m_axi_araddr  (m_axi_araddr),
    .m_axi_arlen   (m_axi_arlen),
    .m_axi_arsize  (m_axi_arsize),
    .m_axi_arburst (m_axi_arburst),
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rlast   (m_axi_rlast),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awlen   (m_axi_awlen),
    .m_axi_awsize  (m_axi_awsize),
    .m_axi_awburst (m_axi_awburst),
    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_wdata   (m_axi_wdata),
    .m_axi_wstrb   (m_axi_wstrb),
    .m_axi_wlast   (m_axi_wlast),
    .m_axi_wvalid  (m_axi_wvalid),
    .m_axi_wready  (m_axi_wready),
    .m_axi_bresp   (m_axi_bresp),
    .m_axi_bvalid  (m_axi_bvalid),
    .m_axi_bready  (m_axi_bready),
    .o_busy        (o_busy),
    .o_done        (o_done),
    .o_error       (o_error),
    .o_irq         (o_irq)
  );

  // ---------------------------------------------------------------------------
  // Clock
  // ---------------------------------------------------------------------------
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // AXI4 slave memory model (DDR stand-in), 32-bit word-addressed internally
  // ---------------------------------------------------------------------------
  localparam int MEM_DEPTH = 512;
  logic [31:0] mem [0:MEM_DEPTH-1];

  // Read channel
  logic [31:0] r_addr;
  logic [7:0]  r_len;
  logic [7:0]  r_beat;
  logic        r_busy;

  assign m_axi_arready = ~r_busy;
  assign m_axi_rvalid  = r_busy;
  assign m_axi_rlast   = (r_beat == r_len);
  assign m_axi_rdata   = mem[(r_addr >> 2) + r_beat];
  assign m_axi_rresp   = 2'b00;

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

  // Write channel
  logic [31:0] w_addr;
  logic [7:0]  w_len;
  logic [7:0]  w_beat;
  logic        w_busy;
  logic        b_valid;

  assign m_axi_awready = ~w_busy;
  assign m_axi_wready  = w_busy;
  assign m_axi_bvalid  = b_valid;
  assign m_axi_bresp   = 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_busy  <= 1'b0;
      b_valid <= 1'b0;
      w_addr  <= '0;
      w_len   <= '0;
      w_beat  <= '0;
    end else begin
      if (m_axi_awvalid && m_axi_awready && !w_busy) begin
        w_addr <= m_axi_awaddr;
        w_len  <= m_axi_awlen;
        w_beat <= 8'd0;
        w_busy <= 1'b1;
      end
      if (w_busy && m_axi_wvalid && m_axi_wready) begin
        mem[(w_addr >> 2) + w_beat] <= m_axi_wdata;
        if (w_beat == w_len) begin
          w_busy  <= 1'b0;
          b_valid <= 1'b1;
        end else begin
          w_beat <= w_beat + 1;
        end
      end
      if (b_valid && m_axi_bready)
        b_valid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // AXI4-Lite tasks
  // ---------------------------------------------------------------------------
  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);          // drive so the DUT samples cleanly at the next posedge
    s_axi_awaddr  = addr;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = data;
    s_axi_wstrb   = 4'hF;
    s_axi_wvalid  = 1'b1;
    s_axi_bready  = 1'b1;
    wait (s_axi_awready && s_axi_wready);
    s_axi_awvalid = 1'b0;
    s_axi_wvalid  = 1'b0;
    wait (s_axi_bvalid);
    @(posedge clk);          // slave clears bvalid on this edge (bvalid & bready)
    s_axi_bready  = 1'b0;
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);          // drive so the DUT samples cleanly at the next posedge
    s_axi_araddr  = addr;
    s_axi_arvalid = 1'b1;
    s_axi_rready  = 1'b1;
    wait (s_axi_arready);
    s_axi_arvalid = 1'b0;
    wait (s_axi_rvalid);
    data = s_axi_rdata;
    @(posedge clk);          // slave clears rvalid on this edge (rvalid & rready)
    s_axi_rready  = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Memory-model helpers: pack a byte into the 32-bit word array
  // ---------------------------------------------------------------------------
  task automatic mem_store8(input int byte_addr, input logic [7:0] data);
    int word = byte_addr >> 2;
    int lane = (byte_addr & 3) * 8;
    mem[word][lane +: 8] = data;
  endtask

  function automatic logic [7:0] mem_load8(input int byte_addr);
    int word = byte_addr >> 2;
    int lane = (byte_addr & 3) * 8;
    mem_load8 = mem[word][lane +: 8];
  endfunction

  // ---------------------------------------------------------------------------
  // Program dims + bases + launch, wait for completion
  // ---------------------------------------------------------------------------
  task automatic run_engine(input int m, n, k);
    logic [31:0] tmp;
    axi_write(32'h14, A_BASE);
    axi_write(32'h18, B_BASE);
    axi_write(32'h1C, C_BASE);
    axi_write(32'h08, m[31:0]);
    axi_write(32'h0C, n[31:0]);
    axi_write(32'h10, k[31:0]);
    // sanity: read back DIM_M
    axi_read(32'h08, tmp);
    if (tmp != m[31:0]) $fatal(1, "DIM_M readback mismatch: %0d", tmp);
    axi_write(32'h00, 32'h1);            // START
    wait (o_done === 1'b1);              // DMA completion pulse
    if (o_error) $fatal(1, "engine reported an error");
  endtask

  // ---------------------------------------------------------------------------
  // Reference GEMM + result compare (C read back from the DDR model)
  // ---------------------------------------------------------------------------
  task automatic check_c(input int m, n, k);
    int errors = 0;

    // reference model
    for (int mi = 0; mi < m; mi++) begin
      for (int ni = 0; ni < n; ni++) begin
        int sum = 0;
        for (int ki = 0; ki < k; ki++)
          sum += $signed(a_tb[mi*k + ki]) * $signed(b_tb[ki*n + ni]);
        c_ref[mi*n + ni] = sum;
      end
    end

    // compare against C written back to the memory model
    for (int mi = 0; mi < m; mi++) begin
      for (int ni = 0; ni < n; ni++) begin
        int got = $signed(mem[(C_BASE >> 2) + mi*n + ni]);
        if (got != c_ref[mi*n + ni]) begin
          $display("[FAIL] C[%0d][%0d] = %0d, expected %0d",
                   mi, ni, got, c_ref[mi*n + ni]);
          errors++;
        end
      end
    end

    if (errors != 0)
      $fatal(1, "M=%0d N=%0d K=%0d: %0d mismatches", m, n, k, errors);
    $display("[PASS] GEMM M=%0d N=%0d K=%0d verified", m, n, k);
  endtask

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  task automatic test_deterministic();
    $display("[TEST] deterministic 1x2x2");
    // A = [ 3, -2 ]   B = [ 1, 4 ; 5, -1 ]  ->  C = [ -7, 14 ]
    a_tb[0] = 3;  a_tb[1] = -2;
    b_tb[0] = 1;  b_tb[1] = 4;  b_tb[2] = 5;  b_tb[3] = -1;

    mem_store8(A_BASE + 0, a_tb[0]);
    mem_store8(A_BASE + 1, a_tb[1]);
    mem_store8(B_BASE + 0, b_tb[0]);
    mem_store8(B_BASE + 1, b_tb[1]);
    mem_store8(B_BASE + 2, b_tb[2]);
    mem_store8(B_BASE + 3, b_tb[3]);

    run_engine(1, 2, 2);
    check_c(1, 2, 2);
  endtask

  // Generate random operands, store to memory, run, and self-check one case.
  task automatic run_random_case(input int m, n, k, input int seed_in);
    int rseed = seed_in;
    rseed = $urandom(rseed);   // deterministic per-case seed
    $display("[TEST] random M=%0d N=%0d K=%0d (seed %0d)", m, n, k, seed_in);

    for (int mi = 0; mi < m; mi++)
      for (int ki = 0; ki < k; ki++)
        a_tb[mi*k + ki] = ($urandom % 17) - 8;   // uniform in [-8, 8]

    for (int ki = 0; ki < k; ki++)
      for (int ni = 0; ni < n; ni++)
        b_tb[ki*n + ni] = ($urandom % 17) - 8;   // uniform in [-8, 8]

    // Pack A and B into the DDR model (row-major, little-endian byte lanes).
    for (int mi = 0; mi < m; mi++)
      for (int ki = 0; ki < k; ki++)
        mem_store8(A_BASE + mi*k + ki, a_tb[mi*k + ki]);

    for (int ki = 0; ki < k; ki++)
      for (int ni = 0; ni < n; ni++)
        mem_store8(B_BASE + ki*n + ni, b_tb[ki*n + ni]);

    run_engine(m, n, k);
    check_c(m, n, k);
  endtask

  // Randomized (but deterministic) sweep across the supported dimension space.
  task automatic run_sweep(input int num_cases);
    int rseed = 4242;
    int m, n, k;
    rseed = $urandom(rseed);   // seed the dimension generator

    for (int s = 0; s < num_cases; s++) begin
      m = ($urandom % MAX_M) + 1;
      n = ($urandom % MAX_N) + 1;
      k = ($urandom % MAX_K) + 1;
      run_random_case(m, n, k, 2000 + s);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  initial begin
    $dumpfile("tb_c930_npu.vcd");
    $dumpvars(0, tb_c930_npu);
    $timeformat(-9, 0, " ns", 8);

    for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 32'h0;

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    test_deterministic();

    // ---- Explicit edge cases ----
    run_random_case(1, 1, 1, 1001);    // minimal: M=1, K=1
    run_random_case(2, 3, 1, 1002);    // K=1 -> single partial tile (kr=1)
    run_random_case(8, 12, 1, 1003);   // max M/N with K=1
    run_random_case(1, 4, 4, 1004);    // M=1, K == NUM_ROWS (one full tile)
    run_random_case(8, 4, 4, 1005);    // K == NUM_ROWS exactly
    run_random_case(3, 4, 8, 1006);    // K == 2 * NUM_ROWS
    run_random_case(8, 4, 12, 1007);   // K == 3 * NUM_ROWS
    run_random_case(2, 3, 16, 1008);   // K == MAX_K == 4 * NUM_ROWS
    run_random_case(1, 2, 5, 1009);    // M=1 with a partial K tile (kr=1)
    run_random_case(5, 4, 6, 1010);    // partial K tile (kr=2)
    run_random_case(8, 5, 16, 1011);   // N=5 -> 2 N-tiles (4 + 1), max K
    run_random_case(3, 8, 4, 1012);    // N=8 -> 2 full N-tiles
    run_random_case(8, 12, 16, 1013);  // max dims: 3 N-tiles x 4 K-tiles
    run_random_case(1, 12, 1, 1014);   // M=1, K=1, 3 N-tiles

    // ---- Randomized M/N/K sweep ----
    run_sweep(16);

    $display("[PASS] all NPU tests passed");
    $finish;
  end

  // Failsafe watchdog
  initial begin
    #2000000;   // 2 ms
    $display("[FAIL] watchdog timeout");
    $fatal(1, "timeout");
  end

endmodule
