# Antenna residue waiver — GRX930 test chip, wafer.space GF180MCU 1×1

**Status:** accepted, conditional (§6). **Date:** 2026-10-21. **Scope:** the pre-DRT antenna
repair residue on the GRX930 core inside the wafer.space project-template wrapper.

This document does two things: it records *why* the residue exists and how large it is, and it
records the decision to proceed with what the paired engine (OpenROAD 26Q4 + LibreLane `#1023`)
still leaves. Every number below is a measurement already in the tree; nothing is extrapolated,
and §5 says plainly what is still unmeasured.

## 1. What is being waived

The pre-DRT antenna repair (`OpenROAD.RepairAntennas` → `OpenROAD.DiodeInsertion`, run through
`scripts/openroad/antenna_repair.tcl`) cannot complete on the engine the flow image pins,
`openroad-2026-02-17` (LibreLane 3.1.0.dev1). The abort is `[ERROR GRT-0183] Net _167563_: heap
underflow during 3D maze routing` — a no-path in the repair's own global-router pass, made fatal
only because that build predates upstream `#11404` (`recoverEdge` instead of abort). Measured
outcomes, all on the same die database:

| configuration | engine | repair outcome | violations left |
|---|---|---|---|
| as designed (diodes + jumpers) | pinned, as shipped | **aborts**: 2,979 found → 3,846 jumpers over 2,080 nets, re-check 1,299, then 2,522 diodes and `GRT-0183` | 1,299 (at abort) |
| `GRT_ANTENNA_REPAIR_JUMPER_ONLY=true` | pinned | completes, 49:37, converging (last iteration inserts 0) | **1,209** — no diodes at all |
| `GRT_ANTENNA_REPAIR_DIODE_ONLY=true` | pinned | completes, 22:55, 8,749 diodes | **522** |
| unmodified repair (probe) | OpenROAD 26Q4 `26Q4-407-geb14e40b7b` | completes, rc=0, no abort, writes the only diode-inserted die database this project had | **114** |
| unmodified repair **in the flow** | 26Q4 + LibreLane `#1023`, tag `died26q4` | completes and converges: 3,020 → 5,368 diodes, 1,102 → 1,658, 343 → 454 | **78** nets (94 pins) |

Evidence: `Claude outputs/die_to_drt_antenna_and_pin.md` §1d, §2, §5; probe logs
`ws/probe/out*/{jumper_only,diode_only,base}.log`; databases under `ws/probe/out*/`. The flow-level
row is `runs/died26q4` (2026-10-21), chain log `ws/logs/die_diode_flow_chain.log`, repair
`04-openroad-repairantennas/1-openroad-diodeinsertion/openroad-diodeinsertion.log`, post-repair check
`04-openroad-repairantennas/2-openroad-checkantennas/reports/antenna_summary.rpt` — copied into this
repo as `build/antenna/died26q4_antenna_summary.rpt`, sha256 `129e7916…`.

The waiver covers the residue as it exists **at the pre-DRT stage**, on the configuration that
produces it today. It does not claim 78 is the figure in the final routed design — §5 explains why
that number cannot be read off yet.

## 2. What the flow does with a non-zero residue

It continues, and it says so:

* the post-repair `CheckAntennas` does not stop the flow. On the jumper-only arm it measured
  **1,989 pin / 1,113 net**; on the paired engine it measures **94 pin / 78 net** (`died26q4`, the
  report captured in §1);
* detailed routing's own antenna stage then ran on the routed database and **inserted 4,013
  diodes** (`diejmp01`, §4.2 of the same note).

So the residue is not silently discarded, and the pre-route figure is not the post-route figure.
What is missing is the post-route count.

## 3. Why wafer.space's own gate does not catch this

Their pre-check has an antenna stage, but it is the **KLayout** antenna deck, a different engine
with different rules from OpenROAD's `check_antennas`. On the wrapper artifact (`tpl02`) it reported
**0 violations on every `ANT.*` rule** (`Claude outputs/evidence_run2/README.md`).

That silence is not evidence about GRX930, for two reasons, and both belong in the record:

1. it was measured on the **placeholder core**, not on this design;
2. **no GDS of the real design exists yet**, so that stage has never seen our geometry at all.

A clean KLayout antenna result on the final GDS would therefore *not* retroactively justify this
waiver; it would only mean the two engines disagree. The waiver rests on OpenROAD's count, which is
the one that measures the construct the repair was trying to fix.

## 4. What the risk actually is

An antenna violation means a net whose long interconnect connects to a gate with no diode path to
the substrate, so charge collected during plasma etch has nowhere to go but through the gate oxide.
The standard consequence is **latent damage**, not immediate failure: threshold shift, increased
gate leakage, reduced lifetime margin. It is not screened at wafer probe, so a damaged part can
test good and drift later.

Two qualifiers that make this design's exposure narrower than the count alone suggests, and one
that widens it:

* the core is built from `gf180mcu_fd_sc_mcu7t5v0` — the **5 V** library, whose `dualgate`
  marker is drawn in the library and present in the DRC tally — and thicker gate oxide is
  generally more tolerant of charge than the thin-oxide flavour;
* the residue is a *count over nets*, not an area: 78 nets against the core's ~210 k standard
  cells (`ws_synth2`, 209,522) is a sparse set, not a global condition;
* but the affected nets are the ones with the **longest** metal — which on this floorplan are the
  clock and the die-spanning rails — so the per-net severity is not uniform and a count cannot say
  which ones matter. That list is what §6.1 records.

## 5. What this waiver does not assert

Recorded explicitly so the decision is not read as stronger than it is:

1. **The post-route residue is measured, the step's own repair reduces it, and the loop has not
   exited.** On the routed database the step runs `check_antennas` → `repair_antennas` → re-route,
   and each round is measured here at the point it ends (`DRT-0198`):

   | pass | last DRT count (`DRT-0199`) | post-route check (net / pin) | repair's own count (`GRT-0012`) | diodes inserted (`GRT-0015`) | ended (UTC) |
   |---|---|---|---|---|---|
   | 0 | 75,459 | 1,055 / 1,341 | 1,269 | 1,710 | 2026-10-22 04:48 |
   | 1 | 236,580 | **319 / 369** | 406 | 489 | 2026-10-22 13:31 |
   | 2 | in flight | — | — | — | started 13:36 |

   So routing does not consume the pre-route residue: pass 0 measures more than an order of magnitude
   above the 78 the pre-route check reported. What reduces it is the step's diodes, and they take it
   down by about 70 % per round — 1,055 → 319 nets, 1,341 → 369 pins. The loop keeps running while
   an iteration is still inserting diodes (`drt.tcl:85-121`, capped at `DRT_ANTENNA_REPAIR_ITERS =
   10`), and round 2 inserted 489, so it is not converged. **319 / 369 is the best post-route
   measurement, not the final one.** One pass costs 6-9 h on this box (pass 0 5 h 59 m, pass 1 8 h
   43 m, wall from the step's own directories). Raw lines behind the table, with log line numbers and
   the source log's sha256: `doc/antenna_evidence_died26q4_rounds.txt`.

   The count at the loop's exit is what closes condition 3, and it does not exist yet. The harvester
   `build/harvest_died26q4.sh` freezes every antenna line and the curve into
   `drt_fast/verdict/died26q4_post_route.txt` when the arm exits. The curve watcher is **not** a
   record for this run: `wafer_space_integration/watch_drt_curve.sh` found the detailed-routing log
   at 23:33:05 UTC on 2026-10-21 and parsed `diejmp01`'s curve out of it (pass 0, best 27,758, n=9 —
   that arm's numbers, not this run's 75,459), wrote `ws/logs/drt_verdict.md` under the `died26q4`
   tag from them, and has written nothing since (`drt_state.tsv` untouched since 2026-10-16). Read
   the step log, not that file. That curve is `diejmp01`'s because the watcher trusted any log it
   found in the run tree; it now identifies the log by the run its step's `state_in.json` names,
   refuses one another arm produced (`LOG_FOREIGN_REFUSED`), and keeps one state file per run
   (`drt_state_<tag>.tsv`) — fixed and self-tested 2026-10-22, after this reading.
2. **The captured list is post-repair; the jumper-only list is missing.** The 78 nets attached in
   §6.1 are the ones the paired engine still carries after its repair. The jumper-only arm's list
   was never copied off the flow box (`ws/probe/out/jumper_only/`), and it is no longer the
   configuration this waiver covers.
3. **No GDS of the real design has ever been checked by any antenna engine.** The only die-shaped
   artifact is the template's placeholder core.

## 6. Conditions of acceptance

The waiver is valid only while all four hold. If any fails, the residue becomes a blocker again.

1. **The per-net list is captured** — `build/antenna/died26q4_antenna_summary.rpt`, 94 rows,
   sha256 `129e7916…`, copied from
   `04-openroad-repairantennas/2-openroad-checkantennas/reports/antenna_summary.rpt`. If a later run
   changes the repair, capture its report the same way rather than counting.
2. **Run the KLayout antenna stage on the final GDS** and record it beside this waiver — not as
   justification, but so a disagreement between the two engines is on the record.
3. **Post-route re-measurement runs to the repair loop's exit, not to a fixed pass.** The number to
   sign against is the check the loop makes when it stops inserting diodes (or at the 10-iteration
   cap), on the database it then routes. Measured so far: **1,055 net / 1,341 pin** after pass 0,
   **319 / 369** after pass 1, both with more diodes inserted afterwards (§5.1). 78 stays a pre-route
   figure and neither post-route pair is the number to sign against. This condition closes when the
   loop exits and that check's count — and its per-net list, captured the way §6.1 captures the
   pre-DRT one — is in the tree. If the exit count is not near zero, the waiver does not carry; it is
   re-decided with that number.
4. **Disclose it to wafer.space** with the submission. There is no formal waiver process in their
   pre-check for this; the honest route is to say what the design carries, rather than rely on a
   gate that does not test it.

## 7. The pairing, measured (2026-10-21, routing through 2026-10-22 13:31 UTC)

This section used to say the pairing had never run end to end. It has now run — the arm that was
queued in October and never harvested, tag `died26q4`. The flow resumed the same frozen step-36
state every earlier arm consumed, with OpenROAD 26Q4 `26Q4-407-geb14e40b7b` supplied through
`_LLN_OVERRIDE_OPENROAD` and LibreLane `#1023` backported in-container
(`PATCH_LLN status=applied pr=1023 … edits=4 checks=6`).

What it settles:

* **the pairing works.** No `GRT-0183` and no `STA-0107` anywhere in the run tree; steps
  `01-openroad-globalrouting` through `06-openroad-detailedrouting` all exist, and `resolved.json`
  reads `RUN_ANTENNA_REPAIR: true` — the unmodified flow, not a restricted variant;
* **the repair completes and converges**: 3,020 found → 5,368 diodes, 1,102 → 1,658, 343 → 454;
* **the residue drops by an order of magnitude at that stage**: 94 pin / 78 net against the
  jumper-only arm's 1,989 / 1,113 — with the caveat §5.1 now carries, that routing takes it back up
  to 1,055 net / 1,341 pin before the router's own repair, which then cuts it to 319 / 369.

Still open, and it is a routing question rather than an engine one. Detailed routing has completed
two passes. Pass 0 ended at **75,459** (493,072 → 273,018 → 251,238 → 145,610 → 115,794 → 100,323 →
89,865 → 83,375 → 75,459) at 04:48 UTC on 2026-10-22; its antenna check measured 1,055 / 1,341 and
the step inserted 1,710 diodes. Pass 1 ended at **236,580** (577,541 → … → 236,580) at 13:31 UTC;
its check measured **319 / 369** and the step inserted 489 more diodes, so pass 2 has been re-routing
since 13:36. Note also that the routed result does not pass sign-off for a reason unrelated to this
waiver: 236,580 detail-route violations against a gate of 0 (`ERROR_ON_TR_DRC`). The post-repair
antenna number comes from the repair loop's exit, not from pass 1 (§5.1, §6.3).

When the arm exits, the records to read are the chain's `drt_fast/verdict/die_diode_flow_arm.md` and
the harvester's `drt_fast/verdict/died26q4_post_route.txt`. The watcher's `ws/logs/drt_verdict.md`
is not one of them — it latched a stale log at start and has written nothing since (§5.1).

## 8. Decision

* Residue accepted at the pre-DRT stage at **78 nets / 94 pins** — the paired-engine measurement —
  conditional on §6. The post-route numbers are **1,055 net / 1,341 pin** after pass 0 and **319 /
  369** after pass 1 (§5.1), both taken before the repair loop exits; the accepted figure is the
  exit count. The earlier expectation that the post-route figure would be the *larger* number is
  measured wrong in both directions: routing raises the residue by an order of magnitude, and the
  step's diodes then cut it by about 70 % per round.
* Configuration covered: the unmodified flow on the paired engine (`RUN_ANTENNA_REPAIR: true`,
  `GRT_ADJUSTMENT: 0.1`, `DRT_OPT_ITERS: 8`). The jumper-only (1,209) and diode-only (522) variants
  are no longer needed and are not covered here.
* Superseded at the arm's exit: if the repair loop's exit count is materially different from
  **319 / 369**, this document is replaced with that number, not amended. It is not amended to a
  mid-loop figure — the two passes already measured are evidence, not the decision.

Risk owner: ____________________  Date: __________
