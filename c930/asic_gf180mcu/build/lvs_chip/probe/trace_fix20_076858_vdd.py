#!/usr/bin/env python3
"""Trace the fix19 _076858_ signal to VDD/VSS through M1-M5.

Read-only.  The target is the M2 _076858_ label at (1762040,1510040).
VDD/VSS source nodes come from the M1 text labels.  The output is the first
via path from the target to a supply node, or NO_SUPPLY_MEET.
"""
import os
import sys
import time
import traceback
from collections import defaultdict, deque

import klayout.db as db

TILE = os.environ.get(
    "TILE",
    "/work/c930/asic_gf180mcu/build/lvs_chip/fix19_target_tile_y1398.gds",
)
TOP = "grx930_test_chip"
M1, V1, M2, V2, M3, V3, M4, V4, M5 = 34, 35, 36, 38, 42, 40, 46, 41, 81
TARGET = db.Point(1_762_040, 1_510_040)
GRID = 20_000


def bstr(b):
    return f"({b.left},{b.bottom};{b.right},{b.top})"


def reg(ly, top, num):
    li = ly.find_layer(db.LayerInfo(num, 0))
    if li is None:
        return db.Region()
    r = db.Region(top.begin_shapes_rec(li))
    r.merge()
    return r


def via_centers(region):
    out = set()
    for p in region.each():
        b = p.bbox()
        out.add(((b.p1.x + b.p2.x) // 2, (b.p1.y + b.p2.y) // 2))
    return sorted(out)


def main():
    t = time.time()
    ly = db.Layout()
    ly.read(TILE)
    top = ly.cell(TOP)
    print("READ", f"{time.time()-t:.1f}s", "TOP", top.name,
          "BBOX", top.bbox(), flush=True)

    regs = {}
    for name, num in (("M1", M1), ("V1", V1), ("M2", M2), ("V2", V2),
                      ("M3", M3), ("V3", V3), ("M4", M4), ("V4", V4),
                      ("M5", M5)):
        regs[name] = reg(ly, top, num)
        print("LAYER", name, num, "shapes", regs[name].size(), flush=True)

    polys = {name: list(regs[name].each())
             for name in ("M1", "M2", "M3", "M4", "M5")}
    for name in polys:
        print("COMPONENTS", name, len(polys[name]), flush=True)

    grid = defaultdict(list)
    for name in ("M1", "M2", "M3", "M4", "M5"):
        for i, p in enumerate(polys[name]):
            b = p.bbox()
            for gx in range(b.left // GRID, b.right // GRID + 1):
                for gy in range(b.bottom // GRID, b.top // GRID + 1):
                    grid[(name, gx, gy)].append(i)

    def comp_at(name, pt):
        for i in grid.get((name, pt.x // GRID, pt.y // GRID), ()):
            p = polys[name][i]
            if p.bbox().contains(pt) and p.inside(pt):
                return i
        return None

    # Exact label transform used by the earlier M1-M5 trace.
    txtli = ly.find_layer(db.LayerInfo(34, 10))
    sources = {"VDD": set(), "VSS": set()}
    counts = defaultdict(int)
    it = top.begin_shapes_rec(txtli)
    while not it.at_end():
        sh = it.shape()
        if sh.is_text() and sh.text is not None and sh.text.string in ("VDD", "VSS"):
            txt = sh.text.string
            tr = it.trans()
            disp = sh.text.trans.disp
            base = tr.trans(disp)
            d = tr.disp
            q = db.Point(base.x + d.x, base.y + d.y)
            ci = comp_at("M1", q)
            counts[txt] += 1
            if ci is not None:
                sources[txt].add(("M1", ci))
        it.next()
    print("LABELS", dict(counts), "SOURCES", {k: len(v) for k, v in sources.items()},
          flush=True)

    target_ci = comp_at("M2", TARGET)
    print("TARGET", TARGET.x, TARGET.y, "M2_NODE", target_ci, flush=True)
    if target_ci is None:
        raise SystemExit("target M2 node not found")
    start = ("M2", target_ci)
    print("TARGET_BBOX", bstr(polys["M2"][target_ci].bbox()), flush=True)

    adj = defaultdict(list)
    edge_counts = defaultdict(int)
    for via, a, b in (("V1", "M1", "M2"), ("V2", "M2", "M3"),
                      ("V3", "M3", "M4"), ("V4", "M4", "M5")):
        for x, y in via_centers(regs[via]):
            pt = db.Point(x, y)
            ia = comp_at(a, pt)
            ib = comp_at(b, pt)
            if ia is None or ib is None:
                continue
            na, nb = (a, ia), (b, ib)
            adj[na].append((nb, via, (x, y)))
            adj[nb].append((na, via, (x, y)))
            edge_counts[via] += 1
    print("EDGES", dict(edge_counts), flush=True)

    parent = {start: None}
    pedge = {}
    q = deque([start])
    end = None
    end_color = None
    if start in sources["VDD"]:
        end, end_color = start, "VDD"
    elif start in sources["VSS"]:
        end, end_color = start, "VSS"
    while q and end is None:
        n = q.popleft()
        for nb, tag, pt in adj.get(n, ()):
            if nb in parent:
                continue
            parent[nb] = n
            pedge[nb] = (tag, pt)
            if nb in sources["VDD"]:
                end, end_color = nb, "VDD"
                break
            if nb in sources["VSS"]:
                end, end_color = nb, "VSS"
                break
            q.append(nb)
    print("BFS_REACHED", len(parent), flush=True)

    if end is None:
        print("NO_SUPPLY_MEET", flush=True)
        print("DONE", f"{time.time()-t:.1f}s", flush=True)
        return 0

    path = []
    cur = end
    while parent[cur] is not None:
        prev = parent[cur]
        path.append((prev, cur, pedge[cur]))
        cur = prev
    path.reverse()
    print("MEET", end_color, end, bstr(polys[end[0]][end[1]].bbox()), flush=True)
    for a, b, (tag, pt) in path:
        print(f"  HOP {tag} {pt[0]},{pt[1]} {a} -> {b}", flush=True)
        print(f"    FROM {a} {bstr(polys[a[0]][a[1]].bbox())}", flush=True)
        print(f"    TO   {b} {bstr(polys[b[0]][b[1]].bbox())}", flush=True)
    print("DONE", f"{time.time()-t:.1f}s", flush=True)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.stdout.flush()
        sys.exit(1)
