# Active-layer fill (dummy COMP + dummy Poly2)

The flow's `KLayout.Filler` step runs this directory's `fill_active.rb` instead of the PDK's
`fill_all.rb`. That is the whole point: the PDK script is the *metal* fill plus a dummy
COMP/Poly2 pattern that does not reach the deck's two global active-layer density floors on this
die, and the two halves are separable — this is the active half with the foundry's metal half
kept.

| File | Role |
|---|---|
| `fill_active.rb` | the entry point the flow runs. Drop-in for `fill_all.rb`: COMP fill, Poly2 fill, then the PDK's own `fill_metal.rb`, then writes the GDS. Exits non-zero if it did not write one |
| `fill_comp_active.rb` | the foundry's `fill_comp.rb` with two measured changes (halo, pattern) and a derived stagger |
| `fill_poly2_active.rb` | the foundry's `fill_poly2.rb`, except the dummy Poly2 is derived from the dummy COMP the step above placed |
| `check_active_density.rb` | reports the two floors the way the deck computes them (DCF.1b/1d = 22/0 + 22/4, PL.8 = 30/0 + 30/4, both over the die bbox). Fast; use it as the smoke test |
| `measure_paired_zone.rb` | per-exclusion cost: which DPF halo removes how much of the pair area. This is what found the Metal1/Metal2 problem, so it keeps all ten distances in its list on purpose |
| `probe_dpf1.rb`, `probe_dpf1b.rb` | the two probes that established how strict DPF.1 is |
| `evidence.md` | every number this file quotes, extracted from the flow box's measurement logs (`/home/kubew/fillrun*.log`) with the log it came from |
| `zone_capacity.rb` | how much room the pairing zone has left for another pattern (region algebra, no rule queries). Also deliberately prices the all-ten-distance policy — see its header |

## What has to be true, and what is true now

Two global floors, neither of which cares *where* the shapes are:

* **DCF.1b** `comp + comp_dummy >= 25 %` (capped at 70 % by DCF.1d)
* **PL.8** `poly2 + poly2_dummy >= 14 %` (no upper bound)

Every number below is the **deck's own**, from the gf180mcuD deck in the pinned pre-check image
(`-rd decks="dummy_comp,dummy_poly2,density" -rd variant=gf180mcuD -rd run_mode=deep`, which is
how the pre-check's own `KLayout.Density` and `KLayout.DRC` steps invoke it), on the flow's own
GDS:

| active-layer fill | COMP (22/0+22/4) | Poly2 (30/0+30/4) | DCF.1b | PL.8 | dummy_comp / dummy_poly2 decks |
|---|---|---|---|---|---|
| **PDK `fill_all.rb`, as the flow runs it today** (`submit/run1/chip_top.gds`, = `tpl02/92-klayout-filler/chip_top.gds`) | 20.182 % | 12.992 % | **FAIL** | **FAIL** | — |
| PDK pattern with the 10 um halo removed (5x5 on 3.0, `fillrun/flow_base.log`¹) | 28.736 % | 12.667 % | PASS | **FAIL** | — |
| 6.0 on 1.9, stagger 1.6, all ten DPF distances (`fillrun/dense.log`¹) | 32.084 % | 13.037 % | PASS | **FAIL** | — |
| 6.0 on 1.9, stagger 1.6, `pair_metal_um 0` (`fillrun3.log`) | 33.449 % | 26.757 % | PASS | PASS | **DCF.2b 42,688 — illegal** |
| **6.0 on 2.0, stagger 0.5, `pair_metal_um 0`** (`fillrun4.log`, the shipped pattern) | **31.274 %** | **26.254 %** | **PASS** | **PASS** | **0 violations** |

¹ Rows 2-3 are from `check_active_density.rb`, which reports the *merged* layer areas; it reads
0.11 points lower than the deck on COMP (deep mode sums raw polygons). The deck's own numbers are
used wherever they were measured, and `fillrun4.log` has both for the shipped pattern.

The first row is the important one: **the artifact the flow produces today fails both rules**, and
that is exactly what the pre-check reported (`runs/run2`, `flow.log`: "2 KLayout density errors
found"). So this is not a margin question — with the PDK script the die is 4.8 points short on
COMP and 1.0 point short on Poly2, both floors missed, and our fill clears both.

## The stagger, which is where the first version failed

The lattice steps are `(fill + space, stagger)` and `(stagger, fill + space)`. Squares that are
`i=1,j=0` apart sit exactly `line_space` apart along x; the `i=1,j=1` pair is the diagonal one,
and its corner-to-corner distance is `(line_space - stagger) * sqrt(2)`. So the pattern's own
minimum dummy COMP space is

```
min(line_space, |line_space - stagger| * sqrt(2))
```

and **DCF.2b — which the deck does check — wants 1.9 um in all directions.** The foundry's 5x5 on
3.0 with its 1.6 stagger passes because `(3.0-1.6)*sqrt(2) = 1.98`. Carrying that same 1.6 stagger
onto a 1.9 um space gives `(1.9-1.6)*sqrt(2) = 0.42 um`: the axial 1.9 um is not enough on its own,
and the deck reports **42,688 DCF.2b violations** over this die (`fillrun3.log`). The shipped
pattern uses `stagger 0.5`, where `(2.0-0.5)*sqrt(2) = 2.12 >= 2.0`, so the diagonal is no longer
the binding pair, and `line_space` is 2.0 rather than the rule's own 1.9 so the axial pair has
0.1 um of margin instead of sitting exactly on it.

`fill_comp_active.rb` now computes this and prints it, and warns if a pattern's minimum is below
DCF.2b's value, so the same trap cannot be re-entered silently by changing `fill_um`.

The first version's second error was in the same family: the diagonally *overlapping* grown Poly2
squares made the dummy Poly2 count read as 63,322 polygons for 81,028 squares (they had merged).
That is gone with a legal stagger — the shipped run reports 78,665 Poly2 squares against 2,884,464
um² of dummy COMP, i.e. 1.8 % of the pairs dropped.

## Why the pairing filter ignores DPF.12 and DPF.13

`fill_poly2_active.rb` drops a pair whenever the grown Poly2 square comes within a DPF distance of
another layer. Ten distances were being applied "for the guideline". Two of them account for almost
everything that was being dropped, and the deck does not check them:

```
  Metal1     2.0 um : 2747852 um^2  (13.644 % of die)     <- DPF.12
  Metal2     2.0 um :  903320 um^2  ( 4.485 % of die)     <- DPF.13
  RES_MK    19.7 um :  103832 um^2  ( 0.516 % of die)     <- DPF.8, checked
  PMNDMY     8.0 um :   41651 um^2  ( 0.207 % of die)     <- DPF.19, checked
  scribe    26.0 um :   26871 um^2  ( 0.133 % of die)     <- DPF.7, checked
  NDMY      29.7 um :   17521 um^2  ( 0.087 % of die)     <- DPF.11, checked
  Poly2      5.0 um :   14493 um^2  ( 0.072 % of die)     <- DPF.5, checked
  Pad        6.7 um :    3088 um^2  ( 0.015 % of die)     <- DPF.9, checked
```

`dummy_poly2.rb` lines 97-114 of the gf180mcuD deck comment both rules out, with the reason
("For now this is disabled since wafer.space moves all fill shapes to active metal layers"), and
the `DUMMY_SUB_PREV` they are guarded by is defined nowhere — `grep -rn DUMMY_SUB_PREV` finds it
only inside those two comments (the other is in `dummy_metal.rb`). The rest of the exclusion set
costs 1.03 % of the die between them. PL.8 was failing because of 18.1 % of die of diamonds the
deck never asked for, not because the pairing zone was exhausted.

`pair_metal_um` is the switch. `0.0` (the default) applies neither; `2.0` restores both at the
deck's own distance for a deck or pre-check that turns `DUMMY_SUB_PREV` on. Rebuilding with 2.0
reproduces the 13 % PL.8 failure: if a future deck enables DPF.12/DPF.13, this die cannot meet
PL.8 with legal dummy Poly2, and the honest answer is "not achievable" rather than a denser
pattern.

Three more decisions in the same two files are the foundry's own numbers, kept:

* Every check the deck *does* run is applied at its own value (DPF.4 3.2, DPF.5 5.0, DPF.6a-d 1/2,
  DPF.7 26, DPF.8 19.7, DPF.9 6.7, DPF.11 29.7, DPF.14 3.0, DPF.16 3.0, DPF.19 8.0), and whole
  squares are filtered rather than clipped, so a surviving Poly2 square always covers its COMP
  square — which is what DPF.1 requires.
* DPF.5 runs from *drawn* Poly2 only (`poly2_drawn` = 30/0): the deck registers `poly2` as
  `poly2_drawn + poly2_dummy`, but the rule asks for `poly2_dummy.separation(poly2_drawn, 5)`. So
  the dummy-to-dummy pitch is governed by DPF.2b's 1.1 um, not by 5.0.
* `comp_halo_um 0` — the foundry script grows COMP by 10 um before adding DCF.4, i.e. keeps dummy
  COMP 13.5 um from circuit COMP. That 10 um is the manual's DCF.1a guideline and the deck does not
  check it (`dummy_comp.rb` has DCF.2b, DCF.4, DCF.5, DCF.6a-d, DCF.8a, DCF.11a, DCF.12 — no
  DCF.1a, no DCF.1c, no DCF.2a, no DCF.3). It is worth **8.9 points of COMP** on this die, measured
  with one instrument on one GDS and one pattern rather than by comparison across runs: the flow's
  own fill leaves dummy COMP at **3.036 %** of the die, and the same 5x5 on 3.0 pattern with the
  halo at 0 leaves **11.898 %** (`fillrun5.log`, `fillrun/flow_base.log`). It is also why the flow
  lands at 20.182 % against the 25 % floor: the halo, not the pattern, is the miss.

A fourth, earlier change was **removed** on measurement: a second pass with a 3 um cell restricted
to the pairing zone added 8,253 um^2 of dummy COMP (0.04 % of the die, 3,070,548 -> 3,078,801 in
`fillrun/twopass.log`) for a second full tiling pass over 20.1 mm^2. The first pass already tiles
its own legal region at the checked spacing, so the 2.5 um gaps it leaves cannot hold a 3 um square
that must stay clear of it.

The pattern cell is named `COMP_fill_cell` — the foundry's name, and one of the four the pre-check's
magic step flattens by exact name (`precheck.py`, `MAGIC_GDS_FLATGLOB`: `COMP_FILL`,
`COMP_fill_cell`, `POLY2_FILL`, `Poly2_fill_cell`). No wildcard is used there, so a variant name
(e.g. one carrying the pattern parameters) would silently fall out of that list.

## How the flow runs it

`KLayout.Filler` is generic (`librelane/steps/klayout.py`, class `Filler`, `run_generic`): it shells
out to

```
klayout -b -zz -r $KLAYOUT_FILLER_SCRIPT -rd input=<in.gds> -rd output=<out.gds> [-rd k=v ...]
```

with one `-rd` per `KLAYOUT_FILLER_OPTIONS` entry, both of which are the step's own config vars. So
`grx930_overrides.yaml` sets them (see the block at the end of that file) and the staging step must
copy this directory to `ws/template/fill/`, because `dir::` in that config resolves against
`ws/template/librelane/`:

```
KLAYOUT_FILLER_SCRIPT: dir::../fill/fill_active.rb
KLAYOUT_FILLER_OPTIONS:
  Metal2_ignore_active: true     # the PDK's own option, kept: it reaches the unchanged fill_metal.rb
  comp_halo_um: 0.0
  fill_um: 6.0
  line_space_um: 2.0
  pair_metal_um: 0.0
```

`Metal2_ignore_active` is not ours. It is set by the template today (with the Metal2 density
rationale in its own comment in `librelane/config.yaml`), our script passes it on to the foundry
`fill_metal.rb` unchanged, and dropping it would change the metal pattern the flow ships.

## Reproducing a measurement

Container side. The image's entrypoint is what puts `klayout` on PATH, so pass the script as the
container *command* (`docker run --rm -v <host>:/work ghcr.io/wafer-space/gf180mcu-precheck
/work/fill/check.sh`) — not through `--entrypoint bash`, which bypasses the nix development shell.
Inside it, on the flow's own pre-fill GDS:

```
klayout -b -zz -r fill_active.rb -rd input=<pre-fill>.gds -rd output=filled.gds \
        -rd Metal2_ignore_active=true
klayout -b -zz -r check_active_density.rb -rd input=filled.gds
klayout -b -zz -r /workspace/gf180mcu/gf180mcuD/libs.tech/klayout/tech/drc/gf180mcu.drc \
        -rd input=filled.gds -rd topcell=chip_top -rd report=out.lyrdb \
        -rd decks="dummy_comp,dummy_poly2,comp,poly2,density" \
        -rd variant=gf180mcuD -rd run_mode=deep -rd threads=6
```

The deck run is the acceptance test: it prints `DRC RESULT: SUCCESS (0 violations)` or a per-rule
count, and `dummy_comp` is the one that catches a bad stagger (DCF.2b). `--scripts
grep -a "DRC RESULT\|violation(s)"` keeps it readable; the full run over five decks took 31 min.

## What the fill does *not* fix, and does not add

The deck's base `comp` and `poly2` rule decks fail on this design with or without any dummy fill,
and the counts are the same set either way: the **unfilled** pre-fill GDS gives `DRC RESULT:
FAILURE (3329 violations)` — DF.11 16, DF.13_MV 257, DF.16_MV 320, DF.17_MV 66, DF.1a_MV 16,
DF.2a_MV 249, DF.3a_MV 185, DF.3b 396, DF.4c_MV 333, DF.4d_MV 199, DF.6_MV 272, PL.1_MV 2,
PL.2_MV 142, PL.3a 80, PL.4_MV 157, PL.5a_MV 195, PL.5b_MV 195, PL.6 249 (`fillrun5.log`) — and
the filled die reports that same list with DCF.2b added only where the stagger was illegal. Those
3,329 are the core's own geometry, not the fill's: the fill's two decks (`dummy_comp`,
`dummy_poly2`) are clean, which is the set of rules dummy COMP and dummy Poly2 can break. Fixing
the core's DF/PL set is a separate piece of work.

## Residual risk

* **Poly2 is now 26.25 % of the die against a 14 % floor.** No rule caps Poly2, and every shape
  sits over dummy COMP by DPF.1's construction, but this is a large amount of dummy poly over dummy
  active and sitting 12 points above the floor is a *choice*. It is one parameter to trade down
  (`fill_um`, or a `pair_metal_um` between 0 and 2).
* **DCF.2b is the rule to re-check after any pattern change.** The pattern's own spacing is now
  printed and warned about by `fill_comp_active.rb`, and the deck is the authority.
* **The fill is only as good as the deck version it was measured against.** All of the above is the
  gf180mcuD deck as shipped in the pinned pre-check image. A different deck (`-rd variant=`) or a
  different PDK revision can re-enable rules; `pair_metal_um` and the pattern parameters are where
  that shows up.
* **DPF.1 pairing is per-square.** A dummy COMP square with no Poly2 partner is legal (DPF.1 forbids
  the reverse), so the 1.8 % of pairs dropped by the checked halos are left as bare dummy COMP.
  That is deliberate, and it is why the COMP number is insensitive to the pairing decision.
