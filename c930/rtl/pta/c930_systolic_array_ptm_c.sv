// -----------------------------------------------------------------------------
// c930_systolic_array_ptm_c.sv
//
// Stands in for rtl/c930_systolic_array.sv when a bench is built with PTM_C=1
// (see the Makefile): the same module name and port list, built from PTM-C
// (c930_ptm_c.sv), so the core, DMA and CSR compile unchanged around it.
//
// Define PTM_C_ABLATE_ROW to move that row's de-skew one window late -- phase
// C0's ablation, which the NPU testbenches must catch.
// -----------------------------------------------------------------------------

module c930_systolic_array
#(
  parameter int NUM_ROWS = 8,
  parameter int NUM_COLS = 8,
  parameter int DIN_W    = 8,
  parameter int ACC_W    = 48
)
(
  input  logic                                     i_clk,
  input  logic                                     i_rst_n,

  input  logic                                     i_wen,
  input  logic                                     i_wbank,
  input  logic [$clog2(NUM_ROWS)-1:0]              i_wrow,
  input  logic [$clog2(NUM_COLS)-1:0]              i_wcol,
  input  logic signed [DIN_W-1:0]                  i_wdata,

  input  logic                                     i_bank_sel,

  input  logic signed [NUM_ROWS*DIN_W-1:0]         i_act,
  input  logic signed [NUM_COLS*ACC_W-1:0]         i_ps_in,

  output signed [ACC_W*NUM_COLS-1:0]               o_ps_out,

  input  logic [2:0]                               i_precision,

  input  logic [NUM_ROWS-1:0]                      i_row_en
);

`ifdef PTM_C_ABLATE_ROW
  localparam int ABLATE_ROW = `PTM_C_ABLATE_ROW;
`else
  localparam int ABLATE_ROW = -1;
`endif

  c930_ptm_c #(
    .NUM_ROWS   (NUM_ROWS),
    .NUM_COLS   (NUM_COLS),
    .DIN_W      (DIN_W),
    .ACC_W      (ACC_W),
    .ABLATE_ROW (ABLATE_ROW)
  ) u_ptm_c (
    .i_clk      (i_clk),
    .i_rst_n    (i_rst_n),
    .i_wen      (i_wen),
    .i_wbank    (i_wbank),
    .i_wrow     (i_wrow),
    .i_wcol     (i_wcol),
    .i_wdata    (i_wdata),
    .i_bank_sel (i_bank_sel),
    .i_act      (i_act),
    .i_ps_in    (i_ps_in),
    .o_ps_out   (o_ps_out),
    .i_precision(i_precision),
    .i_row_en   (i_row_en)
  );

endmodule
