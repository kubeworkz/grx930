# GRX930 on wafer.space — status and indicative schedule

*Status as of 26 October 2026, 20:10 local (27 October 2026, 00:10 UTC). Every figure is measured from a run or a report in the tree; the routing number is live and moves while the current pass runs.*

## In one paragraph

The silicon-side design is done and verified in simulation; the physical implementation is one step from done. The part intended for the shuttle is a **single-core** GRX930 test chip in the template's 1×1 pad ring, booting from its own ROM with no external loader. The flow now completes synthesis, placement, clock tree insertion, global routing and — for the first time — **the full antenna repair, in-flow, with 1,710 diodes inserted**, and it is inside detailed routing with a curve that is falling: 461,079 → 75,455 violations in the first pass, and 542,150 → 258,713 in the second after the repair re-routed the diode-carrying database. Iterations now cost 12–50 minutes rather than 16–27 hours. It is not yet clean, and the pass-over-pass restart level is what decides the date. On the shuttle side the position is unchanged and now verified: **Run 3's full-size slots are sold out**, so the binding deadline is whichever date Run 4 is announced with.

## What changed since the 24 October edition

* **Antenna repair is closed.** A week ago the step aborted (`GRT-0183`) and the arm had to run jumper-only with 1,209 violations deliberately left in. On the pinned 26Q4 engine the same step completes and the flow proceeds on a fully repaired database.
* **Detailed routing turned.** The edition before last described 1.03 M → 1.65 M violations with each pass ending worse. Today's arm ends its first pass at **75,455** and is inside its second at 258,713, classified converging.
* **Iteration cost collapsed.** 16–27 hour iterations were what made this look like months; the same step now lands a round in under an hour, and a wall-clock guard stops any round that does not.

## What is actually going to the shuttle

| | |
|---|---|
| Process | GF180MCU, 180 nm, 5LM_1TM_11K, `gf180mcu_fd_sc_mcu7t5v0` |
| Slot / die | 1×1, **3932 × 5122 µm**, origin (0,0), dbu 0.001 µm |
| Core | 3048 × 4238 µm = **12.93 mm²**, ~46 % utilization |
| CPU | 1× RV64IMAC, 5-stage, 512 B I + 512 B D cache (16 × 32 B lines) |
| Memory | 2 KB on-chip SRAM + 1 KB boot ROM at `0x0001_0000` (`CORE_RESET_PC`) |
| I/O | UART, GPIO, one external interrupt, 74 pad openings (template ring) |
| Frequency | see *Timing* below — the 40 ns data paths close (25 MHz) once the reset tree is fixed; 50 MHz needs a re-floorplan |

**On "quad-core".** The quad-core SoC (4× RV64IMAC, 2 NPUs, 64 KB shared L2, write-through MSI-lite directory) is a real, FPGA-validated design — timing closed on the Artix-7 at ~121 MHz, 0 failing endpoints — but it is not this shuttle part. Its memory architecture was frozen on 28 Oct 2026 as **configuration B**: main memory moves off-chip, removing 26.8 mm² of SRAM macro and putting the part at **86.4 mm² of content** (46.2 mm² of cells + 40.2 mm² of macro) — **not the ~46 mm² earlier editions quoted**, which counted the cells and none of the memories. On the area model that costed the 2×4, that is a **~165 mm² die at 46 % row utilisation — a ~12.9 mm square**, and **≈€151k** at EUROPRACTICE's published €913/mm² (≈€147k at 161 mm², ≈€161k at a 177 mm² relief valve). GlobalFoundries' own shuttle terms are unpublished, and **wafer.space cannot build it:** 20.12 mm² is its largest die (confirmed 27 Oct 2026). Putting it on silicon is therefore its own decision with its own supplier, downstream of this vehicle proving the flow. Details: `wafer_space_integration/quadcore_submission_scope.md` §4.

## Status by stage

| Stage | State | Evidence |
|---|---|---|
| RTL, boot, bring-up | **done** | boots from ROM with empty SRAM (`+NO_PRELOAD` PASS); `-DROM_DISABLE` control fails; cache index/tag and MMIO read-hold fixes landed |
| Pad ring + adapter | **done** | template `chip_top.sv`/`slot_1x1.yaml` unmodified; adapter lint PASS (caught two real defects); precheck stage-3 slot size passes on the template artifact |
| Global routing | **done** | `GRT-0183` root-caused to a no-path in a bounded search region; `GRT_ADJUSTMENT 0.1` converges with 0 overflow on every layer in 8 sweeps |
| Antenna repair | **done** | in-flow on the 26Q4 engine: **1,710 diodes inserted**, step completes; the same step aborted on the pinned build |
| Active-layer density | **done, not yet on this core** | replacement fill reaches COMP 31.27 % / Poly2 26.25 % (floors 25 / 14) with 0 deck violations; the PDK default missed both |
| GDS stream-out | **done** | rebuilt from DEF + PDK library; the previous artifact had LEF-indexed layers, 229 cell abstracts and 30,130 cells in the wrong rows |
| Netlist vs layout (structural) | **done** | CDL-vs-DEF compare `MATCH`: 53,745 instances, 0 unmatched, 0 DEF-only |
| **Detailed routing** | **in progress — falling** | pass 0 **461,079 → 75,455**; repair re-route **542,150 → 258,713** and iterating; gate requires 0 |
| Timing | **reset tree** | data paths close at 40 ns (−0.064 ns on the pinned engine); a 2,132-load `clkbuf_16` on reset does not. Hold −2.44 ns on both engines |
| Precheck on a core GDS | **never run** | pad-mask offset (74 openings 0.5 µm inside the golden mask) and a 5 nm grid snap are known items |
| Shuttle slot | **unavailable** | Run 3 full-size slots sold out (confirmed 26 Oct); Run 4 undated |

## The blocker, in numbers

The live arm is the die with its antenna repair completed, routed on OpenROAD 26Q4, capped at 8 optimisation rounds per pass and re-routed up to 10 times by the antenna-repair loop. Two passes are in the log:

| pass | start | rounds, in order | standing |
|---|---|---|---|
| 0 | 461,079 | 461,079 → 273,018 → 251,227 → 145,595 → 115,794 → 100,318 → 89,865 → 83,371 → **75,455** | capped after 8 rounds, −83.6 % |
| 1 | 542,150 | 542,150 → 297,665 → 275,717 → **258,713** → (4th round open) | converging, mean gain 20.7 %/round |

The restart is higher than the pass-0 floor because the antenna repair inserted its diodes into the routed database and the router re-lands every net they touch. The question the schedule turns on is not the within-pass slope — that is healthy — but whether the **next** pass starts below 542,150 and ends below 75,455. If the restart level falls pass over pass, the loop closes; if it stays above the previous floor, the repair is adding more disturbance than the router removes and the configuration changes below are back on the critical path.

Three things changed the cost of finding out. Iterations are measured at **12–50 minutes**, with a single 84-minute outlier, against the 16–27 hours recorded on the earlier core-only curve. A wall-clock and regression guard watches every pass and stops the first of: a round past 2 h, a pass past 8 h, 30 minutes of silence in an open round, a count 25 % above the pass's best, or three rounds each buying less than 0.25 %. It fired once today (a 2 h round, on an earlier launch) and the arm was relaunched; since then every round has landed inside its budget. And the step log is line-buffered end to end, so a silent router and a stalled one are now distinguishable — the guard's 30-minute rule is real rather than nominal.

The one standing operational risk is disk: the flow box is at **9.4 GB free of 150 GB (94 % used)**, and a pass writes a ~400 MB database. A guard polls the volume and prunes old route trees at the soft threshold, so the arm is protected, but headroom is thin and the spare ARM box (217 GB free) is where the next arm would go.

## Timing

The 24 October edition carried two STA readings of the same database and could not reconcile them. They are reconciled now, and neither was a design change: the −345 ns row was taken *before* the post-CTS resizer, and the flow's own next STA step reads −0.100 ns on that same database. Re-running the post-repair STA on the pinned engine, through the flow's own tool, reproduces its control to five figures and gives:

| measurement | engine | setup WNS | setup TNS | endpoints | 40 ns? |
|---|---|---|---|---|---|
| post-CTS, before the resizer (13 Oct) | pinned | −345.20 ns | — | 30,490 | superseded |
| post-resizer (13 Oct) | pinned | −0.100 ns | −2.01 ns | 43 | yes |
| post-repair (27 Oct) | pinned | **−0.064 ns** | −0.62 ns | 28 | yes |
| post-repair (27 Oct) | 26Q4 | −8.646 ns | −6,808 ns | 2,393 | no |

The two engines disagree by 8.6 ns on identical input, and the whole difference is one net: `split25`, a `clkbuf_16` driving **2,132 loads** with a 21–47 ns transition against a 3 ns limit. Both engines flag that transition as illegal and charge it differently (0.39 ns against 18.55 ns at the load pin), plus a 10.5 ns difference in how a recovery check is timed. So the useful statement is not a single WNS:

* the **40 ns data paths close** (−0.064 ns, i.e. 25 MHz), and did before the repair;
* the **reset distribution does not**, on either engine, and that is a buffering fix rather than a frequency decision;
* hold is −2.44 ns on both engines, so it is a real item for the resizer.

Until the reset tree is fixed, no frequency should be quoted; after it, 40 ns is the target and 50 MHz needs a re-floorplan. Report: `wafer_space_integration/sta_engine_reconciliation.md`.

## Indicative timeframes

| Milestone | Estimate | Confidence | What moves it |
|---|---|---|---|
| A routing curve that reaches zero | 1–3 weeks of iteration | medium | whether the pass-over-pass restart level falls; a configuration change is ~2 h per experiment in the fast loop |
| Clean route → GDS → precheck pass | 2–4 weeks after that | medium-low | each pre-routing change forces a re-route; each precheck run is ~9 h, and the pad-mask/grid items need a re-spin |
| **GDS ready to upload** | **late November 2026 at the earliest; December 2026–Q1 2027 is the realistic band** | medium-low | routing convergence above; nothing else is on the critical path |
| Run 3 (clean GDS 16 Dec 2026) | **not achievable, and moot** | high | full-size slots sold out; purchase closed to us |
| Run 4 | date unknown | — | wafer.space has not published one; we will be precheck-clean and uploadable on day one |
| Silicon in hand | follows the shuttle, not us | high | Run 3 parts are quoted for Q2 2027; Run 4 ships on its own schedule |

Budget unchanged: **$8,000** for the 1×1 slot, **$1,500** for chip-on-board, with the CoB option kept alive in the layout (the four marker cells are already instantiated).

## What we need decided

1. **Reset buffering, then the target clock** — fix the 2,132-load reset buffer so both engines agree, and confirm 40 ns (25 MHz) as the target; 50 MHz needs a re-floorplan. The part boots either way.
2. **Quad-core vehicle** — wafer.space is out (no die above 1×1); whether to open a foundry enquiry now — GlobalFoundries' shuttle, or EUROPRACTICE's GF180MCU shuttle at a published €913/mm² — or hold until this vehicle has taped out.
3. **Slot strategy** — watch for a released Run 3 full-size slot and subscribe for Run 4 notification, or accept that the first silicon lands on Run 4's calendar.

## Evidence trail

Every figure above traces to a run or a report. These are the ones a reviewer would ask for.

| Claim | Source | How it was measured |
|---|---|---|
| Global routing closes at 0 overflow | run `ws_v3` step 37 | one-knob probes on the frozen pre-GRT state, ~7 min each; `wafer_space_integration/probe_grt.sh` |
| Antenna repair completes, 1,710 diodes | run `dielb01` step 04 | the 26Q4 engine in-flow; the pinned build aborts with `GRT-0183` on the same database |
| DRT pass 0: 461,079 → 75,455 | run `dielb01` step 06 | the step's own `DRT-0195` / `DRT-0199` lines, segmented per pass by `watch_drt_curve.sh` |
| Timing: −0.064 ns pinned, −8.646 ns 26Q4 | `sta_engine_reconciliation.md` | single-step LibreLane resume on identical state; the control reproduces the flow's −0.0999734 ns to five figures |
| Density 31.27 % / 26.25 %, 0 deck violations | `wafer_space_integration/fill/` | the gf180mcuD deck in the pre-check image, deep mode, on the flow's own GDS |
| Structural LVS `MATCH` | `build/lvs_chip/net_compare.json` | CDL vs DEF: 53,745 instances each, 0 unmatched, 0 DEF-only |
| Run 3 full-size slots sold out | Crowd Supply campaign page | read 26 Oct 2026; the site still shows 9 Dec purchase / 16 Dec GDS dates |
| No die above 1×1 is offered | wafer.space, 27 Oct 2026 | the four published slot sizes are the catalogue; `--slot` is a closed enum in the pre-check and `check_size.py` exits on anything else |

*Prepared from the run tree on the flow box and the reports in `Claude outputs/` (`ws_run3_readiness_gaps.md` is the full gap register). Figures are point-in-time; the detailed routing count changes with every round.*
