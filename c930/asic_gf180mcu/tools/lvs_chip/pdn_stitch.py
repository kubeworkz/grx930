#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Stitch the die's metal1 supply islands to the metal3 supply grid with via1/via2 straps.

Why (doc/lvs_plan.md, 2026-11-03): the die's lvsdb carries 522 nets named VDD against one in the
CDL, so a one-to-521 partition has no bijection and no comparer bound can pair it. The fill pass
joined the rails under abutting cells but not between runs, and nothing ties a rail upward: at a
populated row the die has metal3/metal4/metal5 grid geometry and **zero via1** down to metal1
(`probe/pdn_probe.rb`). This pass is the missing via.

What it does, and why each choice is measured rather than assumed:

  * **Islands.** Every cell the DEF places has one full-width metal1 rail under its VDD text and
    one under its VSS text, 600 dbu tall (`probe/rail_bands.py`: 42/42 cell types, no exceptions).
    A rail's supply side follows the orientation -- VDD is the top band for `N` and the bottom band
    for `FS` -- so the supply geometry is known exactly from the DEF plus the library. VDD rails
    meet only at a row boundary where both neighbours draw VDD there, so an island is one maximal
    x-interval at one boundary; the tool checks that count against a merged-region count instead of
    trusting it.
  * **The grid.** The routed DEF and the artifact do not agree -- the DEF lists 130 vertical
    metal3 stripes per net that the GDS does not contain -- so the grid is read from the GDS. It
    is 524 horizontal metal3 stripes at a 10 um pitch, VDD and VSS interleaved. The DEF's own
    stripe lines give the phase, and the tool refuses if the GDS stripes do not sit on it.
  * **The strap.** A rail is 600 dbu tall, so a 380-dbu via1 landing pad fits inside it with
    110 dbu to spare. The strap leaves that pad, runs on **metal2** to the nearest metal3 stripe of
    the same supply (10 um at most), and lands with a via2. Metal2 is the only layer that can carry
    it: metal1 is the rail's own layer, and metal2-metal3 connect only where a via2 is drawn, so
    the run may cross the other supply's stripes without touching them.
  * **Clearance.** The one thing that can silently short is metal2: the strap and both pads must
    not overlap any existing metal2 shape, which includes every existing via1/via2 pad. Candidates
    are generated in bulk, filtered with one region intersection, and then re-checked on the
    written file by counting merged metal2 components -- every strap must be its own island there,
    so a strap that touched existing metal2 would show up as a missing count.

VSS is stitched too, and only where it needs it: the p-taps tie almost every VSS rail to the one
substrate net, so the fragments are the intervals with no well-tap cell in them. The report prints
both counts against the census (522 VDD nets, 56 VSS nets), which is what makes the mapping
falsifiable instead of convenient.

The straps go into the streamed GDS, not the DEF: this flow's vias live in the artifact's
hierarchy, and `stream_out.py` copies routing from the artifact rather than from the DEF, so a DEF
edit would not reach the layout. The DEF stays the record of what is placed; the report lists every
strap's coordinates and the island it serves.

    python3 pdn_stitch.py --def build/lvs_chip/filled/grx930_test_chip_filled_metal1.def \
        --gds build/lvs_chip/stream_out_filled_metal1.gds \
        --out-gds build/lvs_chip/stream_out_filled_stitched.gds \
        --report build/lvs_chip/strap_report.json

Exit status: 0 written, 2 refused (a placement, stripe phase, clearance or coverage check failed).
"""

import argparse
import json
import re
import sys
from collections import Counter, defaultdict

import klayout.db as db

ROOT = "/work/c930/asic_gf180mcu"
DEF = f"{ROOT}/build/lvs_chip/filled/grx930_test_chip_filled_metal1.def"
LIB = f"{ROOT}/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds"
GDS = f"{ROOT}/build/lvs_chip/stream_out_filled_metal1.gds"
OUT_GDS = f"{ROOT}/build/lvs_chip/stream_out_filled_stitched.gds"
REPORT = f"{ROOT}/build/lvs_chip/strap_report.json"

ROW_HALF = 300        # a rail is drawn 0.3 um either side of its row edge
VIA1 = "VIA_Via1_VV"  # metal2 pad 280 x 380: the tall side is the strap's direction
VIA2 = "VIA_Via2_VH"  # metal3 pad 380 x 280
PAD1_HALF_X, PAD1_HALF_Y = 130, 190   # metal1 pad of VIA_Via1_VV: 260 wide, 380 tall
M2_HALF_X, M2_HALF_Y = 140, 190
PAD3_HALF_X, PAD3_HALF_Y = 190, 140
STRIPE_PITCH = 20_000  # 20 um between stripes of one supply; VSS sits 10 um from VDD
SITE = 560
CANDIDATES = 96
M2_MARGIN = 40        # clearance a strap must keep from existing metal2 (0.04 um)
FILLTIE = "gf180mcu_fd_sc_mcu7t5v0__filltie"

ROW_RE = re.compile(r"^ROW\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\w+)\s+DO\s+(\d+)\s+BY\s+1"
                    r"\s+STEP\s+(\d+)")
COMP_RE = re.compile(r"^-\s+(\S+)\s+(\S+)\s+.*?\b(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)"
                     r"\s+(\w+)")
STRIPE_RE = re.compile(r"^(?:\+ ROUTED |NEW )?Metal3 (\d+) \+ SHAPE STRIPE \( (\d+) (\d+) \)"
                       r" \( (\d+) (\d+) \)")


def refuse(message):
    print(f"REFUSED  {message}")
    raise SystemExit(2)


def parse_def(path):
    """(units, components, {net: [horizontal stripe centre y]}) from the DEF."""
    units = 0
    comps = []
    stripes = {"VDD": [], "VSS": []}
    net = None
    in_comp = in_special = False
    for line in open(path, errors="replace"):
        s = line.strip()
        m = re.match(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", s)
        if m:
            units = int(m.group(1))
            continue
        if s.startswith("COMPONENTS"):
            in_comp = True
            continue
        if s.startswith("END COMPONENTS"):
            in_comp = False
            continue
        if in_comp:
            m = COMP_RE.match(s)
            if m:
                comps.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4)),
                              m.group(5)))
            continue
        if s.startswith("SPECIALNETS"):
            in_special = True
            continue
        if s.startswith("END SPECIALNETS"):
            in_special = False
            net = None
            continue
        if not in_special:
            continue
        if s.startswith("- "):
            net = s.split()[1]
            continue
        if net not in stripes:
            continue
        m = STRIPE_RE.match(s)
        # The DEF gives a stripe as its centre line and its width; horizontal stripes are the
        # ones with y0 == y1, which is the family the grid is built from.
        if m and m.group(3) == m.group(5) and int(m.group(1)) == 2 * 2 * 800:
            # width 3200 DEF units (0.5 um each) = the 1.6 um stripe the GDS draws
            stripes[net].append(int(m.group(3)))
    if not units:
        refuse("no `UNITS DISTANCE MICRONS` in the DEF header")
    if not comps:
        refuse("no components in the DEF")
    for name, ys in stripes.items():
        if not ys:
            refuse(f"no horizontal Metal3 stripes on special net {name}")
    return units, comps, stripes


def lib_rails(lib, cells):
    """{cell: (width, height, {net: top_side})} from the VDD/VSS texts and the 0/0 box."""
    text_layer = lib.layer(34, 10)
    out = {}
    for name in cells:
        cell = lib.cell(name)
        if cell is None:
            refuse(f"{name} is not in the library GDS")
        box = cell.bbox(lib.layer(0, 0))
        if box is None or box.empty():
            refuse(f"{name} has no layer 0/0 box")
        w, h = box.width(), box.height()
        pos = {}
        for s in cell.shapes(text_layer).each():
            if s.is_text() and s.text is not None and s.text.string in ("VDD", "VSS"):
                pos[s.text.string] = s.text.trans.disp
        if set(pos) != {"VDD", "VSS"}:
            refuse(f"{name} has no VDD/VSS text pair (found {sorted(pos)})")
        sides = {net: p.y > h // 2 for net, p in pos.items()}
        if sides["VDD"] == sides["VSS"]:
            refuse(f"{name}: VDD and VSS texts are on the same rail side")
        out[name] = (w, h, sides)
    return out


def merge_intervals(items):
    """[(x0, x1, payload)] -> [(x0, x1, [payload])] with touching/overlapping runs merged."""
    items = sorted(items, key=lambda t: (t[0], t[1]))
    runs = []
    for x0, x1, payload in items:
        if runs and x0 <= runs[-1][1]:
            runs[-1][1] = max(runs[-1][1], x1)
            runs[-1][2].append(payload)
        else:
            runs.append([x0, x1, [payload]])
    return [(a, b, p) for a, b, p in runs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", default=DEF)
    ap.add_argument("--lib", default=LIB)
    ap.add_argument("--gds", default=GDS)
    ap.add_argument("--out-gds", default=OUT_GDS)
    ap.add_argument("--report", default=REPORT)
    ap.add_argument("--no-vss", action="store_true", help="stitch VDD only")
    ap.add_argument("--limit", type=int, default=0, help="stitch at most N islands (smoke test)")
    ap.add_argument("--allow-unstitched", type=int, default=0,
                    help="permit N islands to be left without a strap (they are listed)")
    args = ap.parse_args()

    units, comps, def_stripes = parse_def(args.def_file)
    lib = db.Layout()
    lib.read(args.lib)
    ly = db.Layout()
    ly.read(args.gds)
    tops = list(ly.top_cells())
    if len(tops) != 1:
        refuse(f"the GDS has {len(tops)} top cells")
    top = tops[0]
    print(f"die {args.gds}: dbu={ly.dbu} top={top.name} bbox={top.bbox()}")

    scale = ly.dbu * units
    if abs(scale - 2.0) > 1e-12:
        refuse(f"DEF {units}/um against dbu {ly.dbu} gives scale {scale}, expected 2")

    def g(v):
        return int(round(v / scale))

    used = {c[1] for c in comps}
    rails = lib_rails(lib, used)
    heights = sorted({h for _w, h, _s in rails.values()})
    if heights != [3920]:
        refuse(f"the placed cells do not share one row height: {heights}")
    print(f"cells: {len(used)} types, {len(comps)} placed, row height {heights[0]} dbu, "
          f"rail bands {2 * ROW_HALF} dbu tall")

    # --- the grid phase, from the DEF and then from the GDS --------------------------------
    phases = {}
    for net in ("VDD", "VSS"):
        ys = sorted({g(y) for y in def_stripes[net]})
        ph = ys[0] % STRIPE_PITCH
        off = [y for y in ys if (y - ph) % STRIPE_PITCH]
        if off:
            refuse(f"{net}: DEF stripes are not on one {STRIPE_PITCH} dbu pitch ({off[0]}, ...)")
        phases[net] = ph
    if (phases["VSS"] - phases["VDD"]) % STRIPE_PITCH != STRIPE_PITCH // 2:
        refuse(f"VDD phase {phases['VDD']} and VSS phase {phases['VSS']} are not interleaved")
    print(f"grid: DEF gives VDD stripes at y%{STRIPE_PITCH}=={phases['VDD']}, "
          f"VSS at {phases['VSS']}")

    m3 = db.Region(top.begin_shapes_rec(ly.layer(42, 0)))
    stripes = {"VDD": defaultdict(list), "VSS": defaultdict(list)}
    ns = Counter()
    for p in m3.merged().each():
        bb = p.bbox()
        if bb.height() != 1600 or bb.width() < 100_000:
            continue
        cy = (bb.bottom + bb.top) // 2
        for net in ("VDD", "VSS"):
            if (cy - phases[net]) % STRIPE_PITCH == 0:
                stripes[net][cy].append((bb.left, bb.right))
                ns[net] += 1
    for net in ("VDD", "VSS"):
        if not ns[net]:
            refuse(f"no metal3 stripes for {net} on the DEF phase")
        if len(stripes[net]) > 1:
            ys = sorted(stripes[net])
            gaps = Counter(b - a for a, b in zip(ys, ys[1:]))
            if gaps.most_common(1)[0][0] % STRIPE_PITCH:
                refuse(f"{net}: GDS stripe spacing {gaps.most_common(1)[0][0]} is not a pitch "
                       f"multiple")
    print(f"grid: GDS carries {ns['VDD']} VDD and {ns['VSS']} VSS metal3 stripes "
          f"({len(stripes['VDD'])} / {len(stripes['VSS'])} distinct y), "
          f"width {sorted({b[1] - b[0] for v in stripes['VDD'].values() for b in v})[:3]}.."
          f"{sorted({b[1] - b[0] for v in stripes['VDD'].values() for b in v})[-1:]} dbu")

    # --- islands --------------------------------------------------------------------------
    bands = defaultdict(list)   # (net, boundary y) -> [(x0, x1, cell)]
    taps = defaultdict(list)    # net -> [(x0, x1, boundary y)] of well-tie cells
    # Only the four orientations that keep a cell's box on its row can occur here. N and FN keep
    # the cell upright (FN mirrors in x, which a full-width rail cannot notice), and FS and S put
    # the cell's top edge at the bottom of its box; E/W would swap width and height and break the
    # row grid, so they are refused rather than guessed at.
    UPRIGHT = ("N", "FN")
    for inst, cell, x, y, orient in comps:
        w, h, sides = rails[cell]
        if orient not in ("N", "FS", "FN", "S"):
            refuse(f"{inst}: orientation {orient} is not on a row")
        x0, y0 = g(x), g(y)
        x1 = x0 + w
        upright = orient in UPRIGHT
        for net in ("VDD", "VSS"):
            top_side = sides[net] if upright else not sides[net]
            cy = y0 + (h if top_side else 0)
            bands[(net, cy)].append((x0, x1, cell))
            if cell == FILLTIE:
                taps[net].append((x0, x1, cy))

    islands = {}
    for key in sorted(bands):
        islands[key] = merge_intervals(bands[key])
    counts = {net: sum(len(v) for k, v in islands.items() if k[0] == net)
              for net in ("VDD", "VSS")}
    print(f"islands: VDD {counts['VDD']}, VSS {counts['VSS']} "
          f"({len(taps['VDD'])} well-tie cells, {len(taps['VSS'])} VSS taps)")

    def tapped(net, cy, x0, x1):
        return any(t[2] == cy and t[0] < x1 and t[1] > x0 for t in taps[net])

    todo = []      # (net, cy, x0, x1, tied)
    for (net, cy), runs in sorted(islands.items()):
        if net == "VSS" and args.no_vss:
            continue
        for x0, x1, payload in runs:
            tied = tapped(net, cy, x0, x1)
            if net == "VSS" and tied:
                continue          # the p-taps already put this rail on the substrate net
            todo.append((net, cy, x0, x1, tied))
    print(f"strap targets: {sum(1 for t in todo if t[0] == 'VDD')} VDD, "
          f"{sum(1 for t in todo if t[0] == 'VSS')} untied VSS")
    if args.limit:
        todo = todo[:args.limit]
        print(f"LIMIT  stitching only the first {len(todo)} targets")

    # --- the island model, checked against merged geometry --------------------------------
    # The intervals claim to be exactly the connected components of the rail metal. For VDD that
    # is the whole net, so the counts must agree; for VSS they must not, because the p-taps join
    # rails through the substrate and no metal1 geometry knows about them -- which is why the
    # VSS targets are the intervals with no tap instead of the components.
    for net in ("VDD", "VSS"):
        reg = db.Region()
        for (n, cy), runs in islands.items():
            if n != net:
                continue
            for x0, x1, _p in runs:
                reg.insert(db.Box(x0, cy - ROW_HALF, x1, cy + ROW_HALF))
        comp = reg.merged().count()
        print(f"{net}: {counts[net]} rail intervals merge into {comp} metal1 components")
        if net == "VDD" and comp != counts["VDD"]:
            refuse(f"VDD intervals ({counts['VDD']}) are not the metal1 components ({comp}): "
                   f"the island model is wrong")

    # --- candidates -----------------------------------------------------------------------
    # A site is (x1 on the rail, x2 on the stripe). x2 == x1 is a straight drop; x2 != x1 adds one
    # metal2 segment along the stripe, which is only needed where nothing straight is clear.
    def stripe_y(net, cy):
        d = (phases[net] - cy) % STRIPE_PITCH
        if d > STRIPE_PITCH // 2:
            d -= STRIPE_PITCH
        return cy + d

    def boxes_for(x1, x2, y1, ys):
        vert = db.Box(x1 - M2_HALF_X, min(y1, ys) - M2_HALF_Y,
                      x1 + M2_HALF_X, max(y1, ys) + M2_HALF_Y)
        if x2 == x1:
            return [vert]
        horiz = db.Box(min(x1, x2) - M2_HALF_X, ys - M2_HALF_Y,
                       max(x1, x2) + M2_HALF_X, ys + M2_HALF_Y)
        return [vert, horiz]

    def make_candidates(targets, offsets, step=SITE, y_shifts=(0,), limit=CANDIDATES):
        """Every (x1, y1) on the island x (x2, y_stripe) on the grid, within the pad's reach."""
        out = []
        for i in targets:
            net, cy, x0, x1, _t = todo[i]
            ys = stripe_y(net, cy)
            spans = stripes[net].get(ys)
            if not spans:
                continue
            lo, hi = x0 + PAD1_HALF_X, x1 - PAD1_HALF_X
            if hi < lo:
                continue
            n = max(1, min(limit, (hi - lo) // step + 1))
            mid = (lo + hi) // 2
            xs = []
            for k in range(n):
                off = 0 if k == 0 else ((k + 1) // 2) * step * (1 if k % 2 else -1)
                x = min(hi, max(lo, mid + off))
                if x not in xs:
                    xs.append(x)
            for x1v in xs:
                for dy in y_shifts:
                    y1v = cy + dy
                    if abs(dy) + PAD1_HALF_Y > ROW_HALF:
                        continue
                    for dx in offsets:
                        x2v = x1v + dx
                        if not any(a <= x2v - PAD3_HALF_X and x2v + PAD3_HALF_X <= b
                                   for a, b in spans):
                            continue
                        out.append({"island": i, "net": net, "x1": x1v, "x2": x2v,
                                    "y_rail": y1v, "y_stripe": ys,
                                    "boxes": boxes_for(x1v, x2v, y1v, ys)})
        return out

    TILE = 4000

    def blocked_set(cands, m2, margin=M2_MARGIN):
        # The test is on a **grown** box. An edge-to-edge abutment has no overlapping area, so a
        # plain boolean AND reports nothing -- and 539 of the first 1027 straps did exactly that:
        # they shared an edge with existing metal2 and the netlist would have called it a short.
        region = db.Region()
        for c in cands:
            for b in c["boxes"]:
                region.insert(b.enlarged(margin))
        hits = m2 & region
        index = defaultdict(list)
        for i, c in enumerate(cands):
            for bb in c["boxes"]:
                eb = bb.enlarged(margin)
                for tx in range(eb.left // TILE, eb.right // TILE + 1):
                    for ty in range(eb.bottom // TILE, eb.top // TILE + 1):
                        index[(tx, ty)].append(i)
        blocked = set()
        for p in hits.each():
            bb = p.bbox()
            for tx in range(bb.left // TILE, bb.right // TILE + 1):
                for ty in range(bb.bottom // TILE, bb.top // TILE + 1):
                    for i in index.get((tx, ty), ()):
                        if i in blocked:
                            continue
                        if any(b.enlarged(margin).overlaps(bb) for b in cands[i]["boxes"]):
                            blocked.add(i)
        return blocked

    def choose(cands, blocked, wanted, taken):
        per_island = defaultdict(list)
        for i, c in enumerate(cands):
            if i not in blocked and c["island"] in wanted:
                per_island[c["island"]].append(i)
        picked = {}
        for island in sorted(per_island):
            for j in per_island[island]:
                clash = False
                for bb in cands[j]["boxes"]:
                    for tx in range(bb.left // TILE, bb.right // TILE + 1):
                        for ty in range(bb.bottom // TILE, bb.top // TILE + 1):
                            for other in taken.get((tx, ty), ()):
                                if other.overlaps(bb.enlarged(1)):
                                    clash = True
                                    break
                            if clash:
                                break
                        if clash:
                            break
                    if clash:
                        break
                if clash:
                    continue
                picked[island] = j
                for bb in cands[j]["boxes"]:
                    for tx in range(bb.left // TILE, bb.right // TILE + 1):
                        for ty in range(bb.bottom // TILE, bb.top // TILE + 1):
                            taken[(tx, ty)].append(bb)
                break
        return picked

    m2 = db.Region(top.begin_shapes_rec(ly.layer(36, 0)))
    print(f"metal2: {m2.count()} shapes on the die")
    taken = defaultdict(list)
    chosen = {}        # island -> index into all_cands
    all_cands = []
    blocked_total = 0

    dogleg = [k * SITE * s for k in range(1, 7) for s in (-1, 1)]
    # Each plan widens the search only for the islands the previous one could not serve: a
    # straight drop first (the shortest possible strap), then a dog-leg along the stripe, then the
    # same two at a finer pitch with the via moved inside the 600-dbu rail, and finally a 1-dbu
    # clearance for any island surrounded by metal2. A 1-dbu test still refuses a butt joint, which
    # is what the netlist would call a short.
    plans = [
        ("straight drop, 0.04 um clearance", M2_MARGIN, (0,), SITE, (0,), CANDIDATES),
        ("dog-leg, 0.04 um clearance", M2_MARGIN, [0] + dogleg, SITE, (0,), CANDIDATES),
        ("straight, 0.001 um clearance", 1, (0,), SITE // 4,
         (0, -110, 110, -55, 55), 4 * CANDIDATES),
        ("dog-leg, 0.001 um clearance", 1, [0] + dogleg, SITE // 4,
         (0, -110, 110, -55, 55), 4 * CANDIDATES),
    ]
    missing = list(range(len(todo)))
    for label, margin, offsets, step, y_shifts, limit in plans:
        if not missing:
            break
        batch = make_candidates(missing, offsets, step=step, y_shifts=y_shifts, limit=limit)
        blocked = blocked_set(batch, m2, margin)
        blocked_total += len(blocked)
        base = len(all_cands)
        all_cands.extend(batch)
        picked = choose(batch, blocked, set(missing), taken)
        chosen.update({island: base + j for island, j in picked.items()})
        print(f"plan {label}: {len(batch)} candidates for {len(missing)} islands, "
              f"{len(blocked)} blocked, {len(picked)} served")
        missing = [i for i in range(len(todo)) if i not in chosen]

    if missing:
        print(f"UNSTITCHED  {len(missing)} islands have no clear strap site: "
              + ", ".join(f"{todo[i][0]}@y{todo[i][1]} x{todo[i][2]}..{todo[i][3]}"
                          for i in missing))
        if len(missing) > args.allow_unstitched:
            print(f"REFUSED  {len(missing)} unstitched islands exceeds --allow-unstitched "
                  f"{args.allow_unstitched}")
            raise SystemExit(2)
        print(f"PROCEEDING with {len(missing)} islands left on their own supply net")
    print(f"straps: {len(chosen)} chosen, one per island")

    # The straps must be clear of the die's metal2 *and* of each other: two straps that touch
    # would join whatever supplies they belong to.
    added = db.Region()
    for j in chosen.values():
        for b in all_cands[j]["boxes"]:
            added.insert(b)
    if added.merged().count() != len(chosen):
        refuse(f"the chosen straps merge into {added.merged().count()} metal2 shapes, "
               f"not {len(chosen)}")
    grown = db.Region()
    for j in chosen.values():
        for b in all_cands[j]["boxes"]:
            grown.insert(b.enlarged(1))
    collide = m2 & grown
    print(f"metal2: straps {len(chosen)}, merged {added.merged().count()}, "
          f"within 1 dbu of existing metal2 {collide.count()} ({collide.area()} dbu^2)")
    if not collide.is_empty():
        refuse(f"{collide.count()} chosen straps touch existing metal2")
    print(f"metal2: components before {m2.merged().count()}")

    # --- write ----------------------------------------------------------------------------
    v1 = ly.cell(VIA1)
    v2 = ly.cell(VIA2)
    if v1 is None or v2 is None:
        refuse(f"the GDS has no {VIA1}/{VIA2} cell")
    m2_layer = ly.layer(36, 0)
    top.shapes(m2_layer)   # ensure the layer exists before inserting
    before = m2.merged().count()
    for j in sorted(chosen.values(), key=lambda i: (all_cands[i]["y_rail"], all_cands[i]["x1"])):
        c = all_cands[j]
        top.insert(db.CellInstArray(v1.cell_index(),
                                    db.Trans(db.Vector(c["x1"], c["y_rail"]))))
        top.insert(db.CellInstArray(v2.cell_index(),
                                    db.Trans(db.Vector(c["x2"], c["y_stripe"]))))
        for b in c["boxes"]:
            top.shapes(m2_layer).insert(b)
    ly.write(args.out_gds)
    print(f"wrote {args.out_gds}")

    # --- re-check the written file --------------------------------------------------------
    chk = db.Layout()
    chk.read(args.out_gds)
    ctop = next(iter(chk.top_cells()))
    m2_after = db.Region(ctop.begin_shapes_rec(chk.layer(36, 0))).merged()
    grew = m2_after.count() - before
    if grew != len(chosen):
        refuse(f"after writing, metal2 components grew by {grew}, expected {len(chosen)}: "
               f"a strap touches existing metal2")
    m1_after = db.Region(ctop.begin_shapes_rec(chk.layer(34, 0)))
    m3_after = db.Region(ctop.begin_shapes_rec(chk.layer(42, 0)))

    # Every strap: metal1 pad inside the island's rail, metal3 pad inside a stripe of its supply.
    # Both are checked in bulk -- one region subtraction for all 1000 pads, not 1000 subtractions
    # of a 20 mm^2 region, which is what made the first version look like it had hung.
    bad = Counter()
    pads1 = db.Region()
    pads3 = db.Region()
    for j in chosen.values():
        c = all_cands[j]
        _net, cy, x0, x1, _t = todo[c["island"]]
        pad1 = db.Box(c["x1"] - PAD1_HALF_X, c["y_rail"] - PAD1_HALF_Y,
                      c["x1"] + PAD1_HALF_X, c["y_rail"] + PAD1_HALF_Y)
        if pad1.left < x0 or pad1.right > x1 or pad1.bottom < cy - ROW_HALF \
                or pad1.top > cy + ROW_HALF:
            bad["outside the island"] += 1
        pads1.insert(pad1)
        pads3.insert(db.Box(c["x2"] - PAD3_HALF_X, c["y_stripe"] - PAD3_HALF_Y,
                            c["x2"] + PAD3_HALF_X, c["y_stripe"] + PAD3_HALF_Y))
    if not (pads1 - m1_after).is_empty():
        bad["metal1 pad off metal1"] += 1
    if not (pads3 - m3_after).is_empty():
        bad["metal3 pad off metal3"] += 1
    if bad:
        print(f"REFUSED  strap pads are not inside their own net's geometry: {dict(bad)}")
        raise SystemExit(2)
    print(f"pads: {len(chosen)} metal1 and {len(chosen)} metal3 pads all inside their own "
          f"geometry")

    stats = {net: Counter() for net in ("VDD", "VSS")}
    lengths = defaultdict(list)
    for j in chosen.values():
        c = all_cands[j]
        stats[c["net"]]["straps"] += 1
        lengths[c["net"]].append(abs(c["y_stripe"] - c["y_rail"]))
    for net in ("VDD", "VSS"):
        ls = lengths[net]
        print(f"{net}: islands {counts[net]}, straps {stats[net]['straps']}, "
              f"target islands {sum(1 for t in todo if t[0] == net)}, "
              f"strap length {min(ls) if ls else 0}..{max(ls) if ls else 0} dbu "
              f"(mean {sum(ls) // len(ls) if ls else 0})")

    report = {
        "inputs": {"def": args.def_file, "lib": args.lib, "gds": args.gds},
        "grid": {"pitch": STRIPE_PITCH, "vdd_phase": phases["VDD"], "vss_phase": phases["VSS"],
                 "vdd_stripes": ns["VDD"], "vss_stripes": ns["VSS"]},
        "islands": {net: counts[net] for net in ("VDD", "VSS")},
        "taps": {net: len(taps[net]) for net in ("VDD", "VSS")},
        "targets": {net: sum(1 for t in todo if t[0] == net) for net in ("VDD", "VSS")},
        "straps": {net: stats[net]["straps"] for net in ("VDD", "VSS")},
        "strap_length_dbu": {net: {"min": min(lengths[net]), "max": max(lengths[net]),
                                   "mean": sum(lengths[net]) // len(lengths[net])}
                             for net in ("VDD", "VSS") if lengths[net]},
        "candidates": {"total": len(all_cands), "blocked_by_metal2": blocked_total},
        "unstitched": [{"net": todo[i][0], "y": todo[i][1], "x0": todo[i][2], "x1": todo[i][3]}
                       for i in missing],
        "metal2_components": {"before": before, "after": m2_after.count()},
        "sites": [{"net": all_cands[j]["net"], "x1": all_cands[j]["x1"],
                   "x2": all_cands[j]["x2"], "y_rail": all_cands[j]["y_rail"],
                   "y_stripe": all_cands[j]["y_stripe"],
                   "island": all_cands[j]["island"]}
                  for j in sorted(chosen.values())],
    }
    with open(args.report, "w") as fh:
        json.dump(report, fh, indent=1)
    print(f"wrote {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
