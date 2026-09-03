// -----------------------------------------------------------------------------
// c930_npu_dma.sv
//
// AXI4 full master for the NPU data plane. On START it autonomously:
//
//   1. P_READ_A   : burst-read A (M*K packed INT8) from A_BASE and stream the
//                   bytes into the core's A buffer via the preload port.
//   2. P_READ_B   : burst-read B (K*N packed INT8) from B_BASE likewise.
//   3. P_LAUNCH   : pulse the core's start and wait for its done.
//   4. P_WRITE_C  : burst-write C (M*N INT32 words) to C_BASE.
//   5. P_DONE     : pulse o_done.
//
// A and B are packed little-endian, 4 INT8 per 32-bit beat, row-major:
//   A byte (m*K + k) lives at beat (m*K + k)/4, lane (m*K + k)%4.
//   B byte (k*N + n) lives at beat (k*N + n)/4, lane (k*N + n)%4.
// C is one INT32 per 32-bit beat: beat (m*N + n).
//
// Bursts are INCR with 4-byte beats. The R channel is back-pressured while a
// beat's 8 bytes are unpacked into the core (one byte per cycle), so the read
// rate is naturally throttled by the unpacking rate.
// -----------------------------------------------------------------------------
module c930_npu_dma
#(
  parameter int AXI_ADDR_W = 32,
  parameter int AXI_DATA_W = 64,
  parameter int DIN_W      = 16,
  parameter int ACC_W      = 48,    // 48-bit fixed-point accumulator
  parameter int MAX_M      = 64,
  parameter int MAX_K      = 256,
  parameter int MAX_N      = 8
)
(
  input  logic        i_clk,
  input  logic        i_rst_n,

  // ---- Control (from the CSR via the top) ----
  input  logic        i_start,
  input  logic [15:0] i_dim_m,
  input  logic [15:0] i_dim_n,
  input  logic [15:0] i_dim_k,
  input  logic [31:0] i_a_base,
  input  logic [31:0] i_b_base,
  input  logic [31:0] i_c_base,
  input  logic [2:0]  i_precision,   // 0=INT8, 1=INT16, 4=INT4

  // ---- Next GEMM params (from CSR FIFO head, for cross-GEMM prefetch) ----
  input  logic        i_next_valid,
  input  logic [15:0] i_next_dim_m,
  input  logic [15:0] i_next_dim_n,
  input  logic [15:0] i_next_dim_k,
  input  logic [31:0] i_next_a_base,
  input  logic [31:0] i_next_b_base,
  input  logic [31:0] i_next_c_base,
  input  logic [2:0]  i_next_precision,

  // ---- Status (to the CSR / top) ----
  output logic        o_busy,
  output logic        o_done,
  output logic        o_error,
  output logic [31:0] o_dma_cycle_count,  // cycles while DMA busy (phase != P_IDLE)
  output logic [31:0] o_dma_last_count,   // latched cycle count from last completed GEMM
  output logic        o_bank_sel,        // bank select for double-buffered A/B memories

  // ---- Core data plane + control ----
  output logic                    o_wen,       // preload write enable
  output logic                    o_wsel,      // 0 = A, 1 = B
  output logic                    o_wbank,     // which bank to write: 0=bank0, 1=bank1
  output logic [15:0]             o_waddr,
  output logic signed [DIN_W-1:0] o_wdata,

  // ---- Staging buffer load (PF2 prefetch → core a_mem/b_mem) ----
  output logic                    o_staging_wen,    // staging write enable
  output logic                    o_staging_wsel,   // 0 = A, 1 = B
  output logic [15:0]             o_staging_waddr,
  output logic signed [DIN_W-1:0] o_staging_wdata,

  output logic                    o_core_start,
  input  logic                    i_core_done,
  input  logic                    i_core_error,
  output logic [15:0]             o_c_raddr,
  input  logic signed [31:0]      i_c_rdata,   // always 32-bit (normalized by core)

  // ---- AXI4 master: read address ----
  output logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,

  // ---- AXI4 master: read data ----
  input  logic [AXI_DATA_W-1:0] m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready,

  // ---- AXI4 master: write address ----
  output logic [AXI_ADDR_W-1:0] m_axi_awaddr,
  output logic [7:0]            m_axi_awlen,
  output logic [2:0]            m_axi_awsize,
  output logic [1:0]            m_axi_awburst,
  output logic                  m_axi_awvalid,
  input  logic                  m_axi_awready,

  // ---- AXI4 master: write data ----
  output logic [AXI_DATA_W-1:0] m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
  output logic                  m_axi_wlast,
  output logic                  m_axi_wvalid,
  input  logic                  m_axi_wready,

  // ---- AXI4 master: write response ----
  input  logic [1:0]            m_axi_bresp,
  input  logic                  m_axi_bvalid,
  output logic                  m_axi_bready
);

  localparam int BYTES_PER_BEAT = AXI_DATA_W / 8;   // 8
  localparam [2:0] BEAT_SIZE    = $clog2(BYTES_PER_BEAT);  // 3 -> 8 bytes/beat

  // Precision-dependent element size: INT4=0.5 byte, INT8=1 byte, INT16=2 bytes
  logic [3:0] elem_size;   // 1 for INT8, 2 for INT16, 0 for INT4 (special case)
  int  elems_per_beat;     // 16 for INT4, 8 for INT8, 4 for INT16
  logic is_int4;           // 1 if precision == 4 (INT4 mode)

  // ---- Phases ----
  localparam [2:0] P_IDLE    = 3'd0;
  localparam [2:0] P_READ_A  = 3'd1;
  localparam [2:0] P_READ_B  = 3'd2;
  localparam [2:0] P_LAUNCH  = 3'd3;
  localparam [2:0] P_WRITE_C = 3'd4;
  localparam [2:0] P_DONE    = 3'd5;
  localparam [2:0] P_STAGING = 3'd6;  // load PF2 staging buffer into core

  // ---- Read sub-states ----
  localparam [1:0] RS_AR     = 2'd0;
  localparam [1:0] RS_R      = 2'd1;
  localparam [1:0] RS_UNPACK = 2'd2;

  // ---- Write sub-states ----
  localparam [2:0] WS_AW    = 3'd0;  // issue AXI write address
  localparam [2:0] WS_ADDR  = 3'd1;  // set core C read address
  localparam [2:0] WS_DATA  = 3'd2;  // latch C value (high or low)
  localparam [2:0] WS_PACK  = 3'd3;  // pack second C value into high word
  localparam [2:0] WS_DRIVE = 3'd4;  // drive AXI write data
  localparam [2:0] WS_B     = 3'd5;  // wait for write response

  logic [2:0] phase;
  logic [1:0] rd_sub;
  logic [2:0] wr_sub;
  logic       bank_sel;    // double-buffer bank select: 0=bank0, 1=bank1
  assign o_bank_sel = bank_sel;

  logic [15:0] dm, dn, dk;
  logic [31:0] a_base_r, b_base_r, c_base_r;

  // ---- Staging load state ----
  logic        staging_load_a;   // 1 = loading A from staging, 0 = loading B
  int  staging_cnt;              // elements loaded so far
  int  staging_total;            // total elements to load (dk for A, dk*dn for B)
  logic staging_ready;           // 1 when staging buffers have valid data (from PF2)

  int  elem_cnt;      // bytes (A/B read) or words (C write) this phase
  int  total_elems;   // total A/B elements (M*K or K*N) for bounds check
  int  rd_beats;      // ceil(elem_cnt / BYTES_PER_BEAT) for reads
  int  rd_beat;       // read beats received so far
  int  flat_idx;      // flat element index into the A/B buffer
  int  unpack_idx;    // 0..BYTES_PER_BEAT-1 within the current beat
  int  c_idx;         // C element index
  int  c_beat;        // AXI beat counter for C writes
  logic [31:0] c_lo;  // low 32 bits of packed pair
  logic        c_odd; // last beat is odd (wstrb = 0x0F)
  logic [AXI_DATA_W-1:0] rword;
  logic [AXI_DATA_W-1:0] wdata_reg;
  logic wsel_reg;     // 0 = reading A, 1 = reading B
  logic launched;

  // ---- Core timeout watchdog ----
  // If i_core_done does not fire within dm*dn*dk*2 cycles of o_core_start,
  // the core is hung.  Raise o_error and abort to prevent infinite stalls.
  int  watchdog_cnt;       // countdown, armed when core starts
  int  watchdog_limit;     // dm * dn * dk * 2 (loaded in P_IDLE)
  logic watchdog_active;   // 1 while counting down in P_LAUNCH

  // ---- DDR read timeout watchdog ----
  // If m_axi_rvalid does not fire within DDR_TIMEOUT_CYCLES of an accepted
  // AR (m_axi_arvalid && m_axi_arready), the DDR/memory subsystem is hung.
  localparam int DDR_TIMEOUT_CYCLES = 1024;
  int  ddr_timeout_cnt;    // countdown after AR accepted
  logic ddr_timeout_active; // 1 while waiting for first rvalid after AR

  // ---- Prefetch sub-state machine (double-buffered A reads) ----
  // While the core computes row 0, the DMA prefetches rows 1..M-1 of A
  // into a_mem, overlapping DDR reads with systolic compute.
  localparam [1:0] PF_IDLE = 2'd0;
  localparam [1:0] PF_AR   = 2'd1;
  localparam [1:0] PF_R    = 2'd2;
  localparam [1:0] PF_UNPK = 2'd3;
  logic [1:0] pf_state;
  int  pf_row;           // next row to prefetch (1..dm-1)
  int  pf_flat_idx;      // element index within the row
  int  pf_rd_beat;       // beats received for current prefetch
  int  pf_unpack_idx;    // byte index within beat
  int  pf_rd_beats;      // total beats per row (computed in P_IDLE)
  logic [AXI_DATA_W-1:0] pf_rword;  // latched read word for prefetch

  // ---- Next-GEMM registers (captured from CSR FIFO head) ----
  // Loaded when the DMA is idle and a new GEMM is dispatched.
  // Used during P_WRITE_C to prefetch the next GEMM's A/B via AXI read.
  logic        next_valid;
  logic [15:0] next_dm, next_dn, next_dk;
  logic [31:0] next_a_base, next_b_base, next_c_base;
  logic [2:0]  next_precision;

  // ---- Staging buffer for next GEMM's first row of A and B ----
  // A staging: MAX_K elements (enough for one row of A)
  // B staging: MAX_K * MAX_N elements (enough for one row-block of B)
  logic signed [DIN_W-1:0] next_a_buf [0:MAX_K-1];
  logic signed [DIN_W-1:0] next_b_buf [0:MAX_K*MAX_N-1];
  logic        next_a_ready;   // 1 when staging buffer has valid A data
  logic        next_b_ready;   // 1 when staging buffer has valid B data
  logic        staging_load;   // pulse to load staging buffer into core
  logic        next_captured;  // 1-cycle deferred capture of i_next_* params
  logic        bank_sel_pending;  // deferred bank_sel toggle (1-cycle delay)

  // ---- Cross-GEMM prefetch sub-states ----
  localparam [1:0] PF2_IDLE = 2'd0;
  localparam [1:0] PF2_AR   = 2'd1;
  localparam [1:0] PF2_R    = 2'd2;
  localparam [1:0] PF2_UNPK = 2'd3;
  logic [1:0] pf2_state;
  int  pf2_row;           // 0 = reading A row 0, 1 = reading B row 0
  int  pf2_flat_idx;
  int  pf2_rd_beat;
  int  pf2_unpack_idx;
  int  pf2_rd_beats;
  logic [AXI_DATA_W-1:0] pf2_rword;
  logic pf2_reading_a;    // 1 = reading A, 0 = reading B

  logic dims_ok;
  assign dims_ok = (i_dim_m >= 1) && (i_dim_m <= MAX_M) &&
                   (i_dim_n >= 1) && (i_dim_n <= MAX_N) &&
                   (i_dim_k >= 1) && (i_dim_k <= MAX_K);

  assign o_busy = (phase != P_IDLE);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      phase         <= P_IDLE;
      rd_sub        <= RS_AR;
      wr_sub        <= WS_AW;
      bank_sel      <= 1'b0;
      o_done        <= 1'b0;
      o_error       <= 1'b0;
      o_dma_cycle_count <= 32'd0;
      o_dma_last_count  <= 32'd0;
      o_wen         <= 1'b0;
      o_wbank       <= 1'b0;
      o_staging_wen <= 1'b0;
      o_core_start  <= 1'b0;
      launched      <= 1'b0;
      watchdog_cnt    <= 0;
      watchdog_limit  <= 0;
      watchdog_active <= 1'b0;
      ddr_timeout_cnt    <= 0;
      ddr_timeout_active <= 1'b0;
      pf_state      <= PF_IDLE;
      pf_row        <= 1;
      pf2_state     <= PF2_IDLE;
      pf2_row       <= 0;
      next_valid    <= 1'b0;
      next_a_ready  <= 1'b0;
      next_b_ready  <= 1'b0;
      staging_load_a <= 1'b0;
      staging_cnt    <= 0;
      staging_total  <= 0;
      staging_ready  <= 1'b0;
      next_captured  <= 1'b1;  // no deferred capture at reset
      bank_sel_pending <= 1'b0;
      c_beat        <= 0;
      c_odd         <= 1'b0;
      m_axi_arvalid <= 1'b0;
      m_axi_rready  <= 1'b0;
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid  <= 1'b0;
      m_axi_bready  <= 1'b0;
      m_axi_arlen   <= 8'd0;
      m_axi_awlen   <= 8'd0;
      m_axi_arsize  <= 3'd0;
      m_axi_arburst <= 2'b00;
      m_axi_awsize  <= 3'd0;
      m_axi_awburst <= 2'b00;
    end else begin
      // Per-cycle defaults
      o_done        <= 1'b0;
      // DMA cycle counter: counts while DMA is busy, resets on start
      if (i_start && dims_ok)
        o_dma_cycle_count <= 32'd0;
      else if (phase != P_IDLE)
        o_dma_cycle_count <= o_dma_cycle_count + 32'd1;
      o_wen         <= 1'b0;
      o_wbank       <= bank_sel;  // default: write to active bank (for P_READ_A/B)
      o_staging_wen <= 1'b0;
      // Deferred bank_sel toggle: apply one cycle after staging completes
      // so the last staging write uses the OLD bank_sel (inactive bank).
      if (bank_sel_pending) begin
        bank_sel <= ~bank_sel;
        bank_sel_pending <= 1'b0;
      end
      o_core_start  <= 1'b0;
      m_axi_arvalid <= 1'b0;
      m_axi_rready  <= 1'b0;
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid  <= 1'b0;
      m_axi_bready  <= 1'b0;

      // ---- DDR read timeout watchdog ----
      // Arm when AR is accepted; count until first rvalid or timeout.
      if (m_axi_arvalid && m_axi_arready) begin
        ddr_timeout_cnt    <= DDR_TIMEOUT_CYCLES;
        ddr_timeout_active <= 1'b1;
      end else if (ddr_timeout_active) begin
        if (m_axi_rvalid) begin
          // DDR responded — disable timeout
          ddr_timeout_active <= 1'b0;
        end else if (ddr_timeout_cnt <= 0) begin
          // Timeout! DDR never responded.  Abort immediately to P_IDLE.
          // The DDR model should have its own safety timeout to release
          // r_busy after the DMA gives up.
          ddr_timeout_active <= 1'b0;
          o_done  <= 1'b1;
          o_error <= 1'b1;
          o_dma_last_count <= o_dma_cycle_count;
          m_axi_arvalid <= 1'b0;
          m_axi_rready  <= 1'b0;
          pf_state      <= PF_IDLE;
          pf2_state     <= PF2_IDLE;
          phase         <= P_IDLE;
        end else begin
          ddr_timeout_cnt <= ddr_timeout_cnt - 1;
        end
      end

      case (phase)

        // ---------------------------------------------------------------------
        P_IDLE: begin
          // Update staging_ready from PF2 completion (persists until consumed)
          if (next_a_ready && next_b_ready)
            staging_ready <= 1'b1;

          if (i_start) begin
            if (!dims_ok) begin
              o_error <= 1'b1;
            end else begin
              o_error  <= 1'b0;
              dm       <= i_dim_m;
              dn       <= i_dim_n;
              dk       <= i_dim_k;
              a_base_r <= i_a_base;
              b_base_r <= i_b_base;
              c_base_r <= i_c_base;
              is_int4     <= (i_precision == 3'd4);
              // Arm watchdog limit: core compute is O(M * ceil(N/8) * ceil(K/8) * 20).
              // Use M*N*K*2 + M*N*16 + 256 as a safe upper bound that covers
              // K-dependent compute, M×N tiling overhead, and DMA round-trips.
              watchdog_limit <= i_dim_m * i_dim_n * i_dim_k * 2 +
                                i_dim_m * i_dim_n * 16 + 256;
              // INT4: nibble-packing means rows share bytes, read all A upfront.
              // INT8/16/FP16/BF16: read first row only, prefetch rest during compute.
              if (i_precision == 3'd4) begin
                total_elems <= i_dim_m * i_dim_k;  // all rows (nibble packing)
                pf_row      <= i_dim_m;             // disable prefetch
                elem_size    <= 3'd0;     // INT4: 4 bits per element
                elems_per_beat <= 16;     // 16 INT4 per 64-bit word (2 nibbles/byte, 8 bytes/beat)
                elem_cnt   <= (i_dim_m * i_dim_k + 1) / 2;
                rd_beats   <= ((i_dim_m * i_dim_k + 1) / 2 + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                pf_rd_beats <= 0;
              end else if (i_precision == 3'd0) begin
                total_elems <= i_dim_k;  // first row only (rest prefetched)
                pf_row      <= 1;        // prefetch starts at row 1
                elem_size    <= 3'd1;     // INT8: 1 byte per element
                elems_per_beat <= 8;      // 8 INT8 per 64-bit word
                elem_cnt   <= i_dim_k;
                rd_beats   <= (i_dim_k + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                pf_rd_beats <= (i_dim_k + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
              end else begin
                total_elems <= i_dim_k;  // first row only (rest prefetched)
                pf_row      <= 1;        // prefetch starts at row 1
                elem_size    <= 3'd2;     // INT16/FP16/BF16: 2 bytes per element
                elems_per_beat <= 4;      // 4 INT16/FP16/BF16 per 64-bit word
                elem_cnt   <= i_dim_k * 2;
                rd_beats   <= (i_dim_k * 2 + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                pf_rd_beats <= (i_dim_k * 2 + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
              end
              rd_beat    <= 0;
              flat_idx   <= 0;
              unpack_idx <= 0;
              wsel_reg   <= 1'b0;                           // A first
              rd_sub     <= RS_AR;
              // If PF2 staging buffers are ready, load them into core first
              if (staging_ready) begin
                staging_load_a <= 1'b1;
                staging_cnt    <= 0;
                staging_total  <= i_dim_k;  // dk elements for A (INT4/INT8/INT16: same element count)
                staging_ready  <= 1'b0;  // consumed
                phase          <= P_STAGING;
    
              end else begin
                phase <= P_READ_A;
              end
              // Reset cross-GEMM prefetch state
              pf2_state    <= PF2_IDLE;
              pf2_row      <= 0;
              next_a_ready <= 1'b0;
              next_b_ready <= 1'b0;
              next_captured <= 1'b0;  // will capture i_next_* on next cycle
              // staging_ready is set below (outside i_start) when PF2 completes
              // and consumed here when we dispatch to P_STAGING
            end
          end
        end

        // ---------------------------------------------------------------------
        // Shared A/B burst read: one INCR burst, unpack 4 bytes per beat.
        // ---------------------------------------------------------------------
        P_READ_A, P_READ_B: begin
          // Deferred capture: one cycle after dispatch, the FIFO pop has
          // taken effect and the head points to the NEXT queued GEMM.
          if (!next_captured) begin
            next_captured <= 1'b1;
            if (i_next_valid) begin
              next_valid    <= 1'b1;
              next_dm       <= i_next_dim_m;
              next_dn       <= i_next_dim_n;
              next_dk       <= i_next_dim_k;
              next_a_base   <= i_next_a_base;
              next_b_base   <= i_next_b_base;
              next_c_base   <= i_next_c_base;
              next_precision <= i_next_precision;
            end else begin
              next_valid    <= 1'b0;
            end
          end
          case (rd_sub)
            RS_AR: begin
              if (m_axi_arvalid && m_axi_arready) begin
                rd_sub       <= RS_R;
                m_axi_rready <= 1'b1;
              end else begin
                m_axi_arvalid <= 1'b1;
                m_axi_arlen   <= rd_beats - 1;   // <= 31, int -> 8-bit truncates cleanly
                m_axi_arsize  <= BEAT_SIZE;
                m_axi_arburst <= 2'b01;           // INCR
                m_axi_araddr  <= wsel_reg ? b_base_r : a_base_r;
              end
            end

            RS_R: begin
              if (m_axi_rvalid && m_axi_rready) begin
                rword       <= m_axi_rdata;
                rd_beat     <= rd_beat + 1;
                unpack_idx  <= 0;
                rd_sub      <= RS_UNPACK;
              end else begin
                m_axi_rready <= 1'b1;
              end
            end

            RS_UNPACK: begin
              // Bounds check: only write if we haven't exceeded total elements
              if (flat_idx < total_elems) begin
                o_wen   <= 1'b1;
                o_wsel  <= wsel_reg;
                o_waddr <= flat_idx[15:0];
                // INT4: extract 4-bit nibble, sign-extend to 16 bits
                // INT8: sign-extend 8→16 bits; INT16: direct 16-bit
                if (is_int4)
                  o_wdata <= {{12{rword[unpack_idx*4+3]}}, rword[unpack_idx*4 +: 4]};
                else if (elem_size == 3'd1)
                  o_wdata <= {{8{rword[unpack_idx*8+7]}}, rword[unpack_idx*8 +: 8]};
                else
                  o_wdata <= rword[unpack_idx*16 +: 16];
              end
              flat_idx   <= flat_idx + 1;
              unpack_idx <= unpack_idx + 1;
              if (unpack_idx == elems_per_beat - 1) begin
                // last byte of this beat
                if (rd_beat == rd_beats) begin
                  if (wsel_reg) begin
                    // B fully loaded -> launch the core
                    phase  <= P_LAUNCH;
                    rd_sub <= RS_AR;
                  end else begin
                    // A loaded -> move on to B
                    total_elems <= dn * dk;  // B element count for bounds check
                    if (is_int4) begin
                      elem_cnt   <= (dn * dk + 1) / 2;
                      rd_beats   <= ((dn * dk + 1) / 2 + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                    end else if (elem_size == 3'd1) begin
                      elem_cnt   <= dn * dk;
                      rd_beats   <= (dn * dk + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                    end else begin
                      elem_cnt   <= dn * dk * 2;
                      rd_beats   <= (dn * dk * 2 + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                    end
                    rd_beat    <= 0;
                    flat_idx   <= 0;
                    unpack_idx <= 0;
                    wsel_reg   <= 1'b1;
                    rd_sub     <= RS_AR;
                    phase      <= P_READ_B;
                  end
                end else begin
                  // more beats to unpack
                  rd_sub       <= RS_R;
                  m_axi_rready <= 1'b1;
                end
              end
            end
          endcase
        end

        // ---------------------------------------------------------------------
        // P_LAUNCH: start core + prefetch remaining A rows during compute.
        // Row 0's A was loaded in P_READ_A. Rows 1..M-1 are prefetched here
        // via the AXI read channel, overlapping DDR reads with systolic compute.
        // ---------------------------------------------------------------------
        P_LAUNCH: begin
          // --- Prefetch sub-state machine (runs in parallel with core) ---
          case (pf_state)
            PF_IDLE: begin
              if (launched && pf_row < dm) begin
                pf_flat_idx   <= 0;
                pf_rd_beat    <= 0;
                pf_unpack_idx <= 0;
                pf_state      <= PF_AR;
              end
            end
            PF_AR: begin
              if (m_axi_arvalid && m_axi_arready) begin
                pf_state     <= PF_R;
                m_axi_rready <= 1'b1;
              end else begin
                m_axi_arvalid <= 1'b1;
                m_axi_arlen   <= pf_rd_beats - 1;
                m_axi_arsize  <= BEAT_SIZE;
                m_axi_arburst <= 2'b01;           // INCR
                m_axi_araddr  <= a_base_r + pf_row * dk * elem_size;
              end
            end
            PF_R: begin
              if (m_axi_rvalid && m_axi_rready) begin
                pf_rword      <= m_axi_rdata;
                pf_rd_beat    <= pf_rd_beat + 1;
                pf_unpack_idx <= 0;
                pf_state      <= PF_UNPK;
              end else begin
                m_axi_rready <= 1'b1;
              end
            end
            PF_UNPK: begin
              // Bounds check: only write dk elements per row
              if (pf_flat_idx < dk) begin
                o_wen   <= 1'b1;
                o_wsel  <= 1'b0;   // A
                o_waddr <= pf_row * dk + pf_flat_idx;
                if (is_int4)
                  o_wdata <= {{12{pf_rword[pf_unpack_idx*4+3]}}, pf_rword[pf_unpack_idx*4 +: 4]};
                else if (elem_size == 3'd1)
                  o_wdata <= {{8{pf_rword[pf_unpack_idx*8+7]}}, pf_rword[pf_unpack_idx*8 +: 8]};
                else
                  o_wdata <= pf_rword[pf_unpack_idx*16 +: 16];
              end
              pf_flat_idx   <= pf_flat_idx + 1;
              pf_unpack_idx <= pf_unpack_idx + 1;
              if (pf_unpack_idx == elems_per_beat - 1) begin
                if (pf_rd_beat == pf_rd_beats) begin
                  pf_row   <= pf_row + 1;
                  pf_state <= PF_IDLE;
                end else begin
                  pf_state    <= PF_R;
                  m_axi_rready <= 1'b1;
                end
              end
            end
          endcase

          // --- Core start / completion + watchdog ---
          if (!launched) begin
            o_core_start  <= 1'b1;
            launched      <= 1'b1;
            // Arm watchdog: countdown from dm*dn*dk*2
            watchdog_cnt    <= watchdog_limit;
            watchdog_active <= 1'b1;

          end else if (i_core_done) begin
            launched       <= 1'b0;
            watchdog_active <= 1'b0;  // disarm watchdog

            // Do NOT stop prefetch here -- let it continue during
            // P_WRITE_C so A prefetch overlaps with C write-back
            // (AXI read and write channels are independent).
            if (i_core_error) begin
              pf_state <= PF_IDLE;  // stop prefetch on error
              o_error <= 1'b1;
              phase   <= P_DONE;
            end else begin
              c_idx  <= 0;
              c_beat <= 0;
              wr_sub <= WS_AW;
              phase  <= P_WRITE_C;
            end

          end else if (watchdog_active) begin
            // Watchdog countdown
            if (watchdog_cnt <= 1) begin
              // TIMEOUT: core did not respond in time
              $display("  [DMA] WATCHDOG TIMEOUT: core did not respond within %0d cycles",
                       watchdog_limit);
              launched       <= 1'b0;
              watchdog_active <= 1'b0;
              pf_state       <= PF_IDLE;  // stop prefetch
              o_error        <= 1'b1;
              phase          <= P_DONE;
            end else begin
              watchdog_cnt <= watchdog_cnt - 1;
            end
          end
        end

        // ---------------------------------------------------------------------
        // P_WRITE_C: write C results back via AXI write channel.
        // The prefetch sub-state machine continues in parallel via the
        // AXI read channel, overlapping A row prefetch with C write-back.
        // ---------------------------------------------------------------------
        P_WRITE_C: begin
          // --- Prefetch continues during C write-back ---
          case (pf_state)
            PF_IDLE: begin
              if (pf_row < dm) begin
                pf_flat_idx   <= 0;
                pf_rd_beat    <= 0;
                pf_unpack_idx <= 0;
                pf_state      <= PF_AR;
              end
            end
            PF_AR: begin
              if (m_axi_arvalid && m_axi_arready) begin
                pf_state     <= PF_R;
                m_axi_rready <= 1'b1;
              end else begin
                m_axi_arvalid <= 1'b1;
                m_axi_arlen   <= pf_rd_beats - 1;
                m_axi_arsize  <= BEAT_SIZE;
                m_axi_arburst <= 2'b01;
                m_axi_araddr  <= a_base_r + pf_row * dk * elem_size;
              end
            end
            PF_R: begin
              if (m_axi_rvalid && m_axi_rready) begin
                pf_rword      <= m_axi_rdata;
                pf_rd_beat    <= pf_rd_beat + 1;
                pf_unpack_idx <= 0;
                pf_state      <= PF_UNPK;
              end else begin
                m_axi_rready <= 1'b1;
              end
            end
            PF_UNPK: begin
              if (pf_flat_idx < dk) begin
                o_wen   <= 1'b1;
                o_wsel  <= 1'b0;   // A
                o_waddr <= pf_row * dk + pf_flat_idx;
                if (is_int4)
                  o_wdata <= {{12{pf_rword[pf_unpack_idx*4+3]}}, pf_rword[pf_unpack_idx*4 +: 4]};
                else if (elem_size == 3'd1)
                  o_wdata <= {{8{pf_rword[pf_unpack_idx*8+7]}}, pf_rword[pf_unpack_idx*8 +: 8]};
                else
                  o_wdata <= pf_rword[pf_unpack_idx*16 +: 16];
              end
              pf_flat_idx   <= pf_flat_idx + 1;
              pf_unpack_idx <= pf_unpack_idx + 1;
              if (pf_unpack_idx == elems_per_beat - 1) begin
                if (pf_rd_beat == pf_rd_beats) begin
                  pf_row   <= pf_row + 1;
                  pf_state <= PF_IDLE;
                end else begin
                  pf_state    <= PF_R;
                  m_axi_rready <= 1'b1;
                end
              end
            end
          endcase

          // --- Cross-GEMM prefetch (PF2): read next GEMM's A row 0 + B row 0 ---
          // Uses the AXI read channel when the existing A-row prefetch is idle.
          // Stores into staging buffers for the next GEMM.
          if (next_valid && pf_state == PF_IDLE) begin
            case (pf2_state)
              PF2_IDLE: begin
                // Start prefetching next GEMM's A row 0
                pf2_flat_idx   <= 0;
                pf2_rd_beat    <= 0;
                pf2_unpack_idx <= 0;
                pf2_reading_a  <= 1'b1;
                // INT4: 16 elements per beat, read ceil(dk/16) beats
                // INT8: 8 elements per beat, read ceil(dk/8) beats
                // INT16/FP16: 4 elements per beat, read ceil(dk/4) beats
                if (next_precision == 3'd4)  // INT4
                  pf2_rd_beats <= (next_dk + 15) / 16;
                else if (next_precision == 3'd0)  // INT8
                  pf2_rd_beats <= (next_dk + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                else  // INT16/FP16/BF16
                  pf2_rd_beats <= (next_dk * 2 + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                pf2_state      <= PF2_AR;
              end
              PF2_AR: begin
                if (m_axi_arvalid && m_axi_arready) begin
                  pf2_state    <= PF2_R;
                  m_axi_rready <= 1'b1;
                end else begin
                  m_axi_arvalid <= 1'b1;
                  m_axi_arlen   <= pf2_rd_beats - 1;
                  m_axi_arsize  <= BEAT_SIZE;
                  m_axi_arburst <= 2'b01;
                  m_axi_araddr  <= pf2_reading_a ? next_a_base : next_b_base;
                end
              end
              PF2_R: begin
                if (m_axi_rvalid && m_axi_rready) begin
                  pf2_rword     <= m_axi_rdata;
                  pf2_rd_beat   <= pf2_rd_beat + 1;
                  pf2_unpack_idx <= 0;
                  pf2_state     <= PF2_UNPK;
                end else begin
                  m_axi_rready <= 1'b1;
                end
              end
              PF2_UNPK: begin
                // Unpack into staging buffer
                // INT4: 16 elements/beat (4-bit nibbles), INT8: 8, INT16: 4
                if (pf2_reading_a) begin
                  if (pf2_flat_idx < next_dk) begin
                    if (next_precision == 3'd4)  // INT4: nibble unpack
                      next_a_buf[pf2_flat_idx] <= {{12{pf2_rword[pf2_unpack_idx*4+3]}}, pf2_rword[pf2_unpack_idx*4 +: 4]};
                    else if (next_precision == 3'd0)  // INT8
                      next_a_buf[pf2_flat_idx] <= {{8{pf2_rword[pf2_unpack_idx*8+7]}}, pf2_rword[pf2_unpack_idx*8 +: 8]};
                    else  // INT16/FP16/BF16
                      next_a_buf[pf2_flat_idx] <= pf2_rword[pf2_unpack_idx*16 +: 16];
                  end
                end else begin
                  if (pf2_flat_idx < next_dk * next_dn) begin
                    if (next_precision == 3'd4)
                      next_b_buf[pf2_flat_idx] <= {{12{pf2_rword[pf2_unpack_idx*4+3]}}, pf2_rword[pf2_unpack_idx*4 +: 4]};
                    else if (next_precision == 3'd0)
                      next_b_buf[pf2_flat_idx] <= {{8{pf2_rword[pf2_unpack_idx*8+7]}}, pf2_rword[pf2_unpack_idx*8 +: 8]};
                    else
                      next_b_buf[pf2_flat_idx] <= pf2_rword[pf2_unpack_idx*16 +: 16];
                  end
                end
                pf2_flat_idx   <= pf2_flat_idx + 1;
                pf2_unpack_idx <= pf2_unpack_idx + 1;
                // Beat boundary: INT4=16 elements, INT8=8, INT16=4
                if (pf2_unpack_idx == (next_precision == 3'd4 ? 15 :
                                      next_precision == 3'd0 ? 7 : 3)) begin
                  if (pf2_rd_beat == pf2_rd_beats) begin
                    if (pf2_reading_a) begin
                      // A row done, start B
                      next_a_ready  <= 1'b1;
                      pf2_reading_a <= 1'b0;
                      pf2_flat_idx  <= 0;
                      pf2_rd_beat   <= 0;
                      // B beat count: INT4 packs 2 elements/byte, INT8 packs 4/byte, INT16 packs 2/byte
                      if (next_precision == 3'd4)  // INT4: dk*dn elements, 16 per beat
                        pf2_rd_beats <= (next_dk * next_dn + 15) / 16;
                      else if (next_precision == 3'd0)  // INT8: dk*dn elements, 8 per beat
                        pf2_rd_beats <= (next_dk * next_dn + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                      else  // INT16/FP16/BF16: dk*dn elements, 4 per beat (2 bytes each)
                        pf2_rd_beats <= (next_dk * next_dn * 2 + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                      pf2_state     <= PF2_AR;
                    end else begin
                      // B done
                      next_b_ready <= 1'b1;
                      pf2_state    <= PF2_IDLE;
                    end
                  end else begin
                    pf2_state     <= PF2_R;
                    m_axi_rready <= 1'b1;
                  end
                end
              end
            endcase
          end else if (pf2_state != PF2_IDLE && pf_state != PF_IDLE) begin
            // Existing A-row prefetch is active — defer PF2
            pf2_state <= PF2_IDLE;
          end

          // --- C write-back (original logic) ---
          case (wr_sub)
            WS_AW: begin
              if (m_axi_awvalid && m_axi_awready) begin
                c_idx  <= 0;
                c_odd  <= ((dm * dn) % 2) != 0;
                wr_sub <= WS_ADDR;
              end else begin
                m_axi_awvalid <= 1'b1;
                // Two INT32 values packed per 64-bit beat
                m_axi_awlen   <= (dm * dn + 1) / 2 - 1;  // ceil(n/2) - 1
                m_axi_awsize  <= 3'd3;            // 8 bytes per beat (64-bit)
                m_axi_awburst <= 2'b01;           // INCR
                m_axi_awaddr  <= c_base_r;
              end
            end

            WS_ADDR: begin
              // c_idx always points to the first element of the pair
              o_c_raddr <= c_idx[15:0];
              wr_sub    <= WS_DATA;
            end

            WS_DATA: begin
              // Latch low word (first element of pair)
              c_lo <= i_c_rdata;
              if (c_idx + 1 < dm * dn) begin
                // Second element exists: request it next cycle
                o_c_raddr <= c_idx + 1;
                wr_sub <= WS_PACK;
              end else begin
                // Single remaining element (odd count): pack low only
                wdata_reg <= {32'b0, i_c_rdata};
                wr_sub <= WS_DRIVE;
              end
            end

            WS_PACK: begin
              // Pack: {c_high[31:0], c_lo[31:0]} into 64-bit word
              wdata_reg <= {i_c_rdata, c_lo};
              wr_sub    <= WS_DRIVE;
            end

            WS_DRIVE: begin
              if (m_axi_wvalid && m_axi_wready) begin
                // Advance to next pair.  c_idx still points to the first
                // element of the pair we just wrote (WS_DATA incremented
                // the address wire but not c_idx, so c_idx is correct).
                // Check if next pair would be past the end:
                if (c_idx + 2 >= dm * dn) begin
                  wr_sub       <= WS_B;
                  m_axi_bready <= 1'b1;
                end else begin
                  c_idx  <= c_idx + 2;
                  wr_sub <= WS_ADDR;
                end
              end else begin
                m_axi_wvalid <= 1'b1;
                m_axi_wdata  <= wdata_reg;
                // Odd last element: only lower 32 bits valid
                m_axi_wstrb  <= (c_idx + 1 >= dm * dn && c_odd) ? 8'h0F : 8'hFF;
                m_axi_wlast  <= (c_idx + 2 >= dm * dn);
              end
            end

            WS_B: begin
              if (m_axi_bvalid && m_axi_bready)
                phase <= P_DONE;
              else
                m_axi_bready <= 1'b1;
            end
          endcase
        end

        // ---------------------------------------------------------------------
        // P_STAGING: load PF2 prefetched A/B from staging buffers into core.
        // Runs while the core is idle (before i_start).  Writes one element
        // per cycle to a_mem or b_mem via the staging write port.
        // A: dk elements (INT8: dk, INT16/FP16: dk*2 bytes = dk*2 elements)
        // B: dk*dn elements (same packing)
        // After A is loaded, switches to B, then transitions to P_LAUNCH.
        // ---------------------------------------------------------------------
        P_STAGING: begin
          // Deferred capture for staging path too
          if (!next_captured) begin
            next_captured <= 1'b1;
            if (i_next_valid) begin
              next_valid    <= 1'b1;
              next_dm       <= i_next_dim_m;
              next_dn       <= i_next_dim_n;
              next_dk       <= i_next_dim_k;
              next_a_base   <= i_next_a_base;
              next_b_base   <= i_next_b_base;
              next_c_base   <= i_next_c_base;
              next_precision <= i_next_precision;
            end else begin
              next_valid    <= 1'b0;
            end
          end
          o_staging_wen  <= 1'b1;
          o_staging_wsel <= staging_load_a ? 1'b0 : 1'b1;  // 0 = A, 1 = B
          o_staging_waddr <= staging_cnt[15:0];
          if (staging_load_a) begin
            // Load A from next_a_buf
            if (next_precision == 3'd4)  // INT4: already sign-extended by PF2
              o_staging_wdata <= next_a_buf[staging_cnt];
            else if (next_precision == 3'd0)  // INT8
              o_staging_wdata <= {{8{next_a_buf[staging_cnt][7]}}, next_a_buf[staging_cnt][7:0]};
            else  // INT16/FP16/BF16
              o_staging_wdata <= next_a_buf[staging_cnt];
          end else begin
            // Load B from next_b_buf
            if (next_precision == 3'd4)
              o_staging_wdata <= next_b_buf[staging_cnt];
            else if (next_precision == 3'd0)  // INT8
              o_staging_wdata <= {{8{next_b_buf[staging_cnt][7]}}, next_b_buf[staging_cnt][7:0]};
            else  // INT16/FP16/BF16
              o_staging_wdata <= next_b_buf[staging_cnt];
          end
          staging_cnt <= staging_cnt + 1;
          if (staging_cnt + 1 >= staging_total) begin
            if (staging_load_a) begin
              // A done, switch to B
              staging_load_a <= 1'b0;
              staging_cnt    <= 0;
              staging_total  <= dk * dn;  // dk*dn elements for B (all precisions)
            end else begin
              // B done, proceed to P_LAUNCH
              staging_load_a <= 1'b0;
              launched       <= 1'b0;
              phase          <= P_LAUNCH;
              // Flip bank: staging loaded data into the inactive bank.
              // Now make it active so the core reads from it during compute.
              // Defer by one cycle so the last staging write uses the OLD bank_sel.
              bank_sel_pending <= 1'b1;
            end
          end
        end

        // ---------------------------------------------------------------------
        // P_DONE: drain any pending AXI read, then return to P_IDLE.
        // A PF1 prefetch may have issued a burst that the DDR model is
        // still processing (r_busy=1).  If we jump straight to P_IDLE,
        // the next P_READ_A stalls forever on arready=0 because the DDR
        // model waits for rready to finish the old burst.
        P_DONE: begin
          o_done <= 1'b1;
          o_dma_last_count <= o_dma_cycle_count;
          // Stop PF state machine from issuing new reads
          pf_state <= PF_IDLE;
          if (m_axi_rvalid) begin
            // Drain pending read data so the DDR model can release r_busy
            m_axi_rready <= 1'b1;
            if (m_axi_rlast) begin
              phase <= P_IDLE;
            end
          end else begin
            // No pending read — safe to return to P_IDLE immediately
            phase <= P_IDLE;
          end
        end

        default: phase <= P_IDLE;
      endcase
    end
  end

endmodule
