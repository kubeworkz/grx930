// c930_soc4_verilator.sv -- Verilator harness top for the FULL 4-core SoC
// with the shared L2 cache ACTIVE (no BYPASS_L2).
//
// The C++ driver (tb_soc4.cc) preloads the DDR through the TB preload port,
// releases reset, and polls the 0xFACEFEED magic written by CPU0 via the
// (public_flat_rd) DDR memory mirror.
module c930_soc4_verilator (
  input  logic        i_clk,
  input  logic        i_rst_n,

  // DDR TB preload port (driven from C++ before reset release)
  input  logic        i_tb_wr_en,
  input  logic [31:0] i_tb_wr_addr,
  input  logic [7:0]  i_tb_wr_data,
  // DDR TB readback port (polled by C++ to detect the 0xFACEFEED magic)
  input  logic [31:0] i_tb_rd_addr,
  output logic [7:0]  o_tb_rd_data,

  // UART
  input  logic        i_uart_rxd,
  output logic        o_uart_txd,

  // NPU status (both NPUs)
  output logic o_npu0_busy,
  output logic o_npu0_done,
  output logic o_npu0_error,
  output logic o_npu0_irq,
  output logic o_npu1_busy,
  output logic o_npu1_done,
  output logic o_npu1_error,
  output logic o_npu1_irq,

  // ---- Diagnostics (integration bringup) ----
  output logic [1:0]  o_xbar_r_state,
  output logic [1:0]  o_xbar_r_grant,
  output logic [3:0]  o_l2_rd_state,
  output logic [3:0]  o_dma0_phase,
  output logic [2:0]  o_dma0_rd_sub,
  output logic [63:0] o_hart0_pc,
  output logic        o_xbar_m2_arvalid,
  output logic        o_l2_s_arvalid,
  output logic        o_l2_s_arready,
  output logic        o_ddr_m_arvalid,
  output logic        o_ddr_m_arready,
  output logic [1:0]  o_csr0_disp,     // NPU0 CSR dispatcher state (D_IDLE=0/D_WAIT=1)
  output logic [3:0]  o_csr0_fifo,     // NPU0 CSR fifo occupancy
  output logic        o_csr0_done_latch,
  // MMIO read-path bring-up probes
  output logic        o_mmio_rd_req,   // bridge read request presented
  output logic        o_mmio_rd_done,  // bridge read done
  output logic [1:0]  o_mmio_arb_state,
  output logic [1:0]  o_mmio_arb_grant,
  output logic        o_csr_arvalid,
  output logic        o_csr_arready,
  output logic        o_csr_rvalid,
  output logic        o_csr_rready,
  output logic [3:0]  o_dc0_state,
  output logic        o_dc0_stall,
  output logic [9:0]  o_ic0_fill,
  output logic [2:0]  o_icadp_state,
  output logic        o_m0_arvalid,
  output logic        o_m0_arready,
  output logic        o_m0_rvalid,
  output logic        o_m0_rready,
  output logic [3:0]  o_l2_rd_cur,
  output logic [1:0]  o_ic0_state,
  output logic        o_ic0_stall,
  // DMA arbiter internals (crossbar M2 wedge diagnosis)
  output logic [1:0]  o_arb_rd_owner,
  output logic        o_arb_rd_active,
  output logic        o_arb_rd_addr_phase,
  output logic        o_arb_s_arvalid,
  output logic        o_arb_s_arready,
  output logic        o_npu0_arvalid,
  output logic        o_npu1_arvalid,
  output logic [3:0]  o_dma1_phase,
  output logic [2:0]  o_dma0_pf,
  output logic [2:0]  o_dma0_pf2,
  output logic [1:0]  o_dma0_wr_sub,
  output logic [2:0]  o_dma0_rdsub,
  output logic [31:0] o_l2_s_araddr,
  output logic [7:0]  o_arb_s_arlen,
  output logic [3:0]  o_l2_wr_state,
  output logic        o_l2_s_awvalid,
  output logic        o_l2_s_awready,
  output logic        o_l2_s_wvalid,
  output logic        o_l2_s_wready,
  output logic        o_l2_s_bvalid,
  output logic        o_l2_s_bready,
  output logic [7:0]  o_l2_wrlog_full,
  output logic [1:0]  o_arb_wr_owner,
  output logic        o_arb_wr_active,
  output logic        o_arb_wr_addr_phase,
  output logic [1:0]  o_xbar_w_state,
  output logic [1:0]  o_xbar_w_grant,
  output logic        o_l2_m_awvalid,
  output logic        o_l2_m_awready,
  output logic        o_l2_m_wvalid,
  output logic        o_l2_m_wready,
  output logic        o_l2_m_bvalid,
  output logic        o_l2_m_bready
);

  c930_soc_top #(
    .NUM_ROWS     (8),
    .NUM_COLS     (8),
    .MAX_M        (8),
    .MAX_K        (16),
    .MAX_N        (12),
    .MEM_BYTES    (65536),
    .CLK_DIV      (1),
    .L2_NUM_SETS  (512),   // full 64 KB shared L2, ACTIVE
    .L2_NUM_WAYS  (4),
    .BYPASS_L2    (1'b0),  // L2 ACTIVE
    .DDR_INIT_FILE(""),    // firmware goes through the TB preload port
    .BOOT_INIT_FILE("sw/boot.hex")
  ) u_soc (
    .i_clk        (i_clk),
    .i_rst_n      (i_rst_n),
    .o_npu_busy   (o_npu0_busy),
    .o_npu_done   (o_npu0_done),
    .o_npu_error  (o_npu0_error),
    .o_npu_irq    (o_npu0_irq),
    .o_npu1_busy  (o_npu1_busy),
    .o_npu1_done  (o_npu1_done),
    .o_npu1_error (o_npu1_error),
    .o_npu1_irq   (o_npu1_irq),
    .o_uart_txd   (o_uart_txd),
    .i_uart_rxd   (i_uart_rxd),
    .i_tb_wr_en   (i_tb_wr_en),
    .i_tb_wr_addr (i_tb_wr_addr),
    .i_tb_wr_data (i_tb_wr_data),
    .i_tb_rd_addr (i_tb_rd_addr),
    .o_tb_rd_data (o_tb_rd_data)
  );

  // Diagnostics
  assign o_xbar_r_state = u_soc.u_crossbar.r_state;
  assign o_xbar_r_grant = u_soc.u_crossbar.r_grant;
  assign o_dma0_phase   = u_soc.u_npu.u_dma.phase;

  generate if (1'b1) begin : g_l2diag
    assign o_l2_rd_state = u_soc.g_l2.u_l2.rd_state;
    assign o_l2_s_arvalid = u_soc.g_l2.u_l2.s_arvalid;
    assign o_l2_s_arready = u_soc.g_l2.u_l2.s_arready;
    assign o_ddr_m_arvalid = u_soc.g_l2.u_l2.m_arvalid;
    assign o_ddr_m_arready = u_soc.g_l2.u_l2.m_arready;
  end else begin : g_l2diag_off
    assign o_l2_rd_state = 4'd0;
    assign o_l2_s_arvalid = 1'b0;
    assign o_l2_s_arready = 1'b1;
    assign o_ddr_m_arvalid = 1'b0;
    assign o_ddr_m_arready = 1'b1;
  end endgenerate
  assign o_hart0_pc     = u_soc.u_cpu.if_pipe_pcf_new;
  assign o_csr0_disp      = u_soc.u_npu.u_csr.disp_state;
  assign o_csr0_fifo      = u_soc.u_npu.u_csr.fifo_count;
  assign o_csr0_done_latch= u_soc.u_npu.u_csr.done_latch;
  assign o_mmio_rd_req    = u_soc.mmio_arb_rd_req;
  assign o_mmio_rd_done   = u_soc.mmio_arb_rd_done;
  assign o_mmio_arb_state = u_soc.u_mmio_arb.state;
  assign o_mmio_arb_grant = u_soc.u_mmio_arb.grant;
  assign o_csr_arvalid    = u_soc.csr_arvalid;
  assign o_csr_arready    = u_soc.u_npu.u_csr.s_axi_arready;
  assign o_csr_rvalid     = u_soc.u_npu.u_csr.s_axi_rvalid;
  assign o_csr_rready     = u_soc.csr_rready;
  assign o_dc0_state      = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE;
  assign o_dc0_stall      = u_soc.u_cpu.d_chache_stall;
  assign o_ic0_state      = u_soc.u_cpu.u_riscv_core_i_cache_top.icache_controller.STATE;
  assign o_ic0_stall      = u_soc.u_cpu.i_chache_stall;
  assign o_ic0_fill       = u_soc.u_cpu.u_riscv_core_i_cache_top.icache_controller.fill_addr[9:0];
  assign o_icadp_state    = u_soc.u_icache_adapter.state;
  assign o_m0_arvalid     = u_soc.icache_arvalid;
  assign o_m0_arready     = u_soc.icache_arready;
  assign o_m0_rvalid      = u_soc.icache_rvalid;
  assign o_m0_rready      = u_soc.icache_rready;
  assign o_l2_rd_cur      = u_soc.g_l2.u_l2.rd_state;

  assign o_arb_rd_owner       = u_soc.u_dma_arb.rd_owner;
  assign o_arb_rd_active      = u_soc.u_dma_arb.rd_active;
  assign o_arb_rd_addr_phase  = u_soc.u_dma_arb.rd_addr_phase;
  assign o_arb_s_arvalid      = u_soc.u_dma_arb.s_arvalid;
  assign o_arb_s_arready      = u_soc.u_dma_arb.s_arready;
  assign o_npu0_arvalid       = u_soc.npu_arvalid;
  assign o_npu1_arvalid       = u_soc.npu1_arvalid;
  assign o_dma1_phase         = u_soc.u_npu1.u_dma.phase;
  assign o_dma0_pf            = u_soc.u_npu.u_dma.pf_state;
  assign o_dma0_pf2           = u_soc.u_npu.u_dma.pf2_state;
  assign o_dma0_wr_sub        = u_soc.u_npu.u_dma.wr_sub;
  assign o_dma0_rdsub         = u_soc.u_npu.u_dma.rd_sub;
  assign o_l2_s_araddr        = u_soc.g_l2.u_l2.s_araddr;
  assign o_arb_s_arlen        = u_soc.u_dma_arb.s_arlen;
  assign o_l2_wr_state        = u_soc.g_l2.u_l2.wr_state;
  assign o_l2_s_awvalid       = u_soc.g_l2.u_l2.s_awvalid;
  assign o_l2_s_awready       = u_soc.g_l2.u_l2.s_awready;
  assign o_l2_s_wvalid        = u_soc.g_l2.u_l2.s_wvalid;
  assign o_l2_s_wready        = u_soc.g_l2.u_l2.s_wready;
  assign o_l2_s_bvalid        = u_soc.g_l2.u_l2.s_bvalid;
  assign o_l2_s_bready        = u_soc.g_l2.u_l2.s_bready;
  assign o_l2_wrlog_full      = u_soc.g_l2.u_l2.wr_log_full;
  assign o_arb_wr_owner       = u_soc.u_dma_arb.wr_owner;
  assign o_arb_wr_active      = u_soc.u_dma_arb.wr_active;
  assign o_arb_wr_addr_phase  = u_soc.u_dma_arb.wr_addr_phase;
  assign o_xbar_w_state       = u_soc.u_crossbar.w_state;
  assign o_xbar_w_grant       = u_soc.u_crossbar.w_grant;
  assign o_l2_m_awvalid       = u_soc.g_l2.u_l2.m_awvalid;
  assign o_l2_m_awready       = u_soc.g_l2.u_l2.m_awready;
  assign o_l2_m_wvalid        = u_soc.g_l2.u_l2.m_wvalid;
  assign o_l2_m_wready        = u_soc.g_l2.u_l2.m_wready;
  assign o_l2_m_bvalid        = u_soc.g_l2.u_l2.m_bvalid;
  assign o_l2_m_bready        = u_soc.g_l2.u_l2.m_bready;

endmodule