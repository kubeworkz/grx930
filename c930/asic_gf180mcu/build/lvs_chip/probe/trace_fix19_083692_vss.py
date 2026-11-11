#!/usr/bin/env python3
"""Read-only check that the fix19 _083692_ route no longer reaches VSS.

Uses only the tile GDS.  The _083692_ label is on M2; VSS is identified by
VSS text labels in the same window and by two known points on the M1 VSS rail.
The graph is M1/V1/M2/V2/M3/V3/M4.  The check stops at the first VSS contact
and prints the complete via path, or prints NO_VSS_MEET.
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
M1, V1, M2, V2, M3, V3, M4 = 34, 35, 36, 38, 42, 40, 46
WINDOW = db.Box(2_780_000, 2_480_000, 3_120_000, 3_120_000)
TARGET_LABEL = db.Point(3_030_440, 2_576_840)
VSS_RAIL_POINTS = [
    db.Point(2_902_200, 2_574_600),
    db.Point(2_888_760, 2_575_440),
]
GRID = 10_000


def reg(ly, top, num):
    li = ly.find_layer(db.LayerInfo(num, 0))
    if li is None:
        return db.Region()
    r = db.Region(top.begin_shapes_rec(li)) & db.Region(WINDOW)
    r.merge()
    return r


def bstr(b):
    return f"({b.left},{b.bottom};{b.right},{b.top})"


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
                      ("M3", M3), ("V3", V3), ("M4", M4)):
        regs[name] = reg(ly, top, num)
        print("LAYER", name, num, "shapes", regs[name].size(), flush=True)

    polys = {name: list(regs[name].each()) for name in ("M1", "M2", "M3", "M4")}
    for name in polys:
        print("COMPONENTS", name, len(polys[name]), flush=True)

    grid = defaultdict(list)
    for name in ("M1", "M2", "M3", "M4"):
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

    # Text labels are transformed exactly as in the prior trace scripts.
    labels = defaultdict(list)
    for ln, lname in ((34, "M1"), (36, "M2"), (42, "M3"), (46, "M4")):
        li = ly.find_layer(db.LayerInfo(ln, 10))
        if li is None:
            continue
        it = top.begin_shapes_rec(li)
        while not it.at_end():
            sh = it.shape()
            if sh.is_text() and sh.text is not None:
                txt = sh.text.string
                if txt in ("_083692_", "VSS"):
                    tr = it.trans()
                    disp = sh.text.trans.disp
                    base = tr.trans(disp)
                    d = tr.disp
                    p = db.Point(base.x + d.x, base.y + d.y)
                    if WINDOW.contains(p):
                        ci = comp_at(lname, p)
                        if ci is not None:
                            labels[(txt, lname)].append((p, ci))
            it.next()
    print("LABELS", {f"{k[0]}/{k[1]}": len(v) for k, v in labels.items()},
          flush=True)

    target_hits = labels.get(("_083692_", "M2"), [])
    target_hits = [(p, i) for p, i in target_hits
                   if abs(p.x - TARGET_LABEL.x) <= 2 and abs(p.y - TARGET_LABEL.y) <= 2]
    print("TARGET_HITS", [(p.x, p.y, i) for p, i in target_hits], flush=True)
    if len(target_hits) != 1:
        raise SystemExit(f"expected one target label at {TARGET_LABEL}, got {len(target_hits)}")
    start = ("M2", target_hits[0][1])
    print("START", start, bstr(polys["M2"][start[1]].bbox()),
          "area", polys["M2"][start[1]].area(), flush=True)

    vss_nodes = set()
    for (txt, lname), rows in labels.items():
        if txt != "VSS":
            continue
        for _p, ci in rows:
            vss_nodes.add((lname, ci))
    for p in VSS_RAIL_POINTS:
        ci = comp_at("M1", p)
        if ci is not None:
            vss_nodes.add(("M1", ci))
    print("VSS_NODES", len(vss_nodes), flush=True)
    for n in sorted(vss_nodes, key=str):
        print("  VSS", n, bstr(polys[n[0]][n[1]].bbox()),
              "area", polys[n[0]][n[1]].area(), flush=True)

    adj = defaultdict(list)
    edge_counts = defaultdict(int)
    for via, a, b in (("V1", "M1", "M2"), ("V2", "M2", "M3"),
                      ("V3", "M3", "M4")):
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
    end = start if start in vss_nodes else None
    while q and end is None:
        n = q.popleft()
        for nb, tag, pt in adj.get(n, ()):
            if nb in parent:
                continue
            parent[nb] = n
            pedge[nb] = (tag, pt)
            if nb in vss_nodes:
                end = nb
                break
            q.append(nb)
    print("BFS_REACHED", len(parent), flush=True)

    if end is None:
        print("NO_VSS_MEET", flush=True)
        print("DONE", f"{time.time()-t:.1f}s", flush=True)
        return 0

    path = []
    cur = end
    while parent[cur] is not None:
        prev = parent[cur]
        path.append((prev, cur, pedge[cur]))
        cur = prev
    path.reverse()
    print("VSS_MEET", end, bstr(polys[end[0]][end[1]].bbox()), flush=True)
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
