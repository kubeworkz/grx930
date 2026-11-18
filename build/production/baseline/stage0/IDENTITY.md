# Stage 0 — production identity freeze

**Status: FROZEN 2026-11-18. No synthesis, P&R, DRT, stream-out, ECO insertion, or
RCX has run.** This is the identity input to the fresh baseline, not a production
signoff. The existing submission package remains **VOID — DO NOT SUBMIT**, and G0
remains `BLOCKED`.

The gate is: every Stage 0 input has a hash, and there is exactly one
netlist/floorplan pair. That gate is met below. The fresh baseline's synthesized
netlist, routed DEF, final GDS, and SPEF do not exist yet.

## One netlist

| Item | Pinned value |
|---|---|
| Netlist entry | `c930/asic_gf180mcu/openlane2_rtl/src` (RTL source, not an old synthesized netlist) |
| Top | `chip_top` |
| RTL files | 40 |
| RTL tree SHA-256 | `7c4d919b1950033089a2a43b8be729defb9ff50e2a50873865552b76f85049b9` |
| Flow RTL files | 38, excluding `c930_bootrom.sv` and `bootrom_wrapper.sv` |
| Flow sources outside RTL tree | `chip_top.sv`, `chip_core_grx930.sv`, `slot_defines.svh` |
| Netlist manifest | `build/production/baseline/stage0/netlist_sha256.txt` |

The tree hash is over the 40 files using the method recorded in the manifest:
`cd c930/asic_gf180mcu/openlane2_rtl/src && find . -type f -print0 | sort -z |
xargs -0 sha256sum | sha256sum`.

The old Yosys netlist
`openlane2_rtl/runs/RUN_2026-09-22_01-09-38/06-yosys-synthesis/grx930_test_chip.nl.v`
(SHA-256 `0540ffbf8a799fb473e3876aa6081d076a4dce964914a5c4e6b9f075185278c7`,
424,882 lines) is **excluded**, as is the audit DEF. The only netlist in this
identity is the RTL entry above; Stage 2 produces a new synthesized netlist from
it, and that new file is not pinned until it exists.

## PDK and tools

| Item | Pinned value |
|---|---|
| PDK | `gf180mcuD` |
| PDK commit | `0fe599b2afb6708d281543108caf8310912f54af` |
| PDK source | `volare fetch --pdk gf180mcu 0fe599b2afb6708d281543108caf8310912f54af` |
| PDK root | `/workspace/gf180mcu` (image default) |
| Standard-cell library | `gf180mcu_fd_sc_mcu7t5v0` |
| Pad library | `gf180mcu_fd_io` |
| RCX corners | `nom`, `min`, `max` (`rules.openrcx.gf180mcuD.*`; verify in Stage 1) |
| Flow image | `ghcr.io/wafer-space/gf180mcu-precheck@sha256:104d9ccbc0d3e4bbffba6201b7f68cd8f64d064b5b9072b64a3a4c926d46339f` |
| Flow image, linux/amd64 | `sha256:f4a9fe760e6dc43ade6245f801b9f6b5807161ea2e12590b241fba55d2d087b0` |
| Stream/fill image | `ghcr.io/efabless/openlane2:2.3.10@sha256:37c3bd4ea0534a276cb2deb88d601044857bad2807b9bc5b36efe9d02c62624e` |
| KLayout G2 image | `grx930/klayout-lvs-pmap:local@sha256:520139faa49df8d2a39a9a88345f7b3544db0bf8698258a4a006b2d2d5c05ae3` |

The flow image is pinned by its OCI index digest, not the mutable `latest` tag.
`docker manifest inspect`/`buildx imagetools inspect` resolved the digest; the
image is **not present locally**, so Stage 1 must pull the pinned digest and
verify the PDK/RCX files inside it. This Stage 0 did not pull it.

## Overrides and PDN

| Input | SHA-256 |
|---|---|
| `grx930_overrides.yaml` | `2e35833d4adc80560f81dce9a13f0f5b1f437e134e8a0c095b2f16c46a3910c9` |
| `pdn_cfg_grx930.tcl` | `cb9fd56896f184fd435f133b3bef370d8825f2ebf97a1ed880da5bbb1e29f00b` |
| `macros_grx930.yaml` | `8b3fa88edb6a5bd75d3962dda9580acbe745edbca76718f84e59d4cd62ebd83e` |
| `cells.lef` | `8251799d31ff62347a27db44e3ec9eed4a3c1ee50c05a54eb06d46bd735ee58b` |
| PDK cell GDS | `6c8be6496c53aa03cb8f35e6b75bef60a05b10cc00b191048cb86e38d3874049` |

The complete checksum list is `baseline_manifest.sha256`; the hashes above are
the design-specific files that must not change without a new Stage 0.

## Die: 3932 × 5122 µm

| Evidence | Value |
|---|---|
| `slot_1x1.yaml` | `DIE_AREA: [0, 0, 3932, 5122]` |
| `slot_1x1.yaml` SHA-256 | `cb47d6bb0e23d802c7b1fd54307880be466a3e6a09622222d47d73601a26b5a9` |
| Core area | `CORE_AREA: [442, 442, 3490, 4680]` = 3048 × 4238 µm |
| Audit DEF | `DIEAREA ( 0 0 ) ( 7864000 10244000 )` at 2000 dbu/µm = **3932 × 5122 µm** |
| Audit DEF SHA-256 | `a2511927e233b9b2ac87e7e0285d5f33499516c0594a4e48d40640cbbeb40b8f` |
| G0 defaults | `expected_die_w=3932`, `expected_die_h=5122` |

**The 3930 × 5120 figure in the earlier plan is wrong and is retired.** The
`slot_1x1` template on disk says 3932 × 5122, the audit DEF says 3932 × 5122, and
G0 says 3932 × 5122. The 3930 × 5120 references belong to older
`PLAN_B`/`pad_ring_check.py`/area-budget material, not this floorplan. The fresh
baseline freezes **3932 × 5122 µm** (DEF bbox `7864000 × 10244000` at 2000
dbu/µm), with core `[442, 442, 3490, 4680]`.

## ECO count: re-derive, do not reproduce 8,168

The old `8,168 = 7,626 sub + 540 rows + 2 rail` count belongs to the fix16/fix70
database: its `sub` M1 islands, its VSS/VDD M3 strips and row-300 exclusion, and
the old `$45264` rail name. A new placement, PDN, fill, and stitch pass change all
three terms, so the count is **not reproducible by this frame**.

Stage 0 therefore freezes:

- `eco_count=TO_BE_DERIVED`
- `count_equation=N_sub + N_rows + N_rail`
- `legacy_count=8168` — historical fixture only, not a target
- `legacy_identity=fix16/fix70`
- `count_gate=Stage 5` — `N` is frozen from `eco_sites.csv` and its report

G0 still hardcodes `expected_drops=8168` in `g0_freeze.sh` and the checkers. It
must be parameterized with `G0_DROPS=<N>` before it is used on this baseline;
8,168 must not gate a fresh frame.

## Stage 0 result

- `identity=READY_FOR_STAGE1`
- `netlist=ONE` (RTL entry; old synthesized netlists excluded)
- `floorplan=ONE` (`slot_1x1`; 3932 × 5122)
- `pdk=PINNED` (`0fe599b2…`)
- `flow_image=PINNED_BY_DIGEST`, locally absent
- `eco_count=TO_BE_DERIVED`
- `G0=BLOCKED`, `G2=BLOCKED`, package=`VOID — DO NOT SUBMIT`

Stage 1 must pull the pinned flow image and verify the in-image PDK commit and
`rules.openrcx.gf180mcuD.{nom,min,max}`. Until then this is an identity freeze,
not a toolchain qualification.

## Verification

From the repository root:

```bash
sha256sum -c build/production/baseline/baseline_manifest.sha256
sha256sum -c build/production/baseline/stage0/netlist_sha256.txt
```

No synthesis, P&R, DRT, stream-out, ECO, or RCX command was run for this record.
