#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Focused regression for stream_out.py's LEF-via path.

No flow, DEF, or PDK layout is read. A small LEF fixture supplies the 2x2 via;
the test checks the built cell on the PDK GDS layers and the refusal paths.

Run from the repository root (Linux/macOS mount shown; on Windows use
`$(cygpath -m .)` for the mount source):

    docker run --rm -v "$PWD:/work" \
        --entrypoint python3 ghcr.io/efabless/openlane2:2.3.10 \
        /work/c930/asic_gf180mcu/tools/lvs_chip/test_stream_out_lef_vias.py

Exit status is unittest's: 0 pass, 1 failure.
"""

import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr

import klayout.db as db

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stream_out  # noqa: E402


VIA = "Via1_2X2_0_60_10_60_H_V"
LEF_2X2 = f"""\
VIA {VIA}
 LAYER Via1 ;
 RECT -0.390 -0.390 -0.130 -0.130 ;
 RECT 0.130 -0.390 0.390 -0.130 ;
 RECT -0.390 0.130 -0.130 0.390 ;
 RECT 0.130 0.130 0.390 0.390 ;
 LAYER Metal1 ;
 RECT -0.450 -0.390 0.450 0.390 ;
 LAYER Metal2 ;
 RECT -0.400 -0.450 0.400 0.450 ;
END {VIA}
"""


class LefViaRegression(unittest.TestCase):
    def setUp(self):
        self.layout = db.Layout()
        self.layout.dbu = 0.001

    def parse(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".lef", delete=False) as fh:
            fh.write(text)
            path = fh.name
        self.addCleanup(os.unlink, path)
        return stream_out.parse_lef_vias(path)

    def test_2x2_builds_four_cuts_and_two_enclosures(self):
        definition = self.parse(LEF_2X2)[VIA]
        cell = stream_out.build_lef_via(self.layout, db, VIA, definition)

        cuts = self.layout.find_layer(35, 0)
        m1 = self.layout.find_layer(34, 0)
        m2 = self.layout.find_layer(36, 0)
        self.assertGreaterEqual(cuts, 0, "Via1 35/0 was not created")
        self.assertGreaterEqual(m1, 0, "Metal1 34/0 was not created")
        self.assertGreaterEqual(m2, 0, "Metal2 36/0 was not created")

        cut_boxes = [shape.box for shape in cell.shapes(cuts).each()]
        self.assertEqual(len(cut_boxes), 4)
        for box in cut_boxes:
            self.assertEqual((box.width(), box.height(), box.area()), (260, 260, 67_600))

        m1_boxes = [shape.box for shape in cell.shapes(m1).each()]
        m2_boxes = [shape.box for shape in cell.shapes(m2).each()]
        self.assertEqual(len(m1_boxes), 1)
        self.assertEqual(len(m2_boxes), 1)
        self.assertEqual((m1_boxes[0].width(), m1_boxes[0].height()), (900, 780))
        self.assertEqual((m2_boxes[0].width(), m2_boxes[0].height()), (800, 900))

    def assert_refused(self, call, message):
        stderr = io.StringIO()
        with self.assertRaises(SystemExit) as caught, redirect_stderr(stderr):
            call()
        self.assertEqual(caught.exception.code, 2)
        self.assertIn(message, stderr.getvalue())

    def test_missing_via_is_refused(self):
        self.assert_refused(
            lambda: stream_out.require_lef_via({}, VIA, ["fixture.lef"]), "no LEF")

    def test_malformed_via_without_geometry_is_refused(self):
        self.assert_refused(
            lambda: self.parse("VIA Broken\n LAYER Metal1 ;\nEND Broken\n"),
            "has no geometry")

    def test_malformed_via_with_unknown_layer_is_refused(self):
        self.assert_refused(
            lambda: stream_out.build_lef_via(
                self.layout, db, "BadLayer", [("Via9", (0.0, 0.0, 1.0, 1.0))]),
            "no PDK GDS number")

    def test_empty_definition_is_refused(self):
        self.assert_refused(
            lambda: stream_out.build_lef_via(self.layout, db, "Empty", []),
            "empty LEF VIA definition")


if __name__ == "__main__":
    unittest.main(verbosity=2)
