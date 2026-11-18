# Fresh baseline plan — RTL to routed DEF to a new-count ECO to GDS/SPEF

**Status: STAGE 1 PASS — PDK/RCX/IMAGE CHECKS PASS; PRODUCTION HOST
READINESS PASSES (197 GiB FREE); NO FLOW STARTED.** The Stage 0 pin is
`build/production/baseline/stage0/IDENTITY.md`.
No synthesis, place-and-route, DRT, stream-out, ECO insertion, or RCX command has
been run for this plan. The submission package remains **VOID — DO NOT SUBMIT**.

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
drop list with a new count `N = N_sub + N_rows + N_rail`. G0, the DEF/GDS check,
and the fixtures must take `N` as a parameter; the 8,168 fixtures remain
historical/synthetic controls only. If the project requires exactly 8,168, the
path is to recover the old database, not to run this plan.

## 1.2 Production host and checkout path

The production target verified on 2026-11-18 is:

- **Host:** `ubuntu@2.31.100.64` (`ubuntu-32gb-fsn1-1`, aarch64; 31,260 MiB
  total memory).
- **Source checkout:** `/home/ubuntu/grx930` (git branch
  `npu/shim-tile-model`; synchronize the intended source before staging).
- **Flow root:** `/mnt/HC_Volume_107515356/grx930_ol2`; this is the deployed
  tree mounted at `/work`, not a git checkout. It contains `ws/`, `build/`, and
  `openlane2_rtl/`.
- **Flow image:** `gf180mcu-precheck:arm64`, the local aarch64 build of the
  pinned pre-check image.

The old assumption `ubuntu@49.13.6.8:/home/ubuntu/grx930_ol2` is retired. The x86
host does not have that path; it has only an old `/home/ubuntu/grx930` checkout,
and its root filesystem has 36 GiB free (its auxiliary volume has 4.3 GiB).

No host may start Stage 2 until the readiness gate in the Stage 2 section writes
`status=PASS` for `/mnt/HC_Volume_107515356/grx930_ol2` with
`disk.available_gb >= 150`. That gate now records **197 GiB free and
`status=PASS`**. Stage 2 has not been started.

## 2. Existing assets to reuse

| Purpose | Path | Notes |
|---|---|---|
| Full-chip flow runner | `c930/asic_gf180mcu/ws/ws_exec.sh` | LibreLane Chip flow; `WS_TAG`, `WS_LIMIT`, `WS_FROM`, `WS_OVERRIDE`; `cd /work/ws/template`; runs land in `librelane/runs/<tag>/` |
| Template source | `c930/asic_gf180mcu/tools/gf180mcu-project-template/` | `librelane/` and `src/`; `ws/template` is absent locally; contains its own `.git` |
| Slot config | `.../librelane/slots/slot_1x1.yaml` | pad ring and DIE/CORE area; **3932 × 5122 µm**, core `[442, 442, 3490, 4680]` |
| Design overrides | `c930/asic_gf180mcu/wafer_space_integration/grx930_overrides.yaml` | SHA-256 `2e35833d4adc80560f81dce9a13f0f5b1f437e134e8a0c095b2f16c46a3910c9`; GRT 0.1, DRT_OPT_ITERS 8, antenna 10/10 |
| Core adapter | `.../wafer_space_integration/chip_core_grx930.sv` | SHA-256 `585661ccc48cf1852ac0d9829abced93bac1beb3f151dbe640ad0f55d8b91c0b`; replaces `src/chip_core.sv` |
| PDN config | `.../wafer_space_integration/pdn_cfg_grx930.tcl` | SHA-256 `cb9fd56896f184fd435f133b3bef370d8825f2ebf97a1ed880da5bbb1e29f00b`; destination is `librelane/pdn/` |
| Macro list | `.../wafer_space_integration/macros_grx930.yaml` | destination is `librelane/macros/`; 5 declarations, 0 demo SRAM |
| RTL tree | `c930/asic_gf180mcu/openlane2_rtl/src/` | destination is `ws/template/asic_core/`; 40 `.sv`; exclude `c930_bootrom.sv` and `bootrom_wrapper.sv` |
| Pre-DRT resume | `c930/asic_gf180mcu/ws/die_predrt_exec.sh` | records the exact resume shape and state-file contract; a fresh run starts from RTL |
| Fast DRT loop | `c930/asic_gf180mcu/drt_fast/{run_drt.sh,die_drt.tcl,drt_fast.tcl}` | `run_drt.sh` hardcodes `D=/work/drt_fast`; output is `$FAST_OUT/$FAST_TAG.odb` |
| DRT chain + guard | `c930/asic_gf180mcu/build/{die_drt_chain.sh,drt_curve_guard.sh,drt_db_compare_chain.sh,gate.sh}` | budgets, divergence kill, disk/memory gate |
| Fill / stream / stitch / CDL | `c930/asic_gf180mcu/tools/lvs_chip/{fill_def.py,stream_out.py,pdn_stitch.py,mk_chip_cdl.py}` | the actual GDS construction; must run in the OpenLane image |
| Stream/route checks | `.../tools/lvs_chip/{stream_check.py,net_compare.py}` | layer/placement and DEF-vs-CDL checks |
| Cell/tech LEF | `c930/asic_gf180mcu/build/cells.lef` | 5 routing layers and 56 `VIA` definitions; the only via-geometry source for `stream_out.py` |
| PDK cell GDS | `c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds` | `stream_out.py` and `pdn_stitch.py` read cell layouts from it |
| G0/G2 | `build/production/run/{g0_freeze.sh,g2_lvs.sh,gds_checks.rb,def_gds_checks.rb}` | die, count, paths, and the row-300 box are hardcoded |

**Toolchain status:** the production ARM flow box has
`gf180mcu-precheck:arm64` at the pinned pre-check identity. Stage 1 pulled and
verified the in-image CIEL `792ef…` PDK, OpenROAD `dcf3613…`, and RCX rules.
The retired x86 image reference is not the production flow target. The local
`openlane2-gf180mcu:latest` and `ghcr.io/efabless/openlane2:2.3.10` images are
not the full-chip flow image.

**Why the GDS pipeline matters.** The production GDS is not a single stream-out.
`fill_def.py` adds fillers and well taps, `stream_out.py` renders the filled DEF,
and `pdn_stitch.py` adds the M2 straps that join the M1 rails to the M3 grid. The
fix16 base is exactly that chain (`..._stream_out_filled_stitched_fix16.gds`), and
the `sub` islands this plan must find exist only after the fill and stitch passes.
`stream_out.py` now builds its `VIA_<name>` cells from the LEF `VIA` definitions
the DEF names and refuses a via with no definition, so the VOID artifact is no
longer in the fresh-baseline GDS path.

## 3. Stages

### Stage 0 — Freeze the identity and choose the floorplan

Inputs: RTL tree, overrides, slot config, PDK version, flow image, `cells.lef`
(including its 56 `VIA` definitions), and the PDK cell GDS.

Record before any compute:
- Netlist entry: full-chip `openlane2_rtl` RTL through `ws_exec.sh`, 40 files,
  tree SHA-256 `7c4d919b1950033089a2a43b8be729defb9ff50e2a50873865552b76f85049b9`.
  The old Yosys netlist and audit DEF are **not** inputs. The flow's `DESIGN_NAME`
  is `chip_top`, so the routed ODB and netlist top is `chip_top`; `stream_out.py`
  names the GDS top `grx930_test_chip`. The CDL must be written with
  `grx930_test_chip` as its top, or G2's `topcell` will name a netlist the deck
  does not have (Stage 4).
- Die/core: the ws `slot_1x1` template, the audit DEF, and G0 all use
  **3932 × 5122 µm** (core `[442, 442, 3490, 4680]`). The old 3930 × 5120 figure
  is retired and must not be used. A fresh floorplan uses the template die; G0
  already defaults to 3932 × 5122.
- **ECO count:** new count `N`; do not plan for 8,168 (see §1.1).
- Corner/RCX set: `nom`, `min`, `max` from the PDK RCX rules.

Output: `build/production/baseline/baseline_manifest.sha256`,
`stage0/IDENTITY.md`, and `stage0/netlist_sha256.txt`. The manifest pins the RTL
tree, overrides, PDN, macros, PDK version, flow image index digest, die/core,
LEF, cell GDS, and `N=TO_BE_DERIVED`; the netlist manifest pins the 40 RTL files
plus `chip_top.sv`, `chip_core_grx930.sv`, and `slot_defines.svh`. Stage 0 has
replaced the `TO_BE_PINNED` placeholders.

Gate met: every input has a hash and there is exactly one netlist/floorplan pair
(`identity=FROZEN_REPINNED`). Stage 1 has pulled the image, verified its PDK
(`792ef…`), OpenROAD (`dcf3613…`), and RCX files, and recorded the pad-ring/mask
comparison; see `baseline/stage1/STAGE1_VERIFICATION.md` and
`baseline/stage1/PAD_RING_MASK_COMPARISON.md`. The 792 cell LEF/GDS and merged
`cells.lef` have replaced the old 0fe pins. The flow has not started.

### Stage 1 — Toolchain and PDK readiness

**Result 2026-11-18: PASS — PDK/RCX re-pin PASS; production host readiness
passes on the volume-backed flow root.** The pinned image was pulled and inspected read-only. Stage 0 was
moved to its CIEL/Open_PDKs `792ef…` PDK and OpenROAD `dcf3613…`; the RCX rules
are present at `gf180mcuD/libs.tech/librelane/`. The 0fe→792 pad-ring/mask
comparison found the GDS pad-opening layer identical and requires no pad-ring or
floorplan edit. Full records: `baseline/stage1/STAGE1_VERIFICATION.md`,
`baseline/stage1/STAGE1_READINESS.txt`, and
`baseline/stage1/PAD_RING_MASK_COMPARISON.md`.

- Pull and pin the full-chip image by index digest, not a tag:
  `docker pull --platform linux/amd64 ghcr.io/wafer-space/gf180mcu-precheck@sha256:104d…`
  and record `docker image inspect --format '{{.Id}}'`.
- Inspect its PDK at the default `--pdk-root /workspace/gf180mcu`; resolve
  `gf180mcuD` and verify the OpenRCX rules at
  `gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.{nom,min,max}`. If the
  image's PDK or OpenROAD does not match the frozen pin, stop; Stage 8 cannot
  run.
- Pin `ghcr.io/efabless/openlane2:2.3.10` (fill/stream/stitch/CDL) and
  `grx930/klayout-lvs-pmap:local` (G2 deck).
- Run the explicit host gate on the production host, against
  `/mnt/HC_Volume_107515356/grx930_ol2`:

  ```bash
  /home/ubuntu/grx930/c930/asic_gf180mcu/build/stage1_readiness.sh \
    --volume /mnt/HC_Volume_107515356/grx930_ol2 \
    --record /mnt/HC_Volume_107515356/grx930_ol2/build/production/baseline/stage1/STAGE1_READINESS.txt
  ```

  The script is present in the source checkout. It requires at least 12 GiB
  available memory for pre-DRT, 8 GiB for a DRT arm, and 150 GiB free on the
  volume. The production run records 29,179 MiB available (both memory floors
  PASS) and 197 GiB free (`disk=PASS`), with `status=PASS`. The flow-chain
  `gate.sh` remains the per-arm launch guard, not a substitute for this Stage 1
  record.

Output: `toolchain_versions.txt`, `STAGE1_READINESS.txt`, and
`STAGE1_VERIFICATION.md` (librelane, OpenROAD, KLayout, image digests, PDK path,
RCX hashes, host readiness, pad-ring/mask comparison, and the pass verdict).

Gate: the exact RCX rule files and OpenROAD build are readable **and match the
frozen pin**, and `STAGE1_READINESS.txt` has `status=PASS`. A version bump or a
resource-gate failure restarts the Stage 1 check. The current production record
is **PASS** (197 GiB free volume), so this gate is **MET**. Stage 2 has not been
started.

### Stage 2 — RTL through global route to a pre-DRT ODB

**Prerequisite — passing production readiness gate.** Do not run any command in
this section until the gate above writes a record ending `status=PASS` and
`disk.available_gb >= 150` for `/mnt/HC_Volume_107515356/grx930_ol2`. The
production volume now records 197 GiB free and `status=PASS`; this section
remains unlaunched until the owner explicitly starts Stage 2.

The container mount root is the deployed flow root
`/mnt/HC_Volume_107515356/grx930_ol2`, **not the source checkout and not the
repository root**: `ws_exec.sh` does `cd /work/ws/template`, and the RTL tree is
at `/work/openlane2_rtl`.

Stage the template exactly:

```bash
set -e
SRC=${SRC:-/home/ubuntu/grx930}
ROOT=${ROOT:-/mnt/HC_Volume_107515356/grx930_ol2}
FLOW="$SRC/c930/asic_gf180mcu"
STAGE="$ROOT/ws/.template.stage"

# ws/template is generated by this block; do not keep local edits there. Build
# the new tree beside the live one, validate it, then swap it in. Re-running the
# block cannot nest the template inside itself or retain stale overlays.
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$FLOW/tools/gf180mcu-project-template/." "$STAGE/"
rm -rf "$STAGE/.git"
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
test -f "$STAGE/src/slot_defines.svh"
test -f "$STAGE/asic_core/grx930_test_chip.sv"
test ! -e "$STAGE/asic_core/c930_bootrom.sv"
test ! -e "$STAGE/asic_core/bootrom_wrapper.sv"
test -f "$STAGE/librelane/slots/slot_1x1.yaml"
test -f "$STAGE/librelane/config.yaml"
test -f "$STAGE/librelane/grx930_overrides.yaml"
test -f "$STAGE/librelane/macros/macros_grx930.yaml"
test -f "$STAGE/librelane/pdn/pdn_cfg_grx930.tcl"
[ "$(ls "$STAGE/asic_core"/*.sv | wc -l)" -eq 38 ]
[ "$(grep -c '^  gf180mcu' "$STAGE/librelane/macros/macros_grx930.yaml")" -eq 5 ]

rm -rf "$ROOT/ws/template"
mv "$STAGE" "$ROOT/ws/template"
```

`grx930_overrides.yaml` declares `VERILOG_FILES` as `../src/chip_top.sv`,
`../src/chip_core.sv`, and `../asic_core/*.sv`; `PDN_CFG` is
`dir::pdn/pdn_cfg_grx930.tcl`, which is why the PDN file goes under
`librelane/pdn/`. `ws_exec.sh` writes `src/generated_defines.svh` itself.

Run on the production host with a fresh tag:

```bash
docker run --rm --user 0:0 \
  -v /mnt/HC_Volume_107515356/grx930_ol2:/work \
  -e WS_TAG=prod_stage2_01 \
  -e WS_LIMIT=OpenROAD.STAMidPNR-3 \
  gf180mcu-precheck:arm64 /work/ws/ws_exec.sh
```

`WS_TAG` must be fresh; resuming an old tag reuses its netlist. `STAMidPNR-3` is
the last pre-DRT state: the STA steps pass the ODB through, and the DRT step reads
the ODB named by the last `state_out.json`. At 0.1 the antenna step can abort with
`GRT-0183`; `ws_exec.sh` installs `lln_antenna_catch.sh`, which keeps the inserted
diodes and lets the step write its database. Treat that as a recorded condition,
not a silent pass, and archive the antenna log.

Output: the ODB named by the newest
`ws/template/librelane/runs/prod_stage2_01/*/state_out.json`; copy it to
`build/production/baseline/pre_drt.odb` and keep the state file.

Gate:
- `resolved.json` shows `GRT_ADJUSTMENT: 0.1` and `DRT_OPT_ITERS: 8`; the GRT log
  contains `Global adjustment: 10%`.
- No `GRT-0183` appears in any step log. A caught occurrence is a failure under
  this gate; archive the log and stop rather than accepting the ODB.
- PDN inserted exactly once; macro-instance check passes.
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

Run the same with `FAST_END_ITER=8` and a **new tag** (`prod01_drt8`) only after
the probe shows a decreasing violation curve; `die_drt.tcl` writes
`$FAST_OUT/$FAST_TAG.odb`, so reusing the probe tag would overwrite the probe.
Keep `drt_curve_guard.sh` attached to kill a divergent pass and to bound
per-iteration and per-pass wall time. Do not use the last ODB if the curve
diverged; the guard exists because the router writes the last database, not the
best one.

Output: `/work/drt_fast/out/prod01_drt/prod01_drt.odb` for the probe and
`/work/drt_fast/out/prod01_drt8/prod01_drt8.odb` for the full pass; copy the
latter to `build/production/baseline/routed.odb` and keep the DRT log and curve.

Gate: **0 DRT violations**, or a numbered, owner-signed waiver. A nonzero count is
not a routed production baseline.

### Stage 4 — Route QA, then build the pre-ECO GDS

Export the routed DEF and the post-route Verilog from the ODB in the flow image:

```bash
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$(cygpath -m .):/work" -w /work \
  ghcr.io/wafer-space/gf180mcu-precheck openroad -no_init -exit <<'EOF'
read_db /work/build/production/baseline/routed.odb
write_def /work/build/production/baseline/routed.def
write_verilog /work/build/production/baseline/grx930_test_chip_routed.v
EOF
```

Build the CDL from that netlist and check the routed DEF against it. This is also
the CDL G0/G2 will freeze, so build it here rather than at the end:

```bash
runpy() {
  MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$(cygpath -m .):/work" -w /work \
    --entrypoint python3 ghcr.io/efabless/openlane2:2.3.10 "$@"
}
# The flow top is chip_top; the GDS top (and the deck's `topcell`) is
# grx930_test_chip. Add `--top` to mk_chip_cdl.py so the CDL's .SUBCKT matches
# the layout, instead of renaming the netlist or the deck.
runpy c930/asic_gf180mcu/tools/lvs_chip/mk_chip_cdl.py \
  --routed /work/build/production/baseline/grx930_test_chip_routed.v \
  --top grx930_test_chip \
  --out /work/build/production/baseline/grx930_test_chip.cdl
runpy c930/asic_gf180mcu/tools/lvs_chip/net_compare.py \
  --def /work/build/production/baseline/routed.def \
  --cdl /work/build/production/baseline/grx930_test_chip.cdl \
  --json /work/build/production/baseline/net_compare.json
```

`net_compare` answers connectivity, not coverage: a net can have both pins and no
wire and still match. Add one small OpenDB pass over the routed database that
counts multi-terminal signal nets with no `Wire`/`SWire` and any net with fewer
than two terminals; the audit DEF had 1,022 and 2 of that class. It is a loop over
`ord::get_db_block`, not a new checker.

**DEF-defined vias.** `stream_out.py` accepts only LEF `VIA` names, and a routed
DEF may define its own vias in a `VIAS` section instead. The old DEF has two:
`via3_4_3200_3200_3_3_1040_1040` and `via4_5_3200_6400_4_2_1240_1240`. Promote
them into a supplemental LEF; do not relax `stream_out.py` and do not read the
artifact. Run `promote_def_vias.py` (§4) after route export:

```bash
runpy c930/asic_gf180mcu/tools/lvs_chip/promote_def_vias.py \
  --def /work/build/production/baseline/routed.def \
  --lef /work/c930/asic_gf180mcu/build/cells.lef \
  --out /work/build/production/baseline/routed_vias.lef
```

For every `VIAS` entry, require `+ VIARULE <name>` (naming a
`VIARULE ... GENERATE` block in the LEF), `+ CUTSIZE w h`, `+ LAYERS lower cut
upper`, `+ CUTSPACING sx sy`, `+ ENCLOSURE e1 e2 e3 e4`, and `+ ROWCOL rows cols`.
Read the DEF's `UNITS DISTANCE MICRONS` (2000 here), convert to microns, and
emit a fixed `VIA <name>` block:

- `pitch_x = w + sx`, `pitch_y = h + sy`; DEF `CUTSPACING` is edge-to-edge, so
  the pitch is cut size plus spacing. Cut centres are
  `(i - (cols-1)/2) * pitch_x` and `(j - (rows-1)/2) * pitch_y`;
- the lower-metal rect spans `cols*w + (cols-1)*sx + 2*e1` by
  `rows*h + (rows-1)*sy + 2*e2`;
- the upper-metal rect spans the cut field plus `2*e3` by `2*e4`;
- one `RECT` per cut on the cut layer, one per metal.

`e1`/`e2` enclose the lower metal in x/y and `e3`/`e4` the upper metal. This is
the DEF convention, not the LEF `VIARULE` `ENCLOSURE` pair.

`LAYERS` must name the same lower, cut, and upper layers as the named VIARULE
(identified by role; the VIARULE block lists lower, upper, cut), and its cut RECT
must equal `CUTSIZE`. The DEF's `CUTSPACING` and `ENCLOSURE` win over the
VIARULE's generator defaults; the two old entries differ from
`Via3_GEN_HH`/`Via4_GEN_HH`, so copying those defaults would silently change the
via. Refuse with status 2 on a missing or unknown token, unknown VIARULE,
layer-role or cut-size mismatch, non-positive dimension, `VIAS` count mismatch,
or a name already defined in the LEF. A bare `VIARULE` name used as a via without
a `VIAS` entry is still refused; the router must emit the `VIAS` definition or use
a LEF via. Never fall back to the artifact.

The formula reproduces the old DEF exactly: 9 cuts with 1.42 × 1.60 µm and
1.60 × 1.42 µm metals, and 8 cuts with 1.60 × 2.24 µm and 1.00 × 2.58 µm metals.
A `test_promote_def_vias.py` regression uses those two entries as fixtures,
feeds the generated LEF through `stream_out.parse_lef_vias`, and checks every
refusal; it reads no design or artifact.

Then build the pre-ECO GDS in the documented order:

```bash
runpy c930/asic_gf180mcu/tools/lvs_chip/fill_def.py \
  --def /work/build/production/baseline/routed.def \
  --lef /work/c930/asic_gf180mcu/build/cells.lef \
  --out /work/build/production/baseline/filled.def
runpy c930/asic_gf180mcu/tools/lvs_chip/stream_out.py \
  --def /work/build/production/baseline/filled.def \
  --lef /work/c930/asic_gf180mcu/build/cells.lef \
  --lef /work/build/production/baseline/routed_vias.lef \
  --routing def --out /work/build/production/baseline/pre_eco_stream.gds
runpy c930/asic_gf180mcu/tools/lvs_chip/pdn_stitch.py \
  --def /work/build/production/baseline/filled.def \
  --gds /work/build/production/baseline/pre_eco_stream.gds \
  --out-gds /work/build/production/baseline/pre_eco.gds \
  --report /work/build/production/baseline/strap_report.json
runpy c930/asic_gf180mcu/tools/lvs_chip/stream_check.py \
  --gds /work/build/production/baseline/pre_eco.gds \
  --def /work/build/production/baseline/filled.def \
  --lib /work/c930/asic_gf180mcu/build/lvs_chip/pdk_fd_sc_mcu7t5v0.gds
```

`stream_out.py` reads the PDK cell GDS for cell layouts and the LEF's `VIA`
definitions for via cells; `--lef` is repeatable, and every via token the DEF
names must be defined in one of them. The routed DEF must therefore use LEF vias
only: a DEF `VIAS` section is promoted above, not approximated from the old
layout. The PDK GDS and base LEF are pinned in Stage 0; `routed_vias.lef` is
generated here and hashed into G0. If the router emits no `VIAS` section, the
promoter writes a header-only LEF and the command still passes both files. The
supplemental file contains only `VIA` blocks, so layer widths stay from
`cells.lef`; the promoter also refuses a name already in the base LEF, so
`stream_out`'s first-definition-wins lookup cannot silently prefer the wrong
geometry. The artifact is not read in `--routing def` mode.

Output: `routed.def`, `routed_vias.lef`, `grx930_test_chip_routed.v`,
`grx930_test_chip.cdl`, `filled.def`, `pre_eco.gds`, `strap_report.json`,
`net_compare.json`.

Gate: `net_compare` MATCH; 0 unrouted signal nets and 0 zero/one-terminal nets
from the OpenDB pass; the CDL top is `grx930_test_chip`, the same name the GDS top
and the G2 deck use; every DEF `VIAS` entry was promoted into `routed_vias.lef`,
and `stream_out.py` built every via from a LEF definition and refused none; fill
and stitch exit 0 with no refused island; stream check passes.

### Stage 5 — Derive the new ECO site list

Build `find_eco_sites.py` on `pre_eco.gds` plus `filled.def`, using the legality
rules in `validate_drop_windows_2x2.rb`. The `sub` islands and the rail ends exist
only after the fill/stitch passes, so the routed ODB is the wrong source.

- Substrate tap islands from connected M1 components on the `sub` net.
- Legal VSS rows from the new VSS labels/strips; exclude any row whose only clean
  M2 corridor overlaps VDD (the row-300 rule, generalized).
- Rail-end drops from the new power-rail geometry; do **not** look for the old
  `$45264` name.
- 0.84 µm M2 strap, 1.40 µm M2 keepout, 0.90 × 0.78 µm M1 landing,
  0.90 × 0.80 µm M3 landing, no VDD overlap.

Output: `eco_sites.csv` (name, x, y, ty, kind) and a report with
`N_sub + N_rows + N_rail = N`.

The CSV carries **GDS database units** (1 nm), the frame the stitched GDS and
`build_row_crops.rb` use. The DEF writer doubles them (2000 dbu/µm) and the
checker converts back with the same round-half-to-even rule as `stream_out.py`;
keep that conversion in one helper so a site cannot shift by half a DEF unit.

Gate: `N` is frozen from the report, every site legal, no duplicate rows, and the
generalized VDD exclusion holds. **Do not gate on 8,168.**

### Stage 6 — Insert the ECO into the DEF/ODB and the base GDS

One site list, two writers, so the DEF and GDS cannot drift:

1. **DEF/ODB** — `insert_eco_2x2.py` reads `filled.def` and `cells.lef` into
   OpenDB (run under `openroad -python`; preflight `import odb`), inserts the M1
   landing, the M2 strap, the M3 landing, and the Via1
   `Via1_2X2_0_60_10_60_H_V` / Via2 `Via2_2X2_0_60_10_60_V_H` arrays, then writes
   `eco_routed.def` and `eco_routed.odb`. Starting from `filled.def`, not the
   routed ODB, keeps the fillers and well taps. The filled DEF has no `sub` net
   (its `SPECIALNETS` are the supply nets), so create one with no terminals and
   attach the substrate drops to it; the DEF net name is not what G0 checks, and
   LVS reads the CDL, not this DEF. If the precheck image's OpenROAD has no
   `odb` Python module, write the ECO DEF statements directly instead; the GDS
   writer and the site list are unchanged.
2. **GDS** — `patch_eco_gds.rb` inserts the same geometry from the same
   `eco_sites.csv` into `pre_eco.gds` and writes
   `build/production/final/grx930_test_chip_final.gds`. This is the 13-site
   `build_row_crops.rb` method extended to the full list, using the 2×2 `VIA`
   definitions from `cells.lef`: M1 landing, M2 strap with 0.45 µm extension past
   each via centre, M3 landing, 0.26 µm cuts on 0.52 µm centres.

Do **not** re-stream the ECO DEF. The 2×2 vias are now buildable from the LEF, but
a re-stream would produce a new `pre_eco` frame and lose the GDS-only stitch
straps; patching the existing `pre_eco.gds` keeps the base/final delta exactly the
inserted geometry.

Run the DRC/landing checks on **all** sites, not the 13-site crop, and compare
before/after reports.

Output: `eco_routed.odb`, `eco_routed.def`, `final/grx930_test_chip_final.gds`,
`eco_drc.rlyrdb`, `eco_landing.log`.

Gate: 0 added M1/M2/M3/V1/V2 findings; `N` of each 2×2 via; no VDD overlap; M1/M3
landing coverage met; M2 keepout respected.

### Stage 7 — G0 geometry checks

The checks are window-based, not full-chip: the pre-ECO GDS carries the
`pdn_stitch` M2 straps that the DEF does not, so a whole-die Metal XOR can never
be zero. Compare only the ECO windows, where base and final differ by exactly the
inserted geometry.

- `gds_checks.rb -rd gds=final.gds -rd base=pre_eco.gds -rd def=eco_routed.def
  -rd topcell=grx930_test_chip -rd expected_die_w=<DEF die>
  -rd expected_die_h=<DEF die> -rd expected_drops=<N> -rd report=...` — counts new
  260 × 260 Via2 cuts, requires `4N`, and checks the die.
- Change `def_gds_checks.rb` to take `-rd base=pre_eco.gds` and
  `-rd sites=eco_sites.csv`, and compare, inside each site window,
  `(final.gds − base.gds)` against `(eco_routed.def − filled.def)`. Count the 2×2
  Via1/Via2 drops from the DEF anchors and require `N`, and assert that the GDS
  delta is contained in the site windows. Drop the hardcoded `ROW300_*` box: the
  generalized VDD exclusion is enforced when the site list is frozen (Stage 5),
  and the old box names coordinates this baseline will not have.
- Remove the old row-300 box from `gds_checks.rb` as well. It is a gate
  (`row300_new == 0`), so on a new floorplan it can only fail spuriously; the
  exclusion belongs in the site list, not in a fixed rectangle.

Run both checkers once, through the parameterized G0 in Stage 9; do not duplicate
the invocations here.

Gate: both checkers exit 0; zero XOR inside every site window; `N` Via1 and Via2
drops; no new geometry outside the windows.

### Stage 8 — Extract SPEF with OpenRCX

Verified against the re-pinned Stage 0 OpenROAD build
(`dcf36133a369abc8f3c5e5738cd4d82e4903c0e0`): `define_process_corner`,
`extract_parasitics`, and `write_spef` are present. `report_parasitics` does
**not** exist; use `report_parasitic_annotation` and `read_spef`/`diff_spef`.
This is command-name verification only; RCX has not run.

Run one corner per process against `eco_routed.odb`, so each rules file defines
its own corner at index 0. Do not pass `-ext_model_file` again after
`define_process_corner`; it redefines the corner set the first call just made.

```tcl
read_db /work/build/production/baseline/eco_routed.odb
define_process_corner -ext_model_index 0 \
  <PDK>/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom
extract_parasitics
write_spef /work/build/production/final/grx930_test_chip.spef
```

`define_process_corner` takes **one filename** plus the optional
`-ext_model_index`; it does **not** take `(index, "corner name")`. Name the corner
in the SPEF metadata or a sidecar. Repeat with a separate process for `min` and
`max` if the signoff corners require them.

Validation: use `report_parasitic_annotation` and a net-coverage count against the
DEF netlist; write a second SPEF with `-nets` for a subset and compare with
`diff_spef` if needed.

Gate: SPEF net count equals the DEF net count; no unannotated clock nets; corner
files exist; `read_spef`/`diff_spef` succeeds.

### Stage 9 — Freeze, G0, and G2

- Add environment overrides to `g0_freeze.sh` and `g2_lvs.sh` rather than editing
  constants per run: `G0_GDS`, `G0_CDL`, `G0_DEF`, `G0_SPEF`, `G0_BASE`,
  `G0_DIE_W`, `G0_DIE_H`, `G0_DROPS`, `G0_SITES`, `G0_VIAS_LEF`, and the
  matching `G2_*`. Keep the current paths as defaults, so the VOID package's
  state is unchanged. The old row-300 rectangles in both checkers are removed
  rather than parameterized; the site list is the only place that rule can be
  stated correctly.
- Run `g0_freeze.sh` with `G0_BASE=pre_eco.gds`, `G0_DROPS=<N>`,
  `G0_SITES=eco_sites.csv`, `G0_VIAS_LEF=routed_vias.lef`, and the new
  GDS/CDL/DEF/SPEF. Require
  `status=READY_FOR_REVIEW`, `gds_checks=PASS`, `def_gds_checks=PASS`,
  `no_void=PASS`, and a manifest hash.
- Fill `G0_signoff.txt` with a **Gridworkz-authorized** signer. Do not fabricate it.
- Run `g2_lvs.sh` with the new GDS/CDL/DEF/SPEF; full-chip LVS uses the frozen
  GDS and CDL and the pmap-capable image. The DEF and SPEF are hash-gated inputs,
  not deck inputs. Historical full-chip LVS cost is ~5,983 s.

Gate: G0 signed; G2 completes with 0 mismatches; report and netlist archived.

## 4. Pieces that must be built

1. **ECO site finder** — GDS/DEF replacement for the missing `chip.l2n` logic,
   with a generalized VDD exclusion and no dependence on `$45264`.
2. **ECO inserter** — one site list consumed by an OpenDB DEF/ODB writer and a
   KLayout GDS patcher.
3. **DEF `VIAS` promoter** — implemented in `promote_def_vias.py`; it parses
   only the DEF `VIAS` section, cross-checks each `+ VIARULE` against the LEF,
   and writes `routed_vias.lef` from the DEF's cut/enclosure/rowcol values. It is
   a pure DEF+LEF transform and never reads the artifact.
4. **All-site DRC/landing harness** — extend the 13-site checks to every row and
   rail.
5. **CDL top override** — a `--top` option for `mk_chip_cdl.py`, because the flow
   top (`chip_top`) is not the GDS/deck top (`grx930_test_chip`).
6. **Window-based `def_gds_checks.rb`** — `base` + `sites` instead of a
   whole-die XOR and a fixed row-300 box.
7. **SPEF extraction Tcl** — one corner per process, verified commands only.
8. **G0/G2 parameterization** — die, count, paths, site list, and promoted LEF via
   environment.
9. **Baseline manifest and signoff form** — one pinned set of hashes from RTL to
   SPEF.

## 5. Compute and schedule risks

| Risk | Evidence / bound | Mitigation |
|---|---|---|
| DRT divergence | v8 ran 10.6 days over 26 iterations; best 237,089 violations at iter 16, then 711,100; the last ODB is kept, not the best | `drt_curve_guard.sh` budgets and kill; short probe first; never ship a diverged ODB |
| DRT memory | measured peaks 6.4–7.0 GB; Docker died under a 5.8 GiB container; pre-DRT gate wants 12 GB | `gate.sh`, 16 GB host, one arm at a time |
| Disk exhaustion | a GRT overflow arm filled a 150 GB volume; flat stream GDS 509 MB, merged 392 MB, plus ODBs | 150 GB free; `disk_guard.sh`; delete intermediate ODBs |
| GRT 0.2 abort | assembled die aborts with `GRT-0183` at 0.2; 0.1 is the landed value | keep 0.1; verify `Global adjustment: 10%` before DRT |
| Antenna repair abort | at 0.1 the die's `repair_antennas` can abort with `GRT-0183`; the landed arm relies on the catch | keep `lln_antenna_catch.sh`; archive the antenna log; do not read a caught abort as an antenna pass |
| ECO count is not 8,168 | the old list depends on fix16 `sub` islands, old VSS rows, and the old `$45264` net (§1.1) | derive `N`; parameterize G0/checkers; retire 8,168 with the old identity |
| CDL/GDS top mismatch | flow `DESIGN_NAME: chip_top`; `stream_out.py` writes the GDS top as `grx930_test_chip`; the deck takes `topcell=grx930_test_chip` | write the CDL with `--top grx930_test_chip` and gate on it before G0 |
| DEF `VIAS` is not streamable as-is | `stream_out.py` accepts only LEF `VIA` names; the old DEF has two `VIAS` entries | run `promote_def_vias.py` after route export, pass `routed_vias.lef` as a second `--lef`, hash it in G0; refuse incomplete entries; never fall back to the artifact |
| VOID artifact in the GDS path | `--routing def` no longer reads the artifact; only `--routing artifact` does, for re-checking the September die | keep `--routing artifact` out of the fresh-baseline stages |
| DEF/GDS mismatch outside the ECO | `pdn_stitch` writes M2 straps to the GDS only | window-based check; do not gate on a whole-die Metal XOR |
| ECO legality | 4,318 pre-existing full-chip DRC findings; 0-added requirement over all sites; 1.40 µm M2 keepout | all-site DRC, resites, generalized VDD exclusion |
| Runtime | full flow to pre-DRT days; DRT 1.5–10+ days per pass; fill/stream/stitch hours; LVS ~100 min; DRC ~10 min; RCX hours/corner; STA corners hours | dedicated machine, one baseline tag, checkpoint every step |
| Identity drift | legacy synth netlist, audit DEF, and die database; stale 3930×5120 references vs the 3932×5122 authority; unsupported keys `FP_DIE_AREA`/`DRT_ALLOW_CONGESTION` in the 2.3.10 log | Stage 0 freezes one RTL entry and 3932×5122; old synthesized netlists are excluded; use supported keys |
| RCX rules absent locally | local PDK `RCX_RULES` is empty; Stage 1 found the image rules at `gf180mcuD/libs.tech/librelane/`, with hashes in `stage1/toolchain_versions.txt` | use the verified `librelane` path; do not use the stale `openlane` path |
| Precheck image present | Stage 1 pulled the pinned index digest; image ID and size are in `stage1/STAGE1_VERIFICATION.md` | image present; PDK/RCX checks pass; host readiness gate PASS; Stage 2 not started |
| PDK/OpenROAD identity | Stage 0 re-pinned to image CIEL/Open_PDKs `792ef…` and OpenROAD `dcf3613…`; no `volare`; pad ring/mask comparison found no edits | use only these pins; the production readiness gate is PASS |
| Signoff | no Gridworkz connector; G1 DFT/ATPG absent; G3 waiver and G4 STA/power open | external signoff; do not claim a pass without receipts |

## 6. Planning envelope

Assuming one engineer, one dedicated 16 GB/150 GB machine, the PDK and RCX rules
available, and DRT converging in the historical 0.1 regime:

- Stage 0–1: 1–2 days.
- Stage 2 (RTL to pre-DRT): 1–3 days.
- Stage 3 (DRT): 1–10+ days; the largest variance.
- Stage 4 (VIAS promoter + QA + fill/stream/stitch/CDL): 2–3 days.
- Stage 5 (ECO list): 3–5 days.
- Stage 6 (ECO insert + all-site DRC): 1–2 weeks; the largest engineering risk.
- Stage 7 (geometry checks): 1 day.
- Stage 8 (RCX/SPEF): 1–3 days.
- Stage 9 (freeze/LVS): 1–2 days, plus Gridworkz signoff latency.

G0/G2 artifacts: roughly **4–8 weeks** after Stage 0. G3 DRC disposition, G4 STA/
power/IR/EM, G1 DFT/ATPG, and G5 foundry review are additional weeks to months and
are outside this plan.

## 7. Explicitly not done

Stage 1 pulled the pinned image and ran only read-only version, path, and hash
probes plus an OpenROAD command-help check; no `ws_exec.sh`, DRT, stream-out, ECO
insertion, or OpenRCX command has been run. The Stage 0 PDK/GDS/LEF pins were
updated to the image's 792 identity (see `baseline/stage0/IDENTITY.md`), and the
pad-ring/mask comparison is recorded in
`baseline/stage1/PAD_RING_MASK_COMPARISON.md`. Read-only inspection, a parser test
of the new LEF via reader, and a KLayout check of the 2×2 cell it builds were
run; no DEF was streamed. G0 remains `BLOCKED`, G2 exits 2, and the package
remains **VOID — DO NOT SUBMIT**.
