// Standalone NPU DPI wrapper for grxcp backend testing.
// Instantiates the NPU, provides a flat 64KB DDR array, and exposes
// DPI functions for CSR access and DDR memory read/write.
//
// The NPU's AXI master connects to a simple behavioral DDR model
// implemented inside this module. C++ code calls DPI functions to:
//   - Write CSRs (DIM_M, DIM_N, DIM_K, A_BASE, B_BASE, C_BASE, PREC, START)
//   - Read CSRs (STATUS, DONE, ERROR, CYCLE_COUNT, OP_COUNT, STALL_COUNT)
//   - Write DDR memory (load A/B data)
//   - Read DDR memory (check C results)
//
// Build: verilator --cc --exe + g++ with npu_dpi.cc

module c930_npu_dpi
#(
  parameter int NUM_ROWS = 4,
  parameter int NUM_COLS = 4,
  parameter int MAX_M    = 8,
  parameter int MAX_K    = 16,
  parameter int MAX_N    = 12,
  parameter int MEM_BYTES = 65536
)
(
  input  logic i_clk,
  input  logic i_rst_n,
  output logic o_busy,
  output logic o_done,
  output logic o_error,
  output logic o_irq
);

  // ---- DPI imports (must be module items, not header imports) ----
  import "DPI-C" function void dpi_npu_csr_write(input int addr, input int data);
  import "DPI-C" function int  dpi_npu_csr_read(input int addr);
  import "DPI-C" function void dpi_npu_mem_write(input int addr, input int data, input int strb);
  import "DPI-C" function int  dpi_npu_mem_read(input int addr);

  // ---- DDR memory (flat byte array) ----
  logic [7:0] ddr_mem [0:MEM_BYTES-1];

  // ---- AXI4-Lite slave (CSR access) ----
  logic [31:0] s_axi_awaddr;
  logic        s_axi_awvalid;
  logic        s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic [3:0]  s_axi_wstrb;
  logic        s_axi_wvalid;
  logic        s_axi_wready;
  logic [1:0]  s_axi_bresp;
  logic        s_axi_bvalid;
  logic        s_axi_bready;
  logic [31:0] s_axi_araddr;
  logic        s_axi_arvalid;
  logic        s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0]  s_axi_rresp;
  logic        s_axi_rvalid;
  logic        s_axi_rready;

  // ---- AXI4 full master (DDR data plane) ----
  logic [31:0] m_axi_araddr;
  logic [7:0]  m_axi_arlen;
  logic [2:0]  m_axi_arsize;
  logic [1:0]  m_axi_arburst;
  logic        m_axi_arvalid;
  logic        m_axi_arready;
  logic [63:0] m_axi_rdata;
  logic [1:0]  m_axi_rresp;
  logic        m_axi_rlast;
  logic        m_axi_rvalid;
  logic        m_axi_rready;
  logic [31:0] m_axi_awaddr;
  logic [7:0]  m_axi_awlen;
  logic [2:0]  m_axi_awsize;
  logic [1:0]  m_axi_awburst;
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

  // ---- NPU instance ----
  c930_npu_top #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (16),
    .ACC_W    (48),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N)
  ) u_npu (
    .i_clk       (i_clk),
    .i_rst_n     (i_rst_n),
    .s_axi_awaddr (s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata  (s_axi_wdata),
    .s_axi_wstrb  (s_axi_wstrb),
    .s_axi_wvalid (s_axi_wvalid),
    .s_axi_wready (s_axi_wready),
    .s_axi_bresp  (s_axi_bresp),
    .s_axi_bvalid (s_axi_bvalid),
    .s_axi_bready (s_axi_bready),
    .s_axi_araddr (s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata  (s_axi_rdata),
    .s_axi_rresp  (s_axi_rresp),
    .s_axi_rvalid (s_axi_rvalid),
    .s_axi_rready (s_axi_rready),
    .m_axi_araddr (m_axi_araddr),
    .m_axi_arlen  (m_axi_arlen),
    .m_axi_arsize (m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rdata  (m_axi_rdata),
    .m_axi_rresp  (m_axi_rresp),
    .m_axi_rlast  (m_axi_rlast),
    .m_axi_rvalid (m_axi_rvalid),
    .m_axi_rready (m_axi_rready),
    .m_axi_awaddr (m_axi_awaddr),
    .m_axi_awlen  (m_axi_awlen),
    .m_axi_awsize (m_axi_awsize),
    .m_axi_awburst(m_axi_awburst),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),
    .m_axi_wdata  (m_axi_wdata),
    .m_axi_wstrb  (m_axi_wstrb),
    .m_axi_wlast  (m_axi_wlast),
    .m_axi_wvalid (m_axi_wvalid),
    .m_axi_wready (m_axi_wready),
    .m_axi_bresp  (m_axi_bresp),
    .m_axi_bvalid (m_axi_bvalid),
    .m_axi_bready (m_axi_bready),
    .o_busy       (o_busy),
    .o_done       (o_done),
    .o_error      (o_error),
    .o_irq        (o_irq)
  );

  // ---- Simple behavioral AXI slave for DDR memory ----
  // Read channel: accept address, provide data after 1 cycle
  logic [31:0] rd_addr_reg;
  logic        rd_valid;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rd_valid <= 1'b0;
    end else begin
      if (m_axi_arvalid && m_axi_arready) begin
        rd_addr_reg <= m_axi_araddr;
        rd_valid <= 1'b1;
      end else if (m_axi_rvalid && m_axi_rready) begin
        rd_valid <= 1'b0;
      end
    end
  end

  assign m_axi_arready = 1'b1;  // always ready
  assign m_axi_rvalid  = rd_valid;
  assign m_axi_rresp   = 2'b00;  // OKAY
  assign m_axi_rlast   = 1'b1;   // single-beat

  // Read data: 64-bit word from flat memory
  wire [31:0] rd_idx = rd_addr_reg >> 3;  // 8 bytes per beat
  wire [2:0]  rd_off = rd_addr_reg[2:0];
  always_comb begin
    if (rd_off[2]) begin
      m_axi_rdata = {ddr_mem[rd_idx*8+7], ddr_mem[rd_idx*8+6],
                      ddr_mem[rd_idx*8+5], ddr_mem[rd_idx*8+4],
                      ddr_mem[rd_idx*8+3], ddr_mem[rd_idx*8+2],
                      ddr_mem[rd_idx*8+1], ddr_mem[rd_idx*8+0]};
    end else begin
      m_axi_rdata = {ddr_mem[rd_idx*8+15], ddr_mem[rd_idx*8+14],
                      ddr_mem[rd_idx*8+13], ddr_mem[rd_idx*8+12],
                      ddr_mem[rd_idx*8+11], ddr_mem[rd_idx*8+10],
                      ddr_mem[rd_idx*8+9],  ddr_mem[rd_idx*8+8]};
    end
  end

  // Write channel: accept address + data, store to memory
  assign m_axi_awready = 1'b1;
  assign m_axi_wready  = 1'b1;
  assign m_axi_bvalid  = m_axi_wvalid;
  assign m_axi_bresp   = 2'b00;

  wire [31:0] wr_idx = m_axi_awaddr >> 3;
  wire [2:0]  wr_off = m_axi_awaddr[2:0];

  always_ff @(posedge i_clk) begin
    if (m_axi_wvalid && m_axi_wready) begin
      if (wr_off[2]) begin
        if (m_axi_wstrb[0]) ddr_mem[wr_idx*8+0]  <= m_axi_wdata[7:0];
        if (m_axi_wstrb[1]) ddr_mem[wr_idx*8+1]  <= m_axi_wdata[15:8];
        if (m_axi_wstrb[2]) ddr_mem[wr_idx*8+2]  <= m_axi_wdata[23:16];
        if (m_axi_wstrb[3]) ddr_mem[wr_idx*8+3]  <= m_axi_wdata[31:24];
        if (m_axi_wstrb[4]) ddr_mem[wr_idx*8+4]  <= m_axi_wdata[39:32];
        if (m_axi_wstrb[5]) ddr_mem[wr_idx*8+5]  <= m_axi_wdata[47:40];
        if (m_axi_wstrb[6]) ddr_mem[wr_idx*8+6]  <= m_axi_wdata[55:48];
        if (m_axi_wstrb[7]) ddr_mem[wr_idx*8+7]  <= m_axi_wdata[63:56];
      end else begin
        if (m_axi_wstrb[0]) ddr_mem[wr_idx*8+8]  <= m_axi_wdata[7:0];
        if (m_axi_wstrb[1]) ddr_mem[wr_idx*8+9]  <= m_axi_wdata[15:8];
        if (m_axi_wstrb[2]) ddr_mem[wr_idx*8+10] <= m_axi_wdata[23:16];
        if (m_axi_wstrb[3]) ddr_mem[wr_idx*8+11] <= m_axi_wdata[31:24];
        if (m_axi_wstrb[4]) ddr_mem[wr_idx*8+12] <= m_axi_wdata[39:32];
        if (m_axi_wstrb[5]) ddr_mem[wr_idx*8+13] <= m_axi_wdata[47:40];
        if (m_axi_wstrb[6]) ddr_mem[wr_idx*8+14] <= m_axi_wdata[55:48];
        if (m_axi_wstrb[7]) ddr_mem[wr_idx*8+15] <= m_axi_wdata[63:56];
      end
    end
  end

  // ---- DPI function hooks for C++ ----
  // CSR read/write: drive AXI4-Lite signals directly
  always_ff @(posedge i_clk) begin
    // Default: deassert valid signals
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;
    s_axi_arvalid <= 1'b0;
    s_axi_bready  <= 1'b1;
    s_axi_rready  <= 1'b1;
  end

endmodule
