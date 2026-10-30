#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""
Seal Ring Generator for wafer.space GF180MCU submission
Creates a seal ring around the die edge for protection
"""

import sys
import os

try:
    import klayout.db as db
except ImportError:
    print("ERROR: klayout package not installed. Install with: pip install klayout")
    sys.exit(1)


def add_seal_ring(layout, top_cell, width=10, margin=5):
    """
    Add seal ring around the die
    
    Args:
        layout: KLayout layout object
        top_cell: Top cell to add seal ring to
        width: Seal ring width in microns
        margin: Margin from die edge in microns
    """
    # Get die bounding box
    bbox = top_cell.bbox()
    
    # Calculate seal ring coordinates (in microns, convert to DBU)
    dbu = layout.dbu * 1000000  # Convert to microns
    x1 = bbox.left / dbu + margin
    y1 = bbox.bottom / dbu + margin
    x2 = bbox.right / dbu - margin
    y2 = bbox.top / dbu - margin
    
    # Seal ring layers (GF180MCU)
    # Metal5 for power ring
    metal5_layer = db.LayerInfo(14, 0)  # Metal5
    metal5_idx = layout.layer(metal5_layer)
    
    # Metal1 for guard ring
    metal1_layer = db.LayerInfo(6, 0)  # Metal1
    metal1_idx = layout.layer(metal1_layer)
    
    # N-Well for guard ring
    nwell_layer = db.LayerInfo(3, 0)  # N-Well
    nwell_idx = layout.layer(nwell_layer)
    
    # Create seal ring path
    # Outer ring on Metal5
    ring_width = width
    
    # Top edge
    top_edge = db.Path([
        db.Point(int(x1 * dbu), int((y2 - ring_width) * dbu)),
        db.Point(int(x2 * dbu), int((y2 - ring_width) * dbu)),
        db.Point(int(x2 * dbu), int(y2 * dbu)),
        db.Point(int(x1 * dbu), int(y2 * dbu))
    ], int(ring_width * dbu))
    
    # Bottom edge
    bottom_edge = db.Path([
        db.Point(int(x1 * dbu), int(y1 * dbu)),
        db.Point(int(x2 * dbu), int(y1 * dbu)),
        db.Point(int(x2 * dbu), int((y1 + ring_width) * dbu)),
        db.Point(int(x1 * dbu), int((y1 + ring_width) * dbu))
    ], int(ring_width * dbu))
    
    # Left edge
    left_edge = db.Path([
        db.Point(int(x1 * dbu), int(y1 * dbu)),
        db.Point(int((x1 + ring_width) * dbu), int(y1 * dbu)),
        db.Point(int((x1 + ring_width) * dbu), int(y2 * dbu)),
        db.Point(int(x1 * dbu), int(y2 * dbu))
    ], int(ring_width * dbu))
    
    # Right edge
    right_edge = db.Path([
        db.Point(int((x2 - ring_width) * dbu), int(y1 * dbu)),
        db.Point(int(x2 * dbu), int(y1 * dbu)),
        db.Point(int(x2 * dbu), int(y2 * dbu)),
        db.Point(int((x2 - ring_width) * dbu), int(y2 * dbu))
    ], int(ring_width * dbu))
    
    # Add to cell
    top_cell.shapes(metal5_idx).insert(top_edge)
    top_cell.shapes(metal5_idx).insert(bottom_edge)
    top_cell.shapes(metal5_idx).insert(left_edge)
    top_cell.shapes(metal5_idx).insert(right_edge)
    
    # Add guard ring on Metal1 (thinner)
    guard_width = 2
    guard_margin = margin + width + 2
    
    # Guard ring coordinates
    gx1 = bbox.left / dbu + guard_margin
    gy1 = bbox.bottom / dbu + guard_margin
    gx2 = bbox.right / dbu - guard_margin
    gy2 = bbox.top / dbu - guard_margin
    
    # Guard ring path
    guard_ring = db.Path([
        db.Point(int(gx1 * dbu), int(gy1 * dbu)),
        db.Point(int(gx2 * dbu), int(gy1 * dbu)),
        db.Point(int(gx2 * dbu), int(gy2 * dbu)),
        db.Point(int(gx1 * dbu), int(gy2 * dbu))
    ], int(guard_width * dbu))
    
    top_cell.shapes(metal1_idx).insert(guard_ring)
    
    # Add N-Well around guard ring
    nwell_width = 4
    nwell_ring = db.Path([
        db.Point(int((gx1 - nwell_width) * dbu), int((gy1 - nwell_width) * dbu)),
        db.Point(int((gx2 + nwell_width) * dbu), int((gy1 - nwell_width) * dbu)),
        db.Point(int((gx2 + nwell_width) * dbu), int((gy2 + nwell_width) * dbu)),
        db.Point(int((gx1 - nwell_width) * dbu), int((gy2 + nwell_width) * dbu))
    ], int(nwell_width * dbu))
    
    top_cell.shapes(nwell_idx).insert(nwell_ring)
    
    print(f"✓ Seal ring added:")
    print(f"  - Metal5 power ring: {width} µm wide")
    print(f"  - Metal1 guard ring: {guard_width} µm wide")
    print(f"  - N-Well guard ring: {nwell_width} µm wide")
    
    return True


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input_gds> [output_gds]")
        print(f"  If output_gds not specified, adds '_sealed' suffix")
        sys.exit(1)
    
    input_gds = sys.argv[1]
    if len(sys.argv) > 2:
        output_gds = sys.argv[2]
    else:
        base, ext = os.path.splitext(input_gds)
        output_gds = f"{base}_sealed{ext}"
    
    print(f"Input:  {input_gds}")
    print(f"Output: {output_gds}")
    print("=" * 60)
    
    # Load GDS
    layout = db.Layout()
    layout.read(input_gds)
    
    # Get top cell
    top_cells = layout.top_cells()
    if len(top_cells) != 1:
        print(f"ERROR: Expected 1 top cell, found {len(top_cells)}")
        sys.exit(1)
    
    top_cell = top_cells[0]
    print(f"Top cell: {top_cell.name}")
    
    # Add seal ring
    if add_seal_ring(layout, top_cell):
        # Write output
        layout.write(output_gds)
        print(f"\n✓ Saved to: {output_gds}")
    else:
        print("ERROR: Failed to add seal ring")
        sys.exit(1)


if __name__ == "__main__":
    main()
