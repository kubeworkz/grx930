# The reset distribution on the die: the 2,132-load buffer, and the 8.6 ns it hid

Date: 2026-10-27. Asked: fix the 2,132-load reset buffer by constraining reset nets in
CTS and `repair_design`, then re-run both engines and confirm they agree on the
post-repair WNS.

**Answer, in one paragraph.** Both engines now read the same database the same way. On the
repaired die database the pinned build (`dcf36133`) and the 26Q4 build
(`geb14e40b7b`) report **setup WNS −35.2862 ns and TNS −127,512 identically** — against
−0.0640 ns / −8.6457 ns on the unrepaired one. The 8.6 ns was never a design datum: it
was two engines extrapolating the delay of a transition 7–16× over its limit on a net
with 2,132 loads, and it disappears the moment that net stops being one net. The buffer
that created it is `split25`, a `clkbuf_16` inserted by `ResizerTimingPostCTS`
(`[INFO RSZ-0045] Inserted 2954 buffers, 133 to split loads.`) — load splitting re-drives
a fanout, it does not bound it. CTS is the pass that bounds it and the patch wired by this
change (`ws/tools/lln_reset_cts.sh`) gives it the reset nets; measured on the core's
pre-CTS database it takes 4,266 pins to 3 on the root with 164 buffers. What the flow
could *not* do is constrain the reset net by name for the repair: this build refuses
per-net and per-pin `set_max_fanout` (`[ERROR STA-0100] unsupported object type …`), so
the reset is constrained only by the design-wide limits every net already has.

## 1. Where the 2,132-load buffer comes from

Not from the antenna repair, and not from CTS — from the *post-CTS resizer's* answer to an
over-loaded net. From the flow's own logs (die run `ws_v3`, the database the die's routing
arm descends from):

| step | what it did |
|---|---|
| 33 `OpenROAD.CTS` | trees the SDC clock only; LibreLane passes no `-clk_nets`. Reset untouched: `i_chip_core.rst_n` = 4,266 pins, 4,204 sequential loads |
| 35 `ResizerTimingPostCTS` | `[INFO RSZ-0045] Inserted 2954 buffers, 133 to split loads.` — 133 nets split, one buffer each |
| result | `split25`, a `clkbuf_16`, driving `net25` with **2,132 loads** |

The die's own database, read by `ws/probe/reset_check.sh` (2026-10-27), fanout over the whole
design:

| net | loads |
|---|---|
| `net25` (reset, behind `split25`) | **2,132** |
| `net` / `net143` / `net4` / `net1` / `net1639` / `i_chip_core.rst_n` | 1,113 / 1,067 / 650 / 557 / 536 / 535 |
| next 8 | 406, 357, 334, 325, 283, 250, 240, 204 |

Against `MAX_FANOUT_CONSTRAINT: 10`. And against `MAX_TRANSITION_CONSTRAINT: 3`:

| point | pinned | 26Q4 |
|---|---|---|
| slew at `_351675_/RN` | 21.297 ns | 46.791 ns |
| delay charged at that pin | 0.387 ns | 18.550 ns |
| setup WNS (same database, same corner) | −0.0640 ns | −8.6457 ns |

Full path-by-path detail: `sta_engine_reconciliation.md` §4.

## 2. The CTS half, and what it can and cannot do

`ws/tools/librelane_reset_cts_patch.py`, installed by `ws/tools/lln_reset_cts.sh` (sourced
by `ws/ws_exec.sh` and `ws/die_predrt_exec.sh` next to `lln_logflush.sh`), patches the
image's `scripts/openroad/cts.tcl` so the CTS step **declares the reset as a clock root**
for that step (`create_clock` on the pin driving each over-limit reset net). CTS trees the
nets the SDC declares as clocks, so that is what puts the reset in its net list. The nets
are found from the reset pad (master `*in_c*`/`*in_s*`, `Y` output) and followed through
buffers, so a fragmented database is covered too; `CTS_RESET_NETS` names them explicitly
when a run wants to be deterministic, and the pad glob can be changed with
`CTS_RESET_NET_PATTERN`.

That it actually installs is measured, not assumed, because the patch writes into
`/nix/store`: on both hosts a fresh container runs
`ws/probe/reset_cts_install_check.sh` and answers
`PATCH_LLN_RESET_CTS status=applied` with the librelane path it changed — `1vqjb59f…`
(aarch64, 2.31.100.64) and `sn70lxqv…` (x86_64, 49.13.6.8), both
`python3.13-librelane-3.1.0.dev1`. A read-only store would have answered `status=read-only`
and left the flow untouched; that is the failure this check exists to catch, and it is why
the wrapper prints a line instead of failing silently.

**Why not `-clk_nets`** (the first version of this patch did that, and it is wrong
here): passing `-clk_nets` replaces LibreLane's own net discovery, so the clock's net has
to be named too — and on both of this design's databases it has no database name.
`get_nets -of_objects [get_pins $CLOCK_NET]` answers with an OpenSTA synthetic handle
(`_b09185b2e7bf0000_p_Net` on the core, `_b8927b36aec60000_p_Net` on the die), and a name
CTS cannot resolve is `[ERROR CTS-0056]`. That would trade the clock tree for the reset
tree. Declaring a clock leaves the step's own discovery alone.

Measured by running the patched region itself, against the core's pre-CTS database
(`ws_arm64_v1/32-openroad-detailedplacement`), with the step's own argument list
(`ws/probe/reset_cts_procs_check.sh`) — not by a hand-written equivalent:

| | before | after |
|---|---|---|
| reset nets over the 10-load limit | 1 (`i_chip_core.rst_n`, **4,265 loads**) | 210 nets at **11–23 loads**, median 14 (CTS's sink clustering bounds them at its own limit, not this design's 10, so by construction they are still over it) |
| CTS cells inserted | — | 2,392 `clkbuf` + 909 `clkload` (clock tree and reset tree together) |
| errors | — | none; the run reaches `PROCS_DONE` |

The 23-load tail is the honest part of that row: CTS bounds the reset, it does not
legalize it. What matters for the failure being fixed is the three orders of magnitude —
4,265 loads on one net, which the splitter answered with one buffer, against 210 nets whose
worst is 23, which it can answer normally.

A single-net probe run earlier (`ws/probe/reset_cts_probe.*`) measured the same thing
from the other direction: `pins_before=4266`, `sequential_loads=4204`, then CTS-0099
`Sinks 4264`, 1,068 leaf buffers, 164 `clkload` dummy loads, path depth 6–7, ~2 min.

**What it cannot do: repair a database that already has the split.** On the die's own
database CTS refuses the net it is pointed at:

```
[INFO CTS-0095] Net "i_chip_core.rst_n" found.
[WARNING CTS-0105] Net "i_chip_core.rst_n" already has clock buffer split25. Skipping...
[WARNING CTS-0105] Net "net25" already has clock buffer split25. Skipping...
[WARNING CTS-0083] No clock nets have been found.
```

(`ws/probe/resetfix/reset_tree_fix.log`, reproducing `ws/probe/reset_tree_fix.*` on
`ws/repro_sta/state/chip_top_repair_pin.odb`: the cone is 4 nets — `i_chip_core.rst_n`
535, `net1639` 536, `net143` 1,067, `net25` 2,132 — and CTS declines every one of them.)

It declines them **and still changes the netlist**, which is the reason not to try this as
a retrofit: `No valid clock nets` is a warning, not a rollback. The database that came out
of that probe has 345,431 instances against 340,141, and `i_chip_core.rst_n` left driving
**5,825** loads — worse than the 2,132 it started with. Pointing CTS at an already-split
reset is not a way to repair one; it is a way to add a second, worse distribution beside
the first. That is `repair_design`'s job (§3), and the reason the CTS half is prevention.

So the CTS half is *prevention*: it is why a fresh arm never builds `split25`. Retrofitting
an already-routed database is `repair_design`'s job, and that is the half below.

## 3. The `repair_design` half: which constraint is even expressible

The intent was to constrain the reset nets by name. On this build that is not possible:

```
set_max_fanout 10 [get_nets net25]     -> [ERROR STA-0100] unsupported object type Net.
set_max_fanout 10 [get_pins split25/Z] -> [ERROR STA-0100] unsupported object type ...
```

Measured, both forms. So the reset is constrained exactly like every other net, by the
design-wide limits the SDC sets (`MAX_FANOUT_CONSTRAINT: 10`,
`MAX_TRANSITION_CONSTRAINT: 3`, `MAX_CAPACITANCE_CONSTRAINT: 0.2`), and the missing piece
was never the constraint — it was the pass that enforces it. `repair_design` is off at both
of its positions (`RUN_POST_GPL_DESIGN_REPAIR: false` by this design's decision, see
`grx930_overrides.yaml`; `RUN_POST_GRT_DESIGN_REPAIR` at LibreLane's own default `false`).

Run on the die's database with the transition and capacitance limits raised so that fanout
is the only thing it has to fix (`ws/probe/reset_repair_fix.tcl` +
`ws/probe/repair_sdc.tcl`):

```
[INFO RSZ-0034] Found 27 slew violations.
[INFO RSZ-0035] Found 2104 fanout violations.
[INFO RSZ-0036] Found 1 capacitance violations.
[INFO RSZ-0038] Inserted 12139 buffers in 2104 nets.
```

| | before | after |
|---|---|---|
| worst net in the design | `net25`, 2,132 loads | 172 loads (a reset net) |
| reset cone | 4 nets, all over the 10-load limit | 4 nets, worst 172 |
| instances | 340,141 | 352,280 (+12,139, +3.5 %) |
| max-fanout violations | 4,282 (pins) | 2,183 |

So the repair **bounds** the reset (2,132 → 172, a 12× reduction, three levels) but does not
**legalize** it to the 10-load limit — its fanout repair stops at its own budget. That is
CTS's strength instead (11–23 sinks per leaf, measured in §2), which is why the ordering
matters: tree it at CTS and the repair has nothing pathological left to do.

Two operational details, both measured rather than assumed, because they turn a repair run
into a different measurement:

* the flow's `repair_design.tcl` legalizes afterwards (`source scripts/openroad/common/dpl.tcl`
  → `remove_fillers`, then `detailed_placement -max_displacement {1500 500}`). Skip it and
  an STA on the result charges overlap parasitics — a property of the run, not the design;
* the positional form `detailed_placement -max_displacement 1500 500` is refused by this
  build (`[ERROR STA-0564] positional arguments not supported`).

## 4. The measurement: two engines, same database

Same corner (tt), same SDC (the *original* `chip_top.sdc` — nothing forgiven), same corner
script, same board layout; only the binary differs. WNS/TNS in ns:

| database | pinned `dcf36133` | 26Q4 `geb14e40b7b` | disagreement |
|---|---|---|---|
| die, post-antenna-repair (2,132-load `net25`) | −0.0640 / −0.6219 | −8.6457 / −6,807.63 | **8.58 ns** |
| + fanout-scoped `repair_design` (2,104 nets, +12,139 buffers) | −35.2862 / −127,512 | −35.2862 / −127,512 | **0.0000 ns** |
| + the flow's DPL on that result (`remove_fillers`, `detailed_placement`) | −36.097 / −132,191 | −36.0969 / −132,191 | **0.0001 ns** |
| hold WNS, all rows | −2.44103 … −2.27761 | −2.46154 … −2.27492 | ≤0.02 ns |

The engines agree to the digit once the illegal transition is gone. That is the claim the
reconciliation note said was pending the reset fix, and it is now measured — including the
part that matters for reading it: **−35.29 ns is not the design's timing.** It is what the
database reads after a design repair is inserted *behind* the resizer's timing work on an
already-routed database, and legalizing it does not change it (the 26Q4 leg reads −36.10 ns
legalized against −35.29 ns unlegalized). Two things follow:

* the engine question and the design question are now separable — the engines agree, so a
  WNS read off a repaired database is a property of the design and of where the repair ran,
  not of the instrument. The 8.58 ns that made the die's timing unquotable is gone: three
databases, two engines, and the largest disagreement left is 0.0001 ns;
* **a fanout repair is not a timing fix.** Inserting 12,139 buffers after the post-CTS
  resizer has done its work leaves the design slower than the resizer left it, and the
  number stays there because nothing re-optimizes afterwards. The die's database cannot be
  retrofitted into a good WNS by this pass; the fix has to be upstream of the resizer, which
  is exactly where the CTS patch puts it.

## 5. What this changes in the flow, and what it does not

* **Changed**: every arm that runs the CTS step now trees the reset
  (`ws/tools/lln_reset_cts.sh`). The post-CTS resizer no longer sees a 4,265-load net, so
  there is no `split25` for load splitting to build.
* **Documented, not enabled**: the `repair_design` positions stay off. Their fanout-only
  cost on this design is 12,139 buffers, and their real limits (79,417 max-slew, 7,036
  max-cap violations) are the explosion class measured at post-GPL
  (`+79.9 %` area, DPL abort). With the CTS tree in place, the repair has nothing
  pathological left to fix.
* **Not a design WNS**: the −36.1 ns of §4 row 3 is the legalized repair's reading, and it
  is *worse* than the −0.0640 ns it started from. A fanout repair inserted after the
  post-CTS resizer has finished leaves the design slower, and nothing re-optimizes
  afterwards, so the number stays there. It is evidence that the two engines agree, not an
  estimate of what the design can do.
* **Not established either**: any frequency claim. The 40 ns clock still has 79,417
  max-slew violations of its own to answer for on the die database; this note is about the
  reset, and about two engines agreeing on what they read.

## 6. Reproducing it

Artifacts on `ubuntu@2.31.100.64` (pinned engine) and `ubuntu@49.13.6.8` (26Q4). Every
probe writes under `ws/probe/` and never touches a flow run.

```
# 0. does the patch install in this image at all? (fresh container, both hosts)
#    -> PATCH_LLN_RESET_CTS status=applied
sh /work/ws/probe/reset_cts_install_check.sh

# 1. the reset cone and the design's fanout tail, read-only
CHECK_ODB=<odb> sh /work/ws/probe/reset_check.sh

# 2. the CTS half: the patched region of the image's own cts.tcl, with the step's own
#    argument list, against a pre-CTS database -> the §2 table
CHECK_ODB=<pre-cts odb> sh /work/ws/probe/reset_cts_procs_check.sh

# 3. the same question one net at a time (the 4,266-pin / 164-clkload probe)
PROBE_ODB=<pre-cts odb> sh /work/ws/probe/reset_cts_probe.sh

# 4. the die's own database: CTS declines a net split25 already drives -> CTS-0105
FIX_ODB=/work/ws/repro_sta/state/chip_top_repair_pin.odb \
FIX_OUT_ODB=/work/ws/probe/resetfix/chip_top_treeonly.odb \
FIX_OUT_DEF=/work/ws/probe/resetfix/chip_top_treeonly.def \
  sh /work/ws/probe/reset_tree_fix.sh

# 5. the repair half: fanout-only repair_design + the flow's DPL, from the die's database
FIX_ODB=/work/ws/repro_sta/state/chip_top_repair_pin.odb \
FIX_OUT_ODB=/work/ws/probe/resetfix/chip_top_fanrep.odb \
FIX_OUT_DEF=/work/ws/probe/resetfix/chip_top_fanrep.def \
  sh /work/ws/probe/reset_repair_fix.sh

# 6. per-net load counts straight off the DEF (engine-neutral; the §1 table)
python3 /work/ws/probe/def_fanout_probe.py <file.def> --top 20

# 7. the STA, both engines, via the corner harness in ws/repro_sta
sh run.sh <env-name>            # pinned; run.sh reads env_<name>.tcl
sh run.sh <env-name>            # 26Q4: PATH=/work/ws/tools/bin-26q4 first, and
                                # librelane_1023_io_patch.py applied in the container
```

| probe | what it produced |
|---|---|
| `reset_cts_install_check.sh` | §2's install proof, both hosts |
| `reset_check.sh` / `.tcl` | §1's fanout table, and the cone before/after a repair |
| `reset_cts_procs_check.sh` | §2's before/after table, from the image's own patched `cts.tcl` |
| `reset_cts_probe.sh` / `.tcl` | §2's single-net run: 4,266 pins → CTS-0099 4,264 sinks, 1,068 leaf buffers |
| `reset_tree_fix.sh` / `.tcl` | §2's CTS-0105 refusal on the die's already-split database — and the 5,290 extra cells it leaves behind, which is why this is not a retrofit |
| `reset_repair_fix.sh` / `.tcl` + `repair_sdc.tcl` | §3's 2,104-net / 12,139-buffer repair |
| `def_fanout_probe.py` | load counts read off a DEF, independent of either engine |
