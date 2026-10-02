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
// The floor is two cycles: the register at the tile's input and the register at
// its output.  It was six until the hop came out -- the core fed this tile on
// half-rate hop edges and the capture waited for one, because that is what PTM-C
// needs to emulate a systolic array.  A broadside tile is not emulating one, so
// nothing here waits for a hop now, and what is left will not go without making
// the tile combinational.  C4(b) already showed that is the wrong direction: the
// activation stage's Fmax is what the board plan's 100 MHz rests on.
//
// Section 6.2's EO points assume Ts = 1; on this core they are Ts = 3 -- the two
// registers plus the register that takes the start strobe.  That is a property of
// the host, like the weight scan the same section refuses to design out, and it is
// reported rather than hidden.
// -----------------------------------------------------------------------------

module c930_ptm_b
#(
  parameter int NUM_ROWS   = 8,
  parameter int NUM_COLS   = 8,
  parameter int DIN_W      = 8,
  parameter int ACC_W      = 48,
  parameter int TRIM_W     = 24,
  // Passed to the tile.  Two keeps every port a single bit; step MB wants Nt*Kt.
  parameter int NUM_BANKS  = 2,
  parameter int BANK_W     = (NUM_BANKS <= 2) ? 1 : $clog2(NUM_BANKS)
)
(
  input  logic                                     i_clk,
  input  logic                                     i_rst_n,

  // Weight port, as the array's and PTM-C's: one cell a beat.
  input  logic                                     i_wen,
  input  logic [BANK_W-1:0]                        i_wbank,
  input  logic [$clog2(NUM_ROWS)-1:0]              i_wrow,
  input  logic [$clog2(NUM_COLS)-1:0]              i_wcol,
  input  logic signed [DIN_W-1:0]                  i_wdata,
  input  logic [BANK_W-1:0]                        i_bank_sel,

  // The shot.  i_act is the whole K-tile vector, i_ps_in the seed to add.
  input  logic signed [NUM_ROWS*DIN_W-1:0]         i_act,
  input  logic signed [NUM_COLS*ACC_W-1:0]         i_ps_in,
  input  logic [NUM_ROWS-1:0]                      i_row_en,
  input  logic [2:0]                               i_precision,
  input  logic                                     i_shot_start,
  input  logic [31:0]                              i_ts,       // PTA_TS, dilation
  // The calibration engine drives the tile directly while it holds it, one
  // column a shot, so its strobes pass through ahead of the schedule below.
  // Broadside a probe shot still illuminates every column -- which is what the
  // tile does -- so the draws advance per column as they do for a GEMM.
  input  logic                                     i_cal_busy,
  input  logic                                     i_cal_shot_start,
  input  logic                                     i_cal_shot,
  input  logic [$clog2(NUM_COLS)-1:0]              i_cal_shot_col,
  // Passed straight through; see c930_ptm_c.sv, where 0 means all columns.
  input  logic [$clog2(NUM_COLS):0]                i_pta_shot_cols,
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
  input  logic [BANK_W-1:0]                        i_pta_trim_bank,
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
  typedef enum logic [1:0] { S_IDLE, S_SHOT, S_WAIT } state_e;
  state_e      st;
  logic [31:0] wait_cnt;
  logic        shot_now;          // this cycle takes the shot

  // S_SHOT is exactly one cycle, so this is a one-cycle strobe -- which it has to
  // be, because the tile's streams step on the shot now rather than on a hop.
  //
  // It needs no hop and no operands_in handshake.  The core registers its broadside
  // feed every cycle (there is no skew to build, so nothing to build at half rate),
  // and act_comb is already valid on the cycle S_RUN is entered, so the operands
  // are at the tile by the time this state is.
  assign shot_now = (st == S_SHOT);

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
        // One cycle.  The tile captures on it, and o_valid is raised as this state
        // is left rather than from a state of its own -- ps_out_q and o_valid then
        // land on the same cycle, which is the one the core reads.
        S_SHOT: begin
          if (i_ts > 32'd1) begin
            wait_cnt <= 32'd0;
            st       <= S_WAIT;
          end else begin
            o_valid <= 1'b1;
            st      <= S_IDLE;
          end
        end
        // The modelled shot latency, on top of the cycle the shot itself cost.
        S_WAIT: begin
          if (wait_cnt >= i_ts - 32'd2) begin
            o_valid <= 1'b1;
            st      <= S_IDLE;
          end else begin
            wait_cnt <= wait_cnt + 32'd1;
          end
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
    .NUM_BANKS  (NUM_BANKS),
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
    // shot_start is the REQUEST, not the shot: inside, BROADSIDE makes
    // drift_tick i_pta_shot_start and cap_tick i_pta_shot, so driving both from
    // shot_now put the drift step and the capture on one edge and the capture
    // read the drift from before the step -- every shot seeing the previous
    // shot's.  Skewed, drift_tick fires at t = 0 and the captures start at
    // t = 2R, so the step is an edge ahead; pta_tile_model.c matches that,
    // calling pta_shot_start() before it computes the shot.  S_SHOT is the cycle
    // after i_shot_start, so the request restores that ordering.
    .i_pta_shot_start   (i_cal_busy ? i_cal_shot_start : i_shot_start),
    .i_pta_shot         (i_cal_busy ? i_cal_shot       : shot_now),
    .i_pta_shot_col     (i_cal_busy ? i_cal_shot_col   : '0),
    .i_pta_shot_cols    (i_pta_shot_cols),
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
