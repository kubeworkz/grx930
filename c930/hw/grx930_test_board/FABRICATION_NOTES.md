# GRX930 Test Board — Fabrication Notes

**Version:** 1.0  
**Date:** September 17, 2026  
**Project:** GRX930 SoC Test Board  
**Quantity:** 10 boards (prototype run)

---

## 1. PCB Specifications

### 1.1 Board Dimensions

| Parameter | Value |
|-----------|-------|
| Length | 100.00 mm |
| Width | 100.00 mm |
| Thickness | 1.6 mm |
| Tolerance | ±0.15 mm |

### 1.2 Layer Stackup

| Layer | Type | Thickness | Copper |
|-------|------|-----------|--------|
| F.SilkS | Silkscreen | — | — |
| F.Mask | Solder mask | 0.01 mm | — |
| F.Cu | Signal | 0.035 mm | 1 oz |
| Dielectric 1 | Core | 0.21 mm | — |
| In1.Cu | GND plane | 0.035 mm | 1 oz |
| Dielectric 2 | Core | 1.06 mm | — |
| In2.Cu | Power planes | 0.035 mm | 1 oz |
| Dielectric 3 | Core | 0.21 mm | — |
| B.Cu | Signal | 0.035 mm | 1 oz |
| B.Mask | Solder mask | 0.01 mm | — |
| B.SilkS | Silkscreen | — | — |

**Total thickness:** 1.6 mm ± 0.1 mm

### 1.3 Material

| Parameter | Value |
|-----------|-------|
| Base material | FR-4 (TG 170) |
| Dielectric constant | 4.5 @ 1 MHz |
| Dissipation factor | 0.02 @ 1 MHz |
| Flammability | UL 94V-0 |

---

## 2. Copper Specifications

### 2.1 Copper Weight

| Layer | Weight | Thickness |
|-------|--------|-----------|
| F.Cu | 1 oz | 35 µm |
| In1.Cu | 1 oz | 35 µm |
| In2.Cu | 1 oz | 35 µm |
| B.Cu | 1 oz | 35 µm |

### 2.2 Copper Density

| Layer | Target | Min | Max |
|-------|--------|-----|-----|
| F.Cu | 40% | 30% | 70% |
| In1.Cu | 95% | 90% | 100% |
| In2.Cu | 60% | 50% | 80% |
| B.Cu | 30% | 20% | 50% |

---

## 3. Drill Specifications

### 3.1 Through-Hole Drills

| Type | Drill Size | Pad Size | Annular Ring | Quantity |
|------|------------|----------|--------------|----------|
| Signal via | 0.3 mm | 0.6 mm | 0.15 mm | ~500 |
| Power via | 0.8 mm | 1.2 mm | 0.2 mm | ~100 |
| Thermal via | 0.3 mm | 0.6 mm | 0.15 mm | 64 |
| Mounting hole | 3.2 mm | 6.0 mm | 1.4 mm | 4 |
| Connector pin | 1.0 mm | 1.8 mm | 0.4 mm | ~50 |

### 3.2 Drill Tolerance

| Parameter | Value |
|-----------|-------|
| Drill size tolerance | ±0.05 mm |
| Drill position tolerance | ±0.05 mm |
| Annular ring minimum | 0.15 mm |

### 3.3 Blind/Buried Vias

- **None required** — All vias are through-hole
- **Via tenting:** Yes (solder mask over vias)

---

## 4. Trace Specifications

### 4.1 Trace Width

| Type | Width | Tolerance |
|------|-------|-----------|
| Signal | 0.25 mm (10 mil) | ±0.025 mm |
| Power (1A) | 0.5 mm (20 mil) | ±0.05 mm |
| Power (1.5A) | 1.0 mm (40 mil) | ±0.1 mm |
| Power (3A) | 1.5 mm (60 mil) | ±0.15 mm |

### 4.2 Trace Spacing

| Type | Spacing | Tolerance |
|------|---------|-----------|
| Signal-to-signal | 0.2 mm (8 mil) | ±0.025 mm |
| Signal-to-power | 0.3 mm (12 mil) | ±0.025 mm |
| Power-to-power | 0.4 mm (16 mil) | ±0.025 mm |
| Trace-to-edge | 0.5 mm (20 mil) | ±0.05 mm |

### 4.3 Impedance Control

| Type | Impedance | Width | Spacing | Layer |
|------|-----------|-------|---------|-------|
| USB differential | 90Ω ±10% | 0.15 mm | 0.15 mm | F.Cu |
| Clock single-ended | 50Ω ±10% | 0.25 mm | — | F.Cu |
| JTAG single-ended | 50Ω ±10% | 0.25 mm | — | F.Cu |

---

## 5. Solder Mask Specifications

### 5.1 Solder Mask

| Parameter | Value |
|-----------|-------|
| Type | LPI (Liquid Photo-Imageable) |
| Color | Green |
| Thickness | 0.01 mm |
| Registration | ±0.05 mm |

### 5.2 Solder Mask Opening

| Pad Type | Opening | Expansion |
|----------|---------|-----------|
| SMT pad | Pad + 0.05 mm | 0.05 mm |
| Through-hole | Pad + 0.1 mm | 0.1 mm |
| Via (tented) | Closed | — |
| BGA pad | Pad + 0.075 mm | 0.075 mm |

### 5.3 Solder Mask Clearance

| Type | Clearance |
|------|-----------|
| Trace to mask | 0.05 mm |
| Via to mask (tented) | 0 mm |
| Via to mask (open) | 0.05 mm |

---

## 6. Silkscreen Specifications

### 6.1 Silkscreen

| Parameter | Value |
|-----------|-------|
| Type | Liquid ink |
| Color | White |
| Min width | 0.15 mm (6 mil) |
| Min height | 0.8 mm |
| Registration | ±0.1 mm |

### 6.2 Silkscreen Content

- Component reference designators (R1, C1, U1, etc.)
- Component values (100nF, 10k, etc.)
- Polarity markings (LEDs, capacitors)
- Pin 1 indicators (ICs, connectors)
- Board name and revision
- Logo (optional)

---

## 7. Surface Finish

### 7.1 Finish Type

| Parameter | Value |
|-----------|-------|
| Type | Lead-free HASL |
| Thickness | 1-2 µm |
| Composition | Sn96.5/Ag3.0/Cu0.5 (SAC305) |
| Temperature | 260°C max |

### 7.2 Finish Requirements

- Uniform coating on all exposed copper
- No solder bridges between pads
- Flat pads for SMT components
- Adequate solder for through-hole

---

## 8. Electrical Specifications

### 8.1 Test Requirements

| Test | Method | Criteria |
|------|--------|----------|
| Continuity | Flying probe | 100% net connectivity |
| Isolation | Flying probe | > 10 MΩ between nets |
| Impedance | TDR | 50Ω ±10% (single-ended) |
| Impedance | TDR | 90Ω ±10% (differential) |

### 8.2 Power Rails

| Rail | Voltage | Current | Via Count |
|------|---------|---------|-----------|
| +3.3V | 3.3V | 1.0A | 20 |
| +1.8V | 1.8V | 1.5A | 30 |
| GND | 0V | — | 50 |

---

## 9. Mechanical Specifications

### 9.1 Board Outline

| Parameter | Value |
|-----------|-------|
| Shape | Rectangular |
| Dimensions | 100 mm × 100 mm |
| Corner radius | 0 mm (sharp) |
| Edge tolerance | ±0.1 mm |

### 9.2 Mounting Holes

| Hole | Position | Drill | Pad | Plating |
|------|----------|-------|-----|---------|
| H1 | (5, 5) | 3.2 mm | 6.0 mm | Plated |
| H2 | (95, 5) | 3.2 mm | 6.0 mm | Plated |
| H3 | (5, 95) | 3.2 mm | 6.0 mm | Plated |
| H4 | (95, 95) | 3.2 mm | 6.0 mm | Plated |

### 9.3 Tooling Holes

| Hole | Position | Drill | Plating |
|------|----------|-------|---------|
| T1 | (0, 0) | 1.5 mm | Plated |
| T2 | (100, 0) | 1.5 mm | Plated |
| T3 | (0, 100) | 1.5 mm | Plated |

---

## 10. Quality Requirements

### 10.1 Visual Inspection

| Criterion | Requirement |
|-----------|-------------|
| Solder mask | No pinholes, no bridging |
| Silkscreen | Legible, no missing text |
| Copper | No exposed copper (except pads) |
| Board | No warping, no delamination |

### 10.2 Dimensional Inspection

| Parameter | Tolerance |
|-----------|-----------|
| Board dimensions | ±0.15 mm |
| Hole position | ±0.05 mm |
| Hole size | ±0.05 mm |
| Trace width | ±0.025 mm |
| Pad size | ±0.025 mm |

### 10.3 Electrical Test

| Test | Criteria |
|------|----------|
| Continuity | 100% of nets |
| Isolation | > 10 MΩ |
| Impedance | 50Ω ±10% (controlled) |
| Hi-pot | 500V DC, 1 second |

---

## 11. Packaging Requirements

### 11.1 Individual Board Packaging

| Parameter | Value |
|-----------|-------|
| Anti-static bag | Yes (ESD safe) |
| Foam padding | Yes (2mm) |
| Label | Board name, revision, date |
| Orientation | Marked (Pin 1 indicator) |

### 11.2 Bulk Packaging

| Parameter | Value |
|-----------|-------|
| Box | Anti-static |
| Layers | Separated by foam |
| Quantity per box | 10 boards |
| Shipping | ESD-safe packaging |

---

## 12. Documentation Deliverables

| File | Format | Description |
|------|--------|-------------|
| Gerber files | RS-274X | All layers |
| Drill files | Excellon | NC drill |
| Pick-and-place | CSV | Component positions |
| BOM | CSV | Bill of materials |
| Assembly drawing | PDF | Placement reference |
| Fab notes | PDF | This document |

---

## 13. Vendor Requirements

### 13.1 PCB Manufacturer Qualifications

- ISO 9001 certified
- IPC-A-600 Class 2 (or higher)
- UL certified (FR-4 material)
- Lead-free manufacturing capability
- Impedance control capability

### 13.2 Assembly House Qualifications

- IPC-A-610 Class 2 (or higher)
- J-STD-001 certified
- ESD-safe facility (ANSI/ESD S20.20)
- SMT capability (0402 and smaller)
- X-ray inspection capability

---

## 14. Notes

1. **All dimensions in millimeters** unless otherwise specified
2. **IPC-A-600 Class 2** standard applies for workmanship
3. **IPC-2221B** standard applies for PCB design
4. **IPC-7351B** standard applies for footprint design
5. **RoHS compliant** — Lead-free finish and materials
6. **REACH compliant** — No restricted substances

---

*This fabrication notes document provides the specifications for PCB manufacturing and assembly. Submit with Gerber files to your PCB vendor.*
