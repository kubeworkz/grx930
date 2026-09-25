// -----------------------------------------------------------------------------
// c930_ptm_c.sv
//
// PTM-C: the compatibility shim of grxcp docs/designs/pta_cpu_integration.md
// section 4.1.  It has c930_systolic_array's port list, parameter for
// parameter, plus the error model's, and replaces the array's skewed PE grid
// with one broadside evaluation per column.  With every impairment off it is
// bit-identical to the array.
//
// There is no start strobe on the array's ports, so the shim cannot know when
// the core begins a row.  It does not need to: the array is a fixed stream
// transform.  Every register in c930_tensor_pe that carries the activation or
// the partial sum updates on the hop edge, two per PE, so with window-stable
// inputs -- which the core guarantees, loading i_act and i_ps_in only on hop
// edges -- column c's output in hop window i is
//
//   seed_c(i - 2R)  (+)  a_0(i - 2R - 2c) * w_0c  (+)  ...  (+)  a_(R-1)(i - 2 - 2c) * w_(R-1)c
//
// with the additions taken top row first.  The shim keeps each input's history
// on hop edges, picks exactly those samples (the de-skew), evaluates the whole
// column in one combinational pass (the shot) and registers it on the hop edge
// (the re-skew).  Row r's enable is taken from the window of its own product,
// i - 2(R - r), as the PE's product register takes it.
//
// Weights and the bank select are used as they stand at the shot, not as they
// stood at each row's product window.  The core writes weights only in
// S_WLOAD and holds the bank through S_RUN, so the two cannot differ at any
// window the core captures; a stream that rewrote weights mid-flight could.
//
// Float columns chain c930_fp32_add, the combinational form of c930_fp16_acc,
// in the cascade's row order: IEEE addition does not associate, so any other
// order is a different function.
//
// The error model, phase C1 (doc/pta_error_model_design_note.md, which states
// the fixed-point contract; sim/pta_tile_model.c implements the same steps and
// sim/tb_core_verilator.cc holds the two to bitwise agreement).  Integer
// columns only: the core refuses an impairment with a float precision.
//
//   at a start      sample the configuration; the THERMAL, SHOT and PROG_ERR
//                   xorshift32 streams load seed ^ K (K itself if that is zero)
//   at a calibration
//                   i_pta_cal_load samples the configuration as a start does
//                   and loads the same three streams from the calibration's own
//                   seed.  The saturation count and drift are left alone: a
//                   calibration inside a GEMM must not reset either
//   model reset     idle only: every drift offset and the drift clock return
//                   to zero, and the DRIFT stream loads seed ^ K.  Drift is
//                   device state, so nothing else resets it
//   weight write    PROG_ERR stream steps; e = (sigma_pr*gs + 2^15) >>> 16,
//                   stored beside the weight (Q.8, weight LSB)
//   shot start      i_pta_shot_start marks each shot's first window (one core
//                   run).  In a GEMM with DRIFT set the drift clock counts it;
//                   on reaching 2^k it restarts, and every cell of both banks
//                   steps, bank, then row, then column:
//                     d = clamp(d + ((sigma_d*gs + 2^15) >>> 16), +-d_max)
//   captured shot   i_pta_shot names the column the core captures from this
//                   window's shot; THERMAL and SHOT streams step on its hop
//                   edge, and that column alone is evaluated with the new
//                   draws (no other column's value this window is read):
//     xa   = QUANT ? q(a, B_a) : a
//     wa_r = ((QUANT ? q(w_r, B_w) : w_r) << 8) + (PROG_ERR ? e_r : 0)
//            + (DRIFT ? d_r : 0)                  Q.8, weight LSB
//     wx_r = wa_r + (XTALK ? (chi * (wa_(r-1) + wa_(r+1)) + 2^7) >>> 8 : 0)
//            a neighbour outside the tile or the K tile (i_row_en) is zero
//     y    = sum xa_r * wx_r                      Q.8, tile units
//     rt   = isqrt4(min(|y| >>> S, 2^23))         Q.4, ADC LSB
//     n_th = (sigma_th * gs_th + 2^15) >>> 16      Q.8, ADC LSB
//     n_sh = (k_shot * rt * gs_sh + 2^19) >>> 20   Q.8, ADC LSB
//     z    = y + ((THERMAL ? n_th : 0) + (SHOT ? n_sh : 0)) << S
//     out  = QUANT && B_adc ? clamp((z + 2^(7+S)) >>> (8+S), B_adc) << S
//                           : (z + 2^7) >>> 8
//     column = seed + out, in ACC_W bits
//   q(x, B) = x if B is 0 or >= DIN_W, else clamp((x + 2^(h-1)) >>> h, B) << h
//   with h = DIN_W - B.  gs = (sum of a draw's four bytes - 510) * 443.
//
// C3's correction, which the error model does not itself produce (grxcp
// docs/designs/pta_chiplet_calibration.md sections 2 and 4, and section 4 of
// the design note).  Two stores, both written from outside, both zero out of
// reset, where they change nothing:
//
//   trim_rn     a cell's trim, in the weight DAC below the weight code's LSB.
//               A write is rounded to the DAC's own step, 2^i_pta_trim_log2 in
//               Q.8 weight LSB, away from zero at the half step, and clamped
//               to +-i_pta_trim_max; o_pta_trim_clamped reports a write that
//               could not reach what was asked, which is the tile saying a
//               cell needs a weight rewrite or a service call.  The trim is in
//               the analog weight, so crosstalk couples it as it couples drift:
//                 wa_r = (...) + (PROG_ERR ? e_r : 0) + (DRIFT ? d_r : 0) + trim_r
//   gain_n      a column's affine, after the ADC and before the seed -- the
//   offs_n      column's receiver, not the GEMM's output column:
//                 out' = ((out * gain_n + 2^7) >>> 8) + offs_n
//
// Both correct the error model, so like the error model they exist only where
// it does: with every impairment clear a column is the array's exact sum, trim
// and affine included.  i_pta_cal_shift overrides the ADC's shift for the
// duration of a probe -- a calibration changes range the way an instrument
// does -- without disturbing the configuration a GEMM is running under.
//
// Ablations, each of which parity must catch: ABLATE_ROW moves one row's
// de-skew a window late (C0); PTM_C_ABLATE_XORSHIFT changes xorshift32's first
// shift from 13 to 12; PTM_C_ABLATE_QROUND drops the quantiser's rounding term;
// PTM_C_ABLATE_DRIFT clears drift at every GEMM start; PTM_C_ABLATE_XTALK
// couples rows outside the K tile; PTM_C_ABLATE_TRIM writes a trim without the
// DAC's step; PTM_C_ABLATE_AFFINE applies the affine before the ADC.
// -----------------------------------------------------------------------------

module c930_ptm_c
#(
  parameter int NUM_ROWS   = 8,   // reduction length per pass
  parameter int NUM_COLS   = 8,   // output width
  parameter int DIN_W      = 8,   // activation / weight width
  parameter int ACC_W      = 48,  // accumulator width
  parameter int ABLATE_ROW = -1,  // C0's ablation: this row's de-skew one window late
  parameter int TRIM_W     = 24   // C3's trim as asked for, before the DAC rounds it
)
(
  input  logic                                     i_clk,
  input  logic                                     i_rst_n,

  input  logic                                     i_wen,
  input  logic                                     i_wbank,
  input  logic [$clog2(NUM_ROWS)-1:0]              i_wrow,
  input  logic [$clog2(NUM_COLS)-1:0]              i_wcol,
  input  logic signed [DIN_W-1:0]                  i_wdata,

  input  logic                                     i_bank_sel,

  input  logic signed [NUM_ROWS*DIN_W-1:0]         i_act,
  input  logic signed [NUM_COLS*ACC_W-1:0]         i_ps_in,

  output signed [ACC_W*NUM_COLS-1:0]               o_ps_out,

  input  logic [2:0]                               i_precision,

  input  logic [NUM_ROWS-1:0]                      i_row_en,

  // ---- Error model (doc/pta_error_model_design_note.md section 3) ----
  input  logic                                     i_pta_cfg_load,   // a start was accepted
  input  logic [6:0]                               i_pta_impair,
  input  logic [3:0]                               i_pta_act_bits,
  input  logic [3:0]                               i_pta_w_bits,
  input  logic [3:0]                               i_pta_adc_bits,
  input  logic [5:0]                               i_pta_adc_shift,
  input  logic [31:0]                              i_pta_seed,
  input  logic [15:0]                              i_pta_sigma_th,
  input  logic [15:0]                              i_pta_k_shot,
  input  logic [15:0]                              i_pta_sigma_pr,
  input  logic [15:0]                              i_pta_drift_sigma,  // drift step sigma, Q8.8 weight LSB
  input  logic [4:0]                               i_pta_drift_log2,   // log2 shots per drift step
  input  logic [15:0]                              i_pta_drift_max,    // drift clamp, Q8.8 weight LSB
  input  logic [7:0]                               i_pta_xtalk,        // chi, Q0.8
  input  logic                                     i_pta_model_rst,    // drift back to zero (idle only)
  input  logic                                     i_pta_shot_start, // this window starts a shot
  input  logic                                     i_pta_shot,       // this window's shot is captured
  input  logic [$clog2(NUM_COLS)-1:0]              i_pta_shot_col,   // ... for this column
  output logic [31:0]                              o_pta_sat_count,

  // ---- C3's correction (see the header) ----
  input  logic                                     i_pta_trim_wen,   // one cell's trim
  input  logic                                     i_pta_trim_bank,
  input  logic [$clog2(NUM_ROWS)-1:0]              i_pta_trim_row,
  input  logic [$clog2(NUM_COLS)-1:0]              i_pta_trim_col,
  input  logic signed [TRIM_W-1:0]                 i_pta_trim_data,  // asked for, Q.8 weight LSB
  input  logic [3:0]                               i_pta_trim_log2,  // DAC step = 2^this, Q.8
  input  logic [15:0]                              i_pta_trim_max,   // clamp, Q.8
  // The cell i_pta_trim_{bank,row,col} names, as the DAC holds it now: the
  // estimator adds to this rather than keeping a shadow copy that a host write
  // could put out of step.
  output logic signed [TRIM_W-1:0]                 o_pta_trim_rdata,
  output logic                                     o_pta_trim_clamped,
  input  logic                                     i_pta_cal_wen,    // one column's affine
  input  logic [$clog2(NUM_COLS)-1:0]              i_pta_cal_col,
  input  logic signed [17:0]                       i_pta_cal_gain,   // Q8.8, 256 is unity
  input  logic signed [31:0]                       i_pta_cal_offs,
  input  logic                                     i_pta_cal_rst,    // trims 0, affine identity
  input  logic                                     i_pta_cal_shift_en, // the probe's own range
  input  logic [5:0]                               i_pta_cal_shift,
  // A calibration loads the THERMAL, SHOT and PROG_ERR streams from its own
  // seed, as a start does, and then they run through the whole of it: the
  // repeats differ from one another, which is what makes averaging work, and
  // the sequence is still reproducible from one word.  It leaves the
  // configuration and the saturation count alone -- a calibration inside a GEMM
  // must not reset either -- and it leaves drift alone, which is device state.
  input  logic                                     i_pta_cal_load,
  input  logic [31:0]                              i_pta_cal_seed
);

  localparam int R = NUM_ROWS;
  localparam int C = NUM_COLS;
  // Deepest activation tap is row 0 at the last column, 2R + 2C - 3 windows
  // back, plus one for the ablation.  The seed tap is 2R - 1.
  localparam int ACT_DEPTH  = 2*R + 2*C;
  localparam int SEED_DEPTH = 2*R;

  localparam int IMP_QUANT   = 0;
  localparam int IMP_THERMAL = 1;
  localparam int IMP_SHOT    = 2;
  localparam int IMP_DRIFT   = 3;
  localparam int IMP_XTALK   = 4;
  localparam int IMP_PROG    = 6;

  localparam logic [31:0] K_THERMAL = 32'h9E3779B9;
  localparam logic [31:0] K_SHOT    = 32'h3C6EF372;
  localparam logic [31:0] K_PROG    = 32'hDAA66D2B;
  localparam logic [31:0] K_DRIFT   = 32'h78DDE6E4;

  // ---- Arithmetic helpers: the contract's, shared with sim/pta_tile_model.c ----
  // The contract's arithmetic, shared with PTM-B so the two cannot drift
  // (pta_cpu_integration.md 4.2: they must agree).
`include "c930_pta_contract.svh"

  // ---- Weight banks, written as the array's PEs write theirs ----
  logic signed [DIN_W-1:0] w_bank0 [0:R-1][0:C-1];
  logic signed [DIN_W-1:0] w_bank1 [0:R-1][0:C-1];
  logic signed [19:0]      e_bank0 [0:R-1][0:C-1];   // programming error, Q.8
  logic signed [19:0]      e_bank1 [0:R-1][0:C-1];

  // ---- C3's correction stores ----
  // A trim per cell of both banks, as the weight DAC holds it, and an affine
  // per column of the tile.  Written from outside; the model never moves them.
  logic signed [TRIM_W-1:0] trim0 [0:R-1][0:C-1];   // Q.8 weight LSB
  logic signed [TRIM_W-1:0] trim1 [0:R-1][0:C-1];
  logic signed [17:0]       gain_q [0:C-1];          // Q8.8, 256 is unity
  logic signed [31:0]       offs_q [0:C-1];

  // The DAC's own step and clamp: round away from zero at the half step, then
  // saturate.  A step of 1 (log2 zero) is a DAC with a bit per Q.8 unit, which
  // rounds nothing.  sim/pta_tile_model.c's pta_trim_write() is the reference,
  // and agrees with this for every step that is a power of two -- which is
  // every step a DAC has.
  function automatic logic signed [TRIM_W:0] trim_dac(input logic signed [TRIM_W-1:0] v);
    logic [TRIM_W-1:0] mag, mq;
    logic [TRIM_W-1:0] lim;
    logic [4:0]        g;
    g   = 5'(i_pta_trim_log2);
    mag = v[TRIM_W-1] ? TRIM_W'(-v) : TRIM_W'(v);
`ifdef PTM_C_ABLATE_TRIM
    mq  = mag;
`else
    mq  = (g == 5'd0) ? mag : (((mag + (TRIM_W'(1) << (g - 5'd1))) >> g) << g);
`endif
    lim = TRIM_W'({8'd0, i_pta_trim_max});
    // The top bit says the write could not reach what it was asked for.
    trim_dac = {mq > lim, v[TRIM_W-1] ? TRIM_W'(-((mq > lim) ? lim : mq))
                                      : TRIM_W'((mq > lim) ? lim : mq)};
  endfunction

  always_ff @(posedge i_clk or negedge i_rst_n) begin : b_cal
    logic signed [TRIM_W:0] tw;
    if (!i_rst_n || i_pta_cal_rst) begin
      for (int r = 0; r < R; r++)
        for (int c = 0; c < C; c++) begin
          trim0[r][c] <= '0;
          trim1[r][c] <= '0;
        end
      for (int c = 0; c < C; c++) begin
        gain_q[c] <= 18'sd256;
        offs_q[c] <= '0;
      end
      o_pta_trim_clamped <= 1'b0;
    end else begin
      o_pta_trim_clamped <= 1'b0;
      if (i_pta_trim_wen) begin
        tw = trim_dac(i_pta_trim_data);
        if (i_pta_trim_bank) trim1[i_pta_trim_row][i_pta_trim_col] <= tw[TRIM_W-1:0];
        else                 trim0[i_pta_trim_row][i_pta_trim_col] <= tw[TRIM_W-1:0];
        o_pta_trim_clamped <= tw[TRIM_W];
      end
      if (i_pta_cal_wen) begin
        gain_q[i_pta_cal_col] <= i_pta_cal_gain;
        offs_q[i_pta_cal_col] <= i_pta_cal_offs;
      end
    end
  end

  assign o_pta_trim_rdata = i_pta_trim_bank ? trim1[i_pta_trim_row][i_pta_trim_col]
                                            : trim0[i_pta_trim_row][i_pta_trim_col];

  // ---- Error-model configuration and generators ----
  logic [6:0]  impair_r;
  logic [3:0]  abits_r, wbits_r, adcbits_r;
  logic [5:0]  shift_r;
  logic [15:0] sigma_th_r, k_shot_r, sigma_pr_r;
  logic [15:0] dsig_r, dmax_r;
  logic [4:0]  dlog2_r;
  logic [7:0]  chi_r;
  logic [31:0] rng_th, rng_sh, rng_pr;
  logic [31:0] rng_th_next, rng_sh_next, rng_pr_next;
  logic signed [19:0] gs_th, gs_sh, gs_pr;
  logic signed [36:0] pr_prod, th_prod;
  logic signed [19:0] e_new;     // this write's programming error, Q.8
  logic signed [20:0] n_th;      // this window's thermal noise, Q.8 ADC LSB

  always_comb begin : b_draws
    rng_th_next = xorshift32(rng_th);
    rng_sh_next = xorshift32(rng_sh);
    rng_pr_next = xorshift32(rng_pr);
    gs_th       = gauss(rng_th_next);
    gs_sh       = gauss(rng_sh_next);
    gs_pr       = gauss(rng_pr_next);
    pr_prod     = $signed({21'd0, sigma_pr_r}) * 37'(gs_pr);
    th_prod     = $signed({21'd0, sigma_th_r}) * 37'(gs_th);
    e_new       = 20'((pr_prod + 37'sd32768) >>> 16);
    // Thermal noise is the same draw for every column this window; only the
    // column i_pta_shot names is captured.
    n_th        = 21'((th_prod + 37'sd32768) >>> 16);
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      for (int r = 0; r < R; r++)
        for (int c = 0; c < C; c++) begin
          w_bank0[r][c] <= '0;
          w_bank1[r][c] <= '0;
          e_bank0[r][c] <= '0;
          e_bank1[r][c] <= '0;
        end
    end else if (i_wen) begin
      if (i_wbank) begin
        w_bank1[i_wrow][i_wcol] <= i_wdata;
        e_bank1[i_wrow][i_wcol] <= e_new;
      end else begin
        w_bank0[i_wrow][i_wcol] <= i_wdata;
        e_bank0[i_wrow][i_wcol] <= e_new;
      end
    end
  end

  // ---- Hop phase: the PEs' free-running toggle, in lockstep from reset ----
  logic hop;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) hop <= 1'b0;
    else          hop <= ~hop;
  end

  wire shot_step = hop && i_pta_shot;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      impair_r   <= '0;
      abits_r    <= '0;
      wbits_r    <= '0;
      adcbits_r  <= '0;
      shift_r    <= '0;
      sigma_th_r <= '0;
      k_shot_r   <= '0;
      sigma_pr_r <= '0;
      dsig_r     <= '0;
      dlog2_r    <= '0;
      dmax_r     <= '0;
      chi_r      <= '0;
      rng_th     <= K_THERMAL;
      rng_sh     <= K_SHOT;
      rng_pr     <= K_PROG;
    end else if (i_pta_cfg_load || i_pta_cal_load) begin
      impair_r   <= i_pta_impair;
      abits_r    <= i_pta_act_bits;
      wbits_r    <= i_pta_w_bits;
      adcbits_r  <= i_pta_adc_bits;
      shift_r    <= i_pta_adc_shift;
      sigma_th_r <= i_pta_sigma_th;
      k_shot_r   <= i_pta_k_shot;
      sigma_pr_r <= i_pta_sigma_pr;
      dsig_r     <= i_pta_drift_sigma;
      dlog2_r    <= i_pta_drift_log2;
      dmax_r     <= i_pta_drift_max;
      chi_r      <= i_pta_xtalk;
      // A calibration samples the configuration as it stands and loads the
      // streams from its own seed; a start does both from i_pta_seed.
      rng_th     <= stream_seed(i_pta_cfg_load ? i_pta_seed : i_pta_cal_seed, K_THERMAL);
      rng_sh     <= stream_seed(i_pta_cfg_load ? i_pta_seed : i_pta_cal_seed, K_SHOT);
      rng_pr     <= stream_seed(i_pta_cfg_load ? i_pta_seed : i_pta_cal_seed, K_PROG);
    end else begin
      if (shot_step) begin
        rng_th <= rng_th_next;
        rng_sh <= rng_sh_next;
      end
      if (i_wen)
        rng_pr <= rng_pr_next;
    end
  end

  // ---- Input history, one entry per hop window (entry k: k windows back) ----
  logic signed [DIN_W-1:0] act_h  [0:R-1][1:ACT_DEPTH];
  logic signed [ACC_W-1:0] seed_h [0:C-1][1:SEED_DEPTH];
  logic                    ren_h  [0:R-1][1:SEED_DEPTH];

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      for (int r = 0; r < R; r++) begin
        for (int k = 1; k <= ACT_DEPTH; k++)  act_h[r][k] <= '0;
        for (int k = 1; k <= SEED_DEPTH; k++) ren_h[r][k] <= 1'b0;
      end
      for (int c = 0; c < C; c++)
        for (int k = 1; k <= SEED_DEPTH; k++) seed_h[c][k] <= '0;
    end else if (hop) begin
      for (int r = 0; r < R; r++) begin
        act_h[r][1] <= i_act[r*DIN_W +: DIN_W];
        ren_h[r][1] <= i_row_en[r];
        for (int k = 2; k <= ACT_DEPTH; k++)  act_h[r][k] <= act_h[r][k-1];
        for (int k = 2; k <= SEED_DEPTH; k++) ren_h[r][k] <= ren_h[r][k-1];
      end
      for (int c = 0; c < C; c++) begin
        seed_h[c][1] <= i_ps_in[c*ACC_W +: ACC_W];
        for (int k = 2; k <= SEED_DEPTH; k++) seed_h[c][k] <= seed_h[c][k-1];
      end
    end
  end

  // ---- The shot, float columns: the operands each cascade would meet ----
  // c930_fp32_add chained in the cascade's row order.  Held at zero in the
  // integer modes, where nothing reads it: a combinational chain re-evaluates on
  // every operand event, and a simulator pays for that on every window.
  wire         fp_mode = (i_precision == 3'd2) || (i_precision == 3'd3);
  logic [31:0] y_fp [0:C-1];

  generate
    genvar gc, gr;
    for (gc = 0; gc < C; gc = gc + 1) begin : g_col
      logic [31:0]             fp_chain [0:R];
      wire  signed [ACC_W-1:0] seed = seed_h[gc][2*R - 1];

      assign fp_chain[0] = fp_mode ? seed[31:0] : 32'h0;

      for (gr = 0; gr < R; gr = gr + 1) begin : g_row
        localparam int ACT_TAP = 2*(R - gr) + 2*gc - 1 + ((gr == ABLATE_ROW) ? 1 : 0);
        localparam int REN_TAP = 2*(R - gr) - 1;

        wire signed [DIN_W-1:0] a = act_h[gr][ACT_TAP];
        wire signed [DIN_W-1:0] w = i_bank_sel ? w_bank1[gr][gc] : w_bank0[gr][gc];
        wire [15:0]             fa = fp_mode ? a[15:0] : 16'h0;
        wire [15:0]             fw = fp_mode ? w[15:0] : 16'h0;
        wire [31:0]             fp_prod;

        c930_fp_mul u_fp_mul (
          .i_a      (fa),
          .i_b      (fw),
          .i_mode   (i_precision == 3'd3),
          .o_result (fp_prod)
        );

        c930_fp32_add u_fp_add (
          .i_ps   (fp_chain[gr]),
          .i_prod (ren_h[gr][REN_TAP] ? fp_prod : 32'h0),
          .o_sum  (fp_chain[gr+1])
        );
      end

      assign y_fp[gc] = fp_chain[R];
    end
  endgenerate

  // ---- Drift: device state, stepped on the drift clock ----
  // Every physical cell of both banks drifts, written or not; a weight write
  // leaves its cell's drift alone.  Only a model reset clears it.
  logic signed [16:0] d_bank0 [0:R-1][0:C-1];     // Q8.8 weight LSB
  logic signed [16:0] d_bank1 [0:R-1][0:C-1];
  logic [31:0]        rng_dr;
  logic [31:0]        dcnt;                       // shots counted since the last step

  always_ff @(posedge i_clk or negedge i_rst_n) begin : b_drift
    logic [31:0]        ds;
    logic signed [36:0] dp;
    logic signed [20:0] dstep;
    logic signed [21:0] dnew, dlim;
    if (!i_rst_n) begin
      for (int r = 0; r < R; r++)
        for (int c = 0; c < C; c++) begin
          d_bank0[r][c] <= '0;
          d_bank1[r][c] <= '0;
        end
      rng_dr <= K_DRIFT;
      dcnt   <= 32'd0;
`ifdef PTM_C_ABLATE_DRIFT
    end else if (i_pta_model_rst || i_pta_cfg_load) begin
`else
    end else if (i_pta_model_rst) begin
`endif
      for (int r = 0; r < R; r++)
        for (int c = 0; c < C; c++) begin
          d_bank0[r][c] <= '0;
          d_bank1[r][c] <= '0;
        end
      rng_dr <= stream_seed(i_pta_seed, K_DRIFT);
      dcnt   <= 32'd0;
    end else if (hop && i_pta_shot_start && impair_r[IMP_DRIFT]) begin
      if (dcnt + 32'd1 >= (32'd1 << dlog2_r)) begin
        dcnt <= 32'd0;
        ds   = rng_dr;
        dlim = $signed({6'd0, dmax_r});
        for (int b = 0; b < 2; b++)
          for (int r = 0; r < R; r++)
            for (int c = 0; c < C; c++) begin
              ds    = xorshift32(ds);
              dp    = $signed({21'd0, dsig_r}) * 37'(gauss(ds));
              dstep = 21'((dp + 37'sd32768) >>> 16);
              dnew  = 22'((b == 0) ? d_bank0[r][c] : d_bank1[r][c]) + 22'(dstep);
              if (dnew > dlim)  dnew = dlim;
              if (dnew < -dlim) dnew = -dlim;
              if (b == 0) d_bank0[r][c] <= 17'(dnew);
              else        d_bank1[r][c] <= 17'(dnew);
            end
        rng_dr <= ds;
      end else begin
        dcnt <= dcnt + 32'd1;
      end
    end
  end

  // Row r's analog weight in column c, Q.8 weight LSB: the DAC's level plus the
  // programming error and the drift the configuration turns on.
  function automatic logic signed [63:0] analog_w(input int r, input int c);
    logic signed [DIN_W-1:0]  w;
    logic signed [19:0]       e;
    logic signed [16:0]       d;
    logic signed [TRIM_W-1:0] tr;
    logic signed [63:0]       wq;
    w  = i_bank_sel ? w_bank1[r][c] : w_bank0[r][c];
    e  = i_bank_sel ? e_bank1[r][c] : e_bank0[r][c];
    d  = i_bank_sel ? d_bank1[r][c] : d_bank0[r][c];
    tr = i_bank_sel ? trim1[r][c]   : trim0[r][c];
    wq = impair_r[IMP_QUANT] ? 64'(quant(int'(w), int'(wbits_r))) : 64'(w);
    analog_w = wq * 64'sd256 + (impair_r[IMP_PROG]  ? 64'(e) : 64'sd0)
                              + (impair_r[IMP_DRIFT] ? 64'(d) : 64'sd0)
                              + 64'(tr);
  endfunction

  // Row r's weight as its input sees it.  With XTALK, the input's light also
  // passes the rows either side in the same column's bank; a row outside the
  // tile or outside the K tile holds no weight for it.
  function automatic logic signed [63:0] coupled_w(input int r, input int c);
    logic signed [63:0] nb;
    if (!impair_r[IMP_XTALK]) begin
      coupled_w = analog_w(r, c);
    end else begin
      nb = 64'sd0;
`ifdef PTM_C_ABLATE_XTALK
      if (r > 0)     nb = nb + analog_w(r - 1, c);
      if (r < R - 1) nb = nb + analog_w(r + 1, c);
`else
      if (r > 0     && i_row_en[r - 1]) nb = nb + analog_w(r - 1, c);
      if (r < R - 1 && i_row_en[r + 1]) nb = nb + analog_w(r + 1, c);
`endif
      coupled_w = analog_w(r, c) + (($signed({56'd0, chi_r}) * nb + 64'sd128) >>> 8);
    end
  endfunction

  // sim/pta_tile_model.c's pta_affine(): the column's gain and offset, with
  // the contract's rounding.  Unity gain and zero offset leave out alone.
  function automatic logic signed [81:0] affine(input int c, input logic signed [63:0] out);
    logic signed [81:0] v;
    v      = (82'(out) * 82'(gain_q[c]) + 82'sd128) >>> 8;
    affine = v + 82'(offs_q[c]);
  endfunction

  // ---- The shot, integer columns ----
  // One column's registered value and whether its ADC clamped.  With modelled
  // clear it is the array's exact sum; set, it is the error model of the header.
  // The output register below sets modelled only for the column the core is
  // capturing from this window, since no other column's value this window is
  // ever read.  Evaluated once per hop edge, inside that register's process,
  // for the simulator's sake as the float chain is held above.
  function automatic logic [ACC_W:0] int_column(input int c, input logic modelled);
    logic signed [ACC_W-1:0] seed;
    logic signed [DIN_W-1:0] a, w;
    logic signed [63:0]      y, xa;
    logic        [63:0]      ay, v;
    logic        [12:0]      rt;
    logic        [28:0]      krt;
    logic signed [49:0]      sh_prod;
    logic signed [29:0]      n_sh;
    logic signed [30:0]      nsum;
    logic signed [79:0]      z, tq, outw, hi, lo;
    logic signed [63:0]      o64;
    logic signed [81:0]      aff;
    logic                    clamped;
    int                      s, b, tap;

    seed = seed_h[c][2*R - 1];
    y    = 64'sd0;
    for (int r = 0; r < R; r++) begin
      tap = 2*(R - r) + 2*c - 1 + ((r == ABLATE_ROW) ? 1 : 0);
      a   = act_h[r][tap];
      if (!modelled) begin
        w = i_bank_sel ? w_bank1[r][c] : w_bank0[r][c];
        y = y + 64'(a) * 64'(w);
      end else begin
        xa = impair_r[IMP_QUANT] ? 64'(quant(int'(a), int'(abits_r))) : 64'(a);
        y  = y + xa * coupled_w(r, c);               // Q.8, tile units
      end
    end
    // An unmodelled column is the exact sum; the modelled path must not overwrite it.
    if (!modelled) begin
      int_column = {1'b0, seed + y[ACC_W-1:0]};
    end else begin
      s       = i_pta_cal_shift_en ? int'(i_pta_cal_shift) : int'(shift_r);
      b       = int'(adcbits_r);
      ay      = y[63] ? 64'(-y) : 64'(y);
      v       = ay >> s;                               // Q.8, ADC LSB
      if (v > 64'd8388608) v = 64'd8388608;            // 2^23
      rt      = isqrt4(v[23:0]);
      krt     = 29'(k_shot_r) * 29'(rt);
      sh_prod = $signed({21'd0, krt}) * 50'(gs_sh);
      n_sh    = 30'((sh_prod + 50'sd524288) >>> 20);
      nsum    = (impair_r[IMP_THERMAL] ? 31'(n_th) : 31'sd0) +
                (impair_r[IMP_SHOT]    ? 31'(n_sh) : 31'sd0);
      z       = 80'(y) + (80'(nsum) <<< s);

`ifdef PTM_C_ABLATE_AFFINE
      // The affine before the ADC: the correction then passes through the
      // ADC's own rounding and clamp, which is not what it corrects.
      z       = 80'(affine(c, z[63:0]));
`endif
      clamped = 1'b0;
      if (impair_r[IMP_QUANT] && b != 0) begin
        tq = (z + (80'sd1 <<< (7 + s))) >>> (8 + s);
        hi = (80'sd1 <<< (b - 1)) - 80'sd1;
        lo = -(80'sd1 <<< (b - 1));
        if (tq > hi)      begin tq = hi; clamped = 1'b1; end
        else if (tq < lo) begin tq = lo; clamped = 1'b1; end
        outw = tq <<< s;
      end else begin
        outw = (z + 80'sd128) >>> 8;
      end
      // C3's affine, on the column's own gain and offset.  The C reference
      // carries out in an int64, so the narrowing is where the model narrows.
      o64     = outw[63:0];
`ifdef PTM_C_ABLATE_AFFINE
      aff     = 82'(o64);
`else
      aff     = 82'(affine(c, o64));
`endif
      int_column = {clamped, seed + aff[ACC_W-1:0]};
    end
  endfunction

  // ---- Re-skew: the hop-edge register the array's last PE row would be ----
  // It also counts ADC saturations, which only a modelled column can have.
  logic signed [ACC_W*C-1:0] ps_out_q;
  logic [31:0]               sat_cnt;
  wire                       modelling = (impair_r != 7'd0);

  always_ff @(posedge i_clk or negedge i_rst_n) begin : b_out
    logic [ACC_W:0] col;
    if (!i_rst_n) begin
      ps_out_q <= '0;
      sat_cnt  <= 32'd0;
    end else begin
      if (i_pta_cfg_load)
        sat_cnt <= 32'd0;
      if (hop) begin
        for (int c = 0; c < C; c++) begin
          if (fp_mode) begin
            ps_out_q[c*ACC_W +: ACC_W] <= {{(ACC_W-32){1'b0}}, y_fp[c]};
          end else begin
            col = int_column(c, modelling && i_pta_shot && (c == int'(i_pta_shot_col)));
            ps_out_q[c*ACC_W +: ACC_W] <= col[ACC_W-1:0];
            if (col[ACC_W])
              sat_cnt <= sat_cnt + 32'd1;
          end
        end
      end
    end
  end

  assign o_ps_out        = ps_out_q;
  assign o_pta_sat_count = sat_cnt;

endmodule
