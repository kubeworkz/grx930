#!/usr/bin/env python3
"""Positive and negative tests for pdn_stitch.py --existing-stack.

The fixture is deliberately tiny: two VDD/VSS rails, two M4 stripes, two M5 stripes, and one
via1/2/3/4 stack per supply. The valid copy must be accepted and copied. Two mutated copies (one
missing a via2 instance, one missing an M5 stripe) must be refused with no output GDS or report.

Run from the repository root; the flow image provides KLayout:

    docker run --rm -v "$PWD:/work" --entrypoint python3 \
        ghcr.io/efabless/openlane2:2.3.10 \
        /work/c930/asic_gf180mcu/tools/lvs_chip/test_pdn_existing_stack.py \
        --pdn /work/c930/asic_gf180mcu/tools/lvs_chip/pdn_stitch.py

CI runs this in the `pdn-negative` job of .github/workflows/lvs-evidence.yml.
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import klayout.db as db

DEF = """VERSION 5.8 ;
UNITS DISTANCE MICRONS 2000 ;
SPECIALNETS 2 ;
    - VDD ( PIN VDD ) + USE POWER
      + ROUTED Metal1 1200 + SHAPE FOLLOWPIN ( 0 1000 ) ( 100000 1000 )
      NEW Metal4 10000 + SHAPE STRIPE ( 5000 0 ) ( 5000 500000 )
      NEW Metal5 10000 + SHAPE STRIPE ( 0 100000 ) ( 300000 100000 )
      NEW Metal1 0 + SHAPE STRIPE ( 5000 1000 ) via1_2_test
      NEW Metal2 0 + SHAPE STRIPE ( 5000 1000 ) via2_3_test
      NEW Metal3 0 + SHAPE STRIPE ( 5000 1000 ) via3_4_test
      NEW Metal4 0 + SHAPE STRIPE ( 5000 100000 ) via4_5_test
    ;
    - VSS ( PIN VSS ) + USE GROUND
      + ROUTED Metal1 1200 + SHAPE FOLLOWPIN ( 0 5000 ) ( 100000 5000 )
      NEW Metal4 10000 + SHAPE STRIPE ( 60000 0 ) ( 60000 500000 )
      NEW Metal5 10000 + SHAPE STRIPE ( 0 300000 ) ( 300000 300000 )
      NEW Metal1 0 + SHAPE STRIPE ( 60000 5000 ) via1_2_test
      NEW Metal2 0 + SHAPE STRIPE ( 60000 5000 ) via2_3_test
      NEW Metal3 0 + SHAPE STRIPE ( 60000 5000 ) via3_4_test
      NEW Metal4 0 + SHAPE STRIPE ( 60000 300000 ) via4_5_test
    ;
END SPECIALNETS
END DESIGN
"""

# GDS (dbu = 0.001 um); DEF units are 2000/um, so the fixture's scale is 2.
VIA_DEFS = {1: ("VIA_via1_2_test", ((34, 0), (35, 0), (36, 0))),
            2: ("VIA_via2_3_test", ((36, 0), (38, 0), (42, 0))),
            3: ("VIA_via3_4_test", ((42, 0), (40, 0), (46, 0))),
            4: ("VIA_via4_5_test", ((46, 0), (41, 0), (81, 0)))}
VIA_POS = {1: ((2500, 500), (30000, 2500)),
           2: ((2500, 500), (30000, 2500)),
           3: ((2500, 500), (30000, 2500)),
           4: ((2500, 50000), (30000, 150000))}


def build_gds(path, omit_via=None, omit_m5=False):
    ly = db.Layout()
    ly.dbu = 0.001
    cells = {}
    for level, (name, layers) in VIA_DEFS.items():
        cell = ly.create_cell(name)
        for layer in layers:
            cell.shapes(ly.layer(*layer)).insert(db.Box(-100, -100, 100, 100))
        cells[level] = cell

    top = ly.create_cell("fixture_top")
    shapes = {
        (34, 0): [(0, 200, 50000, 800), (0, 2200, 50000, 2800)],
        (46, 0): [(0, 0, 5000, 250000), (27500, 0, 32500, 250000)],
        (81, 0): ([(0, 47500, 150000, 52500)] if not omit_m5 else []) +
                 [(0, 147500, 150000, 152500)],
    }
    for layer, boxes in shapes.items():
        for x0, y0, x1, y1 in boxes:
            top.shapes(ly.layer(*layer)).insert(db.Box(x0, y0, x1, y1))
    for level, coords in VIA_POS.items():
        if level == omit_via:
            # Keep the via cell referenced (so its layers exist and the fixture has one top cell),
            # but omit the second expected instance. The dummy is far outside the PDN geometry.
            top.insert(db.CellInstArray(cells[level].cell_index(),
                                        db.Trans(db.Vector(1000000, 1000000))))
            coords = coords[:1]
        for x, y in coords:
            top.insert(db.CellInstArray(cells[level].cell_index(), db.Trans(db.Vector(x, y))))
    ly.write(str(path))


def run_case(pdn, def_file, gds, out, report):
    for path in (out, report):
        path.unlink(missing_ok=True)
    return subprocess.run(
        [sys.executable, str(pdn), "--existing-stack", "--def", str(def_file),
         "--gds", str(gds), "--out-gds", str(out), "--report", str(report)],
        text=True, capture_output=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdn", default=str(Path(__file__).with_name("pdn_stitch.py")))
    ap.add_argument("--work", default=None, help="fixture directory (default: a new temp dir)")
    args = ap.parse_args()

    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="pdn_existing_stack_"))
    work.mkdir(parents=True, exist_ok=True)
    def_file = work / "fixture.def"
    def_file.write_text(DEF)
    pdn = Path(args.pdn).resolve()
    failures = []

    def check(label, rc_expected_zero, case, gds, out, report, stale=False):
        if stale:
            out.write_text("stale output")
            report.write_text("stale report")
        cp = run_case(pdn, def_file, gds, out, report)
        ok = (cp.returncode == 0) == rc_expected_zero
        if rc_expected_zero:
            ok = ok and out.is_file() and report.is_file()
            if ok:
                data = json.loads(report.read_text())
                ok = data.get("verdict") == "NO-STRAPS-NEEDED"
        else:
            ok = ok and not out.exists() and not report.exists()
        print(f"{label}: rc={cp.returncode} {'PASS' if ok else 'FAIL'}")
        if not ok:
            failures.append(label)
            print(cp.stdout[-2000:])
            print(cp.stderr[-2000:])
        return cp

    good = work / "good.gds"
    build_gds(good)
    check("valid fixture", True, None, good, work / "good_out.gds", work / "good.json")

    bad_via = work / "bad_via.gds"
    build_gds(bad_via, omit_via=2)
    check("missing via2", False, None, bad_via, work / "bad_via_out.gds",
          work / "bad_via.json", stale=True)

    bad_m5 = work / "bad_m5.gds"
    build_gds(bad_m5, omit_m5=True)
    check("missing M5 stripe", False, None, bad_m5, work / "bad_m5_out.gds",
          work / "bad_m5.json", stale=True)

    print(f"fixtures: {work}")
    if failures:
        print("FAIL: " + ", ".join(failures))
        return 1
    print("PASS: valid fixture accepted; both mutations refused without output or report")
    return 0


if __name__ == "__main__":
    sys.exit(main())
