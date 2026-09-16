// -----------------------------------------------------------------------------
// tb_ptm_c_lockstep.sv
//
// PTM-C (rtl/pta/c930_ptm_c.sv) against the systolic array it replaces, cycle
// for cycle: the unit-level half of phase C0 in grxcp
// docs/designs/pta_cpu_integration.md.
//
//   Part 1  c930_fp32_add against c930_fp16_acc, the accumulator whose function
//           it copies: random 32-bit pairs, IEEE specials crossed, and pairs
//           built from the real FP16/BF16 multiplier.
//   Part 2  8x8 array, DIN_W 16, all five precisions: random weights, bank and
//           row enables per episode, then random window-stable activations and
//           seeds -- a superset of what the core drives -- with o_ps_out
//           compared every cycle once the episode's weights have flushed.  Some
//           episodes also change the row enables every window.
//   Part 3  4x4 array, DIN_W 8, the integer precisions.
//   Part 4  a PTM-C with row 3's de-skew one window late must disagree with the
//           array: a comparison nobody has watched fail is not a check.
//
// Inputs change only on hop edges, as the core changes them.  Weights and the
// bank select change only between episodes, as the core's S_WLOAD does.
// The error model's ports are tied off: this is C0's exactness, which C1 must
// keep with every impairment clear.
//
//   make ptm_c_lockstep
// -----------------------------------------------------------------------------
module tb_ptm_c_lockstep;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // TB replica of the PEs' hop toggle, in lockstep from reset.
  logic hop_tb;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) hop_tb <= 1'b0;
    else        hop_tb <= ~hop_tb;
  end

  // ===========================================================================
  // Part 1: c930_fp32_add against c930_fp16_acc
  // ===========================================================================
  logic [31:0] p1_ps, p1_prod;
  logic [31:0] p1_ref, p1_dut;
  int          p1_n = 0, p1_bad = 0;

  c930_fp16_acc u_p1_ref (
    .i_clk    (clk),
    .i_rst_n  (rst_n),
    .i_hop    (1'b1),
    .i_ps_in  (p1_ps),
    .i_prod   (p1_prod),
    .o_ps_out (p1_ref)
  );

  c930_fp32_add u_p1_dut (
    .i_ps   (p1_ps),
    .i_prod (p1_prod),
    .o_sum  (p1_dut)
  );

  logic [15:0] p1_ma, p1_mb;
  logic        p1_mode;
  logic [31:0] p1_mprod;
  c930_fp_mul u_p1_mul (.i_a(p1_ma), .i_b(p1_mb), .i_mode(p1_mode), .o_result(p1_mprod));

  // Apply at a negedge; the reference registers at the posedge; compare before
  // the next negedge changes the operands.
  task automatic p1_check(input logic [31:0] ps, input logic [31:0] prod);
    @(negedge clk);
    p1_ps   = ps;
    p1_prod = prod;
    @(posedge clk);
    #1;
    p1_n++;
    if (p1_ref !== p1_dut) begin
      p1_bad++;
      if (p1_bad <= 8)
        $display("[P1-FAIL] ps=%08h prod=%08h  fp16_acc=%08h fp32_add=%08h", ps, prod, p1_ref, p1_dut);
    end
  endtask

  localparam int N_SPECIALS = 14;
  function automatic logic [31:0] special(input int i);
    case (i)
      0:  special = 32'h00000000;   // +0
      1:  special = 32'h80000000;   // -0
      2:  special = 32'h7f800000;   // +inf
      3:  special = 32'hff800000;   // -inf
      4:  special = 32'h7fc00000;   // quiet NaN
      5:  special = 32'h7f800001;   // signalling NaN
      6:  special = 32'h00000001;   // smallest subnormal
      7:  special = 32'h800fffff;   // negative subnormal
      8:  special = 32'h3f800000;   // 1.0
      9:  special = 32'hbf800000;   // -1.0
      10: special = 32'h7f7fffff;   // largest finite
      11: special = 32'h00800000;   // smallest normal
      12: special = 32'h40000000;   // 2.0
      default: special = 32'hc0490fdb;
    endcase
  endfunction

  task automatic part1();
    for (int i = 0; i < 60000; i++)
      p1_check($urandom, $urandom);
    for (int i = 0; i < N_SPECIALS; i++)
      for (int j = 0; j < N_SPECIALS; j++)
        p1_check(special(i), special(j));
    // Products of the real multiplier, FP16 and BF16, against random sums.
    for (int i = 0; i < 20000; i++) begin
      @(negedge clk);
      p1_ma   = $urandom;
      p1_mb   = $urandom;
      p1_mode = $urandom;
      #1;
      p1_check($urandom, p1_mprod);
    end
    $display("[P1] c930_fp32_add vs c930_fp16_acc: %0d vectors, %0d mismatches", p1_n, p1_bad);
  endtask

  // ===========================================================================
  // Parts 2-4: array against PTM-C
  // ===========================================================================
  localparam int RA = 8, CA = 8, DA = 16;
  localparam int RB = 4, CB = 4, DB = 8;
  localparam int ACC_W = 48;

  logic [2:0] prec_a, prec_b;
  logic       wen_a, wbank_a, bank_sel_a;
  logic [2:0] wrow_a, wcol_a;
  logic signed [DA-1:0]       wdata_a;
  logic signed [RA*DA-1:0]    act_a;
  logic signed [CA*ACC_W-1:0] ps_a;
  logic [RA-1:0]              row_en_a;

  logic       wen_b, wbank_b, bank_sel_b;
  logic [1:0] wrow_b, wcol_b;
  logic signed [DB-1:0]       wdata_b;
  logic signed [RB*DB-1:0]    act_b;
  logic signed [CB*ACC_W-1:0] ps_b;
  logic [RB-1:0]              row_en_b;

  // Every PTM-C instance: error model off, no shots named.
  `define PTA_OFF .i_pta_cfg_load(1'b0), .i_pta_impair(7'd0), .i_pta_act_bits(4'd0), \
    .i_pta_w_bits(4'd0), .i_pta_adc_bits(4'd0), .i_pta_adc_shift(6'd0), .i_pta_seed(32'd0), \
    .i_pta_sigma_th(16'd0), .i_pta_k_shot(16'd0), .i_pta_sigma_pr(16'd0), \
    .i_pta_drift_sigma(16'd0), .i_pta_drift_log2(5'd0), .i_pta_drift_max(16'd0), \
    .i_pta_xtalk(8'd0), .i_pta_model_rst(1'b0), .i_pta_shot_start(1'b0), .i_pta_shot(1'b0), \
    .i_pta_shot_col('0), .o_pta_sat_count()

  wire signed [CA*ACC_W-1:0] out_arr_a, out_ptm_a, out_abl_a;
  wire signed [CB*ACC_W-1:0] out_arr_b, out_ptm_b;

  c930_systolic_array #(.NUM_ROWS(RA), .NUM_COLS(CA), .DIN_W(DA), .ACC_W(ACC_W)) u_arr_a (
    .i_clk(clk), .i_rst_n(rst_n), .i_wen(wen_a), .i_wbank(wbank_a), .i_wrow(wrow_a),
    .i_wcol(wcol_a), .i_wdata(wdata_a), .i_bank_sel(bank_sel_a), .i_act(act_a),
    .i_ps_in(ps_a), .o_ps_out(out_arr_a), .i_precision(prec_a), .i_row_en(row_en_a));

  c930_ptm_c #(.NUM_ROWS(RA), .NUM_COLS(CA), .DIN_W(DA), .ACC_W(ACC_W)) u_ptm_a (
    .i_clk(clk), .i_rst_n(rst_n), .i_wen(wen_a), .i_wbank(wbank_a), .i_wrow(wrow_a),
    .i_wcol(wcol_a), .i_wdata(wdata_a), .i_bank_sel(bank_sel_a), .i_act(act_a),
    .i_ps_in(ps_a), .o_ps_out(out_ptm_a), .i_precision(prec_a), .i_row_en(row_en_a),
    `PTA_OFF);

  c930_ptm_c #(.NUM_ROWS(RA), .NUM_COLS(CA), .DIN_W(DA), .ACC_W(ACC_W), .ABLATE_ROW(3)) u_abl_a (
    .i_clk(clk), .i_rst_n(rst_n), .i_wen(wen_a), .i_wbank(wbank_a), .i_wrow(wrow_a),
    .i_wcol(wcol_a), .i_wdata(wdata_a), .i_bank_sel(bank_sel_a), .i_act(act_a),
    .i_ps_in(ps_a), .o_ps_out(out_abl_a), .i_precision(prec_a), .i_row_en(row_en_a),
    `PTA_OFF);

  c930_systolic_array #(.NUM_ROWS(RB), .NUM_COLS(CB), .DIN_W(DB), .ACC_W(ACC_W)) u_arr_b (
    .i_clk(clk), .i_rst_n(rst_n), .i_wen(wen_b), .i_wbank(wbank_b), .i_wrow(wrow_b),
    .i_wcol(wcol_b), .i_wdata(wdata_b), .i_bank_sel(bank_sel_b), .i_act(act_b),
    .i_ps_in(ps_b), .o_ps_out(out_arr_b), .i_precision(prec_b), .i_row_en(row_en_b));

  c930_ptm_c #(.NUM_ROWS(RB), .NUM_COLS(CB), .DIN_W(DB), .ACC_W(ACC_W)) u_ptm_b (
    .i_clk(clk), .i_rst_n(rst_n), .i_wen(wen_b), .i_wbank(wbank_b), .i_wrow(wrow_b),
    .i_wcol(wcol_b), .i_wdata(wdata_b), .i_bank_sel(bank_sel_b), .i_act(act_b),
    .i_ps_in(ps_b), .o_ps_out(out_ptm_b), .i_precision(prec_b), .i_row_en(row_en_b),
    `PTA_OFF);

  // ---- Streaming: new operands at every hop edge, held for the window ----
  logic streaming = 1'b0;
  logic stream_row_en = 1'b0;
  always @(posedge clk) begin
    if (streaming && hop_tb) begin
      for (int r = 0; r < RA; r++) act_a[r*DA +: DA] <= $urandom;
      for (int c = 0; c < CA; c++) ps_a[c*ACC_W +: ACC_W] <= {$urandom, $urandom};
      for (int r = 0; r < RB; r++) act_b[r*DB +: DB] <= $urandom;
      for (int c = 0; c < CB; c++) ps_b[c*ACC_W +: ACC_W] <= {$urandom, $urandom};
      if (stream_row_en) begin
        row_en_a <= $urandom;
        row_en_b <= $urandom;
      end
    end
  end

  // ---- Checking, once an episode's weights have flushed through the grid ----
  localparam int SETTLE_WINDOWS = 2*RA + 2*CA + 4;
  int  settle = 0;
  logic checking = 1'b0;
  int  n_chk_a = 0, bad_a = 0, n_chk_b = 0, bad_b = 0, diff_abl = 0;

  always @(posedge clk) begin
    if (!checking)       settle <= 0;
    else if (hop_tb)     settle <= settle + 1;
  end

  always @(negedge clk) begin
    if (checking && settle > SETTLE_WINDOWS) begin
      n_chk_a++;
      if (out_arr_a !== out_ptm_a) begin
        bad_a++;
        if (bad_a <= 8)
          for (int c = 0; c < CA; c++)
            if (out_arr_a[c*ACC_W +: ACC_W] !== out_ptm_a[c*ACC_W +: ACC_W])
              $display("[P2-FAIL] t=%0t prec=%0d col %0d: array %012h  ptm_c %012h", $time, prec_a, c,
                       out_arr_a[c*ACC_W +: ACC_W], out_ptm_a[c*ACC_W +: ACC_W]);
      end
      if (out_arr_a !== out_abl_a) diff_abl++;
      n_chk_b++;
      if (out_arr_b !== out_ptm_b) begin
        bad_b++;
        if (bad_b <= 8)
          $display("[P3-FAIL] t=%0t prec=%0d: array %h  ptm_c %h", $time, prec_b, out_arr_b, out_ptm_b);
      end
    end
  end

  task automatic load_weights();
    for (int r = 0; r < RA; r++)
      for (int c = 0; c < CA; c++) begin
        @(negedge clk);
        wen_a   = 1'b1;  wbank_a = $urandom;  wrow_a = r;  wcol_a = c;  wdata_a = $urandom;
        if (r < RB && c < CB) begin
          wen_b = 1'b1;  wbank_b = wbank_a;   wrow_b = r;  wcol_b = c;  wdata_b = $urandom;
        end else begin
          wen_b = 1'b0;
        end
      end
    @(negedge clk);
    wen_a = 1'b0;
    wen_b = 1'b0;
  endtask

  task automatic episode(input logic [2:0] prec, input logic rows_stream, input int windows);
    checking = 1'b0;
    prec_a   = prec;
    // Part 3's 8-bit grid runs the integer modes; a float code maps to INT8.
    prec_b   = (prec == 3'd2 || prec == 3'd3) ? 3'd0 : prec;
    load_weights();
    bank_sel_a    = $urandom;
    bank_sel_b    = $urandom;
    row_en_a      = ($urandom % 3 == 0) ? '1 : $urandom;
    row_en_b      = ($urandom % 3 == 0) ? '1 : $urandom;
    stream_row_en = rows_stream;
    @(negedge clk);
    checking = 1'b1;
    repeat (2 * windows) @(posedge clk);
    checking = 1'b0;
  endtask

  // ===========================================================================
  initial begin
    int seed;
    seed = 20260914;
    seed = $urandom(seed);
    wen_a = 0; wbank_a = 0; wrow_a = 0; wcol_a = 0; wdata_a = 0; bank_sel_a = 0;
    act_a = '0; ps_a = '0; row_en_a = '0; prec_a = 0;
    wen_b = 0; wbank_b = 0; wrow_b = 0; wcol_b = 0; wdata_b = 0; bank_sel_b = 0;
    act_b = '0; ps_b = '0; row_en_b = '0; prec_b = 0;
    p1_ps = 0; p1_prod = 0; p1_ma = 0; p1_mb = 0; p1_mode = 0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    part1();

    streaming = 1'b1;
    for (int ep = 0; ep < 30; ep++)
      episode(3'(ep % 5), (ep % 3) == 2, 240);
    streaming = 1'b0;

    $display("[P2] 8x8 DIN_W 16, all five precisions: %0d cycles compared, %0d mismatches", n_chk_a, bad_a);
    $display("[P3] 4x4 DIN_W 8, integer precisions:  %0d cycles compared, %0d mismatches", n_chk_b, bad_b);
    $display("[P4] ablated PTM-C (row 3 one window late) differed on %0d of %0d cycles", diff_abl, n_chk_a);

    if (p1_bad == 0 && bad_a == 0 && bad_b == 0 && diff_abl > 0 && n_chk_a > 0 && n_chk_b > 0)
      $display("[PASS] PTM-C lockstep");
    else
      $fatal(1, "PTM-C lockstep failed");
    $finish;
  end

endmodule
