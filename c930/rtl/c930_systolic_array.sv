// -----------------------------------------------------------------------------
// c930_systolic_array.sv
//
// Weight-stationary systolic array: NUM_ROWS x NUM_COLS grid of PEs.
//
//   * Weights are loaded one PE per cycle through the (i_wrow, i_wcol) address.
//   * Activations enter on the left edge (i_act, one per row) and propagate
//     left -> right.
//   * Partial sums enter on the top edge (i_ps_in, one per column) and
//     propagate top -> bottom; completed results exit at o_ps_out.
//
// Double-buffered: i_wbank selects which weight bank to load into;
// i_bank_sel selects which bank the PEs compute with.
// -----------------------------------------------------------------------------

module c930_systolic_array
#(
  parameter int NUM_ROWS = 8,   // reduction length per pass
  parameter int NUM_COLS = 8,   // output width
  parameter int DIN_W    = 8,   // activation / weight width
  parameter int ACC_W    = 48   // accumulator width
)
(
  input  logic                                     i_clk,
  input  logic                                     i_rst_n,

  // Weight load: one PE per cycle, addressed by (row, col)
  input  logic                                     i_wen,
  input  logic                                     i_wbank,    // 0=write bank0, 1=write bank1
  input  logic [$clog2(NUM_ROWS)-1:0]              i_wrow,
  input  logic [$clog2(NUM_COLS)-1:0]              i_wcol,
  input  logic signed [DIN_W-1:0]                  i_wdata,

  // Bank select: which weight bank to compute with (broadcast to all PEs)
  input  logic                                     i_bank_sel,

  // Left-edge activations (one per row)
  input  logic signed [NUM_ROWS*DIN_W-1:0]         i_act,
  // Top-edge partial sums (one per column)
  input  logic signed [NUM_COLS*ACC_W-1:0]         i_ps_in,

  // Bottom-edge partial sums (one per column): completed outputs.
  output signed [ACC_W*NUM_COLS-1:0]               o_ps_out,

  // Precision control: broadcast to all PEs
  input  logic [2:0]                               i_precision
);

  // Horizontal activation buses
  logic signed [DIN_W-1:0] a_h [0:NUM_ROWS-1][0:NUM_COLS];

  // Vertical partial-sum buses
  logic signed [ACC_W-1:0] ps_v [0:NUM_ROWS][0:NUM_COLS-1];

  generate
    genvar r, c;
    for (r = 0; r < NUM_ROWS; r = r + 1) begin : g_row
      assign a_h[r][0] = i_act[r*DIN_W +: DIN_W];
      for (c = 0; c < NUM_COLS; c = c + 1) begin : g_col
        c930_tensor_pe #(
          .DIN_W (DIN_W),
          .ACC_W (ACC_W)
        ) u_pe (
          .i_clk      (i_clk),
          .i_rst_n    (i_rst_n),
          .i_wen      (i_wen &&
                       (i_wrow == r[$clog2(NUM_ROWS)-1:0]) &&
                       (i_wcol == c[$clog2(NUM_COLS)-1:0])),
          .i_wbank    (i_wbank),
          .i_wdata    (i_wdata),
          .i_bank_sel (i_bank_sel),
          .i_a_in     (a_h[r][c]),
          .o_a_out    (a_h[r][c+1]),
          .i_ps_in    (ps_v[r][c]),
          .o_ps_out   (ps_v[r+1][c]),
          .i_precision(i_precision)
        );
      end
    end
    for (c = 0; c < NUM_COLS; c = c + 1) begin : g_edge
      assign ps_v[0][c]                     = i_ps_in[c*ACC_W +: ACC_W];
      assign o_ps_out[c*ACC_W +: ACC_W]     = ps_v[NUM_ROWS][c];
    end
  endgenerate

endmodule
