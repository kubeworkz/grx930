// -----------------------------------------------------------------------------
// c930_ddr_stub_flat.sv  -- SYNTH-ONLY flat-memory DDR stub for ECP5 synthesis.
//
// Same interface as c930_ddr_stub.sv but uses a 1D memory array instead of 2D,
// so Yosys can map it to EBR (DP16KD / PDPW16KD).
//
// Layout: 512 bytes = 128 x 32-bit words. mem[line*8 + lane] = 32-bit word.
// -----------------------------------------------------------------------------

module c930_ddr #(
  parameter int CACHE_LINE_WIDTH = 256
)(
  input  logic        i_clk,
  input  logic        i_rst_n,

  // Icache port
  input  logic        i_icache_rd_en,
  input  logic [31:0] i_icache_rd_addr,
  output logic        o_icache_rd_done,
  output logic [255:0] o_icache_rd_data,

  // Dcache port
  input  logic        i_dcache_rd_en,
  input  logic        i_dcache_wr_en,
  input  logic [31:0] i_dcache_rd_addr,
  input  logic [31:0] i_dcache_wr_addr,
  input  logic [63:0] i_dcache_wr_data,
  input  logic [7:0]  i_dcache_wr_be,
  output logic        o_dcache_rd_done,
  output logic        o_dcache_wr_done,
  output logic [63:0] o_dcache_rd_data,

  // AXI4 slave (from NPU DMA)
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  input  logic [31:0] s_axi_araddr,
  input  logic [7:0]  s_axi_arlen,
  input  logic [2:0]  s_axi_arsize,
  input  logic [1:0]  s_axi_arburst,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rlast,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_awaddr,
  input  logic [7:0]  s_axi_awlen,
  input  logic [2:0]  s_axi_awsize,
  input  logic [1:0]  s_axi_awburst,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wlast,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  output logic [1:0]  s_axi_bresp
);

  // ---------------------------------------------------------------------------
  // 1D flat memory: 128 x 32-bit words = 512 bytes
  // mem[line*8 + lane] = old_mem[lane][line]
  // ---------------------------------------------------------------------------
  localparam int LINES = 16;
  localparam int DEPTH = 8 * LINES;  // 128

  (* ram_style = "block" *) logic [31:0] mem [0:DEPTH-1];

  wire [3:0] ic_line  = i_icache_rd_addr[8:5];
  wire [3:0] dc_line  = i_dcache_rd_addr[8:5];
  wire [3:0] dcw_line = i_dcache_wr_addr[8:5];
  wire [1:0] dcw_word = i_dcache_wr_addr[4:3];

  // -------------------------------------------------------------------------
  // Boot firmware init (flattened from 2D to 1D)
  // -------------------------------------------------------------------------
  initial begin
    // line 0
    mem[ 0] = 32'h00008137; mem[ 1] = 32'h0040006f; mem[ 2] = 32'h40000737; mem[ 3] = 32'h00200793;
    mem[ 4] = 32'h00f72423; mem[ 5] = 32'h00f72623; mem[ 6] = 32'h00070793; mem[ 7] = 32'h00400713;
    // line 1
    mem[ 8] = 32'h00e7a823; mem[ 9] = 32'h00100713; mem[10] = 32'h00e7aa23; mem[11] = 32'h001100713;
    mem[12] = 32'h00e7ac23; mem[13] = 32'h001200713; mem[14] = 32'h00e7ae23; mem[15] = 32'h00100713;
    // line 2
    mem[16] = 32'h00e7a023; mem[17] = 32'h00478713; mem[18] = 32'h00072783; mem[19] = 32'h0027f793;
    mem[20] = 32'hfe078ce3; mem[21] = 32'h0000006f; mem[22] = 32'h00000000; mem[23] = 32'h00000000;
    // lines 3-7 zero
    for (int i = 24; i < 64; i++) mem[i] = 32'h0;
    // line 8 (dims/metadata)
    mem[64] = 32'h04030201; mem[65] = 32'h08070605; mem[66] = 32'h00000000; mem[67] = 32'h00000000;
    mem[68] = 32'h01000001; mem[69] = 32'h00000000; mem[70] = 32'h00000000; mem[71] = 32'h00000000;
    // lines 9-15 zero
    for (int i = 72; i < DEPTH; i++) mem[i] = 32'h0;
  end

  // -------------------------------------------------------------------------
  // Icache read (single-beat)
  // -------------------------------------------------------------------------
  logic ic_busy;
  logic [3:0] ic_rline;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      ic_busy <= 1'b0;
      o_icache_rd_done <= 1'b0;
      o_icache_rd_data <= '0;
    end else begin
      o_icache_rd_done <= 1'b0;
      if (i_icache_rd_en && !ic_busy) begin
        ic_busy <= 1'b1;
        ic_rline <= ic_line;
      end else if (ic_busy) begin
        // Return 256-bit line (8 words)
        o_icache_rd_data <= {
          mem[ic_rline*8 + 7], mem[ic_rline*8 + 6],
          mem[ic_rline*8 + 5], mem[ic_rline*8 + 4],
          mem[ic_rline*8 + 3], mem[ic_rline*8 + 2],
          mem[ic_rline*8 + 1], mem[ic_rline*8 + 0]
        };
        o_icache_rd_done <= 1'b1;
        ic_busy <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Dcache read (single-beat, 64-bit)
  // -------------------------------------------------------------------------
  logic dc_busy;
  logic [3:0] dc_rline;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      dc_busy <= 1'b0;
      o_dcache_rd_done <= 1'b0;
      o_dcache_rd_data <= '0;
    end else begin
      o_dcache_rd_done <= 1'b0;
      if (i_dcache_rd_en && !dc_busy) begin
        dc_busy <= 1'b1;
        dc_rline <= dc_line;
      end else if (dc_busy) begin
        o_dcache_rd_data <= {
          mem[dc_rline*8 + dc_rline[0]*4 + 1], mem[dc_rline*8 + dc_rline[0]*4],
          mem[dc_rline*8 + dc_rline[0]*4 + 3], mem[dc_rline*8 + dc_rline[0]*4 + 2]
        };
        o_dcache_rd_done <= 1'b1;
        dc_busy <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Dcache write (byte-enable, single-beat)
  // -------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      o_dcache_wr_done <= 1'b0;
    end else begin
      o_dcache_wr_done <= 1'b0;
      if (i_dcache_wr_en) begin
        if (i_dcache_wr_be[0]) mem[dcw_line*8 + dcw_word*2 + 0][7:0]   <= i_dcache_wr_data[7:0];
        if (i_dcache_wr_be[1]) mem[dcw_line*8 + dcw_word*2 + 0][15:8]  <= i_dcache_wr_data[15:8];
        if (i_dcache_wr_be[2]) mem[dcw_line*8 + dcw_word*2 + 0][23:16] <= i_dcache_wr_data[23:16];
        if (i_dcache_wr_be[3]) mem[dcw_line*8 + dcw_word*2 + 0][31:24] <= i_dcache_wr_data[31:24];
        if (i_dcache_wr_be[4]) mem[dcw_line*8 + dcw_word*2 + 1][7:0]   <= i_dcache_wr_data[39:32];
        if (i_dcache_wr_be[5]) mem[dcw_line*8 + dcw_word*2 + 1][15:8]  <= i_dcache_wr_data[47:40];
        if (i_dcache_wr_be[6]) mem[dcw_line*8 + dcw_word*2 + 1][23:16] <= i_dcache_wr_data[55:48];
        if (i_dcache_wr_be[7]) mem[dcw_line*8 + dcw_word*2 + 1][31:24] <= i_dcache_wr_data[63:56];
        o_dcache_wr_done <= 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // AXI4 slave interface (from NPU DMA)
  // -------------------------------------------------------------------------
  localparam int BYTES_PER_BEAT = 4;
  logic        r_busy;
  logic [31:0] r_addr;
  logic [7:0]  r_len;
  logic [7:0]  r_beat;

  assign s_axi_arready = !r_busy;
  assign s_axi_rvalid  = r_busy;
  assign s_axi_rlast   = (r_beat == r_len);
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rdata   = mem[(r_addr[8:5] * 8) + {1'b0, r_addr[4:2]}];

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
      end else if (r_busy && s_axi_rready) begin
        r_beat <= r_beat + 8'd1;
        r_addr <= r_addr + BYTES_PER_BEAT;
        if (r_beat == r_len) begin
          r_busy <= 1'b0;
        end
      end
    end
  end

  // AXI write channel
  localparam int WS_IDLE = 0, WS_ADDR = 1, WS_DATA = 2, WS_RESP = 3;
  logic [1:0] wstate;
  logic [31:0] w_addr;
  logic [7:0]  w_len;
  logic [7:0]  w_beat;

  assign s_axi_awready = (wstate == WS_IDLE);
  assign s_axi_wready  = (wstate == WS_DATA);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      wstate <= WS_IDLE;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp <= 2'b00;
    end else begin
      case (wstate)
        WS_IDLE: begin
          s_axi_bvalid <= 1'b0;
          if (s_axi_awvalid) begin
            w_addr <= s_axi_awaddr;
            w_len  <= s_axi_awlen;
            w_beat <= 8'd0;
            wstate <= WS_DATA;
          end
        end
        WS_DATA: begin
          if (s_axi_wvalid) begin
            // Byte-enables for the 4-byte word
            if (s_axi_wstrb[0]) mem[w_addr[8:5]*8 + {1'b0, w_addr[4:2]}][7:0]   <= s_axi_wdata[7:0];
            if (s_axi_wstrb[1]) mem[w_addr[8:5]*8 + {1'b0, w_addr[4:2]}][15:8]  <= s_axi_wdata[15:8];
            if (s_axi_wstrb[2]) mem[w_addr[8:5]*8 + {1'b0, w_addr[4:2]}][23:16] <= s_axi_wdata[23:16];
            if (s_axi_wstrb[3]) mem[w_addr[8:5]*8 + {1'b0, w_addr[4:2]}][31:24] <= s_axi_wdata[31:24];
            w_beat <= w_beat + 8'd1;
            w_addr <= w_addr + BYTES_PER_BEAT;
            if (w_beat == w_len) begin
              wstate <= WS_RESP;
            end
          end
        end
        WS_RESP: begin
          s_axi_bvalid <= 1'b1;
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            wstate <= WS_IDLE;
          end
        end
        default: wstate <= WS_IDLE;
      endcase
    end
  end

endmodule
