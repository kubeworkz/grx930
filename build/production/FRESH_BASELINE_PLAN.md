# Fresh baseline plan — RTL to ODB to a new-count ECO to GDS/SPEF

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

## 1.1 Determination: the fresh baseline needs a new ECO count

**The 8,168-drop geometry cannot be reproduced by a fresh RTL-to-P&R run.** It is
a property of the old fix16/fix70 database:

- **7,626 `sub` island drops** come from the connected M1 components of the `sub`
  net in the fix16 GDS. A new placement and route changes that connectivity.
- **540 row drops (of 541)** come from VSS labels and VSS/VDD M3 strips in the old
  GDS, with row 300 excluded because its only clean M2 route overlapped VDD. A new
  PDN and placement changes the row set and the row-300 congestion.
- **2 `$45264` rail drops** are tied to one auto-generated net name from the old
  synthesis. A fresh synthesis will not preserve `$45264`; the equivalent rail
  connection must be re-identified, and the count may differ.

Only reusing the exact old routed database preserves 8,168, and that is not a
fresh baseline (and the database is absent). Therefore this plan derives a new
drop list with a new count `N = N_sub + N_rows + N_rail`. G0, `def_gds_checks.rb`,
and the fixtures must take `N` as a parameter; the 8,168 fixtures remain
historical/synthetic controls only. If the project requires exactly 8,168, the
path is to recover the old database, not to run this plan.

## 2. Existing assets to reuse

| Purpose | Path | Notes |
|---|---|---|
| Full-chip flow runner | `c930/asic_gf180mcu/ws/ws_exec.sh` | LibreLane Chip flow; `WS_TAG`, `WS_LIMIT`, `WS_FROM`, `WS_OVERRIDE`; `cd /work/ws/template` |
| Template source | `c930/asic_gf180mcu/tools/gf180mcu-project-template/` | `librelane/` and `src/`; `ws/template` is absent locally |
| Slot config | `.../librelane/slots/slot_1x1.yaml` | pad ring and DIE/CORE area |
| Design overrides | `c930/asic_gf180mcu/wafer_space_integration/grx930_overrides.yaml` | SHA-256 `2e35833d4adc80560f81dce9a13f0f5b1f437e134e8a0c095b2f16c46a3910c9`; GRT 0.1, DRT_OPT_ITERS 8, antenna 10/10 |
| Core adapter | `.../wafer_space_integration/chip_core_grx930.sv` | SHA-256 `585661ccc48cf1852ac0d9829abced93bac1beb3f151dbe640ad0f55d8b91c0b`; replaces `src/chip_core.sv` |
| PDN config | `.../wafer_space_integration/pdn_cfg_grx930.tcl` | SHA-256 `cb9fd56896f184fd435f133b3bef370d8825f2ebf97a1ed880da5bbb1e29f00b`; destination is `librelane/pdn/` |
| Macro list | `.../wafer_space_integration/macros_grx930.yaml` | destination is `librelane/macros/` |
| RTL tree | `c930/asic_gf180mcu/openlane2_rtl/src/` | destination is `ws/template/asic_core/`; exclude `c930_bootrom.sv` and `bootrom_wrapper.sv` |
| Synth netlist (older arm) | `c930/asic_gf180mcu/openlane2_design/src/grx930_test_chip_synth_final.v` | SHA-256 `af4e0ad79a3f48edeb31a472d0130e72e9b9da7b3dcc054adef8483059ea635e`; not the full die |
| Pre-DRT resume | `c930/asic_gf180mcu/ws/die_predrt_exec.sh` | resumes a frozen state; a fresh run starts from RTL |
| Fast DRT loop | `c930/asic_gf180mcu/drt_fast/{run_drt.sh,die_drt.tcl,drt_fast.tcl}` | `run_drt.sh` hardcodes `D=/work/drt_fast`; 8 threads, Metal1–Metal5 |
| DRT chain + guard | `c930/asic_gf180mcu/build/{die_drt_chain.sh,drt_curve_guard.sh,drt_db_compare_chain.sh,gate.sh}` | budgets, divergence kill, disk/memory gate |
| Fill / stream / stitch / CDL | `c930/asic_gf180mcu/tools/lvs_chip/{fill_def.py,stream_out.py,pdn_stitch.py,mk_chip_cdl.py}` | must run in the OpenLane image; `stream_out.py` imports `klayout.db` |
| Stream/route checks | `.../tools/lvs_chip/{stream_check.py,net_compare.py}` | layer/placement and DEF-vs-CDL checks |
| G0/G2 | `build/production/run/{g0_freeze.sh,g2_lvs.sh,gds_checks.rb,def_gds_checks.rb}` | die/count/path currently hardcoded |
| ECO crop geometry | `build_row_crops.rb`, `build_corrected_crops.rb`, `build/lvs_chip/eco_drop_2x2/` | 13 representative sites, not the full list |
| ECO window logic | `validate_drop_windows_2x2.rb` | needs `fill_regression_tie_final.gds` + `chip.l2n`, both absent |

**Toolchain gap:** `ghcr.io/wafer-space/gf180mcu-precheck` is **not present in the
local Docker image list**. It must be pulled and pinned by digest before Stage 2.
The local images include `openlane2-gf180mcu:latest` and
`ghcr.io/efabless/openlane2:2.3.10`, which are not the full-chip flow image.

## 3. Stages

### Stage 0 — Freeze the identity and choose the floorplan

Inputs: RTL tree, overrides, slot config, PDK version.

Record before any compute:
- Netlist entry: full-chip `openlane2_rtl` RTL through `ws_exec.sh`, **not** the
  10 MB `openlane2_design` synth netlist. The two are different cell counts.
- Die/core: the ws `slot_1x1` template uses **3930 × 5120 µm**; the audit DEF and
  G0 currently use **3932 × 5122 µm**. A fresh floorplan uses the template die;
  the old G0 die constant must be parameterized.
- **ECO count:** new count `N`; do not plan for 8,168 (see §1.1).
- Corner/RCX set: `nom`, `min`, `max` from the PDK RCX rules.

Output: `build/production/baseline/baseline_manifest.sha256` with the RTL tree,
overrides, PDN, macros, PDK version, flow image digest, die/core, and `N` marked
`TO_BE_DERIVED`.

Gate: every input has a hash and there is exactly one netlist/floorplan pair.

### Stage 1 — Toolchain and PDK readiness

- Pull and pin the full-chip image:
  `docker pull ghcr.io/wafer-space/gf180mcu-precheck` and record
  `docker image inspect --format '{{.Id}}'`.
- Inspect its PDK at the default `--pdk-root /workspace/gf180mcu` and verify the
  OpenRCX rules exist:
  `rules.openrcx.gf180mcuD.{nom,min,max}`. If the image's PDK lacks them, stop;
  Stage 8 cannot run.
- Pin the signoff images: `ghcr.io/efabless/openlane2:2.3.10` (stream/RCX) and
  `grx930/klayout-lvs-pmap:local` (G2 deck).
- Apply `c930/asic_gf180mcu/build/gate.sh`: at least 12 GB free RAM for pre-DRT,
  8 GB for a DRT arm, and ~150 GB of volume.

Output: `toolchain_versions.txt` (librelane, OpenROAD, KLayout, image digests,
PDK path, RCX rule hashes).

Gate: the exact RCX rule files and OpenROAD build are readable; a version bump
restarts the baseline.

### Stage 2 — RTL through global route to a pre-DRT ODB

The container mount root is `c930/asic_gf180mcu`, **not the repository root**:
`ws_exec.sh` does `cd /work/ws/template`, and the RTL tree is at
`/work/openlane2_rtl`.

Stage the template exactly:

```bash
set -e
FLOW=c930/asic_gf180mcu
STAGE="$FLOW/ws/.template.stage"

# ws/template is generated by this block; do not keep local edits there. Build
# the new tree beside the live one, validate it, then swap it in. Re-running the
# block cannot nest the template inside itself or retain stale overlays.
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$FLOW/tools/gf180mcu-project-template/." "$STAGE/"
cp "$FLOW/wafer_space_integration/grx930_overrides.yaml" "$STAGE/librelane/"
cp "$FLOW/wafer_space_integration/macros_grx930.yaml" "$STAGE/librelane/macros/"
cp "$FLOW/wafer_space_integration/pdn_cfg_grx930.tcl" "$STAGE/librelane/pdn/"
cp "$FLOW/wafer_space_integration/chip_core_grx930.sv" "$STAGE/src/chip_core.sv"

# Copy the whole RTL tree, not just *.sv: any .svh, relative include, or
# subdirectory the core needs must survive. Exclude only the two unused ROM
# modules named in grx930_overrides.yaml.
mkdir -p "$STAGE/asic_core"
cp -a "$FLOW/openlane2_rtl/src/." "$STAGE/asic_core/"
rm -f "$STAGE/asic_core/c930_bootrom.sv" "$STAGE/asic_core/bootrom_wrapper.sv"

# Fail before replacing a good tree if the staged tree is incomplete.
test -f "$STAGE/src/chip_top.sv"
test -f "$STAGE/src/chip_core.sv"
test -f "$STAGE/asic_core/grx930_test_chip.sv"
test ! -e "$STAGE/asic_core/c930_bootrom.sv"
test ! -e "$STAGE/asic_core/bootrom_wrapper.sv"
test -f "$STAGE/librelane/slots/slot_1x1.yaml"
test -f "$STAGE/librelane/config.yaml"
test -f "$STAGE/librelane/grx930_overrides.yaml"
test -f "$STAGE/librelane/macros/macros_grx930.yaml"
test -f "$STAGE/librelane/pdn/pdn_cfg_grx930.tcl"
[ "$(grep -c '^  gf180mcu' "$STAGE/librelane/macros/macros_grx930.yaml")" -eq 5 ]

rm -rf "$FLOW/ws/template"
mv "$STAGE" "$FLOW/ws/template"
```

`grx930_overrides.yaml` declares `VERILOG_FILES` as `../src/chip_top.sv`,
`../src/chip_core.sv`, and `../asic_core/*.sv`; `PDN_CFG` is
`dir::pdn/pdn_cfg_grx930.tcl`, which is why the PDN file goes under
`librelane/pdn/`. `ws_exec.sh` writes `src/generated_defines.svh` itself.

Run with a fresh tag:

```bash
MSYS_NO_PATHCONV=1 docker run --rm --user 0:0 \
  -v "$(cygpath -m c930/asic_gf180mcu):/work" \
  -e WS_TAG=prod01 \
  -e WS_LIMIT=OpenROAD.STAMidPNR-3 \
  ghcr.io/wafer-space/gf180mcu-precheck /work/ws/ws_exec.sh
```

`WS_TAG` must be fresh; resuming an old tag reuses its netlist. `STAMidPNR-3` is
the last pre-DRT state: the STA steps pass the antenna-repaired ODB through, and
the DRT step reads the ODB named by the last `state_out.json`.

Output: `runs/prod01/.../*.odb` (copy to `build/production/baseline/pre_drt.odb`),
`resolved.json`, GRT log.

Gate:
- `resolved.json` shows `GRT_ADJUSTMENT: 0.1` and `DRT_OPT_ITERS: 8`; the GRT log
  contains `Global adjustment: 10%`.
- No `GRT-0183` abort; PDN inserted once; macro-instance check passes.
- Cell count and die match the frozen manifest.

### Stage 3 — Complete detailed routing

Stage `c930/asic_gf180mcu/drt_fast` at `/work/drt_fast` in the image; the runner
hardcodes `D=/work/drt_fast` and its default `FAST_OPENROAD` is a build-machine
Nix path. Set `FAST_OPENROAD` to the OpenROAD binary inside the precheck image.

```bash
MSYS_NO_PATHCONV=1 docker run --rm --user 0:0 \
  -v "$(cygpath -m c930/asic_gf180mcu):/work" \
  -e FAST_TAG=prod01_drt \
  -e FAST_ODB=/work/build/production/baseline/pre_drt.odb \
  -e FAST_END_ITER=2 -e FAST_THREADS=8 \
  -e FAST_MIN_LAYER=Metal1 -e FAST_MAX_LAYER=Metal5 \
  -e FAST_TCL=/work/drt_fast/die_drt.tcl \
  -e FAST_OPENROAD=openroad \
  ghcr.io/wafer-space/gf180mcu-precheck /work/drt_fast/run_drt.sh
```

`FAST_OPENROAD=openroad` resolves through the image entrypoint's nix-shell
`PATH`; the script's own default is a build-machine store path that does not
exist here. Run `MSYS_NO_PATHCONV=1 docker run --rm \
ghcr.io/wafer-space/gf180mcu-precheck sh -lc 'command -v openroad'` first if
the name is not found.

Run the same with `FAST_END_ITER=8` only after the probe shows a decreasing
violation curve. Keep `drt_curve_guard.sh` attached to kill a divergent pass and
to bound per-iteration and per-pass wall time. Do not use the last ODB if the
curve diverged; the guard exists because the router writes the last database, not
the best one.

Output: `build/production/baseline/routed.odb`, DRT log, violation curve.

Gate: **0 DRT violations**, or a numbered, owner-signed waiver. A nonzero count is
not a routed production baseline and must not be streamed as one.

### Stage 4 — Route QA before the ECO

- Export DEF from the routed ODB to
  `build/production/baseline/routed.def`; Stage 7 streams its pre-ECO GDS.
- Run `net_compare.py --def <def> --cdl <cdl>` and `stream_check.py`.
- Build a route-completeness checker (see §4): zero unrouted nets, zero zero-pin
  dangling signal nets, zero unconnected special nets. The audited DEF had 1,022
  dangling signal nets and 2 unconnected special nets; that class must fail here.

Output: `route_qa.json` plus the DEF/CDL comparison.

Gate: 0 dangling/unrouted nets; all pins resolved; antenna clean.

### Stage 5 — Derive the new ECO site list

Build `find_eco_sites.py` on OpenDB, using the legality rules in
`validate_drop_windows_2x2.rb` but taking `sub`, VSS, VDD, and rail shapes from
the routed ODB instead of the missing `chip.l2n`:

- Substrate tap islands from connected M1 components on the `sub` net.
- Legal VSS rows from the new VSS labels/strips; exclude any row whose only clean
  M2 corridor overlaps VDD (the row-300 rule, generalized).
- Rail-end drops from the new power-rail geometry; do **not** look for the old
  `$45264` name.
- 0.84 µm M2 strap, 1.40 µm M2 keepout, 0.90 × 0.78 µm M1 landing,
  0.90 × 0.80 µm M3 landing, no row-300 cut overlap.

Output: `eco_sites.csv` (name, x, y, ty, kind) and a report with
`N_sub + N_rows + N_rail = N`.

Gate: `N` is frozen from the report, every site legal, no duplicate rows, and the
generalized exclusion holds. **Do not gate on 8,168.**

### Stage 6 — Insert the new ECO into the ODB and DEF

Build `insert_eco_2x2.py` (OpenDB) from the geometry already used by
`build_row_crops.rb`:

- M1 landing, M2 strap with 0.45 µm extension past each via centre, M3 landing.
- Via1 `Via1_2X2_0_60_10_60_H_V` and Via2 `Via2_2X2_0_60_10_60_V_H`, 0.26 µm
  cuts on 0.52 µm centres.
- Insert the vias and wire segments into the routed ODB, then write the ECO DEF.

Run the DRC/landing checks on **all** rows and rails, not the 13-site crop. Extend
the `eco_drop_2x2` methodology to the full list and compare before/after reports.

Output: `eco_routed.odb`, `eco_routed.def`, `eco_drc.rlyrdb`, `eco_landing.log`.

Gate: 0 added M1/M2/M3/V1/V2 findings; `N` of each 2×2 via; row-300 area count 0;
M1/M3 landing coverage met; M2 keepout respected.

### Stage 7 — Stream the final GDS and run the G0 geometry checks

Stream the **pre-ECO** GDS first; `gds_checks.rb` needs it as `base` for the
XOR, and without it the check has nothing to compare against. Then stream the
final ECO GDS. Run both inside the OpenLane image (`stream_out.py` imports
`klayout.db`; host Python is not enough):

```bash
stream() {
  MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$(cygpath -m .):/work" -w /work \
    --entrypoint python3 ghcr.io/efabless/openlane2:2.3.10 \
    c930/asic_gf180mcu/tools/lvs_chip/stream_out.py "$@"
}

stream --def /work/build/production/baseline/routed.def \
  --lef /work/c930/asic_gf180mcu/build/cells.lef --routing def \
  --out /work/build/production/baseline/pre_eco.gds

stream --def /work/build/production/baseline/eco_routed.def \
  --lef /work/c930/asic_gf180mcu/build/cells.lef --routing def \
  --out /work/build/production/final/grx930_test_chip_final.gds
```

Run both KLayout checks with the exact `-rd` names the scripts require; both
default to 3932 × 5122 and 8,168, so passing the new values is mandatory:

```bash
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$(cygpath -m .):/work" -w /work \
  --entrypoint klayout grx930/klayout-lvs-pmap:local -b \
  -r /work/build/production/run/gds_checks.rb \
  -rd gds=/work/build/production/final/grx930_test_chip_final.gds \
  -rd base=/work/build/production/baseline/pre_eco.gds \
  -rd def=/work/build/production/baseline/eco_routed.def \
  -rd topcell=grx930_test_chip \
  -rd expected_die_w=<DEF die width> -rd expected_die_h=<DEF die height> \
  -rd expected_drops=<N> \
  -rd report=/work/build/production/manifests/gds_checks.txt

MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$(cygpath -m .):/work" -w /work \
  --entrypoint klayout grx930/klayout-lvs-pmap:local -b \
  -r /work/build/production/run/def_gds_checks.rb \
  -rd gds=/work/build/production/final/grx930_test_chip_final.gds \
  -rd def=/work/build/production/baseline/eco_routed.def \
  -rd topcell=grx930_test_chip \
  -rd expected_drops=<N> \
  -rd report=/work/build/production/manifests/def_gds_checks.txt
```

`g0_freeze.sh` currently names
`build/lvs_chip/rebased_grx930_test_chip.def` and hardcodes die 3932 × 5122 and
8,168 drops; parameterize those before running it.

Gate: both checkers exit 0; zero Metal1–Metal5 XOR; exact Via1/Via2 cut counts for
`N`; row-300 area count 0; G0's no-VOID check rejects any hash matching a VOID
artifact or the fix16 base.

### Stage 8 — Extract SPEF with OpenRCX

Verified in the pinned OpenROAD build
(`edf00dff99f6c40d67a30c0e22a8191c5d2ed9d6`): `define_process_corner`,
`extract_parasitics`, and `write_spef` exist. `report_parasitics` does **not**
exist; use `report_parasitic_annotation` and `read_spef`/`diff_spef` instead.

Build `extract_spef.tcl` and run it against the **same** `eco_routed.odb`:

```tcl
read_db /work/build/production/baseline/eco_routed.odb
define_process_corner -ext_model_index 0 \
  <PDK>/gf180mcuD/libs.tech/openlane/rules.openrcx.gf180mcuD.nom
extract_parasitics -ext_model_file \
  <PDK>/gf180mcuD/libs.tech/openlane/rules.openrcx.gf180mcuD.nom
write_spef /work/build/production/final/grx930_test_chip.spef
```

This build's `define_process_corner` takes **one filename** plus the optional
`-ext_model_index`; it does **not** take `(index, "corner name")`. Name the
corner in the SPEF metadata or a sidecar, not in that call.

`extract_parasitics` supports `-ext_model_file`, `-corner_cnt`, `-max_res`,
`-coupling_threshold`, `-lef_res`, `-cc_model`, and `-no_merge_via_res`.
`write_spef` takes an optional `-net_id`/`-nets` filter and a filename. Repeat for
`min` and `max` if the signoff corners require them.

Validation: use `report_parasitic_annotation` and a net-coverage count against the
DEF netlist; write a second SPEF with `-nets` for a subset and compare with
`diff_spef` if needed. Do not rely on `report_parasitics`; it does not exist.

Gate: SPEF net count equals the DEF net count; no unannotated clock/power nets;
corner files exist; `read_spef`/`diff_spef` succeeds.

### Stage 9 — Freeze, G0, and G2

- Parameterize `build/production/run/g0_freeze.sh` for the new identity paths,
  die (`-rd expected_die_w`, `-rd expected_die_h`), and `N`
  (`-rd expected_drops`), add the pre-ECO `-rd base`, then regenerate
  `input_sha256.txt`.
- Run `g0_freeze.sh`; require `status=READY_FOR_REVIEW`, `gds_checks=PASS`,
  `def_gds_checks=PASS`, `no_void=PASS`, and a manifest hash.
- Fill `G0_signoff.txt` with a **Gridworkz-authorized** signer. Do not fabricate it.
- Run `g2_lvs.sh`; full-chip LVS uses the frozen GDS/SPEF/CDL/DEF and the
  pmap-capable image. Historical full-chip LVS cost is ~5,983 s.

Gate: G0 signed; G2 completes with 0 mismatches; report and netlist archived.

## 4. Pieces that must be built

1. **Template staging script** — copies the template, overlays the four grx930
   files at the exact `librelane/` and `src/` paths, and builds `asic_core/` from
   the RTL tree. `ws/template` is absent locally.
2. **Route QA checker** — dangling/unrouted/zero-pin net counts from the ODB or
   DEF; the current G0 does not check this class.
3. **ECO site finder** — OpenDB replacement for the missing `chip.l2n` logic in
   `validate_drop_windows_2x2.rb`, with a generalized row-300 exclusion and no
   dependence on `$45264`.
4. **Full ECO inserter** — ODB/DEF insertion of the 2×2 arrays for `N` drops;
   only the 13-site GDS crop exists today.
5. **Full-row DRC/landing harness** — extend the 13-site checks to every row and
   rail.
6. **SPEF extraction Tcl** — OpenRCX corner runs using the verified commands.
7. **G0 parameterization** — die, drop count, DEF path, and no-VOID identity.
8. **Baseline manifest and signoff form** — one pinned set of hashes from RTL to
   SPEF.

## 5. Compute and schedule risks

| Risk | Evidence / bound | Mitigation |
|---|---|---|
| DRT divergence | v8 ran 10.6 days over 26 iterations; best 237,089 violations at iter 16, then 711,100; the last ODB is kept, not the best | `drt_curve_guard.sh` budgets and kill; short probe first; never ship a diverged ODB |
| DRT memory | measured peaks 6.4–7.0 GB; Docker died under a 5.8 GiB container; pre-DRT gate wants 12 GB | `gate.sh`, 16 GB host, one arm at a time |
| Disk exhaustion | a GRT overflow arm filled a 150 GB volume; flat stream GDS 509 MB, merged 392 MB, plus ODBs | 150 GB free; `disk_guard.sh`; delete intermediate ODBs |
| GRT 0.2 abort | assembled die aborts with `GRT-0183` at 0.2; 0.1 is the landed value | keep 0.1; verify `Global adjustment: 10%` before DRT |
| ECO count is not 8,168 | the old list depends on fix16 `sub` islands, old VSS rows, and the old `$45264` net (§1.1) | derive `N`; parameterize G0/checkers; retire 8,168 with the old identity |
| ECO legality | 4,318 pre-existing full-chip DRC findings; 0-added requirement over all rows; 1.40 µm M2 keepout | all-site DRC, resites, generalized row-300 exclusion |
| Runtime | full flow to pre-DRT days; DRT 1.5–10+ days per pass; LVS ~100 min; DRC ~10 min; RCX hours/corner; STA corners hours | dedicated machine, one baseline tag, checkpoint every step |
| Identity drift | three netlists/databases (53k synth, 209k audit, 332k die); 3930×5120 vs 3932×5122 die; unsupported keys `FP_DIE_AREA`/`DRT_ALLOW_CONGESTION` in the 2.3.10 log | Stage 0 freeze; pin one netlist/die; use supported keys |
| RCX rules absent locally | local PDK `RCX_RULES` is empty; rules are referenced from the Volare PDK on the build machine; image PDK not yet inspected | verify `rules.openrcx.*` in the precheck image at Stage 1; stop if absent |
| Precheck image absent | not in the local `docker images` list | pull and pin the digest before Stage 2 |
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

No `docker pull`, `volare fetch`, `ws_exec.sh`, DRT, stream-out, or OpenRCX command
has been run for this plan. Only read-only inspection and a no-design OpenROAD
command-existence probe were run. No existing file was replaced. G0 remains
`BLOCKED`, G2 exits 2, and the package remains **VOID — DO NOT SUBMIT**.
