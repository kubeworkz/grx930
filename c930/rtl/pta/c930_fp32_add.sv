// -----------------------------------------------------------------------------
// c930_fp32_add.sv
//
// Combinational FP32 + FP32 -> FP32: the function g of c930_fp16_acc, with its
// stage-1 register removed.  c930_fp16_acc cuts g across a hop-enabled
// register to close timing inside the systolic array; PTM-C (c930_ptm_c.sv)
// needs g whole, to chain a column's rows in one evaluation.
//
// Every expression below is c930_fp16_acc's, in the same order, on the same
// CLA and add/sub submodules, so the two agree bit for bit on every input --
// including the shift clamp at 31 that BF16 products and infinities rely on.
// tb/tb_ptm_c_lockstep.sv checks that against c930_fp16_acc directly.  Change
// one, change both.
//
// A simulation model's helper, not a synthesis target.
// -----------------------------------------------------------------------------

module c930_fp32_add
(
  input  logic [31:0] i_ps,     // running sum
  input  logic [31:0] i_prod,   // product to add
  output logic [31:0] o_sum
);

  // ---- Extract fields ----
  wire        s_sign = i_ps[31];
  wire [7:0]  s_exp  = i_ps[30:23];
  wire [22:0] s_mant = i_ps[22:0];

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
  wire exp_gt, exp_eq;
  c930_cla_comp u_cla_cmp (.i_a(p_exp), .i_b(s_exp), .o_gt(exp_gt), .o_eq(exp_eq));
  wire swap = exp_gt || (exp_eq && (p_mant > s_mant));

  wire [7:0]  exp_a  = swap ? p_exp  : s_exp;
  wire [22:0] mant_a = swap ? p_mant : s_mant;
  wire        sign_a = swap ? p_sign : s_sign;

  wire [7:0]  exp_b  = swap ? s_exp  : p_exp;
  wire [22:0] mant_b = swap ? s_mant : p_mant;
  wire        sign_b = swap ? s_sign : p_sign;

  wire [7:0] exp_diff;
  c930_cla_sub u_cla_exp (.i_a(exp_a), .i_b(exp_b), .o_diff(exp_diff));

  wire both_zero  = s_zero && p_zero;
  wire signs_same = (sign_a == sign_b);

  // ---- Align ----
  wire [26:0] mant_a_ext  = {1'b1, mant_a, 3'b0};
  wire [26:0] mant_b_pre  = {1'b1, mant_b, 3'b0};
  wire [4:0]  shift_amt   = (exp_diff > 8'd31) ? 5'd31 : exp_diff[4:0];
  wire [26:0] mant_b_ext  = mant_b_pre >> shift_amt;

  wire [26:0] sticky_mask = (shift_amt >= 5'd27) ? 27'h7FFFFFF :
                             ((27'h1 << shift_amt) - 27'h1);
  wire sticky = ~(s_zero || p_zero) & (|(mant_b_pre & sticky_mask));

  // ---- Add / subtract magnitudes ----
  wire        do_sub = !signs_same;
  wire [27:0] sum_raw_pre;
  c930_fp16_addsub u_addsub (
    .i_clk  (1'b0),
    .i_a    ({1'b0, mant_a_ext}),
    .i_b    ({1'b0, mant_b_ext}),
    .i_sub  (do_sub),
    .o_out  (sum_raw_pre)
  );

  wire [27:0] sum_diff_clamped = (sum_raw_pre == 28'd0 && sticky && do_sub) ? 28'd1 : sum_raw_pre;

  wire [27:0] sum_raw_w =
    both_zero  ? 28'd0 :
    s_zero     ? {1'b0, mant_a_ext} :
    p_zero     ? {1'b0, mant_a_ext} :
                 sum_diff_clamped;

  wire sum_sign_w =
    both_zero  ? 1'b0 :
    s_zero     ? p_sign :
    p_zero     ? s_sign :
                 sign_a;

  // ---- What c930_fp16_acc registers between its stages ----
  wire        r_sign  = sum_sign_w;
  wire [7:0]  r_exp_a = exp_a;
  wire [27:0] r_sum   = sum_raw_w;
  wire        r_nan   = s_nan || p_nan;
  wire        r_inf   = (s_inf || p_inf) && !(s_nan || p_nan);

  // ---- Normalize, adjust exponent, pack ----
  wire [4:0] lzc =
    r_sum[27] ? 5'd0  :
    r_sum[26] ? 5'd0  :
    r_sum[25] ? 5'd1  :
    r_sum[24] ? 5'd2  :
    r_sum[23] ? 5'd3  :
    r_sum[22] ? 5'd4  :
    r_sum[21] ? 5'd5  :
    r_sum[20] ? 5'd6  :
    r_sum[19] ? 5'd7  :
    r_sum[18] ? 5'd8  :
    r_sum[17] ? 5'd9  :
    r_sum[16] ? 5'd10 :
    r_sum[15] ? 5'd11 :
    r_sum[14] ? 5'd12 :
    r_sum[13] ? 5'd13 :
    r_sum[12] ? 5'd14 :
    r_sum[11] ? 5'd15 :
    r_sum[10] ? 5'd16 :
    r_sum[9]  ? 5'd17 :
    r_sum[8]  ? 5'd18 :
    r_sum[7]  ? 5'd19 :
    r_sum[6]  ? 5'd20 :
    r_sum[5]  ? 5'd21 :
    r_sum[4]  ? 5'd22 :
    r_sum[3]  ? 5'd23 :
    r_sum[2]  ? 5'd24 :
    r_sum[1]  ? 5'd25 :
    r_sum[0]  ? 5'd26 :
                5'd28;

  wire        is_overflow  = (lzc == 5'd0) && r_sum[27];
  wire [27:0] norm_shifted = is_overflow ? (r_sum >> 1) : (r_sum << lzc);

  wire [7:0] exp_norm = is_overflow ? (r_exp_a + 8'd1) :
                        (r_exp_a > {3'b0, lzc}) ? (r_exp_a - {3'b0, lzc}) : 8'd0;

  assign o_sum =
    r_nan              ? {r_sign, 8'd255, 23'd1} :
    r_inf              ? {r_sign, 8'd255, 23'd0} :
    (r_sum == 28'd0)   ? {r_sign, 8'd0, 23'd0} :
    (lzc == 5'd28)     ? {r_sign, 8'd0, 23'd0} :
    {r_sign, exp_norm, norm_shifted[25:3]};

endmodule
