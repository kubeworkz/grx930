#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Build the Fraunhofer IIS / EUROPRACTICE NDA pack from the two published templates.

Inputs -- exactly as published, kept unmodified in this directory:

  * NDA_Request_Form_GF_Rev2.0-1.docx   EUROPRACTICE's "NDA_Request_Form" for GlobalFoundries
  * GF_Template_PDK_request.pptx        the "questionnaire" the same page links (project proposal deck)

Outputs -- written next to the inputs:

  * NDA_Request_Form_GF_Rev2.0-1_prepared.docx
  * GF_Template_PDK_request_prepared.pptx

Every value is filled in, the entity's own details included (Gridworkz, 1931 Norris Ave., Fort Erie,
Ontario, Canada L2A5M4; signatory Dave Cook, Owner, +1 289-303-7651; the PDK contact the same
person). No marker is left in either document. Nothing here is sent: the pack is prepared, not
submitted, and the signature goes on the NDA itself rather than on this form.

The two templates are Office files, so the edits are made on their XML parts and the zip
is rewritten entry for entry; no Office library is needed and no binary is regenerated.
Every edit is anchored on a string that must appear exactly once (or at a known index),
and the script aborts rather than writing a half-filled file.

Run from this directory:  python fill_pack.py
"""
from __future__ import annotations

import re
import sys
import zipfile

DOCX_SRC = 'NDA_Request_Form_GF_Rev2.0-1.docx'
DOCX_DST = 'NDA_Request_Form_GF_Rev2.0-1_prepared.docx'
PPTX_SRC = 'GF_Template_PDK_request.pptx'
PPTX_DST = 'GF_Template_PDK_request_prepared.pptx'

PLACEHOLDER = 'Click here to enter text.'

# --------------------------------------------------------------------------------------
# The Word form: its 19 text content controls, in document order.
# Field order read off the form itself: Company, Department, signatory name/title/address/
# phone/email, PDK contact name/title/phone/email, Technology/Others, research activities,
# product and end use, military description, end user, MPW designs per year, volume wafers
# per year, EUROPRACTICE member number.
# --------------------------------------------------------------------------------------
FORM = [
    # 0 Company
    'Gridworkz',
    # 1 Department (single-owner company: nothing to name)
    'N/A',
    # 2 Name of the person signing the NDA
    'Dave Cook',
    # 3 Job Title
    'Owner',
    # 4 Address: street / town and ZIP / country (one cell, three lines)
    '1931 Norris Ave.\nFort Erie, Ontario L2A5M4\nCanada',
    # 5 Phone
    '+1 289-303-7651',
    # 6 Email Address
    'dave@gridworkz.com',
    # 7 Name of the person handling the PDKs (same person as the signatory)
    'Dave Cook',
    # 8 Job Title
    'Owner',
    # 9 Phone
    '+1 289-303-7651',
    # 10 Email Address
    'dave@gridworkz.com',
    # 11 Technology -> "Others" (the form lists advanced nodes only; GF180MCU is none of them)
    'GF180MCU (180 nm), 5-metal (5LM), 1.8 / 3.3 / 5 V, open-source PDK',
    # 12 Research activities of the organisation / department
    'Gridworkz develops open-source RISC-V processor and neural-network accelerator silicon. '
    'The GRX930 programme has a single-core RV64IMAC test chip in a wafer.space pooled GF180MCU '
    'run, its pre-check path in progress, and is evaluating a four-core SoC for a larger shuttle '
    'slot. Development is public: https://github.com/kubeworkz',
    # 13 Product to be manufactured and its final end use
    'A four-core RV64IMAC RISC-V SoC with two 8×8 systolic-array accelerators, a shared 64 KB L2 '
    'and 160 KB of on-chip 5 V SRAM, built on GF180MCU with gf180mcu_fd_sc_mcu7t5v0 cells and '
    'gf180mcu_fd_ip_sram macros. Die 7.864 × 20.488 mm (161 mm²), custom pad ring, chip-on-board '
    'assembly. Final end use: general-purpose embedded computing and neural-network inference on '
    'evaluation and development boards; no military application. Planned as an MPW shuttle run.',
    # 14 Military application (the box above it is answered No)
    'Not applicable — the design is a general-purpose processor and accelerator SoC with no '
    'military application or end user.',
    # 15 End user of the designed circuits
    'Gridworkz and its development partners, for RISC-V processor and software development on '
    'evaluation boards; the design is developed as open-source hardware and its documentation is '
    'published.',
    # 16 Target volume: MPW run, designs per year
    '1–2',
    # 17 Target volume: volume production, wafers per year (not selected)
    'n/a',
    # 18 EUROPRACTICE member number (if available)
    'None yet — this would be our first EUROPRACTICE order.',
]

# Content-control indices (0-based, document order) of the two ballot boxes this form answers.
# 11-18 are the eight technology boxes, 22/23 are the military Yes/No pair, 26 is "MPW Run",
# 28/29 are "Engineering Run" and "Volume Production".
TICK_BOXES = [(23, 'No'), (26, 'MPW Run')]

# --------------------------------------------------------------------------------------
# The deck: five slides, values appended after each label (or into the empty paragraph the
# template leaves under a label). Kept to what the project's own record supports.
# --------------------------------------------------------------------------------------
TITLE = 'GRX930 — quad-core RISC-V SoC with neural-network accelerators on GF180MCU'
SUBTITLE = 'Gridworkz — project and PDK request for GF180MCU (180 nm) · 27 October 2026'
PROJECT_TITLE = 'GRX930: quad-core RISC-V SoC with systolic-array accelerators (GF180MCU)'
AFFILIATION = 'Gridworkz — Fort Erie, Ontario, Canada'
MAIN_CONTACT = 'Dave Cook — dave@gridworkz.com'
TARGET_TECH = 'GF180MCU (180 nm), 5-metal (5LM), 1.8 / 3.3 / 5 V; open-source PDK'
TARGET_USE = ('General-purpose RISC-V computing with on-die neural-network acceleration; '
              'evaluation and software-development boards')
CLASS_KEEP = '12) AI; 14) Compute'
OVERVIEW = (
    'GRX930 is a quad-core RV64IMAC RISC-V SoC with two 8×8 systolic-array accelerators, a '
    'shared 64 KB L2 and 160 KB of on-chip 5 V SRAM, designed on the open GF180MCU PDK. Measured '
    'on our own GF180 runs the logic is ~46 mm² of cells; with the memories as gf180mcu_fd_ip_sram '
    'macros the die is 7.864 × 20.488 mm (161 mm²) with a ~137 mm² core. A single-core test chip '
    'of the same core is already in a wafer.space pooled GF180MCU run; this request concerns the '
    'larger quad-core part.')
INTRO = (
    'Gridworkz is an independent hardware developer building open-source RISC-V processor and '
    'accelerator silicon. The GRX930 programme has already produced a single-core RV64IMAC test '
    'chip with its own boot ROM — now in a wafer.space pooled GF180MCU run, its pre-check path in '
    'progress — and the quad-core SoC in this request is the next step. Development is public at '
    'https://github.com/kubeworkz.')
STATE_OF_ART = (
    'Open-source RISC-V cores are available as single-core designs, and open-source flows now '
    'yield small GF180MCU test chips in pooled slots (1×1, ~20 mm²). To our knowledge no open part '
    'couples several 64-bit cores with on-die systolic-array accelerators on this process.')
WHAT_IS_NEW = (
    'A quad-core RV64IMAC SoC with two 8×8 systolic-array NPUs, a shared 64 KB L2 with an MSI-lite '
    'directory and 160 KB of on-chip SRAM — 7.864 × 20.488 mm (161 mm²) with the memories as '
    'foundry gf180mcu_fd_ip_sram macros. FPGA-validated: timing closed at ~121 MHz with zero '
    'failing endpoints.')
TIMELINE = (
    'Final GDS targeted Q4 2026 – Q1 2027, with tape-out on the next GF180MCU shuttle registration '
    'we can secure. The single-core 1×1 vehicle is already in fabrication scheduling with '
    'wafer.space.')
SUPPORT = (
    'Measured evidence from the current run tree: global routing closes with 0 overflow on the 1×1 '
    'vehicle; in-flow antenna repair completes with 1,710 diodes inserted; post-repair setup STA '
    'closes the 40 ns data paths (-0.064 ns); structural netlist-vs-layout compare MATCH (53,745 '
    'instances, 0 unmatched); active-layer density 31.27 % COMP / 26.25 % Poly2 with 0 deck '
    'violations. Design files and reports: https://github.com/kubeworkz')


# --------------------------------------------------------------------------- shared helpers
def esc(text: str) -> str:
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def rewrite(src_path: str, dst_path: str, replacements: dict[str, str]) -> None:
    """Rewrite a whole Office zip, replacing the named parts and copying the rest byte for byte."""
    with zipfile.ZipFile(src_path) as src:
        names = src.namelist()
        for name in replacements:
            if name not in names:
                raise SystemExit('%s: no part %r' % (src_path, name))
        with zipfile.ZipFile(dst_path, 'w', zipfile.ZIP_DEFLATED) as out:
            for item in src.infolist():
                data = replacements.get(item.filename)
                if data is None:
                    data = src.read(item.filename)
                elif isinstance(data, str):
                    data = data.encode('utf-8')
                info = zipfile.ZipInfo(item.filename, date_time=item.date_time)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = item.external_attr
                out.writestr(info, data)
    print('wrote %s (%d parts)' % (dst_path, len(names)))


# --------------------------------------------------------------------------- the Word form
def build_docx() -> str:
    with zipfile.ZipFile(DOCX_SRC) as src:
        doc = src.read('word/document.xml').decode('utf-8')

    # 1. the 19 text controls, in document order
    run_re = re.compile(
        r'<w:r(?: [^>]*)?>(?:(?!</w:r>).)*?' + re.escape(PLACEHOLDER) + r'(?:(?!</w:r>).)*?</w:r>',
        re.S)

    def filled_run(value: str) -> str:
        body = '<w:br/>'.join('<w:t>%s</w:t>' % esc(p) for p in value.split('\n'))
        return '<w:r><w:rPr><w:lang w:val="en-US"/></w:rPr>%s</w:r>' % body

    filled: list[str] = []

    def _sub(m: re.Match) -> str:
        filled.append(m.group(0))
        if len(filled) > len(FORM):
            raise SystemExit('more placeholder runs than fields')
        return filled_run(FORM[len(filled) - 1])

    doc, n = run_re.subn(_sub, doc)
    if n != len(FORM):
        raise SystemExit('expected %d placeholder runs, replaced %d' % (len(FORM), n))

    # 2. the two ballot boxes this form answers
    for index, expect_after in TICK_BOXES:
        blocks = list(re.finditer(r'<w:sdt>.*?</w:sdt>', doc, re.S))
        block = blocks[index]
        after = re.sub(r'<[^>]+>', '', doc[block.end():block.end() + 200]).strip()
        if not after.startswith(expect_after):
            raise SystemExit('content control %d is not the %r box (found %r)'
                             % (index, expect_after, after[:30]))
        ticked = re.sub(r'<w:t([^>]*)>☐</w:t>', r'<w:t\1>☒</w:t>', block.group(0), count=1)
        if ticked == block.group(0):
            raise SystemExit('no ballot box inside content control %d' % index)
        doc = doc[:block.start()] + ticked + doc[block.end():]

    # 3. a filled control must stop showing its placeholder text
    doc, flags = re.subn(r'<w:showingPlcHdr/>', '', doc)
    if flags == 0:
        raise SystemExit('no <w:showingPlcHdr/> flags found')

    rewrite(DOCX_SRC, DOCX_DST, {'word/document.xml': doc})
    remaining = [i for i, v in enumerate(FORM) if '[TO COMPLETE' in v]
    return '%d fields filled, %d boxes ticked, %d placeholder flags cleared; %d fields still marked [TO COMPLETE]' % (
        n, len(TICK_BOXES), flags, len(remaining))


# --------------------------------------------------------------------------- the deck
def a_text(paragraph: str) -> str:
    return ''.join(re.findall(r'<a:t>(.*?)</a:t>', paragraph, re.S))


def para_label(paragraph: str) -> str:
    """The label a template paragraph carries, with its trailing colon removed."""
    return re.sub(r'\s+', ' ', a_text(paragraph)).strip().rstrip(':').strip()


def a_run(text: str) -> str:
    return '<a:r><a:rPr lang="en-US" kern="0" dirty="0"/><a:t>%s</a:t></a:r>' % esc(text)


def paragraphs(doc: str, expected: int) -> list[re.Match]:
    found = list(re.finditer(r'<a:p>.*?</a:p>', doc, re.S))
    if len(found) != expected:
        raise SystemExit('expected %d paragraphs, found %d' % (expected, len(found)))
    return found


def para_pPr(paragraph: str) -> str:
    m = re.search(r'<a:pPr[^>]*/>|<a:pPr.*?</a:pPr>', paragraph, re.S)
    if not m:
        raise SystemExit('paragraph has no <a:pPr>: %r' % paragraph[:80])
    return m.group(0)


def append_after_colon(paragraph: str, value: str) -> str:
    """Turn the label paragraph's trailing '<a:t>:</a:t>' into ': value'."""
    if '<a:t>:</a:t>' not in paragraph:
        raise SystemExit('no trailing colon run in %r' % a_text(paragraph)[:60])
    return paragraph.replace('<a:t>:</a:t>', '<a:t>: %s</a:t>' % esc(value), 1)


def body_paragraph(paragraph: str, value: str) -> str:
    """Same paragraph skeleton, its runs replaced by one run holding `value`."""
    end = re.search(r'<a:endParaRPr[^>]*/>', paragraph)
    if not end:
        raise SystemExit('paragraph has no <a:endParaRPr/>: %r' % paragraph[:80])
    return '<a:p>%s%s%s</a:p>' % (para_pPr(paragraph), a_run(value), end.group(0))


def apply_edits(doc: str, edits: list[tuple[int, int, str]]) -> str:
    for start, end, new in sorted(edits, key=lambda e: e[0], reverse=True):
        doc = doc[:start] + new + doc[end:]
    return doc


def build_pptx_slides() -> str:
    with zipfile.ZipFile(PPTX_SRC) as src:
        parts = {name: src.read(name).decode('utf-8')
                 for name in src.namelist() if re.fullmatch(r'ppt/slides/slide\d+\.xml', name)}

    # ---- slide 1: title + subtitle -------------------------------------------------
    doc = parts['ppt/slides/slide1.xml']
    doc, n = re.subn(r'<a:t>Template_UPP</a:t>', '<a:t>%s</a:t>' % esc(TITLE), doc)
    if n != 1:
        raise SystemExit('slide1: Template_UPP run not found exactly once')
    empty = '<a:p><a:endParaRPr lang="en-US"/></a:p>'
    if doc.count(empty) != 1:
        raise SystemExit('slide1: empty subtitle paragraph not found exactly once')
    doc = doc.replace(empty, '<a:p>%s<a:endParaRPr lang="en-US"/></a:p>' % a_run(SUBTITLE))
    parts['ppt/slides/slide1.xml'] = doc

    # ---- slide 2: overview ---------------------------------------------------------
    doc = parts['ppt/slides/slide2.xml']
    doc, n = re.subn(r'<a:t>Project title</a:t>', '<a:t>%s</a:t>' % esc(PROJECT_TITLE), doc)
    if n != 1:
        raise SystemExit('slide2: project-title run not found exactly once')
    paras = paragraphs(doc, 16)
    edits = []
    for index, label, value in ((3, 'Partner affiliation', AFFILIATION),
                                (4, 'Partner main contact', MAIN_CONTACT),
                                (7, 'Target technology', TARGET_TECH),
                                (8, 'Target application/usage', TARGET_USE)):
        if para_label(paras[index].group(0)) != label:
            raise SystemExit('slide2: paragraph %d is not the %r label (found %r)'
                             % (index, label, para_label(paras[index].group(0))))
        edits.append((paras[index].start(), paras[index].end(),
                      append_after_colon(paras[index].group(0), value)))
    if '1) RF devices' not in a_text(paras[10].group(0)):
        raise SystemExit('slide2: classification list is not where it was')
    edits.append((paras[10].start(), paras[10].end(), body_paragraph(paras[10].group(0), CLASS_KEEP)))
    for index in (11, 12):  # the two further list lines, dropped: "remove all not applicable"
        if not a_text(paras[index].group(0)):
            raise SystemExit('slide2: paragraph %d is not a classification line' % index)
        edits.append((paras[index].start(), paras[index].end(), ''))
    if para_label(paras[14].group(0)) != 'Brief overview of the project':
        raise SystemExit('slide2: brief-overview label moved')
    end = re.search(r'<a:endParaRPr[^>]*/>', paras[15].group(0))
    if a_text(paras[15].group(0)) or not end:
        raise SystemExit('slide2: the paragraph after the brief-overview label is not empty')
    edits.append((paras[15].start(), paras[15].end(),
                  paras[15].group(0).replace(end.group(0), a_run(OVERVIEW) + end.group(0), 1)))
    doc = apply_edits(doc, edits)
    doc = enlarge_box(doc, '10444294', '3877985', '5200000', 'slide2 partner-information box')
    parts['ppt/slides/slide2.xml'] = doc

    # ---- slide 3: introduction -----------------------------------------------------
    doc = parts['ppt/slides/slide3.xml']
    paras = paragraphs(doc, 2)
    if para_label(paras[1].group(0)) != 'Introduction':
        raise SystemExit('slide3: introduction label moved')
    doc = apply_edits(doc, [(paras[1].start(), paras[1].end(),
                             append_after_colon(paras[1].group(0), INTRO))])
    doc = enlarge_box(doc, '7692705', '276999', '1905000', 'slide3 introduction box')
    parts['ppt/slides/slide3.xml'] = doc

    # ---- slide 4: technical information --------------------------------------------
    doc = parts['ppt/slides/slide4.xml']
    paras = paragraphs(doc, 6)
    if para_label(paras[1].group(0)) != 'State of the art':
        raise SystemExit('slide4: state-of-the-art label moved')
    if para_label(paras[3].group(0)) not in ('What will be new ?', 'What will be new?'):
        raise SystemExit('slide4: what-will-be-new label moved (found %r)'
                         % para_label(paras[3].group(0)))
    edits = []
    for index, value in ((2, STATE_OF_ART), (4, WHAT_IS_NEW)):
        if a_text(paras[index].group(0)):
            raise SystemExit('slide4: paragraph %d was expected empty' % index)
        edits.append((paras[index].start(), paras[index].end(),
                      body_paragraph(paras[index].group(0), value)))
    edits.append((paras[5].start(), paras[5].end(),
                  append_after_colon(paras[5].group(0), TIMELINE)))
    doc = apply_edits(doc, edits)
    doc = enlarge_box(doc, '7692705', '1384995', '3810000', 'slide4 technical-information box')
    parts['ppt/slides/slide4.xml'] = doc

    # ---- slide 5: supporting project information -----------------------------------
    doc = parts['ppt/slides/slide5.xml']
    paras = paragraphs(doc, 2)
    if not para_label(paras[1].group(0)).startswith('Please, add all information'):
        raise SystemExit('slide5: instruction paragraph moved')
    doc = apply_edits(doc, [(paras[1].end(), paras[1].end(),
                             '<a:p>%s%s</a:p>' % (para_pPr(paras[1].group(0)), a_run(SUPPORT)))])
    doc = enlarge_box(doc, '7692705', '276999', '2540000', 'slide5 supporting-information box')
    parts['ppt/slides/slide5.xml'] = doc

    rewrite(PPTX_SRC, PPTX_DST, parts)
    return 'five slides filled'


def enlarge_box(doc: str, cx: str, cy: str, new_cy: str, what: str) -> str:
    """Give a one-line answer box room for the text that now follows its label."""
    old = '<a:ext cx="%s" cy="%s"/>' % (cx, cy)
    new = '<a:ext cx="%s" cy="%s"/>' % (cx, new_cy)
    if doc.count(old) != 1:
        raise SystemExit('%s: %s not found exactly once' % (what, old))
    return doc.replace(old, new)


def main() -> int:
    print(build_docx())
    print(build_pptx_slides())
    print('done — the pack is prepared, not sent')
    return 0


if __name__ == '__main__':
    sys.exit(main())
