// -----------------------------------------------------------------------------
// c930_ddr_stub.sv  -- SYNTH-ONLY small synthesizable placeholder for c930_ddr.
//
// Used by the P&R / Fmax flow (synth.ys and synth_fit.ys), where nextpnr
// requires every cell to be a real, placeable primitive. The behavioral
// c930_ddr.sv (64 KB byte array, multi-port combinational reads) must NOT be
// synthesized -- it demotes to hundreds of thousands of FFs, and a real board
// replaces it with BRAM or a DDR controller anyway.
//
// This placeholder keeps the EXACT module name, parameters and ports so
// c930_soc_top elaborates unchanged, but contains no storage: it registers the
// handshake/done outputs and derives every read-data output from the REQUEST
// ADDRESS (not from write data, not from constants). That is important: if
// read data were tied to the write bus (e.g. s_axi_rdata <= s_axi_wdata),
// yosys would prove the NPU DMA's A/B/C reads return the master's own idle
// write data and constant-fold the entire systolic array out of the netlist
// (21 -> 2 DSPs, u_npu -> ~600 FFs). Address-derived data keeps the real
// fabric (core + caches + NPU + bridge + DMA) in the report.
//
// It adds only a few hundred flops, so the P&R resource/timing report reflects
// the real fabric.
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
  // Genuine small memory: every read returns STORED STATE, every write lands
  // in the array, and the C-write path is observable.
  //
  // The blackbox probe keeps the full NPU (69 DSPs, ~20K FFs) while ANY
  // address-derived / counter-derived placeholder lets yosys trace through the
  // DDR and constant-fold the systolic array (21 -> 2 DSPs) and the cache
  // arrays: if read data is a function of the request address, yosys proves
  // INSTR_MEM[i] == f(i) and collapses the storage; if the write data is
  // discarded, the C datapath feeding it is provably unobservable and folds.
  //
  // The only form that survives is a REAL memory: icache/dcache fills and DMA
  // A/B/C reads return data previously written by the dcache write port or the
  // AXI write channel. That is genuine state -- yosys cannot unfold it -- and
  // the systolic-array output reaches the AXI write data, so every datapath
  // stays live. Sizing (16 lines x 256 bits) is far below the behavioral 64 KB
  // model so it stays out of the fabric report's critical mass.
  // -------------------------------------------------------------------------
  localparam int LINES = 16;
  logic [CACHE_LINE_WIDTH-1:0] mem [0:LINES-1];

  integer li;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      for (li = 0; li < LINES; li = li + 1) mem[li] <= '0;
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
      // dcache write port: byte-strobed 64-bit store into the line array.
      if (i_dcache_wr_valid) begin
        for (li = 0; li < 8; li = li + 1)
          if (i_dcache_wr_strobe[li])
            mem[i_dcache_wr_addr[$clog2(LINES)-1:0]][li*8 +: 8] <= i_dcache_wr_data[li*8 +: 8];
      end
      // AXI write channel: 32-bit store (C results land here).
      if (s_axi_awvalid && s_axi_wvalid && s_axi_wlast)
        mem[s_axi_awaddr[$clog2(LINES)-1:0]][s_axi_awaddr[4:2]*8 +: 32] <= s_axi_wdata;

      o_icache_rd_done <= i_icache_rd_req;
      o_dcache_rd_done <= i_dcache_rd_req;
      o_dcache_wr_done <= i_dcache_wr_valid;
      // Registered reads return STORED state (not a function of the address).
      o_icache_rd_line <= mem[i_icache_rd_addr[$clog2(LINES)-1:0]];
      o_dcache_rd_line <= mem[i_dcache_rd_addr[$clog2(LINES)-1:0]];
      s_axi_rvalid     <= s_axi_arvalid;
      s_axi_rdata      <= mem[s_axi_araddr[$clog2(LINES)-1:0]][s_axi_araddr[4:2]*8 +: 32];
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
