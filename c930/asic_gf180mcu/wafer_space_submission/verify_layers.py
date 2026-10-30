#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""
Layer verification script for wafer.space GF180MCU submission
Verifies GDS layers match foundry requirements
"""

import sys
import os

try:
    import klayout.db as db
except ImportError:
    print("ERROR: klayout package not installed. Install with: pip install klayout")
    sys.exit(1)


def verify_gds(gds_path):
    """Verify GDS file for wafer.space submission"""
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
    
    print(f"Die size: {die_width:.1f} × {die_height:.1f} µm")
    
    # Check die size (wafer.space 1×1 slot: 3930 × 5120 µm)
    if abs(die_width - 3930) > 10 or abs(die_height - 5120) > 10:
        print(f"WARNING: Die size mismatch (expected 3930 × 5120 µm)")
        return False
    
    print("✓ Die size matches wafer.space 1×1 slot")
    
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
        print("✓ GDS verification PASSED")
        print("✓ Ready for wafer.space submission")
        return True
    else:
        print("✗ GDS verification FAILED")
        print("✗ Fix missing layers before submission")
        return False


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <gds_file>")
        sys.exit(1)
    
    gds_path = sys.argv[1]
    success = verify_gds(gds_path)
    sys.exit(0 if success else 1)
