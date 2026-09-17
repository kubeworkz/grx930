# GRX930 Prototype Test Board — Schematic & BOM

**Version:** 1.0
**Date:** September 17, 2026
**Target Package:** QFN-64 (SKY130 die on PCB interposer)
**Estimated Board Size:** 4" × 4" (100mm × 100mm)

---

## 1. Board Overview

This test board provides the electrical environment to validate the GRX930 SoC on first silicon. It includes:

- **QFN-64 socket** for the packaged GRX930 die
- **USB-to-UART bridge** for serial console
- **JTAG interface** for debug and scan-chain access
- **Multi-rail power supply** with sequencing
- **Clock generation** (external oscillator)
- **Expansion headers** for logic analyzer / oscilloscope probing
- **Status LEDs** for visual feedback

---

## 2. Schematic Block Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        USB Connector (Type-C)                   │
│                              │                                   │
│                    ┌─────────┴─────────┐                        │
│                    │   FTDI FT2232H    │                        │
│                    │  (Dual UART+JTAG) │                        │
│                    └────┬────────┬─────┘                        │
│                         │        │                               │
│              UART ──────┘        └────── JTAG                   │
│              (3.3V)                    (3.3V)                   │
│                         │        │                               │
│              ┌──────────┴────────┴──────────┐                   │
│              │                              │                   │
│              │      GRX930 SoC (QFN-64)    │                   │
│              │                              │                   │
│              └──────────┬────────┬──────────┘                   │
│                         │        │                               │
│                    Power Supply   Clock                          │
│                         │        │                               │
│              ┌──────────┴────────┴──────────┐                   │
│              │   Power Management Board     │                   │
│              │   (TPS562201 + TPS62162)     │                   │
│              └──────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Schematic Sections

### 3.1 Power Supply

#### 3.1.1 Input Power
- **Input:** USB Type-C PD (5V/3A) or DC barrel jack (5V/2A)
- **Connector:** USB-C (CC pins configured for 5V) + 2.1mm barrel jack (backup)

#### 3.1.2 Voltage Regulators

| Rail | Voltage | Current | Regulator | Package | Notes |
|------|---------|---------|-----------|---------|-------|
| VDD_CORE | 1.8V | 1.5A | TPS562201 | SOT-23-6 | Core logic supply |
| VDD_IO | 3.3V | 1.0A | TPS62162 | WSON-8 | I/O and peripherals |
| VDD_PLL | 1.8V | 100mA | Low-dropout (TPS7A20) | SOT-23-5 | PLL analog supply (filtered) |
| VDDA | 1.8V | 50mA | Low-dropout (TPS7A20) | SOT-23-5 | Analog supply (filtered) |

#### 3.1.3 Power Sequencing
```
Power-on sequence:
1. VDD_IO (3.3V) stabilizes
2. VDD_CORE (1.8V) stabilizes
3. VDD_PLL (1.8V) stabilizes
4. Reset released (after 10ms delay)

Power-off sequence (reverse):
1. Reset asserted
2. VDD_PLL removed
3. VDD_CORE removed
4. VDD_IO removed
```

#### 3.1.4 Decoupling Capacitors

| Location | Value | Quantity | Notes |
|----------|-------|----------|-------|
| Each VDD pin | 100nF X7R 0402 | 32 | One per power pin |
| Each VDD pair | 1µF X5R 0402 | 16 | Shared between adjacent pins |
| Board bulk | 10µF X5R 0805 | 4 | Bulk decoupling |
| VDDPLL | 10nF + 1µF | 2 | Additional filtering for PLL |

---

### 3.2 UART Interface

#### 3.2.1 USB-to-UART Bridge
- **Chip:** FTDI FT2232H (dual-channel)
  - Channel A: UART (115200 baud, 8N1)
  - Channel B: JTAG
- **USB Connector:** USB Type-C (shared with power)
- **ESD Protection:** USBLC6-2SC6 (on USB data lines)

#### 3.2.2 UART Connection to GRX930
```
FT2232H Channel A          GRX930
─────────────────          ──────
TXD (pin 23) ──────────────→ RXD (GPIO)
RXD (pin 22) ←────────────── TXD (GPIO)
GND (pin 1)  ─────────────── GND
```

#### 3.2.3 UART Level Shifting
- FTDI operates at 3.3V
- GRX930 I/O operates at 3.3V
- **No level shifting required** (direct connection)

#### 3.2.4 UART Pull-ups
- 10kΩ pull-up on RXD line to 3.3V (idle-high)
- 10kΩ pull-up on TXD line to 3.3V (idle-high)

---

### 3.3 JTAG Interface

#### 3.3.1 JTAG Signals

| Signal | FTDI Pin | GRX930 Pin | Direction | Notes |
|--------|----------|------------|-----------|-------|
| TCK | Channel B, ADBUS0 | JTAG_TCK | FTDI → Chip | Clock |
| TMS | Channel B, ADBUS1 | JTAG_TMS | FTDI → Chip | Mode select |
| TDI | Channel B, ADBUS2 | JTAG_TDI | FTDI → Chip | Data in |
| TDO | Channel B, ADBUS3 | JTAG_TDO | Chip → FTDI | Data out |
| TRST | Channel B, ADBUS4 | JTAG_TRST | FTDI → Chip | Reset (active low) |
| GND | — | GND | Common | Ground reference |

#### 3.3.2 JTAG Pull-ups/Pull-downs
- TCK: 10kΩ pull-down to GND (default state)
- TMS: 10kΩ pull-up to 3.3V (default state)
- TDI: 10kΩ pull-up to 3.3V (default state)
- TRST: 10kΩ pull-up to 3.3V (inactive high)

#### 3.3.3 JTAG Connector
- **2x5 pin header** (0.1" pitch, shrouded)
- Pin 1: TCK, Pin 2: GND, Pin 3: TMS, Pin 4: GND
- Pin 5: TDI, Pin 6: GND, Pin 7: TDO, Pin 8: GND
- Pin 9: TRST, Pin 10: GND

---

### 3.4 Clock Generation

#### 3.4.1 Primary Clock Source
- **Oscillator:** SiTime SiT8008 (MEMS oscillator)
- **Frequency:** 100 MHz (matches FPGA validation)
- **Package:** 3.2mm × 2.5mm (5032)
- **Supply:** 3.3V
- **Output:** LVCMOS 3.3V

#### 3.4.2 Clock Buffer
- **Buffer:** SN74LVC1G17 (single Schmitt-trigger buffer)
- **Purpose:** Clean up clock edge, drive clock tree
- **Output:** 3.3V LVCMOS → level-shift to 1.8V for GRX930

#### 3.4.3 Clock Level Shifting
- **Level Shifter:** SN74LVC1T45 (single-bit bidirectional)
- **Direction:** 3.3V → 1.8V (fixed direction for clock)
- **Propagation Delay:** < 1ns (negligible at 100 MHz)

---

### 3.5 Reset Circuit

#### 3.5.1 Power-On Reset (POR)
- **Chip:** TPS3839K43 (supervisor)
- **Threshold:** 4.3V (monitors USB 5V input)
- **Reset Output:** Active-low, 10ms delay
- **Connection:** GRX930 reset pin (active-low)

#### 3.5.2 Manual Reset
- **Pushbutton:** Tactile switch (momentary, normally-open)
- **Debouncer:** RC circuit (10kΩ + 100nF = 1ms time constant)
- **Connection:** OR'd with POR output via diode

---

### 3.6 Status Indicators

| LED | Color | Pin | Function |
|-----|-------|-----|----------|
| LED1 | Green | GPIO | Heartbeat (1 Hz blink) |
| LED2 | Red | GPIO | Error indicator |
| LED3 | Blue | GPIO | JTAG active |
| LED4 | Yellow | GPIO | UART activity |

- **Current Limiting:** 1kΩ resistors (3.3V / 2mA = 1.5kΩ, use 1kΩ for brightness)

---

### 3.7 Expansion Headers

#### 3.7.1 GPIO Header (2x20 pin, 0.1" pitch)
- 16 GPIO pins (directly from GRX930)
- 4 power pins (1.8V, 3.3V, GND, GND)
- 4 JTAG signals (directly accessible)
- 4 UART signals (TXD, RXD, GND, 3.3V)

#### 3.7.2 Logic Analyzer Header (2x10 pin, 0.1" pitch)
- 8 GPIO pins (for monitoring internal signals)
- Clock input (for synchronous capture)
- Trigger input/output
- GND reference

---

### 3.8 PCB Layout Guidelines

#### 3.8.1 Layer Stackup (4-layer board)
```
Layer 1 (Top):    Signal + Components
Layer 2 (Inner 1): GND Plane (continuous)
Layer 3 (Inner 2): Power Planes (1.8V, 3.3V)
Layer 4 (Bottom): Signal + Components
```

#### 3.8.2 Critical Layout Rules
- **Decoupling caps:** Place within 2mm of power pins
- **Clock traces:** 50Ω impedance, length-matched to ±5mm
- **JTAG traces:** 50Ω impedance, length-matched to ±10mm
- **Power traces:** Wide (≥20 mil for 1A, ≥40 mil for 1.5A)
- **Ground vias:** Multiple vias near each power pin

#### 3.8.3 Thermal Management
- **Thermal pad:** Under QFN package, connected to GND plane with thermal vias (0.3mm drill, 0.8mm pitch)
- **Power regulator:** Copper pour for heat dissipation
- **Ambient:** No forced airflow required (board power < 3W)

---

## 4. Bill of Materials (BOM)

### 4.1 Active Components

| Ref | Part Number | Manufacturer | Description | Qty | Unit Price | Total |
|-----|-------------|--------------|-------------|-----|------------|-------|
| U1 | FT2232H | FTDI | Dual USB-to-UART/JTAG bridge | 1 | $5.50 | $5.50 |
| U2 | TPS562201 | TI | 3.3A step-down converter (1.8V) | 1 | $2.10 | $2.10 |
| U3 | TPS62162 | TI | 1A step-down converter (3.3V) | 1 | $2.80 | $2.80 |
| U4 | TPS7A2018 | TI | 200mA LDO (1.8V, low-noise) | 2 | $1.20 | $2.40 |
| U5 | SiT8008 | SiTime | 100 MHz MEMS oscillator | 1 | $1.80 | $1.80 |
| U6 | SN74LVC1G17 | TI | Single Schmitt-trigger buffer | 1 | $0.45 | $0.45 |
| U7 | SN74LVC1T45 | TI | Single-bit level shifter | 1 | $0.85 | $0.85 |
| U8 | TPS3839K43 | TI | Voltage supervisor (4.3V threshold) | 1 | $0.95 | $0.95 |
| U9 | USBLC6-2SC6 | ST | USB ESD protection | 1 | $0.60 | $0.60 |

### 4.2 Passive Components

| Ref | Value | Package | Description | Qty | Unit Price | Total |
|-----|-------|---------|-------------|-----|------------|-------|
| C1-C32 | 100nF | 0402 | X7R ceramic decoupling | 32 | $0.01 | $0.32 |
| C33-C48 | 1µF | 0402 | X5R ceramic decoupling | 16 | $0.02 | $0.32 |
| C49-C52 | 10µF | 0805 | X5R ceramic bulk | 4 | $0.08 | $0.32 |
| C53-C54 | 10nF+1µF | 0402 | PLL filtering | 2 | $0.03 | $0.06 |
| C55-C56 | 100µF | 1206 | Bulk electrolytic (power input) | 2 | $0.25 | $0.50 |
| C57-C58 | 10nF | 0402 | Reset debouncer | 2 | $0.01 | $0.02 |
| R1-R8 | 10kΩ | 0402 | JTAG/UART pull-ups | 8 | $0.005 | $0.04 |
| R9-R12 | 1kΩ | 0402 | LED current limiting | 4 | $0.005 | $0.02 |
| R13-R14 | 10kΩ | 0402 | Reset debounce RC | 2 | $0.005 | $0.01 |
| R15-R18 | 22Ω | 0402 | USB series termination | 4 | $0.005 | $0.02 |
| R19-R20 | 10kΩ | 0402 | USB CC pull-down (5.1kΩ) | 2 | $0.005 | $0.01 |
| L1 | 4.7µH | 1210 | Inductor for TPS562201 | 1 | $0.35 | $0.35 |
| L2 | 2.2µH | 1210 | Inductor for TPS62162 | 1 | $0.30 | $0.30 |

### 4.3 Connectors

| Ref | Part Number | Description | Qty | Unit Price | Total |
|-----|-------------|-------------|-----|------------|-------|
| J1 | USB4125 | USB Type-C receptacle | 1 | $1.20 | $1.20 |
| J2 | PJ-002AH | 2.1mm DC barrel jack | 1 | $0.35 | $0.35 |
| J3 | QFN-64 socket | Open-top QFN socket (0.4mm pitch) | 1 | $25.00 | $25.00 |
| J4 | 1x10 shrouded | JTAG header (0.1" pitch) | 1 | $0.50 | $0.50 |
| J5 | 2x20 box header | GPIO expansion (0.1" pitch) | 1 | $1.50 | $1.50 |
| J6 | 2x10 box header | Logic analyzer (0.1" pitch) | 1 | $1.00 | $1.00 |
| J7-J8 | Pin header 1x3 | Power test points | 2 | $0.10 | $0.20 |

### 4.4 Indicators & Switches

| Ref | Part Number | Description | Qty | Unit Price | Total |
|-----|-------------|-------------|-----|------------|-------|
| LED1 | 19-217/GHC-YR1S2/3T | Green LED (0603) | 1 | $0.10 | $0.10 |
| LED2 | 19-217/R6C-AL1M2VY/3T | Red LED (0603) | 1 | $0.10 | $0.10 |
| LED3 | 19-217/BHC-ZL1M2VY/3T | Blue LED (0603) | 1 | $0.15 | $0.15 |
| LED4 | 19-217/YHC-AL1M2VY/3T | Yellow LED (0603) | 1 | $0.10 | $0.10 |
| SW1 | PTS645SK50SMTR92 | Tactile reset switch | 1 | $0.25 | $0.25 |
| SW2 | PTS645SK50SMTR92 | Power switch (optional) | 1 | $0.25 | $0.25 |

### 4.5 Mechanical

| Ref | Part Number | Description | Qty | Unit Price | Total |
|-----|-------------|-------------|-----|------------|-------|
| — | — | PCB (4-layer, 100×100mm, HASL) | 1 | $15.00 | $15.00 |
| — | — | Brass standoffs (M3×10mm) | 4 | $0.25 | $1.00 |
| — | — | M3 screws | 8 | $0.10 | $0.80 |
| — | — | Rubber feet | 4 | $0.05 | $0.20 |

---

## 5. BOM Summary

| Category | Total |
|----------|-------|
| Active Components (ICs) | $17.50 |
| Passive Components (R/C/L) | $2.05 |
| Connectors | $29.75 |
| Indicators & Switches | $0.95 |
| Mechanical | $17.00 |
| **Component Subtotal** | **$67.25** |
| PCB Fabrication (10 boards) | $150.00 |
| PCB Assembly (1 board) | $75.00 |
| **Total (1 assembled board)** | **$292.25** |
| Contingency (15%) | $43.84 |
| **Grand Total (per board)** | **$336.09** |

---

## 6. Assembly Notes

### 6.1 QFN Socket
- Use open-top QFN socket for easy die replacement
- Socket requires custom insert for GRX930 package (0.4mm pitch)
- Consider spring-pin adapter for production testing

### 6.2 Assembly Order
1. Solder power regulators (U2-U4) and inductors (L1-L2)
2. Solder decoupling capacitors (C1-C58)
3. Solder passive components (R1-R20)
4. Solder oscillator (U5) and clock buffer (U6)
5. Solder FTDI (U1) and ESD protection (U9)
6. Solder connectors (J1-J8)
7. Solder LEDs and switches
8. Install QFN socket (J3)
9. Install standoffs and feet

### 6.3 Testing Procedure
1. Visual inspection (no solder bridges)
2. Power-on test (verify 1.8V, 3.3V rails)
3. Clock verification (100 MHz output)
4. UART loopback test (FTDI self-test)
5. JTAG scan chain test
6. GRX930 power-up and boot test

---

## 7. Design Files

| File | Description |
|------|-------------|
| `GRX930_test_board.sch` | KiCad schematic (to be created) |
| `GRX930_test_board.kicad_pcb` | KiCad PCB layout (to be created) |
| `GRX930_test_board.bom` | BOM export from KiCad |
| `GRX930_test_board Gerber` | Manufacturing files |

---

## 8. Alternatives & Options

### 8.1 Lower-Cost Option (~$150)
- Remove QFN socket, solder die directly
- Use Arduino Nano for UART/JTAG (instead of FTDI)
- Single-layer PCB (reduce cost)
- **Trade-off:** Less flexibility, harder to debug

### 8.2 Higher-End Option (~$500)
- Add oscilloscope probe points for all clocks
- Add power measurement shunt resistors
- Add test points for all critical signals
- Include logic analyzer integrated (Saleae-compatible)
- **Trade-off:** Higher cost, more features

### 8.3 Production Test Fixture (~$1000)
- Automated bed-of-nails test fixture
- Spring-pin probes for all I/O
- Integrated power supply and measurement
- Automated test scripts
- **Trade-off:** High upfront cost, fast test time

---

*All prices are estimates based on Digi-Key/Mouser pricing for single-unit quantities. Volume discounts may apply for production quantities.*
