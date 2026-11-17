# ECO plan — 2×2 VSS/VDD drop arrays

**Status: PENDING DRC / signoff. This plan is not an approval.**

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
4. **Cropped real-layout gate:** no **added** M1/M2/M3/via finding at the representative sites after the drops. The first pass found 22 added findings (16 M1.2a, 6 M2.2a); this gate is **not yet met**.
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

## Signoff

The Gridworkz signoff packet is
`build/lvs_chip/eco_drop_2x2/GRIDWORKZ_SIGNOFF_PACKET.md`.
It is **pending** because the current cropped run is not clean and no Gridworkz
signoff connector is available in this session.
