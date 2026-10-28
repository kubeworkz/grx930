// ---------------------------------------------------------------------------
// gf180mcu_fd_ip_sram__sram512x8m8wm1.v -- simulation model for the GF180MCU
// 5 V SRAM macro.
//
// The PDK ships this macro as LEF/GDS/lib plus a (* blackbox *) Verilog stub
// (`...__blackbox_pp.v`), which is what the flow's MACROS declaration gives
// yosys and openroad. A blackbox cannot be simulated, so this file is the
// functional model for the RTL testbench: same port list, same cycle
// behaviour, no timing.
//
// Behaviour, from the macro's datasheet pins:
//   * CEN  active low  -- 0 enables the port for this clock edge
//   * GWEN active low  -- 0 = write, 1 = read
//   * WEN  active low, per bit -- a bit is written where WEN[i] == 0, and the
//          bits where WEN[i] == 1 keep their old value (byte-mask write)
//   * Q    registered: the read data appears in the cycle AFTER the edge that
//          sampled CEN/GWEN/A, which is why a line fill takes four beats.
//
// Contents start as X, as the real macro's do: nothing can preload them, so a
// design that reads before writing sees X in simulation exactly as it would
// see undefined silicon state.
// ---------------------------------------------------------------------------

module gf180mcu_fd_ip_sram__sram512x8m8wm1 (
    input  wire       CLK,
    input  wire       CEN,
    input  wire       GWEN,
    input  wire [7:0] WEN,
    input  wire [8:0] A,
    input  wire [7:0] D,
    output reg  [7:0] Q,
    inout  wire       VDD,
    inout  wire       VSS
);

  reg [7:0] mem [0:511];

  integer i;

  always @(posedge CLK) begin
    if (!CEN) begin
      if (!GWEN) begin
        for (i = 0; i < 8; i = i + 1)
          if (!WEN[i])
            mem[A][i] <= D[i];
      end else begin
        Q <= mem[A];
      end
    end
  end

endmodule
