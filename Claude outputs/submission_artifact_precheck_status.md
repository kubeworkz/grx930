# Submission artifact produced, and what the wafer.space precheck says about it

Date: 2026-10-15 (local box, run 13:50 → 23:00 UTC). Asked: *produce the submission artifact — run
the LibreLane template flow with CTS to get `chip_top.gds`, then run the wafer.space precheck on
it and report what it says.*

**2026-10-16 update — both precheck runs are finished.** The pad-mask-skipped scan (§2d) ran to the
end at 11:12 UTC and produced verdicts for density, zero-area, antenna, Magic DRC and KLayout DRC
(§2e), including an off-grid finding that matters more than the pad mask does: 85 % of the 83,777
KLayout DRC errors are one `*_OFFGRID` family, and the artifact is 65 % off the 5 nm grid by
construction. The precheck has **no LVS stage**; that claim in the first version of this note was
wrong.

**2026-10-16 correction — `*_OFFGRID` is a critical warning, not a hard blocker.** wafer.space
rules the off-grid family advisory, so the DRC gate's real failure count on this artifact is not
83,777 but **12,202** (83,777 − 71,575), and the grid-snap item in §4 moves off the critical path.
Encoded in `c930/asic_gf180mcu/tools/precheck_verdict.py`: the split is applied only to what a
per-rule tally accounts for and only in `--run-dir` mode, so a truncated or log-only reading still
counts every violation as blocking. Every measurement below is unchanged — the 83,777 and the
71,575 are what the deck reported; only their weight changed.

## Verdict

Both halves are done, and the precheck's answer is **specific and actionable**:

* The shipped gf180mcu project template, run in the pinned wafer.space image, **does** produce a
  `chip_top.gds`: CTS, detailed routing, fill, stream-out, seal ring and filler insertion all
  complete. Artifact: 160,256,792 B, `md5 bf9b7cb08b415c3c6d8cd9bbe0df89b4`, **3932.000 × 5122.000 µm**.
* The precheck **passes its first three stages and stops at the fourth**:

  | # | stage | result |
  |---|---|---|
  | 1 | Read the Layout | pass |
  | 2 | Check Top-Level Name | pass |
  | 3 | Check Slot Size | **pass** — origin (0,0), dbu 0.001, no Via5/MetalTop, `GUARD_RING_MK` (167/5) present, size 3932.0 × 5122.0 |
  | 4 | Check Pad Mask (`--cob`) | **FAIL — pad mask does not match** |
  | 5-16 | Generate ID → density → zero-area → antenna → Magic DRC → KLayout DRC → Write the Layout | not run in *this* run (it stops at the first failure); they were measured by the pad-mask-skipped scan (§2d/§2e): **two gates fail — global active-layer density, and the KLayout DRC deck on an off-grid layout** |

* The pad-mask failure is measured, not vague: **every one of the 74 pad openings sits 0.5 µm
  inside the golden mask's opening** (artifact centres x = 525.5, 705.5, 885.5 … vs mask 526.0,
  706.0, 886.0 …), so KLayout's xor reports 34 slivers of 0.5 × 60 µm² per side — 68 polygons
  against a tolerance of zero. The 162,302 µm² central opening matches exactly.
* **A second run with only the pad-mask stage skipped measured the rest, and it is finished**
  (§2d/§2e). On the same artifact: top-level name, slot size, ID generation, render, **zero-area
  polygons (0)** and **antenna (0 on every `ANT.*` rule)** pass; **Density Check fails on the two
  minimum-density rules** — `DCF.1b` COMP 20.18 % against a 25 % floor and `PL.8` Poly2 12.99 %
  against 14 % — with every metal band passing; **Magic DRC reports 12,772 errors at warning
  level (not a gate)**; and **KLayout DRC fails with 83,777 violations over 737 rules**, of which
  71,575 (85 %) are `*_OFFGRID` — geometry off the 5 nm manufacturing grid (65 % of the artifact's
  coordinates, 4.37 M of them in `sealring$1`). The precheck has **no LVS stage** at all;
* This is the *wrapper*, not the core: `chip_top.sv`, `slot_1x1.yaml`, `config.yaml` and
  `macros_5v.yaml` are the template **unmodified**, i.e. the same pad ring, slot defines, seal
  ring, ID cells and die size that the real GRX930 submission will use. The precheck's stage-3
  pass therefore transfers to the real chip; the pad-mask failure transfers too, and it has to
  be fixed before any CoB submission.

## 1. The artifact

### 1a. How it was produced

The template was driven directly in the same image the flow box uses
(`ghcr.io/wafer-space/gf180mcu-precheck`, LibreLane 3.1.0.dev1), template tree copied to
`/home/kubew/tplrun`, run tag `tpl02`, container capped at 4 GiB:

```
librelane --pdk gf180mcuD --pdk-root /workspace/gf180mcu --manual-pdk \
  --scl gf180mcu_fd_sc_mcu7t5v0 --pad gf180mcu_fd_io \
  --run-tag tpl02 --save-views-to /work/final \
  librelane/slots/slot_1x1.yaml librelane/macros/macros_5v.yaml librelane/config.yaml
```

Three environment facts had to be fixed to drive the flow without the template's `Makefile`
(each is supplied for free by that Makefile, which is why they are easy to miss):

* the driver script must be `#!/bin/sh`, not `#!/bin/bash` — the image's `dev-shell` wraps the
  command in a nix shell where `/bin/bash` does not exist (`bad interpreter`);
* `SRAM_DEFINE` (and `SLOT`) must be exported — `pdn.tcl` reads `::env(SRAM_DEFINE)` and the flow
  aborts at PDN with *"can't read `::env(SRAM_DEFINE)`: no such variable"*;
* `--run-tag` and `--last-run` are **mutually exclusive**, and `--skip <step>` **rewrites the flow
  definition**, which makes LibreLane start a fresh pass (a second copy of every step, renumbering
  from the current counter) instead of continuing. To disable a step on a resume, use its config
  flag (`-c RUN_<STEP>=false`), not `--skip`.

### 1b. The one step that does not scale: IR drop

Step 55 `OpenROAD.IRDropReport` (PDNSim on the full 1×1 die: pad ring + PDN + 460 k instances)
**ran 6 h 20 m of wall clock for 1 h 46 m of CPU and never wrote a line of its report** — it
thrashed the container's 4 GiB cap rather than converging. It is not needed for the GDS and the
precheck does not read it, so it was switched off by config
(`--override-config RUN_IRDROP_REPORT=false`; `classic.py` maps `RUN_IRDROP_REPORT` to that step)
and the flow resumed from it with `--from OpenROAD.IRDropReport`. Everything else ran as shipped.

Path of the resumed tail, from the run directory (`run tag tpl02`):

| step | what it produced |
|---|---|
| `34-openroad-cts` | clock tree synthesis (CTS) |
| `43-openroad-detailedrouting` | detailed routing |
| `51-openroad-fillinsertion` | metal fill |
| `84-klayout-streamout` | `chip_top.gds` 36,141,368 B (route + fill, **no seal ring yet**) |
| `85/86-klayout-xor` / `checker-xor` | Magic-vs-KLayout xor: **19,880 differences, deferred** |
| `89/87-klayout-antenna` | antenna check |
| **`90-klayout-sealring`** | `chip_top.gds` 76,059,364 B — `GUARD_RING_MK` stamped |
| `91-klayout-render` | layout render |
| **`92-klayout-filler`** | `chip_top.gds` **160,256,792 B** — seal ring + filler, the artifact used below |
| `93-klayout-density` | density check (killed mid-step; the flow's own DRC/LVS were stopped because the precheck runs them too) |

Note the ordering, because it is easy to get wrong: in the **Chip** flow the stream-out happens
*before* the seal ring. `KLayout.StreamOut` writes an unsealed GDS; `KLayout.SealRing` stamps
`GUARD_RING_MK` into it afterwards (`chip.py`: `+Checker.KLayoutAntenna: KLayout.SealRing`), and
`KLayout.Filler` then inserts the fill. The submission-shaped file is therefore the *last*
GDS-writing step's output, not the stream-out.

### 1c. Where the files are

| file | size | md5 |
|---|---|---|
| `/home/kubew/submit/run1/chip_top.gds` (= `…/tpl02/92-klayout-filler/chip_top.gds`) | 160,256,792 | `bf9b7cb08b415c3c6d8cd9bbe0df89b4` |
| `/home/kubew/submit/chip_top_template_sealring_only.gds` (= `…/90-klayout-sealring/chip_top.gds`) | 76,059,364 | `9fb1f1240488abd07422fe1c49cb7381` |

Measured directly from the file (KLayout, `mask_layers.rb` / `gds_probe.rb`): dbu 0.001, 1714
cells, 49 layer entries, bounding box `(0,0) … (3932,5122)`, size 3932.000 × 5122.000 µm, and
`GUARD_RING_MK` (167/5) present. Both numbers agree with the precheck's own stage 3.

## 2. What the precheck says

### 2a. The run

```
docker run --rm --user 0:0 -v /home/kubew/submit:/host ghcr.io/wafer-space/gf180mcu-precheck \
  dev-shell bash -lc 'cd /workspace && python3 precheck.py --slot 1x1 --cob \
    --input /host/run1/chip_top.gds --id GRX93001 --threads 4 --workers 4 \
    --run-tag run1 --output /host/run1/chip_top_checked.oas'
```

**The expected top-cell name comes from the input file name.** The first attempt
(`chip_top_template.gds`) failed stage 2 with *"Top-level cell name 'chip_top' does not match
expected name"* because `check_top.py` is called with `--top <basename minus extension>`. The
artifact must be named `chip_top.gds` (or `--top` supplied).

Four of the flow's 17 stages ran, in this order (from the run directory and the log):
`01-klayout-readlayout`, `02-klayout-checktoplevel`, `03-klayout-checksize`,
`04-klayout-checkpadmask` — then the flow aborted (`precheck.py:618`). The full stage list, from
the reference run in §3: Read the Layout · Check Top-Level Name · Check Slot Size · Check Pad Mask
· Generate ID · Render Image · Density Check · KLayout Density Checker · Find Zero Area Polygons ·
KLayout Zero Area Polygons Checker · Antenna Check · KLayout Antenna Checker · Design Rule Checks
… (17 in total).

### 2b. Stages 1-3: everything the wrapper has to get right, it gets right

`check_size.py` is the whole of stage 3, and it passed on all five of its clauses:

* origin at (0,0) — the die is placed at the slot origin;
* dbu = 0.001;
* `Via5` (82/0) and `MetalTop` (53/0) unused → the **5LM** stack, as wafer.space requires;
* `GUARD_RING_MK` (167/5) non-empty → **the seal ring is present** (this is the check that errors
  with *"wafers.space requires a seal ring (guard ring) around the die"*);
* layout width/height = 3932.0 × 5122.0 → the 1×1 slot exactly.

So the output the template ships — pad ring, slot defines, seal ring, die size — is accepted by
the precheck. That is the part that carries over to the real GRX930 die unchanged.

### 2c. Stage 4: the pad mask fails, by 0.5 µm

`check_mask.drc` compares the artifact's layer **37/0** (the pad/passivation openings) with
`assets/golden_masks/mask_1x1.gds` and requires the mask to be **covered**:

```ruby
mask = mask_layout.input(37, 0)
xor_result = input(37, 0).and(mask).xor(mask)     # extra openings are allowed, missing ones are not
```

Same geometry, same layer, same *number* of openings, same areas — and still a failure, because
the openings are shifted:

| | mask 37/0 | artifact 37/0 |
|---|---|---|
| polygons | 75 | 75 |
| bbox | 3.0,3.0 … 3929.0,5119.0 | 3.0,3.0 … 3929.0,5119.0 |
| first openings, centre x | 526.0, 706.0, 886.0, 1066.0 … (60 µm wide, 180 µm pitch) | **525.5, 705.5, 885.5, 1065.5 …** |
| largest opening | 162,302 µm² (centre) | 162,302 µm² — **matches exactly** |

The set difference is 34 slivers on each edge of the ring, each 0.5 × 60 µm² = 30 µm², total xor
68 polygons, bounding box 555.5,28.0 … 3436.0,5094.0. In other words: **the ring's openings are
0.5 µm outside the mask's at one end and 0.5 µm inside at the other — the template's pad ring is
1 µm wider in its opening span than the golden mask.** The central opening is unaffected, which is
why a naive area/count check would call the two layers identical.

Two candidate causes, both worth one look before touching anything:

1. the pad positions produced for this slot in the template's `librelane/slots/slot_1x1.yaml`
   (the pad list and its offsets, consumed by the `OpenROAD.PadRing` step) differ from the mask's
   by 0.5 µm at the ring's ends — i.e. a rounding/centring difference in the ring arithmetic
   (the template's `scripts/padring.py` is only a driver; it prints paths and calls the flow);
2. or the golden mask was generated from wafer.space's **reference** layout (§3: the reference
   *passes* this check) and the template's ring has drifted since.

Either way the fix is on the design side, and it must be settled before an 8-character ID is
requested, because the precheck stops at this stage for every CoB layout.

### 2d. Running past the mask: the stages behind it (run2)

`precheck.py` takes `--skip`, so the same artifact was re-run with **only** the pad-mask stage
skipped (`--skip KLayout.CheckPadMask`, run tag `run2`, same flags, same 160 MB GDS). Log:
`/home/kubew/submit/run2/precheck_ws.log`; run directory: `docker cp
ws-precheck2:/workspace/runs/run2/. <dir>`.

| stage | result |
|---|---|
| Read the Layout | pass |
| Check Top-Level Name | pass — *"Design name 'chip_top' matches top-level cell"* |
| Check Slot Size | pass — *"Layout dimension matches the selected slot size 1x1"* |
| Check Pad Mask | skipped (that is the stage §2c fails) |
| Generate ID | pass — an 8-character ID (`GRX93001`) is accepted |
| Render Image (w/ KLayout) | pass |
| Density Check | **FAIL — `DRC RESULT: FAILURE (2 violation(s))`** |
| KLayout Density Checker | 2 errors, *deferred* |
| Find Zero Area Polygons | **pass** — `klayout__zero_area_polygons__count 0` |
| KLayout Zero Area Polygons Checker | pass |
| Antenna Check | **pass** — `DRC RESULT: SUCCESS (0 violations)`, 01:08 UTC, `klayout__antenna_error__count 0` |
| KLayout Antenna Checker | pass — *"Check for KLayout antenna errors clear"* |
| Magic.DRC | **12,772 errors — warning level, not a gate** (`magic__drc_error__count 12772`, 01:08 → 01:57 UTC, report at `12-magic-drc/reports/drc.magic.rpt`, 11,694 items in the lyrdb: `M1.2a` 3,051, `PL.5a` 1,749, `CO.7` 909, `DF.3a` 653, `CO.2a` 650 …) |
| KLayout DRC | **FAIL, deferred — 83,777 violations over 737 rules**, 01:57:15 → 11:12:25 UTC (§2e) |
| Write the Layout | ran (stage 17 of 17); the flow then raised the deferred-error exception |
| Netgen LVS | **no such stage exists in the precheck** — see §2e |

Stage durations on this box, measured: read/name/size/ID/render 23:38 → 23:43 (~6 min), density
23:44 → 00:02 (19.4 min), zero-area 00:02 → 00:04 (2.3 min), antenna 00:04 → 01:08 (**64 min**,
~12 per-layer decks), Magic DRC 01:08 → 01:57 (49 min), KLayout DRC 01:57 → 11:12 (**9 h 15 m**,
`Total Run time 33274.9 s` in `klayout-drc.log`). So the whole pad-mask-skipped scan is an
**11.5 h** job on this 6-core box, and 80 % of that is the KLayout DRC deck. The container exits
**0** on failure, so the verdict has to be read out of the log.

One non-issue worth recording so nobody chases it: while Magic loads the layout for DRC it prints
172 `Error while reading cell "…" (byte position …): Warning: cell "…" placed on top of itself.
Ignoring the extra one.` lines (the `M2_M1$$…` / `M2_M1_CDNS_…` cells inside PDK and SRAM
hierarchies). Magic keeps reading and the stage proceeds; the wording says *Warning*, and the
same cells appear in the reference layout. It is reader noise, not a finding.

The two density failures are **minimum-density** shortfalls, and they are the *lowest* ratios the
die has — the ones the template's filler does not touch (it fills metals, not active layers):

| rule | bound (PDK `rule_decks/density.rb`) | artifact | reference layout |
|---|---|---|---|
| `DCF.1b` | COMP + dummy COMP **>= 25 %** | **20.18 %** → violation | 46.33 % |
| `PL.8` | Poly2 coverage **>= 14 %** | **12.99 %** → violation | 36.15 % |
| `DCF.1d` | COMP <= 70 % | 20.18 % pass | — |
| `M1.4` … `M5.4` | metal density bands | 31.94 / 42.20 / 47.99 / 51.45 / 43.83 % — all pass | 43.82 % (M1) |

Every bound in that table was read out of the PDK deck itself
(`gf180mcuD/libs.tech/klayout/tech/drc/rule_decks/density.rb`, copied out of the run container):
*"Minimum global density for active layers (COMP+ Dummy COMP) shall be 25%"* (`DCF.1b`),
*"… shall be 70%"* (`DCF.1d`), *"Poly2 coverage over the entire die shall be 14%"* (`PL.8`),
`M1.4`/`M5.4` *">30%"*. The deck executes 8 density rules (`DCF.1b`, `DCF.1d`, `PL.8`,
`M1.4`–`M5.4`) and prints one ratio line per layer — COMP `20.182089`, Poly2 `12.992005`,
Metal1 `31.940925`, Metal2 `42.204256`, Metal3 `47.989206`, Metal4 `51.445670`, Metal5
`43.830877` — so the two failures are the only two below their floor.

So beyond the pad mask, the gate the artifact misses is *global active-layer density* — by 4.8
points on COMP and 1.0 point on Poly2 — and the metal bands clear comfortably because the flow's
`KLayout.Filler` ran. For the real die this is a floorplan/dummy question, not a wrappering one:
the core (or its dummy COMP / dummy Poly2) has to reach ≥ 25 % and ≥ 14 % on its own area.

The two violations are die-level rules, and both are reported against the **whole-die polygon**
(`0,0;0,5122;3932,5122;3932,0`), from the check's own report database
(`06-klayout-density/reports/density.klayout.lyrdb`, which carries the rule text, and the JSON
`{"DCF.1b": 1, "PL.8": 1, "total": 2}` — 2 items, nothing else):

| rule | PDK wording (from the lyrdb) |
|---|---|
| `DCF.1b` | *"Global density for active layers (COMP + Dummy COMP) shall be >= 25%"* |
| `PL.8` | *"Poly2 coverage over the entire die shall be 14%. Dummy poly2 lines must be added to meet the minimum poly2 density requirement"* |

That wording is the fix: the deck asks for **dummy COMP and dummy Poly2**, which is exactly what
the flow does not insert (its `OpenROAD.FillInsertion` fills metals, which is why the metal bands
pass). The report lists exactly these two items and nothing else (`total: 2`), so everything else
in the density deck — `DCF.1d` and the `M1.4` … `M5.4` metal bands — is clean. (Earlier notes of
mine read the flow's *"density check with 6 threads"* as "6 checks"; that "6" is the thread
count.)

> **Density: fix built and measured, not yet exercised inside a flow run.**
> `wafer_space_integration/fill/fill_active.rb` is now the script the flow's `KLayout.Filler`
> step runs (`KLAYOUT_FILLER_SCRIPT` in `grx930_overrides.yaml`). It keeps the foundry's metal
> fill untouched and replaces the active-layer half. On the same die with the same deck
> (`decks=dummy_comp,dummy_poly2,density`, `run_mode=deep`): **COMP + dummy COMP 31.274 %**
> (floor 25 %), **Poly2 + dummy Poly2 26.254 %** (floor 14 %), and **`DRC RESULT: SUCCESS
> (0 violations)`** — no DCF.2b trap. For comparison, the same deck on this section's artifact
> reads 19.874 % / 12.992 % and the two violations above. Every figure, and the runs they come
> from, are in `wafer_space_integration/fill/README.md` and its `evidence.md`. What is *not*
> done: those numbers are the fill applied to the flow's own pre-fill GDS, not a full template
> flow re-run followed by the pre-check — that is still the outstanding verification.

### 2e. The DRC verdict, and the off-grid finding (run2 finished 2026-10-16 11:12 UTC)

The skipped-mask run ran to the end — 16 stage banners (the skipped pad mask is the 17th), the last
being *Write the Layout* — and the flow then raised:

```
ERROR  The precheck failed with the following exception:
       One or more deferred errors were encountered:
       2 KLayout density errors found.
       83777 KLayout DRC errors found.
```

Both failures are *deferred*: the flow runs every stage and reports at the end, so the log (not an
exit code — the container exits **0**) is the artifact that has to be captured. As on the wrapper
side, the DRC deck that gates is **KLayout's**, not Magic's:

| check | deck and threads | verdict | evidence |
|---|---|---|---|
| KLayout DRC | `decks: all,-antenna,-density,-cup`, 4 threads | **FAIL — 83,777 violations over 737 rules** | `drc.klayout.json` (`{total: 83777, …}`) and `drc.klayout.lyrdb` (26 MB, 83,777 items), recovered from the stopped container into `run2/drc_peek/` |
| Magic DRC | full magic deck | 12,772 errors, **warning level — not deferred, not a gate** | `drc.magic.rpt`, lyrdb with 11,694 items |

Reports and scanner from this section are copied into the repo at `Claude outputs/evidence_run2/`
(`klayout_drc.klayout.json`, `density.klayout.{json,lyrdb}`, `zeroarea.klayout.json`,
`antenna.klayout.json`, `flow.log`, `gds_grid_scan.py`, and a README with the verdict table), so
none of it has to be re-measured off the box.

85 % of the KLayout violations are one family, `*_OFFGRID` — geometry that is not on the 5 nm
manufacturing grid:

| rule | violations | rule | violations |
|---|---|---|---|
| `metal1_OFFGRID` | 22,418 | `pplus_OFFGRID` | 2,316 |
| `contact_OFFGRID` | 22,268 | `nplus_OFFGRID` | 2,313 |
| `poly2_OFFGRID` | 8,361 | `lvpwell_OFFGRID` | 2,171 |
| `comp_OFFGRID` | 5,520 | `nwell_OFFGRID` | 2,138 |
| `v5_xtor_OFFGRID` | 2,020 | `dualgate_OFFGRID` | 2,050 |

What is left behind them is an ordinary tail: `M1.2a` 1,265, `CO.1` 558, `PP.5dii` 552, `CO.10`
546, `CO.2a` 530, `DF.3b` 396, `PP.3d` 391, `NP.3d` 381, `NW.4` 373 … It is not a long tail
once ranked: **20 of the 70 rules carry 70.8 %** and four families carry 72.3 %, and the whole set
is FEOL plus metal1 (every `M2`–`M5` and `via1`–`via4` rule is zero). The ranking, the rule meanings
from the deck, and what is measured versus inferred about each cluster are in
[`drc_blocking_triage.md`](drc_blocking_triage.md). The `*_OFFGRID` item
coordinates are genuinely off-grid (e.g. `3481.011, 4671.271` — a 1 nm coordinate against a 5 nm
grid) and they sit inside the core (`x ≤ 3486.8`, `y ≤ 4673.0` of the 3932 × 5122 die), not in the
pad ring.

**Where the off-grid geometry comes from — measured.** A linear GDSII scan of the artifact
(`/home/kubew/gds_grid_scan.py`, 9.3 M coordinate pairs) counts coordinates not divisible by
5 dbu:

* the artifact carries **9,312,368 coordinate pairs and 6,020,091 of them (64.65 %) are off the
  5 nm grid** — the stream-out is off-grid by construction, not at its edges;
* **4,370,396 of those coordinates are in a single cell, `sealring$1`**; the next tier is the PDK's
  own via-array / filler cells (`M1_PSUB…`, `M4_M3_CDNS_…`, `M5_M4_CDNS_…`, ~20-30 k each;
  layers 33/40/41 = the via/metal stack);
* the precheck's own ID step is **not** the cause: the same scan on the ID-stamped GDS
  (`04-klayout-generateid/chip_top.gds`, recovered from the container) gives 6,019,936 off-grid —
  155 fewer, exactly the ID's own polygons.

So the pad-mask-skipped scan leaves the artifact missing two gates: **global active-layer density**
(§2d, needs dummy COMP / dummy Poly2) and **an off-grid stream-out**, dominated by the seal ring
and the PDK fill/via cells the flow inserts. Both are wrapper properties the real GRX930
submission inherits. The off-grid half is now **settled as advisory** — wafer.space rules the
`*_OFFGRID` family a critical warning rather than a hard blocker, which is the decision this
paragraph left open, so the grid snap is a quality improvement and not a submission gate; what
remains blocking in the deck is the other 12,202 items. The density half is not settled by
treatment: it is a hard minimum, and the fill that lifts it is measured (§2d) but never yet run
inside a full flow.

**There is no LVS stage in this precheck.** The stage banners, in order: Read the Layout · Check
Top-Level Name · Check Slot Size · Check Pad Mask · Generate ID · Render Image (w/ KLayout) ·
Density Check · KLayout Density Checker · Find Zero Area Polygons · KLayout Zero Area Polygons
Checker · Antenna Check · KLayout Antenna Checker · Design Rule Checks · Magic Design Rule Checker ·
Design Rule Check (KLayout) · KLayout Design Rule Checker · Write the Layout. There is no netlist
extraction or LVS step anywhere in it — the only "lvs" strings in the 11 MB log are the GF180
marker layers (`lvs_bjt`, `lvs_io`, `lvs_source`) read by the DRC deck. LVS stays our own job
(§4 item 5), and the first version of this note ("stages 5-17 … DRC/LVS") was wrong about that.

## 3. The same precheck, on wafer.space's own 1×1 reference layout

Run first, to calibrate the gate: `gf180mcu-example-layouts/5v/1x1/chip_top.oas`,
`--id WSREF001`, same image and flags. It reached the **Design Rule Checks** stage — 12 of the 17
stages — after ~3.7 h on this 6-core box, and was torn down by a host restart while the DRC deck
was loading. Findings from it, all of which the real submission needs:

* **`Success: Pad mask matches!`** — the golden mask is consistent with the reference layout, so
  the 0.5 µm offset in §2c is the template's, not the mask's.
* **The die ID must be exactly 8 characters.** The first attempt died at *Generate ID* with
  *"Error: Length of ID must be exactly 8 characters, is 5."* The ID is tied to the die at CoB,
  so it has to be chosen before the precheck, not after.
* **The precheck is a multi-hour job on a full die**, per-layer antenna decks and all, not the
  "one docker run" its README suggests; budget for it. Its *early* gates (layout, name, size, pad
  mask, ID, render) are minutes — a pad-mask failure is a fast, cheap loop.

## 4. What to do next, in order

1. **Settle the 0.5 µm.** Diff the pad positions in `slot_1x1.yaml` / the `OpenROAD.PadRing`
   result against `assets/golden_masks/mask_1x1.gds` (one KLayout xor reproduces §2c in seconds).
   Fix the ring, or ask wafer.space which of the two is authoritative.
2. **The pad-mask-skipped scan has already run the rest** (§2d/§2e) — no need to wait for the mask:
   `--skip KLayout.CheckPadMask` measured density, zero-area, antenna, Magic DRC and KLayout DRC in
   11.5 h. It gives the second and third findings: **global active-layer density is a gate** — COMP
   ≥ 25 % (`DCF.1b`) and Poly2 ≥ 14 % (`PL.8`) over the whole die. The template's metal filler gets
   the metal bands there; nothing but the core's own devices and dummy COMP/Poly2 can lift the
   active layers. The GRX930 core is ~460 k instances at 45.9 % utilisation, so the answer for the
   real die has to be measured on the real die — but the floor is now known to be a *minimum*,
   not a maximum, on both layers — and the KLayout DRC deck's remaining block is the **12,202
   non-`*_OFFGRID` violations** (the 71,575 off-grid items beside them are a critical warning, not a
   hard blocker — ruled 2026-10-16, §2e). The off-grid geometry is still worth snapping, since 4.37 M
   of the coordinates are the seal ring's (§2e), but it no longer decides the submission. What the
   real core inherits either way is the seal ring, the PDK filler cells and the flow's stream-out
   tool.
3. **Then the real die.** This artifact is the template's placeholder core; the wrapper it proves
   is shared with GRX930, but the GRX930 route itself is still the open blocker (`ws_v3` never got
   past `37-openroad-globalrouting`; `diejmp01` is the measurement arm on the die database). The
   precheck verdict here says nothing about the real core's density, antenna or DRC.
4. **Package it**: GDS, netlist, SPEF, the reports, and a README with the measured numbers —
   `wafer_space_submission/` is marked SUPERSEDED and its numbers are wrong for this design. The
   verdict JSON the package carries should be read with `tools/precheck_verdict.py`, whose
   `gates[*].blocking_count` now separates the advisory off-grid family from the rules that decide.
5. **Keep the flow's own numbers**: the Magic-vs-KLayout xor reported **19,880 differences**
   (deferred, not a gate for stream-out) — worth understanding before a submission, since the
   precheck's DRC is run on the KLayout stream-out only.

## 5. Reproducing this in one sitting

```sh
# artifact
docker run -d --name tpl --user 0:0 --memory 4294967296 -v $TPL:/work \
  ghcr.io/wafer-space/gf180mcu-precheck /work/run_flow.sh        # run_flow4.sh in this session
# after 90-klayout-sealring / 92-klayout-filler appear in runs/tpl02/
ln -s .../92-klayout-filler/chip_top.gds /somewhere/run1/chip_top.gds
# verdict
docker run --rm --user 0:0 -v /somewhere:/host ghcr.io/wafer-space/gf180mcu-precheck \
  dev-shell bash -lc 'cd /workspace && python3 precheck.py --slot 1x1 --cob \
  --input /host/run1/chip_top.gds --id <8 chars> --workers 4 --output /host/run1/chip_top.oas'
```

The scripts this session used are on the box: `/home/kubew/tplrun/run_flow{3,4}.sh` (resume with
IR drop off), `/home/kubew/probe/gds_probe.rb`, `mask_layers.rb`, `mask_cmp.rb` (geometry and the
mask xor), and the precheck logs at `/home/kubew/submit/run1/precheck_ws.log`.

## 6. Reading the verdict in CI, not from the exit code

The precheck's verdict is **not** its exit code: the run that failed on density and DRC
(`ws-precheck2`) is recorded as `Exited (0)`, because the wrapper scripts in the image do not
propagate the CLI's `sys.exit(1)`. The verdict exists only in the log text. `c930/asic_gf180mcu/tools/precheck_verdict.py`
now reads it — the log plus, when given a run directory, the per-step `state_in.json` metrics and
the per-check report tallies — into one JSON object with a matching exit code:

| exit | meaning |
|---|---|
| 0 | every blocking gate passed (`Write the Layout` reached, deferred list empty) |
| 1 | a blocking gate failed (this is the template artifact's result: density + KLayout DRC) |
| 2 | the run aborted early: a stage failed inline (the pad-mask and top-level-name runs) |
| 3 | no verdict parseable — never a silent pass |
| 4 | usage or IO error |

The gate semantics are taken from the precheck's own `precheck.py`, not assumed: density and
KLayout DRC are *deferred* checkers, zero-area aborts inline, and Magic DRC is a **metric**
(`ERROR_ON_MAGIC_DRC: False`), so 12,772 Magic DRC errors do not decide anything — the JSON keeps
them as a warning and `summary.non_blocking`.

```sh
python3 tools/precheck_verdict.py --log precheck_ws.log --run-dir runs/run2 --out verdict.json
make precheck_verdict PRECHECK_LOG=/path/precheck_ws.log PRECHECK_RUN=/path/runs/run2
python3 tools/precheck_verdict.py --log precheck_ws.log --expect fail   # assert in CI
bash tools/precheck_verdict_selftest.sh                                 # 55 assertions, no box needed
```

Verified against these real logs: the 11 MB `run2` log returns `fail` with
`blocking_failed: [density, klayout_drc]`, `density: 2`, `klayout_drc: 83777` over **737 rules**
(summing to exactly the total), `magic_drc: warn 12772` non-blocking, zero-area and antenna
`pass`, the artifact sha256 and the 41,650 s wall clock across midnight, and the two small abort
logs return `incomplete` naming `Check Top-Level Name` and `Check Pad Mask`. The JSONs are kept as
[`evidence_run2/verdict_run2.json`](evidence_run2/verdict_run2.json),
[`evidence_run2/verdict_abort_toplevel.json`](evidence_run2/verdict_abort_toplevel.json) and
[`evidence_run2/verdict_abort_padmask.json`](evidence_run2/verdict_abort_padmask.json), so the
submission package can carry the verdict it was accepted on.
