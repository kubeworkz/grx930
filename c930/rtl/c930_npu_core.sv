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
  output logic [31:0]                 o_arow_stall_count // cycles starved of A rows
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
  logic signed [DIN_W-1:0] a_mem_0 [0:A_DEPTH-1];
  logic signed [DIN_W-1:0] a_mem_1 [0:A_DEPTH-1];
  logic signed [DIN_W-1:0] b_mem_0 [0:B_DEPTH-1];
  logic signed [DIN_W-1:0] b_mem_1 [0:B_DEPTH-1];

  // C matrix: inferred as Block RAM when synthesis tool supports it.
  // For MAX_M=8/MAX_N=12 (SoC defaults): 384 bytes, fits in LUTRAM.
  // For MAX_M=64/MAX_N=8 (200T): maps to RAMB18K blocks.
  // Combinational read (OPREG disabled on Xilinx BRAMs) preserves the
  // existing DMA timing — no extra wait states needed.
  //
  // Widened from 32 to ACC_W bits.  Under the m-inner loop order the running
  // K accumulation lives here between K tiles rather than in acc[], and an
  // INT16 x INT16 reduction over MAX_K=256 needs 39 bits.  Truncation to 32
  // happens only on readback, exactly where it happened before.
  (* ram_style = "block" *) logic signed [ACC_W-1:0] c_mem [0:MAX_M*MAX_N-1];

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

  always_ff @(posedge i_clk) begin
    if (write_a) begin
      if (write_bank) a_mem_1[write_addr] <= write_data;
      else            a_mem_0[write_addr] <= write_data;
    end
    if (write_b) begin
      if (write_bank) b_mem_1[write_addr] <= write_data;
      else            b_mem_0[write_addr] <= write_data;
    end
    // Wide port assigned after the narrow one so that if both ever named the
    // same element in the same cycle the bulk load would win.  They target
    // disjoint regions today: the wide port carries A rows 1..M-1 during
    // compute and the whole of A row 0 / B before it, the narrow port carries
    // staging and INT4.
    if (i_wwen) begin
      for (int l = 0; l < WR_LANES; l++) begin
        // i_wwmask is what keeps lane l inside the array on a tail beat: the
        // DMA masks off lanes past the end of the row (or of B), so the
        // addresses below never run past the last valid element.  Each index
        // is sized to its own array so the add cannot wrap wider than the
        // memory it addresses.
        if (i_wwmask[l]) begin
          if (!i_wwsel) begin
            if (i_wwbank) a_mem_1[A_AW'(i_wwaddr + 16'(l))] <= i_wwdata[l*DIN_W +: DIN_W];
            else          a_mem_0[A_AW'(i_wwaddr + 16'(l))] <= i_wwdata[l*DIN_W +: DIN_W];
          end else begin
            if (i_wwbank) b_mem_1[B_AW'(i_wwaddr + 16'(l))] <= i_wwdata[l*DIN_W +: DIN_W];
            else          b_mem_0[B_AW'(i_wwaddr + 16'(l))] <= i_wwdata[l*DIN_W +: DIN_W];
          end
        end
      end
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
  logic [2:0] state;

  int m_reg;        // current output row
  int m_base;       // pre-computed m_reg * i_dim_k (breaks multiply from critical path)
  int nt_reg;       // current N tile
  int kt_reg;       // current K tile
  int t;            // cycle counter within a systolic run
  int w_r, w_n;     // weight-load row/col counters
  int n_cnt;        // result write counter

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

  assign o_busy = (state != S_IDLE);

  // ---------------------------------------------------------------------------
  // o_done: separated from FSM always_ff to break t[25] critical path.
  // yosys shares FSM state-decode logic between state_next (which uses t)
  // and o_done_next in the same always_ff block, creating a t[25] -> o_done
  // chain.  Computing o_done from a dedicated combinational cone that depends
  // only on registered state/counters (not t) breaks this path.
  // ---------------------------------------------------------------------------
  logic done_cond;
  assign done_cond = (state == S_WRITE) &&
                     (n_cnt  == nc - 1) &&
                     (m_reg  == i_dim_m - 1) &&
                     (kt_reg == num_k_tiles - 1) &&
                     (nt_reg == num_n_tiles - 1);

  // ---------------------------------------------------------------------------
  // Performance counters
  // ---------------------------------------------------------------------------
  // See the i_a_rows_ready port comment: 0 disables the interlock entirely.
  wire arow_free = (i_a_rows_ready == 16'd0);

  logic [31:0] cycle_cnt, op_cnt, stall_cnt, arow_stall_cnt;
  assign o_cycle_count      = cycle_cnt;
  assign o_op_count         = op_cnt;
  assign o_stall_count      = stall_cnt;
  assign o_arow_stall_count = arow_stall_cnt;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      cycle_cnt      <= 32'd0;
      op_cnt         <= 32'd0;
      stall_cnt      <= 32'd0;
      arow_stall_cnt <= 32'd0;
    end else begin
      if (state != S_IDLE)
        cycle_cnt <= cycle_cnt + 1;
      if (state == S_IDLE && i_start) begin
        cycle_cnt      <= 32'd0;
        op_cnt         <= 32'd0;
        stall_cnt      <= 32'd0;
        arow_stall_cnt <= 32'd0;
      end
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
      if (state == S_WLOAD || state == S_ACCLD)
        stall_cnt <= stall_cnt + 1;
      // Kept separate from stall_cnt so the accounting identity in
      // doc/c930_architecture.md still decomposes: weight movement and
      // operand starvation are different problems with different fixes.
      if (state == S_AROW)
        arow_stall_cnt <= arow_stall_cnt + 1;
    end
  end

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

  always_comb begin
    act_comb   = '0;
    ps_in_comb = '0;

    if (state == S_RUN) begin
      // Row r's activation A[m][k_base_reg + r] pulses at cycle r (skew by r).
      for (int r = 0; r < NUM_ROWS; r++) begin
        if ((t == 2*r) && (r < kr_reg))
          act_comb[r*DIN_W +: DIN_W] = i_bank_sel ? a_mem_1[m_base + k_base_reg + r] :
                                                       a_mem_0[m_base + k_base_reg + r];
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
  logic        w_load_bank;
  logic [$clog2(NUM_ROWS)-1:0] w_load_row;
  logic [$clog2(NUM_COLS)-1:0] w_load_col;
  logic signed [DIN_W-1:0]     w_load_data;

  assign w_load_active = (state == S_WLOAD);
  assign w_load_bank   = bank_sel;
  assign w_load_row    = w_r[$clog2(NUM_ROWS)-1:0];
  assign w_load_col    = w_n[$clog2(NUM_COLS)-1:0];
  // Double-buffered B read: select bank via b_bank_sel (snapshot of
  // i_bank_sel captured at GEMM start, see comment above).
  logic signed [DIN_W-1:0] b_read_data;
  wire [15:0] b_read_addr = (k_base_reg + w_r)*i_dim_n + n_base + w_n;
  assign b_read_data = b_bank_sel ? b_mem_1[b_read_addr] : b_mem_0[b_read_addr];
  assign w_load_data = b_read_data;

  // Rows of the array that belong to the current K tile.  The rest hold stale
  // weights, which the float modes must not multiply (c930_tensor_pe).
  logic [NUM_ROWS-1:0] row_en;
  always_comb
    for (int r = 0; r < NUM_ROWS; r++) row_en[r] = (r < kr_reg);

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
      k_base_reg  <= 0;
      kr_reg      <= 0;
      bank_sel    <= 1'b0;
      b_bank_sel  <= 1'b0;
      for (int n = 0; n < NUM_COLS; n++) acc[n] <= '0;
    end else begin
      o_done <= done_cond;

      // No more A rows will land once the DMA gives up, so S_AROW would wait
      // forever -- and a core left waiting wakes up when the next GEMM's rows
      // arrive and computes them into this one.
      if (i_abort)
        state <= S_IDLE;
      else
      case (state)

        S_IDLE: begin
          if (i_start) begin
            if (!dims_ok) begin
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
          if ((w_n == nc - 1) && (w_r == kr_reg - 1)) begin
            w_r    <= 0;
            w_n    <= 0;
            t      <= 0;
            n_cnt  <= 0;
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
            state <= S_WRITE;
          end else begin
            t <= t + 1;
          end
          end // hop_phase
        end

        // Write C[m_reg][n_base + n_cnt] = acc[n_cnt] for n_cnt in 0..nc-1.
        // acc[] already holds the running sum through this K tile, so this is
        // a plain store, not a read-modify-write.
        S_WRITE: begin
          c_mem[c_idx] <= acc[n_cnt];
          if (n_cnt == nc - 1) begin
            n_cnt <= 0;
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
              if (arow_free || (m_reg + 1) < i_a_rows_ready)
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
          end else begin
            n_cnt <= n_cnt + 1;
          end
        end

        // Hold until the DMA has unpacked the row this pass needs.  Entered
        // only on an output-row advance; m_reg has already advanced, so the
        // test is against the row about to be read.  Resumes into whichever
        // state the row advance was headed for.
        S_AROW: begin
          if (arow_free || m_reg < i_a_rows_ready)
            state <= (kt_reg == 0) ? S_RUN : S_ACCLD;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
