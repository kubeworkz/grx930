// -----------------------------------------------------------------------------
// c930_bf16_mul.sv
//
// Combinational BF16 × BF16 → FP32 multiplier.
// BF16 format: 1 sign + 8 exp + 7 mant, bias=127 (same exponent range as FP32).
// Denormals flushed to zero. Special cases handled per IEEE 754.
//
// Since BF16 and FP32 share the same exponent width and bias, the product
// exponent is simply exp_a + exp_b - 127 (no bias conversion needed).
// The 8-bit mantissa product (9-bit with hidden 1) fits easily in FP32's
// 23-bit mantissa with padding.
// -----------------------------------------------------------------------------

module c930_bf16_mul
(
  input  logic [15:0] i_a,
  input  logic [15:0] i_b,
  output logic [31:0] o_result
);

  logic        sign_a, sign_b;
  logic [7:0]  exp_a, exp_b;
  logic [6:0]  mant_a, mant_b;

  assign sign_a = i_a[15];
  assign exp_a  = i_a[14:7];
  assign mant_a = i_a[6:0];

  assign sign_b = i_b[15];
  assign exp_b  = i_b[14:7];
  assign mant_b = i_b[6:0];

  // ---- Classify ----
  wire is_zero_a = (exp_a == 8'd0);            // zero or denormal
  wire is_zero_b = (exp_b == 8'd0);
  wire is_inf_a  = (exp_a == 8'd255) && (mant_a == 7'd0);
  wire is_inf_b  = (exp_b == 8'd255) && (mant_b == 7'd0);
  wire is_nan_a  = (exp_a == 8'd255) && (mant_a != 7'd0);
  wire is_nan_b  = (exp_b == 8'd255) && (mant_b != 7'd0);

  wire res_sign = sign_a ^ sign_b;

  // ---- Mantissa product (normal × normal) ----
  // 8-bit with hidden leading 1 → 16-bit product
  logic [15:0] m_prod;
  assign m_prod = {1'b1, mant_a} * {1'b1, mant_b};

  // ---- Exponent ----
  // BF16 bias=127, FP32 bias=127 → fp32_exp = (exp_a-127)+(exp_b-127)+127 = exp_a+exp_b-127
  logic [7:0] fp32_exp_raw;
  assign fp32_exp_raw = exp_a + exp_b - 8'd127;

  // ---- Normalize and assemble FP32 mantissa ----
  // m_prod is 16 bits: [15] = overflow (product >= 2.0), [14:0] = fraction
  logic [7:0]  final_exp;
  logic [22:0] fp32_mant;

  // Use continuous assignments to avoid Icarus part-select issues
  wire [7:0]  norm_exp  = m_prod[15] ? (fp32_exp_raw + 8'd1) : fp32_exp_raw;
  wire [22:0] norm_mant = m_prod[15] ? {m_prod[14:0], 8'b0} :   // 15+8=23 bits
                                         {m_prod[13:0], 9'b0};   // 14+9=23 bits

  logic [31:0] normal_result;
  assign normal_result = {res_sign, norm_exp, norm_mant};

  // ---- Special cases ----
  always_comb begin
    if (is_nan_a || is_nan_b)
      o_result = {1'b0, 8'd255, 23'd1};       // quiet NaN
    else if (is_zero_a || is_zero_b)
      o_result = {res_sign, 8'd0, 23'd0};      // flush to zero
    else if (is_inf_a || is_inf_b)
      o_result = {res_sign, 8'd255, 23'd0};    // infinity
    else
      o_result = normal_result;
  end

endmodule
