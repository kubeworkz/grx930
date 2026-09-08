// -----------------------------------------------------------------------------
// c930_axi_dma_arb.sv
//
// AXI4 round-robin arbiter: merges up to 4 masters into 1 shared port.
// Originally a 2-input NPU DMA merge; widened to 4 inputs so the shared
// crossbar ports can also carry CPU2/CPU3 cache traffic:
//   * u_dma_arb    (crossbar M2): NPU0 DMA, NPU1 DMA, CPU3 I-cache, CPU3 D-cache
//   * u_core1_arb  (crossbar M3): CPU1 I-cache, CPU1 D-cache, CPU2 I-cache, CPU2 D-cache
//
// Only one transaction is active at a time; the others wait.  Round-robin
// ordering keeps any single master from starving the port.  AXI4 ID values
// pass through unchanged -- responses are routed back purely by the
// registered owner, so no ID remapping is needed.
// -----------------------------------------------------------------------------
module c930_axi_dma_arb
#(
  parameter int ADDR_WIDTH = 64,
  parameter int DATA_WIDTH = 64,
  parameter int ID_WIDTH   = 4,
  // 2-bit base for the re-stamped source IDs ({base, owner}).  Shared L2 map:
  //   2'b01 -> 4..7   = CPU1-I/D, CPU2-I/D   (arb1)
  //   2'b10 -> 8..11  = NPU0, NPU1, CPU3-I/D (dma arb)
  parameter logic [1:0] ARB_ID_BASE = 2'b00
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- Master 0 ----
  input  logic [ID_WIDTH-1:0]    m0_awid,
  input  logic [ADDR_WIDTH-1:0]  m0_awaddr,
  input  logic [7:0]             m0_awlen,
  input  logic [2:0]             m0_awsize,
  input  logic [1:0]             m0_awburst,
  input  logic                   m0_awvalid,
  output logic                   m0_awready,
  input  logic [DATA_WIDTH-1:0]  m0_wdata,
  input  logic [DATA_WIDTH/8-1:0] m0_wstrb,
  input  logic                   m0_wlast,
  input  logic                   m0_wvalid,
  output logic                   m0_wready,
  output logic [ID_WIDTH-1:0]    m0_bid,
  output logic [1:0]             m0_bresp,
  output logic                   m0_bvalid,
  input  logic                   m0_bready,
  input  logic [ID_WIDTH-1:0]    m0_arid,
  input  logic [ADDR_WIDTH-1:0]  m0_araddr,
  input  logic [7:0]             m0_arlen,
  input  logic [2:0]             m0_arsize,
  input  logic [1:0]             m0_arburst,
  input  logic                   m0_arvalid,
  output logic                   m0_arready,
  output logic [ID_WIDTH-1:0]    m0_rid,
  output logic [DATA_WIDTH-1:0]  m0_rdata,
  output logic [1:0]             m0_rresp,
  output logic                   m0_rlast,
  output logic                   m0_rvalid,
  input  logic                   m0_rready,

  // ---- Master 1 ----
  input  logic [ID_WIDTH-1:0]    m1_awid,
  input  logic [ADDR_WIDTH-1:0]  m1_awaddr,
  input  logic [7:0]             m1_awlen,
  input  logic [2:0]             m1_awsize,
  input  logic [1:0]             m1_awburst,
  input  logic                   m1_awvalid,
  output logic                   m1_awready,
  input  logic [DATA_WIDTH-1:0]  m1_wdata,
  input  logic [DATA_WIDTH/8-1:0] m1_wstrb,
  input  logic                   m1_wlast,
  input  logic                   m1_wvalid,
  output logic                   m1_wready,
  output logic [ID_WIDTH-1:0]    m1_bid,
  output logic [1:0]             m1_bresp,
  output logic                   m1_bvalid,
  input  logic                   m1_bready,
  input  logic [ID_WIDTH-1:0]    m1_arid,
  input  logic [ADDR_WIDTH-1:0]  m1_araddr,
  input  logic [7:0]             m1_arlen,
  input  logic [2:0]             m1_arsize,
  input  logic [1:0]             m1_arburst,
  input  logic                   m1_arvalid,
  output logic                   m1_arready,
  output logic [ID_WIDTH-1:0]    m1_rid,
  output logic [DATA_WIDTH-1:0]  m1_rdata,
  output logic [1:0]             m1_rresp,
  output logic                   m1_rlast,
  output logic                   m1_rvalid,
  input  logic                   m1_rready,

  // ---- Master 2 ----
  input  logic [ID_WIDTH-1:0]    m2_awid,
  input  logic [ADDR_WIDTH-1:0]  m2_awaddr,
  input  logic [7:0]             m2_awlen,
  input  logic [2:0]             m2_awsize,
  input  logic [1:0]             m2_awburst,
  input  logic                   m2_awvalid,
  output logic                   m2_awready,
  input  logic [DATA_WIDTH-1:0]  m2_wdata,
  input  logic [DATA_WIDTH/8-1:0] m2_wstrb,
  input  logic                   m2_wlast,
  input  logic                   m2_wvalid,
  output logic                   m2_wready,
  output logic [ID_WIDTH-1:0]    m2_bid,
  output logic [1:0]             m2_bresp,
  output logic                   m2_bvalid,
  input  logic                   m2_bready,
  input  logic [ID_WIDTH-1:0]    m2_arid,
  input  logic [ADDR_WIDTH-1:0]  m2_araddr,
  input  logic [7:0]             m2_arlen,
  input  logic [2:0]             m2_arsize,
  input  logic [1:0]             m2_arburst,
  input  logic                   m2_arvalid,
  output logic                   m2_arready,
  output logic [ID_WIDTH-1:0]    m2_rid,
  output logic [DATA_WIDTH-1:0]  m2_rdata,
  output logic [1:0]             m2_rresp,
  output logic                   m2_rlast,
  output logic                   m2_rvalid,
  input  logic                   m2_rready,

  // ---- Master 3 ----
  input  logic [ID_WIDTH-1:0]    m3_awid,
  input  logic [ADDR_WIDTH-1:0]  m3_awaddr,
  input  logic [7:0]             m3_awlen,
  input  logic [2:0]             m3_awsize,
  input  logic [1:0]             m3_awburst,
  input  logic                   m3_awvalid,
  output logic                   m3_awready,
  input  logic [DATA_WIDTH-1:0]  m3_wdata,
  input  logic [DATA_WIDTH/8-1:0] m3_wstrb,
  input  logic                   m3_wlast,
  input  logic                   m3_wvalid,
  output logic                   m3_wready,
  output logic [ID_WIDTH-1:0]    m3_bid,
  output logic [1:0]             m3_bresp,
  output logic                   m3_bvalid,
  input  logic                   m3_bready,
  input  logic [ID_WIDTH-1:0]    m3_arid,
  input  logic [ADDR_WIDTH-1:0]  m3_araddr,
  input  logic [7:0]             m3_arlen,
  input  logic [2:0]             m3_arsize,
  input  logic [1:0]             m3_arburst,
  input  logic                   m3_arvalid,
  output logic                   m3_arready,
  output logic [ID_WIDTH-1:0]    m3_rid,
  output logic [DATA_WIDTH-1:0]  m3_rdata,
  output logic [1:0]             m3_rresp,
  output logic                   m3_rlast,
  output logic                   m3_rvalid,
  input  logic                   m3_rready,

  // ---- Shared slave port (to crossbar) ----
  output logic [ID_WIDTH-1:0]    s_awid,
  output logic [ADDR_WIDTH-1:0]  s_awaddr,
  output logic [7:0]             s_awlen,
  output logic [2:0]             s_awsize,
  output logic [1:0]             s_awburst,
  output logic                   s_awvalid,
  input  logic                   s_awready,
  output logic [DATA_WIDTH-1:0]  s_wdata,
  output logic [DATA_WIDTH/8-1:0] s_wstrb,
  output logic                   s_wlast,
  output logic                   s_wvalid,
  input  logic                   s_wready,
  input  logic [ID_WIDTH-1:0]    s_bid,
  input  logic [1:0]             s_bresp,
  input  logic                   s_bvalid,
  output logic                   s_bready,
  output logic [ID_WIDTH-1:0]    s_arid,
  output logic [ADDR_WIDTH-1:0]  s_araddr,
  output logic [7:0]             s_arlen,
  output logic [2:0]             s_arsize,
  output logic [1:0]             s_arburst,
  output logic                   s_arvalid,
  input  logic                   s_arready,
  input  logic [ID_WIDTH-1:0]    s_rid,
  input  logic [DATA_WIDTH-1:0]  s_rdata,
  input  logic [1:0]             s_rresp,
  input  logic                   s_rlast,
  input  logic                   s_rvalid,
  output logic                   s_rready
);

  localparam int NUM_M = 4;

  // Per-master input vectors (index = master number, packed as {m3,...,m0})
  logic [NUM_M-1:0][ID_WIDTH-1:0]    arid_v;
  logic [NUM_M-1:0][ADDR_WIDTH-1:0]  araddr_v;
  logic [NUM_M-1:0][7:0]             arlen_v;
  logic [NUM_M-1:0][2:0]             arsize_v;
  logic [NUM_M-1:0][1:0]             arburst_v;
  logic [NUM_M-1:0]                  arvalid_v;
  logic [NUM_M-1:0][ID_WIDTH-1:0]    awid_v;
  logic [NUM_M-1:0][ADDR_WIDTH-1:0]  awaddr_v;
  logic [NUM_M-1:0][7:0]             awlen_v;
  logic [NUM_M-1:0][2:0]             awsize_v;
  logic [NUM_M-1:0][1:0]             awburst_v;
  logic [NUM_M-1:0]                  awvalid_v;
  logic [NUM_M-1:0][DATA_WIDTH-1:0]  wdata_v;
  logic [NUM_M-1:0][DATA_WIDTH/8-1:0] wstrb_v;
  logic [NUM_M-1:0]                  wlast_v;
  logic [NUM_M-1:0]                  wvalid_v;
  logic [NUM_M-1:0]                  rready_v;
  logic [NUM_M-1:0]                  bready_v;

  assign arid_v    = {m3_arid, m2_arid, m1_arid, m0_arid};
  assign araddr_v  = {m3_araddr, m2_araddr, m1_araddr, m0_araddr};
  assign arlen_v   = {m3_arlen, m2_arlen, m1_arlen, m0_arlen};
  assign arsize_v  = {m3_arsize, m2_arsize, m1_arsize, m0_arsize};
  assign arburst_v = {m3_arburst, m2_arburst, m1_arburst, m0_arburst};
  assign arvalid_v = {m3_arvalid, m2_arvalid, m1_arvalid, m0_arvalid};
  assign awid_v    = {m3_awid, m2_awid, m1_awid, m0_awid};
  assign awaddr_v  = {m3_awaddr, m2_awaddr, m1_awaddr, m0_awaddr};
  assign awlen_v   = {m3_awlen, m2_awlen, m1_awlen, m0_awlen};
  assign awsize_v  = {m3_awsize, m2_awsize, m1_awsize, m0_awsize};
  assign awburst_v = {m3_awburst, m2_awburst, m1_awburst, m0_awburst};
  assign awvalid_v = {m3_awvalid, m2_awvalid, m1_awvalid, m0_awvalid};
  assign wdata_v   = {m3_wdata, m2_wdata, m1_wdata, m0_wdata};
  assign wstrb_v   = {m3_wstrb, m2_wstrb, m1_wstrb, m0_wstrb};
  assign wlast_v   = {m3_wlast, m2_wlast, m1_wlast, m0_wlast};
  assign wvalid_v  = {m3_wvalid, m2_wvalid, m1_wvalid, m0_wvalid};
  assign rready_v  = {m3_rready, m2_rready, m1_rready, m0_rready};
  assign bready_v  = {m3_bready, m2_bready, m1_bready, m0_bready};

  // =========================================================================
  // Read channel arbitration (round-robin over NUM_M masters)
  // =========================================================================
  logic [1:0] rd_owner;     // which master owns the read transaction
  logic       rd_active;    // read data phase in progress
  logic       rd_addr_phase;// address handshake in progress
  logic [1:0] rd_rr;        // round-robin pointer

  // Grant: pick the first requesting master at/after rd_rr (wrapping).
  logic [1:0] rd_owner_next;
  logic       rd_grant_valid;
  always_comb begin
    rd_owner_next  = '0;
    rd_grant_valid = 1'b0;
    // First requesting master at/after rd_rr (wrapping).  rd_grant_valid is
    // set once the first match is latched, guarding the remaining iterations
    // (an unrolled break -- iverilog rejects `break` in always_comb).
    for (int i = 0; i < NUM_M; i++) begin
      if (!rd_grant_valid && arvalid_v[(rd_rr + i) % NUM_M]) begin
        rd_owner_next  = (rd_rr + i) % NUM_M;
        rd_grant_valid = 1'b1;
      end
    end
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rd_active      <= 1'b0;
      rd_addr_phase  <= 1'b0;
      rd_owner       <= '0;
      rd_rr          <= '0;
    end else begin
      if (!rd_active && !rd_addr_phase) begin
        if (rd_grant_valid) begin
          rd_addr_phase <= 1'b1;
          rd_owner      <= rd_owner_next;
          rd_rr         <= (rd_owner_next + 1) % NUM_M;
        end
      end else if (rd_addr_phase) begin
        // Address handshake in progress — wait for slave accept
        if (s_arvalid && s_arready) begin
          rd_addr_phase <= 1'b0;
          rd_active     <= 1'b1;  // data phase starts
        end else if (!arvalid_v[rd_owner]) begin
          // The granted master withdrew arvalid before the handshake
          // completed (AXI allows withdrawal before acceptance).  Abandon
          // the pending grant so we don't strand the slave (crossbar/L2)
          // waiting on a transaction that will never present.
          rd_addr_phase <= 1'b0;
        end
      end else begin
        // Data phase — wait for last data beat
        if (s_rvalid && s_rready && s_rlast) begin
          rd_active <= 1'b0;
        end
      end
    end
  end

  // Read address channel: mux the granted owner's request.  The AXI ID is
  // re-stamped with {ARB_ID_BASE, owner} so the shared L2 can attribute the
  // transaction to a specific cache/NPU for its coherence directory.
  assign s_arid    = {ARB_ID_BASE[1:0], rd_owner};
  assign s_araddr  = araddr_v[rd_owner];
  assign s_arlen   = arlen_v[rd_owner];
  assign s_arsize  = arsize_v[rd_owner];
  assign s_arburst = arburst_v[rd_owner];
  assign s_arvalid = rd_addr_phase && arvalid_v[rd_owner];

  // Read address ready: only during the address phase, to the granted master
  assign m0_arready = rd_addr_phase && (rd_owner == 2'd0) && s_arready;
  assign m1_arready = rd_addr_phase && (rd_owner == 2'd1) && s_arready;
  assign m2_arready = rd_addr_phase && (rd_owner == 2'd2) && s_arready;
  assign m3_arready = rd_addr_phase && (rd_owner == 2'd3) && s_arready;

  // Read data channel: broadcast to all masters, gate valid by owner
  assign m0_rdata  = s_rdata;   assign m0_rresp = s_rresp;
  assign m0_rlast  = s_rlast;   assign m0_rid   = s_rid;
  assign m1_rdata  = s_rdata;   assign m1_rresp = s_rresp;
  assign m1_rlast  = s_rlast;   assign m1_rid   = s_rid;
  assign m2_rdata  = s_rdata;   assign m2_rresp = s_rresp;
  assign m2_rlast  = s_rlast;   assign m2_rid   = s_rid;
  assign m3_rdata  = s_rdata;   assign m3_rresp = s_rresp;
  assign m3_rlast  = s_rlast;   assign m3_rid   = s_rid;

  assign m0_rvalid = s_rvalid && (rd_owner == 2'd0);
  assign m1_rvalid = s_rvalid && (rd_owner == 2'd1);
  assign m2_rvalid = s_rvalid && (rd_owner == 2'd2);
  assign m3_rvalid = s_rvalid && (rd_owner == 2'd3);

  assign s_rready = rready_v[rd_owner];

  // =========================================================================
  // Write channel arbitration (round-robin over NUM_M masters)
  // =========================================================================
  logic [1:0] wr_owner;
  logic       wr_active;
  logic       wr_addr_phase;
  logic [1:0] wr_rr;

  logic [1:0] wr_owner_next;
  logic       wr_grant_valid;
  always_comb begin
    wr_owner_next  = '0;
    wr_grant_valid = 1'b0;
    // First requesting master at/after wr_rr (wrapping) -- see read side.
    for (int i = 0; i < NUM_M; i++) begin
      if (!wr_grant_valid && awvalid_v[(wr_rr + i) % NUM_M]) begin
        wr_owner_next  = (wr_rr + i) % NUM_M;
        wr_grant_valid = 1'b1;
      end
    end
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      wr_active      <= 1'b0;
      wr_addr_phase  <= 1'b0;
      wr_owner       <= '0;
      wr_rr          <= '0;
    end else begin
      if (!wr_active && !wr_addr_phase) begin
        if (wr_grant_valid) begin
          wr_addr_phase <= 1'b1;
          wr_owner      <= wr_owner_next;
          wr_rr         <= (wr_owner_next + 1) % NUM_M;
        end
      end else if (wr_addr_phase) begin
        if (s_awvalid && s_awready) begin
          wr_addr_phase <= 1'b0;
          wr_active     <= 1'b1;  // data phase starts
        end
      end else begin
        if (s_bvalid && s_bready) begin
          wr_active <= 1'b0;
        end
      end
    end
  end

  // Write address channel (ID re-stamped, see read channel note)
  assign s_awid    = {ARB_ID_BASE[1:0], wr_owner};
  assign s_awaddr  = awaddr_v[wr_owner];
  assign s_awlen   = awlen_v[wr_owner];
  assign s_awsize  = awsize_v[wr_owner];
  assign s_awburst = awburst_v[wr_owner];
  assign s_awvalid = wr_addr_phase && awvalid_v[wr_owner];

  assign m0_awready = wr_addr_phase && (wr_owner == 2'd0) && s_awready;
  assign m1_awready = wr_addr_phase && (wr_owner == 2'd1) && s_awready;
  assign m2_awready = wr_addr_phase && (wr_owner == 2'd2) && s_awready;
  assign m3_awready = wr_addr_phase && (wr_owner == 2'd3) && s_awready;

  // Write data channel
  assign s_wdata  = wdata_v[wr_owner];
  assign s_wstrb  = wstrb_v[wr_owner];
  assign s_wlast  = wlast_v[wr_owner];
  assign s_wvalid = wr_active && wvalid_v[wr_owner];

  assign m0_wready = s_wready && (wr_owner == 2'd0);
  assign m1_wready = s_wready && (wr_owner == 2'd1);
  assign m2_wready = s_wready && (wr_owner == 2'd2);
  assign m3_wready = s_wready && (wr_owner == 2'd3);

  // Write response channel
  assign m0_bid    = s_bid;    assign m0_bresp = s_bresp;
  assign m1_bid    = s_bid;    assign m1_bresp = s_bresp;
  assign m2_bid    = s_bid;    assign m2_bresp = s_bresp;
  assign m3_bid    = s_bid;    assign m3_bresp = s_bresp;

  assign m0_bvalid = s_bvalid && (wr_owner == 2'd0);
  assign m1_bvalid = s_bvalid && (wr_owner == 2'd1);
  assign m2_bvalid = s_bvalid && (wr_owner == 2'd2);
  assign m3_bvalid = s_bvalid && (wr_owner == 2'd3);

  assign s_bready = bready_v[wr_owner];

endmodule
