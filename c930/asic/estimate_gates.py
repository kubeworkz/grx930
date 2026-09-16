#!/usr/bin/env python3
"""
estimate_gates.py — Derive ASIC gate count from FPGA utilization data.

No Yosys required. Uses the known FPGA resource counts and standard
conversion factors to produce a NAND2-equivalent gate count estimate.

Usage:
    python estimate_gates.py
    python estimate_gates.py --sky130    # Include SKY130 area estimate
"""

import argparse
import json
import sys

# ============================================================
# FPGA resource counts (from xc7a200t post-impl)
# ============================================================
FPGA_RESOURCES = {
    "LUT4_logic":   118_000,   # LUTs used as combinational logic
    "LUT4_memory":   7_735,    # LUTs used as distributed RAM
    "FF":           67_007,    # Flip-flops (FDRE/FDCE)
    "BRAM36":           55,    # 36Kb block RAMs (each = 32,768 bits)
    "DSP48":           227,    # DSP48E1 slices (25x18 multiplier)
    "BUFG":              1,    # Global clock buffer
}

# ============================================================
# Conversion factors (NAND2-equivalent gates)
# ============================================================
# These are industry-standard approximations:
#   - 1 LUT4 ≈ 4–6 gates (4:1 MUX + control logic)
#   - 1 FF   ≈ 6–8 gates (D-FF + setup/hold + scan MUX for DFT)
#   - 1 BRAM36Kb ≈ 5,000–8,000 gates (SRAM array + decoder + sense amps)
#   - 1 DSP48 ≈ 500–800 gates (24x24 signed multiplier)
#   - 1 BUFG ≈ 10 gates (clock buffer)

GATES_PER = {
    "LUT4_logic":  (5.0, "4:1 MUX + AND/OR logic"),
    "LUT4_memory": (6.0, "distributed RAM cell"),
    "FF":          (7.0, "D-FF + setup/hold + scan MUX"),
    "BRAM36":      (6500, "SRAM macro (32KB)"),
    "DSP48":       (650, "24x24 signed multiplier"),
    "BUFG":        (10, "clock buffer"),
}

# ============================================================
# SKY130 area estimates
# ============================================================
SKY130 = {
    "cell_density": 330_000,       # NAND2-equivalent gates per mm2
    "gate_area_um2": 0.757,        # single NAND2 gate area in µm²
    "sram_bit_area_um2": 4.0,      # per-bit SRAM area (HD bit-cell)
    "process": "130nm",
    "metal_layers": 4,
    "supply_voltage": 1.8,
}

TSMC_N28 = {
    "cell_density": 3_500_000,     # NAND2-equivalent gates per mm2
    "gate_area_um2": 0.072,        # single NAND2 gate area in µm²
    "sram_bit_area_um2": 0.06,     # per-bit SRAM area (HD bit-cell)
    "process": "28nm",
    "metal_layers": 10,
    "supply_voltage": 0.9,
}


def estimate_gates():
    """Estimate gate count from FPGA resources."""
    results = {}
    total_low = 0
    total_high = 0

    for resource, count in FPGA_RESOURCES.items():
        low_factor, high_factor = {
            "LUT4_logic":  (4.5, 5.5),
            "LUT4_memory": (5.5, 6.5),
            "FF":          (6.0, 8.0),
            "BRAM36":      (5000, 8000),
            "DSP48":       (500, 800),
            "BUFG":        (8, 12),
        }[resource]

        low = int(count * low_factor)
        high = int(count * high_factor)
        total_low += low
        total_high += high

        results[resource] = {
            "count": count,
            "gates_low": low,
            "gates_high": high,
            "description": GATES_PER[resource][1],
        }

    return results, total_low, total_high


def estimate_area(total_gates, tech):
    """Estimate die area from gate count."""
    area_mm2 = total_gates / tech["cell_density"]
    area_um2 = area_mm2 * 1e6
    return area_mm2, area_um2


def estimate_sram_area():
    """Estimate SRAM macro area (separate from logic)."""
    # Total SRAM: 55 BRAM36 x 32,768 bits = 1,802,240 bits
    total_bits = 55 * 32768
    sky130_area_mm2 = (total_bits * SKY130["sram_bit_area_um2"]) / 1e6
    n28_area_mm2 = (total_bits * TSMC_N28["sram_bit_area_um2"]) / 1e6
    return {
        "total_bits": total_bits,
        "sky130_area_mm2": round(sky130_area_mm2, 2),
        "n28_area_mm2": round(n28_area_mm2, 2),
    }


def main():
    parser = argparse.ArgumentParser(description="Estimate GRX930 ASIC gate count")
    parser.add_argument("--sky130", action="store_true", help="Include SKY130 area estimates")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()

    results, total_low, total_high = estimate_gates()
    sram = estimate_sram_area()

    mid = (total_low + total_high) // 2

    if args.json:
        output = {
            "resources": results,
            "gate_count": {"low": total_low, "mid": mid, "high": total_high},
            "sram": sram,
            "sky130_area_mm2": round(mid / SKY130["cell_density"], 2) + sram["sky130_area_mm2"],
            "n28_area_mm2": round(mid / TSMC_N28["cell_density"], 2) + sram["n28_area_mm2"],
        }
        print(json.dumps(output, indent=2))
        return

    # Pretty print
    print("=" * 70)
    print("GRX930 ASIC Gate Count Estimation (from FPGA utilization)")
    print("=" * 70)
    print()

    print(f"{'Resource':<20} {'Count':>8} {'Gates (low)':>12} {'Gates (high)':>12}  Notes")
    print("-" * 70)
    for resource, data in results.items():
        print(f"{resource:<20} {data['count']:>8,} {data['gates_low']:>12,} {data['gates_high']:>12,}  {data['description']}")

    print("-" * 70)
    print(f"{'TOTAL':<20} {'':>8} {total_low:>12,} {total_high:>12,}")
    print(f"{'MIDPOINT':<20} {'':>8} {mid:>12,}")
    print()

    # SRAM area
    print("SRAM Macro Area:")
    print(f"  Total bits: {sram['total_bits']:,}")
    print(f"  SKY130: {sram['sky130_area_mm2']:.2f} mm2")
    print(f"  TSMC N28: {sram['n28_area_mm2']:.2f} mm2")
    print()

    # Die area
    sky130_logic = mid / SKY130["cell_density"]
    sky130_total = sky130_logic + sram["sky130_area_mm2"]
    n28_logic = mid / TSMC_N28["cell_density"]
    n28_total = n28_logic + sram["n28_area_mm2"]

    print("Die Area Estimates:")
    print(f"  SKY130 (130nm): {sky130_total:.1f} mm2  (logic: {sky130_logic:.1f}, SRAM: {sram['sky130_area_mm2']:.1f})")
    print(f"  TSMC N28:       {n28_total:.1f} mm2   (logic: {n28_logic:.1f}, SRAM: {sram['n28_area_mm2']:.1f})")
    print()

    # Shuttle tier fit check
    print("Shuttle Fit Check:")
    if sky130_total <= 10.0:
        print(f"  OpenMPW (free, <=10mm2): [OK] FITS ({sky130_total:.1f} mm2)")
    else:
        print(f"  OpenMPW (free, <=10mm2): [FAIL] ({sky130_total:.1f} mm2 > 10 mm2)")
    if sky130_total <= 16.0:
        print(f"  ChipIgnite ($10K, <=16mm2): [OK] FITS ({sky130_total:.1f} mm2)")
    else:
        print(f"  ChipIgnite ($10K, <=16mm2): [FAIL] ({sky130_total:.1f} mm2 > 16 mm2)")
    if sky130_total <= 30.0:
        print(f"  ChipIgnite ($30K, <=30mm2): [OK] FITS ({sky130_total:.1f} mm2)")
    else:
        print(f"  ChipIgnite ($30K, <=30mm2): [FAIL] ({sky130_total:.1f} mm2 > 30 mm2)")

    print()

    # FPGA comparison
    fpga_luts = FPGA_RESOURCES["LUT4_logic"] + FPGA_RESOURCES["LUT4_memory"]
    print(f"FPGA vs ASIC Gate Ratio:")
    print(f"  FPGA LUT4s: {fpga_luts:,} -> ASIC: ~{mid:,} gates ({mid/fpga_luts:.1f}x per LUT)")
    print(f"  FPGA FFs:   {FPGA_RESOURCES['FF']:,} -> ASIC: ~{FPGA_RESOURCES['FF']*7:,} gates")
    print()


if __name__ == "__main__":
    main()
