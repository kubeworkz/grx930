// -----------------------------------------------------------------------------
// c930_pta_cal.sv
//
// C3(b): the calibration engine of grxcp docs/designs/pta_cpu_integration.md
// section 5.1 and docs/designs/pta_chiplet_calibration.md -- the scheduler, the
// probe, the estimator, and the writes into the tile's trim store.  It drives
// c930_ptm_c's tile through the core, which grants it the tile at a point where
// nothing is in flight; c930_npu_core.sv's S_CAL is that grant.
//
// What it corrects, and what it does not.  The cell loop, which this
// implements: every cell's programming error and accumulated drift, measured
// one-hot and written into the weight DAC's trim.  The column loop -- the
// per-column affine -- corrects a receiver's gain and offset, and the error
// model has neither, so there is nothing here to estimate: the affine store
// exists, the tile applies it, and the host writes it.  That is what the
// calibration document's section 8 says, and it is why this file has one
// estimator rather than two.
//
// The probe (calibration document section 3).  Zero every weight of the bank,
// drive one row at the probe amplitude with every other row at zero, and each
// column reports that row's cell:
//
//   out_rn  ~  q_a(amp) * (e_rn + d_rn + trim_rn) / 256
//
// so R shots measure the whole tile, and the trim to write is the negative of
// what came back.  Each repeat rewrites the weights, which redraws every cell's
// programming error, so averaging over repeats beats the error that is redrawn
// without touching the drift that is not.  The noise streams are never
// reloaded: a calibration is not a GEMM start, the streams run through it, and
// that is what makes one repeat differ from the next.
//
// The estimator, cell by cell, in the units of the contract:
//
//   pa     = 1 << i_amp_log2, the probe amplitude, which the activation
//            quantiser has to leave alone: i_amp_log2 in [DIN_W - B_a,
//            DIN_W - 2].  Outside it o_err is raised and no trim is written.
//   sum    = the cell's captured values summed over 1 << i_reps_log2 repeats
//   delta  = -sign(sum) * ((|sum| << 8) >> (i_amp_log2 + i_reps_log2))
//   trim  <- trim + delta, where trim is what the DAC holds now (read back
//            through o_pta_trim_rdata, so a host write is never out of step)
//            and the DAC rounds the request to its own step and clamps it.  o_drift_alarm is a cell whose trim could not
//            reach what the estimator asked for: the tile saying that cell
//            needs a weight rewrite or a service call.
//
// Auto-ranging, which C3(a) measured (calibration document section 8).  A
// network's ADC shift is set for sums thousands of units wide where a cell's
// error is a handful, so a probe at the GEMM's range reads almost nothing: it
// recovered 2 points of the 15 that were there to recover until the probe took
// its own range.  PASSES passes, each picking the smallest shift whose codes
// span what is left to measure, each refining the range from what the last
// pass left behind:
//
//   pass 0    range = pa * trim_max / 256          (what a trim can hold)
//             i_passes of them, PTA_CAL_CFG[9:8]; zero means one
//   pass i    range = 4 * worst + 8                (worst = max |sum| / repeats)
//   shift     the smallest s with range <= (2^(B_adc-1) - 1) << s, 0 .. 40
//
// With the ADC unquantised there is nothing to refine and one pass is exact.
//
// The four schedulers (PTA_CTRL[6:4], section 5.1), with PTA_CAL_CT and
// PTA_CAL_CYC counting what each of them costs:
//
//   0 off         only PTA_CTRL.CAL_NOW fires a calibration
//   1 periodic    every i_cal_per cycles
//   2 predictive  no more often than i_cal_per, and then on the extrapolation:
//                 with r1 the error the last calibration FOUND and L1 the cycles
//                 it accumulated over, and r0, L0 the pair before it, the error
//                 predicted after E cycles is E * max(r1/L1, r0/L0), and it
//                 fires when that reaches i_cal_thr.  Compared as two products,
//                 E*r >= thr*L, so there is no divider.
//                 Found, not left: the CPU document says to extrapolate the last
//                 two residuals, but a residual is what a calibration leaves,
//                 and one that worked leaves almost nothing -- so the rate it
//                 implies is almost zero and the scheduler stops scheduling.
//                 o_err_found is the widest delta of the first pass, before any
//                 of it has been corrected, which is the error that accumulated
//                 over the interval.  o_err_max keeps its meaning and its
//                 register: what is left afterwards, which is what C3's gate
//                 reports.  Two more things the extrapolation needs: a found
//                 error of zero counts as one unit, since a rate of zero
//                 predicts no error however long the wait; and i_cal_per floors
//                 the interval, because a short interval reads as a steep rate
//                 and calibration then runs away
//   3 shadow      the same floor, and then inside an idle window the tile is in
//                 anyway -- on this core a row the DMA has not landed yet --
//                 once the predicted error is over i_cal_thr/4, with the
//                 predictive rule as the backstop the document asks for
//
// A scheduler fires by raising o_req, and the core grants when it can.  In
// shadow mode the request is withdrawn when the window closes, which is what
// keeps a shadow calibration inside one and makes a periodic one pay for
// itself at a row boundary.
//
// Everything here is exact integer arithmetic with one division, by a power of
// two.  sim/pta_tile_model.c's pta_cal_bank() is the C reference: same probe,
// same estimator, same ranging, and gate P8 holds the two to the same trims.
// -----------------------------------------------------------------------------

module c930_pta_cal
#(
  parameter int NUM_ROWS = 8,
  parameter int NUM_COLS = 8,
  parameter int DIN_W    = 8,
  parameter int ACC_W    = 48,
  parameter int TRIM_W   = 32,   // the trim as the estimator asks for it
  parameter int SUM_W    = 56    // a cell's captures summed over the repeats
)
(
  input  logic                              i_clk,
  input  logic                              i_rst_n,

  // ---- Configuration (PTA_CTRL and PTA_CAL_* of pta_cpu_integration.md 3.1) ----
  input  logic                              i_en,          // PTA_CTRL.EN
  input  logic                              i_cal_now,     // PTA_CTRL.CAL_NOW, a pulse
  input  logic [1:0]                        i_sched,       // PTA_CTRL.CAL_SCHED
  input  logic [31:0]                       i_cal_per,     // PTA_CAL_PER
  input  logic [23:0]                       i_cal_thr,     // PTA_CAL_THR, Q.8 weight LSB
  input  logic [3:0]                        i_amp_log2,    // probe amplitude, 1 << this
  input  logic [3:0]                        i_reps_log2,   // repeats a pass, 1 << this
  input  logic [1:0]                        i_passes,      // auto-ranging passes; 0 is 1
  input  logic [3:0]                        i_act_bits,    // B_a
  input  logic [3:0]                        i_adc_bits,    // B_adc
  input  logic                              i_quant,       // QUANT is on
  input  logic [15:0]                       i_trim_max,    // the DAC's clamp, Q.8
  input  logic                              i_bank,        // the bank to calibrate
  input  logic [31:0]                       i_cal_seed,    // the streams' seed (see o_load)
  input  logic                              i_cal_rst,     // clear the status bits below

  // ---- The core's grant ----
  input  logic                              i_shadow,      // an idle window, free of charge
  output logic                              o_req,
  input  logic                              i_grant,       // the tile is ours from now
  output logic                              o_busy,        // PTA_STATUS.CAL_BUSY
  output logic                              o_done,        // one cycle, at the end

  // ---- The tile, while granted ----
  input  logic                              i_hop,         // the tile's hop phase
  output logic                              o_wen,         // zero this weight
  output logic [$clog2(NUM_ROWS)-1:0]       o_wrow,
  output logic [$clog2(NUM_COLS)-1:0]       o_wcol,
  output logic signed [NUM_ROWS*DIN_W-1:0]  o_act,         // one-hot, on the hop schedule
  output logic                              o_shot_start,
  output logic                              o_shot,
  output logic [$clog2(NUM_COLS)-1:0]       o_shot_col,
  output logic                              o_shift_en,    // the probe's own ADC range
  output logic [5:0]                        o_shift,
  // One cycle at the grant: the tile's noise streams load from o_seed, which
  // is i_cal_seed mixed with the calibration's number so that no two draw the
  // same noise.  They then run through the whole calibration.
  output logic                              o_load,
  output logic [31:0]                       o_seed,
  input  logic signed [NUM_COLS*ACC_W-1:0]  i_ps_out,

  // ---- The trim store ----
  output logic                              o_trim_wen,
  output logic                              o_trim_bank,
  output logic [$clog2(NUM_ROWS)-1:0]       o_trim_row,
  output logic [$clog2(NUM_COLS)-1:0]       o_trim_col,
  output logic signed [TRIM_W-1:0]          o_trim_data,
  input  logic signed [TRIM_W-1:0]          i_trim_rdata,  // what the DAC holds now
  input  logic                              i_trim_clamped,

  // ---- Status and counters ----
  output logic [31:0]                       o_cal_ct,      // PTA_CAL_CT
  output logic [31:0]                       o_cal_cyc,     // PTA_CAL_CYC, cumulative
  output logic [23:0]                       o_err_max,     // PTA_ERR_MAX, Q.8 weight LSB
  output logic [23:0]                       o_err_found,   // ... and what it found, Q.8
  output logic                              o_cal_valid,   // PTA_STATUS.CAL_VALID
  output logic                              o_drift_alarm, // PTA_STATUS.DRIFT_ALARM
  output logic                              o_err          // PTA_IRQ_STATUS.ERR
);

  localparam int R  = NUM_ROWS;
  localparam int C  = NUM_COLS;
  localparam int RW = $clog2(NUM_ROWS);
  localparam int CW = $clog2(NUM_COLS);
  localparam int NCELL = NUM_ROWS * NUM_COLS;
  localparam int KW = $clog2(NUM_ROWS*NUM_COLS) + 1;

  localparam logic [1:0] SCH_OFF  = 2'd0;
  localparam logic [1:0] SCH_PER  = 2'd1;
  localparam logic [1:0] SCH_PRED = 2'd2;
  localparam logic [1:0] SCH_SHAD = 2'd3;

  localparam logic [3:0] C_IDLE = 4'd0;   // not calibrating
  localparam logic [3:0] C_REQ  = 4'd1;   // asking for the tile
  localparam logic [3:0] C_RNG  = 4'd2;   // picking this pass's range
  localparam logic [3:0] C_ZERO = 4'd3;   // zeroing the bank's weights
  localparam logic [3:0] C_SHOT = 4'd4;   // one shot of the one-hot probe
  localparam logic [3:0] C_NEXT = 4'd5;   // next repeat, or on to the estimator
  localparam logic [3:0] C_ESTW = 4'd6;   // a cell's trim written
  localparam logic [3:0] C_ESTR = 4'd7;   // ... and read back as the DAC took it
  localparam logic [3:0] C_END  = 4'd8;

  logic [3:0] cs;

  // ---- The measurement ----
  logic signed [SUM_W-1:0]  sum   [0:NCELL-1];  // captures summed over the repeats
  logic [1:0]               pass;
  logic [15:0]              rep;
  logic [RW:0]              shot;               // 0 .. R-1, the row driven
  logic [KW-1:0]            cidx;               // 0 .. NCELL-1
  logic [15:0]              t;                  // the shot's hop tick
  logic [5:0]               shift_r;
  logic [39:0]              range;              // what this pass has to span
  logic [39:0]              worst;              // what it left behind
  logic [23:0]              resid;              // max |delta| of this pass, Q.8
  logic [23:0]              found;              // ... and of the first one
  logic                     clamped_any;
  logic                     amp_bad;

  // ---- The scheduler ----
  logic [31:0] cyc_since;      // cycles since the last calibration finished
  logic [31:0] cyc_tot;        // PTA_CAL_CYC: every cycle spent calibrating
  logic [31:0] len1, len0;     // the last two intervals
  logic [23:0] fnd1, fnd0;     // and what each of them found
  logic        now_seen;

  // pa = 1 << i_amp_log2 has to survive the activation quantiser untouched:
  // q(x, B) is the identity on multiples of 2^(DIN_W - B) inside its range.
  wire [4:0]  qh = (i_quant && i_act_bits != 4'd0 && int'(i_act_bits) < DIN_W)
                 ? 5'(DIN_W - int'(i_act_bits)) : 5'd0;
  wire        amp_ok    = (int'(i_amp_log2) <= DIN_W - 2) && (5'(i_amp_log2) >= qh);
  wire        quantised = i_quant && (i_adc_bits != 4'd0);
  // PTA_CAL_CFG[9:8] is two bits, and one pass is the fewest that means
  // anything, so zero reads as one.
  wire [1:0]  passes_eff = (i_passes == 2'd0) ? 2'd1 : i_passes;
  wire [39:0] codes     = quantised ? ((40'd1 << (int'(i_adc_bits) - 1)) - 40'd1) : 40'd0;

  // The error predicted after cyc_since cycles, against the threshold: the
  // steeper of the last two intervals' rates, compared as products.  The rate
  // comes from what those calibrations found, not from what they left.  Zero
  // counts as one unit, since a clean measurement means a stable tile rather
  // than one that will never need calibrating again; and with no history at all
  // there is nothing to extrapolate, so the first calibration is due as soon as
  // the minimum interval below allows it.
  wire        no_hist = (len1 == 32'd0);
  wire [23:0] r1e = (fnd1 == 24'd0) ? 24'd1 : fnd1;
  wire [23:0] r0e = (fnd0 == 24'd0) ? 24'd1 : fnd0;
  wire [55:0] p1  = 56'(cyc_since) * 56'(r1e);
  wire [55:0] p0  = 56'(cyc_since) * 56'(r0e);
  wire [55:0] q1  = 56'(i_cal_thr) * 56'(len1);
  wire [55:0] q0  = 56'(i_cal_thr) * 56'(len0);
  wire [55:0] f1  = 56'({2'd0, i_cal_thr[23:2]}) * 56'(len1);
  wire [55:0] f0  = 56'({2'd0, i_cal_thr[23:2]}) * 56'(len0);
  wire        pred_hit  = no_hist || (p1 >= q1) || ((len0 != 32'd0) && (p0 >= q0));
  wire        floor_hit = no_hist || (p1 >= f1) || ((len0 != 32'd0) && (p0 >= f0));

  // The minimum interval.  Without it the extrapolation runs away: the
  // measurement has a noise floor that the interval does not divide out, so a
  // short interval reads as a steep rate, which fires again sooner, which
  // shortens the interval further.
  // PTA_CAL_PER is "how often" for the periodic scheduler and "no more often
  // than" for the two that predict, so a prediction can only ever ask for fewer
  // calibrations than the periodic scheduler would take.
  wire not_too_soon = (i_cal_per == 32'd0) || (cyc_since >= i_cal_per);

  wire sched_hit = i_en &&
                   ((i_sched == SCH_PER  && i_cal_per != 32'd0 && cyc_since >= i_cal_per) ||
                    (i_sched == SCH_PRED && not_too_soon && pred_hit) ||
                    (i_sched == SCH_SHAD && not_too_soon &&
                     ((i_shadow && floor_hit) || pred_hit)));

  // Calibration j's stream seed, j being PTA_CAL_CT before it runs.
  assign o_seed = i_cal_seed ^ (o_cal_ct * 32'h9E3779B1);

  // ---- The probe's stimulus, on the core's own schedule ----
  // Row r's activation enters at t = 2r and column n's value is registered on
  // the hop edge that ends t = 2R + 1 + 2n, exactly as S_RUN drives and
  // captures them, so the tile cannot tell a probe from a GEMM.
  wire        in_shot = (cs == C_SHOT);
  wire [15:0] amp     = 16'd1 << i_amp_log2;

  always_comb begin
    o_act = '0;
    if (in_shot)
      for (int r = 0; r < R; r++)
        if ((t == 16'(2*r)) && (int'(shot) == r))
          o_act[r*DIN_W +: DIN_W] = DIN_W'(amp);
  end

  assign o_shot_start = in_shot && (t == 16'd0);
  assign o_shot       = in_shot && (t >= 16'(2*R)) && !t[0] && (t < 16'(2*R + 2*C));
  assign o_shot_col   = CW'((t - 16'(2*R)) >> 1);
  assign o_shift_en   = o_busy;
  assign o_shift      = shift_r;

  assign o_wen  = (cs == C_ZERO);
  assign o_wrow = RW'(cidx / KW'(C));
  assign o_wcol = CW'(cidx % KW'(C));

  assign o_trim_wen  = (cs == C_ESTW);
  assign o_trim_bank = i_bank;
  assign o_trim_row  = RW'(cidx / KW'(C));
  assign o_trim_col  = CW'(cidx % KW'(C));

  // CAL_BUSY covers the handover as well as the work: o_done is raised on the
  // edge that leaves C_END, and the core does not leave S_CAL until it has seen
  // it, so dropping CAL_BUSY at C_END would leave one cycle in which the tile is
  // still the engine's and a dispatcher believes otherwise.
  assign o_busy    = ((cs != C_IDLE) && (cs != C_REQ)) || o_done;
  assign o_cal_cyc   = cyc_tot;
  assign o_err_max   = resid;
  assign o_err_found = found;

  // ---- The estimator's one division, which is a shift ----
  // delta = -(sum * 256) / (pa * repeats), truncated toward zero as the C
  // reference truncates it, with pa and the repeat count powers of two.
  wire signed [SUM_W-1:0] s_cell = sum[cidx];
  wire [SUM_W-1:0]        s_mag  = s_cell[SUM_W-1] ? SUM_W'(-s_cell) : SUM_W'(s_cell);
  wire [SUM_W+7:0]        s_num  = {s_mag, 8'd0};
  wire [SUM_W+7:0]        s_q    = s_num >> (int'(i_amp_log2) + int'(i_reps_log2));
  wire signed [TRIM_W:0]  delta  = s_cell[SUM_W-1] ? $signed({1'b0, TRIM_W'(s_q)})
                                                   : -$signed({1'b0, TRIM_W'(s_q)});
  wire [39:0]             d_mag  = 40'(s_q);
  // |sum| / repeats: what this pass could not remove, in its own ADC units.
  wire [39:0]             left   = 40'(s_mag >> int'(i_reps_log2));

  // The trim request, saturated into the word the DAC takes.  The C reference
  // carries an int64 here and saturates at the same place, so the two agree.
  localparam logic signed [TRIM_W+1:0] T_HI =  (TRIM_W+2)'((64'd1 << (TRIM_W-1)) - 64'd1);
  localparam logic signed [TRIM_W+1:0] T_LO = -(TRIM_W+2)'(64'd1 << (TRIM_W-1));
  wire signed [TRIM_W+1:0] t_sum = (TRIM_W+2)'(i_trim_rdata) + (TRIM_W+2)'(delta);
  assign o_trim_data = (t_sum > T_HI) ? TRIM_W'(T_HI)
                     : (t_sum < T_LO) ? TRIM_W'(T_LO) : TRIM_W'(t_sum);

  always_ff @(posedge i_clk or negedge i_rst_n) begin : b_cal
    int cap_col;
    if (!i_rst_n) begin
      cs            <= C_IDLE;
      o_req         <= 1'b0;
      o_done        <= 1'b0;
      o_load        <= 1'b0;
      o_cal_ct      <= 32'd0;
      o_cal_valid   <= 1'b0;
      o_drift_alarm <= 1'b0;
      o_err         <= 1'b0;
      pass          <= 2'd0;
      rep           <= 16'd0;
      shot          <= '0;
      cidx          <= '0;
      t             <= 16'd0;
      shift_r       <= 6'd0;
      range         <= 40'd0;
      worst         <= 40'd0;
      resid         <= 24'd0;
      found         <= 24'd0;
      clamped_any   <= 1'b0;
      amp_bad       <= 1'b0;
      cyc_since     <= 32'd0;
      cyc_tot       <= 32'd0;
      len1          <= 32'd0;
      len0          <= 32'd0;
      fnd1          <= 24'd0;
      fnd0          <= 24'd0;
      now_seen      <= 1'b0;
      for (int i = 0; i < NCELL; i++) sum[i] <= '0;
    end else begin
      o_done <= 1'b0;
      o_load <= 1'b0;

      // CAL_NOW is a pulse on a register write; hold it until it is served.
      if (i_cal_now && i_en) now_seen <= 1'b1;

      // PTA_CTRL.MODEL_RST clears the correction, and with it what the engine
      // has to say about a correction that is no longer there.
      if (i_cal_rst) begin
        o_err         <= 1'b0;
        o_drift_alarm <= 1'b0;
        o_cal_valid   <= 1'b0;
      end

      if (o_busy) begin
        cyc_tot <= cyc_tot + 32'd1;
      end else if (cyc_since != 32'hFFFF_FFFF) begin
        cyc_since <= cyc_since + 32'd1;
      end

      case (cs)
        C_IDLE: begin
          if (i_en && (now_seen || sched_hit)) begin
            o_req <= 1'b1;
            cs    <= C_REQ;
          end
        end

        // Held until the core hands the tile over.
        C_REQ: begin
          if (i_grant) begin
            o_load      <= 1'b1;
            o_req       <= 1'b0;
            now_seen    <= 1'b0;
            pass        <= 2'd0;
            rep         <= 16'd0;
            cidx        <= '0;
            worst       <= 40'd0;
            resid       <= 24'd0;
            shift_r     <= 6'd0;
            clamped_any <= 1'b0;
            o_cal_valid <= 1'b0;
            // pa * trim_max / 256: the widest error a trim could hold.
            range       <= (40'(i_trim_max) << i_amp_log2) >> 8;
            amp_bad     <= !amp_ok;
            if (!amp_ok) begin
              o_err <= 1'b1;            // refused: the probe could not be read back
              cs    <= C_END;
            end else begin
              cs <= C_RNG;
            end
          end else if (!now_seen && !sched_hit) begin
            o_req <= 1'b0;              // the window closed before we were let in
            cs    <= C_IDLE;
          end
        end

        // The smallest ADC shift whose codes span what is left to measure.
        // One cycle a step, 40 at the worst, which is the ADC's own limit.
        C_RNG: begin
`ifdef PTA_CAL_ABLATE_RANGE
          // The ablation of C3(a)'s finding: a probe that does not take its own
          // range reads a cell's error against a GEMM's, and recovers little.
          if (1'b1) begin
`else
          if (!quantised) begin
`endif
            shift_r <= 6'd0;
            cidx    <= '0;
            cs      <= C_ZERO;
          end else if (shift_r < 6'd40 && range > (codes << shift_r)) begin
            shift_r <= shift_r + 6'd1;
          end else begin
            cidx <= '0;
            cs   <= C_ZERO;
          end
        end

        // Every weight of the bank to zero, row by row, as S_WLOAD writes
        // them: the write redraws that cell's programming error, which is the
        // error the repeats average away.  A pass's first repeat clears the
        // sums as it goes.
        C_ZERO: begin
          if (rep == 16'd0) sum[cidx] <= '0;
          if (cidx == KW'(NCELL - 1)) begin
            cidx <= '0;
            shot <= '0;
            t    <= 16'd0;
            cs   <= C_SHOT;
          end else begin
            cidx <= cidx + KW'(1);
          end
        end

        // One shot: row `shot` at the probe amplitude, every column captured.
        C_SHOT: begin
          if (i_hop) begin
            if (t >= 16'(2*R + 1) && t[0]) begin
              cap_col = (int'(t) - 2*R - 1) / 2;
              sum[KW'(int'(shot) * C + cap_col)] <= sum[KW'(int'(shot) * C + cap_col)] +
                  SUM_W'($signed(i_ps_out[cap_col*ACC_W +: ACC_W]));
            end
            if (t == 16'(2*R + 2*C - 1)) begin
              t <= 16'd0;
              if (int'(shot) == R - 1) begin
                cidx <= '0;
                cs   <= C_NEXT;
              end else begin
                shot <= shot + (RW+1)'(1);
              end
            end else begin
              t <= t + 16'd1;
            end
          end
        end

        // A repeat ends with the tile measured; the pass ends when the last
        // repeat has been summed into it.
        C_NEXT: begin
          cidx <= '0;
          if (rep == (16'd1 << i_reps_log2) - 16'd1) begin
            cs <= C_ESTW;
          end else begin
            rep <= rep + 16'd1;
            cs  <= C_ZERO;
          end
        end

        // The estimator, a cell at a time: the trim it asks for goes to the
        // DAC, and what the DAC took comes back as that cell's new total.
        C_ESTW: begin
          if (d_mag[39:24] != 16'd0)      resid <= 24'hFFFFFF;
          else if (d_mag[23:0] > resid)   resid <= d_mag[23:0];
          if (left > worst)               worst <= left;
          cs <= C_ESTR;
        end

        C_ESTR: begin
          if (i_trim_clamped) clamped_any <= 1'b1;
          if (cidx == KW'(NCELL - 1)) begin
            cidx <= '0;
            // The first pass measures the tile before anything is corrected, so
            // its widest delta is the error that accumulated over the interval.
            if (pass == 2'd0) found <= resid;
            // The next pass measures what this one left behind; with the ADC
            // unquantised there is nothing to refine.
            if (!quantised || pass == passes_eff - 2'd1) begin
              cs <= C_END;
            end else begin
              pass    <= pass + 2'd1;
              rep     <= 16'd0;
              range   <= (worst << 2) + 40'd8;
              worst   <= 40'd0;
              resid   <= 24'd0;
              shift_r <= 6'd0;
              cs      <= C_RNG;
            end
          end else begin
            cidx <= cidx + KW'(1);
            cs   <= C_ESTW;          // on to the next cell
          end
        end

        C_END: begin
          o_done        <= 1'b1;
          o_cal_valid   <= !amp_bad;
          o_drift_alarm <= clamped_any;
          if (!amp_bad) begin
            o_cal_ct <= o_cal_ct + 32'd1;
            len0     <= len1;
            fnd0     <= fnd1;
            len1     <= cyc_since;
            fnd1     <= found;          // what this one found, over that interval
          end
          cyc_since <= 32'd0;
          cs        <= C_IDLE;
        end

        default: cs <= C_IDLE;
      endcase
    end
  end

endmodule
