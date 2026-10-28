# wafer.space integration — how the final GDS is produced

The submission is judged by [gf180mcu-precheck](https://github.com/wafer-space/gf180mcu-precheck)
(single top cell, origin at 0,0, dbu 0.001 µm, max metal **Metal5**, die size equal to the
slot, CoB marker cells present, pad openings matching the slot's pad mask, density, no
zero-area polygons, antenna, magic DRC, KLayout DRC). Two facts decide the whole path:

1. **The layout must include the pad ring**, and the pad ring is the template's — pad
   positions, pad count, power pads and the QR/logo/marker cells come from
   `gf180mcu-project-template` as-is, because that is what the pre-check and the standard
   breakout PCB expect. Changing them is what breaks board compatibility.
2. **The template's padring-only flow is not a merge tool.** `librelane/config_padring.yaml`
   + `scripts/padring.py` build a pad ring *for analog designs* — that flow has no
   global/detailed routing (synthesis, floorplan, `OpenROAD.PadRing`,
   `Odb.ManualMacroPlacement`, `KLayout.StreamOut`, `KLayout.SealRing`), so a digital core
   cannot be bolted on afterwards with it. The chip has to be built by the template's full
   flow (`make librelane`, i.e. LibreLane's `Chip` flow) with our core inside it.

So the deliverable is **one LibreLane run of the template with our core as `chip_core`**,
followed by the pre-check on its GDS. The OL2 core-only runs (and the fast DRT loop) are
how we find a configuration that routes; they are not the submission artifact.

## Files here

| File | Role |
|---|---|
| `chip_core_grx930.sv` | the adapter the template's `chip_top.sv` instantiates: pad ring ↔ `grx930_test_chip`. Replaces the template's demo `src/chip_core.sv` |
| `PAD_MAP.md` | which pad carries which signal (the development board's contract) |
| `grx930_overrides.yaml` | LibreLane/OpenLane overrides: design name, sources, clock, density, GRT/DRT knobs |
| `tb_chip_core_grx930.sv` | elaboration + pad-map check |
| `run_adapter_lint.sh` | runs that check against the tapeout RTL (seconds, no PDK) |
| `watch_drt_curve.sh` | watches the `OpenROAD.DetailedRouting` step's own iteration curve and writes the routing verdict (converging / stalled / diverged / clean) automatically. `--selftest` runs its fixtures with no run |
| `probe_grt.sh` | reruns only `OpenROAD.GlobalRouting` against a frozen run's own pre-GRT state with one knob changed (~7 min instead of a 3 h flow). This is how the `GRT-0183` abort in `ws_v3` was measured (§ "Pre-flighting the global router") |
| `drt_extend_ws.sh` | measures what the `DRT_OPT_ITERS` cap withheld: the fast loop on the step's own pre-DRT ODB, launched only when the flow container has left the box and `build/gate.sh` passes, writing `ws/logs/drt_cap_cost_measured.md`. Queued automatically by the watcher at step end |
| `extend_selftest.sh` | the end-to-end test of that pair with docker and memwatch stubbed (over 50 checks; launches no container and routes nothing) |
| `fill/` | the active-layer fill the flow's `KLayout.Filler` step runs (dummy COMP + dummy Poly2). `fill_active.rb` is a drop-in replacement for the PDK's `fill_all.rb`; `README.md` there records the deck evidence, the measurements and the wiring |
| `sram_macro_surrogate.md` | the 1×1 vehicle's first use of a real foundry macro: eight `sram512x8` blocks replace part of the FF cache array so the macro path (MACROS, fixed placement, PDN straps over a macro, STA against the vendor `.lib`) runs at the utilisation this part already routes. Records what the flow proved and the four defects it caught first. Built by `macros_grx930_sram.yaml`, `pdn_cfg_grx930_sram.tcl` and `grx930_sram_surrogate.yaml`, launched by `../ws/sram_surrogate_exec.sh` and `../build/sram_surrogate_chain.sh` |
| `quadcore_submission_scope.md` | the separate question of putting the four-core SoC on silicon: what the wrapper needs, what the memories cost in SRAM macros, what the pad ring implies, and the risks. **Not part of this vehicle's path to GDS** — and not a wafer.space part at all: §8 prices the foundry routes now that the slot question is answered. **Configuration frozen 28 Oct 2026:** memory config B (§4) — main memory off-chip, 86.4 mm² of content, ~165 mm² planned die, and the 92-pad memory port that goes with it |
| `quadcore_slot_enquiry.md` | the slot-size enquiry, **answered 27 Oct 2026: no** — the four published sizes are the catalogue, so there is no larger die, no multi-slot block and no custom large-die service. Kept as the record of the question and the numbers it carried |
| `quadcore_gf_enquiry.md` | the enquiry that replaces it: a written maximum design area, a reticle-field answer and a price for a 161 mm² GF180MCU die on GlobalFoundries' own shuttle, or the private-run terms if a die that size is refused. **Submitted 27 Oct 2026** through GF's MPW form (which caps the message at 700 characters, so the submitted text is recorded verbatim); also carries the EUROPRACTICE / Fraunhofer IIS email, **sent 27 Oct 2026** from the project mailbox, and the NDA pack that followed it — that order is NDA-gated and entity-only |
| `nda_pack/` | the NDA-gated step of that route, filled and **sent to Fraunhofer IIS 27 Oct 2026** (both attachments hash-verified against the prepared files): EUROPRACTICE's published `NDA_Request_Form` (Word) and its questionnaire (a five-slide project deck, `Template_UPP`) filled field for field from this project's record, the entity's own details (signatory Dave Cook, Owner; Fort Erie, Ontario) included, nothing left but the signature. Holds the pristine originals (with sha256), the two prepared files and `fill_pack.py`, which rebuilds them from the originals with no dependencies; `README.md` there lists what is filled, what remains and the send record |

Check the adapter before any flow run — it already caught two real defects (reversed part
selects in the testbench, and, in the adapter, bit-wise continuous assignments that
double-drove `bidir_oe`/`bidir_pd`, leaving pad output-enables at X):

```
sh wafer_space_integration/run_adapter_lint.sh
```

## Assembling and running

**Engine: use the pre-check image for both steps.** The flow box (`ubuntu@49.13.6.8`,
`/home/ubuntu/grx930_ol2`) has no nix, and the OpenLane2 2.3.10 image the OL2 investigation
uses cannot run this template at all: its flow list is `Optimizing / Classic / VHDLClassic /
OpenIn* / SynthesisExploration` and the strings `PadRing` / `PAD_SOUTH` appear nowhere in
the installed package — OpenLane2 2.3.x has no pad-ring step (it does support
`substituting_steps`, and its meta versions stop at 2, so the template's `meta.version: 3`
is also a mismatch).

`ghcr.io/wafer-space/gf180mcu-precheck` is the right environment: its `flake.nix` builds a
`librelane-shell` from `github:librelane/librelane/dev` (LibreLane + klayout + magic +
openroad + yosys + `ciel`, plus `gnumake` and `procps`, which the open_pdks density deck
shells out to), pins it in `flake.lock`, and clones the `gf180mcuD` PDK into the image
(`PDK_ROOT=/workspace/gf180mcu`, `PDK=gf180mcuD`). Same container, same versions as the
gate we have to pass.

If the pinned `librelane/dev` ever disagrees with the template's config schema, the
fallback is the LibreLane image (`ghcr.io/librelane/librelane`) with `ciel enable` for the
PDK; what is *not* worth trying is bending the configs down to 2.3.10.

Staging (paths as the flow expects; `asic_core/` is the tapeout RTL minus the two unused
ROM modules):

```
ws/template/            <- gf180mcu-project-template checkout
ws/template/src/chip_core.sv   <- chip_core_grx930.sv
ws/template/src/generated_defines.svh   <- `define SLOT_1X1 / SRAM_gf180mcu_fd_ip_sram
ws/template/librelane/grx930_overrides.yaml
ws/template/asic_core/*.sv      <- c930/asic_gf180mcu/openlane2_rtl/src minus c930_bootrom.sv, bootrom_wrapper.sv
ws/template/fill/*.rb   <- wafer_space_integration/fill/*.rb   (KLAYOUT_FILLER_SCRIPT points here)
```

Run (container side), once the version question above is settled:

```
openlane --run-tag ws_v1 --pdk gf180mcuD --manual-pdk \
    librelane/slots/slot_1x1.yaml \
    librelane/macros/macros_5v.yaml \
    librelane/config.yaml \
    librelane/grx930_overrides.yaml
```

That staging list's last line is not optional: `grx930_overrides.yaml` sets `KLAYOUT_FILLER_SCRIPT` to
`dir::../fill/fill_active.rb`, so the flow's `KLayout.Filler` step reads the staged copy. Skip the
staging and the step fails at `klayout -r` with a missing file — which is the loud failure, but
only if the step is reached. See `fill/README.md` for what that fill does to the two global
density rules and why [this section below](#global-active-layer-density-dcf1b-and-pl8) exists.

Pre-check (LibreLane ≥ 3 environment):

```
export PDK_ROOT=<pdk root> PDK=gf180mcuD
python3 precheck.py --slot 1x1 --cob --input chip_top.gds --id <id> --workers max --output chip_top.oas
```

`--cob` is the right flag while the CoB option is open: the template's `chip_top.sv`
already instantiates the four `gf180mcu_ws_ip__*` marker/ID cells the CoB check looks for,
so the flag costs nothing and keeps the chip-on-board option alive.

## Global active-layer density (DCF.1b and PL.8)

The pre-check measures two global floors over the whole die, and neither cares where the shapes
are: COMP + dummy COMP ≥ 25 % (DCF.1b, ≤ 70 % by DCF.1d) and Poly2 + dummy Poly2 ≥ 14 % (PL.8, no
upper bound). The template flow's `KLayout.Filler` step produces the active-layer fill, and the
PDK default it runs (`fill_all.rb`) **misses both floors on this die**: on the artifact the flow
produces today (`tpl02/92-klayout-filler/chip_top.gds`, i.e. `submit/run1/chip_top.gds`) the
gf180mcuD deck reports COMP **20.182 %** and Poly2 **12.992 %**. That is the pre-check's own "2
KLayout density errors found". The replacement in `fill/` reaches **31.274 %** and **26.254 %** with
the same deck, and `DRC RESULT: SUCCESS (0 violations)` on the `dummy_comp` and `dummy_poly2`
decks. `fill/README.md` has the details, including the two rules the fill *deliberately* does not
honour (the deck comments them out), the DCF.2b stagger trap that the first version fell into, and
what re-enabling either costs.

## Pre-flighting the global router

The one step that can stop a run dead *before* any route exists is
`OpenROAD.GlobalRouting`, and its most confusing failure is
`[ERROR GRT-0183] Net <name>: heap underflow during 3D maze routing`. That is not a
violated constraint and not a corrupted net: it is the maze router finding no legal path
within the search region for one edge while it is trying to *improve* an already-routed
edge, so the route it abandons is the one it had. `probe_grt.sh` reruns that step alone
against the failed step's own `state_in.json` — the exact ODB GRT was handed — with one
knob changed, and prints the outcome off the step's own log:

```
docker run --rm --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
    -e PROBE_TAG=grt_probe_it1 -e GRT_OVERFLOW_ITERS=1 \
    ghcr.io/wafer-space/gf180mcu-precheck /work/ws/probe_grt.sh
```

Measured that way on 2026-10-13 against `ws_v3`'s frozen step-37 state (each arm ~7 min,
3 GiB, one thread; the abort reproduces deterministically on the same net at the same
iteration, so a retry is not a fix):

| arm | GRT end | iterations | final overflow | `GRT-0115` |
|---|---|---|---|---|
| as run (`GRT_ADJUSTMENT` 0.2) | abort, `net21814` | 14 | — | — |
| 0.1 — now the value in `grx930_overrides.yaml` | completes | 8 | **0 on every layer** | no |
| 0.15 | completes | 12 | 18 (M2 2, M4 16) | yes |
| `GRT_OVERFLOW_ITERS` 1 | completes | 1 | 63,525 (M2 47,168) | yes |
| M1 layer adjustment `-0.2`, 0.2 kept | completes | 13 | 7 | yes |

The last row is the useful negative result: it leaves Metal2-Metal5 resources byte-identical
to the 0.2 arms and gives Metal1 +52 % (709,799 → 1,080,188), and GRT still completes — so
the failing region was never "Metal1 out of tracks" (Metal1 runs at 7.6-8.6 % usage,
Metal2 at 59-61 %); it was a local no-path that more capacity anywhere breaks. The check
that decides when this can be undone is the engine pin: the pre-check image's
`openroad-2026-02-17` predates the two Aug 2026 GRT fixes (PR #10711 keeps the edge's
original route instead of aborting; PR #11093 fixes the FastRoute blocked-track charge),
and with those in, 0.2 becomes runnable again.

**The die's own DRT at 0.1 is measured (2026-10-14).** The 0.1 landing left one number
outstanding — what the give-back costs on the layout that ships — and it is now measured:
`build/die_drt_chain.sh` resumes the same frozen state through `STAMidPNR-3` at 0.1 and feeds
the resulting database to the fast loop (2 iterations, Metal1–Metal5, 8 threads, `-or_seed 42`,
in the pre-check image): **353,871 → 213,354 → 204,357** at iteration 2, 1:15:42 wall, 8.1 GiB
peak, curve classified CONVERGING. That is cleaner than the slot core at 0.2 (254,201), so the
price paid here for a 0.1 that completes is smaller on the die than the sweep's core-side
number.

**And the next blocker, filed with it:** with antenna repair enabled the die dies one step
later, inside `OpenROAD.RepairAntennas` → `OpenROAD.DiodeInsertion`, where `repair_antennas`'
own global-router pass hits the same fatal `GRT-0183` (after 3,846 jumpers and 2,522 diodes).
So the measurement above runs on the post-GlobalRouting database with
`-c RUN_ANTENNA_REPAIR=false` — the only pre-DRT state the die reaches on this build — and the
engine pin remains the fix for both. Report: `Claude outputs/die_drt_at01.md`; the full
register: `Claude outputs/ws_run3_readiness_gaps.md` §1b.

**The timing number, reconciled.** The die's post-repair STA was re-run on the pinned engine
(`dcf36133`) through LibreLane itself: it reads **−0.0640 ns** where the 26Q4 build reads
**−8.646 ns**, and the replicating control (the post-resizer database, where the flow's own step 36
says −0.0999734 ns) comes back identical to five figures. The whole difference sits on one net —
`split25`, a `clkbuf_16` driving 2,132 loads with a 21–47 ns transition against a 3 ns limit — so
the data paths close at 40 ns while the reset distribution does not. The pinned build cannot even
open the 26Q4 ODB (schema 0.141 > 0.126); the comparison runs through the repair step's own DEF.
Report: [`sta_engine_reconciliation.md`](sta_engine_reconciliation.md).

**And the same step on arm64, measured.** A full flow from RTL on an `aarch64` box,
same engine commit and same 0.1 config, completes GRT with 0 overflow on every
layer and then `DiodeInsertion` aborts with the same `GRT-0183` after 4,187 jumpers
and 2,688 diodes — an ARM arm is not a way around the engine pin. That run needed
5 extra iterations against the x86 resume's 8, on 3.25 % less wire; replaying the
die's own database on the ARM box (2026-10-26, `diea6401`) shows that difference
was the netlist, not the host: same 8 sweeps, same 39,459,512 µm, same 1,656,170
vias and the same per-layer demand as x86, and the same `GRT-0183` net `_167563_`.
Per-sweep cost favours neither host on that evidence (244 s against 217 s for the
sweep loop). Report: [`arm64_grt_equivalence.md`](arm64_grt_equivalence.md).

**And the reset that made the discrepancy.** `split25` is not a timing defect but a missing
constraint: LibreLane's CTS passes no `-clk_nets`, so an asynchronous reset is never treed, and
the post-CTS resizer's load splitting answers one 4,265-load net with a single buffer in front of
the same 2,132 loads. The CTS step now declares the reset as a clock root
(`ws/tools/lln_reset_cts.sh`, sourced by both flow exec scripts): measured on the core's pre-CTS
database with the step's own argument list, that turns the one 4,265-load net into 210 nets of
11–23 loads. With the reset bounded, the two engines stop disagreeing — −36.097 and −36.0969 ns
WNS on the legalized repair, against −0.0640 and −8.6457 ns on the database it started from —
which is what makes the engine question and the design question separable. Report:
[`reset_distribution_fix.md`](reset_distribution_fix.md).

## Watching the routing verdict

`watch_drt_curve.sh` reads the DRT step's own `DRT-0195` / `DRT-0199` lines and says what the
router is doing, so the verdict does not need a human to babysit a step that runs for hours
(or, before the cap, for 10.6 days):

```
bash ws/watch_drt_curve.sh --tag <run tag>     # watch the newest run, poll every 60 s
bash ws/watch_drt_curve.sh --log <log> --once  # verdict on a finished log
bash ws/watch_drt_curve.sh --selftest          # fixtures only, no run needed
```

It segments the log **per `detailed_route` pass** — the step re-routes up to
`DRT_ANTENNA_REPAIR_ITERS` times (see the header of `grx930_overrides.yaml`), so a single
curve is the wrong model — classifies each pass against thresholds taken from the only
full-length curve this design has (`build/v8_flow.log`: interior minimum at iteration 16,
2.74x spike at iteration 17), and rewrites `ws/logs/drt_verdict.md` and `.txt` on every new
count. `--kill` (or `WATCH_KILL=1`, with `WATCH_KILL_ON=diverged|stalled|both`) stops the step
on the armed verdict by sending SIGTERM to the OpenROAD process whose command line names the
routing script: flag-only by default, and it cannot touch a run that is not in detailed
routing. `build/ws_chain.sh` starts a watcher with every flow run.

**The watcher reports; the bound is `build/drt_curve_guard.sh`.** A verdict is only worth having
if something acts on it, and the two measured ways a pass burns days need different clocks: v8's
late iterations cost 16-27 h each, which the iteration cap cannot see, and one iteration handed
back 2.74x of the best route the pass had already found, which is not slow convergence but a walk
away from the answer. So every chain that launches a flow DRT container starts the guard
(`build/curve_guard.sh`), and it stops the pass on the first of: an iteration still running past
`ITER_BUDGET_S` (2 h, against the measured 26:05 per iteration), a pass past `PASS_BUDGET_S` (8 h,
against the capped ~4 h), an **open iteration that has printed nothing for `STALL_LOG_S`** (30 min),
a count 25 % above this pass's best, or three iterations that each bought less than 0.25 %. It acts
only after the log has shown a `DRT-0195`, so it cannot touch a flow still in synthesis or in the
antenna repair between passes, and a stop is a `docker kill` that loses the pass -- the flow writes
its ODB at the end of one -- which is why `GUARD_STOP=0` records the request instead.

The no-progress bound is the only one that acts before an iteration finishes, and it is therefore
the only one that could be fooled by the engine's buffering. It was: before `465a678`, OpenROAD's
raw progress writes sat in an 8 KB stdio buffer and LibreLane's own `log_file` added a second one,
so a healthy step log could be unchanged for hours (on `diecg01`, 182 lines arrived in one flush
after 42 minutes of silence, and iteration 0's count and iteration 1's start carried the same
timestamp). Both buffers are gone -- the wrapper preloads the extraction's `libstdbuf.so` and
`step.py` opens the log with `buffering=1` (`ws/tools/lln_logflush.sh`) -- and measured on
`dielb01` each decile now reaches the log as a 95-byte write within a poll. The guard still refuses
to fire on a log it has never seen flush mid-iteration (`CURVE_NO_PROGRESS_UNOBSERVED`), so an
image that loses the patch falls back to the wall-clock budgets instead of stopping a healthy pass.

Its selftest drives every branch on a pinned clock and runs in CI as row `drt-curve-guard` of
`build/chain_selftests.sh`.

A log path does **not** identify its run: a resumed run tree can hold the previous arm's step
directory, log included, and the counts carry no tag — on 2026-10-21 that made `died26q4`'s
watcher report `diejmp01`'s curve under the new tag. So the log is identified by the step's own
`state_in.json`, which names the run that produced the database the step routed: a log owned by
another run is refused (`LOG_FOREIGN_REFUSED`, one event, then it waits for this run's own log)
instead of being reported, a log with no `state_in.json` beside it is flagged
`LOG_OWNER_UNVERIFIED` rather than trusted, and every report carries a `Log identity:` line. The
state file is per run for the same reason (`ws/logs/drt_state_<tag>.tsv`); a shared one let one
arm's iteration stamps be read back as another's.

When the step ends — LibreLane writes its `runtime.txt` at the end, pass or fail — the watcher
writes `ws/logs/drt_cap_cost.md` and retires. That report prices the `DRT_OPT_ITERS` cap on the
die it actually ran on: the per-pass curve, the count standing at the cap, the measured
per-iteration wall clock against the 26:05 / 25:25 min core-only baseline, a labelled
extrapolation of the tail rate (with the "this is not a run, it is a rewrite" reading when the
plateau is effectively permanent), and the exact fast-loop command that *measures* the
iterations the cap withheld — run on the step's own input ODB, read from its `state_in.json`,
so it routes the identical database. `--finalize` writes that report by hand at any time.

**That report closes its own loop.** The extrapolation in it is the one number no file on the box
can supply, so when the step ends with the tail still falling faster than the classifier's own
stall rate (1 %/iteration), the watcher hands the step's own database to `drt_extend_ws.sh` and
retires: nothing has to be watching, and `WATCH_EXTEND=0` (or `--no-extend`) turns it off. The
runner is deliberately not allowed to race the flow for this 8-core box — it waits for the
`ws_flow` container to exit, refuses while any other router is running, and then passes the same
`build/gate.sh` gate every chain here uses before it launches the fast loop with
`-droute_end_iter` at 2x the cap (16 by default). It stamps each iteration as it appears, so the
withheld iterations' wall clock is measured rather than inferred, and it writes
`drt_cap_cost_measured.md`: the **instrument check** (the extension's first iterations must
reproduce the flow's own counts exactly — when they do not, it says so and quotes no cost), the
count standing at the cap, the count after the extension, and the difference, which is what the
cap actually cost. The extension's own tail is then classified by the same watcher, so the
verdict on the withheld iterations comes from the one instrument whose thresholds were set
against `build/v8_flow.log`.

Verify that pair without a run (docker and memwatch are stubbed; no container is launched and
nothing is routed):

```
bash wafer_space_integration/extend_selftest.sh     # over 50 checks, incl. the watcher/runner handoff
```

## What is already verified locally

* the core boots standalone from its ROM with an empty SRAM —
  `make sim SIM_PLUSARGS=+NO_PRELOAD` passes; the `-DROM_DISABLE` control fails
  (see `PLAN_B_netlist_rework.md` §8 and the main `README.md`);
* the adapter elaborates with the 1×1 pad counts and its pad map is live
  (`run_adapter_lint.sh`, and the check is in `tb_chip_core_grx930.sv`).

## Open items

1. A configuration that routes: the OL2 fast-DRT arm on the 12.93 mm² core is running and
   decides `GRT_ADJUSTMENT` (0.0 vs stock 0.3) and the bottom layer (`Metal1`, already
   settled). The final run must be a **fresh synthesis** — resuming an old run tag reuses
   its netlist, and the RTL has since gained the cache index/tag fix, the MMIO read-hold
   fix and the boot ROM.
2. Pad-ring + seal-ring DRC on the assembled GDS (the template's own IP, but never run
   with this core).
3. The pre-check image's LibreLane pin (`librelane/dev` at `flake.lock`) is newer than the
   template's own nix shell; run the template's configs as-is and treat a schema error as a
   signal to check that pin, not to edit the template.
