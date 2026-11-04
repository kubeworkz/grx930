# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Where the routed clock's metal1 meets a supply pin, named cell by cell.

The netlist says the clock picked up 301 PFET bodies and 195 PFET source/drains and nothing on the
NFET side.  Bodies come from a *well*, not from a rail, so the thing the clock met is a supply pin
that taps a well -- a cell's VDD pin, a well-tie's stem, or a via pad standing on one.

Both sides are rebuilt from the DEF and the library:

  clock  = the CLK pin rectangles of every instance the DEF lists on `i_clk`, plus the net's own
           Metal1 geometry exactly as the DEF writes it -- segments as centrelines widened to the
           DEF width, `RECT` shapes as the rectangles they are, and via cells by their metal1 pad;
  supply = every POWER/GROUND pin's Metal1 rectangle of every placed instance, from the LEF.

Each hit is reported with both owners, the rail line the supply pin belongs to, and the supply
island in that row's 0.6 um rail band.

    python3 clock_vs_supply_pins.py --def ...filled_metal1.def --lef ../../cells.lef \\
        --gds ...stream_out_filled_metal1.gds [--limit 40]
"""

import argparse
import re
from bisect import bisect_left

import klayout.db as db

COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")
PAIR_RE = re.compile(r"\(\s*(\S+)\s+(\S+)\s*\)")
POINT_RE = re.compile(r"\(\s*([*\-\d]+)\s+([*\-\d]+)(?:\s+-?\d+)?\s*\)")
RECT_RE = re.compile(r"\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+RECT\s+(\(\s*-?\d+\s+-?\d+\s+-?\d+\s+-?\d+\s*\))")
LAYER_RE = re.compile(r"(Metal[1-5])")
VIA_TOKEN_RE = re.compile(r"^(Via\d|VIA_|via)")
UPRIGHT = ("N", "FN")
BAND = 300
# metal1 landing pad of each via cell, in dbu (tech LEF enclosure; H = 380 wide, V = 380 tall)
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
    """components, clock instances, and the i_clk net's metal1 geometry, all in dbu."""
    comps, clock = {}, set()
    boxes = []          # metal1 rectangles (stubs, rect shapes, pads)
    segs = []           # (x1, y1, x2, y2, halfwidth)
    vias = []           # (x, y, via name)
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
        body = None
        if s.startswith("+ ROUTED "):
            body = s[len("+ ROUTED "):]
        elif s.startswith("NEW "):
            body = s[4:]
        if body is None:
            for inst, pin in PAIR_RE.findall(s):
                if not inst.isdigit() and pin.upper() == "CLK":
                    clock.add(inst)
            continue
        m = LAYER_RE.match(body)
        if not m or m.group(1) != "Metal1":
            continue
        rest = body[m.end():].strip()
        rectm = RECT_RE.search(rest)
        if rectm:
            x, y = int(rectm.group(1)) // 2, int(rectm.group(2)) // 2
            nums = [int(v) for v in re.findall(r"-?\d+", rectm.group(3))]
            boxes.append(db.Box(x + nums[0] // 2, y + nums[1] // 2,
                                x + nums[2] // 2, y + nums[3] // 2))
            continue
        pts = POINT_RE.findall(rest)
        if not pts:
            continue
        tail = rest.split(")")[-1].strip(" ;")
        if tail and VIA_TOKEN_RE.match(tail):
            vias.append((int(pts[0][0]) // 2, int(pts[0][1]) // 2, tail))
            continue
        wm = re.match(r"\s*(\d+)\s+\(", rest)
        half = (int(wm.group(1)) // 2) if wm else 0
        x1, y1 = int(pts[0][0]) // 2, int(pts[0][1]) // 2
        if len(pts) < 2:
            continue
        x2 = x1 if pts[1][0] == "*" else int(pts[1][0]) // 2
        y2 = y1 if pts[1][1] == "*" else int(pts[1][1]) // 2
        segs.append((x1, y1, x2, y2, half))
    return comps, clock, boxes, segs, vias


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", required=True)
    ap.add_argument("--gds", required=True)
    ap.add_argument("--limit", type=int, default=40)
    args = ap.parse_args()

    macros = parse_lef(args.lef)
    comps, clock, boxes, segs, vias = parse_def(args.def_file)
    print(f"components={len(comps)} clock instances={len(clock)} "
          f"i_clk metal1 rects={len(boxes)} segments={len(segs)} via pads={len(vias)}",
          flush=True)

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    m1 = db.Region(top.begin_shapes_rec(ly.layer(34, 0)))

    pad = dict(PAD)
    print(f"via1 pad boxes: {pad}", flush=True)

    # ---- clock region ------------------------------------------------------------------------
    clk = db.Region()
    for inst in clock:
        rec = comps.get(inst)
        if not rec:
            continue
        cell, x, y, orient = rec
        mac = macros.get(cell)
        if not mac or mac["size"] is None:
            continue
        w, h = mac["size"]
        for pin, _use, rect in mac["pins"]:
            if pin.upper() == "CLK":
                clk.insert(placed_box(rect, w, h, orient, x, y))
    for b in boxes:
        clk.insert(b)
    for x1, y1, x2, y2, half in segs:
        clk.insert(db.Box(min(x1, x2) - half, min(y1, y2) - half,
                          max(x1, x2) + half, max(y1, y2) + half))
    for x, y, vname in vias:
        bb = pad.get(vname)
        if bb is not None:
            clk.insert(db.Box(x - bb[0], y - bb[1], x + bb[0], y + bb[1]))
    print(f"clock metal1 region: {clk.count()} shapes", flush=True)

    # ---- supply pins -------------------------------------------------------------------------
    supply = db.Region()
    owners = []
    for inst, (cell, x, y, orient) in comps.items():
        mac = macros.get(cell)
        if not mac or mac["size"] is None:
            continue
        w, h = mac["size"]
        for pin, use, rect in mac["pins"]:
            if use not in ("POWER", "GROUND"):
                continue
            box = placed_box(rect, w, h, orient, x, y)
            supply.insert(box)
            owners.append((pin, inst, cell, orient, box, x, y, h))
    print(f"supply pin metal1 region: {supply.count()} shapes from {len(owners)} pin rects",
          flush=True)

    hits = clk & supply
    print(f"clock-metal1 over supply-pin pieces={hits.count()}", flush=True)

    rows = sorted({o[6] for o in owners})
    band_cache = {}

    def island(yline, px):
        if yline not in band_cache:
            band_cache[yline] = (m1 & db.Region(db.Box(-1_000_000, yline - BAND,
                                                       100_000_000, yline + BAND))).merged()
        for p in band_cache[yline].each():
            if p.inside(db.Point(px, yline)):
                return p.bbox()
        return None

    shown = 0
    for p in hits.each():
        bb = p.bbox()
        px, py = (bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2
        ptr = db.Point(px, py)
        sup = [o for o in owners if o[4].contains(ptr)]
        srcs = []
        for inst in clock:
            rec = comps.get(inst)
            if not rec:
                continue
            cell, x, y, orient = rec
            mac = macros.get(cell)
            if not mac or mac["size"] is None:
                continue
            w, h = mac["size"]
            for pin, _use, rect in mac["pins"]:
                if pin.upper() == "CLK" and placed_box(rect, w, h, orient, x, y).contains(ptr):
                    srcs.append(f"CLK pin of {inst} {cell} {orient}")
        for b in boxes:
            if b.contains(ptr):
                srcs.append(f"metal1 rect {b}")
        for x1, y1, x2, y2, half in segs:
            if (min(x1, x2) - half <= px <= max(x1, x2) + half and
                    min(y1, y2) - half <= py <= max(y1, y2) + half):
                srcs.append(f"metal1 segment {x1},{y1}->{x2},{y2} w={2 * half}")
        for x, y, vname in vias:
            vb = pad.get(vname)
            if vb is not None and x - vb[0] <= px <= x + vb[0] and \
                    y - vb[1] <= py <= y + vb[1]:
                srcs.append(f"via1 pad {vname} at ({x},{y})")
        print(f"\ncontact {bb}  um ({px / 1000:.3f},{py / 1000:.3f})")
        for pin, inst, cell, orient, box, x, y, h in sup:
            up = orient in UPRIGHT
            rail_y = (y + h) if ((pin == "VDD") == up) else y
            isl = island(rail_y, px)
            print(f"   supply {pin} pin of {inst} {cell} {orient} at ({x},{y}) box {box}")
            print(f"          rail line y={rail_y} (row {(rail_y - 11760) // 3920}) "
                  f"island={isl}")
        if not sup:
            print("   supply pin: none")
        for src in srcs[:8]:
            print(f"   clock {src}")
        shown += 1
        if shown >= args.limit:
            print(f"   ... stopping at {args.limit}")
            break


if __name__ == "__main__":
    main()
