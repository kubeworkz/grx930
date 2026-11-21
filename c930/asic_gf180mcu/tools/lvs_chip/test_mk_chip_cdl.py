#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Focused smoke test for mk_chip_cdl.py.

The fixtures are a tiny routed netlist and two tiny library CDLs. The test
exercises the CLI paths changed for the route209 reconstruction: `--top`,
repeatable `--lib` (including an IO pad with DVDD/DVSS), and
`--float-unconnected`. It reads no chip, PDK, or routed database and starts no
flow.

Run from the repository root:

    python c930/asic_gf180mcu/tools/lvs_chip/test_mk_chip_cdl.py

Exit status is unittest's: 0 pass, 1 failure.
"""

import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mk_chip_cdl  # noqa: E402


CELL_LIB = """\
* synthetic standard-cell fixture
.SUBCKT INV A ZN VDD VSS
.ENDS
.SUBCKT BUF A Z VDD VSS
.ENDS
"""

PAD_LIB = """\
* synthetic IO-cell fixture
.SUBCKT PAD A PAD DVDD DVSS
.ENDS
"""

ROUTED = """\
module net_top (a, b, z, p);
  input a;
  input b;
  output z;
  output p;
  INV u_inv (.A(a), .ZN(n1));
  BUF u_buf (.A(n1), .Z(z));
  PAD u_pad (.A(z), .PAD(p));
endmodule
"""

FLOATING = """\
module float_top (a, b);
  input a;
  input b;
  INV u_one (.A(a));
  INV u_two (.A(b));
endmodule
"""


class MkChipCdlSmokeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cell_lib = self.write("cells.cdl", CELL_LIB)
        self.pad_lib = self.write("pads.cdl", PAD_LIB)
        self.routed = self.write("routed.v", ROUTED)
        self.floating = self.write("floating.v", FLOATING)
        self.out = os.path.join(self.tmp.name, "chip.cdl")

    def write(self, name, text):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        return path

    def run_cli(self, routed, *extra):
        return subprocess.run(
            [sys.executable, mk_chip_cdl.__file__,
             "--routed", routed, "--out", self.out, *extra],
            capture_output=True, text=True, check=False)

    def read_out(self):
        with open(self.out, encoding="utf-8") as fh:
            return fh.read()

    def test_top_override_and_repeatable_libs(self):
        result = self.run_cli(
            self.routed,
            "--top", "layout_top",
            "--lib", self.cell_lib,
            "--lib", self.pad_lib)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("top: net_top -> layout_top (layout top)", result.stdout)

        text = self.read_out()
        self.assertIn("* layout_top: routed gate-level netlist", text)
        self.assertIn(".SUBCKT layout_top a b z p", text)
        self.assertIn("* library: cells.cdl sha256 ", text)
        self.assertIn("* library: pads.cdl sha256 ", text)
        self.assertIn("Xu_inv a n1 VDD VSS INV", text)
        self.assertIn("Xu_buf n1 z VDD VSS BUF", text)
        # DVDD/DVSS belong to the pad's power pins, not the signal pin list.
        self.assertIn("Xu_pad z p VDD VSS PAD", text)
        self.assertIn(".SUBCKT PAD A PAD DVDD DVSS", text)
        self.assertIn(".SUBCKT INV A ZN VDD VSS", text)
        self.assertIn(".SUBCKT BUF A Z VDD VSS", text)

    def test_pad_cell_requires_its_library(self):
        result = self.run_cli(self.routed, "--lib", self.cell_lib)

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("REFUSED", result.stdout)
        self.assertIn("PAD is not in the library CDL", result.stdout)

    def test_float_unconnected_refusal_and_unique_nets(self):
        refused = self.run_cli(self.floating, "--lib", self.cell_lib)
        self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
        self.assertIn("REFUSED", refused.stdout)
        self.assertIn("2 unconnected pins", refused.stdout)
        self.assertFalse(os.path.exists(self.out),
                         "a refused generation must not leave an output file")

        accepted = self.run_cli(
            self.floating, "--lib", self.cell_lib, "--float-unconnected")
        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
        self.assertIn("floated 2 deliberately unconnected pins on unique nets",
                      accepted.stdout)

        text = self.read_out()
        self.assertIn("Xu_one a NC_u_one_ZN VDD VSS INV", text)
        self.assertIn("Xu_two b NC_u_two_ZN VDD VSS INV", text)
        floated_nets = [line.split()[2] for line in text.splitlines()
                        if line.startswith("Xu_")]
        self.assertEqual(len(floated_nets), 2)
        self.assertEqual(len(set(floated_nets)), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
