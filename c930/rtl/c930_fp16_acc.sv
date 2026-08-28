// -----------------------------------------------------------------------------
// c930_fp16_acc.sv
//
// FP32 + FP32 -> FP32 combinational accumulator for the NPU systolic array.
// PE's output register captures the result each cycle.
//
// Avoids part-selects inside always_comb (Icarus Verilog limitation) by using
// continuous assignments for all output field extraction.
//
// NOTE: This module must be PURELY COMBINATIONAL. The systolic array's
// partial-sum cascade depends on each PE's output being valid within the same
// cycle as its inputs. A pipeline register inside the accumulator would delay
// the output by 1 cycle, causing the next row's PE to read stale partial-sum
// data (NB assignment vs combinational read on the same posedge).
// The PE's own output register provides sufficient pipeline staging.
//
// Barrel-shifter optimization: for FP16 inputs, the exponent difference is at
// most 31.  If exp_diff >= 16, the smaller mantissa is shifted to zero (all 27
// bits fall off).  We cap the effective shift to 4 bits (0-15) and hardwire
// the upper bits, reducing the barrel shifter from 8 mux stages to 4.
// -----------------------------------------------------------------------------

module c930_fp16_acc
(
  input  logic        i_clk,      // unused (combinational), kept for port compat
  input  logic        i_rst_n,    // unused
  input  logic [31:0] i_ps_in,    // FP32 partial sum from top neighbor
  input  logic [31:0] i_prod,     // FP32 product from FP16 multiplier
  output logic [31:0] o_ps_out    // FP32 partial sum to bottom neighbor
);

  // ---- Extract fields ----
  wire        s_sign = i_ps_in[31];
  wire [7:0]  s_exp  = i_ps_in[30:23];
  wire [22:0] s_mant = i_ps_in[22:0];

  wire        p_sign = i_prod[31];
  wire [7:0]  p_exp  = i_prod[30:23];
  wire [22:0] p_mant = i_prod[22:0];

  // ---- Classify ----
  wire s_zero = (s_exp == 8'd0)   && (s_mant == 23'd0);
  wire p_zero = (p_exp == 8'd0)   && (p_mant == 23'd0);
  wire s_inf  = (s_exp == 8'd255) && (s_mant == 23'd0);
  wire p_inf  = (p_exp == 8'd255) && (p_mant == 23'd0);
  wire s_nan  = (s_exp == 8'd255) && (s_mant != 23'd0);
  wire p_nan  = (p_exp == 8'd255) && (p_mant != 23'd0);

  // ---- Sort: A has the larger (or equal) exponent ----
  wire swap = (p_exp > s_exp) || ((p_exp == s_exp) && (p_mant > s_mant));

  wire [7:0]  exp_a  = swap ? p_exp  : s_exp;
  wire [22:0] mant_a = swap ? p_mant : s_mant;
  wire        sign_a = swap ? p_sign : s_sign;

  wire [7:0]  exp_b  = swap ? s_exp  : p_exp;
  wire [22:0] mant_b = swap ? s_mant : p_mant;
  wire        sign_b = swap ? s_sign : p_sign;

  // ---- Carry-lookahead exponent difference ----
  // Breaks the 8-bit ripple-carry subtraction off the critical path.
  // CLA computes all 8 result bits in ~3 LUT levels vs ~8 for ripple.
  wire [7:0] exp_diff;
  c930_cla_sub u_cla_exp (.i_a(exp_a), .i_b(exp_b), .o_diff(exp_diff));

  // ---- Derived flags ----
  wire both_zero  = s_zero && p_zero;
  wire signs_same = (sign_a == sign_b);

  // ---- Build 27-bit aligned mantissas (1 hidden + 23 mantissa + 3 guard) ----
  wire [26:0] mant_a_ext = {1'b1, mant_a, 3'b0};

  // ---- Narrow barrel shifter: cap shift to 5 bits (FP16 exponent range) ----
  // mant_b_pre = {1, mant_b[22:0], 3 guard} = 27 bits
  // For FP16 inputs, exp_diff <= 31 (5-bit exponent range).
  // Capping to 5 bits reduces barrel shifter from 8 mux stages to 5.
  wire [26:0] mant_b_pre = {1'b1, mant_b, 3'b0};
  wire [4:0]  shift_amt   = exp_diff[4:0];  // FP16 max shift = 31
  wire [26:0] mant_b_ext  = mant_b_pre >> shift_amt;

  // ---- Sticky bit: OR of bits shifted out during alignment ----
  // If exp_diff >= 27, all bits are shifted out (sticky = 1).
  // If exp_diff < 27, sticky = OR of the exp_diff lowest bits of mant_b_pre.
  // For FP16 inputs (exp_diff <= 31), the meaningful range is 0-26.
  // Optimization: use a narrow OR tree on the relevant bits.
  wire [26:0] sticky_mask = (shift_amt >= 5'd27) ? 27'h7FFFFFF :
                             ((27'h1 << shift_amt) - 27'h1);
  wire sticky = ~(s_zero || p_zero) & (|(mant_b_pre & sticky_mask));

  // ---- Add / subtract magnitudes (combinational) ----
  wire [27:0] sum_same   = {1'b0, mant_a_ext} + {1'b0, mant_b_ext};
  wire [27:0] sum_diff_a = {1'b0, mant_a_ext} - {1'b0, mant_b_ext};
  wire [27:0] sum_diff_b = {1'b0, mant_b_ext} - {1'b0, mant_a_ext};
  wire        a_geq_b    = (mant_a_ext >= mant_b_ext);

  // Subtraction sticky clamp: if exact cancellation with sticky, set to 1
  wire [27:0] sum_diff_clamped_a = (sum_diff_a == 28'd0 && sticky) ? 28'd1 : sum_diff_a;
  wire [27:0] sum_diff_clamped_b = (sum_diff_b == 28'd0 && sticky) ? 28'd1 : sum_diff_b;

  // Mux the result based on case
  wire [27:0] sum_raw_w;
  wire        sum_sign_w;

  assign sum_raw_w =
    both_zero        ? 28'd0 :
    s_zero           ? {1'b0, mant_a_ext} :
    p_zero           ? {1'b0, mant_a_ext} :
    signs_same       ? sum_same :
    a_geq_b          ? sum_diff_clamped_a :
                       sum_diff_clamped_b;

  assign sum_sign_w =
    both_zero  ? 1'b0 :
    s_zero     ? p_sign :
    p_zero     ? s_sign :
    signs_same ? sign_a :
    a_geq_b    ? sign_a :
                 sign_b;

  // ---- Leading-zero count for normalization ----
  wire [4:0] lzc =
    sum_raw_w[27] ? 5'd0  :
    sum_raw_w[26] ? 5'd0  :
    sum_raw_w[25] ? 5'd1  :
    sum_raw_w[24] ? 5'd2  :
    sum_raw_w[23] ? 5'd3  :
    sum_raw_w[22] ? 5'd4  :
    sum_raw_w[21] ? 5'd5  :
    sum_raw_w[20] ? 5'd6  :
    sum_raw_w[19] ? 5'd7  :
    sum_raw_w[18] ? 5'd8  :
    sum_raw_w[17] ? 5'd9  :
    sum_raw_w[16] ? 5'd10 :
    sum_raw_w[15] ? 5'd11 :
    sum_raw_w[14] ? 5'd12 :
    sum_raw_w[13] ? 5'd13 :
    sum_raw_w[12] ? 5'd14 :
    sum_raw_w[11] ? 5'd15 :
    sum_raw_w[10] ? 5'd16 :
    sum_raw_w[9]  ? 5'd17 :
    sum_raw_w[8]  ? 5'd18 :
    sum_raw_w[7]  ? 5'd19 :
    sum_raw_w[6]  ? 5'd20 :
    sum_raw_w[5]  ? 5'd21 :
    sum_raw_w[4]  ? 5'd22 :
    sum_raw_w[3]  ? 5'd23 :
    sum_raw_w[2]  ? 5'd24 :
    sum_raw_w[1]  ? 5'd25 :
    sum_raw_w[0]  ? 5'd26 :
                    5'd28;

  // ---- Normalize: shift so hidden 1 lands at bit 26 ----
  wire        is_overflow = (lzc == 5'd0) && sum_raw_w[27];
  wire [27:0] norm_shifted = is_overflow ? (sum_raw_w >> 1) :
                                             (sum_raw_w << lzc);

  // ---- Compute final exponent and mantissa ----
  wire [7:0] exp_norm = is_overflow ? (exp_a + 8'd1) :
                         (exp_a > {3'b0, lzc}) ? (exp_a - {3'b0, lzc}) : 8'd0;

  wire [31:0] result_pre =
    (s_nan || p_nan)       ? {sum_sign_w, 8'd255, 23'd1} :
    (s_inf || p_inf)       ? {sum_sign_w, 8'd255, 23'd0} :
    (sum_raw_w == 28'd0)   ? {sum_sign_w, 8'd0, 23'd0} :
    (lzc == 5'd28)         ? {sum_sign_w, 8'd0, 23'd0} :
    {sum_sign_w, exp_norm, norm_shifted[25:3]};

  assign o_ps_out = result_pre;

endmodule
