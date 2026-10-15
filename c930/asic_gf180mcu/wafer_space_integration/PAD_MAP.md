# Pad map — grx930 test chip on the wafer.space 1×1 pad ring

The ring itself is **not ours to change**: `chip_top.sv` + `librelane/slots/slot_1x1.yaml`
place the same pads in the same positions as every other 1×1 submission, which is what
keeps the part compatible with the standard breakout PCB (and with the pre-check's pad
openings / CoB rules). What this file fixes is the *signal* assignment on those pads —
the contract the custom development board (grx930 + GPU + photonic tensor accelerator)
must follow.

Assignment lives in [`chip_core_grx930.sv`](chip_core_grx930.sv) (indices
`P_UART_RX`…`P_EXT_IRQ`); the check in
[`tb_chip_core_grx930.sv`](tb_chip_core_grx930.sv) fails if the two ever disagree.

## Signals

| Pad (`slot_1x1.yaml`) | Core signal | Dir | Notes |
|---|---|---|---|
| `clk_pad` | `i_clk` | in | `in_s` Schmitt pad. 25 MHz — `CLOCK_PERIOD 40`, and the adapter passes `CLK_FREQ 25_000_000` so the UART stays at 115200 baud |
| `rst_n_pad` | `i_rst_n` | in | `in_c` pad, active low |
| `bidir[0].pad` | `i_uart_rxd` | in | pad PD cleared (externally driven) |
| `bidir[1].pad` | `o_uart_txd` | out | boot banner `GRX930 OK\n` at 115200 baud |
| `bidir[2..5].pad` | `o_gpio[3:0]` | out | heartbeat counter bits — the "is it alive" LED |
| `bidir[6].pad` | `i_ext_irq` | in | the core's only interrupt input |
| `bidir[7..39].pad` | — | — | `oe=0, ie=1, pd=1` (input buffer on, output off, held low) |
| `inputs[0..11].pad` | — | — | `pd=1` (dedicated `in_c` pads, unused) |
| `analog[0..1].pad` | — | — | `asig_5p0`, unbonded |
| power | — | — | 6 `DVDD` / 8 `DVSS` / 2 `VDD` / 2 `VSS`, positions per `slot_1x1.yaml` |

All eight board-facing signals are on the **south edge**, in this physical order
(from `PAD_SOUTH` in `slot_1x1.yaml`):

```
clk_pad, rst_n_pad, bidir[0..5], dvss[0], bidir[6..13]
                     ^^^^^^^^^^^^          ^^^^^^^^
                     rx, tx, gpio[3:0]     ext_irq
```

so uart_rx/uart_tx/gpio[3:0] come out as six contiguous pads immediately after clock
and reset, and the interrupt line is the first signal pad past the DVSS pad
(`bidir[6]`). The rest of the ring is unused: one die edge is enough to bring up the
part on a board, which is the point of grouping them.

## Power

`chip_top.sv` shorts the core and I/O domains (`assign VDD = DVDD; assign VSS = DVSS;`)
for the foundry pads, so the board supplies the ring's DVDD/DVSS pairs and the core
domain follows. PDN straps/rings come from the template's `pdn/pdn_cfg.tcl` —
unchanged, as the pre-check expects the same power structure as other 1×1 parts.

## What the board must not do

* Do not add a second driver on `bidir[1]`/`bidir[2..5]` (pad outputs) — those pads
  have `ie=0` so there is no loop, but the board should leave them as inputs only if
  it wants to read them (it cannot: the input buffer is off).
* Do not expect `bidir[7..39]` / `inputs[0..11]` to be high-impedance: they are held
  low by the pad's own pull-down.
* The interrupt input is level/edge sensitive per the core's CSR configuration; the
  firmware image in the ROM does not enable it, so `bidir[6]` is a hook for later
  firmware, not something the boot test exercises.
