// -----------------------------------------------------------------------------
// c930_l2.sv - Shared L2 cache + coherence directory (MSI-lite, write-through).
//
// Sits between the AXI crossbar's DDR slave port (s1) and the DDR.  It is the
// point of coherence for the four RV64IMAC cores.  Because the per-core L1
// data caches are WRITE-THROUGH (they never hold dirty data), the protocol is
// a simplified MSI with no Modified state:
//
//   * Every L1 line is a clean copy of an L2 line.  The L2 directory records
//     which L1s hold each line (a 16-bit sharer vector indexed by SOURCE_ID,
//     see c930_soc_top.sv for the source-id map).
//   * Read fill (32B line, AXI len==3): allocate in the L2, record the
//     requesting L1 as a sharer.  Non-fill reads (len<3, e.g. NPU streaming
//     row reads) bypass the cache and go straight to DDR.
//   * Write: write-through to DDR, NO allocate.  Before the write becomes
//     visible, every L1 sharer of the line is invalidated (asserted on the
//     per-L1 invalidation ports until acked).  The L2 copy is dropped.
//   * Eviction: before a victim line is dropped, all L1 sharers are
//     invalidated, so no L1 can hold a line that is no longer tracked.
//     (L1s ack invalidations even while busy - "clear before next use" - so
//     this wait can never deadlock against an in-flight L1 fill.)
//   * A fill that raced a write (AR issued before the write's AW, fill data
//     returns after) is discarded and re-issued once the write completes, so
//     an L1 can never consume pre-write data.  Detected via the write log:
//     every accepted write is logged with a sequence number; a fill re-checks
//     the log at data-return and retries if any write to its line was
//     accepted at or after its AR.  Because the write path serializes one
//     transaction at a time, at most one log entry is in flight, so a fill
//     can wait for the raced write's completion without the entry wrapping.
//
// The read and write paths are INDEPENDENT FSMs (like the crossbar's), so a
// write waiting on an L1 invalidation ack can never block an L1's pending
// fill and vice versa.
//
// Structure: 4-way set-associative, 512 sets x 32B lines = 64 KB.
//   tag[way][set], valid[way][set], data[way][set][4 x 64b],
//   sharers[way][set][15:0], victim round-robin counter per set.
// -----------------------------------------------------------------------------

module c930_l2
#(
  parameter int ADDR_WIDTH = 64,
  parameter int DATA_WIDTH = 64,      // AXI data width at both ports
  parameter int ID_WIDTH   = 4,
  parameter int LINE_BYTES = 32,      // must match the L1 line size
  parameter int NUM_SETS   = 512,
  parameter int NUM_WAYS   = 4,
  parameter int NUM_SRC    = 16,      // SOURCE_ID space
  parameter int INV_PORTS  = 8,       // L1 caches (I0,D0,I1,D1,I2,D2,I3,D3)
  parameter int WR_LOG_DEPTH = 8
)
(
  input  logic                        i_clk,
  input  logic                        i_rst_n,

  // ---- AXI4 slave (crossbar s1: all DDR traffic) ----
  input  logic [ID_WIDTH-1:0]         s_awid,
  input  logic [ADDR_WIDTH-1:0]       s_awaddr,
  input  logic [7:0]                  s_awlen,
  input  logic [2:0]                  s_awsize,
  input  logic [1:0]                  s_awburst,
  input  logic                        s_awvalid,
  output logic                        s_awready,
  input  logic [DATA_WIDTH-1:0]       s_wdata,
  input  logic [DATA_WIDTH/8-1:0]     s_wstrb,
  input  logic                        s_wlast,
  input  logic                        s_wvalid,
  output logic                        s_wready,
  output logic [ID_WIDTH-1:0]         s_bid,
  output logic [1:0]                  s_bresp,
  output logic                        s_bvalid,
  input  logic                        s_bready,
  input  logic [ID_WIDTH-1:0]         s_arid,
  input  logic [ADDR_WIDTH-1:0]       s_araddr,
  input  logic [7:0]                  s_arlen,
  input  logic [2:0]                  s_arsize,
  input  logic [1:0]                  s_arburst,
  input  logic                        s_arvalid,
  output logic                        s_arready,
  output logic [ID_WIDTH-1:0]         s_rid,
  output logic [DATA_WIDTH-1:0]       s_rdata,
  output logic [1:0]                  s_rresp,
  output logic                        s_rlast,
  output logic                        s_rvalid,
  input  logic                        s_rready,

  // ---- AXI4 master (DDR) ----
  output logic [ID_WIDTH-1:0]         m_awid,
  output logic [ADDR_WIDTH-1:0]       m_awaddr,
  output logic [7:0]                  m_awlen,
  output logic [2:0]                  m_awsize,
  output logic [1:0]                  m_awburst,
  output logic                        m_awvalid,
  input  logic                        m_awready,
  output logic [DATA_WIDTH-1:0]       m_wdata,
  output logic [DATA_WIDTH/8-1:0]     m_wstrb,
  output logic                        m_wlast,
  output logic                        m_wvalid,
  input  logic                        m_wready,
  input  logic [ID_WIDTH-1:0]         m_bid,
  input  logic [1:0]                  m_bresp,
  input  logic                        m_bvalid,
  output logic                        m_bready,
  output logic [ID_WIDTH-1:0]         m_arid,
  output logic [ADDR_WIDTH-1:0]       m_araddr,
  output logic [7:0]                  m_arlen,
  output logic [2:0]                  m_arsize,
  output logic [1:0]                  m_arburst,
  output logic                        m_arvalid,
  input  logic                        m_arready,
  input  logic [ID_WIDTH-1:0]         m_rid,
  input  logic [DATA_WIDTH-1:0]       m_rdata,
  input  logic [1:0]                  m_rresp,
  input  logic                        m_rlast,
  input  logic                        m_rvalid,
  output logic                        m_rready,

  // ---- L1 invalidation ports (one per cache, see INV_SRC map) ----
  output logic [INV_PORTS-1:0]        o_inv_valid,
  output logic [ADDR_WIDTH-1:0]       o_inv_addr,
  input  logic [INV_PORTS-1:0]        i_inv_ack
);

  // ---------------------------------------------------------------------------
  // Derived constants
  // ---------------------------------------------------------------------------
  localparam int WORDS_PER_LINE = LINE_BYTES / (DATA_WIDTH/8);   // 4
  localparam int SET_BITS   = $clog2(NUM_SETS);                  // 9
  localparam int WAY_BITS   = $clog2(NUM_WAYS) < 1 ? 1 : $clog2(NUM_WAYS);  // 2
  localparam int OFF_BITS   = $clog2(LINE_BYTES);                // 5
  localparam int TAG_BITS   = ADDR_WIDTH - SET_BITS - OFF_BITS;  // 50

  // SOURCE_ID -> invalidation port map (see c930_soc_top.sv).
  //   0: CPU0-I   1: CPU0-D
  //   4: CPU1-I   5: CPU1-D   6: CPU2-I   7: CPU2-D   (via arb1)
  //   8: NPU0     9: NPU1    10: CPU3-I  11: CPU3-D   (via dma arb)
  // Ports are {I0,D0,I1,D1,I2,D2,I3,D3}.
  logic [INV_PORTS-1:0] inv_port_of_src [0:NUM_SRC-1];
  always_comb begin
    for (int s = 0; s < NUM_SRC; s++)
      inv_port_of_src[s] = '0;
    inv_port_of_src[0]  = 8'b0000_0001;
    inv_port_of_src[1]  = 8'b0000_0010;
    inv_port_of_src[4]  = 8'b0000_0100;
    inv_port_of_src[5]  = 8'b0000_1000;
    inv_port_of_src[6]  = 8'b0001_0000;
    inv_port_of_src[7]  = 8'b0010_0000;
    inv_port_of_src[10] = 8'b0100_0000;
    inv_port_of_src[11] = 8'b1000_0000;
  end

  function automatic logic [INV_PORTS-1:0] inv_mask_of_sharers(
      input logic [NUM_SRC-1:0] sharers);
    logic [INV_PORTS-1:0] m;
    m = '0;
    for (int s = 0; s < NUM_SRC; s++)
      if (sharers[s]) m |= inv_port_of_src[s];
    return m;
  endfunction

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------
  logic [TAG_BITS-1:0]           tag_mem    [0:NUM_WAYS-1][0:NUM_SETS-1];
  logic                          valid_mem  [0:NUM_WAYS-1][0:NUM_SETS-1];
  logic [DATA_WIDTH-1:0]         data_mem   [0:NUM_WAYS-1][0:NUM_SETS-1][0:WORDS_PER_LINE-1];
  logic [NUM_SRC-1:0]            sharers    [0:NUM_WAYS-1][0:NUM_SETS-1];
  logic [WAY_BITS-1:0]           victim_cnt [0:NUM_SETS-1];

  integer i, j;
  initial begin
    for (i = 0; i < NUM_WAYS; i++)
      for (j = 0; j < NUM_SETS; j++) begin
        valid_mem[i][j] = 1'b0;
        sharers[i][j]   = '0;
      end
    // Round-robin victim pointers must start defined (X indices on first
    // miss would silently drop every allocation and force refill loops).
    for (j = 0; j < NUM_SETS; j++)
      victim_cnt[j] = '0;
    // Write-log entries start invalid (see wr_log_match_idx note).
    for (j = 0; j < WR_LOG_DEPTH; j++) begin
      wr_log_valid[j] = 1'b0;
      wr_log_done[j]  = 1'b1;   // nothing pending
    end
  end

  // ---------------------------------------------------------------------------
  // Write log: {line, seq, done} - detects fill/write races
  // ---------------------------------------------------------------------------
  logic [ADDR_WIDTH-1:0]  wr_log_line [0:WR_LOG_DEPTH-1];
  logic [7:0]             wr_log_seq  [0:WR_LOG_DEPTH-1];
  logic                   wr_log_done [0:WR_LOG_DEPTH-1];
  logic                   wr_log_valid [0:WR_LOG_DEPTH-1];
  logic [7:0]             wr_log_head;   // next entry to write
  logic [7:0]             wr_seq;        // monotonic write sequence
  logic                   wr_log_full;

  assign wr_log_full = (wr_seq - wr_log_head) >= WR_LOG_DEPTH;

  // Index of the FIRST log entry for 'line' with seq >= seq_floor, or -1.
  // Empty entries (never allocated) are invalid and can NEVER match -- a
  // zero-initialized {line=0, seq=0} entry would otherwise false-match the
  // very first refill to line 0 at seq_floor=0 and hang the read FSM waiting
  // for a write that never happened (Icarus started these arrays as X so
  // never matched; Verilator starts them as 0).
  function automatic int wr_log_match_idx(input logic [ADDR_WIDTH-1:0] line,
                                          input logic [7:0] seq_floor);
    for (int e = 0; e < WR_LOG_DEPTH; e++)
      if (wr_log_valid[e] && wr_log_line[e] == line && wr_log_seq[e] >= seq_floor)
        return e;
    return -1;
  endfunction

  // ===========================================================================
  // READ PATH (independent FSM)
  // ===========================================================================
  typedef enum logic [3:0] {
    RD_IDLE       = 4'd0,
    RD_LOOKUP     = 4'd1,
    RD_EVICT_INV  = 4'd2,
    RD_BYPASS_AR  = 4'd3,
    RD_BYPASS_R   = 4'd4,
    RD_REFILL_AR  = 4'd5,
    RD_REFILL_R   = 4'd6,
    RD_REFILL_CHK = 4'd7,
    RD_HIT_SERVE  = 4'd8,
    RD_ALLOC      = 4'd9
  } rd_state_t;

  rd_state_t rd_state;
  logic [ADDR_WIDTH-1:0]  rd_addr;
  logic [ID_WIDTH-1:0]    rd_id;
  logic [7:0]             rd_len;
  logic [3:0]             rd_src;
  logic [SET_BITS-1:0]    rd_set;
  logic [TAG_BITS-1:0]    rd_tag;
  logic [WAY_BITS-1:0]    rd_way;
  logic [INV_PORTS-1:0]   rd_evict_mask;
  logic [DATA_WIDTH-1:0]  rd_stage [0:WORDS_PER_LINE-1];
  logic [DATA_WIDTH-1:0]  rd_serve_q;  // registered serve data (keeps rd_stage
                                        // off every combinational path: a comb
                                        // read of rd_stage makes iverilog
                                        // re-evaluate the read-output block on
                                        // every capture write, which is
                                        // pathologically slow)
  logic [7:0]             rd_seq_floor;
  logic [2:0]             rd_beat;
  int                     rd_wait_entry;   // write-log entry we wait on
  logic                   rd_wait_wr;

  // Lookup result - REGISTERED at AR-accept time (RD_IDLE) so no
  // combinational block reads the valid/tag arrays (keeps iverilog fast:
  // an always_comb reading a dynamic-indexed array is re-evaluated on every
  // element write, which is pathologically slow under load).
  logic [NUM_WAYS-1:0]    rd_hit_way;
  logic                   rd_hit;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rd_state       <= RD_IDLE;
      rd_addr        <= '0;
      rd_id          <= '0;
      rd_len         <= '0;
      rd_src         <= '0;
      rd_evict_mask  <= '0;
      rd_seq_floor   <= '0;
      rd_wait_entry  <= -1;
      rd_wait_wr     <= 1'b0;
      rd_hit_way     <= '0;
      rd_hit         <= 1'b0;
    end else begin
      case (rd_state)
        RD_IDLE: begin
          if (s_arvalid) begin
            rd_addr <= s_araddr;
            rd_id   <= s_arid;
            rd_len  <= s_arlen;
            rd_src  <= s_arid;               // stamped source id
            rd_set  <= s_araddr[OFF_BITS +: SET_BITS];
            rd_tag  <= s_araddr[ADDR_WIDTH-1 -: TAG_BITS];
            // Registered hit for the incoming address (used by RD_LOOKUP and
            // the shared array-write block on the following cycle).
            begin
              logic [NUM_WAYS-1:0] hitw;
              hitw = '0;
              for (int w = 0; w < NUM_WAYS; w++)
                if (valid_mem[w][s_araddr[OFF_BITS +: SET_BITS]] &&
                    tag_mem[w][s_araddr[OFF_BITS +: SET_BITS]] == s_araddr[ADDR_WIDTH-1 -: TAG_BITS])
                  hitw[w] = 1'b1;
              rd_hit_way <= hitw;
              rd_hit     <= |hitw;
            end
            if (s_arlen == WORDS_PER_LINE-1 && s_araddr[OFF_BITS-1:0] == '0)
              rd_state <= RD_LOOKUP;
            else
              rd_state <= RD_BYPASS_AR;
          end
        end

        RD_LOOKUP: begin
          if (rd_hit) begin
            // Capture the line into the staging register; sharer recorded in
            // the shared array-write block.
            for (int w = 0; w < NUM_WAYS; w++)
              if (rd_hit_way[w]) begin
                rd_way <= w[WAY_BITS-1:0];
                for (int b = 0; b < WORDS_PER_LINE; b++)
                  rd_stage[b] <= data_mem[w][rd_set][b];
              end
            rd_state <= RD_HIT_SERVE;
          end else begin
            // Miss: pick the round-robin victim.
            rd_way <= victim_cnt[rd_set];
            if (valid_mem[victim_cnt[rd_set]][rd_set] &&
                sharers[victim_cnt[rd_set]][rd_set] != '0) begin
              rd_evict_mask <= inv_mask_of_sharers(sharers[victim_cnt[rd_set]][rd_set]);
              rd_state      <= RD_EVICT_INV;
            end else begin
              rd_state <= RD_REFILL_AR;
            end
          end
        end

        RD_EVICT_INV: begin
          // Wait for every targeted L1 to ack (they ack even when busy).
          if ((i_inv_ack & rd_evict_mask) == rd_evict_mask) begin
            rd_state <= RD_REFILL_AR;
          end
        end

        RD_BYPASS_AR: begin
          if (m_arready) rd_state <= RD_BYPASS_R;
        end

        RD_BYPASS_R: begin
          if (m_rvalid && m_rready && m_rlast) rd_state <= RD_IDLE;
        end

        RD_REFILL_AR: begin
          // Snapshot the write sequence BEFORE the AR is accepted, so the
          // completion check catches any write accepted at or after this AR.
          rd_seq_floor <= wr_seq;
          if (m_arready) begin
            // Round-robin victim pointer wraps modulo NUM_WAYS (must never
            // hold an out-of-range way index, e.g. 1 in a 1-way cache).
            if (victim_cnt[rd_set] >= NUM_WAYS - 1)
              victim_cnt[rd_set] <= '0;
            else
              victim_cnt[rd_set] <= victim_cnt[rd_set] + 1'b1;
            rd_state          <= RD_REFILL_R;
          end
        end

        RD_REFILL_R: begin
          if (m_rvalid && m_rready) begin
            // Static-index capture: a dynamic rd_stage[rd_beat] write paired
            // with the combinational serve read makes iverilog re-evaluate
            // the whole read-output block on every element write (pathological
            // slowdown).  Unrolled for WORDS_PER_LINE == 4 (32 B line, 64-bit).
            case (rd_beat)
              2'd0:    rd_stage[0] <= m_rdata;
              2'd1:    rd_stage[1] <= m_rdata;
              2'd2:    rd_stage[2] <= m_rdata;
              default: rd_stage[3] <= m_rdata;
            endcase
            if (rd_beat == WORDS_PER_LINE-1)
              rd_state <= RD_REFILL_CHK;
          end
        end

        RD_REFILL_CHK: begin
          if (rd_wait_wr) begin
            // Waiting for the raced write to complete before retrying.
            if (wr_log_done[rd_wait_entry]) begin
              rd_wait_wr <= 1'b0;
              rd_state   <= RD_REFILL_AR;
            end
          end else begin
            rd_wait_entry <= wr_log_match_idx(rd_addr, rd_seq_floor);
            if (wr_log_match_idx(rd_addr, rd_seq_floor) >= 0) begin
              rd_wait_wr <= 1'b1;
            end else begin
              rd_beat  <= '0;             // restart the serve counter
              rd_state <= RD_HIT_SERVE;   // fresh data: serve the staged line
            end
          end
        end

        RD_HIT_SERVE: begin
          if (s_rvalid && s_rready) begin
            if (s_rlast) rd_state <= RD_ALLOC;
          end
        end

        RD_ALLOC: begin
          rd_state <= RD_IDLE;
        end

        default: rd_state <= RD_IDLE;
      endcase
    end
  end

  // Serve/refill beat counter (single driver) + registered serve data.
  // rd_serve_q is latched from rd_stage so the read-output comb block never
  // reads rd_stage (see declaration note: keeps iverilog fast).
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      rd_beat <= '0;
    else begin
      if (rd_state == RD_LOOKUP)
        rd_beat <= '0;
      else if (rd_state == RD_REFILL_AR && m_arready)
        rd_beat <= '0;
      else if (rd_state == RD_REFILL_R && m_rvalid && m_rready)
        rd_beat <= rd_beat + 1'b1;
      else if (rd_state == RD_HIT_SERVE && s_rvalid && s_rready)
        rd_beat <= rd_beat + 1'b1;
    end
  end

  // Latch serve data: at CHK->SERVE boundary load word 0, then advance one
  // word per served beat (parallel to the rd_beat counter).
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      rd_serve_q <= '0;
    else begin
      if (rd_state == RD_REFILL_CHK)
        rd_serve_q <= rd_stage[0];
      else if (rd_state == RD_LOOKUP && rd_hit) begin
        // Hit: prime the serve data from the cached line (rd_stage is being
        // rewritten this cycle, so read data_mem directly).
        for (int w = 0; w < NUM_WAYS; w++)
          if (rd_hit_way[w]) rd_serve_q <= data_mem[w][rd_set][0];
      end
      else if (rd_state == RD_HIT_SERVE && s_rvalid && s_rready && !s_rlast)
        rd_serve_q <= rd_stage[rd_beat + 1];
    end
  end

  // ---------------------------------------------------------------------------
  // Shared array writes (single always_ff: read path + write path)
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      // Flush the L2 on reset.  The L1 caches clear their valid bits on reset
      // too, so a reset that reboots firmware from DDR (rewritten behind the
      // L2's back by a loader/bootrom) must not let the L2 serve stale lines
      // from the previous boot.  (valid/sharers were previously cleared only
      // by the initial block, so a mid-test reset left the directory holding
      // lines whose memory content had changed.)
      for (int w = 0; w < NUM_WAYS; w++)
        for (int j = 0; j < NUM_SETS; j++) begin
          valid_mem[w][j] <= 1'b0;
          sharers[w][j]   <= '0;
        end
    end else begin
      // Read path
      if (rd_state == RD_LOOKUP && rd_hit) begin
        for (int w = 0; w < NUM_WAYS; w++)
          if (rd_hit_way[w])
            sharers[w][rd_set][rd_src] <= 1'b1;
      end
      if (rd_state == RD_EVICT_INV && (i_inv_ack & rd_evict_mask) == rd_evict_mask) begin
        valid_mem[rd_way][rd_set] <= 1'b0;
        sharers[rd_way][rd_set]   <= '0;
      end
      if (rd_state == RD_ALLOC) begin
        tag_mem[rd_way][rd_set]   <= rd_tag;
        valid_mem[rd_way][rd_set] <= 1'b1;
        sharers[rd_way][rd_set]   <= (1 << rd_src);
        for (int b = 0; b < WORDS_PER_LINE; b++)
          data_mem[rd_way][rd_set][b] <= rd_stage[b];
      end
      // Write path: drop the line (wins over a same-cycle alloc: the write
      // is the newer event).
      if (wr_state == WR_INV && (i_inv_ack & wr_inv_mask) == wr_inv_mask) begin
        valid_mem[wr_way][wr_set] <= 1'b0;
        sharers[wr_way][wr_set]   <= '0;
      end
    end
  end

  // Read channel outputs
  always_comb begin
    s_arready = 1'b0;
    s_rid     = rd_id;
    s_rdata   = '0;
    s_rresp   = 2'b00;
    s_rlast   = 1'b0;
    s_rvalid  = 1'b0;

    m_arid    = '0;
    m_araddr  = rd_addr;
    m_arlen   = rd_len;
    m_arsize  = 3'b011;
    m_arburst = 2'b01;
    m_arvalid = 1'b0;
    m_rready  = 1'b0;

    case (rd_state)
      // arready is asserted whenever idle; the crossbar only presents an AR
      // while it has granted a master (R_GRANTED), so arready here never
      // depends on s_arvalid (avoids a combinational coupling back through
      // the crossbar's read mux).
      RD_IDLE:    s_arready = 1'b1;
      RD_BYPASS_AR: begin
        m_araddr  = rd_addr;
        m_arlen   = rd_len;
        m_arvalid = 1'b1;
        m_rready  = s_rready;      // only consume a beat when the downstream master takes it
        s_rvalid  = m_rvalid;
        s_rdata   = m_rdata;
        s_rlast   = m_rlast;
        s_rid     = rd_id;
      end
      RD_BYPASS_R: begin
        m_rready = s_rready;       // gate on downstream readiness (rready drops during DMA unpack)
        s_rvalid = m_rvalid;
        s_rdata  = m_rdata;
        s_rlast  = m_rlast;
        s_rid    = rd_id;
      end
      RD_REFILL_AR: begin
        m_araddr  = {rd_addr[ADDR_WIDTH-1:OFF_BITS], {OFF_BITS{1'b0}}};
        m_arlen   = WORDS_PER_LINE-1;
        m_arvalid = 1'b1;
      end
      RD_REFILL_R: m_rready = 1'b1;
      RD_HIT_SERVE: begin
        s_rvalid = 1'b1;
        s_rdata  = rd_serve_q;   // registered; rd_stage stays off comb paths
        s_rlast  = (rd_beat == WORDS_PER_LINE-1);
      end
      default: ;
    endcase
  end

  // ===========================================================================
  // WRITE PATH (independent FSM)
  // ===========================================================================
  typedef enum logic [3:0] {
    WR_IDLE = 4'd0,
    WR_INV  = 4'd1,
    WR_FWD  = 4'd2,
    WR_B    = 4'd3
  } wr_state_t;

  wr_state_t wr_state;
  logic [ADDR_WIDTH-1:0]  wr_addr;
  logic [ID_WIDTH-1:0]    wr_id;
  logic [7:0]             wr_len;
  logic [SET_BITS-1:0]    wr_set;
  logic [TAG_BITS-1:0]    wr_tag;
  logic [WAY_BITS-1:0]    wr_way;
  logic [INV_PORTS-1:0]   wr_inv_mask;
  logic [7:0]             wr_entry;
  logic                   aw_ok;         // AW accepted by the DDR side

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      wr_state  <= WR_IDLE;
      wr_addr   <= '0;
      wr_id     <= '0;
      wr_len    <= '0;
      wr_inv_mask <= '0;
      wr_entry  <= '0;
      aw_ok     <= 1'b0;
      // Drop any in-flight write-log entries (see reset-flush note above).
      for (int e = 0; e < WR_LOG_DEPTH; e++) begin
        wr_log_valid[e] <= 1'b0;
        wr_log_done[e]  <= 1'b1;
      end
    end else begin
      case (wr_state)
        WR_IDLE: begin
          if (s_awvalid && !wr_log_full) begin
            wr_addr  <= s_awaddr;
            wr_id    <= s_awid;
            wr_len   <= s_awlen;
            wr_set   <= s_awaddr[OFF_BITS +: SET_BITS];
            wr_tag   <= s_awaddr[ADDR_WIDTH-1 -: TAG_BITS];
            // Log the write BEFORE it becomes visible.
            wr_log_line[wr_log_head]  <= s_awaddr;
            wr_log_seq[wr_log_head]   <= wr_seq;
            wr_log_done[wr_log_head]  <= 1'b0;
            wr_log_valid[wr_log_head] <= 1'b1;
            wr_entry    <= wr_log_head;
            // Evaluate the hit from the INCOMING address, not the captured
            // wr_set/wr_tag (those only update this cycle, so they still hold
            // the previous transaction's values -> a stale hit check).
            begin
              logic hit;
              hit = 1'b0;
              for (int w = 0; w < NUM_WAYS; w++)
                if (valid_mem[w][s_awaddr[OFF_BITS +: SET_BITS]] &&
                    tag_mem[w][s_awaddr[OFF_BITS +: SET_BITS]] == s_awaddr[ADDR_WIDTH-1 -: TAG_BITS]) begin
                  hit      = 1'b1;
                  wr_way   <= w[WAY_BITS-1:0];
                  wr_inv_mask <= inv_mask_of_sharers(sharers[w][s_awaddr[OFF_BITS +: SET_BITS]]);
                end
              if (hit) wr_state <= WR_INV;
              else begin
                wr_inv_mask <= '0;
                wr_state    <= WR_FWD;
              end
            end
          end
        end

        WR_INV: begin
          if ((i_inv_ack & wr_inv_mask) == wr_inv_mask)
            wr_state <= WR_FWD;
        end

        WR_FWD: begin
          // Present AW until accepted; forward W beats; leave on the last
          // W beat once the AW has been accepted.  AW and W handshakes
          // complete on different cycles in general, so requiring both in
          // one cycle would deadlock.
          if (m_awvalid && m_awready) aw_ok <= 1'b1;
          if (aw_ok && s_wvalid && s_wready && s_wlast)
            wr_state <= WR_B;
        end

        WR_B: begin
          if (s_bvalid && s_bready) begin
            wr_log_done[wr_entry] <= 1'b1;
            wr_state <= WR_IDLE;
          end
        end

        default: wr_state <= WR_IDLE;
      endcase
    end
  end

  // Write channel outputs
  always_comb begin
    s_awready = 1'b0;
    s_wready  = 1'b0;
    s_bid     = wr_id;
    s_bresp   = 2'b00;
    s_bvalid  = 1'b0;

    m_awid    = '0;
    m_awaddr  = wr_addr;
    m_awlen   = wr_len;
    m_awsize  = 3'b011;
    m_awburst = 2'b01;
    m_awvalid = 1'b0;
    m_wdata   = s_wdata;
    m_wstrb   = s_wstrb;
    m_wlast   = s_wlast;
    m_wvalid  = 1'b0;
    m_bready  = 1'b0;

    case (wr_state)
      // awready independent of s_awvalid (see read channel note).
      WR_IDLE: s_awready = !wr_log_full;
      WR_FWD: begin
        m_awvalid = 1'b1;
        m_wvalid  = s_wvalid;
        s_wready  = m_wready;
      end
      WR_B: begin
        s_bvalid = 1'b1;
        m_bready = 1'b1;
      end
      default: ;
    endcase
  end

  // Sequence counter + log head advance on every accepted write
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      wr_seq      <= '0;
      wr_log_head <= '0;
    end else if (wr_state == WR_IDLE && s_awvalid && !wr_log_full) begin
      wr_seq      <= wr_seq + 1'b1;
      wr_log_head <= wr_log_head + 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // L1 invalidation outputs (shared by both FSMs)
  // ---------------------------------------------------------------------------
  logic [INV_PORTS-1:0] inv_valid_c;
  logic [ADDR_WIDTH-1:0] inv_addr_c;
  always_comb begin
    inv_valid_c = '0;
    inv_addr_c  = '0;
    if (rd_state == RD_EVICT_INV) begin
      inv_valid_c = rd_evict_mask;
      inv_addr_c  = {rd_addr[ADDR_WIDTH-1:OFF_BITS], {OFF_BITS{1'b0}}};
    end
    if (wr_state == WR_INV) begin
      inv_valid_c = inv_valid_c | wr_inv_mask;
      inv_addr_c  = {wr_addr[ADDR_WIDTH-1:OFF_BITS], {OFF_BITS{1'b0}}};
    end
  end
  assign o_inv_valid = inv_valid_c;
  assign o_inv_addr  = inv_addr_c;

endmodule