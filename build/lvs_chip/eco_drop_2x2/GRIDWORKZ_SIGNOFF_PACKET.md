# Gridworkz signoff packet — 2×2 VSS/VDD drops

- **Packet status: PENDING. NOT SIGNED. Candidate is 8,168 drops (540 row drops + 2 rail drops); row 300 is excluded. The 13-site cropped DRC is 226/226 with 0 added findings. Production signoff is not established; see Production readiness below.**
- **Submission status: NOT SUBMITTED — no Gridworkz connector/API is available in this session.**
- **Prepared:** 2026-11-17
- **Scope:** 8,168-drop candidate: 7,626 connected `sub` islands + 540 `sub` row drops + 2 `$45264` rail-end drops. `sub_row_300` is excluded.
- **ECO plan:** `build/lvs_chip/ECO_DROP_PLAN.md`
- **Production signoff plan:** `build/lvs_chip/PRODUCTION_SIGNOFF_PLAN.md` — all gates NOT RUN/BLOCKED

## Decision requested

Approve only after the selected fix70 cropped real-layout DRC has **zero added findings** for the 540-row candidate and the ECO plan’s 0.84 µm M2 / 2×2 array geometry is used. The current 13-site candidate crop has zero added findings, but row 300 is excluded and the historical 541-row source is absent. This packet does not grant a waiver.

## Production readiness — NOT ESTABLISHED

This packet is an ECO geometry/signoff artifact, not a production release. The following production items have no verdict and must not be inferred from the focused crop:

| # | Required production evidence | Current state | Status |
|---|---|---|---|
| 1 | Full-chip LVS verdict | Full run stopped after more than 100 minutes; no full-chip verdict. A reduced crop cannot substitute. | **NOT DONE** |
| 2 | Full-chip DRC across all layers and rules | Only focused M1/M2/M3/V1/V2 checks were run. Antenna, density, ERC, well/isolation, latch-up, ESD, sealring, padring, and DFM are not covered. | **NOT DONE** |
| 3 | Full-chip timing and power signoff | No multi-corner STA, clock/reset integrity, IR drop, electromigration, crosstalk, or thermal signoff. | **NOT DONE** |
| 4 | Production test evidence | No DFT/ATPG coverage, scan, boundary scan, memory BIST, fault simulation, or bring-up plan evidence. | **NOT DONE** |
| 5 | Foundry tape-out review | No final GDS/CDL approval, approved PDK/rule-deck versions, waiver disposition, mask preparation, package/pinout review, or silicon qualification. | **NOT DONE** |

**Overall production release: NOT APPROVED.** The 13-site crop has 0 added findings only for the focused decks listed below.

## Results

| Gate | Result |
|---|---|
| `sub` rows legal | **540 / 541 candidate** |
| `sub` missing rows | **1 — `sub_row_300` excluded** |
| `$45264` endpoints | **2 / 2** legal |
| Endpoint coordinates | `1487.97, 2979.20` and `1651.97, 2979.20` µm |
| Endpoint separation | **164.0 µm** |
| Drop count | **8,168** (7,626 + 540 + 2) |
| Synthetic 14-site PDK DRC | **0 violations** |
| Row-original candidate — 13 sites, no cloned rows | **0 added / 0 removed**; **226 before / 226 after**. Row 300 absent. |
| Row-300 candidate geometry | **Excluded — no M2 dogleg in candidate or packet.** |
| Cropped real-layout DRC — earlier duplicate-row surrogate | 0 added / 0 removed; 49 baseline. **Superseded because it cloned rows.** |
| M1/M3 landing connectivity — row-original retry | M1 pad 79.9% over actual M1; M1 extension 76.9% over actual M1; M3 pad 100% over actual M3. |
| Original first pass (superseded) | 22 added findings: M1.2a ×16, M2.2a ×6 |

The first cropped pass added synthetic M1 landing pads that produced M1.2a edges and six M2 spacing conflicts. The earlier surrogate then reached 0 added findings by cloning clean rows, which is not legal 541-row evidence. The replacement candidate keeps one drop on each included original row and excludes `sub_row_300`. The 13-site crop is **226 before / 226 after, 0 added / 0 removed**. Row 300's prior DRC-clean route was removed because its overlap was VDD, not VSS; the rejected geometry and its label/clear-lane evidence are retained under `rejected_row300/` and are not part of this candidate. The selected fix70 GDS is absent, and the historical 541 validator cannot run because its source GDS is absent. Do not treat any current result as a full-layout signoff.

## Geometry

- Via1: `Via1_2X2_0_60_10_60_H_V`
- Via2: `Via2_2X2_0_60_10_60_V_H`
- Cuts: 0.26 µm; cut spacing 0.26 µm
- M2 strap: **0.84 µm**
- M2 landing extension: 0.45 µm
- M2 keepout: **1.40 µm**
- M1 landing requirement: 0.90 × 0.78 µm
- M3 landing requirement: 0.90 × 0.80 µm
- M1/M3 landing rectangles are placed inside existing rails/strips and checked for overlap; the M1 pad is 76.9–81.3% inside real M1 (70.5% rail_left, 31.4% rail_right), M3 is 100% inside the target strip, and foreign M2 overlap is zero.

## Evidence hashes

### Synthetic 14-site DRC

- GDS SHA-256: `2a41473ce0890c3be6aeeee4a92942cdff8376308040434cd9564cd15f6fe5d1`
- Report SHA-256: `f71182e8faf311e69c24068cdfa1feaa119721695251fa0515c14f5accb7327f`
- Log SHA-256: `96369d7d3991d3c5c6e48be46a0aa0440213fe7c95f960cba8954f974569f935`
- Result: **SUCCESS, 0 violations**

### PDK deck identity

- `gf180mcu.drc`: `e7c7d2597890cfcb4cf0e5312f5652051a119fb3e1cc1772a6e5c04594bc65d8`
- `metal.rb`: `d8ba81b38adc8258c867c87a11a653640ad62b78ea61e7de3729b57bea2aee1e`
- `via.rb`: `d48ead7abee03dec2bf9eb0abbf343c407dc4f1fc2e71b30878d38639ecaf5bf`

### Cropped real-layout DRC

- Source used: `build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds`
- Source SHA-256: `b253e5150650a7ab70adfcf2aeecb5c135f4740748ca5b075cd097f361480b82`
- Selected-route fix70 GDS is absent from this checkout; its recorded SHA is `c5fa46ed3d17e36b75026964655e6376d15a00ca03f57f67277290fc98c20738`. The cropped run is therefore not a fix70 signoff and must be repeated on the selected file.
- First-pass report and comparison:
  - `build/lvs_chip/eco_drop_2x2/crop_before.lyrdb`
  - `build/lvs_chip/eco_drop_2x2/crop_after_with_pads.lyrdb`
  - `build/lvs_chip/eco_drop_2x2/crop_compare.json`
  - Added: M1.2a ×16, M2.2a ×6; removed: 0.
  - Hashes: before report `40e6f975a5a9341c63c935f8727e4f70e83e1a0429abc412363fd5a420294e31`; padded after report `e355cffc6ad0461ee4e3b7a6b30c9ad016c2d697eb1737201830e843732273c3`; comparison `9355bf4635c87e4e9b45535bf5464024c2e05a522103d9fca08d3789d6f5a8ae`.
  - No-pad probe: after report `30d86ab5da4a77ede6a0c8dd320f31da3af30051c0ac5dcdeebf7c684995cbeb`; comparison `2f06c650dbed5ff1dd05e82909109667a2db8ca5612455b8940965db53b6d003`.

### Corrected cropped DRC (supersedes the first cropped pass)

- Before GDS: `build/lvs_chip/eco_drop_2x2/corrected/corrected_before.gds` — `faef835195fff4d79eee773390c23a61738a83f3494164c8a515a81c8d0c7080`
- After GDS: `build/lvs_chip/eco_drop_2x2/corrected/corrected_after.gds` — `12054120d68827fb2d5992b02ad454242dbd438eabd1910c932b31f52bfa730d`
- Before report: `corrected_before.lyrdb` — `c38271e4416e6cae72143cd7e5c8219ba2b4714e709e8f9305e3cadb2c8c631e`
- After report: `corrected_after.lyrdb` — `6af9e1cd7cf14aa1f041d3660216bacbd6e3525f99adaff07b57fd5b54347863`
- Comparison: `corrected_compare.json` — `7dadc72edb9c9fcb5b983b0f6ab3247f440f8bbff3b9c8011e819208b3606538`
- Landing check: `corrected/landing_check.log` — `2479500792c22bfd00f410675467e22241523adcc408f83a6ab5e5d0b9c2a508`
- Earlier duplicate-row surrogate: **49 before, 49 after, 0 added, 0 removed**; `LANDING_CHECK PASS`. **Superseded by the no-duplicate retry.**

### No-duplicate original-row retry

- `row_before.gds` — `59d04611d6479c409d33576d8dd8a0a9135d0c203307738e5988ba80a91cd7f1`
- `row_after.gds` — `df39f58dde496116527f5f5a15e59b04ede1e3be15b1dd79bb0b0abb27d7f890`
- `row_before.lyrdb` — `e7ec14ead0b40395f4a4d6a3017fa86d2bfd60bd8b01c6353dfcf3b99c8f9696`
- `row_after.lyrdb` — `6022060b581463ed4d48739e204f5dd2a087fcd03c2d382461b0a9bf54906061`
- `row_compare.json` — `76c2636c7e14a99c28dbefc927b6bdc91c2f3fe3559bd927de53f1f2a7c13c04`
- Result: **226 before, 226 after, 0 added / 0 removed**; **13 sites**, no `sub_row_300`.

### Rejected row-300 evidence

- The prior dogleg and its VSS/VDD/clear-lane qualification are retained under `build/lvs_chip/eco_drop_2x2/rejected_row300/`.
- **Not part of the candidate or packet geometry.** No row-300 drop is claimed.

### 540/541 evidence

- `validate_drop_windows_2x2.rb` requires `c930/asic_gf180mcu/build/lvs_chip/fill_regression_tie_final.gds`; that file is absent (and the selected fix70 file is absent). The historical 541/541 result cannot be regenerated or updated in this checkout. The current crop is a 13-site representative check of the 540-row candidate.

## Signoff block

- **Technical owner:** ____________________  Date: __________
- **DRC owner:** ____________________  Date: __________
- **Gridworkz signatory:** ____________________  Date: __________
- **Decision:** APPROVED / REJECTED / PENDING
- **Waiver granted:** NO
- **Production release:** NOT APPROVED — full-chip LVS, full DRC, timing/power, test, and foundry review are outstanding
- **Gridworkz submission:** NOT SUBMITTED — connector unavailable

Row 300 is removed from the candidate and packet; the packet remains pending because only 540 of 541 row drops are represented and the selected fix70/full-541-row cropped run cannot be run. The 13-site crop has 0 added findings; the earlier surrogate is not valid 541-row evidence.
