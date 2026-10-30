#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# Build the client-facing PDF from the one-pager's HTML.
#
#   build/pdf/build.sh            -> c930/asic_gf180mcu/wafer_space_status_onepager.pdf
#
# The source is the HTML that sits beside the Markdown and the PDF it produces:
#
#   wafer_space_status_onepager.md      the text, for reading and review
#   wafer_space_status_onepager.html    the same text laid out -- THIS is rendered
#   wafer_space_status_onepager.pdf     the deliverable
#
# WHY NOT build/pdf/onepager.html
#
#   That file is the 24 October edition: four fixed A4 boxes with the footer baked
#   into each. It stopped being the source on 26 October, when the brief moved to a
#   flowing layout, and this script went on rendering it anyway -- so running the
#   documented command silently replaced a current PDF with the old edition's
#   numbers (measured 28 October: the quad-core paragraph regressed from
#   configuration B back to the 2x4 estimate). It stays on disk as the record of the
#   fixed-page layout and is never rendered.
#
# WHAT IS ASSERTED, AND WHY THESE ARE THE RIGHT CHECKS FOR A FLOWING LAYOUT
#
#   Chrome paginates flowing HTML, so nothing is clipped the way a fixed box clips a
#   paragraph that outgrows it. Three quieter failures remain, and each has a check:
#
#     * the brief grows a page and is no longer a four-page brief   -> page count
#     * an edit loses a section, or the render truncates           -> every <h2>
#     * a table or an unbreakable token runs past the @page margin -> text extents
#       (in a flowing layout that is invisible: it is drawn, just outside the 14 mm
#       side margin, and only shows up when someone prints it)
#
#   The page count is exact rather than a ceiling, and deliberately so: 4 is a
#   decision about the document, not an accident, so a change that makes it 5 has to
#   be made here on purpose. EXPECTED_PAGES can be overridden for a one-off check.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"            # c930/asic_gf180mcu
src="$root/wafer_space_status_onepager.html"
out="$root/wafer_space_status_onepager.pdf"
expected_pages="${EXPECTED_PAGES:-4}"

[ -f "$src" ] || { echo "missing source: $src" >&2; exit 1; }

chrome="${CHROME:-/c/Program Files/Google/Chrome/Application/chrome.exe}"
[ -x "$chrome" ] || { echo "chrome not found at $chrome (set CHROME=)" >&2; exit 1; }

"$chrome" --headless=new --disable-gpu --no-pdf-header-footer \
  --user-data-dir="$(mktemp -d)" \
  --print-to-pdf="$(cygpath -w "$out")" \
  "file://$(cygpath -m "$src")" 2>/dev/null

echo "wrote $out ($(stat -c %s "$out") bytes)"

python - "$out" "$src" "$expected_pages" <<'PY'
import html as htmllib
import re
import sys

import pymupdf

pdf_path, src_path, expected_pages = sys.argv[1], sys.argv[2], int(sys.argv[3])

A4_W, A4_H = 595.28, 841.89          # A4 in points
# The @page block in the source: `margin: 15mm 14mm 16mm 14mm`.
SIDE = 14 * 72 / 25.4
TOP, BOTTOM = 15 * 72 / 25.4, 16 * 72 / 25.4
TOL = 2.0                            # a sub-point overshoot is rounding, not overflow

doc = pymupdf.open(pdf_path)
assert doc.page_count == expected_pages, (
    f"expected {expected_pages} pages, got {doc.page_count}. If the brief is meant to grow, "
    f"raise EXPECTED_PAGES in build/pdf/build.sh on purpose; if it is not, the layout has "
    f"spilled and a section now starts on the wrong page."
)

# Every section in the source has to survive into the PDF. CSS uppercases the h2
# text, so compare case-insensitively, with whitespace collapsed.
src_text = open(src_path, encoding="utf8").read()
headings = [
    re.sub(r"\s+", " ", htmllib.unescape(re.sub(r"<[^>]+>", "", h))).strip()
    for h in re.findall(r"<h2[^>]*>(.*?)</h2>", src_text, re.S)
]
assert headings, f"no <h2> sections found in {src_path} -- is that the one-pager?"
page_text = [re.sub(r"\s+", " ", p.get_text()).strip() for p in doc]
whole = " ".join(page_text).lower()
missing = [h for h in headings if h.lower() not in whole]
assert not missing, f"sections missing from the PDF: {missing} -- the render lost text"

for i, (page, text) in enumerate(zip(doc, page_text), 1):
    w, h = page.rect.width, page.rect.height
    assert abs(w - A4_W) < 1 and abs(h - A4_H) < 1, (
        f"page {i} is {w:.1f} x {h:.1f} pt, not A4 -- the @page rule or the print flags changed"
    )
    assert len(text) > 200, (
        f"page {i} holds {len(text)} chars, so it is nearly empty: a spurious page break"
    )
    blocks = page.get_text("blocks")
    x0, x1 = min(b[0] for b in blocks), max(b[2] for b in blocks)
    y0, y1 = min(b[1] for b in blocks), max(b[3] for b in blocks)
    assert x0 >= SIDE - TOL and x1 <= w - SIDE + TOL, (
        f"page {i}: text spans x {x0:.1f}..{x1:.1f}, outside the 14 mm side margins "
        f"({SIDE:.1f}..{w - SIDE:.1f}) -- something is wider than its column"
    )
    assert y0 >= TOP - TOL and y1 <= h - BOTTOM + TOL, (
        f"page {i}: text spans y {y0:.1f}..{y1:.1f}, outside the 15/16 mm top and bottom "
        f"margins ({TOP:.1f}..{h - BOTTOM:.1f})"
    )
    print(f"  p{i}: {w:.0f} x {h:.0f} pt, {len(text)} chars, text inside the margins")

print(f"OK: {doc.page_count} A4 pages, all {len(headings)} sections present, "
      f"nothing drawn outside the margins")
PY
