# GRX930 Test Chip - wafer.space Submission Package

> **VOID — DO NOT SUBMIT.** This entire package is built from the pre-fix
> 21 September synthesis and is superseded in full; [SUPERSEDED.md](SUPERSEDED.md)
> says why. Its GDS, README, checklist and numbers are historical and must not
> be used for the current part.
>
> **Current die-size authority:** `build/lvs_chip/rebased_grx930_test_chip.def`,
> `DIEAREA ( 0 0 ) ( 7864000 10244000 )` at 2000 dbu/µm = **3932 × 5122 µm**.
> The old **3930 × 5120 µm** figure is retired and is not the current die size.
> Other current figures: [the one-pager](../wafer_space_status_onepager.md).

## Chip Specifications — VOID ARTIFACT

The table describes the void September artifact, not the current part. The current
**die** is defined by the DEF `DIEAREA`: **3932 × 5122 µm** (see the banner above).

| Property | Value |
|----------|-------|
| **Package status** | **VOID — DO NOT SUBMIT** |
| **Design Name** | grx930_test_chip |
| **Process** | GlobalFoundries GF180MCU (180nm) |
| **Die Size (current design authority)** | **3932 × 5122 µm** — from `build/lvs_chip/rebased_grx930_test_chip.def` `DIEAREA`; not a measurement of this VOID GDS |
| **Core Area** | 3048 × 4238 µm = 12.93 mm² (current one-pager; core is not defined by DEF `DIEAREA`) |
| **Standard Cell Library** | gf180mcu_fd_sc_mcu7t5v0 |
| **Metal Stack** | 5LM_1TM_11K |
| **Cell Count** | 4,088 (after synthesis — the SRAM array was dead logic; see [SUPERSEDED.md](SUPERSEDED.md)) |
| **Routing Violations** | 0 |
| **Total Vias** | 409,399 |

## Design Description

The GRX930 is a 64-bit RISC-V processor (RV64IMAC) with:
- UART interface for communication
- Boot ROM for startup
- GPIO peripherals
- Timer subsystem

## Clock Configuration

- **Clock Port**: `i_clk`
- **Target Frequency**: 50 MHz (20 ns period) — as built for this void GDS;
  the current part targets 25 MHz (40 ns)
- **CTS Status**: Skipped (flat clock routing) to avoid DRT-0073 pin access limitation
- **Clock Skew**: Not balanced (acceptable for test chip)

## Pin Assignments

| Pin | Direction | Description |
|-----|-----------|-------------|
| `i_clk` | Input | System clock |
| `i_rst_n` | Input | Active-low reset |
| `i_uart_rx` | Input | UART receive |
| `o_uart_tx` | Output | UART transmit |
| `io_gpio[31:0]` | Bidirectional | General purpose I/O |

## Files in This Package — VOID

These are the only files in this directory. The package does **not** contain a
`.def`, a routed Verilog netlist, or a `cells.lef`; do not expect them here.

- `grx930_test_chip_final.gds` — **VOID** GDS-II layout; **77,083,214 bytes (73.51 MiB)**
- `grx930_test_chip_with_seal.gds` — **VOID** GDS-II layout with seal ring; **77,083,634 bytes (73.51 MiB)**
- `README.md` — this file
- `SUPERSEDED.md` — why the package is VOID
- `submission_checklist.md` — historical checklist, marked VOID
- `verify_layers.py` — layer/die diagnostic; it reads the current DEF `DIEAREA`
- `list_layers.py` — layer listing helper
- `generate_seal_ring.py` — historical seal-ring helper

**Expected GDS sizes:** approximately **77.08 MB decimal / 73.51 MiB** each.
There is no separate 77 MB “final DEF” artifact in this package.

## Verification Steps

1. Run the VOID diagnostic:
   ```bash
   python3 verify_layers.py grx930_test_chip_final.gds
   ```

   The checker reads the current DEF `DIEAREA` from
   `build/lvs_chip/rebased_grx930_test_chip.def`. This VOID GDS is expected to
   fail die containment because its content origin is negative; that failure is
   diagnostic, not an approval.

2. List the GDS layers:
   ```bash
   python3 list_layers.py grx930_test_chip_final.gds
   ```

## Notes

- This is a test chip design for validating the GF180MCU open-source PDK flow
- The design uses no-CTS flow to work around OpenROAD DRT-0073 limitation
- For production chips with tight timing, CTS should be enabled via OpenLane2

## Contact

For questions about this design, contact the GRX930 development team.
