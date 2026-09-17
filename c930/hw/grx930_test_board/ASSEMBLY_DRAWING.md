# GRX930 Test Board — Assembly Drawing

**Version:** 1.0  
**Date:** September 17, 2026  
**Board:** 100mm × 100mm (4" × 4")  
**Layer:** Top (F.Cu) — All components on top side

---

## 1. Board Outline

```
    ┌────────────────────────────────────────────────────────────────────────────────────────────────┐
    │  (0,0)                                                                                     (100,0)│
    │    ┌───┐                                                                                 ┌───┐  │
    │    │H1 │                                                                                 │H2 │  │
    │    │   │                                                                                 │   │  │
    │    └───┘                                                                                 └───┘  │
    │                                                                                              │
    │    ┌──────────────────────────────────────────────────────────────────────────────────────┐  │
    │    │                                                                                      │  │
    │    │                           GRX930 Test Board v1.0                                     │  │
    │    │                           4-Layer PCB: 100mm x 100mm                                 │  │
    │    │                                                                                      │  │
    │    └──────────────────────────────────────────────────────────────────────────────────────┘  │
    │                                                                                              │
    │    ┌───┐                                                                                 ┌───┐  │
    │    │H3 │                                                                                 │H4 │  │
    │    │   │                                                                                 │   │  │
    │    └───┘                                                                                 └───┘  │
    │                                                                                              │
    │  (0,100)                                                                                  (100,100)│
    └────────────────────────────────────────────────────────────────────────────────────────────────┘

    Mounting Holes (M3, 3.2mm drill):
    H1: (5, 5)      H2: (95, 5)
    H3: (5, 95)     H4: (95, 95)
```

---

## 2. Component Placement Zones

```
    ┌────────────────────────────────────────────────────────────────────────────────────────────────┐
    │                                                                                              │
    │  ┌─────────────────────┐        ┌─────────────────────┐        ┌─────────────────────┐      │
    │  │   POWER SUPPLY      │        │     GRX930 SoC      │        │    USB/UART         │      │
    │  │   (10,10)-(35,35)   │        │   (35,35)-(65,65)   │        │   (65,10)-(90,35)   │      │
    │  │                     │        │                     │        │                     │      │
    │  │  J2 (DC Jack)       │        │  J3 (QFN-64 Socket) │        │  J1 (USB-C)         │      │
    │  │  U2 (TPS562201)     │        │                     │        │  U1 (FT2232H)       │      │
    │  │  U3 (TPS62162)      │        │  C1-C32 (100nF)     │        │  U10 (USBLC6)       │      │
    │  │  U4 (TPS7A2018)     │        │  C33-C48 (1µF)      │        │  R11-R14 (22Ω)      │      │
    │  │  U5 (TPS7A2018)     │        │                     │        │  R17-R18 (5.1kΩ)    │      │
    │  │  U9 (TPS3839K43)    │        │                     │        │                     │      │
    │  │  L1 (4.7µH)         │        │                     │        │                     │      │
    │  │  L2 (2.2µH)         │        │                     │        │                     │      │
    │  │  C49-C56 (bulk)     │        │                     │        │                     │      │
    │  │                     │        │                     │        │                     │      │
    │  └─────────────────────┘        └─────────────────────┘        └─────────────────────┘      │
    │                                                                                              │
    │  ┌─────────────────────┐        ┌─────────────────────┐        ┌─────────────────────┐      │
    │  │   CLOCK GENERATION  │        │    EXPANSION        │        │    JTAG             │      │
    │  │   (10,65)-(35,90)   │        │   (Edges)           │        │   (65,65)-(90,90)   │      │
    │  │                     │        │                     │        │                     │      │
    │  │  U6 (SiT8008)       │        │  J5 (GPIO 2x20)     │        │  J4 (JTAG 2x5)     │      │
    │  │  U7 (SN74LVC1G17)   │        │  J6 (LA 2x10)       │        │  R1-R4 (10kΩ)       │      │
    │  │  U8 (SN74LVC1T45)   │        │                     │        │                     │      │
    │  │  C53-C54 (PLL)      │        │                     │        │                     │      │
    │  │                     │        │                     │        │                     │      │
    │  └─────────────────────┘        └─────────────────────┘        └─────────────────────┘      │
    │                                                                                              │
    │  ┌─────────────────────┐        ┌─────────────────────┐        ┌─────────────────────┐      │
    │  │   TEST POINTS       │        │    STATUS LEDs      │        │    RESET            │      │
    │  │   (10,80)-(20,90)   │        │   (20,85)-(40,95)   │        │   (25,90)-(35,95)   │      │
    │  │                     │        │                     │        │                     │      │
    │  │  J7 (TP 3.3V)       │        │  D1 (Green)         │        │  SW1 (Reset)        │      │
    │  │  J8 (TP 1.8V)       │        │  D2 (Red)           │        │  C57-C58 (debounce) │      │
    │  │  TP3 (GND)          │        │  D3 (Blue)          │        │  R15-R16 (10kΩ)     │      │
    │  │                     │        │  D4 (Yellow)        │        │                     │      │
    │  │                     │        │  R7-R10 (1kΩ)       │        │                     │      │
    │  │                     │        │                     │        │                     │      │
    │  └─────────────────────┘        └─────────────────────┘        └─────────────────────┘      │
    │                                                                                              │
    └────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Component Placement Details

### 3.1 Power Supply Section (10,10) to (35,35)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| J2 | PJ-002AH DC Jack | BarrelJack | (12.5, 15) | 0° | Board edge, right-angle |
| U2 | TPS562201 | SOT-23-6 | (22.5, 22.5) | 0° | 1.8V buck, thermal pad |
| U3 | TPS62162 | WSON-8 | (22.5, 32.5) | 0° | 3.3V buck, thermal pad |
| U4 | TPS7A2018 | SOT-23-5 | (22.5, 42.5) | 0° | 1.8V PLL LDO |
| U5 | TPS7A2018 | SOT-23-5 | (22.5, 47.5) | 0° | 1.8V analog LDO |
| U9 | TPS3839K43 | SOT-23-5 | (22.5, 52.5) | 0° | POR supervisor |
| L1 | 4.7µH | 1210 | (22.5, 17.5) | 0° | 1.8V buck inductor |
| L2 | 2.2µH | 1210 | (22.5, 27.5) | 0° | 3.3V buck inductor |
| C49 | 10µF | 0805 | (27.5, 27.5) | 0° | Bulk 3.3V input |
| C50 | 10µF | 0805 | (27.5, 37.5) | 0° | Bulk 1.8V input |
| C51 | 10µF | 0805 | (17.5, 27.5) | 0° | Bulk USB VBUS |
| C52 | 10µF | 0805 | (17.5, 37.5) | 0° | Bulk USB VBUS |
| C55 | 100µF | 1206 | (12.5, 22.5) | 0° | Input bulk |
| C56 | 100µF | 1206 | (12.5, 32.5) | 0° | Input bulk |

### 3.2 GRX930 SoC Section (35,35) to (65,65)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| J3 | QFN-64 Socket | QFN-64 | (55, 55) | 0° | Open-top socket |
| C1-C32 | 100nF | 0402 | (42.5-72.5, 42.5-62.5) | 0° | Per-pin decoupling |
| C33-C48 | 1µF | 0402 | (35-85, 45-65) | 0° | Shared decoupling |

### 3.3 USB/UART Section (65,10) to (90,35)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| J1 | USB4125 USB-C | USB_C | (85, 15) | 0° | Board edge, horizontal |
| U1 | FT2232H | LQFP-64 | (77.5, 22.5) | 0° | Dual USB bridge |
| U10 | USBLC6-2SC6 | SOT-23-6 | (72.5, 22.5) | 0° | ESD protection |
| R11 | 22Ω | 0402 | (72.5, 17.5) | 0° | USB DP termination |
| R12 | 22Ω | 0402 | (72.5, 22.5) | 0° | USB DM termination |
| R13 | 22Ω | 0402 | (67.5, 17.5) | 0° | USB DP termination |
| R14 | 22Ω | 0402 | (67.5, 22.5) | 0° | USB DM termination |
| R17 | 5.1kΩ | 0402 | (82.5, 22.5) | 0° | USB CC1 pull-down |
| R18 | 5.1kΩ | 0402 | (87.5, 22.5) | 0° | USB CC2 pull-down |
| R5 | 10kΩ | 0402 | (82.5, 17.5) | 0° | UART TXD pull-up |
| R6 | 10kΩ | 0402 | (87.5, 17.5) | 0° | UART RXD pull-up |

### 3.4 Clock Generation Section (10,65) to (35,90)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| U6 | SiT8008 | Oscillator_5032 | (22.5, 72.5) | 0° | 100 MHz MEMS |
| U7 | SN74LVC1G17 | SOT-353 | (27.5, 72.5) | 0° | Clock buffer |
| U8 | SN74LVC1T45 | SOT-353 | (32.5, 72.5) | 0° | Level shifter |
| C53 | 10nF | 0402 | (27.5, 77.5) | 0° | PLL input filter |
| C54 | 1µF | 0402 | (32.5, 77.5) | 0° | PLL input filter |

### 3.5 JTAG Section (65,65) to (90,90)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| J4 | 2x5 Shrouded | PinHeader | (85, 75) | 0° | JTAG header |
| R1 | 10kΩ | 0402 | (77.5, 72.5) | 0° | TCK pull-down |
| R2 | 10kΩ | 0402 | (82.5, 72.5) | 0° | TMS pull-up |
| R3 | 10kΩ | 0402 | (87.5, 72.5) | 0° | TDI pull-up |
| R4 | 10kΩ | 0402 | (77.5, 77.5) | 0° | TRST pull-up |

### 3.6 Expansion Headers (Edges)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| J5 | 2x20 Box Header | PinHeader | (5, 50) | 0° | GPIO, board edge |
| J6 | 2x10 Box Header | PinHeader | (95, 50) | 0° | Logic analyzer, board edge |

### 3.7 Status LEDs (20,85) to (40,95)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| D1 | Green LED | LED_0603 | (22.5, 85) | 0° | Heartbeat |
| D2 | Red LED | LED_0603 | (27.5, 85) | 0° | Error |
| D3 | Blue LED | LED_0603 | (32.5, 85) | 0° | JTAG active |
| D4 | Yellow LED | LED_0603 | (37.5, 85) | 0° | UART activity |
| R7 | 1kΩ | 0402 | (22.5, 87.5) | 0° | LED1 current limit |
| R8 | 1kΩ | 0402 | (27.5, 87.5) | 0° | LED2 current limit |
| R9 | 1kΩ | 0402 | (32.5, 87.5) | 0° | LED3 current limit |
| R10 | 1kΩ | 0402 | (37.5, 87.5) | 0° | LED4 current limit |

### 3.8 Reset Switch (25,90) to (35,95)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| SW1 | PTS645 Tactile | Switch_Tactile | (27.5, 92.5) | 0° | Manual reset |
| C57 | 10nF | 0402 | (27.5, 82.5) | 0° | Reset debounce |
| C58 | 10nF | 0402 | (32.5, 82.5) | 0° | Reset debounce |
| R15 | 10kΩ | 0402 | (22.5, 82.5) | 0° | Reset debounce RC |
| R16 | 10kΩ | 0402 | (37.5, 82.5) | 0° | Reset debounce RC |

### 3.9 Test Points (10,80) to (20,90)

| Ref | Component | Package | Position | Rotation | Notes |
|-----|-----------|---------|----------|----------|-------|
| J7 | 3.3V Test Point | PinHeader_1x3 | (10, 82.5) | 0° | Power verification |
| J8 | 1.8V Test Point | PinHeader_1x3 | (15, 82.5) | 0° | Power verification |
| TP3 | GND Test Point | Via | (20, 82.5) | 0° | Ground reference |

---

## 4. Assembly Notes

### 4.1 Solder Paste

| Layer | Thickness | Purpose |
|-------|-----------|---------|
| F.Paste | 0.1mm | Top side components (all SMT) |
| B.Paste | 0.1mm | Bottom side (none — no bottom components) |

### 4.2 Stencil Design

- **Stencil type:** Laser-cut stainless steel
- **Aperture size:** 1:1 pad ratio for 0402, 0.8:1 for 0603, 0.7:1 for 0805+
- **Frame:** Standard 290mm × 290mm for PCB assembly

### 4.3 Reflow Profile

| Stage | Temperature | Time | Notes |
|-------|-------------|------|-------|
| Preheat | 150°C | 60-90s | Flux activation |
| Thermal soak | 150-200°C | 60-90s | Temperature equalization |
| Reflow | 235-245°C | 30-60s | Lead-free SAC305 |
| Cooling | < 100°C | — | Avoid thermal shock |

### 4.4 Assembly Order

1. **Stencil printing** — Apply solder paste to F.Paste layer
2. **Component placement** — SMT pick-and-place machine
3. **Reflow soldering** — Lead-free profile (SAC305)
4. **Visual inspection** — Check for solder bridges, tombstoning
5. **Through-hole insertion** — Connectors, mounting holes
6. **Wave/selective soldering** — Through-hole components
7. **Final inspection** — AOI + manual check
8. **Functional test** — Power-on, UART, JTAG verification

---

## 5. Component Count Summary

| Category | Count | Packages |
|----------|-------|----------|
| ICs | 10 | LQFP-64, SOT-23-5/6, WSON-8, SOT-353, Oscillator_5032 |
| Capacitors | 58 | 0402 (50), 0805 (4), 1206 (2), 0402 (2) |
| Resistors | 18 | 0402 (18) |
| Inductors | 2 | 1210 (2) |
| Connectors | 8 | USB_C, BarrelJack, QFN-64, PinHeader |
| LEDs | 4 | 0603 (4) |
| Switches | 1 | Tactile (1) |
| **Total** | **101** | — |

---

## 6. Manufacturing Specifications

| Parameter | Value |
|-----------|-------|
| Board size | 100mm × 100mm |
| Layer count | 4 |
| Thickness | 1.6mm |
| Copper weight | 1 oz (35µm) |
| Finish | Lead-free HASL |
| Solder mask | Green LPI |
| Silkscreen | White |
| Min track/space | 0.15mm / 0.15mm |
| Min drill | 0.3mm |
| Via tenting | Yes |

---

## 7. Quality Control Checkpoints

### 7.1 Pre-Assembly
- [ ] PCB visual inspection (no scratches, oxidation)
- [ ] Stencil alignment verification
- [ ] Solder paste inspection (SPI)

### 7.2 Post-Reflow
- [ ] AOI (Automated Optical Inspection)
- [ ] X-ray inspection (BGA/QFN thermal pads)
- [ ] Manual inspection (connectors, LEDs)

### 7.3 Post-Assembly
- [ ] Visual inspection (solder bridges, tombstoning)
- [ ] Electrical test (continuity, short detection)
- [ ] Functional test (power-on, UART, JTAG)

---

## 8. File List

| File | Description |
|------|-------------|
| `grx930_test_board_cpl.csv` | Pick-and-place file (CPL) |
| `ASSEMBLY_DRAWING.md` | This document |
| `PCB_LAYOUT_GUIDE.md` | PCB design rules |
| `GRX930_test_board.md` | Design document |
| `GRX930_test_board_bom.csv` | Bill of materials |

---

*This assembly drawing provides the reference for PCB fabrication and assembly. Use the CPL file for automated pick-and-place machines.*
