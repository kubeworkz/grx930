"""Item-level compare of two lyrdb reports: added and removed findings by rule."""
import collections
import sys
import xml.etree.ElementTree as ET


def load(path):
    c = collections.Counter()
    for item in ET.parse(path).getroot().iter("item"):
        cat = (item.findtext("category") or "?").replace("'", "")
        vals = tuple((v.text or "").strip() for v in item.iter("value"))
        c[(cat, vals)] += 1
    return c


def main(a_path, b_path):
    a, b = load(a_path), load(b_path)
    print(f"before {a_path}: {sum(a.values())} items")
    print(f"after  {b_path}: {sum(b.values())} items")
    print(f"delta {sum(b.values()) - sum(a.values()):+d}")

    cats = sorted({k[0] for k in set(a) | set(b)})
    print(f"\n{'rule':10s} {'before':>7s} {'after':>7s} {'added':>7s} {'removed':>7s}")
    added = collections.Counter()
    removed = collections.Counter()
    for cat in cats:
        ca = sum(v for k, v in a.items() if k[0] == cat)
        cb = sum(v for k, v in b.items() if k[0] == cat)
        if ca == cb:
            continue
        add = b - a
        rem = a - b
        nadd = sum(v for k, v in add.items() if k[0] == cat)
        nrem = sum(v for k, v in rem.items() if k[0] == cat)
        added[cat] = nadd
        removed[cat] = nrem
        print(f"{cat:10s} {ca:7d} {cb:7d} {nadd:7d} {nrem:7d}")

    if not added and not removed:
        print("\n(item sets identical)")
    new = [k for k, n in (b - a).items() for _ in range(n)]
    gone = [k for k, n in (a - b).items() for _ in range(n)]
    print(f"\nadded {len(new)}  removed {len(gone)}")
    for cat, vals in new[:8]:
        print(f"  NEW {cat} {vals[0][:100] if vals else ''}")
    for cat, vals in gone[:8]:
        print(f"  GONE {cat} {vals[0][:100] if vals else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
