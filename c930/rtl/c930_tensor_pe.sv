// -----------------------------------------------------------------------------
// c930_tensor_pe.sv
//
// One processing element of the weight-stationary systolic array.
//
//   * Weight `w` is stationary: loaded once via i_wen/i_wdata and held.
//   * Activation flows left -> right: o_a_out <= i_a_in (registered).
//   * Partial sum flows top -> bottom: o_ps_out <= i_ps_in + i_a_in * w.
//
// All operands are signed two's complement. The product is a DIN_W x DIN_W
// multiply accumulated into a ACC_W-wide partial sum.
// -----------------------------------------------------------------------------
module c930_tensor_pe
#(
  parameter int DIN_W = 8,   // activation / weight bit width
  parameter int ACC_W = 32   // accumulator bit width
)
(
  input  logic                        i_clk,
  input  logic                        i_rst_n,

  // Weight load (weight-stationary)
  input  logic                        i_wen,
  input  logic signed [DIN_W-1:0]     i_wdata,

  // Activation: in from the left neighbor, out to the right neighbor
  input  logic signed [DIN_W-1:0]     i_a_in,
  output logic signed [DIN_W-1:0]     o_a_out,

  // Partial sum: in from the top neighbor, out to the bottom neighbor
  input  logic signed [ACC_W-1:0]     i_ps_in,
  output logic signed [ACC_W-1:0]     o_ps_out
);

  logic signed [DIN_W-1:0] w;

  // Full-precision signed product (DIN_W x DIN_W -> 2*DIN_W); sign-extended to
  // ACC_W when added into the partial sum.
  logic signed [2*DIN_W-1:0] prod;
  assign prod = i_a_in * w;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      w        <= '0;
      o_a_out  <= '0;
      o_ps_out <= '0;
    end else begin
      if (i_wen)
        w <= i_wdata;

      o_a_out  <= i_a_in;
      o_ps_out <= i_ps_in + prod;
    end
  end

endmodule
