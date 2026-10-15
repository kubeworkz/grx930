// chip_core_grx930.sv -- grx930 test chip inside the wafer.space project template.
//
// This file *replaces* the template's src/chip_core.sv (a 42-bit counter demo).
// The template's chip_top.sv -- the pad ring, the chip-ID QR code, the
// wafer.space logo, the marker cells -- is used unmodified, so the pad
// positions, the pad count/power-pad placement and the CoB marker cells are
// byte-identical to every other 1x1 submission. That is what keeps this part
// compatible with the standard breakout PCB and with the pre-check's CoB rules.
//
// Signal-to-pad assignment (see PAD_MAP.md for the table the dev board needs):
//
//   clk_pad        -> core clk          (dedicated in_s pad, south edge)
//   rst_n_pad      -> core rst_n        (dedicated in_c pad, south edge)
//   bidir[0]       -> i_uart_rxd        (pad input)
//   bidir[1]       -> o_uart_txd        (pad output)
//   bidir[2..5]    -> o_gpio[3:0]       (pad outputs, heartbeat)
//   bidir[6]       -> i_ext_irq         (pad input)
//   everything else-> tied off (inputs held low, outputs disabled)
//
// All eight board-facing signals sit on the SOUTH edge, on contiguous pads
// (clk, rst_n, then bidir[0..6]), so the custom development board -- the one
// that also carries the GPU and the photonic tensor accelerator -- can route
// them with a single fan-out off one die edge instead of reaching three sides.
//
// The template documents that the *number* of pads and the power/ground pads
// must not change for board compatibility; only signal-pad types are free.
// Nothing here changes the ring: the unused pads are still instantiated by
// chip_top and simply tied off in this wrapper.
//
// Clock: the template's chip_top.sdc and librelane/config.yaml use
// CLOCK_PERIOD 40 ns (25 MHz) on clk_pad/Y. CLK_FREQ/BAUD_DIV below match that
// clock, so the boot ROM's UART banner comes out at 115200 baud on silicon
// exactly as it does in simulation:
//   BAUD_DIV = 25e6 / 115200 = 217 clocks/bit = 115,207 baud (-0.006 %).
//
// The core itself is grx930_test_chip unchanged (RV64IMAC + 2 KB caches +
// 2 KB SRAM + UART + boot ROM at 0x0001_0000, which is CORE_RESET_PC, so the
// part boots standalone from the ROM as verified by `make sim
// SIM_PLUSARGS=+NO_PRELOAD`).

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS  = 12,      // from slot_defines.svh (SLOT_1X1)
    parameter NUM_BIDIR_PADS  = 40,
    parameter NUM_ANALOG_PADS = 2
) (
`ifdef USE_POWER_PINS
    // The core takes no power ports: LibreLane builds the PDN from PDN_CFG
    // (dir::pdn/pdn_cfg.tcl) and connects it to the standard cells directly.
    inout  wire VDD,
    inout  wire VSS,
`endif

    input  wire clk,        // from clk_pad (Schmitt-trigger input pad)
    input  wire rst_n,      // from rst_n_pad

    // Dedicated input pads (in_c): all unused by this design.
    input  wire [NUM_INPUT_PADS-1:0]  input_in,
    output wire [NUM_INPUT_PADS-1:0]  input_pu,
    output wire [NUM_INPUT_PADS-1:0]  input_pd,

    // Bidirectional pads (bi_24t): outputs, inputs, and tie-offs.
    input  wire [NUM_BIDIR_PADS-1:0]  bidir_in,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_out,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_oe,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_cs,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_sl,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_ie,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_pu,
    output wire [NUM_BIDIR_PADS-1:0]  bidir_pd,

    // Analog pads (asig_5p0): unused, left unbonded.
    inout  wire [NUM_ANALOG_PADS-1:0] analog
);

    // Core outputs, declared before the instance that drives them (this file is
    // compiled with `default_nettype none, so there are no implicit nets).
    logic        o_uart_txd;
    logic [3:0]  o_gpio;

    // ---------------------------------------------------------------------
    // Signal pads used by the core. Keep these indices in sync with PAD_MAP.md.
    // ---------------------------------------------------------------------
    localparam int P_UART_RX = 0;   // bidir[0]
    localparam int P_UART_TX = 1;   // bidir[1]
    localparam int P_GPIO0   = 2;   // bidir[2]
    localparam int P_GPIO3   = 5;   // bidir[5]  (= gpio[3:0] on 2..5)
    localparam int P_EXT_IRQ = 6;   // bidir[6]

    // Unused dedicated input pads: input buffer on, pad pulled down, so an
    // unconnected pad cannot float into the input buffer.
    assign input_pu = '0;
    assign input_pd = '1;

    // Pad control vectors. Each is built once in a combinational block and
    // assigned once: bit-wise continuous assignments to the same net's bits
    // (a blanket '1 plus a per-bit override) are multiple drivers, and the
    // conflicting bit resolves to X -- a pad with an unknown output enable.
    // tb_chip_core_grx930 checks these vectors bit by bit.
    logic [NUM_BIDIR_PADS-1:0] oe_q, pd_q, out_q;

    always_comb begin
        // Defaults for every pad this design does not use: output driver off,
        // input buffer on, no pull-up, pull-down so nothing floats.
        oe_q  = '0;
        pd_q  = '1;
        out_q = '0;

        // uart_tx: pad output.
        oe_q [P_UART_TX]   = 1'b1;
        pd_q [P_UART_TX]   = 1'b0;
        out_q[P_UART_TX]   = o_uart_txd;

        // gpio[3:0]: pad outputs (heartbeat LED on the board).
        oe_q [P_GPIO0 +: 4] = 4'b1111;
        pd_q [P_GPIO0 +: 4] = 4'b0000;
        out_q[P_GPIO0 +: 4] = o_gpio;

        // uart_rx and ext_irq: pad inputs -- a driven pad must not be pulled
        // down, so clear PD on exactly those two.
        pd_q [P_UART_RX]   = 1'b0;
        pd_q [P_EXT_IRQ]   = 1'b0;
    end

    assign bidir_oe  = oe_q;
    assign bidir_pd  = pd_q;
    assign bidir_out = out_q;
    // Same convention as the template's own chip_core: the input buffer is on
    // wherever this design reads the pad, off on pads it drives.
    assign bidir_ie  = ~oe_q;
    assign bidir_cs  = '0;                // CMOS buffer, not Schmitt
    assign bidir_sl  = '1;                // 1 = slow slew rate
    assign bidir_pu  = '0;                // no pull-up anywhere

    // ---------------------------------------------------------------------
    // The core, unchanged
    // ---------------------------------------------------------------------
    grx930_test_chip #(
        .CLK_FREQ (25_000_000),    // must match CLOCK_PERIOD 40 ns in config.yaml
        .BAUD_DIV (25_000_000 / 115_200)
    ) u_core (
        .i_clk      (clk),
        .i_rst_n    (rst_n),
        .o_uart_txd (o_uart_txd),
        .i_uart_rxd (bidir_in[P_UART_RX]),
        .o_gpio     (o_gpio),
        .i_ext_irq  (bidir_in[P_EXT_IRQ])
    );

    // Unused inputs and the `analog` pads are intentionally left unread; the
    // template's config.yaml already lists what it tolerates as disconnected
    // (IGNORE_DISCONNECTED_MODULES), and this keeps the vectors from being
    // optimised into nothing before the pad ring is placed.
    logic _unused;
    assign _unused = &{1'b0, input_in, bidir_in, analog};

endmodule

`default_nettype wire
