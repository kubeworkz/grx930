// -----------------------------------------------------------------------------
// c930_npu_top.sv
//
// Memory-mapped INT8 tensor accelerator IP:
//
//   * AXI4-Lite slave  -> c930_npu_csr   (control/status/dims/bases)
//   * AXI4 full master -> c930_npu_dma   (autonomous fetch of A/B, store of C)
//   * c930_npu_core    -> systolic GEMM datapath + buffers
//
// Flow: the host writes DIMs and A/B/C base addresses plus CTRL.START over the
// AXI4-Lite slave. The DMA burst-reads A and B from memory into the core,
// launches the GEMM, then burst-writes C back to memory and pulses o_irq.
// -----------------------------------------------------------------------------
module c930_npu_top
#(
  parameter int NUM_ROWS = 8,
  parameter int NUM_COLS = 8,
  parameter int DIN_W    = 16,
  parameter int ACC_W    = 48,    // 48-bit fixed-point accumulator for FP modes
  parameter int MAX_M    = 64,
  parameter int MAX_K    = 256,
  parameter int MAX_N    = 8,
  // Elements the DMA writes into the core per cycle on the wide preload port.
  parameter int WR_LANES = 8
)
(
  input  logic        i_clk,
  input  logic        i_rst_n,

  // ---- AXI4-Lite slave (control / status / dims / bases) ----
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

  // ---- AXI4 full master (DDR data plane) ----
  output logic [31:0] m_axi_araddr,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [63:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rlast,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready,
  output logic [31:0] m_axi_awaddr,
  output logic [7:0]  m_axi_awlen,
  output logic [2:0]  m_axi_awsize,
  output logic [1:0]  m_axi_awburst,
  output logic        m_axi_awvalid,
  input  logic        m_axi_awready,
  output logic [63:0] m_axi_wdata,
  output logic [7:0]  m_axi_wstrb,
  output logic        m_axi_wlast,
  output logic        m_axi_wvalid,
  input  logic        m_axi_wready,
  input  logic [1:0]  m_axi_bresp,
  input  logic        m_axi_bvalid,
  output logic        m_axi_bready,

  // ---- Completion ----
  output logic        o_busy,
  output logic        o_done,
  output logic        o_error,
  output logic        o_irq,    // pulses on completion

  // Cycles the core spent waiting for the DMA to unpack the next A row.
  // Non-zero means the core is consuming rows faster than PF_UNPK supplies
  // them.  Not yet in the CSR map -- the NPU register file decodes only
  // addr[5:2] and all 16 words are assigned.
  output logic [31:0] o_arow_stall_count
);

  logic        start;
  logic        busy, done, error;
  logic [15:0] dim_m, dim_n, dim_k;
  logic [31:0] a_base, b_base, c_base;
  logic [2:0]  precision;

  logic                    dma_wen, dma_wsel, core_start, core_abort;
  logic [15:0]             a_rows_ready;
  // Wide preload path: one AXI beat per cycle instead of one element.
  logic                          dma_wwen, dma_wwsel, dma_wwbank;
  logic [WR_LANES-1:0]           dma_wwmask;
  logic [15:0]                   dma_wwaddr;
  logic [WR_LANES*DIN_W-1:0]     dma_wwdata;
  logic [15:0]             dma_waddr;
  logic signed [DIN_W-1:0] dma_wdata;

  // Staging buffer load signals (DMA → core)
  logic                    staging_wen, staging_wsel;
  logic [15:0]             staging_waddr;
  logic signed [DIN_W-1:0] staging_wdata;
  logic [15:0]             c_raddr;
  logic signed [31:0]      c_rdata;   // always 32-bit (normalized by core)
  logic                    core_done, core_error;
  logic [31:0]             cycle_count, op_count, stall_count, dma_cycle_count, dma_last_count;
  logic                    dma_bank_sel;
  logic                    dma_wbank;

  // FIFO head (next GEMM params for cross-GEMM prefetch)
  logic        fifo_valid;
  // PTA_STATUS.CAL_BUSY from the core's calibration engine, and the CSR's
  // dispatch guard it feeds (grxcp pta_cpu_integration.md section 3.2).
  logic        pta_cal_busy;
  // ---- The PTA register block's side of the tile (C4(a)) ----
  logic        pta_cal_en, pta_cal_now, pta_mrst, pta_crst;
  logic [1:0]  pta_cal_sched, pta_cal_passes;
  logic [6:0]  pta_impair;
  logic [3:0]  pta_act_bits, pta_w_bits, pta_adc_bits;
  logic [5:0]  pta_adc_shift;
  logic [31:0] pta_seed, pta_tw, pta_ts, pta_cal_per, pta_cal_seed;
  logic [15:0] pta_sigma_th, pta_k_shot, pta_sigma_pr, pta_drift_sigma, pta_drift_max;
  logic [4:0]  pta_drift_log2;
  logic [7:0]  pta_xtalk;
  logic [23:0] pta_cal_thr;
  logic [3:0]  pta_cal_amp, pta_cal_reps, pta_trim_log2;
  logic [15:0] pta_trim_max;
  logic        pta_cal_bank;
  logic        pta_aff_wen;
  logic [$clog2(NUM_COLS)-1:0] pta_aff_col;
  logic signed [17:0] pta_aff_gain;
  logic signed [31:0] pta_aff_offs;
  logic        pta_cal_valid, pta_drift_alarm, pta_cal_err;
  logic [31:0] pta_cal_ct, pta_cal_cyc, pta_shot_ct, pta_wload_ct, pta_sat_ct;
  logic [23:0] pta_err_max, pta_err_found;

  logic [15:0] fifo_dim_m, fifo_dim_n, fifo_dim_k;
  logic [31:0] fifo_a_base, fifo_b_base, fifo_c_base;
  logic [2:0]  fifo_precision;

  c930_npu_csr #(.NUM_COLS (NUM_COLS)) u_csr (
    .i_clk         (i_clk),
    .i_rst_n       (i_rst_n),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .o_start       (start),
    .o_dim_m       (dim_m),
    .o_dim_n       (dim_n),
    .o_dim_k       (dim_k),
    .o_a_base      (a_base),
    .o_b_base      (b_base),
    .o_c_base      (c_base),
    .o_precision   (precision),
    .i_busy        (busy),
    .i_cal_busy    (pta_cal_busy),
    .i_done        (done),
    .i_error       (error),

    // ---- The PTA register block (C4(a)) ----
    .o_pta_cal_en      (pta_cal_en),
    .o_pta_cal_now     (pta_cal_now),
    .o_pta_cal_sched   (pta_cal_sched),
    .o_pta_model_rst   (pta_mrst),
    .o_pta_cal_rst     (pta_crst),
    .o_pta_impair      (pta_impair),
    .o_pta_act_bits    (pta_act_bits),
    .o_pta_w_bits      (pta_w_bits),
    .o_pta_adc_bits    (pta_adc_bits),
    .o_pta_adc_shift   (pta_adc_shift),
    .o_pta_seed        (pta_seed),
    .o_pta_sigma_th    (pta_sigma_th),
    .o_pta_k_shot      (pta_k_shot),
    .o_pta_sigma_pr    (pta_sigma_pr),
    .o_pta_drift_sigma (pta_drift_sigma),
    .o_pta_drift_log2  (pta_drift_log2),
    .o_pta_drift_max   (pta_drift_max),
    .o_pta_xtalk       (pta_xtalk),
    .o_pta_tw          (pta_tw),
    .o_pta_ts          (pta_ts),
    .o_pta_cal_per     (pta_cal_per),
    .o_pta_cal_thr     (pta_cal_thr),
    .o_pta_cal_amp     (pta_cal_amp),
    .o_pta_cal_reps    (pta_cal_reps),
    .o_pta_cal_passes  (pta_cal_passes),
    .o_pta_cal_bank    (pta_cal_bank),
    .o_pta_trim_log2   (pta_trim_log2),
    .o_pta_trim_max    (pta_trim_max),
    .o_pta_cal_seed    (pta_cal_seed),
    .o_pta_aff_wen     (pta_aff_wen),
    .o_pta_aff_col     (pta_aff_col),
    .o_pta_aff_gain    (pta_aff_gain),
    .o_pta_aff_offs    (pta_aff_offs),
    .i_pta_cal_valid   (pta_cal_valid),
    .i_pta_drift_alarm (pta_drift_alarm),
    .i_pta_cal_err     (pta_cal_err),
    .i_pta_cal_ct      (pta_cal_ct),
    .i_pta_cal_cyc     (pta_cal_cyc),
    .i_pta_shot_ct     (pta_shot_ct),
    .i_pta_wload_ct    (pta_wload_ct),
    .i_pta_sat_count   (pta_sat_ct),
    .i_pta_err_max     (pta_err_max),
    .i_pta_err_found   (pta_err_found),
    .i_cycle_count (cycle_count),
    .i_op_count    (op_count),
    .i_stall_count (stall_count),
    .i_dma_cycle_count (dma_cycle_count),
    .i_dma_last_count  (dma_last_count),
    .o_fifo_valid    (fifo_valid),
    .o_fifo_dim_m    (fifo_dim_m),
    .o_fifo_dim_n    (fifo_dim_n),
    .o_fifo_dim_k    (fifo_dim_k),
    .o_fifo_a_base   (fifo_a_base),
    .o_fifo_b_base   (fifo_b_base),
    .o_fifo_c_base   (fifo_c_base),
    .o_fifo_precision (fifo_precision)
  );

  c930_npu_dma #(
    // DIN_W was never passed here.  The DMA ran its whole data path at its own
    // default of 16 bits and the scalar o_wdata port truncated on the way out,
    // which happened to give the right byte.  A packed wide bus has no such
    // luck: lane l sits at bit l*DIN_W, so the two sides must agree.
    .DIN_W    (DIN_W),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N),
    .WR_LANES (WR_LANES)
  ) u_dma (
    .i_clk         (i_clk),
    .i_rst_n       (i_rst_n),
    .i_start       (start),
    .i_dim_m       (dim_m),
    .i_dim_n       (dim_n),
    .i_dim_k       (dim_k),
    .i_a_base      (a_base),
    .i_b_base      (b_base),
    .i_c_base      (c_base),
    .i_precision   (precision),
    .i_next_valid  (fifo_valid),
    .i_next_dim_m  (fifo_dim_m),
    .i_next_dim_n  (fifo_dim_n),
    .i_next_dim_k  (fifo_dim_k),
    .i_next_a_base (fifo_a_base),
    .i_next_b_base (fifo_b_base),
    .i_next_c_base (fifo_c_base),
    .i_next_precision (fifo_precision),
    .o_busy        (busy),
    .o_done        (done),
    .o_error       (error),
    .o_dma_cycle_count (dma_cycle_count),
    .o_dma_last_count  (dma_last_count),
    .o_bank_sel       (dma_bank_sel),
    .o_a_rows_ready   (a_rows_ready),
    .o_wwen        (dma_wwen),
    .o_wwsel       (dma_wwsel),
    .o_wwbank      (dma_wwbank),
    .o_wwmask      (dma_wwmask),
    .o_wwaddr      (dma_wwaddr),
    .o_wwdata      (dma_wwdata),
    .o_wen         (dma_wen),
    .o_wsel        (dma_wsel),
    .o_wbank       (dma_wbank),
    .o_waddr       (dma_waddr),
    .o_wdata       (dma_wdata),
    .o_staging_wen   (staging_wen),
    .o_staging_wsel  (staging_wsel),
    .o_staging_waddr (staging_waddr),
    .o_staging_wdata (staging_wdata),
    .o_core_start  (core_start),
    .o_core_abort  (core_abort),
    .i_core_done   (core_done),
    .i_core_error  (core_error),
    .o_c_raddr     (c_raddr),
    .i_c_rdata     (c_rdata),
    .m_axi_araddr  (m_axi_araddr),
    .m_axi_arlen   (m_axi_arlen),
    .m_axi_arsize  (m_axi_arsize),
    .m_axi_arburst (m_axi_arburst),
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rlast   (m_axi_rlast),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awlen   (m_axi_awlen),
    .m_axi_awsize  (m_axi_awsize),
    .m_axi_awburst (m_axi_awburst),
    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_wdata   (m_axi_wdata),
    .m_axi_wstrb   (m_axi_wstrb),
    .m_axi_wlast   (m_axi_wlast),
    .m_axi_wvalid  (m_axi_wvalid),
    .m_axi_wready  (m_axi_wready),
    .m_axi_bresp   (m_axi_bresp),
    .m_axi_bvalid  (m_axi_bvalid),
    .m_axi_bready  (m_axi_bready)
  );

  c930_npu_core #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (DIN_W),
    .ACC_W    (ACC_W),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N),
    .WR_LANES (WR_LANES)
  ) u_core (
    .i_clk      (i_clk),
    .i_rst_n    (i_rst_n),
    .i_wen      (dma_wen),
    .i_wsel     (dma_wsel),
    .i_waddr    (dma_waddr),
    .i_wdata    (dma_wdata),
    .i_staging_wen   (staging_wen),
    .i_staging_wsel  (staging_wsel),
    .i_staging_waddr (staging_waddr),
    .i_staging_wdata (staging_wdata),
    .i_bank_sel (dma_bank_sel),
    .i_wbank    (dma_wbank),
    .i_start    (core_start),
    .i_abort    (core_abort),
    .i_dim_m    (dim_m),
    .i_dim_n    (dim_n),
    .i_dim_k    (dim_k),
    .i_precision(precision),
    .o_busy     (),             // internal to the core; DMA drives the top's o_busy
    .o_done     (core_done),
    .o_error    (core_error),
    .i_c_raddr  (c_raddr),
    .o_c_rdata  (c_rdata),
    .i_a_rows_ready (a_rows_ready),
    .i_wwen     (dma_wwen),
    .i_wwsel    (dma_wwsel),
    .i_wwbank   (dma_wwbank),
    .i_wwmask   (dma_wwmask),
    .i_wwaddr   (dma_wwaddr),
    .i_wwdata   (dma_wwdata),
    .o_cycle_count (cycle_count),
    .o_op_count    (op_count),
    .o_stall_count (stall_count),
    .o_arow_stall_count (o_arow_stall_count),
    // S_ACT is core-level only until its gates are green
    // (doc/npu_act_stage_design_note.md section 7): off at the top.
    .i_act_en          (1'b0),
    .i_act_requant     (1'b0),
    .i_act_adc_bits    (4'd0),
    .i_act_xs          ({(32*NUM_COLS){1'b0}}),
    .i_act_xshift      (6'd0),
    .i_act_r           ({(16*NUM_COLS){1'b0}}),
    .i_act_yshift      (6'd0),
    .i_act_k_shot      (16'd0),
    .i_act_noise_const (1'b0),
    .i_act_seed        (32'd0),
    .i_act_tbl_wen     (1'b0),
    .i_act_tbl_waddr   (11'd0),
    .i_act_tbl_wdata   (24'sd0),
    .o_act_count       (),
    .o_act_sat_count   (),
    .o_act_cycles      (),
    // The PTA error model and its calibration engine, on the CSR's register
    // block since C4(a) (doc/pta_error_model_design_note.md section 3, and the
    // CSR's own header for where the block sits and why not at 0x40).
    .i_pta_impair      (pta_impair),
    .i_pta_act_bits    (pta_act_bits),
    .i_pta_w_bits      (pta_w_bits),
    .i_pta_adc_bits    (pta_adc_bits),
    .i_pta_adc_shift   (pta_adc_shift),
    .i_pta_seed        (pta_seed),
    .i_pta_sigma_th    (pta_sigma_th),
    .i_pta_k_shot      (pta_k_shot),
    .i_pta_sigma_pr    (pta_sigma_pr),
    .i_pta_drift_sigma (pta_drift_sigma),
    .i_pta_drift_log2  (pta_drift_log2),
    .i_pta_drift_max   (pta_drift_max),
    .i_pta_xtalk       (pta_xtalk),
    .i_pta_model_rst   (pta_mrst),
    .o_pta_sat_count   (pta_sat_ct),
    .i_pta_cal_en      (pta_cal_en),
    .i_pta_cal_now     (pta_cal_now),
    .i_pta_cal_sched   (pta_cal_sched),
    .i_pta_cal_per     (pta_cal_per),
    .i_pta_cal_thr     (pta_cal_thr),
    .i_pta_cal_amp     (pta_cal_amp),
    .i_pta_cal_reps    (pta_cal_reps),
    .i_pta_cal_passes  (pta_cal_passes),
    .i_pta_cal_bank    (pta_cal_bank),
    .i_pta_trim_log2   (pta_trim_log2),
    .i_pta_trim_max    (pta_trim_max),
    .i_pta_cal_seed    (pta_cal_seed),
    .i_pta_aff_wen     (pta_aff_wen),
    .i_pta_aff_col     (pta_aff_col),
    .i_pta_aff_gain    (pta_aff_gain),
    .i_pta_aff_offs    (pta_aff_offs),
    .i_pta_cal_rst     (pta_crst),
    // The host's trim write port has no registers: the map has nowhere to put a
    // (bank, row, column, value) write, and inventing one is not C4(a)'s to do.
    // It exists for the parity gate and for a driver that restores a saved
    // calibration, and it stays tied off here.
    .i_pta_trim_wen    (1'b0),
    .i_pta_trim_bank   (1'b0),
    .i_pta_trim_row    ('0),
    .i_pta_trim_col    ('0),
    .i_pta_trim_data   (32'sd0),
    .o_pta_cal_busy    (pta_cal_busy),
    .o_pta_cal_valid   (pta_cal_valid),
    .o_pta_drift_alarm (pta_drift_alarm),
    .o_pta_cal_ct      (pta_cal_ct),
    .o_pta_cal_cyc     (pta_cal_cyc),
    .o_pta_err_max     (pta_err_max),
    .o_pta_err_found   (pta_err_found),
    .o_pta_shot_ct     (pta_shot_ct),
    .o_pta_wload_ct    (pta_wload_ct),
    .o_pta_cal_err     (pta_cal_err)
  );

  assign o_busy  = busy;
  assign o_done  = done;
  assign o_error = error;
  assign o_irq   = done;

endmodule
