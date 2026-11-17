# Gridworkz signoff packet — 2×2 VSS/VDD drops

- **Packet status: PENDING. NOT SIGNED.**
- **Submission status: NOT SUBMITTED — no Gridworkz connector/API is available in this session.**
- **Prepared:** 2026-11-17
- **Scope:** 8,169-drop candidate: 7,626 connected `sub` islands + 541 `sub` row drops + 2 `$45264` rail-end drops.
- **ECO plan:** `build/lvs_chip/ECO_DROP_PLAN.md`

## Decision requested

Approve only if the final cropped real-layout DRC has **zero added findings** and the ECO plan’s 0.84 µm M2 / 2×2 array geometry is used. This packet does not grant a waiver.

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
| Cropped real-layout DRC | **22 added findings** in first pass: M1.2a ×16, M2.2a ×6; **not clean** |
| Cropped correction probe | No M1/M3 pads: M2.2a ×6, V1.3a ×56; **not clean** — landing metal must be net-merged |

The first cropped pass added synthetic M1 landing pads that produced M1.2a edges, and found six M2 spacing conflicts at three actual sites. Removing the pads cleared M1.2a but exposed V1.3a (56), so the final correction must merge/clip the M1/M3 landing into the real net and re-site the M2 conflicts. The corrected candidate must be re-run before approval. Do not treat the 0-violation synthetic result as a full-layout signoff.

## Geometry

- Via1: `Via1_2X2_0_60_10_60_H_V`
- Via2: `Via2_2X2_0_60_10_60_V_H`
- Cuts: 0.26 µm; cut spacing 0.26 µm
- M2 strap: **0.84 µm**
- M2 landing extension: 0.45 µm
- M2 keepout: **1.40 µm**
- M1 landing requirement: 0.90 × 0.78 µm
- M3 landing requirement: 0.90 × 0.80 µm
- Existing M1/M3 rails/strips are the landing metal; no synthetic pads protruding into neighboring shapes.

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

## Signoff block

- **Technical owner:** ____________________  Date: __________
- **DRC owner:** ____________________  Date: __________
- **Gridworkz signatory:** ____________________  Date: __________
- **Decision:** APPROVED / REJECTED / PENDING
- **Waiver granted:** NO
- **Gridworkz submission:** NOT SUBMITTED — connector unavailable

Until this block is completed and the corrected cropped run is clean, the packet remains pending.
