# Gridworkz signoff packet — 2×2 VSS/VDD drops

- **Packet status: PENDING. NOT SIGNED. The no-duplicate original-row retry has 0 added findings; the row-300 M2 dogleg overlap is not net-qualified and the historical 541/541 source GDS is absent.**
- **Submission status: NOT SUBMITTED — no Gridworkz connector/API is available in this session.**
- **Prepared:** 2026-11-17
- **Scope:** 8,169-drop candidate: 7,626 connected `sub` islands + 541 `sub` row drops + 2 `$45264` rail-end drops.
- **ECO plan:** `build/lvs_chip/ECO_DROP_PLAN.md`

## Decision requested

Approve only after the selected fix70/full-541-row cropped real-layout DRC has **zero added findings** and the ECO plan’s 0.84 µm M2 / 2×2 array geometry is used. The current corrected 14-site surrogate has zero added findings but is not sufficient for approval. This packet does not grant a waiver.

## Results

| Gate | Result |
|---|---|
| `sub` rows legal | **541 / 541** |
| `sub` missing rows | **0** |
| `$45264` endpoints | **2 / 2** legal |
| Endpoint coordinates | `1487.97, 2979.20` and `1651.97, 2979.20` µm |
| Endpoint separation | **164.0 µm** |
| Drop count | **8,169** (7,626 + 541 + 2) |
| Synthetic 14-site PDK DRC | **0 violations** |
| Row-original retry — 14 sites, no cloned rows | **0 added / 0 removed**; 253 before / 253 after. `sub_row_300` uses a routed M2 dogleg. |
| Row-300 M2 route | 0.84 µm dogleg x3076.08 → x3077.20 → x3076.08; DRC 0 added. Overlaps 0.146 µm² existing M2; net ownership unqualified. |
| Cropped real-layout DRC — earlier duplicate-row surrogate | 0 added / 0 removed; 49 baseline. **Superseded because it cloned rows.** |
| M1/M3 landing connectivity — row-original retry | M1 pad 79.9% over actual M1; M1 extension 76.9% over actual M1; M3 pad 100% over actual M3. |
| Original first pass (superseded) | 22 added findings: M1.2a ×16, M2.2a ×6 |

The first cropped pass added synthetic M1 landing pads that produced M1.2a edges and six M2 spacing conflicts. The earlier surrogate then reached 0 added findings by cloning clean rows, which is not legal 541-row evidence. The replacement no-duplicate crop keeps one drop on each original row. `sub_row_300` is routed with an explicit M2 dogleg around the staggered M2 shapes: it holds x=3076.08 to y=2796.30, jogs to x=3077.20, returns at y=2799.80, and continues at x=3076.08. The metal/via DRC is **253 before / 253 after, 0 added**. A local geometry check finds 0.146 µm² of overlap with existing M2; because the L2N mapping is absent, that overlap is not proven same-net. The selected fix70 GDS is also absent, and the historical 541 validator cannot run because its source GDS is absent. Do not treat any current result as a full-layout signoff.

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

- `row_before.gds` — `3cbeb5fd04f940abe9d323b2d7ba3e385e1b095a1d1349ea76d9f966ef860222`
- `row_after.gds` — `1bf77c7f537803f38c0cdd9736ed1f04e28c19d5d605c5f736e77ec8834e08bc`
- `row_before.lyrdb` — `6893215faa8ca44d6463c33877906cd33d654372cf61fa90af7f61e3aed5df4d`
- `row_after.lyrdb` — `afdbc4686049d81efd3ce9aba8d47950a02877597d8e7254a15451f89b58ee1b`
- `row_compare.json` — `19a07a227119d3ee03461ad6a9675d6f4b83b81bb1cb159236671aa893dfaa59`
- `row300_route_check.log` — `9b82303a3dc4861becd740fb9bfc03170149cfa384a73490bd7fe0c2f4e3e4ec`
- Result: **253 before, 253 after, 0 added / 0 removed**; all 14 original-row sites pass.

### 541/541 evidence

- `validate_drop_windows_2x2.rb` requires `c930/asic_gf180mcu/build/lvs_chip/fill_regression_tie_final.gds`; that file is absent (and the selected fix70 file is absent). The historical 541/541 result cannot be regenerated or updated in this checkout. The current no-duplicate crop is representative only.

## Signoff block

- **Technical owner:** ____________________  Date: __________
- **DRC owner:** ____________________  Date: __________
- **Gridworkz signatory:** ____________________  Date: __________
- **Decision:** APPROVED / REJECTED / PENDING
- **Waiver granted:** NO
- **Gridworkz submission:** NOT SUBMITTED — connector unavailable

Until the row-300 M2 overlap is net-qualified and the selected fix70/full-541-row cropped run can be run, the packet remains pending. The no-duplicate 14-site crop has 0 added findings; the earlier surrogate is not valid 541-row evidence.
