# GRX930 Test Board — KiCad Hardware Project

**Version:** 1.0  
**Date:** September 17, 2026  
**Target Package:** QFN-64 (SKY130 die on PCB interposer)  
**Board Size:** 100mm × 100mm (4" × 4")

---

## Project Overview

This KiCad project contains the schematic and PCB design for the GRX930 prototype test board. The board provides:

- **QFN-64 socket** for the packaged GRX930 die
- **USB-to-UART bridge** (FTDI FT2232H) for serial console
- **JTAG interface** for debug and scan-chain access
- **Multi-rail power supply** with sequencing (1.8V core, 3.3V I/O)
- **Clock generation** (100 MHz MEMS oscillator)
- **Expansion headers** for logic analyzer / oscilloscope probing
- **Status LEDs** for visual feedback

---

## Project Structure

```
grx930_test_board/
├── grx930_test_board.kicad_pro      # KiCad project file
├── grx930_test_board.kicad_sch      # Main schematic
├── grx930_test_board.kicad_pcb      # PCB layout (to be created)
├── sym-lib-table                    # Symbol library configuration
├── fp-lib-table                     # Footprint library configuration
├── README.md                        # This file
└── doc/                             # Documentation
    └── GRX930_test_board.md         # Detailed design document
```

---

## Prerequisites

- **KiCad 8.0** or later (https://www.kicad.org/)
- **SKY130 PDK** (for simulation, not required for schematic capture)

---

## Opening the Project

1. Launch KiCad
2. Select **File → Open Project**
3. Navigate to `grx930_test_board.kicad_pro`
4. Click **Open**

---

## Schematic Symbol Libraries

The project uses the following symbol libraries:

| Library | Description |
|---------|-------------|
| Device | Resistors, capacitors, inductors |
| Connector | Connectors (USB, pin headers, barrel jack) |
| power | Power symbols (VCC, GND) |
| Interface_UART | UART interface ICs |
| Regulator_Linear | Linear regulators (LDO) |
| Regulator_Switching | Switching regulators (buck converters) |
| LED | Light-emitting diodes |
| Oscillator | Clock oscillators |
| Timer | Timer ICs (POR, watchdog) |
| 74xx | Logic ICs (level shifters, buffers) |

---

## Footprint Libraries

The project uses the following footprint libraries:

| Library | Description |
|---------|-------------|
| Capacitor_SMD | SMD capacitors (0402, 0805) |
| Resistor_SMD | SMD resistors (0402) |
| Inductor_SMD | SMD inductors (1210) |
| Connector_USB | USB Type-C connectors |
| Connector_PinHeader_2.54mm | 2.54mm pitch pin headers |
| Package_DFN_QFN | QFN packages |
| Package_SOT | SOT packages |
| LED_SMD | SMD LEDs (0603) |
| Switch_SMD | Tactile switches |
| Connector_BarrelJack | DC barrel jacks |

---

## Key Components

### Active Components

| Ref | Part Number | Description |
|-----|-------------|-------------|
| U1 | FT2232H | Dual USB-to-UART/JTAG bridge |
| U2 | TPS562201 | 3.3A step-down converter (1.8V) |
| U3 | TPS62162 | 1A step-down converter (3.3V) |
| U4 | TPS7A2018 | 200mA LDO (1.8V, low-noise) |
| U5 | SiT8008 | 100 MHz MEMS oscillator |
| U6 | SN74LVC1G17 | Single Schmitt-trigger buffer |
| U7 | SN74LVC1T45 | Single-bit level shifter |
| U8 | TPS3839K43 | Voltage supervisor (4.3V) |
| U9 | USBLC6-2SC6 | USB ESD protection |

### Connectors

| Ref | Description |
|-----|-------------|
| J1 | USB Type-C receptacle |
| J2 | 2.1mm DC barrel jack |
| J3 | QFN-64 socket (open-top) |
| J4 | JTAG header (2x5, 0.1") |
| J5 | GPIO expansion (2x20, 0.1") |
| J6 | Logic analyzer (2x10, 0.1") |

### Power Rails

| Rail | Voltage | Current | Regulator |
|------|---------|---------|-----------|
| VDD_CORE | 1.8V | 1.5A | TPS562201 |
| VDD_IO | 3.3V | 1.0A | TPS62162 |
| VDD_PLL | 1.8V | 100mA | TPS7A2018 |
| VDDA | 1.8V | 50mA | TPS7A2018 |

---

## Schematic Notes

### Power Supply
- Input: USB Type-C (5V/3A) or DC barrel jack (5V/2A)
- Power sequencing: VDD_IO → VDD_CORE → VDD_PLL
- Decoupling: 100nF on each power pin, 1µF shared, 10µF bulk

### UART Interface
- FTDI FT2232H Channel A for UART
- 115200 baud, 8N1
- Direct 3.3V connection (no level shifting needed)

### JTAG Interface
- FTDI FT2232H Channel B for JTAG
- TCK, TMS, TDI, TDO, TRST signals
- Proper pull-ups/pull-downs for default states

### Clock Generation
- 100 MHz MEMS oscillator (SiT8008)
- Level shifting from 3.3V to 1.8V for GRX930

---

## PCB Design Guidelines

### Layer Stackup (4-layer)
```
Layer 1 (Top):    Signal + Components
Layer 2 (Inner 1): GND Plane (continuous)
Layer 3 (Inner 2): Power Planes (1.8V, 3.3V)
Layer 4 (Bottom): Signal + Components
```

### Critical Layout Rules
- Decoupling caps: Place within 2mm of power pins
- Clock traces: 50Ω impedance, length-matched to ±5mm
- JTAG traces: 50Ω impedance, length-matched to ±10mm
- Power traces: ≥20 mil for 1A, ≥40 mil for 1.5A
- Ground vias: Multiple vias near each power pin

---

## BOM Summary

| Category | Cost |
|----------|------|
| Active Components (ICs) | $17.50 |
| Passive Components (R/C/L) | $2.05 |
| Connectors | $29.75 |
| LEDs & Switches | $0.95 |
| Mechanical | $17.00 |
| **Component Subtotal** | **$67.25** |
| PCB Fabrication (10 boards) | $150.00 |
| PCB Assembly (1 board) | $75.00 |
| **Total (1 assembled board)** | **$292.25** |
| Contingency (15%) | $43.84 |
| **Grand Total** | **$336.09** |

---

## Next Steps

1. **Complete the schematic** — Add all components from the design document
2. **Assign footprints** — Map each symbol to its physical footprint
3. **Create netlist** — Generate netlist from schematic
4. **PCB layout** — Place components and route traces
5. **Design rule check** — Verify DRC compliance
6. **Generate manufacturing files** — Gerber, BOM, pick-and-place

---

## References

- [GRX930 Test Board Design Document](../doc/GRX930_test_board.md)
- [GRX930 Manufacturing Plan](../doc/GRX930_manufacturing_plan.md)
- [GRX930 Cost Estimate](../doc/GRX930_cost_estimate.md)
- [KiCad Documentation](https://docs.kicad.org/)

---

*This project was created as part of the GRX930 ASIC development effort for SKY130 silicon validation.*
