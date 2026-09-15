// -----------------------------------------------------------------------------
// c930_ptm_c.sv
//
// PTM-C: the compatibility shim of grxcp docs/designs/pta_cpu_integration.md
// section 4.1.  It has c930_systolic_array's port list, parameter for
// parameter, and replaces the array's skewed PE grid with one broadside
// evaluation per column.  With every impairment off -- and this phase has
// none -- it is bit-identical to the array.
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
// order is a different function.  The integer columns sum in ACC_W bits.
//
// ABLATE_ROW moves one row's de-skew a window late.  Phase C0 requires that to
// fail the NPU testbenches; the default, -1, touches nothing.
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

  input  logic [NUM_ROWS-1:0]                      i_row_en
);

  localparam int R = NUM_ROWS;
  localparam int C = NUM_COLS;
  // Deepest activation tap is row 0 at the last column, 2R + 2C - 3 windows
  // back, plus one for the ablation.  The seed tap is 2R - 1.
  localparam int ACT_DEPTH  = 2*R + 2*C;
  localparam int SEED_DEPTH = 2*R;

  // ---- Weight banks, written as the array's PEs write theirs ----
  logic signed [DIN_W-1:0] w_bank0 [0:R-1][0:C-1];
  logic signed [DIN_W-1:0] w_bank1 [0:R-1][0:C-1];

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      for (int r = 0; r < R; r++)
        for (int c = 0; c < C; c++) begin
          w_bank0[r][c] <= '0;
          w_bank1[r][c] <= '0;
        end
    end else if (i_wen) begin
      if (i_wbank) w_bank1[i_wrow][i_wcol] <= i_wdata;
      else         w_bank0[i_wrow][i_wcol] <= i_wdata;
    end
  end

  // ---- Hop phase: the PEs' free-running toggle, in lockstep from reset ----
  logic hop;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) hop <= 1'b0;
    else          hop <= ~hop;
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

  // ---- The shot: every column over the operands its cascade would meet ----
  logic signed [ACC_W-1:0] y_int [0:C-1];
  logic [31:0]             y_fp  [0:C-1];

  generate
    genvar gc, gr;
    for (gc = 0; gc < C; gc = gc + 1) begin : g_col
      logic [31:0]             fp_chain  [0:R];
      logic signed [ACC_W-1:0] int_terms [0:R-1];
      wire  signed [ACC_W-1:0] seed = seed_h[gc][2*R - 1];

      assign fp_chain[0] = seed[31:0];

      for (gr = 0; gr < R; gr = gr + 1) begin : g_row
        localparam int ACT_TAP = 2*(R - gr) + 2*gc - 1 + ((gr == ABLATE_ROW) ? 1 : 0);
        localparam int REN_TAP = 2*(R - gr) - 1;

        wire signed [DIN_W-1:0]   a = act_h[gr][ACT_TAP];
        wire signed [DIN_W-1:0]   w = i_bank_sel ? w_bank1[gr][gc] : w_bank0[gr][gc];
        wire signed [2*DIN_W-1:0] int_prod = a * w;
        wire [31:0]               fp_prod;

        c930_fp_mul u_fp_mul (
          .i_a      (a[15:0]),
          .i_b      (w[15:0]),
          .i_mode   (i_precision == 3'd3),
          .o_result (fp_prod)
        );

        c930_fp32_add u_fp_add (
          .i_ps   (fp_chain[gr]),
          .i_prod (ren_h[gr][REN_TAP] ? fp_prod : 32'h0),
          .o_sum  (fp_chain[gr+1])
        );

        assign int_terms[gr] = {{(ACC_W-2*DIN_W){int_prod[2*DIN_W-1]}}, int_prod};
      end

      always_comb begin
        y_int[gc] = seed;
        for (int r = 0; r < R; r++) y_int[gc] = y_int[gc] + int_terms[r];
      end
      assign y_fp[gc] = fp_chain[R];
    end
  endgenerate

  // ---- Re-skew: the hop-edge register the array's last PE row would be ----
  logic signed [ACC_W*C-1:0] ps_out_q;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      ps_out_q <= '0;
    end else if (hop) begin
      for (int c = 0; c < C; c++) begin
        if (i_precision == 3'd2 || i_precision == 3'd3)
          ps_out_q[c*ACC_W +: ACC_W] <= {{(ACC_W-32){1'b0}}, y_fp[c]};
        else
          ps_out_q[c*ACC_W +: ACC_W] <= y_int[c];
      end
    end
  end

  assign o_ps_out = ps_out_q;

endmodule
