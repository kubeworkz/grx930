# Tape-out GDSII for the wafer.space shuttle — plan and state (2026-10-11)

Goal: a GDS that passes wafer.space's pre-check and can be bonded onto the development
board that also carries the GPU and the photonic tensor accelerator.

## 1. The deliverable, defined by the pre-check

`gf180mcu-precheck/precheck.py` requires: a single top cell; origin (0,0); dbu 0.001 µm;
**max metal Metal5**; die dimensions equal to the slot (1×1 → 3932 × 5122 µm); with `--cob`,
the four `gf180mcu_ws_ip__*` marker/ID cells exactly once at the template's positions;
pad openings matching the slot's pad mask; density within limits; no zero-area polygons;
KLayout antenna; magic DRC; KLayout DRC. It imports `librelane.steps.klayout`, so it runs
in a **LibreLane ≥ 3** environment.

## 2. Which flow produces it (decision)

The pad ring is not optional and is not ours to redesign: pad positions, pad count, power
pads and the marker/QR cells come from `gf180mcu-project-template` and are what both the
pre-check and the standard breakout PCB expect. Two consequences, both checked against the
template on disk:

* `make librelane-padring` / `librelane/config_padring.yaml` builds a pad ring **for analog
  designs** — synthesis → floorplan → `OpenROAD.PadRing` → `Odb.ManualMacroPlacement` →
  `KLayout.StreamOut` → `KLayout.SealRing`, with **no router**. A digital core cannot be
  merged in with it. The hybrid "route the core in OL2, add the ring afterwards" plan is
  therefore dead.
* The submission must come from the template's **full `Chip` flow** with our core as
  `chip_core`. `chip_top.sv`, `slot_1x1.yaml`, `macros_5v.yaml`, `pdn_cfg.tcl` and
  `chip_top.sdc` stay as shipped; only `src/chip_core.sv` is replaced and our RTL is added
  to `VERILOG_FILES`.

Artifacts for that are in `c930/asic_gf180mcu/wafer_space_integration/`:

* `chip_core_grx930.sv` — the adapter (pads ↔ `grx930_test_chip`); all eight board-facing
  signals grouped on the south edge so one die edge brings the part up on a board;
* `PAD_MAP.md` — the pad contract for that board;
* `grx930_overrides.yaml` — clock 40 ns, density 55 %, `RT_MIN_LAYER Metal1`, GRT
  adjustment (see §4), sources;
* `tb_chip_core_grx930.sv` + `run_adapter_lint.sh` — elaboration and pad-map check, no PDK
  needed. It already caught two defects that would otherwise have shipped: reversed part
  selects in the check, and bit-wise continuous assignments in the adapter that
  double-drove `bidir_oe`/`bidir_pd` (pad output-enables would have been X — every used
  pad broken).

The adapter passes: `RESULT: PASS (chip_core adapter elaborates and the pad map is live)`.

## 3. What the silicon-side correctness work already delivered

The part must boot on that board with no external loader, so the previously flagged
tapeout blocker ("the chip has no boot path") is closed:

* `grx930_test_chip_rom` — a 1 KB constant ROM at `0x0001_0000`, which is now
  `CORE_RESET_PC`, generated from `sw/test_chip_boot.hex` by `tools/gen_bootrom.py`. It is
  a constant `case` (combinational logic), *not* a memory with `initial` contents, because
  a flop-init ROM does not survive synthesis into a netlist OpenROAD can place.
* It mirrors the SRAM's 2-cycle, 256-bit-line read interface **including the hold**: the
  line stays valid past the done pulse, because the I-cache controller registers its write
  enable from that pulse and samples the fill line one cycle later, when the requesting
  controller has already dropped its address. The first version did not hold, and the core
  fetched garbage, trapped, and fell into whatever the SRAM happened to contain — invisible
  in the preloaded test, which still printed the banner.
* Evidence: `make sim SIM_PLUSARGS=+NO_PRELOAD` (empty SRAM, power-on conditions) passes
  with the same numbers as the preloaded run (banner after 1647 clocks, `0x2A5A_1234` at
  `0x400`, `0x0000_C0DE` at `0x408`, heartbeat advancing); the negative control
  `SIM_DEFS=-DROM_DISABLE` fails with zero UART bytes. `make check_rom` guards ROM/hex
  drift, `make fw` regenerates both together.

Also already fixed in this tree and required for a correct netlist: the cache index/tag
decomposition and the MMIO read-hold latch (see `PLAN_B_netlist_rework.md` §8-9, §12 of
`Claude outputs/DRT_fastloop_status.md`).

## 4. The open risk, and what decides it

Routing. On the fat layout (33 % utilisation, core = whole die) DRT diverged after 17
iterations at ~1 conflict per net pair — 222 k unique net pairs, half of them at cell-pin
geometry. The v8 flow never set `CORE_AREA`, so it had placed 369 k cells across the area
the pad ring must occupy. The 12.93 mm² slot core (the area the template uses) raises
utilisation to 51.6 % and is the layout the shuttle actually requires.

Measured knobs so far: `RT_MIN_LAYER=Metal1` is the only bottom layer that routes at all
(1.08 M initial-route violations vs 13-20 M on Metal2); the router version is not the
problem (26Q3 is 5-6 % worse consistently).

Ran on the flow box (`ubuntu@49.13.6.8`) — **both arms are now complete**:

* `drt_core` — fast DRT (2 iterations) on `pre_drt_slotcore.odb` (12.93 mm² core,
  `GRT_ADJUSTMENT 0.0`), started 00:50, finished 04:00 UTC; baseline to beat was
  1,081,775 / 405,529 / 387,049;
* `grt03c_chain` — the same layout with the stock `GRT_ADJUSTMENT 0.3` (the
  configuration the diagnosis in `DRT_fastloop_status.md` §7 said was worth
  running on the *slot* core): GRT segment 04:01-09:48, fast DRT 09:48-11:11 UTC.

Both arms' curves were captured by `build/arm_verdict_capture.sh` into
`drt_fast/verdict/arm_compare.md`. The capture itself needed two fixes — it took
the percentage rather than the count off each curve line, and its arm-2 deadline
expired nine minutes before arm 2's log landed and published the report with arm 2
blank — both fixed and the report regenerated.

| arm | GRT | iter0 | iter1 | iter2 | DRT-0199 | GRT wire | wall |
|---|---|---|---|---|---|---|---|
| fat (baseline) | 0.0 | 1,081,775 | 405,529 | 387,049 | — | 24.22 M µm | 10.6 d (killed) |
| arm 1, slot | 0.0 | 1,096,857 | 435,492 | 418,613 | 418,633 | 24.30 M µm | 3:06:08 |
| arm 2, slot | 0.3 | 659,733 | 207,748 | **191,575** | **191,578** | 28.73 M µm | **1:20:31** |

The two slot rows are a matched pair: same design dir, PDK, core geometry and DRT
arguments, and each input ODB is the endpoint of the same flow with only
`GRT_ADJUSTMENT` changed (arm 1's input 203,851,717 B = the 0.0 GRT step's output;
arm 2's 219,661,871 B = the 0.3 step's).

**Arm 1** (slot core, `GRT_ADJUSTMENT 0.0`) finished its initial route at
**1,096,857 violations** vs the baseline's **1,081,775** (+1.4 %). Its intra-route
progress curve was 5-8 % worse at every checkpoint (20 % 207,648 vs 190,579 · 30 %
274,097 vs 258,958 · 50 % 485,480 vs 449,853 · 60 % 545,285 vs 517,669 · 70 %
758,404 vs 712,201) and then converged to parity at 100 %, so the initial route is
not where the layouts separate -- the optimization iterations are.

**Correction (wirelength).** An earlier draft of this section reported arm 1 as
carrying **19,626,753 um of wire vs 24,215,167 um (-19 %)**, "the floorplan
experiment's own prediction (-20 %) delivered". That number was never measured: it
is 0.81 x 24,215,167, the prediction itself. The measured GRT wirelength for arm 1
is **24,301,804 um — +0.4 % vs the fat baseline**. The core shrink did not reduce
wirelength, and the √(area) reasoning above it is falsified — see
`DRT_fastloop_status.md` §13. The cells were already packed in a hot middle band
over a sparse skirt, so removing the skirt pulls cells together without
shortening the nets that carry the total. The same wrong figure had reached
`grx930_overrides.yaml`; corrected in both places.

**Decision: `GRT_ADJUSTMENT` is 0.3, in both flows.** Arm 2 wins the
pre-registered criterion by **2.19x** (191,578 vs 418,633 final violations) in
2.31x less DRT wall clock, and its plateau is still falling (-7.8 %/iteration)
where arm 1's has nearly stopped (-3.9 %); arm 1 would need ~20 more iterations
(~18 h) to catch up even at its own rate. Set in `openlane2_rtl/config.json` (was
0.0) and already in `wafer_space_integration/grx930_overrides.yaml`, where the
"provisional" caveat is now removed.

Two qualifications are recorded with the decision rather than hidden:

* the pre-registered guard clause — "if arm 2's GRT log shows overflow, 0.3 is
  unaffordable and the lever moves to placement" — is **broken as a test**: its
  trigger line appears in *both* logs (the 0.0 arm logs it, then clears its own
  overflow: 0 on every layer, 12.18 % usage). The discriminating line is
  `WARNING GRT-0115 Global routing finished with overflow`, which appears only at
  0.3 (15,155 across M1-M5). Read strictly the guard says "unaffordable", the
  opposite of what DRT measures. 0.3 is kept because the reservation *is* what
  produces that overflow — GRT is given ~34 % less capacity per edge and so goes
  over its own budget by construction — and with `GRT_ALLOW_CONGESTION: true` that
  is informational. The guard's real question, does reserving capacity pay out at
  DRT, is answered yes by measurement.
* 0.3 is **not** net-faster end to end: the flow tail that feeds DRT is 23x slower
  (globalrouting 3:14 → 1:17:46; repairantennas 8:45 → 4:24:27; tail total 14:34 →
  5:45:27), so the segment costs ~+3:45 net. It also costs +18.2 % wirelength.
  Neither is a reason to stay at 0.0 — 418,633 violations is not a viable
  endpoint at any speed — but it makes the **0.1/0.2 arm the higher-value next
  run**, not more DRT iterations.

## 4b. The staged flow now passes the first gates (2026-10-12 01:50 UTC)

The template run is staged on the flow box (`ws/template/`: template + our
`chip_core_grx930.sv` as `src/chip_core.sv` + 38 core sources in `asic_core/` +
`librelane/grx930_overrides.yaml`) and driven by `ws/ws_exec.sh` through
`build/ws_chain.sh`. The pre-check image is down (13.6 GB) and **is** the flow
environment: `librelane/dev` from its flake accepted the template's
`meta.version: 3` config, resolved the pad ring and ws_ip macros, instantiated
the adapter, and built the hierarchy in 0.8 s.

Two Verilator errors stopped it at `Checker.LintErrors` (step 2/83, "2 Lint
errors found", exit 2), both `MULTIDRIVEN`: `NEXT` in each cache controller was
written by the `initial` block (a simulator-only t=0 initializer, documented in
the files) and by the `always_comb` FSM. A **declaration initializer is also a
second writer** to Verilator -- that attempt failed identically, and a first
attempt with the explanatory comment *starting* with the word "Verilator" failed
earlier still with `BADVLTPRAGMA`, because Verilator parses such comments as
pragmas.

Fixed by removing the FSM initializer outright in both controllers (`STATE`,
`NEXT` are defined before the first clock edge by the async reset, asserted from
t=0). Verified from both ends: `make sim` and `make sim SIM_PLUSARGS=+NO_PRELOAD`
still pass with byte-identical numbers (heartbeat 0x0 -> 0xe3f), and in the flow
`Verilator.Lint` reports clean, `Checker.LintErrors` passes and the run exits 0.

So the RTL changes that must be in the final netlist now also include this lint
fix -- together with the cache index/tag fix, the MMIO read-hold fix and the boot
ROM, all of which is why the final run must be a fresh synthesis.

## 4c. First synthesis attempt: it is a memory question, not a design question

Staged flow, tag `ws_synth1`, run concurrently with arm 1's DRT under a 4 GB
container cap (`--memory=4g --memory-swap=4g`): lint passed (154 warnings, no
errors -- the `MULTIDRIVEN` fix holds), `Yosys.Synthesis` ran for 19 minutes and
was **OOM-killed inside ABC** (`docker inspect` -> `OOMKilled=true`), so the flow
exited 2. The cap did its job: `drt_core` was never touched (6.2-6.25 GB RSS
throughout), and the cgroup limit means the synthesis can only ever kill itself.
So chip_top + pad ring + the 370 k-cell core needs **more than 4 GB** of
Yosys/ABC -- the core alone synthesized on this box in the OL2 runs, so this is
the pad ring + ws_ip + the (now larger) RTL, not a new failure mode.

Retry is armed and window-aware: `build/ws_synth_chain.sh` (tag `ws_synth2`,
cap 8g) waits until no `drt_core*`/`ol2_*` container is alive -- the first such
window is when arm 1's DRT finishes (~04:00 UTC, during arm 2's GRT segment) --
then runs the flow to `Checker.YosysSynthChecks` and writes
`ws/logs/netlist_compare.ws_synth2.txt`.

**Comparison baseline, measured** (`openlane2_rtl/runs/slotcore_v1/06-yosys-synthesis/grx930_test_chip.nl.v`,
32.8 MB, the pre-ROM/pre-fix core-only netlist): 1 module (flattened),
**217,836 std cells in 79 types**, 0 pads, 0 ws_ip, 0 ROM. Top types: nand2_1
88,270; dffq_1 27,520; oai21_1 23,027; nand3_1 14,564; clkinv_1 13,727; buf_1
11,242. (The 370 k *instances* the DRT loop sees are this netlist plus the
flow's later tap/fill/diode cells.)

What the new netlist must show to count as a match, pre-registered so the
comparison is falsifiable: ~217.8 k std cells plus the known RTL deltas -- the
ROM's constant logic (absent from the OL2 netlist entirely), +48 tag flops per
cache from the derived tag width, +64 flops and a mux for the MMIO read-hold,
and nothing from the lint fix -- plus 74 `gf180mcu_fd_io__` pad macros
(6 DVDD + 8 DVSS + 2 VDD + 2 VSS + 12 `in_c` + 40 `bi_24t` + 2 `asig_5p0` +
`clk`/`rst_n`) and 5 `gf180mcu_ws_ip__` cells (QR, shuttle, project, marker,
logo). The staged RTL was fingerprint-checked against the repo (five files,
md5-identical) so the netlist really is built from the current tree.

## 4d. Chip-top synthesis: the netlist matches the OL2 one (2026-10-12 04:04 UTC)

The window opened when arm 1's DRT finished (04:00:24), the chain launched the
synthesis with the 10 GB cap, and it completed in **4 minutes** -- the 4 GB
first attempt was the only reason it had failed. Outcome: `WS_EXIT:0`,
`Checker.LintErrors` clear, `Checker.YosysUnmappedCells` clear, 154 lint
warnings. Netlist: `ws/template/librelane/runs/ws_synth2/` (hierarchy view in
`06-yosys-synthesis/chip_top.nl.v`, flattened submission view in `final/nl/`),
inventory in `ws/logs/netlist_compare.ws_synth2.txt`.

| metric | OL2 `slotcore_v1` (core only) | new `ws_synth2` (chip_top) | expected |
|---|---|---|---|
| std cell instances | 217,836 | **209,522** | ~217.8 k + ROM |
| distinct std cell types | 79 | (redistributed) | -- |
| `dffq_1` | 27,520 | **27,616 (+96)** | +48 tag flops x 2 caches |
| `gf180mcu_fd_io__*` pads | 0 | **74** | 40 `bi_24t` + 13 `in_c` + 10 `dvss` + 8 `dvdd` + 2 `asig_5p0` + 1 `in_s` |
| `gf180mcu_ws_ip__*` | 0 | **5** | QR, shuttle, project, marker, logo |
| ROM | 0 | **instantiated** | `Used module: ...grx930_test_chip_rom` in the hierarchy log |
| modules (hierarchy) | 1 (was flattened) | 235 used modules | -- |

So: same design, same core hierarchy, the ROM really is in it, the pad ring and
the five marker cells are there, and the flip-flop delta is **exactly** the
predicted cost of the tag-width fix (+96 `dffq_1`). The one real difference is
that the new netlist is 3.8 % *smaller* in logic cells -- and that is the
toolchain, not the RTL: this flow runs **Yosys 0.66** (from LibreLane's nix
shell) against the OL2 baseline's **Yosys 0.46**, both confirmed from the two
synthesis logs, with the cell-type mix redistributed accordingly (e.g.
`oai21_1` 23,027 -> 18,621, `aoi22_1` appears at 10,295).

Two notes for the record: the flattened `final/nl` netlist cannot be grepped for
submodule names (my first ROM check reported 0 because of it -- fixed in
`build/ws_synth_chain.sh`), and the ROM's exact gate cost was not extracted
because Yosys' `stat` label differs from the grep I used.

## 5. Traps already paid for (do not re-learn)

* The September GDS is **void** — pre-fix RTL, SRAM optimised away, no CTS. Never submit it.
* Re-running a flow step on an existing run tag **reuses that tag's netlist**; the RTL has
  changed since. The final run must use a fresh tag.
* The pre-check cannot run in the OL2 2.3.10 image (it imports `librelane`); plan a
  LibreLane ≥ 3 container for it. The image *does* have KLayout+pya and magic, which is
  what a DRC/antenna pass needs.
* Each flow container `volare fetch`es its own ~3 GB PDK copy; `docker rm -f` on finished
  containers is what keeps the 150 GB volume alive. Measured 2026-10-12 01:57: 10 GB free,
  with `docker system df` reporting 24.94 GB of unused images, 3.9 GB of stopped
  containers and 5.46 GB of volumes. `docker container prune -f` + `docker volume prune -f`
  recovered 3.9 GB (14 GB free) without touching the running `drt_core`. Still reclaimable
  if the final flow needs it: `openroad/orfs:latest` (6.55 GB) and
  `openroad/ubuntu22.04-dev:latest` (4.82 GB), both leftovers -- the OL2 image, the
  pre-check image and `openroad/ubuntu24.04` (the 26Q3 A/B) must stay.

## 6. Flow engine — settled (2026-10-12)

Checked inside the OpenLane2 2.3.10 image the OL2 work uses:

* it *does* support `substituting_steps` (the template's `config.yaml` relies on it), but
  its meta-version handling tops out at 2 (`default_meta_version = 2`), so the template's
  `meta.version: 3` needs a one-line edit;
* the string `PadRing` and the variable `PAD_SOUTH` **appear nowhere in the package** and
  its flow list is only `Optimizing / Classic / VHDLClassic / OpenInKLayout /
  OpenInOpenROAD / OpenInMagic / SynthesisExploration`. OpenLane2 2.3.10 has no pad-ring
  step, so the template's flow cannot run there at all.

So the template run needs **LibreLane ≥ 3**, and the cleanest source of it is the image
wafer.space already publishes for the pre-check,
`ghcr.io/wafer-space/gf180mcu-precheck`: its `flake.nix` pulls
`github:librelane/librelane/dev` into a `librelane-shell` (LibreLane + klayout + magic +
openroad + yosys + `ciel`, plus `gnumake` and `procps` for the density deck), pins that
librelane in `flake.lock`, and clones the `gf180mcuD` PDK into the image at build time
(`PDK_ROOT=/workspace/gf180mcu`). One container therefore runs both the chip flow and
`precheck.py`, with no nix install on the box. The pull is running on the flow box
(`ws/precheck_pull.log`); 28 GB free beforehand.

## 7. Next actions, in order

1. ~~Read the two DRT arms' verdicts; set `GRT_ADJUSTMENT`/density from evidence.~~
   **Done (2026-10-12 15:05 UTC):** 0.3 set in both flows on a 2.19× violation win in
   2.31× less DRT wall clock; see §4a. Open follow-up: a 0.1/0.2 arm, which the flow-tail
   cost (23× slower at 0.3) now makes the higher-value next run.
2. Stage `wafer_space_integration/` into `ws/template/` on the flow box; run the full
   template flow from a fresh tag inside the pre-check image.
3. Run the pre-check (`--slot 1x1 --cob`) on the resulting GDS in the same image; fix
   findings; package.
