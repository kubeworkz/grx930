# LVS on the die — what the September artifact is, and what can be checked

`doc/lvs_plan.md` §S2 says: convert `build/grx930_test_chip_routed.v` to SPICE, run the deck on
`grx930_test_chip_final.gds`, keep the report. This directory is that attempt, and its first
result is not a verdict: **the artifact cannot be LVS'd as it stands**, because it carries no
device geometry. Everything below is reproducible from the tree with the scripts in
`c930/asic_gf180mcu/tools/lvs_chip/` and `c930/asic_gf180mcu/build/lvs_chip_check.sh`.

Inputs, hashed:

| file | sha256 |
|---|---|
| `wafer_space_submission/grx930_test_chip_final.gds` | `ade20508299f6f64…` |
| `build/grx930_test_chip_routed.v` | `86692ee51756929d…` |
| the deck `libs.tech/klayout/tech/lvs/gf180mcu.lvs` | `00019ed0a7f434fc…` (the same deck the fixture family records) |

## 1. What the deck reads from the die, and what it means

The deck's layer numbers are the PDK's — `polygons(22, 0)` for comp, `30/0` poly2, `33/0` contact,
`34/0` metal1, `34/10` metal1 labels, `35/0` via1 … `81/0` metal5. The die's 26 layers are
`1/1, 1/2, 2/1, 2/2, 5/0 … 5/3, 6/0, 7/0 … 7/2, 8/0, 9/0 … 9/2, 10/0, 11/0 … 11/2, 12/0,
13/0 … 13/2, 14/0, 15/0`, all unnamed, and two of those numbers land on layers the deck *does*
know — with entirely different meanings:

```
$ bash tools/klayout_lvs.sh --layout wafer_space_submission/grx930_test_chip_final.gds \
      --netlist build/lvs_chip/grx930_test_chip.cdl --out build/lvs_chip/run_die_as_is \
      --switch metal_level=5LM                  # 9 minutes
...
dnwell has 1353041 polygons      # the die's Via4 cuts, on 12/0
nat has 289170 polygons          # the die's Metal1 routing, on 5/0
Total no. of polygons in the design is 1642211
devices  MISMATCH extracted 35 instances, schematic 371
verdict  MISMATCH
```

So the deck reads the die's *via4 cut* layer as `dnwell` and its *metal1* as `nat`, extracts 35
devices out of that noise, and compares them against 53,745 cells' worth of netlist. Nothing is
ever read on comp, poly2, contact or any metal — the numbers the die uses for those do not exist
in the deck. Scoped instead to a single standard cell (`--topcell gf180mcu_fd_sc_mcu7t5v0__
clkinv_1`, whose own geometry is the abstract on `5/2`, `1/2`, `2/2`), the same deck reads
`Total no. of polygons in the design is 0`.

Either way the answer is the same: this file cannot be LVS'd, and the failure is not silent — it
is a mismatch with a device count from layers that are not devices. The run's own record is kept:
`die_as_is/verdict.json` and `die_as_is/klayout.log` (layout `ade20508299f6f64…`, netlist
`50fd3a7c0d4d60de…`, deck `00019ed0a7f434fc…`, switches `combine=true`, `check_ports=false`,
`top_lvl_pins=true`, `run_mode=deep`, `metal_level=5LM`), and the repo's gate judges it
`LVS: MISMATCH devices: mismatch` (exit 1).

## 2. The die's numbering, derived rather than guessed

The DEF is the ground truth, because it names every layer and its `VIAS` section says which layers
each via joins:

```
- via3_4_3200_3200_3_3_1040_1040  + LAYERS Metal3 Via3 Metal4  + ROWCOL 3 3
- via4_5_3200_6400_4_2_1240_1240  + LAYERS Metal4 Via4 Metal5  + ROWCOL 4 2
```

The die's via cells contain exactly those shapes, with the cut arrays of 9 and 8:

| die cell | own geometry | DEF says |
|---|---|---|
| `VIA_via3_4_3200_3200_3_3_1040_1040` | `10/0` ×9, `9/0` ×1, `11/0` ×1 | 3×3 cuts of Via3 between Metal3 and Metal4 |
| `VIA_via4_5_3200_6400_4_2_1240_1240` | `12/0` ×8, `11/0` ×1, `13/0` ×1 | 4×2 cuts of Via4 between Metal4 and Metal5 |

so `Metal3 = 9/0`, `Via3 = 10/0`, `Metal4 = 11/0`, `Via4 = 12/0`, `Metal5 = 13/0`, and the
Via1/Via2 cells (`{5/0,6/0,7/0}` and `{7/0,8/0,9/0}`, one shape each) close the chain:
`Metal1 = 5/0`, `Via1 = 6/0`, `Metal2 = 7/0`, `Via2 = 8/0`. Datatype 1 is the label of its layer,
2 and 3 are LEF pin and obstruction shapes, 14/0 is a cell boundary, 15/0 the die boundary, and
`1`/`2` are Pwell and Nwell (each one shape plus a `VPW`/`VNW` label per cell).

`wafer_space_submission/verify_layers.py` asserts a different map — `(5,0)` Contact, `(5,1)`
Poly, `(6,0)` Metal1 … `(14,0)` Metal5 — which is off by one from Metal1 onward and calls text
layers geometry. Run on the die it agrees with itself and says the file is ready:

```
✓ Active (1.1) ✓ P-Well (2.1) ✓ Contact (5.0) ✓ Poly (5.1) ✓ Metal1 (6.0) … ✓ Metal5 (14.0)
Cell instances: 698639
✓ GDS verification PASSED
✓ Ready for wafer.space submission
```

Every `✓` there is a layer number the PDK does not use for that name, and the checker has no way
to notice: it asserts the map it then verifies against.

## 3. The standard cells are LEF abstracts, not layouts

`tools/lvs_chip/compare_cells.py` reads the same cells out of the PDK library GDS and out of the
die. For `clkinv_1`:

| PDK library GDS | die |
|---|---|
| `34/0` Metal1 ×4, area 4.692 µm² | `5/2` ×6, area 4.692 µm² |
| `34/10` labels ×4 | `5/1` labels ×4 |
| `33/0` contact ×7, `30/0` poly2 ×1, `22/0` comp ×2, `32/0` nplus, `31/0` pplus, `55/0` dualgate | — nothing |
| `21/0` Nwell, `204/0` Pwell, `0/0`/`112/1` boundary | `2/2` Nwell, `1/2` Pwell, `14/0` boundary |

Six Metal1 shapes is exactly the LEF's six pin rectangles for that cell (`I`, `ZN`, `VDD` ×2,
`VSS` ×2) plus the two well pins and a `SIZE` boundary; the obstruction datatype appears in cells
that have LEF obstructions (`mux2_1`: `5/3` ×8). The die's cells are the abstracts the router
placed, not the library layouts — so the file has no comp, no poly and no contact anywhere, and
no transistor can be extracted from it, by this deck or any other.

The flow's own foundry-fill evidence was measured on a different file (`submit/run1/chip_top.gds`
in the run container), which is why it reports comp and poly areas at all.

## 4. The harness is not the problem

One cell taken straight out of the PDK library GDS, compared with its own CDL subcircuit:

```
devices  MATCH    extracted 3 instances, schematic 2
INFO : Congratulations! Netlists match.
```

(`tools/lvs_chip/mk_pdk_cell_probe.py`, then `tools/klayout_lvs.sh` with `metal_level=5LM`.) The
device comparison matches; the only difference is the deck's port convention — it extracts a `SUB`
pin for the p-substrate where the CDL declares `VNW`/`VPW`, which is why the harness reports the
port check as failed for a standalone cell and why the chip CDL binds `VPW` to `SUB`.

## 5. The reconstruction, and what it is worth

`tools/lvs_chip/reconstruct_die.py` rebuilds the stream the flow should have written: the die's
routing and cell placements, with the PDK's real cells and the PDK's layer numbers; the LEF
abstracts and boundary markers are dropped. `tools/lvs_chip/mk_chip_cdl.py` turns the routed
netlist into a device-level CDL — 53,745 instances, 34 cell types, power bound (`VDD`/`VSS`,
`VNW` left a net of its own, `VPW` to `SUB`), names sanitised with a collision check.

```
die as shipped                         1,642,211 polygons, all on misread layers (dnwell/nat)
                                       -> 35 devices extracted, MISMATCH
reconstructed (real cells + remap)     7,432,081 polygons on comp/poly2/contact/metal1..5
                                       -> extraction running (see below)
```

The reconstructed file (`build/lvs_chip/reconstructed.gds`, sha256 `1c49ab417d299af7…`) is 60 MB
and 53,940 standard cells plus 644,699 DEF vias. It is **not** the submitted artifact: it is the
artifact with its cells restored to the layouts the PDK ships. A verdict on it says whether the
die's routing agrees with the routed netlist — everything inside the cells belongs to the library.

Full-die extraction at this size is the cost `doc/lvs_plan.md` §5 budgeted as "hours, unmeasured":
on this box (7.7 GB RAM, 5.8 GB to the container) the run held 3.4-4.8 GB and one core for over
an hour and a half inside the deck's derivation phase alone, without reaching the comparison.
`build/lvs_chip_check.sh` is the runner; `--net-only` stops after extraction when only the
timing is wanted.

**The verdict of that run is still outstanding as this is written.** Measured, rather than
guessed: three hours of wall clock bought 1 h 44 m of klayout CPU time, one core at ~70 %, no
phase boundary crossed since `Starting GF180MCU LVS runset`, resident memory oscillating between
2.5 and 4.8 GB of the 5.8 GB the container is allowed. The collection is queued rather than
eyeballed — `bash build/lvs_chip_collect.sh` waits for the run to return, copies the report and
both logs into `chip/`, and runs the repo's gate over it so the exit status is recorded beside
it; run it with `--now` to collect whatever exists at any point. If the container runs out of
memory first, the verdict is `CANNOT-RUN` and the finding is the resource one: a full-die
extraction does not fit this box's container budget, and `doc/lvs_plan.md` §5's "hours,
unmeasured" acquires a number.

## 6. What this means for the submission

- The September GDS is not an LVS candidate, and not a manufacturing candidate either: a die with
  no diffusion is not a die.
- The cell stream-out is the broken step: the library GDSs have to be **merged** into the final
  stream (`CELL_GDS` in `libs.tech/librelane/config.tcl` names them), and the layers have to be
  written with `KLAYOUT_DEF_LAYER_MAP` (the PDK's `gf180mcu.map`), not with a LEF/DEF index.
- `verify_layers.py` passing is not evidence of either: it checks a map it also asserts.
- `doc/lvs_plan.md` §7's "the September artifact is void for reasons LVS cannot see" is wrong in
  one direction: LVS sees this one first, as an empty extraction.
