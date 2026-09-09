// -----------------------------------------------------------------------------
// c930_soc_top.sv
//
// Full C930-class SoC integrating:
//
//   * riscv_core_top       : CPU0 (RV64IMAC, 5-stage in-order, I/D caches),
//                            resets to 0x0000_0000 in DDR
//   * riscv_core_top (x3)  : CPU1..CPU3, reset into Boot ROM parking loops at
//                            0x0001_0020 / 0x0001_0060 / 0x0001_00A0
//   * c930_npu_top (x2)    : NPU0/NPU1 (AXI4-Lite CSR + AXI4 full DMA)
//   * c930_axi_cache_adapter (x4) : CPU cache-line ports → AXI4 full master
//   * c930_axi_crossbar    : 4-master × 4-slave AXI4 shared-bus crossbar
//   * c930_axi_dma_arb     : NPU0+NPU1 DMA merge (M2) and CPU1 I/D merge (M3)
//   * c930_mmio_arb        : CPU0+CPU1 uncached MMIO merge + HART_ID register
//   * c930_bootrom         : 1 KB boot ROM (AXI4 full slave, read-only)
//   * c930_ddr             : unified DDR (AXI4 full slave)
//   * c930_uart            : 16550-compatible UART (AXI4-Lite slave)
//   * c930_mmio_bridge     : CPU uncached MMIO → NPU AXI4-Lite CSR
//
// Memory map (byte addressed).  Two decoders, two views -- see
// doc/c930_architecture.md section 2.
//
// AXI4 crossbar (CPU caches, NPU DMA):
//   0x0000_0000 .. 0x0000_FFFF : DDR (code + data + NPU A/B/C buffers)
//   0x0001_0000 .. 0x0001_03FF : Boot ROM (1 KB, read-only)
//   0x4000_1000 .. 0x4000_100F : UART (16550, AXI4-Lite)
//   0x4000_0000 .. 0x4000_FFFF : MMIO -- SLVERR stub, reaches no peripheral
//
// CPU uncached MMIO path (mmio_arb -> mmio_bridge -> the mux below):
//   0x4000_0000 .. 0x4000_003F : NPU0 CSR (also the mux's DEFAULT target, so
//                                unclaimed 0x4000_xxxx aliases onto it)
//   0x4000_0040 .. 0x4000_007F : NPU1 CSR
//   0x4000_0FF0                : HART_ID (bridge-intercepted)
//   0x4000_0FF4/8/C            : CORE1/2/3_RELEASE (bridge-intercepted)
//   0x4000_1000 .. 0x4000_1FFF : UART (16550, AXI4-Lite)
//   0x4000_4000 .. 0x4000_4FFF : APLIC
//
// The CPU's data cache issues uncached MMIO transactions for addresses at or
// above MMIO_BASE through the existing c930_mmio_bridge. Everything else
// (I-cache reads, D-cache reads/writes) goes through the AXI4 cache adapters
// into the crossbar, which routes to boot ROM or DDR based on address.
//
// The NPU DMA master connects to the crossbar and shares DDR bandwidth with
// the CPU. Round-robin arbitration ensures fair access.
// -----------------------------------------------------------------------------
module c930_soc_top
#(
  parameter int NUM_ROWS = 8,
  parameter int NUM_COLS = 8,
  parameter int MAX_M    = 8,
  parameter int MAX_K    = 16,
  parameter int MAX_N    = 12,
  parameter int MEM_BYTES = 65536,
  parameter int CLK_DIV  = 1,
  // Shared L2 geometry.  Default 64 KB (512 sets x 4 ways x 32 B).  Tests can
  // shrink this (e.g. L2_NUM_SETS=64) for fast Icarus simulation; coherence
  // behavior is identical at any size.
  parameter int L2_NUM_SETS = 512,
  parameter int L2_NUM_WAYS = 4,
  // Debug: bypass the L2 (crossbar S1 -> DDR directly).  For isolating
  // boot hangs; normal operation leaves this 0.
  parameter bit BYPASS_L2 = 0,
  parameter     DDR_INIT_FILE = "",  // optional hex preload for DDR (testbench use)
  parameter     BOOT_INIT_FILE = "sw/boot.hex"  // boot ROM firmware hex
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- NPU0 status ----
  output logic o_npu_busy,
  output logic o_npu_done,
  output logic o_npu_error,
  output logic o_npu_irq,

  // ---- NPU1 status ----
  output logic o_npu1_busy,
  output logic o_npu1_done,
  output logic o_npu1_error,
  output logic o_npu1_irq,

  // ---- UART ----
  output logic o_uart_txd,
  input  logic i_uart_rxd,

  // ---- DDR testbench preload port (active only when USE_TB_PRELOAD=1) ----
  input  logic        i_tb_wr_en,
  input  logic [31:0] i_tb_wr_addr,
  input  logic [7:0]  i_tb_wr_data,

  // ---- DDR testbench readback port (simulation/debug only) ----
  input  logic [31:0] i_tb_rd_addr,
  output logic [7:0]  o_tb_rd_data
);

  localparam logic [63:0] MMIO_BASE = 64'h4000_0000;

  // =========================================================================
  // Clock generation (same as before)
  // =========================================================================
  logic core_clk;
  logic core_rst_n;

  generate
    if (CLK_DIV > 1) begin : g_clkgen
      (* DONT_TOUCH = "TRUE" *) logic [$clog2(CLK_DIV)-1:0] clk_cnt;
      (* DONT_TOUCH = "TRUE" *) logic clk_div;
      logic rst_s1, rst_s2;

      initial begin
        clk_cnt = '0;
        clk_div = 1'b0;
        rst_s1  = 1'b0;
        rst_s2  = 1'b0;
      end

      always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
          clk_cnt <= '0;
          clk_div <= 1'b0;
        end else begin
          if (clk_cnt == (CLK_DIV / 2) - 1) begin
            clk_cnt <= '0;
            clk_div <= ~clk_div;
          end else
            clk_cnt <= clk_cnt + 1'b1;
        end
      end
      assign core_clk = clk_div;

      always_ff @(posedge core_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
          rst_s1 <= 1'b0;
          rst_s2 <= 1'b0;
        end else begin
          rst_s1 <= 1'b1;
          rst_s2 <= rst_s1;
        end
      end
      assign core_rst_n = rst_s2;
    end else begin : g_clkpass
      assign core_clk   = i_clk;
      assign core_rst_n = i_rst_n;
    end
  endgenerate

  // =========================================================================
  // CPU cache-line ports (to cache adapters)
  // =========================================================================
  logic [63:0]  icache_rd_addr;
  logic         icache_rd_req;
  logic         icache_rd_done;
  logic [255:0] icache_rd_line;

  logic [63:0]  dcache_rd_addr;
  logic         dcache_rd_req;
  logic         dcache_rd_done;
  logic [255:0] dcache_rd_line;

  logic [63:0]  dcache_wr_addr;
  logic [63:0]  dcache_wr_data;
  logic [7:0]   dcache_wr_strobe;
  logic         dcache_wr_valid;
  logic         dcache_wr_done;

  // =========================================================================
  // CPU MMIO port (to MMIO bridge, for NPU CSR backward compat)
  // =========================================================================
  logic [63:0]  mmio_rd_addr;
  logic         mmio_rd_req;
  logic         mmio_rd_done;
  logic [63:0]  mmio_rd_data;

  logic [63:0]  mmio_wr_addr;
  logic [63:0]  mmio_wr_data;
  logic [7:0]   mmio_wr_strobe;
  logic         mmio_wr_valid;
  logic         mmio_wr_done;

  // =========================================================================
  // MMIO bridge <-> NPU AXI4-Lite CSR
  // =========================================================================
  logic [31:0]  csr_awaddr;
  logic         csr_awvalid;
  logic         csr_awready;
  logic [31:0]  csr_wdata;
  logic [3:0]   csr_wstrb;
  logic         csr_wvalid;
  logic         csr_wready;
  logic [1:0]   csr_bresp;
  logic         csr_bvalid;
  logic         csr_bready;
  logic [31:0]  csr_araddr;
  logic         csr_arvalid;
  logic         csr_arready;
  logic [31:0]  csr_rdata;
  logic [1:0]   csr_rresp;
  logic         csr_rvalid;
  logic         csr_rready;

  // =========================================================================
  // NPU0 AXI4 full master (to DMA arbiter -> crossbar)
  // =========================================================================
  logic [3:0]   npu_awid;
  logic [63:0]  npu_awaddr;
  logic [7:0]   npu_awlen;
  logic [2:0]   npu_awsize;
  logic [1:0]   npu_awburst;
  logic         npu_awvalid;
  logic         npu_awready;
  logic [63:0]  npu_wdata;
  logic [7:0]   npu_wstrb;
  logic         npu_wlast;
  logic         npu_wvalid;
  logic         npu_wready;
  logic [3:0]   npu_bid;
  logic [1:0]   npu_bresp;
  logic         npu_bvalid;
  logic         npu_bready;
  logic [3:0]   npu_arid;
  logic [63:0]  npu_araddr;
  logic [7:0]   npu_arlen;
  logic [2:0]   npu_arsize;
  logic [1:0]   npu_arburst;
  logic         npu_arvalid;
  logic         npu_arready;
  logic [3:0]   npu_rid;
  logic [63:0]  npu_rdata;
  logic [1:0]   npu_rresp;
  logic         npu_rlast;
  logic         npu_rvalid;
  logic         npu_rready;

  // =========================================================================
  // NPU1 AXI4-Lite CSR slave (from MMIO bridge, address 0x4000_0040+)
  // =========================================================================
  logic [31:0]  csr1_awaddr;
  logic         csr1_awvalid;
  logic         csr1_awready;
  logic [31:0]  csr1_wdata;
  logic [3:0]   csr1_wstrb;
  logic         csr1_wvalid;
  logic         csr1_wready;
  logic [1:0]   csr1_bresp;
  logic         csr1_bvalid;
  logic         csr1_bready;
  logic [31:0]  csr1_araddr;
  logic         csr1_arvalid;
  logic         csr1_arready;
  logic [31:0]  csr1_rdata;
  logic [1:0]   csr1_rresp;
  logic         csr1_rvalid;
  logic         csr1_rready;

  // =========================================================================
  // NPU1 AXI4 full master (to DMA arbiter -> crossbar)
  // =========================================================================
  logic [3:0]   npu1_awid;
  logic [63:0]  npu1_awaddr;
  logic [7:0]   npu1_awlen;
  logic [2:0]   npu1_awsize;
  logic [1:0]   npu1_awburst;
  logic         npu1_awvalid;
  logic         npu1_awready;
  logic [63:0]  npu1_wdata;
  logic [7:0]   npu1_wstrb;
  logic         npu1_wlast;
  logic         npu1_wvalid;
  logic         npu1_wready;
  logic [3:0]   npu1_bid;
  logic [1:0]   npu1_bresp;
  logic         npu1_bvalid;
  logic         npu1_bready;
  logic [3:0]   npu1_arid;
  logic [63:0]  npu1_araddr;
  logic [7:0]   npu1_arlen;
  logic [2:0]   npu1_arsize;
  logic [1:0]   npu1_arburst;
  logic         npu1_arvalid;
  logic         npu1_arready;
  logic [3:0]   npu1_rid;
  logic [63:0]  npu1_rdata;
  logic [1:0]   npu1_rresp;
  logic         npu1_rlast;
  logic         npu1_rvalid;
  logic         npu1_rready;

  // =========================================================================
  // DMA arbiter output (shared M2 port to crossbar)
  // =========================================================================
  logic [3:0]   arb_awid;
  logic [63:0]  arb_awaddr;
  logic [7:0]   arb_awlen;
  logic [2:0]   arb_awsize;
  logic [1:0]   arb_awburst;
  logic         arb_awvalid;
  logic         arb_awready;
  logic [63:0]  arb_wdata;
  logic [7:0]   arb_wstrb;
  logic         arb_wlast;
  logic         arb_wvalid;
  logic         arb_wready;
  logic [3:0]   arb_bid;
  logic [1:0]   arb_bresp;
  logic         arb_bvalid;
  logic         arb_bready;
  logic [3:0]   arb_arid;
  logic [63:0]  arb_araddr;
  logic [7:0]   arb_arlen;
  logic [2:0]   arb_arsize;
  logic [1:0]   arb_arburst;
  logic         arb_arvalid;
  logic         arb_arready;
  logic [3:0]   arb_rid;
  logic [63:0]  arb_rdata;
  logic [1:0]   arb_rresp;
  logic         arb_rlast;
  logic         arb_rvalid;
  logic         arb_rready;

  // =========================================================================
  // I-cache adapter: CPU I-cache → AXI4 full master (to crossbar)
  // =========================================================================
  logic [3:0]   icache_awid;
  logic [63:0]  icache_awaddr;
  logic [7:0]   icache_awlen;
  logic [2:0]   icache_awsize;
  logic [1:0]   icache_awburst;
  logic         icache_awvalid;
  logic         icache_awready;
  logic [63:0]  icache_wdata;
  logic [7:0]   icache_wstrb;
  logic         icache_wlast;
  logic         icache_wvalid;
  logic         icache_wready;
  logic [3:0]   icache_bid;
  logic [1:0]   icache_bresp;
  logic         icache_bvalid;
  logic         icache_bready;
  logic [3:0]   icache_arid;
  logic [63:0]  icache_araddr;
  logic [7:0]   icache_arlen;
  logic [2:0]   icache_arsize;
  logic [1:0]   icache_arburst;
  logic         icache_arvalid;
  logic         icache_arready;
  logic [3:0]   icache_rid;
  logic [63:0]  icache_rdata;
  logic [1:0]   icache_rresp;
  logic         icache_rlast;
  logic         icache_rvalid;
  logic         icache_rready;

  c930_axi_cache_adapter u_icache_adapter (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),

    // CPU I-cache port
    .i_cache_rd_addr (icache_rd_addr),
    .i_cache_rd_req  (icache_rd_req),
    .o_cache_rd_done (icache_rd_done),
    .o_cache_rd_line (icache_rd_line),

    // No write port for I-cache
    .i_cache_wr_addr  (64'd0),
    .i_cache_wr_data  (64'd0),
    .i_cache_wr_strobe(8'd0),
    .i_cache_wr_valid (1'b0),
    .o_cache_wr_done  (),

    // AXI4 full master
    .m_axi_awid      (icache_awid),
    .m_axi_awaddr    (icache_awaddr),
    .m_axi_awlen     (icache_awlen),
    .m_axi_awsize    (icache_awsize),
    .m_axi_awburst   (icache_awburst),
    .m_axi_awvalid   (icache_awvalid),
    .m_axi_awready   (icache_awready),
    .m_axi_wdata     (icache_wdata),
    .m_axi_wstrb     (icache_wstrb),
    .m_axi_wlast     (icache_wlast),
    .m_axi_wvalid    (icache_wvalid),
    .m_axi_wready    (icache_wready),
    .m_axi_bid       (icache_bid),
    .m_axi_bresp     (icache_bresp),
    .m_axi_bvalid    (icache_bvalid),
    .m_axi_bready    (icache_bready),
    .m_axi_arid      (icache_arid),
    .m_axi_araddr    (icache_araddr),
    .m_axi_arlen     (icache_arlen),
    .m_axi_arsize    (icache_arsize),
    .m_axi_arburst   (icache_arburst),
    .m_axi_arvalid   (icache_arvalid),
    .m_axi_arready   (icache_arready),
    .m_axi_rid       (icache_rid),
    .m_axi_rdata     (icache_rdata),
    .m_axi_rresp     (icache_rresp),
    .m_axi_rlast     (icache_rlast),
    .m_axi_rvalid    (icache_rvalid),
    .m_axi_rready    (icache_rready)
  );

  // =========================================================================
  // D-cache adapter: CPU D-cache → AXI4 full master (to crossbar)
  // =========================================================================
  logic [3:0]   dcache_awid;
  logic [63:0]  dcache_awaddr;
  logic [7:0]   dcache_awlen;
  logic [2:0]   dcache_awsize;
  logic [1:0]   dcache_awburst;
  logic         dcache_awvalid;
  logic         dcache_awready;
  logic [63:0]  dcache_wdata;
  logic [7:0]   dcache_wstrb;
  logic         dcache_wlast;
  logic         dcache_wvalid;
  logic         dcache_wready;
  logic [3:0]   dcache_bid;
  logic [1:0]   dcache_bresp;
  logic         dcache_bvalid;
  logic         dcache_bready;
  logic [3:0]   dcache_arid;
  logic [63:0]  dcache_araddr;
  logic [7:0]   dcache_arlen;
  logic [2:0]   dcache_arsize;
  logic [1:0]   dcache_arburst;
  logic         dcache_arvalid;
  logic         dcache_arready;
  logic [3:0]   dcache_rid;
  logic [63:0]  dcache_rdata;
  logic [1:0]   dcache_rresp;
  logic         dcache_rlast;
  logic         dcache_rvalid;
  logic         dcache_rready;

  c930_axi_cache_adapter #(.SOURCE_ID(1)) u_dcache_adapter (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),

    // CPU D-cache port
    .i_cache_rd_addr (dcache_rd_addr),
    .i_cache_rd_req  (dcache_rd_req),
    .o_cache_rd_done (dcache_rd_done),
    .o_cache_rd_line (dcache_rd_line),

    .i_cache_wr_addr  (dcache_wr_addr),
    .i_cache_wr_data  (dcache_wr_data),
    .i_cache_wr_strobe(dcache_wr_strobe),
    .i_cache_wr_valid (dcache_wr_valid),
    .o_cache_wr_done  (dcache_wr_done),

    // AXI4 full master
    .m_axi_awid      (dcache_awid),
    .m_axi_awaddr    (dcache_awaddr),
    .m_axi_awlen     (dcache_awlen),
    .m_axi_awsize    (dcache_awsize),
    .m_axi_awburst   (dcache_awburst),
    .m_axi_awvalid   (dcache_awvalid),
    .m_axi_awready   (dcache_awready),
    .m_axi_wdata     (dcache_wdata),
    .m_axi_wstrb     (dcache_wstrb),
    .m_axi_wlast     (dcache_wlast),
    .m_axi_wvalid    (dcache_wvalid),
    .m_axi_wready    (dcache_wready),
    .m_axi_bid       (dcache_bid),
    .m_axi_bresp     (dcache_bresp),
    .m_axi_bvalid    (dcache_bvalid),
    .m_axi_bready    (dcache_bready),
    .m_axi_arid      (dcache_arid),
    .m_axi_araddr    (dcache_araddr),
    .m_axi_arlen     (dcache_arlen),
    .m_axi_arsize    (dcache_arsize),
    .m_axi_arburst   (dcache_arburst),
    .m_axi_arvalid   (dcache_arvalid),
    .m_axi_arready   (dcache_arready),
    .m_axi_rid       (dcache_rid),
    .m_axi_rdata     (dcache_rdata),
    .m_axi_rresp     (dcache_rresp),
    .m_axi_rlast     (dcache_rlast),
    .m_axi_rvalid    (dcache_rvalid),
    .m_axi_rready    (dcache_rready)
  );

  // =========================================================================
  // CPU1 cache-line ports (second core)
  // =========================================================================
  logic [63:0]  icache1_rd_addr;
  logic         icache1_rd_req;
  logic         icache1_rd_done;
  logic [255:0] icache1_rd_line;

  logic [63:0]  dcache1_rd_addr;
  logic         dcache1_rd_req;
  logic         dcache1_rd_done;
  logic [255:0] dcache1_rd_line;

  logic [63:0]  dcache1_wr_addr;
  logic [63:0]  dcache1_wr_data;
  logic [7:0]   dcache1_wr_strobe;
  logic         dcache1_wr_valid;
  logic         dcache1_wr_done;

  // CPU1 MMIO port (uncached, merged with CPU0 by c930_mmio_arb)
  logic [63:0]  mmio1_rd_addr;
  logic         mmio1_rd_req;
  logic         mmio1_rd_done;
  logic [63:0]  mmio1_rd_data;
  logic [63:0]  mmio1_wr_addr;
  logic [63:0]  mmio1_wr_data;
  logic [7:0]   mmio1_wr_strobe;
  logic         mmio1_wr_valid;
  logic         mmio1_wr_done;

  // CPU1 cache adapter AXI4 signals
  logic [3:0]   icache1_awid;   logic [63:0]  icache1_awaddr;  logic [7:0]   icache1_awlen;
  logic [2:0]   icache1_awsize; logic [1:0]   icache1_awburst; logic         icache1_awvalid;
  logic         icache1_awready;
  logic [63:0]  icache1_wdata;  logic [7:0]   icache1_wstrb;   logic         icache1_wlast;
  logic         icache1_wvalid; logic         icache1_wready;
  logic [3:0]   icache1_bid;    logic [1:0]   icache1_bresp;   logic         icache1_bvalid;
  logic         icache1_bready;
  logic [3:0]   icache1_arid;   logic [63:0]  icache1_araddr;  logic [7:0]   icache1_arlen;
  logic [2:0]   icache1_arsize; logic [1:0]   icache1_arburst; logic         icache1_arvalid;
  logic         icache1_arready;
  logic [3:0]   icache1_rid;    logic [63:0]  icache1_rdata;   logic [1:0]   icache1_rresp;
  logic         icache1_rlast;  logic         icache1_rvalid;  logic         icache1_rready;

  logic [3:0]   dcache1_awid;   logic [63:0]  dcache1_awaddr;  logic [7:0]   dcache1_awlen;
  logic [2:0]   dcache1_awsize; logic [1:0]   dcache1_awburst; logic         dcache1_awvalid;
  logic         dcache1_awready;
  logic [63:0]  dcache1_wdata;  logic [7:0]   dcache1_wstrb;   logic         dcache1_wlast;
  logic         dcache1_wvalid; logic         dcache1_wready;
  logic [3:0]   dcache1_bid;    logic [1:0]   dcache1_bresp;   logic         dcache1_bvalid;
  logic         dcache1_bready;
  logic [3:0]   dcache1_arid;   logic [63:0]  dcache1_araddr;  logic [7:0]   dcache1_arlen;
  logic [2:0]   dcache1_arsize; logic [1:0]   dcache1_arburst; logic         dcache1_arvalid;
  logic         dcache1_arready;
  logic [3:0]   dcache1_rid;    logic [63:0]  dcache1_rdata;   logic [1:0]   dcache1_rresp;
  logic         dcache1_rlast;  logic         dcache1_rvalid;  logic         dcache1_rready;

  c930_axi_cache_adapter u_icache1_adapter (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),
    .i_cache_rd_addr (icache1_rd_addr),
    .i_cache_rd_req  (icache1_rd_req),
    .o_cache_rd_done (icache1_rd_done),
    .o_cache_rd_line (icache1_rd_line),
    .i_cache_wr_addr  (64'd0),
    .i_cache_wr_data  (64'd0),
    .i_cache_wr_strobe(8'd0),
    .i_cache_wr_valid (1'b0),
    .o_cache_wr_done  (),
    .m_axi_awid      (icache1_awid),
    .m_axi_awaddr    (icache1_awaddr),
    .m_axi_awlen     (icache1_awlen),
    .m_axi_awsize    (icache1_awsize),
    .m_axi_awburst   (icache1_awburst),
    .m_axi_awvalid   (icache1_awvalid),
    .m_axi_awready   (icache1_awready),
    .m_axi_wdata     (icache1_wdata),
    .m_axi_wstrb     (icache1_wstrb),
    .m_axi_wlast     (icache1_wlast),
    .m_axi_wvalid    (icache1_wvalid),
    .m_axi_wready    (icache1_wready),
    .m_axi_bid       (icache1_bid),
    .m_axi_bresp     (icache1_bresp),
    .m_axi_bvalid    (icache1_bvalid),
    .m_axi_bready    (icache1_bready),
    .m_axi_arid      (icache1_arid),
    .m_axi_araddr    (icache1_araddr),
    .m_axi_arlen     (icache1_arlen),
    .m_axi_arsize    (icache1_arsize),
    .m_axi_arburst   (icache1_arburst),
    .m_axi_arvalid   (icache1_arvalid),
    .m_axi_arready   (icache1_arready),
    .m_axi_rid       (icache1_rid),
    .m_axi_rdata     (icache1_rdata),
    .m_axi_rresp     (icache1_rresp),
    .m_axi_rlast     (icache1_rlast),
    .m_axi_rvalid    (icache1_rvalid),
    .m_axi_rready    (icache1_rready)
  );

  c930_axi_cache_adapter u_dcache1_adapter (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),
    .i_cache_rd_addr (dcache1_rd_addr),
    .i_cache_rd_req  (dcache1_rd_req),
    .o_cache_rd_done (dcache1_rd_done),
    .o_cache_rd_line (dcache1_rd_line),
    .i_cache_wr_addr  (dcache1_wr_addr),
    .i_cache_wr_data  (dcache1_wr_data),
    .i_cache_wr_strobe(dcache1_wr_strobe),
    .i_cache_wr_valid (dcache1_wr_valid),
    .o_cache_wr_done  (dcache1_wr_done),
    .m_axi_awid      (dcache1_awid),
    .m_axi_awaddr    (dcache1_awaddr),
    .m_axi_awlen     (dcache1_awlen),
    .m_axi_awsize    (dcache1_awsize),
    .m_axi_awburst   (dcache1_awburst),
    .m_axi_awvalid   (dcache1_awvalid),
    .m_axi_awready   (dcache1_awready),
    .m_axi_wdata     (dcache1_wdata),
    .m_axi_wstrb     (dcache1_wstrb),
    .m_axi_wlast     (dcache1_wlast),
    .m_axi_wvalid    (dcache1_wvalid),
    .m_axi_wready    (dcache1_wready),
    .m_axi_bid       (dcache1_bid),
    .m_axi_bresp     (dcache1_bresp),
    .m_axi_bvalid    (dcache1_bvalid),
    .m_axi_bready    (dcache1_bready),
    .m_axi_arid      (dcache1_arid),
    .m_axi_araddr    (dcache1_araddr),
    .m_axi_arlen     (dcache1_arlen),
    .m_axi_arsize    (dcache1_arsize),
    .m_axi_arburst   (dcache1_arburst),
    .m_axi_arvalid   (dcache1_arvalid),
    .m_axi_arready   (dcache1_arready),
    .m_axi_rid       (dcache1_rid),
    .m_axi_rdata     (dcache1_rdata),
    .m_axi_rresp     (dcache1_rresp),
    .m_axi_rlast     (dcache1_rlast),
    .m_axi_rvalid    (dcache1_rvalid),
    .m_axi_rready    (dcache1_rready)
  );

  // =========================================================================
  // CPU2 cache-line + MMIO ports (third core)
  // =========================================================================
  logic [63:0]  icache2_rd_addr;
  logic         icache2_rd_req;
  logic         icache2_rd_done;
  logic [255:0] icache2_rd_line;
  logic [63:0]  dcache2_rd_addr;
  logic         dcache2_rd_req;
  logic         dcache2_rd_done;
  logic [255:0] dcache2_rd_line;
  logic [63:0]  dcache2_wr_addr;
  logic [63:0]  dcache2_wr_data;
  logic [7:0]   dcache2_wr_strobe;
  logic         dcache2_wr_valid;
  logic         dcache2_wr_done;
  logic [63:0]  mmio2_rd_addr;
  logic         mmio2_rd_req;
  logic         mmio2_rd_done;
  logic [63:0]  mmio2_rd_data;
  logic [63:0]  mmio2_wr_addr;
  logic [63:0]  mmio2_wr_data;
  logic [7:0]   mmio2_wr_strobe;
  logic         mmio2_wr_valid;
  logic         mmio2_wr_done;

  // CPU3 cache-line + MMIO ports (fourth core)
  logic [63:0]  icache3_rd_addr;
  logic         icache3_rd_req;
  logic         icache3_rd_done;
  logic [255:0] icache3_rd_line;
  logic [63:0]  dcache3_rd_addr;
  logic         dcache3_rd_req;
  logic         dcache3_rd_done;
  logic [255:0] dcache3_rd_line;
  logic [63:0]  dcache3_wr_addr;
  logic [63:0]  dcache3_wr_data;
  logic [7:0]   dcache3_wr_strobe;
  logic         dcache3_wr_valid;
  logic         dcache3_wr_done;
  logic [63:0]  mmio3_rd_addr;
  logic         mmio3_rd_req;
  logic         mmio3_rd_done;
  logic [63:0]  mmio3_rd_data;
  logic [63:0]  mmio3_wr_addr;
  logic [63:0]  mmio3_wr_data;
  logic [7:0]   mmio3_wr_strobe;
  logic         mmio3_wr_valid;
  logic         mmio3_wr_done;

  // CPU2 cache-adapter AXI4 signals
  logic [3:0]   icache2_awid;   logic [63:0]  icache2_awaddr;  logic [7:0]   icache2_awlen;
  logic [2:0]   icache2_awsize; logic [1:0]   icache2_awburst; logic         icache2_awvalid;
  logic         icache2_awready;
  logic [63:0]  icache2_wdata;  logic [7:0]   icache2_wstrb;   logic         icache2_wlast;
  logic         icache2_wvalid; logic         icache2_wready;
  logic [3:0]   icache2_bid;    logic [1:0]   icache2_bresp;   logic         icache2_bvalid;
  logic         icache2_bready;
  logic [3:0]   icache2_arid;   logic [63:0]  icache2_araddr;  logic [7:0]   icache2_arlen;
  logic [2:0]   icache2_arsize; logic [1:0]   icache2_arburst; logic         icache2_arvalid;
  logic         icache2_arready;
  logic [3:0]   icache2_rid;    logic [63:0]  icache2_rdata;   logic [1:0]   icache2_rresp;
  logic         icache2_rlast;  logic         icache2_rvalid;  logic         icache2_rready;
  logic [3:0]   dcache2_awid;   logic [63:0]  dcache2_awaddr;  logic [7:0]   dcache2_awlen;
  logic [2:0]   dcache2_awsize; logic [1:0]   dcache2_awburst; logic         dcache2_awvalid;
  logic         dcache2_awready;
  logic [63:0]  dcache2_wdata;  logic [7:0]   dcache2_wstrb;   logic         dcache2_wlast;
  logic         dcache2_wvalid; logic         dcache2_wready;
  logic [3:0]   dcache2_bid;    logic [1:0]   dcache2_bresp;   logic         dcache2_bvalid;
  logic         dcache2_bready;
  logic [3:0]   dcache2_arid;   logic [63:0]  dcache2_araddr;  logic [7:0]   dcache2_arlen;
  logic [2:0]   dcache2_arsize; logic [1:0]   dcache2_arburst; logic         dcache2_arvalid;
  logic         dcache2_arready;
  logic [3:0]   dcache2_rid;    logic [63:0]  dcache2_rdata;   logic [1:0]   dcache2_rresp;
  logic         dcache2_rlast;  logic         dcache2_rvalid;  logic         dcache2_rready;

  // CPU3 cache-adapter AXI4 signals
  logic [3:0]   icache3_awid;   logic [63:0]  icache3_awaddr;  logic [7:0]   icache3_awlen;
  logic [2:0]   icache3_awsize; logic [1:0]   icache3_awburst; logic         icache3_awvalid;
  logic         icache3_awready;
  logic [63:0]  icache3_wdata;  logic [7:0]   icache3_wstrb;   logic         icache3_wlast;
  logic         icache3_wvalid; logic         icache3_wready;
  logic [3:0]   icache3_bid;    logic [1:0]   icache3_bresp;   logic         icache3_bvalid;
  logic         icache3_bready;
  logic [3:0]   icache3_arid;   logic [63:0]  icache3_araddr;  logic [7:0]   icache3_arlen;
  logic [2:0]   icache3_arsize; logic [1:0]   icache3_arburst; logic         icache3_arvalid;
  logic         icache3_arready;
  logic [3:0]   icache3_rid;    logic [63:0]  icache3_rdata;   logic [1:0]   icache3_rresp;
  logic         icache3_rlast;  logic         icache3_rvalid;  logic         icache3_rready;
  logic [3:0]   dcache3_awid;   logic [63:0]  dcache3_awaddr;  logic [7:0]   dcache3_awlen;
  logic [2:0]   dcache3_awsize; logic [1:0]   dcache3_awburst; logic         dcache3_awvalid;
  logic         dcache3_awready;
  logic [63:0]  dcache3_wdata;  logic [7:0]   dcache3_wstrb;   logic         dcache3_wlast;
  logic         dcache3_wvalid; logic         dcache3_wready;
  logic [3:0]   dcache3_bid;    logic [1:0]   dcache3_bresp;   logic         dcache3_bvalid;
  logic         dcache3_bready;
  logic [3:0]   dcache3_arid;   logic [63:0]  dcache3_araddr;  logic [7:0]   dcache3_arlen;
  logic [2:0]   dcache3_arsize; logic [1:0]   dcache3_arburst; logic         dcache3_arvalid;
  logic         dcache3_arready;
  logic [3:0]   dcache3_rid;    logic [63:0]  dcache3_rdata;   logic [1:0]   dcache3_rresp;
  logic         dcache3_rlast;  logic         dcache3_rvalid;  logic         dcache3_rready;

  c930_axi_cache_adapter u_icache2_adapter (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),
    .i_cache_rd_addr (icache2_rd_addr),
    .i_cache_rd_req  (icache2_rd_req),
    .o_cache_rd_done (icache2_rd_done),
    .o_cache_rd_line (icache2_rd_line),
    .i_cache_wr_addr  (64'd0),
    .i_cache_wr_data  (64'd0),
    .i_cache_wr_strobe(8'd0),
    .i_cache_wr_valid (1'b0),
    .o_cache_wr_done  (),
    .m_axi_awid      (icache2_awid),
    .m_axi_awaddr    (icache2_awaddr),
    .m_axi_awlen     (icache2_awlen),
    .m_axi_awsize    (icache2_awsize),
    .m_axi_awburst   (icache2_awburst),
    .m_axi_awvalid   (icache2_awvalid),
    .m_axi_awready   (icache2_awready),
    .m_axi_wdata     (icache2_wdata),
    .m_axi_wstrb     (icache2_wstrb),
    .m_axi_wlast     (icache2_wlast),
    .m_axi_wvalid    (icache2_wvalid),
    .m_axi_wready    (icache2_wready),
    .m_axi_bid       (icache2_bid),
    .m_axi_bresp     (icache2_bresp),
    .m_axi_bvalid    (icache2_bvalid),
    .m_axi_bready    (icache2_bready),
    .m_axi_arid      (icache2_arid),
    .m_axi_araddr    (icache2_araddr),
    .m_axi_arlen     (icache2_arlen),
    .m_axi_arsize    (icache2_arsize),
    .m_axi_arburst   (icache2_arburst),
    .m_axi_arvalid   (icache2_arvalid),
    .m_axi_arready   (icache2_arready),
    .m_axi_rid       (icache2_rid),
    .m_axi_rdata     (icache2_rdata),
    .m_axi_rresp     (icache2_rresp),
    .m_axi_rlast     (icache2_rlast),
    .m_axi_rvalid    (icache2_rvalid),
    .m_axi_rready    (icache2_rready)
  );

  c930_axi_cache_adapter u_dcache2_adapter (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),
    .i_cache_rd_addr (dcache2_rd_addr),
    .i_cache_rd_req  (dcache2_rd_req),
    .o_cache_rd_done (dcache2_rd_done),
    .o_cache_rd_line (dcache2_rd_line),
    .i_cache_wr_addr  (dcache2_wr_addr),
    .i_cache_wr_data  (dcache2_wr_data),
    .i_cache_wr_strobe(dcache2_wr_strobe),
    .i_cache_wr_valid (dcache2_wr_valid),
    .o_cache_wr_done  (dcache2_wr_done),
    .m_axi_awid      (dcache2_awid),
    .m_axi_awaddr    (dcache2_awaddr),
    .m_axi_awlen     (dcache2_awlen),
    .m_axi_awsize    (dcache2_awsize),
    .m_axi_awburst   (dcache2_awburst),
    .m_axi_awvalid   (dcache2_awvalid),
    .m_axi_awready   (dcache2_awready),
    .m_axi_wdata     (dcache2_wdata),
    .m_axi_wstrb     (dcache2_wstrb),
    .m_axi_wlast     (dcache2_wlast),
    .m_axi_wvalid    (dcache2_wvalid),
    .m_axi_wready    (dcache2_wready),
    .m_axi_bid       (dcache2_bid),
    .m_axi_bresp     (dcache2_bresp),
    .m_axi_bvalid    (dcache2_bvalid),
    .m_axi_bready    (dcache2_bready),
    .m_axi_arid      (dcache2_arid),
    .m_axi_araddr    (dcache2_araddr),
    .m_axi_arlen     (dcache2_arlen),
    .m_axi_arsize    (dcache2_arsize),
    .m_axi_arburst   (dcache2_arburst),
    .m_axi_arvalid   (dcache2_arvalid),
    .m_axi_arready   (dcache2_arready),
    .m_axi_rid       (dcache2_rid),
    .m_axi_rdata     (dcache2_rdata),
    .m_axi_rresp     (dcache2_rresp),
    .m_axi_rlast     (dcache2_rlast),
    .m_axi_rvalid    (dcache2_rvalid),
    .m_axi_rready    (dcache2_rready)
  );

  c930_axi_cache_adapter u_icache3_adapter (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),
    .i_cache_rd_addr (icache3_rd_addr),
    .i_cache_rd_req  (icache3_rd_req),
    .o_cache_rd_done (icache3_rd_done),
    .o_cache_rd_line (icache3_rd_line),
    .i_cache_wr_addr  (64'd0),
    .i_cache_wr_data  (64'd0),
    .i_cache_wr_strobe(8'd0),
    .i_cache_wr_valid (1'b0),
    .o_cache_wr_done  (),
    .m_axi_awid      (icache3_awid),
    .m_axi_awaddr    (icache3_awaddr),
    .m_axi_awlen     (icache3_awlen),
    .m_axi_awsize    (icache3_awsize),
    .m_axi_awburst   (icache3_awburst),
    .m_axi_awvalid   (icache3_awvalid),
    .m_axi_awready   (icache3_awready),
    .m_axi_wdata     (icache3_wdata),
    .m_axi_wstrb     (icache3_wstrb),
    .m_axi_wlast     (icache3_wlast),
    .m_axi_wvalid    (icache3_wvalid),
    .m_axi_wready    (icache3_wready),
    .m_axi_bid       (icache3_bid),
    .m_axi_bresp     (icache3_bresp),
    .m_axi_bvalid    (icache3_bvalid),
    .m_axi_bready    (icache3_bready),
    .m_axi_arid      (icache3_arid),
    .m_axi_araddr    (icache3_araddr),
    .m_axi_arlen     (icache3_arlen),
    .m_axi_arsize    (icache3_arsize),
    .m_axi_arburst   (icache3_arburst),
    .m_axi_arvalid   (icache3_arvalid),
    .m_axi_arready   (icache3_arready),
    .m_axi_rid       (icache3_rid),
    .m_axi_rdata     (icache3_rdata),
    .m_axi_rresp     (icache3_rresp),
    .m_axi_rlast     (icache3_rlast),
    .m_axi_rvalid    (icache3_rvalid),
    .m_axi_rready    (icache3_rready)
  );

  c930_axi_cache_adapter u_dcache3_adapter (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),
    .i_cache_rd_addr (dcache3_rd_addr),
    .i_cache_rd_req  (dcache3_rd_req),
    .o_cache_rd_done (dcache3_rd_done),
    .o_cache_rd_line (dcache3_rd_line),
    .i_cache_wr_addr  (dcache3_wr_addr),
    .i_cache_wr_data  (dcache3_wr_data),
    .i_cache_wr_strobe(dcache3_wr_strobe),
    .i_cache_wr_valid (dcache3_wr_valid),
    .o_cache_wr_done  (dcache3_wr_done),
    .m_axi_awid      (dcache3_awid),
    .m_axi_awaddr    (dcache3_awaddr),
    .m_axi_awlen     (dcache3_awlen),
    .m_axi_awsize    (dcache3_awsize),
    .m_axi_awburst   (dcache3_awburst),
    .m_axi_awvalid   (dcache3_awvalid),
    .m_axi_awready   (dcache3_awready),
    .m_axi_wdata     (dcache3_wdata),
    .m_axi_wstrb     (dcache3_wstrb),
    .m_axi_wlast     (dcache3_wlast),
    .m_axi_wvalid    (dcache3_wvalid),
    .m_axi_wready    (dcache3_wready),
    .m_axi_bid       (dcache3_bid),
    .m_axi_bresp     (dcache3_bresp),
    .m_axi_bvalid    (dcache3_bvalid),
    .m_axi_bready    (dcache3_bready),
    .m_axi_arid      (dcache3_arid),
    .m_axi_araddr    (dcache3_araddr),
    .m_axi_arlen     (dcache3_arlen),
    .m_axi_arsize    (dcache3_arsize),
    .m_axi_arburst   (dcache3_arburst),
    .m_axi_arvalid   (dcache3_arvalid),
    .m_axi_arready   (dcache3_arready),
    .m_axi_rid       (dcache3_rid),
    .m_axi_rdata     (dcache3_rdata),
    .m_axi_rresp     (dcache3_rresp),
    .m_axi_rlast     (dcache3_rlast),
    .m_axi_rvalid    (dcache3_rvalid),
    .m_axi_rready    (dcache3_rready)
  );

  // =========================================================================
  // CPU1 bus arbiter: merges CPU1 I/D caches into crossbar M3 port
  // =========================================================================
  logic [3:0]   arb1_awid;   logic [63:0]  arb1_awaddr;  logic [7:0]   arb1_awlen;
  logic [2:0]   arb1_awsize; logic [1:0]   arb1_awburst; logic         arb1_awvalid;
  logic         arb1_awready;
  logic [63:0]  arb1_wdata;  logic [7:0]   arb1_wstrb;   logic         arb1_wlast;
  logic         arb1_wvalid; logic         arb1_wready;
  logic [3:0]   arb1_bid;    logic [1:0]   arb1_bresp;   logic         arb1_bvalid;
  logic         arb1_bready;
  logic [3:0]   arb1_arid;   logic [63:0]  arb1_araddr;  logic [7:0]   arb1_arlen;
  logic [2:0]   arb1_arsize; logic [1:0]   arb1_arburst; logic         arb1_arvalid;
  logic         arb1_arready;
  logic [3:0]   arb1_rid;    logic [63:0]  arb1_rdata;   logic [1:0]   arb1_rresp;
  logic         arb1_rlast;  logic         arb1_rvalid;  logic         arb1_rready;

  c930_axi_dma_arb #(
    .ADDR_WIDTH (64),
    .DATA_WIDTH (64),
    .ID_WIDTH   (4),
    .ARB_ID_BASE (2'b01)
  ) u_core1_arb (
    .i_clk     (core_clk),
    .i_rst_n   (core_rst_n),

    // CPU1 I-cache (master 0)
    .m0_awid    (icache1_awid),  .m0_awaddr  (icache1_awaddr), .m0_awlen  (icache1_awlen),
    .m0_awsize  (icache1_awsize),.m0_awburst (icache1_awburst),.m0_awvalid(icache1_awvalid),
    .m0_awready (icache1_awready),
    .m0_wdata   (icache1_wdata), .m0_wstrb   (icache1_wstrb),  .m0_wlast  (icache1_wlast),
    .m0_wvalid  (icache1_wvalid),.m0_wready  (icache1_wready),
    .m0_bid     (icache1_bid),   .m0_bresp   (icache1_bresp),  .m0_bvalid (icache1_bvalid),
    .m0_bready  (icache1_bready),
    .m0_arid    (icache1_arid),  .m0_araddr  (icache1_araddr), .m0_arlen  (icache1_arlen),
    .m0_arsize  (icache1_arsize),.m0_arburst (icache1_arburst),.m0_arvalid(icache1_arvalid),
    .m0_arready (icache1_arready),
    .m0_rid     (icache1_rid),   .m0_rdata   (icache1_rdata),  .m0_rresp  (icache1_rresp),
    .m0_rlast   (icache1_rlast), .m0_rvalid  (icache1_rvalid), .m0_rready (icache1_rready),

    // CPU1 D-cache (master 1)
    .m1_awid    (dcache1_awid),  .m1_awaddr  (dcache1_awaddr), .m1_awlen  (dcache1_awlen),
    .m1_awsize  (dcache1_awsize),.m1_awburst (dcache1_awburst),.m1_awvalid(dcache1_awvalid),
    .m1_awready (dcache1_awready),
    .m1_wdata   (dcache1_wdata), .m1_wstrb   (dcache1_wstrb),  .m1_wlast  (dcache1_wlast),
    .m1_wvalid  (dcache1_wvalid),.m1_wready  (dcache1_wready),
    .m1_bid     (dcache1_bid),   .m1_bresp   (dcache1_bresp),  .m1_bvalid (dcache1_bvalid),
    .m1_bready  (dcache1_bready),
    .m1_arid    (dcache1_arid),  .m1_araddr  (dcache1_araddr), .m1_arlen  (dcache1_arlen),
    .m1_arsize  (dcache1_arsize),.m1_arburst (dcache1_arburst),.m1_arvalid(dcache1_arvalid),
    .m1_arready (dcache1_arready),
    .m1_rid     (dcache1_rid),   .m1_rdata   (dcache1_rdata),  .m1_rresp  (dcache1_rresp),
    .m1_rlast   (dcache1_rlast), .m1_rvalid  (dcache1_rvalid), .m1_rready (dcache1_rready),

    // CPU2 I-cache (master 2)
    .m2_awid    (icache2_awid),  .m2_awaddr  (icache2_awaddr), .m2_awlen  (icache2_awlen),
    .m2_awsize  (icache2_awsize),.m2_awburst (icache2_awburst),.m2_awvalid(icache2_awvalid),
    .m2_awready (icache2_awready),
    .m2_wdata   (icache2_wdata), .m2_wstrb   (icache2_wstrb),  .m2_wlast  (icache2_wlast),
    .m2_wvalid  (icache2_wvalid),.m2_wready  (icache2_wready),
    .m2_bid     (icache2_bid),   .m2_bresp   (icache2_bresp),  .m2_bvalid (icache2_bvalid),
    .m2_bready  (icache2_bready),
    .m2_arid    (icache2_arid),  .m2_araddr  (icache2_araddr), .m2_arlen  (icache2_arlen),
    .m2_arsize  (icache2_arsize),.m2_arburst (icache2_arburst),.m2_arvalid(icache2_arvalid),
    .m2_arready (icache2_arready),
    .m2_rid     (icache2_rid),   .m2_rdata   (icache2_rdata),  .m2_rresp  (icache2_rresp),
    .m2_rlast   (icache2_rlast), .m2_rvalid  (icache2_rvalid), .m2_rready (icache2_rready),

    // CPU2 D-cache (master 3)
    .m3_awid    (dcache2_awid),  .m3_awaddr  (dcache2_awaddr), .m3_awlen  (dcache2_awlen),
    .m3_awsize  (dcache2_awsize),.m3_awburst (dcache2_awburst),.m3_awvalid(dcache2_awvalid),
    .m3_awready (dcache2_awready),
    .m3_wdata   (dcache2_wdata), .m3_wstrb   (dcache2_wstrb),  .m3_wlast  (dcache2_wlast),
    .m3_wvalid  (dcache2_wvalid),.m3_wready  (dcache2_wready),
    .m3_bid     (dcache2_bid),   .m3_bresp   (dcache2_bresp),  .m3_bvalid (dcache2_bvalid),
    .m3_bready  (dcache2_bready),
    .m3_arid    (dcache2_arid),  .m3_araddr  (dcache2_araddr), .m3_arlen  (dcache2_arlen),
    .m3_arsize  (dcache2_arsize),.m3_arburst (dcache2_arburst),.m3_arvalid(dcache2_arvalid),
    .m3_arready (dcache2_arready),
    .m3_rid     (dcache2_rid),   .m3_rdata   (dcache2_rdata),  .m3_rresp  (dcache2_rresp),
    .m3_rlast   (dcache2_rlast), .m3_rvalid  (dcache2_rvalid), .m3_rready (dcache2_rready),

    // Merged AXI4 master (to crossbar M3)
    .s_awid    (arb1_awid),    .s_awaddr  (arb1_awaddr),   .s_awlen  (arb1_awlen),
    .s_awsize  (arb1_awsize),  .s_awburst (arb1_awburst),  .s_awvalid(arb1_awvalid),
    .s_awready (arb1_awready),
    .s_wdata   (arb1_wdata),   .s_wstrb   (arb1_wstrb),    .s_wlast  (arb1_wlast),
    .s_wvalid  (arb1_wvalid),  .s_wready  (arb1_wready),
    .s_bid     (arb1_bid),     .s_bresp   (arb1_bresp),    .s_bvalid (arb1_bvalid),
    .s_bready  (arb1_bready),
    .s_arid    (arb1_arid),    .s_araddr  (arb1_araddr),   .s_arlen  (arb1_arlen),
    .s_arsize  (arb1_arsize),  .s_arburst (arb1_arburst),  .s_arvalid(arb1_arvalid),
    .s_arready (arb1_arready),
    .s_rid     (arb1_rid),     .s_rdata   (arb1_rdata),    .s_rresp  (arb1_rresp),
    .s_rlast   (arb1_rlast),   .s_rvalid  (arb1_rvalid),   .s_rready (arb1_rready)
  );

  // =========================================================================
  // AXI4 crossbar: 4 masters × 4 slaves
  //
  // M0: I-cache adapter
  // M1: D-cache adapter
  // M2: NPU DMA
  //
  // S0: Boot ROM (0x0000_0000 – 0x0000_03FF)
  // S1: DDR      (0x0000_1000 – 0x0000_FFFF)
  // S2: MMIO     (0x4000_0000 – 0x4000_FFFF, for future peripherals)
  // S3: UART     (0x4000_1000 – 0x4000_100F)
  // =========================================================================

  // Boot ROM signals
  logic [3:0]   boot_awid;
  logic [63:0]  boot_awaddr;
  logic [7:0]   boot_awlen;
  logic [2:0]   boot_awsize;
  logic [1:0]   boot_awburst;
  logic         boot_awvalid;
  logic         boot_awready;
  logic [63:0]  boot_wdata;
  logic [7:0]   boot_wstrb;
  logic         boot_wlast;
  logic         boot_wvalid;
  logic         boot_wready;
  logic [3:0]   boot_bid;
  logic [1:0]   boot_bresp;
  logic         boot_bvalid;
  logic         boot_bready;
  logic [3:0]   boot_arid;
  logic [63:0]  boot_araddr;
  logic [7:0]   boot_arlen;
  logic [2:0]   boot_arsize;
  logic [1:0]   boot_arburst;
  logic         boot_arvalid;
  logic         boot_arready;
  logic [3:0]   boot_rid;
  logic [63:0]  boot_rdata;
  logic [1:0]   boot_rresp;
  logic         boot_rlast;
  logic         boot_rvalid;
  logic         boot_rready;

  // DDR signals (from crossbar slave 1)
  // Shared L2 slave-side nets (crossbar S1 -> L2).  The L2 master side
  // drives the ddr_* nets below.
  logic [3:0]   l2_s_awid;
  logic [63:0]  l2_s_awaddr;
  logic [7:0]   l2_s_awlen;
  logic [2:0]   l2_s_awsize;
  logic [1:0]   l2_s_awburst;
  logic         l2_s_awvalid;
  logic         l2_s_awready;
  logic [63:0]  l2_s_wdata;
  logic [7:0]   l2_s_wstrb;
  logic         l2_s_wlast;
  logic         l2_s_wvalid;
  logic         l2_s_wready;
  logic [3:0]   l2_s_bid;
  logic [1:0]   l2_s_bresp;
  logic         l2_s_bvalid;
  logic         l2_s_bready;
  logic [3:0]   l2_s_arid;
  logic [63:0]  l2_s_araddr;
  logic [7:0]   l2_s_arlen;
  logic [2:0]   l2_s_arsize;
  logic [1:0]   l2_s_arburst;
  logic         l2_s_arvalid;
  logic         l2_s_arready;
  logic [3:0]   l2_s_rid;
  logic [63:0]  l2_s_rdata;
  logic [1:0]   l2_s_rresp;
  logic         l2_s_rlast;
  logic         l2_s_rvalid;
  logic         l2_s_rready;

  // L1 invalidation bus (L2 -> the 8 per-core caches):
  //   port 0 = CPU0-I   1 = CPU0-D   2 = CPU1-I   3 = CPU1-D
  //   port 4 = CPU2-I   5 = CPU2-D   6 = CPU3-I   7 = CPU3-D
  logic [7:0]   l2_inv_valid;
  logic [63:0]  l2_inv_addr;
  logic [7:0]   l2_inv_ack;

  logic [3:0]   ddr_awid;
  logic [63:0]  ddr_awaddr;
  logic [7:0]   ddr_awlen;
  logic [2:0]   ddr_awsize;
  logic [1:0]   ddr_awburst;
  logic         ddr_awvalid;
  logic         ddr_awready;
  logic [63:0]  ddr_wdata;
  logic [7:0]   ddr_wstrb;
  logic         ddr_wlast;
  logic         ddr_wvalid;
  logic         ddr_wready;
  logic [3:0]   ddr_bid;
  logic [1:0]   ddr_bresp;
  logic         ddr_bvalid;
  logic         ddr_bready;
  logic [3:0]   ddr_arid;
  logic [63:0]  ddr_araddr;
  logic [7:0]   ddr_arlen;
  logic [2:0]   ddr_arsize;
  logic [1:0]   ddr_arburst;
  logic         ddr_arvalid;
  logic         ddr_arready;
  logic [3:0]   ddr_rid;
  logic [63:0]  ddr_rdata;
  logic [1:0]   ddr_rresp;
  logic         ddr_rlast;
  logic         ddr_rvalid;
  logic         ddr_rready;

  // MMIO slave signals (from crossbar slave 2, for future peripherals)
  logic [3:0]   mmio_sl_awid;
  logic [63:0]  mmio_sl_awaddr;
  logic [7:0]   mmio_sl_awlen;
  logic [2:0]   mmio_sl_awsize;
  logic [1:0]   mmio_sl_awburst;
  logic         mmio_sl_awvalid;
  logic         mmio_sl_awready;
  logic [63:0]  mmio_sl_wdata;
  logic [7:0]   mmio_sl_wstrb;
  logic         mmio_sl_wlast;
  logic         mmio_sl_wvalid;
  logic         mmio_sl_wready;
  logic [3:0]   mmio_sl_bid;
  logic [1:0]   mmio_sl_bresp;
  logic         mmio_sl_bvalid;
  logic         mmio_sl_bready;
  logic [3:0]   mmio_sl_arid;
  logic [63:0]  mmio_sl_araddr;
  logic [7:0]   mmio_sl_arlen;
  logic [2:0]   mmio_sl_arsize;
  logic [1:0]   mmio_sl_arburst;
  logic         mmio_sl_arvalid;
  logic         mmio_sl_arready;
  logic [3:0]   mmio_sl_rid;
  logic [63:0]  mmio_sl_rdata;
  logic [1:0]   mmio_sl_rresp;
  logic         mmio_sl_rlast;
  logic         mmio_sl_rvalid;
  logic         mmio_sl_rready;

  // UART slave signals (from crossbar slave 3)
  logic [3:0]   uart_awid;
  logic [63:0]  uart_awaddr;
  logic [7:0]   uart_awlen;
  logic [2:0]   uart_awsize;
  logic [1:0]   uart_awburst;
  logic         uart_awvalid;
  logic         uart_awready;
  logic [63:0]  uart_wdata;
  logic [7:0]   uart_wstrb;
  logic         uart_wlast;
  logic         uart_wvalid;
  logic         uart_wready;
  logic [3:0]   uart_bid;
  logic [1:0]   uart_bresp;
  logic         uart_bvalid;
  logic         uart_bready;
  logic [3:0]   uart_arid;
  logic [63:0]  uart_araddr;
  logic [7:0]   uart_arlen;
  logic [2:0]   uart_arsize;
  logic [1:0]   uart_arburst;
  logic         uart_arvalid;
  logic         uart_arready;
  logic [3:0]   uart_rid;
  logic [63:0]  uart_rdata;
  logic [1:0]   uart_rresp;
  logic         uart_rlast;
  logic         uart_rvalid;
  logic         uart_rready;

  // APLIC interrupt controller signals (from MMIO bridge address-decode mux)
  logic [63:0]  aplic_awaddr;
  logic         aplic_awvalid, aplic_awready;
  logic [63:0]  aplic_wdata;
  logic [7:0]   aplic_wstrb;
  logic         aplic_wvalid, aplic_wready;
  logic [1:0]   aplic_bresp;
  logic         aplic_bvalid, aplic_bready;
  logic [63:0]  aplic_araddr;
  logic         aplic_arvalid, aplic_arready;
  logic [63:0]  aplic_rdata;
  logic [1:0]   aplic_rresp;
  logic         aplic_rvalid, aplic_rready;

  // IRQ source nets: UART level (to APLIC src3) and APLIC muxed output (to CPUs)
  logic uart_irq;
  logic aplic_irq;

  // =========================================================================
  // Instantiate crossbar
  // =========================================================================
  c930_axi_crossbar u_crossbar (
    .i_clk     (core_clk),
    .i_rst_n   (core_rst_n),

    // ---- M0: I-cache adapter ----
    .m0_awid    (icache_awid),    .m0_awaddr  (icache_awaddr),  .m0_awlen  (icache_awlen),
    .m0_awsize  (icache_awsize),  .m0_awburst (icache_awburst), .m0_awvalid(icache_awvalid),
    .m0_awready (icache_awready),
    .m0_wdata   (icache_wdata),   .m0_wstrb   (icache_wstrb),   .m0_wlast  (icache_wlast),
    .m0_wvalid  (icache_wvalid),  .m0_wready  (icache_wready),
    .m0_bid     (icache_bid),     .m0_bresp   (icache_bresp),   .m0_bvalid (icache_bvalid),
    .m0_bready  (icache_bready),
    .m0_arid    (icache_arid),    .m0_araddr  (icache_araddr),  .m0_arlen  (icache_arlen),
    .m0_arsize  (icache_arsize),  .m0_arburst (icache_arburst), .m0_arvalid(icache_arvalid),
    .m0_arready (icache_arready),
    .m0_rid     (icache_rid),     .m0_rdata   (icache_rdata),   .m0_rresp  (icache_rresp),
    .m0_rlast   (icache_rlast),   .m0_rvalid  (icache_rvalid),  .m0_rready (icache_rready),

    // ---- M1: D-cache adapter ----
    .m1_awid    (dcache_awid),    .m1_awaddr  (dcache_awaddr),  .m1_awlen  (dcache_awlen),
    .m1_awsize  (dcache_awsize),  .m1_awburst (dcache_awburst), .m1_awvalid(dcache_awvalid),
    .m1_awready (dcache_awready),
    .m1_wdata   (dcache_wdata),   .m1_wstrb   (dcache_wstrb),   .m1_wlast  (dcache_wlast),
    .m1_wvalid  (dcache_wvalid),  .m1_wready  (dcache_wready),
    .m1_bid     (dcache_bid),     .m1_bresp   (dcache_bresp),   .m1_bvalid (dcache_bvalid),
    .m1_bready  (dcache_bready),
    .m1_arid    (dcache_arid),    .m1_araddr  (dcache_araddr),  .m1_arlen  (dcache_arlen),
    .m1_arsize  (dcache_arsize),  .m1_arburst (dcache_arburst), .m1_arvalid(dcache_arvalid),
    .m1_arready (dcache_arready),
    .m1_rid     (dcache_rid),     .m1_rdata   (dcache_rdata),   .m1_rresp  (dcache_rresp),
    .m1_rlast   (dcache_rlast),   .m1_rvalid  (dcache_rvalid),  .m1_rready (dcache_rready),

    // ---- M2: DMA arbiter output (NPU0 + NPU1 shared) ----
    .m2_awid    (arb_awid),      .m2_awaddr  (arb_awaddr),     .m2_awlen  (arb_awlen),
    .m2_awsize  (arb_awsize),    .m2_awburst (arb_awburst),    .m2_awvalid(arb_awvalid),
    .m2_awready (arb_awready),
    .m2_wdata   (arb_wdata),     .m2_wstrb   (arb_wstrb),      .m2_wlast  (arb_wlast),
    .m2_wvalid  (arb_wvalid),    .m2_wready  (arb_wready),
    .m2_bid     (arb_bid),       .m2_bresp   (arb_bresp),      .m2_bvalid (arb_bvalid),
    .m2_bready  (arb_bready),
    .m2_arid    (arb_arid),      .m2_araddr  (arb_araddr),     .m2_arlen  (arb_arlen),
    .m2_arsize  (arb_arsize),    .m2_arburst (arb_arburst),    .m2_arvalid(arb_arvalid),
    .m2_arready (arb_arready),
    .m2_rid     (arb_rid),       .m2_rdata   (arb_rdata),      .m2_rresp  (arb_rresp),
    .m2_rlast   (arb_rlast),     .m2_rvalid  (arb_rvalid),     .m2_rready (arb_rready),

    // ---- M3: CPU1 bus arbiter output (I/D caches) ----
    .m3_awid    (arb1_awid),     .m3_awaddr  (arb1_awaddr),    .m3_awlen  (arb1_awlen),
    .m3_awsize  (arb1_awsize),   .m3_awburst (arb1_awburst),   .m3_awvalid(arb1_awvalid),
    .m3_awready (arb1_awready),
    .m3_wdata   (arb1_wdata),    .m3_wstrb   (arb1_wstrb),     .m3_wlast  (arb1_wlast),
    .m3_wvalid  (arb1_wvalid),   .m3_wready  (arb1_wready),
    .m3_bid     (arb1_bid),      .m3_bresp   (arb1_bresp),     .m3_bvalid (arb1_bvalid),
    .m3_bready  (arb1_bready),
    .m3_arid    (arb1_arid),     .m3_araddr  (arb1_araddr),    .m3_arlen  (arb1_arlen),
    .m3_arsize  (arb1_arsize),   .m3_arburst (arb1_arburst),   .m3_arvalid(arb1_arvalid),
    .m3_arready (arb1_arready),
    .m3_rid     (arb1_rid),      .m3_rdata   (arb1_rdata),     .m3_rresp  (arb1_rresp),
    .m3_rlast   (arb1_rlast),    .m3_rvalid  (arb1_rvalid),    .m3_rready (arb1_rready),

    // ---- S0: Boot ROM ----
    .s0_awid    (boot_awid),     .s0_awaddr  (boot_awaddr),    .s0_awlen  (boot_awlen),
    .s0_awsize  (boot_awsize),   .s0_awburst (boot_awburst),   .s0_awvalid(boot_awvalid),
    .s0_awready (boot_awready),
    .s0_wdata   (boot_wdata),    .s0_wstrb   (boot_wstrb),     .s0_wlast  (boot_wlast),
    .s0_wvalid  (boot_wvalid),   .s0_wready  (boot_wready),
    .s0_bid     (boot_bid),      .s0_bresp   (boot_bresp),     .s0_bvalid (boot_bvalid),
    .s0_bready  (boot_bready),
    .s0_arid    (boot_arid),     .s0_araddr  (boot_araddr),    .s0_arlen  (boot_arlen),
    .s0_arsize  (boot_arsize),   .s0_arburst (boot_arburst),   .s0_arvalid(boot_arvalid),
    .s0_arready (boot_arready),
    .s0_rid     (boot_rid),      .s0_rdata   (boot_rdata),     .s0_rresp  (boot_rresp),
    .s0_rlast   (boot_rlast),    .s0_rvalid  (boot_rvalid),    .s0_rready (boot_rready),

    // ---- S1: DDR ----
    .s1_awid    (l2_s_awid),    .s1_awaddr  (l2_s_awaddr),   .s1_awlen  (l2_s_awlen),
    .s1_awsize  (l2_s_awsize),  .s1_awburst (l2_s_awburst),  .s1_awvalid(l2_s_awvalid),
    .s1_awready (l2_s_awready),
    .s1_wdata   (l2_s_wdata),   .s1_wstrb   (l2_s_wstrb),    .s1_wlast  (l2_s_wlast),
    .s1_wvalid  (l2_s_wvalid),  .s1_wready  (l2_s_wready),
    .s1_bid     (l2_s_bid),     .s1_bresp   (l2_s_bresp),    .s1_bvalid (l2_s_bvalid),
    .s1_bready  (l2_s_bready),
    .s1_arid    (l2_s_arid),    .s1_araddr  (l2_s_araddr),   .s1_arlen  (l2_s_arlen),
    .s1_arsize  (l2_s_arsize),  .s1_arburst (l2_s_arburst),  .s1_arvalid(l2_s_arvalid),
    .s1_arready (l2_s_arready),
    .s1_rid     (l2_s_rid),     .s1_rdata   (l2_s_rdata),    .s1_rresp  (l2_s_rresp),
    .s1_rlast   (l2_s_rlast),   .s1_rvalid  (l2_s_rvalid),   .s1_rready (l2_s_rready),

    // ---- S2: MMIO (stub for future peripherals) ----
    .s2_awid    (mmio_sl_awid),  .s2_awaddr  (mmio_sl_awaddr), .s2_awlen  (mmio_sl_awlen),
    .s2_awsize  (mmio_sl_awsize),.s2_awburst (mmio_sl_awburst),.s2_awvalid(mmio_sl_awvalid),
    .s2_awready (mmio_sl_awready),
    .s2_wdata   (mmio_sl_wdata), .s2_wstrb   (mmio_sl_wstrb),  .s2_wlast  (mmio_sl_wlast),
    .s2_wvalid  (mmio_sl_wvalid),.s2_wready  (mmio_sl_wready),
    .s2_bid     (mmio_sl_bid),   .s2_bresp   (mmio_sl_bresp),  .s2_bvalid (mmio_sl_bvalid),
    .s2_bready  (mmio_sl_bready),
    .s2_arid    (mmio_sl_arid),  .s2_araddr  (mmio_sl_araddr), .s2_arlen  (mmio_sl_arlen),
    .s2_arsize  (mmio_sl_arsize),.s2_arburst (mmio_sl_arburst),.s2_arvalid(mmio_sl_arvalid),
    .s2_arready (mmio_sl_arready),
    .s2_rid     (mmio_sl_rid),   .s2_rdata   (mmio_sl_rdata),  .s2_rresp  (mmio_sl_rresp),
    .s2_rlast   (mmio_sl_rlast), .s2_rvalid  (mmio_sl_rvalid), .s2_rready (mmio_sl_rready),

    // ---- S3: UART (unused — UART is driven by MMIO bridge mux, not crossbar) ----
    .s3_awid    (),              .s3_awaddr  (),               .s3_awlen  (),
    .s3_awsize  (),              .s3_awburst (),               .s3_awvalid(),
    .s3_awready (1'b1),
    .s3_wdata   (),              .s3_wstrb   (),               .s3_wlast  (),
    .s3_wvalid  (),              .s3_wready  (1'b1),
    .s3_bid     (),              .s3_bresp   (2'b00),          .s3_bvalid (1'b0),
    .s3_bready  (),
    .s3_arid    (),              .s3_araddr  (),               .s3_arlen  (),
    .s3_arsize  (),              .s3_arburst (),               .s3_arvalid(),
    .s3_arready (1'b1),
    .s3_rid     (),              .s3_rdata   (64'd0),          .s3_rresp  (2'b00),
    .s3_rlast   (1'b1),          .s3_rvalid  (1'b0),           .s3_rready ()
  );

  // =========================================================================
  // S0: Boot ROM (1 KB, read-only)
  // =========================================================================
  c930_bootrom #(
    .MEM_DEPTH  (128),            // 1024 bytes / 8 = 128 entries
    .DATA_WIDTH (64),
    .ADDR_WIDTH (64),
    .ID_WIDTH   (4),
    .HEX_FILE   (BOOT_INIT_FILE)
  ) u_bootrom (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),

    .s_axi_awid      (boot_awid),     .s_axi_awaddr    (boot_awaddr),
    .s_axi_awlen     (boot_awlen),    .s_axi_awsize    (boot_awsize),
    .s_axi_awburst   (boot_awburst),  .s_axi_awvalid   (boot_awvalid),
    .s_axi_awready   (boot_awready),

    .s_axi_wdata     (boot_wdata),    .s_axi_wstrb     (boot_wstrb),
    .s_axi_wlast     (boot_wlast),    .s_axi_wvalid    (boot_wvalid),
    .s_axi_wready    (boot_wready),

    .s_axi_bid       (boot_bid),      .s_axi_bresp     (boot_bresp),
    .s_axi_bvalid    (boot_bvalid),   .s_axi_bready    (boot_bready),

    .s_axi_arid      (boot_arid),     .s_axi_araddr    (boot_araddr),
    .s_axi_arlen     (boot_arlen),    .s_axi_arsize    (boot_arsize),
    .s_axi_arburst   (boot_arburst),  .s_axi_arvalid   (boot_arvalid),
    .s_axi_arready   (boot_arready),

    .s_axi_rid       (boot_rid),      .s_axi_rdata     (boot_rdata),
    .s_axi_rresp     (boot_rresp),    .s_axi_rlast     (boot_rlast),
    .s_axi_rvalid    (boot_rvalid),   .s_axi_rready    (boot_rready)
  );

  // =========================================================================
  // S1: Unified DDR (AXI4 full slave, 64 KB)
  //
  // =========================================================================
  // Shared L2 (64 KB, 4-way) + coherence directory, inserted between the
  // crossbar's DDR slave port (S1) and the DDR.  Point of coherence for the
  // four cores' write-through L1s (MSI-lite: no dirty states).  See
  // c930_l2.sv for the protocol and the SOURCE_ID map.
  // =========================================================================
  generate
    if (BYPASS_L2) begin : g_l2_bypass
      // Debug: crossbar S1 -> DDR directly (no L2, no coherence).
      assign ddr_awid = l2_s_awid;    assign ddr_awaddr = l2_s_awaddr; assign ddr_awlen = l2_s_awlen;
      assign ddr_awsize = l2_s_awsize;assign ddr_awburst = l2_s_awburst;assign ddr_awvalid = l2_s_awvalid;
      assign l2_s_awready = ddr_awready;
      assign ddr_wdata = l2_s_wdata;  assign ddr_wstrb = l2_s_wstrb;   assign ddr_wlast = l2_s_wlast;
      assign ddr_wvalid = l2_s_wvalid;assign l2_s_wready = ddr_wready;
      assign l2_s_bid = ddr_bid;      assign l2_s_bresp = ddr_bresp;   assign l2_s_bvalid = ddr_bvalid;
      assign ddr_bready = l2_s_bready;
      assign ddr_arid = l2_s_arid;    assign ddr_araddr = l2_s_araddr; assign ddr_arlen = l2_s_arlen;
      assign ddr_arsize = l2_s_arsize;assign ddr_arburst = l2_s_arburst;assign ddr_arvalid = l2_s_arvalid;
      assign l2_s_arready = ddr_arready;
      assign l2_s_rid = ddr_rid;      assign l2_s_rdata = ddr_rdata;   assign l2_s_rresp = ddr_rresp;
      assign l2_s_rlast = ddr_rlast;  assign l2_s_rvalid = ddr_rvalid; assign ddr_rready = l2_s_rready;
      assign l2_inv_valid = 8'b0;
    end else begin : g_l2
  c930_l2 #(
    .ADDR_WIDTH (64),
    .DATA_WIDTH (64),
    .ID_WIDTH   (4),
    .LINE_BYTES (32),
    .NUM_SETS   (L2_NUM_SETS),
    .NUM_WAYS   (L2_NUM_WAYS),
    .NUM_SRC    (16),
    .INV_PORTS  (8)
  ) u_l2 (
    .i_clk       (core_clk),
    .i_rst_n     (core_rst_n),

    // slave: crossbar S1 (all DDR traffic)
    .s_awid      (l2_s_awid),    .s_awaddr  (l2_s_awaddr),   .s_awlen  (l2_s_awlen),
    .s_awsize    (l2_s_awsize),  .s_awburst (l2_s_awburst),  .s_awvalid(l2_s_awvalid),
    .s_awready   (l2_s_awready),
    .s_wdata     (l2_s_wdata),   .s_wstrb   (l2_s_wstrb),    .s_wlast  (l2_s_wlast),
    .s_wvalid    (l2_s_wvalid),  .s_wready  (l2_s_wready),
    .s_bid       (l2_s_bid),     .s_bresp   (l2_s_bresp),    .s_bvalid (l2_s_bvalid),
    .s_bready    (l2_s_bready),
    .s_arid      (l2_s_arid),    .s_araddr  (l2_s_araddr),   .s_arlen  (l2_s_arlen),
    .s_arsize    (l2_s_arsize),  .s_arburst (l2_s_arburst),  .s_arvalid(l2_s_arvalid),
    .s_arready   (l2_s_arready),
    .s_rid       (l2_s_rid),     .s_rdata   (l2_s_rdata),    .s_rresp  (l2_s_rresp),
    .s_rlast     (l2_s_rlast),   .s_rvalid  (l2_s_rvalid),   .s_rready (l2_s_rready),

    // master: DDR
    .m_awid      (ddr_awid),     .m_awaddr  (ddr_awaddr),    .m_awlen  (ddr_awlen),
    .m_awsize    (ddr_awsize),   .m_awburst (ddr_awburst),   .m_awvalid(ddr_awvalid),
    .m_awready   (ddr_awready),
    .m_wdata     (ddr_wdata),    .m_wstrb   (ddr_wstrb),     .m_wlast  (ddr_wlast),
    .m_wvalid    (ddr_wvalid),   .m_wready  (ddr_wready),
    .m_bid       (ddr_bid),      .m_bresp   (ddr_bresp),     .m_bvalid (ddr_bvalid),
    .m_bready    (ddr_bready),
    .m_arid      (ddr_arid),     .m_araddr  (ddr_araddr),    .m_arlen  (ddr_arlen),
    .m_arsize    (ddr_arsize),   .m_arburst (ddr_arburst),   .m_arvalid(ddr_arvalid),
    .m_arready   (ddr_arready),
    .m_rid       (ddr_rid),      .m_rdata   (ddr_rdata),     .m_rresp  (ddr_rresp),
    .m_rlast     (ddr_rlast),    .m_rvalid  (ddr_rvalid),    .m_rready (ddr_rready),

    // L1 invalidation ports
    .o_inv_valid (l2_inv_valid),
    .o_inv_addr  (l2_inv_addr),
    .i_inv_ack   (l2_inv_ack)
  );
    end
  endgenerate

  // NOTE: The existing c930_ddr module uses a mixed interface (cache-line
  // ports + AXI4 slave). For the crossbar integration, we connect it via
  // the AXI4 slave port only. The cache-line ports are unused (the cache
  // adapters now route through the crossbar).
  // =========================================================================
  c930_ddr #(
    .MEM_BYTES         (MEM_BYTES),
    .ADDR_WIDTH        (64),
    .CACHE_LINE_WIDTH  (256),
    .INIT_FILE         (DDR_INIT_FILE)
  ) u_ddr (
    .i_clk             (core_clk),
    .i_rst_n           (core_rst_n),

    // CPU cache ports: UNUSED (routed through crossbar via cache adapters)
    .i_icache_rd_addr  ('0),
    .i_icache_rd_req   (1'b0),
    .o_icache_rd_done  (),
    .o_icache_rd_line  (),

    .i_dcache_rd_addr  ('0),
    .i_dcache_rd_req   (1'b0),
    .o_dcache_rd_done  (),
    .o_dcache_rd_line  (),

    .i_dcache_wr_addr  ('0),
    .i_dcache_wr_data  ('0),
    .i_dcache_wr_strobe('0),
    .i_dcache_wr_valid (1'b0),
    .o_dcache_wr_done  (),

    // Testbench preload/readback ports (active when driven by testbench)
    .i_tb_wr_en   (i_tb_wr_en),
    .i_tb_wr_addr  (i_tb_wr_addr),
    .i_tb_wr_data  (i_tb_wr_data),
    .i_tb_rd_addr (i_tb_rd_addr),
    .o_tb_rd_data (o_tb_rd_data),

    // AXI4 slave (from crossbar S1)
    .s_axi_araddr      (ddr_araddr),
    .s_axi_arlen       (ddr_arlen),
    .s_axi_arvalid     (ddr_arvalid),
    .s_axi_arready     (ddr_arready),
    .s_axi_rdata       (ddr_rdata),
    .s_axi_rresp       (ddr_rresp),
    .s_axi_rlast       (ddr_rlast),
    .s_axi_rvalid      (ddr_rvalid),
    .s_axi_rready      (ddr_rready),
    .s_axi_awaddr      (ddr_awaddr),
    .s_axi_awlen       (ddr_awlen),
    .s_axi_awvalid     (ddr_awvalid),
    .s_axi_awready     (ddr_awready),
    .s_axi_wdata       (ddr_wdata),
    .s_axi_wstrb       (ddr_wstrb),
    .s_axi_wlast       (ddr_wlast),
    .s_axi_wvalid      (ddr_wvalid),
    .s_axi_wready      (ddr_wready),
    .s_axi_bresp       (ddr_bresp),
    .s_axi_bvalid      (ddr_bvalid),
    .s_axi_bready      (ddr_bready)
  );

  // =========================================================================
  // S2: MMIO stub (for future peripherals like timer, GPIO, APLIC)
  // Returns SLVERR for all transactions (no real peripheral yet)
  // =========================================================================
  // Tie off unused MMIO slave ports (crossbar returns SLVERR for unmapped)
  assign mmio_sl_awready = 1'b1;
  assign mmio_sl_wready  = 1'b1;
  assign mmio_sl_bid     = '0;
  assign mmio_sl_bresp   = 2'b11;  // SLVERR
  assign mmio_sl_bvalid  = 1'b0;
  assign mmio_sl_arready = 1'b1;
  assign mmio_sl_rid     = '0;
  assign mmio_sl_rdata   = '0;
  assign mmio_sl_rresp   = 2'b11;
  assign mmio_sl_rlast   = 1'b1;
  assign mmio_sl_rvalid  = 1'b0;

  // =========================================================================
  // S3: UART (16550-compatible, AXI4-Lite slave)
  // =========================================================================
  c930_uart #(
    .CLK_FREQ   (100_000_000),   // default; overridden by CLK_DIV in synth
    .BAUD_RATE  (115200),
    .FIFO_DEPTH (64)
  ) u_uart (
    .i_clk       (core_clk),
    .i_rst_n     (core_rst_n),

    .o_uart_txd  (o_uart_txd),
    .i_uart_rxd  (i_uart_rxd),
    .o_irq       (uart_irq),   // -> APLIC source 3

    // AXI4-Lite slave (from MMIO bridge address-decode mux)
    .s_axi_awaddr (uart_awaddr[31:0]),
    .s_axi_awvalid(uart_awvalid),
    .s_axi_awready(uart_awready),
    .s_axi_wdata  (uart_wdata[31:0]),
    .s_axi_wstrb  (uart_wstrb[3:0]),
    .s_axi_wvalid (uart_wvalid),
    .s_axi_wready (uart_wready),
    .s_axi_bresp  (uart_bresp),
    .s_axi_bvalid (uart_bvalid),
    .s_axi_bready (uart_bready),
    .s_axi_araddr (uart_araddr[31:0]),
    .s_axi_arvalid(uart_arvalid),
    .s_axi_arready(uart_arready),
    .s_axi_rdata  (uart_rdata[31:0]),
    .s_axi_rresp  (uart_rresp),
    .s_axi_rvalid (uart_rvalid),
    .s_axi_rready (uart_rready)
  );

  // Tie off unused AXI4 fields from UART (AXI4-Lite doesn't use them)
  assign uart_bid    = '0;
  assign uart_rid    = '0;
  assign uart_rlast  = 1'b1;  // single-beat, always last

  // =========================================================================
  // APLIC: 3-source interrupt controller (0x4000_4000, from MMIO bridge mux)
  //   src1 = NPU0 done (edge)   src2 = NPU1 done (edge)   src3 = UART (level)
  //   o_irq feeds BOTH CPUs' machine-external-interrupt inputs.
  // =========================================================================
  c930_aplic u_aplic (
    .i_clk       (core_clk),
    .i_rst_n     (core_rst_n),

    .i_irq_npu0  (o_npu_irq),
    .i_irq_npu1  (o_npu1_irq),
    .i_irq_uart  (uart_irq),
    .o_irq       (aplic_irq),

    // AXI4-Lite slave (from MMIO bridge address-decode mux)
    .s_axi_awaddr (aplic_awaddr[31:0]),
    .s_axi_awvalid(aplic_awvalid),
    .s_axi_awready(aplic_awready),
    .s_axi_wdata  (aplic_wdata[31:0]),
    .s_axi_wstrb  (aplic_wstrb[3:0]),
    .s_axi_wvalid (aplic_wvalid),
    .s_axi_wready (aplic_wready),
    .s_axi_bresp  (aplic_bresp),
    .s_axi_bvalid (aplic_bvalid),
    .s_axi_bready (aplic_bready),
    .s_axi_araddr (aplic_araddr[31:0]),
    .s_axi_arvalid(aplic_arvalid),
    .s_axi_arready(aplic_arready),
    .s_axi_rdata  (aplic_rdata[31:0]),
    .s_axi_rresp  (aplic_rresp),
    .s_axi_rvalid (aplic_rvalid),
    .s_axi_rready (aplic_rready)
  );

  // Tie off unused AXI4 fields from APLIC
  assign aplic_bid    = '0;
  assign aplic_rid    = '0;



  // =========================================================================
  // CPU
  // =========================================================================
  riscv_core_top u_cpu (
    .i_riscv_core_clk                  (core_clk),
    .i_riscv_core_rst_n                (core_rst_n),
    .i_riscv_core_external_interrupt_m (aplic_irq),
    .i_riscv_core_external_interrupt_s (1'b0),
    .o_riscv_core_ack                  (),

    // data cache → D-cache adapter
    .mem_read_address              (dcache_rd_addr),
    .o_mem_write_data              (dcache_wr_data),
    .o_mem_write_address           (dcache_wr_addr),
    .mem_read_req                  (dcache_rd_req),
    .o_mem_write_valid             (dcache_wr_valid),
    .mem_read_done                 (dcache_rd_done),
    .i_mem_write_done              (dcache_wr_done),
    .i_block_from_axi_data_cache   (dcache_rd_line),
    .o_mem_write_strobe            (dcache_wr_strobe),

    // instruction cache → I-cache adapter
    .o_addr_from_control_to_axi    (icache_rd_addr),
    .o_mem_req                     (icache_rd_req),
    .i_mem_done                    (icache_rd_done),
    .i_block_from_axi_i_cache      (icache_rd_line),

    // MMIO (uncached) → MMIO bridge → NPU CSR
    .o_mmio_read_address           (mmio_rd_addr),
    .o_mmio_read_req               (mmio_rd_req),
    .i_mmio_read_done              (mmio_rd_done),
    .i_mmio_read_data              (mmio_rd_data),
    .o_mmio_write_address          (mmio_wr_addr),
    .o_mmio_write_data             (mmio_wr_data),
    .o_mmio_write_strobe           (mmio_wr_strobe),
    .o_mmio_write_valid            (mmio_wr_valid),
    .i_mmio_write_done             (mmio_wr_done),

    // coherence invalidation (from shared L2): ports 0 (I) and 1 (D)
    .i_icache_inv_valid            (l2_inv_valid[0]),
    .i_icache_inv_addr             (l2_inv_addr),
    .o_icache_inv_ack              (l2_inv_ack[0]),
    .i_dcache_inv_valid            (l2_inv_valid[1]),
    .i_dcache_inv_addr             (l2_inv_addr),
    .o_dcache_inv_ack              (l2_inv_ack[1])
  );

  // =========================================================================
  // CPU1 (second core; boots at boot ROM 0x10020 = idle loop in boot.hex,
  // so it never touches DDR/MMIO until dual-core firmware is loaded)
  // =========================================================================
  riscv_core_top #(
    .CORE_RESET_PC (64'h0001_0020)
  ) u_cpu1 (
    .i_riscv_core_clk                  (core_clk),
    .i_riscv_core_rst_n                (core_rst_n),
    .i_riscv_core_external_interrupt_m (aplic_irq),
    .i_riscv_core_external_interrupt_s (1'b0),
    .o_riscv_core_ack                  (),

    // data cache → D-cache adapter
    .mem_read_address              (dcache1_rd_addr),
    .o_mem_write_data              (dcache1_wr_data),
    .o_mem_write_address           (dcache1_wr_addr),
    .mem_read_req                  (dcache1_rd_req),
    .o_mem_write_valid             (dcache1_wr_valid),
    .mem_read_done                 (dcache1_rd_done),
    .i_mem_write_done              (dcache1_wr_done),
    .i_block_from_axi_data_cache   (dcache1_rd_line),
    .o_mem_write_strobe            (dcache1_wr_strobe),

    // instruction cache → I-cache adapter
    .o_addr_from_control_to_axi    (icache1_rd_addr),
    .o_mem_req                     (icache1_rd_req),
    .i_mem_done                    (icache1_rd_done),
    .i_block_from_axi_i_cache      (icache1_rd_line),

    // MMIO (uncached) → MMIO arbiter → bridge
    .o_mmio_read_address           (mmio1_rd_addr),
    .o_mmio_read_req               (mmio1_rd_req),
    .i_mmio_read_done              (mmio1_rd_done),
    .i_mmio_read_data              (mmio1_rd_data),
    .o_mmio_write_address          (mmio1_wr_addr),
    .o_mmio_write_data             (mmio1_wr_data),
    .o_mmio_write_strobe           (mmio1_wr_strobe),
    .o_mmio_write_valid            (mmio1_wr_valid),
    .i_mmio_write_done             (mmio1_wr_done),

    // coherence invalidation (from shared L2): ports 2 (I) and 3 (D)
    .i_icache_inv_valid            (l2_inv_valid[2]),
    .i_icache_inv_addr             (l2_inv_addr),
    .o_icache_inv_ack              (l2_inv_ack[2]),
    .i_dcache_inv_valid            (l2_inv_valid[3]),
    .i_dcache_inv_addr             (l2_inv_addr),
    .o_dcache_inv_ack              (l2_inv_ack[3])
  );

  // =========================================================================
  // CPU2 (third core; boots at boot ROM 0x10060 = parking loop polling
  // CORE2_RELEASE @ 0x4000_0FF8, so it never touches DDR/MMIO until the
  // 4-core firmware releases it)
  // =========================================================================
  riscv_core_top #(
    .CORE_RESET_PC (64'h0001_0060)
  ) u_cpu2 (
    .i_riscv_core_clk                  (core_clk),
    .i_riscv_core_rst_n                (core_rst_n),
    .i_riscv_core_external_interrupt_m (aplic_irq),
    .i_riscv_core_external_interrupt_s (1'b0),
    .o_riscv_core_ack                  (),

    // data cache → D-cache adapter
    .mem_read_address              (dcache2_rd_addr),
    .o_mem_write_data              (dcache2_wr_data),
    .o_mem_write_address           (dcache2_wr_addr),
    .mem_read_req                  (dcache2_rd_req),
    .o_mem_write_valid             (dcache2_wr_valid),
    .mem_read_done                 (dcache2_rd_done),
    .i_mem_write_done              (dcache2_wr_done),
    .i_block_from_axi_data_cache   (dcache2_rd_line),
    .o_mem_write_strobe            (dcache2_wr_strobe),

    // instruction cache → I-cache adapter
    .o_addr_from_control_to_axi    (icache2_rd_addr),
    .o_mem_req                     (icache2_rd_req),
    .i_mem_done                    (icache2_rd_done),
    .i_block_from_axi_i_cache      (icache2_rd_line),

    // MMIO (uncached) → MMIO arbiter → bridge
    .o_mmio_read_address           (mmio2_rd_addr),
    .o_mmio_read_req               (mmio2_rd_req),
    .i_mmio_read_done              (mmio2_rd_done),
    .i_mmio_read_data              (mmio2_rd_data),
    .o_mmio_write_address          (mmio2_wr_addr),
    .o_mmio_write_data             (mmio2_wr_data),
    .o_mmio_write_strobe           (mmio2_wr_strobe),
    .o_mmio_write_valid            (mmio2_wr_valid),
    .i_mmio_write_done             (mmio2_wr_done),

    // coherence invalidation (from shared L2): ports 4 (I) and 5 (D)
    .i_icache_inv_valid            (l2_inv_valid[4]),
    .i_icache_inv_addr             (l2_inv_addr),
    .o_icache_inv_ack              (l2_inv_ack[4]),
    .i_dcache_inv_valid            (l2_inv_valid[5]),
    .i_dcache_inv_addr             (l2_inv_addr),
    .o_dcache_inv_ack              (l2_inv_ack[5])
  );

  // =========================================================================
  // CPU3 (fourth core; boots at boot ROM 0x100A0 = parking loop polling
  // CORE3_RELEASE @ 0x4000_0FFC)
  // =========================================================================
  riscv_core_top #(
    .CORE_RESET_PC (64'h0001_00A0)
  ) u_cpu3 (
    .i_riscv_core_clk                  (core_clk),
    .i_riscv_core_rst_n                (core_rst_n),
    .i_riscv_core_external_interrupt_m (aplic_irq),
    .i_riscv_core_external_interrupt_s (1'b0),
    .o_riscv_core_ack                  (),

    // data cache → D-cache adapter
    .mem_read_address              (dcache3_rd_addr),
    .o_mem_write_data              (dcache3_wr_data),
    .o_mem_write_address           (dcache3_wr_addr),
    .mem_read_req                  (dcache3_rd_req),
    .o_mem_write_valid             (dcache3_wr_valid),
    .mem_read_done                 (dcache3_rd_done),
    .i_mem_write_done              (dcache3_wr_done),
    .i_block_from_axi_data_cache   (dcache3_rd_line),
    .o_mem_write_strobe            (dcache3_wr_strobe),

    // instruction cache → I-cache adapter
    .o_addr_from_control_to_axi    (icache3_rd_addr),
    .o_mem_req                     (icache3_rd_req),
    .i_mem_done                    (icache3_rd_done),
    .i_block_from_axi_i_cache      (icache3_rd_line),

    // MMIO (uncached) → MMIO arbiter → bridge
    .o_mmio_read_address           (mmio3_rd_addr),
    .o_mmio_read_req               (mmio3_rd_req),
    .i_mmio_read_done              (mmio3_rd_done),
    .i_mmio_read_data              (mmio3_rd_data),
    .o_mmio_write_address          (mmio3_wr_addr),
    .o_mmio_write_data             (mmio3_wr_data),
    .o_mmio_write_strobe           (mmio3_wr_strobe),
    .o_mmio_write_valid            (mmio3_wr_valid),
    .i_mmio_write_done             (mmio3_wr_done),

    // coherence invalidation (from shared L2): ports 6 (I) and 7 (D)
    .i_icache_inv_valid            (l2_inv_valid[6]),
    .i_icache_inv_addr             (l2_inv_addr),
    .o_icache_inv_ack              (l2_inv_ack[6]),
    .i_dcache_inv_valid            (l2_inv_valid[7]),
    .i_dcache_inv_addr             (l2_inv_addr),
    .o_dcache_inv_ack              (l2_inv_ack[7])
  );

  // =========================================================================
  // NPU
  // =========================================================================
  c930_npu_top #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (16),
    .ACC_W    (48),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N)
  ) u_npu (
    .i_clk         (core_clk),
    .i_rst_n       (core_rst_n),

    // AXI4-Lite CSR slave (from MMIO bridge, backward compat)
    .s_axi_awaddr  (csr_awaddr),
    .s_axi_awvalid (csr_awvalid),
    .s_axi_awready (csr_awready),
    .s_axi_wdata   (csr_wdata),
    .s_axi_wstrb   (csr_wstrb),
    .s_axi_wvalid  (csr_wvalid),
    .s_axi_wready  (csr_wready),
    .s_axi_bresp   (csr_bresp),
    .s_axi_bvalid  (csr_bvalid),
    .s_axi_bready  (csr_bready),
    .s_axi_araddr  (csr_araddr),
    .s_axi_arvalid (csr_arvalid),
    .s_axi_arready (csr_arready),
    .s_axi_rdata   (csr_rdata),
    .s_axi_rresp   (csr_rresp),
    .s_axi_rvalid  (csr_rvalid),
    .s_axi_rready  (csr_rready),

    // AXI4 full master → crossbar M2
    .m_axi_araddr  (npu_araddr),
    .m_axi_arlen   (npu_arlen),
    .m_axi_arsize  (npu_arsize),
    .m_axi_arburst (npu_arburst),
    .m_axi_arvalid (npu_arvalid),
    .m_axi_arready (npu_arready),
    .m_axi_rdata   (npu_rdata),
    .m_axi_rresp   (npu_rresp),
    .m_axi_rlast   (npu_rlast),
    .m_axi_rvalid  (npu_rvalid),
    .m_axi_rready  (npu_rready),
    .m_axi_awaddr  (npu_awaddr),
    .m_axi_awlen   (npu_awlen),
    .m_axi_awsize  (npu_awsize),
    .m_axi_awburst (npu_awburst),
    .m_axi_awvalid (npu_awvalid),
    .m_axi_awready (npu_awready),
    .m_axi_wdata   (npu_wdata),
    .m_axi_wstrb   (npu_wstrb),
    .m_axi_wlast   (npu_wlast),
    .m_axi_wvalid  (npu_wvalid),
    .m_axi_wready  (npu_wready),
    .m_axi_bresp   (npu_bresp),
    .m_axi_bvalid  (npu_bvalid),
    .m_axi_bready  (npu_bready),

    .o_busy        (o_npu_busy),
    .o_done        (o_npu_done),
    .o_error       (o_npu_error),
    .o_irq         (o_npu_irq)
  );

  // NPU0 doesn't use AXI ID signals — the arbiter drives npu_bid/npu_rid
  // as outputs; they're dead-end signals since the NPU has no bid/rid ports.

  // =========================================================================
  // DMA arbiter: merges NPU0 and NPU1 DMA into shared crossbar M2 port
  // =========================================================================
  c930_axi_dma_arb #(
    .ADDR_WIDTH (64),
    .DATA_WIDTH (64),
    .ID_WIDTH   (4),
    .ARB_ID_BASE (2'b10)
  ) u_dma_arb (
    .i_clk     (core_clk),
    .i_rst_n   (core_rst_n),

    // NPU0 DMA (master 0)
    .m0_awid    (npu_awid),    .m0_awaddr  (npu_awaddr),  .m0_awlen  (npu_awlen),
    .m0_awsize  (npu_awsize),  .m0_awburst (npu_awburst), .m0_awvalid(npu_awvalid),
    .m0_awready (npu_awready),
    .m0_wdata   (npu_wdata),   .m0_wstrb   (npu_wstrb),   .m0_wlast  (npu_wlast),
    .m0_wvalid  (npu_wvalid),  .m0_wready  (npu_wready),
    .m0_bid     (npu_bid),     .m0_bresp   (npu_bresp),   .m0_bvalid (npu_bvalid),
    .m0_bready  (npu_bready),
    .m0_arid    (npu_arid),    .m0_araddr  (npu_araddr),  .m0_arlen  (npu_arlen),
    .m0_arsize  (npu_arsize),  .m0_arburst (npu_arburst), .m0_arvalid(npu_arvalid),
    .m0_arready (npu_arready),
    .m0_rid     (npu_rid),     .m0_rdata   (npu_rdata),   .m0_rresp  (npu_rresp),
    .m0_rlast   (npu_rlast),   .m0_rvalid  (npu_rvalid),  .m0_rready (npu_rready),

    // NPU1 DMA (master 1)
    .m1_awid    (npu1_awid),   .m1_awaddr  (npu1_awaddr), .m1_awlen  (npu1_awlen),
    .m1_awsize  (npu1_awsize), .m1_awburst (npu1_awburst),.m1_awvalid(npu1_awvalid),
    .m1_awready (npu1_awready),
    .m1_wdata   (npu1_wdata),  .m1_wstrb   (npu1_wstrb),  .m1_wlast  (npu1_wlast),
    .m1_wvalid  (npu1_wvalid), .m1_wready  (npu1_wready),
    .m1_bid     (npu1_bid),    .m1_bresp   (npu1_bresp),  .m1_bvalid (npu1_bvalid),
    .m1_bready  (npu1_bready),
    .m1_arid    (npu1_arid),   .m1_araddr  (npu1_araddr), .m1_arlen  (npu1_arlen),
    .m1_arsize  (npu1_arsize), .m1_arburst (npu1_arburst),.m1_arvalid(npu1_arvalid),
    .m1_arready (npu1_arready),    .m1_rid     (npu1_rid),    .m1_rdata   (npu1_rdata),   .m1_rresp  (npu1_rresp),
    .m1_rlast   (npu1_rlast),  .m1_rvalid  (npu1_rvalid),  .m1_rready (npu1_rready),

    // CPU3 I-cache (master 2)
    .m2_awid    (icache3_awid),  .m2_awaddr  (icache3_awaddr), .m2_awlen  (icache3_awlen),
    .m2_awsize  (icache3_awsize),.m2_awburst (icache3_awburst),.m2_awvalid(icache3_awvalid),
    .m2_awready (icache3_awready),
    .m2_wdata   (icache3_wdata), .m2_wstrb   (icache3_wstrb),  .m2_wlast  (icache3_wlast),
    .m2_wvalid  (icache3_wvalid),.m2_wready  (icache3_wready),
    .m2_bid     (icache3_bid),   .m2_bresp   (icache3_bresp),  .m2_bvalid (icache3_bvalid),
    .m2_bready  (icache3_bready),
    .m2_arid    (icache3_arid),  .m2_araddr  (icache3_araddr), .m2_arlen  (icache3_arlen),
    .m2_arsize  (icache3_arsize),.m2_arburst (icache3_arburst),.m2_arvalid(icache3_arvalid),
    .m2_arready (icache3_arready),
    .m2_rid     (icache3_rid),   .m2_rdata   (icache3_rdata),  .m2_rresp  (icache3_rresp),
    .m2_rlast   (icache3_rlast), .m2_rvalid  (icache3_rvalid), .m2_rready (icache3_rready),

    // CPU3 D-cache (master 3)
    .m3_awid    (dcache3_awid),  .m3_awaddr  (dcache3_awaddr), .m3_awlen  (dcache3_awlen),
    .m3_awsize  (dcache3_awsize),.m3_awburst (dcache3_awburst),.m3_awvalid(dcache3_awvalid),
    .m3_awready (dcache3_awready),
    .m3_wdata   (dcache3_wdata), .m3_wstrb   (dcache3_wstrb),  .m3_wlast  (dcache3_wlast),
    .m3_wvalid  (dcache3_wvalid),.m3_wready  (dcache3_wready),
    .m3_bid     (dcache3_bid),   .m3_bresp   (dcache3_bresp),  .m3_bvalid (dcache3_bvalid),
    .m3_bready  (dcache3_bready),
    .m3_arid    (dcache3_arid),  .m3_araddr  (dcache3_araddr), .m3_arlen  (dcache3_arlen),
    .m3_arsize  (dcache3_arsize),.m3_arburst (dcache3_arburst),.m3_arvalid(dcache3_arvalid),
    .m3_arready (dcache3_arready),
    .m3_rid     (dcache3_rid),   .m3_rdata   (dcache3_rdata),  .m3_rresp  (dcache3_rresp),
    .m3_rlast   (dcache3_rlast), .m3_rvalid  (dcache3_rvalid), .m3_rready (dcache3_rready),

    // Shared slave (to crossbar M2)
    .s_awid     (arb_awid),    .s_awaddr   (arb_awaddr),  .s_awlen   (arb_awlen),
    .s_awsize   (arb_awsize),  .s_awburst  (arb_awburst), .s_awvalid (arb_awvalid),
    .s_awready  (arb_awready),
    .s_wdata    (arb_wdata),    .s_wstrb    (arb_wstrb),    .s_wlast   (arb_wlast),
    .s_wvalid   (arb_wvalid),  .s_wready   (arb_wready),
    .s_bid      (arb_bid),     .s_bresp    (arb_bresp),    .s_bvalid  (arb_bvalid),
    .s_bready   (arb_bready),
    .s_arid     (arb_arid),    .s_araddr   (arb_araddr),  .s_arlen   (arb_arlen),
    .s_arsize   (arb_arsize),  .s_arburst  (arb_arburst), .s_arvalid (arb_arvalid),
    .s_arready  (arb_arready),
    .s_rid      (arb_rid),     .s_rdata    (arb_rdata),    .s_rresp   (arb_rresp),
    .s_rlast    (arb_rlast),   .s_rvalid   (arb_rvalid),  .s_rready  (arb_rready)
  );

  // =========================================================================
  // NPU1 (second GEMM tile, same config as NPU0)
  // CSR at 0x4000_0040-0x4000_007F (address decode in MMIO mux below)
  // =========================================================================
  c930_npu_top #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (16),
    .ACC_W    (48),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N)
  ) u_npu1 (
    .i_clk         (core_clk),
    .i_rst_n       (core_rst_n),

    // AXI4-Lite CSR slave (from MMIO bridge mux)
    .s_axi_awaddr  (csr1_awaddr),
    .s_axi_awvalid (csr1_awvalid),
    .s_axi_awready (csr1_awready),
    .s_axi_wdata   (csr1_wdata),
    .s_axi_wstrb   (csr1_wstrb),
    .s_axi_wvalid  (csr1_wvalid),
    .s_axi_wready  (csr1_wready),
    .s_axi_bresp   (csr1_bresp),
    .s_axi_bvalid  (csr1_bvalid),
    .s_axi_bready  (csr1_bready),
    .s_axi_araddr  (csr1_araddr),
    .s_axi_arvalid (csr1_arvalid),
    .s_axi_arready (csr1_arready),
    .s_axi_rdata   (csr1_rdata),
    .s_axi_rresp   (csr1_rresp),
    .s_axi_rvalid  (csr1_rvalid),
    .s_axi_rready  (csr1_rready),

    // AXI4 full master -> DMA arbiter
    .m_axi_araddr  (npu1_araddr),
    .m_axi_arlen   (npu1_arlen),
    .m_axi_arsize  (npu1_arsize),
    .m_axi_arburst (npu1_arburst),
    .m_axi_arvalid (npu1_arvalid),
    .m_axi_arready (npu1_arready),
    .m_axi_rdata   (npu1_rdata),
    .m_axi_rresp   (npu1_rresp),
    .m_axi_rlast   (npu1_rlast),
    .m_axi_rvalid  (npu1_rvalid),
    .m_axi_rready  (npu1_rready),
    .m_axi_awaddr  (npu1_awaddr),
    .m_axi_awlen   (npu1_awlen),
    .m_axi_awsize  (npu1_awsize),
    .m_axi_awburst (npu1_awburst),
    .m_axi_awvalid (npu1_awvalid),
    .m_axi_awready (npu1_awready),
    .m_axi_wdata   (npu1_wdata),
    .m_axi_wstrb   (npu1_wstrb),
    .m_axi_wlast   (npu1_wlast),    .m_axi_wvalid  (npu1_wvalid), .m_axi_wready  (npu1_wready),
    .m_axi_bresp   (npu1_bresp),
    .m_axi_bvalid  (npu1_bvalid),
    .m_axi_bready  (npu1_bready),

    .o_busy        (o_npu1_busy),
    .o_done        (o_npu1_done),
    .o_error       (o_npu1_error),
    .o_irq         (o_npu1_irq)
  );

  // NPU1 doesn't use AXI ID signals — the arbiter drives npu1_bid/npu1_rid
  // as outputs; they're dead-end signals since the NPU has no bid/rid ports.

  // =========================================================================
  // CPU MMIO bridge (CPU uncached MMIO → AXI4-Lite peripherals)
  //
  // The bridge converts the CPU's simple req/done MMIO protocol to AXI4-Lite.
  // An address-decode mux downstream routes:
  //   0x4000_0000-0x4000_003F  → NPU0 CSR (backward compat)
  //   0x4000_0040-0x4000_007F  → NPU1 CSR
  //   0x4000_1000-0x4000_100F  → UART TX/RX/status
  // =========================================================================
  logic [31:0]  mmio_awaddr_raw;
  logic         mmio_awvalid_raw;
  logic         mmio_awready_raw;
  logic [31:0]  mmio_wdata_raw;
  logic [3:0]   mmio_wstrb_raw;
  logic         mmio_wvalid_raw;
  logic         mmio_wready_raw;
  logic [1:0]   mmio_bresp_raw;
  logic         mmio_bvalid_raw;
  logic         mmio_bready_raw;
  logic [31:0]  mmio_araddr_raw;
  logic         mmio_arvalid_raw;
  logic         mmio_arready_raw;
  logic [31:0]  mmio_rdata_raw;
  logic [1:0]   mmio_rresp_raw;
  logic         mmio_rvalid_raw;
  logic         mmio_rready_raw;

  // MMIO arbiter: merges CPU0..CPU3 uncached MMIO into the bridge, and
  // provides the HART_ID register at 0x4000_0FF0 (returns requesting core).
  logic [63:0]  mmio_arb_rd_addr;
  logic         mmio_arb_rd_req;
  logic         mmio_arb_rd_done;
  logic [63:0]  mmio_arb_rd_data;
  logic [63:0]  mmio_arb_wr_addr;
  logic [63:0]  mmio_arb_wr_data;
  logic [7:0]   mmio_arb_wr_strobe;
  logic         mmio_arb_wr_valid;
  logic         mmio_arb_wr_done;
  logic [1:0]   mmio_arb_req_core;

  c930_mmio_arb u_mmio_arb (
    .i_clk           (core_clk),
    .i_rst_n         (core_rst_n),

    // Core 0 (CPU0)
    .i0_rd_addr      (mmio_rd_addr),
    .i0_rd_req       (mmio_rd_req),
    .o0_rd_done      (mmio_rd_done),
    .o0_rd_data      (mmio_rd_data),
    .i0_wr_addr      (mmio_wr_addr),
    .i0_wr_data      (mmio_wr_data),
    .i0_wr_strobe    (mmio_wr_strobe),
    .i0_wr_valid     (mmio_wr_valid),
    .o0_wr_done      (mmio_wr_done),

    // Core 1 (CPU1)
    .i1_rd_addr      (mmio1_rd_addr),
    .i1_rd_req       (mmio1_rd_req),
    .o1_rd_done      (mmio1_rd_done),
    .o1_rd_data      (mmio1_rd_data),
    .i1_wr_addr      (mmio1_wr_addr),
    .i1_wr_data      (mmio1_wr_data),
    .i1_wr_strobe    (mmio1_wr_strobe),
    .i1_wr_valid     (mmio1_wr_valid),
    .o1_wr_done      (mmio1_wr_done),

    // Core 2 (CPU2)
    .i2_rd_addr      (mmio2_rd_addr),
    .i2_rd_req       (mmio2_rd_req),
    .o2_rd_done      (mmio2_rd_done),
    .o2_rd_data      (mmio2_rd_data),
    .i2_wr_addr      (mmio2_wr_addr),
    .i2_wr_data      (mmio2_wr_data),
    .i2_wr_strobe    (mmio2_wr_strobe),
    .i2_wr_valid     (mmio2_wr_valid),
    .o2_wr_done      (mmio2_wr_done),

    // Core 3 (CPU3)
    .i3_rd_addr      (mmio3_rd_addr),
    .i3_rd_req       (mmio3_rd_req),
    .o3_rd_done      (mmio3_rd_done),
    .o3_rd_data      (mmio3_rd_data),
    .i3_wr_addr      (mmio3_wr_addr),
    .i3_wr_data      (mmio3_wr_data),
    .i3_wr_strobe    (mmio3_wr_strobe),
    .i3_wr_valid     (mmio3_wr_valid),
    .o3_wr_done      (mmio3_wr_done),

    // Merged port to bridge
    .o_mmio_read_addr  (mmio_arb_rd_addr),
    .o_mmio_read_req   (mmio_arb_rd_req),
    .i_mmio_read_done  (mmio_arb_rd_done),
    .i_mmio_read_data  (mmio_arb_rd_data),
    .o_mmio_write_addr   (mmio_arb_wr_addr),
    .o_mmio_write_data   (mmio_arb_wr_data),
    .o_mmio_write_strobe (mmio_arb_wr_strobe),
    .o_mmio_write_valid  (mmio_arb_wr_valid),
    .i_mmio_write_done   (mmio_arb_wr_done),

    // Requesting core ID (for the bridge's HART_ID register)
    .o_req_core          (mmio_arb_req_core)
  );

  c930_mmio_bridge u_mmio_bridge (
    .i_clk              (core_clk),
    .i_rst_n            (core_rst_n),

    .i_mmio_read_addr   (mmio_arb_rd_addr),
    .i_mmio_read_req    (mmio_arb_rd_req),
    .o_mmio_read_done   (mmio_arb_rd_done),
    .o_mmio_read_data   (mmio_arb_rd_data),

    .i_mmio_write_addr  (mmio_arb_wr_addr),
    .i_mmio_write_data  (mmio_arb_wr_data),
    .i_mmio_write_strobe(mmio_arb_wr_strobe),
    .i_mmio_write_valid (mmio_arb_wr_valid),
    .o_mmio_write_done  (mmio_arb_wr_done),

    .i_hart_id          (mmio_arb_req_core),

    // Raw AXI4-Lite output (before address decode mux)
    .m_axi_awaddr       (mmio_awaddr_raw),
    .m_axi_awvalid      (mmio_awvalid_raw),
    .m_axi_awready      (mmio_awready_raw),
    .m_axi_wdata        (mmio_wdata_raw),
    .m_axi_wstrb        (mmio_wstrb_raw),
    .m_axi_wvalid       (mmio_wvalid_raw),
    .m_axi_wready       (mmio_wready_raw),
    .m_axi_bresp        (mmio_bresp_raw),
    .m_axi_bvalid       (mmio_bvalid_raw),
    .m_axi_bready       (mmio_bready_raw),
    .m_axi_araddr       (mmio_araddr_raw),
    .m_axi_arvalid      (mmio_arvalid_raw),
    .m_axi_arready      (mmio_arready_raw),
    .m_axi_rdata        (mmio_rdata_raw),
    .m_axi_rresp        (mmio_rresp_raw),
    .m_axi_rvalid       (mmio_rvalid_raw),
    .m_axi_rready       (mmio_rready_raw)
  );

  // ---- Address decode mux ----
  // Route MMIO bridge output to NPU0 CSR, NPU1 CSR, UART, or APLIC.
  //   0x4000_0000-0x4000_003F  → NPU0 CSR
  //   0x4000_0040-0x4000_007F  → NPU1 CSR
  //   0x4000_1000-0x4000_1FFF  → UART
  //   0x4000_4000-0x4000_4FFF  → APLIC
  // ---- Address decode mux (write side: decodes the write address) ----
  wire w_to_uart  = (mmio_awaddr_raw[31:12] == 20'h40001);
  wire w_to_aplic = (mmio_awaddr_raw[31:12] == 20'h40004);
  wire w_to_npu1  = (mmio_awaddr_raw[31:6]  == 26'h1000001);   // 0x4000_0040-0x4000_007F
  wire w_to_npu0  = ~w_to_uart & ~w_to_npu1 & ~w_to_aplic;  // default: NPU0

  // ---- Address decode mux (read side: decodes the READ address) ----
  // Reads must decode off the read address, NOT the write address.  The write
  // address bus holds a stale last-write value during a read, so routing reads
  // with it silently steered APLIC/NPU1/UART reads to NPU0 (the default) --
  // which is exactly what happened to the APLIC claim/status reads.
  wire r_to_uart  = (mmio_araddr_raw[31:12] == 20'h40001);
  wire r_to_aplic = (mmio_araddr_raw[31:12] == 20'h40004);
  wire r_to_npu1  = (mmio_araddr_raw[31:6]  == 26'h1000001);   // 0x4000_0040-0x4000_007F
  wire r_to_npu0  = ~r_to_uart & ~r_to_npu1 & ~r_to_aplic;  // default: NPU0

  // NPU0 CSR (backward compat)
  assign csr_awaddr  = mmio_awaddr_raw;
  assign csr_awvalid = mmio_awvalid_raw & w_to_npu0;
  assign csr_wdata   = mmio_wdata_raw;
  assign csr_wstrb   = mmio_wstrb_raw;
  assign csr_wvalid  = mmio_wvalid_raw & w_to_npu0;
  assign csr_bready  = mmio_bready_raw & w_to_npu0;
  assign csr_araddr  = mmio_araddr_raw;
  assign csr_arvalid = mmio_arvalid_raw & r_to_npu0;
  assign csr_rready  = mmio_rready_raw & r_to_npu0;

  // NPU1 CSR
  assign csr1_awaddr  = mmio_awaddr_raw;
  assign csr1_awvalid = mmio_awvalid_raw & w_to_npu1;
  assign csr1_wdata   = mmio_wdata_raw;
  assign csr1_wstrb   = mmio_wstrb_raw;
  assign csr1_wvalid  = mmio_wvalid_raw & w_to_npu1;
  assign csr1_bready  = mmio_bready_raw & w_to_npu1;
  assign csr1_araddr  = mmio_araddr_raw;
  assign csr1_arvalid = mmio_arvalid_raw & r_to_npu1;
  assign csr1_rready  = mmio_rready_raw & r_to_npu1;

  // UART AXI4-Lite signals (active when w_to_uart / r_to_uart)
  assign uart_awaddr  = mmio_awaddr_raw;
  assign uart_awvalid = mmio_awvalid_raw & w_to_uart;
  assign uart_awlen   = '0;
  assign uart_awsize  = 3'd2;
  assign uart_awburst = 2'b00;
  assign uart_wdata   = {32'd0, mmio_wdata_raw};
  assign uart_wstrb   = {{4{mmio_wstrb_raw[3]}}, {4{mmio_wstrb_raw[2]}},
                         {4{mmio_wstrb_raw[1]}}, {4{mmio_wstrb_raw[0]}}};
  assign uart_wlast   = 1'b1;
  assign uart_wvalid  = mmio_wvalid_raw & w_to_uart;
  assign uart_bready  = mmio_bready_raw & w_to_uart;

  assign uart_araddr  = mmio_araddr_raw;
  assign uart_arvalid = mmio_arvalid_raw & r_to_uart;
  assign uart_arlen   = '0;
  assign uart_arsize  = 3'd2;
  assign uart_arburst = 2'b00;
  assign uart_rready  = mmio_rready_raw & r_to_uart;

  // APLIC AXI4-Lite signals (active when w_to_aplic / r_to_aplic)
  assign aplic_awaddr  = mmio_awaddr_raw;
  assign aplic_awvalid = mmio_awvalid_raw & w_to_aplic;
  assign aplic_wdata   = {32'd0, mmio_wdata_raw};
  assign aplic_wstrb   = {{4{mmio_wstrb_raw[3]}}, {4{mmio_wstrb_raw[2]}},
                          {4{mmio_wstrb_raw[1]}}, {4{mmio_wstrb_raw[0]}}};
  assign aplic_wvalid  = mmio_wvalid_raw & w_to_aplic;
  assign aplic_bready  = mmio_bready_raw & w_to_aplic;

  assign aplic_araddr  = mmio_araddr_raw;
  assign aplic_arvalid = mmio_arvalid_raw & r_to_aplic;
  assign aplic_rready  = mmio_rready_raw & r_to_aplic;

  // Mux responses back to bridge (4 targets: NPU0, NPU1, UART, APLIC)
  logic [1:0] sel_r;
  localparam logic [1:0] SEL_NPU0 = 2'd0, SEL_NPU1 = 2'd1, SEL_UART = 2'd2, SEL_APLIC = 2'd3;
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n)
      sel_r <= SEL_NPU0;
    else if (mmio_arvalid_raw && mmio_arready_raw)
      sel_r <= r_to_aplic ? SEL_APLIC : r_to_uart ? SEL_UART : r_to_npu1 ? SEL_NPU1 : SEL_NPU0;
  end

  // Write response mux (combinational, use current write address decode)
  assign mmio_awready_raw = w_to_aplic ? aplic_awready : w_to_uart ? uart_awready :
                            w_to_npu1 ? csr1_awready : csr_awready;
  assign mmio_wready_raw  = w_to_aplic ? aplic_wready  : w_to_uart ? uart_wready  :
                            w_to_npu1 ? csr1_wready  : csr_wready;
  assign mmio_bresp_raw   = w_to_aplic ? aplic_bresp   : w_to_uart ? uart_bresp   :
                            w_to_npu1 ? csr1_bresp   : csr_bresp;
  assign mmio_bvalid_raw  = w_to_aplic ? aplic_bvalid  : w_to_uart ? uart_bvalid  :
                            w_to_npu1 ? csr1_bvalid  : csr_bvalid;
  // Read arready mux (use current READ address decode)
  assign mmio_arready_raw = r_to_aplic ? aplic_arready : r_to_uart ? uart_arready :
                            r_to_npu1 ? csr1_arready : csr_arready;
  // Read response mux (uses registered sel_r for correct data return)
  assign mmio_rdata_raw   = (sel_r == SEL_APLIC) ? aplic_rdata[31:0] :
                            (sel_r == SEL_UART) ? uart_rdata[31:0] :
                            (sel_r == SEL_NPU1) ? csr1_rdata : csr_rdata;
  assign mmio_rresp_raw   = (sel_r == SEL_APLIC) ? aplic_rresp :
                            (sel_r == SEL_UART) ? uart_rresp  :
                            (sel_r == SEL_NPU1) ? csr1_rresp  : csr_rresp;
  assign mmio_rvalid_raw  = (sel_r == SEL_APLIC) ? aplic_rvalid :
                            (sel_r == SEL_UART) ? uart_rvalid :
                            (sel_r == SEL_NPU1) ? csr1_rvalid : csr_rvalid;

endmodule
