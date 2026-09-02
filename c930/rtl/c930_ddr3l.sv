// -----------------------------------------------------------------------------
// c930_ddr3l.sv
//
// DDR3L memory controller for the C930 SoC, targeting the Arty A7-100T board
// (MT41K128M16JT-125, 256 MB, 16-bit data bus).
//
// Replaces c930_ddr.sv (behavioral) and c930_ddr_stub.sv (BRAM stub) when
// synthesizing with Vivado for the Arty A7-100T board.
//
// Interface: identical port list to c930_ddr / c930_ddr_stub so c930_soc_top
// instantiates unchanged.
//
// Architecture:
//   ┌──────────────────────────────────────────────────────────────────┐
//   │ c930_soc_top                                                     │
//   │  ┌──────────┐  ┌──────────┐  ┌──────────────────────────────┐  │
//   │  │ icache   │  │ dcache   │  │ NPU DMA (AXI4 full master)   │  │
//   │  │ 256b line│  │ 256b+wr  │  │ 64b data, 32b addr           │  │
//   │  └────┬─────┘  └────┬─────┘  └──────────┬───────────────────┘  │
//   │       │              │                    │                      │
//   │       └──────┬───────┘                    │                      │
//   │              │                            │                      │
//   │    ┌─────────▼──────────┐    ┌────────────▼─────────────┐      │
//   │    │ Cache → AXI4       │    │ NPU DMA AXI4 (direct)    │      │
//   │    │ bridge FSM         │    │                          │      │
//   │    └─────────┬──────────┘    └────────────┬─────────────┘      │
//   │              │                            │                      │
//   │    ┌─────────▼────────────────────────────▼─────────────┐      │
//   │    │              AXI4 arbiter (icache > dcache > DMA)  │      │
//   │    └───────────────────────┬────────────────────────────┘      │
//   │                            │                                    │
//   │    ┌───────────────────────▼────────────────────────────┐      │
//   │    │ MIG 7 Series (ui_clk domain, ~200 MHz)             │      │
//   │    │ AXI4 slave → DDR3L PHY → MT41K128M16JT-125        │      │
//   │    └───────────────────────┬────────────────────────────┘      │
//   └────────────────────────────┼──────────────────────────────────┘
//                                │
//                          DDR3L chip (256 MB)
//
// Clock domains:
//   - i_clk (core_clk, ~50 MHz from Arty oscillator / CLK_DIV)
//     Used by: cache-line ports, NPU DMA AXI4
//   - ui_clk (~200 MHz from MIG MMCM, derived from 200 MHz sys_clk_i)
//     Used by: AXI4 arbiter, MIG AXI4 slave interface
//
//   The cache→AXI4 bridge and arbiter run in ui_clk domain.  Cache-line
//   request signals are toggled and CDC-synchronized into ui_clk.  Done
//   signals and read data are toggled back into core_clk domain.
//
// Memory map (flat, byte-addressed, same as c930_ddr):
//   0x0000_0000 .. 0x0000_FFFF : first 64 KB (firmware + NPU buffers)
//   0x0001_0000 .. 0x0FFF_FFFF : remainder of 256 MB DDR3L
//
// The first 64 KB must contain the boot firmware (sw/npu_boot.c).  Since
// DDR3L is volatile and uninitialised at power-up, the firmware must be
// loaded via JTAG/UART before the first boot, OR the DDR3L stub's embedded
// boot ROM must be retained as a fallback.
//
// MIG IP: instantiate via Vivado IP Customizer (see synth_xilinx/README.md).
// The .xci is NOT checked into the repo — it is generated from the
// configuration documented in synth_xilinx/mig_7series_arty_a7_100t.tcl.
// -----------------------------------------------------------------------------
module c930_ddr3l
#(
  parameter int MEM_BYTES        = 65536,
  parameter int ADDR_WIDTH       = 64,
  parameter int CACHE_LINE_WIDTH = 256
)
(
  input  logic i_clk,     // core clock (~50 MHz)
  input  logic i_rst_n,   // active-low reset (synchronous to i_clk)

  // ---- CPU instruction-cache read port ----
  input  logic [ADDR_WIDTH-1:0]       i_icache_rd_addr,
  input  logic                        i_icache_rd_req,
  output logic                        o_icache_rd_done,
  output logic [CACHE_LINE_WIDTH-1:0] o_icache_rd_line,

  // ---- CPU data-cache read port ----
  input  logic [ADDR_WIDTH-1:0]       i_dcache_rd_addr,
  input  logic                        i_dcache_rd_req,
  output logic                        o_dcache_rd_done,
  output logic [CACHE_LINE_WIDTH-1:0] o_dcache_rd_line,

  // ---- CPU data-cache write port (raw register data + byte strobe) ----
  input  logic [ADDR_WIDTH-1:0]       i_dcache_wr_addr,
  input  logic [63:0]                 i_dcache_wr_data,
  input  logic [7:0]                  i_dcache_wr_strobe,
  input  logic                        i_dcache_wr_valid,
  output logic                        o_dcache_wr_done,

  // ---- AXI4 full slave (NPU DMA) ----
  input  logic [31:0] s_axi_araddr,
  input  logic [7:0]  s_axi_arlen,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [63:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rlast,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,
  input  logic [31:0] s_axi_awaddr,
  input  logic [7:0]  s_axi_awlen,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [63:0] s_axi_wdata,
  input  logic [7:0]  s_axi_wstrb,
  input  logic        s_axi_wlast,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,

  // ---- DDR3L physical interface (active when SYNTHESIS define is set) ----
  output logic        ddr3_ck_p,
  output logic        ddr3_ck_n,
  output logic        ddr3_reset_n,
  output logic        ddr3_cke,
  output logic        ddr3_cs_n,
  output logic        ddr3_ras_n,
  output logic        ddr3_cas_n,
  output logic        ddr3_we_n,
  output logic [1:0]  ddr3_dm,
  output logic [1:0]  ddr3_dqs_p,
  output logic [1:0]  ddr3_dqs_n,
  output logic [15:0] ddr3_dq,
  output logic [13:0] ddr3_addr,
  output logic [2:0]  ddr3_ba,

  // ---- System clocks (board oscillator feeds MIG) ----
  input  logic sys_clk_i,    // 100 MHz directly from board oscillator
  input  logic sys_rst_i     // active-high directly from board button
);


// ==========================================================================
// Clock domain crossing: core_clk <-> ui_clk (MIG)
//
// The MIG AXI4 slave interface runs on ui_clk (~200 MHz).  The SoC cache
// ports and NPU DMA run on core_clk (~50 MHz).  We use a simple toggle-
// synchroniser for request/done handshakes.
// ==========================================================================

// ---- CDC: core_clk → ui_clk (requests) ----
logic ic_req_toggle_core;   // toggles in core_clk domain on icache request
logic ic_req_toggle_ui[2];  // synchronised into ui_clk domain
logic ic_req_seen_ui;       // rising-edge detect in ui_clk
logic dc_req_toggle_core;
logic dc_req_toggle_ui[2];
logic dc_req_seen_ui;
logic dcw_req_toggle_core;
logic dcw_req_toggle_ui[2];
logic dcw_req_seen_ui;

always_ff @(posedge i_clk or negedge i_rst_n) begin
  if (!i_rst_n) begin
    ic_req_toggle_core  <= 1'b0;
    dc_req_toggle_core  <= 1'b0;
    dcw_req_toggle_core <= 1'b0;
  end else begin
    if (i_icache_rd_req && !o_icache_rd_done)
      ic_req_toggle_core <= ~ic_req_toggle_core;
    if (i_dcache_rd_req && !o_dcache_rd_done)
      dc_req_toggle_core <= ~dc_req_toggle_core;
    if (i_dcache_wr_valid && !o_dcache_wr_done)
      dcw_req_toggle_core <= ~dcw_req_toggle_core;
  end
end

// Synchroniser into ui_clk domain
always_ff @(posedge ui_clk or negedge sys_rst_i) begin
  if (!sys_rst_i) begin
    ic_req_toggle_ui <= '{2{1'b0}};
    dc_req_toggle_ui <= '{2{1'b0}};
    dcw_req_toggle_ui <= '{2{1'b0}};
  end else begin
    ic_req_toggle_ui <= {ic_req_toggle_ui[0], ic_req_toggle_core};
    dc_req_toggle_ui <= {dc_req_toggle_ui[0], dc_req_toggle_core};
    dcw_req_toggle_ui <= {dcw_req_toggle_ui[0], dcw_req_toggle_core};
  end
end

// Rising-edge detect
assign ic_req_seen_ui  = ic_req_toggle_ui[1] ^ ic_req_toggle_ui[0];
assign dc_req_seen_ui  = dc_req_toggle_ui[1] ^ dcw_req_toggle_ui[0];
assign dcw_req_seen_ui = dcw_req_toggle_ui[1] ^ dcw_req_toggle_ui[0];

// Latched request addresses/data in ui_clk domain
logic [ADDR_WIDTH-1:0] ic_req_addr_ui;
logic [ADDR_WIDTH-1:0] dc_req_addr_ui;
logic [ADDR_WIDTH-1:0] dcw_req_addr_ui;
logic [63:0]            dcw_req_data_ui;
logic [7:0]             dcw_req_strobe_ui;

always_ff @(posedge ui_clk or negedge sys_rst_i) begin
  if (!sys_rst_i) begin
    ic_req_addr_ui  <= '0;
    dc_req_addr_ui  <= '0;
    dcw_req_addr_ui <= '0;
    dcw_req_data_ui <= '0;
    dcw_req_strobe_ui <= '0;
  end else begin
    if (ic_req_seen_ui)  ic_req_addr_ui  <= i_icache_rd_addr;
    if (dc_req_seen_ui)  dc_req_addr_ui  <= i_dcache_rd_addr;
    if (dcw_req_seen_ui) begin
      dcw_req_addr_ui   <= i_dcache_wr_addr;
      dcw_req_data_ui   <= i_dcache_wr_data;
      dcw_req_strobe_ui <= i_dcache_wr_strobe;
    end
  end
end


// ==========================================================================
// Cache → AXI4 bridge FSM (runs in ui_clk domain)
//
// Converts cache-line reads (256-bit / 32 bytes → AXI4 INCR burst, len=3)
// and dcache writes (64-bit / 8 bytes → AXI4 single-beat, len=0) into AXI4
// transactions on the merged master port.
// ==========================================================================

typedef enum logic [2:0] {
  CB_IDLE,
  CB_ICACHE_RD_ADDR,
  CB_ICACHE_RD_DATA,
  CB_DCACHE_RD_ADDR,
  CB_DCACHE_RD_DATA,
  CB_DCACHE_WR_ADDR,
  CB_DCACHE_WR_DATA,
  CB_DCACHE_WR_RESP
} cb_state_t;

cb_state_t cb_state;

// AXI4 signals from the cache bridge to the arbiter
logic [31:0] cb_axi_araddr;
logic [7:0]  cb_axi_arlen;
logic        cb_axi_arvalid;
logic        cb_axi_arready;
logic [63:0] cb_axi_rdata;
logic [1:0]  cb_axi_rresp;
logic        cb_axi_rlast;
logic        cb_axi_rvalid;
logic        cb_axi_rready;

logic [31:0] cb_axi_awaddr;
logic [7:0]  cb_axi_awlen;
logic        cb_axi_awvalid;
logic        cb_axi_awready;
logic [63:0] cb_axi_wdata;
logic [7:0]  cb_axi_wstrb;
logic        cb_axi_wlast;
logic        cb_axi_wvalid;
logic        cb_axi_wready;
logic [1:0]  cb_axi_bresp;
logic        cb_axi_bvalid;
logic        cb_axi_bready;

// Read beat counter
logic [2:0] cb_rd_beat;
logic [2:0] cb_rd_len;  // 3 for icache/dcache (256 bits = 4 × 64 bits)

// Write beat counter
logic [7:0] cb_wr_beat;

// 256-bit line assembly register (accumulates 4 × 64-bit beats)
logic [255:0] cb_line_buf;
logic         cb_line_src;  // 0 = icache, 1 = dcache

always_ff @(posedge ui_clk or negedge sys_rst_i) begin
  if (!sys_rst_i) begin
    cb_state      <= CB_IDLE;
    cb_rd_beat    <= '0;
    cb_rd_len     <= '0;
    cb_wr_beat    <= '0;
    cb_line_buf   <= '0;
    cb_line_src   <= 1'b0;

    cb_axi_araddr  <= '0;
    cb_axi_arlen   <= '0;
    cb_axi_arvalid <= 1'b0;
    cb_axi_awaddr  <= '0;
    cb_axi_awlen   <= '0;
    cb_axi_awvalid <= 1'b0;
    cb_axi_wdata   <= '0;
    cb_axi_wstrb   <= '0;
    cb_axi_wlast   <= 1'b0;
    cb_axi_wvalid  <= 1'b0;
    cb_axi_rready  <= 1'b0;
    cb_axi_bready  <= 1'b0;
  end else begin
    // Defaults: deassert handshake signals after one cycle
    cb_axi_arvalid <= 1'b0;
    cb_axi_awvalid <= 1'b0;
    cb_axi_wvalid  <= 1'b0;

    case (cb_state)
      // ---------------------------------------------------------------
      CB_IDLE: begin
        cb_axi_rready <= 1'b0;
        cb_axi_bready <= 1'b0;

        if (ic_req_seen_ui) begin
          // icache read: 256-bit line = 4 × 64-bit beats, INCR burst
          cb_axi_araddr  <= ic_req_addr_ui[31:0] & 32'hFFFF_FFE0;  // 32-byte align
          cb_axi_arlen   <= 8'd3;  // 4 beats
          cb_axi_arvalid <= 1'b1;
          cb_rd_beat     <= '0;
          cb_rd_len      <= 3'd3;
          cb_line_src    <= 1'b0;
          cb_line_buf    <= '0;
          cb_axi_rready  <= 1'b1;
          cb_state       <= CB_ICACHE_RD_ADDR;

        end else if (dc_req_seen_ui) begin
          // dcache read: 256-bit line = 4 × 64-bit beats
          cb_axi_araddr  <= dc_req_addr_ui[31:0] & 32'hFFFF_FFE0;
          cb_axi_arlen   <= 8'd3;
          cb_axi_arvalid <= 1'b1;
          cb_rd_beat     <= '0;
          cb_rd_len      <= 3'd3;
          cb_line_src    <= 1'b1;
          cb_line_buf    <= '0;
          cb_axi_rready  <= 1'b1;
          cb_state       <= CB_DCACHE_RD_ADDR;

        end else if (dcw_req_seen_ui) begin
          // dcache write: 64-bit data = 1 × 64-bit beat
          cb_axi_awaddr  <= dcw_req_addr_ui[31:0] & 32'hFFFF_FFF8;  // 8-byte align
          cb_axi_awlen   <= 8'd0;  // 1 beat
          cb_axi_awvalid <= 1'b1;
          cb_axi_wdata   <= dcw_req_data_ui;
          cb_axi_wstrb   <= dcw_req_strobe_ui;
          cb_axi_wlast   <= 1'b1;
          cb_axi_wvalid  <= 1'b1;
          cb_axi_bready  <= 1'b1;
          cb_wr_beat     <= '0;
          cb_state       <= CB_DCACHE_WR_ADDR;
        end
      end

      // ---------------------------------------------------------------
      // icache read: wait for AR handshake, then capture 4 beats
      // ---------------------------------------------------------------
      CB_ICACHE_RD_ADDR: begin
        if (cb_axi_arvalid && cb_axi_arready)
          cb_state <= CB_ICACHE_RD_DATA;
      end

      CB_ICACHE_RD_DATA: begin
        if (cb_axi_rvalid && cb_axi_rready) begin
          cb_line_buf[cb_rd_beat*64 +: 64] <= cb_axi_rdata;
          if (cb_axi_rlast) begin
            cb_axi_rready <= 1'b0;
            cb_state      <= CB_IDLE;
          end else begin
            cb_rd_beat <= cb_rd_beat + 1;
          end
        end
      end

      // ---------------------------------------------------------------
      // dcache read: same as icache, different done source
      // ---------------------------------------------------------------
      CB_DCACHE_RD_ADDR: begin
        if (cb_axi_arvalid && cb_axi_arready)
          cb_state <= CB_DCACHE_RD_DATA;
      end

      CB_DCACHE_RD_DATA: begin
        if (cb_axi_rvalid && cb_axi_rready) begin
          cb_line_buf[cb_rd_beat*64 +: 64] <= cb_axi_rdata;
          if (cb_axi_rlast) begin
            cb_axi_rready <= 1'b0;
            cb_state      <= CB_IDLE;
          end else begin
            cb_rd_beat <= cb_rd_beat + 1;
          end
        end
      end

      // ---------------------------------------------------------------
      // dcache write: wait for AW+W handshakes, then wait for B
      // ---------------------------------------------------------------
      CB_DCACHE_WR_ADDR: begin
        // Both AW and W are presented simultaneously; wait for both
        // to be accepted (they may be accepted in any order).
        if (cb_axi_awvalid && cb_axi_awready)
          cb_axi_awvalid <= 1'b0;
        if (cb_axi_wvalid && cb_axi_wready)
          cb_axi_wvalid <= 1'b0;

        if ((!cb_axi_awvalid || cb_axi_awready) &&
            (!cb_axi_wvalid  || cb_axi_wready)) begin
          // Both accepted (or deasserted) — wait for write response
          cb_state <= CB_DCACHE_WR_DATA;
        end
      end

      CB_DCACHE_WR_DATA: begin
        if (cb_axi_bvalid && cb_axi_bready) begin
          cb_axi_bready <= 1'b0;
          cb_state      <= CB_IDLE;
        end
      end

      default: cb_state <= CB_IDLE;
    endcase
  end
end


// ==========================================================================
// CDC: ui_clk → core_clk (done signals + read data)
//
// The done signals and 256-bit line data cross back from ui_clk to core_clk
// using a toggle synchroniser.  The done pulse is extended so the core_clk
// domain captures it.
// ==========================================================================

// Toggle in ui_clk when a cache read completes
logic ic_done_toggle_ui;
logic dc_done_toggle_ui;
logic dcw_done_toggle_ui;

assign ic_done_toggle_ui  = (cb_state == CB_ICACHE_RD_DATA) && cb_axi_rvalid && cb_axi_rready && cb_axi_rlast;
assign dc_done_toggle_ui  = (cb_state == CB_DCACHE_RD_DATA) && cb_axi_rvalid && cb_axi_rready && cb_axi_rlast;
assign dcw_done_toggle_ui = (cb_state == CB_DCACHE_WR_DATA) && cb_axi_bvalid && cb_axi_bready;

logic ic_done_toggle_core[2];
logic dc_done_toggle_core[2];
logic dcw_done_toggle_core[2];

always_ff @(posedge i_clk or negedge i_rst_n) begin
  if (!i_rst_n) begin
    ic_done_toggle_core  <= '{2{1'b0}};
    dc_done_toggle_core  <= '{2{1'b0}};
    dcw_done_toggle_core <= '{2{1'b0}};
  end else begin
    ic_done_toggle_core  <= {ic_done_toggle_core[0],  ic_done_toggle_ui};
    dc_done_toggle_core  <= {dc_done_toggle_core[0],  dc_done_toggle_ui};
    dcw_done_toggle_core <= {dcw_done_toggle_core[0], dcw_done_toggle_ui};
  end
end

// Rising-edge detect in core_clk
assign o_icache_rd_done  = ic_done_toggle_core[1] ^ ic_done_toggle_core[0];
assign o_dcache_rd_done  = dc_done_toggle_core[1] ^ dc_done_toggle_core[0];
assign o_dcache_wr_done  = dcw_done_toggle_core[1] ^ dcw_done_toggle_core[0];

// Line data: latch when done fires (the data is stable in ui_clk; we sample
// it in core_clk when the done toggle arrives — the data has been stable for
// at least 2 core_clk cycles due to the synchroniser latency).
// NOTE: In a production design this should use a proper handshake or FIFO.
// For now we trust that the line buffer is stable when done fires.
assign o_icache_rd_line = cb_line_buf;
assign o_dcache_rd_line = cb_line_buf;


// ==========================================================================
// AXI4 arbiter (runs in ui_clk domain)
//
// Priority: icache read > dcache read > NPU DMA.  Only one transaction
// can be active at a time.  The arbiter presents a single AXI4 master
// interface to the MIG.
// ==========================================================================

typedef enum logic [1:0] {
  ARB_IDLE,
  ARB_READ,
  ARB_WRITE,
  ARB_RESP
} arb_state_t;

arb_state_t arb_state;
logic [1:0] arb_src;  // 00=icache, 01=dcache, 10=NPU DMA

// Merged AXI4 master → MIG
logic [31:0] m_axi_araddr;
logic [7:0]  m_axi_arlen;
logic        m_axi_arvalid;
logic        m_axi_arready;
logic [63:0] m_axi_rdata;
logic [1:0]  m_axi_rresp;
logic        m_axi_rlast;
logic        m_axi_rvalid;
logic        m_axi_rready;
logic [31:0] m_axi_awaddr;
logic [7:0]  m_axi_awlen;
logic        m_axi_awvalid;
logic        m_axi_awready;
logic [63:0] m_axi_wdata;
logic [7:0]  m_axi_wstrb;
logic        m_axi_wlast;
logic        m_axi_wvalid;
logic        m_axi_wready;
logic [1:0]  m_axi_bresp;
logic        m_axi_bvalid;
logic        m_axi_bready;

// Source read signals
logic [31:0] src_araddr;
logic [7:0]  src_arlen;
logic        src_arvalid;
logic        src_rready;
logic [1:0]  src_rresp;
logic [63:0] src_rdata;
logic        src_rlast;
logic        src_rvalid;

// Source write signals
logic [31:0] src_awaddr;
logic [7:0]  src_awlen;
logic        src_awvalid;
logic [63:0] src_wdata;
logic [7:0]  src_wstrb;
logic        src_wlast;
logic        src_wvalid;
logic        src_wready;
logic [1:0]  src_bresp;
logic        src_bvalid;
logic        src_bready;

// Select the highest-priority source
wire src_icache_r  = (cb_state == CB_ICACHE_RD_ADDR) || (cb_state == CB_ICACHE_RD_DATA);
wire src_dcache_r  = (cb_state == CB_DCACHE_RD_ADDR) || (cb_state == CB_DCACHE_RD_DATA);
wire src_dcache_w  = (cb_state == CB_DCACHE_WR_ADDR) || (cb_state == CB_DCACHE_WR_DATA);
wire src_dma_r     = s_axi_arvalid;
wire src_dma_w     = s_axi_awvalid;

// NPU DMA direct pass-through (no conversion needed — already AXI4)
assign s_axi_arready = m_axi_arready && (arb_state == ARB_IDLE) && !src_icache_r && !src_dcache_r && !src_dcache_w;
assign s_axi_rdata   = m_axi_rdata;
assign s_axi_rresp   = m_axi_rresp;
assign s_axi_rlast   = m_axi_rlast;
assign s_axi_rvalid  = m_axi_rvalid && (arb_src == 2'b10);
assign s_axi_awready = m_axi_awready && (arb_state == ARB_IDLE) && !src_icache_r && !src_dcache_r && !src_dcache_w;
assign s_axi_wready  = m_axi_wready  && (arb_src == 2'b10);
assign s_axi_bresp   = m_axi_bresp;
assign s_axi_bvalid  = m_axi_bvalid  && (arb_src == 2'b10);

// Arbiter FSM
always_ff @(posedge ui_clk or negedge sys_rst_i) begin
  if (!sys_rst_i) begin
    arb_state <= ARB_IDLE;
    arb_src   <= 2'b00;
  end else begin
    case (arb_state)
      ARB_IDLE: begin
        if (src_icache_r) begin
          arb_src   <= 2'b00;
          arb_state <= ARB_READ;
        end else if (src_dcache_r) begin
          arb_src   <= 2'b01;
          arb_state <= ARB_READ;
        end else if (src_dma_r) begin
          arb_src   <= 2'b10;
          arb_state <= ARB_READ;
        end else if (src_dcache_w) begin
          arb_src   <= 2'b01;
          arb_state <= ARB_WRITE;
        end else if (src_dma_w) begin
          arb_src   <= 2'b10;
          arb_state <= ARB_WRITE;
        end
      end

      ARB_READ: begin
        if (m_axi_rvalid && m_axi_rready && m_axi_rlast)
          arb_state <= ARB_IDLE;
      end

      ARB_WRITE: begin
        if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
          arb_state <= ARB_RESP;
      end

      ARB_RESP: begin
        if (m_axi_bvalid && m_axi_bready)
          arb_state <= ARB_IDLE;
      end
    endcase
  end
end

// Mux arbiter outputs to the MIG AXI4 master
assign m_axi_araddr  = (arb_src == 2'b10) ? s_axi_araddr  : cb_axi_araddr;
assign m_axi_arlen   = (arb_src == 2'b10) ? s_axi_arlen   : cb_axi_arlen;
assign m_axi_arvalid = (arb_src == 2'b10) ? src_dma_r      :
                       (arb_src == 2'b00) ? cb_axi_arvalid :
                       (arb_src == 2'b01) ? cb_axi_arvalid : 1'b0;
assign m_axi_rready  = (arb_src == 2'b10) ? s_axi_rready  : cb_axi_rready;

assign m_axi_awaddr  = (arb_src == 2'b10) ? s_axi_awaddr  : cb_axi_awaddr;
assign m_axi_awlen   = (arb_src == 2'b10) ? s_axi_awlen   : cb_axi_awlen;
assign m_axi_awvalid = (arb_src == 2'b10) ? src_dma_w      :
                       (arb_src == 2'b01) ? cb_axi_awvalid : 1'b0;
assign m_axi_wdata   = (arb_src == 2'b10) ? s_axi_wdata   : cb_axi_wdata;
assign m_axi_wstrb   = (arb_src == 2'b10) ? s_axi_wstrb   : cb_axi_wstrb;
assign m_axi_wlast   = (arb_src == 2'b10) ? s_axi_wlast   : cb_axi_wlast;
assign m_axi_wvalid  = (arb_src == 2'b10) ? src_dma_w      :
                       (arb_src == 2'b01) ? cb_axi_wvalid  : 1'b0;
assign m_axi_bready  = (arb_src == 2'b10) ? s_axi_bready  : cb_axi_bready;

// Feed arbiter responses back to the cache bridge
assign cb_axi_arready = m_axi_arready && (arb_src == arb_src);  // active when arb_src matches
assign cb_axi_rdata   = m_axi_rdata;
assign cb_axi_rresp   = m_axi_rresp;
assign cb_axi_rlast   = m_axi_rlast;
assign cb_axi_rvalid  = m_axi_rvalid && (arb_src != 2'b10);
assign cb_axi_awready = m_axi_awready && (arb_src == arb_src);
assign cb_axi_wready  = m_axi_wready && (arb_src != 2'b10);
assign cb_axi_bresp   = m_axi_bresp;
assign cb_axi_bvalid  = m_axi_bvalid && (arb_src != 2'b10);


// ==========================================================================
// MIG 7 Series instantiation
//
// The MIG IP must be generated via Vivado IP Customizer before synthesis.
// See synth_xilinx/README.md for the configuration and synth_xilinx/
// mig_7series_arty_a7_100t.tcl for the GUI-less generation script.
//
// The MIG's AXI4 slave interface (m_axi_*) is connected to the arbiter
// output above.  The DDR3L physical pins are forwarded to the top-level.
// ==========================================================================

// MIG-generated signals
logic        ui_clk;           // ~200 MHz AXI4 clock from MIG
logic        ui_clk_sync_out;  // sync output from MIG (unused)
logic        init_calib_complete;
logic [5:0]  sys_rst_o;        // active-low reset outputs from MIG

// DDR3L physical signals (driven by MIG)
wire         ddr3_ck_p_int;
wire         ddr3_ck_n_int;
wire         ddr3_reset_n_int;
wire         ddr3_cke_int;
wire         ddr3_cs_n_int;
wire         ddr3_ras_n_int;
wire         ddr3_cas_n_int;
wire         ddr3_we_n_int;
wire [1:0]   ddr3_dm_int;
wire [1:0]   ddr3_dqs_p_int;
wire [1:0]   ddr3_dqs_n_int;
wire [15:0]  ddr3_dq_int;
wire [13:0]  ddr3_addr_int;
wire [2:0]   ddr3_ba_int;

// Invert active-low reset for MIG (MIG expects active-high sys_rst_i)
wire sys_rst_i_activehigh = sys_rst_i;

// Instantiate the MIG 7 Series IP
// NOTE: This is a placeholder — the actual module name and parameters
// depend on the MIG IP configuration.  Generate the IP via:
//   1. Open Vivado → IP Catalog → search "MIG 7 Series"
//   2. Configure for MT41K128M16JT-125 on Arty A7-100T
//   3. Generate Output Products → the module will be named "mig_7series_0"
//
// The ports below follow the standard MIG 7 Series AXI4 wrapper.
mig_7series_0 u_mig (
  // System clocks
  .sys_clk_i           (sys_clk_i),          // 100 MHz board oscillator
  .sys_rst_i           (sys_rst_i_activehigh),

  // DDR3L physical interface
  .ddr3_addr           (ddr3_addr_int),
  .ddr3_ba             (ddr3_ba_int),
  .ddr3_cas_n          (ddr3_cas_n_int),
  .ddr3_ck_p           (ddr3_ck_p_int),
  .ddr3_ck_n           (ddr3_ck_n_int),
  .ddr3_cke            (ddr3_cke_int),
  .ddr3_ras_n          (ddr3_ras_n_int),
  .ddr3_reset_n        (ddr3_reset_n_int),
  .ddr3_we_n           (ddr3_we_n_int),
  .ddr3_dq             (ddr3_dq_int),
  .ddr3_dqs_p          (ddr3_dqs_p_int),
  .ddr3_dqs_n          (ddr3_dqs_n_int),
  .ddr3_dm             (ddr3_dm_int),
  .ddr3_cs_n           (ddr3_cs_n_int),

  // AXI4 slave interface (from arbiter)
  .s_axi_awid          (6'b0),
  .s_axi_awaddr        (m_axi_awaddr),
  .s_axi_awlen         (m_axi_awlen),
  .s_axi_awsize        (3'b011),            // 8 bytes (64-bit)
  .s_axi_awburst       (2'b01),             // INCR
  .s_axi_awlock        (1'b0),
  .s_axi_awcache       (4'b0010),           // Non-cacheable
  .s_axi_awprot        (3'b000),
  .s_axi_awqos         (4'b0),
  .s_axi_awvalid       (m_axi_awvalid),
  .s_axi_awready       (m_axi_awready),

  .s_axi_wid           (6'b0),
  .s_axi_wdata         (m_axi_wdata),
  .s_axi_wstrb         (m_axi_wstrb),
  .s_axi_wlast         (m_axi_wlast),
  .s_axi_wvalid        (m_axi_wvalid),
  .s_axi_wready        (m_axi_wready),

  .s_axi_bid           (),
  .s_axi_bresp         (m_axi_bresp),
  .s_axi_bvalid        (m_axi_bvalid),
  .s_axi_bready        (m_axi_bready),

  .s_axi_arid          (6'b0),
  .s_axi_araddr        (m_axi_araddr),
  .s_axi_arlen         (m_axi_arlen),
  .s_axi_arsize        (3'b011),            // 8 bytes
  .s_axi_arburst       (2'b01),             // INCR
  .s_axi_arlock        (1'b0),
  .s_axi_arcache       (4'b0010),
  .s_axi_arprot        (3'b000),
  .s_axi_arqos         (4'b0),
  .s_axi_arvalid       (m_axi_arvalid),
  .s_axi_arready       (m_axi_arready),

  .s_axi_rid           (),
  .s_axi_rdata         (m_axi_rdata),
  .s_axi_rresp         (m_axi_rresp),
  .s_axi_rlast         (m_axi_rlast),
  .s_axi_rvalid        (m_axi_rvalid),
  .s_axi_rready        (m_axi_rready),

  // UI clocks and status
  .ui_clk              (ui_clk),
  .ui_clk_sync_out     (ui_clk_sync_out),
  .init_calib_complete (init_calib_complete),
  .sys_rst_o           (sys_rst_o)
);

// Forward DDR3L physical pins to top-level ports
assign ddr3_ck_p    = ddr3_ck_p_int;
assign ddr3_ck_n    = ddr3_ck_n_int;
assign ddr3_reset_n = ddr3_reset_n_int;
assign ddr3_cke     = ddr3_cke_int;
assign ddr3_cs_n    = ddr3_cs_n_int;
assign ddr3_ras_n   = ddr3_ras_n_int;
assign ddr3_cas_n   = ddr3_cas_n_int;
assign ddr3_we_n    = ddr3_we_n_int;
assign ddr3_dm      = ddr3_dm_int;
assign ddr3_dqs_p   = ddr3_dqs_p_int;
assign ddr3_dqs_n   = ddr3_dqs_n_int;
assign ddr3_dq      = ddr3_dq_int;
assign ddr3_addr    = ddr3_addr_int;
assign ddr3_ba      = ddr3_ba_int;


endmodule
