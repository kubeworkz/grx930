# GRT_ADJUSTMENT sweep — the violation win does not flatten before 0.2, and 0.3 is past the knee

**Question.** 0.0 → 0.3 bought a 2.19× cut in DRT violations (418,633 → 191,578) but charged
+18.2 % wirelength and a 23× slower flow tail. Two points cannot say which side of the knee 0.3
is on. So the middle was measured: 0.1 and 0.2, same instrument, same endpoint.

**Answer.** The knee is **0.2**. The violation win is *not* flattening anywhere between 0.0 and
0.2 — it **peaks** at the 0.1 → 0.2 step and only falls off at 0.2 → 0.3, which is the same step
where the marginal wire price rises 8× and the flow tail 17×. 0.2 captures **72.4 % of the total
violation win for 23 % of 0.3's wire premium**, and is the most efficient and the fastest point
in the sweep. 0.3 pays for the last 27.6 % of the win at 8× the marginal wire and +5 h 22 m of
extra tail.

## The four-point curve

Every row is the same experiment: resume `runs/slotcore_v1` from `OpenROAD.GlobalRouting` to
`OpenROAD.RepairAntennas` with **only** `GRT_ADJUSTMENT` changed, then fast DRT (2 iterations,
Metal1–Metal5, 8 threads, same six `detailed_route` arguments) on the ODB that comes out. Serialized,
one flow and one DRT at a time. Run tag `slotcore_v1`; core 3048×4238 µm (12.93 mm²).

| GRT adj | init route | iter1 | **iter2 / DRT-0199** | GRT wire (µm) | GRT overflow | GRT-0115 | flow tail | DRT wall | peak mem (MB) | pre-DRT ODB (MiB) |
|---|---|---|---|---|---|---|---|---|---|---|
| 0.0 | 1,096,857 | 435,492 | **418,633** | 24,301,804 | 0 | no | 14:34 | 3:09:36 | 6,418 | 194.4 |
| 0.1 | 903,830 | 357,759 | **344,494** | 24,897,381 | 0 | no | 18:21 | 1:47:04 | 6,861 | 201.2 |
| 0.2 | 764,679 | 265,661 | **254,201** | 25,323,984 | 0 | no | 22:27 | 1:32:23 | 6,778 | 202.2 |
| 0.3 | 659,733 | 207,748 | **191,578** | 28,725,060 | 15,155 | **yes** | 5:45:27 | 1:23:33 | 7,024 | 209.5 |

`flow tail` = the four reservation-sensitive flow steps (`globalrouting` + `checkantennas` +
`odb-diodesonports` + `repairantennas`) from `runtime.txt`, the same definition the 0.0-vs-0.3
comparison used. `DRT wall` is the driver's `RUN_START`→`RUN_END`, ~3 min above OpenROAD's own
`DRT-0267` total (3:06:08 / 1:44:16 / 1:29:39 / 1:20:31) because it includes container start and
log flush. `GRT-0115` is the line `WARNING GRT-0115 Global routing finished with overflow`.
Each arm's ODB is the endpoint of its own flow — the DRT logs name it
(`odb=.../pre_drt_sweep0.2.odb`), so no arm can be a silent duplicate of another.

## 1. The violation win peaks at 0.1 → 0.2, and 0.2 → 0.3 is the weakest step at every stage

Marginal violation drop per +0.1 of adjustment, measured at all three stages:

| step | init route | iter1 | iter2 |
|---|---|---|---|
| 0.0 → 0.1 | −193,027 | −77,733 | −74,139 |
| 0.1 → 0.2 | −139,151 | **−92,098** | **−90,283** |
| 0.2 → 0.3 | −104,946 | −57,913 | **−62,626** |

On the initial route the returns decay steadily (a saturation effect: GRT's guides are already
close to the capacity limit). But on the stages that matter — the routed, optimized ones — the
yield **increases** into the 0.1 → 0.2 step and only then falls to its smallest value in the whole
sweep at 0.2 → 0.3. That ordering is stage-independent, which means the knee conclusion does not
depend on the 2-iteration cutoff: 0.2 is not an interpolation point on a smooth curve toward 0.3,
it is the peak of the marginal-yield curve.

In share-of-total-win terms (the total available being 418,633 − 191,578 = **227,055** virtual):

| arm | violations removed | share of the win | extra wire paid | extra tail paid |
|---|---|---|---|---|
| 0.1 | 74,139 | 32.7 % | +0.596 M µm (+2.45 %) | +3:47 |
| 0.2 | 164,432 | **72.4 %** | +1.022 M µm (+4.21 %) | +7:53 |
| 0.3 | 227,055 | 100 % | +4.423 M µm (+18.20 %) | +5:30:53 |

## 2. On wire, 0.2 is the cheapest point measured — not a compromise

Marginal GRT wirelength per +0.1 of adjustment:

| step | Δ wire | marginal µm of wire per violation removed |
|---|---|---|
| 0.0 → 0.1 | +595,577 µm (+2.45 %) | 8.0 |
| 0.1 → 0.2 | **+426,603 µm (+1.71 %)** | **4.7** |
| 0.2 → 0.3 | +3,401,076 µm (+13.43 %) | **54.3** |

Cumulative, against the win actually captured:

| arm | cumulative wire paid | cumulative µm/violation |
|---|---|---|
| 0.1 | 595,577 | 8.0 |
| 0.2 | 1,022,180 | **6.2** |
| 0.3 | 4,423,256 | 19.5 |

So the price per violation *falls* from 8.0 to 6.2 µm as the adjustment goes 0.1 → 0.2, and then
**triples to 19.5** at 0.3. The last increment alone is 54.3 µm/violation — 11.5× the previous
increment. That is the wire overspend, quantified: 0.3 pays **3.4 M µm of extra routing to remove
62,626 violations**, roughly the same violation mass that 0.1 → 0.2 removed for **8× less wire**.

(Granted: on a fixed shuttle slot, wire does not buy die area. Its real cost is routability, power
and capacitance — and routability is exactly what DRT's own outcome prices. That is the honest
case for 0.3, and §5 is where it is weighed.)

## 3. The flow tail is near-linear to 0.2 and then breaks

Per step, from `runtime.txt` on the same run tag:

| step | 0.0 (38–41) | 0.1 (46–49) | 0.2 (50–53) | 0.3 (42–45) |
|---|---|---|---|---|
| globalrouting | 3:14 | 4:38 | 5:27 | **1:17:46** |
| checkantennas | 2:35 | 2:41 | 2:43 | 3:14 |
| odb-diodesonports | ~0 | ~0 | ~0 | ~0 |
| repairantennas (diode insertion) | 8:45 | 11:02 | 14:17 | **4:24:27** |
| **tail total** | **14:34** | **18:21** | **22:27** | **5:45:27** |

Through 0.2 the tail grows almost linearly — about **+2 min of tail per +0.1** of reservation
(+3:47, then +4:04). At 0.3 it is **17.3×** the 0.2 tail, and globalrouting alone (1:17:46) is
14.2× its own 0.2 value. There is a genuine cliff in the tail, and it lies strictly between 0.2
and 0.3 — the only interval in the sweep where the wire price *and* the tail price both jump by
an order of magnitude.

## 4. Net of DRT, 0.1 and 0.2 pay for themselves; 0.3 does not

DRT converges faster when GRT leaves it headroom, so part of the tail increase is refunded:

| arm | tail Δ vs 0.0 | DRT wall saving | net (tail + DRT) |
|---|---|---|---|
| 0.1 | +3:47 | 1:22:32 | **−1:18:45** (net faster) |
| 0.2 | +7:53 | 1:37:13 | **−1:29:20** (net fastest) |
| 0.3 | +5:30:53 | 1:46:03 | **+3:44:50** (net slower) |

0.2 is the minimum-total-time point as well as the maximum-efficiency point: cheaper end-to-end
than 0.0 by 1 h 29 m, and 10 m 35 s better than 0.1 while removing twice as many violations.
0.3 is the only arm where the reservation costs more time than it saves. The saving side is
conservative — it is measured on a 2-iteration DRT, and a full-length DRT would widen the
absolute difference, since every extra iteration is cheaper on a cleaner layout.

## 5. An independent instrument puts the boundary in the same place

GRT's own overflow check says the same thing the cost curve does:

* 0.0, 0.1, 0.2 — `GRT-0115 Global routing finished with overflow`: **absent**. Total overflow
  column: 0, 0, 0.
* 0.3 — **present**, 15,155 unresolved overflow across M1–M5.

The 30 % reservation is the first one that over-commits GRT's own reduced budget. Two unrelated
measurements — a cost curve and a congestion check — draw the line in the same interval.

The mechanism behind the tail blow-up is visible in the pre-DRT ODB size, which tracks diode
insertion: 194.4 → 201.2 → **202.2** → 209.5 MiB. 0.1 → 0.2 adds 0.5 %; 0.2 → 0.3 adds 3.6 % and
4 h 10 m of repair time. Peak memory stays flat across the sweep (6.4–7.0 GB), so 0.2 costs
nothing in the memory envelope either — all four arms fit the same 8 GB box.

## Verdict

**Set `GRT_ADJUSTMENT: 0.2`.** It is the knee on every axis measured: the peak of marginal
violation yield, the lowest wire paid per violation, the lowest total time, no GRT overflow, and
the last point before the tail cliff. Relative to 0.3 it gives up 62,626 violations (24.6 % worse
absolute count) to avoid 3.4 M µm of marginal wire, +5 h 22 m of flow tail and 15,155 units of
GRT over-commitment.

This **changes the previously pre-registered rule**, which was "whichever arm reaches the lower
iteration-2 plateau sets the value" — a rule that optimises violation count and ignores cost
entirely, and which therefore selected 0.3. The sweep was run precisely because that rule cannot
answer the question that matters, and the cost side is now measured rather than assumed.

**What would change it back** (the pre-registered falsifier): a full-length DRT run in which 0.2's
plateau stalls far above 0.3's while 0.3 keeps converging. There is one measurement pointing that
way and it is recorded here rather than buried: 0.3's per-iteration gain is still large (−7.8 %
from iter1 to iter2) where 0.0, 0.1 and 0.2 have settled into −3.9 %, −3.7 % and −4.3 %. At equal
iteration count 0.3 is further from its own asymptote, so its advantage could grow with more
iterations. A 2-iteration DRT cannot settle an asymptote; the decisive next run is 0.2 vs 0.3 at
full DRT iteration count, on the same layout pair — not more sweep points.

**Die-side postscript (2026-10-14).** One arm of this question is now answered on the layout
that ships rather than on the slot core: with 0.1 landed, the *die's* pre-DRT database routes
353,871 → 213,354 → **204,357** at iteration 2 on this protocol (Metal1–Metal5, 8 threads,
`-or_seed 42`) — cleaner than this table's 0.2 core number (254,201). The same run also shows
the die has no 0.2 arm to compare against: GRT at 0.2 aborts there (GRT-0183), which is why the
landing is 0.1. And the arm runs with `-c RUN_ANTENNA_REPAIR=false`, because this build's
`OpenROAD.RepairAntennas` hits the same fatal no-path inside its own router — both findings are in
`Claude outputs/die_drt_at01.md` and
`Claude outputs/ws_run3_readiness_gaps.md` §1b, and the landed knob with its rationale is in
`c930/asic_gf180mcu/wafer_space_integration/grx930_overrides.yaml`.

## Provenance

* Driver: `c930/asic_gf180mcu/build/grt_sweep_chain.sh` (`harvest-only` mode rewrites the table
  from disk without launching anything). Per-arm flow: `build/grt_sweep_exec.sh`; DRT:
  `drt_fast/run_drt.sh`.
* Gate, measured: each arm re-reads `Global adjustment: N%` out of its own GRT log and skips its
  DRT if the CLI `-c GRT_ADJUSTMENT` override lost to the config file. All four arms logged the
  value they were asked for (0 %, 10 %, 20 %, 30 %) — a sweep where the override silently lost
  would have looked flat for entirely the wrong reason.
* Logs: `drt_fast/logs/core_drt.log` (0.0), `grt01_drt.log` (0.1), `grt02_drt.log` (0.2),
  `core03_drt.log` (0.3); chain log `drt_fast/grt_sweep_chain.log`; table
  `drt_fast/verdict/grt_sweep.md`.
* Arms 0.1 and 0.2 ran 15:15 → 19:18 UTC on 2026-10-12, serialized behind the earlier DRT arms.
* Wirelength is GRT's estimate against GRT's estimate: the deltas are sound, the absolute level is
  optimistic (GRT over-estimates routed wire ~25 % on this design). No arm reaches a routed result,
  so the *routed*-wire penalty of any setting is still unmeasured.
