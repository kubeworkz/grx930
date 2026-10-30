// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// tb_grx930_test_chip.sv -- chip-level boot testbench for grx930_test_chip.
//
// This is the testbench asic_gf180mcu/Makefile's `sim` target compiles
// (`../tb/tb_grx930_test_chip.sv`, which did not exist before: the target had
// nothing to build). It boots the real chip top -- core, both caches, the SRAM,
// the UART and the heartbeat counter -- and checks what a boot must produce:
//
//   1. the UART sends the firmware's banner "GRX930 OK\n", decoded here from
//      o_uart_txd at the DUT's own divisor (so this also proves the MMIO write
//      path, the baud generator and the pin timing),
//   2. the firmware's store/load-back pair agrees: 0x2A5A_1234 at SRAM 0x400
//      (D-cache write-through into the SRAM, read back through a load),
//   3. the firmware got that far: 0x0000_C0DE at SRAM 0x408,
//   4. the heartbeat counter is running (the clock is alive and the chip is not
//      stuck in reset).
//
// HOW THE PROGRAM GETS IN: grx930_test_chip boots from grx930_test_chip_rom, a
// 1 KB constant ROM based at 0x0001_0000 -- the address CORE_RESET_PC holds.
// The ROM is generated from the same ../sw/test_chip_boot.hex this testbench
// reads and holds the whole program, so the part needs nothing external at
// power-on. Execution therefore never touches SRAM 0x0, and the SRAM image this
// testbench preloads (dut.u_sram.mem) is an extra state rather than the boot
// source: the test passes with and without it.
//
// `+NO_PRELOAD` skips that preload and is the run that matches silicon: an
// untouched SRAM with the ROM as the only code. It must PASS -- if it does not,
// the ROM (or its mux into the caches) is broken. The negative control is now
// to zero the ROM instead: compile with -DROM_DISABLE (the generator emits a
// zeroed table under that define) and run +NO_PRELOAD, which must FAIL because
// then no code exists anywhere. That pair is what proves the PASS comes from
// the ROM and not from some incidental execution path.
//
// The older c930_bootrom/bootrom_wrapper pair is still unused: the OL2 run
// drops it as unreachable (see the Makefile's SIM_UNUSED_ROM note).
//
// Run:
//   iverilog -g2012 -o vvp_out grx930_test_chip sources... ../tb/tb_grx930_test_chip.sv
//   vvp vvp_out                                   # boots (SRAM also preloaded), PASS
//   vvp vvp_out +NO_PRELOAD                       # ROM-only boot, PASS
//   vvp vvp_out +FW=<path>                        # firmware image override
//   (compile with -DROM_DISABLE, then +NO_PRELOAD: must FAIL)
//
// FW_HEX default note: the file is opened relative to the working directory, so
// both the Makefile's `../sw/...` and a repo-root `sw/...` invocation work.
`timescale 1ns/1ps
module tb_grx930_test_chip #(
    // CLK_FREQ only sets the DUT's UART divisor (CLK_FREQ/(BAUD_RATE*16)-1), so
    // a low value here is a pure simulation-speed choice: the logic is the same
    // as the 50 MHz part. BIT_CLKS reproduces the DUT's bit period exactly.
    parameter int CLK_FREQ  = 2_000_000,
    parameter int BAUD_RATE = 115_200,
    parameter int WATCHDOG  = 200_000,      // clocks before giving up on the banner
    parameter int SRAM_WORDS = 256          // 2 KB / 8 bytes, grx930_sram_64kb
) ();

  localparam int BIT_CLKS = 16 * (CLK_FREQ / (BAUD_RATE * 16));   // == divisor+1 ticks
  localparam int BIT_NS   = BIT_CLKS * 10;                        // 10 ns clock period
  localparam int MAX_IMG  = 4096;

  localparam int    MAGIC_ADDR   = 1024;  // 0x400
  localparam int    MARK_ADDR    = 1032;  // 0x408
  localparam [31:0] EXP_MAGIC_LO = 32'h2A5A_1234;
  localparam [63:0] EXP_MARK     = 64'h0000_0000_0000_C0DE;
  // "GRX930 OK\n" as bytes, compared as a packed vector: string literals and
  // %c formatting carry tool-specific escape handling, bytes do not.
  localparam int    EXP_LEN      = 10;
  localparam [79:0] EXP_BYTES    = {8'h47, 8'h52, 8'h58, 8'h39, 8'h33,
                                    8'h30, 8'h20, 8'h4f, 8'h4b, 8'h0a};

  logic        clk = 1'b0;
  logic        rst_n = 1'b0;
  logic        uart_txd;
  logic        uart_rxd = 1'b1;   // idle high
  logic [3:0]  gpio;
  logic        ext_irq = 1'b0;

  int          errors = 0;
  byte         rx_b [0:255];      // decoded UART bytes, in arrival order
  int          rx_len = 0;
  bit          banner_seen = 1'b0;

  grx930_test_chip #(
      .CLK_FREQ (CLK_FREQ)
  ) dut (
      .i_clk      (clk),
      .i_rst_n    (rst_n),
      .o_uart_txd (uart_txd),
      .i_uart_rxd (uart_rxd),
      .o_gpio     (gpio),
      .i_ext_irq  (ext_irq)
  );

  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // Firmware image
  // -------------------------------------------------------------------------
  logic [31:0] img [0:MAX_IMG-1];
  int          nwords = 0;
  string       fw_path;

  // Read the hex image from an open file descriptor into img[].
  function automatic bit load_fd(input int fd);
    logic [31:0] w;
    nwords = 0;
    while (!$feof(fd) && nwords < MAX_IMG) begin
      if ($fscanf(fd, "%h\n", w) == 1) begin
        img[nwords] = w;
        nwords++;
      end
    end
    $fclose(fd);
    return (nwords > 0);
  endfunction

  // $fopen is called with the literal paths here, not through a string-typed
  // parameter: iverilog 11 warns (and some builds misbehave) when a `string`
  // argument reaches $fopen as a VPI string variable.
  function automatic bit open_fw();
    int          fd;
    logic [8*256-1:0] p;
    if ($value$plusargs("FW=%s", p)) begin
      fd = $fopen(p, "r");
      if (fd != 0 && load_fd(fd)) begin fw_path = p; return 1'b1; end
    end
    fd = $fopen("../sw/test_chip_boot.hex", "r");
    if (fd != 0 && load_fd(fd)) begin fw_path = "../sw/test_chip_boot.hex"; return 1'b1; end
    fd = $fopen("sw/test_chip_boot.hex", "r");
    if (fd != 0 && load_fd(fd)) begin fw_path = "sw/test_chip_boot.hex"; return 1'b1; end
    fd = $fopen("../c930/sw/test_chip_boot.hex", "r");
    if (fd != 0 && load_fd(fd)) begin fw_path = "../c930/sw/test_chip_boot.hex"; return 1'b1; end
    fd = $fopen("test_chip_boot.hex", "r");
    if (fd != 0 && load_fd(fd)) begin fw_path = "test_chip_boot.hex"; return 1'b1; end
    return 1'b0;
  endfunction

  task automatic preload_sram();
`ifdef USE_SRAM_MACRO
    // The macro-backed storage has no flop array to poke: its contents are the
    // macro's own X state, as silicon's are. The ROM is the boot source and the
    // firmware writes the SRAM before it reads it, so the preload is not
    // needed -- this configuration must boot and pass without it.
    $display("[info] USE_SRAM_MACRO: SRAM preload skipped (foundry macro storage)");
`else
    logic [31:0] hi;
    for (int i = 0; i < SRAM_WORDS; i++)
      dut.u_sram.mem[i] = 64'd0;
    for (int i = 0; i < nwords; i += 2) begin
      hi = (i + 1 < nwords) ? img[i+1] : 32'd0;
      dut.u_sram.mem[i >> 1] = {hi, img[i]};      // little-endian word pair
    end
    $display("[info] firmware %s: %0d words (%0d bytes) into SRAM", fw_path, nwords, nwords * 4);
`endif
  endtask

  // -------------------------------------------------------------------------
  // UART receiver: 1 start bit, 8 data bits LSB first, 1 stop bit, no parity.
  // Sampling is mid-bit at the DUT's exact bit period, so it cannot drift.
  // -------------------------------------------------------------------------
  // Rebuild the last EXP_LEN bytes as one vector so the comparison needs no
  // string handling.
  function automatic logic [79:0] tail_bytes();
    logic [79:0] v = 80'b0;
    for (int k = 0; k < EXP_LEN; k++)
      v = {v[71:0], rx_b[rx_len - EXP_LEN + k]};
    return v;
  endfunction

  // Short hex dump of what the UART has sent so far, for failure messages.
  function automatic string rx_dump(input int n);
    string s = "";
    int    from = (rx_len > n) ? (rx_len - n) : 0;
    for (int k = from; k < rx_len; k++)
      s = {s, $sformatf("%02x ", rx_b[k])};
    return s;
  endfunction

  initial begin : uart_rx
    int bitv;
    byte ch;
    forever begin
      @(negedge uart_txd);                 // start bit
      #(BIT_NS / 2.0);
      if (uart_txd !== 1'b0) begin
        $display("[fail] uart: start bit not held at mid-bit");
        errors++;
      end else begin
        ch = 8'h00;
        for (bitv = 0; bitv < 8; bitv++) begin
          #(BIT_NS);
          ch[bitv] = uart_txd;
        end
        #(BIT_NS);
        if (uart_txd !== 1'b1) begin
          $display("[fail] uart: stop bit low after byte %02x", ch);
          errors++;
        end else begin
          $display("[uart] byte 0x%02x", ch);
          if (rx_len < 256) begin
            rx_b[rx_len] = ch;
            rx_len++;
          end
          if (rx_len >= EXP_LEN)
            banner_seen = (tail_bytes() == EXP_BYTES);
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Checks
  // -------------------------------------------------------------------------
  int hb_first;

  // One 64-bit word of the chip's SRAM, whichever storage backs it. The FF
  // configuration is one array; the macro bank is eight byte-wide macros, so a
  // word is assembled from theirs -- written out because a hierarchical name
  // cannot be indexed.
`ifdef USE_SRAM_MACRO
  function automatic logic [63:0] sram_word(input int idx);
    return {dut.u_sram.u_macro_7.mem[idx], dut.u_sram.u_macro_6.mem[idx],
            dut.u_sram.u_macro_5.mem[idx], dut.u_sram.u_macro_4.mem[idx],
            dut.u_sram.u_macro_3.mem[idx], dut.u_sram.u_macro_2.mem[idx],
            dut.u_sram.u_macro_1.mem[idx], dut.u_sram.u_macro_0.mem[idx]};
  endfunction
`else
  function automatic logic [63:0] sram_word(input int idx);
    return dut.u_sram.mem[idx];
  endfunction
`endif

  task automatic check_magic();
    automatic logic [63:0] got = sram_word(MAGIC_ADDR / 8);
    if (got !== {32'd0, EXP_MAGIC_LO}) begin
      $display("[fail] SRAM 0x%0h: got 0x%0h expected 0x%0h (D-cache write-through / load)",
               MAGIC_ADDR, got, {32'd0, EXP_MAGIC_LO});
      errors++;
    end else begin
      $display("[ok  ] SRAM 0x%0h holds 0x%0h (store through the D-cache, read back)",
               MAGIC_ADDR, got);
    end
  endtask

  task automatic check_mark();
    automatic logic [63:0] got = sram_word(MARK_ADDR / 8);
    if (got !== EXP_MARK) begin
      $display("[fail] SRAM 0x%0h: got 0x%0h expected 0x%0h (firmware did not reach its marker)",
               MARK_ADDR, got, EXP_MARK);
      errors++;
    end else begin
      $display("[ok  ] SRAM 0x%0h holds 0x%0h (firmware ran to completion)", MARK_ADDR, got);
    end
  endtask

  int elapsed;
  initial begin
    if (!open_fw()) begin
      // The hex is generated (c930/sw/*.hex is gitignored), so a fresh checkout
      // needs `make fw` before this test can run.
      $display("RESULT: FAIL (no firmware image; tried +FW, ../sw/, sw/ — build it with 'make fw')");
      $fatal(1, "tb_grx930_test_chip: firmware image missing");
    end

    $display("== tb_grx930_test_chip: CLK_FREQ=%0d Hz, BIT_CLKS=%0d (%0d ns), watchdog %0d clks ==",
             CLK_FREQ, BIT_CLKS, BIT_NS, WATCHDOG);
    $display("== expected banner: %0d bytes, 0x%020x (\"GRX930 OK<LF>\") ==", EXP_LEN, EXP_BYTES);

    rst_n = 1'b0;
    repeat (20) @(posedge clk);

    if ($test$plusargs("NO_PRELOAD")) begin
      $display("[info] +NO_PRELOAD: SRAM left as it powers up (this is the control run)");
    end else begin
      preload_sram();
    end

    hb_first = dut.heartbeat_cnt;
    @(posedge clk);
    rst_n = 1'b1;

    // Wait for the banner (or time out), then let the firmware finish its SRAM
    // store/load and marker.
    elapsed = 0;
    while (!banner_seen && elapsed < WATCHDOG) begin
      @(posedge clk);
      elapsed++;
    end

    if (!banner_seen) begin
      errors++;
      $display("[fail] no complete banner after %0d clocks (%0d byte(s) received)",
               elapsed, rx_len);
      $display("[fail]   expected 0x%020x", EXP_BYTES);
      $display("[fail]   received %s", rx_dump(EXP_LEN));
    end else begin
      $display("[ok  ] banner received after %0d clocks: %s", elapsed, rx_dump(EXP_LEN));
    end

    repeat (2000) @(posedge clk);   // marker stores lag the last UART byte

    check_magic();
    check_mark();

    if (dut.heartbeat_cnt == hb_first) begin
      $display("[fail] heartbeat counter did not advance (0x%0h)", hb_first);
      errors++;
    end else begin
      $display("[ok  ] heartbeat counter running (0x%0h -> 0x%0h)", hb_first, dut.heartbeat_cnt);
    end

    if (errors == 0) begin
      $display("RESULT: PASS (chip booted: banner received, SRAM store/load agreed, heartbeat alive)");
      $finish;
    end else begin
      $display("RESULT: FAIL (%0d error(s), %0d UART byte(s) received)", errors, rx_len);
      $fatal(1, "tb_grx930_test_chip: boot test failed");
    end
  end

  // Simulation-wide timeout, so a hang reports instead of running forever.
  initial begin
    #(WATCHDOG * 40);
    $display("RESULT: FAIL (timeout: no completion in %0d clocks)", WATCHDOG);
    $fatal(1, "tb_grx930_test_chip: timeout");
  end

endmodule
