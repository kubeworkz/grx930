// tb_l2_coherent.sv - standalone verification of the shared L2:
//   read miss/refill, hit, write-through + readback, and coherence
//   invalidation (a write to a line invalidates its L1 sharers).
//
// Drives the L2 slave port directly; a small DDR model sits on the master port.
`timescale 1ns/1ps
module tb_l2_coherent;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;

  // slave (crossbar-facing) AXI
  logic [3:0] s_awid;  logic [63:0] s_awaddr; logic [7:0] s_awlen;
  logic [2:0] s_awsize; logic [1:0] s_awburst; logic s_awvalid, s_awready;
  logic [63:0] s_wdata; logic [7:0] s_wstrb; logic s_wlast, s_wvalid, s_wready;
  logic [3:0] s_bid; logic [1:0] s_bresp; logic s_bvalid, s_bready;
  logic [3:0] s_arid; logic [63:0] s_araddr; logic [7:0] s_arlen;
  logic [2:0] s_arsize; logic [1:0] s_arburst; logic s_arvalid, s_arready;
  logic [3:0] s_rid; logic [63:0] s_rdata; logic [1:0] s_rresp;
  logic s_rlast, s_rvalid, s_rready;

  // master (DDR) AXI
  logic [3:0] m_awid;  logic [63:0] m_awaddr; logic [7:0] m_awlen;
  logic [2:0] m_awsize; logic [1:0] m_awburst; logic m_awvalid, m_awready;
  logic [63:0] m_wdata; logic [7:0] m_wstrb; logic m_wlast, m_wvalid, m_wready;
  logic [3:0] m_bid; logic [1:0] m_bresp; logic m_bvalid, m_bready;
  logic [3:0] m_arid; logic [63:0] m_araddr; logic [7:0] m_arlen;
  logic [2:0] m_arsize; logic [1:0] m_arburst; logic m_arvalid, m_arready;
  logic [3:0] m_rid; logic [63:0] m_rdata; logic [1:0] m_rresp;
  logic m_rlast, m_rvalid, m_rready;

  logic [7:0] inv_valid, inv_ack;
  assign inv_ack = 8'hFF;  // ack immediately; we watch inv_valid pulses

  c930_l2 #(.NUM_SETS(16), .NUM_WAYS(1)) u_l2 (
    .i_clk(clk), .i_rst_n(rst_n),
    .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen),
    .s_awsize(s_awsize), .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
    .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
    .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
    .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen),
    .s_arsize(s_arsize), .s_arburst(s_arburst), .s_arvalid(s_arvalid), .s_arready(s_arready),
    .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast),
    .s_rvalid(s_rvalid), .s_rready(s_rready),
    .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
    .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
    .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
    .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
    .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
    .m_rvalid(m_rvalid), .m_rready(m_rready),
    .o_inv_valid(inv_valid), .o_inv_addr(), .i_inv_ack(inv_ack)
  );

  // ---------------- simple DDR model (64-bit, 1-beat-per-cycle) ----------------
  logic [63:0] mem [0:1023];
  logic r_busy = 0; logic [7:0] r_len; logic [63:0] r_addr; logic [7:0] r_beat = 0;
  logic w_busy = 0; logic [7:0] w_len; logic [63:0] w_addr; logic [7:0] w_beat = 0;
  logic b_valid = 0;

  assign m_arready = ~r_busy;
  assign m_rvalid  = r_busy;
  assign m_rlast   = (r_beat == r_len);
  assign m_rdata   = mem[r_addr/8 + r_beat];
  assign m_awready = ~w_busy;
  assign m_wready  = w_busy;
  assign m_bvalid  = b_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      r_busy <= 0; w_busy <= 0; b_valid <= 0;
    end else begin
      if (m_arvalid && m_arready && !r_busy) begin
        r_addr <= m_araddr; r_len <= m_arlen; r_beat <= 0; r_busy <= 1;
      end
      if (r_busy && m_rvalid && m_rready) begin
        if (r_beat == r_len) r_busy <= 0; else r_beat <= r_beat + 1;
      end
      if (m_awvalid && m_awready && !w_busy) begin
        w_addr <= m_awaddr; w_len <= m_awlen; w_beat <= 0; w_busy <= 1;
      end
      if (w_busy && m_wvalid && m_wready) begin
        for (int i = 0; i < 8; i++)
          if (m_wstrb[i]) mem[w_addr/8 + w_beat][i*8 +: 8] <= m_wdata[i*8 +: 8];
        if (w_beat == w_len) begin w_busy <= 0; b_valid <= 1; end
        else w_beat <= w_beat + 1;
      end
      if (b_valid && m_bready) b_valid <= 0;
    end
  end

  int errs = 0;
  logic [7:0] inv_seen = 8'h00;
  always @(posedge clk) if (inv_valid != 8'h00) inv_seen |= inv_valid;

  bit got_first, got_second, got_third;

  // issue a line read (len=3) from source 'src'; waits for rlast and returns
  // the 4 words in beat order.
  task automatic read_line(input [63:0] addr, input [3:0] src,
                           output logic [63:0] w0, w1, w2, w3);
    begin
      s_arvalid = 1; s_araddr = addr; s_arlen = 3; s_arid = src;
      s_rready  = 1;
      while (!s_arready) @(posedge clk);
      @(posedge clk);
      s_arvalid = 0;
      w0 = 0; w1 = 0; w2 = 0; w3 = 0;
      while (!(s_rvalid && s_rready && s_rlast)) begin
        @(posedge clk);
        if (s_rvalid && s_rready) begin
          if (!got_first) begin
            got_first = 1; w0 = s_rdata;
          end else if (!got_second) begin
            got_second = 1; w1 = s_rdata;
          end else if (!got_third) begin
            got_third = 1; w2 = s_rdata;
          end else begin
            w3 = s_rdata;
          end
        end
      end
      @(posedge clk);
      s_rready = 0;
    end
  endtask

  // issue a word write (len=0) from source 'src'; returns after B.
  task automatic write_word(input [63:0] addr, input [63:0] data,
                            input [3:0] src);
    begin
      s_awvalid = 1; s_awaddr = addr; s_awlen = 0; s_awid = src;
      s_wvalid  = 1; s_wdata = data; s_wstrb = 8'hFF; s_wlast = 1;
      s_bready  = 1;
      while (!s_awready) @(posedge clk);
      @(posedge clk);   // present AW for at least one clock edge
      s_awvalid = 0;
      while (!(s_wvalid && s_wready)) @(posedge clk);
      @(posedge clk);   // let the L2 capture the accepted W beat and advance
      s_wvalid = 0;
      while (!s_bvalid) @(posedge clk);
      @(posedge clk);
      s_bready = 0;
    end
  endtask

  initial begin
    integer i;
    logic [63:0] w0, w1, w2, w3;

    for (i = 0; i < 1024; i++) mem[i] = 64'hA000000000000000 + i;

    // seed: line at 0x20 = words A000..A003
    mem[4] = 64'h0000000000000001;
    mem[5] = 64'h0000000000000002;
    mem[6] = 64'h0000000000000003;
    mem[7] = 64'h0000000000000004;

    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- Test 1: read miss -> refill -> serve (source 0) ----
    got_first = 0; got_second = 0; got_third = 0;
    read_line(64'h20, 4'd0, w0, w1, w2, w3);
    if (w0 !== 64'h0000000000000001 || w1 !== 64'h0000000000000002 ||
        w2 !== 64'h0000000000000003 || w3 !== 64'h0000000000000004) begin
      $display("FAIL T1 refill data w0=%0h w1=%0h w2=%0h w3=%0h", w0, w1, w2, w3);
      errs++;
    end else
      $display("PASS T1 refill served correct line");

    // ---- Test 2: read hit (source 1) ----
    got_first = 0; got_second = 0; got_third = 0;
    read_line(64'h20, 4'd1, w0, w1, w2, w3);
    if (w0 !== 64'h0000000000000001)
      $display("FAIL T2 hit"); else
      $display("PASS T2 hit served from line");

    // ---- Test 3: write-through to word 1 of the line (source 1) ----
    write_word(64'h28, 64'hDEADBEEFCAFEBABE, 4'd1);
    if (mem[5] !== 64'hDEADBEEFCAFEBABE) begin
      $display("FAIL T3 write-through DDR got %0h", mem[5]);
      errs++;
    end else
      $display("PASS T3 write-through reached DDR");

    // ---- Test 4: readback (source 2) sees the new word ----
    got_first = 0; got_second = 0; got_third = 0;
    read_line(64'h20, 4'd2, w0, w1, w2, w3);
    if (w1 !== 64'hDEADBEEFCAFEBABE) begin
      $display("FAIL T4 readback w1=%0h", w1);
      errs++;
    end else
      $display("PASS T4 readback sees written word");

    // ---- Test 5: a write to an UNTOUCHED line must NOT invalidate the
    //              sharers of a different line ----
    inv_seen = 8'h00;
    write_word(64'h30, 64'h1111222233334444, 4'd10);
    if (inv_seen[0] || inv_seen[1] || inv_seen[4]) begin
      $display("FAIL T5 spurious invalidation seen=%0h", inv_seen);
      errs++;
    end else
      $display("PASS T5 no spurious invalidation for untouched line");

    // ---- Test 6/7: coherence on a fresh line (0x40) with mapped sources ----
    // src0 and src1 both read the line (both become sharers: ports 0,1).
    mem[8]  = 64'hAAAAAAAAAAAAAAAA;  // 0x40 word 0
    mem[9]  = 64'hBBBBBBBBBBBBBBBB;
    got_first = 0; got_second = 0; got_third = 0;
    read_line(64'h40, 4'd0, w0, w1, w2, w3);          // src0: miss -> alloc
    got_first = 0; got_second = 0; got_third = 0;
    read_line(64'h40, 4'd1, w0, w1, w2, w3);          // src1: hit -> add sharer
    // A write from src 10 (mapped -> port 6) to this shared line must
    // invalidate ports 0 (src0) and 1 (src1).
    inv_seen = 8'h00;
    write_word(64'h40, 64'hCDCDCDCDCDCDCDCD, 4'd10);
    if (!(inv_seen[0] && inv_seen[1])) begin
      $display("FAIL T6 expected invalidation of ports 0,1 got %0h", inv_seen);
      errs++;
    end else
      $display("PASS T6 write invalidated sharers (ports 0,1)");
    // After invalidation, a read from src0 must REFILL and see the new data.
    got_first = 0; got_second = 0; got_third = 0;
    read_line(64'h40, 4'd0, w0, w1, w2, w3);
    if (w0 !== 64'hCDCDCDCDCDCDCDCD) begin
      $display("FAIL T7 post-invalidate readback w0=%0h (expect CDCD...)", w0);
      errs++;
    end else
      $display("PASS T7 post-invalidate read sees new data");

    if (errs == 0)
      $display("ALL L2 TESTS PASSED");
    else
      $display("L2 TESTS FAILED: %0d errors", errs);
    $finish;
  end
endmodule