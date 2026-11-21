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

- **Full-chip disposition:** `DRC_DISPOSITION.md` — **0 route-induced findings**; **4,318 unchanged pre-existing baseline findings**; waiver decision still **OPEN**.
- Item-level comparison against `fix59` found only five removed findings and zero added findings; the full report has **0 items inside the ZN window**.

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

## Catalog-fill candidate — actual8 (M1.2a clean, not selected)

Built from the original routed DEF, not from the filled or stitched fix70 artifact.

- **DEF:** `build/lvs_chip/filled/grx930_test_chip_filled_catalog_actual8.def`
- **DEF SHA-256:** `124f469957ad07cbe95814ca48bf72fd4153342aa79be714e877a801da02f738`
- **GDS:** `build/lvs_chip/stream_out_filled_catalog_actual8.gds`
- **GDS SHA-256:** `16f95289983983bb3ed557fd9b54e38576059910b548fa53697e1e95a925523b`
- **Fill:** 62,707 filler cells; 384,110 sites filled; 8,310 sites left empty by catalog-M1 blocking; 0 route/rail overlaps.
- **Gate:** actual streamed cell M1 polygons are decomposed into exact rectangles, and top-level route M1 boxes are included in the same spacing set. M1.2a is 0.23 µm = 460 dbu at 2000 dbu/µm.
- **Full metal+via DRC:** **86 findings**, all **DCF.1a**; **M1.2a = 0** (`catalog_actual8_drc/beol_tiling.lyrdb`, SHA-256 `7bea88ee4ef9c4a98edba678d8a11759a4e69ae28d8e91a6404e4af24abd978a`, 295.858 s).
- **M1.2a ownership:** 0 fill+standard, 0 standard+via, 0 standard+standard, 0 fill+via, 0 fill+fill, 0 direct top-level M1.
- **Status:** the requested fill-to-standard M1.2a closure is met without weakening DRC. This candidate is not selected and does not replace `fix70`.
- **Tap note:** worst cell-to-tap is 397.04 µm and 4 rows have no tap (limit 20 µm); this must be repaired before the candidate can be considered shippable.

### Tap-repair attempt — actual10 (not accepted)

- **DEF:** `build/lvs_chip/filled/grx930_test_chip_filled_catalog_actual10.def`
- **DEF SHA-256:** `cc38a205f54d12ff5938464a6c85119fee13eb2e1616c2763cf3aba6c5b38349`
- **GDS:** `build/lvs_chip/stream_out_filled_catalog_actual10.gds`
- **GDS SHA-256:** `40900871adf7fbdc3cef0dc161b272c4ef6e9a3595375943ff9126053fdf56da`
- **Taps:** 32,151 filltie cells; **0 rows without a tap**; worst cell-to-tap **182.56 µm** (limit 20 µm).
- **Beol DRC:** **88 findings**, all **DCF.1a**; **M1.2a = 0**
  (`catalog_actual10_drc/beol_tiling.lyrdb`, SHA-256 `659c5aaf830309048d4811d2a0135ba073cbbec96830e917323f4283e9aa41b2`).
- **Blocker:** for the worst row, every `filltie` site within ±20 µm of `_75537_`/`_85452_` has a positive **0.165 µm** M1 gap to `_75537_` in all tested orientations. Placing one would add an M1.2a violation, so the tap target cannot be met with the stock `filltie` cell and this row's M1. The candidate is not selected and is not shippable by the tap criterion.

## Previous: fix71 (notch only, superseded)

- **GDS:** `rebased_tap_stream_out_filled_stitched_fix71.gds`
- **SHA-256:** `166db1e7047ac19e71a50daa72985d7e3b7e4cabb3f4a2435fe5423d627018af`
- Focused ZN window: **M2.1 ×3, M2.2a ×0** — two crop artifacts plus one real M2.1. **Not clean.**
- Full metal+via DRC: **4,319 violations** (`fix71_full_drc/beol_tiling.lyrdb`).
- Full-chip LVS: **854,961 matches, 0 mismatches**, 5,727.730 s.

`fix71` is retained as the notch-only candidate. It does not include the separately approved extension and is superseded by `fix70` for the selected route.

## Stage 6 — ECO 2x2 drops: 168 sites, 504 sboxes

The 209 candidate sites were screened with the reject rule in `find_eco_sites.py`
(M1.2a space check on the metal the landing adds, including the anchor's own
fingers; M2.2a 0.28 µm and V1.2a 0.26 µm margins in the keepout). 41 were dropped
(12 comb-slot drawn pads, 29 spacing) and 4 moved to a clean x in their row; no
waivers. The all-site crop DRC, the Stage 7 XOR and the GDS-vs-DEF cross-check
are all clean on the resulting list.

- **Site list:** `build/lvs_chip/eco_drop_2x2/stage6/eco_sites_v3.csv` — **168 sites**, all `row`; `find_eco_sites.py` reports `refused_sites 31 (foreign 2 / M1.2a spacing 29)` and `ECO_SITES: CLEAN`.
- **Pre-ECO DEF:** `filled.def`, 172,187,377 B, SHA-256 `2ae87c2db7a0f6a1bb0095ee9f9a8a2786a556d07eb49208640ba772ef1fac04` — 361,906 components (209,075 placed + 152,831 filler), 0 rows without a tap, 0 rail/route overlaps.
- **ECO DEF:** `eco_routed.def`, 172,217,358 B, SHA-256 `d8c7211bf6d20db3297395d5a5c6ff5f31e9df70e3cb9ef55b6ef6b525579a01`; one `sub` special net (`USE GROUND`, no terminals) on **one swire with 504 sboxes** — 168 M2 straps, 168 `Via1_2X2_0_60_10_60_H_V`, 168 `Via2_2X2_0_60_10_60_V_H`. ODB read-back: `NET sub special=1 / SWIRES 1 / SBOXES 504`.
- **Crop DRC (168 windows, metal1..V2):** **891 before, 891 after, 0 added, 0 removed** — identical item sets (`drc_crop_v2/all_before.lyrdb`, `all_after.lyrdb`).
- **Chip-wide DRC (20 decks, `run_mode=flat`, `threads=1`):** **4,243 before, 4,243 after, 0 added, 0 removed**; the two reports are byte-identical, SHA-256 `aa61d907b5eb74bf68dd394337acdf347d5fb365aae8acdfc8cfc10f641baeb5` (`full_drc/before.lyrdb`, `full_drc/after.lyrdb`, 1,304,980 B each). Same deck list on both files (metal1–metal3, V1.1–V1.3d, V1.4a–c, V2.1–V2.4c), both RC 0; tiled and deep modes are unusable on this deck build (`Heap lost: the DeepShapeStore container no longer exists`). Rules: **M1.2a 4,183, M2.2a 45, M2.3 15** — unchanged.
- **Crop vs chip-wide counts:** the crop's 891 items span twenty rules, the chip-wide 4,243 only three. The crop's extra categories (M1.1, M1.3, V1.3c/d, V1.4a–c, V2.x) are **window-boundary artifacts** — shapes clipped at the crop edges — not design findings. The 4,243 is the pre-ECO baseline of `rebased_tap_stream_out_filled_stitched_fix16.gds`, and the 168 pads leave every item of it untouched.
- **Stage 7 XOR (`eco_routed.def` vs `filled.def`):** everything before `SPECIALNETS` and after `END SPECIALNETS` byte-identical; VDD/VSS/`one_`/`zero_` unchanged; only `sub` added. 168/168 straps match the CSV with 450 nm past each via, no unmatched or duplicate; M2 296.605 µm, 249.148 µm². **CLEAN**.
- **GDS-vs-DEF cross-check:** `grx930_test_chip_final.gds` (168 pads, 138,195,264 B, SHA-256 `0b21c684165ef12335332cf2e340b3c2b41b3ab3378a468697875cf2d663b24c`) and the crop pair: exact written shapes **168/168 M1, 168/168 M2, 168/168 M3, 672/672 V1, 672/672 V2**; missing 0.000 µm², extra 0.000 µm²; **no site disagrees**. The 209-site GDS is kept as `grx930_test_chip_final_209.gds`.
- **M3 pads kept on purpose:** the 900 × 800 M3 box is the via's own LEF enclosure (`Via2_2X2_0_60_10_60_V_H`: `RECT -0.450 -0.400 0.450 0.400`), not a separate pad, and the DEF placement already carries it. All 168 fall entirely inside existing M3 (M3 adds **0.000 µm²**), so the pads change no metal; dropping them in the GDS only would make GDS ≠ DEF and silently assume existing M3 at every site. **Decision: keep.**

## Builder

`probe/connect_zn_to_b.py` starts from the accepted `fix59` base.

- Default: notch-only, producing the `fix71` geometry.
- `--with-extension`: adds the separately approved M2 extension and produces the selected `fix70` geometry.
- The extension is never folded into the notch.
- `build_connect.sh` defaults to the notch-only output; the approved extension route requires the explicit `--with-extension` invocation documented in `EXTENSION_CHANGE.md`.
