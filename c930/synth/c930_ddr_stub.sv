// -----------------------------------------------------------------------------
// c930_ddr_stub.sv  -- SYNTH-ONLY small synthesizable placeholder for c930_ddr.
//
// Used by the P&R / Fmax fit test (synth_fit.ys), where nextpnr requires every
// cell to be a real, placeable primitive. The behavioral c930_ddr.sv (64 KB
// byte array, multi-port combinational reads) must NOT be synthesized -- it
// demotes to hundreds of thousands of FFs, and a real board replaces it with
// BRAM or a DDR controller anyway.
//
// This placeholder keeps the EXACT module name, parameters and ports so
// c930_soc_top elaborates unchanged, but contains no storage: it registers the
// handshake/done outputs and echoes the last write data on the read lines.
// It adds only a few hundred flops, so the P&R resource/timing report reflects
// the real fabric (core + caches + NPU + bridge + DMA port logic).
// -----------------------------------------------------------------------------
module c930_ddr
#(
  parameter int MEM_BYTES        = 65536,
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
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rlast,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,
  input  logic [31:0] s_axi_awaddr,
  input  logic [7:0]  s_axi_awlen,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wlast,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready
);

  // -------------------------------------------------------------------------
  // Minimal registered placeholder: 1-cycle done/valid, read lines echo the
  // last written data. No storage -- intentionally out of the fabric report.
  // -------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      o_icache_rd_done <= 1'b0;
      o_dcache_rd_done <= 1'b0;
      o_dcache_wr_done <= 1'b0;
      o_icache_rd_line <= '0;
      o_dcache_rd_line <= '0;
      s_axi_rvalid     <= 1'b0;
      s_axi_rdata      <= '0;
      s_axi_bvalid     <= 1'b0;
    end
    else begin
      o_icache_rd_done <= i_icache_rd_req;
      o_dcache_rd_done <= i_dcache_rd_req;
      o_dcache_wr_done <= i_dcache_wr_valid;
      o_icache_rd_line <= {4{i_dcache_wr_data}};
      o_dcache_rd_line <= {4{i_dcache_wr_data}};
      s_axi_rvalid     <= s_axi_arvalid;
      s_axi_rdata      <= s_axi_wdata;
      s_axi_bvalid     <= s_axi_awvalid & s_axi_wvalid & s_axi_wlast;
    end
  end

  assign s_axi_arready = 1'b1;
  assign s_axi_awready = 1'b1;
  assign s_axi_wready  = 1'b1;
  assign s_axi_rlast   = (s_axi_arlen == 8'd0);
  assign s_axi_rresp   = 2'b00;
  assign s_axi_bresp   = 2'b00;

endmodule
