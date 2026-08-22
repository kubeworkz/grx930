// -----------------------------------------------------------------------------
// c930_fp16_acc.sv
//
// FP32 + FP32 → FP32 registered accumulator for the NPU systolic array.
//
// Takes a FP32 partial sum (i_ps_in) and a FP32 product (i_prod), produces
// the new FP32 partial sum (o_ps_out). The add is combinational; the result
// is registered to match the PE pipeline stage.
//
// FP32 format:
//   [31]    sign
//   [30:23] exponent  (bias = 127)
//   [22:0]  mantissa  (hidden leading 1 for normals)
//
// Special cases:
//   inf + x  = inf  (with correct sign)
//   NaN + x  = NaN
//   denormals flushed to zero
// -----------------------------------------------------------------------------

module c930_fp32_acc
(
  input  logic        i_clk,
  input  logic        i_rst_n,
  input  logic [31:0] i_ps_in,  // FP32 partial sum from top neighbor
  input  logic [31:0] i_prod,   // FP32 product from FP16 multiplier
  output logic [31:0] o_ps_out  // FP32 partial sum to bottom neighbor
);

  // ---- Extract fields for i_ps_in ----
  logic        sign_s;
  logic [7:0]  exp_s;
  logic [22:0] mant_s;

  assign sign_s = i_ps_in[31];
  assign exp_s  = i_ps_in[30:23];
  assign mant_s = i_ps_in[22:0];

  // ---- Extract fields for i_prod ----
  logic        sign_p;
  logic [7:0]  exp_p;
  logic [22:0] mant_p;

  assign sign_p = i_prod[31];
  assign exp_p  = i_prod[30:23];
  assign mant_p = i_prod[22:0];

  // ---- Classify ----
  wire is_zero_s  = (exp_s == 8'd0)  && (mant_s == 23'd0);
  wire is_zero_p  = (exp_p == 8'd0)  && (mant_p == 23'd0);
  wire is_inf_s   = (exp_s == 8'd255) && (mant_s == 23'd0);
  wire is_inf_p   = (exp_p == 8'd255) && (mant_p == 23'd0);
  wire is_nan_s   = (exp_s == 8'd255) && (mant_s != 23'd0);
  wire is_nan_p   = (exp_p == 8'd255) && (mant_p != 23'd0);

  // ---- Align exponents ----
  // Compare exponents and shift the smaller one's mantissa right
  logic [7:0] exp_diff;
  logic [7:0]  exp_larger;
  logic [26:0] mant_a, mant_b;  // 27 bits: 1 hidden + 23 mantissa + 3 guard bits
  logic        sign_larger;

  always_comb begin
    if (is_zero_s) begin
      // 0 + x = x
      exp_larger  = exp_p;
      sign_larger = sign_p;
      mant_a      = {1'b0, mant_p, 3'b0};  // product
      mant_b      = '0;                     // zero
    end else if (is_zero_p) begin
      // x + 0 = x
      exp_larger  = exp_s;
      sign_larger = sign_s;
      mant_a      = {1'b0, mant_s, 3'b0};  // partial sum
      mant_b      = '0;                     // zero
    end else begin
      // Both non-zero: align by exponent difference
      if (exp_s >= exp_p) begin
        exp_larger  = exp_s;
        sign_larger = sign_s;
        exp_diff    = exp_s - exp_p;
        mant_a      = {1'b0, mant_s, 3'b0};             // larger
        mant_b      = {1'b0, mant_p, 3'b0} >> exp_diff;  // smaller, shifted right
      end else begin
        exp_larger  = exp_p;
        sign_larger = sign_p;
        exp_diff    = exp_p - exp_s;
        mant_a      = {1'b0, mant_p, 3'b0};             // larger
        mant_b      = {1'b0, mant_s, 3'b0} >> exp_diff;  // smaller, shifted right
      end
    end
  end

  // ---- Add/subtract mantissas ----
  logic [27:0] sum_mant;   // 28 bits to detect overflow
  logic        sum_sign;

  always_comb begin
    if (is_zero_s && is_zero_p) begin
      sum_mant  = '0;
      sum_sign  = 1'b0;
    end else if (sign_s == sign_p || is_zero_s || is_zero_p) begin
      // Same sign: add
      sum_mant = {1'b0, mant_a} + {1'b0, mant_b};
      sum_sign = sign_larger;
    end else begin
      // Different signs: subtract
      if (mant_a >= mant_b) begin
        sum_mant = {1'b0, mant_a} - {1'b0, mant_b};
        sum_sign = sign_larger;
      end else begin
        sum_mant = {1'b0, mant_b} - {1'b0, mant_a};
        sum_sign = ~sign_larger;
      end
    end
  end

  // ---- Normalize result ----
  logic [7:0]  final_exp;
  logic [22:0] final_mant;

  always_comb begin
    if (is_nan_s || is_nan_p) begin
      // NaN propagation
      final_exp  = 8'd255;
      final_mant = 23'd1;
    end else if (is_inf_s) begin
      final_exp  = 8'd255;
      final_mant = 23'd0;
    end else if (is_inf_p) begin
      final_exp  = 8'd255;
      final_mant = 23'd0;
    end else if (is_zero_s && is_zero_p) begin
      final_exp  = 8'd0;
      final_mant = 23'd0;
    end else if (sum_mant[27]) begin
      // Overflow from addition: shift right 1, increment exponent
      final_exp  = exp_larger + 8'd1;
      final_mant = sum_mant[26:4];  // take bits [26:4] → 23 mantissa bits
    end else if (sum_mant[26]) begin
      // No overflow, leading 1 at bit 26
      final_exp  = exp_larger;
      final_mant = sum_mant[25:3];  // bits [25:3] → 23 mantissa bits
    end else if (sum_mant == 0) begin
      // Result is zero
      final_exp  = 8'd0;
      final_mant = 23'd0;
    end else begin
      // Need to normalize: find leading 1 and shift
      // Simple priority encoder for normalization (up to 23 shifts)
      logic [7:0] shift;
      logic [27:0] shifted;
      shifted = sum_mant;
      shift = 0;
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end
      if (!shifted[26]) begin shifted = shifted << 1; shift = shift + 1; end

      if (exp_larger >= shift)
        final_exp  = exp_larger - shift;
      else
        final_exp  = 8'd0;  // underflow → denormal, flush to zero
      final_mant = shifted[25:3];
    end
  end

  // ---- Output ----
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      o_ps_out <= '0;
    else
      o_ps_out <= {sum_sign, final_exp, final_mant};
  end

endmodule
