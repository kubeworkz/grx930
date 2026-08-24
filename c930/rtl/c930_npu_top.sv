// -----------------------------------------------------------------------------
// c930_npu_top.sv
//
// Memory-mapped INT8 tensor accelerator IP:
//
//   * AXI4-Lite slave  -> c930_npu_csr   (control/status/dims/bases)
//   * AXI4 full master -> c930_npu_dma   (autonomous fetch of A/B, store of C)
//   * c930_npu_core    -> systolic GEMM datapath + buffers
//
// Flow: the host writes DIMs and A/B/C base addresses plus CTRL.START over the
// AXI4-Lite slave. The DMA burst-reads A and B from memory into the core,
// launches the GEMM, then burst-writes C back to memory and pulses o_irq.
// -----------------------------------------------------------------------------
module c930_npu_top
#(
  parameter int NUM_ROWS = 8,
  parameter int NUM_COLS = 8,
  parameter int DIN_W    = 16,
  parameter int ACC_W    = 48,    // 48-bit fixed-point accumulator for FP modes
  parameter int MAX_M    = 64,
  parameter int MAX_K    = 256,
  parameter int MAX_N    = 8
)
(
  input  logic        i_clk,
  input  logic        i_rst_n,

  // ---- AXI4-Lite slave (control / status / dims / bases) ----
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

  // ---- AXI4 full master (DDR data plane) ----
  output logic [31:0] m_axi_araddr,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [31:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rlast,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready,
  output logic [31:0] m_axi_awaddr,
  output logic [7:0]  m_axi_awlen,
  output logic [2:0]  m_axi_awsize,
  output logic [1:0]  m_axi_awburst,
  output logic        m_axi_awvalid,
  input  logic        m_axi_awready,
  output logic [31:0] m_axi_wdata,
  output logic [3:0]  m_axi_wstrb,
  output logic        m_axi_wlast,
  output logic        m_axi_wvalid,
  input  logic        m_axi_wready,
  input  logic [1:0]  m_axi_bresp,
  input  logic        m_axi_bvalid,
  output logic        m_axi_bready,

  // ---- Completion ----
  output logic        o_busy,
  output logic        o_done,
  output logic        o_error,
  output logic        o_irq     // pulses on completion
);

  logic        start;
  logic        busy, done, error;
  logic [15:0] dim_m, dim_n, dim_k;
  logic [31:0] a_base, b_base, c_base;
  logic [2:0]  precision;

  logic                    dma_wen, dma_wsel, core_start;
  logic [15:0]             dma_waddr;
  logic signed [DIN_W-1:0] dma_wdata;
  logic [15:0]             c_raddr;
  logic signed [31:0]      c_rdata;   // always 32-bit (normalized by core)
  logic                    core_done, core_error;

  c930_npu_csr u_csr (
    .i_clk         (i_clk),
    .i_rst_n       (i_rst_n),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .o_start       (start),
    .o_dim_m       (dim_m),
    .o_dim_n       (dim_n),
    .o_dim_k       (dim_k),
    .o_a_base      (a_base),
    .o_b_base      (b_base),
    .o_c_base      (c_base),
    .o_precision   (precision),
    .i_busy        (busy),
    .i_done        (done),
    .i_error       (error)
  );

  c930_npu_dma #(
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N)
  ) u_dma (
    .i_clk         (i_clk),
    .i_rst_n       (i_rst_n),
    .i_start       (start),
    .i_dim_m       (dim_m),
    .i_dim_n       (dim_n),
    .i_dim_k       (dim_k),
    .i_a_base      (a_base),
    .i_b_base      (b_base),
    .i_c_base      (c_base),
    .i_precision   (precision),
    .o_busy        (busy),
    .o_done        (done),
    .o_error       (error),
    .o_wen         (dma_wen),
    .o_wsel        (dma_wsel),
    .o_waddr       (dma_waddr),
    .o_wdata       (dma_wdata),
    .o_core_start  (core_start),
    .i_core_done   (core_done),
    .i_core_error  (core_error),
    .o_c_raddr     (c_raddr),
    .i_c_rdata     (c_rdata),
    .m_axi_araddr  (m_axi_araddr),
    .m_axi_arlen   (m_axi_arlen),
    .m_axi_arsize  (m_axi_arsize),
    .m_axi_arburst (m_axi_arburst),
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rlast   (m_axi_rlast),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awlen   (m_axi_awlen),
    .m_axi_awsize  (m_axi_awsize),
    .m_axi_awburst (m_axi_awburst),
    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_wdata   (m_axi_wdata),
    .m_axi_wstrb   (m_axi_wstrb),
    .m_axi_wlast   (m_axi_wlast),
    .m_axi_wvalid  (m_axi_wvalid),
    .m_axi_wready  (m_axi_wready),
    .m_axi_bresp   (m_axi_bresp),
    .m_axi_bvalid  (m_axi_bvalid),
    .m_axi_bready  (m_axi_bready)
  );

  c930_npu_core #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (DIN_W),
    .ACC_W    (ACC_W),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N)
  ) u_core (
    .i_clk      (i_clk),
    .i_rst_n    (i_rst_n),
    .i_wen      (dma_wen),
    .i_wsel     (dma_wsel),
    .i_waddr    (dma_waddr),
    .i_wdata    (dma_wdata),
    .i_start    (core_start),
    .i_dim_m    (dim_m),
    .i_dim_n    (dim_n),
    .i_dim_k    (dim_k),
    .i_precision(precision),
    .o_busy     (),             // internal to the core; DMA drives the top's o_busy
    .o_done     (core_done),
    .o_error    (core_error),
    .i_c_raddr  (c_raddr),
    .o_c_rdata  (c_rdata)
  );

  assign o_busy  = busy;
  assign o_done  = done;
  assign o_error = error;
  assign o_irq   = done;

endmodule
