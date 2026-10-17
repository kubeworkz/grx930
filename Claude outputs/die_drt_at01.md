# The die's own DRT at GRT_ADJUSTMENT 0.1 — measured, 2 iterations

Written 2026-10-14 00:26:24 UTC by `build/die_drt_chain.sh` (tag `die02`).
It answers the one question the 0.1 landing left open: the overrides file pays
for 0.1 with "the DRT half of the sweep" — 344,494 violations at 0.1 against
0.2's 254,201 — but both of those were the **slot core**. The layout that ships
is the die. There is no die-side 0.2 counterfactual to subtract: GRT at 0.2
aborts on this layout (`GRT-0183`, deterministic), so 0.1 is the only arm that
reaches routing and this is its number.

## The measurement

* **Database** `/work/ws/template/librelane/runs/die02/01-openroad-globalrouting/chip_top.odb` — host `/home/ubuntu/grx930_ol2/ws/template/librelane/runs/die02/01-openroad-globalrouting/chip_top.odb`, 232.7 MB, written
  2026-10-13 22:33:10 UTC. This is the file the flow's
  own `OpenROAD.DetailedRouting` step would read:
  it is the ODB the pre-DRT run tree records as current at its last pre-DRT
  step, passed to this chain as `DIE_ODB_C` because only the DRT half was re-run.
* **Instrument** `drt_fast/run_drt.sh` → `drt_fast/die_drt.tcl`: 2 iterations,
  `-or_seed 42`, 8 threads, Metal1–Metal5 — the same protocol the slot-core arms
  ran, with the layer range stated via `set_routing_layers` because THIS build
  answers the deprecated `-bottom_routing_layer` with `[ERROR DRT-0509] ...
  deprecated` and aborts (measured on this chain's first attempt, 2026-10-13 23:01,
  rc=1 after 2 s). `set_routing_layers` is the replacement DRT-0509 names and what
  LibreLane's own GPL/GRT scripts do from RT_MIN_LAYER/RT_MAX_LAYER. The `detailed_route`
  call itself is the flow's own (`scripts/openroad/drt.tcl`: no layer flags). Run in
  `ghcr.io/wafer-space/gf180mcu-precheck` — the image that wrote the database and
  that the flow's DRT step runs in, so the router build is not a variable either.
* **Pre-DRT arm** `-c RUN_ANTENNA_REPAIR=false` — the antenna-repair composite is skipped (see below); everything else is the staged config, and the run's resolved.json records `RUN_ANTENNA_REPAIR: false`.
* **GRT arm proof** (the chain refuses to launch DRT without it): the step's log
  says `Global adjustment: 10%`, 8 extra iteration(s), overflow `0`
  (demand / max / total of the final congestion report), wire `39459512` µm.
  That is the landed file's own value, resolved by the flow.

| iteration | violations |
|---|---|
| initial route | 353,871 |
| iter 1 | 213,354 |
| **iter 2 (DRT-0199)** | **204,357** |

* **Wall clock** `RUN_START` → `RUN_END`: 1:15:42; peak memory
  8,123 MB; container exit rc=0.
* Cross-check: the router's own `Completing 100% with` summary for the last
  iteration reads 204,347 — the `DRT-0199` value, 204,357, is the one every
  earlier table quotes (same 10-violation offset on the slot core).
* **Violation report** `drt_fast/out/die02/die02.drc`, log `drt_fast/logs/die02_drt.log`.
* **Phase A** was not re-run (`DIE_ODB_C` given); step runtimes as the flow
  recorded them in `runs/die02`:

| step | runtime |
|---|---|
| 01-openroad-globalrouting | 00:04:08.424 |
| 02-openroad-checkantennas | 00:08:51.449 |
| 03-odb-diodesonports | 00:00:00.001 |
| 04-openroad-stamidpnr-3 | 00:18:16.330 |


## Why the pre-DRT database carries no antenna diodes

The unmodified resume (tag `die01`, these same scripts, 2026-10-13) reaches
GlobalRouting cleanly at 0.1 — 8 extra iterations, wire 39,459,512 µm, 0 overflow —
and then dies inside `OpenROAD.RepairAntennas` → `OpenROAD.DiodeInsertion`,
which runs `scripts/openroad/antenna_repair.tcl`:
`repair_antennas gf180mcu_fd_sc_mcu7t5v0__antenna -iterations 3 -ratio_margin 10
-allow_congestion`. After 3,846 jumpers (2,080 nets) and 2,522 diodes it hits
`[ERROR GRT-0183] Net _167563_: heap underflow during 3D maze routing` — the same
fatal no-path this build turns into an abort, now inside the repair's own global
router pass (#10711 only makes it recoverable). Evidence:
`ws/logs/predrt_die01.container.log`,
`ws/template/librelane/runs/die01/04-openroad-repairantennas/1-openroad-diodeinsertion/openroad-diodeinsertion.log`.
So on this build the die cannot insert antenna diodes at 0.1 at all — the second
instance of the pin predating #10711/#11093, and the reason this measurement uses the
post-GlobalRouting database with the composite skipped (`RUN_ANTENNA_REPAIR` is the
flow's own gating variable for it). What the missing diodes would have cost DRT is not
measured — no diode-inserted die database exists — so it is recorded as a limitation,
not assumed small.

## What it is compared with — and what it is not

* Same instrument, slot core (3048×4238 µm): 418,633 / 344,494 / 254,201 /
  191,578 at iteration 2 for GRT_ADJUSTMENT 0.0 / 0.1 / 0.2 / 0.3. The 0.2 → 0.1
  give-back cost the slot core +90,293 violations (×1.36). The die's number above
  is that same trade measured where it matters, and it is the only arm available:
  0.2 does not complete GRT here.
  One instrument difference, stated: the sweep's arms passed the layer range as
  `-bottom/‑top_routing_layer` flags in the openlane2 build; this arm states the same
  Metal1–Metal5 range via `set_routing_layers`. Same range (the die's log prints the
  tech's routing layers), one different code path.
* **Not a flow result.** The fast loop runs pass 0 of the flow's DRT step only.
  The flow's `DRT_OPT_ITERS: 8` cap, its interleaved antenna-repair re-routes and
  its `Checker.TrDRC` (threshold 0) are not in this number; this is the curve a
  flow DRT would start from, so the flow's own verdict will be read against it.
* **One seed, one thread count, one box.** Run-to-run variation in TritonRoute is
  not measured here; 2 iterations is the protocol's endpoint (the slot-core table's
  endpoint too), not a converged route.
