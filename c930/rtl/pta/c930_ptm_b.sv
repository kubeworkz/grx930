// -----------------------------------------------------------------------------
// c930_ptm_b.sv
//
// PTM-B, the broadside tile of pta_cpu_integration.md section 4.2: takes a whole
// K-tile activation vector, returns a whole column of results after PTA_TS.  The
// variant the section 2 loop interchange is written against, and the one the
// speedup lives in -- PTM-C is where the trust lives, and the two must agree.
//
// They agree by construction rather than by comparison.  This is a shot-and-wait
// schedule wrapped around c930_ptm_c's arithmetic with BROADSIDE = 1, so there is
// one implementation of the error model, one copy of the contract's rounding, and
// nothing to drift.  What BROADSIDE changes, and all it changes:
//
//   * the activation comes from i_act directly rather than from the de-skew
//     history, because the whole vector arrives at once and there is no skew;
//   * the seed comes from i_ps_in directly, for the same reason;
//   * every column is captured on one shot rather than one column a window,
//     each with its own draw, in the column order PTM-C takes them in.
//
// What this module adds is the schedule:
//
//   i_shot_start    the core presents i_act and asserts this for one cycle.
//   PTA_TS          i_ts cycles of modelled shot latency are then spent.  The
//                   emulation cannot represent a 1-5 ns photonic shot at a 10 ns
//                   cycle (section 6.2), so this is a dilation knob, and the
//                   ratio it sets against PTA_TW is the experiment.
//   o_valid         one cycle, with o_ps_out holding every column.
//
// The floor is two cycles, not one.  grx930's array runs on a half-rate hop and
// the tile captures on hop edges, so a shot cannot be shorter than one hop.
// Section 6.2's EO points assume Ts = 1; on this core they are Ts = 2.  That is a
// property of the host, like the 64-cycle weight scan the same section refuses to
// design out, and it is reported rather than hidden.
// -----------------------------------------------------------------------------

module c930_ptm_b
#(
  parameter int NUM_ROWS   = 8,
  parameter int NUM_COLS   = 8,
  parameter int DIN_W      = 8,
  parameter int ACC_W      = 48,
  parameter int TRIM_W     = 24
)
(
  input  logic                                     i_clk,
  input  logic                                     i_rst_n,

  // Weight port, as the array's and PTM-C's: one cell a beat.
  input  logic                                     i_wen,
  input  logic                                     i_wbank,
  input  logic [$clog2(NUM_ROWS)-1:0]              i_wrow,
  input  logic [$clog2(NUM_COLS)-1:0]              i_wcol,
  input  logic signed [DIN_W-1:0]                  i_wdata,
  input  logic                                     i_bank_sel,

  // The shot.  i_act is the whole K-tile vector, i_ps_in the seed to add.
  input  logic signed [NUM_ROWS*DIN_W-1:0]         i_act,
  input  logic signed [NUM_COLS*ACC_W-1:0]         i_ps_in,
  input  logic [NUM_ROWS-1:0]                      i_row_en,
  input  logic [2:0]                               i_precision,
  input  logic                                     i_shot_start,
  input  logic [31:0]                              i_ts,       // PTA_TS, dilation
  output logic                                     o_valid,
  output logic signed [ACC_W*NUM_COLS-1:0]         o_ps_out,

  // Error model and corrections, passed through unchanged.
  input  logic                                     i_pta_cfg_load,
  input  logic [6:0]                               i_pta_impair,
  input  logic [3:0]                               i_pta_act_bits,
  input  logic [3:0]                               i_pta_w_bits,
  input  logic [3:0]                               i_pta_adc_bits,
  input  logic [5:0]                               i_pta_adc_shift,
  input  logic [31:0]                              i_pta_seed,
  input  logic [15:0]                              i_pta_sigma_th,
  input  logic [15:0]                              i_pta_k_shot,
  input  logic [15:0]                              i_pta_sigma_pr,
  input  logic [15:0]                              i_pta_drift_sigma,
  input  logic [4:0]                               i_pta_drift_log2,
  input  logic [15:0]                              i_pta_drift_max,
  input  logic [7:0]                               i_pta_xtalk,
  input  logic                                     i_pta_model_rst,
  output logic [31:0]                              o_pta_sat_count,
  input  logic                                     i_pta_trim_wen,
  input  logic                                     i_pta_trim_bank,
  input  logic [$clog2(NUM_ROWS)-1:0]              i_pta_trim_row,
  input  logic [$clog2(NUM_COLS)-1:0]              i_pta_trim_col,
  input  logic signed [TRIM_W-1:0]                 i_pta_trim_data,
  input  logic [3:0]                               i_pta_trim_log2,
  input  logic [15:0]                              i_pta_trim_max,
  output logic signed [TRIM_W-1:0]                 o_pta_trim_rdata,
  output logic                                     o_pta_trim_clamped,
  input  logic                                     i_pta_cal_wen,    // one column's affine
  input  logic [$clog2(NUM_COLS)-1:0]              i_pta_cal_col,
  input  logic signed [17:0]                       i_pta_cal_gain,   // Q8.8, 256 is unity
  input  logic signed [31:0]                       i_pta_cal_offs,
  input  logic                                     i_pta_cal_rst,    // trims 0, affine identity
  input  logic                                     i_pta_cal_load,
  input  logic [31:0]                              i_pta_cal_seed,
  input  logic                                     i_pta_cal_shift_en,
  input  logic [5:0]                               i_pta_cal_shift
);

  // ---- The shot's schedule --------------------------------------------------
  // The tile captures on hop edges, so a shot is taken on the first hop at or
  // after i_shot_start and the dilation is counted from there.  One cycle of
  // o_valid follows; the core reads o_ps_out on it.
  logic        hop;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) hop <= 1'b0;
    else          hop <= ~hop;
  end

  typedef enum logic [1:0] { S_IDLE, S_SHOT, S_WAIT, S_DONE } state_e;
  state_e      st;
  logic [31:0] wait_cnt;
  logic        shot_now;          // this hop takes the shot

  assign shot_now = (st == S_SHOT) && hop;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      st           <= S_IDLE;
      wait_cnt     <= 32'd0;
      o_valid      <= 1'b0;
    end else begin
      o_valid <= 1'b0;
      case (st)
        S_IDLE: begin
          if (i_shot_start) st <= S_SHOT;
        end
        // Held until a hop edge: the capture happens on one, so the shot cannot
        // be shorter than a hop and Ts has a floor of two cycles on this core.
        S_SHOT: begin
          if (hop) begin
            wait_cnt <= 32'd0;
            st       <= (i_ts > 32'd1) ? S_WAIT : S_DONE;
          end
        end
        // The modelled shot latency, beyond the hop the capture already cost.
        S_WAIT: begin
          if (wait_cnt >= i_ts - 32'd2) st <= S_DONE;
          else                          wait_cnt <= wait_cnt + 32'd1;
        end
        S_DONE: begin
          o_valid <= 1'b1;
          st      <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  // ---- The arithmetic, once ------------------------------------------------
  // BROADSIDE = 1 is the whole difference: i_act and i_ps_in read directly, and
  // every column captured on the one shot with its own draw.  The shot strobes
  // are what the schedule above drives; i_pta_shot_col is unused broadside,
  // since there is no column being singled out.
  c930_ptm_c #(
    .NUM_ROWS   (NUM_ROWS),
    .NUM_COLS   (NUM_COLS),
    .DIN_W      (DIN_W),
    .ACC_W      (ACC_W),
    .ABLATE_ROW (-1),
    .TRIM_W     (TRIM_W),
    .BROADSIDE  (1'b1)
  ) u_tile (
    .i_clk              (i_clk),
    .i_rst_n            (i_rst_n),
    .i_wen              (i_wen),
    .i_wbank            (i_wbank),
    .i_wrow             (i_wrow),
    .i_wcol             (i_wcol),
    .i_wdata            (i_wdata),
    .i_bank_sel         (i_bank_sel),
    .i_act              (i_act),
    .i_ps_in            (i_ps_in),
    .o_ps_out           (o_ps_out),
    .i_precision        (i_precision),
    .i_row_en           (i_row_en),
    .i_pta_cfg_load     (i_pta_cfg_load),
    .i_pta_impair       (i_pta_impair),
    .i_pta_act_bits     (i_pta_act_bits),
    .i_pta_w_bits       (i_pta_w_bits),
    .i_pta_adc_bits     (i_pta_adc_bits),
    .i_pta_adc_shift    (i_pta_adc_shift),
    .i_pta_seed         (i_pta_seed),
    .i_pta_sigma_th     (i_pta_sigma_th),
    .i_pta_k_shot       (i_pta_k_shot),
    .i_pta_sigma_pr     (i_pta_sigma_pr),
    .i_pta_drift_sigma  (i_pta_drift_sigma),
    .i_pta_drift_log2   (i_pta_drift_log2),
    .i_pta_drift_max    (i_pta_drift_max),
    .i_pta_xtalk        (i_pta_xtalk),
    .i_pta_model_rst    (i_pta_model_rst),
    .i_pta_shot_start   (shot_now),
    .i_pta_shot         (shot_now),
    .i_pta_shot_col     ('0),
    .o_pta_sat_count    (o_pta_sat_count),
    .i_pta_trim_wen     (i_pta_trim_wen),
    .i_pta_trim_bank    (i_pta_trim_bank),
    .i_pta_trim_row     (i_pta_trim_row),
    .i_pta_trim_col     (i_pta_trim_col),
    .i_pta_trim_data    (i_pta_trim_data),
    .i_pta_trim_log2    (i_pta_trim_log2),
    .i_pta_trim_max     (i_pta_trim_max),
    .o_pta_trim_rdata   (o_pta_trim_rdata),
    .o_pta_trim_clamped (o_pta_trim_clamped),
    .i_pta_cal_wen      (i_pta_cal_wen),
    .i_pta_cal_col      (i_pta_cal_col),
    .i_pta_cal_gain     (i_pta_cal_gain),
    .i_pta_cal_offs     (i_pta_cal_offs),
    .i_pta_cal_rst      (i_pta_cal_rst),
    .i_pta_cal_load     (i_pta_cal_load),
    .i_pta_cal_seed     (i_pta_cal_seed),
    .i_pta_cal_shift_en (i_pta_cal_shift_en),
    .i_pta_cal_shift    (i_pta_cal_shift)
  );

endmodule
