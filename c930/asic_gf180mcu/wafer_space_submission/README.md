# GRX930 Test Chip - wafer.space Submission Package

## Chip Specifications

| Property | Value |
|----------|-------|
| **Design Name** | grx930_test_chip |
| **Process** | GlobalFoundries GF180MCU (180nm) |
| **Die Size** | 3930 × 5120 µm (wafer.space 1×1 slot) |
| **Core Area** | 3920 × 5100 µm (12.92 mm²) |
| **Standard Cell Library** | gf180mcu_fd_sc_mcu7t5v0 |
| **Metal Stack** | 5LM_1TM_11K |
| **Cell Count** | 4,088 (after synthesis) |
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
- **Target Frequency**: 50 MHz (20 ns period)
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

## Files in This Package

- `grx930_test_chip_final.gds` - Final GDS-II layout (77 MB)
- `grx930_test_chip.def` - Design Exchange Format with routing
- `grx930_test_chip_routed.v` - Gate-level netlist with routing
- `cells.lef` - Standard cell library LEF
- `verify_layers.py` - Layer verification script
- `README.md` - This file

## Verification Steps

1. Run layer verification:
   ```bash
   python3 verify_layers.py grx930_test_chip_final.gds
   ```

2. Check DRC violations in DEF:
   ```bash
   grep -c "DRC" grx930_test_chip.def
   ```

## Notes

- This is a test chip design for validating the GF180MCU open-source PDK flow
- The design uses no-CTS flow to work around OpenROAD DRT-0073 limitation
- For production chips with tight timing, CTS should be enabled via OpenLane2

## Contact

For questions about this design, contact the GRX930 development team.
