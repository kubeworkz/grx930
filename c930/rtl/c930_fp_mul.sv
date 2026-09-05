// -----------------------------------------------------------------------------
// c930_fp_mul.sv
//
// Merged FP16×FP16 → FP32 and BF16×BF16 → FP32 multiplier.
//
// Replaces the two parallel multipliers (c930_fp16_mul + c930_bf16_mul) that
// used to sit side-by-side in every tensor PE.  A BF16 mantissa
// {1'b1, 7-bit mant} zero-extended to 11 bits has the same numeric value as
// the FP16-style operand, and shifting it up by 3 places {1'b1, m[6:0], 3'b0}
// aligns the BF16 16-bit product into exactly the same [20:0] window as the
// FP16 22-bit product.  One shared 11×11 multiply therefore serves both
// formats; only the exponent arithmetic and mantissa finalization are
// precision-muxed.
//
//  i_mode: 0 = FP16 (exp[4:0] = [14:10], mant = [9:0], bias 15)
//          1 = BF16 (exp[7:0] = [14:7], mant = [6:0], bias 127)
//
// Denormals flushed to zero.  Special cases handled per IEEE 754 with the
// same priority as the original split modules (NaN, then zero, then inf),
// and outputs are bit-identical to the previous c930_fp16_mul / c930_bf16_mul
// for every input (including their historical exponent-wrap behavior in the
// far overflow/underflow corners, which is outside any practical GEMM range).
// -----------------------------------------------------------------------------

module c930_fp_mul
(
  input  logic [15:0] i_a,
  input  logic [15:0] i_b,
  input  logic        i_mode,   // 0 = FP16, 1 = BF16
  output logic [31:0] o_result
);

  wire        sign_a = i_a[15];
  wire        sign_b = i_b[15];

  // ---- Mode-muxed operand decode ----
  wire [7:0]  exp_a  = i_mode ? i_a[14:7]            : {3'b0, i_a[14:10]};
  wire [7:0]  exp_b  = i_mode ? i_b[14:7]            : {3'b0, i_b[14:10]};
  wire [6:0]  mant7_a = i_a[6:0];
  wire [6:0]  mant7_b = i_b[6:0];
  wire [9:0]  mant10_a = i_a[9:0];
  wire [9:0]  mant10_b = i_b[9:0];

  // 11-bit normalized operands.  BF16 keeps the hidden bit at bit 10 and the
  // 7-bit fraction in bits [6:0] (bits [9:7] forced to 0), i.e. the BF16
  // mantissa << 3.  FP16 places its 10-bit fraction in bits [9:0].
  wire [10:0] mul_a = i_mode ? {1'b1, mant7_a, 3'b0} : {1'b1, mant10_a};
  wire [10:0] mul_b = i_mode ? {1'b1, mant7_b, 3'b0} : {1'b1, mant10_b};

  // ---- Shared mantissa product (single 11x11 -> DSP48) ----
  // FP16: 22-bit product in [2^20, 2^22).  BF16: real 16-bit product shifted
  // left 6, so overflow (product >= 2.0) is m_prod[21] in both formats.
  logic [21:0] m_prod;
  assign m_prod = mul_a * mul_b;

  // ---- Classify ----
  wire [7:0] exp_max   = i_mode ? 8'd255 : 8'd31;
  wire       mant_zero_a = i_mode ? (mant7_a  == 7'd0) : (mant10_a == 10'd0);
  wire       mant_zero_b = i_mode ? (mant7_b  == 7'd0) : (mant10_b == 10'd0);

  wire is_zero_a = (exp_a == 8'd0);                 // zero or denormal
  wire is_zero_b = (exp_b == 8'd0);
  wire is_inf_a  = (exp_a == exp_max) &&  mant_zero_a;
  wire is_inf_b  = (exp_b == exp_max) &&  mant_zero_b;
  wire is_nan_a  = (exp_a == exp_max) && !mant_zero_a;
  wire is_nan_b  = (exp_b == exp_max) && !mant_zero_b;

  wire res_sign = sign_a ^ sign_b;

  // ---- Exponent ----
  // FP16: bias 15 -> FP32 bias 127: exp_a + exp_b + 97.
  // BF16: bias 127 -> FP32 bias 127: exp_a + exp_b - 127.
  wire [7:0] fp32_exp_raw = i_mode ? (exp_a + exp_b - 8'd127)
                                   : (exp_a + exp_b + 8'd97);
  wire [7:0] norm_exp = m_prod[21] ? (fp32_exp_raw + 8'd1) : fp32_exp_raw;

  // ---- Normalize and assemble FP32 mantissa ----
  wire [22:0] fp16_mant = m_prod[21] ? {m_prod[20:0], 2'b0}
                                     : {m_prod[19:0], 3'b0};
  wire [22:0] bf16_mant = m_prod[21] ? {m_prod[20:6], 8'b0}
                                     : {m_prod[19:6], 9'b0};
  wire [22:0] fp32_mant = i_mode ? bf16_mant : fp16_mant;

  wire [31:0] normal_result = {res_sign, norm_exp, fp32_mant};

  // ---- Special cases (same priority as original split modules) ----
  always_comb begin
    if (is_nan_a || is_nan_b)
      o_result = {1'b0, 8'd255, 23'd1};       // quiet NaN
    else if (is_zero_a || is_zero_b)
      o_result = {res_sign, 8'd0, 23'd0};     // flush to zero
    else if (is_inf_a || is_inf_b)
      o_result = {res_sign, 8'd255, 23'd0};   // infinity
    else
      o_result = normal_result;
  end

endmodule
