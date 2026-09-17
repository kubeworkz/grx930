# GRX930 Test Board — PCB Layout Guide

**Version:** 1.0
**Date:** September 17, 2026
**Target:** 4-Layer PCB, 100mm × 100mm

---

## 1. Layer Stackup

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1 (F.Cu)     Signal + Components                │
│  ─────────────────────────────────────────────────────  │
│  Dielectric 1        FR4, 0.21mm (εr = 4.5)            │
│  ─────────────────────────────────────────────────────  │
│  Layer 2 (In1.Cu)    GND Plane (continuous)             │
│  ─────────────────────────────────────────────────────  │
│  Dielectric 2        FR4, 1.06mm (εr = 4.5)            │
│  ─────────────────────────────────────────────────────  │
│  Layer 3 (In2.Cu)    Power Planes (3.3V / 1.8V split)  │
│  ─────────────────────────────────────────────────────  │
│  Dielectric 3        FR4, 0.21mm (εr = 4.5)            │
│  ─────────────────────────────────────────────────────  │
│  Layer 4 (B.Cu)     Signal + Components                │
└─────────────────────────────────────────────────────────┘
Total thickness: 1.6mm (standard)
Copper weight: 1 oz (35µm)
```

### Stackup Rationale
- **GND on Layer 2:** Continuous ground plane directly below signal layer provides low-inductance return paths
- **Power on Layer 3:** Split plane for 3.3V (left) and 1.8V (right) reduces via count for power distribution
- **Signal layers on 1 & 4:** Top for components, bottom for routing overflow and test points

---

## 2. Board Outline

```
    ┌──────────────────────────────────────────────────────┐
    │ ○ H1 (5,5)                              H2 (95,5) ○ │
    │                                                      │
    │   ┌────────────────────────────────────────────┐    │
    │   │            GRX930 QFN-64                   │    │
    │   │              (Center)                      │    │
    │   └────────────────────────────────────────────┘    │
    │                                                      │
    │ ○ H3 (5,95)                             H4 (95,95) ○ │
    └──────────────────────────────────────────────────────┘
    Board dimensions: 100mm × 100mm (4" × 4")
    Mounting holes: 4× M3, 3.2mm drill, 5mm from edges
```

---

## 3. Component Placement Zones

### 3.1 Placement Map

| Zone | Coordinates | Contents | Notes |
|------|-------------|----------|-------|
| **Power Supply** | (10,10) to (35,35) | TPS562201, TPS62162, TPS7A20×2, inductors, input caps | Keep away from clock section |
| **GRX930 Socket** | (35,35) to (65,65) | QFN-64 socket (J3) | Center of board, thermal vias below |
| **USB/UART** | (65,10) to (90,35) | USB-C (J1), FT2232H (U1), ESD (U9) | Keep USB traces short |
| **Clock** | (10,65) to (35,90) | SiT8008 (U5), buffer (U6), level shifter (U7) | Isolate from power supply |
| **JTAG** | (65,65) to (90,90) | JTAG header (J4), pull-ups | Group with GRX930 |
| **GPIO Header** | Left edge (10,50) | J5 (2×20 pin) | Accessible from board edge |
| **Logic Analyzer** | Right edge (90,50) | J6 (2×10 pin) | Accessible from board edge |
| **LEDs** | Bottom-left (15-30, 85) | LED1-4, current limiting resistors | Visible to user |
| **Reset** | Bottom-left (15,92) | SW1 tactile switch | Accessible from edge |
| **Test Points** | Top-left (10-20, 15) | TP1 (3.3V), TP2 (1.8V), TP3 (GND) | For multimeter access |

### 3.2 Placement Rules

1. **Decoupling capacitors:** Within 2mm of IC power pins
2. **Inductors:** Minimize loop area with input/output caps
3. **Crystal/oscillator:** Minimize trace length to IC, ground guard ring
4. **Connectors:** Mount at board edges, secure with mounting holes
5. **LEDs:** Group together, near board edge for visibility

---

## 4. Power Distribution

### 4.1 Power Rails

| Net | Voltage | Max Current | Track Width | Via Size | Plane Layer |
|-----|---------|-------------|-------------|----------|-------------|
| +3.3V | 3.3V | 1.0A | 0.5mm (20 mil) | 0.8mm drill | In2.Cu (left) |
| +1.8V | 1.8V | 1.5A | 1.0mm (40 mil) | 0.8mm drill | In2.Cu (right) |
| VDD_PLL | 1.8V | 100mA | 0.3mm (12 mil) | 0.5mm drill | In2.Cu (right) |
| VDDA | 1.8V | 50mA | 0.3mm (12 mil) | 0.5mm drill | In2.Cu (right) |
| VBUS | 5V | 3.0A | 1.5mm (60 mil) | 1.0mm drill | In2.Cu (left) |
| GND | 0V | — | Plane fill | 0.8mm drill | In1.Cu (full) |

### 4.2 Power Sequencing Layout

```
USB 5V → TPS62162 → 3.3V rail → TPS562201 → 1.8V rail → TPS7A20 → VDD_PLL/VDDA
                │
                └→ TPS3839K43 → RESET_N (after 10ms)
```

### 4.3 Decoupling Strategy

| Location | Value | Qty | Package | Placement |
|----------|-------|-----|---------|-----------|
| Each VDD pin | 100nF | 32 | 0402 | Within 2mm of pin |
| Each VDD pair | 1µF | 16 | 0402 | Within 5mm of pin group |
| Board bulk | 10µF | 4 | 0805 | At each regulator output |
| VDD_PLL input | 10nF | 1 | 0402 | Directly at pin |
| VDDA input | 1µF | 1 | 0402 | Directly at pin |
| USB VBUS | 100µF | 2 | 1206 | At USB connector and regulator input |

---

## 5. Signal Routing Rules

### 5.1 Impedance Control

| Signal Type | Impedance | Trace Width | Layer | Notes |
|-------------|-----------|-------------|-------|-------|
| USB (DP/DM) | 90Ω differential | 0.15mm | F.Cu | Length-matched to ±0.5mm |
| Clock (100MHz) | 50Ω single-ended | 0.25mm | F.Cu | Length-matched to ±5mm |
| JTAG | 50Ω single-ended | 0.25mm | F.Cu | Length-matched to ±10mm |
| UART | 50Ω single-ended | 0.25mm | F.Cu | No length matching needed |
| General GPIO | 50Ω single-ended | 0.25mm | F.Cu/B.Cu | — |

### 5.2 Trace Width Guidelines

| Current | Min Width | Recommended | Notes |
|---------|-----------|-------------|-------|
| < 100mA | 0.15mm (6 mil) | 0.25mm (10 mil) | Signal traces |
| 100mA - 500mA | 0.3mm (12 mil) | 0.5mm (20 mil) | Medium power |
| 500mA - 1A | 0.5mm (20 mil) | 1.0mm (40 mil) | Power rails |
| 1A - 2A | 1.0mm (40 mil) | 1.5mm (60 mil) | High-current power |
| > 2A | 1.5mm (60 mil) | 2.0mm (80 mil) | USB VBUS, main power |

### 5.3 Via Guidelines

| Type | Drill | Pad | Annular Ring | Usage |
|------|-------|-----|--------------|-------|
| Signal | 0.3mm | 0.6mm | 0.15mm | Layer transitions |
| Power | 0.8mm | 1.2mm | 0.2mm | Power plane connections |
| Thermal | 0.3mm | 0.6mm | 0.15mm | Under QFN thermal pad |
| Mounting | 3.2mm | 6.0mm | 1.4mm | M3 screws |

### 5.4 Routing Priority

1. **USB differential pair** — Route first, keep away from power switching
2. **Clock signal** — Route second, keep away from USB and power
3. **JTAG signals** — Route third, group together
4. **UART signals** — Route fourth
5. **Power connections** — Route last, use plane fills where possible

---

## 6. Thermal Management

### 6.1 Thermal Pad (Under QFN Socket)

```
    ┌─────────────────────────────────┐
    │         QFN-64 Socket          │
    │     (30mm × 30mm area)         │
    │                                 │
    │   ┌─────────────────────┐      │
    │   │  Thermal Pad (GND)  │      │
    │   │  25mm × 25mm        │      │
    │   │                     │      │
    │   │  ○ ○ ○ ○ ○ ○ ○ ○   │      │
    │   │  ○ ○ ○ ○ ○ ○ ○ ○   │      │
    │   │  ○ ○ ○ ○ ○ ○ ○ ○   │      │
    │   │  ○ ○ ○ ○ ○ ○ ○ ○   │      │
    │   │  ○ = Thermal Via    │      │
    │   │  0.3mm drill        │      │
    │   │  0.8mm pitch        │      │
    │   └─────────────────────┘      │
    │                                 │
    └─────────────────────────────────┘
```

**Thermal via array:**
- Drill: 0.3mm
- Pitch: 0.8mm (center-to-center)
- Array: 8×8 = 64 vias
- Connected to GND plane (In1.Cu)
- Solder mask: Tent vias (cover with solder mask)

### 6.2 Power Regulator Thermal Pad

**TPS562201 (1.8V, 1.5A):**
- Thermal pad: 2.5mm × 2.5mm
- 4× thermal vias (0.3mm drill, 0.8mm pitch)
- Connected to GND plane

**TPS62162 (3.3V, 1A):**
- Thermal pad: 2.0mm × 2.0mm
- 2× thermal vias (0.3mm drill, 1.0mm pitch)
- Connected to GND plane

### 6.3 Copper Pour Strategy

| Layer | Net | Area | Purpose |
|-------|-----|------|---------|
| In1.Cu | GND | Full layer | Continuous ground reference |
| In2.Cu | +3.3V | Left half | Power distribution |
| In2.Cu | +1.8V | Right half | Power distribution |
| F.Cu | GND | Under QFN | Thermal dissipation |
| B.Cu | GND | Under power section | Thermal dissipation |

### 6.4 Thermal Analysis

**Estimated board power dissipation:**
- GRX930 SoC: ~200mW (1.8V × 110mA)
- Power regulators: ~150mW (combined)
- FTDI FT2232H: ~50mW
- Clock oscillator: ~20mW
- **Total: ~420mW**

**Thermal resistance (no forced airflow):**
- Junction-to-ambient: ~50°C/W (estimate)
- Temperature rise: 420mW × 50°C/W = **21°C above ambient**
- **Conclusion:** No heatsink required, board-level cooling is sufficient

---

## 7. High-Speed Design Guidelines

### 7.1 USB (90Ω Differential)

- **Trace width:** 0.15mm (6 mil)
- **Trace spacing:** 0.15mm (6 mil) differential
- **Layer:** F.Cu (top)
- **Length matching:** DP and DM within ±0.5mm
- **Series termination:** 22Ω resistors (R15-R18) near FTDI
- **Keep-out:** 2mm from other traces, no vias between DP/DM

### 7.2 Clock (50Ω Single-Ended)

- **Trace width:** 0.25mm (10 mil)
- **Layer:** F.Cu (top)
- **Length matching:** ±5mm (not critical at 100MHz)
- **Guard trace:** GND trace on both sides if routing near other signals
- **Via count:** Minimize, ideally 0-2 transitions
- **Keep-out:** 1mm from other signals

### 7.3 JTAG (50Ω Single-Ended)

- **Trace width:** 0.25mm (10 mil)
- **Layer:** F.Cu (top)
- **Length matching:** ±10mm (not critical)
- **Group routing:** Keep TCK, TMS, TDI, TDO together
- **Pull-ups/pull-downs:** Place near GRX930, not near FTDI

---

## 8. DRC Rules

### 8.1 Clearance Rules

| Rule | Value | Notes |
|------|-------|-------|
| Trace-to-trace | 0.2mm (8 mil) | Minimum clearance |
| Trace-to-pad | 0.2mm (8 mil) | Minimum clearance |
| Trace-to-via | 0.2mm (8 mil) | Minimum clearance |
| Via-to-via | 0.25mm (10 mil) | Minimum clearance |
| Copper-to-edge | 0.5mm (20 mil) | Board edge clearance |
| Solder mask | 0.05mm (2 mil) | Solder mask expansion |

### 8.2 Track Width Rules

| Rule | Value | Notes |
|------|-------|-------|
| Minimum trace | 0.15mm (6 mil) | Signal traces |
| Maximum trace | 2.0mm (80 mil) | Power traces |
| Minimum via drill | 0.3mm (12 mil) | Microvias |
| Minimum via pad | 0.6mm (24 mil) | Via annular ring |

### 8.3 Design Rule Checks (DRC)

Before generating manufacturing files, verify:
- [ ] No clearance violations
- [ ] No track width violations
- [ ] No unconnected nets (rat's nest)
- [ ] No copper slivers (minimum copper fill)
- [ ] Solder mask opening correct
- [ ] Silkscreen not overlapping pads
- [ ] Board outline closed
- [ ] Mounting holes correct size

---

## 9. Manufacturing Notes

### 9.1 PCB Specifications

| Parameter | Value |
|-----------|-------|
| Layer count | 4 |
| Board size | 100mm × 100mm |
| Thickness | 1.6mm |
| Copper weight | 1 oz (35µm) |
| Finish | Lead-free HASL |
| Min track/space | 0.15mm / 0.15mm |
| Min drill | 0.3mm |
| Solder mask | Green LPI |
| Silkscreen | White |
| Via tenting | Yes (solder mask over vias) |

### 9.2 Assembly Notes

- **SMT assembly:** All components on F.Cu side
- **Through-hole:** Connectors (J1-J6) and mounting holes (H1-H4)
- **QFN socket:** Install after all SMT components
- **Stencil:** Required for SMT pads, 0.1mm thickness

### 9.3 Test Points

| Reference | Net | Location | Purpose |
|-----------|-----|----------|---------|
| TP1 | +3.3V | (10, 15) | Power rail verification |
| TP2 | +1.8V | (15, 15) | Power rail verification |
| TP3 | GND | (20, 15) | Ground reference |
| TP4 | RESET_N | Near SW1 | Reset signal verification |
| TP5 | CLK_100MHZ | Near U5 | Clock verification |

---

## 10. Reference Design Files

| File | Description |
|------|-------------|
| `grx930_test_board.kicad_pcb` | Main PCB layout |
| `grx930_test_board.kicad_sch` | Schematic |
| `grx930_test_board.kicad_pro` | Project file |
| `PCB_LAYOUT_GUIDE.md` | This document |
| `GRX930_test_board.md` | Detailed design document |

---

*This PCB layout guide provides the foundation for completing the physical design. Open the .kicad_pcb file in KiCad 8+ to begin component placement and routing.*
