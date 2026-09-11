// c930_soc_verilator.sv -- Verilator harness top for the single-core SoC.
//
// Exposes the UART pins (o_uart_txd / i_uart_rxd) and the DDR testbench
// preload/readback ports so a C++ testbench can load firmware into DDR,
// release reset, and talk to the core over the 16550 UART (0x4000_1000).
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
  output logic [7:0]  o_tb_rd_data
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

endmodule