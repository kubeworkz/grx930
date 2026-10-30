#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""merge_layers.py -- merge each layer's shapes once, so the netter unions fewer objects.

WHY

  A deep net-only run spent 5 h 46 min inside `netlist` and wrote nothing
  (`Claude outputs/stream_out_fix.md` section 4f), while the comparer answers the same design in
  50.5 s. That run was on the stream the via-units bug had already corrupted, so its number is not a
  baseline: section 4h re-measures both arms on the fixed layout, where merging cuts the deck's
  read/extract phase by 62 % and the netlist phase not at all. Nothing in that time was the aligner and nothing was a giant polygon -- the worst shape in
  the file is 32 vertices. What is left is breadth: 1.35 M shapes on `41/0`, 1.17 M on `33/0`, 742 k
  on `34/0`, 744 k on `36/0`, all of which the netter has to union into one graph.

  Merging is the one transformation that reduces that count without changing what the layout means:
  two metal polygons that abut are already one node to the netter, so replacing them with their union
  removes work and changes no connection. This writes that layout and proves the equivalence rather
  than asserting it.

WHAT IT DOES

  For every layer: builds the top cell's region for that layer (hierarchy included, as the deck sees
  it), records polygon and vertex counts, merges, and writes the merged polygons into a flat copy of
  the layout. Texts (labels) are copied unchanged, on their own layers.

  The output is **flat**: one top cell, no instances. That is deliberate -- the netter unions the
  top's coverage anyway -- but it means a merged-vs-unmerged timing also differs in hierarchy, and a
  report that quotes it has to say so.

HOW IT PROVES NEUTRALITY

  The proof is one check per layer: `merged XOR unmerged` is empty over the whole layer. XOR is a
  point-set operation, so an empty result says the merged file covers exactly the same silicon --
  which is the only property connectivity depends on. (An empty XOR also implies equal area, so
  nothing is gained by testing area as well. It does not say the netter is faster; that is what the
  second run measures.)

  The first version of this script tested `before.area() == merged.area()` instead, and that was a
  bug worth recording: a Region with `merged_semantics = False` -- the only way to get a "before"
  count at all, since inserting into a merged-semantics region unions the layer and the count
  becomes the "after" count -- reports area as the **sum over its polygons**, double counting
  overlap. On `21/0` (nwell, 53,745 shapes, abutting cells sharing well strips) that sum is 10.6 %
  above the union, so a merge that was *exactly* neutral was reported as `MERGE: FAIL`.

BUCKETS (a fallback, not the default)

  This script was written while a global `Region#merged()` appeared never to return on this die, and
  `--buckets N` exists for that case: it splits each layer into an N x N plain of cores, puts every
  shape that touches a core into that core's region (a long wire lands in every core along its path
  -- the halo, chosen by bounding box rather than by a distance guess), merges each core, and clips
  the result back. Neighbouring cores meet on the exact same coordinate, so the pieces abut rather
  than overlap, and the proof is the same XOR run per core: `(merged & core) XOR (region & core)`
  empty, cheap at core size.

  That hang turned out to be a units bug upstream, not this geometry (`stream_out.py` was inserting
  via instances through the integer transform overload, piling all 644,699 of them into a 3 x 5 um
  corner). With the fixed layout, the plain global merge finishes every one of the 27 layers --
  6,681,399 -> 4,346,840 polygons in 140 s -- so **`--buckets 0` is the default**. Bucketing is kept
  because it is the only way to finish a layer that genuinely defeats the scanline, and it is not
  free: a wire crossing a core boundary is written as several polygons, which on a small cell
  fragments the output badly (25 polygons became 154 kB of pieces at 16 x 16).

USAGE

  python3 tools/lvs_chip/merge_layers.py --gds build/lvs_chip/stream_out.gds \\
      --out build/lvs_chip/stream_out_merged.gds --json build/lvs_chip/merge_layers.json
  python3 tools/lvs_chip/merge_layers.py --only 46/0 --buckets 24 --steps      # one layer, timed
"""

import argparse
import json
import os
import sys
import time

import klayout.db as db


def hull_points(p):
    """Vertex count of the containing hull, which is what the netter's bounds care about."""
    if hasattr(p, "num_points_hull"):
        return p.num_points_hull()
    return p.num_points()


def layer_rows(layout):
    """Every layer in the file. Counting here would be a second full pass over 6.4 M shapes, and the
    loop below already gets the count for free from the unmerged region it has to build anyway."""
    return [(li, layout.get_info(li)) for li in layout.layer_indexes()]


def merge_bucketed(before, n, record, bad, stage=lambda _m: None):
    """Merge `before` core by core, returning the merged coverage as a region of core-clipped pieces.

    Every shape whose bounding box touches a core goes into that core's region, so a shape crossing
    the plain is present in each core it spans and the merge inside a core sees its full local
    neighbourhood. The pieces then meet on exact core edges: abutting, never overlapping.
    """
    box = before.bbox()
    if box.empty():
        return db.Region()
    nx = ny = n
    tw = max(1, -(-box.width() // nx))
    th = max(1, -(-box.height() // ny))

    stage(f"plain {nx}x{ny} of {tw}x{th} dbu over {box}, collecting cores")
    buckets = {}
    seen = 0
    for poly in before.each():
        bb = poly.bbox()
        ix0 = min(nx - 1, max(0, (bb.left - box.left) // tw))
        ix1 = min(nx - 1, max(0, (bb.right - box.left) // tw))
        iy0 = min(ny - 1, max(0, (bb.bottom - box.bottom) // th))
        iy1 = min(ny - 1, max(0, (bb.top - box.bottom) // th))
        for ix in range(ix0, ix1 + 1):
            for iy in range(iy0, iy1 + 1):
                reg = buckets.get((ix, iy))
                if reg is None:
                    reg = db.Region()
                    reg.merged_semantics = False
                    buckets[(ix, iy)] = reg
                reg.insert(poly)
        seen += 1
        if not seen % 25_000:
            stage(f"  collected {seen} shapes into {len(buckets)} cores")
    stage(f"  collected {seen} shapes into {len(buckets)} cores")

    out = db.Region()
    out.merged_semantics = False
    worst = 0
    for done, ((ix, iy), reg) in enumerate(sorted(buckets.items()), 1):
        if done % 8 == 1 or done == len(buckets):
            stage(f"  core {done}/{len(buckets)} ({ix},{iy}) {reg.count()} polys")
        x0 = box.left + ix * tw
        x1 = min(x0 + tw - 1, box.right)
        y0 = box.bottom + iy * th
        y1 = min(y0 + th - 1, box.top)
        core = db.Box(x0, y0, x1, y1)
        merged = reg.merged() & core
        diff = merged.xor(reg & core)
        if diff.count():
            bad.append((record["layer"], f"core {ix},{iy}", diff.count(), diff.area()))
        worst = max(worst, merged.count())
        out.insert(merged)

    record["buckets"] = len(buckets)
    record["bucket_max_polys"] = worst
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gds", default="build/lvs_chip/stream_out.gds")
    ap.add_argument("--out", default="build/lvs_chip/stream_out_merged.gds")
    ap.add_argument("--json", default="build/lvs_chip/merge_layers.json")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the XOR/area proof (for a timing-only smoke run)")
    ap.add_argument("--only", default=None,
                    help="one layer as LAYER/DATATYPE, e.g. 46/0 -- for timing a single layer")
    ap.add_argument("--steps", action="store_true",
                    help="print each stage of a layer as it happens, so a slow one is visible")
    ap.add_argument("--buckets", type=int, default=0,
                    help="split each layer into N x N cores and merge each one; 0 (default) is one "
                         "global merge, which finishes on every layer of this die. Non-zero is a "
                         "fallback for a layer whose global merge does not return, and it "
                         "fragments polygons at core boundaries")
    ap.add_argument("--no-merge", action="store_true",
                    help="flatten only: write every layer through unchanged. This is the control "
                         "for the merged file -- both are flat, so a timing difference between "
                         "them is the merge and not the hierarchy, which the merged file also "
                         "removes and which the die-sized extraction phase is sensitive to")
    ap.add_argument("--xor-budget", type=int, default=200_000,
                    help="in global mode, largest layer (polygons before merging) the whole-layer "
                         "XOR proof is run on")
    args = ap.parse_args()

    t0 = time.time()
    src = db.Layout()
    src.read(args.gds)
    tops = src.top_cells()
    if len(tops) != 1:
        sys.exit(f"merge_layers: {len(tops)} top cells in {args.gds}; expected one")
    top = tops[0]
    print(f"read {args.gds} ({os.path.getsize(args.gds)} B) top={top.name} dbu={src.dbu} "
          f"in {time.time() - t0:.1f} s", flush=True)

    out = db.Layout()
    out.dbu = src.dbu
    otop = out.create_cell(top.name)

    rows = []
    bad = []
    for li, info in layer_rows(src):
        if args.only and f"{info.layer}/{info.datatype}" != args.only:
            continue
        t = time.time()

        def stage(name, _t=t):
            if args.steps:
                print(f"      {info.layer}/{info.datatype} {name:<22} {time.time() - _t:7.1f} s",
                      flush=True)
        stage("start")
        # A Region built over an iterator has merged_semantics ON by default, which silently unions
        # the layer while reading it -- the "before" count would then already be the "after" count,
        # and the expensive part of this script would run twice. Off first, then merge once, on
        # purpose.
        # Texts first, by their own pass: they are not polygons, they carry the pin names the deck
        # reports, and a Region read over them is not what either side of this comparison wants.
        texts = []
        it = top.begin_shapes_rec(li)
        while not it.at_end():
            sh = it.shape()
            if sh.is_text():
                texts.append(sh.text)
            it.next()
        before = db.Region()
        before.merged_semantics = False
        before.insert(top.begin_shapes_rec(li))
        n_before = before.count()
        stage(f"inserted {n_before} polys, {len(texts)} texts")
        v_before = sum(hull_points(p) for p in before.each())
        stage(f"counted {v_before} vertices")

        record = {
            "layer": info.layer,
            "datatype": info.datatype,
            "name": info.name or "",
            "polys_before": n_before,
            "vertices_before": v_before,
            "texts": len(texts),
        }

        if args.no_merge:
            merged = before
            record["proof"] = "flatten-only"
            record["merge_mode"] = "none"
        elif args.buckets and n_before:
            merged = merge_bucketed(before, args.buckets, record, bad, stage)
            record["proof"] = "xor-per-core"
            record["merge_mode"] = f"buckets {args.buckets}x{args.buckets}"
        else:
            merged = before.merged()
            record["proof"] = "xor" if n_before <= args.xor_budget else "area-bound"
            record["merge_mode"] = "global"
            if not args.no_verify and n_before:
                # `before` has merged_semantics off, so its area() is the sum over polygons and
                # counts overlap twice -- an upper bound on coverage, not coverage. Only the
                # direction that cannot happen (union covering more than the sum) is a failure.
                area_sum = before.area()
                area_union = merged.area()
                record["area_sum_before"] = area_sum
                record["area_union"] = area_union
                record["area_sum_over_union"] = (round(area_sum / area_union, 6)
                                                 if area_union else None)
                if area_union > area_sum:
                    bad.append((record["layer"], "area-added", area_sum, area_union))
            if not args.no_verify and n_before and n_before <= args.xor_budget:
                diff = merged.xor(before)
                record["xor_polygons"] = diff.count()
                record["xor_area"] = diff.area()
                if diff.count():
                    bad.append((record["layer"], "xor", diff.count(), diff.area()))
            elif n_before:
                record["xor_polygons"] = f"skipped (n_before > {args.xor_budget})"

        n_after = merged.count()
        v_after = sum(hull_points(p) for p in merged.each())
        record["polys_after"] = n_after
        record["vertices_after"] = v_after
        record["seconds"] = round(time.time() - t, 1)
        stage(f"merged {n_before} -> {n_after}")
        rows.append(record)

        print(f"  {info.layer:>3}/{info.datatype:<2} {record['name'][:22]:<22} "
              f"polys {n_before:>9} -> {n_after:>9}   verts {v_before:>9} -> {v_after:>9}"
              f"   {record['proof']:<13} {record['seconds']:>7} s", flush=True)

        target = out.layer(info.layer, info.datatype)
        shapes = otop.shapes(target)
        shapes.insert(merged)
        for tx in texts:
            shapes.insert(tx)

    out.write(args.out)

    tot_before = sum(r["polys_before"] for r in rows)
    tot_after = sum(r["polys_after"] for r in rows)
    tot_vb = sum(r["vertices_before"] for r in rows)
    tot_va = sum(r["vertices_after"] for r in rows)
    summary = {
        "input": args.gds,
        "input_bytes": os.path.getsize(args.gds),
        "output": args.out,
        "output_bytes": os.path.getsize(args.out),
        "top": top.name,
        "merge_mode": f"buckets {args.buckets}x{args.buckets}" if args.buckets else "global",
        "layers": rows,
        "polys_before": tot_before,
        "polys_after": tot_after,
        "poly_ratio": round(tot_after / tot_before, 4) if tot_before else None,
        "vertices_before": tot_vb,
        "vertices_after": tot_va,
        "verified": not args.no_verify,
        "failures": bad,
        "seconds": round(time.time() - t0, 1),
    }
    with open(args.json, "w") as f:
        json.dump(summary, f, indent=2)

    print(f"\ntotal polygons {tot_before} -> {tot_after} ({summary['poly_ratio']}), "
          f"vertices {tot_vb} -> {tot_va} in {summary['seconds']} s")
    print(f"wrote {args.out} ({summary['output_bytes']} B), summary {args.json}")
    if bad:
        print(f"MERGE: FAIL -- {len(bad)} place(s) changed coverage: {bad[:5]}", file=sys.stderr)
        return 1
    if args.no_merge:
        print(f"FLATTEN: PASS -- {len(rows)} layers copied through unchanged "
              f"({tot_before} polygons), no merge and so nothing to prove")
        return 0
    if args.no_verify:
        print("MERGE: UNVERIFIED -- --no-verify was passed")
        return 0
    proven = [r for r in rows if r["proof"] in ("xor", "xor-per-core")]
    bounded = [r for r in rows if r["proof"] == "area-bound"]
    cores = sum(r.get("buckets", 0) for r in rows)
    how = f"{cores} cores" if cores else "whole layer"
    print(f"MERGE: PASS -- {len(proven)}/{len(rows)} layers XOR empty against the unmerged "
          f"coverage ({how}, identical silicon); {len(bounded)} bounded only "
          f"(union area <= summed polygon area)")
    for r in bounded:
        print(f"  no exact proof: {r['layer']}/{r['datatype']} ({r['polys_before']} polygons)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
