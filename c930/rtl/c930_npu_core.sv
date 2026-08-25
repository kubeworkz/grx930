// -----------------------------------------------------------------------------
// c930_npu_core.sv
//
// INT8/INT16/FP16/BF16 GEMM engine:  C[M x N] = A[M x K] * B[K x N]
//
// The datapath is a weight-stationary systolic array (c930_systolic_array).
// This controller:
//   * preloads A and B into small internal buffers (data-plane ports),
//   * loops over output rows M, N-tiles of NUM_COLS each, and K-tiles of
//     NUM_ROWS each,
//   * generates the activation skew (row k pulses at cycle k) and the
//     accumulator skew (column n pulses at cycle n),
//   * captures the bottom-edge outputs in a staggered window,
//   * writes the results to the C buffer.
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
  parameter int MAX_N    = 8      // max output cols (tiled over NUM_COLS passes)
)
(
  input  logic                        i_clk,
  input  logic                        i_rst_n,

  // ---- Data-plane preload / readback (attached to a DMA or debug bus) ----
  input  logic                        i_wen,    // preload write enable
  input  logic                        i_wsel,   // 0 = A, 1 = B
  input  logic [15:0]                 i_waddr,
  input  logic signed [DIN_W-1:0]     i_wdata,

  // ---- Control ----
  input  logic                        i_start,  // 1-cycle pulse, sampled in IDLE
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
  output logic [31:0]                 o_stall_count   // cycles stalled (S_WLOAD or stall)
);

  // ---------------------------------------------------------------------------
  // Operand / result buffers
  // ---------------------------------------------------------------------------
  logic signed [DIN_W-1:0] a_mem [0:MAX_M*MAX_K-1];   // A stored row-major, stride K
  logic signed [DIN_W-1:0] b_mem [0:MAX_K*MAX_N-1];   // B stored row-major, stride N
  logic signed [31:0]      c_mem [0:MAX_M*MAX_N-1];   // C stored row-major, stride N (32-bit)

  assign o_c_rdata = c_mem[i_c_raddr];

  // Preload A/B (blocked while the engine is running)
  always_ff @(posedge i_clk) begin
    if (i_wen && !o_busy) begin
      if (i_wsel) b_mem[i_waddr] <= i_wdata;
      else        a_mem[i_waddr] <= i_wdata;
    end
  end

  // ---------------------------------------------------------------------------
  // Control FSM state and counters
  // ---------------------------------------------------------------------------
  // localparam state encoding (avoids iverilog's enum-label-in-port quirk)
  localparam logic [2:0] S_IDLE    = 3'd0;
  localparam logic [2:0] S_WLOAD   = 3'd1;
  localparam logic [2:0] S_PRELOAD = 3'd2;  // preload next tile into inactive bank
  localparam logic [2:0] S_RUN     = 3'd3;
  localparam logic [2:0] S_WRITE   = 3'd4;
  logic [2:0] state;

  int m_reg;        // current output row
  int m_base;       // pre-computed m_reg * i_dim_k (breaks multiply from critical path)
  int nt_reg;       // current N tile
  int kt_reg;       // current K tile
  int t;            // cycle counter within a systolic run
  int w_r, w_n;     // weight-load row/col counters
  int n_cnt;        // result write counter

  // Double-buffering: bank_sel toggles between 0/1; preload registers
  // drive weight loading during S_RUN so the next tile's weights are
  // ready when S_RUN finishes.
  logic        bank_sel;           // which weight bank is active for compute
  logic        preload_en;        // 1 while preloading next tile's weights during S_RUN
  logic        preload_done;      // 1 when preload for next tile completed
  int  preload_w_r, preload_w_n;  // preload address counters
  int  preload_kr;                // kr for the next K tile being preloaded

  logic signed [ACC_W-1:0] acc [0:NUM_COLS-1];   // running accumulator per column

  // Combinational helpers
  int  n_base;          // nt_reg * NUM_COLS
  int  nc;              // columns actually used in the current N tile
  int  num_k_tiles;     // ceil(K / NUM_ROWS)
  int  num_n_tiles;     // ceil(N / NUM_COLS)
  logic dims_ok;

  assign n_base      = nt_reg * NUM_COLS;
  assign nc          = (i_dim_n - n_base >= NUM_COLS) ? NUM_COLS : (i_dim_n - n_base);
  assign num_k_tiles = (i_dim_k + NUM_ROWS - 1) / NUM_ROWS;
  assign num_n_tiles = (i_dim_n + NUM_COLS - 1) / NUM_COLS;
  assign dims_ok     = (i_dim_m >= 1) && (i_dim_m <= MAX_M) &&
                       (i_dim_n >= 1) && (i_dim_n <= MAX_N)  &&
                       (i_dim_k >= 1) && (i_dim_k <= MAX_K);

  assign o_busy = (state != S_IDLE);

  // ---------------------------------------------------------------------------
  // Performance counters
  // ---------------------------------------------------------------------------
  logic [31:0] cycle_cnt, op_cnt, stall_cnt;
  assign o_cycle_count = cycle_cnt;
  assign o_op_count    = op_cnt;
  assign o_stall_count = stall_cnt;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      cycle_cnt <= 32'd0;
      op_cnt    <= 32'd0;
      stall_cnt <= 32'd0;
    end else begin
      if (state != S_IDLE)
        cycle_cnt <= cycle_cnt + 1;
      if (state == S_IDLE && i_start) begin
        cycle_cnt <= 32'd0;
        op_cnt    <= 32'd0;
        stall_cnt <= 32'd0;
      end
      // Count PE MAC operations: all PEs fire each cycle during S_RUN.
      // NUM_ROWS * NUM_COLS = 64 PEs, each doing one MAC per cycle.
      if (state == S_RUN)
        op_cnt <= op_cnt + NUM_ROWS * NUM_COLS;
      // Count stall cycles (S_WLOAD = weight loading, not compute)
      if (state == S_WLOAD)
        stall_cnt <= stall_cnt + 1;
    end
  end

  // Registered K-tile helpers: k_base and kr are computed at the START of each
  // K tile (end of the previous tile) and held stable for the whole S_WLOAD +
  // S_RUN sequence.  This breaks the 32-bit subtraction carry chain
  // (i_dim_k - k_base) off the critical path to the PE datapath.
  int  k_base_reg;      // kt_reg * NUM_ROWS, registered
  int  kr_reg;          // min(NUM_ROWS, i_dim_k - k_base), registered

  // ---------------------------------------------------------------------------
  // Systolic-array feed (combinational): skew generation
  // ---------------------------------------------------------------------------
  logic signed [NUM_ROWS*DIN_W-1:0] act;    // row r in bits [r*DIN_W +: DIN_W]
  logic signed [NUM_COLS*ACC_W-1:0] ps_in;  // col n in bits [n*ACC_W +: ACC_W]

  always_comb begin
    act   = '0;
    ps_in = '0;

    if (state == S_RUN) begin
      // Row r's activation A[m][k_base_reg + r] pulses at cycle r (skew by r).
      // Uses registered k_base_reg and kr_reg to keep the subtraction carry
      // chain off the PE critical path.
      for (int r = 0; r < NUM_ROWS; r++) begin
        if ((t == r) && (r < kr_reg))
          act[r*DIN_W +: DIN_W] = a_mem[m_base + k_base_reg + r];  // m_base pre-computed
      end
      // Column n's running accumulator pulses at cycles n and n+1 (skew by n).
      // The 2-cycle pulse is needed because the PE registers the product before
      // the accumulator; PE(0,c) captures ps_in at the first pulse and the
      // accumulator uses the registered product at the second pulse.
      for (int n = 0; n < NUM_COLS; n++) begin
        if (t == n || t == n + 1)
          ps_in[n*ACC_W +: ACC_W] = acc[n];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Systolic array
  // ---------------------------------------------------------------------------
  logic signed [ACC_W*NUM_COLS-1:0] ps_out;   // flat; col c = bits [c*ACC_W +: ACC_W]

  // Weight load mux: during S_WLOAD use main counters, during S_RUN use preload counters
  logic        w_load_active;
  logic        w_load_bank;
  logic [$clog2(NUM_ROWS)-1:0] w_load_row;
  logic [$clog2(NUM_COLS)-1:0] w_load_col;
  logic signed [DIN_W-1:0]     w_load_data;

  assign w_load_active = (state == S_WLOAD) || preload_en;
  assign w_load_bank   = preload_en ? ~bank_sel : bank_sel;
  assign w_load_row    = preload_en ? preload_w_r[$clog2(NUM_ROWS)-1:0] : w_r[$clog2(NUM_ROWS)-1:0];
  assign w_load_col    = preload_en ? preload_w_n[$clog2(NUM_COLS)-1:0] : w_n[$clog2(NUM_COLS)-1:0];
  assign w_load_data   = preload_en ?
                         b_mem[((kt_reg+1)*NUM_ROWS + preload_w_r)*i_dim_n + n_base + preload_w_n] :
                         b_mem[(k_base_reg + w_r)*i_dim_n + n_base + w_n];

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
    .i_precision(i_precision)
  );

  // ---------------------------------------------------------------------------
  // FSM  (double-buffered: preload next K tile during S_RUN)
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      state       <= S_IDLE;
      o_done      <= 1'b0;
      o_error     <= 1'b0;
      m_reg       <= 0;
      nt_reg      <= 0;
      kt_reg      <= 0;
      t           <= 0;
      w_r         <= 0;
      w_n         <= 0;
      n_cnt       <= 0;
      k_base_reg  <= 0;
      kr_reg      <= 0;
      bank_sel    <= 1'b0;
      preload_en  <= 1'b0;
      preload_done <= 1'b0;
      preload_w_r <= 0;
      preload_w_n <= 0;
      preload_kr  <= 0;
      for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
    end else begin
      o_done <= 1'b0;

      case (state)

        S_IDLE: begin
          if (i_start) begin
            if (!dims_ok) begin
              o_error <= 1'b1;          // stay IDLE
            end else begin
              o_error    <= 1'b0;
              m_reg      <= 0;
              m_base     <= 0;  // pre-computed m_reg * i_dim_k
              nt_reg     <= 0;
              kt_reg     <= 0;
              t          <= 0;
              w_r        <= 0;
              w_n        <= 0;
              n_cnt      <= 0;
              bank_sel    <= 1'b0;
              preload_en  <= 1'b0;
              preload_done <= 1'b0;
              // Pre-register first K tile: k_base=0, kr=min(NUM_ROWS, dim_k)
              k_base_reg <= 0;
              kr_reg     <= (i_dim_k >= NUM_ROWS) ? NUM_ROWS : i_dim_k;
              for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
              state      <= S_WLOAD;
            end
          end
        end

        // Load B[k_base + w_r][n_base + w_n] into PE(w_r, w_n), one per cycle.
        // Only the nc active columns of this N tile are loaded.
        S_WLOAD: begin
          if ((w_n == nc - 1) && (w_r == kr_reg - 1)) begin
            // last weight of this tile -- start preloading next K tile
            w_r   <= 0;
            w_n   <= 0;
            t     <= 0;
            if (kt_reg + 1 < num_k_tiles) begin
              // Preload next tile's weights into inactive bank
              preload_en  <= 1'b1;
              preload_w_r <= 0;
              preload_w_n <= 0;
              preload_kr  <= ((i_dim_k - (kt_reg + 1) * NUM_ROWS) >= NUM_ROWS) ?
                             NUM_ROWS : (i_dim_k - (kt_reg + 1) * NUM_ROWS);
              state <= S_PRELOAD;  // run preload before S_RUN
            end else begin
              state <= S_RUN;  // last tile, no preload needed
            end
          end else if (w_n == nc - 1) begin
            w_n <= 0;
            w_r <= w_r + 1;
          end else begin
            w_n <= w_n + 1;
          end
        end

        // Preload next K tile's weights into inactive bank.
        // Runs for preload_kr * nc cycles using the same write port as S_WLOAD
        // but targeting the other bank.
        S_PRELOAD: begin
          if ((preload_w_n == nc - 1) && (preload_w_r == preload_kr - 1)) begin
            // preload done -- start compute
            preload_en   <= 1'b0;
            preload_done <= 1'b1;
            t <= 0;
            state <= S_RUN;
          end else if (preload_w_n == nc - 1) begin
            preload_w_n <= 0;
            preload_w_r <= preload_w_r + 1;
          end else begin
            preload_w_n <= preload_w_n + 1;
          end
        end

        // Run one K tile: NUM_ROWS + NUM_COLS + 1 cycles.
        S_RUN: begin
          // Staggered capture: column (t - NUM_ROWS - 1) finishes at cycle t.
          if (t >= NUM_ROWS + 1)
            acc[t - NUM_ROWS - 1] <= ps_out[(t - NUM_ROWS - 1)*ACC_W +: ACC_W];

          if (t == NUM_ROWS + NUM_COLS) begin
            t <= 0;
            if (kt_reg == num_k_tiles - 1) begin
              // all K tiles done for this (row, N tile) -> write results
              state <= S_WRITE;
              n_cnt <= 0;
              preload_en <= 1'b0;  // stop any preload
            end else begin
              // next K tile: swap banks (weights were preloaded in S_PRELOAD)
              kt_reg <= kt_reg + 1;
              bank_sel <= ~bank_sel;
              preload_done <= 1'b0;
              // Update k_base and kr for the new tile
              k_base_reg <= (kt_reg + 1) * NUM_ROWS;
              kr_reg     <= ((i_dim_k - (kt_reg + 1) * NUM_ROWS) >= NUM_ROWS) ?
                             NUM_ROWS : (i_dim_k - (kt_reg + 1) * NUM_ROWS);
              w_r <= 0;
              w_n <= 0;
              // Start preloading the tile AFTER next (if it exists)
              if (kt_reg + 2 < num_k_tiles) begin
                preload_en  <= 1'b1;
                preload_w_r <= 0;
                preload_w_n <= 0;
                preload_kr  <= ((i_dim_k - (kt_reg + 2) * NUM_ROWS) >= NUM_ROWS) ?
                               NUM_ROWS : (i_dim_k - (kt_reg + 2) * NUM_ROWS);
                state <= S_PRELOAD;  // preload next-next tile before S_RUN
              end else begin
                preload_en <= 1'b0;
                state <= S_RUN;  // no more tiles to preload, go directly to S_RUN
              end
            end
          end else begin
            t <= t + 1;
          end
        end

        // Write C[m_reg][n_base + n_cnt] = acc[n_cnt] for n_cnt in 0..nc-1.
        // For FP16/BF16 modes, acc[n_cnt] is in FP32 format (zero-extended to ACC_W).
        // For INT8/INT16, acc[n_cnt] is in integer format.
        S_WRITE: begin
          c_mem[m_reg*i_dim_n + n_base + n_cnt] <= acc[n_cnt][31:0];
          if (n_cnt == nc - 1) begin
            n_cnt <= 0;
            if (nt_reg == num_n_tiles - 1) begin
              // last N tile for this row
              if (m_reg == i_dim_m - 1) begin
                o_done <= 1'b1;
                state  <= S_IDLE;
              end else begin
                m_reg      <= m_reg + 1;
                m_base     <= (m_reg + 1) * i_dim_k;  // pre-compute for next M-row
                nt_reg     <= 0;
                kt_reg     <= 0;
                k_base_reg <= 0;
                kr_reg     <= (i_dim_k >= NUM_ROWS) ? NUM_ROWS : i_dim_k;
                w_r        <= 0;
                w_n        <= 0;
                for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
                state      <= S_WLOAD;
              end
            end else begin
              // next N tile (same row): fresh accumulator
              nt_reg     <= nt_reg + 1;
              kt_reg     <= 0;
              k_base_reg <= 0;
              kr_reg     <= (i_dim_k >= NUM_ROWS) ? NUM_ROWS : i_dim_k;
              w_r        <= 0;
              w_n        <= 0;
              for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
              state      <= S_WLOAD;
            end
          end else begin
            n_cnt <= n_cnt + 1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
