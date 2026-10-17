#!/usr/bin/env python3
"""drc_tally_rank.py -- rank the precheck's KLayout DRC tally, and say what each rule means.

WHY THIS EXISTS
  The precheck reports one number (83,777 on the run2 artifact) plus a per-rule tally
  (klayout_drc.klayout.json). The number is useless as a work list: 85.4 % of it is the
  advisory *_OFFGRID family, and the remainder is spread over 70 rules of which a handful
  carry most of the weight. This turns the tally into a ranked list, groups it, and attaches
  each rule's OWN description string from the PDK deck that produced it -- so a rule name is
  never interpreted from memory.

WHAT IT DOES NOT DO
  It does not run DRC and it does not attribute a violation to a cell. The tally is counts
  only, with no coordinates, so anything below a rule's own text is inference. The per-item
  .lyrdb the precheck writes (26 MB, one item per violation) is what settles that.

USAGE
  python3 tools/drc_tally_rank.py [TALLY.json] [--deck DIR] [--top N]

EXIT STATUS
  0  printed a ranking
  2  the tally was missing, unreadable, or internally inconsistent (rules != total)
"""

import argparse
import json
import os
import re
import sys

# The family wafer.space rules advisory: a critical warning, not a hard blocker.
ADVISORY_SUFFIXES = ("_OFFGRID",)

# Families by leading token. Longest match wins, so order the longer prefixes first.
FAMILIES = [
    ("O.CO.", "Contact, other/optional variant"),
    ("M1.", "Metal1"),
    ("M2.", "Metal2"),
    ("M3.", "Metal3"),
    ("M4.", "Metal4"),
    ("M5.", "Metal5"),
    ("CO.", "Contact (size, spacing, enclosure, forbidden placement)"),
    ("NP.", "N+ implant (nplus)"),
    ("PP.", "P+ implant (pplus)"),
    ("DF.", "COMP butt/diffusion (NCOMP vs PCOMP, channel dimensions)"),
    ("NW.", "Nwell"),
    ("LPW.", "LVPWELL"),
    ("PL.", "Poly2"),
    ("DV.", "Dualgate"),
    ("GR.", "Guard ring"),
    ("S.", "SRAM-specific"),
    ("Y.", "YMTP-specific"),
    ("DN.", "Deep nwell in a cell"),
    ("MIM", "MIM capacitor"),
    ("MT.", "MetalTop"),
    ("MSLOT", "Metal slotting"),
    ("PRES.", "Precision resistor"),
    ("VA", "Via array"),
    ("V1.", "Via1"),
    ("V2.", "Via2"),
    ("V3.", "Via3"),
    ("V4.", "Via4"),
    ("DCF.", "Density"),
    ("PL.8", "Poly2 density"),
]

# Gate classes, decided by the deck's own wording (see classify()).
CLASS_ORDER = [
    "structural",
    "enclosure",
    "spacing",
    "size",
    "dimension",
    "other",
]


def default_tally():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(
        here, "..", "..", "..", "Claude outputs", "evidence_run2",
        "klayout_drc.klayout.json"))


def default_deck():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(
        here, "..", "libs.tech", "klayout", "tech", "drc", "rule_decks"))


def family_of(rule):
    for prefix, label in FAMILIES:
        if rule.startswith(prefix):
            return label
    return "(other)"


def classify(desc):
    """Sort a rule by what kind of check it is, using the deck's own wording.

    This matters because the classes have different fixes: a `forbidden` construct is a
    layout that must not exist, while a `min spacing` miss can be a rounding margin.
    """
    d = (desc or "").lower()
    if not d:
        return "other"
    if "forbidden" in d or "cannot" in d or "not allowed" in d or "should not" in d:
        return "structural"
    if "extension beyond" in d or "overlap" in d or "enclosure" in d or "extend" in d:
        return "enclosure"
    if "space" in d or "spacing" in d or "separation" in d:
        return "spacing"
    if "width" in d and "channel" not in d:
        return "size"
    if "channel" in d or "length" in d:
        return "dimension"
    if "min" in d or "max" in d or "size" in d:
        return "size"
    return "other"


# The deck's rule text carries unit and bound glyphs (Âµm, ÂµmÂ², â‰¥). Transliterate for the
# console: a Windows cp1252 pipe turns them into replacement characters otherwise.
_ASCII = {"\u00b5": "u", "\u03bc": "u", "\u00b2": "2", "\u00d7": "x", "\u00b0": "deg",
          "\u2013": "-", "\u2014": "-", "\u2265": ">=", "\u2264": "<=", "\u2260": "!=",
          "\u00b1": "+/-"}


def _ascii(s):
    return "".join(_ASCII.get(ch, ch) for ch in s)


def _quoted(src, i):
    """Return (text, next_index) for the string literal that starts at src[i]."""
    quote = src[i]
    i += 1
    out = []
    while i < len(src):
        ch = src[i]
        if ch == chr(92) and i + 1 < len(src):
            out.append(src[i + 1])
            i += 2
            continue
        if ch == quote:
            return "".join(out), i + 1
        out.append(ch)
        i += 1
    return "".join(out), i


def extract_outputs(src):
    """[(name, description)] for every .output(name, desc) call in a rule deck."""
    found = []
    for m in re.finditer(r"\.output\(\s*", src):
        i = m.end()
        if i >= len(src) or src[i] not in "'\"":
            continue
        name, i = _quoted(src, i)
        while i < len(src) and src[i] in " \t\r\n":
            i += 1
        if i >= len(src) or src[i] != ",":
            continue
        i += 1
        while i < len(src) and src[i] in " \t\r\n":
            i += 1
        if i >= len(src) or src[i] not in "'\"":
            continue
        desc, i = _quoted(src, i)
        found.append((name, desc))
    return found


def load_deck(deck_dir):
    """rule name -> description, straight from the deck's own output() strings.

    The metal and via decks interpolate the layer index (`M#{idx}.2a`), so those rules are
    expanded for every layer they cover and the index is baked into the text.
    """
    names = {}
    if not os.path.isdir(deck_dir):
        return names
    for fn in sorted(os.listdir(deck_dir)):
        if not fn.endswith(".rb"):
            continue
        try:
            with open(os.path.join(deck_dir, fn), encoding="utf-8", errors="replace") as fh:
                src = fh.read()
        except OSError:
            continue
        for name, desc in extract_outputs(src):
            desc = re.sub(r"\s+", " ", desc).strip()
            layers = [None] if "#{idx}" not in name else list(range(1, 7))
            for idx in layers:
                concrete = name if idx is None else name.replace("#{idx}", str(idx))
                if "#{" in concrete:
                    continue
                text = desc if idx is None else desc.replace("#{idx}", str(idx))
                text = re.sub(r"#\{(\w+)\}", r"<\1>", text)
                names.setdefault(concrete, text)
    return names


def load_tally(path):
    if not os.path.isfile(path):
        sys.stderr.write("tally not found: %s\n" % path)
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as exc:
        sys.stderr.write("cannot read tally %s: %s\n" % (path, exc))
        return None
    return raw


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tally", nargs="?", default=default_tally())
    ap.add_argument("--deck", default=default_deck())
    ap.add_argument("--top", type=int, default=0, help="only the first N rules")
    args = ap.parse_args()

    raw = load_tally(args.tally)
    if raw is None:
        return 2

    total = raw.pop("total", None)
    if total is None:
        sys.stderr.write("tally has no 'total' key; refusing to rank a partial report\n")
        return 2
    if sum(raw.values()) != total:
        sys.stderr.write("tally inconsistent: rules sum to %d, total says %d\n"
                         % (sum(raw.values()), total))
        return 2

    advisory = {k: v for k, v in raw.items() if k.endswith(ADVISORY_SUFFIXES)}
    blocking = {k: v for k, v in raw.items() if not k.endswith(ADVISORY_SUFFIXES)}
    nz = {k: v for k, v in blocking.items() if v}
    blk_total = sum(nz.values())
    desc = load_deck(args.deck)

    print("tally          %s" % args.tally)
    print("deck           %s%s" % (args.deck, "" if desc else "  (not found; no descriptions)"))
    print("rules          %d reported, %d with a non-zero count" % (len(raw), len(nz)))
    # Coverage is what makes the meanings trustworthy: every rule this report leans on
    # has to resolve, or the description belongs to a different deck build than the run.
    unresolved = sorted(r for r in nz if r not in desc)
    print("deck coverage  %d of %d reporting rules, and %d of %d with a non-zero count%s"
          % (sum(1 for r in raw if r in desc), len(raw), len(nz) - len(unresolved), len(nz),
             "" if not unresolved else "  <-- unresolved: " + ", ".join(unresolved[:8])))
    print("total          %d" % total)
    print("  advisory     %d (%.1f%%) on %s"
          % (sum(advisory.values()), 100.0 * sum(advisory.values()) / total,
             ", ".join(ADVISORY_SUFFIXES).strip("_")))
    print("  blocking     %d (%.1f%%)" % (blk_total, 100.0 * blk_total / total))
    print()

    ranked = sorted(nz.items(), key=lambda kv: (-kv[1], kv[0]))
    if args.top:
        ranked = ranked[:args.top]

    print("%-3s %-12s %6s %6s %7s %-30s %s"
          % ("#", "rule", "count", "share", "cum", "class", "meaning (from the deck)"))
    cum = 0
    for i, (rule, count) in enumerate(ranked, 1):
        cum += count
        text = _ascii(desc.get(rule, ""))
        print("%-3d %-12s %6d %5.1f%% %6.1f%% %-30s %s"
              % (i, rule, count, 100.0 * count / blk_total, 100.0 * cum / blk_total,
                 classify(text), text[:96]))
    print()

    print("cumulative: top %s" % ", ".join(
        "%-2d = %d (%.1f%%)" % (n, sum(c for _, c in ranked[:n]),
                                100.0 * sum(c for _, c in ranked[:n]) / blk_total)
        for n in (1, 5, 10, 20, 35) if n <= len(ranked)))
    print()

    fam = {}
    cls = {}
    for rule, count in nz.items():
        e = fam.setdefault(family_of(rule), [0, 0])
        e[0] += 1
        e[1] += count
        k = classify(desc.get(rule, ""))
        c = cls.setdefault(k, [0, 0])
        c[0] += 1
        c[1] += count

    print("%-58s %5s %6s %7s" % ("family", "rules", "count", "share"))
    for label, (n, c) in sorted(fam.items(), key=lambda kv: -kv[1][1]):
        print("%-58s %5d %6d %6.1f%%" % (label, n, c, 100.0 * c / blk_total))
    print("%-58s %5d %6d" % ("TOTAL", len(nz), blk_total))
    print()

    print("%-58s %5s %6s %7s" % ("gate class (by the deck's own wording)",
                                 "rules", "count", "share"))
    for label in CLASS_ORDER:
        if label in cls:
            n, c = cls[label]
            print("%-58s %5d %6d %6.1f%%" % (label, n, c, 100.0 * c / blk_total))
    print()

    mv = sum(c for r, c in nz.items() if r.endswith("_MV"))
    lv = sum(c for r, c in nz.items() if r.endswith("_LV"))
    plain = blk_total - mv - lv
    print("device flavour: _MV (5V/6V) %d (%.1f%%), _LV (3.3V) %d (%.1f%%), unscoped %d (%.1f%%)"
          % (mv, 100.0 * mv / blk_total, lv, 100.0 * lv / blk_total,
             plain, 100.0 * plain / blk_total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
