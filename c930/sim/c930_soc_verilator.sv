module c930_soc_verilator (
  input  logic i_clk,
  input  logic i_rst_n,
  output logic o_npu_busy,
  output logic o_npu_done,
  output logic o_npu_error,
  output logic o_npu_irq
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
    .o_npu_irq  (o_npu_irq)
  );

endmodule
