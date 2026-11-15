#!/usr/bin/env python3
"""Build the ZN route from the accepted fix59 base.

fix59 supplies the clean-LVS route and the original ZN island. This script
trims and widens that island, replaces the ZN M2 vertical, V2 and M3 patch,
and applies the approved 60 dbu local notch to the adjacent M2 block.

By default the notch is applied alone (fix71), matching the notch-only approval.
--with-extension additionally adds the separately approved 60 dbu same-net
strip at x=4340..4400, y=9220..9610 and produces the selected fix70 geometry.
It is outside the notch footprint and is not part of the notch.

The M2 result is rebuilt as one merged region because the adjacent block is
represented by overlapping polygons; a local edit leaves internal edges
that the DRC width/spacing checks still see. Only M2 is touched by the merge.

The script reads --gds and writes --out. --check-only validates the input
geometry without modifying anything.
"""

import argparse
import hashlib
import json
import os
import sys

import klayout.db as db

TOP = "grx930_test_chip"
LAYERS = {
    "M2": 36,
    "V2": 38,
    "M3": 42,
}

OLD_Z_M2_ISLAND = db.Box(2_874_060, 2_578_100, 2_874_320, 2_578_710)
NEW_Z_M2_ISLAND = db.Box(2_874_060, 2_578_100, 2_874_320, 2_578_660)
Z_M2_WIDEN = db.Box(2_873_780, 2_578_046, 2_874_060, 2_578_660)

OLD_Z_M2_V = db.Box(2_873_500, 2_578_380, 2_873_910, 2_579_250)
NEW_Z_M2_V = db.Box(2_873_500, 2_578_380, 2_873_840, 2_579_250)
OLD_Z_V2 = db.Box(2_873_600, 2_578_950, 2_873_860, 2_579_210)
NEW_Z_V2 = db.Box(2_873_540, 2_578_950, 2_873_800, 2_579_210)
OLD_Z_M3 = db.Box(2_873_500, 2_578_940, 2_874_720, 2_579_220)
NEW_Z_M3 = db.Box(2_873_480, 2_578_940, 2_874_720, 2_579_220)

# Approved 60 dbu local notch. The effective diff vs fix61 is only this
# notch plus a 60 dbu-wide same-net strip at x=4340..4400, y=9220..9610;
# that strip preserves the 280 dbu block width after the edge shift.
Z_NOTCH = db.Box(2_874_060, 2_578_940, 2_874_120, 2_579_430)
Z_EXT = db.Box(2_874_340, 2_579_220, 2_874_400, 2_579_610)
Z_NOTCH_PROBE = db.Point(2_874_090, 2_579_000)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def bstr(box):
    return f"({box.left},{box.bottom};{box.right},{box.top})"


def region(cell, layer):
    shapes = db.Region(cell.begin_shapes_rec(layer))
    shapes.merge()
    return shapes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", required=True)
    ap.add_argument("--out")
    ap.add_argument("--report")
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--with-extension", action="store_true")
    args = ap.parse_args()
    if not args.check_only and (not args.out or not args.report):
        raise SystemExit("--out and --report are required unless --check-only")
    if not args.check_only and (os.path.exists(args.out) or os.path.exists(args.report)):
        raise SystemExit("refusing to overwrite output")

    layout = db.Layout()
    layout.read(args.gds)
    top = layout.cell(TOP)
    if top is None:
        raise SystemExit(f"missing {TOP}")
    layers = {name: layout.find_layer(db.LayerInfo(num, 0)) for name, num in LAYERS.items()}
    if None in layers.values():
        raise SystemExit("missing routing layer")
    geo = {name: region(top, layer) for name, layer in layers.items()}

    if (geo["M2"] & db.Region(OLD_Z_M2_ISLAND)).size() != 1:
        raise SystemExit("fix59 ZN island not found")
    if (geo["M2"] & db.Region(OLD_Z_M2_V)).size() != 1:
        raise SystemExit("fix59 ZN vertical not found")
    if (geo["V2"] & db.Region(OLD_Z_V2)).size() != 1:
        raise SystemExit("fix59 V2 not found")
    if (geo["M3"] & db.Region(OLD_Z_M3)).size() != 1:
        raise SystemExit("fix59 M3 patch not found")
    if (geo["M2"] & db.Region(Z_NOTCH)).area() == 0:
        raise SystemExit("adjacent M2 block not found at notch")

    result = {
        "input": args.gds,
        "input_sha256": sha256(args.gds),
        "topcell": TOP,
        "old_island": bstr(OLD_Z_M2_ISLAND),
        "new_island": bstr(NEW_Z_M2_ISLAND),
        "island_widen": bstr(Z_M2_WIDEN),
        "old_zn_m2_v": bstr(OLD_Z_M2_V),
        "new_zn_m2_v": bstr(NEW_Z_M2_V),
        "old_v2": bstr(OLD_Z_V2),
        "new_v2": bstr(NEW_Z_V2),
        "old_m3_patch": bstr(OLD_Z_M3),
        "new_m3_patch": bstr(NEW_Z_M3),
        "notch": bstr(Z_NOTCH),
        "extension": bstr(Z_EXT),
        "extension_applied": args.with_extension,
    }
    if args.check_only:
        print(json.dumps(result, indent=1))
        print("CHECK_OK", flush=True)
        return 0

    m2 = top.shapes(layers["M2"])
    removed = 0
    for sh in list(m2.each()):
        if sh.is_box() and sh.box == OLD_Z_M2_ISLAND:
            m2.erase(sh)
            removed += 1
    if removed != 1:
        raise SystemExit(f"expected one ZN island, found {removed}")

    v2 = top.shapes(layers["V2"])
    removed = 0
    for sh in list(v2.each()):
        if sh.is_box() and sh.box == OLD_Z_V2:
            v2.erase(sh)
            removed += 1
    if removed != 1:
        raise SystemExit(f"expected one V2, found {removed}")

    m3 = top.shapes(layers["M3"])
    removed = 0
    for sh in list(m3.each()):
        if sh.is_box() and sh.box == OLD_Z_M3:
            m3.erase(sh)
            removed += 1
    if removed != 1:
        raise SystemExit(f"expected one M3 patch, found {removed}")

    # Rebuild M2 once: island trim/widen, ZN vertical, notch, extension.
    r = region(top, layers["M2"])
    r -= db.Region(OLD_Z_M2_ISLAND)
    r |= db.Region(NEW_Z_M2_ISLAND) | db.Region(Z_M2_WIDEN)
    # Above the M2 horizontal the vertical is the only ZN metal; below it
    # the horizontal must remain. Cut only the old vertical's upper part.
    r -= db.Region(db.Box(2_873_500, 2_578_660, 2_873_910, 2_579_250))
    r |= db.Region(NEW_Z_M2_V)
    r -= db.Region(Z_NOTCH)
    if args.with_extension:
        r |= db.Region(Z_EXT)
    r.merge()
    m2.clear()
    for p in r.each():
        m2.insert(p)

    v2.insert(NEW_Z_V2)
    m3.insert(NEW_Z_M3)
    layout.write(args.out)

    written = db.Layout()
    written.read(args.out)
    ctop = written.cell(TOP)
    out_geo = {
        name: region(ctop, written.find_layer(db.LayerInfo(num, 0)))
        for name, num in LAYERS.items()
    }
    after = {
        "island": (out_geo["M2"] & db.Region(NEW_Z_M2_ISLAND)).size(),
        "island_widen": (out_geo["M2"] & db.Region(Z_M2_WIDEN)).size(),
        "zn_m2_v": (out_geo["M2"] & db.Region(NEW_Z_M2_V)).size(),
        "v2": (out_geo["V2"] & db.Region(NEW_Z_V2)).size(),
        "m3_patch": (out_geo["M3"] & db.Region(NEW_Z_M3)).size(),
        "notch_removed": (out_geo["M2"] & db.Region(Z_NOTCH)).area(),
        "extension": (out_geo["M2"] & db.Region(Z_EXT)).size(),
    }
    for key, value in after.items():
        if key == "notch_removed":
            if value != 0:
                raise SystemExit(f"notch still covered: {value}")
        elif key == "extension" and not args.with_extension:
            if value != 0:
                raise SystemExit(f"extension unexpectedly present: {value}")
        elif value < 1:
            raise SystemExit(f"missing added shape {key}")
    result["written"] = after
    result["output"] = args.out
    result["output_sha256"] = sha256(args.out)
    with open(args.report, "w") as fh:
        json.dump(result, fh, indent=1)
    print(json.dumps(result, indent=1))
    print("WRITE_OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
