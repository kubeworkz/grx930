// tb_dcache_mmio.sv
//
// Minimal: dcache MMIO store -> bridge -> CSR. No instrumentation inside RTL.
module tb_dcache_mmio;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  logic [63:0] data_from_core = 64'd0;
  logic [63:0] addr_from_core = 64'd0;
  logic        read = 1'b0;
  logic        write = 1'b0;
  logic [1:0]  size = 2'b10;
  logic [3:0]  amo_op = 4'd0;
  logic        amo = 1'b0, lr = 1'b0, sc = 1'b0;
  logic        stall;
  logic [63:0] data_to_core;
  logic        store_fault, load_fault, amo_fault;

  logic [63:0]  dmem_rd_addr;
  logic         dmem_rd_req;
  logic         dmem_rd_done;
  logic [255:0] dmem_rd_line;
  logic [63:0]  dmem_wr_addr;
  logic [63:0]  dmem_wr_data;
  logic [7:0]   dmem_wr_strobe;
  logic         dmem_wr_valid;
  logic         dmem_wr_done;

  logic [63:0] mmio_rd_addr, mmio_wr_addr, mmio_wr_data;
  logic        mmio_rd_req, mmio_rd_done, mmio_wr_valid, mmio_wr_done;
  logic [63:0] mmio_rd_data;
  logic [7:0]  mmio_wr_strobe;

  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [3:0]  wstrb;
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic [1:0]  bresp, rresp;
  logic        arvalid, arready, rvalid, rready;

  logic        npu_start, npu_done, npu_busy, npu_error;
  logic [15:0] npu_dim_m, npu_dim_n, npu_dim_k;
  logic [31:0] npu_a_base, npu_b_base, npu_c_base;

  always #5 clk = ~clk;

  riscv_core_dcache_top #(
    .TAG_WIDTH (52),
    .MMIO_BASE (64'h4000_0000)
  ) u_dcache (
    .i_clk              (clk),
    .i_rst_n            (rst_n),
    .i_data_from_core   (data_from_core),
    .i_addr_from_core   (addr_from_core),
    .i_read             (read),
    .i_write            (write),
    .i_size             (size),
    .i_amo_op           (amo_op),
    .i_amo              (amo),
    .i_lr               (lr),
    .i_sc               (sc),
    .o_stall            (stall),
    .o_data_to_core     (data_to_core),
    .o_store_fault      (store_fault),
    .o_load_fault       (load_fault),
    .o_amo_fault        (amo_fault),
    .o_mem_read_address (dmem_rd_addr),
    .o_mem_read_req     (dmem_rd_req),
    .i_mem_read_done    (dmem_rd_done),
    .i_block_from_axi   (dmem_rd_line),
    .i_mem_write_done   (dmem_wr_done),
    .o_mem_write_valid  (dmem_wr_valid),
    .o_mem_write_data   (dmem_wr_data),
    .o_mem_write_address(dmem_wr_addr),
    .o_mem_write_strobe (dmem_wr_strobe),
    .o_mmio_read_address(mmio_rd_addr),
    .o_mmio_read_req    (mmio_rd_req),
    .i_mmio_read_done   (mmio_rd_done),
    .i_mmio_read_data   (mmio_rd_data),
    .o_mmio_write_address(mmio_wr_addr),
    .o_mmio_write_data  (mmio_wr_data),
    .o_mmio_write_strobe(mmio_wr_strobe),
    .o_mmio_write_valid (mmio_wr_valid),
    .i_mmio_write_done  (mmio_wr_done)
  );

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

  // DDR stub for cache fills (read-only, zero line)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dmem_rd_done <= 1'b0;
      dmem_rd_line <= '0;
      dmem_wr_done <= 1'b0;
    end else begin
      dmem_rd_done <= 1'b0;
      dmem_wr_done <= 1'b0;
      if (dmem_rd_req) begin
        dmem_rd_line <= '0;
        dmem_rd_done <= 1'b1;
      end
      if (dmem_wr_valid)
        dmem_wr_done <= 1'b1;
    end
  end

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk);
    addr_from_core = 64'h4000_0008;
    data_from_core = 64'd2;
    size           = 2'b10;
    write          = 1'b1;

    wait (!stall);
    @(posedge clk);
    write = 1'b0;

    repeat (5) @(posedge clk);
    if (npu_dim_m == 16'd2)
      $display("[PASS] dcache MMIO store wrote dim_m=2");
    else
      $display("[FAIL] dim_m=%0d", npu_dim_m);
    $finish;
  end

endmodule
