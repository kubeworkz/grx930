// -----------------------------------------------------------------------------
// c930_axi_cache_adapter.sv
//
// Bridges the riscv_core_top's cache-line ports to AXI4 full master interfaces.
// Two instances are needed: one for I-cache, one for D-cache.
//
// I-cache: read-only, 256-bit line fetches → AXI4 read bursts (INCR, 8 beats)
// D-cache: read (256-bit line) + write (64-bit byte-strobe) → AXI4 read + write
//
// The CPU cache ports use a simple req/done handshake:
//   - Master asserts req with an address
//   - Slave returns done=1 for one cycle with the 256-bit line (read)
//   - Slave returns done=1 for one cycle after accepting write data
//
// This adapter converts that to standard AXI4 full protocol.
// -----------------------------------------------------------------------------
module c930_axi_cache_adapter
#(
  parameter int ADDR_WIDTH = 64,
  parameter int DATA_WIDTH = 256,  // cache line width
  parameter int ID_WIDTH   = 4
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- CPU cache port (from riscv_core_top) ----
  // Read port (I-cache and D-cache both use this)
  input  logic [ADDR_WIDTH-1:0] i_cache_rd_addr,
  input  logic                  i_cache_rd_req,
  output logic                  o_cache_rd_done,
  output logic [DATA_WIDTH-1:0] o_cache_rd_line,

  // Write port (D-cache only; tie off for I-cache adapter)
  input  logic [ADDR_WIDTH-1:0] i_cache_wr_addr,
  input  logic [63:0]           i_cache_wr_data,
  input  logic [7:0]            i_cache_wr_strobe,
  input  logic                  i_cache_wr_valid,
  output logic                  o_cache_wr_done,

  // ---- AXI4 full master ----
  // Write address channel
  output logic [ID_WIDTH-1:0]   m_axi_awid,
  output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
  output logic [7:0]            m_axi_awlen,
  output logic [2:0]            m_axi_awsize,
  output logic [1:0]            m_axi_awburst,
  output logic                  m_axi_awvalid,
  input  logic                  m_axi_awready,

  // Write data channel
  output logic [DATA_WIDTH-1:0] m_axi_wdata,
  output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
  output logic                  m_axi_wlast,
  output logic                  m_axi_wvalid,
  input  logic                  m_axi_wready,

  // Write response channel
  input  logic [ID_WIDTH-1:0]   m_axi_bid,
  input  logic [1:0]            m_axi_bresp,
  input  logic                  m_axi_bvalid,
  output logic                  m_axi_bready,

  // Read address channel
  output logic [ID_WIDTH-1:0]   m_axi_arid,
  output logic [ADDR_WIDTH-1:0] m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,

  // Read data channel
  input  logic [ID_WIDTH-1:0]   m_axi_rid,
  input  logic [DATA_WIDTH-1:0] m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready
);

  // Cache line is 256 bits = 32 bytes = 8 AXI beats of 32 bits each.
  // But AXI beat size is 4 bytes (32-bit), so a 256-bit line = 8 beats.
  // Actually: the CPU data bus is 64-bit (8 bytes per beat for writes),
  // but the cache line read is 256 bits. Let's use 64-bit AXI data width
  // and burst the 256-bit line as 4 beats of 64 bits.
  //
  // Re-parameterize: use 64-bit AXI data, 4-beat bursts for 256-bit lines.
  localparam int AXI_DATA_W = 64;
  localparam int BEATS_PER_LINE = DATA_WIDTH / AXI_DATA_W;  // 256/64 = 4

  typedef enum logic [2:0] {
    S_IDLE     = 3'd0,
    S_RD_ISSUE = 3'd1,  // issue AXI read address
    S_RD_DATA  = 3'd2,  // receive AXI read data beats
    S_WR_ISSUE = 3'd3,  // issue AXI write address (single beat)
    S_WR_DATA  = 3'd4,  // send AXI write data
    S_WR_RESP  = 3'd5   // wait for write response
  } state_t;

  state_t state, next_state;

  logic [ADDR_WIDTH-1:0] addr_r;
  logic [63:0]           wr_data_r;
  logic [7:0]            wr_strobe_r;
  logic                  is_write_r;
  logic [1:0]            beat_cnt;
  logic [255:0]          line_buf;

  // AXI defaults
  assign m_axi_awid    = '0;
  assign m_axi_awsize  = 3'b011;  // 8 bytes (64-bit)
  assign m_axi_awburst = 2'b01;   // INCR
  assign m_axi_arid    = '0;
  assign m_axi_arsize  = 3'b011;  // 8 bytes
  assign m_axi_arburst = 2'b01;   // INCR

  // State register
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      state <= S_IDLE;
    else
      state <= next_state;
  end

  // Next-state logic
  always_comb begin
    next_state = state;
    case (state)
      S_IDLE: begin
        if (i_cache_wr_valid)
          next_state = S_WR_ISSUE;
        else if (i_cache_rd_req)
          next_state = S_RD_ISSUE;
      end
      S_RD_ISSUE: begin
        if (m_axi_arready)
          next_state = S_RD_DATA;
      end
      S_RD_DATA: begin
        if (m_axi_rvalid && m_axi_rready && m_axi_rlast)
          next_state = S_IDLE;
      end
      S_WR_ISSUE: begin
        if (m_axi_awready)
          next_state = S_WR_DATA;
      end
      S_WR_DATA: begin
        if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
          next_state = S_WR_RESP;
      end
      S_WR_RESP: begin
        if (m_axi_bvalid)
          next_state = S_IDLE;
      end
      default: next_state = S_IDLE;
    endcase
  end

  // Address and data capture
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      addr_r      <= '0;
      wr_data_r   <= '0;
      wr_strobe_r <= '0;
      is_write_r  <= 1'b0;
      beat_cnt    <= '0;
      line_buf    <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          beat_cnt <= '0;
          if (i_cache_wr_valid) begin
            addr_r      <= i_cache_wr_addr;
            wr_data_r   <= i_cache_wr_data;
            wr_strobe_r <= i_cache_wr_strobe;
            is_write_r  <= 1'b1;
          end else if (i_cache_rd_req) begin
            addr_r     <= i_cache_rd_addr;
            is_write_r <= 1'b0;
          end
        end
        S_RD_DATA: begin
          if (m_axi_rvalid && m_axi_rready) begin
            line_buf[beat_cnt*64 +: 64] <= m_axi_rdata;
            beat_cnt <= beat_cnt + 1;
          end
        end
        default: ;
      endcase
    end
  end

  // AXI read address channel
  assign m_axi_araddr = {addr_r[63:5], 5'b0};  // align to 32-byte line
  assign m_axi_arlen  = BEATS_PER_LINE - 1;     // 3 beats (4 beats total)
  assign m_axi_arvalid = (state == S_RD_ISSUE);

  // AXI read data channel (always ready when in RD_DATA)
  assign m_axi_rready = (state == S_RD_DATA);

  // AXI write address channel
  assign m_axi_awaddr = addr_r;
  assign m_axi_awlen  = 8'd0;  // single beat (64-bit write)
  assign m_axi_awvalid = (state == S_WR_ISSUE);

  // AXI write data channel
  assign m_axi_wdata  = wr_data_r;
  assign m_axi_wstrb  = wr_strobe_r;
  assign m_axi_wlast  = 1'b1;  // single beat, always last
  assign m_axi_wvalid = (state == S_WR_DATA);

  // AXI write response channel
  assign m_axi_bready = (state == S_WR_RESP);

  // CPU-side done signals
  assign o_cache_rd_done = (state == S_RD_DATA) && m_axi_rvalid && m_axi_rready && m_axi_rlast;
  assign o_cache_rd_line = line_buf;
  assign o_cache_wr_done = (state == S_WR_RESP) && m_axi_bvalid;

endmodule
