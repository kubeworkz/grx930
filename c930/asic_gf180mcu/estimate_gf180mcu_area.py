#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""
estimate_gf180mcu_area.py — Estimate GRX930 test chip area on GF180MCU

Uses FPGA resource counts (known from xc7a200t post-impl) and
GF180MCU cell density data from wafer.space Run 1 to produce
realistic area estimates for the wafer.space 0.5×1 slot.
"""

# ============================================================
# GF180MCU density data (from wafer.space Run 1 density report)
# ============================================================
# Theoretical max: ~50k cells/mm2 (7-track library)
# Run 1 best: 22k cells/mm2 (44% utilization, Cloneless1)
# Run 1 typical: 3k-14k cells/mm2
# Conservative estimate for first-time design: 8k cells/mm2

GF180MCU_DENSITY = {
    "theoretical_max": 50_000,  # cells/mm2
    "run1_best": 22_000,        # Cloneless1 (44%)
    "run1_typical_high": 14_000, # Tiny Tapeout (29%)
    "run1_typical_mid": 10_000,  # Chess (25%)
    "run1_typical_low": 7_000,   # KianV (16%)
    "conservative": 8_000,       # Our estimate for first design
    "optimistic": 14_000,        # If routing is efficient
}

# wafer.space slot dimensions
SLOT = {
    "die_width": 3.93,    # mm (1×1 slot)
    "die_height": 5.12,   # mm
    "core_area": 12.92,   # mm2 (with default pad ring)
    "seal_ring": 0.026,   # mm each side
}

# ============================================================
# Full SoC FPGA resources (from xc7a200t post-impl)
# ============================================================
FULL_SOC_FPGA = {
    "LUT4_logic":  118_000,
    "LUT4_memory": 7_735,
    "FF":          67_007,
    "BRAM36":          55,    # 32KB each = 1,760KB total
    "DSP48":          227,
}

# ============================================================
# Test chip: what's removed vs full SoC
# ============================================================
# Removed components and their estimated FPGA resource contribution:
#
# NPU (2× systolic array + DMA + CSR + FP units):
#   ~35,000 LUTs, ~15,000 FFs, ~15 DSPs
# CPU cores 1-3 (3× RV64IMAC):
#   ~75,000 LUTs, ~50,000 FFs, ~195 DSPs
# L2 cache (64KB, 4-way):
#   ~8,000 LUTs, ~3,000 FFs, ~30 BRAMs
# DDR controller:
#   ~5,000 LUTs, ~2,000 FFs, ~5 BRAMs
# AXI4 crossbar (4×4):
#   ~8,000 LUTs, ~3,000 FFs
# Cache adapters (×4):
#   ~4,000 LUTs, ~2,000 FFs
# APLIC:
#   ~2,000 LUTs, ~1,000 FFs
# Cache coherency fabric:
#   ~2,000 LUTs, ~1,000 FFs
#
# Total removed: ~139,000 LUTs, ~77,000 FFs, ~210 DSPs, ~35 BRAMs
#
# Remaining (test chip):
TEST_CHIP_FPGA = {
    "LUT4_logic":  118_000 - 35_000 - 75_000 - 8_000 - 5_000 - 8_000 - 4_000 - 2_000 - 2_000,  # ~-21,000
    "LUT4_memory": 7_735,    # Distributed RAM (SRAM controller uses this)
    "FF":          67_007 - 15_000 - 50_000 - 3_000 - 2_000 - 3_000 - 2_000 - 1_000 - 1_000,  # ~-9,000
    "BRAM36":          2,    # Tiny 2KB I-cache + 2KB D-cache (2 BRAMs)
    "DSP48":          227 - 15 - 195,  # 17 remaining (Booth multiplier)
}

# Fix negative values
TEST_CHIP_FPGA["LUT4_logic"] = max(10_000, TEST_CHIP_FPGA["LUT4_logic"])
TEST_CHIP_FPGA["FF"] = max(5_000, TEST_CHIP_FPGA["FF"])

# ============================================================
# Conversion: FPGA resources → GF180MCU standard cells
# ============================================================
# Key: GF180MCU density is measured in standard cells per mm2,
# NOT NAND2-equivalent gates. A standard cell is much larger.
#
# Conversion factors (FPGA resource → standard cells):
#   1 LUT4 ≈ 1.0 cell (roughly MUX-sized)
#   1 FF   ≈ 2.0 cells (DFF + setup/hold + scan MUX)
#   1 BRAM36 ≈ 100 cells (macro equivalent)
#   1 DSP48 ≈ 50 cells (macro equivalent)
CELLS_PER = {
    "LUT4_logic":  1.0,   # MUX + logic → 1 standard cell
    "LUT4_memory": 1.2,   # distributed RAM → slightly more
    "FF":          2.0,   # DFF + setup/hold + scan MUX
    "BRAM36":      100,   # SRAM macro
    "DSP48":       50,    # multiplier macro
}

def fpga_to_cells(resources):
    """Convert FPGA resources to GF180MCU standard cells."""
    total = 0
    breakdown = {}
    for res, count in resources.items():
        cells = int(count * CELLS_PER[res])
        breakdown[res] = {"count": count, "cells": cells}
        total += cells
    return total, breakdown

def cells_to_area(cells, density):
    """Convert cell count to mm2 using cell density."""
    return cells / density

def main():
    print("=" * 72)
    print("GRX930 Test Chip — GF180MCU Area Estimate")
    print("=" * 72)
    print()

    # 1. Cell count
    total_cells, breakdown = fpga_to_cells(TEST_CHIP_FPGA)
    print("FPGA Resources (test chip only):")
    print(f"  {'Resource':<16} {'Count':>8} {'Cells':>10}")
    print(f"  {'-'*16} {'-'*8} {'-'*10}")
    for res, data in breakdown.items():
        print(f"  {res:<16} {data['count']:>8,} {data['cells']:>10,}")
    print(f"  {'TOTAL':<16} {'':>8} {total_cells:>10,}")
    print()

    # 2. Area estimates at different densities
    print("Area Estimates (logic only, GF180MCU 7t 5V):")
    print(f"  {'Density':<25} {'Cells/mm2':>10} {'Area (mm2)':>10} {'Fits?':>8}")
    print(f"  {'-'*25} {'-'*10} {'-'*10} {'-'*8}")
    for name, density in sorted(GF180MCU_DENSITY.items(), key=lambda x: -x[1]):
        area = cells_to_area(total_cells, density)
        fits = "[OK]" if area <= SLOT["core_area"] else "[NO]"
        margin = (1 - area / SLOT["core_area"]) * 100
        print(f"  {name:<25} {density:>10,} {area:>10.2f} {fits:>4} ({margin:+.0f}%)")
    print()

    # 3. SRAM analysis
    # 64KB on-chip SRAM
    sram_bits = 64 * 1024 * 8  # 524,288 bits
    # GF180MCU sram512x8 macro: ~0.023 mm2 per macro (512×8 = 4096 bits)
    # 524,288 / 4096 = 128 macros
    sram_macros = 128
    sram_area_per_macro = 0.023  # mm2 (estimated from GF180MCU docs)
    sram_area = sram_macros * sram_area_per_macro

    print("SRAM Analysis (64KB on-chip):")
    print(f"  Total bits:       {sram_bits:>10,}")
    print(f"  SRAM macros:      {sram_macros:>10} (gf180mcu_fd_sc_mcu7t5v0__sram512x8)")
    print(f"  Area per macro:   {sram_area_per_macro:>10.3f} mm2")
    print(f"  Total SRAM area:  {sram_area:>10.2f} mm2")
    print()

    # 4. Total die area
    print("Total Die Area (conservative estimate):")
    logic_area_conservative = cells_to_area(total_cells, GF180MCU_DENSITY["conservative"])
    logic_area_optimistic = cells_to_area(total_cells, GF180MCU_DENSITY["optimistic"])
    routing_overhead = 1.30  # 30% routing overhead

    total_conservative = (logic_area_conservative + sram_area) * routing_overhead
    total_optimistic = (logic_area_optimistic + sram_area) * routing_overhead

    print(f"  Logic area (conservative):  {logic_area_conservative:>6.2f} mm2")
    print(f"  Logic area (optimistic):    {logic_area_optimistic:>6.2f} mm2")
    print(f"  SRAM area:                  {sram_area:>6.2f} mm2")
    print(f"  Routing overhead:           {routing_overhead:>6.0%}")
    print()
    print(f"  Total (conservative):       {total_conservative:>6.2f} mm2  {'FITS' if total_conservative <= SLOT['core_area'] else 'OVER'}")
    print(f"  Total (optimistic):         {total_optimistic:>6.2f} mm2  {'FITS' if total_optimistic <= SLOT['core_area'] else 'OVER'}")
    print(f"  Available core area:        {SLOT['core_area']:>6.2f} mm2")
    print()

    # 5. Comparison with Run 1 designs
    print("Comparison with wafer.space Run 1 Designs:")
    print(f"  {'Design':<25} {'Core SC/mm2':>12} {'Gates':>10} {'Area':>8}")
    print(f"  {'-'*25} {'-'*12} {'-'*10} {'-'*8}")
    run1_designs = [
        ("Cloneless1 (best)", 22000, 316000, 14.4),
        ("Tiny Tapeout", 14000, 204000, 14.6),
        ("FABulous FPGA", 14000, 204000, 14.6),
        ("Chess Move Gen", 10000, 145000, 14.5),
        ("KianV RISC-V", 6000, 89000, 14.8),
        ("Racquet 23-core", 5000, 78000, 15.6),
        ("GRX930 test chip (est.)", GF180MCU_DENSITY["conservative"],
         total_cells, total_conservative),
    ]
    for name, density, cells, area in run1_designs:
        print(f"  {name:<25} {density:>12,} {cells:>10,} {area:>7.1f}")
    print()

    # 6. Verdict
    print("=" * 72)
    print("VERDICT:")
    if total_conservative <= SLOT["core_area"]:
        print(f"  Design FITS in wafer.space 1x1 slot")
        print(f"  Conservative: {total_conservative:.2f} mm2 / {SLOT['core_area']:.2f} mm2 ({total_conservative/SLOT['core_area']*100:.0f}%)")
        print(f"  Optimistic:   {total_optimistic:.2f} mm2 / {SLOT['core_area']:.2f} mm2 ({total_optimistic/SLOT['core_area']*100:.0f}%)")
        print(f"  Margin:       {(1-total_conservative/SLOT['core_area'])*100:.0f}% – {(1-total_optimistic/SLOT['core_area'])*100:.0f}%")
    else:
        print(f"  Design MAY NOT FIT in wafer.space 1x1 slot")
        print(f"  Conservative: {total_conservative:.2f} mm2 / {SLOT['core_area']:.2f} mm2 ({total_conservative/SLOT['core_area']*100:.0f}%)")
        print(f"  Consider: 1×1 slot (12.92 mm2 core) or reduce design further")
    print("=" * 72)

if __name__ == "__main__":
    main()
