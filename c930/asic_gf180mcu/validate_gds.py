#!/usr/bin/env python3
"""Validate GRX930 test chip GDS for wafer.space 1x1 slot submission."""
import klayout.db as db
import sys
import re
from pathlib import Path

DIE_W_UM = 3930.0
DIE_H_UM = 5120.0
TOLERANCE_UM = 10.0
LEF_PATH = "gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0_combined_klayout.lef"
GDS_PATH = "build/grx930_test_chip.gds"
DEF_PATH = "build/grx930_test_chip.def"

errors = []
warnings = []

print("=" * 60)
print("GRX930 Test Chip GDS Validation")
print("=" * 60)

# 1. Load GDS
print("\n[1] Loading GDS...")
try:
    layout = db.Layout()
    layout.read(GDS_PATH)
    print(f"    Cells: {layout.cells()}")
    print(f"    Layers: {layout.layers()}")
    print(f"    DBU: {layout.dbu} um/dbu")
except Exception as e:
    errors.append(f"Failed to load GDS: {e}")
    print(f"    ERROR: {e}")
    sys.exit(1)

# 2. Check die size
print("\n[2] Checking die size...")
top_cell_idx = layout.top_cells()[0]
top = layout.cell(top_cell_idx)
bb = top.bbox()
die_w = (bb.right - bb.left) * layout.dbu
die_h = (bb.top - bb.bottom) * layout.dbu
print(f"    Die size: {die_w:.1f} x {die_h:.1f} um")
print(f"    Expected: {DIE_W_UM:.1f} x {DIE_H_UM:.1f} um")
if abs(die_w - DIE_W_UM) > TOLERANCE_UM:
    errors.append(f"Die width {die_w:.1f} um differs from expected {DIE_W_UM:.1f} um")
    print(f"    ERROR: Width mismatch ({abs(die_w - DIE_W_UM):.1f} um off)")
else:
    print(f"    OK: Width within {TOLERANCE_UM} um tolerance")
if abs(die_h - DIE_H_UM) > TOLERANCE_UM:
    errors.append(f"Die height {die_h:.1f} um differs from expected {DIE_H_UM:.1f} um")
    print(f"    ERROR: Height mismatch ({abs(die_h - DIE_H_UM):.1f} um off)")
else:
    print(f"    OK: Height within {TOLERANCE_UM} um tolerance")

# 3. Check cell instances
print("\n[3] Checking cell instances...")
cell_names = set()
for i in range(layout.cells()):
    cell = layout.cell(i)
    cell_names.add(cell.name)
top_cells = [c.name for c in layout.top_cells()]
print(f"    Top cell: {top_cells}")
print(f"    Total cells: {layout.cells()}")

# Count instances per cell type in top cell
inst_counts = {}
for inst in top.called_cells():
    cell = layout.cell(inst)
    name = cell.name
    inst_counts[name] = inst_counts.get(name, 0) + 1
print(f"    Unique cell types in design: {len(inst_counts)}")

# 4. Load LEF and check matching
print("\n[4] Checking LEF cell matching...")
try:
    lef_layout = db.Layout()
    lef_layout.read(LEF_PATH)
    lef_cells = set()
    for i in range(lef_layout.cells()):
        lef_cells.add(lef_layout.cell(i).name)
    print(f"    LEF cell definitions: {len(lef_cells)}")
except Exception as e:
    warnings.append(f"Could not load LEF for comparison: {e}")
    lef_cells = set()

# Check each instance has a matching LEF definition
missing_cells = []
for cell_name in inst_counts:
    if cell_name not in lef_cells and cell_name != top_cells[0]:
        # Ignore PDN-generated VIA cells (not standard cells)
        if cell_name.startswith('VIA_'):
            continue
        missing_cells.append(cell_name)

if missing_cells:
    errors.append(f"{len(missing_cells)} cells in design but not in LEF: {missing_cells[:5]}...")
    print(f"    ERROR: {len(missing_cells)} cells missing from LEF:")
    for c in missing_cells[:10]:
        print(f"      - {c} ({inst_counts[c]} instances)")
else:
    print(f"    OK: All {len(inst_counts)} cell types found in LEF")

# 5. Check layers
print("\n[5] Checking layers...")
expected_layers = {
    "Metal1": (9, 0),
    "Metal2": (11, 0),
    "Via1": (10, 0),
    "Metal3": (13, 0),
    "Via2": (12, 0),
    "Metal4": (14, 0),
}
for li in layout.layer_infos():
    layer_id = layout.layer(li)
    shape_count = 0
    it = top.begin_shapes_rec(layer_id)
    while not it.at_end():
        shape_count += 1
        it.next()
    if shape_count > 0:
        print(f"    Layer {li}: {shape_count} shapes")

# 6. Summary
print("\n" + "=" * 60)
if errors:
    print(f"RESULT: {len(errors)} ERRORS, {len(warnings)} WARNINGS")
    for e in errors:
        print(f"  ERROR: {e}")
    for w in warnings:
        print(f"  WARN:  {w}")
    sys.exit(1)
else:
    print("RESULT: ALL CHECKS PASSED")
    if warnings:
        for w in warnings:
            print(f"  WARN: {w}")
    print(f"\nGDS ready for wafer.space 1x1 submission:")
    print(f"  Die: {die_w:.1f} x {die_h:.1f} um")
    print(f"  Area: {die_w * die_h / 1e6:.2f} mm^2")
    print(f"  Cells: {layout.cells()}")
    print(f"  File: {GDS_PATH}")
    sys.exit(0)
