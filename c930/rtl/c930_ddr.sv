// -----------------------------------------------------------------------------
// c930_ddr.sv
//
// Unified byte-addressable "DDR" model for the C930 SoC. A single byte array is
// shared by three ports:
//
//   * CPU instruction-cache read port  (256-bit cache line)
//   * CPU data-cache read/write ports  (256-bit line read, 64-bit byte-strobe write)
//   * AXI4 full slave                  (NPU DMA master: 64-bit INCR bursts)
//
// The CPU cache ports mirror the reference main_mem + mem_shifter semantics
// (registered read done/line, registered write done, write data shifted by the
// lowest asserted strobe lane). The AXI4 slave mirrors the proven slave model
// from tb_c930_npu so the NPU DMA runs against it unchanged.
// -----------------------------------------------------------------------------
module c930_ddr
#(
  parameter int MEM_BYTES        = 65536,   // 64 KB byte-addressable
  parameter int ADDR_WIDTH       = 64,
  parameter int CACHE_LINE_WIDTH = 256
)
(
  input  logic i_clk,
  input  logic i_rst_n,

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
  input  logic        s_axi_bready
);

  // ---------------------------------------------------------------------------
  // Byte storage
  // ---------------------------------------------------------------------------
  logic [7:0] mem [0:MEM_BYTES-1];

  // ---------------------------------------------------------------------------
  // Helpers: lowest asserted strobe lane, and byte extraction
  // ---------------------------------------------------------------------------
  function automatic int lowest_set_bit(input logic [7:0] strobe);
    lowest_set_bit = 0;
    if      (strobe[0]) lowest_set_bit = 0;
    else if (strobe[1]) lowest_set_bit = 1;
    else if (strobe[2]) lowest_set_bit = 2;
    else if (strobe[3]) lowest_set_bit = 3;
    else if (strobe[4]) lowest_set_bit = 4;
    else if (strobe[5]) lowest_set_bit = 5;
    else if (strobe[6]) lowest_set_bit = 6;
    else if (strobe[7]) lowest_set_bit = 7;
  endfunction

  function automatic logic [CACHE_LINE_WIDTH-1:0] line_at(input logic [ADDR_WIDTH-1:0] addr);
    logic [ADDR_WIDTH-1:0] base;
    base = {addr[ADDR_WIDTH-1:5], 5'b0};
    for (int i = 0; i < CACHE_LINE_WIDTH/8; i++)
      line_at[i*8 +: 8] = mem[base + i];
  endfunction

  // ---------------------------------------------------------------------------
  // CPU instruction-cache read (registered, mirrors main_mem)
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      o_icache_rd_done <= 1'b0;
      o_icache_rd_line <= '0;
    end else begin
      o_icache_rd_done <= 1'b0;
      if (i_icache_rd_req) begin
        o_icache_rd_line <= line_at(i_icache_rd_addr);
        o_icache_rd_done <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // CPU data-cache read (registered)
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      o_dcache_rd_done <= 1'b0;
      o_dcache_rd_line <= '0;
    end else begin
      o_dcache_rd_done <= 1'b0;
      if (i_dcache_rd_req) begin
        o_dcache_rd_line <= line_at(i_dcache_rd_addr);
        o_dcache_rd_done <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // CPU data-cache write: commit the low (popcount) bytes of the raw data into
  // the byte lanes selected by the strobe (equivalent to mem_shifter + main_mem).
  // ---------------------------------------------------------------------------
  int                        wr_off;
  logic [ADDR_WIDTH-1:0]      wr_base;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      o_dcache_wr_done <= 1'b0;
    end else begin
      o_dcache_wr_done <= 1'b0;
      if (i_dcache_wr_valid) begin
        wr_off  = lowest_set_bit(i_dcache_wr_strobe);
        wr_base = {i_dcache_wr_addr[ADDR_WIDTH-1:3], 3'b0};
        for (int i = 0; i < 8; i++)
          if (i_dcache_wr_strobe[i])
            mem[wr_base + i] <= i_dcache_wr_data[(i - wr_off)*8 +: 8];
        o_dcache_wr_done <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // AXI4 slave: read channel
  // ---------------------------------------------------------------------------
  logic [31:0] r_addr;
  logic [7:0]  r_len;
  logic [7:0]  r_beat;
  logic        r_busy;

  assign s_axi_arready = ~r_busy;
  assign s_axi_rvalid  = r_busy;
  assign s_axi_rlast   = (r_beat == r_len);
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rdata   = { mem[r_addr + r_beat*8 + 7], mem[r_addr + r_beat*8 + 6],
                           mem[r_addr + r_beat*8 + 5], mem[r_addr + r_beat*8 + 4],
                           mem[r_addr + r_beat*8 + 3], mem[r_addr + r_beat*8 + 2],
                           mem[r_addr + r_beat*8 + 1], mem[r_addr + r_beat*8 + 0] };

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      r_busy <= 1'b0;
      r_addr <= '0;
      r_len  <= '0;
      r_beat <= '0;
    end else begin
      if (s_axi_arvalid && s_axi_arready && !r_busy) begin
        r_addr <= s_axi_araddr;
        r_len  <= s_axi_arlen;
        r_beat <= 8'd0;
        r_busy <= 1'b1;
      end
      if (r_busy && s_axi_rvalid && s_axi_rready) begin
        if (r_beat == r_len)
          r_busy <= 1'b0;
        else
          r_beat <= r_beat + 1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // AXI4 slave: write channel
  // ---------------------------------------------------------------------------
  logic [31:0] w_addr;
  logic [7:0]  w_len;
  logic [7:0]  w_beat;
  logic        w_busy;
  logic        b_valid;

  assign s_axi_awready = ~w_busy;
  assign s_axi_wready  = w_busy;
  assign s_axi_bvalid  = b_valid;
  assign s_axi_bresp   = 2'b00;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      w_busy  <= 1'b0;
      b_valid <= 1'b0;
      w_addr  <= '0;
      w_len   <= '0;
      w_beat  <= '0;
    end else begin
      if (s_axi_awvalid && s_axi_awready && !w_busy) begin
        w_addr <= s_axi_awaddr;
        w_len  <= s_axi_awlen;
        w_beat <= 8'd0;
        w_busy <= 1'b1;
      end
      if (w_busy && s_axi_wvalid && s_axi_wready) begin
        for (int i = 0; i < 8; i++)
          if (s_axi_wstrb[i])
            mem[w_addr + w_beat*8 + i] <= s_axi_wdata[i*8 +: 8];
        if (w_beat == w_len) begin
          w_busy  <= 1'b0;
          b_valid <= 1'b1;
        end else begin
          w_beat <= w_beat + 1;
        end
      end
      if (b_valid && s_axi_bready)
        b_valid <= 1'b0;
    end
  end

endmodule
