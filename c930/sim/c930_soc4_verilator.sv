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
  output logic        o_ddr_m_arready
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
    .BYPASS_L2    (1'b0),  // L2 enabled -- this is the point of the harness
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
  assign o_l2_rd_state  = u_soc.g_l2.u_l2.rd_state;
  assign o_dma0_phase   = u_soc.u_npu.u_dma.phase;
  assign o_dma0_rd_sub  = u_soc.u_npu.u_dma.rd_sub;
  assign o_hart0_pc     = u_soc.u_cpu.if_pipe_pcf_new;
  assign o_xbar_m2_arvalid = u_soc.u_crossbar.m2_arvalid;
  assign o_l2_s_arvalid = u_soc.g_l2.u_l2.s_arvalid;
  assign o_l2_s_arready = u_soc.g_l2.u_l2.s_arready;
  assign o_ddr_m_arvalid = u_soc.g_l2.u_l2.m_arvalid;
  assign o_ddr_m_arready = u_soc.g_l2.u_l2.m_arready;

endmodule