// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// ---------------------------------------------------------------------------
// grx930_test_chip.sv
//
// Stripped-down GRX930 test chip for wafer.space GF180MCU shuttle.
// Targets the 1×1 slot (3.932mm × 5.122mm die, 12.92 mm² core).
//
// What's included:
//   - 1× RV64IMAC core (5-stage in-order, compressed ISA)
//   - 512 B I-cache + 512 B D-cache (INDEX_WIDTH 4; FF arrays)
//   - 2 KB on-chip SRAM (data + stack; the RTL module keeps its old name)
//   - 1 KB boot ROM at 0x0001_0000 — the reset PC; the chip's only code
//     source at power-up, since the SRAM has no initial contents
//   - Simple AXI4-Lite bus fabric (1 master, 3 slaves)
//   - 16550-compatible UART (debug output)
//   - 74-pad wafer.space standard ring (placed outside this module)
//
// What's removed vs. full c930_soc_top:
//   - No NPU (saves ~300K gates)
//   - No multi-core (saves 3× CPU + arbiter)
//   - No DDR controller (uses on-chip SRAM)
//   - No L2 cache (not needed for single core)
//   - No APLIC (simplified interrupt: just external)
//   - No cache coherency fabric
//   - Tiny caches (512 B vs 32KB each)
//
// Memory map:
//   0x0000_0000 – 0x0000_07FF : 2 KB SRAM (≥2 KB addresses alias into it)
//   0x0001_0000 – 0x0001_03FF : 1 KB boot ROM (read-only, reset vector)
//   0x4000_1000 – 0x4000_100F : UART (16550, AXI4-Lite)
//
// Wafer.space slot: 1×1
//   Die: 3.932mm × 5.122mm (20.1 mm²) — exact precheck size
//   Core: 12.92 mm² (inside the default pad ring)
//   I/O: 74-pad default ring (40 bidir, 13 input, 2 analog, 18 power)
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
    // Reset into the boot ROM (0x0001_0000). The SRAM powers up uninitialised,
    // so 0x0 is not a code source in silicon; the ROM holds the banner/self-test
    // firmware (openlane2_rtl/src/grx930_test_chip_rom.sv, generated from
    // sw/test_chip_boot.hex by tools/gen_bootrom.py).
    .CORE_RESET_PC      (64'h0_0001_0000)
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
  logic inflight;            // a read has been accepted and is not yet complete
  logic inflight_rom;        // ... the ROM is serving it (held until done)
  logic inflight_d;          // ... the D-cache owns it (held until done)
  logic sram_busy;           // SRAM cannot accept a read this cycle

  assign dcache_rd_granted = ~icache_rd_req & dcache_rd_req;


  // --- Boot ROM / SRAM address split ---------------------------------------
  // Both memories present the same interface (256-bit line, 2-cycle latency),
  // so which one serves an access is a pure address-range mux on the arbitrated
  // address and the arbiter/owner pipeline above is untouched. ROM reads do not
  // clock the SRAM (no wasted read, no spurious done pulse).
  // Data loads from ROM space take the D-cache path and alias into the SRAM
  // (documented limitation; the boot firmware reads only SRAM/UART data).
  localparam logic [63:0] ROM_BASE = 64'h0000_0000_0001_0000;

  logic [255:0] rom_rd_line;
  logic         rom_rd_done;
  wire rom_hit = (sram_rd_addr[63:10] == ROM_BASE[63:10]);

  grx930_test_chip_rom #(.ROM_BASE(ROM_BASE)) u_rom (
    .i_clk     (core_clk),
    .i_rst_n   (core_rst_n),
    .i_rd_addr (sram_rd_addr),
    .o_rd_line (rom_rd_line),
    .o_rd_done (rom_rd_done)
  );

  // -------------------------------------------------------------------------
  // Read handshake: one access in flight, owner and select held until done.
  //
  // The two memories no longer have the same latency, so a fixed-depth owner
  // pipeline cannot align the done pulse with the master that asked for it:
  // the ROM answers in 2 cycles, while the macro-backed SRAM
  // (`USE_SRAM_MACRO`) needs 5 -- four word beats plus the registered output --
  // and refuses a read for a cycle while it drains a buffered write
  // (`o_busy`). Both requesters hold their request until *_rd_done, so the bus
  // can simply accept one access at a time, latch who owns it, and route each
  // memory's own done strobe to that owner.
  //
  // Holding the select also keeps the fill line stable for the write-back
  // cycle: the I-cache controller drops its request at the done cycle and
  // stores the line ONE CYCLE LATER, so a live-address mux would pick the
  // wrong (idle) memory exactly when the line is consumed -- which is how the
  // ROM boot once silently stored X in the cache.
  wire accept_i = icache_rd_req & ~inflight & (rom_hit | ~sram_busy);
  wire accept_d = dcache_rd_req & ~icache_rd_req & ~inflight & (rom_hit | ~sram_busy);
  wire accept   = accept_i | accept_d;

  // One-cycle request pulse: both memories latch on it and report their own
  // completion later. `rom_hit` is only sampled on an accept cycle -- another
  // master may present a different address while this access is in flight, so
  // it must not be read live downstream.
  //
  // The address mux selects on the request priority, NOT on accept_d: rom_hit
  // is decoded from this address and the accept terms test rom_hit, so routing
  // accept_d back into the mux is a combinational loop (Yosys `check` reports
  // it, and Checker.YosysSynthChecks then stops the flow). Priority and accept
  // agree on every accept cycle -- accept_d requires ~icache_rd_req -- so the
  // address is the requester's either way.
  assign sram_rd_req  = accept & ~rom_hit;
  assign sram_rd_addr = dcache_rd_granted ? dcache_rd_addr : icache_rd_addr;

  wire done_any = inflight_rom ? rom_rd_done : sram_rd_done;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      inflight     <= 1'b0;
      inflight_rom <= 1'b0;
      inflight_d   <= 1'b0;
    end else if (accept) begin
      inflight     <= 1'b1;
      inflight_rom <=   rom_hit;
      inflight_d   <=   accept_d;
    end else if (done_any) begin
      inflight     <= 1'b0;
    end
  end

  // D-cache reads also go to SRAM (address 0x0000_0000 – 0x0000_07FF; higher
  // aliases), and addresses in the ROM window are served by the ROM instead.
  assign icache_rd_done = done_any & ~inflight_d;
  assign dcache_rd_done = done_any &  inflight_d;

  // Read data feeds both cache fill ports; the *_rd_done strobes above decide
  // which side consumes a given line.  Left undriven before, which tripped
  // Yosys' check pass (512 'used but has no driver' errors) and meant the CPU
  // never received cache line data at all.
  // Both memories must HOLD their line past the done pulse for this to work:
  // the SRAM's rd_word[] registers do, and the ROM's rd_line_r does.
  assign icache_rd_line = inflight_rom ? rom_rd_line : sram_rd_line;
  assign dcache_rd_line = inflight_rom ? rom_rd_line : sram_rd_line;

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
    .o_wr_done  (sram_wr_done),
    .o_busy     (sram_busy)
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
//
// Two implementations behind the same ports:
//   * default -- a flip-flop array, 2-cycle line read (every existing run and
//     the FPGA build use this);
//   * `USE_SRAM_MACRO` -- eight foundry gf180mcu_fd_ip_sram__sram512x8m8wm1
//     macros, byte-sliced, 5-cycle line read. This variant exists to put the
//     real macro path (MACROS, PDN straps over a macro, fixed placement,
//     antenna, STA against the vendor .lib) through the flow; see the block
//     comment on the implementation for the beat sequence.
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
  output logic         o_wr_done,

  // Cannot accept a read this cycle: the macro bank starts a fill only when
  // the port is free (a buffered write gets it first). Always 0 for the FF
  // array, which is fully pipelined.
  output logic         o_busy
);

  // =========================================================================
  // Storage: 2KB = 256 × 64-bit words (single bank; Plan B shrink from 8KB)
  // =========================================================================
  localparam int DEPTH = 256;            // 64-bit words
  localparam int AW    = $clog2(DEPTH);  // 8 bits

`ifdef USE_SRAM_MACRO
  // =========================================================================
  // Foundry-macro storage: 8 × gf180mcu_fd_ip_sram__sram512x8m8wm1
  //
  // This is the macro-flow surrogate (scope §7 step 3): the same 2KB built
  // from the real SRAM instead of flops, so the flow has to do everything a
  // macro needs -- MACROS/PDN_MACRO_CONNECTIONS, straps over a macro, fixed
  // placement, antenna repair and STA against the vendor .lib -- at the
  // utilisation this part already routes.
  //
  // The macro is 512 × 8 with one synchronous port (Q is registered), so the
  // 64-bit word is byte-sliced across eight of them and the 256-bit line is
  // assembled from four sequential beats:
  //
  //   cycle  0        1         2         3         4
  //   addr   beat0 -> beat1  -> beat2  -> beat3
  //   Q      --        beat0     beat1     beat2     beat3 (captured here)
  //
  // o_rd_done is registered from that last capture, i.e. a line read takes 5
  // cycles against the FF array's 2 -- the same number of beats a real cache
  // fill takes. The bus above does not care: it routes each memory's own done
  // strobe and holds the owner for the access's lifetime.
  //
  // A single-port macro cannot read and write in the same cycle, so one write
  // is buffered and applied between fills, and o_busy is high from the moment
  // it arrives until it has been applied. The d-cache holds its write request
  // until o_wr_done, which is what makes a one-deep buffer enough.
  // =========================================================================
  logic [AW:0]   m_a;          // {0, word}: 9 bits, 256 of the 512 rows used
  logic          m_cen;        // chip enable, active low
  logic          m_gwen;       // global write enable, active low
  logic [63:0]   m_wen;        // per-bit write mask, active low: one byte per
                               // slice, all 8 bits of it the slice's strobe
  logic [63:0]   m_d;
  logic [63:0]   m_q;

  logic          fill_active;  // a line fill owns the port
  logic [1:0]    fill_beat;    // beat being issued, 0..3
  logic [AW-1:0] fill_word;    // word index of beat 0
  logic          q_is_word;    // m_q next cycle holds a line word
  logic [1:0]    q_word;       // ... which one
  logic          rd_done_r;

  logic          wb_valid;     // one buffered write, waiting for the port
  logic [AW-1:0] wb_addr;
  logic [63:0]   wb_data;
  logic [7:0]    wb_strobe;
  logic          wr_req_d;     // rising-edge detect: the requester holds req
  logic          wr_done_r;

  logic [63:0]   rd_word [3:0];  // 4 consecutive 64-bit words = 256-bit line

  assign o_busy    = fill_active | wb_valid;
  assign o_rd_line = {rd_word[3], rd_word[2], rd_word[1], rd_word[0]};
  assign o_rd_done = rd_done_r;
  assign o_wr_done = wr_done_r;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      m_cen       <= 1'b1;
      m_gwen      <= 1'b1;
      m_wen       <= {64{1'b1}};
      m_a         <= '0;
      m_d         <= '0;
      fill_active <= 1'b0;
      fill_beat   <= 2'd0;
      fill_word   <= '0;
      q_is_word   <= 1'b0;
      q_word      <= 2'd0;
      rd_done_r   <= 1'b0;
      wb_valid    <= 1'b0;
      wb_addr     <= '0;
      wb_data     <= '0;
      wb_strobe   <= '0;
      wr_req_d    <= 1'b0;
      wr_done_r   <= 1'b0;
    end else begin
      // Port idle and no completion, unless something below says otherwise.
      m_cen     <= 1'b1;
      m_gwen    <= 1'b1;
      m_wen     <= {64{1'b1}};
      rd_done_r <= 1'b0;
      wr_done_r <= 1'b0;
      wr_req_d  <= i_wr_req;

      // 1. Collect the word the macro drove out this cycle.
      if (q_is_word) begin
        rd_word[q_word] <= m_q;
        if (q_word == 2'd3)
          rd_done_r <= 1'b1;
      end

      // 2. Buffer one write. Captured on the rising edge of i_wr_req, which
      //    the d-cache holds until o_wr_done -- so a held request is one
      //    write, not one per cycle.
      if (i_wr_req & ~wr_req_d & ~wb_valid) begin
        wb_valid  <= 1'b1;
        wb_addr   <= i_wr_addr[AW+2:3];
        wb_data   <= i_wr_data;
        wb_strobe <= i_wr_strobe;
      end

      // 3. Drive the single port: a buffered write first, then line beats.
      if (wb_valid & ~fill_active) begin
        m_cen     <= 1'b0;
        m_gwen    <= 1'b0;          // write
        // One bit of the strobe masks all eight data bits of its slice:
        // slice i holds byte i, so WEN[8i +: 8] = ~wb_strobe[i] repeated.
        m_wen     <= ~{8{wb_strobe}};
        m_a       <= {1'b0, wb_addr};
        m_d       <= wb_data;
        wb_valid  <= 1'b0;
        wr_done_r <= 1'b1;
        q_is_word <= 1'b0;
      end else if (!fill_active) begin
        if (i_rd_req) begin
          // Accept: beat 0 goes out this cycle.
          fill_active <= 1'b1;
          fill_beat   <= 2'd1;
          fill_word   <= i_rd_addr[AW+2:3];
          m_cen       <= 1'b0;
          m_gwen      <= 1'b1;      // read
          m_a         <= {1'b0, i_rd_addr[AW+2:3]};
          q_is_word   <= 1'b1;
          q_word      <= 2'd0;
        end else begin
          q_is_word <= 1'b0;
        end
      end else begin
        m_cen     <= 1'b0;
        m_gwen    <= 1'b1;          // read
        m_a       <= {1'b0, fill_word + fill_beat};
        q_is_word <= 1'b1;
        q_word    <= fill_beat;
        if (fill_beat == 2'd3) begin
          fill_active <= 1'b0;
          fill_beat   <= 2'd0;
        end else begin
          fill_beat <= fill_beat + 2'd1;
        end
      end
    end
  end

  // Byte slice i of the 64-bit word lives in macro i: all eight share the
  // address, enables and clock, and each gets its own active-low byte mask.
  gf180mcu_fd_ip_sram__sram512x8m8wm1 u_macro_0 (
    .CLK (i_clk), .CEN (m_cen), .GWEN (m_gwen), .WEN (m_wen[ 7: 0]),
    .A (m_a), .D (m_d[ 7: 0]), .Q (m_q[ 7: 0])
  );
  gf180mcu_fd_ip_sram__sram512x8m8wm1 u_macro_1 (
    .CLK (i_clk), .CEN (m_cen), .GWEN (m_gwen), .WEN (m_wen[15: 8]),
    .A (m_a), .D (m_d[15: 8]), .Q (m_q[15: 8])
  );
  gf180mcu_fd_ip_sram__sram512x8m8wm1 u_macro_2 (
    .CLK (i_clk), .CEN (m_cen), .GWEN (m_gwen), .WEN (m_wen[23:16]),
    .A (m_a), .D (m_d[23:16]), .Q (m_q[23:16])
  );
  gf180mcu_fd_ip_sram__sram512x8m8wm1 u_macro_3 (
    .CLK (i_clk), .CEN (m_cen), .GWEN (m_gwen), .WEN (m_wen[31:24]),
    .A (m_a), .D (m_d[31:24]), .Q (m_q[31:24])
  );
  gf180mcu_fd_ip_sram__sram512x8m8wm1 u_macro_4 (
    .CLK (i_clk), .CEN (m_cen), .GWEN (m_gwen), .WEN (m_wen[39:32]),
    .A (m_a), .D (m_d[39:32]), .Q (m_q[39:32])
  );
  gf180mcu_fd_ip_sram__sram512x8m8wm1 u_macro_5 (
    .CLK (i_clk), .CEN (m_cen), .GWEN (m_gwen), .WEN (m_wen[47:40]),
    .A (m_a), .D (m_d[47:40]), .Q (m_q[47:40])
  );
  gf180mcu_fd_ip_sram__sram512x8m8wm1 u_macro_6 (
    .CLK (i_clk), .CEN (m_cen), .GWEN (m_gwen), .WEN (m_wen[55:48]),
    .A (m_a), .D (m_d[55:48]), .Q (m_q[55:48])
  );
  gf180mcu_fd_ip_sram__sram512x8m8wm1 u_macro_7 (
    .CLK (i_clk), .CEN (m_cen), .GWEN (m_gwen), .WEN (m_wen[63:56]),
    .A (m_a), .D (m_d[63:56]), .Q (m_q[63:56])
  );
`else
  // =========================================================================
  // Flip-flop array (default): 2-cycle line read, 1-cycle write
  // =========================================================================

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
  assign o_busy    = 1'b0;   // fully pipelined: a read can be accepted every cycle
`endif

endmodule
