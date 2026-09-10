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
  output logic        o_dc_rd_en,             // dcache o_rd_en (load read)
  output logic [63:0] o_dc_data_to_core,      // dcache load return data
  output logic [63:0] o_dc_rd_addr,           // dcache line-fill address
  output logic [255:0] o_adapt_rd_line,       // adapter fill line (256b)
  output logic        o_dc_i_read,            // dcache i_read
  output logic        o_dc_block_replace,     // dcache o_block_replace
  output logic [255:0] o_dc_mem31,            // dcache DATA_MEM[31] (contentious set)
  output logic [63:0] o_mwb_read_data,        // core mem_wb_pipe_read_data (captured load value)
  output logic [63:0] o_ex_mem_alu,           // core ex_mem_pipe_alu_result (dcache addr)
  output logic        o_hu_stall_mem,         // hazard unit stall_mem
  output logic        o_hu_stall_wb,          // hazard unit stall_wb
  output logic [63:0] o_rf_a4,                // register file x14 (a4)
  output logic [63:0] o_rf_a5,                // register file x15 (a5)
  output logic        o_mwb_regwrite,         // mem_wb regwrite
  output logic [63:0] o_result_wb,            // WB result mux
  output logic [63:0] o_if_pc,                // fetch PC (if_pipe_pcf_new)
  output logic [31:0] o_instr_raw,            // icache output word
  output logic [31:0] o_instr_dec,            // compressed-decoder output
  output logic        o_instr_comp,           // instr_is_compressed
  output logic [31:0] o_instr_mem,            // instruction in MEM stage (instr_mem)
  output logic [31:0] o_instr_ex,             // instruction in EX stage (instr_ex)
  output logic        o_pcsrc_ex,             // branch/jump taken in EX
  output logic        o_hu_flush_ex,          // hazard unit flush of id_ex pipe
  output logic        o_hu_stall_ex,          // hazard unit stall of id_ex pipe
  output logic        o_pc_cntrl_wb,          // trap/mret PC redirect
  output logic        o_trap_cntrl_wb,        // trap to handler
  output logic [63:0] o_trap_addr_if,         // trap target PC

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
  output logic [1:0]  o_l2_wr_state,          // L2 write FSM

  // ---- UART internals (baud / TX-path debug) ----
  output logic [15:0] o_uart_baud_div,        // u_uart.baud_divisor
  output logic [1:0]  o_uart_tx_state,        // u_uart.tx_state
  output logic [3:0]  o_uart_tx_baud_cnt,     // u_uart.tx_baud_cnt
  output logic [7:0]  o_uart_tx_fifo_rdata,   // u_uart.tx_fifo_rdata
  output logic        o_uart_tx_fifo_empty,
  output logic        o_uart_tx_fifo_full,
  output logic [7:0]  o_uart_tx_shift,
  output logic        o_uart_rx_pin,          // u_uart.rx_pin
  output logic [31:0] o_uart_awaddr,          // UART AXI write address
  output logic        o_uart_awvalid,
  output logic [31:0] o_uart_wdata,           // UART AXI write data
  output logic        o_uart_wvalid,
  output logic [3:0]  o_uart_wstrb,
  output logic [7:0]  o_uart_tx_fifo_wdata,   // u_uart.tx_fifo_wdata
  output logic        o_uart_tx_fifo_we,
  output logic        o_dc_mmio_rd_req,       // dcache MMIO read request
  output logic [63:0] o_dc_mmio_rd_addr,
  output logic [63:0] o_dc_mmio_rd_data,      // mmio_rd_data (bridge return)
  output logic        o_dc_mmio_wr_valid,     // dcache MMIO write
  output logic [63:0] o_dc_mmio_wr_addr,
  output logic [63:0] o_dc_mmio_wr_data,
  output logic [7:0]  o_dc_mmio_wr_strobe,

  // ---- UART RX path (echo-test debug) ----
  output logic [1:0]  o_uart_rx_state,         // u_uart.rx_state
  output logic [3:0]  o_uart_rx_baud_cnt,
  output logic [7:0]  o_uart_rx_shift,
  output logic        o_uart_rx_fifo_empty,
  output logic [7:0]  o_uart_rx_fifo_wdata,
  output logic        o_uart_rx_fifo_we,
  output logic        o_mmio_rd_req_raw,       // bridge read request
  output logic [63:0] o_mmio_rd_addr_raw,
  output logic [63:0] o_mmio_rd_data_raw,      // bridge read data return
  output logic [1:0]  o_mmio_rd_core,          // arb grant_r: which core owns the request
  // ---- PAIRED UART-slave read/write probes (addr+data latched together) ----
  output logic        o_uart_axi_rd_valid,     // u_uart: AXI_RD && s_axi_rvalid
  output logic [4:0]  o_uart_axi_rd_addr,      // u_uart.axi_addr_r (latched at req)
  output logic [63:0] o_uart_axi_rd_data,      // u_uart.s_axi_rdata
  output logic        o_uart_rx_fifo_re,       // u_uart.rx_fifo_re (FIFO pop)
  output logic        o_uart_rx_fifo_rd_ptr,   // u_uart.rx_fifo_rd_ptr[0] (pop timing)
  output logic        o_uart_tx_fifo_re,       // u_uart.tx_fifo_re (TX shift pop)
  output logic        o_uart_axi_wr_valid,     // u_uart: AXI_WR && s_axi_wvalid
  output logic [4:0]  o_uart_axi_wr_addr,      // u_uart.axi_addr_r
  output logic [63:0] o_uart_axi_wr_data       // u_uart.s_axi_wdata
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
  assign o_dc_rd_en           = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_rd_en;
  assign o_dc_data_to_core    = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_memory.o_data_to_core;
  assign o_dc_rd_addr         = u_soc.dcache_rd_addr;
  assign o_adapt_rd_line      = u_soc.u_dcache_adapter.o_cache_rd_line;
  assign o_dc_i_read          = u_soc.u_cpu.mem_cahce_read;
  assign o_dc_block_replace   = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_block_replace;
  assign o_dc_mem31           = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_memory.DATA_MEM[31];
  assign o_mwb_read_data      = u_soc.u_cpu.mem_wb_pipe_read_data;
  assign o_ex_mem_alu         = u_soc.u_cpu.ex_mem_pipe_alu_result;
  assign o_hu_stall_mem       = u_soc.u_cpu.hu_stall_mem;
  assign o_hu_stall_wb        = u_soc.u_cpu.hu_stall_wb;
  assign o_rf_a4              = u_soc.u_cpu.u_riscv_core_rf.rf[14];
  assign o_rf_a5              = u_soc.u_cpu.u_riscv_core_rf.rf[15];
  assign o_mwb_regwrite       = u_soc.u_cpu.mem_wb_pipe_regwrite;
  assign o_result_wb          = u_soc.u_cpu.result_wb;
  assign o_if_pc              = u_soc.u_cpu.if_pipe_pcf_new;
  assign o_instr_raw          = u_soc.u_cpu.instr;
  assign o_instr_dec          = u_soc.u_cpu.c_ext_instr_out;
  assign o_instr_comp         = u_soc.u_cpu.instr_is_compressed;
  assign o_instr_mem          = u_soc.u_cpu.instr_mem;
  assign o_instr_ex           = u_soc.u_cpu.instr_ex;
  assign o_pcsrc_ex           = u_soc.u_cpu.pcsrc_ex;
  assign o_hu_flush_ex        = u_soc.u_cpu.hu_flush_ex;
  assign o_hu_stall_ex        = u_soc.u_cpu.hu_stall_ex;
  assign o_pc_cntrl_wb        = u_soc.u_cpu.pc_cntrl_wb;
  assign o_trap_cntrl_wb      = u_soc.u_cpu.trap_cntrl_wb;
  assign o_trap_addr_if       = u_soc.u_cpu.trap_addr_if;

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

  // ---- UART internals ----
  assign o_uart_baud_div      = u_soc.u_uart.baud_divisor;
  assign o_uart_tx_state      = u_soc.u_uart.tx_state;
  assign o_uart_tx_baud_cnt   = u_soc.u_uart.tx_baud_cnt;
  assign o_uart_tx_fifo_rdata = u_soc.u_uart.tx_fifo_rdata;
  assign o_uart_tx_fifo_empty = u_soc.u_uart.tx_fifo_empty;
  assign o_uart_tx_fifo_full  = u_soc.u_uart.tx_fifo_full;
  assign o_uart_tx_shift      = u_soc.u_uart.tx_shift_reg;
  assign o_uart_rx_pin        = u_soc.u_uart.rx_pin;
  assign o_uart_awaddr        = u_soc.uart_awaddr;
  assign o_uart_awvalid       = u_soc.uart_awvalid;
  assign o_uart_wdata         = u_soc.uart_wdata;
  assign o_uart_wvalid        = u_soc.uart_wvalid;
  assign o_uart_wstrb         = u_soc.uart_wstrb[3:0];
  assign o_uart_tx_fifo_wdata = u_soc.u_uart.tx_fifo_wdata;
  assign o_uart_tx_fifo_we    = u_soc.u_uart.tx_fifo_we;
  assign o_dc_mmio_rd_req     = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_read_req;
  assign o_dc_mmio_rd_addr    = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_read_address;
  assign o_dc_mmio_rd_data    = u_soc.mmio_rd_data;
  assign o_dc_mmio_wr_valid   = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_write_valid;
  assign o_dc_mmio_wr_addr    = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_write_address;
  assign o_dc_mmio_wr_data    = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_write_data;
  assign o_dc_mmio_wr_strobe  = u_soc.u_cpu.u_riscv_core_dcache_top.dcache_controller.o_mmio_write_strobe;

  // ---- UART RX path ----
  assign o_uart_rx_state      = u_soc.u_uart.rx_state;
  assign o_uart_rx_baud_cnt   = u_soc.u_uart.rx_baud_cnt;
  assign o_uart_rx_shift      = u_soc.u_uart.rx_shift_reg;
  assign o_uart_rx_fifo_empty = u_soc.u_uart.rx_fifo_empty;
  assign o_uart_rx_fifo_wdata = u_soc.u_uart.rx_fifo_wdata;
  assign o_uart_rx_fifo_we    = u_soc.u_uart.rx_fifo_we;
  assign o_mmio_rd_req_raw    = u_soc.u_mmio_bridge.i_mmio_read_req;
  assign o_mmio_rd_addr_raw   = u_soc.u_mmio_bridge.i_mmio_read_addr;
  assign o_mmio_rd_data_raw   = u_soc.u_mmio_bridge.o_mmio_read_data;
  assign o_mmio_rd_core       = u_soc.u_mmio_arb.grant_r;

  // ---- PAIRED UART-slave probes ----
  assign o_uart_axi_rd_valid  = (u_soc.u_uart.axi_state == u_soc.u_uart.AXI_RD) && u_soc.u_uart.s_axi_rvalid;
  assign o_uart_axi_rd_addr   = u_soc.u_uart.axi_addr_r;
  assign o_uart_axi_rd_data   = u_soc.u_uart.s_axi_rdata;
  assign o_uart_rx_fifo_re    = u_soc.u_uart.rx_fifo_re;
  assign o_uart_rx_fifo_rd_ptr= u_soc.u_uart.rx_fifo_rd_ptr[0];
  assign o_uart_tx_fifo_re    = u_soc.u_uart.tx_fifo_re;
  assign o_uart_axi_wr_valid  = (u_soc.u_uart.axi_state == u_soc.u_uart.AXI_WR) && u_soc.u_uart.s_axi_wvalid;
  assign o_uart_axi_wr_addr   = u_soc.u_uart.axi_addr_r;
  assign o_uart_axi_wr_data   = u_soc.u_uart.s_axi_wdata;

endmodule