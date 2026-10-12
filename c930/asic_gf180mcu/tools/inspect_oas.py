#!/usr/bin/env python3
"""Dump the structure of a wafer.space example layout (GDS/OAS).

Run inside the OpenLane 2 image (klayout bindings) with the tools dir mounted:

    MSYS_NO_PATHCONV=1 docker run --rm --user 0:0 \
      -v C:/Users/kubew/grx930/c930/asic_gf180mcu/tools:/data \
      --entrypoint /bin/sh ghcr.io/efabless/openlane2:2.3.10 \
      -c 'python3 /data/inspect_oas.py /data/gf180mcu-example-layouts/5v/1x1/chip_top.oas'

Prints: dbu, top cell(s), die bbox, per-layer shape counts over the top cell,
and every cell instantiated (with instance count and first placement) so the
pad ring, seal ring and wafer.space IP cells can be identified by name.
"""
import sys
from collections import Counter

try:
    import klayout.db as db
except ImportError:  # older KLayout builds expose the same API as `pya`
    import pya as db  # type: ignore


def shape_count(cell, layer_index):
    n = 0
    it = cell.begin_shapes_rec(layer_index)
    while not it.at_end():
        n += 1
        it.next()
    return n


def main(path):
    ly = db.Layout()
    ly.read(path)
    print(f"file       {path}")
    print(f"dbu        {ly.dbu}")
    tops = [c.name for c in ly.top_cells()]
    print(f"top cells  {tops}")
    print(f"cells      {ly.cells()}")

    top = ly.top_cells()[0]
    bb = top.dbbox()
    print(
        "bbox um    left={:.3f} bottom={:.3f} right={:.3f} top={:.3f} "
        "w={:.3f} h={:.3f}".format(
            bb.left, bb.bottom, bb.right, bb.top, bb.width(), bb.height()
        )
    )

    print("\nlayers used by the top cell:")
    total = 0
    for li in ly.layer_infos():
        idx = ly.layer(li)
        n = shape_count(top, idx)
        total += n
        if n:
            print(f"  {li.name:<20} ({li.layer}/{li.datatype}): {n}")
    print(f"  total shapes: {total}")

    # Direct children of the top cell (floorplan building blocks).
    insts = Counter()
    first = {}
    for inst in top.each_inst():
        name = inst.cell.name
        insts[name] += 1
        if name not in first:
            d = inst.trans.disp
            first[name] = (d.x * ly.dbu, d.y * ly.dbu)
    print(f"\ncell instances in top cell ({len(insts)} distinct):")
    for name, count in insts.most_common():
        x, y = first[name]
        print(f"  x{count:<4} first@({x:9.3f}, {y:9.3f})  {name}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/data/chip_top.oas")
