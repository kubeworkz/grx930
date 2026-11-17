# Fresh baseline plan — RTL to ODB to 8,168-drop ECO to GDS/SPEF

**Status: PLANNING ONLY — NOT STARTED.** No synthesis, place-and-route, DRT,
stream-out, or RCX command has been run for this plan.

This creates a **new identity**. It cannot claim `fix59`, `fix70`, the historical
541-row source, or the current 8,168-drop provenance. The existing submission
package stays **VOID — DO NOT SUBMIT** and G0/G2 stay blocked until this baseline
finishes, passes the gates below, and is signed.

## 1. Identity rule

A fresh baseline is production-eligible only when one pinned set of netlist, PDK,
flow config, DEF, GDS, and SPEF hashes is used from synthesis through signoff.
Changing any of them creates a new baseline and invalidates every prior G0/G2
result.

The 8,168 count is a property of the old fix16/fix70 geometry (7,626 connected
`sub` islands + 540 row drops + 2 rail drops, row 300 excluded). A new baseline
must either reproduce that exact die/row geometry or **re-derive the drop list and
count**. Do not force 8,168 onto a different floorplan and call it the same ECO.

## 2. Existing assets to reuse

| Purpose | Path | Notes |
|---|---|---|
| Full-chip flow runner | `c930/asic_gf180mcu/ws/ws_exec.sh` | LibreLane Chip flow in `ghcr.io/wafer-space/gf180mcu-precheck`; `WS_TAG`, `WS_LIMIT`, `WS_FROM` |
| Template source | `c930/asic_gf180mcu/tools/gf180mcu-project-template/` | `librelane/`, `src/`, `Makefile`, pad-ring slot definitions |
| Slot config | `.../librelane/slots/slot_1x1.yaml` | pad ring, DIE/CORE area |
| Design overrides | `c930/asic_gf180mcu/wafer_space_integration/grx930_overrides.yaml` | SHA-256 `2e35833d4adc80560f81dce9a13f0f5b1f437e134e8a0c095b2f16c46a3910c9`; GRT 0.1, DRT_OPT_ITERS 8, antenna 10/10 |
| Core adapter | `.../wafer_space_integration/chip_core_grx930.sv` | SHA-256 `585661ccc48cf1852ac0d9829abced93bac1beb3f151dbe640ad0f55d8b91c0b` |
| PDN config | `.../wafer_space_integration/pdn_cfg_grx930.tcl` | SHA-256 `cb9fd56896f184fd435f133b3bef370d8825f2ebf97a1ed880da5bbb1e29f00b` |
| Macro list | `.../wafer_space_integration/macros_grx930.yaml` | template ws_ip macros minus the demo SRAM |
| RTL tree | `c930/asic_gf180mcu/openlane2_rtl/src/` | tapeout RTL; includes `grx930_test_chip.sv` |
| Synth netlist (older arm) | `c930/asic_gf180mcu/openlane2_design/src/grx930_test_chip_synth_final.v` | SHA-256 `af4e0ad79a3f48edeb31a472d0130e72e9b9da7b3dcc054adef8483059ea635e`; 53k-cell arm, not the full die |
| Pre-DRT resume | `c930/asic_gf180mcu/ws/die_predrt_exec.sh` | resumes a frozen state; a fresh baseline starts from RTL instead |
| Fast DRT loop | `c930/asic_gf180mcu/drt_fast/run_drt.sh`, `die_drt.tcl`, `drt_fast.tcl` | 8 threads, Metal1–Metal5, `FAST_END_ITER`, `FAST_TAG` |
| DRT chain + guard | `c930/asic_gf180mcu/build/die_drt_chain.sh`, `drt_curve_guard.sh`, `drt_db_compare_chain.sh`, `gate.sh` | budgets, divergence kill, disk/memory gate |
| Fill / stream / stitch / CDL | `c930/asic_gf180mcu/tools/lvs_chip/{fill_def.py,stream_out.py,pdn_stitch.py,mk_chip_cdl.py}` | same tools used for the rebased artifacts |
| Stream/route checks | `.../tools/lvs_chip/{stream_check.py,net_compare.py}` | layer/placement and DEF-vs-CDL checks |
| G0/G2 | `build/production/run/{g0_freeze.sh,g2_lvs.sh,gds_checks.rb,def_gds_checks.rb}` | fail-closed gates; die/count currently hardcoded |
| ECO crop geometry | `build_row_crops.rb`, `build_corrected_crops.rb`, `build/lvs_chip/eco_drop_2x2/` | 13 representative sites, not the full list |
| ECO window logic | `validate_drop_windows_2x2.rb` | needs `fill_regression_tie_final.gds` + `chip.l2n`, both absent |

The local `c930/asic_gf180mcu/ws/template/` tree is **not present**. It must be
staged from `tools/gf180mcu-project-template/` and overlaid with the grx930 files
above; `ws_exec.sh` expects `/work/ws/template`.

## 3. Stages

### Stage 0 — Freeze the identity and choose the floorplan

Inputs: RTL tree, overrides, slot config, PDK version `0fe599b2afb6708d281543108caf8310912f54af`.

Decisions to record before any compute:
- Netlist entry: full-chip `openlane2_rtl` RTL through `ws_exec.sh`, **not** the
  10 MB `openlane2_design` synth netlist. The two are different cell counts.
- Die/core: the ws `slot_1x1` template uses **3930 × 5120 µm**; the audit DEF and
  G0 currently use **3932 × 5122 µm**. If the old 8,168 geometry must be
  reproduced, use the old die/row frame; otherwise this is a new floorplan.
- Corner/RCX set: `nom`, `min`, `max` from the PDK `rules.openrcx.gf180mcuD.*`.

Output: `build/production/baseline/baseline_manifest.sha256` containing the RTL
tree hash, overrides, PDN, macros, PDK version, flow image digest, and die/core.

Gate: every input has a hash and there is exactly one netlist/floorplan pair.

### Stage 1 — Toolchain and PDK readiness

- Fetch or mount the PDK: `volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af`
  (the command already used by `core_exec.sh`).
- Verify the RCX rules exist under
  `<PDK>/gf180mcuD/libs.tech/openlane/rules.openrcx.gf180mcuD.{nom,min,max}`.
  They are **not in this checkout**; without them Stage 7 cannot run.
- Pin image digests: `ghcr.io/wafer-space/gf180mcu-precheck` (flow/DRT),
  `ghcr.io/efabless/openlane2:2.3.10` (stream/RCX), and
  `grx930/klayout-lvs-pmap:local` (G2 deck).
- Apply the memory/disk gate from `build/gate.sh`: at least 12 GB free RAM for
  pre-DRT and 8 GB for a DRT arm, and ~150 GB of volume.

Output: `toolchain_versions.txt` (librelane, OpenROAD, KLayout, Volare, image digests).

Gate: the exact RCX rule files and OpenROAD build are readable; a version bump
restarts the baseline.

### Stage 2 — RTL through global route to a pre-DRT ODB

Stage the template once:

```bash
cp -a c930/asic_gf180mcu/tools/gf180mcu-project-template c930/asic_gf180mcu/ws/template
# overlay grx930_overrides.yaml, pdn_cfg_grx930.tcl, macros_grx930.yaml,
# chip_core_grx930.sv, and openlane2_rtl/src into the paths ws_exec.sh expects
```

`WS_TAG` must be fresh; resuming an old tag reuses that tag's netlist. Run the
Chip flow to the state before detailed routing:

```bash
docker run --rm --user 0:0 -v <repo>:/work \
  -e WS_TAG=prod01 \
  -e WS_LIMIT=OpenROAD.STAMidPNR-3 \
  ghcr.io/wafer-space/gf180mcu-precheck /work/ws/ws_exec.sh
```

`die_predrt_exec.sh` documents why `STAMidPNR-3` is the last pre-DRT state: the
STA steps pass the antenna-repaired ODB through, and the DRT step reads the ODB
named by the last `state_out.json`.

Output: `runs/prod01/.../*.odb` (copy to `build/production/baseline/pre_drt.odb`),
`resolved.json`, GRT log.

Gate:
- `resolved.json` shows `GRT_ADJUSTMENT: 0.1` and `DRT_OPT_ITERS: 8`; the GRT log
  contains `Global adjustment: 10%`.
- No `GRT-0183` abort; PDN inserted exactly once; macro-instance check passes.
- Cell count and die match the frozen manifest.

### Stage 3 — Complete detailed routing

Probe with the fast loop first, then run the full iteration budget:

```bash
# stage c930/asic_gf180mcu/drt_fast at /work/drt_fast inside the image;
# run_drt.sh hardcodes D=/work/drt_fast
FAST_TAG=prod01_drt FAST_ODB=/work/build/production/baseline/pre_drt.odb \
FAST_END_ITER=2 FAST_THREADS=8 FAST_MIN_LAYER=Metal1 FAST_MAX_LAYER=Metal5 \
FAST_TCL=/work/drt_fast/die_drt.tcl /work/drt_fast/run_drt.sh
```

Run the same with `FAST_END_ITER=8` only after the probe shows a decreasing
violation curve. Keep `drt_curve_guard.sh` attached to kill a divergent pass and
to bound per-iteration and per-pass wall time. Do not use the last ODB if the
curve diverged; the guard exists because the router writes the last database, not
the best one.

Output: `build/production/baseline/routed.odb`, DRT log, violation curve.

Gate: **0 DRT violations**, or a numbered, owner-signed waiver. A nonzero count is
not a routed production baseline and must not be streamed as one.

### Stage 4 — Route QA before the ECO

- Export DEF from the routed ODB.
- Run `net_compare.py --def <def> --cdl <cdl>` and `stream_check.py`.
- Build a route-completeness checker (see §4): zero unrouted nets, zero zero-pin
  dangling signal nets, zero unconnected special nets. The audited DEF had 1,022
  dangling signal nets and 2 unconnected special nets; that class of defect must
  fail this stage.

Output: `route_qa.json` plus the DEF/CDL comparison.

Gate: 0 dangling/unrouted nets; all pins resolved; antenna clean.

### Stage 5 — Derive the new ECO site list

Build `find_eco_sites.py` on OpenDB, using the legality rules in
`validate_drop_windows_2x2.rb` but taking `sub`, `vss`, `vdd`, and `$45264`
shapes from the routed ODB instead of the missing `chip.l2n`:

- 7,626 connected `sub` islands (M1 connected components on the `sub` net).
- 540 legal rows of the 541 candidates; `sub_row_300` excluded.
- 2 `$45264` rail-end drops.
- 0.84 µm M2 strap, 1.40 µm M2 keepout, 0.90 × 0.78 µm M1 landing,
  0.90 × 0.80 µm M3 landing, no row-300 cut overlap.

Output: `eco_sites.csv` (one row per drop: name, x, y, ty, kind) and a report with
the island/row/rail counts.

Gate: exactly 8,168 rows if the old floorplan is reproduced; otherwise the new
count is frozen and the G0 expected count is updated. Every site legal, row 300
absent, no duplicate rows.

### Stage 6 — Insert the full ECO into the ODB and DEF

Build `insert_eco_2x2.py` (OpenDB) from the geometry already used by
`build_row_crops.rb`:

- M1 landing, M2 strap with 0.45 µm extension past each via centre, M3 landing.
- Via1 `Via1_2X2_0_60_10_60_H_V` and Via2 `Via2_2X2_0_60_10_60_V_H`, 0.26 µm
  cuts on 0.52 µm centres.
- Insert the vias and wire segments into the routed ODB, then write the ECO DEF.

Run the DRC/landing checks on **all** rows and rails, not the 13-site crop. Extend
the `eco_drop_2x2` methodology to the full list and compare before/after reports.

Output: `eco_routed.odb`, `eco_routed.def`, `eco_drc.rlyrdb`, `eco_landing.log`.

Gate: 0 added M1/M2/M3/V1/V2 findings; 8,168 (or the frozen count) of each 2×2
via; row-300 area count 0; M1/M3 landing coverage met; M2 keepout respected.

### Stage 7 — Stream the final GDS and run the G0 geometry checks

```bash
python3 c930/asic_gf180mcu/tools/lvs_chip/stream_out.py \
  --def build/production/baseline/eco_routed.def \
  --lef c930/asic_gf180mcu/build/cells.lef \
  --routing def \
  --out build/production/final/grx930_test_chip_final.gds
```

Then:

```bash
klayout -b -r build/production/run/gds_checks.rb ...
klayout -b -r build/production/run/def_gds_checks.rb ...
```

Update the hardcoded expectations first: `g0_freeze.sh` currently names
`build/lvs_chip/rebased_grx930_test_chip.def` and expects die 3932 × 5122 and
8,168 drops. A new die or count requires parameterizing those values in G0 and
`def_gds_checks.rb`.

Gate: both checkers exit 0; zero Metal1–Metal5 XOR; exact Via1/Via2 cut counts;
row-300 area count 0; G0's no-VOID check rejects any hash matching a VOID artifact
or the fix16 base.

### Stage 8 — Extract SPEF with OpenRCX

Build `extract_spef.tcl`; run it in the OpenLane image against the **same**
`eco_routed.odb`:

```tcl
read_db build/production/baseline/eco_routed.odb
define_process_corner(0, "nom")
extract_parasitics -ext_model_file <PDK>/libs.tech/openlane/rules.openrcx.gf180mcuD.nom
write_spef build/production/final/grx930_test_chip.spef
```

Repeat for `min` and `max` if the signoff corners require them. SPEF cannot be
derived from the GDS; it needs the routed database and the RCX rules.

Gate: SPEF net count equals the DEF net count; no unannotated clock/power nets;
corner files exist; a `report_parasitics` sanity run is clean.

### Stage 9 — Freeze, G0, and G2

- Update `build/production/run/g0_freeze.sh` for the new identity paths, die, and
  drop count, and regenerate `input_sha256.txt`.
- Run `g0_freeze.sh`; require `status=READY_FOR_REVIEW`, `gds_checks=PASS`,
  `def_gds_checks=PASS`, `no_void=PASS`, and a manifest hash.
- Fill `G0_signoff.txt` with a **Gridworkz-authorized** signer. Do not fabricate it.
- Run `g2_lvs.sh`; full-chip LVS uses the frozen GDS/SPEF/CDL/DEF and the
  pmap-capable image. Historical full-chip LVS cost is ~5,983 s.

Gate: G0 signed; G2 completes with 0 mismatches; report and netlist archived.

## 4. Pieces that must be built

1. **Template staging script** — copies `tools/gf180mcu-project-template` to
   `ws/template` and overlays the grx930 config, PDN, macros, core adapter, and
   RTL. `ws/template` is absent locally.
2. **Route QA checker** — dangling/unrouted/zero-pin net counts from the ODB or
   DEF; the current G0 does not check this class.
3. **ECO site finder** — OpenDB replacement for the missing `chip.l2n` logic in
   `validate_drop_windows_2x2.rb`.
4. **Full ECO inserter** — ODB/DEF insertion of the 2×2 arrays; only the 13-site
   GDS crop exists today.
5. **Full-row DRC/landing harness** — extend the 13-site crop checks to every
   row and rail.
6. **SPEF extraction Tcl** — OpenRCX corner runs; no extraction script exists.
7. **G0 parameterization** — die, drop count, DEF path, and no-VOID identity for a
   new baseline.
8. **Baseline manifest and signoff form** — one pinned set of hashes from RTL to
   SPEF.

## 5. Compute and schedule risks

| Risk | Evidence / bound | Mitigation |
|---|---|---|
| DRT divergence | v8 ran 10.6 days over 26 iterations; best 237,089 violations at iter 16, then 711,100; the last ODB is kept, not the best | `drt_curve_guard.sh` budgets and kill; short probe first; never ship a diverged ODB |
| DRT memory | measured peaks 6.4–7.0 GB; Docker died under a 5.8 GiB container; pre-DRT gate wants 12 GB | `gate.sh`, 16 GB host, one arm at a time |
| Disk exhaustion | a GRT overflow arm filled a 150 GB volume; flat stream GDS 509 MB, merged 392 MB, plus ODBs | 150 GB free; `disk_guard.sh`; delete intermediate ODBs |
| GRT 0.2 abort | assembled die aborts with `GRT-0183` at 0.2; 0.1 is the landed value | keep 0.1; verify `Global adjustment: 10%` before DRT |
| ECO legality | 4,318 pre-existing full-chip DRC findings; 0-added requirement over 541 rows; 1.40 µm M2 keepout | all-site DRC, resites, row-300 exclusion, no waiver for added findings |
| Runtime | full flow to pre-DRT days; DRT 1.5–10+ days per pass; LVS ~100 min; DRC ~10 min; RCX hours/corner; STA corners hours | dedicated machine, one baseline tag, checkpoint every step |
| Identity drift | three netlists/databases (53k synth, 209k audit, 332k die); 3930×5120 vs 3932×5122 die; unknown keys `FP_DIE_AREA`/`DRT_ALLOW_CONGESTION` in the 2.3.10 log | Stage 0 freeze; pin one netlist/die; use supported keys |
| RCX rules absent | local PDK `RCX_RULES` is empty; rules live in the Volare PDK on the build machine | fetch/pin `0fe599b2…`; verify the three rule files before Stage 7 |
| Signoff | no Gridworkz connector; G1 DFT/ATPG absent; G3 waiver and G4 STA/power open | external signoff; do not claim a pass without receipts |

## 6. Planning envelope

Assuming one engineer, one dedicated 16 GB/150 GB machine, the PDK and RCX rules
available, and DRT converging in the historical 0.1 regime:

- Stage 0–1: 1–2 days.
- Stage 2 (RTL to pre-DRT): 1–3 days.
- Stage 3 (DRT): 1–10+ days; the largest variance.
- Stage 4 (route QA): 1–2 days.
- Stage 5 (ECO list): 3–5 days.
- Stage 6 (ECO insert + all-site DRC): 1–2 weeks; the largest engineering risk.
- Stage 7 (stream + G0 geometry): 1–2 days.
- Stage 8 (RCX/SPEF): 1–3 days.
- Stage 9 (freeze/LVS): 1–2 days, plus Gridworkz signoff latency.

G0/G2 artifacts: roughly **4–8 weeks** after Stage 0. G3 DRC disposition, G4 STA/
power/IR/EM, G1 DFT/ATPG, and G5 foundry review are additional weeks to months and
are outside this plan.

## 7. Explicitly not done

No `volare fetch`, `ws_exec.sh`, DRT, stream-out, or OpenRCX command has been run
for this plan. No existing file was replaced. G0 remains `BLOCKED`, G2 exits 2,
and the package remains **VOID — DO NOT SUBMIT**.
