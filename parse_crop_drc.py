#!/usr/bin/env python3
"""Compare two KLayout DRC reports, item by item, and report additions."""
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter

NUM = re.compile(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")


def items(path):
    root = ET.parse(path).getroot()
    out = []
    for item in root.findall("./items/item"):
        cat = (item.findtext("category") or "").strip().strip("'\"")
        vals = [v.text for v in item.findall("./values/value") if v.text]
        nums = [float(x) for v in vals for x in NUM.findall(v)]
        pts = list(zip(nums[0::2], nums[1::2]))
        if not pts:
            continue
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        out.append({
            "category": cat,
            "bbox": [min(xs), min(ys), max(xs), max(ys)],
            "value": " | ".join(vals),
        })
    return out


def key(item):
    return (item["category"], *(round(v, 3) for v in item["bbox"]))


def near(a, b, tol=0.25):
    if a["category"] != b["category"]:
        return False
    return all(abs(a["bbox"][i] - b["bbox"][i]) <= tol for i in range(4))


def main():
    before = items(sys.argv[1])
    after = items(sys.argv[2])
    bset = set(map(key, before))
    added = [a for a in after if key(a) not in bset and not any(near(a, b) for b in before)]
    removed = [b for b in before if key(b) not in set(map(key, after)) and not any(near(a, b) for a in after)]
    summary = {
        "before": len(before),
        "after": len(after),
        "added": len(added),
        "removed": len(removed),
        "before_categories": dict(sorted(Counter(x["category"] for x in before).items())),
        "after_categories": dict(sorted(Counter(x["category"] for x in after).items())),
        "added_categories": dict(sorted(Counter(x["category"] for x in added).items())),
        "removed_categories": dict(sorted(Counter(x["category"] for x in removed).items())),
        "added_items": added,
        "removed_items": removed,
    }
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
