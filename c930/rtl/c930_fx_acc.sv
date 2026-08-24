// -----------------------------------------------------------------------------
// c930_fx_acc.sv
//
// Fixed-point FP32 + FP32 -> FP32 accumulator for the NPU systolic array.
// Replaces c930_fp16_acc in FP16/BF16 modes to break the critical path.
//
// Key insight: skip per-cycle full FP32 normalization (LZC + shift + pack).
// Instead, accumulate in a wider fixed-point format and renormalize only when
// the result has leading zeros (subtraction case) — a cheap 4-bit shift.
// This is ~3x faster than the full normalizer.
//
// Format: {sign[47], exp[39:32], mantissa[31:0]}
//   - sign: 1 bit
//   - exp:  8 bits (IEEE 754 bias-127)
//   - mant: 32 bits, hidden 1 at bit 31 (normalized position)
//
// Critical path: sort + barrel-shift + add + 4-bit renorm ≈ 12 ns
//   (vs. ~25 ns for the old FP32 accumulator that included full LZC + normalize).
// -----------------------------------------------------------------------------

module c930_fx_acc
(
  input  logic [47:0] i_ps_in,    // 48-bit fixed-point partial sum from top neighbor
  input  logic [31:0] i_prod,     // FP32 product from FP16/BF16 multiplier
  output logic [47:0] o_ps_out    // 48-bit fixed-point result
);

  // =========================================================================
  // 1. Extract fields
  // =========================================================================

  wire        s_sign = i_ps_in[47];
  wire [7:0]  s_exp  = i_ps_in[39:32];
  wire [31:0] s_mant = i_ps_in[31:0];

  wire        p_sign = i_prod[31];
  wire [7:0]  p_exp  = i_prod[30:23];
  wire [22:0] p_mant_stored = i_prod[22:0];

  // Hidden bit: 0 for zero/denorm, 1 for normal/inf/nan
  wire        p_hidden = (p_exp != 8'd0);
  wire [23:0] p_mant_full = {p_hidden, p_mant_stored};

  // =========================================================================
  // 2. Classify
  // =========================================================================

  wire s_zero = (s_exp == 8'd0) && (s_mant == 32'd0);
  wire p_zero = (p_exp == 8'd0) && (p_mant_stored == 23'd0);
  wire s_nan  = (s_exp == 8'd255) && (s_mant != 32'd0);
  wire p_nan  = (p_exp == 8'd255) && (p_mant_stored != 23'd0);
  wire s_inf  = (s_exp == 8'd255) && (s_mant == 32'd0);
  wire p_inf  = (p_exp == 8'd255) && (p_mant_stored == 23'd0);

  wire both_zero = s_zero && p_zero;

  // =========================================================================
  // 3. Sort: A has the larger (or equal) exponent
  // =========================================================================

  // Mantissa hidden 1 is at bit 31; compare upper 24 bits.
  wire swap = (p_exp > s_exp) || ((p_exp == s_exp) && (p_mant_full > s_mant[31:8]));

  wire [7:0]  exp_a  = swap ? p_exp  : s_exp;
  // Product: shift left by 8 to move hidden 1 from bit 23 to bit 31.
  wire [31:0] mant_a = swap ? {p_mant_full, 8'd0} : s_mant;
  wire        sign_a = swap ? p_sign : s_sign;

  wire [7:0]  exp_b  = swap ? s_exp  : p_exp;
  wire [31:0] mant_b = swap ? s_mant : {p_mant_full, 8'd0};
  wire        sign_b = swap ? s_sign : p_sign;

  wire [7:0] exp_diff = exp_a - exp_b;

  // =========================================================================
  // 4. Align mantissas (barrel-shift the smaller right)
  // =========================================================================

  wire [39:0] mant_b_ext = {8'd0, mant_b};  // 40-bit for shift headroom

  wire [39:0] mant_b_shifted =
    (exp_diff == 8'd0)  ? mant_b_ext :
    (exp_diff == 8'd1)  ? {1'd0,  mant_b_ext[39:1]} :
    (exp_diff == 8'd2)  ? {2'd0,  mant_b_ext[39:2]} :
    (exp_diff == 8'd3)  ? {3'd0,  mant_b_ext[39:3]} :
    (exp_diff == 8'd4)  ? {4'd0,  mant_b_ext[39:4]} :
    (exp_diff == 8'd5)  ? {5'd0,  mant_b_ext[39:5]} :
    (exp_diff == 8'd6)  ? {6'd0,  mant_b_ext[39:6]} :
    (exp_diff == 8'd7)  ? {7'd0,  mant_b_ext[39:7]} :
    (exp_diff == 8'd8)  ? {8'd0,  mant_b_ext[39:8]} :
    (exp_diff == 8'd9)  ? {9'd0,  mant_b_ext[39:9]} :
    (exp_diff == 8'd10) ? {10'd0, mant_b_ext[39:10]} :
    (exp_diff == 8'd11) ? {11'd0, mant_b_ext[39:11]} :
    (exp_diff == 8'd12) ? {12'd0, mant_b_ext[39:12]} :
    (exp_diff == 8'd13) ? {13'd0, mant_b_ext[39:13]} :
    (exp_diff == 8'd14) ? {14'd0, mant_b_ext[39:14]} :
    (exp_diff == 8'd15) ? {15'd0, mant_b_ext[39:15]} :
    (exp_diff == 8'd16) ? {16'd0, mant_b_ext[39:16]} :
    (exp_diff == 8'd17) ? {17'd0, mant_b_ext[39:17]} :
    (exp_diff == 8'd18) ? {18'd0, mant_b_ext[39:18]} :
    (exp_diff == 8'd19) ? {19'd0, mant_b_ext[39:19]} :
    (exp_diff == 8'd20) ? {20'd0, mant_b_ext[39:20]} :
    (exp_diff == 8'd21) ? {21'd0, mant_b_ext[39:21]} :
    (exp_diff == 8'd22) ? {22'd0, mant_b_ext[39:22]} :
    (exp_diff == 8'd23) ? {23'd0, mant_b_ext[39:23]} :
    (exp_diff == 8'd24) ? {24'd0, mant_b_ext[39:24]} :
    (exp_diff == 8'd25) ? {25'd0, mant_b_ext[39:25]} :
    (exp_diff == 8'd26) ? {26'd0, mant_b_ext[39:26]} :
    (exp_diff == 8'd27) ? {27'd0, mant_b_ext[39:27]} :
    (exp_diff == 8'd28) ? {28'd0, mant_b_ext[39:28]} :
    (exp_diff == 8'd29) ? {29'd0, mant_b_ext[39:29]} :
    (exp_diff == 8'd30) ? {30'd0, mant_b_ext[39:30]} :
                          {31'd0, mant_b_ext[39:31]};

  wire [31:0] mant_b_aligned = mant_b_shifted[31:0];

  // =========================================================================
  // 5. Add / subtract magnitudes
  // =========================================================================

  wire signs_same = (sign_a == sign_b);

  wire [32:0] sum_same = {1'b0, mant_a} + {1'b0, mant_b_aligned};
  wire [32:0] sum_diff = (mant_a >= mant_b_aligned)
                       ? ({1'b0, mant_a} - {1'b0, mant_b_aligned})
                       : ({1'b0, mant_b_aligned} - {1'b0, mant_a});

  wire        a_geq_b = (mant_a >= mant_b_aligned);
  wire        result_sign = signs_same ? sign_a : (a_geq_b ? sign_a : sign_b);

  wire [32:0] sum_raw =
    both_zero  ? 33'd0 :
    s_zero     ? {1'b0, mant_a} :
    p_zero     ? {1'b0, mant_a} :
    signs_same ? sum_same :
                 sum_diff;

  // =========================================================================
  // 6. Post-add normalization
  //    - Overflow (bit 32 set): shift right by 1, increment exp
  //    - Underflow (no leading 1 at bit 31): shift left until bit 31 is set,
  //      decrement exp.  Max 24 positions for FP16/BF16 (K up to 256).
  // =========================================================================

  wire overflow = sum_raw[32];

  // Left-shift count: count leading zeros starting from bit 31
  wire [4:0] lzc =
    sum_raw[31] ? 5'd0  :
    sum_raw[30] ? 5'd1  :
    sum_raw[29] ? 5'd2  :
    sum_raw[28] ? 5'd3  :
    sum_raw[27] ? 5'd4  :
    sum_raw[26] ? 5'd5  :
    sum_raw[25] ? 5'd6  :
    sum_raw[24] ? 5'd7  :
    sum_raw[23] ? 5'd8  :
    sum_raw[22] ? 5'd9  :
    sum_raw[21] ? 5'd10 :
    sum_raw[20] ? 5'd11 :
    sum_raw[19] ? 5'd12 :
    sum_raw[18] ? 5'd13 :
    sum_raw[17] ? 5'd14 :
    sum_raw[16] ? 5'd15 :
    sum_raw[15] ? 5'd16 :
    sum_raw[14] ? 5'd17 :
    sum_raw[13] ? 5'd18 :
    sum_raw[12] ? 5'd19 :
    sum_raw[11] ? 5'd20 :
    sum_raw[10] ? 5'd21 :
    sum_raw[9]  ? 5'd22 :
    sum_raw[8]  ? 5'd23 :
    sum_raw[7]  ? 5'd24 :
                  5'd25;  // zero or tiny

  // Left-shift barrel mux (max 25 positions)
  wire [32:0] lshifted =
    (lzc == 5'd0)  ? sum_raw :
    (lzc == 5'd1)  ? {sum_raw[31:0], 1'd0} :
    (lzc == 5'd2)  ? {sum_raw[30:0], 2'd0} :
    (lzc == 5'd3)  ? {sum_raw[29:0], 3'd0} :
    (lzc == 5'd4)  ? {sum_raw[28:0], 4'd0} :
    (lzc == 5'd5)  ? {sum_raw[27:0], 5'd0} :
    (lzc == 5'd6)  ? {sum_raw[26:0], 6'd0} :
    (lzc == 5'd7)  ? {sum_raw[25:0], 7'd0} :
    (lzc == 5'd8)  ? {sum_raw[24:0], 8'd0} :
    (lzc == 5'd9)  ? {sum_raw[23:0], 9'd0} :
    (lzc == 5'd10) ? {sum_raw[22:0], 10'd0} :
    (lzc == 5'd11) ? {sum_raw[21:0], 11'd0} :
    (lzc == 5'd12) ? {sum_raw[20:0], 12'd0} :
    (lzc == 5'd13) ? {sum_raw[19:0], 13'd0} :
    (lzc == 5'd14) ? {sum_raw[18:0], 14'd0} :
    (lzc == 5'd15) ? {sum_raw[17:0], 15'd0} :
    (lzc == 5'd16) ? {sum_raw[16:0], 16'd0} :
    (lzc == 5'd17) ? {sum_raw[15:0], 17'd0} :
    (lzc == 5'd18) ? {sum_raw[14:0], 18'd0} :
    (lzc == 5'd19) ? {sum_raw[13:0], 19'd0} :
    (lzc == 5'd20) ? {sum_raw[12:0], 20'd0} :
    (lzc == 5'd21) ? {sum_raw[11:0], 21'd0} :
    (lzc == 5'd22) ? {sum_raw[10:0], 22'd0} :
    (lzc == 5'd23) ? {sum_raw[9:0],  23'd0} :
    (lzc == 5'd24) ? {sum_raw[8:0],  24'd0} :
                      {sum_raw[7:0],  25'd0};

  // Apply normalization: overflow → right-shift; underflow → left-shift
  wire [31:0] mant_normalized = overflow ? sum_raw[32:1] : lshifted[31:0];
  wire [7:0]  exp_normalized  = overflow ? (exp_a + 8'd1) :
                                (sum_raw == 33'd0) ? 8'd0 :
                                (exp_a - {3'd0, lzc});

  // =========================================================================
  // 7. Pack output
  // =========================================================================

  wire [47:0] result =
    (s_nan || p_nan)         ? {result_sign, 8'd255, 32'd1} :
    (s_inf || p_inf)         ? {result_sign, 8'd255, 32'd0} :
    (both_zero)              ? {1'b0, 8'd0, 32'd0} :
    (sum_raw == 33'd0)       ? {result_sign, 8'd0, 32'd0} :
    {result_sign, exp_normalized, mant_normalized};

  assign o_ps_out = result;

endmodule
