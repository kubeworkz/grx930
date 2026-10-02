// -----------------------------------------------------------------------------
// c930_npu_csr.sv
//
// Control/status register file for the NPU with a command queue.
//
// Register map (word offsets):
//   0x00 CTRL       (W)  bit0 START — push command to queue
//   0x04 STATUS     (R)  bit0 BUSY, bit1 DONE (latched), bit2 ERROR
//   0x08 DIM_M      (R/W) output rows
//   0x0C DIM_N      (R/W) output cols
//   0x10 DIM_K      (R/W) reduction length
//   0x14 A_BASE     (R/W) A matrix base address
//   0x18 B_BASE     (R/W) B matrix base address
//   0x1C C_BASE     (R/W) C matrix base address
//   0x20 PREC       (R/W) bit[2:0] precision
//   0x24 CYCLE_LO   (R)  free-running cycle counter
//   0x2C OP_COUNT   (R)  MAC operations completed
//   0x30 STALL_CT   (R)  stall cycles
//   0x34 DMA_CT     (R)  DMA busy cycles (live counter)
//   0x28 DMA_LAST   (R)  latched cycle count from last completed GEMM
//   0x38 QUEUE_STAT (R)  bit[3:0] occupancy, bit[4] full
//   0x3C QUEUE_MAX  (R)  max depth (compile-time)
//
// Command queue:
//   CTRL.START snapshots the current CSR values into a FIFO. If the engine
//   is idle and the FIFO is empty, the command dispatches immediately from
//   the live CSRs. If the engine is busy, the command waits in the FIFO and
//   dispatches automatically when the engine completes. The CPU never blocks.
//
// Completion contract (drivers MUST read this):
//   * STATUS.DONE is a latched LEVEL, cleared only by a CTRL write with
//     START=1. It is set whenever ANY queued GEMM completes, so with N>1
//     commands in the FIFO it cannot identify which command finished.
//   * STATUS.BUSY is per-command and drops to 0 in the short P_DONE->next-
//     dispatch bubble even when the FIFO is not empty.
//   * Polling DONE then BUSY is therefore INVALID for a batch: it can
//     observe the stale DONE in a BUSY=0 dispatch bubble and declare the
//     batch finished while the last command has only just launched.
//   * Correct batch completion test: QUEUE_STAT occupancy==0 AND
//     STATUS busy==0. Both are required (see doc/c930_architecture.md).
//   * Never write START while the FIFO is full: START is a one-cycle pulse
//     and the snapshot push requires FIFO space in that same cycle, so a
//     submission against a full FIFO is silently dropped.
//
// The PTA register block, phase C4(a) (grxcp pta_cpu_integration.md section 3.1
// and pta_chiplet_regmap.md section 4).  The internal decode widens from
// s_axi_awaddr[5:2] to [9:2] -- sixteen words to 256, 0x000 to 0x3FC -- which
// leaves 0x00-0x3C bit-identical and needs no change in the crossbar, whose
// MMIO slave already covers 0x4000_0000-0x4000_FFFF.
//
// It does NOT go at 0x40, which is where the CPU document's section 3 puts it.
// That range is NPU1's CSR window on this SoC (c930_soc_top's w_to_npu1 /
// r_to_npu1 decode 0x4000_0040-0x4000_007F), so a block there would have been
// shadowed by the second NPU whenever ENABLE_NPU1 was set -- and by nothing at
// all when it was clear, which is worse, because it would have worked in test.
// The block therefore sits at 0x100, laid out exactly as the chiplet's window
// from its own 0x040 (pta_chiplet_regmap.md section 4), so one driver reaches a
// c930 tile and a chiplet with the same offsets inside the block and a different
// base:
//
//   0x000-0x03C  this file's own registers, unchanged
//   0x040-0x07F  NPU1's CSR window -- routed away by the SoC, never seen here
//   0x0F0-0x0FC  the MMIO bridge's HART_ID and CORE*_RELEASE, likewise
//   0x140-0x1DC  the PTA block: CTRL, STATUS, IMPAIR, BITS, SEED, the sigmas,
//                DRIFT, XTALK, TW, TS, CAL_PER, CAL_THR, CAL_CT, CAL_CYC,
//                SHOT_CT, WLOAD_CT, SAT_CT, ERR_MAX, GAIN[j], OFFS[j],
//                DRIFT_MAX, CAL_CFG, TRIM, CAL_SEED
//   0x1F0        PTA_ERR_FOUND, the error the last calibration found
//
// Three things the register block does that no document said.  PTA_CTRL bit2,
// CAL_AUTO, reads zero and does nothing: CAL_SCHED already says whether
// calibration is automatic, and two controls for one question is a way to make
// firmware wrong.  PTA_STATUS gains bit4 BUSY, as the chiplet's map does, so one
// read is a consistent snapshot, and bit5 CAL_ERR, because the c930 has no
// interrupt block for PTA_IRQ_STATUS.ERR to live in.  And MODEL_RST clears the
// correction stores with the model, which is what the calibration document says
// it does, so this file clears its own copies of GAIN and OFFS with them.
//
// Every address above 0x3F that the SoC does not route elsewhere still falls
// through to this slave and aliases modulo 1 KB, as it aliased modulo 64 bytes
// before: 0x4000_2140 reaches PTA_CTRL.  That is the fall-through the
// architecture document describes, with a wider footprint.
//
// Calibration (i_cal_busy), grxcp pta_cpu_integration.md section 3.2:
//   The PTA tile calibrates between commands, and while it does the tile is
//   not available -- but the calibration is not a command, so STATUS.BUSY
//   stays 0 and keeps its per-command meaning.  That is a third machine state,
//   and it can invalidate the completion predicate above in either direction:
//   dispatch a START into a tile that is busy elsewhere, or drop it and leave
//   occupancy 0 with busy 0, which a correct driver reads as "the batch
//   finished".  So i_cal_busy widens the "cannot dispatch now" condition
//   instead of touching BUSY: a START arriving during a calibration is pushed
//   to the FIFO, occupancy goes non-zero, and occupancy == 0 && busy == 0
//   correctly reports not-done.  Calibration is visible only through
//   PTA_STATUS.CAL_BUSY.  tb/tb_npu_cal_queue.sv is the regression.
// -----------------------------------------------------------------------------
module c930_npu_csr
#(
  parameter int CMD_QUEUE_DEPTH = 4,
  parameter int NUM_COLS        = 8    // PTA_GAIN[j] / PTA_OFFS[j], one per column
)
(
  input  logic        i_clk,
  input  logic        i_rst_n,

  // ---- AXI4-Lite slave ----
  input  logic [31:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,

  input  logic [31:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // ---- NPU core interface (driven from dispatch register) ----
  output logic        o_start,
  output logic [15:0] o_dim_m,
  output logic [15:0] o_dim_n,
  output logic [15:0] o_dim_k,
  output logic [31:0] o_a_base,
  output logic [31:0] o_b_base,
  output logic [31:0] o_c_base,
  output logic [2:0]  o_precision,
  input  logic        i_busy,
  // The PTA tile is calibrating: it cannot take a command, and this is not a
  // command's BUSY (see the header).  Tie low where there is no PTA tile.
  input  logic        i_cal_busy,
  input  logic        i_done,
  input  logic        i_error,

  // Performance counters
  input  logic [31:0] i_cycle_count,
  input  logic [31:0] i_op_count,
  input  logic [31:0] i_stall_count,
  // Cycles the core spent starved of A rows (S_AROW).  Weight movement and
  // operand starvation are different problems with different fixes, which is why
  // the core keeps them apart, and F2 is about the second one.
  input  logic [31:0] i_arow_stall_count,
  input  logic [31:0] i_dma_cycle_count,
  input  logic [31:0] i_dma_last_count,

  // ---- PTA register block, C4(a) ----
  // Configuration out to the core, status and counters back.  Every field is
  // the CPU document's section 3.1 unless the header says otherwise.
  output logic        o_pta_cal_en,        // PTA_CTRL.EN
  output logic        o_pta_cal_now,       // PTA_CTRL.CAL_NOW, one cycle
  output logic [1:0]  o_pta_cal_sched,     // PTA_CTRL.CAL_SCHED
  output logic        o_pta_model_rst,     // PTA_CTRL.MODEL_RST, one cycle
  output logic        o_pta_cal_rst,       // ... which also clears the correction
  output logic [6:0]  o_pta_impair,
  output logic [3:0]  o_pta_act_bits,
  output logic [3:0]  o_pta_w_bits,
  output logic [3:0]  o_pta_adc_bits,
  output logic [5:0]  o_pta_adc_shift,
  output logic [31:0] o_pta_seed,
  output logic [15:0] o_pta_sigma_th,
  output logic [15:0] o_pta_k_shot,
  output logic [15:0] o_pta_sigma_pr,
  output logic [15:0] o_pta_drift_sigma,
  output logic [4:0]  o_pta_drift_log2,
  output logic [15:0] o_pta_drift_max,
  output logic [7:0]  o_pta_xtalk,
  output logic [31:0] o_pta_tw,            // the emulation's settle and shot
  output logic [31:0] o_pta_ts,            // latency; the tile takes them at C2
  // MB's modes, PTA_CTRL bits 9:7.  All zero is the shipped behaviour: one bank
  // per compute, scanned every tile, interchanged loop order.
  output logic        o_pta_resident,      // PTA_CTRL.RESIDENT, a bank per tile
  output logic        o_pta_wskip,         // PTA_CTRL.WSKIP, banks already loaded
  output logic        o_pta_morder,        // PTA_CTRL.MORDER, m-outer
  // F2's third feed option, PTA_CTRL bit 10.  It goes to the DMA, not the tile:
  // every A row is read before the core is launched, instead of row 0 up front
  // and rows 1..M-1 streamed during compute (PF1).
  output logic        o_pta_stage_a,       // PTA_CTRL.STAGE_A, A staged in full
  // F2's other feed option, PTA_CTRL bit 11, also the DMA's: no cross-GEMM
  // prefetch.  Unlike STAGE_A this leaves PF1 alone.
  output logic        o_pta_pf2_off,       // PTA_CTRL.PF2_OFF
  // ---- S_ACT (A-CSR; npu_act_stage_design_note.md section 4) --------------
  // Every scalar is sampled by the core at i_start, like i_precision.  requant
  // is the exception and rides the command snapshot instead: a live bit would
  // apply to whichever command dispatched next, which is the hazard the
  // completion contract exists to prevent.
  output logic        o_act_en,
  output logic        o_act_requant,       // from the FIFO head, not the register
  output logic [3:0]  o_act_adc_bits,
  output logic [5:0]  o_act_xshift,
  output logic [5:0]  o_act_yshift,
  output logic [15:0] o_act_k_shot,
  output logic        o_act_noise_const,
  output logic [31:0] o_act_seed,
  output logic [32*NUM_COLS-1:0] o_act_xs,
  output logic [16*NUM_COLS-1:0] o_act_r,
  output logic        o_act_tbl_wen,
  output logic [10:0] o_act_tbl_waddr,
  output logic signed [23:0] o_act_tbl_wdata,
  input  logic [31:0] i_act_count,
  input  logic [31:0] i_act_sat_count,
  input  logic [31:0] i_act_cycles,
  output logic [31:0] o_pta_cal_per,
  output logic [23:0] o_pta_cal_thr,
  output logic [3:0]  o_pta_cal_amp,
  output logic [3:0]  o_pta_cal_reps,
  output logic [1:0]  o_pta_cal_passes,
  output logic        o_pta_cal_bank,
  output logic [3:0]  o_pta_trim_log2,
  output logic [15:0] o_pta_trim_max,
  output logic [31:0] o_pta_cal_seed,
  // A write to PTA_GAIN[j] or PTA_OFFS[j] sends the pair to the tile.
  output logic        o_pta_aff_wen,
  output logic [$clog2(NUM_COLS)-1:0] o_pta_aff_col,
  output logic signed [17:0] o_pta_aff_gain,
  output logic signed [31:0] o_pta_aff_offs,

  input  logic        i_pta_cal_valid,
  input  logic        i_pta_drift_alarm,
  input  logic        i_pta_cal_err,
  input  logic [31:0] i_pta_cal_ct,
  input  logic [31:0] i_pta_cal_cyc,
  input  logic [31:0] i_pta_shot_ct,
  input  logic [31:0] i_pta_wload_ct,
  input  logic [31:0] i_pta_sat_count,
  input  logic [23:0] i_pta_err_max,
  input  logic [23:0] i_pta_err_found,

  // ---- FIFO head (next GEMM params for cross-GEMM prefetch) ----
  output logic        o_fifo_valid,    // 1 when FIFO has a queued command
  output logic [15:0] o_fifo_dim_m,
  output logic [15:0] o_fifo_dim_n,
  output logic [15:0] o_fifo_dim_k,
  output logic [31:0] o_fifo_a_base,
  output logic [31:0] o_fifo_b_base,
  output logic [31:0] o_fifo_c_base,
  output logic [2:0]  o_fifo_precision
);

  // Word indices into a 256-word window; the byte offset is four times these.
  localparam logic [7:0] ADDR_CTRL      = 8'h00;
  localparam logic [7:0] ADDR_STAT      = 8'h01;
  localparam logic [7:0] ADDR_DIM_M     = 8'h02;
  localparam logic [7:0] ADDR_DIM_N     = 8'h03;
  localparam logic [7:0] ADDR_DIM_K     = 8'h04;
  localparam logic [7:0] ADDR_A_BASE    = 8'h05;
  localparam logic [7:0] ADDR_B_BASE    = 8'h06;
  localparam logic [7:0] ADDR_C_BASE    = 8'h07;
  localparam logic [7:0] ADDR_PREC      = 8'h08;
  localparam logic [7:0] ADDR_CYCLE_LO  = 8'h09;
  localparam logic [7:0] ADDR_OP_COUNT  = 8'h0B;
  localparam logic [7:0] ADDR_STALL_CT  = 8'h0C;
  localparam logic [7:0] ADDR_DMA_CT    = 8'h0D;
  localparam logic [7:0] ADDR_DMA_LAST  = 8'h0A;  // 0x28: latched DMA cycle count from last completed GEMM
  localparam logic [7:0] ADDR_QUEUE_STAT = 8'h0E;
  localparam logic [7:0] ADDR_QUEUE_MAX  = 8'h0F;

  // The PTA block: byte 0x100 plus the chiplet map's own offsets (see header).
  localparam logic [7:0] A_PTA_CTRL   = 8'h50;   // 0x140
  localparam logic [7:0] A_PTA_STATUS = 8'h51;
  localparam logic [7:0] A_PTA_IMPAIR = 8'h52;
  localparam logic [7:0] A_PTA_BITS   = 8'h53;
  localparam logic [7:0] A_PTA_SEED   = 8'h54;
  localparam logic [7:0] A_PTA_SIG_TH = 8'h55;
  localparam logic [7:0] A_PTA_SIG_SH = 8'h56;
  localparam logic [7:0] A_PTA_SIG_PR = 8'h57;
  localparam logic [7:0] A_PTA_DRIFT  = 8'h58;
  localparam logic [7:0] A_PTA_XTALK  = 8'h59;
  localparam logic [7:0] A_PTA_TW     = 8'h5A;
  localparam logic [7:0] A_PTA_TS     = 8'h5B;
  localparam logic [7:0] A_PTA_CAL_PER = 8'h5C;
  localparam logic [7:0] A_PTA_CAL_THR = 8'h5D;
  localparam logic [7:0] A_PTA_CAL_CT  = 8'h5E;
  localparam logic [7:0] A_PTA_CAL_CYC = 8'h5F;
  localparam logic [7:0] A_PTA_SHOT_CT = 8'h60;
  localparam logic [7:0] A_PTA_WLOAD_CT = 8'h61;
  localparam logic [7:0] A_PTA_SAT_CT  = 8'h62;
  localparam logic [7:0] A_PTA_ERR_MAX = 8'h63;
  localparam logic [7:0] A_PTA_GAIN0   = 8'h64;   // 0x190, NUM_COLS words
  localparam logic [7:0] A_PTA_OFFS0   = 8'h6C;   // 0x1B0, NUM_COLS words
  localparam logic [7:0] A_PTA_DRIFT_MAX = 8'h74; // 0x1D0
  localparam logic [7:0] A_PTA_CAL_CFG   = 8'h75;
  localparam logic [7:0] A_PTA_TRIM      = 8'h76;
  localparam logic [7:0] A_PTA_CAL_SEED  = 8'h77;
  localparam logic [7:0] A_PTA_ERR_FOUND = 8'h7C; // 0x1F0
  // An NPU counter, not a PTA one, in the PTA block's spare space: NPU0's own
  // counter window (0x00-0x3C) is full and 0x40 upward is NPU1's.  Named for what
  // it counts rather than where it sits -- being starved of operands is a host
  // problem, not a tile one, which is why F2 wants it.
  localparam logic [7:0] A_NPU_AROW_CT   = 8'h78; // 0x1E0

  localparam int CW = $clog2(NUM_COLS);

  // ---------------------------------------------------------------------------
  // Live CSR registers
  // ---------------------------------------------------------------------------
  logic [15:0] dim_m, dim_n, dim_k;
  logic [31:0] a_base, b_base, c_base;
  logic [2:0]  precision;
  logic        done_latch;

  // ---- The PTA block's own registers (C4(a)) ----
  logic        pta_en;
  logic [1:0]  pta_sched;
  logic        pta_resident;
  logic        pta_wskip;
  logic        pta_morder;
  logic        pta_stage_a;
  logic        pta_pf2_off;
  // ---- S_ACT's registers --------------------------------------------------
  logic        act_en, act_noise_const, act_requant_r;
  logic [3:0]  act_adc_bits;
  logic [5:0]  act_xshift, act_yshift;
  logic [15:0] act_k_shot;
  logic [31:0] act_seed;
  logic [31:0] act_xs_mem [0:NUM_COLS-1];
  logic [15:0] act_r_mem  [0:NUM_COLS-1];
  logic [1:0]  act_ir;
  logic [10:0] act_iaddr;
  logic [6:0]  pta_impair;
  logic [3:0]  pta_abits, pta_wbits, pta_adcbits;
  logic [5:0]  pta_shift;
  logic [31:0] pta_seed;
  logic [15:0] pta_sig_th, pta_sig_sh, pta_sig_pr;
  logic [15:0] pta_dsig, pta_dmax;
  logic [4:0]  pta_dlog2;
  logic [7:0]  pta_xtalk;
  logic [31:0] pta_tw, pta_ts;
  logic [31:0] pta_cal_per;
  logic [23:0] pta_cal_thr;
  logic [3:0]  pta_cal_amp, pta_cal_reps;
  logic [1:0]  pta_cal_passes;
  logic        pta_cal_bank;
  logic [3:0]  pta_trim_log2;
  logic [15:0] pta_trim_max;
  logic [31:0] pta_cal_seed;
  logic signed [17:0] pta_gain [0:NUM_COLS-1];
  logic signed [31:0] pta_offs [0:NUM_COLS-1];
  // One-cycle strobes, and the affine write the tile takes as a pair.
  logic        pta_now_q, pta_mrst_q, pta_aff_wen_q;
  logic [CW-1:0]      pta_aff_col_q;
  logic signed [17:0] pta_aff_gain_q;
  logic signed [31:0] pta_aff_offs_q;

  wire [7:0] wsel = s_axi_awaddr[9:2];
  wire [7:0] rsel = s_axi_araddr[9:2];
  wire       w_gain = (wsel >= A_PTA_GAIN0) && (wsel < A_PTA_GAIN0 + 8'(NUM_COLS));
  wire       w_offs = (wsel >= A_PTA_OFFS0) && (wsel < A_PTA_OFFS0 + 8'(NUM_COLS));
  wire [7:0] w_col  = w_gain ? (wsel - A_PTA_GAIN0) : (wsel - A_PTA_OFFS0);
  wire       r_gain = (rsel >= A_PTA_GAIN0) && (rsel < A_PTA_GAIN0 + 8'(NUM_COLS));
  wire       r_offs = (rsel >= A_PTA_OFFS0) && (rsel < A_PTA_OFFS0 + 8'(NUM_COLS));
  wire [7:0] r_col  = r_gain ? (rsel - A_PTA_GAIN0) : (rsel - A_PTA_OFFS0);

  assign o_pta_cal_en      = pta_en;
  assign o_pta_cal_now     = pta_now_q;
  assign o_pta_cal_sched   = pta_sched;
  assign o_pta_model_rst   = pta_mrst_q;
  assign o_pta_cal_rst     = pta_mrst_q;   // MODEL_RST clears the correction too
  assign o_pta_impair      = pta_impair;
  assign o_pta_act_bits    = pta_abits;
  assign o_pta_w_bits      = pta_wbits;
  assign o_pta_adc_bits    = pta_adcbits;
  assign o_pta_adc_shift   = pta_shift;
  assign o_pta_seed        = pta_seed;
  assign o_pta_sigma_th    = pta_sig_th;
  assign o_pta_k_shot      = pta_sig_sh;
  assign o_pta_sigma_pr    = pta_sig_pr;
  assign o_pta_drift_sigma = pta_dsig;
  assign o_pta_drift_log2  = pta_dlog2;
  assign o_pta_drift_max   = pta_dmax;
  assign o_pta_xtalk       = pta_xtalk;
  assign o_pta_tw          = pta_tw;
  assign o_pta_ts          = pta_ts;
  assign o_pta_resident    = pta_resident;
  assign o_pta_wskip       = pta_wskip;
  assign o_pta_morder      = pta_morder;
  assign o_pta_stage_a     = pta_stage_a;
  assign o_pta_pf2_off     = pta_pf2_off;
  assign o_act_en          = act_en;
  assign o_act_adc_bits    = act_adc_bits;
  assign o_act_xshift      = act_xshift;
  assign o_act_yshift      = act_yshift;
  assign o_act_k_shot      = act_k_shot;
  assign o_act_noise_const = act_noise_const;
  assign o_act_seed        = act_seed;
  always_comb begin
    for (int j = 0; j < NUM_COLS; j++) begin
      o_act_xs[32*j +: 32] = act_xs_mem[j];
      o_act_r [16*j +: 16] = act_r_mem[j];
    end
  end
  assign o_pta_cal_per     = pta_cal_per;
  assign o_pta_cal_thr     = pta_cal_thr;
  assign o_pta_cal_amp     = pta_cal_amp;
  assign o_pta_cal_reps    = pta_cal_reps;
  assign o_pta_cal_passes  = pta_cal_passes;
  assign o_pta_cal_bank    = pta_cal_bank;
  assign o_pta_trim_log2   = pta_trim_log2;
  assign o_pta_trim_max    = pta_trim_max;
  assign o_pta_cal_seed    = pta_cal_seed;
  assign o_pta_aff_wen     = pta_aff_wen_q;
  assign o_pta_aff_col     = pta_aff_col_q;
  assign o_pta_aff_gain    = pta_aff_gain_q;
  assign o_pta_aff_offs    = pta_aff_offs_q;

  // ---------------------------------------------------------------------------
  // Dispatch register — drives o_dim_m etc. to the DMA.
  // Loaded either from live CSRs (idle, FIFO empty) or from FIFO head.
  // ---------------------------------------------------------------------------
  logic [15:0] cur_dim_m, cur_dim_n, cur_dim_k;
  logic [31:0] cur_a_base, cur_b_base, cur_c_base;
  logic [2:0]  cur_precision;
  logic        start_pulse;

  assign o_dim_m     = cur_dim_m;
  assign o_dim_n     = cur_dim_n;
  assign o_dim_k     = cur_dim_k;
  assign o_a_base    = cur_a_base;
  assign o_b_base    = cur_b_base;
  assign o_c_base    = cur_c_base;
  assign o_precision = cur_precision;
  assign o_start     = start_pulse;

  // FIFO head outputs for cross-GEMM prefetch
  assign o_fifo_valid    = !fifo_empty;
  assign o_fifo_dim_m    = fifo_head[15:0];
  assign o_fifo_dim_n    = fifo_head[31:16];
  assign o_fifo_dim_k    = fifo_head[47:32];
  assign o_fifo_a_base   = fifo_head[79:48];
  assign o_fifo_b_base   = fifo_head[111:80];
  assign o_fifo_c_base   = fifo_head[143:112];
  assign o_fifo_precision = fifo_head[146:144];

  // ---------------------------------------------------------------------------
  // Command FIFO (147 bits per entry)
  // ---------------------------------------------------------------------------
  // ---- S_ACT's four words -------------------------------------------------
  // The free words in the PTA block, which are 0x79-0x7B and 0x7D-0x7F in word
  // terms: byte 0xE4, 0xE8, 0xEC and 0xF4, 0xF8, 0xFC.  The design note's
  // "twelve words, 0xD0-0xFC" predates DRIFT_MAX, CAL_CFG, TRIM, CAL_SEED,
  // AROW_CT and ERR_FOUND, which take half of them.
  localparam [7:0] A_ACT_CFG   = 8'h79;   // byte 0xE4
  localparam [7:0] A_ACT_SEED  = 8'h7A;   // byte 0xE8
  localparam [7:0] A_ACT_CTRL  = 8'h7B;   // byte 0xEC
  localparam [7:0] A_ACT_IADDR = 8'h7D;   // byte 0xF4
  localparam [7:0] A_ACT_IDATA = 8'h7E;   // byte 0xF8
  // 0x7F (byte 0xFC) is left spare on purpose: the next thing to need a word
  // should not have to re-plan this block.

  // The indirect window's regions.  Anything that is not a scalar lives here:
  // the per-column scales, the 1025-entry table, and the three counters.  One
  // window rather than three because six words is what there is.
  localparam [1:0] IR_XS   = 2'd0;   // 32 bits x NUM_COLS
  localparam [1:0] IR_R    = 2'd1;   // 16 bits x NUM_COLS
  localparam [1:0] IR_TBL  = 2'd2;   // 24 bits x 1025, write-only, idle only
  localparam [1:0] IR_CNT  = 2'd3;   // 32 bits x 3, read-only

  // requant takes CMD_W from 147 to 148 (design note section 4).
  localparam int CMD_W = 32 + 32 + 32 + 16 + 16 + 16 + 3 + 1;

  logic [CMD_W-1:0] fifo_mem [0:CMD_QUEUE_DEPTH-1];
  logic [$clog2(CMD_QUEUE_DEPTH):0] fifo_wr_ptr, fifo_rd_ptr;
  logic [$clog2(CMD_QUEUE_DEPTH):0] fifo_count;
  logic fifo_push, fifo_pop;
  logic [CMD_W-1:0] fifo_head;

  wire [$clog2(CMD_QUEUE_DEPTH)-1:0] fifo_wr_idx = fifo_wr_ptr[$clog2(CMD_QUEUE_DEPTH)-1:0];
  wire [$clog2(CMD_QUEUE_DEPTH)-1:0] fifo_rd_idx = fifo_rd_ptr[$clog2(CMD_QUEUE_DEPTH)-1:0];

  assign fifo_head = fifo_mem[fifo_rd_idx];
  wire   fifo_empty = (fifo_count == 0);
  wire   fifo_full  = (fifo_count == CMD_QUEUE_DEPTH);

  wire [CMD_W-1:0] cmd_snapshot = {
    act_requant_r,
    precision,
    c_base, b_base, a_base,
    dim_k, dim_n, dim_m
  };
  // The head's requant bit is the one the core sees, so a queued GEMM carries
  // the reset it was submitted with rather than whatever the register says now.
  assign o_act_requant = fifo_head[CMD_W-1];

  // Initialize
  integer fi;
  initial begin
    fifo_wr_ptr = 0;
    fifo_rd_ptr = 0;
    fifo_count  = 0;
    fifo_pop    = 0;
    fifo_push   = 0;
    for (fi = 0; fi < CMD_QUEUE_DEPTH; fi = fi + 1)
      fifo_mem[fi] = '0;
  end

  // ---------------------------------------------------------------------------
  // Start detection (rising edge of CTRL.START write)
  // ---------------------------------------------------------------------------
  logic start_written;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      start_written <= 1'b0;
    else if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid &&
             s_axi_awaddr[9:2] == ADDR_CTRL && s_axi_wstrb[0] && s_axi_wdata[0])
      start_written <= 1'b1;
    else
      start_written <= 1'b0;
  end

  wire start_requested = start_written;

  // Anything that means "the engine cannot take a command now".  The ablation
  // CAL_GUARD_ABLATE drops calibration from both of these, which is exactly
  // the regression of pta_cpu_integration.md section 3.2: a START arriving
  // during a calibration then dispatches into a tile that is not available.
`ifdef CAL_GUARD_ABLATE
  wire cannot_dispatch = i_busy;
  wire cal_blocks      = 1'b0;
`else
  wire cannot_dispatch = i_busy || i_cal_busy;
  wire cal_blocks      = i_cal_busy;
`endif

  // ---------------------------------------------------------------------------
  // Dispatcher FSM
  //
  // D_IDLE:   engine idle. If FIFO non-empty, pop and dispatch from head.
  //           If FIFO empty, dispatch immediately from live CSRs.
  // D_WAIT:   engine busy — wait for done, then return to D_IDLE.
  //
  // pending_start: latches a START that arrived while D_WAIT.  Without this,
  // a rapid back-to-back START (CTA1 + CTA2 within one DMA registration
  // cycle) is lost: the dispatcher is in D_WAIT, so start_requested is
  // ignored, and the FIFO push condition fails because i_busy hasn't gone
  // high yet.  The pending_start flag ensures the FIFO push fires when the
  // engine becomes busy, and the dispatcher sees the queued command when it
  // returns to D_IDLE.
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    D_IDLE,
    D_WAIT
  } disp_state_t;

  disp_state_t disp_state;
  logic        pending_start;  // START captured while dispatcher is in D_WAIT
  logic        pending_pushed; // one-shot: set once do_push fires for pending_start
  logic        was_busy;       // DMA was busy — prevents spurious double DRAIN

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      disp_state    <= D_IDLE;
      start_pulse   <= 1'b0;
      fifo_pop      <= 1'b0;
      pending_start <= 1'b0;
      pending_pushed <= 1'b0;
      was_busy      <= 1'b0;
      cur_dim_m     <= 16'd0;
      cur_dim_n     <= 16'd0;
      cur_dim_k     <= 16'd0;
      cur_a_base    <= 32'd0;
      cur_b_base    <= 32'd0;
      cur_c_base    <= 32'd0;
      cur_precision <= 3'd0;
    end else begin
      start_pulse <= 1'b0;
      fifo_pop    <= 1'b0;

      case (disp_state)
        D_IDLE: begin
          // Nothing dispatches into a calibrating tile; the pushes above have
          // already put the command in the FIFO, and the drain branch below
          // takes it when the tile comes back.
          if (cal_blocks) begin
            // hold
          end else if (pending_start && !fifo_empty) begin
            // Previous pending_start pushed to FIFO — dispatch from head
            cur_dim_m     <= fifo_head[15:0];
            cur_dim_n     <= fifo_head[31:16];
            cur_dim_k     <= fifo_head[47:32];
            cur_a_base    <= fifo_head[79:48];
            cur_b_base    <= fifo_head[111:80];
            cur_c_base    <= fifo_head[143:112];
            cur_precision <= fifo_head[146:144];
            fifo_pop      <= 1'b1;
            pending_start  <= 1'b0;
            pending_pushed <= 1'b0;
            start_pulse    <= 1'b1;
            disp_state     <= D_WAIT;
          end else if (pending_start && fifo_empty) begin
            // Pending start but FIFO push hasn't registered yet.
            // Wait one cycle for do_push to update fifo_count.
          end else if (start_requested) begin
            if (!fifo_empty) begin
              // FIFO has queued commands — dispatch from head
              cur_dim_m     <= fifo_head[15:0];
              cur_dim_n     <= fifo_head[31:16];
              cur_dim_k     <= fifo_head[47:32];
              cur_a_base    <= fifo_head[79:48];
              cur_b_base    <= fifo_head[111:80];
              cur_c_base    <= fifo_head[143:112];
              cur_precision <= fifo_head[146:144];
              fifo_pop      <= 1'b1;
            end else begin
              // FIFO empty — dispatch directly from live CSRs (zero bubble)
              cur_dim_m     <= dim_m;
              cur_dim_n     <= dim_n;
              cur_dim_k     <= dim_k;
              cur_a_base    <= a_base;
              cur_b_base    <= b_base;
              cur_c_base    <= c_base;
              cur_precision <= precision;
            end
            start_pulse <= 1'b1;
            disp_state  <= D_WAIT;
          end else if (!fifo_empty) begin
            // FIFO drain: engine idle, no new START, but commands queued.
            // Without this branch, queued commands strand forever —
            // the grxcp team's back-to-back regression (occupancy stuck
            // at 1, STATUS=0x2, queue count corrupted on 3+ commands).
            cur_dim_m     <= fifo_head[15:0];
            cur_dim_n     <= fifo_head[31:16];
            cur_dim_k     <= fifo_head[47:32];
            cur_a_base    <= fifo_head[79:48];
            cur_b_base    <= fifo_head[111:80];
            cur_c_base    <= fifo_head[143:112];
            cur_precision <= fifo_head[146:144];
            fifo_pop      <= 1'b1;
            start_pulse   <= 1'b1;
            disp_state    <= D_WAIT;
          end
        end

        D_WAIT: begin
          if (start_requested) begin
            if (do_push) begin
              // First clause already pushed this cycle — no need for pending
              pending_start  <= 1'b0;
              pending_pushed <= 1'b1;  // mark consumed
            end else begin
              // Push couldn't fire yet (i_busy=0 edge case) — defer push
              pending_start  <= 1'b1;
              pending_pushed <= 1'b0;
            end
          end
          // Mark pending as consumed once do_push fires for it
          if (pending_start && do_push && !pending_pushed)
            pending_pushed <= 1'b1;
          // Track that DMA was actually busy — don't return to D_IDLE until
          // the DMA has consumed start_pulse and entered a non-IDLE phase.
          // Without this, the dispatcher returns to D_IDLE one cycle too
          // early (before the DMA's phase change takes effect), causing a
          // spurious second DRAIN that pops the next FIFO entry.
          // Return to D_IDLE only after DMA was busy then became idle.
          // This prevents a spurious second DRAIN before start_pulse is
          // consumed (the DMA's phase change is an NBA, so i_busy lags
          // start_pulse by one cycle).
          if (i_busy)
            was_busy <= 1'b1;
          if (!i_busy && was_busy) begin
            disp_state     <= D_IDLE;
            pending_start  <= 1'b0;
            pending_pushed <= 1'b0;
            was_busy       <= 1'b0;
          end
        end

        default: disp_state <= D_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Push/pop enable signals (combinational)
  //
  // Push fires when:
  //  (a) normal START while engine busy or FIFO non-empty, OR
  //  (b) pending_start latched while engine is still busy (the START arrived
  //      in D_WAIT before i_busy went high, so we need to push retroactively)
  wire do_push = (start_requested && !fifo_full && (cannot_dispatch || !fifo_empty)) ||
                (pending_start && !pending_pushed && !fifo_full && cannot_dispatch);
  wire do_pop  = fifo_pop && !fifo_empty;

  // ---------------------------------------------------------------------------
  // FIFO push/pop
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      fifo_wr_ptr <= 0;
      fifo_rd_ptr <= 0;
      fifo_count  <= 0;
    end else begin
      // Push: START writes snapshot to FIFO when the command cannot be
      // dispatched immediately (engine busy or FIFO non-empty), or when a
      // pending_start is waiting for the engine to go busy.
      // After the push, clear pending_start so do_push doesn't re-fire
      // every cycle (the root cause of the grxcp team's corrupted queue).
      if (do_push) begin
        fifo_mem[fifo_wr_idx] <= cmd_snapshot;
        fifo_wr_ptr <= fifo_wr_ptr + 1;
      end

      // Pop: dispatcher requested a pop
      if (fifo_pop && !fifo_empty) begin
        fifo_rd_ptr <= fifo_rd_ptr + 1;
      end

      // Count update
      if (do_push && do_pop)
        fifo_count <= fifo_count;           // push+pop cancel
      else if (do_push)
        fifo_count <= fifo_count + 1;
      else if (do_pop)
        fifo_count <= fifo_count - 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Write channel
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      dim_m         <= 16'd0;
      dim_n         <= 16'd0;
      dim_k         <= 16'd0;
      a_base        <= 32'd0;
      b_base        <= 32'd0;
      c_base        <= 32'd0;
      precision     <= 3'd0;
      done_latch    <= 1'b0;
      pta_en        <= 1'b0;
      pta_resident <= 1'b0;
      pta_wskip    <= 1'b0;
      pta_morder   <= 1'b0;
      pta_stage_a  <= 1'b0;
      pta_pf2_off  <= 1'b0;
      act_en          <= 1'b0;
      act_requant_r   <= 1'b0;
      act_noise_const <= 1'b0;
      act_adc_bits    <= 4'd0;
      act_xshift      <= 6'd0;
      act_yshift      <= 6'd0;
      act_k_shot      <= 16'd0;
      act_seed        <= 32'd0;
      act_ir          <= 2'd0;
      act_iaddr       <= 11'd0;
      o_act_tbl_wen   <= 1'b0;
      o_act_tbl_waddr <= 11'd0;
      o_act_tbl_wdata <= 24'sd0;
      for (int j = 0; j < NUM_COLS; j++) begin
        act_xs_mem[j] <= 32'd0;
        act_r_mem[j]  <= 16'd0;
      end
      pta_sched     <= 2'd0;
      pta_impair    <= 7'd0;
      pta_abits     <= 4'd0;
      pta_wbits     <= 4'd0;
      pta_adcbits   <= 4'd0;
      pta_shift     <= 6'd0;
      pta_seed      <= 32'd0;
      pta_sig_th    <= 16'd0;
      pta_sig_sh    <= 16'd0;
      pta_sig_pr    <= 16'd0;
      pta_dsig      <= 16'd0;
      pta_dlog2     <= 5'd0;
      pta_dmax      <= 16'd0;
      pta_xtalk     <= 8'd0;
      pta_tw        <= 32'd0;
      pta_ts        <= 32'd0;
      pta_cal_per   <= 32'd0;
      pta_cal_thr   <= 24'd0;
      pta_cal_amp   <= 4'd0;
      pta_cal_reps  <= 4'd0;
      // Three passes out of reset: C3(a) measured that a probe which does not
      // take its own range recovers almost nothing, and three is what it took.
      pta_cal_passes <= 2'd3;
      pta_cal_bank  <= 1'b0;
      pta_trim_log2 <= 4'd0;
      pta_trim_max  <= 16'd0;
      pta_cal_seed  <= 32'd0;
      for (int j = 0; j < NUM_COLS; j++) begin
        pta_gain[j] <= 18'sd256;          // unity
        pta_offs[j] <= 32'sd0;
      end
      pta_now_q      <= 1'b0;
      pta_mrst_q     <= 1'b0;
      pta_aff_wen_q  <= 1'b0;
      pta_aff_col_q  <= '0;
      pta_aff_gain_q <= 18'sd256;
      pta_aff_offs_q <= 32'sd0;
    end else begin
      if (i_done)
        done_latch <= 1'b1;

      // The strobes are one cycle each.
      pta_now_q     <= 1'b0;
      pta_mrst_q    <= 1'b0;
      pta_aff_wen_q <= 1'b0;

      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;

      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;

      if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;

        // PTA_GAIN[j] and PTA_OFFS[j] are a range, and either write sends the
        // pair to the tile, since the tile takes them together.
        if (s_axi_wstrb[0] && (w_gain || w_offs)) begin
          if (w_gain) pta_gain[w_col[CW-1:0]] <= s_axi_wdata[17:0];
          else        pta_offs[w_col[CW-1:0]] <= s_axi_wdata;
          pta_aff_wen_q  <= 1'b1;
          pta_aff_col_q  <= w_col[CW-1:0];
          pta_aff_gain_q <= w_gain ? s_axi_wdata[17:0] : pta_gain[w_col[CW-1:0]];
          pta_aff_offs_q <= w_offs ? s_axi_wdata       : pta_offs[w_col[CW-1:0]];
        end else
        case (wsel)
          ADDR_CTRL: begin
            if (s_axi_wstrb[0] && s_axi_wdata[0])
              done_latch <= 1'b0;
          end
          ADDR_DIM_M:  if (s_axi_wstrb[0]) dim_m <= s_axi_wdata[15:0];
          ADDR_DIM_N:  if (s_axi_wstrb[0]) dim_n <= s_axi_wdata[15:0];
          ADDR_DIM_K:  if (s_axi_wstrb[0]) dim_k <= s_axi_wdata[15:0];
          ADDR_A_BASE: if (s_axi_wstrb[0]) a_base <= s_axi_wdata;
          ADDR_B_BASE: if (s_axi_wstrb[0]) b_base <= s_axi_wdata;
          ADDR_C_BASE: if (s_axi_wstrb[0]) c_base <= s_axi_wdata;
          ADDR_PREC:   if (s_axi_wstrb[0]) precision <= s_axi_wdata[2:0];
          // S_ACT's scalars, packed to fit the four words there are.
          A_ACT_CFG: if (s_axi_wstrb[0]) begin
            act_k_shot   <= s_axi_wdata[15:0];
            act_adc_bits <= s_axi_wdata[19:16];
            act_xshift   <= s_axi_wdata[25:20];
            act_yshift   <= s_axi_wdata[31:26];
          end
          A_ACT_SEED: if (s_axi_wstrb[0]) act_seed <= s_axi_wdata;
          A_ACT_CTRL: if (s_axi_wstrb[0]) begin
            act_en          <= s_axi_wdata[0];
            act_noise_const <= s_axi_wdata[1];
            // Latched, then snapshotted at START like the dims.  Writing it
            // does not disturb a GEMM already queued.
            act_requant_r   <= s_axi_wdata[2];
          end
          A_ACT_IADDR: if (s_axi_wstrb[0]) begin
            act_iaddr <= s_axi_wdata[10:0];
            act_ir    <= s_axi_wdata[13:12];
          end
          A_ACT_IDATA: if (s_axi_wstrb[0]) begin
            case (act_ir)
              IR_XS: if (act_iaddr < NUM_COLS)
                       act_xs_mem[act_iaddr[$clog2(NUM_COLS)-1:0]] <= s_axi_wdata;
              IR_R:  if (act_iaddr < NUM_COLS)
                       act_r_mem[act_iaddr[$clog2(NUM_COLS)-1:0]] <= s_axi_wdata[15:0];
              // A breakpoint write is idle-only, as the core's port requires:
              // the table is read combinationally while S_ACT runs.  A write
              // while busy is dropped rather than queued, and the drop is
              // visible because the readback will not match.
              IR_TBL: if (!i_busy) begin
                        o_act_tbl_wen   <= 1'b1;
                        o_act_tbl_waddr <= act_iaddr;
                        o_act_tbl_wdata <= s_axi_wdata[23:0];
                      end
              default: ;   // IR_CNT is read-only
            endcase
            // Auto-increment, so loading 1025 breakpoints is one address write
            // and 1025 data writes rather than 2050 writes.
            act_iaddr <= act_iaddr + 11'd1;
          end
          A_PTA_CTRL: if (s_axi_wstrb[0]) begin
            pta_en    <= s_axi_wdata[0];
            pta_sched <= s_axi_wdata[5:4];      // bit 6 of CAL_SCHED is reserved
            // MB's modes.  Latched, not strobed: they are sampled by the core at
            // each GEMM start, so firmware sets them once for a sweep point.
            pta_resident <= s_axi_wdata[7];
            pta_wskip    <= s_axi_wdata[8];
            pta_morder   <= s_axi_wdata[9];
            // F2's option, latched the same way and read by the DMA at START.
            pta_stage_a  <= s_axi_wdata[10];
            pta_pf2_off  <= s_axi_wdata[11];
            if (s_axi_wdata[1]) pta_now_q  <= 1'b1;
            if (s_axi_wdata[3]) pta_mrst_q <= 1'b1;
            // MODEL_RST clears the correction in the tile, so this file's copy
            // of it goes back to unity and zero with it.
            if (s_axi_wdata[3])
              for (int j = 0; j < NUM_COLS; j++) begin
                pta_gain[j] <= 18'sd256;
                pta_offs[j] <= 32'sd0;
              end
          end
          A_PTA_IMPAIR: if (s_axi_wstrb[0]) pta_impair <= s_axi_wdata[6:0];
          A_PTA_BITS:   if (s_axi_wstrb[0]) begin
            pta_abits   <= s_axi_wdata[3:0];
            pta_wbits   <= s_axi_wdata[7:4];
            pta_adcbits <= s_axi_wdata[11:8];
            pta_shift   <= s_axi_wdata[17:12];
          end
          A_PTA_SEED:   if (s_axi_wstrb[0]) pta_seed   <= s_axi_wdata;
          A_PTA_SIG_TH: if (s_axi_wstrb[0]) pta_sig_th <= s_axi_wdata[15:0];
          A_PTA_SIG_SH: if (s_axi_wstrb[0]) pta_sig_sh <= s_axi_wdata[15:0];
          A_PTA_SIG_PR: if (s_axi_wstrb[0]) pta_sig_pr <= s_axi_wdata[15:0];
          A_PTA_DRIFT:  if (s_axi_wstrb[0]) begin
            pta_dsig  <= s_axi_wdata[15:0];
            pta_dlog2 <= s_axi_wdata[20:16];
          end
          A_PTA_XTALK:  if (s_axi_wstrb[0]) pta_xtalk <= s_axi_wdata[7:0];
          A_PTA_TW:     if (s_axi_wstrb[0]) pta_tw <= s_axi_wdata;
          A_PTA_TS:     if (s_axi_wstrb[0]) pta_ts <= s_axi_wdata;
          A_PTA_CAL_PER: if (s_axi_wstrb[0]) pta_cal_per <= s_axi_wdata;
          A_PTA_CAL_THR: if (s_axi_wstrb[0]) pta_cal_thr <= s_axi_wdata[23:0];
          A_PTA_DRIFT_MAX: if (s_axi_wstrb[0]) pta_dmax <= s_axi_wdata[15:0];
          A_PTA_CAL_CFG: if (s_axi_wstrb[0]) begin
            pta_cal_amp    <= s_axi_wdata[3:0];
            pta_cal_reps   <= s_axi_wdata[7:4];
            pta_cal_passes <= s_axi_wdata[9:8];
            pta_cal_bank   <= s_axi_wdata[10];
          end
          A_PTA_TRIM: if (s_axi_wstrb[0]) begin
            pta_trim_log2 <= s_axi_wdata[3:0];
            pta_trim_max  <= s_axi_wdata[31:16];
          end
          A_PTA_CAL_SEED: if (s_axi_wstrb[0]) pta_cal_seed <= s_axi_wdata;
          default: ;
        endcase

        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= 2'b00;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read channel
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= 32'd0;
      s_axi_rresp   <= 2'b00;
    end else begin
      s_axi_arready <= 1'b0;

      if (s_axi_rvalid && s_axi_rready)
        s_axi_rvalid <= 1'b0;

      if (s_axi_arvalid && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;

        if (r_gain)
          s_axi_rdata <= {14'd0, pta_gain[r_col[CW-1:0]]};
        else if (r_offs)
          s_axi_rdata <= pta_offs[r_col[CW-1:0]];
        else
        case (rsel)
          ADDR_STAT:       s_axi_rdata <= {29'd0, i_error, done_latch, i_busy};
          ADDR_DIM_M:      s_axi_rdata <= {16'd0, dim_m};
          ADDR_DIM_N:      s_axi_rdata <= {16'd0, dim_n};
          ADDR_DIM_K:      s_axi_rdata <= {16'd0, dim_k};
          ADDR_A_BASE:     s_axi_rdata <= a_base;
          ADDR_B_BASE:     s_axi_rdata <= b_base;
          ADDR_C_BASE:     s_axi_rdata <= c_base;
          ADDR_PREC:       s_axi_rdata <= {29'd0, precision};
          ADDR_CYCLE_LO:   s_axi_rdata <= i_cycle_count;
          ADDR_OP_COUNT:   s_axi_rdata <= i_op_count;
          ADDR_STALL_CT:   s_axi_rdata <= i_stall_count;
          A_NPU_AROW_CT:   s_axi_rdata <= i_arow_stall_count;
          ADDR_DMA_CT:     s_axi_rdata <= i_dma_cycle_count;
          ADDR_DMA_LAST:   s_axi_rdata <= i_dma_last_count;
          ADDR_QUEUE_STAT: s_axi_rdata <= {28'd0, fifo_full, fifo_count[$clog2(CMD_QUEUE_DEPTH):0]};
          ADDR_QUEUE_MAX:  s_axi_rdata <= {28'd0, CMD_QUEUE_DEPTH[3:0]};
          // 20 + 5 + 1 + 2 + 3 + 1 = 32.  The old form concatenated to 31 and
          // relied on the zero-extension; MB's bits are not going on top of that,
          // and F2's stage_a widened the field rather than the padding.
          A_ACT_CFG:   s_axi_rdata <= {act_yshift, act_xshift, act_adc_bits,
                                        act_k_shot};
          A_ACT_SEED:  s_axi_rdata <= act_seed;
          A_ACT_CTRL:  s_axi_rdata <= {29'd0, act_requant_r, act_noise_const,
                                       act_en};
          A_ACT_IADDR: s_axi_rdata <= {18'd0, act_ir, 1'b0, act_iaddr};
          A_ACT_IDATA: case (act_ir)
                         IR_XS:  s_axi_rdata <= act_iaddr < NUM_COLS
                                 ? act_xs_mem[act_iaddr[$clog2(NUM_COLS)-1:0]] : 32'd0;
                         IR_R:   s_axi_rdata <= act_iaddr < NUM_COLS
                                 ? {16'd0, act_r_mem[act_iaddr[$clog2(NUM_COLS)-1:0]]}
                                 : 32'd0;
                         // The table is write-only from here: the core owns the
                         // only read port and S_ACT reads it combinationally.
                         IR_TBL: s_axi_rdata <= 32'd0;
                         IR_CNT: case (act_iaddr[1:0])
                                   2'd0: s_axi_rdata <= i_act_count;
                                   2'd1: s_axi_rdata <= i_act_sat_count;
                                   2'd2: s_axi_rdata <= i_act_cycles;
                                   default: s_axi_rdata <= 32'd0;
                                 endcase
                         default: s_axi_rdata <= 32'd0;
                       endcase
          A_PTA_CTRL:      s_axi_rdata <= {20'd0,
                                           pta_pf2_off, pta_stage_a,
                                           pta_morder, pta_wskip, pta_resident,
                                           1'b0,            // CAL_SCHED bit 6
                                           pta_sched, 3'd0, pta_en};
          // One read is the whole snapshot: bit4 BUSY as the chiplet's map has
          // it, bit5 CAL_ERR because this SoC has no interrupt block, and the
          // residual in [23:8] as the CPU document's 3.1 asks.
          A_PTA_STATUS:    s_axi_rdata <= {8'd0, i_pta_err_max[15:0], 2'd0,
                                           i_pta_cal_err, i_busy, i_pta_drift_alarm,
                                           (i_pta_sat_count != 32'd0), i_pta_cal_valid,
                                           i_cal_busy};
          A_PTA_IMPAIR:    s_axi_rdata <= {25'd0, pta_impair};
          A_PTA_BITS:      s_axi_rdata <= {14'd0, pta_shift, pta_adcbits, pta_wbits,
                                           pta_abits};
          A_PTA_SEED:      s_axi_rdata <= pta_seed;
          A_PTA_SIG_TH:    s_axi_rdata <= {16'd0, pta_sig_th};
          A_PTA_SIG_SH:    s_axi_rdata <= {16'd0, pta_sig_sh};
          A_PTA_SIG_PR:    s_axi_rdata <= {16'd0, pta_sig_pr};
          A_PTA_DRIFT:     s_axi_rdata <= {11'd0, pta_dlog2, pta_dsig};
          A_PTA_XTALK:     s_axi_rdata <= {24'd0, pta_xtalk};
          A_PTA_TW:        s_axi_rdata <= pta_tw;
          A_PTA_TS:        s_axi_rdata <= pta_ts;
          A_PTA_CAL_PER:   s_axi_rdata <= pta_cal_per;
          A_PTA_CAL_THR:   s_axi_rdata <= {8'd0, pta_cal_thr};
          A_PTA_CAL_CT:    s_axi_rdata <= i_pta_cal_ct;
          A_PTA_CAL_CYC:   s_axi_rdata <= i_pta_cal_cyc;
          A_PTA_SHOT_CT:   s_axi_rdata <= i_pta_shot_ct;
          A_PTA_WLOAD_CT:  s_axi_rdata <= i_pta_wload_ct;
          A_PTA_SAT_CT:    s_axi_rdata <= i_pta_sat_count;
          A_PTA_ERR_MAX:   s_axi_rdata <= {8'd0, i_pta_err_max};
          A_PTA_DRIFT_MAX: s_axi_rdata <= {16'd0, pta_dmax};
          A_PTA_CAL_CFG:   s_axi_rdata <= {21'd0, pta_cal_bank, pta_cal_passes,
                                           pta_cal_reps, pta_cal_amp};
          A_PTA_TRIM:      s_axi_rdata <= {pta_trim_max, 12'd0, pta_trim_log2};
          A_PTA_CAL_SEED:  s_axi_rdata <= pta_cal_seed;
          A_PTA_ERR_FOUND: s_axi_rdata <= {8'd0, i_pta_err_found};
          default:         s_axi_rdata <= 32'd0;
        endcase

        s_axi_rvalid <= 1'b1;
        s_axi_rresp  <= 2'b00;
      end
    end
  end

endmodule
