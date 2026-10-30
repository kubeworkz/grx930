# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
import klayout.db as db
ly = db.Layout(); ly.read("/work/c930/asic_gf180mcu/build/lvs_chip/stream_out.gds")
top = ly.top_cell()
rows = []
for li in ly.layer_indexes():
    info = ly.get_info(li)
    n = big = 0; mx = 0; verts = 0
    it = top.begin_shapes_rec(li)
    while not it.at_end():
        sh = it.shape()
        if sh.is_polygon() or sh.is_box() or sh.is_path():
            p = sh.polygon if sh.is_polygon() else None
            if p is not None:
                v = p.num_points_hull() if hasattr(p, "num_points_hull") else p.num_points()
                n += 1; verts += v; mx = max(mx, v)
                if v > 64: big += 1
            else:
                n += 1
        it.next()
    if n: rows.append((info.layer, info.datatype, n, mx, big, verts))
rows.sort(key=lambda r: -(r[3]))
print(f"{'layer':>10} {'polys':>9} {'maxverts':>9} {'>64v':>7} {'vertices':>11}")
for l, d, n, mx, big, verts in rows:
    print(f"{l:5}/{d:<4} {n:9d} {mx:9d} {big:7d} {verts:11d}")
