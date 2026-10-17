# wafer.space Run 3 readiness — status and gap register

Date: 2026-10-13, 18:15 UTC; updated 2026-10-14 00:45 UTC (§1b, §3.1, §7 — the die's own DRT
at 0.1 is measured, and the antenna-repair abort that follows the GRT workaround is filed).
Evidence base: the `ws_v3` run tree on the flow box (now stopped at
step 37, §1), its `resolved.json`, the installed LibreLane inside
`ghcr.io/wafer-space/gf180mcu-precheck`, the `gf180mcu-precheck` sources in
`c930/asic_gf180mcu/tools/gf180mcu-precheck/`, and the template in
`c930/asic_gf180mcu/tools/gf180mcu-project-template/`. Every number below was read from one of
those, not inferred. The run tree itself is
`ubuntu@49.13.6.8:/home/ubuntu/grx930_ol2/ws/template/librelane/runs/ws_v3`.

---

## 1. Where the flow is

**`ws_v3` is dead — it failed in step 37, `OpenROAD.GlobalRouting`, before detailed routing
ever started.** `ws_flow` exited 2 at 17:56 UTC on 2026-10-13 with
`[GRT-0183] Net net21814: heap underflow during 3D maze routing` (`ws/logs/ws_flow.ws_v3.log`,
step dir `37-openroad-globalrouting/openroad-globalrouting.log`, `ws_chain.log` line
`WS_EXIT:2`). That is OpenROAD's global router giving up on a *no-path* search, not a violated
constraint — measured, not read off the message: see §1a, which also lands the one-key config
change that gets GRT through. The run reached GRT with a step-35/36 state (post-CTS resizer and
STAMidPNR completed, both with `runtime.txt`) and died inside the router. Nothing downstream
exists — no step 43, no `runtime.txt` for it, no DRT counts — so **the DRT cap and its
instrument have nothing to measure in this run**; the measurements below come from the earlier
arms and from `build/v8_flow.log`, as labelled.

Until 17:56 the run was at **step 35→37 of 83** (post-CTS STA → GRT), container `ws_flow` at
~102 % CPU with a growing step log, driven by `build/ws_chain.sh` on the box.

**Done:** synthesis → floorplan + pad ring → PDN → global placement → manual macro
placement → detailed placement → CTS → post-CTS STA → GRT state (step 36 `STAMidPNR`).

### 1a. The GRT abort: measured, and worked around in one key

**`GRT-0183` is a no-path, not a corruption.** In `mazeRouteMSMDOrder3D` the maze expansion
gives up when the source subtree's priority queue empties before reaching the destination
subtree — the comment on the upstream fix says it plainly: "no path could be found within the
search region". It fires during the overflow-removal loop, i.e. while the router is trying to
*improve* an edge, so the route it abandons is the one it already had. The net named
(`net21814`) is not special: it is whichever edge the router reached when a local region had no
legal path left.

**Two things have to be true for the run to die, and they belong to different owners.**

* The *configuration* is what puts the router into that state. This die at `GRT_ADJUSTMENT`
  0.2 is over its own routing budget: with `GRT_OVERFLOW_ITERS: 1` (an arm below) GRT's final
  table reads 63,525 overflow units, 47,168 of them on Metal2, against Metal1's 228 — the
  pressure is on the vertical layers, not on Metal1.
* The *pinned build* is what makes it fatal, and it is two fixes out of date.
  `ghcr.io/wafer-space/gf180mcu-precheck` pins **`openroad-2026-02-17`** (LibreLane
  3.1.0.dev1). Upstream, **PR #10711** (merged Aug 2026) stops treating this exact condition as
  fatal: it keeps the edge's original route via `recoverEdge()` and continues. **PR #11093**
  (merged 2026-08-07) fixes a FastRoute capacity defect in the same neighborhood —
  `initBlockedIntervals` rounded each blocked interval up to a track separately, making the
  charge depend on how the blocked metal happened to be fragmented (it could *rise* when metal
  was removed) and "mainly impacts Metal 1 resources". Both post-date the pin.

**One knob moves it, and the boundary is measured.** `wafer_space_integration/probe_grt.sh`
resumes the frozen step-37 state (`37-openroad-globalrouting/state_in.json`, the exact ODB GRT
was handed) into a fresh run tag with one key changed. Each arm is ~7 min, 3 GiB peak, one
thread:

| arm | knob changed | GRT end | iterations used | final overflow | `GRT-0115` | wire (µm) |
|---|---|---|---|---|---|---|
| ws_v3 as it ran | — | **abort, net21814** | 14 | — | — | — |
| control re-run | — | **abort, net21814** | 14 | — | — | — |
| landed | `GRT_ADJUSTMENT` 0.2 → **0.1** | completes | 8 | **0 everywhere** | no | 39,459,512 |
| | `GRT_ADJUSTMENT` → 0.15 | completes | 12 | 18 (M2 2, M4 16) | yes | 41,057,898 |
| | `GRT_OVERFLOW_ITERS` 50 → 1 | completes | 1 | 63,525 (M2 47,168) | yes | 39,475,195 |
| | `GRT_LAYER_ADJUSTMENTS` 0→ `[-0.2,0,0,0,0]`, 0.2 kept | completes | 13 | 7 | yes | 41,205,578 |

The control arm is the same net at the same iteration as the frozen run — the abort is
deterministic, so a retry is not a fix. **0.1 is the value landed in `grx930_overrides.yaml`**
because it is the only arm that both passes and *converges*: zero overflow on every layer and no
`GRT-0115`, in 8 iterations. 0.15 completes but stops 18 units short of its own budget (the
mini-0.3 signature), and the Metal1-relax arm — which keeps 0.2 on M2–M5, their resources
byte-identical at 2,255,039 / 2,467,749 / 2,157,644 / 1,351,235, and gives Metal1 +52 %
(709,799 → 1,080,188) — completes with 7 units left. That last arm is the disproof of the
obvious guess: Metal1 runs at 7.6–8.6 % usage against Metal2's 59–61 %, so the region with no
path was never "Metal1 out of tracks"; it was a local no-path that more capacity *anywhere*
breaks.

**What this costs, and what is still unmeasured.** The DRT half of the earlier sweep was
measured on the slot core, and it says 0.1 finishes with 344,494 violations against 0.2's
254,201 (`grt_adjustment_sweep.md`). That is a real quality cost and it is the honest price of
a route that reaches detailed routing at all. **The die's own DRT at 0.1 has now been measured
on the same protocol — 204,357 at iteration 2, i.e. cleaner than the slot core at 0.2, §1b** —
but the flow that would produce it still cannot run: the next abort is at the antenna-repair
step, on the same outdated pin (§1b). What remains unmeasured is the *flow's* own DRT curve on
the die (its capped passes and antenna-repair re-routes), not the routing quality of its
pre-DRT database.
The proper fix remains the engine pin: with #10711 and #11093 in, 0.2 becomes runnable again and
the sweep's numbers are the ones to choose from. That route needs a rebuilt or newer LibreLane
image (13 GB pull, `ciel enable` for the PDK) and the box had 5.5 GB free, so it was not taken
here.

### 1b. The die's own DRT at 0.1: measured — 204,357; and the next abort is in antenna repair

Two runs with the landed file — the chain writes the staged copy's sha256 into its own log, and
both runs logged `87372d7b…` — both resuming `ws_v3`'s frozen step-36 state.
Evidence: `die_drt_at01.md`, `ws/logs/die_drt_chain.log`, `ws/logs/predrt_die01.container.log`,
`runs/die01/`, `runs/die02/`. Reproduce with
`DIE_TAG=<fresh> bash build/die_drt_chain.sh` (a full run) or, reusing an existing database,
`DIE_TAG=die02 DIE_ODB_C=<odb> bash build/die_drt_chain.sh`.

**The revision that was measured, and the file since.** The repository's file has gained only
comments since that run — `diff` against the staged revision shows 13 added / 1 removed lines,
every one of them a comment, no setting moved — so the current `0abbccbb…` resolves the same
values the run resolved. The measured revision is kept beside the staging area on the box as
`ws/grx930_overrides.measured_87372d7b.yaml`, so the datum can be reproduced with the exact file
that produced it rather than a later copy of it.

**The measurement.** `build/die_drt_chain.sh` (tag `die02`) ran `OpenROAD.GlobalRouting` →
`STAMidPNR-3` and fed the resulting database — the file `OpenROAD.DetailedRouting` would read,
`01-openroad-globalrouting/chip_top.odb`, 232.7 MB — to the fast DRT loop: 2 iterations,
Metal1–Metal5, 8 threads, `-or_seed 42`, in the pre-check image (the build that wrote the
database and that the flow's own DRT step runs in). The GRT step's own log proves the arm:
`Global adjustment: 10%`, 8 extra iterations, 0 overflow, wire 39,459,512 µm — the probe's
wirelength to the µm.

| iteration | die at 0.1 | slot core at 0.1 | slot core at 0.2 |
|---|---|---|---|
| initial route | **353,871** | 903,830 | 764,679 |
| iter 1 | **213,354** | 357,759 | 265,661 |
| iter 2 (`DRT-0199`) | **204,357** | 344,494 | 254,201 |

Wall clock 1:15:42 (slot core 0.1: 1:47:04), peak 8,123 MB (slot core 0.1: 6,861 MB), and
`watch_drt_curve.sh` classifies the curve **CONVERGING** (last gain −4.2 %, mean −24.0 %).
**The die at 0.1 is cleaner than the slot core at 0.2** — the give-back's price, measured on
the layout that ships, is 204,357. There is no die-side 0.2 to subtract: GRT aborts there (§1a).

**The catch: on this build the die cannot insert antenna diodes at all.** The unmodified
resume (tag `die01`, the same scripts; launched 21:41 UTC, died 22:11:29) gets GRT through
cleanly and then dies in `OpenROAD.RepairAntennas` → `OpenROAD.DiodeInsertion`, which runs
`scripts/openroad/antenna_repair.tcl`: `repair_antennas gf180mcu_fd_sc_mcu7t5v0__antenna
-iterations 3 -ratio_margin 10 -allow_congestion`. It finds 2,979 antenna violations, inserts
3,846 jumpers for 2,080 nets, re-checks (1,299 left), inserts 2,522 diodes, and then hits
`[ERROR GRT-0183] Net _167563_: heap underflow during 3D maze routing` — the same fatal
no-path, now inside the repair's own global-router pass — and LibreLane exits 2. So the 0.1
landing unblocks step 37 but not the flow: **with the staged config the next run dies at
`OpenROAD.RepairAntennas`**, roughly 30 min into a resume, and the pin is what makes a
recoverable condition fatal in two different steps.

The measurement above therefore uses the post-GlobalRouting database with the composite
skipped via the flow's own gate (`-c RUN_ANTENNA_REPAIR=false`, recorded in the run's
`resolved.json`). That is the closest pre-DRT state the die reaches on this build; what the
missing diodes would have cost DRT is not measured (no diode-inserted die database exists) and
is recorded as a limitation, not assumed small.

**One instrument repair, for the record.** This build rejects the fast driver's
`-bottom_routing_layer`/`-top_routing_layer` (`[ERROR DRT-0509] ... deprecated`, measured on
the first attempt, 23:01: rc=1 after 2 s) — which is exactly why LibreLane's own `drt.tcl`
passes no layer flags. The die arm therefore runs `drt_fast/die_drt.tcl`, which states the same
Metal1–Metal5 range with `set_routing_layers` (the replacement DRT-0509 names, and what the
flow's GPL/GRT scripts do from `RT_MIN_LAYER`/`RT_MAX_LAYER`) and prints the tech's routing
layers — exactly Metal1–Metal5, levels 1–5, the whole stack.

A GRT failure is also the one failure the capped-DRT plan cannot absorb: the cap buys a verdict
in hours *inside* step 43, and the run did not get there.

**The two ws_v2 killers are behind us.** `RepairDesignPostGPL` is disabled in
`grx930_overrides.yaml` on measurement, and detailed placement legalized without it
(steps 31 `odb-manualglobalplacement` and 32 `openroad-detailedplacement` both exist;
there is no repair step directory). ws_v2 died exactly there.

### 1d. Past the antenna repair: a lever that passes, and the engine pin that fixes it

Both arms were driven as the *same* `repair_antennas` call on the *same* database the
failing step read (`runs/die01/01-openroad-globalrouting/chip_top.odb`), so neither depends
on a 30-minute flow resume per setting. Report: `Claude outputs/die_to_drt_antenna_and_pin.md`.

**The lever.** `-jumper_only` — the one setting that never inserts diodes — completes on the
pinned engine: rc=0, no `GRT-0183`, 49:37 wall, converging (last iteration inserts 0 jumpers).
But it converges with **1209 antenna violations unresolved** (2979 → 1299 → 1209): jumpers
alone cannot fix them, so this is a way *past* the abort, not a repaired design. Flow-level
run with `-c GRT_ANTENNA_REPAIR_JUMPER_ONLY=true` (tag `diejmp01`, pinned engine) is in the
run log as it goes; it is the only configuration measured to reach the router on this build.

**The pin.** OpenROAD 26Q4 (PR #11093 merged 2026-08-12 for the capacity charge; PR #10711 was
closed, and its merged follow-up **#11404**, commit `c751cdc`, merged 2026-09-14, is what makes
the no-path recoverable) completes the identical call: rc=0, zero `GRT-0183`, 114 violations
left against 1299 where the pinned build died, and it writes the first *diode-inserted* die
database this project has. No released LibreLane carries it (3.0.16 and 3.1.0.dev3 pin the same
`dcf36133`, 2026-02-17), so the engine is supplied by hand:
`ws/tools/openroad_26q4.sh` (binary + libs extracted from
`openroad/debian12:26Q4-407-geb14e40b7b`, run under its own loader) wired in with LibreLane's
own hook `_LLN_OVERRIDE_OPENROAD` (`steps/openroad.py:297`). Two traps, both measured and
both handled: the extraction needs `tar -h` or the libraries arrive as dangling symlinks, and
that build bundles Tcl 9, whose ASCII stdout channel kills LibreLane's first non-ASCII `puts`
(`error writing "stdout": invalid or incomplete multibyte or wide character`, in
`read_pnr_libs`) unless `ws/tools/openroad_26q4_init.tcl` is installed as `$HOME/.openroad`.

**And the pin's real cost:** at flow level the swap stops at LibreLane's own scene shim —
`[ERROR STA-0107] ..._p_Scene is not the name of a scene` out of `common/io.tcl`'s
"in OpenSTA 3, that's the scene's name again" branch — so a working pin needs a LibreLane whose
scripts match the newer OpenSTA API, which no release has today. The abort is the engine's bug;
the *pairing* is the work.

### The pre-CTS → post-CTS A/B (tt corner, 40 ns constraint)

| metric | pre-CTS (step 30) | post-CTS (step 34) |
|---|---|---|
| max-slew violations | 157,453 | **115,223** (−27 %) |
| hold WNS / count | −18.11 ns / 2,003 | **−3.20 ns / 2** |
| setup WNS / count | −574.47 ns / — | −345.20 ns / **30,490** |
| max-cap violations | — | 5,944 |
| max-fanout violations | — | 2,275 (see `slew_violation_sources.md` §7 on the 99-vs-13,180 anomaly) |

So CTS took roughly a quarter out of the slew problem and essentially all of the hold
problem (2,003 → 2), but the design does not close 40 ns and never will at this floorplan:
the WNS path is the ROM decode (`u_rom.line_p1[2]`, 2,228 loads). `clock.rpt`'s
"Propagated: no" header is static text — the post-CTS path walks a nine-level `clkbuf`
tree with 3.6 ns latency and 142 ps skew.

**Implied real frequency:** min period ≈ 40 + 345 = 385 ns → **≈ 2.6 MHz** at tt
(ss: 40 + 147.9 ≈ 188 ns → ≈ 5.3 MHz).

## 2. The gates that decide whether this run can land

Read from the live run's own `resolved.json` plus the installed `librelane/steps/checker.py`:

| gate | resolved | verdict for this design |
|---|---|---|
| `ERROR_ON_TR_DRC` | `True` (threshold 0) | **fails if DRT is not clean** — see §3 |
| `Checker.SetupViolations` | `SETUP_VIOLATION_CORNERS: null` → PDK `TIMING_VIOLATION_CORNERS: ["*tt*"]` | **fails** — 30,490 violations at tt |
| `Checker.HoldViolations` | `HOLD_VIOLATION_CORNERS: ["*"]` | **fails if nonzero** — 2 at tt right now; the resizers own this |
| `Checker.MaxSlewViolations` / `MaxCapViolations` | `[""]` → empty list | warn only (verified in source and in the run) |
| `ERROR_ON_KLAYOUT_DRC` / `_DENSITY` / `_ANTENNA` / `_XOR` / `_LVS` / `_DISCONNECTED_PINS` | all `True` | normal sign-off, not yet exercised |
| `ERROR_ON_MAGIC_DRC` | `False` | tolerated — wafer.space's own precheck tolerates it too |
| `ERROR_ON_LONG_WIRE` | `True`, but `WIRE_LENGTH_THRESHOLD: null` | **inert** — `MetricChecker.run` skips a checker with no threshold |

The setup row is the one that surprises: the gf180mcuD **PDK** sets a tt wildcard, so on
this PDK setup violations are a `DeferredStepError`, not a warning. That is recorded in
`slew_violation_sources.md` §6 (which carried the wrong row until today).

## 3. What has never been done, and is the real risk

1. **Detailed routing on the assembled design** (pad ring + 12.92 mm² core) has still run in
   no flow. Its pre-DRT database has now been routed in the fast loop (2 iterations at the
   landed 0.1 → **204,357**, §1b), but nothing carries the flow's cap, its antenna-repair
   re-routes or its `Checker.TrDRC` verdict. The other comparable evidence, all on the
   core-only slot layout:
   - fast-loop 2-iteration DRT arms: 254,201 violations at `GRT_ADJUSTMENT 0.2`,
     191,578 at 0.3 (initial route ≈ 0.7–0.8 M);
   - the only full-length attempt (v8, adjustment 0.0) reached its best point, 237,089, at
     the end of optimization iteration 16 — then jumped to 649,172 at iteration 17 and to
     711,100 at iteration 25; the run was killed at 10.6 days.
   `ws_v3` carries 0.2 (the measured cost-weighted knee) with `DRT_OPT_ITERS` unset, i.e.
   the router's default **64** iterations — the same regime that burned v8. The next run
   caps it at **8** (see the subsection below). The staged, decisive next measurement is
   still 0.2 vs 0.3 at full iteration count
   (`drt_fast/ckpt/WHERE_ARE_THE_CHECKPOINTS.md`), ~2 h per experiment with the fast loop
   instead of ~10 days.
2. **Everything after DRT** (antenna repair, `Checker.XOR`, `KLayout.Antenna`,
   `KLayout.SealRing`, `KLayout.Filler`, `KLayout.Density`, stream-out, sign-off) —
   never exercised on this design. Flow order confirmed from the installed
   `librelane/flows/classic.py` step list (the Chip flow's is built from it).
3. **The wafer.space precheck has never been run** — there is no GDS with a pad ring yet.

### The `DRT_OPT_ITERS` cap: set to 8, and what it costs in violations

**Decision, 2026-10-13: `DRT_OPT_ITERS: 8`** in
[grx930_overrides.yaml](../c930/asic_gf180mcu/wafer_space_integration/grx930_overrides.yaml),
with the full rationale in the comment there. The knob belongs to
`OpenROAD.DetailedRouting` — the installed LibreLane 3.1.0.dev1 declares it `default=64`
in `steps/openroad.py` and consumes it at `scripts/openroad/drt.tcl:88` as
`-droute_end_iter`.

**Correction to the first version of this section (same day, from reading the installed
`drt.tcl` in full): the step is not one routing job.** The Chip flow runs DetailedRouting
once (`flows/classic.py:87`, gated by `RUN_DRT`), but that step contains a loop —
`drt.tcl:85-121` routes (`drt-run-0`), then keeps running `check_antennas` / `repair_antennas`
and re-routing (`drt-run-1`, ...) while diodes are actually inserted, up to
`DRT_ANTENNA_REPAIR_ITERS` (10 here), and **every pass gets a fresh `-droute_end_iter` budget
from this key**. So the cap bounds the pass, not the step: the step's worst case is
(1 + 10) x (initial route + 8 iterations) ~ several days, and the hours figure below is per
pass. What bounds the step in practice is that the loop exits as soon as antenna repair stops
inserting diodes — which is one more reason to watch the per-pass curve rather than the step.
That instrument now exists: [watch_drt_curve.sh](../c930/asic_gf180mcu/wafer_space_integration/watch_drt_curve.sh)
segments the log per pass, classifies each as CONVERGING / STALLED / DIVERGED / CLEAN against
the thresholds below, writes the verdict to `ws/logs/drt_verdict.md` on every new count, and
can stop the step on the armed verdict (`--kill`; flag-only by default). `build/ws_chain.sh`
starts it with the flow. When the step ends the same script writes `ws/logs/drt_cap_cost.md`,
which prices *this* cap on the die it ran on: the count standing at the cap, the measured
per-iteration wall clock against the 26:05 / 25:25 min core-only baseline, a labelled
extrapolation of the tail rate, and the fast-loop command that measures the withheld
iterations directly on the step's own input ODB.

**The loop now closes itself.** That extrapolation was the only part of the report that was not
a measurement, and it is the part the run can take for itself, so the watcher now queues
[drt_extend_ws.sh](../c930/asic_gf180mcu/wafer_space_integration/drt_extend_ws.sh) at step end —
when the step actually finished and the tail is still falling faster than the classifier's own
1 %/iteration stall rate (below that, twelve more iterations cannot arrive at 0 and saying so is
arithmetic, not a measurement, so it prints that reason instead and launches nothing). The
runner waits for `ws_flow` to exit, refuses while any other router is running, passes the same
gate the chains use, routes the step's own `state_in.json` database with `-droute_end_iter 16`,
and writes `drt_cap_cost_measured.md`: the **instrument check** (its first iterations must
reproduce the flow's counts exactly, else it quotes no cost), the count at the cap, the count
after, the difference, and the withheld iterations' own measured wall clock. Verified by
[extend_selftest.sh](../c930/asic_gf180mcu/wafer_space_integration/extend_selftest.sh) (over 50
checks, docker stubbed, nothing launched), on the box as well as locally, plus one integration
run through the real container/log pipeline whose streamed output is `build/v8_flow.log`
truncated to 16 iterations: the instrument check matched all 8 shared counts and the measured
cost was 17,960 violations (7.01 % of the 256,296 standing at iteration 7) — the same
iterations the row-1 figure below prices by subtraction.

**Where DRT actually is in ws_v3.** Three steps in the flow are switched off in this run
(`RUN_POST_GPL_DESIGN_REPAIR`, `RUN_POST_GRT_DESIGN_REPAIR`, `RUN_POST_GRT_RESIZER_TIMING`
— all `false` in its `resolved.json`), so the enabled sequence after the post-CTS resizer is:
37 GlobalRouting, 38 CheckAntennas, 39 DiodesOnPorts, 40 HeuristicDiodeInsertion,
41 RepairAntennas, 42 STAMidPNR, **43 DetailedRouting**, 44 RemoveRoutingObstructions,
45 CheckAntennas, **46 Checker.TrDRC**. Step 43 is the one the watcher waits for (it finds
the step by name, not by number); step 46 is where a count above 0 stops the flow with
`ERROR_ON_TR_DRC: true`. Its own fixture tests (`--selftest`, 10 cases built from the curves
in this section) plus six end-to-end box tests—real v8 log, real 0.2 arm log, live growing
log, clean pass, no-DRT log, and the kill guard against a run that is not routing—pass.

**Time the cap removes.** On the tapeout layout (12.93 mm² slot core, 8 threads — the
count this flow also resolves `DRT_THREADS` to, since it is unset and the box has 8), the
fast loop's own `DRT-0267` lines give **37:55** for the initial route and **26:05 / 25:25**
for optimization iterations 1 and 2 (`drt_fast/logs/grt02_drt.log`, GRT_ADJUSTMENT 0.2).
The default 64 is therefore ≈ 38 min + 64 × ~26 min ≈ **28 h** of detailed routing, and that
is a floor: the fast loop routes the bare core ODB while this flow routes the assembled die.
The only unbounded run, v8, spent **10.6 days** in step 43 (2026-10-01 01:26 →
2026-10-11 15:58) for 26 optimization iterations, with its own `DRT-0267` lines recording
single iterations of 34 min early on growing to 16–27 h later. At 8, the step budgets
≈ 38 min + 8 × 26 min ≈ **4 h**.

**Violations the cap costs.** The only full-length violation curve on this design is v8's
(fat core, GRT 0.0, `build/v8_flow.log`, `DRT-0199` lines); no unbounded run exists on the
tapeout layout, so the cost is quoted against that curve's floor. The tapeout-layout curve
at 0.2 is measured only to iteration 2 — 764,679 → 265,661 → 254,201 — and those first three
points are **identical** to v8's, so the cap changes nothing about iterations 0–2; it only
truncates what follows:

| iteration | 0 | 1 | 2 | 4 | 8 | 12 | 16 | 17 | 25 |
|---|---|---|---|---|---|---|---|---|---|
| v8 violations | 1,081,775 | 405,529 | 387,049 | 266,147 | 254,306 | 242,556 | **237,089** | 649,172 | 711,100 |
| above that floor | +844,686 | +168,440 | +149,960 | +29,058 | **+17,217** | +5,467 | 0 | +412,083 | +474,011 |

* The minimum is **interior**: iteration 16 is the best point the unbounded router reached,
  iteration 17 is 2.74× worse and iteration 25 is 3.0× worse. Uncapped iterations therefore
  buy a longer walk that can end far above the router's own best — the strongest argument
  for a cap that does not rest on wall clock at all.
* **Cap 2** (the convention every fast-loop sweep row was measured at): 387,049, i.e.
  **+149,960 (+63.2 %)** above the floor.
* **Cap 8** (chosen): 254,306, i.e. **+17,217 (+7.3 %)**, and by iteration 8 the curve is
  inside its plateau at −0.5 % to −0.8 % per iteration.
* **Cap 16** would recover exactly those 17,217 and double the wall clock to ≈ 7 h.

**What this does and does not buy.** It does not make the step pass: the tapeout layout is
at 254,201 TrDRC violations after 2 iterations on the core and `ERROR_ON_TR_DRC` is `True`
with threshold 0, so the checker fails the step at any cap. What the cap buys is a
**verdict in hours** — converging, stalled or diverging — plus the tapeout layout's own
iteration curve, which is the measurement that does not exist yet; if that curve is still
falling steeply at 8, the cap is the first thing to raise. It does not touch the open
falsifier experiment (0.2 vs 0.3 at full iteration count,
[grt_adjustment_sweep.md](grt_adjustment_sweep.md)): that runs in the standalone fast loop,
whose `FAST_END_ITER` is independent of the flow config.

**Not yet verified:** the flow has not run with the key set — `ws_v3` is past its config
load with the old resolved value (`resolved.json`: `"DRT_OPT_ITERS": 64`), so the 8 is a
config edit whose effect on a run is unobserved. The first run that carries it will show it
in `resolved.json` and in the `DRT-0195`/`DRT-0199` iteration lines.

## 4. Submission mechanics that are already right

* **Die geometry is an exact match.** `precheck/scripts/klayout/check_size.py` requires
  the 1×1 die to be `3880 + 2×26 × 5070 + 2×26` = **3932 × 5122 µm**; the template's
  `slot_1x1.yaml` `DIE_AREA` is `[0, 0, 3932, 5122]`. Origin at (0,0), dbu 0.001, 5LM
  stack (precheck errors on `Via5`/`MetalTop`).
* **The seal ring is required and the flow provides it.** `check_size.py:64-74` errors if
  layer `GUARD_RING_MK` (167/5) is unused; the template's `librelane/config.yaml:8` inserts
  `KLayout.SealRing` before `KLayout.Render`, so the Chip flow stamps it.
* **CoB path is alive.** `chip_top.sv` already instantiates the four `gf180mcu_ws_ip__*`
  marker/ID cells; `precheck.py --cob` additionally checks pad openings against
  `assets/golden_masks/mask_1x1.gds` and generates the ID cell.
* **Upload target:** `platform.wafer.space` (accepts GDS or OASIS).

## 5. External gap: there is no slot to buy (Run 3)

* wafer.space news, 22 Sep 2026: **1×1 sold out**, half/quarter remaining.
* Today the Crowd Supply Run 3 listing shows **all four sizes "No longer available"**.
* Run 3 dates still on the books: slot purchase **9 Dec 2026**, clean GDS **16 Dec 2026**
  (AoE) — moot without a slot, but live again if one frees up (notify list only, no queue).
* Run 4: page exists, "launching soon", **no date**.
* Only a 1×1 can carry this die: halves are 1.94 × 5.12 or 3.93 × 2.53 mm, the die is
  3.93 × 5.12 mm; the core is 12.92 mm² at 45.9 % utilization, so halving the area is not
  a re-floorplan, it is a different chip.

**Consequence:** the realistic target is **Run 4**, and the work now is to be
precheck-clean and ready to upload on day one — not to make a Run 3 deadline.

## 6. Documentation and artifact gaps

* `wafer_space_submission/` is marked SUPERSEDED, and correctly: its GDS is the pre-CTS,
  core-only legacy artifact (no pad ring, no seal ring, CTS skipped). But its README still
  reads like a submission README and its numbers are wrong for this design — 4,088 cells
  (the run has ~460 k instances), "50 MHz" (≈ 2.6 MHz implied), "0 routing violations".
* There is no submission README/report for the `ws_v3` artifact, no precheck report, and
  no written record of the setup/hold corner decision (§2).
* Bring-up: the boot-from-ROM test passes in simulation with empty SRAM, and the cache
  index/tag + MMIO read-hold fixes are landed and verified — but the bring-up binary and
  UART dividers have not been written against the ~2.6 MHz the silicon will actually run.

## 7. Gap list, ordered by what unblocks what

| # | gap | kind | closed by |
|---|---|---|---|
| 1 | DRT convergence (the `TrDRC` gate) | technical, open | **blocked upstream, not reached**: `ws_v3` died at step 37 (GRT-0183, §1) before step 43; then **capped and instrumented**: `DRT_OPT_ITERS: 8` (~4 h per pass instead of ~28 h to 10.6 days; costs +17,217 violations over the only measured full-length curve's floor), `watch_drt_curve.sh` writes the per-pass verdict automatically and queues `drt_extend_ws.sh` at step end to measure the withheld iterations on the die (§3). Next: GRT is unblocked by §1a's one-key change, but a resume now dies at `OpenROAD.RepairAntennas` (row 1c, §1b); the die's own 2-iteration curve at 0.1 is measured — 204,357 (§1b) |
| 1c | Antenna repair aborts (`repair_antennas` → `GRT-0183`, `OpenROAD.DiodeInsertion`) | technical, **root cause measured (§1d)** | at 0.1 the repair inserts 3,846 jumpers / 2,522 diodes and then its own router hits the same fatal no-path. §1d: `-jumper_only` completes on the pinned engine but leaves 1209 violations — a way past, not a repair; the 26Q4 build completes the identical call with 0 aborts and 114 violations left, but at flow level it stops at LibreLane's STA scene shim (`STA-0107`, `common/io.tcl`), so the pin needs a LibreLane/OpenSTA pairing no release has yet. Measurement-only workaround until then: `-c RUN_ANTENNA_REPAIR=false` |
| 1b | GRT aborts (`heap underflow`, step 37) | technical, **worked around; root cause split** | measured in §1a: the abort is deterministic, it is a *no-path in a bounded search region* (overflow-removal loop, Metal2 59-61 % usage, Metal1 7.6-8.6 %), and it is fatal only because `openroad-2026-02-17` predates PR #10711 (`recoverEdge` instead of aborting) and PR #11093 (FastM1 capacity). Landed `GRT_ADJUSTMENT: 0.1` — completes AND converges (0 overflow, no `GRT-0115`, 8 iterations); 0.15 and a Metal1-only relax also complete but stop short of their own budget. Re-opens if the engine pin moves past Aug 2026, which is the fix rather than the workaround |
| 2 | Setup hard error at sign-off | decision | explicit `SETUP_VIOLATION_CORNERS: [""]` in the overrides, with the true fmax published — or nothing passes the flow's own checkers |
| 3 | Hold = 2 violations at tt | technical | the post-CTS (running) and post-GRT resizers; must be 0 at sign-off; re-check then |
| 4 | Precheck never run | infrastructure | one `docker run` of the precheck image on the final GDS; image is already on the box |
| 5 | Seal ring / filler / density never exercised | technical | falls out of the same run, if it gets past DRT |
| 6 | No purchasable slot | external | Run 4 (subscribe), or a Run 3 1×1 freeing up |
| 7 | Stale submission docs, no fmax truth | documentation | write the README/report from the run's measured metrics |
| 8 | Bring-up clock/UART plan for ~2.6 MHz | firmware | a bring-up plan against the real clock |

## 8. What "ready" looks like

1. a run reaches sign-off with hold 0 and a clean route (`route__drc_errors = 0`);
2. its GDS carries `GUARD_RING_MK` and is exactly 3932 × 5122 µm;
3. `precheck.py --slot 1x1 --cob` passes on it;
4. the README/report states the measured cell count, the real closable frequency, and the
   setup/slew/cap numbers as they are;
5. a Run 4 1×1 slot is bought and the `.oas` is uploaded to `platform.wafer.space`.
