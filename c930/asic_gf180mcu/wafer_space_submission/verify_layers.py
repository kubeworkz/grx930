#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""
Layer verification script for wafer.space GF180MCU submission
Verifies GDS layers match foundry requirements
"""

import sys
import os
import re

try:
    import klayout.db as db
except ImportError:
    print("ERROR: klayout package not installed. Install with: pip install klayout")
    sys.exit(1)


def read_def_die(def_path):
    """Return width, height, and (x1, y1, x2, y2) bounds from a DEF DIEAREA."""
    with open(def_path, "r", encoding="utf-8") as f:
        text = f.read()
    units = re.search(r"^UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", text, re.MULTILINE)
    die = re.search(
        r"^DIEAREA\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)",
        text,
        re.MULTILINE,
    )
    if units is None or die is None:
        raise ValueError(f"DEF UNITS/DIEAREA missing in {def_path}")
    scale = float(units.group(1))
    x1, y1, x2, y2 = (float(v) for v in die.groups())
    return (x2 - x1) / scale, (y2 - y1) / scale, (x1 / scale, y1 / scale, x2 / scale, y2 / scale)


def verify_gds(gds_path, def_path):
    """Verify GDS layers and die containment for the VOID package."""
    print("Package status: VOID — DO NOT SUBMIT (diagnostic only)")
    print(f"Verifying GDS: {gds_path}")
    print("=" * 60)
    
    if not os.path.exists(gds_path):
        print(f"ERROR: File not found: {gds_path}")
        return False
    
    # Load GDS
    layout = db.Layout()
    layout.read(gds_path)
    
    # Get top cell
    top_cells = layout.top_cells()
    if len(top_cells) != 1:
        print(f"ERROR: Expected 1 top cell, found {len(top_cells)}")
        return False
    
    top_cell = top_cells[0]
    print(f"Top cell: {top_cell.name}")
    
    # Get die bounding box
    bbox = top_cell.bbox()
    dbu = layout.dbu  # DBU in microns
    die_width = bbox.width() * dbu  # Convert from DBU to microns
    die_height = bbox.height() * dbu
    
    print(f"VOID GDS top-cell bbox: {die_width:.3f} × {die_height:.3f} µm")
    print(f"VOID GDS bounds: ({bbox.left * dbu:.3f}, {bbox.bottom * dbu:.3f}) to ({bbox.right * dbu:.3f}, {bbox.top * dbu:.3f}) µm")
    
    # The DEF DIEAREA is the die authority; the GDS top-cell bbox is only the
    # routed content extent and must fit inside that die.
    if not os.path.exists(def_path):
        print(f"ERROR: DEF not found: {def_path}")
        return False
    try:
        def_width, def_height, (dx1, dy1, dx2, dy2) = read_def_die(def_path)
    except ValueError as exc:
        print(f"ERROR: {exc}")
        return False
    print(f"DEF die: {def_width:.3f} × {def_height:.3f} µm (DIEAREA authority)")
    print(f"DEF die bounds: ({dx1:.3f}, {dy1:.3f}) to ({dx2:.3f}, {dy2:.3f}) µm")
    eps = 1e-6
    if (bbox.left * dbu < dx1 - eps or bbox.bottom * dbu < dy1 - eps or
            bbox.right * dbu > dx2 + eps or bbox.top * dbu > dy2 + eps):
        print("ERROR: GDS content extends outside the DEF die")
        return False
    print(f"✓ GDS content fits inside the DEF die ({def_width:.3f} × {def_height:.3f} µm)")
    
    # Count layers
    layer_set = set()
    for layer_idx in layout.layer_indices():
        layer_info = layout.get_info(layer_idx)
        layer_set.add((layer_info.layer, layer_info.datatype))
    
    print(f"\nLayers found: {len(layer_set)}")
    
    # Check for required layers (GF180MCU layer numbers)
    # Note: N-Well (3.0) is not in GDS - well is defined by foundry process
    required_layers = {
        (1, 1): "Active",
        (2, 1): "P-Well",
        (5, 1): "Poly",
        (5, 0): "Contact",
        (6, 0): "Metal1",
        (7, 0): "Via1",
        (8, 0): "Metal2",
        (9, 0): "Via2",
        (10, 0): "Metal3",
        (11, 0): "Via3",
        (12, 0): "Metal4",
        (13, 0): "Via4",
        (14, 0): "Metal5",
    }
    
    print("\nRequired layer check:")
    all_layers_ok = True
    for (layer, datatype), name in sorted(required_layers.items()):
        if (layer, datatype) in layer_set:
            print(f"  ✓ {name} ({layer}.{datatype})")
        else:
            print(f"  ✗ {name} ({layer}.{datatype}) - MISSING")
            all_layers_ok = False
    
    # Count instances
    instance_count = 0
    for inst in top_cell.each_inst():
        instance_count += 1
    
    print(f"\nCell instances: {instance_count}")
    
    # Summary
    print("\n" + "=" * 60)
    if all_layers_ok:
        print("✓ Layer/die checks passed (diagnostic only)")
        print("✗ Package is VOID — DO NOT SUBMIT")
        return True
    else:
        print("✗ GDS layer verification FAILED")
        print("✗ Package remains VOID — DO NOT SUBMIT")
        return False


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print(f"Usage: {sys.argv[0]} <gds_file> [def_file]")
        sys.exit(1)

    gds_path = sys.argv[1]
    if len(sys.argv) == 3:
        def_path = sys.argv[2]
    else:
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
        def_path = os.path.join(repo_root, "build/lvs_chip/rebased_grx930_test_chip.def")
    success = verify_gds(gds_path, def_path)
    sys.exit(0 if success else 1)
