// -----------------------------------------------------------------------------
// c930_fp16_mul.sv
//
// Combinational FP16 × FP16 → FP32 multiplier.
// Denormals flushed to zero. Special cases handled per IEEE 754.
// -----------------------------------------------------------------------------

module c930_fp16_mul
(
  input  logic [15:0] i_a,
  input  logic [15:0] i_b,
  output logic [31:0] o_result
);

  logic        sign_a, sign_b;
  logic [4:0]  exp_a, exp_b;
  logic [9:0]  mant_a, mant_b;

  assign sign_a = i_a[15];
  assign exp_a  = i_a[14:10];
  assign mant_a = i_a[9:0];

  assign sign_b = i_b[15];
  assign exp_b  = i_b[14:10];
  assign mant_b = i_b[9:0];

  // ---- Classify ----
  wire is_zero_a = (exp_a == 5'd0);            // zero or denormal
  wire is_zero_b = (exp_b == 5'd0);
  wire is_inf_a  = (exp_a == 5'd31) && (mant_a == 10'd0);
  wire is_inf_b  = (exp_b == 5'd31) && (mant_b == 10'd0);
  wire is_nan_a  = (exp_a == 5'd31) && (mant_a != 10'd0);
  wire is_nan_b  = (exp_b == 5'd31) && (mant_b != 10'd0);

  wire res_sign = sign_a ^ sign_b;

  // ---- Mantissa product (normal × normal) ----
  // 11-bit with hidden leading 1 → 22-bit product
  logic [21:0] m_prod;
  assign m_prod = {1'b1, mant_a} * {1'b1, mant_b};

  // ---- Exponent ----
  // FP16 bias=15, FP32 bias=127 → fp32_exp = (exp_a-15)+(exp_b-15)+127 = exp_a+exp_b+97
  logic [7:0] fp32_exp_raw;
  assign fp32_exp_raw = exp_a + exp_b + 8'd97;

  // ---- Normalize and assemble FP32 mantissa ----
  logic [7:0]  final_exp;
  logic [22:0] fp32_mant;

  always_comb begin
    if (m_prod[21]) begin
      // Product in [2.0, 4.0): shift right 1
      final_exp = fp32_exp_raw + 8'd1;
      fp32_mant = {m_prod[20:0], 2'b0};     // 21+2=23 bits
    end else begin
      // Product in [1.0, 2.0): no shift
      final_exp = fp32_exp_raw;
      fp32_mant = {m_prod[19:0], 3'b0};     // 20+3=23 bits
    end
  end

  logic [31:0] normal_result;
  assign normal_result = {res_sign, final_exp, fp32_mant};

  // ---- Special cases ----
  always_comb begin
    if (is_nan_a || is_nan_b)
      o_result = {1'b0, 8'd255, 23'd1};
    else if (is_zero_a || is_zero_b)
      o_result = {res_sign, 8'd0, 23'd0};
    else if (is_inf_a && is_inf_b)
      o_result = {res_sign, 8'd255, 23'd0};
    else if (is_inf_a || is_inf_b)
      o_result = {res_sign, 8'd255, 23'd0};
    else
      o_result = normal_result;
  end

endmodule
