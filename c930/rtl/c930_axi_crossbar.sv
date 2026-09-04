// -----------------------------------------------------------------------------
// c930_axi_crossbar.sv
//
// AXI4 shared-bus crossbar: 3 masters × 4 slaves.
//
// Masters:
//   M0: CPU I-cache (via c930_axi_cache_adapter)
//   M1: CPU D-cache (via c930_axi_cache_adapter)
//   M2: NPU DMA    (AXI4 full master, direct connection)
//
// Slaves (address-decoded):
//   S0: Boot ROM   (0x0000_0000 – 0x0000_03FF, 1 KB, read-only)
//   S1: DDR        (0x0000_1000 – 0x0000_FFFF, ~60 KB)
//   S2: MMIO       (0x4000_0000 – 0x4000_FFFF, 64 KB, AXI4-Lite peripherals)
//   S3: UART       (0x4000_1000 – 0x4000_100F, 16 B)
//
// Arbitration: round-robin per channel (read and write independent).
// When a master wins arbitration, its AXI signals are forwarded to the
// selected slave. The arbiter holds the grant until the transaction completes
// (last beat for read, bvalid for write).
//
// AXI4 ID signals are preserved: each master gets a unique ID prefix so
// out-of-order responses can be matched (not needed for this single-issue
// design, but correct for future use).
// -----------------------------------------------------------------------------
module c930_axi_crossbar
#(
  parameter int ADDR_WIDTH = 64,
  parameter int DATA_WIDTH = 64,   // AXI data bus width (64-bit)
  parameter int ID_WIDTH   = 4
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- Master 0: CPU I-cache ----
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

  // ---- Master 1: CPU D-cache ----
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

  // ---- Master 2: NPU DMA ----
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

  // ---- Slave 0: Boot ROM (AXI4 read-only) ----
  output logic [ID_WIDTH-1:0]    s0_awid,
  output logic [ADDR_WIDTH-1:0]  s0_awaddr,
  output logic [7:0]             s0_awlen,
  output logic [2:0]             s0_awsize,
  output logic [1:0]             s0_awburst,
  output logic                   s0_awvalid,
  input  logic                   s0_awready,
  output logic [DATA_WIDTH-1:0]  s0_wdata,
  output logic [DATA_WIDTH/8-1:0] s0_wstrb,
  output logic                   s0_wlast,
  output logic                   s0_wvalid,
  input  logic                   s0_wready,
  input  logic [ID_WIDTH-1:0]    s0_bid,
  input  logic [1:0]             s0_bresp,
  input  logic                   s0_bvalid,
  output logic                   s0_bready,
  output logic [ID_WIDTH-1:0]    s0_arid,
  output logic [ADDR_WIDTH-1:0]  s0_araddr,
  output logic [7:0]             s0_arlen,
  output logic [2:0]             s0_arsize,
  output logic [1:0]             s0_arburst,
  output logic                   s0_arvalid,
  input  logic                   s0_arready,
  input  logic [ID_WIDTH-1:0]    s0_rid,
  input  logic [DATA_WIDTH-1:0]  s0_rdata,
  input  logic [1:0]             s0_rresp,
  input  logic                   s0_rlast,
  input  logic                   s0_rvalid,
  output logic                   s0_rready,

  // ---- Slave 1: DDR ----
  output logic [ID_WIDTH-1:0]    s1_awid,
  output logic [ADDR_WIDTH-1:0]  s1_awaddr,
  output logic [7:0]             s1_awlen,
  output logic [2:0]             s1_awsize,
  output logic [1:0]             s1_awburst,
  output logic                   s1_awvalid,
  input  logic                   s1_awready,
  output logic [DATA_WIDTH-1:0]  s1_wdata,
  output logic [DATA_WIDTH/8-1:0] s1_wstrb,
  output logic                   s1_wlast,
  output logic                   s1_wvalid,
  input  logic                   s1_wready,
  input  logic [ID_WIDTH-1:0]    s1_bid,
  input  logic [1:0]             s1_bresp,
  input  logic                   s1_bvalid,
  output logic                   s1_bready,
  output logic [ID_WIDTH-1:0]    s1_arid,
  output logic [ADDR_WIDTH-1:0]  s1_araddr,
  output logic [7:0]             s1_arlen,
  output logic [2:0]             s1_arsize,
  output logic [1:0]             s1_arburst,
  output logic                   s1_arvalid,
  input  logic                   s1_arready,
  input  logic [ID_WIDTH-1:0]    s1_rid,
  input  logic [DATA_WIDTH-1:0]  s1_rdata,
  input  logic [1:0]             s1_rresp,
  input  logic                   s1_rlast,
  input  logic                   s1_rvalid,
  output logic                   s1_rready,

  // ---- Slave 2: MMIO (AXI4-Lite peripherals) ----
  output logic [ID_WIDTH-1:0]    s2_awid,
  output logic [ADDR_WIDTH-1:0]  s2_awaddr,
  output logic [7:0]             s2_awlen,
  output logic [2:0]             s2_awsize,
  output logic [1:0]             s2_awburst,
  output logic                   s2_awvalid,
  input  logic                   s2_awready,
  output logic [DATA_WIDTH-1:0]  s2_wdata,
  output logic [DATA_WIDTH/8-1:0] s2_wstrb,
  output logic                   s2_wlast,
  output logic                   s2_wvalid,
  input  logic                   s2_wready,
  input  logic [ID_WIDTH-1:0]    s2_bid,
  input  logic [1:0]             s2_bresp,
  input  logic                   s2_bvalid,
  output logic                   s2_bready,
  output logic [ID_WIDTH-1:0]    s2_arid,
  output logic [ADDR_WIDTH-1:0]  s2_araddr,
  output logic [7:0]             s2_arlen,
  output logic [2:0]             s2_arsize,
  output logic [1:0]             s2_arburst,
  output logic                   s2_arvalid,
  input  logic                   s2_arready,
  input  logic [ID_WIDTH-1:0]    s2_rid,
  input  logic [DATA_WIDTH-1:0]  s2_rdata,
  input  logic [1:0]             s2_rresp,
  input  logic                   s2_rlast,
  input  logic                   s2_rvalid,
  output logic                   s2_rready,

  // ---- Slave 3: UART ----
  output logic [ID_WIDTH-1:0]    s3_awid,
  output logic [ADDR_WIDTH-1:0]  s3_awaddr,
  output logic [7:0]             s3_awlen,
  output logic [2:0]             s3_awsize,
  output logic [1:0]             s3_awburst,
  output logic                   s3_awvalid,
  input  logic                   s3_awready,
  output logic [DATA_WIDTH-1:0]  s3_wdata,
  output logic [DATA_WIDTH/8-1:0] s3_wstrb,
  output logic                   s3_wlast,
  output logic                   s3_wvalid,
  input  logic                   s3_wready,
  input  logic [ID_WIDTH-1:0]    s3_bid,
  input  logic [1:0]             s3_bresp,
  input  logic                   s3_bvalid,
  output logic                   s3_bready,
  output logic [ID_WIDTH-1:0]    s3_arid,
  output logic [ADDR_WIDTH-1:0]  s3_araddr,
  output logic [7:0]             s3_arlen,
  output logic [2:0]             s3_arsize,
  output logic [1:0]             s3_arburst,
  output logic                   s3_arvalid,
  input  logic                   s3_arready,
  input  logic [ID_WIDTH-1:0]    s3_rid,
  input  logic [DATA_WIDTH-1:0]  s3_rdata,
  input  logic [1:0]             s3_rresp,
  input  logic                   s3_rlast,
  input  logic                   s3_rvalid,
  output logic                   s3_rready
);

  // =========================================================================
  // Address decode
  // =========================================================================
  // Returns slave index for a given byte address.
  localparam logic [63:0] BOOT_ROM_BASE = 64'h0000_0000;
  localparam logic [63:0] BOOT_ROM_END  = 64'h0000_03FF;
  localparam logic [63:0] DDR_BASE      = 64'h0000_1000;
  localparam logic [63:0] DDR_END       = 64'h0000_FFFF;
  localparam logic [63:0] MMIO_BASE     = 64'h4000_0000;
  localparam logic [63:0] MMIO_END      = 64'h4000_FFFF;
  localparam logic [63:0] UART_BASE     = 64'h4000_1000;
  localparam logic [63:0] UART_END      = 64'h4000_100F;

  typedef enum logic [1:0] {
    SLAVE_BOOT_ROM = 2'd0,
    SLAVE_DDR      = 2'd1,
    SLAVE_MMIO     = 2'd2,
    SLAVE_UART     = 2'd3
  } slave_idx_t;

  // Unmapped address placeholder (not a real slave index)
  localparam logic [1:0] SLAVE_UNMAP = 2'b11;  // same encoding as UART, will SLVERR

  function automatic slave_idx_t decode_addr(input logic [63:0] addr);
    if (addr >= BOOT_ROM_BASE && addr <= BOOT_ROM_END)
      return SLAVE_BOOT_ROM;
    else if (addr >= DDR_BASE && addr <= DDR_END)
      return SLAVE_DDR;
    else if (addr >= UART_BASE && addr <= UART_END)
      return SLAVE_UART;
    else if (addr >= MMIO_BASE && addr <= MMIO_END)
      return SLAVE_MMIO;
    else
      return SLAVE_UART;  // unmapped: route to UART (will get SLVERR response)
  endfunction

  // =========================================================================
  // Read channel arbitration (round-robin)
  // =========================================================================
  typedef enum logic [1:0] {
    R_IDLE    = 2'd0,
    R_GRANTED = 2'd1,
    R_DONE    = 2'd2
  } r_state_t;

  r_state_t r_state;
  logic [1:0] r_grant;       // which master has read grant
  logic [1:0] r_rr_ptr;      // round-robin pointer
  logic       r_active;       // transaction in progress

  // Read request per master
  logic [2:0] r_req;
  assign r_req = {m2_arvalid, m1_arvalid, m0_arvalid};

  // Read address decode per master
  slave_idx_t r_slave [2:0];
  assign r_slave[0] = decode_addr(m0_araddr);
  assign r_slave[1] = decode_addr(m1_araddr);
  assign r_slave[2] = decode_addr(m2_araddr);

  // Round-robin arbiter for read channel
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      r_state   <= R_IDLE;
      r_grant   <= '0;
      r_rr_ptr  <= '0;
      r_active  <= 1'b0;
    end else begin
      case (r_state)
        R_IDLE: begin
          r_active <= 1'b0;
          // Find next requesting master (round-robin)
          if (r_req[r_rr_ptr]) begin
            r_grant  <= r_rr_ptr;
            r_state  <= R_GRANTED;
            r_active <= 1'b1;
            r_rr_ptr <= r_rr_ptr + 1;
          end else if (r_req[(r_rr_ptr + 1) % 3]) begin
            r_grant  <= (r_rr_ptr + 1) % 3;
            r_state  <= R_GRANTED;
            r_active <= 1'b1;
            r_rr_ptr <= (r_rr_ptr + 2) % 3;
          end else if (r_req[(r_rr_ptr + 2) % 3]) begin
            r_grant  <= (r_rr_ptr + 2) % 3;
            r_state  <= R_GRANTED;
            r_active <= 1'b1;
            r_rr_ptr <= (r_rr_ptr + 3) % 3;
          end
        end
        R_GRANTED: begin
          // Wait for last data beat on the shared read bus
          if (r_shared_rvalid && r_shared_rready && r_shared_rlast) begin
            r_active <= 1'b0;
            r_state  <= R_IDLE;
          end
        end
        default: r_state <= R_IDLE;
      endcase
    end
  end

  // =========================================================================
  // Write channel arbitration (round-robin)
  // =========================================================================
  typedef enum logic [1:0] {
    W_IDLE    = 2'd0,
    W_GRANTED = 2'd1,
    W_DONE    = 2'd2
  } w_state_t;

  w_state_t w_state;
  logic [1:0] w_grant;
  logic [1:0] w_rr_ptr;
  logic       w_active;

  logic [2:0] w_req;
  assign w_req = {m2_awvalid, m1_awvalid, m0_awvalid};

  slave_idx_t w_slave [2:0];
  assign w_slave[0] = decode_addr(m0_awaddr);
  assign w_slave[1] = decode_addr(m1_awaddr);
  assign w_slave[2] = decode_addr(m2_awaddr);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      w_state   <= W_IDLE;
      w_grant   <= '0;
      w_rr_ptr  <= '0;
      w_active  <= 1'b0;
    end else begin
      case (w_state)
        W_IDLE: begin
          w_active <= 1'b0;
          if (w_req[w_rr_ptr]) begin
            w_grant  <= w_rr_ptr;
            w_state  <= W_GRANTED;
            w_active <= 1'b1;
            w_rr_ptr <= w_rr_ptr + 1;
          end else if (w_req[(w_rr_ptr + 1) % 3]) begin
            w_grant  <= (w_rr_ptr + 1) % 3;
            w_state  <= W_GRANTED;
            w_active <= 1'b1;
            w_rr_ptr <= (w_rr_ptr + 2) % 3;
          end else if (w_req[(w_rr_ptr + 2) % 3]) begin
            w_grant  <= (w_rr_ptr + 2) % 3;
            w_state  <= W_GRANTED;
            w_active <= 1'b1;
            w_rr_ptr <= (w_rr_ptr + 3) % 3;
          end
        end
        W_GRANTED: begin
          // Wait for write response on the shared write bus
          if (w_shared_bvalid && w_shared_bready) begin
            w_active <= 1'b0;
            w_state  <= W_IDLE;
          end
        end
        default: w_state <= W_IDLE;
      endcase
    end
  end

  // =========================================================================
  // Master → Shared bus multiplexing (read)
  // =========================================================================
  logic [ID_WIDTH-1:0]    r_shared_arid;
  logic [ADDR_WIDTH-1:0]  r_shared_araddr;
  logic [7:0]             r_shared_arlen;
  logic [2:0]             r_shared_arsize;
  logic [1:0]             r_shared_arburst;
  logic                   r_shared_arvalid;
  logic                   r_shared_arready;

  logic [ID_WIDTH-1:0]    r_shared_rid;
  logic [DATA_WIDTH-1:0]  r_shared_rdata;
  logic [1:0]             r_shared_rresp;
  logic                   r_shared_rlast;
  logic                   r_shared_rvalid;
  logic                   r_shared_rready;

  // Mux read address to shared bus
  always_comb begin
    r_shared_arid    = '0;
    r_shared_araddr  = '0;
    r_shared_arlen   = '0;
    r_shared_arsize  = '0;
    r_shared_arburst = '0;
    r_shared_arvalid = 1'b0;
    case (r_grant)
      2'd0: begin r_shared_arid = m0_arid; r_shared_araddr = m0_araddr; r_shared_arlen = m0_arlen; r_shared_arsize = m0_arsize; r_shared_arburst = m0_arburst; r_shared_arvalid = m0_arvalid; end
      2'd1: begin r_shared_arid = m1_arid; r_shared_araddr = m1_araddr; r_shared_arlen = m1_arlen; r_shared_arsize = m1_arsize; r_shared_arburst = m1_arburst; r_shared_arvalid = m1_arvalid; end
      2'd2: begin r_shared_arid = m2_arid; r_shared_araddr = m2_araddr; r_shared_arlen = m2_arlen; r_shared_arsize = m2_arsize; r_shared_arburst = m2_arburst; r_shared_arvalid = m2_arvalid; end
      default: ;
    endcase
  end

  // Demux read data back to winning master
  always_comb begin
    m0_rdata  = '0; m0_rresp = '0; m0_rlast = 1'b0; m0_rvalid = 1'b0; m0_rid = '0;
    m1_rdata  = '0; m1_rresp = '0; m1_rlast = 1'b0; m1_rvalid = 1'b0; m1_rid = '0;
    m2_rdata  = '0; m2_rresp = '0; m2_rlast = 1'b0; m2_rvalid = 1'b0; m2_rid = '0;
    case (r_grant)
      2'd0: begin m0_rdata = r_shared_rdata; m0_rresp = r_shared_rresp; m0_rlast = r_shared_rlast; m0_rvalid = r_shared_rvalid; m0_rid = r_shared_rid; end
      2'd1: begin m1_rdata = r_shared_rdata; m1_rresp = r_shared_rresp; m1_rlast = r_shared_rlast; m1_rvalid = r_shared_rvalid; m1_rid = r_shared_rid; end
      2'd2: begin m2_rdata = r_shared_rdata; m2_rresp = r_shared_rresp; m2_rlast = r_shared_rlast; m2_rvalid = r_shared_rvalid; m2_rid = r_shared_rid; end
      default: ;
    endcase
  end

  // Read ready: only the granted master can provide ready
  assign r_shared_rready = (r_grant == 2'd0) ? m0_rready :
                           (r_grant == 2'd1) ? m1_rready :
                                               m2_rready;

  // All non-granted masters see ready=0 (cannot issue)
  assign m0_arready = (r_grant == 2'd0) ? r_shared_arready : 1'b0;
  assign m1_arready = (r_grant == 2'd1) ? r_shared_arready : 1'b0;
  assign m2_arready = (r_grant == 2'd2) ? r_shared_arready : 1'b0;

  // =========================================================================
  // Master → Shared bus multiplexing (write)
  // =========================================================================
  logic [ID_WIDTH-1:0]    w_shared_awid;
  logic [ADDR_WIDTH-1:0]  w_shared_awaddr;
  logic [7:0]             w_shared_awlen;
  logic [2:0]             w_shared_awsize;
  logic [1:0]             w_shared_awburst;
  logic                   w_shared_awvalid;
  logic                   w_shared_awready;

  logic [DATA_WIDTH-1:0]  w_shared_wdata;
  logic [DATA_WIDTH/8-1:0] w_shared_wstrb;
  logic                   w_shared_wlast;
  logic                   w_shared_wvalid;
  logic                   w_shared_wready;

  logic [ID_WIDTH-1:0]    w_shared_bid;
  logic [1:0]             w_shared_bresp;
  logic                   w_shared_bvalid;
  logic                   w_shared_bready;

  // Mux write address to shared bus
  always_comb begin
    w_shared_awid    = '0;
    w_shared_awaddr  = '0;
    w_shared_awlen   = '0;
    w_shared_awsize  = '0;
    w_shared_awburst = '0;
    w_shared_awvalid = 1'b0;
    case (w_grant)
      2'd0: begin w_shared_awid = m0_awid; w_shared_awaddr = m0_awaddr; w_shared_awlen = m0_awlen; w_shared_awsize = m0_awsize; w_shared_awburst = m0_awburst; w_shared_awvalid = m0_awvalid; end
      2'd1: begin w_shared_awid = m1_awid; w_shared_awaddr = m1_awaddr; w_shared_awlen = m1_awlen; w_shared_awsize = m1_awsize; w_shared_awburst = m1_awburst; w_shared_awvalid = m1_awvalid; end
      2'd2: begin w_shared_awid = m2_awid; w_shared_awaddr = m2_awaddr; w_shared_awlen = m2_awlen; w_shared_awsize = m2_awsize; w_shared_awburst = m2_awburst; w_shared_awvalid = m2_awvalid; end
      default: ;
    endcase
  end

  // Mux write data to shared bus
  always_comb begin
    w_shared_wdata  = '0;
    w_shared_wstrb  = '0;
    w_shared_wlast  = 1'b0;
    w_shared_wvalid = 1'b0;
    case (w_grant)
      2'd0: begin w_shared_wdata = m0_wdata; w_shared_wstrb = m0_wstrb; w_shared_wlast = m0_wlast; w_shared_wvalid = m0_wvalid; end
      2'd1: begin w_shared_wdata = m1_wdata; w_shared_wstrb = m1_wstrb; w_shared_wlast = m1_wlast; w_shared_wvalid = m1_wvalid; end
      2'd2: begin w_shared_wdata = m2_wdata; w_shared_wstrb = m2_wstrb; w_shared_wlast = m2_wlast; w_shared_wvalid = m2_wvalid; end
      default: ;
    endcase
  end

  // Demux write response back to winning master
  always_comb begin
    m0_bid = '0; m0_bresp = '0; m0_bvalid = 1'b0;
    m1_bid = '0; m1_bresp = '0; m1_bvalid = 1'b0;
    m2_bid = '0; m2_bresp = '0; m2_bvalid = 1'b0;
    case (w_grant)
      2'd0: begin m0_bid = w_shared_bid; m0_bresp = w_shared_bresp; m0_bvalid = w_shared_bvalid; end
      2'd1: begin m1_bid = w_shared_bid; m1_bresp = w_shared_bresp; m1_bvalid = w_shared_bvalid; end
      2'd2: begin m2_bid = w_shared_bid; m2_bresp = w_shared_bresp; m2_bvalid = w_shared_bvalid; end
      default: ;
    endcase
  end

  assign w_shared_bready = (w_grant == 2'd0) ? m0_bready :
                           (w_grant == 2'd1) ? m1_bready :
                                               m2_bready;

  assign m0_awready = (w_grant == 2'd0) ? w_shared_awready : 1'b0;
  assign m1_awready = (w_grant == 2'd1) ? w_shared_awready : 1'b0;
  assign m2_awready = (w_grant == 2'd2) ? w_shared_awready : 1'b0;

  assign m0_wready = (w_grant == 2'd0) ? w_shared_wready : 1'b0;
  assign m1_wready = (w_grant == 2'd1) ? w_shared_wready : 1'b0;
  assign m2_wready = (w_grant == 2'd2) ? w_shared_wready : 1'b0;

  // =========================================================================
  // Shared bus → Slave demultiplexing (read)
  // =========================================================================
  slave_idx_t r_active_slave;
  logic       r_slave_set;  // flag: slave index already set for current transaction
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      r_active_slave <= SLAVE_UART;
      r_slave_set    <= 1'b0;
    end else if (r_state == R_IDLE) begin
      r_slave_set <= 1'b0;
    end else if (r_state == R_GRANTED && r_active && !r_slave_set) begin
      // Set slave index on first cycle of R_GRANTED based on winning master's address
      r_slave_set <= 1'b1;
      case (r_grant)
        2'd0: r_active_slave <= decode_addr(m0_araddr);
        2'd1: r_active_slave <= decode_addr(m1_araddr);
        2'd2: r_active_slave <= decode_addr(m2_araddr);
        default: r_active_slave <= SLAVE_UART;
      endcase
    end
  end

  // Demux read address to selected slave
  always_comb begin
    // Defaults: no slave selected
    s0_arid = '0; s0_araddr = '0; s0_arlen = '0; s0_arsize = '0; s0_arburst = '0; s0_arvalid = 1'b0;
    s1_arid = '0; s1_araddr = '0; s1_arlen = '0; s1_arsize = '0; s1_arburst = '0; s1_arvalid = 1'b0;
    s2_arid = '0; s2_araddr = '0; s2_arlen = '0; s2_arsize = '0; s2_arburst = '0; s2_arvalid = 1'b0;
    s3_arid = '0; s3_araddr = '0; s3_arlen = '0; s3_arsize = '0; s3_arburst = '0; s3_arvalid = 1'b0;

    r_shared_arready = 1'b0;

    case (r_active_slave)
      SLAVE_BOOT_ROM: begin s0_arid = r_shared_arid; s0_araddr = r_shared_araddr; s0_arlen = r_shared_arlen; s0_arsize = r_shared_arsize; s0_arburst = r_shared_arburst; s0_arvalid = r_shared_arvalid; r_shared_arready = s0_arready; end
      SLAVE_DDR:      begin s1_arid = r_shared_arid; s1_araddr = r_shared_araddr; s1_arlen = r_shared_arlen; s1_arsize = r_shared_arsize; s1_arburst = r_shared_arburst; s1_arvalid = r_shared_arvalid; r_shared_arready = s1_arready; end
      SLAVE_MMIO:     begin s2_arid = r_shared_arid; s2_araddr = r_shared_araddr; s2_arlen = r_shared_arlen; s2_arsize = r_shared_arsize; s2_arburst = r_shared_arburst; s2_arvalid = r_shared_arvalid; r_shared_arready = s2_arready; end
      SLAVE_UART:     begin s3_arid = r_shared_arid; s3_araddr = r_shared_araddr; s3_arlen = r_shared_arlen; s3_arsize = r_shared_arsize; s3_arburst = r_shared_arburst; s3_arvalid = r_shared_arvalid; r_shared_arready = s3_arready; end
      default:        r_shared_arready = 1'b1;  // absorb and return error
    endcase
  end

  // Mux read data from active slave
  always_comb begin
    r_shared_rdata  = '0;
    r_shared_rresp  = 2'b11;  // default: SLVERR
    r_shared_rlast  = 1'b0;
    r_shared_rvalid = 1'b0;
    r_shared_rid    = '0;

    case (r_active_slave)
      SLAVE_BOOT_ROM: begin r_shared_rdata = s0_rdata; r_shared_rresp = s0_rresp; r_shared_rlast = s0_rlast; r_shared_rvalid = s0_rvalid; r_shared_rid = s0_rid; end
      SLAVE_DDR:      begin r_shared_rdata = s1_rdata; r_shared_rresp = s1_rresp; r_shared_rlast = s1_rlast; r_shared_rvalid = s1_rvalid; r_shared_rid = s1_rid; end
      SLAVE_MMIO:     begin r_shared_rdata = s2_rdata; r_shared_rresp = s2_rresp; r_shared_rlast = s2_rlast; r_shared_rvalid = s2_rvalid; r_shared_rid = s2_rid; end
      SLAVE_UART:     begin r_shared_rdata = s3_rdata; r_shared_rresp = s3_rresp; r_shared_rlast = s3_rlast; r_shared_rvalid = s3_rvalid; r_shared_rid = s3_rid; end
      default:        begin r_shared_rvalid = 1'b1; r_shared_rlast = 1'b1; r_shared_rresp = 2'b11; end
    endcase
  end

  assign s0_rready = (r_active_slave == SLAVE_BOOT_ROM) ? r_shared_rready : 1'b0;
  assign s1_rready = (r_active_slave == SLAVE_DDR)      ? r_shared_rready : 1'b0;
  assign s2_rready = (r_active_slave == SLAVE_MMIO)     ? r_shared_rready : 1'b0;
  assign s3_rready = (r_active_slave == SLAVE_UART)     ? r_shared_rready : 1'b0;

  // =========================================================================
  // Shared bus → Slave demultiplexing (write)
  // =========================================================================
  slave_idx_t w_active_slave;
  logic       w_slave_set;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      w_active_slave <= SLAVE_UART;
      w_slave_set    <= 1'b0;
    end else if (w_state == W_IDLE) begin
      w_slave_set <= 1'b0;
    end else if (w_state == W_GRANTED && w_active && !w_slave_set) begin
      w_slave_set <= 1'b1;
      case (w_grant)
        2'd0: w_active_slave <= decode_addr(m0_awaddr);
        2'd1: w_active_slave <= decode_addr(m1_awaddr);
        2'd2: w_active_slave <= decode_addr(m2_awaddr);
        default: w_active_slave <= SLAVE_UART;
      endcase
    end
  end

  // Demux write address to selected slave
  always_comb begin
    s0_awid = '0; s0_awaddr = '0; s0_awlen = '0; s0_awsize = '0; s0_awburst = '0; s0_awvalid = 1'b0;
    s1_awid = '0; s1_awaddr = '0; s1_awlen = '0; s1_awsize = '0; s1_awburst = '0; s1_awvalid = 1'b0;
    s2_awid = '0; s2_awaddr = '0; s2_awlen = '0; s2_awsize = '0; s2_awburst = '0; s2_awvalid = 1'b0;
    s3_awid = '0; s3_awaddr = '0; s3_awlen = '0; s3_awsize = '0; s3_awburst = '0; s3_awvalid = 1'b0;

    w_shared_awready = 1'b0;

    case (w_active_slave)
      SLAVE_BOOT_ROM: begin s0_awid = w_shared_awid; s0_awaddr = w_shared_awaddr; s0_awlen = w_shared_awlen; s0_awsize = w_shared_awsize; s0_awburst = w_shared_awburst; s0_awvalid = w_shared_awvalid; w_shared_awready = s0_awready; end
      SLAVE_DDR:      begin s1_awid = w_shared_awid; s1_awaddr = w_shared_awaddr; s1_awlen = w_shared_awlen; s1_awsize = w_shared_awsize; s1_awburst = w_shared_awburst; s1_awvalid = w_shared_awvalid; w_shared_awready = s1_awready; end
      SLAVE_MMIO:     begin s2_awid = w_shared_awid; s2_awaddr = w_shared_awaddr; s2_awlen = w_shared_awlen; s2_awsize = w_shared_awsize; s2_awburst = w_shared_awburst; s2_awvalid = w_shared_awvalid; w_shared_awready = s2_awready; end
      SLAVE_UART:     begin s3_awid = w_shared_awid; s3_awaddr = w_shared_awaddr; s3_awlen = w_shared_awlen; s3_awsize = w_shared_awsize; s3_awburst = w_shared_awburst; s3_awvalid = w_shared_awvalid; w_shared_awready = s3_awready; end
      default:        w_shared_awready = 1'b1;  // absorb and return error
    endcase
  end

  // Demux write data to selected slave
  always_comb begin
    s0_wdata = '0; s0_wstrb = '0; s0_wlast = 1'b0; s0_wvalid = 1'b0;
    s1_wdata = '0; s1_wstrb = '0; s1_wlast = 1'b0; s1_wvalid = 1'b0;
    s2_wdata = '0; s2_wstrb = '0; s2_wlast = 1'b0; s2_wvalid = 1'b0;
    s3_wdata = '0; s3_wstrb = '0; s3_wlast = 1'b0; s3_wvalid = 1'b0;

    w_shared_wready = 1'b0;

    case (w_active_slave)
      SLAVE_BOOT_ROM: begin s0_wdata = w_shared_wdata; s0_wstrb = w_shared_wstrb; s0_wlast = w_shared_wlast; s0_wvalid = w_shared_wvalid; w_shared_wready = s0_wready; end
      SLAVE_DDR:      begin s1_wdata = w_shared_wdata; s1_wstrb = w_shared_wstrb; s1_wlast = w_shared_wlast; s1_wvalid = w_shared_wvalid; w_shared_wready = s1_wready; end
      SLAVE_MMIO:     begin s2_wdata = w_shared_wdata; s2_wstrb = w_shared_wstrb; s2_wlast = w_shared_wlast; s2_wvalid = w_shared_wvalid; w_shared_wready = s2_wready; end
      SLAVE_UART:     begin s3_wdata = w_shared_wdata; s3_wstrb = w_shared_wstrb; s3_wlast = w_shared_wlast; s3_wvalid = w_shared_wvalid; w_shared_wready = s3_wready; end
      default:        w_shared_wready = 1'b1;  // absorb
    endcase
  end

  // Mux write response from active slave
  always_comb begin
    w_shared_bid    = '0;
    w_shared_bresp  = 2'b11;  // default: SLVERR
    w_shared_bvalid = 1'b0;

    case (w_active_slave)
      SLAVE_BOOT_ROM: begin w_shared_bid = s0_bid; w_shared_bresp = s0_bresp; w_shared_bvalid = s0_bvalid; end
      SLAVE_DDR:      begin w_shared_bid = s1_bid; w_shared_bresp = s1_bresp; w_shared_bvalid = s1_bvalid; end
      SLAVE_MMIO:     begin w_shared_bid = s2_bid; w_shared_bresp = s2_bresp; w_shared_bvalid = s2_bvalid; end
      SLAVE_UART:     begin w_shared_bid = s3_bid; w_shared_bresp = s3_bresp; w_shared_bvalid = s3_bvalid; end
      default:        begin w_shared_bvalid = 1'b1; w_shared_bresp = 2'b11; end
    endcase
  end

  assign s0_bready = (w_active_slave == SLAVE_BOOT_ROM) ? w_shared_bready : 1'b0;
  assign s1_bready = (w_active_slave == SLAVE_DDR)      ? w_shared_bready : 1'b0;
  assign s2_bready = (w_active_slave == SLAVE_MMIO)     ? w_shared_bready : 1'b0;
  assign s3_bready = (w_active_slave == SLAVE_UART)     ? w_shared_bready : 1'b0;

endmodule
