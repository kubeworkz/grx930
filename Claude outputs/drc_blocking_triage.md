# The 12,202 blocking KLayout DRC violations, ranked and attributed

Date: 2026-10-16. Input: the run2 tally committed at
[`evidence_run2/klayout_drc.klayout.json`](evidence_run2/klayout_drc.klayout.json) — the artifact is
the template flow's `chip_top.gds` (160,256,792 B, sha256 `764c79ba…`, 3932 × 5122 µm, run tag
`tpl02`). Rule meanings come from the PDK deck that produced the tally; the ranking is reproducible
with [`../../c930/asic_gf180mcu/tools/drc_tally_rank.py`](../../c930/asic_gf180mcu/tools/drc_tally_rank.py).

**The one-line answer.** The gate is not 83,777 items and it is not a long tail: it is **70 rules
carrying 12,202**, of which **20 rules carry 70.8 %** and **4 rule families carry 72.3 %**. Almost
all of it is FEOL — every `M2`–`M5` and `via1`–`via4` rule is zero — and 74.4 % of it is the
spacing/enclosure class, which is exactly the class a 1–4 nm grid error decides.

## 1. The ranking

`*_OFFGRID` (71,575) is set aside as advisory; the numbers below are over the 12,202 that block.

| # | rule | count | share | cum | class | what the deck says the rule is |
|---|---|---|---|---|---|---|
| 1 | `M1.2a` | 1,265 | 10.4 % | 10.4 % | spacing | min. metal1 spacing |
| 2 | `CO.1` | 558 | 4.6 % | 14.9 % | size | Min/max contact size 0.22 µm (implemented as *every drawn contact edge exactly 0.22 µm*) |
| 3 | `PP.5dii` | 552 | 4.5 % | 19.5 % | enclosure | P+ extension beyond COMP, outside DNWELL |
| 4 | `CO.10` | 546 | 4.5 % | 23.9 % | **structural** | Contact on Poly2 gate over COMP **is forbidden** |
| 5 | `CO.2a` | 530 | 4.3 % | 28.3 % | spacing | min. contact spacing 0.25 µm |
| 6 | `PP.5b` | 419 | 3.4 % | 31.7 % | enclosure | P+ extension beyond COMP (inside NWELL / outside LVPWELL) |
| 7 | `DF.3b` | 396 | 3.2 % | 35.0 % | structural | NCOMP↔PCOMP space in the same well for **butted** COMP |
| 8 | `PP.3d` | 391 | 3.2 % | 38.2 % | spacing | min/max space to a **butted** NCOMP: **0 µm** |
| 9 | `NP.3d` | 381 | 3.1 % | 41.3 % | spacing | min/max space to a **butted** PCOMP: **0 µm** |
| 10 | `NW.4` | 373 | 3.1 % | 44.3 % | spacing | Min. **Nwell to LVPWELL space: 0 µm** |
| 11 | `NP.5b` | 369 | 3.0 % | 47.4 % | enclosure | N+ extension beyond COMP (inside LVPWELL / outside Nwell) |
| 12 | `PP.3e` | 350 | 2.9 % | 50.2 % | spacing | space to NCOMP edge adjacent to a **butting** edge: 0 µm |
| 13 | `NP.5dii` | 344 | 2.8 % | 53.1 % | enclosure | N+ extension beyond COMP, inside Nwell |
| 14 | `NP.3e` | 341 | 2.8 % | 55.9 % | spacing | space to related PCOMP edge adjacent to a butting edge: 0 µm |
| 15 | `DF.4c_MV` | 333 | 2.7 % | 58.6 % | enclosure | Min. Nwell overlap of PCOMP outside DNWELL: 0.6 µm (5V) |
| 16 | `LPW.12` | 330 | 2.7 % | 61.3 % | **structural** | **LVPWELL cannot overlap with Nwell** |
| 17 | `DF.16_MV` | 320 | 2.6 % | 63.9 % | spacing | Min. space Nwell→NCOMP outside Nwell: 0.6 µm (5V) |
| 18 | `CO.3` | 315 | 2.6 % | 66.5 % | enclosure | Poly2 overlap of contact: 0.07 µm |
| 19 | `DF.6_MV` | 272 | 2.2 % | 68.7 % | enclosure | Min. COMP extend beyond gate (source/drain overhang): 0.4 µm (5V) |
| 20 | `DF.13_MV` | 257 | 2.1 % | 70.8 % | size | Max distance of Nwell tap from PCOMP inside Nwell: 15 µm (5V) |

Cumulative: **top 1 = 10.4 %, top 5 = 28.3 %, top 10 = 44.3 %, top 20 = 70.8 %, top 35 = 91.4 %.**
Rules 36–70 are 1,048 items between them (8.6 %) and are not a work list; rules 2–4 are.

## 2. By family and by class

| family | rules | count | share |
|---|---|---|---|
| Contact (size, spacing, enclosure, forbidden placement) | 11 | 2,327 | 19.1 % |
| COMP butt/diffusion (NCOMP vs PCOMP, channel dimensions) | 11 | 2,309 | 18.9 % |
| P+ implant (pplus) | 15 | 2,250 | 18.4 % |
| N+ implant (nplus) | 14 | 1,935 | 15.9 % |
| Metal1 | 2 | 1,303 | 10.7 % |
| Poly2 | 7 | 1,020 | 8.4 % |
| Nwell | 6 | 621 | 5.1 % |
| LVPWELL | 1 | 330 | 2.7 % |
| Dualgate | 3 | 107 | 0.9 % |

| gate class | rules | count | share |
|---|---|---|---|
| spacing | 28 | 5,693 | 46.7 % |
| enclosure | 20 | 3,376 | 27.7 % |
| **structural** (forbidden construct) | 6 | 1,731 | 14.2 % |
| size | 12 | 981 | 8.0 % |
| dimension (channel W/L) | 3 | 407 | 3.3 % |
| other | 1 | 14 | 0.1 % |

Device flavour: `_MV` (5 V/6 V) **2,710 (22.2 %)**, `_LV` (3.3 V) 126 (1.0 %), unscoped 9,366 (76.8 %).

## 3. Root causes, group by group

Each group below names the evidence it rests on and the confidence it deserves.

### 3a. The implant / COMP / well / Poly2 stack at device and butting edges — 7,445 items (61 %)

The stack families: P+ 2,250 + N+ 1,935 + COMP/DF 2,309 + Nwell 621 + LVPWELL 330 (**7,445, 61.0 %**),
and 8,465 (69.4 %) once Poly2's 1,020 is added — the same physical stack. The heaviest rules inside
it are `PP.5dii`, `PP.5b`, `DF.3b`, `PP.3d`, `NP.3d`, `NW.4`, `NP.5b`, `PP.3e`, `NP.5dii`, `NP.3e`
and the `_MV` cluster `DF.4c/16/6/13/2a/3a/4d/17`, `PL.2/4/5a/5b`, `NW.2a/b`. The deck's own wording
for them is a relationship at a **device or butting edge** — "extension beyond COMP", "space to a
butted COMP: 0 µm", "Nwell overlap of PCOMP", "90° bends on the COMP", "Min Channel Width".

Two measured facts make this group coherent rather than a list:

* The flow was run with **`--scl gf180mcu_fd_sc_mcu7t5v0`, the 5 V standard-cell library**, and the
  pad ring is `gf180mcu_fd_io`. So the whole core is 5 V device area, and the deck's `_MV` rules
  govern it. Checking that the scope claim is real, not assumed: the standard-cell library itself
  draws the `dualgate` marker (layer 55/0 — measured present, 2,290 coordinate pairs), which is what
  the deck scopes its 5 V rules by.
* The **5V/6V rules are the stricter set**, and they apply die-wide rather than at a few 5 V
  islands: `DF.4c_MV` wants 0.6 µm of Nwell overlap, `NW.2b_MV` wants 1.7 µm of well-to-well space.

Confidence: **high on the scope** (`--scl` is in the recorded command; the marker layers are in the
tally as `dualgate_OFFGRID`/`v5_xtor_OFFGRID` and are present in the library), **medium on
per-item attribution** — see §5 for why the tally cannot settle the last mile.

### 3b. The contact family — 2,327 items (19.1 %), and a negative result that matters

`CO.1` 558 (size), `CO.2a` 530 (spacing), `CO.10` 546 (forbidden), `CO.3` 315 (enclosure), `CO.7` 236,
`CO.4` 74, `CO.8` 40, `CO.2b` 12, `CO.9` 14, `CO.6a/b` 2.

`CO.1` is worth reading in the deck, because its implementation is not what its name suggests:

```ruby
co1_l1 = contact.edges.without_length(0.22.um)     # rule_decks/contact.rb
```

With the deck's **default `run_mode: 'deep'`** (`options.rb`, `DEFAULTS`) `generic_layers.rb` does
**not** merge (`merge = (ctx.options.run_mode != 'deep')`). So `CO.1` is: *every drawn contact edge
that is not exactly 0.22 µm, one item each*.

This depends on the run not having overridden `run_mode`, so it is worth saying exactly how far the
evidence goes: neither the PDK's `libs.tech/librelane/config.tcl` (which sets `decks` and `variant`
only) nor the template's `librelane/config.yaml` (`decks`, `variant`, `workers`) passes one. That is
the config side, and it is what the flow log's `decks: all,-antenna,-density,-cup` line is
consistent with; the DRC step's own argument line lives in `14-klayout-drc/klayout-drc.log` on the
box and I could not read it from here. If it turns out to carry `-rd run_mode=flat`, `CO.1` would
instead fire on *merged* contact islands (i.e. on contact arrays), which would move attribution but
not the count.

I then measured the libraries rather than assuming, with
[`drc_lib_exposure.py`](../../c930/asic_gf180mcu/tools/drc_lib_exposure.py) (klayout.db, layer 33/0,
as drawn):

| library | drawn contact polygons | polygons failing the exact-edge test |
|---|---|---|
| `gf180mcu_fd_sc_mcu7t5v0.gds` (230 cells) | 8,782 | **0** |
| `gf180mcu_fd_io.gds` (657 cells) | 63,209 | **0** |
| `gf180mcu_fd_ip_sram__sram128x8m8wm1.gds` (600 cells) | 18,995 | **0** |

**The foundry's own cells draw contacts at exactly 0.22 µm, 90,986 polygons of them, none failing.**
So `CO.1`'s 558 items are *not* inherited library geometry. This is also where a tempting but wrong
explanation dies: the pad ring and the SRAM macros really are off the 5 nm grid (§3e), but an
off-grid **position** cannot change a shape's **width**, so grid error alone cannot manufacture a
size violation. The 558 are contacts the flow drew, altered, or merged — and `CO.10` (546, a
forbidden construct) and `LPW.12` (330, a forbidden overlap) sit in the same bucket of "geometry
that exists and should not", which snapping cannot fix.

### 3c. Metal1 spacing — 1,303 items (10.7 %)

`M1.2a` 1,265 (min spacing 0.23 µm), `M1.1` 38 (min width). Two eliminations, both from the tally:

* **Not the filler.** `KLayout.Filler` fills all five metals; `M2.*`–`M5.*` are all zero.
* **Not route/via geometry in general.** Every `via1`–`via4` rule is zero and every `M2.2a`-style
  spacing rule is zero. Whatever it is, it is metal1-specific.

That leaves metal1 geometry drawn by cells, the PDN straps, and cell abutment — i.e. the class where
a 1–4 nm relative offset decides pass/fail.

Group 3d below overlaps this one by construction: it is a *mechanism* cut across the same families,
not a fourth disjoint pile, and the two are not meant to be added.

### 3d. The forbidden constructs — 1,731 items (14.2 %), the group that cannot be grid error

`CO.10` 546 (contact on a Poly2 gate over COMP), `DF.3b` 396, `LPW.12` 330 (LVPWELL ∩ Nwell),
`PL.6` 249 (90° bends on the COMP), `NP.12` 124 + `PP.12` 86 (implant over the *opposite* gate
extension within 0.32 µm) — 1,731 items by the wording test, plus `CO.9` (14, "contact must not
straddle a butting edge") which is the same construct. A topological overlap or a forbidden
placement is not moved by
a nanometre of grid, so these need a geometry review and they will not shrink when the layout snaps.
They are also the group most likely to be a *deck-vs-library* interaction rather than a design bug —
`LPW.12` plus `NW.4` (0 µm Nwell↔LVPWELL space) are the two faces of one well-boundary relationship
firing 703 times.

### 3e. The reason to be careful: the artifact and wafer.space's own reference are the same grid case

Measured here, on the files in this repo (the same linear GDS scan as the run2 off-grid finding,
[`gds_grid_scan.py`](evidence_run2/gds_grid_scan.py) — whose dbu line I fixed while doing this: it
decoded the GDSII excess-64 real as IEEE and printed `0.000 nm`; the counts were never affected,
and the corrected line reads `dbu=1.000 nm`, which is what makes `coord % 5` mean "5 nm"):

| layout | coordinate pairs | off the 5 nm grid | dominant owner |
|---|---|---|---|
| run2 artifact (`tpl02` output) | 9,312,368 | 6,020,091 (64.65 %) | `sealring$1` 4,370,396 |
| **`tools/gf180mcu-example-layouts/5v/1x1/chip_top.oas`** (wafer.space's 1×1 reference) | 9,345,640 | **6,038,101 (64.61 %)** | **`sealring$1` 4,370,396** |

The reference layout carries the *identical* seal-ring off-grid count and the same per-layer profile
(contact `33`, via1–via4 `35/38/40/41`, then metal1 `34`). It is off the grid to the same 64.6 % —
and it is the layout wafer.space calibrates the gate with (§3 of the status note: it *passes* the
pad mask). The two are the same design family — the template's pad-ring wrapper plus a small
synthesized placeholder core (artifact 1,714 cells, reference 1,746) — and the agreement above is
aggregate: total coordinate count within 0.4 %, the identical seal-ring off-grid count, and the same
per-layer profile. A file-level xor would need the artifact GDS, which lives on the flow box, not
here; the claim is "the same grid condition", not "the same layout".

**What follows:** the off-grid family is a wafer.space-wide property this project inherits whatever
it does, and the *marginality* that the spacing/enclosure classes (74.4 % of the 12,202) express is
the same condition at a smaller amplitude. It follows that the honest next question is not "how do
we fix 12,202 items" but "what does this deck report on wafer.space's own reference layout".

Two hypotheses remain live for that, and one measurement separates them:

* **Inheritance.** If the deck reports ~12 k blocking items on the reference layout too, the 12,202
  is a property of wafer.space's template/example plus their deck, and the deliverable is a bug
  report to them, not 12 k fixes here.
* **Design-side.** If the reference comes back clean and this layout does not, the 12,202 is ours —
  and §3a/§3d are the work list.

## 4. Root cause above the geometry: nothing ever DRC'd this layout

This is not a metaphor. In `tpl02` the flow's own DRC/LVS steps were **stopped** because the precheck
runs DRC too (status note §1b: step `93-klayout-density` "killed mid-step; the flow's own DRC/LVS
were stopped because the precheck runs them too"). So the first DRC deck ever run on this layout was
the precheck's, on the *post-filler, post-seal-ring* GDS, and the artifact is the **template's
placeholder core**, not GRX930. Two consequences worth stating plainly:

* the 12,202 are first-pass results, not a regression, and nothing in the flow's own gate chain ever
  saw them;
* they describe the *wrapper plus a placeholder core*. The GRX930 core is a different netlist, so
  (§3a/§3d) the numbers do not transfer — the *kinds* do.

## 5. What would settle the open half, in order of cost

1. **The reference layout through the deck.** The precheck already reached the Design Rule Checks
   stage on `chip_top.oas` before a host restart tore it down. Re-running it (with `--skip
   KLayout.CheckPadMask` to save the hours) answers the inheritance question of §3e directly.
2. **The per-item report.** `run2/drc_peek/drc.klayout.lyrdb` on the box is 26 MB with one item per
   violation and coordinates; the committed tallies are counts only, which is the single reason the
   last mile of §3 is inference. Clustering item bboxes by instance splits "inside a shipped library
   cell" from "drawn by the flow" per rule — and settles `CO.1` (are those 558 inside library cells
   or not) and `M1.2a` the same way.
3. **Snap and re-run.** Write the artifact with 5 nm snapping and re-run the deck. The prediction
   from §2 is falsifiable and specific: most of the spacing/enclosure 74.4 % moves, the structural
   14.2 % and the size 8.0 % do not. If that prediction fails, the grid story is not the story.

## 6. Limitations of this analysis

* The tally has counts only — no coordinates, no cells. Everything below a rule's own text is
  inference, and §3 says which parts are which.
* The local PDK copies are `gf180mcuA`; the run used `gf180mcuD`. The rule decks are identical
  (`rule_decks/contact.rb` md5 `a24fac53b450cd82a184a478f48073d7` in every local copy), so the
  descriptions and the `CO.1` implementation are the run's, but this is not a byte-identical PDK.
* No DRC engine on this box: `klayout` 0.30.12 is present as a Python module only (`klayout.db`),
  with no `klayout.drc`, no `Region#space`, no `Edges#without_length`, and no CLI. Rules could
  therefore be *re-implemented* (as in §3b) but not re-run.
* The `run_mode` the precheck's DRC step actually used is inferred from the PDK and template
  configs plus the deck's default, not read from that step's log (§3b).
* The reference-layout grid numbers come from a `.oas` re-streamed to GDS by `klayout.db`; the
  writer does not snap, and the off-grid counts agree with the run2 artifact's to 0.04 %, so the
  conversion is not doing the work.
* `drc_tally_rank.py` resolves 551 of 737 reported rule names and **70 of 70 of the non-zero ones**.
  Every unresolved name has a zero count — the tool prints any unresolved rule that *does* carry a
  non-zero count, and it prints none — so no meaning in §1 or §2 is borrowed from a name the deck
  does not define.
