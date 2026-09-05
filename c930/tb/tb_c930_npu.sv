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

  localparam int NUM_ROWS = 8;   // systolic rows (reduction per pass)
  localparam int NUM_COLS = 8;   // systolic cols (output width)
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
  logic [63:0] m_axi_rdata;
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
  logic [63:0] m_axi_wdata;
  logic [7:0]  m_axi_wstrb;
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
  // Byte-aligned AXI read: use a 16-byte window (4 consecutive words)
  // and shift by the byte offset within the window.  Without this,
  // non-word-aligned PF prefetch addresses (e.g. K=1 INT8 where the
  // second row starts at byte offset 1) return the wrong byte.
  logic [127:0] rd_window;
  logic [1:0]   rd_byte_off;
  assign rd_byte_off = r_addr[1:0];
  assign rd_window = { mem[(r_addr >> 2) + r_beat*2 + 3],
                       mem[(r_addr >> 2) + r_beat*2 + 2],
                       mem[(r_addr >> 2) + r_beat*2 + 1],
                       mem[(r_addr >> 2) + r_beat*2] };
  assign m_axi_rdata = rd_window >> {rd_byte_off, 3'b000};
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
        begin
          for (int i = 0; i < 4; i++)
            if (m_axi_wstrb[i])
              mem[(w_addr >> 2) + w_beat*2][i*8 +: 8] <= m_axi_wdata[i*8 +: 8];
          for (int i = 0; i < 4; i++)
            if (m_axi_wstrb[i+4])
              mem[(w_addr >> 2) + w_beat*2 + 1][i*8 +: 8] <= m_axi_wdata[(i+4)*8 +: 8];
        end
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
  task automatic run_engine_p(input int m, n, k, input int prec,
                              input logic [31:0] ab, bb, cb);
    logic [31:0] tmp;
    axi_write(32'h14, ab);
    axi_write(32'h18, bb);
    axi_write(32'h1C, cb);
    axi_write(32'h20, prec[31:0]);       // PREC register (0x20)
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

  task automatic run_engine(input int m, n, k);
    run_engine_p(m, n, k, 0, A_BASE, B_BASE, C_BASE);
  endtask

  // ---------------------------------------------------------------------------
  // Queue a command (CSR regs + START) without waiting for completion.
  // While the engine is busy the CSR pushes it to the command FIFO, so
  // back-to-back calls build a queue that drains automatically.
  // ---------------------------------------------------------------------------
  task automatic push_cmd(input int m, n, k, input int prec,
                          input logic [31:0] ab, bb, cb);
    axi_write(32'h14, ab);
    axi_write(32'h18, bb);
    axi_write(32'h1C, cb);
    axi_write(32'h20, prec[31:0]);
    axi_write(32'h08, m[31:0]);
    axi_write(32'h0C, n[31:0]);
    axi_write(32'h10, k[31:0]);
    axi_write(32'h00, 32'h1);            // START (pushes to FIFO if busy)
  endtask

  // Wait until the engine is idle AND the command queue is drained.
  // expected_pulses = total o_done pulses the whole queue will produce, so
  // the 1-cycle idle gaps BETWEEN GEMMs (when the next command hasn't been
  // popped yet, or was just popped) don't fool the check: QUEUE_STAT is
  // read a few cycles after the !o_busy observation, by which time the
  // dispatcher may have already popped the next command.
  task automatic wait_queue_drain(input int expected_pulses);
    logic [31:0] q;
    logic        drained = 1'b0;
    int          dpulses = 0;
    while (!drained) begin
      @(posedge clk);
      if (o_done) dpulses = dpulses + 1;
      if (dpulses >= expected_pulses && !o_busy) begin
        axi_read(32'h38, q);             // QUEUE_STAT: [2:0] = queue depth
        if (q[2:0] == 0) drained = 1'b1;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // INT4 packing: element e -> byte e/2, nibble (e%2)*4 (low nibble first)
  // ---------------------------------------------------------------------------
  task automatic mem_store4(input int base, input int elem_idx, input logic [3:0] val);
    int byte_addr = base + elem_idx / 2;
    int lane      = (elem_idx % 2) * 4;
    mem[byte_addr >> 2][(byte_addr & 3) * 8 + lane +: 4] = val;
  endtask

  // ---------------------------------------------------------------------------
  // Reference GEMM + result compare (C read back from the DDR model).
  // Operands come from the caller-supplied arrays so queued GEMMs can be
  // verified after the whole queue drains.
  // ---------------------------------------------------------------------------
  // Uses the global a_tb/b_tb arrays (Icarus cannot pass arrays to tasks).
  // Callers copy their operands into a_tb/b_tb before calling.
  task automatic check_c_from(input logic [31:0] cbase, input int m, n, k,
                              input string tag);
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
        int got = $signed(mem[(cbase >> 2) + mi*n + ni]);
        if (got != c_ref[mi*n + ni]) begin
          $display("[FAIL] %s C[%0d][%0d] = %0d, expected %0d",
                   tag, mi, ni, got, c_ref[mi*n + ni]);
          errors++;
        end
      end
    end

    if (errors != 0)
      $fatal(1, "%s M=%0d N=%0d K=%0d: %0d mismatches", tag, m, n, k, errors);
    $display("[PASS] %s M=%0d N=%0d K=%0d verified", tag, m, n, k);
  endtask

  task automatic check_c(input int m, n, k);
    check_c_from(C_BASE, m, n, k, "GEMM");
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
  // INT4 standalone: nibble-packed A/B, full-A upfront read path.
  // ---------------------------------------------------------------------------
  task automatic test_int4_basic();
    int m = 3, n = 4, k = 5;   // odd K exercises partial nibble bytes
    $display("[TEST] INT4 standalone M=%0d N=%0d K=%0d", m, n, k);

    for (int mi = 0; mi < m; mi++)
      for (int ki = 0; ki < k; ki++) begin
        a_tb[mi*k + ki] = ($urandom % 16) - 8;   // INT4 range [-8, 7]
        mem_store4(A_BASE, mi*k + ki, a_tb[mi*k + ki][3:0]);
      end
    for (int ki = 0; ki < k; ki++)
      for (int ni = 0; ni < n; ni++) begin
        b_tb[ki*n + ni] = ($urandom % 16) - 8;
        mem_store4(B_BASE, ki*n + ni, b_tb[ki*n + ni][3:0]);
      end

    run_engine_p(m, n, k, 4, A_BASE, B_BASE, C_BASE);
    check_c_from(C_BASE, m, n, k, "INT4");
  endtask

  // ---------------------------------------------------------------------------
  // Mixed INT4/INT8 queue: INT8 -> INT8 -> INT4 -> INT8 back-to-back.
  // PF2's deferred capture (1 cycle after dispatch) only sees commands that
  // are ALREADY in the FIFO, so the INT4 GEMM must be at index 2: GEMM1
  // captures it as the FIFO head and PF2 prefetches its data during GEMM1's
  // writeback.  The INT4 GEMM then dispatches via P_STAGING, which must
  // carry ALL of A (M*K nibbles), not just row 0 -- INT4 has no PF1 row
  // prefetch.  Fails without the PF2 INT4 fix.
  // ---------------------------------------------------------------------------
  task automatic test_int4_queue();
    // Memory layout (all within the 2 KB model):
    //   GEMM0 INT8 8x12x16: A@0x000 (128B)  B@0x100 (192B)  C@0x200 (384B)
    //   GEMM1 INT8 8x12x16: A@0x380 (128B)  B@0x400 (192B)  C@0x4C0 (384B)
    //   GEMM2 INT4 2x4x4 :  A@0x640 (4B)    B@0x650 (8B)    C@0x660 (32B)
    //   GEMM3 INT8 3x3x4 :  A@0x680 (12B)   B@0x690 (12B)   C@0x6A0 (36B)
    localparam [31:0] A0 = 32'h000, B0 = 32'h100, C0 = 32'h200;
    localparam [31:0] A1 = 32'h380, B1 = 32'h400, C1 = 32'h4C0;
    localparam [31:0] A2 = 32'h640, B2 = 32'h650, C2 = 32'h660;
    localparam [31:0] A3 = 32'h680, B3 = 32'h690, C3 = 32'h6A0;

    logic signed [7:0] a0 [0:MAX_M*MAX_K-1];
    logic signed [7:0] b0 [0:MAX_K*MAX_N-1];
    logic signed [7:0] a1 [0:MAX_M*MAX_K-1];
    logic signed [7:0] b1 [0:MAX_K*MAX_N-1];
    logic signed [7:0] a2 [0:MAX_M*MAX_K-1];
    logic signed [7:0] b2 [0:MAX_K*MAX_N-1];
    logic signed [7:0] a3 [0:MAX_M*MAX_K-1];
    logic signed [7:0] b3 [0:MAX_K*MAX_N-1];

    logic saw_int4_staging = 1'b0;
    logic saw_ge1_done     = 1'b0;

    $display("[TEST] INT4/INT8 queue: INT8 -> INT8 -> INT4 -> INT8");

    // ---- GEMM0 + GEMM1: big INT8 GEMMs so PF2 has time to prefetch ----
    for (int mi = 0; mi < 8; mi++)
      for (int ki = 0; ki < 16; ki++) begin
        a0[mi*16 + ki] = ($urandom % 17) - 8;
        mem_store8(A0 + mi*16 + ki, a0[mi*16 + ki]);
        a1[mi*16 + ki] = ($urandom % 17) - 8;
        mem_store8(A1 + mi*16 + ki, a1[mi*16 + ki]);
      end
    for (int ki = 0; ki < 16; ki++)
      for (int ni = 0; ni < 12; ni++) begin
        b0[ki*12 + ni] = ($urandom % 17) - 8;
        mem_store8(B0 + ki*12 + ni, b0[ki*12 + ni]);
        b1[ki*12 + ni] = ($urandom % 17) - 8;
        mem_store8(B1 + ki*12 + ni, b1[ki*12 + ni]);
      end

    // ---- GEMM2: INT4 2x4x4 (M=2 -> row 1 of A is the bug detector) ----
    for (int mi = 0; mi < 2; mi++)
      for (int ki = 0; ki < 4; ki++) begin
        a2[mi*4 + ki] = ($urandom % 16) - 8;
        mem_store4(A2, mi*4 + ki, a2[mi*4 + ki][3:0]);
      end
    for (int ki = 0; ki < 4; ki++)
      for (int ni = 0; ni < 4; ni++) begin
        b2[ki*4 + ni] = ($urandom % 16) - 8;
        mem_store4(B2, ki*4 + ni, b2[ki*4 + ni][3:0]);
      end

    // ---- GEMM3: INT8 3x3x4 (trailing correctness check) ----
    for (int mi = 0; mi < 3; mi++)
      for (int ki = 0; ki < 4; ki++) begin
        a3[mi*4 + ki] = ($urandom % 17) - 8;
        mem_store8(A3 + mi*4 + ki, a3[mi*4 + ki]);
      end
    for (int ki = 0; ki < 4; ki++)
      for (int ni = 0; ni < 3; ni++) begin
        b3[ki*3 + ni] = ($urandom % 17) - 8;
        mem_store8(B3 + ki*3 + ni, b3[ki*3 + ni]);
      end

    // ---- Queue all four, then let the CSR auto-drain ----
    push_cmd(8, 12, 16, 0, A0, B0, C0);
    wait (o_busy);                       // GEMM0 dispatched; queue the rest
    push_cmd(8, 12, 16, 0, A1, B1, C1);
    push_cmd(2, 4, 4, 4, A2, B2, C2);
    push_cmd(3, 3, 4, 0, A3, B3, C3);

    // ---- Watch the window between GEMM1's done and GEMM2's done: the
    //      INT4 GEMM must dispatch via P_STAGING (PF2 prefetch path). ----
    wait (o_done === 1'b1);              // GEMM0 done pulse
    @(negedge o_done);
    wait (o_done === 1'b1);              // GEMM1 done pulse
    @(negedge o_done);
    while (!saw_ge1_done) begin
      @(posedge clk);
      if (dut.u_dma.phase == 3'd6)       // P_STAGING
        saw_int4_staging = 1'b1;
      if (o_done) saw_ge1_done = 1'b1;   // GEMM2 done pulse
    end

    wait_queue_drain(1);   // only GEMM3's done pulse remains (monitor consumed 0-2)

    if (!saw_int4_staging)
      $fatal(1, "INT4 GEMM did not use the PF2 staging path (prefetch incomplete)");

    for (int i = 0; i < MAX_M*MAX_K; i++) a_tb[i] = a0[i];
    for (int i = 0; i < MAX_K*MAX_N; i++) b_tb[i] = b0[i];
    check_c_from(C0, 8, 12, 16, "Q0-INT8 ");
    for (int i = 0; i < MAX_M*MAX_K; i++) a_tb[i] = a1[i];
    for (int i = 0; i < MAX_K*MAX_N; i++) b_tb[i] = b1[i];
    check_c_from(C1, 8, 12, 16, "Q1-INT8 ");
    for (int i = 0; i < MAX_M*MAX_K; i++) a_tb[i] = a2[i];
    for (int i = 0; i < MAX_K*MAX_N; i++) b_tb[i] = b2[i];
    check_c_from(C2, 2, 4, 4,  "Q2-INT4 ");
    for (int i = 0; i < MAX_M*MAX_K; i++) a_tb[i] = a3[i];
    for (int i = 0; i < MAX_K*MAX_N; i++) b_tb[i] = b3[i];
    check_c_from(C3, 3, 3, 4,  "Q3-INT8 ");
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

    // ---- INT4 coverage (PF2 cross-GEMM prefetch for nibble-packed mode) ----
    test_int4_basic();
    test_int4_queue();

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
