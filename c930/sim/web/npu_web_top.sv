// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// npu_web_top.sv -- c930_npu_top as the SoC builds it, with a DDR stand-in,
// for a Verilator model a host program (or a browser) drives cycle by cycle.
//
// The NPU's parameters are c930_soc_top.sv's: an 8 x 8 array, DIN_W 16,
// ACC_W 48, MAX_M 8, MAX_K 16, MAX_N 12, and a weight bank per (N tile, K tile).
// The AXI4 slave memory is tb/tb_c930_npu.sv's model, unchanged except for
// its size (64 KB, the SoC's DDR stub) and two DPI exports a host uses to load
// operands and read results. The AXI4-Lite CSR port is driven by the host.
module npu_web_top #(
  parameter int NUM_ROWS = 8,
  parameter int NUM_COLS = 8,
  parameter int MAX_M    = 8,
  parameter int MAX_K    = 16,
  parameter int MAX_N    = 12,
  parameter int NPU_BANKS = ((MAX_N + NUM_COLS - 1) / NUM_COLS) * ((MAX_K + NUM_ROWS - 1) / NUM_ROWS),
  parameter int MEM_DEPTH = 16384     // 32-bit words: 64 KB
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [31:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,
  output logic        o_busy,
  output logic        o_done,
  output logic        o_error,
  output logic        o_irq
);
  logic [31:0] m_axi_araddr;  logic [7:0] m_axi_arlen;  logic [2:0] m_axi_arsize;  logic [1:0] m_axi_arburst;
  logic        m_axi_arvalid, m_axi_arready;
  logic [63:0] m_axi_rdata;   logic [1:0] m_axi_rresp;  logic m_axi_rlast, m_axi_rvalid, m_axi_rready;
  logic [31:0] m_axi_awaddr;  logic [7:0] m_axi_awlen;  logic [2:0] m_axi_awsize;  logic [1:0] m_axi_awburst;
  logic        m_axi_awvalid, m_axi_awready;
  logic [63:0] m_axi_wdata;   logic [7:0] m_axi_wstrb;  logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
  logic [1:0]  m_axi_bresp;   logic m_axi_bvalid, m_axi_bready;
  logic [31:0] arow_stall_count;

  c930_npu_top #(
    .NUM_ROWS (NUM_ROWS), .NUM_COLS (NUM_COLS), .DIN_W (16), .ACC_W (48),
    .MAX_M (MAX_M), .MAX_K (MAX_K), .MAX_N (MAX_N), .NUM_BANKS (NPU_BANKS)
  ) u_npu (
    .i_clk (clk), .i_rst_n (rst_n),
    .s_axi_awaddr, .s_axi_awvalid, .s_axi_awready, .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid,
    .s_axi_wready, .s_axi_bresp, .s_axi_bvalid, .s_axi_bready, .s_axi_araddr, .s_axi_arvalid,
    .s_axi_arready, .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
    .m_axi_araddr, .m_axi_arlen, .m_axi_arsize, .m_axi_arburst, .m_axi_arvalid, .m_axi_arready,
    .m_axi_rdata, .m_axi_rresp, .m_axi_rlast, .m_axi_rvalid, .m_axi_rready,
    .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst, .m_axi_awvalid, .m_axi_awready,
    .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid, .m_axi_wready,
    .m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
    .o_busy, .o_done, .o_error, .o_irq,
    .o_arow_stall_count (arow_stall_count)
  );

  // ---- AXI4 slave memory: tb/tb_c930_npu.sv's model ----
  logic [31:0] mem [0:MEM_DEPTH-1];

  export "DPI-C" function web_mem_write;
  export "DPI-C" function web_mem_read;
  function void web_mem_write(input int word, input int data);
    if (word >= 0 && word < MEM_DEPTH) mem[word] = data;
  endfunction
  function int web_mem_read(input int word);
    return (word >= 0 && word < MEM_DEPTH) ? mem[word] : 0;
  endfunction

  // Read channel
  logic [31:0] r_addr;  logic [7:0] r_len;  logic [7:0] r_beat;  logic r_busy;
  assign m_axi_arready = ~r_busy;
  assign m_axi_rvalid  = r_busy;
  assign m_axi_rlast   = (r_beat == r_len);
  logic [127:0] rd_window;
  logic [1:0]   rd_byte_off;
  // Word indices wrap inside the array, as the testbench's smaller one would not need to.
  function automatic logic [31:0] mw(input logic [31:0] i); return mem[i % MEM_DEPTH]; endfunction
  assign rd_byte_off = r_addr[1:0];
  assign rd_window = { mw((r_addr >> 2) + r_beat*2 + 3), mw((r_addr >> 2) + r_beat*2 + 2),
                       mw((r_addr >> 2) + r_beat*2 + 1), mw((r_addr >> 2) + r_beat*2) };
  assign m_axi_rdata = 64'(rd_window >> {rd_byte_off, 3'b000});
  assign m_axi_rresp = 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_busy <= 1'b0; r_addr <= '0; r_len <= '0; r_beat <= '0;
    end else begin
      if (m_axi_arvalid && m_axi_arready && !r_busy) begin
        r_addr <= m_axi_araddr; r_len <= m_axi_arlen; r_beat <= 8'd0; r_busy <= 1'b1;
      end
      if (r_busy && m_axi_rvalid && m_axi_rready) begin
        if (r_beat == r_len) r_busy <= 1'b0;
        else r_beat <= r_beat + 1;
      end
    end
  end

  // Write channel
  logic [31:0] w_addr;  logic [7:0] w_len;  logic [7:0] w_beat;  logic w_busy;  logic b_valid;
  assign m_axi_awready = ~w_busy;
  assign m_axi_wready  = w_busy;
  assign m_axi_bvalid  = b_valid;
  assign m_axi_bresp   = 2'b00;
  wire [31:0] w_word = ((w_addr >> 2) + w_beat*2) % MEM_DEPTH;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_busy <= 1'b0; b_valid <= 1'b0; w_addr <= '0; w_len <= '0; w_beat <= '0;
    end else begin
      if (m_axi_awvalid && m_axi_awready && !w_busy) begin
        w_addr <= m_axi_awaddr; w_len <= m_axi_awlen; w_beat <= 8'd0; w_busy <= 1'b1;
      end
      if (w_busy && m_axi_wvalid && m_axi_wready) begin
        for (int i = 0; i < 4; i++)
          if (m_axi_wstrb[i]) mem[w_word][i*8 +: 8] <= m_axi_wdata[i*8 +: 8];
        for (int i = 0; i < 4; i++)
          if (m_axi_wstrb[i+4]) mem[(w_word + 1) % MEM_DEPTH][i*8 +: 8] <= m_axi_wdata[(i+4)*8 +: 8];
        if (w_beat == w_len) begin w_busy <= 1'b0; b_valid <= 1'b1; end
        else w_beat <= w_beat + 1;
      end
      if (b_valid && m_axi_bready) b_valid <= 1'b0;
    end
  end
endmodule
