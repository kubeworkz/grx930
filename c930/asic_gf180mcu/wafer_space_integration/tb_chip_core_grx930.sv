// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// tb_chip_core_grx930.sv -- elaboration + pad-wiring check for the wafer.space
// chip_core adapter. Not a functional test (the core has its own boot test in
// c930/tb/tb_grx930_test_chip.sv); this one exists so that a pad-count or
// port-name mistake in the adapter is caught locally in seconds, before it
// costs an hour inside a LibreLane run.
//
// Checks, in order:
//   1. chip_core elaborates with the SLOT_1X1 pad counts (12/40/2 -- the
//      numbers slot_defines.svh defines), i.e. the adapter's interface matches
//      what the template's chip_top drives;
//   2. the pad tie-off policy is what PAD_MAP.md says: outputs disabled on
//      every bidir pad except uart_tx (bidir[1]) and gpio (bidir[2..5]), which
//      drive bidir_out; pull-downs set everywhere except the two pad inputs and
//      the driven outputs; unused input pads pulled down;
//   3. toggling the pad inputs moves the core's uart input and interrupt input
//      (i.e. the mapping is live, not tied to a constant).

`timescale 1ns/1ps
module tb_chip_core_grx930;

  localparam int NI = 12;
  localparam int NB = 40;
  localparam int NA = 2;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic [NI-1:0] input_in = '0;
  wire  [NI-1:0] input_pu, input_pd;
  logic [NB-1:0] bidir_in = '0;
  wire  [NB-1:0] bidir_out, bidir_oe, bidir_cs, bidir_sl, bidir_ie, bidir_pu, bidir_pd;
  wire  [NA-1:0] analog;

  int errors = 0;
  task automatic ck(input logic cond, input string what);
    begin
      if (!cond) begin
        $display("[FAIL] %s", what);
        errors++;
      end else begin
        $display("[ok  ] %s", what);
      end
    end
  endtask

  chip_core #(
      .NUM_INPUT_PADS  (NI),
      .NUM_BIDIR_PADS  (NB),
      .NUM_ANALOG_PADS (NA)
  ) dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .input_in   (input_in),
      .input_pu   (input_pu),
      .input_pd   (input_pd),
      .bidir_in   (bidir_in),
      .bidir_out  (bidir_out),
      .bidir_oe   (bidir_oe),
      .bidir_cs   (bidir_cs),
      .bidir_sl   (bidir_sl),
      .bidir_ie   (bidir_ie),
      .bidir_pu   (bidir_pu),
      .bidir_pd   (bidir_pd),
      .analog     (analog)
  );

  logic [NB-1:0] oe_expect, pd_expect;

  initial begin
    // Expected tie-off (PAD_MAP.md): outputs on 1 and 2..5 only.
    oe_expect = '0;
    oe_expect[1]     = 1'b1;      // uart_tx
    oe_expect[5:2]   = 4'b1111;   // gpio[3:0]
    pd_expect = '1;                 // unused pads held low
    pd_expect[1]     = 1'b0;      // driven output
    pd_expect[5:2]   = 4'b0000;   // driven outputs
    pd_expect[0]     = 1'b0;      // uart_rx (pad input)
    pd_expect[6]     = 1'b0;      // ext_irq (pad input)

    #1;
    ck(bidir_oe === oe_expect, $sformatf("bidir_oe ties off all but tx/gpio (0x%0h)", bidir_oe));
    ck(bidir_pd === pd_expect, $sformatf("bidir_pd pulls down unused pads only (0x%0h)", bidir_pd));
    ck(bidir_ie === ~oe_expect, "bidir input buffer on exactly where the pad is not driven");
    ck(bidir_sl === '1,   "bidir slew rate set to slow");
    ck(bidir_cs === '0,   "bidir buffers are CMOS, not Schmitt");
    ck(bidir_pu === '0,   "bidir pull-ups off");
    ck(input_pu === '0,   "unused input pads: no pull-up");
    ck(input_pd === '1,   "unused input pads: pull-down on");
    ck(bidir_out[1] === dut.u_core.o_uart_txd, "uart_tx pad carries the core's UART TX");
    ck(bidir_out[5:2] === dut.u_core.o_gpio,   "gpio pads carry the core's heartbeat output");

    // The pad inputs reach the core: read back the core's own port nets, which
    // is what proves the mapping is wired and not tied to a constant.
    bidir_in[6] = 1'b1;
    bidir_in[0] = 1'b1;
    #1;
    ck(dut.u_core.i_ext_irq === 1'b1, "bidir[6] reaches the core's external interrupt input");
    ck(dut.u_core.i_uart_rxd === 1'b1, "bidir[0] reaches the core's UART RX input");
    bidir_in[6] = 1'b0;
    bidir_in[0] = 1'b0;
    #1;
    ck(dut.u_core.i_ext_irq === 1'b0, "bidir[6] follows the pad down again");

    if (errors == 0) begin
      $display("RESULT: PASS (chip_core adapter elaborates and the pad map is live)");
      $finish;
    end else begin
      $display("RESULT: FAIL (%0d error(s))", errors);
      $fatal(1, "tb_chip_core_grx930");
    end
  end

endmodule
