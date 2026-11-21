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
the GDS or any single input. `sha256sum -c input_sha256.txt` passes all 13
entries.

## 2. Frozen inputs

All 13 entries below are present and match the manifest. Paths are relative to
the repository root; `input_sha256.txt` records the absolute paths.

| Input | SHA-256 |
|---|---|
| `build/production/final/grx930_test_chip_final.gds` | `8fdeb5812ae7325a0b336e26b60cb873e1c75d370640aa63ecd69b0acf766b62` |
| `c930/asic_gf180mcu/build/lvs_chip/rebased_tap_grx930_test_chip.cdl` | `1a29a6ad2cb99882a8e2d8974cadff3237f317cc349c1a0c3e7f20545f75b717` |
| `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.def` | `d8c7211bf6d20db3297395d5a5c6ff5f31e9df70e3cb9ef55b6ef6b525579a01` |
| `build/production/final/grx930_test_chip.spef` | `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0` |
| `build/production/final/pre_eco_stream.gds` | `dcdd8a307f53e7f298940a49b555b6a8037ad2aaad145ce45e08ba0923a29b04` |
| `build/lvs_chip/eco_drop_2x2/stage6/filled.def` | `2ae87c2db7a0f6a1bb0095ee9f9a8a2786a556d07eb49208640ba772ef1fac04` |
| `build/lvs_chip/eco_drop_2x2/stage6/eco_sites_v3.csv` | `8efedede2176095d20b634a04c16f1ffd1d7f8cdc8edcd0025b1e60b6ee01c82` |
| `build/production/run/gds_checks.rb` | `fbfac9851f7b6209ae086b27ebd9bc9f9928cd2ce87e2d69d93253e8d616bac5` |
| `build/production/run/def_gds_checks.rb` | `55945b780991609e392721164efabac477c23918324f171f7b44e49dae54eb93` |
| `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/gf180mcu.drc` | `e7c7d2597890cfcb4cf0e5312f5652051a119fb3e1cc1772a6e5c04594bc65d8` |
| `c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/gf180mcu.lvs` | `00019ed0a7f434fc9ead466be75c07cbaed4bf5de698446d6e3fafd43ac7cc59` |
| `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/metal.rb` | `d8ba81b38adc8258c867c87a11a653640ad62b78ea61e7de3729b57bea2aee1e` |
| `c930/asic_gf180mcu/libs.tech/klayout/tech/drc/rule_decks/via.rb` | `d48ead7abee03dec2bf9eb0abbf343c407dc4f1fc2e71b30878d38639ecaf5bf` |

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

Output: `build/production/final/grx930_test_chip.spef`, 188,709,802 bytes,
SHA-256 `f4d4b6f2ce01b9c52bf0808a295579dd8984cb4b8d82c1c64b78bcb7e91410b0`.

Extraction record:

- Tool: OpenROAD `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0` from
  `ghcr.io/wafer-space/gf180mcu-precheck:104d9ccbc0d3`.
- Model: GF180MCU `nom` RCX rules,
  `/workspace/gf180mcu/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.nom`,
  SHA-256 `d83a04ea28af9b74a097fb479bbab9ed52859a1e3428b33d3151cb5afae62ddf`.
- Database: `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb` (206,880,759
  bytes; `sub` special net, 1 swire, 504 sboxes = 168 straps + 168 Via1 + 168
  Via2).
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

Run from `/c/Users/kubew/grx930`:

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

A blank row is unsigned. G0 remains `READY_FOR_REVIEW` until the signatory
creates `G0_signoff.txt`; this package alone does not change the gate.

## 8. Addendum — 2026-11-21: Stage 8 closure linkage

This addendum links the G0 review package to the Stage 8 closure completed after
the package was prepared. It does not change any frozen G0 input or sign G0.

- Stage 8 closure: `build/production/baseline/stage8/STAGE8_CLOSURE.md`
- Closure status: `CLOSED_WITH_RECORDED_EXCEPTION`
- Closure SHA-256: `92afb51c8bd24145087d81a6961e4db80cb8e7a1cc9dcbd2fe6bf1a020453839`
- ODB used for extraction: `build/lvs_chip/eco_drop_2x2/stage6/eco_routed.odb`
- ODB size: 206,880,759 bytes
- ODB SHA-256: `5290f82150c00d321e9650cdbfc903fe331f29167dfbc52a2e060ec16ff52772`

The ODB is Stage 8 extraction evidence, not part of the signed 13-entry G0 input
manifest.

The Stage 8 closure accepts the 1,022-net coverage exception: 126,236 DEF signal
nets, of which 1,022 have fewer than two terminals and no wire; the SPEF has
125,214 `*D_NET` records, and `125,214 + 1,022 = 126,236`. No clock net is in the
exception class. This is a Stage 8 RCX coverage disposition only, not an LVS/DRC
waiver, and it does not alter G0, G2, or any signoff requirement.

G0 remains `READY_FOR_REVIEW`; `G0_signoff.txt` is absent and no LVS has been
started.
