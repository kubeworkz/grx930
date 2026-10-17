# grx930 detailed-routing investigation — status

Server: `ubuntu@49.13.6.8` (8 cores, 15 GB RAM). Work in `/home/ubuntu/grx930_ol2`.
PDK: **gf180mcuD**, std cell lib `gf180mcu_fd_sc_mcu7t5v0`, OpenLane2 **2.3.10** (Classic flow).

**Headline:** running more DRT iterations cannot fix this — the run was configured for 64
iterations (≈ a month), it converged for 16 and then broke. The real lever is the global-router
capacity reservation (`GRT_ADJUSTMENT`), which this design overrides from the stock **0.3** to
**0.0**. That override is now **reverted**, and the middle of the range is measured too: the A/B
(§13) showed 0.3 wins 2.19× on violations in 2.31× less wall clock, but the 0.1/0.2 sweep (§14)
showed 0.3 pays for that last 27.6 % at 8× the marginal wire and 17× the flow tail. **The knee is
0.2**, and both flows carry `GRT_ADJUSTMENT: 0.2`. An experiment now costs ~2 h instead of ~10 days.

---

## 1. The 10-day run is stopped; the input checkpoint is preserved

v8 (`RUN_2026-09-30_23-41-23`) sat in `OpenROAD.DetailedRouting` for 10.6 days on iteration 26
of 64, and was worse than its own best by then. It has been stopped (only the DRT process and
its `openlane` driver were signalled; exit code 143).

Its DRT input is preserved as a self-contained ODB (no PDK files needed):

```
/home/ubuntu/grx930_ol2/drt_fast/ckpt/pre_drt.odb      (332 MB)
  = runs/RUN_2026-09-30_23-41-23/41-openroad-repairantennas/grx930_test_chip.odb
```

## 2. A fast DRT-only loop, validated byte-for-byte against v8

`drt_fast/drt_fast.tcl` + `run_drt.sh` read that ODB and call the *same* `detailed_route`
OpenLane's `scripts/openroad/drt.tcl` calls, with the same six arguments (checked against the
shipped tcl; the ODB carries the GRT guides).

| checkpoint | v8 (10 days) | fast loop `out/exp1` (2 h 20 m) |
|---|---|---|
| initial route | 1,081,775 | **1,081,775** |
| opt iter 1 | 405,529 | **405,529** |
| opt iter 2 | 387,049 | **387,049** |

So an experiment costs **~2 h instead of ~10 days**: ~76 min for the initial route, ~50 min per
optimization iteration. Knobs: `FAST_END_ITER`, `FAST_MIN_LAYER`, `FAST_MAX_LAYER`,
`FAST_THREADS`, `FAST_ODB`. Sweep driver `drt_fast/sweep2.sh` (config `configs2.tsv`, one line
per run, results in `drt_fast/out/<TAG>/`, logs in `drt_fast/logs/<TAG>.log`).

## 3. What v8 actually did — the full curve (new evidence)

`build/v8_flow.log`, violations at the end of each iteration:

```
   1  1,081,775   initial route
   2    405,529
   3    387,049
   4    278,169
   ...  monotone improvement ...
  16    238,336
  17    237,089   <- best ever (~Oct 1-2)
  18    649,172   <- breaks: 2.7x worse in one iteration
  19    473,371
  20    453,722   ... creeping back up ...
  26    711,100   (killed here)
```

There is no downward trend to extrapolate. This is not "grinding toward zero"; the loop is
diverging after iteration 17 and restarts from near-zero twice.

## 4. The design is not congested — the area/RTL work paid off

Global-route final congestion report (v8):

| layer | resource | demand | usage | overflow |
|---|---|---|---|---|
| Metal1 | 2,643,587 | 418,223 | 15.8% | 0 |
| Metal2 | 4,259,456 | 922,447 | 21.7% | 0 |
| Metal3 | 4,254,632 | 566,118 | 13.3% | 0 |
| Metal4 | 4,169,376 | 260,363 | 6.2% | 0 |
| Metal5 | 2,486,576 | 46,257 | 1.9% | 0 |
| **total** | **17,813,627** | **2,213,408** | **12.4%** | **0** |

Measured from the ODB (probes in `drt_fast/*_probe.tcl`):

* die 3930 x 5120 um (20.1 mm²), core 3916 x 5088 um (19.9 mm²), 1298 rows of 3.92 um;
* 370,059 instances, total cell area 6.66 mm² → **33.4% core utilization**;
* 231,915 nets, 11 BTerms, **no macros / hard blocks at all**;
* **highest signal fanout is 22** (only VDD/VSS exceed it, 608,160 iterms each) — no fanout bomb;
* exactly 2 special nets (VDD, VSS), correctly declared;
* 5 routing layers (M1/M3/M5 horizontal, M2/M4 vertical), pitch 0.56 um (M5 0.90);
* wire 19.4 m (GRT estimate 24.3 m), 1.9M vias;
* placement is a broad Gaussian: uniform across x, ~5x denser in the central y band
  (~35k vs ~6.6k instances per 256 um band).

## 5. Anatomy of the violations (from the 53 MB DRC report of the 2-iteration run)

346,875 Short markers at iteration 2, plus 39,905 Metal Spacing, 211 Cut Short:

* **222,314 unique net pairs**, 1.56 markers per pair → diffuse, not a few hotspots;
* **84,851 distinct nets** involved — about one third of the design;
* only **1.8%** involve VDD/VSS → **not** a PDN/rail collision;
* **45% of sampled pairs share a standard cell** → about half the shorts are at or near cell
  pin geometry, the rest are net-to-net;
* spatially clustered: one 256 um band holds ~43-48% of all shorts;
* each marker is a single 0.28 x 0.28 um cell (one wire width) — unit-track overlaps.

At the best iteration the shorts are M2 119,546 / M3 51,706 / M4 33,900 / M5 6,156, M1 only
2,518 (at iteration 0, M1 had 314,808 shorts and 0.35 m of M1 wire; DRT retreats off M1 and
pushes the conflict up).

Warnings worth noting: `ODB-0388 unsupported LEF58_EOLENCLOSURE property for layer Via1..Via4`,
`GRT-0043 No OR_DEFAULT vias defined` — via-enclosure rules from the tech LEF are skipped by
this OpenROAD build.

## 6. `RT_MIN_LAYER=Metal1` is the fix, not the bug

| run | bottom layer | initial-route shape | outcome |
|---|---|---|---|
| v3d/v5 | Metal2 | 20% = 1.88-2.28M, 70% = 13.1M | died, hopeless |
| v7 | Metal1 | 20% = 3.12M | died (pin-not-visited / feedthrough mode) |
| **v8** | **Metal1** | **1.08M total** | best by ~10x, plateaus at 237k |

Do not re-test a Metal2 bottom layer; that axis is closed.

## 7. Root-cause candidate: `GRT_ADJUSTMENT=0.0`

OpenLane 2.3.10 source (`steps/common_variables.py`):

```
Variable("GRT_ADJUSTMENT", Decimal,
  "Reduction in the routing capacity of the edges between the cells in the global routing
   graph for all layers. Values range from 0 to 1. 1 = most reduction, 0 = least reduction.",
  default=0.3),
```

* **Stock default 0.3** → GRT plans with only 70% of each edge's capacity, deliberately leaving
  headroom for vias, jogs, pin escape and DRC spacing.
* This design's `config.json` sets **0.0** → GRT plans as if every track is usable, so its
  guides are packed to the theoretical limit. GRT then reports a clean report — v8's log says
  `Global adjustment: 0%`, 0 overflow, 12.4% usage — **while DRT cannot realize those guides
  without shorting, and no amount of iteration fixes it.** That is exactly the observed
  "GRT clean / DRT stuck at ~1 conflict per net pair" signature.
* The override was introduced in **v4**, whose own header comment says the reason: *"because
  OL2's stock GRT_ADJUSTMENT=0.3 cuts all edge capacity by 30%"* — i.e. it was a hack to get
  GRT's *reported* congestion under a gate (102.95% → 92.66%). Every run since v4, including
  v8, inherited it.
* With the shrunk Option-B netlist the design only uses 12.4% of routing capacity, so reserving
  30% is now safe as well as correct.

**Attempted and dropped on evidence.** The 0.3 arm was launched on the fat (33.4 %, 19.93 mm²)
layout by re-running the flow from `OpenROAD.GlobalRouting`. GRT logged
`[INFO GRT-0022] Global adjustment: 30%` — so the override took effect — and then
`[INFO GRT-0101] Running extra iterations to remove overflow`, i.e. exactly the overflow regime
that historically produced the 143.72 % / 4.57 M-overflow guides which made DRT diverge
(22.8 M → 25.5 M). On this layout the stock 30 % reservation is **not** free: the design's own v4
comment said the reservation was removed *because* it cut edge capacity by 30 %.

The run was killed before it produced a congestion report — it had also filled the 150 GB volume
(see §9), which is a second, independent reason not to repeat it as-is. The variant worth running
was 0.3 **on the slot-core layout** (§10). That arm has since run (§13): it wins decisively on
violations, but two expectations stated here were **wrong** — wirelength did not drop (it rose
18.2 %), and 0.3 did not stay below the overflow knee (GRT finished with 15,155 overflow, because
the reservation is what raises the demand it measures).

## 8. The router version is not the problem (A/B, in progress)

* The 2.3.10 image bundles OpenROAD commit `edf00dff99f6c40d67a30c0e22a8191c5d2ed9d6`.
* `openroad/ubuntu24.04:latest` is already on the box with **OpenROAD 26Q3
  (26Q3-1876-gedad3701c7)** and reads our pre-DRT ODB cleanly (231,915 nets, 2 s). Note the API
  change: `-bottom_routing_layer` is deprecated (DRT-0509); use
  `set_routing_layers -signal Metal1-Metal5`.
* `drt_newor2` runs the identical input and options on 26Q3. Initial-route checkpoints:

| % of initial route | 2.3.10 (exp1) | 26Q3 (newor2) |
|---|---|---|
| 10% | 0 (t=5:37) | 0 (t=6:57) |
| 20% | 190,579 (t=13:22) | 200,574 (t=14:59) |
| 30% | 258,958 (t=18:05) | 274,685 |
| 40% | 258,958 | 274,685 |
| 50% | 449,853 | 477,455 |
| 60% | 517,669 | 550,562 |
| 70% | 712,201 | 755,583 |
| 100% | 1,081,775 (final iter-0) | stopped at 70% |

  **Consistently ~5-6 % worse, never better** — upgrading the router is not the fix. newor2 was
  stopped at 70 % of its initial route (log kept at `drt_fast/logs/newor2.log`) to free the box for
  the floorplan experiment; the fast loop measures iteration behaviour on both layouts anyway.

## 10. The floorplan experiment — the core was in the wrong place (running)

**Finding.** The v8 flow never set `CORE_AREA` (`resolved.json` → `"CORE_AREA": null`), so OL2
derived a core from `DIE_AREA` minus default margins:

| | x (µm) | y (µm) | area |
|---|---|---|---|
| die (`DIE_AREA`) | 0 … 3930 | 0 … 5120 | 20.12 mm² |
| v8 core (margins 6.96 / 15.92 µm) | 6.96 … 3923.9 | 15.92 … 5104.1 | 19.93 mm² |
| **slot core** (`pad_ring.cfg` §1) | **441 … 3489** | **441 … 4679** | **12.92 mm²** |

The repo's own `pad_ring.cfg` already specifies the physical core: seal ring 26 µm, pad band
26…376 (`gf180mcu_fd_io` pads are 75×350), corners to 381, plus a routing channel to 441 — and its
integration list says, verbatim, *"Set config.json: CORE_AREA \"441 441 3489 4679\" (keeps
DIE_AREA) … NOT yet set in config.json"*. `pad_ring_check.py` derives the same numbers and asserts
the 12.92 mm² area. So **v8 placed 369,247 standard cells across the area the pad ring must
occupy** — and, incidentally, spread 6.66 mm² of cells over 19.93 mm² of silicon.

**Where the cells really are (measured, `drt_fast/dens_probe.tcl` on `ckpt/pre_drt.odb`).**
A sum-of-master-area map at 300×300 µm granularity (instrument self-check: summed area
6,663,429 µm² vs the flow's 6,659,860 µm² metric, 0.05 %):

| | value |
|---|---|
| hottest bins | **84,908 / 84,326 / 84,201 / 83,716 / 83,128 µm² per 90,000 µm²** = **91-94 % cell-area density** |
| location of the hot bins | x ≈ 0.9-1.5 mm and x ≈ 3.0-3.3 mm, y ≈ 2.1-3.0 mm (i.e. the middle band, two lobes in x) |
| cell bounding box | 6.0, 15.0 → 3922.0, 5103.0 µm (the full core) |
| rows / site | 1298 rows, `GF018hv5v_mcu_sc7`, site 1120 × 7840 DBU = 0.56 × 3.92 µm |

So the earlier count-based reading — "the placer is pinned at its 65 % density target" — was **wrong and
is corrected here**: GPL's target is a soft global parameter and detailed placement packs rows far
tighter than it. The design has ~91-94 % **local** density hot spots while averaging 33.4 %
*globally*, because ~1.1 mm² of cells (17 %) sit in the sparse skirt (the top/bottom ~1.28 mm at
~11 % density) and the rest is packed hot in the middle. That changes the expected mechanism: the
slot core does not "spread cells more uniformly", it removes the skirt and pulls those cells into
the already-hot middle, so the wirelength win is bounded by how much of the total wirelength the
skirt nets actually carry — and the pin-access risk is concentrated where the hot spots already are.

**Consequence, and why this is the requested experiment.** Setting that `CORE_AREA` raises
utilization from **33.4 % to 51.6 %** with no other change — not as a knob, but as the layout the
shuttle actually requires. Predicted effect on the metric the user asked about: total placement
area drops to 0.648×, so GRT wirelength should fall ~sqrt(0.648) ≈ **-20 %** from the measured
baseline of **24,215,167 µm** (≈ 285 µm average over 84,851 nets).

  **Prediction falsified (§13).** The measured GRT wirelength on the slot core is **24,301,804 µm**
  — **+0.4 %**, not -20 %. The √(area) scaling assumed the wire is spread with the cells, but per
  the density map above the cells were already packed in a hot middle band over a sparse skirt, so
  removing the skirt pulls cells together without shortening the nets that dominate the total. The
  core shrink is a shuttle-mandated layout change that is roughly neutral on wire, not a wireline
  win. (This prediction is what the `grx930_overrides.yaml` arm table had recorded as `19.63 M um`
  "measured"; it was never measured — see §13.)

**Honest uncertainty.** The DRT signature is 222,314 unique conflicting net pairs and ~45 % of
markers at cell-pin geometry, and denser placement means 1.55× more pin-access pressure per unit
area. So the experiment can go either way, and that is the point: shorter wires reduce the
surface area for shorts, denser rows make every pin escape harder. The chain measures both
outcomes with the same instrument.

**Running now** (`drt_fast/core_chain.sh`, log `drt_fast/core_chain.log`):

1. fresh OL2 run `slotcore_v1` with `config.json` + `core_area_cfg.json`
   (`CORE_AREA = [441,441,3489,4679]`), stopped after `OpenROAD.RepairAntennas` — the same
   checkpoint v8's DRT consumed;
2. **geometry gate**: `place_probe2.tcl` on the new checkpoint; DRT only runs if the core reads
   3048×4238, so a config that silently doesn't take cannot burn 2 h;
3. fast DRT, 2 iterations, same six arguments → compare against
   1,081,775 / 405,529 / 387,049, plus GRT wirelength and the congestion report.

Two CLI lessons paid for in aborted starts (both recorded in `build/core_exec.sh`): the flow CLI
`-c KEY=VALUE` does not JSON-parse list values (`Decimal('[441')`), and `dir::` resolves against
the **last** config file's directory, so the override must be co-located with `config.json`.

## 9. Constraints / gotchas

* Disk: **the real consumer is Docker, not `runs/`.** At one point the volume hit 0 bytes free
  (`No space left on device`) with 16.09 GB held in *stopped* containers' writable layers — every
  OL2 flow container `volare fetch`es its own ~3 GB PDK copy — plus 5.46 GB of unused volumes.
  `docker rm -f` on the finished containers took the volume from 0 to **21 GB free**; the chain now
  gates on ≥6 GB and removes its flow container as soon as the step is done. `docker system df`
  is the first thing to check, not `du`.
* Derived artifacts of the superseded Sept 22-23 runs (`.sdf`, `.nl.v.json`,
  `primitive_techmap.dot`) were gzipped in place (16 files, ~5 GB → ~0.4 GB, nothing deleted) by
  `build/free_space.sh` + a root container. Note `gzip` as the `ubuntu` user **fails silently** on
  those root-owned run dirs — file mode is fine but the directories are not writable, so the
  compression has to run as root inside a container.
* `drt_fast/out/` is root-owned; containers must run with `--user 0:0`.
* The openlane2 image's `/bin/sh` has no `sed`/`ls`/`awk` — scripts there use bash builtins only.
* Re-running a flow step on an existing run tag **appends new step directories with higher
  ordinals** (evidence: the Sept 24 run reached GRT/DRT at ordinals 50/52/53 after re-runs), so a
  chain must take the newest `*-openroad-repairantennas/*.odb`, not a fixed step number.
* The openlane2 image has **no `/bin/bash`** (`/bin/sh` only, bash via `PATH` at
  `/root/.nix-profile/bin/bash`) — `docker run --entrypoint /bin/bash` fails outright. Run
  container-side scripts as `--entrypoint /bin/sh <script>`, as run_v8.sh did.
* The checkpoint we depend on is already copied into `drt_fast/ckpt/` (`pre_drt.odb`,
  `pre_drt_slotcore.odb`, `pre_drt_grt03.odb`).

## 12. Cache index/tag decomposition fix landed (silicon correctness, not a PPA change)

The pre-existing bug recorded in `asic_gf180mcu/PLAN_B_netlist_rework.md` §8.6 is
**fixed and re-verified** while the floorplan arm was running. It was not a
floorplan issue, but it gated any claim about silicon cache hits, so it is part
of the record here.

* **Defect.** The controllers selected the tag array with the literal 7-bit
  macros (`` `ICACHE_INDEX 11:5 `` / `` `DCACHE_INDEX 11:5 ``) while the data
  arrays used `` [11 -: INDEX_WIDTH] ``. They agree only at `INDEX_WIDTH = 7`;
  the chip runs 4, so 8 tag entries aliased one data line and a fill of B left A
  `VALID` over B's data — **a wrong line on a hit**.
* **Fix.** Both selects derive from `INDEX_WIDTH` (`index = addr[5 +: W]`,
  `tag = addr[63 : 5+W]`), the tag storage width is derived
  (`TAG_W = ADDR_WIDTH-5-W`) instead of trusted from `TAG_WIDTH`, the tops pass it
  down and default it to the derived value, and `riscv_core_top` no longer
  hardcodes `.TAG_WIDTH(52)`. A sim-only `$error` flags a conflicting explicit
  `TAG_WIDTH`. Seven files in `openlane2_rtl/src/`.
* **Evidence.** `c930/tb/run_cache_index_alias.sh` against the pre-fix and fixed
  trees: `FAIL … got 000000a0 expected 00000000 (wrong line served on HIT)` →
  `PASS … fill addresses decomposed correctly`, exit 1 → 0, for both caches.
  `run_tag_width_guard.sh`: silent on the derived default, fires on the pre-fix
  `TAG_WIDTH=52` at width 4. `verify_cache_fix.sh`: verilator lint of
  `grx930_test_chip` 0 errors in both trees, `%Warning-WIDTHTRUNC` 21 → 7 and no
  new warning type; yosys `synth -run coarse` keeps the same `$mem_v2` inventory
  (`TAG_MEM`, `INSTR_MEM`/`DATA_MEM`; `VALID_MEM` → registers in both, by design).
* **Effect on this investigation: none for the A/B, but the netlist moves.**
  `runs/slotcore_v1/06-yosys-synthesis/grx930_test_chip.nl.v` was written
  20:16:51, before the RTL edits (20:25:44 / 20:31:49), and no Yosys step re-reads
  the sources afterwards — so the running arm and the v8 baseline are both the
  pre-fix netlist and remain directly comparable. The fix adds ~48 flops per cache
  at width 4 (negligible against 6.66 mm² of cells), but **final PPA/DRC/LVS
  numbers must come from a fresh synthesis** (new tag generation: do not resume by
  run tag).
* **Second RTL change in the same window: the MMIO read-data hold latch.** The
  ASIC tree was copied before the 2026-10-03 fix described in
  `c930/doc/dcache_mmio_read_hold.md`, so an MMIO load frozen in
  `MMIO_RD_RETIRE` sampled the live response bus to WB. Ported into
  `riscv_core_dcache_top.sv` (2026-10-11, one file, three pieces). Gate
  `tb_dcache_mmio_hold`: `FATAL … 4 checks` / exit 1 before → `[PASS] … every
  check` / exit 0 after; lint unchanged (0 errors, 80 warnings, same 7 types);
  yosys shows the cost as one 64-bit `$adff` + one `$mux` with the arrays still
  `$mem_v2`. On the single-core 1×1 die the trigger (a second master on the
  shared bridge) cannot arise, so this is a question removed rather than a
  measured failure there.
* **Snapshots.** The pre-fix sources are preserved both inside the run tree and at
  `~/grx930_ol2/cache_sim/rtl_prefix/` (md5 of the pre-fix icache controller
  `6ea2fa5d…`, fixed `444e70e6…`), which is what makes the A/B re-runnable. The
  post-index-fix / pre-MMIO-port tree is kept as
  `~/grx930_ol2/cache_sim/rtl_nommio/` (dcache top md5 `56442034…`, ported
  `e25d0d6b…`).

## 13. Arm 2 verdict: 0.3 wins by 2.19x — and the wirelength prediction failed

Both arms are complete. They are a matched pair: same design dir, PDK, core geometry and DRT
arguments, and each input ODB is the endpoint of the same flow with only `GRT_ADJUSTMENT` changed
(arm 1's input is the 0.0 GRT step's output, 203,851,717 B; arm 2's the 0.3 step's, 219,661,871 B).
Report: `drt_fast/verdict/arm_compare.md`.

| arm | GRT | iter0 | iter1 | iter2 | DRT-0199 | wall | peak mem |
|---|---|---|---|---|---|---|---|
| fat (baseline) | 0.0 | 1,081,775 | 405,529 | 387,049 | — | 10.6 d (killed) | — |
| arm 1, slot | 0.0 | 1,096,857 | 435,492 | 418,613 | 418,633 | 3:06:08 | 6,418 MB |
| arm 2, slot | 0.3 | 659,733 | 207,748 | 191,575 | **191,578** | **1:20:31** | 7,024 MB |

**Decision: `GRT_ADJUSTMENT` is now 0.3 in both flows** — `openlane2_rtl/config.json` (was 0.0)
and `wafer_space_integration/grx930_overrides.yaml` (0.3 there was provisional until now).
*Superseded: see §14 — the value is 0.2, and this rule scored violations without scoring cost.* 2.19×
fewer violations at equal iteration depth, 2.31× less wall clock, +9.4 % peak memory. Arm 1 cannot
close the gap: at its own -3.9 %/iteration it would need ~20 more iterations (~18 h at ~55 min each)
even if the rate held, and DRT's rate decelerates.

**The guard clause in the pre-registered rule was broken as a test.** It fired on "extra iterations
to remove overflow" — a line present in **both** logs; the 0.0 arm logs it and then clears its own
overflow (0 on every layer, 12.18 % usage). The discriminating line is `WARNING GRT-0115 Global
routing finished with overflow`, which appears only at 0.3 (15,155 across M1-M5). Read strictly the
guard says "0.3 unaffordable, move the lever to placement" — the opposite of what DRT measures. 0.3
is kept because the guard scored the mechanism rather than the outcome: the reservation *is* what
produces that overflow, since GRT is given ~34 % less capacity per edge, goes over its own budget by
construction and pushes demand up to M3/M4 (usage 12.3→24.9 % and 6.9→19.9 % of true capacity).
With `GRT_ALLOW_CONGESTION: true` that is informational, not an error. The guard's real question —
does reserving capacity pay out at DRT? — is answered yes, by measurement.

**The √area wirelength prediction failed, and a committed table had it as a measurement.** §10
predicted the core shrink would cut GRT wirelength ~20 % (√0.648 × 24,215,167 ≈ 19.4 M µm). Arm 1's
measured GRT wirelength is **24,301,804 µm — +0.4 % vs the fat baseline, not -20 %.**
`grx930_overrides.yaml` carried `19.63 M um` in its arm table with the claim "carries 19 % LESS
wire"; that was the prediction written down as a result, and it is corrected in place.

**Cost this does not address:** wirelength +18.2 % (24.30 → 28.73 M µm), +21.0 % after diode
insertion. Both are GRT estimate against GRT estimate, so the delta is sound but the level is
optimistic — GRT over-estimates routed wire by ~25 % on this design (v8: GRT 24.3 M vs 19.4 M
measured from the ODB). Neither arm reaches a routed result, so the true routed-wire penalty is
unmeasured. Treat 0.3 as a starting point, not an optimum: the next measurement is a 0.1/0.2 arm,
not more DRT iterations.

**And it is not net-faster end to end — the flow tail that feeds DRT gets 23× slower.** quoting
`runtime.txt` per step, the same run tag, 0.0's tail steps 38-41 against 0.3's 42-45:

| step | 0.0 | 0.3 | ratio |
|---|---|---|---|
| globalrouting | 3:14 | **1:17:46** | 24.0× |
| checkantennas | 2:35 | 3:14 | 1.3× |
| repairantennas (diode insertion) | 8:45 | **4:24:27** | 30.2× |
| **tail total** | **14:34** | **5:45:27** | **23.7×** |

So the DRT saving (3:06:08 → 1:20:31, -1:45:37) is partly given back: the segment costs **+3:45 net**
with 0.3. GRT burns 78 min instead of 3 because it is iterating on a graph it has been told is over
budget, and antenna repair burns 4.4 h instead of 9 min because the guides carry more antenna
violations to fix — the resulting ODB is 7.7 % larger (203,851,717 → 219,661,871 B), i.e. more
diodes. This does not change the verdict (418,633 violations is not a viable endpoint at any speed,
and 0.3 is the only arm trending toward zero) but it does bound it: **0.3 buys routability with a
much more expensive flow tail, so the 0.1/0.2 arm is now the higher-value next run** — if a smaller
reservation keeps most of the violation win, it should keep the tail cheap too.

**Two bugs fixed in `build/arm_verdict_capture.sh` while capturing this** (both had already
corrupted the record once): it took the first digit run on a `Completing 100% with N violations`
line, which is the percentage and not N, producing cells like `100\n1096857`; and its arm-2 wait was
budgeted from the moment arm 1's log appeared, so it expired at 11:02 — nine minutes before arm 2's
log was written at 11:11 — and published the report with arm 2 blank. It now waits on both logs
under one shared budget and anchors every number on the labelled form (`with N violations`,
`Total wirelength: N um`).

## 14. The knee is 0.2 — 0.3 spends 8× the marginal wire and 17× the tail for the last 27.6 %

The open question §13 left was whether 0.3 is the knee or the far side of it: two points cannot
say, and its +18.2 % wirelength came with a 23× slower flow tail. So the middle was measured with
the same instrument (`build/grt_sweep_chain.sh` + `build/grt_sweep_exec.sh`; each arm resumes the
same run tag from `OpenROAD.GlobalRouting` to `OpenROAD.RepairAntennas` with only
`GRT_ADJUSTMENT` changed, then fast DRT, 2 iterations, Metal1–Metal5). Every arm's gate is
**measured**, not assumed: it re-reads `Global adjustment: N%` out of its own GRT log and skips its
DRT if the CLI `-c GRT_ADJUSTMENT` override lost to the config file. All four arms logged the value
they were asked for.

| GRT adj | init route | iter1 | iter2 / DRT-0199 | GRT wire (µm) | overflow | GRT-0115 | flow tail | DRT wall | net vs 0.0 |
|---|---|---|---|---|---|---|---|---|---|
| 0.0 | 1,096,857 | 435,492 | 418,633 | 24,301,804 | 0 | no | 14:34 | 3:09:36 | — |
| 0.1 | 903,830 | 357,759 | 344,494 | 24,897,381 | 0 | no | 18:21 | 1:47:04 | −1:18:45 |
| 0.2 | 764,679 | 265,661 | **254,201** | 25,323,984 | 0 | no | 22:27 | 1:32:23 | **−1:29:20** |
| 0.3 | 659,733 | 207,748 | 191,578 | 28,725,060 | 15,155 | **yes** | 5:45:27 | 1:23:33 | +3:44:50 |

**The violation win does not flatten before 0.2 — it peaks there.** Marginal yield per +0.1 of
adjustment is −74,139 / **−90,283** / −62,626 at iteration 2, and that ordering (the 0.1→0.2 step
largest, the 0.2→0.3 step smallest) holds at the initial route and iteration 1 too. So the knee does
not depend on the 2-iteration cutoff: 0.2 is not an interpolation point on a smooth curve toward
0.3, it is the peak of the marginal-yield curve.

**On cost 0.2 is the cheapest point measured, not a compromise.** Marginal wire per violation
removed is 8.0 / **4.7** / **54.3** µm, and cumulative 8.0 / 6.2 / 19.5 µm — the price *falls* from
8.0 to 6.2 µm as the adjustment goes 0.1 → 0.2 and then triples. The last increment alone is 3.4 M
µm of extra routing for 62,626 violations, roughly what 0.1 → 0.2 removed for 8× less wire. The flow
tail grows near-linearly through 0.2 (+3:47, then +4:04, ≈ +2 min per +0.1) and then multiplies by
17.3×; `globalrouting` alone goes 5:27 → 1:17:46.

**Net of the DRT it buys back, 0.1 and 0.2 are both faster end to end than 0.0** (−1:18:45 and
−1:29:20), because DRT converges faster on a layout that has headroom. 0.3 is the only arm where the
reservation costs more time than it saves (+3:44:50). That reverses §13's framing on one point: 0.3
is *not* net-faster end to end — it is the only arm that is net-slower.

**An independent instrument puts the boundary in the same interval.** `WARNING GRT-0115 Global
routing finished with overflow` is absent at 0.0/0.1/0.2 and present only at 0.3 (15,155 across
M1–M5). The 30 % reservation is the first one that over-commits GRT's own reduced budget. The
mechanism behind the tail blow-up is visible in the pre-DRT ODB size, which tracks diode insertion:
194.4 → 201.2 → **202.2** → 209.5 MiB (0.1 → 0.2 adds 0.5 %; 0.2 → 0.3 adds 3.6 % and 4 h 10 m of
repair). Peak memory stays flat (6.4–7.0 GB), so 0.2 costs nothing in the memory envelope either.

**Verdict: `GRT_ADJUSTMENT: 0.2`** in `openlane2_rtl/config.json` and
`wafer_space_integration/grx930_overrides.yaml`. Full report: `Claude outputs/grt_adjustment_sweep.md`;
raw table: `drt_fast/verdict/grt_sweep.md` (regenerable from disk with
`bash build/grt_sweep_chain.sh harvest-only`, which launches nothing).

**This changes the rule §13 pre-registered**, which was "whichever arm reaches the lower iteration-2
plateau sets the value" — a rule that scores violation count and ignores cost, so it selects 0.3 by
construction. The sweep was run precisely because that rule cannot answer the question that matters;
the cost side is now measured rather than assumed.

**The falsifier, recorded rather than buried.** One measurement still favours 0.3: its per-iteration
gain is −7.8 %, where 0.0/0.1/0.2 have settled into −3.9 % / −3.7 % / −4.3 %. At equal iteration
count 0.3 is further from its own asymptote, so its violation advantage could widen with more
iterations — and a 2-iteration DRT cannot settle an asymptote. If a full-length DRT shows 0.2's
plateau stalling well above 0.3's, the value goes back to 0.3. The decisive next measurement is 0.2
vs 0.3 at full iteration count on the same layout pair, not more sweep points.

The inputs for that run need no re-flow and are already staged. `drt_fast/ckpt/` held
byte-identical copies (`cmp`) of each arm's pre-DRT ODB; those were freed to reclaim disk on
the flow box (/ was at 89 %), and the origin paths are recorded in
`drt_fast/ckpt/WHERE_ARE_THE_CHECKPOINTS.md` and in `build/reclaim_disk.sh` — **0.2 is run step
53, 0.3 is step 45**, both under `runs/slotcore_v1/*-openroad-repairantennas/1-diodeinsertion/`.
The fast-DRT outputs and DRC reports were kept and zstd'd rather than deleted (ODBs 4.1–4.4×,
DRCs 8.3–9.4× smaller, each archive verified), so `zstd -d` restores them.

## 15. The memory tripwire — because the one OOM we have was a single line

**The gap this closes.** The only recorded memory failure on this box is one line in
`PLAN_B_netlist_rework.md`: *"OOM at 60 % iter 0, swap exhausted, 6h55m"*. A 7-hour run died and
nothing says how close it was, what it peaked at, or which run. Chasing it after the fact is why
the box ended up with **four swapfiles (28 GiB of swap for 15.25 GiB of RAM)**. It was not
theoretical: `/proc/vmstat` showed **32.0 M pages swapped in and 39.4 M out in 22 h of uptime
(122 GB in / 150 GB out)**, and PSI had accumulated **1903 s of memory stall** — and neither could
be attributed to any particular run. `dmesg` is not readable (`kernel.dmesg_restrict=1`), so the
kernel's own OOM messages are unavailable and cgroups are the only sensor.

**What is now in place.** `build/memwatch.sh`, on a user crontab (`* * * * * … --tick`, no root),
installed and running. Its peaks are **kernel high-water marks**, not samples:

| recorded | source | why it matters |
|---|---|---|
| `memory.peak`, `memory.swap.peak` | cgroup v2, per container | exact peak RSS and peak swap, independent of the sampling interval |
| `memory.max`, `memory.events` (`oom`, `oom_kill`, `max`, `high`) | cgroup v2 | the container's cap and its own OOM/throttle counters |
| `MemAvailable`, `SwapFree`, `pswpin`/`pswpout` rate, PSI some/full `avg10` | `/proc` | the host trajectory leading into a failure |

A tick samples once a minute when the box is idle, and every 5 s for ~55 s while a container is
running — because **a container's cgroup is destroyed the moment its last process exits**, taking
its high-water marks with it. On exit it writes a per-run summary that outlives the container
(which the chains delete with `docker rm -f` seconds later).

**Verified against a real OOM, not assumed.** A container capped at 256 MB made to allocate 400 MB:
the tripwire logged `peak_rss_mb=256 cap_mb=256 oom_kill=1`, raised
`LEVEL=CRIT OOM KILL in container memtest … peak RSS 256 MB, cap 256 MB`, and after `docker rm -f`
still produced a summary reading `verdict=OOM_KILLED` — the peaks survived the container. cron was
confirmed firing on its own, and the lock is released, so ticks complete. Cost: 36 KB of audit data
accumulated in the first minutes after install (~2 lines a minute when idle, so well under 1 MB a
day), with rotation at 20 MB — this tripwire must never be the thing that fills the disk.

**Reading it.** `bash build/memwatch.sh --status` (host + peaks + newest alerts), `--summary NAME`
for one run, `--all` for every run's one-liner, and `--headroom` for the single line the launchers
print at start-up (headroom now + any live alert). Files: `mem_audit/samples.log` (the time series),
`mem_audit/alerts.log`, `mem_audit/ALERT` (newest alert, so one `ls` shows it),
`mem_audit/runs/*.summary`. Sample timestamps line up with the flow's own step logs, which is what
turns "OOM at 60 %" into a curve. Thresholds (MemAvailable < 1 GiB, SwapFree < 2 GiB, PSI some
> 20, container at 90 % of cap, swap-out > 100 MB/min) are at the top of the script and are
judgement, not measurement. `crontab -l | grep -v memwatch | crontab -` removes it.

**The launchers now ask before they start.** Recording an OOM afterwards is not enough — PLAN_B's
failure cost 6h55m before anything noticed. All six host-side chains (`core_chain`, `both_chain`,
`grt03c_chain`, `grt_sweep_chain` per arm, `ws_chain`, `ws_synth_chain`) gate on `build/gate.sh`:

```
. $B/gate.sh
gate 8000 core_chain || { say "ABORT_$GATE_REASON"; exit 1; }
```

**One gate, defined once.** `gate.sh` holds the disk floor and the memory gate together, because six
files used to carry their own copy of both — seven call sites, three spellings of the memwatch path,
and a `6` or a `10` typed into the middle of each chain. A copy is a threshold waiting to drift, and
drift is exactly how a chain ends up measuring the box against a number nobody re-measured. So the
floor defaults to `GATE_MIN_GB` and the sites that genuinely differ say so in their own call:
`ws_chain` passes `10 /` because its run tree is on `/`, and the sites whose disk figure was only ever
*reported* — `both_chain`, `core_chain`'s DRT arm, `ws_synth_chain` — pass `0`, which is never
reached, so no new refusal appears anywhere. The refusal now names itself: `gate` sets
`GATE_REASON=DISK_LOW|MEM_LOW`, so a caller cannot report `ABORT_MEM_LOW` for a full disk. `MEMWATCH`
is resolved next to `gate.sh` (still overridable, for testing), so there is no path to misspell.
Every site logs the same shape — `DISK_GB_FREE`, `MEM_HEADROOM`, `MEM_PREFLIGHT … verdict=…`, and an
`ABORT_<reason>` line only on a refusal — which is what makes one grep work on all seven.

**And each launcher reads the tripwire out loud before it starts.** A gate that only printed to the
console would leave no trace: these chains are launched with `nohup ... > /dev/null 2>&1 &`, so stdout
is thrown away and the log is the only witness. So beside the gate every launcher says the headroom
and any live alert, in the same shape everywhere:

```
say "MEM_HEADROOM $(bash build/memwatch.sh --headroom)"   # inside gate.sh's mem_gate()
```

which lands in the chain log as `MEM_HEADROOM memavail_mb=… swapfree_mb=… headroom_mb=… psi_some=…\
live_alert=none|<LEVEL> <message>`. `--headroom` is a separate, read-only mode rather than extra
`--preflight` chatter so the same line greps identically in all seven call sites (six chains;
`core_chain` re-reads it again before its DRT arm, and `grt_sweep_chain` before *every* arm, since
its arms run serially for hours and each one should start on its own reading). The alert stays
*context* here too — printed, never a reason to refuse.

`--preflight` prints the headroom (MemAvailable + SwapFree), the current pressure and the newest alert
— the alert as *context*, never as a blocker, so a stale OOM cannot wedge the box forever — appends
one line to the caller's log and to `mem_audit/preflight.log`, and refuses when the job cannot fit.
`--need` is the job's measured peak plus margin: **8000 MB** for the DRT-bearing chains (arms peak at
6.4-7.0 GB), **9000 MB** for `ws_chain` (full Chip flow, and `ws_flow` carries no cgroup cap, so the
box is the only limit), and for `ws_synth_chain` it is **derived from its own `--memory=$CAP`** so the
gate and the cap cannot drift apart. `MEMWATCH_FORCE=1` proceeds anyway and records that it did.

**The start-of-run reading, verified in every state it can be in.** `--headroom` was exercised three
ways on the box: the real box (`memavail_mb=14595 swapfree_mb=20379 headroom_mb=34974 psi_some=0.00
live_alert=none`), a scratch `MEMWATCH_ROOT` holding a planted alert (`live_alert=LEVEL=CRIT OOM KILL
in container drt_core after 3 oom events`), and an empty scratch root (`live_alert=none`) — the
`MEMWATCH_ROOT` override exists so the alert branch could be tested *without* planting a fake live
alert on the real box, which would have been indistinguishable from a real one afterwards. Then two
launchers were run the way an unattended chain actually runs, `--need` forced past the headroom and
stdout to `/dev/null`: `core_chain` and `ws_synth_chain` each opened their log with
`CORE_CHAIN_START` / `DISK_GB_FREE 34` / `MEM_HEADROOM memavail_mb=14607 … live_alert=none`,
followed by `verdict=REFUSE headroom 34985 MB < need 999999 MB` and `ABORT_MEM_LOW`, exited 1, and
left `docker ps -a` byte-identical — the state the decision came from is in the log rather than lost
to the redirect, which is the whole reason for the line. The go path was re-checked with a stub
`docker` on PATH so nothing launched: `MEM_HEADROOM … live_alert=none` → `verdict=OK` (need 8192 MB
derived from `cap=8g`) → `SYNTH_LAUNCHED` → `SYNTH_CHAIN_COMPLETE`, exit 0.

**Both directions verified, without launching anything.** With the need forced past the headroom,
`core_chain` and `ws_synth_chain` each printed the refusal, wrote `ABORT_MEM_LOW` to their own log and
exited 1 with the container list unchanged — nothing was created. With a stubbed `docker` on PATH,
the same `ws_synth_chain` reached `MEM_PREFLIGHT OK -- starting` (need 8192 MB derived from `cap=8g`)
and ran through to `SYNTH_CHAIN_COMPLETE`.

**The refactor, verified as delivered.** `gate.sh` was exercised on the box in three modes at all
seven call sites, each site's line taken out of the delivered file (`grep -n` → `eval`) rather than
paraphrased: as it stands → exit 0 and the three-line shape above; with the need forced past the box
→ exit 1 and the historical refusal text (`ABORT_MEM_LOW`, `ABORT_MEM_LOW (DRT arm)`,
`ARM_ABORT_MEM_LOW adj=0.1`, `ABORT_MEM_LOW (cap 8g)`); with `MEMWATCH_FORCE=1` → exit 0 with
`MEM_PREFLIGHT FORCED past the refusal` recorded in the chain's own log. Then all six real chain
scripts were run against a refusing memwatch, with a stub `docker` on PATH: five exited 1 at the gate,
`grt_sweep_chain`'s two arms returned `ARM_ABORT_MEM_LOW` and the sweep still completed (by design —
an arm failure never aborts the sweep), and **no chain issued a single `docker run`, `rm`, `stop` or
`start`**; the only docker calls were the `ps`/`inspect` queries the wait loops make. Going the other
way, `core_chain` and `ws_synth_chain` ran to `CORE_CHAIN_COMPLETE` / `SYNTH_CHAIN_COMPLETE` with
`verdict=OK` from the real tripwire, every write path pointed at a scratch tree. The real campaign
logs and `grt_sweep.md` are byte-identical afterwards. `mem_audit/preflight.log` gained exactly the
gate lines of those two real go-path runs: the harness's own exercises are anchored in a scratch
`MEMWATCH_ROOT`, and its first pass — before that variable was exported, so those decisions were
audited in the real ledger instead — is marked in the ledger by a `NOTE` line rather than deleted, on
the same principle as the earlier forced-refusal tests. All nine delivered files (the gate, its
self-test, the six chains and `memwatch.sh`) hash the same locally and on the box.

**And a test, so the drift cannot come back quietly.** `bash build/gate_selftest.sh` has four parts:
the wiring `gate.sh` ships (where `MEMWATCH` resolves, the real `df` path); every branch above, against
a stub memwatch and a stubbed `free_gb`; every gate call site in every `*_chain.sh`, executed as
delivered — the chain must source `gate.sh`, must not read the disk itself (`df -BG`) or call memwatch
directly, must check the answer (`||`), and must refuse and name a reason; and then **six whole chains
run end to end with the box stubbed to refuse**, each of which must stop where its design says (five
exit 1 at the gate; `grt_sweep_chain`'s two arms return 1 and the sweep still completes), leave
`DISK_GB_FREE` / `MEM_HEADROOM` / `verdict=REFUSE` and a named `ABORT_MEM_LOW` in its own log, and
launch **nothing**. It never runs the real memwatch or a real container: both are stubs,
`MEMWATCH_ROOT` is its own temp dir, and every destination a chain writes to — its `D`/`B`/`ROOT`/`WS`,
its `LOG` and `OUT`, and the volume it hands docker — is redirected there, with a `diff` after each run
proving the copy differs from the delivered chain in those destinations and nowhere else. That matters
most in the last phase: the failure it hunts is a chain that *ignores* its refusal, and that run must
not be able to reach the campaign tree. 117 checks pass on the workstation (3 skipped: no `/home`, no
box ledger, no campaign logs) and **120 on the box with none skipped**. The drift demos all exit 1 with
the reason printed: a chain that regrows `df -BG` plus a direct memwatch call (2 FAIL), a site with its
`||` removed (2 FAIL), `GATE_REASON` renamed in `gate.sh` (10 FAIL), and on the box a chain with its
gate call stripped — caught by the four `docker run`/`rm` calls it makes (6 FAIL) **while the campaign
logs stay byte-identical**, which is the sandbox working rather than a claim that it does.

**The disk branch, exercised locally.** The disk floor is a plain comparison, so it was driven with a
stubbed `free_gb` against the delivered `gate.sh`: below the floor → `DISK_LOW` and memwatch never
called; at the floor → go; `MIN_GB 0` → print only, even with a full disk; and an unreadable `df`
figure → refusal with `GATE_DISK_UNREADABLE`. That last one is a deliberate change: `[ "" -lt 6 ]` is
a bash error returning non-zero, which an `if` reads as *enough disk*, and the one answer a disk gate
must never give by accident is a pass it did not measure.

**Limits.** The gate is a snapshot at launch, not a prediction: a run that grows past its declared
`--need` is only caught by the cron alerts and by its own summary, because **nothing kills it
mid-flight**. Turning the tripwire into a watchdog that aborts a container when swap runs out is the
natural next step, and it is deliberately not done yet. Separately: a container that lives less than
~5 s after its peak still loses the peak — the cgroup is gone before the next sample — and only
docker's `OOMKilled`/exit-137 flags survive; that case is recorded as `UNMEASURED` rather than
reported as zero. For an *uncapped* container killed by the host kernel there is no per-cgroup
counter at all, so the evidence is the sampled trajectory plus the exit code. And the redundant 8 GB
swapfile on the Hetzner volume (see `retire_volume_swap.sh`) is exactly the kind of change whose
consequences this tripwire would now catch.
