# Change record: approved separate M2 extension

## Approval

- **Status:** APPROVED and applied to the selected route.
- **Approved by:** user, 2026-11-15.
- **Approved addition:** one M2 rectangle at `x=4340..4400, y=9220..9610`. In the selected GDS it is merged into the adjacent M2 block; it is not a standalone polygon.
- **Size:** 60 × 390 dbu = **23,400 dbu²**.
- **Layer:** M2 (36/0).
- **Relationship to the notch:** this is an **addition outside the notch**, not part of the notch and not covered by the earlier notch-only approval.

## Selected result

- **GDS:** `rebased_tap_stream_out_filled_stitched_fix70.gds`
- **SHA-256:** `c5fa46ed3d17e36b75026964655e6376d15a00ca03f57f67277290fc98c20738`
- **Base:** accepted `fix59`, with the same island trim/widen, V2 shift, M3 patch, and 60 dbu notch used by `fix71`.

## What changed relative to fix71

`fix70` is `fix71` plus exactly the approved extension:

- M2 XOR: **23,400 dbu²**, bbox `(2874340,2579220;2874400,2579610)`, one merged XOR polygon.
- V2 XOR: **0**.
- M3 XOR: **0**.

Only M2 is rebuilt by the extension branch. No other layer is written or merged differently.

## Unchanged geometry

- **Notch:** `x=4060..4120, y=8940..9430`, unchanged.
- **V2 shift:** `x=3540..3800, y=8950..9210`, unchanged from `fix71`.
- **Island trim/widen:** unchanged.
- **M3 patch:** `x=3480..4720, y=8940..9220`, unchanged.
- **M4/V3/V4/M5 route:** unchanged.

## Verification

The checks were not weakened. The full runs use the same GF180MCU 5LM metal+via deck, tiling mode, and full-chip LVS command as the prior candidates.

### Focused ZN window

Window: `2873000,2576500,2876500,2579900`

- **M2.1 ×2**, both crop-boundary artifacts:
  - `(2873,2576.5;2873,2579.9)|(2873.22,2579.9;2873.22,2576.5)`
  - `(2876.3,2576.5;2876.3,2578.94)|(2876.5,2579.136;2876.5,2576.5)`
- **M2.2a ×0**
- No interior M2.1 remains. The ZN window is **clean of real violations**; the only two M2.1 items are crop-boundary artifacts.

### Full metal+via DRC

- **4,318 violations** (`fix70_full_drc/beol_tiling.lyrdb`, 610.905 s)

| Rule | Count |
|---|---:|
| M1.2a | 4,211 |
| M2.1 | 1 |
| M2.2a | 53 |
| M2.3 | 15 |
| M3.2a | 1 |
| M4.2a | 23 |
| V2.4b | 3 |
| V2.4c | 3 |
| V3.1 | 6 |
| V3.3b | 2 |
| **Total** | **4,318** |

The single full-chip M2.1 is at `(1765.6,1499.3;1765.1,1499.3)|(1765.1,1499.5;1765.6,1499.5)` (report units: µm), far outside the ZN window; it is not the real ZN M2.1 that the extension removed.

### Full-chip LVS

- **854,961 matches**
- **0 mismatches**
- **5,983.017 s**
- Report: `fix70_full_lvs/report.lvsdb`
- Log ends: `Congratulations! Netlists match.`

## Reproduction

The approved route is the `--with-extension` output from the accepted `fix59` base:

```sh
python3 probe/connect_zn_to_b.py \
  --gds rebased_tap_stream_out_filled_stitched_fix59.gds \
  --out fix70_repro.gds \
  --report fix70_repro_report.json \
  --with-extension
```

Build to a new path because the builder refuses to overwrite an existing output. The fresh output must match `fix70` geometrically: zero XOR on all routed layers. A review build produced `GEOMETRY_MATCH` with zero XOR on layers 34, 35, 36, 38, 40, 41, 42, 46 and 81. Its byte SHA-256 differed (`2f5e4cf0…` vs `c5fa46ed…`) even though the geometry matched; do not require SHA equality. The extension is a separate flag and is never folded into the notch.
