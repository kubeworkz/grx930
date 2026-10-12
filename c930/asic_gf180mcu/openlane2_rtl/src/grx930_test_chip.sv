// ---------------------------------------------------------------------------
// grx930_test_chip.sv
//
// Stripped-down GRX930 test chip for wafer.space GF180MCU shuttle.
// Targets the 0.5×1 slot (1.94mm × 5.12mm, 4.46 mm² core).
//
// What's included:
//   - 1× RV64IMAC core (5-stage in-order, compressed ISA)
//   - 2KB I-cache + 2KB D-cache (tiny, BRAM-based)
//   - 64KB on-chip SRAM (boot/data memory, replaces DDR)
//   - Simple AXI4-Lite bus fabric (1 master, 3 slaves)
//   - 16550-compatible UART (debug output)
//   - 256-byte boot ROM
//   - 56-pad ring (wafer.space default)
//
// What's removed vs. full c930_soc_top:
//   - No NPU (saves ~300K gates)
//   - No multi-core (saves 3× CPU + arbiter)
//   - No DDR controller (uses on-chip SRAM)
//   - No L2 cache (not needed for single core)
//   - No APLIC (simplified interrupt: just external)
//   - No cache coherency fabric
//   - Tiny caches (2KB vs 32KB each)
//
// Memory map:
//   0x0000_0000 – 0x0000_07FF : 2KB SRAM (boot + data; ≥2KB addresses alias)
//   0x0001_0000 – 0x0001_00FF : Boot ROM (256 bytes, read-only)
//   0x4000_1000 – 0x4000_100F : UART (16550, AXI4-Lite)
//
// Wafer.space slot: 0.5×1 (half width)
//   Die: 1.94mm × 5.12mm (9.93 mm²)
//   Core: 4.46 mm² (with default pad ring)
//   I/O: 56 pads default, up to 122 with custom pad ring
// ---------------------------------------------------------------------------
module grx930_test_chip
#(
  parameter int CLK_FREQ = 50_000_000,   // 50 MHz (conservative for 180nm)
  parameter int BAUD_DIV = CLK_FREQ / 115200
)
(
  input  logic i_clk,           // External clock (50 MHz)
  input  logic i_rst_n,         // Active-low reset

  // ---- UART ----
  output logic o_uart_txd,
  input  logic i_uart_rxd,

  // ---- GPIO (active-low LED) ----
  output logic [3:0] o_gpio,

  // ---- Interrupts ----
  input  logic i_ext_irq        // External interrupt
);

  // =========================================================================
  // Internal clock and reset
  // =========================================================================
  logic core_clk;
  logic core_rst_n;

  assign core_clk   = i_clk;
  assign core_rst_n = i_rst_n;

  // =========================================================================
  // CPU core (RV64IMAC, single core)
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

  // MMIO port (uncached)
  logic [63:0]  mmio_rd_addr;
  logic         mmio_rd_req;
  logic         mmio_rd_done;
  logic [63:0]  mmio_rd_data;

  logic [63:0]  mmio_wr_addr;
  logic [63:0]  mmio_wr_data;
  logic [7:0]   mmio_wr_strobe;
  logic         mmio_wr_valid;
  logic         mmio_wr_done;

  // Not used (no L2 coherency in test chip)
  logic         icache_inv_ack;
  logic         dcache_inv_ack;

  riscv_core_top #(
    .ICACHE_INDEX_WIDTH (4),    // Plan B shrink: 2^4 = 16 data-array sets × 32 B = 512 B I-cache data
    .DCACHE_INDEX_WIDTH (4),    // Plan B shrink: 512 B D-cache data
    .CORE_RESET_PC      (64'h0_0000_0000)
  ) u_cpu (
    .i_riscv_core_clk              (core_clk),
    .i_riscv_core_rst_n            (core_rst_n),
    .i_riscv_core_external_interrupt_m (i_ext_irq),
    .i_riscv_core_external_interrupt_s (1'b0),
    .o_riscv_core_ack              (),

    // D-cache
    .mem_read_address              (dcache_rd_addr),
    .o_mem_write_data              (dcache_wr_data),
    .o_mem_write_address           (dcache_wr_addr),
    .mem_read_req                  (dcache_rd_req),
    .o_mem_write_valid             (dcache_wr_valid),
    .mem_read_done                 (dcache_rd_done),
    .i_mem_write_done              (dcache_wr_done),
    .i_block_from_axi_data_cache   (dcache_rd_line),
    .o_mem_write_strobe            (dcache_wr_strobe),

    // I-cache
    .o_addr_from_control_to_axi   (icache_rd_addr),
    .o_mem_req                    (icache_rd_req),
    .i_mem_done                   (icache_rd_done),
    .i_block_from_axi_i_cache     (icache_rd_line),

    // MMIO
    .o_mmio_read_address          (mmio_rd_addr),
    .o_mmio_read_req              (mmio_rd_req),
    .i_mmio_read_done             (mmio_rd_done),
    .i_mmio_read_data             (mmio_rd_data),
    .o_mmio_write_address         (mmio_wr_addr),
    .o_mmio_write_data            (mmio_wr_data),
    .o_mmio_write_strobe          (mmio_wr_strobe),
    .o_mmio_write_valid           (mmio_wr_valid),
    .i_mmio_write_done            (mmio_wr_done),

    // Coherence (tie off — no L2 in test chip)
    .i_icache_inv_valid           (1'b0),
    .i_icache_inv_addr            (64'd0),
    .o_icache_inv_ack             (icache_inv_ack),
    .i_dcache_inv_valid           (1'b0),
    .i_dcache_inv_addr            (64'd0),
    .o_dcache_inv_ack             (dcache_inv_ack)
  );

  // =========================================================================
  // Bus fabric: I-cache → SRAM, D-cache → SRAM, MMIO → UART/BootROM
  //
  // Simplified: no AXI4 crossbar. Direct point-to-point connections with
  // address decoding for MMIO space.
  // =========================================================================

  // --- SRAM (64KB, single-port muxed for I/D) ---
  logic        sram_rd_req;
  logic [63:0] sram_rd_addr;
  logic [255:0] sram_rd_line;
  logic        sram_rd_done;

  logic        sram_wr_req;
  logic [63:0] sram_wr_addr;
  logic [63:0] sram_wr_data;
  logic [7:0]  sram_wr_strobe;
  logic        sram_wr_done;

  // Simple arbiter for the single SRAM read port: I-cache has priority.
  // Both cache controllers hold their request until *_rd_done, so a fixed
  // priority mux plus a registered owner flag routes it safely: the owner is
  // sampled while the request is presented (it cannot change mid-flight
  // because the current master holds req until done) and *_rd_done is then
  // routed to that master only.  The previous code tied the port to the
  // I-cache alone and gated its done on ~dcache_rd_req, which both starved
  // D-cache misses forever and let a concurrent D-cache request mask the
  // I-cache completion.
  logic dcache_rd_granted;   // combinational: D-cache owns the port this cycle
  logic rd_owner_p1, rd_owner_p2; // owner of the in-flight access, pipelined

  assign dcache_rd_granted = ~icache_rd_req & dcache_rd_req;

  assign sram_rd_req  = icache_rd_req | dcache_rd_granted;
  assign sram_rd_addr = dcache_rd_granted ? dcache_rd_addr : icache_rd_addr;

  // The SRAM reports completion two cycles after accepting a request
  // (rd_valid_p1 → rd_valid_p2), so the owner flag is pipelined in lockstep
  // to align the done pulse with the master whose request is completing.
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      rd_owner_p1 <= 1'b0;
      rd_owner_p2 <= 1'b0;
    end else begin
      rd_owner_p1 <= dcache_rd_granted;
      rd_owner_p2 <= rd_owner_p1;
    end
  end

  // D-cache reads also go to SRAM (address 0x0000_0000 – 0x0000_1FFF; higher aliases)
  // Done routing: whichever master owns the in-flight access sees completion.
  assign icache_rd_done = sram_rd_done & ~rd_owner_p2;
  assign dcache_rd_done = sram_rd_done &  rd_owner_p2;

  // SRAM read data feeds both cache fill ports; the *_rd_done strobes above
  // decide which side consumes a given line.  Left undriven before, which
  // tripped Yosys' check pass (512 'used but has no driver' errors) and meant
  // the CPU never received cache line data at all.
  assign icache_rd_line = sram_rd_line;
  assign dcache_rd_line = sram_rd_line;

  // D-cache write-through to SRAM
  assign sram_wr_req   = dcache_wr_valid;
  assign sram_wr_addr  = dcache_wr_addr;
  assign sram_wr_data  = dcache_wr_data;
  assign sram_wr_strobe = dcache_wr_strobe;
  assign dcache_wr_done = sram_wr_done;

  // (Legacy registered grant removed: it double-drove dcache_rd_granted
  // together with the combinational assign above — Yosys "multiple
  // conflicting drivers". The combinational grant + rd_owner pipeline is
  // the correct scheme: addr/grant/owner stay consistent every cycle.)

  // --- On-chip SRAM (8KB — shrunk from 64KB for GF180 1×1 die area) ---
  grx930_sram_64kb u_sram (
    .i_clk      (core_clk),
    .i_rst_n    (core_rst_n),
    // Read port (I-cache and D-cache share)
    .i_rd_req   (sram_rd_req),
    .i_rd_addr  (sram_rd_addr),
    .o_rd_line  (sram_rd_line),
    .o_rd_done  (sram_rd_done),
    // Write port (D-cache write-through)
    .i_wr_req   (sram_wr_req),
    .i_wr_addr  (sram_wr_addr),
    .i_wr_data  (sram_wr_data),
    .i_wr_strobe(sram_wr_strobe),
    .o_wr_done  (sram_wr_done)
  );

  // --- UART (16550, AXI4-Lite) ---
  logic        uart_rd_done;
  logic [31:0] uart_rd_data;  // UART AXI-Lite rdata is 32-bit; don't declare 64-bit —
                              // [63:32] was never driven and tripped Yosys' check pass.
  logic        uart_wr_done;

  // Simple AXI4-Lite decode for UART at 0x4000_1000
  localparam logic [63:0] UART_BASE = 64'h4000_1000;
  localparam logic [63:0] UART_END  = 64'h4000_1FFF;

  logic uart_sel;
  assign uart_sel = (mmio_rd_addr >= UART_BASE) & (mmio_rd_addr < UART_END);

  // UART read response (combinational — 1 cycle latency)
  assign mmio_rd_done = uart_rd_done;
  // Upper 32 bits are tie-off: the UART only ever returns 32-bit register reads.
  // Left undriven before, which tripped Yosys' check pass in synthesis.
  assign mmio_rd_data = {32'd0, uart_rd_data};
  assign mmio_wr_done = uart_wr_done;

  c930_uart #(
    .CLK_FREQ (CLK_FREQ)
  ) u_uart (
    .i_clk      (core_clk),
    .i_rst_n    (core_rst_n),
    // UART pins
    .o_uart_txd (o_uart_txd),
    .i_uart_rxd (i_uart_rxd),
    // IRQ
    .o_irq      (),
    // AXI4-Lite slave
    .s_axi_awaddr  (mmio_wr_addr[15:0]),
    .s_axi_awvalid (mmio_wr_valid & uart_sel),
    .s_axi_awready (),
    .s_axi_wdata   (mmio_wr_data[31:0]),
    .s_axi_wstrb   (mmio_wr_strobe[3:0]),
    .s_axi_wvalid  (mmio_wr_valid & uart_sel),
    .s_axi_wready  (),
    .s_axi_bresp   (),
    .s_axi_bvalid  (uart_wr_done),
    .s_axi_bready  (1'b1),
    .s_axi_araddr  (mmio_rd_addr[15:0]),
    .s_axi_arvalid (mmio_rd_req & uart_sel),
    .s_axi_arready (),
    .s_axi_rdata   (uart_rd_data),
    .s_axi_rresp   (),
    .s_axi_rvalid  (uart_rd_done),
    .s_axi_rready  (1'b1)
  );

  // =========================================================================
  // GPIO output (heartbeat counter)
  // =========================================================================
  logic [31:0] heartbeat_cnt;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n)
      heartbeat_cnt <= 32'd0;
    else
      heartbeat_cnt <= heartbeat_cnt + 1'b1;
  end

  assign o_gpio = heartbeat_cnt[27:24];  // Toggles ~ every 1.3s at 50 MHz

endmodule


// ---------------------------------------------------------------------------
// grx930_sram_64kb — 2KB on-chip SRAM (Plan B: shrunk from 8KB for netlist area)
//
// Simple dual-port SRAM: one read port (256-bit line) + one write port (64-bit).
// Read returns a full 256-bit cache line (32 bytes) aligned to 32-byte boundary.
// Write is byte-granular with strobe.
//
// The GF180 1×1 die (3930×5120 µm ≈ 20.1 mm²) cannot hold a 64KB flip-flop
// array (545K flops ≈ 34 mm² alone), and even the 8KB version pushed the
// netlist to 84% core utilization, so storage is 2KB single-bank.
// Byte addresses ≥ 2KB wrap (alias) into this array.
// ---------------------------------------------------------------------------
module grx930_sram_64kb
(
  input  logic         i_clk,
  input  logic         i_rst_n,

  // Read port (cache-line aligned, 256-bit)
  input  logic         i_rd_req,
  input  logic [63:0]  i_rd_addr,
  output logic [255:0] o_rd_line,
  output logic         o_rd_done,

  // Write port (byte-granular, 64-bit)
  input  logic         i_wr_req,
  input  logic [63:0]  i_wr_addr,
  input  logic [63:0]  i_wr_data,
  input  logic [7:0]   i_wr_strobe,
  output logic         o_wr_done
);

  // =========================================================================
  // Storage: 2KB = 256 × 64-bit words (single bank; Plan B shrink from 8KB)
  // =========================================================================
  localparam int DEPTH = 256;            // 64-bit words
  localparam int AW    = $clog2(DEPTH);  // 10 bits

  // Storage array (synthesized as a flip-flop array)
  logic [63:0] mem [DEPTH-1:0];

  // Read pipeline (2-cycle latency for SRAM access)
  logic        rd_valid_p1, rd_valid_p2;
  logic [AW-1:0] rd_addr_p1, rd_addr_p2;
  logic [63:0] rd_word [3:0];  // 4 consecutive 64-bit words = 256-bit line

  // Address decoding
  logic [AW-1:0] word_addr;
  logic [2:0]    line_offset;  // which 64-bit word within the 256-bit line

  assign word_addr  = i_rd_addr[AW+2:3];  // word-aligned
  assign line_offset = i_rd_addr[4:2];  // byte offset within line

  // =========================================================================
  // Read path (2-cycle pipeline)
  // =========================================================================
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rd_valid_p1 <= 1'b0;
      rd_valid_p2 <= 1'b0;
      rd_addr_p1  <= '0;
      rd_addr_p2  <= '0;
    end else begin
      // Stage 1: latch address, start SRAM read
      rd_valid_p1 <= i_rd_req;
      rd_addr_p1  <= word_addr;

      // Stage 2: SRAM data available
      rd_valid_p2 <= rd_valid_p1;
      rd_addr_p2  <= rd_addr_p1;
    end
  end

  // SRAM read (combinational from registered address)
  always_ff @(posedge i_clk) begin
    if (rd_valid_p1) begin
      rd_word[0] <= mem[rd_addr_p1];
      rd_word[1] <= mem[rd_addr_p1 + 1];
      rd_word[2] <= mem[rd_addr_p1 + 2];
      rd_word[3] <= mem[rd_addr_p1 + 3];
    end
  end

  // Assemble 256-bit line from 4 × 64-bit words
  assign o_rd_line = {rd_word[3], rd_word[2], rd_word[1], rd_word[0]};
  assign o_rd_done = rd_valid_p2;

  // =========================================================================
  // Write path (1-cycle latency)
  // =========================================================================
  logic wr_valid_p1;
  logic [AW-1:0] wr_addr_p1;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      wr_valid_p1 <= 1'b0;
      wr_addr_p1  <= '0;
    end else begin
      wr_valid_p1 <= i_wr_req;
      wr_addr_p1  <= i_wr_addr[AW+2:3];
    end
  end

  // Byte-granular write
  always_ff @(posedge i_clk) begin
    if (i_wr_req) begin
      for (int i = 0; i < 8; i++) begin
        if (i_wr_strobe[i])
          mem[i_wr_addr[AW+2:3]][i*8 +: 8] <= i_wr_data[i*8 +: 8];
      end
    end
  end

  assign o_wr_done = wr_valid_p1;

endmodule
