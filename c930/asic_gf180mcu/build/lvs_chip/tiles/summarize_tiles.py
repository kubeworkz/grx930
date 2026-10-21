#!/usr/bin/env python3
"""summarize_tiles.py -- one table of every netlist arm, tile and die, from the artifacts.

Reads `build/lvs_chip/net_arms/<label>/arm.json` (written by `net_arm.sh`) plus each arm's
`klayout.log`, and prints/writes the numbers the write-up quotes: the objects the netter was given
(summed over the deck's own `metal*_drawn`, `contact`, `via*` counts), the deck's read+extract phase,
and the netlist phase, both taken from the probe's timestamps rather than from the poll loop.

  python3 build/lvs_chip/tiles/summarize_tiles.py --json build/lvs_chip/tiles/arms_summary.json
"""
import argparse
import json
import os
import re

ARMS = [
    ("1000 merged", "tile1k_merged"),
    ("1000 merged (rerun)", "tile1k_merged_r2"),
    ("1000 flat", "tile1k_flat"),
    ("1000 flat (rerun)", "tile1k_flat_r2"),
    ("strip320x5120 merged", "strip320_merged"),
    ("strip320x5120 (rerun)", "strip320_merged_r2"),
    ("strip3930x650 merged", "strip650h_merged"),
    ("strip3930x650 (rerun)", "strip650h_merged_r2"),
    ("strip3930x790 merged", "strip790h_merged"),
    ("strip3930x790 (rerun)", "strip790h_merged_r2"),
    ("square1131 merged", "sq1131_merged"),
    ("square1131 (rerun)", "sq1131_merged_r2"),
    ("1500 merged", "tile15_merged"),
    ("1500 merged (rerun)", "tile15_merged_r2"),
    ("1500 flat", "tile15_flat"),
    ("1500 flat (rerun)", "tile15_flat_r2"),
    ("die merged", "merged"),
    ("die flat", "flat_control"),
]
NETTER_LAYERS = ["metal1_drawn", "metal2_drawn", "metal3_drawn", "metal4_drawn", "metal5_drawn",
                 "contact", "via1", "via2", "via3", "via4"]


def derived(path):
    got = {}
    if not os.path.exists(path):
        return got
    for line in open(path, errors="replace"):
        m = re.search(r": (\w+) has (\d+) polygons", line)
        if m and m.group(1) in NETTER_LAYERS and m.group(1) not in got:
            got[m.group(1)] = int(m.group(2))
    got["total"] = sum(v for k, v in got.items() if k != "total")
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="c930/asic_gf180mcu/build/lvs_chip")
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    rows = []
    for label, arm in ARMS:
        d = os.path.join(args.root, "net_arms", arm)
        aj = os.path.join(d, "arm.json")
        if not os.path.exists(aj):
            continue
        a = json.load(open(aj))
        pol = derived(os.path.join(d, "klayout.log"))
        rows.append({
            "arm": arm,
            "label": label,
            "input": a.get("input"),
            "input_bytes": a.get("input_bytes"),
            "netter_objects": pol.get("total"),
            "read_extract_seconds": a.get("read_extract_seconds"),
            "netlist_seconds": a.get("netlist_seconds"),
            "verdict": a.get("verdict"),
            "stopped_by": a.get("stopped_by"),
            "netlist_bytes": a.get("netlist_bytes"),
            "netlist_sink": a.get("netlist_sink"),
            "per_layer": {k: v for k, v in pol.items() if k != "total"},
        })

    print(f"{'arm':22s} {'objects':>11} {'read+extract':>13} {'netlist':>9}  verdict")
    for r in rows:
        def num(v, unit=""):
            return f"{v:,}{unit}" if isinstance(v, (int, float)) else "-"
        print(f"{r['label']:22s} {num(r['netter_objects']):>11} "
              f"{num(r['read_extract_seconds'], 's'):>13} "
              f"{num(r['netlist_seconds'], 's'):>9}  {r['verdict']}")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(rows, fh, indent=2)
        print(f"wrote {args.json}")


if __name__ == "__main__":
    main()
