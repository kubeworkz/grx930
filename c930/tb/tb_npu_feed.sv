// -----------------------------------------------------------------------------
// tb_npu_feed.sv
//
// The operand feed of c930_npu_top at the PTA sweep's shape, M=64 N=8 K=256
// INT8: step F0 of grxcp docs/designs/pta_program_plan.md.
//
// Four GEMMs are queued back to back, each on its own copy of the same A and
// B.  GEMM0 dispatches alone and the rest are queued behind it, so GEMM0 and
// GEMM1 load cold, GEMM1's writeback PF2-prefetches GEMM2, and GEMM2's
// prefetches GEMM3 (PF2 captures only a command already in the FIFO).
//
// For each GEMM it prints the DMA's cycles by phase, the core's by state, the
// read and write beats, PF1 and PF2 activity, and the A-row wait (S_AROW).
// A window closes when the DMA leaves P_DONE: o_done is a level for all of
// P_DONE, which drains any read burst still in flight, so the drain is
// charged to the GEMM that left it.
//
// A measurement, not a regression: it checks every GEMM's C bitwise and the
// A-row watermark, and `make npu_feed` runs it twice and fails if the two
// runs differ.  The AXI memory model is the ideal one c930_ddr.sv mirrors --
// a read's first beat one cycle after AR -- so the numbers are the DMA's own
// feed cost, not a memory system's.
//
//   make npu_feed
// -----------------------------------------------------------------------------
module tb_npu_feed;
  localparam int FEED_M = 64;
  localparam int FEED_N = 8;
  localparam int FEED_K = 256;

  localparam int NUM_ROWS = 8;
  localparam int NUM_COLS = 8;
  localparam int DIN_W    = 8;
  localparam int ACC_W    = 48;
  localparam int MAX_M    = 64;
  localparam int MAX_K    = 256;
  localparam int MAX_N    = 8;

  // One operand set per GEMM, FEED_STRIDE bytes apart.
  localparam int          FEED_GEMMS  = 4;
  localparam logic [31:0] FEED_STRIDE = 32'h6000;
  localparam logic [31:0] A_BASE = 32'h0000;   // 64*256 B = 16 KB
  localparam logic [31:0] B_BASE = 32'h4000;   //  8*256 B =  2 KB
  localparam logic [31:0] C_BASE = 32'h5000;   // 64*8 words = 2 KB

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

  // Operands (the same for every GEMM) and the reference C
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
  localparam int MEM_DEPTH = 32768;
  logic [31:0] mem [0:MEM_DEPTH-1];

  // Read channel
  logic [31:0] r_addr;
  logic [7:0]  r_len;
  logic [7:0]  r_beat;
  logic        r_busy;

  assign m_axi_arready = ~r_busy;
  assign m_axi_rvalid  = r_busy;
  assign m_axi_rlast   = (r_beat == r_len);
  // Byte-aligned AXI read: a 16-byte window (4 consecutive words) shifted by
  // the byte offset within it, so non-word-aligned prefetch addresses work.
  logic [127:0] rd_window;
  logic [1:0]   rd_byte_off;
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
        for (int i = 0; i < 4; i++)
          if (m_axi_wstrb[i])
            mem[(w_addr >> 2) + w_beat*2][i*8 +: 8] <= m_axi_wdata[i*8 +: 8];
        for (int i = 0; i < 4; i++)
          if (m_axi_wstrb[i+4])
            mem[(w_addr >> 2) + w_beat*2 + 1][i*8 +: 8] <= m_axi_wdata[(i+4)*8 +: 8];
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

  task automatic mem_store8(input int byte_addr, input logic [7:0] data);
    int word = byte_addr >> 2;
    int lane = (byte_addr & 3) * 8;
    mem[word][lane +: 8] = data;
  endtask

  // Queue a command (CSR regs + START) without waiting for completion.
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

  // Batch completion per c930_npu_csr.sv: queue occupancy 0 and not busy.
  task automatic wait_queue_drain();
    logic [31:0] q;
    logic        drained = 1'b0;
    while (!drained) begin
      @(posedge clk);
      if (!o_busy) begin
        axi_read(32'h38, q);             // QUEUE_STAT: [3:0] occupancy
        if (q[3:0] == 0 && !o_busy) drained = 1'b1;
      end
    end
  endtask

  task automatic check_c_from(input logic [31:0] cbase, input string tag);
    int errors = 0;
    for (int mi = 0; mi < FEED_M; mi++)
      for (int ni = 0; ni < FEED_N; ni++) begin
        int sum = 0;
        for (int ki = 0; ki < FEED_K; ki++)
          sum += $signed(a_tb[mi*FEED_K + ki]) * $signed(b_tb[ki*FEED_N + ni]);
        c_ref[mi*FEED_N + ni] = sum;
      end
    for (int mi = 0; mi < FEED_M; mi++)
      for (int ni = 0; ni < FEED_N; ni++) begin
        int got = $signed(mem[(cbase >> 2) + mi*FEED_N + ni]);
        if (got != c_ref[mi*FEED_N + ni]) begin
          if (errors < 8)
            $display("[FAIL] %s C[%0d][%0d] = %0d, expected %0d",
                     tag, mi, ni, got, c_ref[mi*FEED_N + ni]);
          errors++;
        end
      end
    if (errors != 0)
      $fatal(1, "%s: %0d mismatches", tag, errors);
    $display("[PASS] %s M=%0d N=%0d K=%0d verified", tag, FEED_M, FEED_N, FEED_K);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  initial begin
    int          rseed;
    logic [31:0] base;

    for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 32'h0;

    rseed = 7001;
    rseed = $urandom(rseed);
    for (int i = 0; i < FEED_M*FEED_K; i++) a_tb[i] = ($urandom % 17) - 8;
    for (int i = 0; i < FEED_K*FEED_N; i++) b_tb[i] = ($urandom % 17) - 8;
    for (int g = 0; g < FEED_GEMMS; g++) begin
      base = FEED_STRIDE * g;
      for (int i = 0; i < FEED_M*FEED_K; i++) mem_store8(base + A_BASE + i, a_tb[i]);
      for (int i = 0; i < FEED_K*FEED_N; i++) mem_store8(base + B_BASE + i, b_tb[i]);
    end

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[TEST] feed: %0d queued GEMMs, M=%0d N=%0d K=%0d INT8",
             FEED_GEMMS, FEED_M, FEED_N, FEED_K);
    push_cmd(FEED_M, FEED_N, FEED_K, 0, A_BASE, B_BASE, C_BASE);
    wait (o_busy);
    for (int g = 1; g < FEED_GEMMS; g++) begin
      base = FEED_STRIDE * g;
      push_cmd(FEED_M, FEED_N, FEED_K, 0, base + A_BASE, base + B_BASE, base + C_BASE);
    end
    wait_queue_drain();
    repeat (4) @(posedge clk);           // let the last GEMM's window close
    if (f0_win != FEED_GEMMS)
      $fatal(1, "saw %0d GEMM windows, expected %0d", f0_win, FEED_GEMMS);

    for (int g = 0; g < FEED_GEMMS; g++)
      check_c_from(FEED_STRIDE * g + C_BASE, $sformatf("feed GEMM%0d", g));

    $display("[WM] watermark checks=%0d violations=%0d", wm_chk, wm_viol);
    if (wm_viol != 0) $fatal(1, "A-row watermark violations");
    $display("[PASS] feed run complete");
    $finish;
  end

  initial begin
    #400000000;  // 400 ms
    $display("[FAIL] watchdog timeout");
    $fatal(1, "timeout");
  end

  // ---------------------------------------------------------------------------
  // Feed probe (measurement only)
  // ---------------------------------------------------------------------------
  int f0_win = 0;
  int f0_ph [0:7];
  int f0_cs [0:7];
  int f0_pf1_busy, f0_pf1_ars, f0_pf1_beats;
  int f0_pf2_busy, f0_pf2_ars, f0_pf2_beats, f0_pf2_unpk;
  int f0_ar, f0_rb, f0_aw, f0_wb, f0_wall, f0_drain_beats;
  int f0_core_cyc, f0_core_stall, f0_core_arow;
  logic        f0_on = 1'b0;
  logic [2:0]  f0_prev_phase = 3'd0;
  logic        f0_core_done_q = 1'b0;
  logic [31:0] f0_abase;

  task automatic f0_clear();
    for (int i = 0; i < 8; i++) begin f0_ph[i] = 0; f0_cs[i] = 0; end
    f0_pf1_busy = 0; f0_pf1_ars = 0; f0_pf1_beats = 0;
    f0_pf2_busy = 0; f0_pf2_ars = 0; f0_pf2_beats = 0; f0_pf2_unpk = 0;
    f0_ar = 0; f0_rb = 0; f0_aw = 0; f0_wb = 0; f0_wall = 0; f0_drain_beats = 0;
  endtask

  initial f0_clear();

  always @(posedge clk) begin
    if (rst_n) begin
      if (f0_prev_phase == 3'd5 && dut.u_dma.phase != 3'd5) begin   // left P_DONE
        $display("[F0] gemm=%0d a_base=0x%05h wall=%0d dma_last=%0d | phase read_a=%0d read_b=%0d launch=%0d write_c=%0d done=%0d staging=%0d",
                 f0_win, f0_abase, f0_wall, dut.u_dma.o_dma_last_count,
                 f0_ph[1], f0_ph[2], f0_ph[3], f0_ph[4], f0_ph[5], f0_ph[6]);
        $display("[F0] gemm=%0d core cycles=%0d wstall=%0d arow_stall=%0d | state idle=%0d wload=%0d accld=%0d run=%0d write=%0d arow=%0d act=%0d",
                 f0_win, f0_core_cyc, f0_core_stall, f0_core_arow,
                 f0_cs[0], f0_cs[1], f0_cs[2], f0_cs[3], f0_cs[4], f0_cs[5], f0_cs[6]);
        $display("[F0] gemm=%0d axi ar=%0d rbeats=%0d aw=%0d wbeats=%0d drain_beats=%0d | pf1 busy=%0d ars=%0d beats=%0d | pf2 busy=%0d ars=%0d beats=%0d unpk=%0d",
                 f0_win, f0_ar, f0_rb, f0_aw, f0_wb, f0_drain_beats,
                 f0_pf1_busy, f0_pf1_ars, f0_pf1_beats,
                 f0_pf2_busy, f0_pf2_ars, f0_pf2_beats, f0_pf2_unpk);
        f0_win = f0_win + 1;
        f0_clear();
        f0_on = 1'b0;
      end
      f0_prev_phase = dut.u_dma.phase;
      if (dut.u_dma.phase != 3'd0) f0_on = 1'b1;
      if (dut.u_dma.phase == 3'd1 || dut.u_dma.phase == 3'd6) f0_abase = dut.u_dma.a_base_r;
      if (f0_on) begin
        f0_wall = f0_wall + 1;
        f0_ph[dut.u_dma.phase]  = f0_ph[dut.u_dma.phase] + 1;
        f0_cs[dut.u_core.state] = f0_cs[dut.u_core.state] + 1;
        if (dut.u_dma.phase == 3'd5 && m_axi_rvalid && m_axi_rready)
          f0_drain_beats = f0_drain_beats + 1;
        if (dut.u_dma.pf_state != 2'd0) f0_pf1_busy = f0_pf1_busy + 1;
        if (dut.u_dma.pf_state == 2'd1 && m_axi_arvalid && m_axi_arready)
          f0_pf1_ars = f0_pf1_ars + 1;
        if (dut.u_dma.pf_state == 2'd2 && m_axi_rvalid && m_axi_rready)
          f0_pf1_beats = f0_pf1_beats + 1;
        if (dut.u_dma.pf2_state != 2'd0) f0_pf2_busy = f0_pf2_busy + 1;
        if (dut.u_dma.pf2_state == 2'd1 && m_axi_arvalid && m_axi_arready)
          f0_pf2_ars = f0_pf2_ars + 1;
        if (dut.u_dma.pf2_state == 2'd2 && m_axi_rvalid && m_axi_rready)
          f0_pf2_beats = f0_pf2_beats + 1;
        if (dut.u_dma.pf2_state == 2'd3) f0_pf2_unpk = f0_pf2_unpk + 1;
        if (m_axi_arvalid && m_axi_arready) f0_ar = f0_ar + 1;
        if (m_axi_rvalid && m_axi_rready)   f0_rb = f0_rb + 1;
        if (m_axi_awvalid && m_axi_awready) f0_aw = f0_aw + 1;
        if (m_axi_wvalid && m_axi_wready)   f0_wb = f0_wb + 1;
      end
      if (dut.u_core.o_done && !f0_core_done_q) begin
        f0_core_cyc   = dut.u_core.cycle_cnt;
        f0_core_stall = dut.u_core.stall_cnt;
        f0_core_arow  = dut.u_core.arow_stall_cnt;
      end
      f0_core_done_q = dut.u_core.o_done;
    end
  end

  // ---------------------------------------------------------------------------
  // A-row watermark honesty: on the cycle o_a_rows_ready rises to R, the last
  // element of row R-1 must already be in a_mem -- which is exactly what the
  // core's S_AROW interlock trusts.
  // ---------------------------------------------------------------------------
  int wm_viol = 0, wm_chk = 0;
  int wm_prev, wm_r, wm_kk, wm_idx;
  logic signed [DIN_W-1:0] wm_got;
  always @(posedge clk) begin
    if (!rst_n) begin
      wm_prev <= 0;
    end else begin
      wm_prev <= int'(dut.u_dma.o_a_rows_ready);
      if ((dut.u_dma.phase == 3'd3 || dut.u_dma.phase == 3'd4) &&
          int'(dut.u_dma.o_a_rows_ready) > wm_prev) begin
        wm_r   = int'(dut.u_dma.o_a_rows_ready) - 1;
        wm_kk  = int'(dut.u_dma.dk);
        wm_idx = wm_r*wm_kk + wm_kk - 1;
        // Either bank: o_wbank tracks bank_sel one cycle late, so around a bank
        // flip the element legitimately lands in the other one.
        wm_got = (dut.u_core.a_mem_0[wm_idx] === a_tb[wm_idx]) ? a_tb[wm_idx]
                                                               : dut.u_core.a_mem_1[wm_idx];
        if (wm_r > 0 && wm_kk > 0) begin
          wm_chk = wm_chk + 1;
          if (wm_got !== a_tb[wm_idx]) begin
            wm_viol = wm_viol + 1;
            if (wm_viol <= 8)
              $display("[WM-VIOL] rows_ready=%0d A[%0d]=%0d exp=%0d @%0t",
                       dut.u_dma.o_a_rows_ready, wm_idx, wm_got, a_tb[wm_idx], $time);
          end
        end
      end
    end
  end

endmodule
