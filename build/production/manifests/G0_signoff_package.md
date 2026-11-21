# G0 signoff package — GRX930 test chip

Prepared 2026-11-21 from the `READY_FOR_REVIEW` G0 run. This is a review
package, not a signature. It does not modify `G0_status.txt`,
`input_sha256.txt`, the signoff template, or any gate result.
`G0_signoff.txt` is absent and must only be created by a Gridworkz-authorized
signatory after the reviews below.

## 1. Gate state

Source: `build/production/manifests/G0_status.txt` (SHA-256
`99d4be37683047fe11abb1284a4cb96f71277e1c3004bf51cb31aace78879a85`).

```text
gate=G0
status=READY_FOR_REVIEW
generated_utc=2026-11-21T21:39:35Z
no_void=PASS
gds_checks=PASS
def_gds_checks=PASS
missing=none
failures=none
manifest_sha256=15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800
```

The run log `build/production/manifests/g0_run.log` ends `g0_rc=0` (SHA-256
`4ababf5a9551e50319c4af3dca5f62addfda30cc2dadf176c7348b893691a4b8`).

**Manifest hash to sign:**

```text
15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800
```

This is the SHA-256 of `build/production/manifests/input_sha256.txt`, not of
the GDS or any single input. In this worktree, where the external inputs are
present, `sha256sum -c input_sha256.txt` passes all 13 entries. A clean checkout
can verify only the tracked subset; see §2.

## 2. Frozen inputs

All 13 entries are present and match the manifest in this worktree. Paths are
relative to the repository root; `input_sha256.txt` records absolute
`/c/Users/kubew/grx930` paths, so its `sha256sum -c` command is specific to this
checkout location. Only three entries are tracked at HEAD; the other ten are
untracked external inputs. Their hashes are recorded for verification after the
external artifacts are restored, not by a clean checkout.

| Input | SHA-256 | Clean checkout |
|---|---|---|
| `build/production/final/grx930_test_chip_final.gds` | `8fdeb5812ae7325a0b336e26b60cb873e1c75d370640aa63ecd69b0acf766b62` | external — not in Git |
| `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl` | `1a29a6ad2cb99882a8e2d8974cadff3237f317cc349c1a0c3e7f20545f75b717` | external — ignored |
| `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.def` | `d8c7211bf6d20db3297395d5a5c6ff5f31e9df70e3cb9ef55b6ef6b525579a01` | external — not in Git |
| `build/production/final/grx930_test_chip.spef` | `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0` | external — not in Git |
| `build/production/final/pre_eco_stream.gds` | `dcdd8a307f53e7f298940a49b555b6a8037ad2aaad145ce45e08ba0923a29b04` | external — not in Git |
| `build/lvs_chip/eco_drop_2x2/stage6/filled.def` | `2ae87c2db7a0f6a1bb0095ee9f9a8a2786a556d07eb49208640ba772ef1fac04` | external — not in Git |
| `build/lvs_chip/eco_drop_2x2/stage6/eco_sites_v3.csv` | `8efedede2176095d20b634a04c16f1ffd1d7f8cdc8edcd0025b1e60b6ee01c82` | tracked |
| `build/production/run/gds_checks.rb` | `fbfac9851f7b6209ae086b27ebd9bc9f9928cd2ce87e2d69d93253e8d616bac5` | tracked |
| `build/production/run/def_gds_checks.rb` | `55945b780991609e392721164efabac477c23918324f171f7b44e49dae54eb93` | tracked |
| `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc` | `e7c7d2597890cfcb4cf0e5312f5652051a119fb3e1cc1772a6e5c04594bc65d8` | external — ignored PDK |
| `c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs` | `00019ed0a7f434fc9ead466be75c07cbaed4bf5de698446d6e3fafd43ac7cc59` | external — ignored PDK |
| `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/metal.rb` | `d8ba81b38adc8258c867c87a11a653640ad62b78ea61e7de3729b57bea2aee1e` | external — ignored PDK |
| `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/via.rb` | `d48ead7abee03dec2bf9eb0abbf343c407dc4f1fc2e71b30878d38639ecaf5bf` | external — ignored PDK |

Design-artifact sizes: final GDS 154,570,546 B; base GDS 154,541,386 B; CDL
17,754,516 B; `eco_routed.def` 172,217,358 B; `filled.def` 172,187,377 B; site
list 8,193 B; SPEF 188,709,802 B.

## 3. Geometry evidence

`build/production/manifests/gds_checks.txt` (SHA-256
`8a725206a60088ab85199b9f38f55f57c65155c892fcee446ddd1c9d880fdda0`):

```text
DEF_DIE_UM=3932.000x5122.000
GDS_CONTENT_BBOX_UM=3931.530x5121.790
GDS_CONTENT_ORIGIN_UM=0.090,0.090
VIA2_NEW_CUTS=672
DROPS=168
EXPECTED_DROPS=168
EXPECTED_DIE_UM=3932.000x5122.000
FAILURES=
```

`build/production/manifests/def_gds_checks.txt` (SHA-256
`d42b537a397acb238bf1b8ad99c7dfa53863d6365a5d124cdbc20152a14f9f5f`):

```text
ECO_Via1_2X2_0_60_10_60_H_V=168
ECO_Via2_2X2_0_60_10_60_V_H=168
EXPECTED_DROPS=168
WINDOWS=168
WINDOWS_WITH_DELTA=168
WINDOW_FAILURES=0
FAILURES=
```

All 168 `WINDOW` lines are `PASS`; all `OUTSIDE_WINDOWS_*_DBU2` values are
zero; the full-chip Metal1–Metal5 XOR is zero.

## 4. SPEF extraction and readback

Output: `build/production/final/grx930_test_chip.spef` (external; not tracked),
188,709,802 bytes, SHA-256
`f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0`.

Extraction record:

- Tool: OpenROAD `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0` from
  `ghcr.io/wafer-space/gf180mcu-precheck:104d9ccbc0d3`.
- Model: GF180MCU `nom` RCX rules,
  `/workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom`,
  SHA-256 `d83a04ea28af9b74a097fb479bbab9ed52859a1e3428b33d3151cb5afae62ddf`
  (container-only path; not in this repository).
- Database: `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb` (external; not
  tracked), 206,880,759 bytes; SHA-256
  `5290f82150c00d321e9650cdbfc903fe331f29167dfbc52a2e060ec16ff52772`; `sub`
  special net, 1 swire, 504 sboxes = 168 straps + 168 Via1 + 168 Via2.
- Command:

```tcl
read_db /work/build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb
extract_parasitics -ext_model_file /workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom
write_spef /work/build/production/final/grx930_test_chip.spef
```

- Extraction ended `RCX_DONE`, exit 0; 126,236 nets finished. SPEF header:
  `*DESIGN "grx930_test_chip"`, `*VERSION "dcf36133..."`; 125,214 `*D_NET`s.
- Coverage: the DEF has 126,236 signal nets; 1,022 have fewer than two
  terminals and no wire, so 126,236 − 1,022 = 125,214 annotated nets.

Readback: `build/production/sta/spef_readback.log` (SHA-256
`160c0b89eb55205f29ed0b6bdbf58f17b60257b39195d9e67437ce47c22f3b69`):

```text
READ_SPEF=OK
Found 0 unannotated drivers.
Found 0 partially unannotated drivers.
readback_rc=0
```

Extraction log: `build/production/sta/spef_extract.log` (SHA-256
`4f12d4825daaf0833c98c56a366f2feb7ce1e73df39d7dddf5b63f21c9f4604c`).

## 5. Independent verification commands

Run from `/c/Users/kubew/grx930`. These commands require the external inputs to
be present; the first two cannot pass from a clean checkout, and the manifest
uses absolute paths for this checkout location. In this worktree they pass with
13 `OK` lines.

```bash
sha256sum build/production/manifests/input_sha256.txt
# expect 15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800

sha256sum -c build/production/manifests/input_sha256.txt
# expect 13 "OK" lines and exit 0

grep -E '^(status|missing|failures|manifest_sha256)=' \
  build/production/manifests/G0_status.txt
# expect READY_FOR_REVIEW, none, none, 15f623f5...

sha256sum build/production/final/grx930_test_chip.spef
# expect f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0
```

Reviewer evidence hashes:

| File | SHA-256 |
|---|---|
| `input_sha256.txt` | `15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800` |
| `G0_status.txt` | `99d4be37683047fe11abb1284a4cb96f71277e1c3004bf51cb31aace78879a85` |
| `g0_run.log` | `4ababf5a9551e50319c4af3dca5f62addfda30cc2dadf176c7348b893691a4b8` |
| `gds_checks.txt` | `8a725206a60088ab85199b9f38f55f57c65155c892fcee446ddd1c9d880fdda0` |
| `def_gds_checks.txt` | `d42b537a397acb238bf1b8ad99c7dfa53863d6365a5d124cdbc20152a14f9f5f` |
| `spef_extract.log` | `4f12d4825daaf0833c98c56a366f2feb7ce1e73df39d7dddf5b63f21c9f4604c` |
| `spef_readback.log` | `160c0b89eb55205f29ed0b6bdbf58f17b60257b39195d9e67437ce47c22f3b69` |
| `grx930_test_chip.spef` | `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0` |

## 6. Exact fields the signatory must fill

Create only `build/production/manifests/G0_signoff.txt` by copying
`G0_signoff.template.txt`. Do not edit the template. The file must contain:

```text
gate=G0
status=SIGNED
signed_by=<Gridworkz-authorized signer name>
signed_utc=<YYYY-MM-DDTHH:MM:SSZ>
manifest_sha256=15f623f5127715d47b8436bf43fa39b1c8f31a393773835c3f0ab0814d560800
```

Field rules enforced by `build/production/run/g2_lvs.sh`:

- `gate` must be exactly `G0`.
- `status` must be exactly `SIGNED`. Set it only after both reviews pass.
- `signed_by` must be non-empty and contain `Gridworkz`; the gate checks for
  that substring. Put the authorized person's full name and role.
- `signed_utc` must be non-empty; use ISO 8601 UTC.
- `manifest_sha256` must be exactly the 64-character hash above.
- Comments and extra lines are not read; keep the five fields exact.
- The agent must not create or prefill `G0_signoff.txt` on Gridworkz's behalf.

## 7. Review record (not part of the gate file)

The design lead and independent reviewer complete this record; the Gridworkz
signatory uses it before filling `G0_signoff.txt`.

| Role | Review scope | Name | Date (UTC) | Result |
|---|---|---|---|---|
| Design lead | Frozen GDS/CDL/DEF/SPEF identity, 168-drop geometry, G0 status |  |  |  |
| Independent reviewer | Recompute manifest and all 13 input hashes; confirm SPEF readback |  |  |  |
| Gridworkz signatory | Confirm both reviews; fill the five fields above |  |  |  |

**Design-lead CDL exception — DRAFT; UNSIGNED**

Proposed design-lead acceptance (not signed):

The design lead would accept the route209 post-hoc generation log as **content
evidence only** for G0 CDL identity. The retained route209 ODB
(`8d2c4b23edf29b102969ce58ef4d5dcdbf3c3edf1e48c2bb39c01ba9a8203d13`; external,
not tracked) and exported Verilog
(`3645b3bc3acfe75c759a73d9769689ef10808fb25ed5f911c7d40c529fe196e5`; tracked)
regenerate all 209,075 X-instance lines with `mk_chip_cdl.py`
(`41cb50f99f18faa7514835c849688a69b2cd805aedeebc6bfaf88bda5871c68f`); the
sorted X-instance set matches the G0 CDL
(`6c042d79ce83d70403d66909119e59419cac095d4e7815d54aeb69fa562fd918`) with
zero CDL-only or regeneration-only lines. Byte identity is not claimed because
the header (`CDLs` vs `CDL`), port order, and instance order differ.

This exception is limited to CDL content identity. It does not establish or pin
the original routed netlist, the original `mk_chip_cdl.py` revision, the
original `cdl.log`/`pipeline_tap.log`, or an original byte-identical file, and
it does not waive G2/LVS, geometry, SPEF, or any other gate requirement.

Design lead: ____________________  Date (UTC): ____________________

Result: DRAFT — NOT SIGNED (proposed `ACCEPTED_WITH_RECORDED_EXCEPTION`)

A blank row is unsigned. This draft is not a signature. G0 remains
`READY_FOR_REVIEW` until the signatory creates `G0_signoff.txt`; this package
alone does not change the gate.

## 8. Addendum — 2026-11-21: Stage 8 closure linkage

This addendum links the G0 review package to the Stage 8 closure completed after
the package was prepared. It does not change any frozen G0 input or sign G0.

- Stage 8 closure: `build/production/baseline/stage8/STAGE8_CLOSURE.md`
- Closure status: `CLOSED_WITH_RECORDED_EXCEPTION`
- Closure SHA-256: `92afb51c8bd24145087d81a6961e4db80cb8e7a1cc9dcbd2fe6bf1a020453839`
- ODB used for extraction: `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb`
  (external; not tracked)
- ODB size: 206,880,759 bytes
- ODB SHA-256: `5290f82150c00d321e9650cdbfc903fe331f29167dfbc52a2e060ec16ff52772`

The ODB is Stage 8 extraction evidence (external; not tracked), not part of the
signed 13-entry G0 input manifest.

The Stage 8 closure accepts the 1,022-net coverage exception: 126,236 DEF signal
nets, of which 1,022 have fewer than two terminals and no wire; the SPEF has
125,214 `*D_NET` records, and `125,214 + 1,022 = 126,236`. No clock net is in the
exception class. This is a Stage 8 RCX coverage disposition only, not an LVS/DRC
waiver, and it does not alter G0, G2, or any signoff requirement.

G0 remains `READY_FOR_REVIEW`; `G0_signoff.txt` is absent and no LVS has been
started.

## 9. CDL provenance — 2026-11-21

The G0 package previously recorded only the CDL hash. This section links the
derivation recipe, records the retained cell-instance identity check, and records
a post-hoc generation from the retained tap-routed route209 ODB. This is
**content evidence only**: the post-hoc log reproduces all 209,075 X-instance
lines, but it is not the original pipeline log, does not pin the original
tool/netlist/log, and does not claim byte-for-byte identity.

Clean-checkout boundary: the generation log, export recipe/log, exported
netlist, raw and normalized CDL, identity log, and current generator are
tracked. The route209 ODB/DEF, G0 CDL, library CDL, and container image are
external and cannot be verified from a clean checkout.

**Linked derivation recipe**

- `c930/asic_gf180mcu/build/rebuild_after_probe.sh` (SHA-256
  `10e2236316d88d48ace19a30c24cb71f185a9a4e759e267f9c557d43b86d986f`) runs the
  tap placement/route rebuild and then `rebased_pipeline.sh --lvs`.
- `c930/asic_gf180mcu/build/rebased_pipeline.sh` (SHA-256
  `b4575ee93b93b97f941b2e8f8bf1f02a9f0a0c72a73aaa55b4a2c7c4f789ef97`), step
  “CDL (routed netlist)” lines 108–117, invokes
  `mk_chip_cdl.py --routed /work/build/grx930_test_chip_routed.v` and copies
  the result to `build/lvs_chip/rebased_grx930_test_chip.cdl`.
- The current G0 CDL is
  `build/lvs_chip/rebased_tap_grx930_test_chip.cdl` (external; ignored, not in
  Git), SHA-256
  `1a29a6ad2cb99882a8e2d8974cadff3237f317cc349c1a0c3e7f20545f75b717`,
  matching `input_sha256.txt`.

**Retained cell-instance identity check**

`build/production/sta/cdl_netlist_identity.log` (tracked; SHA-256
`d889db8779cffc8b1fb2561800b16bafdf343e412cca29fa825a96712986177d`)
compares the G0 CDL against the frozen G0 DEF. Both inputs are external and not
tracked; the log is tracked, but the check cannot be rerun from a clean checkout
without restoring them. It compares CDL `X` instance names and cell types with
DEF `COMPONENTS` entries whose cell type appears in the CDL; DEF-only filler cell
types absent from the CDL are excluded.

```text
def_components_total=361906
cdl_x_instances=209075
def_instances_with_cdl_types=209076
matched=209075
def_only=1
cdl_only=0
cdl_types_absent_from_def=0
def_only_instances:
  FILL_ROW_861_TIE77 gf180mcu_fd_sc_mcu7t5v0__filltie
result=IDENTITY_WITH_ONE_DEF_ONLY_FILLTIE
```

All 209,075 CDL instances match a DEF instance by name and cell type; the CDL
has no unmatched instance. The single DEF-only instance is a physical filltie.
This is consistent with a post-CDL fill insertion, but the tree does not contain
the original generation log that proves that sequence. The check does not compare
connectivity, so it is not a full netlist-identity check.

**Post-hoc generation from the retained tap-routed route209 ODB (content evidence only)**

This is post-hoc content evidence only. It does not identify or pin the
original generation run, original routed netlist, original `mk_chip_cdl.py`
revision, or original `cdl.log`; those remain open.

No original routed Verilog netlist or retained `cdl.log`/`pipeline_tap.log`
exists in the worktree or any Git ref/history. The retained
`eco_routed_route209.odb` / `.def` is a tap-bearing routed database with
209,075 components and 83,865 fillties; it is the external (not tracked) source
used here.

- Generation log: `build/production/sta/cdl_route209_generation.log` (tracked),
  SHA-256
  `c8cc01c5a02aefefe4873d4b3f1bcd586d0891ecabdcd69e88c6938da6c5adb9`.
- Exported Verilog: `build/production/sta/eco_routed_route209_export.v`
  (tracked), SHA-256
  `3645b3bc3acfe75c759a73d9769689ef10808fb25ed5f911c7d40c529fe196e5`.
- Raw CRLF output: `build/production/sta/eco_routed_route209_repro.cdl`,
  17,964,084 bytes, SHA-256
  `dbe8dd714dfe14cfd54a98342ca5d8601dd53b133741fd1765b27fe88b4d7a3e`.
- Post-hoc generator: current `mk_chip_cdl.py` (tracked), SHA-256
  `41cb50f99f18faa7514835c849688a69b2cd805aedeebc6bfaf88bda5871c68f`;
  this is the reconstruction tool, not the recorded original revision. Library
  CDL (external; ignored, not in Git) SHA-256
  `8c7f781f8bd314070f390559ec09ffdab07d7cb25533a9790df62a43f99ff175`.
- Content result (post-hoc only): 209,075 X-instances; the sorted X-instance set is identical to the
  G0 CDL (`6c042d79ce83d70403d66909119e59419cac095d4e7815d54aeb69fa562fd918`),
  with zero CDL-only or regeneration-only lines. The regenerated output is
  `build/production/sta/eco_routed_route209_repro_lf.cdl` (SHA-256
  `939ac844c67998bd46dcf17daa1ec5dc3ab5252aa62d3f55a90d608aae0e74ad`).
- Byte identity is **not** claimed: the header says `CDLs` rather than `CDL`,
  and the top-level port and instance orders differ. No X-instance content
  differs.

`post_hoc_content_evidence=REPRODUCED_FROM_ROUTE209_ODB`
`original_run_pinned=NO`

**Residual historical gap**

- No retained original `cdl.log` or `pipeline_tap.log` exists in this checkout;
  the pipeline logs to the remote `$WORK/cdl.log`. The post-hoc generation log
  above is not the missing original run.
- The linked recipe names `rebased_grx930_test_chip.cdl`; no recorded copy or
  rename to the G0 path `rebased_tap_grx930_test_chip.cdl` was found.
- The current worktree `mk_chip_cdl.py` (tracked) has SHA-256
  `41cb50f99f18faa7514835c849688a69b2cd805aedeebc6bfaf88bda5871c68f`, while
  the Stage 1 baseline pins
  `685ab89d0dbf9442bc6eee3986ab8b999d7fbc0ef58dafe3cb5d81747ea3c806`. The
  tool is modified, and no original tool revision is recorded. The G0 header's
  singular `CDL` wording is not produced by the current `41cb…` tool (which
  writes `CDLs`), so the original likely used the pre-`--lib` baseline; this is
  evidence, not proof.
- The exact original generation run is still not recovered: no original
  `cdl.log`, no `pipeline_tap.log`, and no original routed `.v`. The post-hoc
  regeneration establishes **content evidence only** from the retained route209
  ODB; it does not establish original-run provenance or byte-identical
  historical output. G2, which is blocked, is the first planned
  device/top-level-pin comparison.

**Design-lead attestation (not signed; fallback)**

Design lead of record: `Gridworkz` (name supplied 2026-11-21). This records the
name only; it is not a signature. The post-hoc generation log above is the
selected content evidence only; this attestation remains an unsigned fallback.

The fallback attestation would state:

> I attest that `build/lvs_chip/rebased_tap_grx930_test_chip.cdl` is the CDL
> generated from the routed netlist for the G0-frozen DEF; that the one DEF-only
> filltie `FILL_ROW_861_TIE77` is accounted for as (post-CDL fill insertion /
> intentionally excluded / other): ____________________; that the exact
> `mk_chip_cdl.py` revision used was ____________________; that the
> `rebased_tap` filename corresponds to the pipeline output; and that no other
> unrecorded cell or netlist edits occurred after generation.

Name: ____________________  Date (UTC): ____________________

Generator revision/SHA-256: ____________________

Routed netlist path and SHA-256: ____________________

Result: ____________________

These fields are intentionally blank: no original tool revision, routed netlist,
or original generation log has been established.

The post-hoc generation log above is content evidence only and does not fill the
blank original-run fields. G0 remains `READY_FOR_REVIEW`; this attestation is not
signed and no LVS has been started.
