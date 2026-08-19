// -----------------------------------------------------------------------------
// c930_npu_core.sv
//
// INT8 GEMM engine:  C[M x N] = A[M x K] * B[K x N],  INT8 in, INT32 acc.
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
  parameter int ACC_W    = 32,    // accumulator width
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
  output logic                        o_busy,
  output logic                        o_done,   // 1-cycle pulse
  output logic                        o_error,  // sticky, cleared on valid start

  // ---- Result readback ----
  input  logic [15:0]                 i_c_raddr,
  output logic signed [ACC_W-1:0]     o_c_rdata
);

  // ---------------------------------------------------------------------------
  // Operand / result buffers
  // ---------------------------------------------------------------------------
  logic signed [DIN_W-1:0] a_mem [0:MAX_M*MAX_K-1];   // A stored row-major, stride K
  logic signed [DIN_W-1:0] b_mem [0:MAX_K*MAX_N-1];   // B stored row-major, stride N
  logic signed [ACC_W-1:0] c_mem [0:MAX_M*MAX_N-1];   // C stored row-major, stride N

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
  localparam logic [1:0] S_IDLE  = 2'd0;
  localparam logic [1:0] S_WLOAD = 2'd1;
  localparam logic [1:0] S_RUN   = 2'd2;
  localparam logic [1:0] S_WRITE = 2'd3;
  logic [1:0] state;

  int m_reg;        // current output row
  int nt_reg;       // current N tile
  int kt_reg;       // current K tile
  int t;            // cycle counter within a systolic run
  int w_r, w_n;     // weight-load row/col counters
  int n_cnt;        // result write counter

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
          act[r*DIN_W +: DIN_W] = a_mem[m_reg*i_dim_k + k_base_reg + r];
      end
      // Column n's running accumulator pulses at cycle n (skew by n).
      for (int n = 0; n < NUM_COLS; n++) begin
        if (t == n)
          ps_in[n*ACC_W +: ACC_W] = acc[n];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Systolic array
  // ---------------------------------------------------------------------------
  logic signed [ACC_W*NUM_COLS-1:0] ps_out;   // flat; col c = bits [c*ACC_W +: ACC_W]

  c930_systolic_array #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (DIN_W),
    .ACC_W    (ACC_W)
  ) u_array (
    .i_clk    (i_clk),
    .i_rst_n  (i_rst_n),
    .i_wen    (state == S_WLOAD),
    .i_wrow   (w_r[$clog2(NUM_ROWS)-1:0]),
    .i_wcol   (w_n[$clog2(NUM_COLS)-1:0]),
    .i_wdata  (b_mem[(k_base_reg + w_r)*i_dim_n + n_base + w_n]),
    .i_act    (act),
    .i_ps_in  (ps_in),
    .o_ps_out (ps_out)
  );

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      state      <= S_IDLE;
      o_done     <= 1'b0;
      o_error    <= 1'b0;
      m_reg      <= 0;
      nt_reg     <= 0;
      kt_reg     <= 0;
      t          <= 0;
      w_r        <= 0;
      w_n        <= 0;
      n_cnt      <= 0;
      k_base_reg <= 0;
      kr_reg     <= 0;
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
              nt_reg     <= 0;
              kt_reg     <= 0;
              t          <= 0;
              w_r        <= 0;
              w_n        <= 0;
              n_cnt      <= 0;
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
            // last weight of this tile
            w_r   <= 0;
            w_n   <= 0;
            t     <= 0;
            state <= S_RUN;
          end else if (w_n == nc - 1) begin
            w_n <= 0;
            w_r <= w_r + 1;
          end else begin
            w_n <= w_n + 1;
          end
        end

        // Run one K tile: NUM_ROWS + NUM_COLS cycles. A partial tile (kr <
        // NUM_ROWS) must drain through the unused (zero-weight, zero-activation)
        // bottom rows before the result reaches the bottom edge.
        S_RUN: begin
          // Staggered capture: column (t - NUM_ROWS) finishes at cycle t.
          if (t >= NUM_ROWS)
            acc[t - NUM_ROWS] <= ps_out[(t - NUM_ROWS)*ACC_W +: ACC_W];

          if (t == NUM_ROWS + NUM_COLS - 1) begin
            t <= 0;
            if (kt_reg == num_k_tiles - 1) begin
              // all K tiles done for this (row, N tile) -> write results
              state <= S_WRITE;
              n_cnt <= 0;
            end else begin
              // next K tile (accumulator is kept across tiles)
              kt_reg <= kt_reg + 1;
              // Pre-register k_base and kr for the next S_WLOAD + S_RUN
              k_base_reg <= (kt_reg + 1) * NUM_ROWS;
              kr_reg     <= ((i_dim_k - (kt_reg + 1) * NUM_ROWS) >= NUM_ROWS) ?
                             NUM_ROWS : (i_dim_k - (kt_reg + 1) * NUM_ROWS);
              w_r    <= 0;
              w_n    <= 0;
              state  <= S_WLOAD;
            end
          end else begin
            t <= t + 1;
          end
        end

        // Write C[m_reg][n_base + n_cnt] = acc[n_cnt] for n_cnt in 0..nc-1.
        S_WRITE: begin
          c_mem[m_reg*i_dim_n + n_base + n_cnt] <= acc[n_cnt];
          if (n_cnt == nc - 1) begin
            n_cnt <= 0;
            if (nt_reg == num_n_tiles - 1) begin
              // last N tile for this row
              if (m_reg == i_dim_m - 1) begin
                o_done <= 1'b1;
                state  <= S_IDLE;
              end else begin
                m_reg      <= m_reg + 1;
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
