// -----------------------------------------------------------------------------
// c930_axi_dma_arb.sv
//
// AXI4 round-robin arbiter: merges 2 NPU DMA masters into 1 shared port.
// Used for dual-NPU configurations where both NPUs share DDR bandwidth.
//
// The arbiter round-robins between m0 (NPU0 DMA) and m1 (NPU1 DMA),
// forwarding whichever has an active request to the shared s (slave) port.
// Only one transaction is active at a time; the other master waits.
//
// AXI4 ID signals are preserved with a 1-bit prefix (0/1) so responses
// can be routed back to the correct master.
// -----------------------------------------------------------------------------
module c930_axi_dma_arb
#(
  parameter int ADDR_WIDTH = 64,
  parameter int DATA_WIDTH = 64,
  parameter int ID_WIDTH   = 4
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- Master 0: NPU0 DMA ----
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

  // ---- Master 1: NPU1 DMA ----
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

  // ---- Shared slave port (to crossbar M2) ----
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

  // =========================================================================
  // Read channel arbitration
  // =========================================================================
  // Which master currently owns the read channel: 0=NPU0, 1=NPU1
  logic       rd_owner;      // registered owner (1 bit)
  logic       rd_active;     // read transaction in progress
  logic       rd_rr;         // round-robin flip-flop

  // Read request from each master (valid and not yet granted)
  wire rd_req0 = m0_arvalid && (!rd_active && !rd_addr_phase || (rd_owner == 0));
  wire rd_req1 = m1_arvalid && (!rd_active && !rd_addr_phase || (rd_owner == 1));

  // Grant selection: round-robin when both request, prioritize current owner
  logic rd_grant0, rd_grant1;
  always_comb begin
    rd_grant0 = 1'b0;
    rd_grant1 = 1'b0;
    if (rd_active || rd_addr_phase) begin
      if (rd_owner == 1'b0) rd_grant0 = 1'b1;
      else                  rd_grant1 = 1'b1;
    end else begin
      // New transaction: round-robin
      if (rd_rr == 1'b0) begin
        if (rd_req0) rd_grant0 = 1'b1;
        else if (rd_req1) rd_grant1 = 1'b1;
      end else begin
        if (rd_req1) rd_grant1 = 1'b1;
        else if (rd_req0) rd_grant0 = 1'b1;
      end
    end
  end

  // Read channel state machine
  // rd_addr_phase: high from grant until address handshake completes
  // rd_active: high from address handshake completion until rlast
  logic rd_addr_phase;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rd_active     <= 1'b0;
      rd_addr_phase <= 1'b0;
      rd_owner      <= 1'b0;
      rd_rr         <= 1'b0;
    end else begin
      if (!rd_active && !rd_addr_phase) begin
        if (rd_grant0 || rd_grant1) begin
          rd_addr_phase <= 1'b1;
          rd_owner       <= rd_grant1 ? 1'b1 : 1'b0;
          rd_rr          <= rd_grant1 ? 1'b0 : 1'b1;
        end
      end else if (rd_addr_phase) begin
        // Address handshake in progress — wait for slave accept
        if (s_arvalid && s_arready) begin
          rd_addr_phase <= 1'b0;
          rd_active     <= 1'b1;  // data phase starts
        end
      end else begin
        // Data phase — wait for last data beat
        if (s_rvalid && s_rready && s_rlast) begin
          rd_active <= 1'b0;
        end
      end
    end
  end

  // Read address channel mux
  assign s_arid    = rd_owner ? m1_arid    : m0_arid;
  assign s_araddr  = rd_owner ? m1_araddr  : m0_araddr;
  assign s_arlen   = rd_owner ? m1_arlen   : m0_arlen;
  assign s_arsize  = rd_owner ? m1_arsize  : m0_arsize;
  assign s_arburst = rd_owner ? m1_arburst : m0_arburst;
  assign s_arvalid = rd_addr_phase && (rd_owner ? m1_arvalid : m0_arvalid);

  // Read address ready: only during address phase, to the granted master
  assign m0_arready = rd_addr_phase && (rd_owner == 1'b0) && s_arready;
  assign m1_arready = rd_addr_phase && (rd_owner == 1'b1) && s_arready;

  // Read data channel: forward from slave to the owner
  assign m0_rdata  = s_rdata;
  assign m0_rresp  = s_rresp;
  assign m0_rlast  = s_rlast;
  assign m0_rvalid = s_rvalid && (rd_owner == 1'b0);
  assign m0_rid    = s_rid;

  assign m1_rdata  = s_rdata;
  assign m1_rresp  = s_rresp;
  assign m1_rlast  = s_rlast;
  assign m1_rvalid = s_rvalid && (rd_owner == 1'b1);
  assign m1_rid    = s_rid;

  assign s_rready = rd_owner ? m1_rready : m0_rready;

  // =========================================================================
  // Write channel arbitration
  // =========================================================================
  logic       wr_owner;      // registered owner
  logic       wr_active;     // write transaction in progress
  logic       wr_rr;         // round-robin flip-flop

  wire wr_req0 = m0_awvalid && (!wr_active && !wr_addr_phase || (wr_owner == 0));
  wire wr_req1 = m1_awvalid && (!wr_active && !wr_addr_phase || (wr_owner == 1));

  logic wr_grant0, wr_grant1;
  always_comb begin
    wr_grant0 = 1'b0;
    wr_grant1 = 1'b0;
    if (wr_active || wr_addr_phase) begin
      if (wr_owner == 1'b0) wr_grant0 = 1'b1;
      else                  wr_grant1 = 1'b1;
    end else begin
      if (wr_rr == 1'b0) begin
        if (wr_req0) wr_grant0 = 1'b1;
        else if (wr_req1) wr_grant1 = 1'b1;
      end else begin
        if (wr_req1) wr_grant1 = 1'b1;
        else if (wr_req0) wr_grant0 = 1'b1;
      end
    end
  end

  logic wr_addr_phase;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      wr_active      <= 1'b0;
      wr_addr_phase  <= 1'b0;
      wr_owner       <= 1'b0;
      wr_rr          <= 1'b0;
    end else begin
      if (!wr_active && !wr_addr_phase) begin
        if (wr_grant0 || wr_grant1) begin
          wr_addr_phase <= 1'b1;
          wr_owner       <= wr_grant1 ? 1'b1 : 1'b0;
          wr_rr          <= wr_grant1 ? 1'b0 : 1'b1;
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

  // Write address channel mux
  assign s_awid    = wr_owner ? m1_awid    : m0_awid;
  assign s_awaddr  = wr_owner ? m1_awaddr  : m0_awaddr;
  assign s_awlen   = wr_owner ? m1_awlen   : m0_awlen;
  assign s_awsize  = wr_owner ? m1_awsize  : m0_awsize;
  assign s_awburst = wr_owner ? m1_awburst : m0_awburst;
  assign s_awvalid = wr_addr_phase && (wr_owner ? m1_awvalid : m0_awvalid);

  assign m0_awready = wr_addr_phase && (wr_owner == 1'b0) && s_awready;
  assign m1_awready = wr_addr_phase && (wr_owner == 1'b1) && s_awready;

  // Write data channel: forward from owner to slave
  assign s_wdata  = wr_owner ? m1_wdata  : m0_wdata;
  assign s_wstrb  = wr_owner ? m1_wstrb  : m0_wstrb;
  assign s_wlast  = wr_owner ? m1_wlast  : m0_wlast;
  assign s_wvalid = wr_active && (wr_owner ? m1_wvalid : m0_wvalid);

  assign m0_wready = s_wready && (wr_owner == 1'b0);
  assign m1_wready = s_wready && (wr_owner == 1'b1);

  // Write response channel: forward from slave to the owner
  assign m0_bid    = s_bid;
  assign m0_bresp  = s_bresp;
  assign m0_bvalid = s_bvalid && (wr_owner == 1'b0);

  assign m1_bid    = s_bid;
  assign m1_bresp  = s_bresp;
  assign m1_bvalid = s_bvalid && (wr_owner == 1'b1);

  assign s_bready = wr_owner ? m1_bready : m0_bready;

endmodule
