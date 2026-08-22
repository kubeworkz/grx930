// -----------------------------------------------------------------------------
// c930_soc_top.sv
//
// Minimal C930-class SoC that stitches the reference RV64IMAC core together
// with the INT8 tensor NPU:
//
//   * riscv_core_top   : CPU (RV64IMAC, 5-stage in-order, I/D caches)
//   * c930_npu_top     : NPU (AXI4-Lite CSR slave + AXI4 full DMA master)
//   * c930_ddr         : unified byte-addressable memory (CPU cache ports +
//                        AXI4 slave), a DDR stand-in
//   * c930_mmio_bridge : CPU uncached MMIO port <-> NPU AXI4-Lite CSR slave
//
// Memory map (flat, byte addressed):
//   0x0000_0000 .. 0x0000_FFFF : DDR (code + data + NPU A/B/C buffers)
//   0x4000_0000 .. 0x4000_001F : NPU MMIO control/status (uncached)
//
// The CPU's data cache issues uncached MMIO transactions for addresses at or
// above MMIO_BASE; everything else goes through the cache ports to the DDR.
// -----------------------------------------------------------------------------
module c930_soc_top
#(
  parameter int NUM_ROWS = 4,
  parameter int NUM_COLS = 4,
  parameter int MAX_M    = 8,
  parameter int MAX_K    = 16,
  parameter int MAX_N    = 12,
  parameter int MEM_BYTES = 65536,
  // Core clock divider. 1 = run the whole SoC on the input clock (default;
  // used by the Icarus testbenches and the ECP5 flow). >1 divides the input
  // clock so the 100 MHz Arty oscillator produces a core clock comfortably
  // below the routed Fmax (100 MHz / 2 = 50 MHz vs ~68.75 MHz routed). The
  // Xilinx flow overrides this to 2 via the synth run's `generic` property.
  parameter int CLK_DIV  = 1
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- NPU completion (for test/monitor; the C program polls STATUS) ----
  output logic o_npu_busy,
  output logic o_npu_done,
  output logic o_npu_error,
  output logic o_npu_irq
);

  localparam logic [63:0] MMIO_BASE = 64'h4000_0000;

  // ---------------------------------------------------------------------------
  // Core clock generation. CLK_DIV = 1 passes the input clock through
  // unchanged. CLK_DIV > 1 runs a counter-based divide-by-N toggle (50% duty
  // cycle) plus an async-assert/sync-release reset synchronizer on the divided
  // clock, so the core and all peripherals see a clean, resettable clock.
  // The divider output is a plain FF (no combinational logic), so the divided
  // clock edges are glitch-free; the XDC declares it as a generated clock.
  // ---------------------------------------------------------------------------
  logic core_clk;
  logic core_rst_n;

  generate
    if (CLK_DIV > 1) begin : g_clkgen
      (* DONT_TOUCH = "TRUE" *) logic [$clog2(CLK_DIV)-1:0] clk_cnt;
      (* DONT_TOUCH = "TRUE" *) logic clk_div;
      logic rst_s1, rst_s2;

      // Icarus t=0 fix (same pattern as the core's caches): define the
      // divider/synchronizer registers before the first clock edge, else the
      // async-reset arms never fire (no reset transition at t=0) and the
      // divided reset propagates X into the core.
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

      // Reset synchronizer: async assert on i_rst_n, sync release on core_clk.
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

  // ---------------------------------------------------------------------------
  // CPU <-> DDR (cache-line read ports + write port)
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // CPU MMIO <-> bridge
  // ---------------------------------------------------------------------------
  logic [63:0]  mmio_rd_addr;
  logic         mmio_rd_req;
  logic         mmio_rd_done;
  logic [63:0]  mmio_rd_data;

  logic [63:0]  mmio_wr_addr;
  logic [63:0]  mmio_wr_data;
  logic [7:0]   mmio_wr_strobe;
  logic         mmio_wr_valid;
  logic         mmio_wr_done;

  // ---------------------------------------------------------------------------
  // bridge <-> NPU AXI4-Lite (CSR)
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // NPU AXI4 full master <-> DDR AXI4 slave
  // ---------------------------------------------------------------------------
  logic [31:0]  m_axi_araddr;
  logic [7:0]   m_axi_arlen;
  logic [2:0]   m_axi_arsize;
  logic [1:0]   m_axi_arburst;
  logic         m_axi_arvalid;
  logic         m_axi_arready;
  logic [31:0]  m_axi_rdata;
  logic [1:0]   m_axi_rresp;
  logic         m_axi_rlast;
  logic         m_axi_rvalid;
  logic         m_axi_rready;
  logic [31:0]  m_axi_awaddr;
  logic [7:0]   m_axi_awlen;
  logic [2:0]   m_axi_awsize;
  logic [1:0]   m_axi_awburst;
  logic         m_axi_awvalid;
  logic         m_axi_awready;
  logic [31:0]  m_axi_wdata;
  logic [3:0]   m_axi_wstrb;
  logic         m_axi_wlast;
  logic         m_axi_wvalid;
  logic         m_axi_wready;
  logic [1:0]   m_axi_bresp;
  logic         m_axi_bvalid;
  logic         m_axi_bready;

  // ---------------------------------------------------------------------------
  // CPU
  // ---------------------------------------------------------------------------
  riscv_core_top u_cpu (
    .i_riscv_core_clk                  (core_clk),
    .i_riscv_core_rst_n                (core_rst_n),
    .i_riscv_core_external_interrupt_m (1'b0),
    .i_riscv_core_external_interrupt_s (1'b0),
    .o_riscv_core_ack                  (),

    // data cache
    .mem_read_address              (dcache_rd_addr),
    .o_mem_write_data              (dcache_wr_data),
    .o_mem_write_address           (dcache_wr_addr),
    .mem_read_req                  (dcache_rd_req),
    .o_mem_write_valid             (dcache_wr_valid),
    .mem_read_done                 (dcache_rd_done),
    .i_mem_write_done              (dcache_wr_done),
    .i_block_from_axi_data_cache   (dcache_rd_line),
    .o_mem_write_strobe            (dcache_wr_strobe),

    // instruction cache
    .o_addr_from_control_to_axi    (icache_rd_addr),
    .o_mem_req                     (icache_rd_req),
    .i_mem_done                    (icache_rd_done),
    .i_block_from_axi_i_cache      (icache_rd_line),

    // MMIO (uncached peripheral)
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

  // ---------------------------------------------------------------------------
  // NPU
  // ---------------------------------------------------------------------------
  c930_npu_top #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (8),
    .ACC_W    (32),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N)
  ) u_npu (
    .i_clk         (core_clk),
    .i_rst_n       (core_rst_n),

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
    .m_axi_bready  (m_axi_bready),

    .o_busy        (o_npu_busy),
    .o_done        (o_npu_done),
    .o_error       (o_npu_error),
    .o_irq         (o_npu_irq)
  );

  // ---------------------------------------------------------------------------
  // CPU MMIO <-> NPU AXI4-Lite CSR
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Unified DDR
  // ---------------------------------------------------------------------------
  c930_ddr #(
    .MEM_BYTES         (MEM_BYTES),
    .ADDR_WIDTH        (64),
    .CACHE_LINE_WIDTH  (256)
  ) u_ddr (
    .i_clk             (core_clk),
    .i_rst_n           (core_rst_n),

    .i_icache_rd_addr  (icache_rd_addr),
    .i_icache_rd_req   (icache_rd_req),
    .o_icache_rd_done  (icache_rd_done),
    .o_icache_rd_line  (icache_rd_line),

    .i_dcache_rd_addr  (dcache_rd_addr),
    .i_dcache_rd_req   (dcache_rd_req),
    .o_dcache_rd_done  (dcache_rd_done),
    .o_dcache_rd_line  (dcache_rd_line),

    .i_dcache_wr_addr  (dcache_wr_addr),
    .i_dcache_wr_data  (dcache_wr_data),
    .i_dcache_wr_strobe(dcache_wr_strobe),
    .i_dcache_wr_valid (dcache_wr_valid),
    .o_dcache_wr_done  (dcache_wr_done),

    .s_axi_araddr      (m_axi_araddr),
    .s_axi_arlen       (m_axi_arlen),
    .s_axi_arvalid     (m_axi_arvalid),
    .s_axi_arready     (m_axi_arready),
    .s_axi_rdata       (m_axi_rdata),
    .s_axi_rresp       (m_axi_rresp),
    .s_axi_rlast       (m_axi_rlast),
    .s_axi_rvalid      (m_axi_rvalid),
    .s_axi_rready      (m_axi_rready),
    .s_axi_awaddr      (m_axi_awaddr),
    .s_axi_awlen       (m_axi_awlen),
    .s_axi_awvalid     (m_axi_awvalid),
    .s_axi_awready     (m_axi_awready),
    .s_axi_wdata       (m_axi_wdata),
    .s_axi_wstrb       (m_axi_wstrb),
    .s_axi_wlast       (m_axi_wlast),
    .s_axi_wvalid      (m_axi_wvalid),
    .s_axi_wready      (m_axi_wready),
    .s_axi_bresp       (m_axi_bresp),
    .s_axi_bvalid      (m_axi_bvalid),
    .s_axi_bready      (m_axi_bready)
  );

endmodule
