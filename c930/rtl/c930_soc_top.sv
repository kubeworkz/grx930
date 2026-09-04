// -----------------------------------------------------------------------------
// c930_soc_top.sv
//
// Full C930-class SoC integrating:
//
//   * riscv_core_top       : CPU (RV64IMAC, 5-stage in-order, I/D caches)
//   * c930_npu_top         : NPU (AXI4-Lite CSR + AXI4 full DMA)
//   * c930_axi_cache_adapter (x2) : CPU cache-line ports → AXI4 full master
//   * c930_axi_crossbar    : 3-master × 4-slave AXI4 shared-bus crossbar
//   * c930_bootrom         : 1 KB boot ROM (AXI4 full slave, read-only)
//   * c930_ddr             : unified DDR (AXI4 full slave)
//   * c930_uart            : 16550-compatible UART (AXI4-Lite slave)
//   * c930_mmio_bridge     : CPU uncached MMIO → NPU AXI4-Lite CSR
//
// Memory map (byte addressed):
//   0x0000_0000 .. 0x0000_03FF : Boot ROM (1 KB, read-only)
//   0x0000_1000 .. 0x0000_FFFF : DDR (code + data + NPU A/B/C buffers)
//   0x4000_0000 .. 0x4000_003F : NPU MMIO (via MMIO bridge, backward compat)
//   0x4000_1000 .. 0x4000_100F : UART (16550, AXI4-Lite)
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
  parameter     DDR_INIT_FILE = "",  // optional hex preload for DDR (testbench use)
  parameter     BOOT_INIT_FILE = "sw/boot.hex"  // boot ROM firmware hex
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- NPU status ----
  output logic o_npu_busy,
  output logic o_npu_done,
  output logic o_npu_error,
  output logic o_npu_irq,

  // ---- UART ----
  output logic o_uart_txd,
  input  logic i_uart_rxd
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
  // NPU AXI4 full master (to crossbar)
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

  c930_axi_cache_adapter u_dcache_adapter (
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
  // AXI4 crossbar: 3 masters × 4 slaves
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

    // ---- M2: NPU DMA ----
    .m2_awid    (npu_awid),      .m2_awaddr  (npu_awaddr),     .m2_awlen  (npu_awlen),
    .m2_awsize  (npu_awsize),    .m2_awburst (npu_awburst),    .m2_awvalid(npu_awvalid),
    .m2_awready (npu_awready),
    .m2_wdata   (npu_wdata),     .m2_wstrb   (npu_wstrb),      .m2_wlast  (npu_wlast),
    .m2_wvalid  (npu_wvalid),    .m2_wready  (npu_wready),
    .m2_bid     (npu_bid),       .m2_bresp   (npu_bresp),      .m2_bvalid (npu_bvalid),
    .m2_bready  (npu_bready),
    .m2_arid    (npu_arid),      .m2_araddr  (npu_araddr),     .m2_arlen  (npu_arlen),
    .m2_arsize  (npu_arsize),    .m2_arburst (npu_arburst),    .m2_arvalid(npu_arvalid),
    .m2_arready (npu_arready),
    .m2_rid     (npu_rid),       .m2_rdata   (npu_rdata),      .m2_rresp  (npu_rresp),
    .m2_rlast   (npu_rlast),     .m2_rvalid  (npu_rvalid),     .m2_rready (npu_rready),

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
    .s1_awid    (ddr_awid),      .s1_awaddr  (ddr_awaddr),     .s1_awlen  (ddr_awlen),
    .s1_awsize  (ddr_awsize),    .s1_awburst (ddr_awburst),    .s1_awvalid(ddr_awvalid),
    .s1_awready (ddr_awready),
    .s1_wdata   (ddr_wdata),     .s1_wstrb   (ddr_wstrb),      .s1_wlast  (ddr_wlast),
    .s1_wvalid  (ddr_wvalid),    .s1_wready  (ddr_wready),
    .s1_bid     (ddr_bid),       .s1_bresp   (ddr_bresp),      .s1_bvalid (ddr_bvalid),
    .s1_bready  (ddr_bready),
    .s1_arid    (ddr_arid),      .s1_araddr  (ddr_araddr),     .s1_arlen  (ddr_arlen),
    .s1_arsize  (ddr_arsize),    .s1_arburst (ddr_arburst),    .s1_arvalid(ddr_arvalid),
    .s1_arready (ddr_arready),
    .s1_rid     (ddr_rid),       .s1_rdata   (ddr_rdata),      .s1_rresp  (ddr_rresp),
    .s1_rlast   (ddr_rlast),     .s1_rvalid  (ddr_rvalid),     .s1_rready (ddr_rready),

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

    // ---- S3: UART ----
    .s3_awid    (uart_awid),     .s3_awaddr  (uart_awaddr),    .s3_awlen  (uart_awlen),
    .s3_awsize  (uart_awsize),   .s3_awburst (uart_awburst),   .s3_awvalid(uart_awvalid),
    .s3_awready (uart_awready),
    .s3_wdata   (uart_wdata),    .s3_wstrb   (uart_wstrb),     .s3_wlast  (uart_wlast),
    .s3_wvalid  (uart_wvalid),   .s3_wready  (uart_wready),
    .s3_bid     (uart_bid),      .s3_bresp   (uart_bresp),     .s3_bvalid (uart_bvalid),
    .s3_bready  (uart_bready),
    .s3_arid    (uart_arid),     .s3_araddr  (uart_araddr),    .s3_arlen  (uart_arlen),
    .s3_arsize  (uart_arsize),   .s3_arburst (uart_arburst),   .s3_arvalid(uart_arvalid),
    .s3_arready (uart_arready),
    .s3_rid     (uart_rid),      .s3_rdata   (uart_rdata),     .s3_rresp  (uart_rresp),
    .s3_rlast   (uart_rlast),    .s3_rvalid  (uart_rvalid),    .s3_rready (uart_rready)
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

    // Testbench preload port (tied off in synthesis)
    .i_tb_wr_en   (1'b0),
    .i_tb_wr_addr  (32'd0),
    .i_tb_wr_data  (8'd0),

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
    .o_irq       (),  // TODO: connect to APLIC when built

    // AXI4-Lite slave (from crossbar S3)
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
  // CPU
  // =========================================================================
  riscv_core_top u_cpu (
    .i_riscv_core_clk                  (core_clk),
    .i_riscv_core_rst_n                (core_rst_n),
    .i_riscv_core_external_interrupt_m (1'b0),
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
    .i_mmio_write_done             (mmio_wr_done)
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

  // =========================================================================
  // CPU MMIO bridge (backward compat: CPU uncached MMIO → NPU AXI4-Lite CSR)
  // =========================================================================
  c930_mmio_bridge u_mmio_bridge (
    .i_clk              (core_clk),
    .i_rst_n            (core_rst_n),

    .i_mmio_read_addr   (mmio_rd_addr),
    .i_mmio_read_req    (mmio_rd_req),
    .o_mmio_read_done   (mmio_rd_done),
    .o_mmio_read_data   (mmio_rd_data),

    .i_mmio_write_addr  (mmio_wr_addr),
    .i_mmio_write_data  (mmio_wr_data),
    .i_mmio_write_strobe(mmio_wr_strobe),
    .i_mmio_write_valid (mmio_wr_valid),
    .o_mmio_write_done  (mmio_wr_done),

    .m_axi_awaddr       (csr_awaddr),
    .m_axi_awvalid      (csr_awvalid),
    .m_axi_awready      (csr_awready),
    .m_axi_wdata        (csr_wdata),
    .m_axi_wstrb        (csr_wstrb),
    .m_axi_wvalid       (csr_wvalid),
    .m_axi_wready       (csr_wready),
    .m_axi_bresp        (csr_bresp),
    .m_axi_bvalid       (csr_bvalid),
    .m_axi_bready       (csr_bready),
    .m_axi_araddr       (csr_araddr),
    .m_axi_arvalid      (csr_arvalid),
    .m_axi_arready      (csr_arready),
    .m_axi_rdata        (csr_rdata),
    .m_axi_rresp        (csr_rresp),
    .m_axi_rvalid       (csr_rvalid),
    .m_axi_rready       (csr_rready)
  );

endmodule
