#!/usr/bin/env python3
"""List all layers in GDS file"""
import sys
import klayout.db as db

layout = db.Layout()
layout.read(sys.argv[1])
for layer_idx in layout.layer_indices():
    info = layout.get_info(layer_idx)
    name = info.name if info.name else "(no name)"
    print(f"{info.layer}.{info.datatype}  {name}")
