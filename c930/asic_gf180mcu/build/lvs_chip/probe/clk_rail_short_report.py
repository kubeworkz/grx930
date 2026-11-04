# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Name the fill cell, the clock load and the rail island of every clock-to-VDD contact.

The pre-stitch comparison (`filled-vnwvd-b12300`) puts the clock on a net with 301 PFET bodies and
195 PFET source/drains -- well-side terminals, so the clock met a supply *pin*, not a rail edge by
accident.  This probe finds those pins by rebuilding the clock's metal1 from the routed DEF (its
CLK pin rectangles, its `( x y ) RECT ( ... )` pin-access shapes, its centrelines and its via1
pads) and intersecting it with every POWER/GROUND pin rectangle in the LEF.

For each contact it reports:

  * the supply cell, pin and the rail line the pin hangs from;
  * the clock object that touched it and the nearest clock load (instance, cell, distance), which
    is the cell the stub exists to reach;
  * the rail island: merged metal1 of the streamed die clipped to that row's 0.6 um band, and the
    piece under the contact;
  * the GDS check: the merged metal1 component that contains the clock's via1 nearest the contact,
    its bbox and how far it reaches into the band (empty means no contact in the artifact).

    python3 clk_rail_short_report.py --def ...filled_metal1.def --lef ../../cells.lef \\
        --gds ...stream_out_filled_metal1.gds [--unfilled ...stream_out.gds]
"""

import argparse
import math
import re

import klayout.db as db

COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")
PAIR_RE = re.compile(r"\(\s*(\S+)\s+(\S+)\s*\)")
POINT_RE = re.compile(r"\(\s*([*\-\d]+)\s+([*\-\d]+)(?:\s+-?\d+)?\s*\)")
RECT_RE = re.compile(r"\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+RECT\s+\((\s*-?\d+\s+-?\d+\s+-?\d+\s+-?\d+)\s*\)")
LAYER_RE = re.compile(r"(Metal[1-5])")
VIA_TOKEN_RE = re.compile(r"^(Via\d|VIA_|via)")
UPRIGHT = ("N", "FN")
BAND = 300
ROW_Y0 = 11760
PITCH = 3920
PAD = {"Via1_HV": (190, 130), "Via1_VV": (130, 190)}


def parse_lef(path):
    macros = {}
    name = pin = use = None
    in_metal1 = False
    for line in open(path, errors="replace"):
        s = line.strip()
        m = re.match(r"MACRO (\S+)", s)
        if m:
            name, pin, use, in_metal1 = m.group(1), None, None, False
            macros[name] = {"size": None, "pins": []}
            continue
        if name is None:
            continue
        if s.startswith("END ") and s[4:].strip() == name:
            name = None
            continue
        m = re.match(r"SIZE ([\d.]+) BY ([\d.]+)", s)
        if m:
            macros[name]["size"] = (round(float(m.group(1)) * 1000),
                                    round(float(m.group(2)) * 1000))
            continue
        m = re.match(r"PIN (\S+)", s)
        if m:
            pin, use, in_metal1 = m.group(1), None, False
            continue
        if pin and s.startswith("END " + pin):
            pin = None
            continue
        m = re.match(r"USE\s+(\S+)", s)
        if m and pin:
            use = m.group(1)
            continue
        if s.startswith("LAYER Metal1"):
            in_metal1 = True
            continue
        if s.startswith("LAYER "):
            in_metal1 = False
            continue
        m = re.match(r"RECT\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)", s)
        if m and pin and in_metal1:
            macros[name]["pins"].append((pin, use,
                                         [round(float(v) * 1000) for v in m.groups()]))
    return macros


def parse_def(path):
    comps, clock = {}, set()
    rects, segs, vias = [], [], []
    section = net = None
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("COMPONENTS"):
            section = "comps"
            continue
        if s.startswith("END COMPONENTS"):
            section = None
            continue
        if s.startswith("NETS"):
            section = "nets"
            continue
        if s.startswith("END NETS"):
            section = None
            continue
        if section == "comps":
            m = COMP_RE.match(s)
            if m:
                comps[m.group(1)] = (m.group(2), int(m.group(3)) // 2, int(m.group(4)) // 2,
                                     m.group(5))
            continue
        if section != "nets":
            continue
        if s.startswith("- "):
            net = s[2:].split()[0]
            s = s[len(net) + 2:]
        if net != "i_clk" or s.startswith("+ USE"):
            continue
        body = s[len("+ ROUTED "):] if s.startswith("+ ROUTED ") else (s[4:] if s.startswith("NEW ") else None)
        if body is None:
            for inst, pin in PAIR_RE.findall(s):
                if not inst.isdigit() and pin.upper() == "CLK":
                    clock.add(inst)
            continue
        m = LAYER_RE.match(body)
        if not m or m.group(1) != "Metal1":
            continue
        rest = body[m.end():].strip()
        rm = RECT_RE.search(rest)
        if rm:
            x, y = int(rm.group(1)) // 2, int(rm.group(2)) // 2
            n = [int(v) // 2 for v in rm.group(3).split()]
            rects.append(db.Box(x + n[0], y + n[1], x + n[2], y + n[3]))
            continue
        pts = POINT_RE.findall(rest)
        if not pts:
            continue
        tail = rest.split(")")[-1].strip(" ;")
        if tail and VIA_TOKEN_RE.match(tail):
            vias.append((int(pts[0][0]) // 2, int(pts[0][1]) // 2, tail))
            continue
        if len(pts) < 2:
            continue
        x1, y1 = int(pts[0][0]) // 2, int(pts[0][1]) // 2
        x2 = x1 if pts[1][0] == "*" else int(pts[1][0]) // 2
        y2 = y1 if pts[1][1] == "*" else int(pts[1][1]) // 2
        segs.append((x1, y1, x2, y2))
    return comps, clock, rects, segs, vias


def transform(pt, w, h, orient):
    x, y = pt
    if orient in ("FS", "S"):
        y = h - y
    if orient in ("FN", "S"):
        x = w - x
    return x, y


def placed_box(rect, w, h, orient, ox, oy):
    x0, y0, x1, y1 = rect
    a = transform((x0, y0), w, h, orient)
    b = transform((x1, y1), w, h, orient)
    return db.Box(min(a[0], b[0]) + ox, min(a[1], b[1]) + oy,
                  max(a[0], b[0]) + ox, max(a[1], b[1]) + oy)


def merged_components(gds):
    ly = db.Layout()
    ly.read(gds)
    top = ly.top_cell()
    m1 = db.Region(top.begin_shapes_rec(ly.layer(34, 0))).merged()
    v1 = db.Region(top.begin_shapes_rec(ly.layer(35, 0))).merged()
    return ly, top, m1, v1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--gds", required=True)
    ap.add_argument("--unfilled")
    args = ap.parse_args()

    macros = parse_lef(args.lef)
    comps, clock, rects, segs, vias = parse_def(args.def_file)
    print(f"clock instances={len(clock)}  metal1: rects={len(rects)} segments={len(segs)} "
          f"via1 pads={len(vias)}", flush=True)

    clk = db.Region()
    for b in rects:
        clk.insert(b)
    for x1, y1, x2, y2 in segs:
        clk.insert(db.Box(min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)))
    for x, y, v in vias:
        p = PAD.get(v)
        if p:
            clk.insert(db.Box(x - p[0], y - p[1], x + p[0], y + p[1]))

    # CLK pins of the clock loads, and every supply pin
    pins = {}
    supply = []
    for inst, (cell, x, y, orient) in comps.items():
        mac = macros.get(cell)
        if not mac or mac["size"] is None:
            continue
        w, h = mac["size"]
        for pin, use, rect in mac["pins"]:
            box = placed_box(rect, w, h, orient, x, y)
            if use in ("POWER", "GROUND"):
                supply.append((pin, inst, cell, orient, box, x, y, h))
            elif pin.upper() == "CLK" and inst in clock:
                pins[inst] = (cell, box, x, y, orient)
    print(f"supply pin rects={len(supply)} clock CLK pins={len(pins)}", flush=True)

    hits = clk & db.Region([o[4] for o in supply])
    print(f"clock metal1 over supply pin: {hits.count()} pieces", flush=True)

    ly, top, m1, v1 = merged_components(args.gds)
    bands = db.Region()
    k = 0
    while ROW_Y0 + k * PITCH <= 5_120_000:
        bands.insert(db.Box(-1_000_000, ROW_Y0 + k * PITCH - BAND, 100_000_000,
                            ROW_Y0 + k * PITCH + BAND))
        k += 1

    unfilled = None
    if args.unfilled:
        unfilled = merged_components(args.unfilled)

    def component_at(comp, pt):
        for poly in comp.each():
            bb = poly.bbox()
            if bb.contains(pt) and poly.inside(pt):
                return poly
        return None

    for h in hits.each():
        bb = h.bbox()
        cx, cy = (bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2
        ptr = db.Point(cx, cy)
        print(f"\n=== contact {bb}  um ({cx / 1000:.3f},{cy / 1000:.3f})")
        owners = [o for o in supply if o[4].contains(ptr)]
        for pin, inst, cell, orient, box, x, y, hh in owners:
            up = orient in UPRIGHT
            rail_y = (y + hh) if ((pin == "VDD") == up) else y
            band = db.Region(db.Box(-1_000_000, rail_y - BAND, 100_000_000, rail_y + BAND))
            isl = (m1 & band).merged()
            island = None
            for poly in isl.each():
                if poly.inside(db.Point(cx, rail_y)):
                    island = poly.bbox()
            print(f" supply {pin}: {inst} {cell} {orient} at ({x},{y}) dbu "
                  f"({x / 1000:.3f},{y / 1000:.3f}) um")
            print(f"   its {pin} metal1 {box}  um ({box.left / 1000:.3f}..{box.right / 1000:.3f},"
                  f" {box.bottom / 1000:.3f}..{box.top / 1000:.3f})")
            print(f"   rail line y={rail_y} dbu ({rail_y / 1000:.3f} um), "
                  f"row {(rail_y - ROW_Y0) // PITCH} boundary")
            print(f"   VDD island at that line: {island}")
            if island:
                print(f"     island x {island.left / 1000:.3f}..{island.right / 1000:.3f} um "
                      f"({(island.right - island.left) / 1000:.3f} um wide)")
        # which clock object touches, and which clock load it serves
        srcs = [f"metal1 rect {b}" for b in rects if b.contains(ptr)]
        for s in segs:
            x1, y1, x2, y2 = s
            if min(x1, x2) <= cx <= max(x1, x2) and min(y1, y2) <= cy <= max(y1, y2):
                srcs.append(f"metal1 segment {s} ({(x2 - x1) / 2000:.3f} x "
                            f"{(y2 - y1) / 2000:.3f} um)")
        for x, y, v in vias:
            p = PAD.get(v)
            if p and x - p[0] <= cx <= x + p[0] and y - p[1] <= cy <= y + p[1]:
                srcs.append(f"via1 pad {v} at ({x},{y}) dbu")
        for s in srcs:
            print(f" clock {s}")
        best = None
        for inst, (cell, box, x, y, orient) in pins.items():
            d = math.hypot(box.center().x - cx, box.center().y - cy)
            if best is None or d < best[0]:
                best = (d, inst, cell, box)
        if best:
            print(f" nearest clock load: {best[1]} {best[2]} CLK pin at {best[3]} "
                  f"({best[0] / 1000:.3f} um away)")
        # GDS: does the clock's via1 at the stub sit in a component that holds rail metal?
        near = [(math.hypot(x - cx, y - cy), x, y, v) for x, y, v in vias]
        near.sort()
        for d, x, y, v in near[:2]:
            poly = component_at(m1, db.Point(x, y))
            if poly is None:
                print(f" GDS: no metal1 component at via1 ({x},{y})")
                continue
            pbb = poly.bbox()
            print(f" GDS: via1 {v} at ({x},{y}) {d / 1000:.3f} um from the contact")
            print(f"   merged metal1 component bbox {pbb} "
                  f"({(pbb.right - pbb.left) / 1000:.3f} x {(pbb.bottom - pbb.top) / 1000:.3f} um)")
            print(f"   component x {pbb.left / 1000:.3f}..{pbb.right / 1000:.3f} "
                  f"y {pbb.bottom / 1000:.3f}..{pbb.top / 1000:.3f} um")
            print(f"   via1 pads inside it: {(v1 & db.Region(poly)).count()}")
            if unfilled:
                upoly = component_at(unfilled[2], db.Point(x, y))
                if upoly:
                    ubb = upoly.bbox()
                    print(f"   same via1 in the unfilled die: component bbox {ubb} "
                          f"({(ubb.right - ubb.left) / 1000:.3f} x "
                          f"{(ubb.bottom - ubb.top) / 1000:.3f} um)")
                else:
                    print("   same via1 in the unfilled die: not in any metal1 component")


if __name__ == "__main__":
    main()
