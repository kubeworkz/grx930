# Routing status

## Selected: fix70 — notch + separately approved M2 extension

- **GDS:** `rebased_tap_stream_out_filled_stitched_fix70.gds`
- **SHA-256:** `c5fa46ed3d17e36b75026964655e6376d15a00ca03f57f67277290fc98c20738`
- **Approval:** user approved the separate M2 extension on **2026-11-15**. The extension is outside the notch and is not part of the notch-only approval.
- **Change record:** `EXTENSION_CHANGE.md`.

### ZN window: clean of real violations (two crop-boundary artifacts)

Focused window `2873000,2576500,2876500,2579900` (`fix70_zn_crop.lyrdb`):

- **M2.1 ×2** — both are crop-boundary artifacts from the focused crop:
  - `(2873,2576.5;2873,2579.9)|(2873.22,2579.9;2873.22,2576.5)`
  - `(2876.3,2576.5;2876.3,2578.94)|(2876.5,2579.136;2876.5,2576.5)`
- **M2.2a ×0**
- **No interior M2.1 remains.** The ZN window is clean of real violations; the two boundary artifacts are not real layout violations.

### Full metal+via DRC

**4,318 violations** (`fix70_full_drc/beol_tiling.lyrdb`, 610.905 s)

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

The single full-chip M2.1 is at `(1765.6,1499.3;1765.1,1499.3)|(1765.1,1499.5;1765.6,1499.5)` (report units: µm), far outside the ZN window. It does not affect the clean ZN result above.

### Full-chip LVS

- **854,961 matches**
- **0 mismatches**
- **5,983.017 s**
- Report: `fix70_full_lvs/report.lvsdb`
- Log ends: `Congratulations! Netlists match.`

### Geometry

The approved extension is a separate addition, not a standalone polygon in the final GDS; it is merged into the adjacent M2 block:

- Extension: `x=4340..4400, y=9220..9610`
- Size: **60 × 390 dbu = 23,400 dbu²**
- It lies outside the notch footprint.

The rest of the route is unchanged from the notch-only candidate:

- **Notch:** `x=4060..4120, y=8940..9430`
- **V2 shift:** `x=3540..3800, y=8950..9210`
- Island: `x=4060..4320, y=8100..8660`
- Lower widening: `x=3780..4060, y=8046..8660`
- M2 escape: `x=3500..4060, y=8380..8660` plus vertical `x=3500..3840, y=8380..9250`
- M3 patch: `x=3480..4720, y=8940..9220`
- V3: `x=4400..4660, y=8950..9210`
- M4 riser: `x=4280..4900, y=7250..9300`
- V4: `x=4400..4660, y=7310..7570`
- M5 bridge to B2, with the existing B2 M4/V3/V4 landing stack

The extension changes only M2 relative to `fix71`:

- M2 XOR: **23,400 dbu²** at `(2874340,2579220;2874400,2579610)`
- V2 XOR: **0**
- M3 XOR: **0**

The notch and V2 shift are therefore unchanged. No check was weakened.

## Previous: fix71 (notch only, superseded)

- **GDS:** `rebased_tap_stream_out_filled_stitched_fix71.gds`
- **SHA-256:** `166db1e7047ac19e71a50daa72985d7e3b7e4cabb3f4a2435fe5423d627018af`
- Focused ZN window: **M2.1 ×3, M2.2a ×0** — two crop artifacts plus one real M2.1. **Not clean.**
- Full metal+via DRC: **4,319 violations** (`fix71_full_drc/beol_tiling.lyrdb`).
- Full-chip LVS: **854,961 matches, 0 mismatches**, 5,727.730 s.

`fix71` is retained as the notch-only candidate. It does not include the separately approved extension and is superseded by `fix70` for the selected route.

## Builder

`probe/connect_zn_to_b.py` starts from the accepted `fix59` base.

- Default: notch-only, producing the `fix71` geometry.
- `--with-extension`: adds the separately approved M2 extension and produces the selected `fix70` geometry.
- The extension is never folded into the notch.
- `build_connect.sh` defaults to the notch-only output; the approved extension route requires the explicit `--with-extension` invocation documented in `EXTENSION_CHANGE.md`.
