// -----------------------------------------------------------------------------
// c930_npu_core.sv
//
// INT8/INT16/FP16/BF16 GEMM engine:  C[M x N] = A[M x K] * B[K x N]
//
// The datapath is a weight-stationary systolic array (c930_systolic_array).
// This controller:
//   * preloads A and B into small internal buffers (data-plane ports),
//   * loops over N-tiles of NUM_COLS each, K-tiles of NUM_ROWS each, and then
//     output rows M innermost, so each B tile is loaded once and reused by
//     every row rather than reloaded per row,
//   * generates the activation skew (row k pulses at cycle k) and the
//     accumulator skew (column n pulses at cycle n),
//   * captures the bottom-edge outputs in a staggered window,
//   * carries the running K accumulation in the C buffer between K tiles,
//     restoring it into acc[] before each run so the arithmetic (including
//     non-associative FP32 addition order) is unchanged.
//
// See c930/doc/c930_architecture.md section 5 for the dataflow proof.
// -----------------------------------------------------------------------------
module c930_npu_core
#(
  parameter int NUM_ROWS = 8,     // systolic rows = reduction elements per pass
  parameter int NUM_COLS = 8,     // systolic cols = output elements per pass
  parameter int DIN_W    = 8,     // activation / weight width
  parameter int ACC_W    = 48,    // accumulator width (48 for INT8/INT16)
  parameter int MAX_M    = 64,    // max output rows
  parameter int MAX_K    = 256,   // max reduction length
  parameter int MAX_N    = 8,     // max output cols (tiled over NUM_COLS passes)
  // Elements the wide preload port writes per cycle.  Must be >= the widest
  // elements-per-beat the DMA drives on that port: AXI_DATA_W/8 = 8 at INT8.
  // Tied to NUM_ROWS by intent, not by necessity -- the compute path already
  // reads NUM_ROWS consecutive elements per cycle, so writing the same number
  // makes a_mem's two ports the same shape, which is what a future banked
  // a_mem would need.
  parameter int WR_LANES = 8
)
(
  input  logic                        i_clk,
  input  logic                        i_rst_n,

  // ---- Data-plane preload / readback (attached to a DMA or debug bus) ----
  input  logic                        i_wen,    // preload write enable
  input  logic                        i_wsel,   // 0 = A, 1 = B
  input  logic [15:0]                 i_waddr,
  input  logic signed [DIN_W-1:0]     i_wdata,

  // ---- Wide preload port: WR_LANES consecutive elements in one cycle ----
  // The narrow port above accepts one element per cycle, which made the DMA
  // eight times slower than its own 64-bit bus: an AXI beat carries 8 INT8
  // elements and took 8 cycles to drain.  This port drains a beat in one.
  //
  // It is affordable because a_mem/b_mem are flop arrays, not block RAM --
  // the compute path reads NUM_ROWS *unaligned* consecutive elements
  // combinationally, which no BRAM can do -- so a wide write buys write
  // enables rather than banking.  It is not free: each element gains a
  // WR_LANES-way address match.  See doc/c930_architecture.md for the
  // banked-a_mem follow-on that makes both ports cheap at once.
  //
  // INT4 does not use this port: it packs 16 elements per beat and its
  // A-load is not on the prefetch path, so it stays on the narrow port.
  input  logic                        i_wwen,
  input  logic                        i_wwsel,    // 0 = A, 1 = B
  input  logic                        i_wwbank,
  input  logic [WR_LANES-1:0]         i_wwmask,   // per-lane enable; tail beats
  input  logic [15:0]                 i_wwaddr,   // element index of lane 0
  input  logic [WR_LANES*DIN_W-1:0]   i_wwdata,   // lane l -> [i_wwaddr + l]

  // ---- Staging buffer load (from DMA PF2 prefetch) ----
  // Active during P_STAGING: loads prefetched A/B data into a_mem/b_mem
  // before the core starts.  Must be deasserted before i_start.
  input  logic                        i_staging_wen,    // staging write enable
  input  logic                        i_staging_wsel,   // 0 = A, 1 = B
  input  logic [15:0]                 i_staging_waddr,
  input  logic signed [DIN_W-1:0]     i_staging_wdata,

  // ---- Control ----
  input  logic                        i_bank_sel, // bank select from DMA: 0=bank0, 1=bank1 (core reads)

  // A-row watermark from the DMA: rows 0 .. i_a_rows_ready-1 are present in
  // a_mem.  The DMA loads only row 0 before i_start and streams the rest in
  // during compute, so without this the core can read a row that has not
  // landed yet and silently compute on zeros.
  //
  // Zero means "no watermark, never wait".  A real GEMM cannot report zero:
  // the DMA has row 0 resident before it pulses i_start, so o_a_rows_ready is
  // at least 1 throughout.  Making 0 the disable value is what keeps an
  // unconnected port fail-safe -- every core-only bench that predates this
  // signal leaves it at 0, and would otherwise sit in S_AROW forever waiting
  // for a row nobody is going to announce.
  input  logic [15:0]                 i_a_rows_ready,
  input  logic                        i_wbank,    // write bank select from DMA: 0=bank0, 1=bank1
  input  logic                        i_start,  // 1-cycle pulse, sampled in IDLE
  // 1-cycle pulse from the DMA: it has abandoned this GEMM (DDR timeout or
  // watchdog), so return to S_IDLE from wherever the FSM is.  Tie low where
  // there is no DMA.
  input  logic                        i_abort,
  input  logic [15:0]                 i_dim_m,
  input  logic [15:0]                 i_dim_n,
  input  logic [15:0]                 i_dim_k,
  input  logic [2:0]                  i_precision,  // 0=INT8, 1=INT16, 2=FP16, 3=BF16, 4=INT4
  output logic                        o_busy,
  output logic                        o_done,   // 1-cycle pulse
  output logic                        o_error,  // sticky, cleared on valid start

  // ---- Result readback ----
  input  logic [15:0]                 i_c_raddr,
  output logic signed [31:0]          o_c_rdata,  // always 32-bit (normalized FP32 or INT32)

  // ---- Performance counters ----
  output logic [31:0]                 o_cycle_count,  // free-running cycles while busy
  output logic [31:0]                 o_op_count,     // total PE MAC operations
  output logic [31:0]                 o_stall_count,  // weight-movement cycles
  output logic [31:0]                 o_arow_stall_count, // cycles starved of A rows

  // ---- Activation stage, S_ACT (doc/npu_act_stage_design_note.md) ----
  // Core-level only: no DMA, CSR or firmware path yet.  Every scalar is
  // sampled when a start is accepted.  The arithmetic is c930_npu_act's.
  input  logic                        i_act_en,           // last K tile through S_ACT
  input  logic                        i_act_requant,      // this GEMM is an O-E-O reset
  input  logic [3:0]                  i_act_adc_bits,     // B_adc for requantisation, 1..15
  input  logic [32*NUM_COLS-1:0]      i_act_xs,           // per column: XSCALE * s_j
  input  logic [5:0]                  i_act_xshift,       // acc -> table domain
  input  logic [16*NUM_COLS-1:0]      i_act_r,            // per column: 1/s_j, Q4.12
  input  logic [5:0]                  i_act_yshift,       // table output -> C
  input  logic [15:0]                 i_act_k_shot,       // Q8.8; 0 disables noise
  input  logic                        i_act_noise_const,  // constant sigma (amplitude tables)
  input  logic [31:0]                 i_act_seed,         // xorshift32 seed, nonzero
  input  logic                        i_act_tbl_wen,      // breakpoint write, idle only
  input  logic [10:0]                 i_act_tbl_waddr,
  input  logic signed [23:0]          i_act_tbl_wdata,
  output logic [31:0]                 o_act_count,        // elements activated
  output logic [31:0]                 o_act_sat_count,    // saturation events
  output logic [31:0]                 o_act_cycles,       // cycles spent in S_ACT

  // ---- PTA error model, phase C1 (doc/pta_error_model_design_note.md) ----
  // Core-level only, like S_ACT's ports: sampled when a start is accepted and
  // modelled only when the core is built with PTM-C (PTM_C defined).  A start
  // is refused -- o_error, stay idle -- if it sets a bit this build cannot
  // model, sets any bit with FP16 or BF16, or sets any bit with a shift above 40.
  input  logic [6:0]                  i_pta_impair,       // QUANT THERMAL SHOT DRIFT XTALK MZM_NL PROG_ERR
  input  logic [3:0]                  i_pta_act_bits,     // B_a, 0 = unquantised
  input  logic [3:0]                  i_pta_w_bits,       // B_w, 0 = unquantised
  input  logic [3:0]                  i_pta_adc_bits,     // B_adc, 0 = no ADC quantisation
  input  logic [5:0]                  i_pta_adc_shift,    // S: LSB_adc = 2^S, 0..40
  input  logic [31:0]                 i_pta_seed,         // every generator, reloaded per GEMM
  input  logic [15:0]                 i_pta_sigma_th,     // thermal sigma, Q8.8 ADC LSB
  input  logic [15:0]                 i_pta_k_shot,       // shot coefficient k, Q8.8
  input  logic [15:0]                 i_pta_sigma_pr,     // programming-error sigma, Q8.8 weight LSB
  input  logic [15:0]                 i_pta_drift_sigma,  // drift step sigma, Q8.8 weight LSB
  input  logic [4:0]                  i_pta_drift_log2,   // log2 shots per drift step
  input  logic [15:0]                 i_pta_drift_max,    // drift clamp, Q8.8 weight LSB
  input  logic [7:0]                  i_pta_xtalk,        // crosstalk chi, Q0.8
  // Drift is device state: it persists across GEMMs, and this pulse, honoured
  // only while idle, returns it to zero and reloads its generator from i_pta_seed.
  input  logic                        i_pta_model_rst,
  output logic [31:0]                 o_pta_sat_count,    // ADC saturations, captured elements

  // ---- PTA calibration, phase C3(b) (rtl/pta/c930_pta_cal.sv) ----
  // Core-level like the rest of the PTA ports: the register block is C4's.
  // The engine runs only in a PTM-C build; elsewhere every output is tied off.
  input  logic                        i_pta_cal_en,       // PTA_CTRL.EN
  input  logic                        i_pta_cal_now,      // PTA_CTRL.CAL_NOW, a pulse
  input  logic [1:0]                  i_pta_cal_sched,    // PTA_CTRL.CAL_SCHED
  input  logic [31:0]                 i_pta_cal_per,      // PTA_CAL_PER, cycles
  input  logic [23:0]                 i_pta_cal_thr,      // PTA_CAL_THR, Q.8 weight LSB
  input  logic [3:0]                  i_pta_cal_amp,      // probe amplitude, 1 << this
  input  logic [3:0]                  i_pta_cal_reps,     // repeats a pass, 1 << this
  input  logic [1:0]                  i_pta_cal_passes,   // auto-ranging passes; 0 is 1
  // The emulation's settle: cycles held after a weight program's last write,
  // on top of the scan itself, so Tw = NUM_ROWS * NUM_COLS + i_pta_tw and a
  // GEMM's total is affine in it (pta_cpu_integration.md 6.2).  Zero is free.
  input  logic [31:0]                 i_pta_tw,
  // The emulation's shot latency, spent by the broadside tile (PTM_B).  The
  // floor is a hop, not a cycle: the tile captures on hop edges and this core
  // runs a half-rate hop, so section 6.2's Ts = 1 points are Ts = 2 here.
  input  logic [31:0]                 i_pta_ts,
  input  logic                        i_pta_cal_bank,     // the bank to calibrate
  input  logic [3:0]                  i_pta_trim_log2,    // the weight DAC's step, Q.8
  input  logic [15:0]                 i_pta_trim_max,     // ... and its clamp
  input  logic [31:0]                 i_pta_cal_seed,     // the calibration's noise seed
  // The affine is host-written: the error model has no per-column gain or
  // offset error, so there is nothing for the engine to estimate (grxcp
  // pta_chiplet_calibration.md section 8).
  input  logic                        i_pta_aff_wen,
  input  logic [$clog2(NUM_COLS)-1:0] i_pta_aff_col,
  input  logic signed [17:0]          i_pta_aff_gain,     // Q8.8, 256 is unity
  input  logic signed [31:0]          i_pta_aff_offs,
  input  logic                        i_pta_cal_rst,      // trims 0, affine identity
  // A host write of one cell's trim, for the parity gate and for a driver that
  // restores a saved calibration.  The engine's writes take precedence.
  input  logic                        i_pta_trim_wen,
  input  logic                        i_pta_trim_bank,
  input  logic [$clog2(NUM_ROWS)-1:0] i_pta_trim_row,
  input  logic [$clog2(NUM_COLS)-1:0] i_pta_trim_col,
  input  logic signed [31:0]          i_pta_trim_data,
  output logic                        o_pta_cal_busy,     // PTA_STATUS.CAL_BUSY
  output logic                        o_pta_cal_valid,    // PTA_STATUS.CAL_VALID
  output logic                        o_pta_drift_alarm,  // PTA_STATUS.DRIFT_ALARM
  output logic [31:0]                 o_pta_cal_ct,       // PTA_CAL_CT
  output logic [31:0]                 o_pta_cal_cyc,      // PTA_CAL_CYC
  output logic [23:0]                 o_pta_err_max,      // PTA_ERR_MAX
  output logic [23:0]                 o_pta_err_found,    // PTA_ERR_FOUND
  // The two counters PTA_SHOT_CT and PTA_WLOAD_CT read.  Both are cumulative,
  // as the chiplet's map has them, and not reset per GEMM: they exist so a
  // reported GEMM time can be decomposed, which needs a difference, and a
  // difference needs something that does not restart under you.
  output logic [31:0]                 o_pta_shot_ct,      // optical shots issued
  output logic [31:0]                 o_pta_wload_ct,     // weight-bank programmings
  // PTA_IRQ_STATUS.ERR: a probe the estimator could not read back, a START
  // that reached the core while CAL_BUSY was set (which the CSR's dispatch
  // guard is there to prevent), or a MODEL_RST during a calibration.
  output logic                        o_pta_cal_err
);

  // ---------------------------------------------------------------------------
  // Operand / result buffers (double-buffered for pipelined GEMM execution)
  // ---------------------------------------------------------------------------
  // bank 0 and bank 1: while the core computes with bank i_bank_sel,
  // the DMA loads the next GEMM's A/B into the other bank.
  // Icarus Verilog doesn't support 2D dynamic indexing, so we flatten.
  localparam int A_DEPTH = MAX_M * MAX_K;
  localparam int B_DEPTH = MAX_K * MAX_N;
  localparam int A_AW    = $clog2(A_DEPTH);
  localparam int B_AW    = $clog2(B_DEPTH);
  // ---------------------------------------------------------------------------
  // SUB-BANKING (synthesis inference fix, functional no-op):
  // The DMA's wide preload port writes up to WR_LANES(=8) elements per cycle
  // at consecutive addresses (i_wwaddr + l).  Expressing that directly -- 8
  // writes to one flat array in one process -- is un-inferable for Vivado
  // ("multiple writes via different ports in same process"), which used to
  // fall back to registers: a_mem/b_mem became flop arrays with giant
  // async-read mux trees (~130K LUTs, the 2026-09-14 192.9% overfit).
  // Fix: split each bank into WR_LANES sub-arrays by address[2:0].  The 8
  // wide-port lanes always have distinct addr[2:0] residues, so every
  // sub-array sees at most ONE write per cycle (narrow port OR its decoded
  // wide lane) and infers as LUTRAM.  Reads remap to (flat>>3) at sub[flat%8]
  // -- pure wiring, cycle behavior identical.
  // ---------------------------------------------------------------------------
  localparam int A_SUBS   = WR_LANES;
  localparam int B_SUBS   = WR_LANES;
  localparam int A_SD     = (A_DEPTH + A_SUBS - 1) / A_SUBS;
  localparam int B_SD     = (B_DEPTH + B_SUBS - 1) / B_SUBS;
  logic signed [DIN_W-1:0] a_bank0 [0:A_SUBS-1][0:A_SD-1];
  logic signed [DIN_W-1:0] a_bank1 [0:A_SUBS-1][0:A_SD-1];
  logic signed [DIN_W-1:0] b_bank0 [0:B_SUBS-1][0:B_SD-1];
  logic signed [DIN_W-1:0] b_bank1 [0:B_SUBS-1][0:B_SD-1];

  // C matrix: LUTRAM (distributed).  It used to be ram_style="block", but
  // BRAM reads are synchronous -- S_ACCLD's running-sum restore and the DMA's
  // C readback both sample c_mem combinationally, and a sync read would add a
  // cycle to each and desynchronize them.  Distributed RAM keeps every read
  // asynchronous at any depth; for MAX_M=8/MAX_N=12 (SoC defaults) it is only
  // 96 x 48 bit anyway.
  //
  // Widened from 32 to ACC_W bits.  Under the m-inner loop order the running
  // K accumulation lives here between K tiles rather than in acc[], and an
  // INT16 x INT16 reduction over MAX_K=256 needs 39 bits.  Truncation to 32
  // happens only on readback, exactly where it happened before.
  (* ram_style = "distributed" *) logic signed [ACC_W-1:0] c_mem [0:MAX_M*MAX_N-1];

  assign o_c_rdata = c_mem[i_c_raddr][31:0];

  // Preload A/B: write port always targets the INACTIVE bank (~i_bank_sel).
  // staging_wen has priority — fires during P_STAGING when the core is
  // idle.  i_wen fires during P_READ_A/P_READ_B and P_WRITE_C (via PF prefetch).
  // i_bank_sel: core reads from this bank during compute.
  // i_wbank: DMA writes to this bank (set by DMA per-phase:
  //   P_READ_A/B -> bank_sel, PF2 -> ~bank_sel).
  //   Staging writes always target the INACTIVE bank (~i_bank_sel) because
  //   the bank flip at end of P_STAGING makes ~bank_sel active for the next GEMM.
  wire write_a = i_staging_wen ? ~i_staging_wsel : (i_wen ? ~i_wsel : 1'b0);
  wire write_b = i_staging_wen ? i_staging_wsel : (i_wen ? i_wsel : 1'b0);
  wire [15:0] write_addr = i_staging_wen ? i_staging_waddr : i_waddr;
  wire signed [DIN_W-1:0] write_data = i_staging_wen ? i_staging_wdata : i_wdata;
  wire write_bank = i_staging_wen ? ~i_bank_sel : i_wbank;

  // One always_ff per sub-array: each sees at most one write per cycle, so
  // Vivado infers LUTRAM with asynchronous reads preserved (flat address f
  // lives at sub f%WR_LANES, row f/WR_LANES -- pure wiring on the read side).
  //
  // Wide-port decode (general, no driver-side alignment assumption): lane l
  // writes flat address i_wwaddr + l, which belongs to sub (i_wwaddr + l)%8.
  // Inverting per sub sb, the owning lane is l_own = (sb - i_wwaddr) mod 8.
  // l_own indexes i_wwmask/i_wwdata through plain muxes -- still a single
  // write port per sub-array process, which is all inference requires.
  //
  // A given sub-array is written by at most one of {narrow, wide} per cycle:
  // narrow fires only in P_STAGING/P_READ_A/B single-beat states, the wide
  // port only in the DMA's beat-accept cycle, and the two stream types never
  // drive the same cycle (same contract the old priority order relied on).
  localparam int AW_SUB = $clog2(A_SUBS);   // 3 for 8
  localparam int BW_SUB = $clog2(B_SUBS);

  for (genvar sb = 0; sb < A_SUBS; sb++) begin : g_amem
    // -- bank 0 --------------------------------------------------------------
    wire        a0_narrow = write_a && !write_bank
                            && (16'(write_addr) % 16'(A_SUBS)) == 16'(sb);
    wire [AW_SUB-1:0] a0_own  = AW_SUB'((16'(sb) - 16'(i_wwaddr)) % 16'(A_SUBS));
    wire        a0_wide   = i_wwen && !i_wwsel && !i_wwbank && i_wwmask[a0_own];
    wire [15:0] a0_addr   = a0_narrow ? write_addr
                                  : 16'(i_wwaddr) + 16'({ {(8-AW_SUB){1'b0}}, a0_own });
    wire signed [DIN_W-1:0] a0_data = a0_narrow ? write_data
                                                : i_wwdata[a0_own*DIN_W +: DIN_W];
    always_ff @(posedge i_clk) if (a0_narrow || a0_wide)
      a_bank0[sb][a0_addr / A_SUBS] <= a0_data;
    // -- bank 1 --------------------------------------------------------------
    wire        a1_narrow = write_a && write_bank
                            && (16'(write_addr) % 16'(A_SUBS)) == 16'(sb);
    wire [AW_SUB-1:0] a1_own  = AW_SUB'((16'(sb) - 16'(i_wwaddr)) % 16'(A_SUBS));
    wire        a1_wide   = i_wwen && !i_wwsel && i_wwbank && i_wwmask[a1_own];
    wire [15:0] a1_addr   = a1_narrow ? write_addr
                                  : 16'(i_wwaddr) + 16'({ {(8-AW_SUB){1'b0}}, a1_own });
    wire signed [DIN_W-1:0] a1_data = a1_narrow ? write_data
                                                : i_wwdata[a1_own*DIN_W +: DIN_W];
    always_ff @(posedge i_clk) if (a1_narrow || a1_wide)
      a_bank1[sb][a1_addr / A_SUBS] <= a1_data;
  end

  for (genvar sb = 0; sb < B_SUBS; sb++) begin : g_bmem
    // -- bank 0 --------------------------------------------------------------
    wire        b0_narrow = write_b && !write_bank
                            && (16'(write_addr) % 16'(B_SUBS)) == 16'(sb);
    wire [BW_SUB-1:0] b0_own  = BW_SUB'((16'(sb) - 16'(i_wwaddr)) % 16'(B_SUBS));
    wire        b0_wide   = i_wwen && i_wwsel && !i_wwbank && i_wwmask[b0_own];
    wire [15:0] b0_addr   = b0_narrow ? write_addr
                                  : 16'(i_wwaddr) + 16'({ {(8-BW_SUB){1'b0}}, b0_own });
    wire signed [DIN_W-1:0] b0_data = b0_narrow ? write_data
                                                : i_wwdata[b0_own*DIN_W +: DIN_W];
    always_ff @(posedge i_clk) if (b0_narrow || b0_wide)
      b_bank0[sb][b0_addr / B_SUBS] <= b0_data;
    // -- bank 1 --------------------------------------------------------------
    wire        b1_narrow = write_b && write_bank
                            && (16'(write_addr) % 16'(B_SUBS)) == 16'(sb);
    wire [BW_SUB-1:0] b1_own  = BW_SUB'((16'(sb) - 16'(i_wwaddr)) % 16'(B_SUBS));
    wire        b1_wide   = i_wwen && i_wwsel && i_wwbank && i_wwmask[b1_own];
    wire [15:0] b1_addr   = b1_narrow ? write_addr
                                  : 16'(i_wwaddr) + 16'({ {(8-BW_SUB){1'b0}}, b1_own });
    wire signed [DIN_W-1:0] b1_data = b1_narrow ? write_data
                                                : i_wwdata[b1_own*DIN_W +: DIN_W];
    always_ff @(posedge i_clk) if (b1_narrow || b1_wide)
      b_bank1[sb][b1_addr / B_SUBS] <= b1_data;
  end

  // Flat read-only mirrors of the sub-banked operand memories, for testbench
  // backdoor access (tb_big.sv / tb_npu_float_prec.sv read a_mem_0[...] and
  // friends by hierarchical name, with a variable index).  The gathers use
  // only constant indices, and nothing in the RTL loads them, so synthesis
  // prunes them entirely.
  logic signed [DIN_W-1:0] a_mem_0 [0:A_DEPTH-1];
  logic signed [DIN_W-1:0] a_mem_1 [0:A_DEPTH-1];
  logic signed [DIN_W-1:0] b_mem_0 [0:B_DEPTH-1];
  logic signed [DIN_W-1:0] b_mem_1 [0:B_DEPTH-1];
  always_comb begin
    for (int f = 0; f < A_DEPTH; f++) begin
      a_mem_0[f] = a_bank0[f % A_SUBS][f / A_SUBS];
      a_mem_1[f] = a_bank1[f % A_SUBS][f / A_SUBS];
    end
    for (int f = 0; f < B_DEPTH; f++) begin
      b_mem_0[f] = b_bank0[f % B_SUBS][f / B_SUBS];
      b_mem_1[f] = b_bank1[f % B_SUBS][f / B_SUBS];
    end
  end

  // ---------------------------------------------------------------------------
  // Control FSM state and counters
  // ---------------------------------------------------------------------------
  // localparam state encoding (avoids iverilog's enum-label-in-port quirk)
  localparam logic [2:0] S_IDLE    = 3'd0;
  localparam logic [2:0] S_WLOAD   = 3'd1;
  localparam logic [2:0] S_ACCLD   = 3'd2;  // reload acc[] from C for K tiles > 0
  localparam logic [2:0] S_RUN     = 3'd3;
  localparam logic [2:0] S_WRITE   = 3'd4;
  localparam logic [2:0] S_AROW    = 3'd5;  // wait for the next A row to land
  localparam logic [2:0] S_ACT     = 3'd6;  // activate the last K tile's sums into C
  localparam logic [2:0] S_CAL     = 3'd7;  // the tile is the calibration engine's
  localparam int         ACT_P     = 8;     // c930_npu_act's latency, element to write
                                            // (7 since the stage-2 split: root/draw
                                            // and the k_shot multiply are separate
                                            // cycles, see c930_npu_act.sv)
  logic [2:0] state;

  // ---- The calibration engine's side of the tile (C3(b)) ----
  // Declared for both builds; in a digital-array build nothing drives them and
  // every mux below collapses.
  logic                             cal_busy;      // the engine owns the tile
  logic                             cal_req;       // ... and would like to
  logic                             cal_done;
  logic                             cal_wen;       // its weight zeroing
  logic [$clog2(NUM_ROWS)-1:0]      cal_wrow;
  logic [$clog2(NUM_COLS)-1:0]      cal_wcol;
  logic signed [NUM_ROWS*DIN_W-1:0] cal_act;       // its one-hot stimulus
  logic                             cal_shot_start;
  logic                             cal_shot;
  logic [$clog2(NUM_COLS)-1:0]      cal_shot_col;
  logic                             cal_bank;
  // Set while the calibration interrupted a GEMM: the weights it zeroed have
  // to be reloaded before the GEMM can go on, and o_busy stays high because
  // the GEMM really is still in flight.
  logic                             cal_resume;
  logic [2:0]                       cal_resume_st;
  logic                             cal_abort_pend;
  logic                             cal_err_q;
  logic                             cal_eng_err;
  // The shot strobe the tile sees, whoever is driving it.  Zero in a build with
  // no modelled tile, where there are no shots to count.
  logic                             tile_shot_start;

  int m_reg;        // current output row
  int m_base;       // pre-computed m_reg * i_dim_k (breaks multiply from critical path)
  int nt_reg;       // current N tile
  int kt_reg;       // current K tile
  int t;            // cycle counter within a systolic run
  int w_r, w_n;     // weight-load row/col counters
  int n_cnt;        // result write counter
  int act_t;        // cycle within S_ACT: elements enter at 0 .. nc-1
  logic act_en_r;   // i_act_en, sampled at start

  // Weight bank.  With the m-inner loop order a B tile is loaded once and then
  // used for every output row, so the K-tile double-buffer that the m-outer
  // order needed is gone: one bank is loaded and computed with for the whole
  // (N tile, K tile) pass.  The array's second bank is left unused here; the
  // DMA still uses i_bank_sel for its own A/B double-buffering across GEMMs.
  logic        bank_sel;           // which weight bank is active for compute

  // Snapshot of i_bank_sel captured at GEMM start.  Used for all B memory
  // reads (weight loading) so the read bank is stable even if
  // the DMA's bank_sel toggles mid-GEMM (e.g. bank_sel_pending from a
  // earlier P_STAGING).  Also decouples the B read path from the live
  // i_bank_sel, eliminating a potential combinational timing hazard
  // through the b_mem mux into the PE datapath.
  logic        b_bank_sel;

  logic signed [ACC_W-1:0] acc [0:NUM_COLS-1];   // running accumulator per column

  // Combinational helpers
  int  n_base;          // nt_reg * NUM_COLS
  int  nc;              // columns actually used in the current N tile
  int  num_k_tiles;     // ceil(K / NUM_ROWS)
  int  num_n_tiles;     // ceil(N / NUM_COLS)
  logic dims_ok;

  assign n_base      = nt_reg * NUM_COLS;
  assign nc          = (i_dim_n - n_base >= NUM_COLS) ? NUM_COLS : (i_dim_n - n_base);

  // C element addressed by S_ACCLD (read) and S_WRITE (write).  The two states
  // are mutually exclusive, so c_mem keeps one read port and one write port
  // and still infers as a simple dual-port BRAM alongside the DMA's readback.
  localparam int C_AW = $clog2(MAX_M * MAX_N);
  wire [C_AW-1:0] c_idx = C_AW'(m_reg * i_dim_n + n_base + n_cnt);
  assign num_k_tiles = (i_dim_k + NUM_ROWS - 1) / NUM_ROWS;
  assign num_n_tiles = (i_dim_n + NUM_COLS - 1) / NUM_COLS;
  assign dims_ok     = (i_dim_m >= 1) && (i_dim_m <= MAX_M) &&
                       (i_dim_n >= 1) && (i_dim_n <= MAX_N)  &&
                       (i_dim_k >= 1) && (i_dim_k <= MAX_K);

  // A calibration between GEMMs is not a command, so it does not report BUSY:
  // PTA_STATUS.CAL_BUSY is where it shows, and the CSR's dispatch guard is
  // what keeps a START out of it (grxcp pta_cpu_integration.md section 3.2).
  // One that interrupted a GEMM does report BUSY, because that GEMM has not
  // finished.
  assign o_busy = (state != S_IDLE) && !((state == S_CAL) && !cal_resume);

  // PTA impairments this build can model (doc/pta_error_model_design_note.md
  // section 2): the digital array models none, so asking it for any would
  // silently return exact results under an analog label.
`ifdef PTM_C
  localparam logic [6:0] PTA_BUILT = 7'b101_1111;   // all but MZM_NL
`else
  localparam logic [6:0] PTA_BUILT = 7'b000_0000;
`endif
  wire pta_any = (i_pta_impair != 7'd0);
  wire pta_bad = pta_any &&
                 (((i_pta_impair & ~PTA_BUILT) != 7'd0) ||
                  (i_precision == 3'd2) || (i_precision == 3'd3) ||
                  (i_pta_adc_shift > 6'd40));

  // S_ACT refuses the float modes too (see the activation stage below).
  wire act_fp   = i_act_en && (i_precision == 3'd2 || i_precision == 3'd3);

  // The cycle a start is accepted: S_ACT and the tile sample their
  // configuration here.
  wire start_ok = (state == S_IDLE) && i_start && dims_ok && !act_fp && !pta_bad;

  // ---------------------------------------------------------------------------
  // o_done: separated from FSM always_ff to break t[25] critical path.
  // yosys shares FSM state-decode logic between state_next (which uses t)
  // and o_done_next in the same always_ff block, creating a t[25] -> o_done
  // chain.  Computing o_done from a dedicated combinational cone that depends
  // only on registered state/counters (not t) breaks this path.
  // ---------------------------------------------------------------------------
  logic done_cond;
  // With S_ACT enabled the last K tile ends in S_ACT rather than S_WRITE, so
  // the last write of a GEMM is S_ACT's.
  wire  last_row_tile = (m_reg  == i_dim_m - 1) &&
                        (kt_reg == num_k_tiles - 1) &&
                        (nt_reg == num_n_tiles - 1);
  assign done_cond = last_row_tile &&
                     (((state == S_WRITE) && (n_cnt == nc - 1)) ||
                      ((state == S_ACT)   && (act_t == nc + ACT_P - 1)));

  // End of a row's store, in whichever state stored it (see the advance block
  // after the FSM case).
  wire row_done = ((state == S_WRITE) && (n_cnt == nc - 1)) ||
                  ((state == S_ACT)   && (act_t == nc + ACT_P - 1));

  // ---------------------------------------------------------------------------
  // Performance counters
  // ---------------------------------------------------------------------------
  // See the i_a_rows_ready port comment: 0 disables the interlock entirely.
  wire arow_free = (i_a_rows_ready == 16'd0);

  logic [31:0] cycle_cnt, op_cnt, stall_cnt, arow_stall_cnt, act_cycle_cnt;
  logic [31:0] shot_cnt, wload_cnt;
  assign o_pta_shot_ct  = shot_cnt;
  assign o_pta_wload_ct = wload_cnt;
  assign o_cycle_count      = cycle_cnt;
  assign o_op_count         = op_cnt;
  assign o_stall_count      = stall_cnt;
  assign o_arow_stall_count = arow_stall_cnt;
  assign o_act_cycles       = act_cycle_cnt;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      cycle_cnt      <= 32'd0;
      op_cnt         <= 32'd0;
      stall_cnt      <= 32'd0;
      arow_stall_cnt <= 32'd0;
      act_cycle_cnt  <= 32'd0;
    end else begin
      if (state != S_IDLE && state != S_CAL)
        cycle_cnt <= cycle_cnt + 1;
      if (state == S_IDLE && i_start) begin
        cycle_cnt      <= 32'd0;
        op_cnt         <= 32'd0;
        stall_cnt      <= 32'd0;
        arow_stall_cnt <= 32'd0;
        act_cycle_cnt  <= 32'd0;
      end
      // S_ACT is its own term in CYCLE_COUNT's decomposition: without it the
      // identity in doc/c930_architecture.md cannot close once S_ACT runs.
      if (state == S_ACT)
        act_cycle_cnt <= act_cycle_cnt + 1;
      // Count PE MAC operations: all PEs fire each cycle during S_RUN.
      // NUM_ROWS * NUM_COLS = 64 PEs, each doing one MAC per cycle.
      if (state == S_RUN)
        op_cnt <= op_cnt + NUM_ROWS * NUM_COLS;
      // Count weight-movement cycles.  Under the m-inner loop order every K
      // tile is loaded exactly once, in S_WLOAD, so S_WLOAD alone is the whole
      // figure again -- the S_PRELOAD term the m-outer order needed is gone
      // with the state.  Also count S_ACCLD: reloading acc[] from C is
      // accumulator traffic, not compute, and hiding it would overstate the
      // array's utilisation the same way undercounting weights did.
      // The settle is inside S_WLOAD and counted here with the scan: it is the
      // cost of delivering weights, and counting it keeps the accounting
      // identity in doc/c930_architecture.md closing as CYCLE_COUNT grows.
      if (state == S_WLOAD || state == S_ACCLD)
        stall_cnt <= stall_cnt + 1;
      // Kept separate from stall_cnt so the accounting identity in
      // doc/c930_architecture.md still decomposes: weight movement and
      // operand starvation are different problems with different fixes.
      if (state == S_AROW)
        arow_stall_cnt <= arow_stall_cnt + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Where the tile can be handed to the calibration engine (C3(b))
  // ---------------------------------------------------------------------------
  // Idle is between GEMMs.  A starved S_AROW is the memory shadow of grxcp
  // pta_cpu_integration.md section 5.1 -- a row the DMA has not landed yet, so
  // the tile is waiting anyway.  A row advance is a boundary where nothing is
  // in flight but nothing is waiting either, which is what makes the periodic
  // scheduler pay for itself and the shadow one not: the shadow withdraws its
  // request outside a window, and a row advance is not one.
  wire arow_wait      = (state == S_AROW) && !(arow_free || m_reg < i_a_rows_ready);
  wire cal_take_idle  = cal_req && (state == S_IDLE) && !i_start;
  wire cal_take_arow  = cal_req && arow_wait;
  wire cal_take_row   = cal_req && row_done && (m_reg != i_dim_m - 1);
  wire cal_grant      = cal_take_idle || cal_take_arow || cal_take_row;
  wire cal_shadow_now = (state == S_IDLE) || arow_wait;

  // Registered K-tile helpers: k_base and kr are computed at the START of each
  // K tile (end of the previous tile) and held stable for the whole S_WLOAD +
  // S_RUN sequence.  This breaks the 32-bit subtraction carry chain
  // (i_dim_k - k_base) off the critical path to the PE datapath.
  int  k_base_reg;      // kt_reg * NUM_ROWS, registered
  int  kr_reg;          // min(NUM_ROWS, i_dim_k - k_base), registered

  // NOTE: FP16/BF16 accumulator must remain purely combinational.
  // A pipeline register inside the accumulator breaks the systolic
  // partial-sum cascade (NB assignment timing issue).

  // ---------------------------------------------------------------------------
  // Systolic-array feed (registered): skew generation
  // ---------------------------------------------------------------------------
  // HALF-RATE HOP: the PE stream registers update on gated edges (every 2nd
  // cycle, see c930_tensor_pe `hop`).  The FSM replicates that phase exactly
  // (same free-running toggle from reset) and runs the S_RUN schedule on hop
  // edges only: all t== conditions, seed windows and capture offsets keep
  // their old semantics, with t now counting hops instead of cycles.  S_RUN
  // therefore takes 2*(NUM_ROWS+NUM_COLS+2) cycles wall-clock; every other
  // state (weight load, preload, DMA) still runs at full rate.
  // The act/ps_in outputs are registered to break the t[] -> state-decode ->
  // PE FP16-accumulator critical path.  Without registration yosys merges
  // the t==n comparison with the accumulator's combinational cone, creating a
  // ~26 ns path from t[23] through the exp_b subtraction / mantissa add.
  //
  // Registration adds 1 cycle of latency; S_RUN runs for
  // NUM_ROWS + NUM_COLS + 2 cycles (vs +1 before) to compensate, and the
  // staggered capture shifts by 1.
  // ---------------------------------------------------------------------------
  logic signed [NUM_ROWS*DIN_W-1:0] act_comb;    // combinational
  int a_act_flat;   // flat a_mem address for the act read (sub-banked, see above)
  logic signed [NUM_COLS*ACC_W-1:0] ps_in_comb;  // combinational
  logic signed [NUM_ROWS*DIN_W-1:0] act;          // registered -> PE
  logic signed [NUM_COLS*ACC_W-1:0] ps_in;        // registered -> PE

  // Hop-phase replica of the PEs' stream-update phase (toggle every cycle
  // from reset => identical to the PEs' `hop`).  S_RUN advances on edges
  // where the old value is 1 -- the same edges on which PE stream registers
  // load, so seeds presented in one hop window are captured at the next.
  logic hop_phase;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      hop_phase <= 1'b0;
    else
      hop_phase <= ~hop_phase;
  end

`ifdef PTM_B
  // The broadside shot is asked for once, on the cycle S_RUN is entered.
  logic [2:0] state_q;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) state_q <= S_IDLE;
    else          state_q <= state;
  end
  wire bs_shot_req = (state == S_RUN) && (state_q != S_RUN);
  logic bs_valid;                       // the tile's o_valid
`endif

  always_comb begin
    act_comb   = '0;
    ps_in_comb = '0;

    if (cal_busy) begin
      // The probe's stimulus goes through the same hop-gated registers the
      // core's own feed uses, so the tile cannot tell the two apart.  Its
      // seeds are zero: a probe accumulates nothing.
      act_comb = cal_act;
    end else if (state == S_RUN) begin
`ifdef PTM_B
      // Broadside: the whole K-tile vector and every column's seed, held for the
      // shot.  There is no skew to emulate, which is the tile's point.
      for (int r = 0; r < NUM_ROWS; r++) begin
        if (r < kr_reg) begin
          a_act_flat = m_base + k_base_reg + r;
          act_comb[r*DIN_W +: DIN_W] = i_bank_sel
            ? a_bank1[a_act_flat % A_SUBS][a_act_flat / A_SUBS]
            : a_bank0[a_act_flat % A_SUBS][a_act_flat / A_SUBS];
        end
      end
      for (int n = 0; n < NUM_COLS; n++)
        ps_in_comb[n*ACC_W +: ACC_W] = acc[n];
`else
      // Row r's activation A[m][k_base_reg + r] pulses at cycle r (skew by r).
      for (int r = 0; r < NUM_ROWS; r++) begin
        if ((t == 2*r) && (r < kr_reg)) begin
          a_act_flat = m_base + k_base_reg + r;
          act_comb[r*DIN_W +: DIN_W] = i_bank_sel
            ? a_bank1[a_act_flat % A_SUBS][a_act_flat / A_SUBS]
            : a_bank0[a_act_flat % A_SUBS][a_act_flat / A_SUBS];
        end
      end
      // Column n's running accumulator pulses at cycles n and n+1 (skew by n).
      for (int n = 0; n < NUM_COLS; n++) begin
        // HALF-RATE HOP: single-window seed.  The pipelined accumulator pairs
        // i_ps_in and the product from the SAME hop window (both stable across
        // the window), so unlike the old 2-cycle pulse the seed must span
        // exactly one window: a second window would re-enter the cascade and
        // regress the running sum (f(S, 0) = S overwrites the accumulation).
        // Skewed at 2n: the ps stream travels 2 windows per column (the
        // accumulator's stage-1 register + the PE's stream register), so
        // column n's seed must enter 2 windows after column n-1's.
        if (t == 2*n)
          ps_in_comb[n*ACC_W +: ACC_W] = acc[n];
      end
`endif
    end
  end

  // Register act/ps_in to break the t[] -> PE critical path.
  // Hop-gated (HALF-RATE HOP): loading only at the same edges on which the
  // PEs' hop-gated registers sample guarantees each row's activation and each
  // column's seed are held stable across a FULL hop window.  A combinational
  // 1-cycle pulse would fall between the PEs' sample points: their free-running
  // product registers would still catch row 0, but the hop-gated a_r1 stage --
  // which carries the activation to columns 1..7 -- would miss it entirely
  // (observed: column 0 correct, columns 1+ = 0).
  //   act[r]  : comb pulses during window 2r    -> visible during window 2r+1
  //   ps_in[n]: comb pulses during window 2n    -> visible during window 2n+1
  // which is exactly when PE[0][n] multiplies A[0] (window 1+2n), so every
  // PE[r][n] meets A[r] and column n's partial at window 2r+1+2n.
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      act   <= '0;
      ps_in <= '0;
    end else if (hop_phase) begin
      act   <= act_comb;
      ps_in <= ps_in_comb;
    end
  end

  // ---------------------------------------------------------------------------
  // Systolic array
  // ---------------------------------------------------------------------------
  logic signed [ACC_W*NUM_COLS-1:0] ps_out;   // flat; col c = bits [c*ACC_W +: ACC_W]

  // Weight load: S_WLOAD drives the array's write port directly.  The
  // preload path the m-outer order needed is gone with S_PRELOAD.
  logic        w_load_active;
  // Cycles held in S_WLOAD after the last weight write, counting the settle.
  //
  // Rounded up to the hop cadence, which is why it is even.  hop_phase is a
  // free-running toggle and S_RUN advances only on its edges, so a settle of an
  // odd number of cycles leaves the next state entered on the other phase and
  // costs it a cycle -- the total then carries an alignment term of up to one
  // cycle per weight program instead of being affine in the register.  An even
  // settle preserves the phase, so a GEMM pays exactly Nt * Kt * PTA_TW.  Every
  // point in pta_cpu_integration.md 6.2 is even (100,000, 1,000, 0); an odd
  // value costs one cycle more than it asks for, per program.
  logic [31:0] settle_cnt;
  wire [31:0]  tw_eff = i_pta_tw + {31'd0, i_pta_tw[0]};
  wire         scan_done = (w_n == nc - 1) && (w_r == kr_reg - 1);
  wire         settling  = (state == S_WLOAD) && scan_done && (settle_cnt != 32'd0);
  logic        w_load_bank;
  logic [$clog2(NUM_ROWS)-1:0] w_load_row;
  logic [$clog2(NUM_COLS)-1:0] w_load_col;
  logic signed [DIN_W-1:0]     w_load_data;

  // The calibration zeroes the bank through this same port, which is what
  // redraws each cell's programming error (rtl/pta/c930_pta_cal.sv).
  // Not while settling: a weight write steps the PROG_ERR stream, so holding the
  // port open would redraw the last cell's error once per settle cycle.
  assign w_load_active = ((state == S_WLOAD) && !settling) || cal_wen;
  assign w_load_bank   = cal_wen ? cal_bank : bank_sel;
  assign w_load_row    = cal_wen ? cal_wrow : w_r[$clog2(NUM_ROWS)-1:0];
  assign w_load_col    = cal_wen ? cal_wcol : w_n[$clog2(NUM_COLS)-1:0];
  // Double-buffered B read: select bank via b_bank_sel (snapshot of
  // i_bank_sel captured at GEMM start, see comment above).
  logic signed [DIN_W-1:0] b_read_data;
  wire [15:0] b_read_addr = (k_base_reg + w_r)*i_dim_n + n_base + w_n;
  wire [B_AW-1:0] b_flat = B_AW'(b_read_addr);
  assign b_read_data = b_bank_sel ? b_bank1[b_flat % B_SUBS][b_flat / B_SUBS] :
                                    b_bank0[b_flat % B_SUBS][b_flat / B_SUBS];
  assign w_load_data = cal_wen ? '0 : b_read_data;

  // Rows of the array that belong to the current K tile.  The rest hold stale
  // weights, which the float modes must not multiply (c930_tensor_pe).
  // Every row of the tile is in the probe's K tile, so crosstalk couples
  // across all of them, as it does in a full GEMM tile.
  logic [NUM_ROWS-1:0] row_en;
  always_comb
    for (int r = 0; r < NUM_ROWS; r++) row_en[r] = cal_busy || (r < kr_reg);

`ifdef PTM_C
  // PTM-C in place of the array (grxcp pta_cpu_integration.md section 4.1),
  // with the error model of doc/pta_error_model_design_note.md.  The tile
  // draws only for results the core captures: column n is captured on the hop
  // edge that ends t = 2*NUM_ROWS + 1 + 2n (see S_RUN), from the shot the tile
  // registered one hop edge earlier, so the window with t = 2*NUM_ROWS + 2n
  // names column n.  Columns at or past nc are never written to C and draw
  // nothing.  A shot -- one run of one output row over one K tile -- starts in
  // the window with t = 0, which is where the drift clock counts it.
`ifdef PTM_C_ABLATE_ROW
  localparam int PTM_ABLATE_ROW = `PTM_C_ABLATE_ROW;
`else
  localparam int PTM_ABLATE_ROW = -1;
`endif
  localparam int PTA_CW = $clog2(NUM_COLS);

  // The engine's side of the tile, declared before the instance that reads it:
  // a net used before its declaration is a one-bit implicit wire under iverilog,
  // which would make cal_trim_data one bit of a thirty-two bit trim.
  localparam int PTA_TRIM_W = 32;
  logic                             cal_trim_wen, cal_trim_bank, cal_trim_clamped;
  logic [$clog2(NUM_ROWS)-1:0]      cal_trim_row;
  logic [$clog2(NUM_COLS)-1:0]      cal_trim_col;
  logic signed [PTA_TRIM_W-1:0]     cal_trim_data, cal_trim_rdata;
  logic                             cal_shift_en;
  logic [5:0]                       cal_shift;
  logic                             cal_load;
  logic [31:0]                      cal_seed;
  wire              pta_shot     = (state == S_RUN) && (t >= 2*NUM_ROWS) && !t[0] &&
                                   (((t - 2*NUM_ROWS) >>> 1) < nc);
  wire [PTA_CW-1:0] pta_shot_col = PTA_CW'((t - 2*NUM_ROWS) >>> 1);
  wire              pta_shot_start = (state == S_RUN) && (t == 0);
  assign tile_shot_start = cal_busy ? cal_shot_start : pta_shot_start;

`ifdef PTM_B
  // PTM-B (pta_cpu_integration.md 4.2): the same arithmetic with BROADSIDE = 1
  // inside it, and a shot-and-wait schedule around it.  The whole K-tile vector
  // goes in at once and every column comes back together, so the core's run is
  // a shot and a wait instead of a skewed drain.
  c930_ptm_b #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (DIN_W),
    .ACC_W    (ACC_W),
    .TRIM_W   (24)
  ) u_tile_b (
    .i_clk           (i_clk),
    .i_rst_n         (i_rst_n),
    .i_wen           (w_load_active),
    .i_wbank         (w_load_bank),
    .i_wrow          (w_load_row),
    .i_wcol          (w_load_col),
    .i_wdata         (w_load_data),
    .i_bank_sel      (cal_busy ? cal_bank : bank_sel),
    .i_act           (act),
    .i_ps_in         (ps_in),
    .i_row_en        (row_en),
    .i_precision     (i_precision),
    .i_shot_start    (bs_shot_req),
    .i_ts            (i_pta_ts),
    .o_valid         (bs_valid),
    .o_ps_out        (ps_out),
    .i_pta_cfg_load  (start_ok),
    .i_pta_impair    (i_pta_impair),
    .i_pta_act_bits  (i_pta_act_bits),
    .i_pta_w_bits    (i_pta_w_bits),
    .i_pta_adc_bits  (i_pta_adc_bits),
    .i_pta_adc_shift (i_pta_adc_shift),
    .i_pta_seed      (i_pta_seed),
    .i_pta_sigma_th  (i_pta_sigma_th),
    .i_pta_k_shot    (i_pta_k_shot),
    .i_pta_sigma_pr  (i_pta_sigma_pr),
    .i_pta_drift_sigma (i_pta_drift_sigma),
    .i_pta_drift_log2  (i_pta_drift_log2),
    .i_pta_drift_max   (i_pta_drift_max),
    .i_pta_xtalk       (i_pta_xtalk),
    .i_pta_model_rst   (i_pta_model_rst && (state == S_IDLE)),
    .o_pta_sat_count (o_pta_sat_count),
    .i_pta_trim_wen     (cal_trim_wen || i_pta_trim_wen),
    .i_pta_trim_bank    (cal_trim_wen ? cal_trim_bank : i_pta_trim_bank),
    .i_pta_trim_row     (cal_trim_wen ? cal_trim_row  : i_pta_trim_row),
    .i_pta_trim_col     (cal_trim_wen ? cal_trim_col  : i_pta_trim_col),
    .i_pta_trim_data    (cal_trim_wen ? cal_trim_data : i_pta_trim_data),
    .i_pta_trim_log2    (i_pta_trim_log2),
    .i_pta_trim_max     (i_pta_trim_max),
    .o_pta_trim_rdata   (cal_trim_rdata),
    .o_pta_trim_clamped (cal_trim_clamped),
    .i_pta_cal_wen      (i_pta_aff_wen),
    .i_pta_cal_col      (i_pta_aff_col),
    .i_pta_cal_gain     (i_pta_aff_gain),
    .i_pta_cal_offs     (i_pta_aff_offs),
    .i_pta_cal_rst      (i_pta_cal_rst),
    .i_pta_cal_shift_en (cal_shift_en),
    .i_pta_cal_shift    (cal_shift),
    .i_pta_cal_load     (cal_load),
    .i_pta_cal_seed     (cal_seed)
  );
`else
  c930_ptm_c #(
    .NUM_ROWS   (NUM_ROWS),
    .NUM_COLS   (NUM_COLS),
    .DIN_W      (DIN_W),
    .ACC_W      (ACC_W),
    .ABLATE_ROW (PTM_ABLATE_ROW)
  ) u_array (
    .i_clk           (i_clk),
    .i_rst_n         (i_rst_n),
    .i_wen           (w_load_active),
    .i_wbank         (w_load_bank),
    .i_wrow          (w_load_row),
    .i_wcol          (w_load_col),
    .i_wdata         (w_load_data),
    .i_bank_sel      (cal_busy ? cal_bank : bank_sel),
    .i_act           (act),
    .i_ps_in         (ps_in),
    .o_ps_out        (ps_out),
    .i_precision     (i_precision),
    .i_row_en        (row_en),
    .i_pta_cfg_load  (start_ok),
    .i_pta_impair    (i_pta_impair),
    .i_pta_act_bits  (i_pta_act_bits),
    .i_pta_w_bits    (i_pta_w_bits),
    .i_pta_adc_bits  (i_pta_adc_bits),
    .i_pta_adc_shift (i_pta_adc_shift),
    .i_pta_seed      (i_pta_seed),
    .i_pta_sigma_th  (i_pta_sigma_th),
    .i_pta_k_shot    (i_pta_k_shot),
    .i_pta_sigma_pr  (i_pta_sigma_pr),
    .i_pta_drift_sigma (i_pta_drift_sigma),
    .i_pta_drift_log2  (i_pta_drift_log2),
    .i_pta_drift_max   (i_pta_drift_max),
    .i_pta_xtalk       (i_pta_xtalk),
    .i_pta_model_rst   (i_pta_model_rst && (state == S_IDLE)),
    .i_pta_shot_start  (tile_shot_start),
    .i_pta_shot      (cal_busy ? cal_shot     : pta_shot),
    .i_pta_shot_col  (cal_busy ? cal_shot_col : pta_shot_col),
    .o_pta_sat_count (o_pta_sat_count),
    .i_pta_trim_wen     (cal_trim_wen || i_pta_trim_wen),
    .i_pta_trim_bank    (cal_trim_wen ? cal_trim_bank : i_pta_trim_bank),
    .i_pta_trim_row     (cal_trim_wen ? cal_trim_row  : i_pta_trim_row),
    .i_pta_trim_col     (cal_trim_wen ? cal_trim_col  : i_pta_trim_col),
    .i_pta_trim_data    (cal_trim_wen ? cal_trim_data : i_pta_trim_data),
    .i_pta_trim_log2    (i_pta_trim_log2),
    .i_pta_trim_max     (i_pta_trim_max),
    .o_pta_trim_rdata   (cal_trim_rdata),
    .o_pta_trim_clamped (cal_trim_clamped),
    .i_pta_cal_wen      (i_pta_aff_wen),
    .i_pta_cal_col      (i_pta_aff_col),
    .i_pta_cal_gain     (i_pta_aff_gain),
    .i_pta_cal_offs     (i_pta_aff_offs),
    .i_pta_cal_rst      (i_pta_cal_rst),
    .i_pta_cal_shift_en (cal_shift_en),
    .i_pta_cal_shift    (cal_shift),
    .i_pta_cal_load     (cal_load),
    .i_pta_cal_seed     (cal_seed)
  );

  // The engine.  It owns the probe, the estimator and the schedulers; the core
  // owns only the grant and putting the weights back afterwards.
  c930_pta_cal #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (DIN_W),
    .ACC_W    (ACC_W),
    .TRIM_W   (PTA_TRIM_W)
  ) u_cal (
    .i_clk          (i_clk),
    .i_rst_n        (i_rst_n),
    .i_en           (i_pta_cal_en),
    .i_cal_now      (i_pta_cal_now),
    .i_sched        (i_pta_cal_sched),
    .i_cal_per      (i_pta_cal_per),
    .i_cal_thr      (i_pta_cal_thr),
    .i_amp_log2     (i_pta_cal_amp),
    .i_reps_log2    (i_pta_cal_reps),
    .i_passes       (i_pta_cal_passes),
    .i_act_bits     (i_pta_act_bits),
    .i_adc_bits     (i_pta_adc_bits),
    .i_quant        (i_pta_impair[0]),
    .i_trim_max     (i_pta_trim_max),
    .i_bank         (i_pta_cal_bank),
    .i_shadow       (cal_shadow_now),
    .o_req          (cal_req),
    .i_grant        (cal_grant),
    .o_busy         (cal_busy),
    .o_done         (cal_done),
    .i_hop          (hop_phase),
    .o_wen          (cal_wen),
    .o_wrow         (cal_wrow),
    .o_wcol         (cal_wcol),
    .o_act          (cal_act),
    .o_shot_start   (cal_shot_start),
    .o_shot         (cal_shot),
    .o_shot_col     (cal_shot_col),
    .o_shift_en     (cal_shift_en),
    .o_shift        (cal_shift),
    .o_load         (cal_load),
    .o_seed         (cal_seed),
    .i_cal_seed     (i_pta_cal_seed),
    .i_cal_rst      (i_pta_cal_rst),
    .i_ps_out       (ps_out),
    .o_trim_wen     (cal_trim_wen),
    .o_trim_bank    (cal_trim_bank),
    .o_trim_row     (cal_trim_row),
    .o_trim_col     (cal_trim_col),
    .o_trim_data    (cal_trim_data),
    .i_trim_rdata   (cal_trim_rdata),
    .i_trim_clamped (cal_trim_clamped),
    .o_cal_ct       (o_pta_cal_ct),
    .o_cal_cyc      (o_pta_cal_cyc),
    .o_err_max      (o_pta_err_max),
    .o_err_found    (o_pta_err_found),
    .o_cal_valid    (o_pta_cal_valid),
    .o_drift_alarm  (o_pta_drift_alarm),
    .o_err          (cal_eng_err)
  );

`endif

  assign cal_bank       = i_pta_cal_bank;
  assign o_pta_cal_busy = cal_busy;
  assign o_pta_cal_err  = cal_eng_err || cal_err_q;
`else
  c930_systolic_array #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (DIN_W),
    .ACC_W    (ACC_W)
  ) u_array (
    .i_clk      (i_clk),
    .i_rst_n    (i_rst_n),
    .i_wen      (w_load_active),
    .i_wbank    (w_load_bank),
    .i_wrow     (w_load_row),
    .i_wcol     (w_load_col),
    .i_wdata    (w_load_data),
    .i_bank_sel (bank_sel),
    .i_act      (act),
    .i_ps_in    (ps_in),
    .o_ps_out   (ps_out),
    .i_precision(i_precision),
    .i_row_en   (row_en)
  );

  assign o_pta_sat_count = 32'd0;

  // No modelled tile, so no calibration: the engine's whole interface is off.
  assign cal_busy       = 1'b0;
  assign cal_req        = 1'b0;
  assign cal_done       = 1'b0;
  assign cal_wen        = 1'b0;
  assign cal_wrow       = '0;
  assign cal_wcol       = '0;
  assign cal_act        = '0;
  assign cal_shot_start = 1'b0;
  assign cal_shot       = 1'b0;
  assign cal_shot_col   = '0;
  assign cal_bank       = 1'b0;
  assign cal_eng_err     = 1'b0;
  assign tile_shot_start = 1'b0;
  assign o_pta_cal_busy    = 1'b0;
  assign o_pta_cal_valid   = 1'b0;
  assign o_pta_drift_alarm = 1'b0;
  assign o_pta_cal_ct      = 32'd0;
  assign o_pta_cal_cyc     = 32'd0;
  assign o_pta_err_max     = 24'd0;
  assign o_pta_err_found   = 24'd0;
  assign o_pta_cal_err     = 1'b0;
`endif

  // ---------------------------------------------------------------------------
  // Activation stage.  S_ACT feeds acc[j], j = 0 .. nc-1, on consecutive cycles
  // and stores what comes back into C through the same c_mem port S_WRITE uses,
  // so the DMA reads activated values with no change.  INT8/INT16/INT4 only:
  // the float modes accumulate normalised FP32, which a table over integer
  // sums does not describe, so enabling S_ACT with FP16 or BF16 is an error at
  // start, like an out-of-range dimension.
  // ---------------------------------------------------------------------------
  wire act_feed = (state == S_ACT) && (act_t < nc);
  wire [$clog2(NUM_COLS)-1:0] act_col = act_t[$clog2(NUM_COLS)-1:0];
  wire [C_AW-1:0] act_cidx = C_AW'(m_reg * i_dim_n + n_base + act_t);

  logic                    act_wvalid;
  logic [C_AW-1:0]         act_widx;
  logic signed [ACC_W-1:0] act_wdata;

  c930_npu_act #(
    .NUM_COLS (NUM_COLS),
    .ACC_W    (ACC_W),
    .C_AW     (C_AW)
  ) u_act (
    .i_clk         (i_clk),
    .i_rst_n       (i_rst_n),
    .i_cfg_load    (start_ok),
    .i_requant     (i_act_requant),
    .i_adc_bits    (i_act_adc_bits),
    .i_xs          (i_act_xs),
    .i_xshift      (i_act_xshift),
    .i_r           (i_act_r),
    .i_yshift      (i_act_yshift),
    .i_k_shot      (i_act_k_shot),
    .i_noise_const (i_act_noise_const),
    .i_seed        (i_act_seed),
    .i_idle        (state == S_IDLE),
    .i_tbl_wen     (i_act_tbl_wen),
    .i_tbl_waddr   (i_act_tbl_waddr),
    .i_tbl_wdata   (i_act_tbl_wdata),
    .i_valid       (act_feed),
    .i_acc         (acc[act_col]),
    .i_col         (act_col),
    .i_cidx        (act_cidx),
    .o_wvalid      (act_wvalid),
    .o_widx        (act_widx),
    .o_wdata       (act_wdata),
    .o_count       (o_act_count),
    .o_sat_count   (o_act_sat_count)
  );

  // ---------------------------------------------------------------------------
  // FSM  (m-inner loop order: for each N tile, for each K tile, load the B
  // tile once and then sweep every output row against it)
  //
  //   for nt:                       N tile
  //     for kt:                     K tile
  //       S_WLOAD                   load B[kt][nt] into the array, once
  //       for m:                    output row  <-- innermost
  //         S_AROW                  wait if the DMA has not landed A[m] yet
  //         S_ACCLD                 acc[] <- C[m][nt]  (skipped when kt == 0)
  //         S_RUN                   accumulate this tile into acc[]
  //         S_WRITE                 C[m][nt] <- acc[]
  //
  // The m-outer order this replaces reloaded the same B tile once per output
  // row: M * n_tiles * k_tiles weight loads where n_tiles * k_tiles suffice.
  //
  // The partial sum still enters the array through i_ps_in exactly as before,
  // so the arithmetic -- including FP32 addition order, which is not
  // associative -- is unchanged.  That is what S_ACCLD buys: it restores acc[]
  // from C before each run instead of letting the accumulator live in
  // registers across K tiles, which the m-inner order makes impossible.
  //
  // Note what this does to the operand supply.  m innermost means the core
  // walks all M rows of A during the very first K tile, instead of finishing
  // row 0 entirely before touching row 1.  The DMA's row prefetch now has to
  // keep up from the first pass -- which is what S_AROW is for.
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      state       <= S_IDLE;
      o_done      <= 1'b0;
      o_error     <= 1'b0;
      m_reg       <= 0;
      m_base      <= 0;
      nt_reg      <= 0;
      kt_reg      <= 0;
      t           <= 0;
      w_r         <= 0;
      w_n         <= 0;
      n_cnt       <= 0;
      act_t       <= 0;
      act_en_r    <= 1'b0;
      k_base_reg  <= 0;
      kr_reg      <= 0;
      bank_sel    <= 1'b0;
      b_bank_sel  <= 1'b0;
      cal_resume     <= 1'b0;
      cal_resume_st  <= S_IDLE;
      cal_abort_pend <= 1'b0;
      cal_err_q      <= 1'b0;
      settle_cnt     <= 32'd0;
      for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
    end else begin
      o_done <= done_cond;

      // Two things that must never reach the tile during a calibration, and
      // must never be lost in silence either (grxcp pta_cpu_integration.md
      // section 3.2, and the calibration document's section 6).  A START is
      // the CSR's dispatch guard's job; if one arrives anyway it is reported.
      if (state == S_CAL && (i_start || i_pta_model_rst))
        cal_err_q <= 1'b1;

      // No more A rows will land once the DMA gives up, so S_AROW would wait
      // forever -- and a core left waiting wakes up when the next GEMM's rows
      // arrive and computes them into this one.
      // A calibration cannot be abandoned half way: the engine would go on
      // driving a tile the core had walked away from.  The abort is held until
      // it finishes, and then taken instead of the resume.
      if (i_abort && state == S_CAL)
        cal_abort_pend <= 1'b1;
      if (i_abort && state != S_CAL)
        state <= S_IDLE;
      else begin
      case (state)

        S_IDLE: begin
          if (cal_take_idle) begin
            cal_resume    <= 1'b0;
            cal_resume_st <= S_IDLE;
            state         <= S_CAL;
          end else if (i_start) begin
            if (!dims_ok || act_fp || pta_bad) begin
              o_error <= 1'b1;          // stay IDLE
            end else begin
              o_error    <= 1'b0;
              m_reg      <= 0;
              m_base     <= 0;
              nt_reg     <= 0;
              kt_reg     <= 0;
              t          <= 0;
              w_r        <= 0;
              w_n        <= 0;
              n_cnt      <= 0;
              act_t      <= 0;
              act_en_r   <= i_act_en;
              bank_sel   <= i_bank_sel;  // match DMA's active bank for weight loading
              b_bank_sel <= i_bank_sel;  // snapshot for stable B reads throughout GEMM
              // Pre-register first K tile: k_base=0, kr=min(NUM_ROWS, dim_k)
              k_base_reg <= 0;
              kr_reg     <= (i_dim_k >= NUM_ROWS) ? NUM_ROWS : i_dim_k;
              for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
              state      <= S_WLOAD;
            end
          end
        end

        // Load B[k_base + w_r][n_base + w_n] into PE(w_r, w_n), one per cycle.
        // Only the nc active columns and kr active rows of this tile are
        // loaded.  Entered once per (N tile, K tile), not once per row.
        S_WLOAD: begin
          if (scan_done && (settle_cnt < tw_eff)) begin
            // The tile is settling.  w_n and w_r hold, so scan_done stays true
            // and w_load_active is gated off above.
            settle_cnt <= settle_cnt + 32'd1;
          end else if (scan_done) begin
            settle_cnt <= 32'd0;
            w_r    <= 0;
            w_n    <= 0;
            n_cnt  <= 0;
            if (cal_resume) begin
              // This pass through S_WLOAD only put back what the calibration
              // zeroed, so the GEMM's place in the row sweep is untouched and
              // it resumes where the grant found it.
              cal_resume <= 1'b0;
              state      <= cal_resume_st;
            end else begin
            t      <= 0;
            m_reg  <= 0;
            m_base <= 0;
            if (kt_reg == 0) begin
              // First K tile: the accumulator starts at zero, so there is
              // nothing to restore -- this is the m-outer order's behaviour.
              for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
              state <= S_RUN;
            end else begin
              state <= S_ACCLD;
            end
            end // !cal_resume
          end else if (w_n == nc - 1) begin
            w_n <= 0;
            w_r <= w_r + 1;
          end else begin
            w_n <= w_n + 1;
          end
        end

        // Restore this row's running partial sums from C, one column per
        // cycle, so i_ps_in carries the same value it carried when the
        // accumulator lived in registers.
        S_ACCLD: begin
          acc[n_cnt] <= c_mem[c_idx];
          if (n_cnt == nc - 1) begin
            n_cnt <= 0;
            t     <= 0;
            state <= S_RUN;
          end else begin
            n_cnt <= n_cnt + 1;
          end
        end

        // Run one K tile for one output row.  Cycles: 2*(NUM_ROWS + NUM_COLS)
        // (All precisions have 2-cycle PE latency: product reg + output reg;
        // stream registers hop every 2nd cycle, see HALF-RATE HOP above.)
        // The FP16 accumulator is internally pipelined (stage1/stage2) with
        // both stages free-running inside one hop window.
        S_RUN: begin
`ifdef PTM_B
          // Shot-and-wait (pta_cpu_integration.md 4.2).  bs_shot_req pulses on
          // the cycle this state is entered, the tile takes the shot on its next
          // hop and spends PTA_TS, and o_valid brings every column back at once.
          // Ts is that hop plus the dilation, against the 2 * (NUM_ROWS +
          // NUM_COLS) hop windows the skewed drain walks -- the variant's point.
          if (bs_valid) begin
            for (int n = 0; n < NUM_COLS; n++)
              if (n < nc) acc[n] <= ps_out[n*ACC_W +: ACC_W];
            t     <= 0;
            n_cnt <= 0;
            act_t <= 0;
            state <= (act_en_r && kt_reg == num_k_tiles - 1) ? S_ACT : S_WRITE;
          end
`else
          // Advance the run schedule only on hop edges (old value 1 -- the
          // same edges on which the PEs' stream registers load, so seeds
          // presented during a hop window are captured at the next edge,
          // exactly matching the old every-cycle behavior in t-space).
          if (hop_phase) begin
          // Staggered capture (window algebra, see HALF-RATE HOP above):
          // real accumulated results emerge at the bottom edge only on ODD
          // ticks -- a column's value passes through 2 registers per row
          // (accumulator stage-1 + PE stream reg), so column 0's result
          // (seeded at t=0, one row of travel after the stage-1 register)
          // is first visible at t = 2*NUM_ROWS + 1, and each later column
          // two ticks after the previous one.  Even ticks carry only the
          // pass-through junk windows, which are never captured.
          if ((t >= 2*NUM_ROWS + 1) && t[0]) begin
            acc[(t - 2*NUM_ROWS - 1) / 2] <=
              ps_out[((t - 2*NUM_ROWS - 1) / 2)*ACC_W +: ACC_W];
          end

          // Last capture (column NUM_COLS-1 at t = 2R+2C-1, odd) and the
          // exit share this edge -- same structure as the pre-hop design.
          if (t == 2*NUM_ROWS + 2*NUM_COLS - 1) begin
            t     <= 0;
            n_cnt <= 0;
            act_t <= 0;
            // Only the last K tile's sums are complete; an earlier tile's are
            // partial and go to C unactivated, to be restored by S_ACCLD.
            state <= (act_en_r && kt_reg == num_k_tiles - 1) ? S_ACT : S_WRITE;
          end else begin
            t <= t + 1;
          end
          end // hop_phase
`endif
        end

        // Write C[m_reg][n_base + n_cnt] = acc[n_cnt] for n_cnt in 0..nc-1.
        // acc[] already holds the running sum through this K tile, so this is
        // a plain store, not a read-modify-write.  The row / tile advance at
        // its end follows the case, shared with S_ACT.
        S_WRITE: begin
          // c_mem write lives in the dedicated reset-free process at the foot
          // of this file (a write inside this async-reset process is not
          // RAM-inferable).  S_WRITE/S_ACT are mutually exclusive, so that
          // single port serves both.
          if (n_cnt != nc - 1)
            n_cnt <= n_cnt + 1;
        end

        // The last K tile's complete sums, activated on their way into C.
        // acc[j] enters c930_npu_act on cycle j and its result is written
        // ACT_P cycles later, so the state lasts nc + ACT_P cycles and ends on
        // the last write.
        S_ACT: begin
          // c_mem write lives in the dedicated reset-free process below.
          if (act_t != nc + ACT_P - 1)
            act_t <= act_t + 1;
        end

        // Hold until the DMA has unpacked the row this pass needs.  Entered
        // only on an output-row advance; m_reg has already advanced, so the
        // test is against the row about to be read.  Resumes into whichever
        // state the row advance was headed for.
        S_AROW: begin
          if (arow_free || m_reg < i_a_rows_ready)
            state <= (kt_reg == 0) ? S_RUN : S_ACCLD;
          else if (cal_take_arow) begin
            cal_resume    <= 1'b1;
            cal_resume_st <= S_AROW;
            w_r           <= 0;
            w_n           <= 0;
            state         <= S_CAL;
          end
        end

        // The engine has the tile.  It drives the weight port, the activation
        // feed and the shot strobes (see the muxes above); the core waits, and
        // then puts back the weights the probe zeroed.
        S_CAL: begin
          if (cal_done) begin
            if (cal_abort_pend) begin
              cal_abort_pend <= 1'b0;
              cal_resume     <= 1'b0;
              state          <= S_IDLE;
            end else if (cal_resume) begin
              state <= S_WLOAD;
            end else begin
              state <= S_IDLE;
            end
          end
        end

        default: state <= S_IDLE;
      endcase

      // Row / tile advance at the end of S_WRITE or S_ACT.  One block, so S_ACT
      // inherits every step in S_WRITE's order -- in particular acc[] is
      // cleared for the next row only after S_ACT has consumed it, which a
      // GEMM with a single K tile, its first and last, depends on.
      if (row_done) begin
        n_cnt <= 0;
        act_t <= 0;
        if (m_reg != i_dim_m - 1) begin
          // Next output row, same weights: this is the whole point.
          m_reg  <= m_reg + 1;
          m_base <= m_base + i_dim_k;
          t      <= 0;
          if (kt_reg == 0)
            for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
          // Do not start the next output row until its A row has landed.
          // Bypassed when it already has, so the interlock costs nothing
          // on the common path.  Under this loop order the wait is real:
          // the first K tile walks all M rows while the DMA is still
          // fetching them.
          if (cal_take_row) begin
            // Calibrate here and come back to whichever state this advance was
            // headed for, once the weights are back.
            cal_resume    <= 1'b1;
            cal_resume_st <= (arow_free || (m_reg + 1) < i_a_rows_ready)
                             ? ((kt_reg == 0) ? S_RUN : S_ACCLD) : S_AROW;
            w_r           <= 0;
            w_n           <= 0;
            state         <= S_CAL;
          end else if (arow_free || (m_reg + 1) < i_a_rows_ready)
            state <= (kt_reg == 0) ? S_RUN : S_ACCLD;
          else
            state <= S_AROW;
        end else begin
          m_reg  <= 0;
          m_base <= 0;
          w_r    <= 0;
          w_n    <= 0;
          if (kt_reg != num_k_tiles - 1) begin
            // Next K tile, same N tile: reload the weight bank.
            kt_reg     <= kt_reg + 1;
            k_base_reg <= (kt_reg + 1) * NUM_ROWS;
            kr_reg     <= ((i_dim_k - (kt_reg + 1) * NUM_ROWS) >= NUM_ROWS) ?
                           NUM_ROWS : (i_dim_k - (kt_reg + 1) * NUM_ROWS);
            state      <= S_WLOAD;
          end else begin
            kt_reg     <= 0;
            k_base_reg <= 0;
            kr_reg     <= (i_dim_k >= NUM_ROWS) ? NUM_ROWS : i_dim_k;
            if (nt_reg != num_n_tiles - 1) begin
              nt_reg <= nt_reg + 1;
              state  <= S_WLOAD;
            end else begin
              // o_done is driven by done_cond (see above)
              state <= S_IDLE;
            end
          end
        end
      end
      end  // !i_abort
    end
  end

  // ---------------------------------------------------------------------------
  // PTA counters, C4(a): what PTA_SHOT_CT and PTA_WLOAD_CT read
  // ---------------------------------------------------------------------------
  // A shot is one run of one output row over one K tile, counted from the strobe
  // the tile actually sees -- so a calibration's probe shots are in here too,
  // which is what makes this the chiplet map's "optical shots issued" rather
  // than "shots a GEMM asked for".  A programming is one pass through S_WLOAD:
  // the quantity PTA_TW's slope multiplies in the section 2.1 model.
  wire wload_done = (state == S_WLOAD) && (w_n == nc - 1) && (w_r == kr_reg - 1);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      shot_cnt  <= 32'd0;
      wload_cnt <= 32'd0;
    end else begin
      if (hop_phase && tile_shot_start) shot_cnt  <= shot_cnt + 32'd1;
      if (wload_done)                   wload_cnt <= wload_cnt + 32'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // c_mem write port: dedicated, reset-free, one address per cycle.
  // The FSM always_ff above carries an asynchronous reset; a memory write
  // inside an async-reset process is not RAM-inferable (Vivado 8-4767:
  // "RAM is sensitive to asynchronous reset signal").  S_WRITE and S_ACT are
  // mutually exclusive (act_en_r is fixed for the whole GEMM), so this single
  // port serves both without conflicts.
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (state == S_WRITE)
      c_mem[c_idx] <= acc[n_cnt];
    else if ((state == S_ACT) && act_wvalid)
      c_mem[act_widx] <= act_wdata;
  end

endmodule
