// c930_ddr_verilator.sv -- Verilator-friendly DDR stub
//
// Same ports as c930_ddr (synth stub) but uses a flat byte array instead of
// bank-interleaved 2D logic.  Uses explicit per-bank assignments for Verilator
// compatibility (no for loops with automatic variables in always_ff).

module c930_ddr
#(
  parameter int MEM_BYTES        = 65536,
  parameter int ADDR_WIDTH       = 64,
  parameter int CACHE_LINE_WIDTH = 256
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  input  logic [ADDR_WIDTH-1:0]       i_icache_rd_addr,
  input  logic                        i_icache_rd_req,
  output logic                        o_icache_rd_done,
  output logic [CACHE_LINE_WIDTH-1:0] o_icache_rd_line,

  input  logic [ADDR_WIDTH-1:0]       i_dcache_rd_addr,
  input  logic                        i_dcache_rd_req,
  output logic                        o_dcache_rd_done,
  output logic [CACHE_LINE_WIDTH-1:0] o_dcache_rd_line,

  input  logic [ADDR_WIDTH-1:0]       i_dcache_wr_addr,
  input  logic [63:0]                 i_dcache_wr_data,
  input  logic [7:0]                  i_dcache_wr_strobe,
  input  logic                        i_dcache_wr_valid,
  output logic                        o_dcache_wr_done,

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

  // Flat byte array -- Verilator handles 1D arrays reliably.
  logic [7:0] mem [0:MEM_BYTES-1];

  // ---- Boot firmware (sw/npu_boot.c -> sw/npu_boot.bin) ----
  initial begin
    for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h00;

    // line  0 = 256'h004007130007079300f7262300f7242300200793400007370040006f00008137
    {mem[ 3], mem[ 2], mem[ 1], mem[ 0]} = 32'h00008137;
    {mem[ 7], mem[ 6], mem[ 5], mem[ 4]} = 32'h0040006f;
    {mem[11], mem[10], mem[ 9], mem[ 8]} = 32'h40000737;
    {mem[15], mem[14], mem[13], mem[12]} = 32'h00200793;
    {mem[19], mem[18], mem[17], mem[16]} = 32'h00f72423;
    {mem[23], mem[22], mem[21], mem[20]} = 32'h00f72623;
    {mem[27], mem[26], mem[25], mem[24]} = 32'h00070793;
    {mem[31], mem[30], mem[29], mem[28]} = 32'h00400713;

    // line  1 = 256'h0010071300e7ae231200071300e7ac231100071300e7aa231000071300e7a823
    {mem[35], mem[34], mem[33], mem[32]} = 32'h00e7a823;
    {mem[39], mem[38], mem[37], mem[36]} = 32'h10000713;
    {mem[43], mem[42], mem[41], mem[40]} = 32'h00e7aa23;
    {mem[47], mem[46], mem[45], mem[44]} = 32'h11000713;
    {mem[51], mem[50], mem[49], mem[48]} = 32'h00e7ac23;
    {mem[55], mem[54], mem[53], mem[52]} = 32'h12000713;
    {mem[59], mem[58], mem[57], mem[56]} = 32'h00e7ae23;
    {mem[63], mem[62], mem[61], mem[60]} = 32'h00100713;

    // line  2
    {mem[67], mem[66], mem[65], mem[64]} = 32'h00e7a023;
    {mem[71], mem[70], mem[69], mem[68]} = 32'h00478713;
    {mem[75], mem[74], mem[73], mem[72]} = 32'h00072783;
    {mem[79], mem[78], mem[77], mem[76]} = 32'h0027f793;
    {mem[83], mem[82], mem[81], mem[80]} = 32'hfe078ce3;
    {mem[87], mem[86], mem[85], mem[84]} = 32'h0000006f;

    // line 8 (byte offset 256): NPU test data
    {mem[259], mem[258], mem[257], mem[256]} = 32'h04030201;
    {mem[263], mem[262], mem[261], mem[260]} = 32'h08070605;
    {mem[275], mem[274], mem[273], mem[272]} = 32'h01000001;
  end

  // ---- Read path: 3-cycle state machine ----
  typedef enum logic [1:0] { RD_IDLE, RD_ADDR, RD_DATA } rd_state_t;
  rd_state_t rd_state;
  logic [3:0]  rd_line_q;
  logic [1:0]  rd_src_q;
  logic [2:0]  rd_wordidx_q;

  wire [3:0] ic_line = i_icache_rd_addr[8:5];
  wire [3:0] dc_line = i_dcache_rd_addr[8:5];

  // Explicit per-bank read data (no for loops -- Verilator safe)
  logic [31:0] bank0, bank1, bank2, bank3, bank4, bank5, bank6, bank7;
  logic [CACHE_LINE_WIDTH-1:0] rd_line_data;

  wire [8:0] line_base = {rd_line_q, 5'b0};  // line_base = line * 32

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rd_state     <= RD_IDLE;
      rd_line_q    <= '0;
      rd_src_q     <= 2'b00;
      rd_wordidx_q <= '0;
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
        RD_ADDR: begin
          // Explicit bank reads (no for loop)
          bank0 <= {mem[line_base+ 3], mem[line_base+ 2], mem[line_base+ 1], mem[line_base]};
          bank1 <= {mem[line_base+ 7], mem[line_base+ 6], mem[line_base+ 5], mem[line_base+ 4]};
          bank2 <= {mem[line_base+11], mem[line_base+10], mem[line_base+ 9], mem[line_base+ 8]};
          bank3 <= {mem[line_base+15], mem[line_base+14], mem[line_base+13], mem[line_base+12]};
          bank4 <= {mem[line_base+19], mem[line_base+18], mem[line_base+17], mem[line_base+16]};
          bank5 <= {mem[line_base+23], mem[line_base+22], mem[line_base+21], mem[line_base+20]};
          bank6 <= {mem[line_base+27], mem[line_base+26], mem[line_base+25], mem[line_base+24]};
          bank7 <= {mem[line_base+31], mem[line_base+30], mem[line_base+29], mem[line_base+28]};
          rd_state <= RD_DATA;
        end
        RD_DATA: rd_state <= RD_IDLE;
      endcase
    end
  end

  // Assemble line from registered bank outputs
  assign rd_line_data = {bank7, bank6, bank5, bank4, bank3, bank2, bank1, bank0};

  assign o_icache_rd_done = (rd_state == RD_DATA) && (rd_src_q == 2'b00);
  assign o_dcache_rd_done = (rd_state == RD_DATA) && (rd_src_q == 2'b01);
  assign o_icache_rd_line = rd_line_data;
  assign o_dcache_rd_line = rd_line_data;

  // ---- Write path ----
  wire [2:0] dcw_word = i_dcache_wr_addr[4:3];
  wire [2:0] dc_ba = {dcw_word, 1'b0};
  wire [2:0] dc_bb = {dcw_word, 1'b1};
  wire [3:0] dcw_line = i_dcache_wr_addr[8:5];
  wire       dc_wr = i_dcache_wr_valid;
  wire [2:0] ax_bank = w_waddr[4:2];
  wire       ax_conf = dc_wr && (ax_bank == dc_ba || ax_bank == dc_bb);

  always_ff @(posedge i_clk) begin
    // Dcache write (2 banks, 32 bits each)
    if (dc_wr) begin
      if (i_dcache_wr_strobe[0]) mem[{dcw_line, 5'b0} + dc_ba*4 + 0] <= i_dcache_wr_data[7:0];
      if (i_dcache_wr_strobe[1]) mem[{dcw_line, 5'b0} + dc_ba*4 + 1] <= i_dcache_wr_data[15:8];
      if (i_dcache_wr_strobe[2]) mem[{dcw_line, 5'b0} + dc_ba*4 + 2] <= i_dcache_wr_data[23:16];
      if (i_dcache_wr_strobe[3]) mem[{dcw_line, 5'b0} + dc_ba*4 + 3] <= i_dcache_wr_data[31:24];
      if (i_dcache_wr_strobe[4]) mem[{dcw_line, 5'b0} + dc_bb*4 + 0] <= i_dcache_wr_data[39:32];
      if (i_dcache_wr_strobe[5]) mem[{dcw_line, 5'b0} + dc_bb*4 + 1] <= i_dcache_wr_data[47:40];
      if (i_dcache_wr_strobe[6]) mem[{dcw_line, 5'b0} + dc_bb*4 + 2] <= i_dcache_wr_data[55:48];
      if (i_dcache_wr_strobe[7]) mem[{dcw_line, 5'b0} + dc_bb*4 + 3] <= i_dcache_wr_data[63:56];
    end
    // AXI write (64-bit)
    if (ax_wr && !dc_wr) begin
      if (s_axi_wstrb[0]) mem[{w_waddr[8:5], 5'b0} + ax_bank*4 + 0] <= s_axi_wdata[7:0];
      if (s_axi_wstrb[1]) mem[{w_waddr[8:5], 5'b0} + ax_bank*4 + 1] <= s_axi_wdata[15:8];
      if (s_axi_wstrb[2]) mem[{w_waddr[8:5], 5'b0} + ax_bank*4 + 2] <= s_axi_wdata[23:16];
      if (s_axi_wstrb[3]) mem[{w_waddr[8:5], 5'b0} + ax_bank*4 + 3] <= s_axi_wdata[31:24];
      if (s_axi_wstrb[4]) mem[{w_waddr[8:5], 5'b0} + ax_bank*4 + 32 + 0] <= s_axi_wdata[39:32];
      if (s_axi_wstrb[5]) mem[{w_waddr[8:5], 5'b0} + ax_bank*4 + 32 + 1] <= s_axi_wdata[47:40];
      if (s_axi_wstrb[6]) mem[{w_waddr[8:5], 5'b0} + ax_bank*4 + 32 + 2] <= s_axi_wdata[55:48];
      if (s_axi_wstrb[7]) mem[{w_waddr[8:5], 5'b0} + ax_bank*4 + 32 + 3] <= s_axi_wdata[63:56];
    end
  end

  // ---- AXI read channel ----
  logic [31:0] r_addr;
  logic [7:0]  r_len;
  logic [7:0]  r_beat;
  logic        r_busy;
  wire [31:0]  r_waddr = r_addr + r_beat * 8;

  assign s_axi_arready = ~r_busy;
  assign s_axi_rvalid  = (rd_state == RD_DATA) && (rd_src_q == 2'b10);
  assign s_axi_rlast   = (r_beat == r_len);
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rdata   = rd_line_data[rd_wordidx_q*32 +: 64];

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

  // ---- AXI write channel ----
  logic [31:0] w_addr;
  logic [7:0]  w_len;
  logic [7:0]  w_beat;
  logic        w_busy;
  logic        b_valid;
  wire [31:0]  w_waddr = w_addr + w_beat * 8;

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

  // ---- Cache write-done handshake ----
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      o_dcache_wr_done <= 1'b0;
    else
      o_dcache_wr_done <= i_dcache_wr_valid;
  end

endmodule
