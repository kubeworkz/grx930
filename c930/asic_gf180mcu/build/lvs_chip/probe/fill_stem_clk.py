# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Which fill cell's supply stem reaches the clock, in which rail island.

The earlier fill-vs-pin probe classified a library supply polygon by its bbox against the cell
edge, which silently dropped `filltie`'s VDD polygon: its bbox runs from y=1.930 to the top rail,
so it neither starts in the lower half nor ends in the upper half.  Only the *stem* of each fill
supply pin can reach a row interior anyway (the rail part abuts its neighbours' rails by design),
and the LEF states both stems exactly, so this probe uses the LEF rectangles rather than a
heuristic:

  * stem   = a Metal1 rectangle of a POWER/GROUND pin that is narrower than the cell;
  * rail   = a Metal1 rectangle that spans the cell's full width;
  * clock  = the instances the DEF lists on `i_clk` as `( inst CLK )`, plus their CLK pin metal.

Every touch of a stem on metal1 outside the row's 0.6 um rail band is a defect; the ones whose
touched shape belongs to a clock load are the clock short.  For each defect the probe also names
the owner of the touched shape, the pin it is, and the rail island the stem hangs from (merged
metal1 inside that row's rail band, clipped to the piece under the stem), so the answer is a cell,
a pin and an island rather than a coordinate.

    python3 fill_stem_clk.py --def ...filled_metal1.def --lef ../../cells.lef \\
        --gds ...stream_out_filled_metal1.gds [--limit 40]
"""

import argparse
import re
from bisect import bisect_left

import klayout.db as db

COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+\+\s+(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)")
ROW_RE = re.compile(r"^ROW\s+(\S+)\s+\S+\s+(\d+)\s+(\d+)\s+(\w+)\s+DO\s+\d+\s+BY\s+1\s+STEP\s+(\d+)")
PAIR_RE = re.compile(r"\(\s*(\S+)\s+(\S+)\s*\)")
FILL_PREFIX = "FILL_ROW_"
UPRIGHT = ("N", "FN")
BAND = 300          # dbu either side of a row line: the 0.6 um rail band
DEF_PER_UM = 2000
DBU_PER_UM = 1000


def parse_lef(path):
    """{macro: {"size": (w,b), "pins": [(name, use, kind, (x0,y0,x1,y1))]}} in dbu."""
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
            macros[name]["size"] = (round(float(m.group(1)) * DBU_PER_UM),
                                    round(float(m.group(2)) * DBU_PER_UM))
            continue
        m = re.match(r"PIN (\S+)", s)
        if m:
            pin, use, in_metal1 = m.group(1), None, False
            continue
        if s.startswith("END " + (pin or "")):
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
            vals = [round(float(v) * DBU_PER_UM) for v in m.groups()]
            macros[name]["pins"].append((pin, use, tuple(vals)))
    return macros


def parse_def(path):
    rows, comps = [], {}
    clock = set()
    section = None
    net = None
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("ROW "):
            m = ROW_RE.match(s)
            if m:
                rows.append((m.group(1), int(m.group(2)) // 2, int(m.group(3)) // 2, m.group(4)))
            continue
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
        if net != "i_clk":
            continue
        if "ROUTED" in s or s.startswith("NEW") or s.startswith("+ USE"):
            continue
        for inst, pin in PAIR_RE.findall(s):
            if pin.isdigit() or inst.isdigit() or inst == "PIN":
                continue
            if pin.upper() == "CLK":
                clock.add(inst)
    return rows, comps, clock


def transform(pt, w, h, orient):
    x, y = pt
    if orient in ("FS", "S"):
        y = h - y
    if orient in ("FN", "S"):
        x = w - x
    return x, y


def placed_rect(rect, w, h, orient, ox, oy):
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
    rows, comps, clock = parse_def(args.def_file)
    print(f"rows={len(rows)} components={len(comps)} i_clk CLK loads={len(clock)}", flush=True)

    # ---- fill stems, from the LEF rectangles -------------------------------------------------
    stems = []          # (net, inst, cell, orient, box, rail_y)
    rails = []          # (net, box)
    for inst, (cell, x, y, orient) in comps.items():
        if not inst.startswith(FILL_PREFIX):
            continue
        mac = macros.get(cell)
        if not mac or mac["size"] is None:
            continue
        w, h = mac["size"]
        for pin, use, rect in mac["pins"]:
            if use not in ("POWER", "GROUND"):
                continue
            box = placed_rect(rect, w, h, orient, x, y)
            if box.width() >= w - 2:            # full-width: the rail itself
                rails.append((pin, box))
                continue
            # The rail this stem hangs from: the row line its far end runs into.
            up = orient in UPRIGHT
            top = y + h
            if pin == "VDD":
                rail_y = top if up else y
            else:
                rail_y = y if up else top
            stems.append((pin, inst, cell, orient, box, rail_y))
    print(f"fill stems={len(stems)} fill rails={len(rails)}", flush=True)

    # ---- geometry ----------------------------------------------------------------------------
    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    m1 = db.Region(top.begin_shapes_rec(ly.layer(34, 0)))
    v1 = db.Region(top.begin_shapes_rec(ly.layer(35, 0)))
    print(f"metal1 shapes={m1.count()} via1={v1.count()}", flush=True)

    lines = sorted({r[2] for r in rows} | {r[2] + 3920 for r in rows})
    bands = db.Region()
    for yl in lines:
        bands.insert(db.Box(-1_000_000, yl - BAND, 100_000_000, yl + BAND))
    interior = m1 - bands
    print(f"row lines={len(lines)} metal1 in a band={m1.count() - interior.count()} "
          f"row-interior metal1={interior.count()}", flush=True)

    stem_region = db.Region()
    for _n, _i, _c, _o, box, _ry in stems:
        stem_region.insert(box)
    # A stem is itself metal1: subtract every fill cell's own supply metal (rails and stems) so
    # that only *other* metal1 can register as a contact.
    own = db.Region()
    for _n, box in rails:
        own.insert(box)
    own += stem_region
    other = interior - own
    hits = stem_region & other
    print(f"row-interior metal1 that is not fill supply={other.count()}", flush=True)
    print(f"stem-over-other-metal1 pieces={hits.count()}", flush=True)

    # ---- owners ------------------------------------------------------------------------------
    row_y = sorted({r[2] for r in rows})
    per_row = {}
    for inst, (cell, x, y, orient) in comps.items():
        mac = macros.get(cell)
        if not mac or mac["size"] is None:
            continue
        w, h = mac["size"]
        per_row.setdefault(y, []).append((x, x + w, inst, cell, orient, y, y + h))
    for v in per_row.values():
        v.sort()

    def owner(px, py):
        i = bisect_left(row_y, py)
        for k in (i, i - 1):
            if not (0 <= k < len(row_y)):
                continue
            cands = per_row.get(row_y[k])
            if not cands:
                continue
            j = bisect_left(cands, (px + 1,))
            for t in (j - 1, j):
                if 0 <= t < len(cands):
                    x0, x1, inst, cell, orient, y0, y1 = cands[t]
                    if x0 <= px + 1 and px <= x1 and y0 <= py <= y1:
                        return inst, cell, orient, y0, (x0, x1)
        return None

    def pin_name(own_rec, px, py):
        inst, cell, orient, y0, _xr = own_rec
        mac = macros.get(cell)
        if not mac:
            return None
        cx, cy, _o = comps[inst][1], comps[inst][2], comps[inst][3]
        w, h = mac["size"]
        names = []
        for name, use, rect in mac["pins"]:
            box = placed_rect(rect, w, h, orient, cx, cy)
            if box.contains(db.Point(px, py)):
                names.append((name, use))
        return names

    # ---- islands -----------------------------------------------------------------------------
    band_cache = {}

    def island(yline, px):
        if yline not in band_cache:
            r = db.Region(top.begin_shapes_rec(ly.layer(34, 0)))
            band_cache[yline] = (r & db.Region(db.Box(-1_000_000, yline - BAND,
                                                      100_000_000, yline + BAND))).merged()
        reg = band_cache[yline]
        for p in reg.each():
            if p.inside(db.Point(px, yline)):
                return p.bbox()
        return None

    def via_at(box):
        return (v1 & db.Region(box)).count()

    print("", flush=True)
    shown = 0
    for p in hits.each():
        bb = p.bbox()
        px, py = (bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2
        # which stem made it
        cand = [s for s in stems if s[4].contains(db.Point(px, py))]
        own = owner(px, py)
        if not cand:
            continue
        net, inst, cell, orient, sbox, rail_y = cand[0]
        isl = island(rail_y, sbox.center().x)
        on_clock = own is not None and own[0] in clock
        pins = pin_name(own, px, py) if own else None
        print(f"{net} stem of {inst} {cell} {orient} at ({comps[inst][1]},{comps[inst][2]})")
        print(f"   stem box {sbox}  contact {bb}  um ({px / 1000:.3f},{py / 1000:.3f})")
        if own:
            oi, oc, oo, oy, ox = own
            print(f"   touches {oi} {oc} {oo} at x {ox[0]}..{ox[1]} y {oy}"
                  f"{'  *** ON i_clk ***' if on_clock else ''}")
            if pins:
                print(f"   pin(s) of that cell covering the contact: {pins}")
        print(f"   rail island at y={rail_y} (row {(rail_y - rows[0][2]) // 3920}): {isl}"
              f"  via1 pads in contact={via_at(bb)}")
        shown += 1
        if shown >= args.limit:
            print(f"   ... stopping at {args.limit}")
            break


if __name__ == "__main__":
    main()
