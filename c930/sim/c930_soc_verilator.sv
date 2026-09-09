// c930_soc_verilator.sv -- Verilator harness top for the single-core SoC.
//
// Exposes the UART pins (o_uart_txd / i_uart_rxd) and the DDR testbench
// preload/readback ports so a C++ testbench can load firmware into DDR,
// release reset, and talk to the core over the 16550 UART (0x4000_1000).
// Mirrors the port set already used by c930_soc4_verilator.sv.
module c930_soc_verilator (
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- NPU status ----
  output logic o_npu_busy,
  output logic o_npu_done,
  output logic o_npu_error,
  output logic o_npu_irq,

  // ---- UART ----
  input  logic i_uart_rxd,
  output logic o_uart_txd,

  // ---- DDR testbench preload port ----
  input  logic        i_tb_wr_en,
  input  logic [31:0] i_tb_wr_addr,
  input  logic [7:0]  i_tb_wr_data,
  // ---- DDR testbench readback port ----
  input  logic [31:0] i_tb_rd_addr,
  output logic [7:0]  o_tb_rd_data,

  // ---- CPU0 PC probe (bring-up debug) ----
  output logic [63:0] o_hart0_pc,

  // ---- store-path bring-up probes ----
  output logic [2:0] o_dcache_adapter_state,  // u_soc.u_dcache_adapter.state
  output logic       o_adapter_wr_valid,      // u_soc.dcache_wr_valid
  output logic       o_adapter_wr_done,       // u_soc.dcache_wr_done
  output logic       o_xbar_m1_awvalid,       // crossbar M1 (dcache) AW
  output logic       o_xbar_m1_awready,
  output logic       o_l2_s_awvalid,
  output logic       o_l2_s_awready,
  output logic       o_l2_s_wvalid,
  output logic       o_l2_s_wready,
  output logic       o_l2_s_bvalid,
  output logic       o_l2_s_bready,
  output logic       o_ddr_m_awvalid,         // L2 -> DDR AW
  output logic       o_ddr_m_awready,
  output logic       o_ddr_m_wvalid,
  output logic       o_ddr_m_wready,
  output logic       o_ddr_m_bvalid,
  output logic       o_ddr_m_bready,
  output logic       o_xbar_m1_arvalid,       // crossbar M1 (dcache) AR
  output logic       o_xbar_m1_arready,
  output logic       o_xbar_m1_rvalid,
  output logic       o_xbar_m1_rready,
  output logic       o_l2_s_arvalid,
  output logic       o_l2_s_arready,
  output logic       o_l2_s_rvalid,
  output logic       o_l2_s_rready,
  output logic       o_ddr_m_arvalid,         // L2 -> DDR AR
  output logic       o_ddr_m_arready,
  output logic       o_ddr_m_rvalid,
  output logic       o_ddr_m_rready,
  output logic       o_ddr_m_rlast,
  output logic       o_l2_inv_valid,          // L2 -> L1 invalidation
  output logic       o_l2_inv_ack,
  output logic [3:0] o_dcache_ctrl_state,     // dcache controller STATE
  output logic [63:0] o_dcache_wr_addr,
  output logic [3:0]  o_l2_rd_state,          // L2 read FSM
  output logic [2:0]  o_l2_rd_beat,           // L2 refill beat counter
  output logic        o_ddr_r_busy,           // DDR read busy
  output logic [7:0]  o_ddr_r_beat,           // DDR read beat
  output logic [7:0]  o_l2_wr_seq,            // L2 write sequence
  output logic [7:0]  o_l2_wr_log_head,       // L2 write-log head
  output logic        o_l2_wr_log_full,

  // ---- dcache controller internals (write-miss debug) ----
  output logic        o_dc_i_write,           // ex_mem_pipe_memwrite
  output logic [11:0] o_dc_addr_lo,           // ex_mem_pipe_alu_result[11:0]
  output logic        o_dc_tag_hit,
  output logic        o_dc_update_en,
  output logic        o_dc_wr_en,
  output logic        o_dc_mem_write_valid,
  output logic        o_dc_mem_read_req,
  output logic        o_dc_rd_done,           // adapter read done
  output logic [1:0]  o_dc_adapt_state,       // adapter FSM state

  // ---- crossbar write-path probes ----
  output logic [1:0]  o_xbar_w_state,         // crossbar write FSM
  output logic [1:0]  o_xbar_w_grant,
  output logic        o_xbar_s1_awvalid,      // crossbar -> L2 AW
  output logic        o_xbar_s1_awready,
  output logic        o_xbar_s1_wvalid,
  output logic        o_xbar_s1_wready,
  output logic        o_xbar_s1_bvalid,
  output logic        o_xbar_s1_bready,
  output logic        o_xbar_m1_wvalid,       // adapter -> crossbar W
  output logic        o_xbar_m1_bvalid,       // adapter -> crossbar B
  output logic [1:0]  o_l2_wr_state           // L2 write FSM
);

  c930_soc_top #(
    .NUM_ROWS (4),
    .NUM_COLS (4),
    .MAX_M    (8),
    .MAX_K    (16),
    .MAX_N    (12),
    .MEM_BYTES(65536),
    .CLK_DIV  (1)
  ) u_soc (
    .i_clk      (i_clk),
    .i_rst_n    (i_rst_n),
    .o_npu_busy (o_npu_busy),
    .o_npu_done (o_npu_done),
    .o_npu_error(o_npu_error),
    .o_npu_irq  (o_npu_irq),
    .o_uart_txd (o_uart_txd),
    .i_uart_rxd (i_uart_rxd),
    .i_tb_wr_en   (i_tb_wr_en),
    .i_tb_wr_addr (i_tb_wr_addr),
    .i_tb_wr_data (i_tb_wr_data),
    .i_tb_rd_addr (i_tb_rd_addr),
    .o_tb_rd_data (o_tb_rd_data)
  );

  assign o_hart0_pc = u_soc.u_cpu.if_pipe_pcf_new;

  // ---- store-path bring-up probes ----
  assign o_dcache_adapter_state = u_soc.u_dcache_adapter.state;
  assign o_adapter_wr_valid     = u_soc.dcache_wr_valid;
  assign o_adapter_wr_done      = u_soc.dcache_wr_done;
  assign o_xbar_m1_awvalid      = u_soc.dcache_awvalid;
  assign o_xbar_m1_awready      = u_soc.dcache_awready;
  assign o_l2_s_awvalid         = u_soc.l2_s_awvalid;
  assign o_l2_s_awready         = u_soc.l2_s_awready;
  assign o_l2_s_wvalid          = u_soc.l2_s_wvalid;
  assign o_l2_s_wready          = u_soc.l2_s_wready;
  assign o_l2_s_bvalid          = u_soc.l2_s_bvalid;
  assign o_l2_s_bready          = u_soc.l2_s_bready;
  assign o_ddr_m_awvalid        = u_soc.ddr_awvalid;
  assign o_ddr_m_awready        = u_soc.ddr_awready;
  assign o_ddr_m_wvalid         = u_soc.ddr_wvalid;
  assign o_ddr_m_wready         = u_soc.ddr_wready;  assign o_ddr_m_bvalid        = u_soc.ddr_bvalid;
  assign o_ddr_m_bready        = u_soc.ddr_bready;

  // ---- read-path probes ----
  assign o_xbar_m1_arvalid = u_soc.dcache_arvalid;
  assign o_xbar_m1_arready = u_soc.dcache_arready;
  assign o_xbar_m1_rvalid  = u_soc.dcache_rvalid;
  assign o_xbar_m1_rready  = u_soc.dcache_rready;
  assign o_l2_s_arvalid    = u_soc.l2_s_arvalid;
  assign o_l2_s_arready    = u_soc.l2_s_arready;
  assign o_l2_s_rvalid     = u_soc.l2_s_rvalid;
  assign o_l2_s_rready     = u_soc.l2_s_rready;
  assign o_ddr_m_arvalid   = u_soc.ddr_arvalid;
  assign o_ddr_m_arready   = u_soc.ddr_arready;  assign o_ddr_m_rvalid   = u_soc.ddr_rvalid;
  assign o_ddr_m_rready   = u_soc.ddr_rready;
  assign o_ddr_m_rlast    = u_soc.ddr_rlast;
  assign o_ddr_m_rlast    = u_soc.ddr_rlast;
  assign o_l2_inv_valid    = u_soc.l2_inv_valid[0];
  assign o_l2_inv_ack      = u_soc.l2_inv_ack[0];
  assign o_dcache_ctrl_state = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE;
  assign o_dcache_wr_addr    = u_soc.dcache_wr_addr;
  assign o_l2_rd_state       = u_soc.g_l2.u_l2.rd_state;
  assign o_l2_rd_beat        = u_soc.g_l2.u_l2.rd_beat;
  assign o_ddr_r_busy        = u_soc.u_ddr.r_busy;
  assign o_ddr_r_beat        = u_soc.u_ddr.r_beat;
  assign o_l2_wr_seq         = u_soc.g_l2.u_l2.wr_seq;
  assign o_l2_wr_log_head    = u_soc.g_l2.u_l2.wr_log_head;
  assign o_l2_wr_log_full    = u_soc.g_l2.u_l2.wr_log_full;

  // ---- dcache controller internals ----
  assign o_dc_i_write         = u_soc.u_cpu.ex_mem_pipe_memwrite;
  assign o_dc_addr_lo         = u_soc.u_cpu.ex_mem_pipe_alu_result[11:0];
  assign o_dc_tag_hit         = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.tag_hit;
  assign o_dc_update_en       = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.update_en;
  assign o_dc_wr_en           = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_wr_en;
  assign o_dc_mem_write_valid = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mem_write_valid;
  assign o_dc_mem_read_req    = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mem_read_req;
  assign o_dc_rd_done         = u_soc.u_cpu.mem_read_done;
  assign o_dc_adapt_state     = u_soc.u_dcache_adapter.state;

  // ---- crossbar write-path probes ----
  assign o_xbar_w_state       = u_soc.u_crossbar.w_state;
  assign o_xbar_w_grant       = u_soc.u_crossbar.w_grant;
  assign o_xbar_s1_awvalid    = u_soc.l2_s_awvalid;
  assign o_xbar_s1_awready    = u_soc.l2_s_awready;
  assign o_xbar_s1_wvalid     = u_soc.l2_s_wvalid;
  assign o_xbar_s1_wready     = u_soc.l2_s_wready;
  assign o_xbar_s1_bvalid     = u_soc.l2_s_bvalid;
  assign o_xbar_s1_bready     = u_soc.l2_s_bready;
  assign o_xbar_m1_wvalid     = u_soc.dcache_wvalid;
  assign o_xbar_m1_bvalid     = u_soc.dcache_bvalid;
  assign o_l2_wr_state        = u_soc.g_l2.u_l2.wr_state;

endmodule