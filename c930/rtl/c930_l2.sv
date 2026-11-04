// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// -----------------------------------------------------------------------------
// c930_l2.sv - Shared L2 cache + coherence directory (MSI-lite, write-through).
//
// Sits between the AXI crossbar's DDR slave port (s1) and the DDR.  It is the
// point of coherence for the four RV64IMAC cores.  Because the per-core L1
// data caches are WRITE-THROUGH (they never hold dirty data), the protocol is
// a simplified MSI with no Modified state:
//
//   * Every L1 line is a clean copy of an L2 line, EXCEPT between a
//     write-through and the writer's next miss: the writer's L1 then holds data
//     this L2 does not.  dir_mem is what keeps the directory honest across that
//     window -- the tag and sharer vector outlive valid_mem, so a later write to
//     the line still finds the writer and invalidates it.  Without it the writer
//     read its own stale copy for as long as the line survived.
//   * Every L1 line is a clean copy of an L2 line.  The L2 directory records
//     which L1s hold each line (a 16-bit sharer vector indexed by SOURCE_ID,
//     see c930_soc_top.sv for the source-id map).
//   * Read fill (32B line, AXI len==3, from an L1): allocate in the L2, record
//     the requesting L1 as a sharer.  Every other read bypasses the cache and
//     goes straight to DDR -- any other length, and any read from a source
//     with no invalidation port, such as an NPU DMA row or operand read that
//     happens to be exactly one aligned line long.
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
    inv_mask_of_sharers = m;
  endfunction

  // ---------------------------------------------------------------------------
  // FSM state
  // ---------------------------------------------------------------------------
  // Declared ahead of the storage section because each directory bank's write
  // port is expressed inside that bank's own generate block, and a generate
  // block's names are resolved in declaration order by Yosys and iverilog.
  localparam logic [3:0] RD_IDLE       = 4'd0;
  localparam logic [3:0] RD_LOOKUP     = 4'd1;
  localparam logic [3:0] RD_EVICT_INV  = 4'd2;
  localparam logic [3:0] RD_BYPASS_AR  = 4'd3;
  localparam logic [3:0] RD_BYPASS_R   = 4'd4;
  localparam logic [3:0] RD_REFILL_AR  = 4'd5;
  localparam logic [3:0] RD_REFILL_R   = 4'd6;
  localparam logic [3:0] RD_REFILL_CHK = 4'd7;
  localparam logic [3:0] RD_HIT_SERVE  = 4'd8;
  localparam logic [3:0] RD_ALLOC      = 4'd9;

  localparam logic [3:0] WR_IDLE   = 4'd0;
  localparam logic [3:0] WR_LOOKUP = 4'd4;  // directory lookup for one line of the burst
  localparam logic [3:0] WR_INV    = 4'd1;
  localparam logic [3:0] WR_FWD    = 4'd2;
  localparam logic [3:0] WR_B      = 4'd3;

  localparam logic [NUM_SRC-1:0] SRC_ONE = 1;

  logic [3:0] rd_state;
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
  // The miss path reused an entry that was already this tag (dir-only, its
  // sharers are the earlier writer's).  The alloc ORs into the sharer vector
  // only in that case; see the sharer-write commands below.
  logic                   rd_same_tag;

  logic [3:0] wr_state;
  logic [ADDR_WIDTH-1:0]  wr_addr;
  logic [ID_WIDTH-1:0]    wr_id;
  logic [7:0]             wr_len;
  logic [SET_BITS-1:0]    wr_set;
  logic [TAG_BITS-1:0]    wr_tag;
  logic [WAY_BITS-1:0]    wr_way;
  logic [INV_PORTS-1:0]   wr_inv_mask;
  logic [7:0]             wr_entry;
  logic                   aw_ok;         // AW accepted by the DDR side

  // Multi-line invalidate walk.  A single write burst can span many 32-byte
  // lines, and EVERY line it overwrites must have its L1 sharers invalidated
  // (and the L2 copy dropped).  Clearing only the line containing awaddr
  // leaves every L1 holding a stale copy of the rest of the burst, so a
  // DMA write-back of a multi-line buffer reads back as the PREVIOUS
  // buffer's contents in the CPU.
  logic [7:0]             wr_nlines;      // 32B lines touched by this burst
  logic [7:0]             wr_line_idx;    // line currently being invalidated
  logic [ADDR_WIDTH-1:0]  wr_cur_line;    // 32B-aligned address of that line
  logic                   wr_hit;         // that line was resident in the L2
  logic [7:0]             wr_nlines_c;
  logic [31:0]            wr_bytes_c, wr_off_end_c;

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------
  // Tag storage: one memory per way, one whole-word write port and two
  // addressed read ports.  That shape is what makes Yosys infer a memory; the
  // previous form did not, and the SKY130 run died because of it:
  //
  //   * the banks were read through a per-set wire alias
  //     (`for (gs) assign tag_mem[gt][gs] = tag_bank[gs]`), which is 512
  //     constant-indexed reads, not one addressed read.  Yosys never emitted a
  //     memory at all -- it materialised NUM_SETS*TAG_BITS registers per way,
  //     each with its own write decoder, and the run was killed at 13 GB while
  //     still inside the frontend/opt block.
  //
  // Two read ports, because the read and write FSMs are independent and can
  // look up different sets in the same cycle: the read FSM compares the way's
  // tag against the incoming AR (and again against rd_tag for the same-tag
  // reuse test), the write FSM against the line its burst is currently on.
  //
  // The banks are not reset.  Every compare is gated by valid_mem/dir_mem, so
  // an unallocated entry's tag is unreachable, and a reset leaves both gates
  // clear.  (A clocked reset over an array is itself a construct Yosys answers
  // by expanding the array to registers -- see valid_mem below.)
  //
  // As LUTRAM on the FPGA this is ~2K LUT-equivalents; as a register file on
  // SKY130 it is NUM_WAYS x 512 x 50 flops behind the read muxes.
  wire [SET_BITS-1:0]  tag_rd_addr_r;
  wire [TAG_BITS-1:0]  tag_rd_r [0:NUM_WAYS-1];
  wire [TAG_BITS-1:0]  tag_rd_w [0:NUM_WAYS-1];
  // The read path asks for the AR's set while idle and for the same set -- now
  // registered in rd_set -- for the rest of the transaction, so one port serves
  // both halves of the lookup.
  assign tag_rd_addr_r = (rd_state == RD_IDLE) ? s_araddr[OFF_BITS +: SET_BITS] : rd_set;
  // The write FSM looks up the set of the line its burst is currently on.
  wire [SET_BITS-1:0]  tag_rd_addr_w = wr_cur_line[OFF_BITS +: SET_BITS];

  genvar gt, gs;
  generate
    for (gt = 0; gt < NUM_WAYS; gt++) begin : g_tag
      // `initial` is memory initialisation ($meminit), not a clocked reset: it
      // keeps simulation deterministic without giving the array a reset port.
      (* ram_style = "distributed" *)
      logic [TAG_BITS-1:0] tag_bank [0:NUM_SETS-1];
      initial begin
        for (int s = 0; s < NUM_SETS; s++) tag_bank[s] = '0;
      end
      always_ff @(posedge i_clk) begin
        if (rd_state == RD_ALLOC && !rd_hit && rd_way == gt[WAY_BITS-1:0])
          tag_bank[rd_set] <= rd_tag;
      end
      assign tag_rd_r[gt] = tag_bank[tag_rd_addr_r];
      assign tag_rd_w[gt] = tag_bank[tag_rd_addr_w];
    end
  endgenerate
  logic                          valid_mem  [0:NUM_WAYS-1][0:NUM_SETS-1];
  // The directory's own validity, separate from the data's.  A write-through
  // leaves the L2 without the line's data but with an L1 that still holds it, so
  // the tag and the sharer vector have to outlive valid_mem or the next write to
  // the line invalidates nobody.  Set wherever valid_mem is set; kept when a
  // write-through clears it.
  logic                          dir_mem    [0:NUM_WAYS-1][0:NUM_SETS-1];
  // Line data storage: one simple-dual-port BRAM per (way, word) - 16 total
  // for the default geometry.  As flops this array alone is
  // NUM_WAYS*NUM_SETS*WORDS_PER_LINE*DATA_WIDTH = 524,288 FFs (4x the
  // xc7a200t's entire FF budget); as block RAM it is 16 RAMB36s of 365
  // available.  Access pattern (checked against both FSMs):
  //   * reads: RD_LOOKUP hit-capture and the RD_HIT_SERVE prime - both consume
  //     the line addressed by the AR accepted in the previous cycle;
  //   * write: RD_ALLOC only, one beat-word each, address registered two
  //     cycles earlier;
  //   * the write FSM never touches data_mem (write-through, no allocate).
  // So the read-issue cycle (RD_IDLE) never overlaps the write cycle
  // (RD_ALLOC) and the mapping is race-free.
  // Registered BRAM read outputs: all ways/words of the AR-addressed set are
  // read at AR-accept (RD_IDLE); outputs are stable during RD_LOOKUP, where
  // the registered hit way selects them.  Timing is identical to the
  // pre-BRAM code: the old code read data_mem during the RD_LOOKUP cycle and
  // registered it into rd_stage/rd_serve_q at the same edge at which this
  // pipeline delivers the same value.
  //
  // The storage itself is NUM_WAYS*WORDS_PER_LINE independent simple-dual-port
  // banks (one per (way, word) plane) instead of one 3-D array: Vivado cannot
  // map a [way][set][word] array to BRAM (Synth 8-11357 "3D-RAM" warning; the
  // array silently falls back to 524,288 registers), but each 2-D
  // NUM_SETS x DATA_WIDTH plane infers one RAMB36.  Write priority over read
  // on the shared clock edge is the standard SDP behaviour; the two events
  // never coincide anyway (RD_IDLE read issue vs RD_ALLOC write, disjoint
  // FSM states).
`ifdef USE_SKY130_SRAM
  // Foundry SRAM (`USE_SKY130_SRAM`, the SKY130 ASIC flow): the same 16 banks,
  // built from the PDK's sky130_sram_2kbyte_1rw1r_32x512_8 -- 512 words x 32
  // bits, one read-write port and one independent read port, both with
  // registered outputs.  Two macros side by side make the 64-bit word;
  // NUM_SETS must be 512 and DATA_WIDTH a multiple of 32 (asserted below).
  //
  // Timing is the flop array's own, not an approximation of it: the read port
  // samples s_araddr and returns that set's word on the next cycle, which is
  // exactly when the old `data_q <= bank[s_araddr[...]]` register presented it
  // (RD_LOOKUP).  The write port is the old `bank[rd_set] <= rd_stage[gb]`
  // edge-qualified write.  A read and a write in the same cycle hit different
  // ports, and the read returns the pre-write word -- what the nonblocking
  // read did when both addresses were equal.  The two events never coincide
  // anyway (RD_IDLE read issue vs RD_ALLOC write).
  //
  // din0/wmask0 are active low on the macro: wmask0 all-zero writes all four
  // bytes, and csb0 low with web0 low is the write.
  wire [DATA_WIDTH-1:0] data_q [0:NUM_WAYS-1][0:WORDS_PER_LINE-1];

  genvar gw, gb;   // `gs` is declared with the tag banks above
  generate
    if (NUM_SETS > 512 || (DATA_WIDTH % 32) != 0) begin : g_bad_geometry
      initial begin
        $error("USE_SKY130_SRAM needs NUM_SETS <= 512 and DATA_WIDTH a multiple of 32");
      end
    end
    for (gw = 0; gw < NUM_WAYS; gw++) begin : g_way
      for (gb = 0; gb < WORDS_PER_LINE; gb++) begin : g_word
        wire wr = (rd_state == RD_ALLOC) && (rd_way == gw);
        // 9-bit macro addresses: the set field is narrower on a smaller cache
        // (tb_l2_coherent runs 16 sets) and zero-extends into the unused rows.
        wire [8:0] a_wr  = rd_set;
        wire [8:0] a_rd  = s_araddr[OFF_BITS +: SET_BITS];
        for (gs = 0; gs < DATA_WIDTH/32; gs++) begin : g_slice
          wire [31:0] dout;
          sky130_sram_2kbyte_1rw1r_32x512_8 u_sram (
            .clk0   (i_clk),
            .csb0   (~wr),
            .web0   (1'b0),
            .wmask0 (4'b0000),
            .addr0  (a_wr),
            .din0   (rd_stage[gb][gs*32 +: 32]),
            .dout0  (),
            .clk1   (i_clk),
            .csb1   (1'b0),
            .addr1  (a_rd),
            .dout1  (dout)
          );
          assign data_q[gw][gb][gs*32 +: 32] = dout;
        end
      end
    end
  endgenerate
`else
  logic [DATA_WIDTH-1:0] data_q [0:NUM_WAYS-1][0:WORDS_PER_LINE-1];

  genvar gw, gb;
  generate
    for (gw = 0; gw < NUM_WAYS; gw++) begin : g_way
      for (gb = 0; gb < WORDS_PER_LINE; gb++) begin : g_word
        (* ram_style = "block" *)
        logic [DATA_WIDTH-1:0] bank [0:NUM_SETS-1];
        always_ff @(posedge i_clk) begin
          if (rd_state == RD_ALLOC && rd_way == gw)
            bank[rd_set] <= rd_stage[gb];
          data_q[gw][gb] <= bank[s_araddr[OFF_BITS +: SET_BITS]];  // read port: next-cycle RD_LOOKUP data
        end
      end
    end
  endgenerate
`endif
  // Sharer vectors: one memory per way, the same shape as the tags -- one
  // whole-word write port and two addressed read ports.  The old array was
  // written a bit at a time (`sharers[w][set][src] <= 1`), which the frontend
  // cannot express on a memory: it expanded to 32,768 registers with a 512-way
  // address decoder each.
  //
  // The single-bit update (a hit adds the reader) is a read-modify-write here:
  // the word comes back on the read FSM's own read port, which is addressed at
  // rd_set for the whole transaction, so the OR is against the entry's current
  // vector.  No reset, for the same reason as the tags: dir_mem gates every
  // read, and the alloc replaces the vector unless it is reusing a live
  // dir-only entry (rd_same_tag).
  wire [NUM_SRC-1:0]    sh_rd_r [0:NUM_WAYS-1];   // addressed by rd_set
  wire [NUM_SRC-1:0]    sh_rd_w [0:NUM_WAYS-1];   // addressed by the write burst's line
  // One write command per way.  The read and write FSMs can update DIFFERENT
  // ways in the same cycle (an alloc while a write-through drops another line),
  // and the old single always_ff let both land; one shared command would lose
  // one of them.  Where they target the SAME way the write path still wins,
  // which is the order the old block gave by putting the write path last.
  logic [NUM_WAYS-1:0]  sh_we;
  logic [SET_BITS-1:0]  sh_wset [0:NUM_WAYS-1];
  logic [NUM_SRC-1:0]   sh_wdat [0:NUM_WAYS-1];

  generate
    for (gt = 0; gt < NUM_WAYS; gt++) begin : g_sharer
      (* ram_style = "distributed" *)
      logic [NUM_SRC-1:0] sharer_bank [0:NUM_SETS-1];
      initial begin
        for (int s = 0; s < NUM_SETS; s++) sharer_bank[s] = '0;
      end
      always_ff @(posedge i_clk) begin
        if (sh_we[gt]) sharer_bank[sh_wset[gt]] <= sh_wdat[gt];
      end
      assign sh_rd_r[gt] = sharer_bank[rd_set];
      assign sh_rd_w[gt] = sharer_bank[wr_cur_line[OFF_BITS +: SET_BITS]];
    end
  endgenerate

  // Sharer-vector write commands, lowest priority first, in exactly the order
  // the statements they replace appeared in the old shared always_ff.
  always_comb begin
    for (int w = 0; w < NUM_WAYS; w++) begin
      sh_we[w]   = 1'b0;
      sh_wset[w] = rd_set;
      sh_wdat[w] = '0;
    end

    // Read path: a hit adds the reader to the line's sharers.
    if (rd_state == RD_LOOKUP && rd_hit) begin
      for (int w = 0; w < NUM_WAYS; w++)
        if (rd_hit_way[w]) begin
          sh_we[w]   = 1'b1;
          sh_wset[w] = rd_set;
          sh_wdat[w] = sh_rd_r[w] | (SRC_ONE << rd_src);
        end
    end
    // Read path: the evicted line's sharers are gone.
    if (rd_state == RD_EVICT_INV && (i_inv_ack & rd_evict_mask) == rd_evict_mask) begin
      sh_we[rd_way]   = 1'b1;
      sh_wset[rd_way] = rd_set;
      sh_wdat[rd_way] = '0;
    end
    // Read path: install the refilled line.  OR only when this way already held
    // the same tag as a dir-only entry -- that vector belongs to the earlier
    // writer, which still holds the line.  Any other way has been invalidated
    // (or was free), so a replace is what keeps a stale vector from surviving a
    // reset, which is no longer allowed to clear this array.
    if (rd_state == RD_ALLOC && !rd_hit) begin
      sh_we[rd_way]   = 1'b1;
      sh_wset[rd_way] = rd_set;
      sh_wdat[rd_way] = (rd_same_tag ? sh_rd_r[rd_way] : '0) | (SRC_ONE << rd_src);
    end
    // Write path: a write-through leaves the writer holding the line and nobody
    // else; a writer with no invalidation port (the NPU's DMA) leaves the way
    // genuinely free.
    if (wr_state == WR_INV && wr_hit && (i_inv_ack & wr_inv_mask) == wr_inv_mask) begin
      sh_we[wr_way]   = 1'b1;
      sh_wset[wr_way] = wr_set;
      sh_wdat[wr_way] = (inv_port_of_src[wr_id] != '0) ? (SRC_ONE << wr_id) : '0;
    end
  end

  logic [WAY_BITS-1:0]           victim_cnt [0:NUM_SETS-1];

  integer i, j;
  initial begin
    for (i = 0; i < NUM_WAYS; i++)
      for (j = 0; j < NUM_SETS; j++) begin
        valid_mem[i][j] = 1'b0;
        dir_mem[i][j]   = 1'b0;
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
        wr_log_match_idx = e;
    wr_log_match_idx = -1;
  endfunction

  // ===========================================================================
  // READ PATH (independent FSM)
  // ===========================================================================
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
      rd_beat        <= '0;   // serve/refill beat counter lives in this block too
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
            rd_same_tag <= 1'b0;
            // Registered hit for the incoming address (used by RD_LOOKUP and
            // the shared array-write block on the following cycle).  tag_rd_r
            // is this set's tag on each way: the bank read port is addressed
            // by s_araddr while the FSM is idle, so the compare is still
            // against the AR being accepted.
            begin
              logic [NUM_WAYS-1:0] hitw;
              hitw = '0;
              for (int w = 0; w < NUM_WAYS; w++)
                if (valid_mem[w][s_araddr[OFF_BITS +: SET_BITS]] &&
                    tag_rd_r[w] == s_araddr[ADDR_WIDTH-1 -: TAG_BITS])
                  hitw[w] = 1'b1;
              rd_hit_way <= hitw;
              rd_hit     <= |hitw;
            end
            // Only an L1 fills: the directory can invalidate an L1 and nobody
            // else.  Length alone let an NPU read of exactly four beats (a
            // 32-byte B operand, say) allocate a line with no invalidatable
            // sharer, evicting a CPU line to do it -- and serve that NPU's
            // next read from the copy, which is stale the moment anything
            // writes DDR without passing through here, as a testbench
            // backdoor preload does.
            if (s_arlen == WORDS_PER_LINE-1 && s_araddr[OFF_BITS-1:0] == '0 &&
                inv_port_of_src[s_arid] != '0)
              rd_state <= RD_LOOKUP;
            else
              rd_state <= RD_BYPASS_AR;
          end
        end

        RD_LOOKUP: begin
          if (rd_hit) begin
            // Capture the line into the staging register; the reader is added
            // to the line's sharers by the write-command block.
            for (int w = 0; w < NUM_WAYS; w++)
              if (rd_hit_way[w]) begin
                rd_way <= w[WAY_BITS-1:0];
                for (int b = 0; b < WORDS_PER_LINE; b++)
                  rd_stage[b] <= data_q[w][b];
              end
            rd_state <= RD_HIT_SERVE;
            rd_beat  <= '0;   // single-writer: serve counter restarts here
          end else begin
            // Miss.  A dir-only entry for this very tag is the one way that must
            // be reused rather than passed over: allocating the tag elsewhere
            // would leave the set holding one line twice, its sharers split
            // between the two entries, and a later write would invalidate only
            // the entry its lookup happened to find.  No eviction for that case
            // -- it is the same line, so the sharer's copy is still current, a
            // write-through having put the same bytes in DDR that this refill is
            // about to bring back.
            begin
              logic [WAY_BITS-1:0] pick;
              logic                same_tag;
              same_tag = 1'b0;
              pick     = victim_cnt[rd_set];
              // The bank read port is addressed at rd_set from the cycle after
              // the AR was accepted, so tag_rd_r/sh_rd_r are this set's entries
              // here.
              for (int w = 0; w < NUM_WAYS; w++)
                if (dir_mem[w][rd_set] && tag_rd_r[w] == rd_tag) begin
                  same_tag = 1'b1;
                  pick     = w[WAY_BITS-1:0];
                end
              rd_way      <= pick;
              rd_same_tag <= same_tag;
              // Either kind of entry occupies a way it is taking over.  A
              // dir-only line holds no data but does hold a sharer, and reusing
              // its way for another tag without invalidating that sharer loses
              // the entry exactly as the write-through used to.
              if (!same_tag &&
                  (valid_mem[pick][rd_set] || dir_mem[pick][rd_set]) &&
                  sh_rd_r[pick] != '0) begin
                rd_evict_mask <= inv_mask_of_sharers(sh_rd_r[pick]);
                rd_state      <= RD_EVICT_INV;
              end else begin
                rd_state <= RD_REFILL_AR;
              end
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
            rd_beat           <= '0;   // refill beat counter resets on AR accept
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
            rd_beat <= rd_beat + 1'b1;   // advance the refill beat counter
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
              rd_state <= RD_HIT_SERVE;   // fresh data: serve the staged line
              rd_beat  <= '0;             // restart the serve counter
            end
          end
        end

        RD_HIT_SERVE: begin
          if (s_rvalid && s_rready) begin
            rd_beat <= rd_beat + 1'b1;   // advance the serve beat counter
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
          if (rd_hit_way[w]) rd_serve_q <= data_q[w][0];
      end
      else if (rd_state == RD_HIT_SERVE && s_rvalid && s_rready && !s_rlast)
        rd_serve_q <= rd_stage[rd_beat + 1];
    end
  end

  // ---------------------------------------------------------------------------
  // Shared directory-validity writes (single always_ff: read path + write path)
  // ---------------------------------------------------------------------------
  // Only the two 2048-bit arrays live here now.  They keep their clocked bulk
  // reset: they are one bit wide each, so Yosys expanding them to flops is what
  // is wanted, and a reset that reboots firmware from DDR (rewritten behind the
  // L2's back by a loader/bootrom) must not let the L2 serve stale lines from
  // the previous boot.  The tag and sharer banks are memories and deliberately
  // have no reset -- these two gates make their stale entries unreachable.
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      for (int w = 0; w < NUM_WAYS; w++)
        for (int j = 0; j < NUM_SETS; j++) begin
          valid_mem[w][j] <= 1'b0;
          dir_mem[w][j]   <= 1'b0;
        end
    end else begin
      // Read path.  The sharer vectors are written by the command block above;
      // only the validity bits are written here.
      if (rd_state == RD_EVICT_INV && (i_inv_ack & rd_evict_mask) == rd_evict_mask) begin
        valid_mem[rd_way][rd_set] <= 1'b0;
        dir_mem[rd_way][rd_set]   <= 1'b0;
      end
      // Install a refilled line.  Only a miss allocates.  A hit reaches
      // RD_ALLOC too -- every serve ends there -- but its line is already
      // resident and RD_LOOKUP has already added the reader to its sharers.
      // Re-installing it replaced the sharer set with this reader alone, so a
      // later write left every other L1 holding its pre-write copy; and if a
      // write dropped the line mid-serve, it put the pre-write data back.
      // tb_l2_coherent T8 and T9 cover both, independent of write timing.
      // tag_mem itself is written by the g_tag distributed-RAM banks (way
      // select via the generate guard; the banks carry the same !rd_hit
      // guard), so only valid/sharers are installed here.
      if (rd_state == RD_ALLOC && !rd_hit) begin
        valid_mem[rd_way][rd_set] <= 1'b1;
        dir_mem[rd_way][rd_set]   <= 1'b1;
        // The sharer vector is installed by the command block: OR, not replace,
        // when this way already held the tag as a dir-only entry (rd_same_tag) --
        // that vector is the earlier writer's, which still holds the line.  A
        // way taken for a different tag has had its sharers invalidated and
        // cleared by RD_EVICT_INV before this runs, and a free way's set is
        // replaced outright.
        // Line data: written by the g_way/g_word generate banks (one bank
        // captures rd_stage[gb] when rd_way matches its way).
      end
      // Write path: drop the line (wins over a same-cycle alloc: the write
      // is the newer event).
      // Only a line that was actually resident is dropped; a miss has no way
      // or set worth touching (wr_way/wr_set still hold the previous line).
      if (wr_state == WR_INV && wr_hit && (i_inv_ack & wr_inv_mask) == wr_inv_mask) begin
        // The data goes: after a write-through the L2's copy is stale.
        valid_mem[wr_way][wr_set] <= 1'b0;
        // The directory stays, and says what is true -- the writer holds this
        // line in its L1 and nobody else does.  Clearing it here is what let a
        // later write invalidate nobody, so a driver that cleared C before a GEMM
        // read its own zeros back afterwards (CPU document 3.3).
        // The matching sharer vector is written by the command block.
        if (inv_port_of_src[wr_id] != '0) begin
          dir_mem[wr_way][wr_set] <= 1'b1;
        end else begin
          // A writer with no L1 to invalidate -- the NPU's DMA -- is not worth an
          // entry, so the way is left genuinely free.
          dir_mem[wr_way][wr_set] <= 1'b0;
        end
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
  always_comb begin
    // Bytes covered by the burst, from the incoming AW (awsize is in bytes as
    // a log2, so 1<<awsize is the beat size; beats = awlen+1).
    wr_bytes_c   = (32'd1 << s_awsize) * ({24'b0, s_awlen} + 32'd1);
    wr_off_end_c = {27'b0, s_awaddr[OFF_BITS-1:0]} + wr_bytes_c - 32'd1;
    wr_nlines_c  = wr_off_end_c[OFF_BITS+7:OFF_BITS] + 8'd1;
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      wr_state  <= WR_IDLE;
      wr_addr   <= '0;
      wr_id     <= '0;
      wr_len    <= '0;
      wr_inv_mask <= '0;
      wr_entry  <= '0;
      aw_ok     <= 1'b0;
      wr_nlines   <= 8'd1;
      wr_line_idx <= 8'd0;
      wr_cur_line <= '0;
      wr_hit      <= 1'b0;
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
            // Walk every 32B line of the burst, starting at the first one.
            // The directory lookup happens in WR_LOOKUP (next cycle), off the
            // registered wr_cur_line, so it can never read a stale wr_set/
            // wr_tag from the previous transaction.
            wr_nlines   <= wr_nlines_c;
            wr_line_idx <= 8'd0;
            wr_cur_line <= {s_awaddr[ADDR_WIDTH-1:OFF_BITS], {OFF_BITS{1'b0}}};
            wr_state    <= WR_LOOKUP;
          end
        end

        // Directory lookup for the line in wr_cur_line.  Registers the hit,
        // way and sharer mask; WR_INV then holds the invalidations until the
        // L1s ack and drops the L2 copy.
        WR_LOOKUP: begin
          begin
            logic hit;
            hit = 1'b0;
            wr_hit      <= 1'b0;
            wr_inv_mask <= '0;
            for (int w = 0; w < NUM_WAYS; w++)
              // dir_mem, not valid_mem: a line whose data this L2 dropped on an
              // earlier write-through is still one whose sharers it must
              // invalidate.  That is the whole fix.
              if (dir_mem[w][wr_cur_line[OFF_BITS +: SET_BITS]] &&
                  tag_rd_w[w] == wr_cur_line[ADDR_WIDTH-1 -: TAG_BITS]) begin
                hit         = 1'b1;
                wr_hit      <= 1'b1;
                wr_way      <= w[WAY_BITS-1:0];
                wr_set      <= wr_cur_line[OFF_BITS +: SET_BITS];
                wr_tag      <= wr_cur_line[ADDR_WIDTH-1 -: TAG_BITS];
                wr_inv_mask <= inv_mask_of_sharers(sh_rd_w[w]) & ~inv_port_of_src[wr_id];
              end
          end
          wr_state <= WR_INV;
        end

        WR_INV: begin
          // A miss has an empty mask, so this completes immediately and only
          // advances to the next line -- no L2 line is dropped for a miss.
          if ((i_inv_ack & wr_inv_mask) == wr_inv_mask) begin
            if (wr_line_idx + 8'd1 < wr_nlines) begin
              wr_line_idx <= wr_line_idx + 8'd1;
              wr_cur_line <= wr_cur_line + LINE_BYTES;
              wr_state    <= WR_LOOKUP;
            end else begin
              wr_state <= WR_FWD;
            end
          end
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
      inv_addr_c  = wr_cur_line;   // the line currently being invalidated
    end
  end
  assign o_inv_valid = inv_valid_c;
  assign o_inv_addr  = inv_addr_c;

endmodule