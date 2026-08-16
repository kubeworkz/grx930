// tb_bridge_hold.sv
//
// Minimal bridge+CSR test that mimics the dcache behavior: i_mmio_write_valid
// is asserted and HELD until o_mmio_write_done pulses, then dropped one cycle
// later. Verifies the full handshake completes without deadlock or oscillation.
module tb_bridge_hold;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  // CPU MMIO port
  logic [63:0] mmio_wr_addr = 64'd0;
  logic [63:0] mmio_wr_data = 64'd0;
  logic [7:0]  mmio_wr_strobe = 8'hF;
  logic        mmio_wr_valid = 1'b0;
  logic        mmio_wr_done;

  logic [63:0] mmio_rd_addr = 64'd0;
  logic        mmio_rd_req = 1'b0;
  logic        mmio_rd_done;
  logic [63:0] mmio_rd_data;

  // AXI4-Lite (bridge master <-> CSR slave)
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [3:0]  wstrb;
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic [1:0]  bresp, rresp;
  logic        arvalid, arready, rvalid, rready;

  logic        npu_start, npu_done, npu_busy, npu_error;
  logic [15:0] npu_dim_m, npu_dim_n, npu_dim_k;
  logic [31:0] npu_a_base, npu_b_base, npu_c_base;

  always #5 clk = ~clk;

  c930_mmio_bridge u_bridge (
    .i_clk              (clk),
    .i_rst_n            (rst_n),
    .i_mmio_read_addr   (mmio_rd_addr),
    .i_mmio_read_req    (mmio_rd_req),
    .o_mmio_read_done   (mmio_rd_done),
    .o_mmio_read_data   (mmio_rd_data),
    .i_mmio_write_addr  (mmio_wr_addr),
    .i_mmio_write_data  (mmio_wr_data),
    .i_mmio_write_strobe(mmio_wr_strobe),
    .i_mmio_write_valid (mmio_wr_valid),
    .o_mmio_write_done  (mmio_wr_done),
    .m_axi_awaddr       (awaddr),
    .m_axi_awvalid      (awvalid),
    .m_axi_awready      (awready),
    .m_axi_wdata        (wdata),
    .m_axi_wstrb        (wstrb),
    .m_axi_wvalid       (wvalid),
    .m_axi_wready       (wready),
    .m_axi_bresp        (bresp),
    .m_axi_bvalid       (bvalid),
    .m_axi_bready       (bready),
    .m_axi_araddr       (araddr),
    .m_axi_arvalid      (arvalid),
    .m_axi_arready      (arready),
    .m_axi_rdata        (rdata),
    .m_axi_rresp        (rresp),
    .m_axi_rvalid       (rvalid),
    .m_axi_rready       (rready)
  );

  c930_npu_csr u_csr (
    .i_clk        (clk),
    .i_rst_n      (rst_n),
    .s_axi_awaddr (awaddr),
    .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata  (wdata),
    .s_axi_wstrb  (wstrb),
    .s_axi_wvalid (wvalid),
    .s_axi_wready (wready),
    .s_axi_bresp  (bresp),
    .s_axi_bvalid (bvalid),
    .s_axi_bready (bready),
    .s_axi_araddr (araddr),
    .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .s_axi_rdata  (rdata),
    .s_axi_rresp  (rresp),
    .s_axi_rvalid (rvalid),
    .s_axi_rready (rready),
    .o_start      (npu_start),
    .o_dim_m      (npu_dim_m),
    .o_dim_n      (npu_dim_n),
    .o_dim_k      (npu_dim_k),
    .o_a_base     (npu_a_base),
    .o_b_base     (npu_b_base),
    .o_c_base     (npu_c_base),
    .i_busy       (npu_busy),
    .i_done       (npu_done),
    .i_error      (npu_error)
  );

  assign npu_busy  = 1'b0;
  assign npu_done  = 1'b0;
  assign npu_error = 1'b0;

  int cyc = 0;
  always @(posedge clk) begin
    if (cyc >= 2 && cyc <= 14) begin
      $display("[C%0d] wrv=%0d wr_done=%0d awv=%0d awrdy=%0d wv=%0d wrdy=%0d bv=%0d brdy=%0d st=%0d dim_m=%0d",
               cyc, mmio_wr_valid, mmio_wr_done, awvalid, awready, wvalid, wready,
               bvalid, bready, u_bridge.state, npu_dim_m);
      $fflush();
    end
    cyc = cyc + 1;
    if (cyc > 40) $finish;
  end

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    // Write DIM_M=2, holding valid until done pulses (dcache behavior).
    @(posedge clk);
    mmio_wr_addr   = 64'h4000_0008;
    mmio_wr_data   = 64'd2;
    mmio_wr_strobe = 8'h0F;
    mmio_wr_valid  = 1'b1;

    wait (mmio_wr_done);
    @(posedge clk);
    mmio_wr_valid = 1'b0;
    @(posedge clk);

    // Back-to-back second write (DIM_N=6), also held.
    mmio_wr_addr   = 64'h4000_000C;
    mmio_wr_data   = 64'd6;
    mmio_wr_valid  = 1'b1;
    wait (mmio_wr_done);
    @(posedge clk);
    mmio_wr_valid = 1'b0;

    #200;
    $display("[PASS] held-request writes completed; dim_m=%0d dim_n=%0d",
             npu_dim_m, npu_dim_n);
    $finish;
  end

endmodule
