# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Vias that land inside a supply stripe: the contact a routing-vs-stripe test cannot see.

The DEF's clock routing is clear of the rails, the taps and the stripes on its own layers.  What the
DEF does not spell out is the *via instances*: they are implicit at layer changes, and the streamed
GDS takes them from the artifact.  A via2 at a clock vertex that sits inside a VDD metal3 stripe
shortest the clock to the grid without any metal1 being involved, so this intersects each via cut
with the stripes of the layer it lands on.

    python3 via_on_stripe.py --def .../grx930_test_chip_filled_metal1.def \
        --gds .../stream_out_filled_metal1.gds [--limit 20]

Exit status 0.
"""

import argparse
import re
from collections import defaultdict

import klayout.db as db

# GF180 GDS numbers: via2=38/0, via3=40/0, via4=41/0 (see gf180mcu.lyp).
VIA_ON = {38: ("Metal3", 42), 40: ("Metal4", 46), 41: ("Metal5", 81)}
LABEL = {38: "via2", 40: "via3", 41: "via4"}
SEG_RE = re.compile(r"(Metal[1-5])(?: (\d+))?(?: \+ SHAPE \w+)? \( (\d+) (\d+)(?: \d+)? \)"
                    r" \( (\S+) (\S+)(?: \d+)? \)")
NET_RE = re.compile(r"^-\s+(\S+)")


def parse_stripes(path):
    out = defaultdict(list)
    in_special = False
    net = None
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("SPECIALNETS"):
            in_special = True
            continue
        if s.startswith("END SPECIALNETS"):
            in_special = False
            continue
        if not in_special:
            continue
        m = NET_RE.match(s)
        if m:
            net = m.group(1)
            continue
        if net not in ("VDD", "VSS") or "+ SHAPE STRIPE" not in s:
            continue
        m = SEG_RE.search(s)
        if not m:
            continue
        layer, w, x1, y1, x2, y2 = m.groups()
        if not w:
            continue
        x2 = x1 if x2 == "*" else x2
        y2 = y1 if y2 == "*" else y2
        half = int(w) // 2
        # DEF units (2 per dbu) -> dbu, and the stripe is a rectangle around its centre line
        out[layer].append((net, min(int(x1), int(x2)) // 2 - half // 2,
                           min(int(y1), int(y2)) // 2 - half // 2,
                           max(int(x1), int(x2)) // 2 + half // 2,
                           max(int(y1), int(y2)) // 2 + half // 2, int(w) // 2))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--gds", required=True)
    ap.add_argument("--limit", type=int, default=20)
    args = ap.parse_args()

    stripes = parse_stripes(args.def_file)
    print("stripes: " + ", ".join(f"{k}:{len(v)}" for k, v in sorted(stripes.items())))

    ly = db.Layout()
    ly.read(args.gds)
    top = ly.top_cell()
    for via, (sname, slayer) in sorted(VIA_ON.items()):
        cuts = db.Region(top.begin_shapes_rec(ly.layer(via, 0)))
        reg = db.Region()
        for net, x0, y0, x1, y1, w in stripes.get(sname, ()):
            reg.insert(db.Box(x0, y0, x1, y1))
        hits = cuts & reg
        print(f"{LABEL[via]} on {sname} ({via}/0) cuts={cuts.count()} stripe area={reg.area()} "
              f"cuts inside a stripe={hits.count()}")
        n = 0
        for p in hits.each():
            bb = p.bbox()
            cx, cy = (bb.left + bb.right) // 2, (bb.bottom + bb.top) // 2
            owner = [t for t in stripes.get(sname, ())
                     if t[1] <= cx <= t[3] and t[2] <= cy <= t[4]]
            print(f"   cut {bb} at ({cx},{cy}) um ({cx / 1000:.3f},{cy / 1000:.3f}) "
                  f"stripe {[o[0] for o in owner]}")
            n += 1
            if n >= args.limit:
                break


if __name__ == "__main__":
    main()
