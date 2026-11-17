# ECO plan — 2×2 VSS/VDD drop arrays

**Status: PENDING net-ownership check and missing 541 evidence source. The no-duplicate original-row crop now has 0 added findings, including a routed row-300 M2 dogleg; this plan is not an approval.**

## Scope

- Connect every VSS row in `sub` to the nearest VSS M3 strip.
- Connect both `$45264` M1 rail ends to the nearest VDD M3 strip.
- Candidate count:
  - 7,626 connected `sub` islands
  - +541 `sub` row drops
  - +2 `$45264` rail-end drops
  - = **8,169 drops**
- No netlist, LVS deck, or DRC deck changes are part of this ECO.

## Mandatory geometry

The final ECO must use the **2×2 via arrays**, not the earlier single-via geometry:

- Via1: `Via1_2X2_0_60_10_60_H_V`
- Via2: `Via2_2X2_0_60_10_60_V_H`
- Via cuts: **0.26 µm** square, **0.26 µm** cut spacing
- **M2 strap: 0.84 µm wide** (not 0.80 µm)
- M2 landing extension: **0.45 µm** past each via center
- M2 keepout corridor: **1.40 µm** = 0.84 µm strap + 2 × 0.28 µm M2 spacing
- M1/M3 landing: reuse the existing `sub`/`VSS` M1 and M3 metal. If a pad is required, clip/merge it into the real net; do not leave pad edges that introduce M1.2a. The first cropped run showed that unclipped pads add M1.2a; a no-pad run then exposed V1.3a, so the required fix is a net-merged landing, not removing the landing entirely.
- Required M1 landing coverage: **0.90 × 0.78 µm**
- Required M3 landing coverage: **0.90 × 0.80 µm**
- Every `sub` row must have at least one legal M2-free window.

## Required acceptance gates

1. **Window gate:** 541/541 `sub` rows legal with the 2×2 arrays and 0.84 µm M2 strap.
2. **Rail gate:** both `$45264` endpoints legal; current endpoints are `1487.97, 2979.20` and `1651.97, 2979.20` µm (164.0 µm apart).
3. **Synthetic DRC gate:** 14 representative drop sites, PDK `metal1,metal2,metal3,via1,via2` decks, **0 violations**.
4. **Cropped real-layout gate (representative):** no **added** M1/M2/M3/via finding at the corrected representative sites after the drops. **MET for DRC**: the no-duplicate retry keeps all 14 sites on original rows and gives **253 before / 253 after, 0 added / 0 removed**, including the routed `sub_row_300`. The row-300 dogleg overlaps existing M2 inside the channel; DRC reports no added violation, but net ownership of that M2 is not available in this checkout.
5. **Full-chip DRC:** unchanged pre-existing baseline; this plan does not claim full-chip DRC clean.
6. **LVS:** not rerun by this ECO validation; prior residual remains 772 (770 with two NWELL taps).

## Evidence and provenance

- Selected route cited by the project: `rebased_tap_stream_out_filled_stitched_fix70.gds`
  - SHA-256: `c5fa46ed3d17e36b75026964655e6376d15a00ca03f57f67277290fc98c20738`
- The selected fix70 GDS file is **not present in this checkout**. The cropped real-layout run therefore uses the latest available full-layout file:
  - `build/lvs_chip/rebased_tap_stream_out_filled_stitched_fix16.gds`
  - SHA-256: `b253e5150650a7ab70adfcf2aeecb5c135f4740748ca5b075cd097f361480b82`
- PDK deck:
  - `gf180mcu.drc`: `e7c7d2597890cfcb4cf0e5312f5652051a119fb3e1cc1772a6e5c04594bc65d8`
  - `metal.rb`: `d8ba81b38adc8258c867c87a11a653640ad62b78ea61e7de3729b57bea2aee1e`
  - `via.rb`: `d48ead7abee03dec2bf9eb0abbf343c407dc4f1fc2e71b30878d38639ecaf5bf`
- Synthetic 14-site DRC:
  - GDS: `2a41473ce0890c3be6aeeee4a92942cdff8376308040434cd9564cd15f6fe5d1`
  - Report: `f71182e8faf311e69c24068cdfa1feaa119721695251fa0515c14f5accb7327f`
  - Log: `96369d7d3991d3c5c6e48be46a0aa0440213fe7c95f960cba8954f974569f935`
  - Result: 0 violations
- Cropped real-layout evidence is under `build/lvs_chip/eco_drop_2x2/`.

## Corrected cropped validation (2026-11-17)

The synthetic M1/M3 pads from the first pass were replaced by 0.90 × 0.78 µm M1
and 0.90 × 0.80 µm M3 landing rectangles placed inside existing M1/M3 net
geometry. The M1 pad sits inside the real VSS row/rail shape (76.9–81.3% area
overlap; rail_left 70.5%, rail_right 31.4%), and the M3 pad is 100% inside the
target strip. The M2 strap has **zero** overlap with existing foreign M2 on all
14 checked sites.

Resites used in the representative crop (original site → clean surrogate):

- `sub_row_250` (2716.45, 2402.96) → `sub_row_500` (1970.53, 4362.96), M3 y=4362.96; removes the M1.2a conflict.
- `sub_row_350` (2724.29, 3186.961) → `sub_row_0` (2727.65, 442.985), M3 y=462.96; removes the M2.2a conflict.
- `sub_row_400` (1970.53, 3578.96) → `sub_row_150` (2716.45, 1618.96), M3 y=1622.96; removes the M2.2a conflict.
- `rail_right` (1651.97, 2979.20) → (1651.60, 2973.50), M3 y=2972.96; shifts along the real rail into a 1.40 µm M2-free corridor.
- Extra safety resites: `sub_row_50` → `sub_row_100` (1970.53, 1226.96), `sub_row_300` → `sub_row_450` (1970.53, 3970.96).

Corrected evidence:

- `build/lvs_chip/eco_drop_2x2/corrected/corrected_before.gds` — `faef835195fff4d79eee773390c23a61738a83f3494164c8a515a81c8d0c7080`
- `build/lvs_chip/eco_drop_2x2/corrected/corrected_after.gds` — `12054120d68827fb2d5992b02ad454242dbd438eabd1910c932b31f52bfa730d`
- `corrected_before.lyrdb` — `c38271e4416e6cae72143cd7e5c8219ba2b4714e709e8f9305e3cadb2c8c631e`
- `corrected_after.lyrdb` — `6af9e1cd7cf14aa1f041d3660216bacbd6e3525f99adaff07b57fd5b54347863`
- `corrected_compare.json` — `7dadc72edb9c9fcb5b983b0f6ab3247f440f8bbff3b9c8011e819208b3606538`
- `landing_check.log` — `2479500792c22bfd00f410675467e22241523adcc408f83a6ab5e5d0b9c2a508`

The run still uses the available fix16 surrogate, not the absent selected fix70
GDS. **Full 541-row/fix70 cropped DRC and LVS remain pending.**

## Original-row retry (no duplicate rows)

The duplicate-row surrogate was rejected. `build_row_crops.rb` now places one drop on each of the original rows and uses explicit M1/M3 landing extensions plus clean-x positions. All 14 sites are original rows/rail points; no row is cloned.

Result on the available fix16 file:

- `row_before.gds` — `57b7eb9d5585a8d4944cdb66981dd6315d9cd0b8fa62be8c3d9c5b9eb0bd8786`
- `row_after.gds` — `f1378f60db36432b288c3f5198073360e441f723dc2458d93f4ce3be36b056a3`
- `row_before.lyrdb` — `1728c42bfd0aa4897bce8cbb6889f4aa9bc853e7b8c7acda251a31599c67366e`
- `row_after.lyrdb` — `09de4857991fe1d2c5faf7808c2d5a6e8fe1e9ee413185f6373c9daa0633fd1a`
- `row_compare.json` — `83c5eaaa43b6b5b5d5e005ec70cb2a56c580aaa1c7e86e0504fd1f6a65966926`
- **253 before, 253 after, 0 added / 0 removed**; all 14 original-row sites pass.
- `sub_row_300` uses an explicit M2 dogleg: vertical at x=3076.08, right jog to x=3077.20 between y=2796.30/2799.80, then back to x=3076.08. The M2 width is 0.84 µm throughout.
- The dogleg's test segments overlap **0.146 µm²** of existing M2 at x3076.22–3076.50; DRC reports no added M2.2a. This overlap is not proven same-net because no L2N/netlist mapping is present.

## 541/541 evidence status

The historical `541/541` validator (`validate_drop_windows_2x2.rb`) reads `c930/asic_gf180mcu/build/lvs_chip/fill_regression_tie_final.gds` and `/scripts/chip.l2n`. **That GDS is absent from this checkout**, and the selected `fix70` GDS is also absent. The prior 541/541 result therefore cannot be regenerated or honestly updated here. The current no-duplicate crop is a 14-site representative check, not a replacement for 541/541 signoff.

## Signoff

The Gridworkz signoff packet is
`build/lvs_chip/eco_drop_2x2/GRIDWORKZ_SIGNOFF_PACKET.md`.
It is **pending** because the row-300 dogleg's M2 overlap is not net-qualified, the selected fix70 and the historical 541 source GDS are absent, and no Gridworkz signoff connector is available in this session. The no-duplicate 14-site crop itself has **0 added findings**; the earlier duplicate-row surrogate is not valid 541-row evidence.
