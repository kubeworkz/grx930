// -----------------------------------------------------------------------------
// c930_ddr_stub.sv  -- SYNTH-ONLY small synthesizable placeholder for c930_ddr.
//
// Used by the synthesis / P&R flows, where every cell must be a real,
// placeable primitive. The behavioral c930_ddr.sv (64 KB byte array,
// multi-port combinational reads) must NOT be synthesized -- it demotes to
// hundreds of thousands of FFs.
//
// This placeholder keeps the EXACT module name, parameters and ports so
// c930_soc_top elaborates unchanged, but implements a REAL 512-byte memory:
//
//   * storage: 8 banks x 16 lines x 32 bits (bank k = line bytes [k*4 +: 4]),
//     mapped to BRAM (ram_style = "block"). The earlier FF line-array version
//     cost ~5K LUTs of write-decode/read muxes and blew the A7-35T budget
//     (26.6K LUTs > 20.8K); bank-interleaved BRAM keeps the same port
//     semantics at ~1-1.5K LUTs.
//   * reads : icache/dcache 256-bit line reads and the AXI 32-bit word read
//     share ONE arbitrated BRAM read port (priority icache > dcache > AXI).
//     The arbiter captures the request, presents the line address to the
//     banks, and asserts the per-source done/rvalid when the bank outputs are
//     valid (2 cycles after capture). All three consumers hold their requests
//     until served, so the extra latency is transparent.
//   * writes: dcache 64-bit stores and AXI 32-bit beats write directly to the
//     target bank(s) with per-byte enables, in the same cycle (no arbitration
//     needed except a same-bank conflict, where the dcache wins and the AXI
//     beat is held via wready).
//
// A genuine memory (reads return stored state, writes land) is required to
// keep the full fabric (core + caches + NPU + bridge + DMA) in the netlist:
// address-derived or write-bus-derived placeholders let synthesis prove the
// storage collapses and constant-fold the systolic array out of the report.
//
// The stub is also the REAL boot memory on the FPGA: it contains the tiny NPU
// GEMM kick-off firmware (sw/npu_boot.c, embedded below via
// sw/gen_stub_init.py). The memory is initialized once at power-up and is NOT
// cleared by reset, so the core boots straight into the kick-off program:
// it programs a fixed 2x4x2 GEMM over MMIO, the NPU DMA fetches A/B from the
// stub (0x100/0x110), and C lands at 0x120; o_npu_busy (LD4) lights for the
// GEMM duration, o_npu_done / o_npu_irq (LD5/LD7) pulse on completion.
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

  // -------------------------------------------------------------------------
  // Genuine small memory: 512 bytes = 16 lines x 32 B, bank-interleaved so it
  // maps to BRAM. Line index = addr[8:5], word-in-line = addr[4:2].
  // -------------------------------------------------------------------------
  localparam int LINES = 16;   // 16 lines x 32 B = 512 B
  localparam int LW    = CACHE_LINE_WIDTH;

  logic [31:0] mem [0:7][0:LINES-1];

  wire [3:0] ic_line  = i_icache_rd_addr[8:5];
  wire [3:0] dc_line  = i_dcache_rd_addr[8:5];
  wire [3:0] dcw_line = i_dcache_wr_addr[8:5];
  wire [1:0] dcw_word = i_dcache_wr_addr[4:3];   // 64-bit word within the line

  // -------------------------------------------------------------------------
  // Boot firmware (sw/npu_boot.c -> sw/npu_boot.bin), bank-interleaved.
  // mem[k][L] = 32 bits at line L, bytes [k*4 +: 4]; NOT cleared by reset
  // (boot ROM semantics).
  // -------------------------------------------------------------------------
  initial begin
    // line  0 = 256'h004007130007079300f7262300f7242300200793400007370040006f00008137
    mem[0][ 0] = 32'h00008137;
    mem[1][ 0] = 32'h0040006f;
    mem[2][ 0] = 32'h40000737;
    mem[3][ 0] = 32'h00200793;
    mem[4][ 0] = 32'h00f72423;
    mem[5][ 0] = 32'h00f72623;
    mem[6][ 0] = 32'h00070793;
    mem[7][ 0] = 32'h00400713;
    // line  1 = 256'h0010071300e7ae231200071300e7ac231100071300e7aa231000071300e7a823
    mem[0][ 1] = 32'h00e7a823;
    mem[1][ 1] = 32'h10000713;
    mem[2][ 1] = 32'h00e7aa23;
    mem[3][ 1] = 32'h11000713;
    mem[4][ 1] = 32'h00e7ac23;
    mem[5][ 1] = 32'h12000713;
    mem[6][ 1] = 32'h00e7ae23;
    mem[7][ 1] = 32'h00100713;
    // line  2 = 256'h00000000000000000000006ffe078ce30027f793000727830047871300e7a023
    mem[0][ 2] = 32'h00e7a023;
    mem[1][ 2] = 32'h00478713;
    mem[2][ 2] = 32'h00072783;
    mem[3][ 2] = 32'h0027f793;
    mem[4][ 2] = 32'hfe078ce3;
    mem[5][ 2] = 32'h0000006f;
    mem[6][ 2] = 32'h00000000;
    mem[7][ 2] = 32'h00000000;
    // line  3 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][ 3] = 32'h00000000;
    mem[1][ 3] = 32'h00000000;
    mem[2][ 3] = 32'h00000000;
    mem[3][ 3] = 32'h00000000;
    mem[4][ 3] = 32'h00000000;
    mem[5][ 3] = 32'h00000000;
    mem[6][ 3] = 32'h00000000;
    mem[7][ 3] = 32'h00000000;
    // line  4 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][ 4] = 32'h00000000;
    mem[1][ 4] = 32'h00000000;
    mem[2][ 4] = 32'h00000000;
    mem[3][ 4] = 32'h00000000;
    mem[4][ 4] = 32'h00000000;
    mem[5][ 4] = 32'h00000000;
    mem[6][ 4] = 32'h00000000;
    mem[7][ 4] = 32'h00000000;
    // line  5 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][ 5] = 32'h00000000;
    mem[1][ 5] = 32'h00000000;
    mem[2][ 5] = 32'h00000000;
    mem[3][ 5] = 32'h00000000;
    mem[4][ 5] = 32'h00000000;
    mem[5][ 5] = 32'h00000000;
    mem[6][ 5] = 32'h00000000;
    mem[7][ 5] = 32'h00000000;
    // line  6 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][ 6] = 32'h00000000;
    mem[1][ 6] = 32'h00000000;
    mem[2][ 6] = 32'h00000000;
    mem[3][ 6] = 32'h00000000;
    mem[4][ 6] = 32'h00000000;
    mem[5][ 6] = 32'h00000000;
    mem[6][ 6] = 32'h00000000;
    mem[7][ 6] = 32'h00000000;
    // line  7 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][ 7] = 32'h00000000;
    mem[1][ 7] = 32'h00000000;
    mem[2][ 7] = 32'h00000000;
    mem[3][ 7] = 32'h00000000;
    mem[4][ 7] = 32'h00000000;
    mem[5][ 7] = 32'h00000000;
    mem[6][ 7] = 32'h00000000;
    mem[7][ 7] = 32'h00000000;
    // line  8 = 256'h0000000000000000000000000100000100000000000000000807060504030201
    mem[0][ 8] = 32'h04030201;
    mem[1][ 8] = 32'h08070605;
    mem[2][ 8] = 32'h00000000;
    mem[3][ 8] = 32'h00000000;
    mem[4][ 8] = 32'h01000001;
    mem[5][ 8] = 32'h00000000;
    mem[6][ 8] = 32'h00000000;
    mem[7][ 8] = 32'h00000000;
    // line  9 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][ 9] = 32'h00000000;
    mem[1][ 9] = 32'h00000000;
    mem[2][ 9] = 32'h00000000;
    mem[3][ 9] = 32'h00000000;
    mem[4][ 9] = 32'h00000000;
    mem[5][ 9] = 32'h00000000;
    mem[6][ 9] = 32'h00000000;
    mem[7][ 9] = 32'h00000000;
    // line 10 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][10] = 32'h00000000;
    mem[1][10] = 32'h00000000;
    mem[2][10] = 32'h00000000;
    mem[3][10] = 32'h00000000;
    mem[4][10] = 32'h00000000;
    mem[5][10] = 32'h00000000;
    mem[6][10] = 32'h00000000;
    mem[7][10] = 32'h00000000;
    // line 11 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][11] = 32'h00000000;
    mem[1][11] = 32'h00000000;
    mem[2][11] = 32'h00000000;
    mem[3][11] = 32'h00000000;
    mem[4][11] = 32'h00000000;
    mem[5][11] = 32'h00000000;
    mem[6][11] = 32'h00000000;
    mem[7][11] = 32'h00000000;
    // line 12 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][12] = 32'h00000000;
    mem[1][12] = 32'h00000000;
    mem[2][12] = 32'h00000000;
    mem[3][12] = 32'h00000000;
    mem[4][12] = 32'h00000000;
    mem[5][12] = 32'h00000000;
    mem[6][12] = 32'h00000000;
    mem[7][12] = 32'h00000000;
    // line 13 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][13] = 32'h00000000;
    mem[1][13] = 32'h00000000;
    mem[2][13] = 32'h00000000;
    mem[3][13] = 32'h00000000;
    mem[4][13] = 32'h00000000;
    mem[5][13] = 32'h00000000;
    mem[6][13] = 32'h00000000;
    mem[7][13] = 32'h00000000;
    // line 14 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][14] = 32'h00000000;
    mem[1][14] = 32'h00000000;
    mem[2][14] = 32'h00000000;
    mem[3][14] = 32'h00000000;
    mem[4][14] = 32'h00000000;
    mem[5][14] = 32'h00000000;
    mem[6][14] = 32'h00000000;
    mem[7][14] = 32'h00000000;
    // line 15 = 256'h0000000000000000000000000000000000000000000000000000000000000000
    mem[0][15] = 32'h00000000;
    mem[1][15] = 32'h00000000;
    mem[2][15] = 32'h00000000;
    mem[3][15] = 32'h00000000;
    mem[4][15] = 32'h00000000;
    mem[5][15] = 32'h00000000;
    mem[6][15] = 32'h00000000;
    mem[7][15] = 32'h00000000;
  end

  // -------------------------------------------------------------------------
  // Read path: ONE arbitrated BRAM port, priority icache > dcache > AXI.
  //   RD_IDLE : capture the highest-priority pending request, latch its line
  //             (and for AXI, the word select). The requesters HOLD until
  //             served, so a deasserting req cannot be re-captured.
  //   RD_ADDR : banks clock rd_line_q into their internal address registers.
  //   RD_DATA : bank outputs valid; per-source done/rvalid asserted.
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] { RD_IDLE, RD_ADDR, RD_DATA } rd_state_t;

  rd_state_t rd_state;
  logic [3:0]  rd_line_q;
  logic [1:0]  rd_src_q;      // 2'b00 icache, 2'b01 dcache, 2'b10 AXI
  logic [2:0]  rd_wordidx_q;  // AXI word index within the line

  // Registered bank read outputs (the BRAM DO registers).
  logic [31:0] rd_data [0:7];
  // 256-bit line assembled from the 8 bank outputs (valid during RD_DATA).
  wire [LW-1:0] bank_line = {rd_data[7], rd_data[6], rd_data[5], rd_data[4],
                             rd_data[3], rd_data[2], rd_data[1], rd_data[0]};

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rd_state    <= RD_IDLE;
      rd_line_q   <= '0;
      rd_src_q    <= 2'b00;
      rd_wordidx_q<= '0;
    end else begin
      case (rd_state)
        RD_IDLE: begin
          if (i_icache_rd_req) begin
            rd_line_q <= ic_line;
            rd_src_q  <= 2'b00;
            rd_state  <= RD_ADDR;
          end else if (i_dcache_rd_req) begin
            rd_line_q <= dc_line;
            rd_src_q  <= 2'b01;
            rd_state  <= RD_ADDR;
          end else if (r_busy) begin
            rd_line_q    <= r_waddr[8:5];
            rd_wordidx_q <= r_waddr[4:2];
            rd_src_q     <= 2'b10;
            rd_state     <= RD_ADDR;
          end
        end
        RD_ADDR: rd_state <= RD_DATA;
        RD_DATA: rd_state <= RD_IDLE;
      endcase
    end
  end

  assign o_icache_rd_done = (rd_state == RD_DATA) && (rd_src_q == 2'b00);
  assign o_dcache_rd_done = (rd_state == RD_DATA) && (rd_src_q == 2'b01);
  // Both cache line ports see the shared bank assembly; each cache only
  // samples it when its own done is asserted.
  assign o_icache_rd_line = bank_line;
  assign o_dcache_rd_line = bank_line;

  // -------------------------------------------------------------------------
  // Storage banks: each is a 16x32 1R1W BRAM (registered read, per-byte
  // write enable). All 8 banks share the arbiter's read line; each bank has
  // its own write port so dcache (2 banks) and AXI (1 bank) writes land in
  // the same cycle.
  // -------------------------------------------------------------------------
  wire [2:0] ax_bank = w_waddr[4:2];
  wire [2:0] dc_ba   = {dcw_word, 1'b0};   // dcache low bank
  wire [2:0] dc_bb   = {dcw_word, 1'b1};   // dcache high bank
  wire       dc_wr   = i_dcache_wr_valid;
  wire       ax_conf = dc_wr && (ax_bank == dc_ba || ax_bank == dc_bb);

  genvar gk;
  generate
    for (gk = 0; gk < 8; gk = gk + 1) begin : g_bank
      wire       b_wr_en = (dc_wr && (gk == dc_ba || gk == dc_bb)) ||
                           (ax_wr && (gk == ax_bank));
      // Dcache: 32-bit write, AXI: 64-bit write (8 bytes)
      wire [7:0]  b_wr_be_all = (dc_wr && (gk == dc_ba || gk == dc_bb)) ?
                                {4'b0, (gk[0] ? i_dcache_wr_strobe[7:4] : i_dcache_wr_strobe[3:0])} :
                                s_axi_wstrb;
      wire [63:0] b_wr_dt_all = (dc_wr && (gk == dc_ba || gk == dc_bb)) ?
                                {32'b0, (gk[0] ? i_dcache_wr_data[63:32] : i_dcache_wr_data[31:0])} :
                                s_axi_wdata;
      wire [3:0]  b_wr_ad = (dc_wr && (gk == dc_ba || gk == dc_bb)) ? dcw_line : w_waddr[8:5];
      wire [3:0]  b_wr_ad2 = b_wr_ad + 4'd1; // next word in same bank (512B line)

      always_ff @(posedge i_clk) begin
        // Low 32 bits
        if (b_wr_en)
          for (int bb = 0; bb < 4; bb++)
            if (b_wr_be_all[bb])
              mem[gk][b_wr_ad][bb*8 +: 8] <= b_wr_dt_all[bb*8 +: 8];
        // High 32 bits (AXI only, when upper strobes active)
        if (b_wr_en && (b_wr_be_all[7:4] != 4'h0) && !dc_wr)
          for (int bb = 0; bb < 4; bb++)
            if (b_wr_be_all[bb+4])
              mem[gk][b_wr_ad2][bb*8 +: 8] <= b_wr_dt_all[(bb+4)*8 +: 8];
        rd_data[gk] <= mem[gk][rd_line_q];
      end
    end
  endgenerate

  // -------------------------------------------------------------------------
  // AXI4 read channel: burst FSM, one beat per shared-port slot.
  // -------------------------------------------------------------------------
  logic [31:0] r_addr;
  logic [7:0]  r_len;
  logic [7:0]  r_beat;
  logic        r_busy;  wire [31:0] r_waddr = r_addr + r_beat*8;   // byte address of the current beat (64-bit)

  assign s_axi_arready = ~r_busy;
  assign s_axi_rvalid  = (rd_state == RD_DATA) && (rd_src_q == 2'b10);
  assign s_axi_rlast   = (r_beat == r_len);
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rdata   = bank_line[rd_wordidx_q*32 +: 64];

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

  // -------------------------------------------------------------------------
  // AXI4 write channel: burst FSM. wready is gated on a same-bank dcache
  // conflict so a beat is never dropped (the DMA holds wvalid until wready).
  // -------------------------------------------------------------------------
  logic [31:0] w_addr;
  logic [7:0]  w_len;
  logic [7:0]  w_beat;
  logic        w_busy;
  logic        b_valid;  wire [31:0] w_waddr = w_addr + w_beat*8;   // byte address of the current beat (64-bit write)

  assign s_axi_awready = ~w_busy;
  assign s_axi_wready  = w_busy && !ax_conf;
  assign s_axi_bvalid  = b_valid;
  assign s_axi_bresp   = 2'b00;
  wire ax_wr = w_busy && s_axi_wvalid && s_axi_wready;

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
      if (ax_wr) begin
        // (mem write happens in the per-bank generate blocks above)
        if (w_beat == w_len) begin
          w_busy  <= 1'b0;
          b_valid <= 1'b1;
        end else
          w_beat <= w_beat + 1;
      end
      if (b_valid && s_axi_bready)
        b_valid <= 1'b0;
    end
  end

  // -------------------------------------------------------------------------
  // Cache write-done handshake (registered, mirrors the behavioral DDR).
  // -------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      o_dcache_wr_done <= 1'b0;
    else
      o_dcache_wr_done <= i_dcache_wr_valid;
  end

endmodule
