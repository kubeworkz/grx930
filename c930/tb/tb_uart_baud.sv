// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// =============================================================================
// tb_uart_baud.sv — unit test for c930_uart's baud divisor (TX and RX)
//
// CTRL[15:0] (offset 0x0C) is the register a double `always_ff` driver used to
// cost the synthesised netlist: the baud generator and the AXI register block
// both reset it, Yosys `check` reported one $adff per bit and sixteen
// conflicting drivers, and the netlist that came out of `make mapped` had no
// baud_divisor at all (see c930/asic/build/sky130_mapped2/README.md) — so
// ADDR_CTRL writes reached nothing and the baud rate was not programmable.
// The fix left the AXI block as the single owner.  This bench drives that
// register over the AXI4-Lite slave and measures the TX bit period on
// o_uart_txd, so the path the fix restored is simulated rather than only
// checked for a single driver.  The same baud_tick generates the receive
// sample grid, so the bench also injects frames on i_uart_rxd at the
// programmed divisor, checks each one decodes into the RX FIFO exactly once,
// and checks the RX interrupt reports it exactly once when enabled.
//
// Bit period is 16 * (DIVISOR + 1) core clocks: `baud_cnt` counts DIVISOR down
// to 0 and reloads, so a tick lands every DIVISOR + 1 clocks, and the TX FSM
// spends exactly 16 ticks on every bit (start, 8 data, stop).
//
// Covers:
//   1. Reset: CTRL reads back CLK_FREQ/(BAUD_RATE*16) - 1, and a frame sent
//      without touching CTRL has that bit period — the reset the fix left in
//      the AXI block is the one that reaches the counter.
//   2. Programmed divisor 3: CTRL reads back 3 and every bit is 64 clocks.
//   3. Reprogrammed to 7: CTRL reads back 7 and every bit is 128 clocks.  The
//      2x change is the point: a divisor that latched into a readable register
//      but never into the counter cannot pass both 2 and 3.
//   4. Byte strobes: WSTRB=0001 writes only CTRL[7:0], WSTRB=0010 only
//      CTRL[15:8].
//   5. Data integrity: the byte is 0x55, so the measured segment levels must be
//      start=0, then 1,0,1,0,1,0,1,0, stop=1 — the timing test cannot pass on a
//      stuck or wrongly shifted line.
//   6. Receive: a frame injected on i_uart_rxd at divisor 7 decodes to the
//      driven byte and leaves exactly one entry in the RX FIFO — it is empty
//      again after a single read.  The RX FIFO store is tick-gated because
//      rx_fifo_we is held high for a whole tick; without that gate one frame
//      used to push ~divisor copies.  Four more frames at divisor 3 sweep the
//      start edge across the whole baud tick, so the decode has to work at
//      every detection phase rather than one lucky one.
//   7. Receive interrupt: with IRQ_EN[1] set, one frame raises o_irq exactly
//      once (counted on rising edges), the level holds while the byte is
//      unread and falls when RX_DATA is read, and with the enable clear the
//      frame is still received but the interrupt stays quiet.
// =============================================================================
`timescale 1ns/1ps

module tb_uart_baud;

  localparam int CLK_FREQ  = 100_000_000;
  localparam int BAUD_RATE = 115_200;
  // Same expression as the DUT's DEFAULT_DIVISOR, so the expected reset value
  // cannot drift away from the RTL's.
  localparam int DEFAULT_D = CLK_FREQ / (BAUD_RATE * 16) - 1;   // 53

  localparam [31:0] ADDR_TX_DATA = 32'h00;
  localparam [31:0] ADDR_RX_DATA = 32'h04;
  localparam [31:0] ADDR_STATUS  = 32'h08;
  localparam [31:0] ADDR_CTRL    = 32'h0C;
  localparam [31:0] ADDR_IRQ_EN  = 32'h10;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic txd, irq;
  logic rxd = 1'b1;   // RX line, idle high between injected frames

  // AXI4-Lite slave side
  logic [31:0] awaddr = '0;
  logic        awvalid = 1'b0, awready;
  logic [31:0] wdata = '0;
  logic [3:0]  wstrb = '0;
  logic        wvalid = 1'b0, wready;
  logic [1:0]  bresp;
  logic        bvalid, bready = 1'b0;
  logic [31:0] araddr = '0;
  logic        arvalid = 1'b0, arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid, rready = 1'b0;

  c930_uart #(
    .CLK_FREQ  (CLK_FREQ),
    .BAUD_RATE (BAUD_RATE)
  ) dut (
    .i_clk        (clk),
    .i_rst_n      (rst_n),
    .o_uart_txd   (txd),
    .i_uart_rxd   (rxd),
    .o_irq        (irq),
    .s_axi_awaddr (awaddr),
    .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata  (wdata),
    .s_axi_wstrb  (wstrb),
    .s_axi_wvalid (wvalid),
    .s_axi_wready (wready),
    .s_axi_bresp  (bresp),
    .s_axi_bvalid (bvalid),
    .s_axi_bready (bready),
    .s_axi_araddr (araddr),
    .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .s_axi_rdata  (rdata),
    .s_axi_rresp  (rresp),
    .s_axi_rvalid (rvalid),
    .s_axi_rready (rready)
  );

  int errs = 0;

  // Free-running clock counter.  Every TX edge lands on a baud tick, which is
  // a clock edge, so differences of this counter are exact bit periods.
  int cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // IRQ rising-edge counter.  The RX interrupt is a level on "unread byte",
  // so "asserts once per frame" is a claim about edges: a stuck-high or
  // double-asserting line is invisible to a final-level check but shows here.
  int   irq_rises = 0;
  logic irq_prev  = 1'b0;
  always @(posedge clk) begin
    irq_prev <= irq;
    if (irq && !irq_prev)
      irq_rises <= irq_rises + 1;
  end

  // ---------------------------------------------------------------------------
  // Checks
  // ---------------------------------------------------------------------------
  task automatic check(input string what, input logic got, input logic want);
    begin
      if (got !== want) begin
        $display("  [FAIL] %s: got %0b, want %0b", what, got, want);
        errs = errs + 1;
      end else begin
        $display("  [PASS] %s", what);
      end
    end
  endtask

  task automatic check_val(input string what, input int got, input int want);
    begin
      if (got !== want) begin
        $display("  [FAIL] %s: got 0x%0h, want 0x%0h", what, got, want);
        errs = errs + 1;
      end else begin
        $display("  [PASS] %s", what);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // AXI4-Lite driver.  c930_uart accepts AW only in AXI_IDLE and W only in
  // AXI_WR, so the two channels are driven one after the other (asserting both
  // at once would re-accept the address when the FSM returns to IDLE).  Drive
  // on negedge, sample ready on posedge, so there is no set/sample race.
  // ---------------------------------------------------------------------------
  task automatic axi_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
    begin
      @(negedge clk);
      awaddr  = addr;
      awvalid = 1'b1;
      do @(posedge clk); while (!awready);
      @(negedge clk);
      awvalid = 1'b0;

      wdata  = data;
      wstrb  = strb;
      wvalid = 1'b1;
      do @(posedge clk); while (!wready);
      @(negedge clk);
      wvalid = 1'b0;

      do @(posedge clk); while (!bvalid);
      @(negedge clk);
      bready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      bready = 1'b0;
    end
  endtask

  task automatic axi_read(input [31:0] addr, output logic [31:0] data);
    begin
      @(negedge clk);
      araddr  = addr;
      arvalid = 1'b1;
      do @(posedge clk); while (!arready);
      @(negedge clk);
      arvalid = 1'b0;

      do @(posedge clk); while (!rvalid);
      data = rdata;
      @(negedge clk);
      rready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rready = 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Frame measurement
  //
  // Waits for the start bit's falling edge and then records the width of the
  // start bit and of each of the 8 data bits, plus the level each segment
  // starts at.  The stop bit is the 10th segment; it is not measured because
  // it merges into the idle-high line, but its edge is what sets levels[8].
  // ---------------------------------------------------------------------------
  int  widths[0:8];
  bit  levels[0:8];

  task automatic measure_frame(input int d, input [7:0] byte_val);
    int   i;
    int   t0;
    int   period;
    logic prev;
    bit   widths_ok;
    bit   levels_ok;
    begin
      period    = 16 * (d + 1);
      widths_ok = 1'b1;
      levels_ok = 1'b1;

      // Arm before the write: the FIFO can pop on the first baud tick after
      // TX_DATA is written, which may be inside the AXI transaction itself, so
      // a monitor started afterwards could miss the start bit.
      fork
        begin : wait_and_capture
          // Idle high first (the line is high between frames).
          while (txd !== 1'b1) @(posedge clk);
          // Start bit: falling edge.  #1 samples past the nonblocking update.
          do begin @(posedge clk); #1; end while (txd !== 1'b0);
          t0   = cyc;
          prev = 1'b0;

          // 9 further transitions: bit0..bit7 and the stop bit.
          for (i = 0; i < 9; i++) begin
            do begin @(posedge clk); #1; end while (txd === prev);
            widths[i] = cyc - t0;
            levels[i] = txd;
            t0        = cyc;
            prev      = txd;
          end
        end
        begin : send_byte
          axi_write(ADDR_TX_DATA, {24'd0, byte_val}, 4'hF);
        end
      join

      for (i = 0; i < 9; i++) begin
        if (widths[i] != period) begin
          $display("  [FAIL] divisor %0d: segment %0d is %0d clocks, want %0d",
                   d, i, widths[i], period);
          errs      = errs + 1;
          widths_ok = 1'b0;
        end
        // 0x55 is start=0 then 1,0,1,0,1,0,1,0 then stop=1: a segment that
        // starts at index i is high on even i, low on odd i.
        if (levels[i] !== ((i % 2) == 0)) begin
          $display("  [FAIL] divisor %0d: segment %0d starts %0b (byte 0x%02h not on the line)",
                   d, i, levels[i], byte_val);
          errs      = errs + 1;
          levels_ok = 1'b0;
        end
      end

      $display("  [INFO] divisor %0d: segment widths %0d %0d %0d %0d %0d %0d %0d %0d %0d clocks (want %0d)",
               d, widths[0], widths[1], widths[2], widths[3], widths[4],
               widths[5], widths[6], widths[7], widths[8], period);

      if (widths_ok)
        $display("  [PASS] divisor %0d: start + 8 data bits each %0d clocks (%0d ns)",
                 d, period, period * 10);
      if (levels_ok)
        $display("  [PASS] divisor %0d: start/8 data/stop pattern is 0x%02h",
                 d, byte_val);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Frame injection
  //
  // Drives one 8N1 frame onto i_uart_rxd at the programmed divisor: start bit,
  // 8 data bits LSB first, stop bit, each exactly 16 * (divisor + 1) clocks.
  // Edges land on negedge so they are a clean half cycle away from the posedge
  // where the DUT's synchroniser samples the pin.  Both bytes used below have
  // bit 7 = 0, so a stop sample that drifts back into the last data bit reads
  // 0 and drops the frame instead of accepting it silently.
  // ---------------------------------------------------------------------------
  task automatic rx_send_byte(input int d, input [7:0] byte_val, input int phase_clk);
    int period;
    int i;
    begin
      period = 16 * (d + 1);
      rxd = 1'b1;                        // idle high, line settled
      // phase_clk shifts the start edge relative to the free-running baud
      // counter, which picks where in a tick the receiver detects the frame.
      repeat (2 * period + phase_clk) @(negedge clk);
      rxd = 1'b0;                        // start bit
      repeat (period) @(negedge clk);
      for (i = 0; i < 8; i++) begin      // data, LSB first
        rxd = byte_val[i];
        repeat (period) @(negedge clk);
      end
      rxd = 1'b1;                        // stop bit
      repeat (period) @(negedge clk);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  initial begin : main
    logic [31:0] r;
    int ph;
    int rises_before;

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk); #1;

    $display("\n=== c930_uart baud divisor test ===");
    check("TXD idle high after reset", txd, 1'b1);
    check("no IRQ with both enables clear", irq, 1'b0);

    // 1. Reset value, and a frame at it.
    axi_read(ADDR_CTRL, r);
    check_val($sformatf("CTRL reset value is DEFAULT_DIVISOR (%0d)", DEFAULT_D), int'(r), DEFAULT_D);
    measure_frame(DEFAULT_D, 8'h55);

    // 2. Divisor 3 -> 4 clocks per tick, 64 clocks per bit.
    axi_write(ADDR_CTRL, 32'd3, 4'hF);
    axi_read(ADDR_CTRL, r);
    check_val("CTRL reads back the programmed divisor 3", int'(r), 3);
    measure_frame(3, 8'h55);

    // 3. Reprogram to 7 -> 128 clocks per bit.  Both periods must be right.
    axi_write(ADDR_CTRL, 32'd7, 4'hF);
    axi_read(ADDR_CTRL, r);
    check_val("CTRL reads back the reprogrammed divisor 7", int'(r), 7);
    measure_frame(7, 8'h55);

    // 4. Receive path.  RX shares baud_tick with TX, so the programmed divisor
    //    sets the receive sample grid too: this frame is driven at
    //    16 * (7 + 1) = 128 clocks per bit.  A receiver still on the reset
    //    divisor would sample in the wrong places and decode nothing.
    //    CTRL is already 7 from the TX section; rewrite it so this section
    //    does not depend on that.
    axi_write(ADDR_CTRL, 32'd7, 4'hF);
    rx_send_byte(7, 8'h55, 0);

    // The RX FIFO store is tick-gated and happens one baud tick after the stop
    // sample, so give it a few ticks before looking at STATUS.
    repeat (4 * 8) @(posedge clk);
    axi_read(ADDR_STATUS, r);
    check("RX: decoded frame is present (STATUS rx_empty = 0)", r[1], 1'b0);

    axi_read(ADDR_RX_DATA, r);
    check_val("RX: divisor 7 decoded 0x55", int'(r[7:0]), 8'h55);

    // Exactly one entry.  rx_fifo_we stays high for a whole tick period, so
    // the store has to be gated on baud_tick; with the store and the write
    // pointer both ungated one frame fills the FIFO with ~divisor copies and
    // a single read leaves it non-empty.
    axi_read(ADDR_STATUS, r);
    check("RX: one frame pushes exactly one byte (empty after one read)", r[1], 1'b1);

    // Second, at a different divisor (64 clocks per bit) and all-zero data:
    // after the start edge the stop bit is the only high level the receiver
    // sees, so accepting the frame shows the stop sample is inside the stop
    // bit.
    //
    // The sample grid is anchored to whichever baud tick first sees the start
    // bit, so the start edge's position within a tick decides where every
    // sample lands.  The sweep moves it across a whole tick (4 clocks at
    // divisor 3) and every phase has to decode, so the receiver cannot be
    // relying on one lucky alignment.  It does not prove the old cnt==7
    // stop sample is gone: that sample falls exactly on the stop bit's start
    // edge, so which value it sees turns on the sub-cycle phase, and
    // reintroducing it still passes these phases (measured).
    axi_write(ADDR_CTRL, 32'd3, 4'hF);
    for (ph = 0; ph < 4; ph++) begin
      rx_send_byte(3, 8'h00, ph);
      repeat (4 * 4) @(posedge clk);
      axi_read(ADDR_STATUS, r);
      check($sformatf("RX: d=3 phase %0d frame present", ph), r[1], 1'b0);

      axi_read(ADDR_RX_DATA, r);
      check_val($sformatf("RX: d=3 phase %0d decoded 0x00", ph), int'(r[7:0]), 8'h00);

      axi_read(ADDR_STATUS, r);
      check($sformatf("RX: d=3 phase %0d pushed exactly one byte", ph), r[1], 1'b1);
    end

    // A read with nothing queued must not invent a byte or change the level.
    axi_read(ADDR_RX_DATA, r);
    axi_read(ADDR_STATUS, r);
    check("RX: read on empty FIFO leaves it empty", r[1], 1'b1);

    // 5. Receive interrupt.  IRQ_EN[1] gates a level on "RX FIFO not empty",
    //    so one frame has to raise o_irq exactly once, hold it until the byte
    //    is consumed, and drop it when RX_DATA is read (the read pops the
    //    entry).  IRQ_EN[0] (TX done) stays clear so this is RX only.
    axi_write(ADDR_IRQ_EN, 32'h0000_0002, 4'hF);
    axi_read(ADDR_IRQ_EN, r);
    check_val("IRQ_EN reads back RX-enable only (0x2)", int'(r), 32'h2);
    check("IRQ: clear before a frame arrives", irq, 1'b0);

    rises_before = irq_rises;
    rx_send_byte(3, 8'hA5, 0);
    repeat (4 * 4) @(posedge clk);
    check("IRQ: high once the received byte lands", irq, 1'b1);
    check_val("IRQ: one rising edge for one frame", irq_rises - rises_before, 1);

    // A level, not a one-cycle pulse: an ISR that is slow to get there must
    // still see it, and the wait itself must not produce another edge.
    repeat (8 * 4) @(posedge clk);
    check("IRQ: still high with the byte unread", irq, 1'b1);
    check_val("IRQ: no extra edge while the byte sits", irq_rises - rises_before, 1);

    axi_read(ADDR_RX_DATA, r);
    check_val("IRQ: the byte behind the interrupt is 0xA5", int'(r[7:0]), 8'hA5);
    repeat (2) @(posedge clk);
    check("IRQ: clears when RX_DATA is read", irq, 1'b0);

    // Gated by IRQ_EN[1]: with the enable clear the frame is still received,
    // but the interrupt must stay quiet.
    axi_write(ADDR_IRQ_EN, 32'd0, 4'hF);
    rx_send_byte(3, 8'h3C, 0);
    repeat (4 * 4) @(posedge clk);
    check("IRQ: disabled, a frame raises nothing", irq, 1'b0);
    check_val("IRQ: disabled, no rising edge either", irq_rises - rises_before, 1);

    axi_read(ADDR_RX_DATA, r);
    check_val("IRQ: disabled, the byte is still received", int'(r[7:0]), 8'h3C);
    axi_read(ADDR_STATUS, r);
    check("IRQ: second byte consumed, FIFO empty", r[1], 1'b1);

    // 6. Byte strobes select the half of the divisor register that is written.
    axi_write(ADDR_CTRL, 32'h0000_BEEF, 4'hF);
    axi_read(ADDR_CTRL, r);
    check_val("full write sets CTRL = 0xBEEF", int'(r), 32'hBEEF);
    axi_write(ADDR_CTRL, 32'h0000_0011, 4'b0001);
    axi_read(ADDR_CTRL, r);
    check_val("WSTRB=0001 writes CTRL[7:0] only", int'(r), 32'hBE11);
    axi_write(ADDR_CTRL, 32'h0000_2200, 4'b0010);
    axi_read(ADDR_CTRL, r);
    check_val("WSTRB=0010 writes CTRL[15:8] only", int'(r), 32'h2211);

    // 7. Status is readable and TX is idle again by now.
    axi_read(ADDR_STATUS, r);
    check("STATUS: TX FIFO empty and not full", (r[0] === 1'b0) && (r[1] === 1'b1), 1'b1);

    repeat (4) @(posedge clk);
    // $fatal, not $finish: vvp has to leave a non-zero status so a failing run
    // cannot look like a pass to whatever invokes the bench.
    if (errs != 0)
      $fatal(1, "\n  UART BAUD DIVISOR TEST FAILED: %0d error(s)\n", errs);
    $display("\n  UART BAUD DIVISOR TEST PASSED\n");
    $finish;
  end

  // A DUT that never transmits would otherwise spin in the edge loops forever.
  initial begin : watchdog
    #2_000_000;
    $fatal(1, "\n  [FAIL] watchdog: no complete frame within 2 ms\n");
  end

endmodule
