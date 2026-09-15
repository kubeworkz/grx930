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
//   at a start      sample the configuration; each xorshift32 stream loads
//                   seed ^ K (K itself if that is zero)
//   weight write    PROG_ERR stream steps; e = (sigma_pr*gs + 2^15) >>> 16,
//                   stored beside the weight (Q.8, weight LSB)
//   captured shot   i_pta_shot names the column the core captures from this
//                   window's shot; THERMAL and SHOT streams step on its hop
//                   edge, and that column alone is evaluated with the new
//                   draws (no other column's value this window is read):
//     xa   = QUANT ? q(a, B_a) : a
//     wa   = ((QUANT ? q(w, B_w) : w) << 8) + (PROG_ERR ? e : 0)
//     y    = sum xa * wa                          Q.8, tile units
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
// Ablations, each of which parity must catch: ABLATE_ROW moves one row's
// de-skew a window late (C0); PTM_C_ABLATE_XORSHIFT changes xorshift32's first
// shift from 13 to 12; PTM_C_ABLATE_QROUND drops the quantiser's rounding term.
// -----------------------------------------------------------------------------

module c930_ptm_c
#(
  parameter int NUM_ROWS   = 8,   // reduction length per pass
  parameter int NUM_COLS   = 8,   // output width
  parameter int DIN_W      = 8,   // activation / weight width
  parameter int ACC_W      = 48,  // accumulator width
  parameter int ABLATE_ROW = -1   // C0's ablation: this row's de-skew one window late
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
  input  logic                                     i_pta_shot,       // this window's shot is captured
  input  logic [$clog2(NUM_COLS)-1:0]              i_pta_shot_col,   // ... for this column
  output logic [31:0]                              o_pta_sat_count
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
  localparam int IMP_PROG    = 6;

  localparam logic [31:0] K_THERMAL = 32'h9E3779B9;
  localparam logic [31:0] K_SHOT    = 32'h3C6EF372;
  localparam logic [31:0] K_PROG    = 32'hDAA66D2B;

  // ---- Arithmetic helpers: the contract's, shared with sim/pta_tile_model.c ----
  function automatic logic [31:0] xorshift32(input logic [31:0] s);
    logic [31:0] v;
`ifdef PTM_C_ABLATE_XORSHIFT
    v = s ^ (s << 12);
`else
    v = s ^ (s << 13);
`endif
    v = v ^ (v >> 17);
    v = v ^ (v << 5);
    return v;
  endfunction

  // (sum of the four bytes - 510) * 443: about N(0, 1) * 2^16
  function automatic logic signed [19:0] gauss(input logic [31:0] s);
    logic signed [10:0] g;
    g = $signed({3'b0, s[31:24]}) + $signed({3'b0, s[23:16]}) +
        $signed({3'b0, s[15:8]})  + $signed({3'b0, s[7:0]}) - 11'sd510;
    return g * 20'sd443;
  endfunction

  function automatic logic [31:0] stream_seed(input logic [31:0] seed, input logic [31:0] k);
    return ((seed ^ k) == 32'd0) ? k : (seed ^ k);
  endfunction

  // c930_npu_act's isqrt4, unchanged: a leading-zero count and a four-entry
  // table of 2^11 * sqrt(1..4), interpolated on six fraction bits.
  function automatic logic [4:0] msb24(input logic [23:0] a);
    logic [7:0] byte_sel;
    logic [2:0] byte_idx;
    logic [2:0] bit_idx;
    if (a[23:16] != 8'd0) begin
      byte_sel = a[23:16]; byte_idx = 3'd2;
    end else if (a[15:8] != 8'd0) begin
      byte_sel = a[15:8];  byte_idx = 3'd1;
    end else begin
      byte_sel = a[7:0];   byte_idx = 3'd0;
    end
    bit_idx = byte_sel[7] ? 3'd7 : byte_sel[6] ? 3'd6 :
              byte_sel[5] ? 3'd5 : byte_sel[4] ? 3'd4 :
              byte_sel[3] ? 3'd3 : byte_sel[2] ? 3'd2 :
              byte_sel[1] ? 3'd1 : 3'd0;
    return {byte_idx, bit_idx};
  endfunction

  function automatic logic [12:0] isqrt4(input logic [23:0] a);
    logic [4:0]  p;
    logic [3:0]  e;
    logic [7:0]  th;
    logic [1:0]  seg;
    logic [12:0] lo, hi;
    logic [22:0] prod;
    logic [12:0] rn;
    if (a == 24'd0) return 13'd0;
    p   = msb24(a);
    e   = 4'(p >> 1);
    th  = 8'((a << (5'd22 - {e, 1'b0})) >> 16);
    seg = th[7:6] - 2'd1;
    case (seg)
      2'd0:    begin lo = 13'd2048; hi = 13'd2896; end
      2'd1:    begin lo = 13'd2896; hi = 13'd3547; end
      default: begin lo = 13'd3547; hi = 13'd4096; end
    endcase
    prod = 23'(hi - lo) * 23'(th[5:0]);
    rn   = lo + 13'(prod >> 6);
    return rn >> (4'd11 - e);
  endfunction

  // q(x, B) over the DIN_W-bit operand range: round half up, saturate.
  function automatic int quant(input int x, input int b);
    int h, v, hi, lo;
    if (b == 0 || b >= DIN_W) return x;
    h  = DIN_W - b;
`ifdef PTM_C_ABLATE_QROUND
    v  = x >>> h;
`else
    v  = (x + (1 << (h - 1))) >>> h;
`endif
    hi = (1 << (b - 1)) - 1;
    lo = -(1 << (b - 1));
    if (v > hi) v = hi;
    if (v < lo) v = lo;
    return v <<< h;
  endfunction

  // ---- Weight banks, written as the array's PEs write theirs ----
  logic signed [DIN_W-1:0] w_bank0 [0:R-1][0:C-1];
  logic signed [DIN_W-1:0] w_bank1 [0:R-1][0:C-1];
  logic signed [19:0]      e_bank0 [0:R-1][0:C-1];   // programming error, Q.8
  logic signed [19:0]      e_bank1 [0:R-1][0:C-1];

  // ---- Error-model configuration and generators ----
  logic [6:0]  impair_r;
  logic [3:0]  abits_r, wbits_r, adcbits_r;
  logic [5:0]  shift_r;
  logic [15:0] sigma_th_r, k_shot_r, sigma_pr_r;
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
      rng_th     <= K_THERMAL;
      rng_sh     <= K_SHOT;
      rng_pr     <= K_PROG;
    end else if (i_pta_cfg_load) begin
      impair_r   <= i_pta_impair;
      abits_r    <= i_pta_act_bits;
      wbits_r    <= i_pta_w_bits;
      adcbits_r  <= i_pta_adc_bits;
      shift_r    <= i_pta_adc_shift;
      sigma_th_r <= i_pta_sigma_th;
      k_shot_r   <= i_pta_k_shot;
      sigma_pr_r <= i_pta_sigma_pr;
      rng_th     <= stream_seed(i_pta_seed, K_THERMAL);
      rng_sh     <= stream_seed(i_pta_seed, K_SHOT);
      rng_pr     <= stream_seed(i_pta_seed, K_PROG);
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
    logic signed [19:0]      e;
    logic signed [63:0]      y, xa, wa;
    logic        [63:0]      ay, v;
    logic        [12:0]      rt;
    logic        [28:0]      krt;
    logic signed [49:0]      sh_prod;
    logic signed [29:0]      n_sh;
    logic signed [30:0]      nsum;
    logic signed [79:0]      z, tq, outw, hi, lo;
    logic                    clamped;
    int                      s, b, tap;

    seed = seed_h[c][2*R - 1];
    y    = 64'sd0;
    for (int r = 0; r < R; r++) begin
      tap = 2*(R - r) + 2*c - 1 + ((r == ABLATE_ROW) ? 1 : 0);
      a   = act_h[r][tap];
      w   = i_bank_sel ? w_bank1[r][c] : w_bank0[r][c];
      if (!modelled) begin
        y = y + 64'(a) * 64'(w);
      end else begin
        e  = i_bank_sel ? e_bank1[r][c] : e_bank0[r][c];
        xa = impair_r[IMP_QUANT] ? 64'(quant(int'(a), int'(abits_r))) : 64'(a);
        wa = (impair_r[IMP_QUANT] ? 64'(quant(int'(w), int'(wbits_r))) : 64'(w)) * 64'sd256 +
             (impair_r[IMP_PROG]  ? 64'(e) : 64'sd0);
        y  = y + xa * wa;                            // Q.8, tile units
      end
    end
    if (!modelled)
      return {1'b0, seed + y[ACC_W-1:0]};

    s       = int'(shift_r);
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
    return {clamped, seed + outw[ACC_W-1:0]};
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
