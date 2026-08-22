// -----------------------------------------------------------------------------
// c930_tensor_pe.sv
//
// One processing element of the weight-stationary systolic array.
//
//   * Weight `w` is stationary: loaded once via i_wen/i_wdata and held.
//   * Activation flows left -> right: o_a_out <= i_a_in (registered).
//   * Partial sum flows top -> bottom.
//
// Supports two datapaths based on i_precision:
//   - INT8/INT16 (precision 0/1): signed integer MAC (existing path)
//   - FP16 (precision 2): FP16 × FP16 → FP32 multiplier + FP32 accumulator
//
// For INT8/INT16: All operands are signed two's complement. The product is
// DIN_W × DIN_W multiply accumulated into a ACC_W-wide partial sum.
//
// For FP16: Inputs are FP16 bit patterns (reinterpreted from the signed
// DIN_W bus). The FP16 multiplier produces FP32, and the FP32 accumulator
// adds to the FP32 partial sum.
// -----------------------------------------------------------------------------

module c930_tensor_pe
#(
  parameter int DIN_W = 8,   // activation / weight bit width (16 for INT8/INT16/FP16)
  parameter int ACC_W = 32   // accumulator bit width (40 for int, 32 for FP32)
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
  output logic signed [ACC_W-1:0]     o_ps_out,

  // Precision control: 0=INT8, 1=INT16, 2=FP16
  input  logic [1:0]                  i_precision
);

  // ---- Weight register ----
  logic signed [DIN_W-1:0] w;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      w <= '0;
    else if (i_wen)
      w <= i_wdata;
  end

  // Activation passthrough (registered, regardless of mode)
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      o_a_out <= '0;
    else
      o_a_out <= i_a_in;
  end

  // ---- Integer MAC path (INT8/INT16) ----
  logic signed [2*DIN_W-1:0] int_prod;
  assign int_prod = i_a_in * w;

  logic signed [ACC_W-1:0] int_ps_out;
  assign int_ps_out = i_ps_in + int_prod;

  // ---- FP16 MAC path ----
  // Reinterpret DIN_W-bit signed inputs as unsigned FP16 bit patterns
  logic [15:0] fp16_a, fp16_w;
  assign fp16_a = i_a_in[15:0];
  assign fp16_w = w[15:0];

  // FP16 × FP16 → FP32 product (combinational)
  logic [31:0] fp32_prod;
  c930_fp16_mul u_fp16_mul (
    .i_a      (fp16_a),
    .i_b      (fp16_w),
    .o_result (fp32_prod)
  );

  // FP32 + FP32 → FP32 accumulator (registered, same stage as integer MAC)
  logic [31:0] fp32_ps_out;
  c930_fp16_acc u_fp16_acc (
    .i_clk    (i_clk),
    .i_rst_n  (i_rst_n),
    .i_ps_in  (i_ps_in[31:0]),   // lower 32 bits of ACC_W partial sum
    .i_prod   (fp32_prod),
    .o_ps_out (fp32_ps_out)
  );

  // ---- Output mux based on precision ----
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      o_ps_out <= '0;
    else if (i_precision == 2'd2) begin
      // FP16 mode: use FP32 accumulator output
      o_ps_out[ACC_W-1:32] <= '0;  // zero-extend upper bits (if ACC_W > 32)
      o_ps_out[31:0]        <= fp32_ps_out;
    end else begin
      // INT8/INT16 mode: use integer MAC output
      o_ps_out <= int_ps_out;
    end
  end

endmodule
