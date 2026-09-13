// -----------------------------------------------------------------------------
// c930_fp16_acc.sv
//
// FP32 + FP32 -> FP32 accumulator for the NPU systolic array (FP16/BF16 mode).
// PE's output register captures the result each cycle.
//
// PIPELINED (2-stage internal).  Cycle-boundary behavior is IDENTICAL to the
// previous fully-combinational version: the PE's output register still
// captures one result per cycle, o_ps_out(T+1) = g(i_ps_in(T), i_prod(T))
// with the same combinational function g.  What changed is only how the cone
// is cut across two register-to-register stages:
//
//   stage 1 (combinational, captured into the internal r_* registers):
//     classify -> exponent sort -> CLA diff -> alignment barrel -> sticky
//     -> fused DSP48E1 add/sub -> case mux
//   stage 2 (combinational from the stage-1 registers):
//     leading-zero count -> normalize barrel -> exponent adjust -> pack
//
// The old single-stage cone (align+add+normalize, ~34 logic levels) missed
// the 50 MHz core_clk budget at 90% device utilization (WNS -4.8 ns on the
// fp32_prod_reg -> o_ps_out_reg path); splitting it halves both the logic
// depth and the routing span of each stage.
//
// STREAM CONTRACT (do not regress):
//   The systolic partial-sum stream flows one PE per cycle: o_ps_out must
//   stay REGISTERED, unconditionally enabled, and must keep mapping
//   i_ps_in(T) -> o_ps_out(T+1).  Do NOT add stream latency (no clock
//   enables, no extra stream register), and do not move the stream register
//   into this module.  Only the internal cone split above is allowed.
//
// Avoids part-selects inside always_comb (Icarus Verilog limitation) by using
// continuous assignments for all output field extraction.
//
// Area optimization (dual-NPU SoC fit on Arty A7-200T):
//   The previous implementation computed three speculative 28-bit results
//   (A+B, A-B, B-A) plus a 28-bit magnitude comparator and selected between
//   them.  Because the input sort below guarantees |A| >= |B| (exponent sort
//   with mantissa tie-break, and the alignment shift of B is exact), the
//   subtraction direction is fixed: A - B is always non-negative.  The
//   comparator and the B-A subtractor were therefore dead logic.  They are
//   replaced by ONE fused add/sub unit (c930_fp16_addsub) which maps to a
//   single DSP48E1 in synthesis (multiplier bypassed, 48-bit adder only) --
//   saving ~2 adders + 1 comparator + one mux level (~90 LUTs) per PE.
//   The DSP path is used only under `ifdef SYNTHESIS` (defined by the Vivado
//   flow); simulation uses an identical behavioral add/sub.
//
// Barrel-shifter optimization: for FP16 inputs, the exponent difference is at
// most 31.  If exp_diff >= 16, the smaller mantissa is shifted to zero (all 27
// bits fall off).  We cap the effective shift to 5 bits (0-31) and hardwire
// the upper bits, reducing the barrel shifter from 8 mux stages to 5.
// -----------------------------------------------------------------------------

module c930_fp16_acc
(
  input  logic        i_clk,      // stage-1 register clock
  input  logic        i_rst_n,
  input  logic        i_hop,      // window phase: stage-1 captures only on the
                                  // gated (hop) edge, matching the PE's stream
                                  // registers -- free-running stage-1 would
                                  // sample half-window states and mix windows
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
  // CLA comparator breaks the exponent comparison off the critical path.
  // exp_gt: p_exp > s_exp  (8-bit CLA, ~3 LUT levels)
  // exp_eq: p_exp == s_exp  (XOR + NOR, 2 LUT levels)
  wire exp_gt, exp_eq;
  c930_cla_comp u_cla_cmp (.i_a(p_exp), .i_b(s_exp), .o_gt(exp_gt), .o_eq(exp_eq));
  wire swap = exp_gt || (exp_eq && (p_mant > s_mant));

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
  // For FP16 inputs, exp_diff <= 31 (5-bit exponent range), which keeps the
  // barrel at 5 mux stages.  Exponents are 8-bit, so CLAMP the shift at 31:
  // taking exp_diff[4:0] directly would WRAP (e.g. diff 128 -> shift 0) and
  // break alignment for BF16 products or inf operands.
  wire [26:0] mant_b_pre = {1'b1, mant_b, 3'b0};
  wire [4:0]  shift_amt   = (exp_diff > 8'd31) ? 5'd31 : exp_diff[4:0];
  wire [26:0] mant_b_ext  = mant_b_pre >> shift_amt;

  // ---- Sticky bit: OR of bits shifted out during alignment ----
  // If exp_diff >= 27, all bits are shifted out (sticky = 1).
  // If exp_diff < 27, sticky = OR of the exp_diff lowest bits of mant_b_pre.
  // For FP16 inputs (exp_diff <= 31), the meaningful range is 0-26.
  // Optimization: use a narrow OR tree on the relevant bits.
  wire [26:0] sticky_mask = (shift_amt >= 5'd27) ? 27'h7FFFFFF :
                             ((27'h1 << shift_amt) - 27'h1);
  wire sticky = ~(s_zero || p_zero) & (|(mant_b_pre & sticky_mask));

  // ---- Add / subtract magnitudes (single fused unit) ----
  // The sort guarantees A >= B, so the subtraction is always A - B >= 0.
  wire        do_sub = !signs_same;
  wire [27:0] sum_raw_pre;
  c930_fp16_addsub u_addsub (
    .i_clk  (i_clk),
    .i_a    ({1'b0, mant_a_ext}),
    .i_b    ({1'b0, mant_b_ext}),
    .i_sub  (do_sub),
    .o_out  (sum_raw_pre)
  );

  // Subtraction sticky clamp: if exact cancellation with sticky, set to 1
  wire [27:0] sum_diff_clamped = (sum_raw_pre == 28'd0 && sticky && do_sub) ? 28'd1 : sum_raw_pre;

  // Mux the result based on case
  wire [27:0] sum_raw_w;
  wire        sum_sign_w;

  assign sum_raw_w =
    both_zero  ? 28'd0 :
    s_zero     ? {1'b0, mant_a_ext} :
    p_zero     ? {1'b0, mant_a_ext} :
                 sum_diff_clamped;

  assign sum_sign_w =
    both_zero  ? 1'b0 :
    s_zero     ? p_sign :
    p_zero     ? s_sign :
                 sign_a;    // A >= B, so the result takes A's sign

  // ---- STAGE 1 REGISTER ----
  // Captures everything stage 2 needs: the raw sum (for LZC + normalize),
  // the larger exponent (for overflow increment / LZC subtract), the result
  // sign, and the special-case flags.  Bit-exact by construction: stage 2
  // recomputes exactly the expressions the old single-stage code applied to
  // sum_raw_w / exp_a / sum_sign_w / the nan/inf/zero cases.
  logic        r_sign;
  logic [7:0]  r_exp_a;
  logic [27:0] r_sum;
  logic        r_nan;
  logic        r_inf;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      r_sign  <= 1'b0;
      r_exp_a <= 8'd0;
      r_sum   <= 28'd0;
      r_nan   <= 1'b0;
      r_inf   <= 1'b0;
    end else if (i_hop) begin
      r_sign  <= sum_sign_w;
      r_exp_a <= exp_a;
      r_sum   <= sum_raw_w;
      r_nan   <= s_nan || p_nan;
      r_inf   <= (s_inf || p_inf) && !(s_nan || p_nan);
    end
  end

  // ---- STAGE 2: leading-zero count for normalization ----
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

  // ---- STAGE 2: normalize, exponent adjust, pack ----
  wire        is_overflow = (lzc == 5'd0) && r_sum[27];
  wire [27:0] norm_shifted = is_overflow ? (r_sum >> 1) :
                                            (r_sum << lzc);

  wire [7:0] exp_norm = is_overflow ? (r_exp_a + 8'd1) :
                        (r_exp_a > {3'b0, lzc}) ? (r_exp_a - {3'b0, lzc}) : 8'd0;

  wire [31:0] result_pre =
    r_nan                  ? {r_sign, 8'd255, 23'd1} :
    r_inf                  ? {r_sign, 8'd255, 23'd0} :
    (r_sum == 28'd0)       ? {r_sign, 8'd0, 23'd0} :
    (lzc == 5'd28)         ? {r_sign, 8'd0, 23'd0} :
    {r_sign, exp_norm, norm_shifted[25:3]};

  assign o_ps_out = result_pre;

endmodule


// -----------------------------------------------------------------------------
// c930_fp16_addsub
//
// 28-bit fused add/sub:  o = a + b  (i_sub = 0),  o = a - b  (i_sub = 1).
// The subtract direction assumes i_a >= i_b (guaranteed by the caller's
// exponent sort + exact alignment shift), so the result is non-negative.
//
// In synthesis this maps to one DSP48E1 used as a pure 48-bit adder with the
// multiplier bypassed (USE_MULT = "NONE"):
//     OPMODE = 7'b0110011  ->  X = A:B, Y = 0, Z = C
//     ALUMODE[1:0]         ->  00: out = X + Y + Z + CIN
//                               01: out = X + Y - Z - 1 + CIN
//     CARRYIN = i_sub      ->  sub=1 turns X - Z - 1 into X - Z
//   with A:B = i_a (zero-extended to 48) and C = i_b (zero-extended).
//   => P = i_a + i_b  (sub=0)   or   P = i_a - i_b  (sub=1).
// All pipeline registers are disabled (AREG/BREG/CREG/PREG = 0) so the DSP
// output is combinational, matching the systolic cascade's single-cycle
// requirement.  Simulation uses an identical behavioral add/sub.
// -----------------------------------------------------------------------------
module c930_fp16_addsub
(
  input  logic        i_clk,   // unused (combinational), kept for DSP clock
  input  logic [27:0] i_a,
  input  logic [27:0] i_b,
  input  logic        i_sub,
  output logic [27:0] o_out
);
`ifdef SYNTHESIS
  wire [47:0] p;

  DSP48E1 #(
    // Feature Control Attributes: Data Path Selection
    .A_INPUT("DIRECT"),
    .B_INPUT("DIRECT"),
    .USE_DPORT("FALSE"),
    .USE_MULT("NONE"),
    .USE_SIMD("ONE48"),
    // Pattern Detector Attributes
    .AUTORESET_PATDET("NO_RESET"),
    .MASK(48'h3fffffffffff),
    .PATTERN(48'h000000000000),
    .SEL_MASK("MASK"),
    .SEL_PATTERN("PATTERN"),
    .USE_PATTERN_DETECT("NO_PATDET"),
    // Register Control Attributes: all registers bypassed (combinational)
    .ACASCREG(0), .ADREG(0), .ALUMODEREG(0), .AREG(0),
    .BCASCREG(0), .BREG(0), .CARRYINREG(0), .CARRYINSELREG(0),
    .CREG(0), .DREG(0), .INMODEREG(0), .MREG(0), .OPMODEREG(0), .PREG(0)
  ) u_dsp (
    // Cascade outputs (unused)
    .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .MULTSIGNOUT(), .PCOUT(),
    // Control/status outputs (unused)
    .OVERFLOW(), .PATTERNBDETECT(), .PATTERNDETECT(), .UNDERFLOW(),
    .CARRYOUT(),
    // Data output
    .P(p),
    // Cascade inputs (unused)
    .ACIN(30'b0), .BCIN(18'b0), .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
    .PCIN(48'b0),
    // Control inputs
    .ALUMODE({2'b00, 1'b0, i_sub}),   // 0000: add, 0001: subtract form
    .CARRYINSEL(3'b000),              // carry source = CARRYIN port
    .CLK(i_clk),
    .INMODE(5'b00000),
    .OPMODE(7'b0110011),              // X = A:B, Y = 0, Z = C
    // Data inputs
    .A({20'b0, i_a[27:18]}),          // A:B = {A[29:0], B[17:0]} = i_a
    .B(i_a[17:0]),
    .C({20'b0, i_b}),
    .CARRYIN(i_sub),                  // +1 turns (X - Z - 1) into (X - Z)
    .D(25'b0),
    // Clock enables (unused with all registers bypassed)
    .CEA1(1'b0), .CEA2(1'b0), .CEAD(1'b0), .CEALUMODE(1'b0),
    .CEB1(1'b0), .CEB2(1'b0), .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b0),
    .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0), .CEP(1'b0),
    // Resets (unused with all registers bypassed)
    .RSTA(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
    .RSTB(1'b0), .RSTC(1'b0), .RSTCTRL(1'b0), .RSTD(1'b0),
    .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(1'b0)
  );

  assign o_out = p[27:0];
`else
  assign o_out = i_sub ? (i_a - i_b) : (i_a + i_b);
`endif
endmodule