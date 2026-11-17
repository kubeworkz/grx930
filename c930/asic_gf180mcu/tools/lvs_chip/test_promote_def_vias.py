#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Focused regression for promote_def_vias.py.

The fixtures are the two `VIAS` entries in the old routed DEF and the two LEF
`VIARULE ... GENERATE` blocks they name. The test checks the generated fixed
`VIA` geometry through `stream_out.parse_lef_vias`, plus the refusal paths. It
reads no design, PDK layout, or artifact and starts no flow.

Run from the repository root (on Windows use `$(cygpath -m .)` for the mount):

    docker run --rm -v "$PWD:/work" \
        --entrypoint python3 ghcr.io/efabless/openlane2:2.3.10 \
        /work/c930/asic_gf180mcu/tools/lvs_chip/test_promote_def_vias.py

Exit status is unittest's: 0 pass, 1 failure.
"""

import io
import os
import subprocess
import sys
import tempfile
import unittest
from collections import defaultdict
from contextlib import redirect_stderr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import promote_def_vias as promoter  # noqa: E402
import stream_out  # noqa: E402


VIA3 = ("via3_4_3200_3200_3_3_1040_1040")
VIA4 = ("via4_5_3200_6400_4_2_1240_1240")

DEF_HEADER = """\
VERSION 5.8 ;
UNITS DISTANCE MICRONS 2000 ;
DIEAREA ( 0 0 ) ( 3930 5120 ) ;
"""

VIA3_DEF = (
    "- via3_4_3200_3200_3_3_1040_1040 "
    "+ VIARULE Via3_GEN_HH "
    "+ CUTSIZE 520 520 "
    "+ LAYERS Metal3 Via3 Metal4 "
    "+ CUTSPACING 520 520 "
    "+ ENCLOSURE 120 300 300 120 "
    "+ ROWCOL 3 3 ;"
)
VIA4_DEF = (
    "- via4_5_3200_6400_4_2_1240_1240 "
    "+ VIARULE Via4_GEN_HH "
    "+ CUTSIZE 520 520 "
    "+ LAYERS Metal4 Via4 Metal5 "
    "+ CUTSPACING 720 720 "
    "+ ENCLOSURE 720 120 120 460 "
    "+ ROWCOL 4 2 ;"
)

LEF_RULES = """\
VIARULE Via3_GEN_HH GENERATE
  LAYER Metal3 ;
    ENCLOSURE 0.060 0.010 ;
  LAYER Metal4 ;
    ENCLOSURE 0.060 0.010 ;
  LAYER Via3 ;
    RECT -0.130 -0.130 0.130 0.130 ;
    SPACING 0.520 BY 0.520 ;
END Via3_GEN_HH

VIARULE Via4_GEN_HH GENERATE
  LAYER Metal4 ;
    ENCLOSURE 0.060 0.010 ;
  LAYER Metal5 ;
    ENCLOSURE 0.060 0.010 ;
  LAYER Via4 ;
    RECT -0.130 -0.130 0.130 0.130 ;
    SPACING 0.520 BY 0.520 ;
END Via4_GEN_HH
"""


def def_with_vias(vias, count=None):
    count = len(vias) if count is None else count
    body = "\n".join("    " + via for via in vias)
    return f"{DEF_HEADER}VIAS {count} ;\n{body}\nEND VIAS\nEND DESIGN\n"


class PromoteDefViasRegression(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.def_path = os.path.join(self.tmp.name, "routed.def")
        self.lef_path = os.path.join(self.tmp.name, "cells.lef")
        self.out_path = os.path.join(self.tmp.name, "routed_vias.lef")

    def write(self, path, text):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def promote(self, def_text, lef_text=LEF_RULES):
        self.write(self.def_path, def_text)
        self.write(self.lef_path, lef_text)
        count = promoter.promote(self.def_path, self.lef_path, self.out_path)
        with open(self.out_path, encoding="utf-8") as fh:
            return count, fh.read()

    def assert_refused(self, def_text, lef_text, message):
        self.write(self.def_path, def_text)
        self.write(self.lef_path, lef_text)
        if os.path.exists(self.out_path):
            os.unlink(self.out_path)
        stderr = io.StringIO()
        with self.assertRaises(SystemExit) as caught, redirect_stderr(stderr):
            promoter.promote(self.def_path, self.lef_path, self.out_path)
        self.assertEqual(caught.exception.code, 2)
        self.assertIn(message, stderr.getvalue())
        self.assertFalse(os.path.exists(self.out_path),
                         "a refused promotion must not leave an output file")

    @staticmethod
    def layer_boxes(definition):
        boxes = defaultdict(list)
        for layer, box in definition:
            boxes[layer].append(box)
        return boxes

    @staticmethod
    def dims(box):
        return (round(box[2] - box[0], 6), round(box[3] - box[1], 6))

    @staticmethod
    def centers(boxes):
        return sorted((round((box[0] + box[2]) / 2, 6),
                       round((box[1] + box[3]) / 2, 6)) for box in boxes)

    def test_two_old_def_entries_promote_and_parse(self):
        count, _text = self.promote(def_with_vias([VIA3_DEF, VIA4_DEF]))
        self.assertEqual(count, 2)
        vias = stream_out.parse_lef_vias(self.out_path)
        self.assertEqual(set(vias), {VIA3, VIA4})

        via3 = self.layer_boxes(vias[VIA3])
        self.assertEqual(self.dims(via3["Metal3"][0]), (1.42, 1.60))
        self.assertEqual(self.dims(via3["Metal4"][0]), (1.60, 1.42))
        self.assertEqual(len(via3["Via3"]), 9)
        for box in via3["Via3"]:
            self.assertEqual(self.dims(box), (0.26, 0.26))
        self.assertEqual(self.centers(via3["Via3"]),
                         self.centers([(x - 0.13, y - 0.13, x + 0.13, y + 0.13)
                                       for x in (-0.52, 0.0, 0.52)
                                       for y in (-0.52, 0.0, 0.52)]))

        via4 = self.layer_boxes(vias[VIA4])
        self.assertEqual(self.dims(via4["Metal4"][0]), (1.60, 2.24))
        self.assertEqual(self.dims(via4["Metal5"][0]), (1.00, 2.58))
        self.assertEqual(len(via4["Via4"]), 8)
        for box in via4["Via4"]:
            self.assertEqual(self.dims(box), (0.26, 0.26))
        self.assertEqual(self.centers(via4["Via4"]),
                         self.centers([(x - 0.13, y - 0.13, x + 0.13, y + 0.13)
                                       for x in (-0.31, 0.31)
                                       for y in (-0.93, -0.31, 0.31, 0.93)]))

    def test_no_vias_section_writes_header_only(self):
        count, text = self.promote(f"{DEF_HEADER}END DESIGN\n")
        self.assertEqual(count, 0)
        self.assertIn("No DEF VIAS entries", text)
        self.assertEqual(stream_out.parse_lef_vias(self.out_path), {})

    def test_missing_viarule_clause_is_refused(self):
        broken = VIA3_DEF.replace("+ VIARULE Via3_GEN_HH ", "")
        self.assert_refused(def_with_vias([broken]), LEF_RULES,
                            "missing +VIARULE")

    def test_unknown_viarule_is_refused(self):
        broken = VIA3_DEF.replace("Via3_GEN_HH", "Via9_GEN_HH")
        self.assert_refused(def_with_vias([broken]), LEF_RULES,
                            "unknown VIARULE")

    def test_layer_role_mismatch_is_refused(self):
        broken_lef = LEF_RULES.replace(
            "  LAYER Metal4 ;\n    ENCLOSURE 0.060 0.010 ;",
            "  LAYER Metal2 ;\n    ENCLOSURE 0.060 0.010 ;", 1)
        self.assert_refused(def_with_vias([VIA3_DEF]), broken_lef,
                            "do not match VIARULE")

    def test_cut_size_mismatch_is_refused(self):
        broken_lef = LEF_RULES.replace(
            "RECT -0.130 -0.130 0.130 0.130 ;",
            "RECT -0.135 -0.135 0.135 0.135 ;", 1)
        self.assert_refused(def_with_vias([VIA3_DEF]), broken_lef,
                            "VIARULE cut is")

    def test_non_positive_cut_is_refused(self):
        broken = VIA3_DEF.replace("+ CUTSIZE 520 520", "+ CUTSIZE 0 520")
        self.assert_refused(def_with_vias([broken]), LEF_RULES,
                            "+CUTSIZE must be positive")

    def test_rowcol_zero_is_refused(self):
        broken = VIA3_DEF.replace("+ ROWCOL 3 3", "+ ROWCOL 0 3")
        self.assert_refused(def_with_vias([broken]), LEF_RULES,
                            "+ROWCOL must be positive")

    def test_vias_count_mismatch_is_refused(self):
        self.assert_refused(def_with_vias([VIA3_DEF, VIA4_DEF], count=3),
                            LEF_RULES, "VIAS says 3 entries")

    def test_duplicate_def_via_name_is_refused(self):
        self.assert_refused(def_with_vias([VIA3_DEF, VIA3_DEF]), LEF_RULES,
                            "duplicate DEF via")

    def test_fixed_lef_via_collision_is_refused(self):
        collision = LEF_RULES + f"""\
VIA {VIA3}
  LAYER Metal3 ;
    RECT 0 0 1 1 ;
END {VIA3}
"""
        self.assert_refused(def_with_vias([VIA3_DEF]), collision,
                            "already a fixed LEF VIA")

    def test_unknown_clause_is_refused(self):
        broken = VIA3_DEF.replace("+ ROWCOL 3 3", "+ FOO 3 3")
        self.assert_refused(def_with_vias([broken]), LEF_RULES,
                            "unknown clause +FOO")

    def test_missing_units_is_refused(self):
        no_units = def_with_vias([VIA3_DEF]).replace(
            "UNITS DISTANCE MICRONS 2000 ;\n", "")
        self.assert_refused(no_units, LEF_RULES,
                            "no `UNITS DISTANCE MICRONS`")

    def test_missing_end_vias_is_refused(self):
        broken = def_with_vias([VIA3_DEF]).replace("END VIAS\n", "")
        self.assert_refused(broken, LEF_RULES, "no `END VIAS`")

    def test_cli_refusal_exits_two(self):
        broken = VIA3_DEF.replace("Via3_GEN_HH", "Via9_GEN_HH")
        self.write(self.def_path, def_with_vias([broken]))
        self.write(self.lef_path, LEF_RULES)
        result = subprocess.run(
            [sys.executable, promoter.__file__, "--def", self.def_path,
             "--lef", self.lef_path, "--out", self.out_path],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("REFUSED", result.stderr)
        self.assertIn("unknown VIARULE", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
