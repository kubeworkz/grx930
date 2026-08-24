// -----------------------------------------------------------------------------
// c930_fx_acc.sv
//
// Fixed-point FP32 + FP32 -> FP32 accumulator for the NPU systolic array.
// Replaces c930_fp16_acc in FP16/BF16 modes to break the critical path.
//
// Key insight: skip per-cycle LZC + normalize.  Accumulate in a wider
// fixed-point format (32-bit mantissa + 8-bit exponent + sign = 41 bits,
// packed into 48-bit bus).  Normalize once at writeback (S_WRITE in the core).
//
// Critical path: sort + barrel-shift + add + overflow-check ≈ 12 ns
//   (vs. ~25 ns for the old FP32 accumulator that included LZC + normalize).
//
// Format: {sign[47], exp[39:32], mantissa[31:0]}
//   - sign: 1 bit
//   - exp:  8 bits (IEEE 754 bias-127)
//   - mant: 32 bits (24 effective + 8 guard bits for K up to 256)
//
// The mantissa can grow beyond 24 bits during accumulation.  If it overflows
// bit 32, we shift right by 1 and increment the exponent (at most once per
// cycle).  Precision loss is at most log2(K) bits — acceptable for INT8/INT16/
// FP16/BF16 workloads.
//
// Avoids part-selects inside always_comb (Icarus limitation) by using
// continuous assignments throughout.
// -----------------------------------------------------------------------------

module c930_fx_acc
(
  input  logic [47:0] i_ps_in,    // 48-bit fixed-point partial sum from top neighbor
  input  logic [31:0] i_prod,     // FP32 product from FP16/BF16 multiplier
  output logic [47:0] o_ps_out    // 48-bit fixed-point result (no normalization)
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
  // Store mantissa with hidden 1 at bit 31 (normalized position).
  // Product: shift left by 8 to move hidden 1 from bit 23 to bit 31.
  // Partial sum: already in this format from previous accumulator output.
  wire [31:0] mant_a = swap ? {p_mant_full, 8'd0} : s_mant;
  wire        sign_a = swap ? p_sign : s_sign;

  wire [7:0]  exp_b  = swap ? s_exp  : p_exp;
  wire [31:0] mant_b = swap ? s_mant : {p_mant_full, 8'd0};
  wire        sign_b = swap ? s_sign : p_sign;

  wire [7:0] exp_diff = exp_a - exp_b;

  // =========================================================================
  // 4. Align mantissas (barrel-shift the smaller right)
  // =========================================================================

  // Shift mant_b right by exp_diff (0..31).  Use a40-bit intermediate to
  // preserve guard bits during the shift, then truncate to 32 bits.
  wire [39:0] mant_b_ext = {8'd0, mant_b};  // 40-bit zero-padded at MSB for shift headroom

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

  // Truncate shifted B to 32 bits (lower 32 of the 40-bit result)
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
  // 6. Overflow check: if bit 32 is set, shift right by 1, increment exp
  // =========================================================================

  wire        overflow = sum_raw[32];
  wire [31:0] mant_result = overflow ? sum_raw[32:1] : sum_raw[31:0];
  wire [7:0]  exp_result  = overflow ? (exp_a + 8'd1) : exp_a;

  // =========================================================================
  // 7. Pack output
  // =========================================================================

  wire [47:0] result =
    (s_nan || p_nan)         ? {result_sign, 8'd255, 32'd1} :
    (s_inf || p_inf)         ? {result_sign, 8'd255, 32'd0} :
    (both_zero)              ? {1'b0, 8'd0, 32'd0} :
    (sum_raw == 33'd0)       ? {result_sign, 8'd0, 32'd0} :
    {result_sign, exp_result, mant_result};

  assign o_ps_out = result;

endmodule
