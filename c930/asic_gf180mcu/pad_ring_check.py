#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Verify c930/asic_gf180mcu/pad_ring.cfg against independently derived geometry.

Re-derives the ring layout from the slot numbers (die 3930x5120, seal 26,
pad depth 350, corner 355, pad pitch 75) and checks every SITE/FILL/CORNER
box in the file for: correct band coordinates, contiguity along each edge,
pairwise non-overlap, pad/signal/power counts vs the 56-pad budget, and
CORE_AREA consistency with the published 12.92 mm2 core.

Exit 0 = all checks pass. Any failure prints FAIL lines and exits 1.
"""
import re
import sys
from pathlib import Path

# ---- Slot constants (wafer.space Run 3 1x1, area review doc) ----
DIE_W, DIE_H = 3930, 5120
SEAL = 26
PAD_W, PAD_D = 75, 350
COR = 355
CORE_INSET = 441          # 26 seal + 415 ring
BAND0, BAND1 = SEAL, SEAL + PAD_D      # 26..376
CORE_AREA = (441, 441, 3489, 4679)
BOND_BUDGET = 56
RTL_SIGNALS = {
    "i_clk", "i_rst_n", "i_ext_irq", "i_uart_rxd",
    "o_gpio[0]", "o_gpio[1]", "o_gpio[2]", "o_gpio[3]", "o_uart_txd",
}

CFG = Path(__file__).resolve().parent / "pad_ring.cfg"

fails = []


def fail(msg):
    fails.append(msg)


def box_ok(x0, x1, y0, y1, what):
    if not (0 <= x0 < x1 <= DIE_W and 0 <= y0 < y1 <= DIE_H):
        fail(f"{what}: box {x0},{y0}..{x1},{y1} outside die")
        return False
    if x0 < SEAL or y0 < SEAL or x1 > DIE_W - SEAL or y1 > DIE_H - SEAL:
        fail(f"{what}: box intrudes into seal band or past die edge")
        return False
    return True


def overlap(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def main():
    if not CFG.exists():
        print(f"FAIL: {CFG} not found")
        return 1
    text = CFG.read_text()

    boxes = []          # (x0, y0, x1, y1, label)
    sites = []          # parsed SITE rows
    fill_rows = []      # (label, x0, x1, y0, y1, tail)

    site_re = re.compile(
        r"^SITE\s+(\S+)\s+x\s+(\d+)\.\.(\d+)\s+y\s+(\d+)\.\.(\d+)\s+"
        r"(\S+)\s+(\S+)\s+(PWR|IN|OUT)\s*$")
    fill_re = re.compile(r"^FILL\s+(\S+)\s+x\s+(\d+)\.\.(\d+)\s+y\s+(\d+)\.\.(\d+)\s+(.+)$")
    cor_re = re.compile(
        r"^CORNER\s+(\S+)\s+x\s+(\d+)\.\.(\d+)\s+y\s+(\d+)\.\.(\d+)\s+"
        r"gf180mcu_fd_io__cor\s+(R\d+)\s*$")

    for line in text.splitlines():
        m = site_re.match(line)
        if m:
            sid, x0, x1, y0, y1, cell, net, dirn = m.groups()
            x0, x1, y0, y1 = int(x0), int(x1), int(y0), int(y1)
            sites.append((sid, x0, x1, y0, y1, cell, net, dirn))
            boxes.append((x0, y0, x1, y1, f"SITE {sid}"))
            if not box_ok(x0, x1, y0, y1, f"SITE {sid}"):
                continue
            # band + cell-type checks
            if sid[0] in "SN":
                if (y0, y1) not in {(BAND0, BAND1), (5120 - BAND1, 5120 - BAND0)}:
                    fail(f"SITE {sid}: row band y {y0}..{y1} != {BAND0}..{BAND1} or {5120-BAND1}..{5120-BAND0}")
                if x1 - x0 != PAD_W:
                    fail(f"SITE {sid}: width {x1-x0} != {PAD_W}")
            else:
                if (x0, x1) not in {(BAND0, BAND1), (3930 - BAND1, 3930 - BAND0)}:
                    fail(f"SITE {sid}: column band x {x0}..{x1} invalid")
                if y1 - y0 != PAD_W:
                    fail(f"SITE {sid}: height {y1-y0} != {PAD_W}")
            if dirn == "PWR" and cell not in ("gf180mcu_fd_io__dvdd", "gf180mcu_fd_io__dvss"):
                fail(f"SITE {sid}: PWR with cell {cell}")
            if dirn in ("IN", "OUT") and cell != "gf180mcu_fd_io__bi_t":
                fail(f"SITE {sid}: signal with cell {cell}")
            continue
        m = fill_re.match(line)
        if m:
            lab, x0, x1, y0, y1, tail = m.groups()
            x0, x1, y0, y1 = int(x0), int(x1), int(y0), int(y1)
            fill_rows.append((lab, x0, x1, y0, y1, tail))
            boxes.append((x0, y0, x1, y1, f"FILL {lab}"))
            if not box_ok(x0, x1, y0, y1, f"FILL {lab}"):
                continue
            w, h = x1 - x0, y1 - y0
            ms = re.match(r"(\d+) sites, each 7\*fill10 \+ fill5$", tail.strip())
            if ms:
                n = int(ms.group(1))
                row = (y0, y1) in {(BAND0, BAND1), (5120 - BAND1, 5120 - BAND0)}
                if row:
                    if w % PAD_W or n * PAD_W != w:
                        fail(f"FILL {lab}: {n} sites x {PAD_W} != width {w}")
                    if h != PAD_D:
                        fail(f"FILL {lab}: band height {h} != {PAD_D}")
                else:
                    if h % PAD_W or n * PAD_W != h:
                        fail(f"FILL {lab}: {n} sites x {PAD_W} != height {h}")
                    if w != PAD_D:
                        fail(f"FILL {lab}: band width {w} != {PAD_D}")
                continue
            mt = re.match(r"((?:\d*\*?fill\d+)(?: \+ \d*\*?fill\d+)*) = (\d+)$", tail.strip())
            if mt:
                terms = mt.group(1)
                stated = int(mt.group(2))
                total = 0
                for t in terms.split(" + "):
                    mm = re.match(r"(?:(\d+)\*)?fill(\d+)$", t)
                    if not mm:
                        fail(f"FILL {lab}: unparsable term {t}")
                        continue
                    cnt = int(mm.group(1) or 1)
                    wid = int(mm.group(2))
                    total += cnt * wid
                if total != stated:
                    fail(f"FILL {lab}: fill sum {total} != stated {stated}")
                if not (stated == w or stated == h):
                    fail(f"FILL {lab}: fill sum {stated} matches neither width {w} nor height {h}")
                continue
            fail(f"FILL {lab}: unparsable tail {tail!r}")
            continue
        m = cor_re.match(line)
        if m:
            pos, x0, x1, y0, y1, rot = m.groups()
            x0, x1, y0, y1 = int(x0), int(x1), int(y0), int(y1)
            boxes.append((x0, y0, x1, y1, f"CORNER {pos}"))
            if (x1 - x0, y1 - y0) != (COR, COR):
                fail(f"CORNER {pos}: size {x1-x0}x{y1-y0} != {COR}x{COR}")
            exp = {
                "SW": (SEAL, SEAL + COR, SEAL, SEAL + COR),
                "SE": (DIE_W - SEAL - COR, DIE_W - SEAL, SEAL, SEAL + COR),
                "NE": (DIE_W - SEAL - COR, DIE_W - SEAL, DIE_H - SEAL - COR, DIE_H - SEAL),
                "NW": (SEAL, SEAL + COR, DIE_H - SEAL - COR, DIE_H - SEAL),
            }[pos]
            if (x0, x1, y0, y1) != exp:
                fail(f"CORNER {pos}: box {(x0,x1,y0,y1)} != expected {exp}")
            box_ok(x0, x1, y0, y1, f"CORNER {pos}")

    # ---- pairwise non-overlap ----
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            if overlap(boxes[i], boxes[j]):
                fail(f"overlap: {boxes[i][4]} vs {boxes[j][4]}")

    # ---- per-edge contiguity: sites+fills+trail chain from 381 to corner ----
    def chain(intervals, lo, hi, label):
        iv = sorted(intervals)
        pos = lo
        for a, b in iv:
            if a != pos:
                fail(f"{label}: gap/step at {a}, expected {pos}")
                break
            pos = b
        else:
            if pos != hi:
                fail(f"{label}: chain ends {pos}, expected {hi}")

    spans = {"S": [], "N": [], "W": [], "E": []}
    for lab, x0, x1, y0, y1, _ in fill_rows:
        if (y0, y1) == (BAND0, BAND1):
            spans["S"].append((x0, x1))
        elif (y0, y1) == (5120 - BAND1, 5120 - BAND0):
            spans["N"].append((x0, x1))
        elif (x0, x1) == (BAND0, BAND1):
            spans["W"].append((y0, y1))
        elif (x0, x1) == (3930 - BAND1, 3930 - BAND0):
            spans["E"].append((y0, y1))
        else:
            fail(f"FILL {lab}: not in a known band")
    for sid, x0, x1, y0, y1, *_ in sites:
        if sid[0] == "S":
            spans["S"].append((x0, x1))
        elif sid[0] == "N":
            spans["N"].append((x0, x1))
        elif sid[0] == "W":
            spans["W"].append((y0, y1))
        elif sid[0] == "E":
            spans["E"].append((y0, y1))

    CORNER_S, CORNER_E = SEAL + COR, DIE_W - SEAL - COR      # 381 .. 3549
    CORNER_S_V, CORNER_E_V = SEAL + COR, DIE_H - SEAL - COR  # 381 .. 4739
    chain(spans["S"], CORNER_S, CORNER_E, "south row")
    chain(spans["N"], CORNER_S, CORNER_E, "north row")
    chain(spans["W"], CORNER_S_V, CORNER_E_V, "west column")
    chain(spans["E"], CORNER_S_V, CORNER_E_V, "east column")

    # ---- counts ----
    n_dvdd = sum(1 for s in sites if s[5].endswith("__dvdd"))
    n_dvss = sum(1 for s in sites if s[5].endswith("__dvss"))
    n_bit = sum(1 for s in sites if s[5].endswith("__bi_t"))
    if (n_dvdd, n_dvss, n_bit) != (10, 10, 9):
        fail(f"counts dvdd/dvss/bi_t = {n_dvdd}/{n_dvss}/{n_bit}, expected 10/10/9")
    total = len(sites)
    if total != 29:
        fail(f"{total} pad sites, expected 29")
    if total > BOND_BUDGET:
        fail(f"{total} pads exceed {BOND_BUDGET} budget")
    sigs = {s[6] for s in sites if s[7] in ("IN", "OUT")}
    if sigs != RTL_SIGNALS:
        fail(f"signal set mismatch: {sigs ^ RTL_SIGNALS}")

    # ---- IN/OUT marks must match grx930_test_chip.sv port directions ----
    rtl = CFG.parent / "grx930_test_chip.sv"
    if not rtl.exists():
        fail("grx930_test_chip.sv not found for direction check")
    else:
        src = rtl.read_text()
        mh = re.search(r"module\s+grx930_test_chip\b.*?\);", src, re.S)
        if not mh:
            fail("top module header not found in grx930_test_chip.sv")
        else:
            rtl_dir = {}
            for m2 in re.finditer(
                    r"^\s*(input|output)\s+logic\s*(?:\[(\d+):(\d+)\])?\s*(\w+)",
                    mh.group(0), re.M):
                d, hi, lo, name = m2.groups()
                if hi is None:
                    rtl_dir[name] = d
                else:
                    for i in range(int(lo), int(hi) + 1):
                        rtl_dir[f"{name}[{i}]"] = d
            for sid, x0, x1, y0, y1, cell, net, dirn in sites:
                if dirn == "PWR":
                    continue
                if net not in rtl_dir:
                    fail(f"SITE {sid}: {net} not an RTL top port")
                else:
                    want = "OUT" if rtl_dir[net] == "output" else "IN"
                    if dirn != want:
                        fail(f"SITE {sid}: {net} marked {dirn}, RTL direction is "
                             f"{rtl_dir[net]}")
    # ---- full 75-um site capacity per edge (trails excluded) ----
    full = {"S": 0, "N": 0, "W": 0, "E": 0}
    for sid, *_ in sites:
        full[sid[0]] += 1
    for lab, x0, x1, y0, y1, tail in fill_rows:
        m2 = re.match(r"(\d+) sites,", tail)
        if not m2:
            continue
        if (y0, y1) == (BAND0, BAND1):
            full["S"] += int(m2.group(1))
        elif (y0, y1) == (5120 - BAND1, 5120 - BAND0):
            full["N"] += int(m2.group(1))
        elif (x0, x1) == (BAND0, BAND1):
            full["W"] += int(m2.group(1))
        elif (x0, x1) == (3930 - BAND1, 3930 - BAND0):
            full["E"] += int(m2.group(1))
        else:
            fail(f"FILL {lab}: not in a known band (site count)")
    if full != {"S": 42, "N": 42, "W": 58, "E": 58}:
        fail(f"full-site counts {full}, expected 42/42/58/58")

    # ---- CORE_AREA ----
    m = re.search(r'CORE_AREA\s*:\s*"(\d+) (\d+) (\d+) (\d+)"\s*->\s*(\d+) x (\d+) = ([\d.]+) mm2', text)
    if not m:
        fail("CORE_AREA line not found/unparsable")
    else:
        x0, y0, x1, y1 = map(int, m.group(1, 2, 3, 4))
        w, h, area = int(m.group(5)), int(m.group(6)), float(m.group(7))
        if (x0, y0, x1, y1) != CORE_AREA:
            fail(f"CORE_AREA {(x0,y0,x1,y1)} != {CORE_AREA}")
        if (x1 - x0, y1 - y0) != (w, h):
            fail("CORE_AREA dims mismatch")
        if abs(w * h / 1e6 - area) > 0.005 or abs(area - 12.92) > 0.01:
            fail(f"core area {area} mm2 not ~12.92")
        if x0 != CORE_INSET:
            fail(f"CORE inset {x0} != {CORE_INSET}")
        # core must not touch ring band interior (415 channel beyond pad band)
        if x0 < BAND1 + 50:
            fail(f"CORE inset {x0} leaves only {x0 - BAND1} um routing channel")

    # ---- required text presence ----
    for needle in ("3930 x 5120", "gf180mcu_fd_io__dvdd", "provide your own pad ring",
                   "56 pads default", "comp018green_esd_clamp"):
        if needle not in text:
            fail(f"expected text missing: {needle!r}")

    if fails:
        for f in fails:
            print("FAIL:", f)
        print(f"\n{len(fails)} failure(s)")
        return 1
    print(f"OK: {len(sites)} pad cells (10 dvdd, 10 dvss, 9 bi_t), "
          f"{len(fill_rows)} fill ranges, 4 corners, "
          f"core {CORE_AREA} = 12.92 mm2, budget {total}/{BOND_BUDGET} "
          f"({BOND_BUDGET - total} reserved)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
