# Pad-ring and precheck-mask comparison — 0fe vs CIEL 792

**Status: PASS — NO PAD-RING OR FLOORPLAN EDIT REQUIRED.**
**Date: 2026-11-18.** This is a geometry comparison, not a flow run. No synthesis,
P&R, DRT, stream-out, ECO insertion, or RCX was started. The submission package
remains **VOID — DO NOT SUBMIT**.

## Conclusion

The 0fe → 792 IO change does **not** require an edit to `slot_1x1`, the pad ring,
the die/core floorplan, or `mask_1x1.gds`.

The GDS pad-opening layer is identical between the two PDK versions. The only
changed pad geometry is the LEF `PAD` pin on the signal pads, and the precheck
reads the GDS opening layer, not the LEF pin.

## Sources

| Item | Value |
|---|---|
| Flow image | `ghcr.io/wafer-space/gf180mcu-precheck@sha256:104d9ccbc0d3e4bbffba6201b7f68cd8f64d064b5b9072b64a3a4c926d46339f` |
| Slot | `c930/asic_gf180mcu/tools/gf180mcu-project-template/librelane/slots/slot_1x1.yaml` |
| Slot SHA-256 | `cb47d6bb0e23d802c7b1fd54307880be466a3e6a09622222d47d73601a26b5a9` |
| Precheck mask | in-image `assets/golden_masks/mask_1x1.gds` |
| Mask SHA-256 / size | `77bbb647e191291255943cf343ef3b4a8c52e1b70cf3e34e631bd6a8bb188c66` / 5,014 bytes |
| 0fe IO GDS | `gf180mcuD/libs.ref/gf180mcu_fd_io/gds/gf180mcu_fd_io.gds`, 17,720,326 bytes |
| 792 IO GDS | same path in the pulled image, 17,722,484 bytes, SHA-256 `99586e415ba4d9013ee6b0acfcc419bf2a1e30d9dcaa99953deb2878c82ebf51` |

## Slot and mask

`slot_1x1.yaml` defines 74 pads:

| Edge | Pads | Mask aperture pitch |
|---|---:|---:|
| South | 17 | 180 µm |
| East | 20 | 211 µm |
| North | 17 | 180 µm |
| West | 20 | 211 µm |
| **Total** | **74** | — |

`mask_1x1.gds` contains:

- **74 pad apertures, all 60 × 60 µm**
- one full-frame layer-37/0 shape of 3926 × 5116 µm at the 3 µm inset
- the same **S17 / E20 / N17 / W20** allocation and the same pitches

The precheck script's pad check is:

```text
input(37,0).and(mask).xor(mask)
```

It compares GDS layer 37/0 openings against `mask_1x1.gds`. It does not read the
LEF `PAD` pin.

## 0fe vs 792 IO geometry

### GDS pad openings

For every `gf180mcu_fd_io` cell carrying layer 37/0, both versions have a
**60 × 60 µm** opening at the same cell-relative center, **(32, 32)**. A KLayout
region XOR of the 0fe and 792 layer-37/0 geometry is **empty for every IO cell**,
including `in_c`, `in_s`, `bi_t`, `bi_24t`, `asig_5p0`, `dvdd`, `dvss`, the fill
cells, and the corner cell.

The two IO GDS files are not byte-identical overall: 0fe is 17,720,326 bytes and
792 is 17,722,484 bytes. The difference is outside the pad-opening layer; the
37/0 geometry is unchanged.

### LEF footprints and PAD pins

| Item | 0fe | 792 |
|---|---|---|
| Pad cell `SIZE` | 75 × 350 µm | 75 × 350 µm |
| Fill cells | 1 / 5 / 10 / 0.1 × 350 µm | unchanged |
| Corner cell | 355 × 355 µm | unchanged |
| `in_c`/`in_s`/`bi_t`/`bi_24t` LEF `PAD` | **25 × 25 µm** at (25,20)–(50,45) | **60 × 60 µm** at (7.5,2)–(67.5,62) |
| `asig_5p0`/`dvdd`/`dvss` LEF `PAD` | none | none |
| `gf180mcu_ef_io__bi_t` | 25 × 25 µm | unchanged; not used by the slot |

The 0fe-to-792 change is therefore a **LEF pin-aperture change**, not a change
in the physical pad opening, cell footprint, pad order, or pad count.

## Verdict for the re-pin

| Check | Result |
|---|---|
| Pad count/order matches `slot_1x1` (S17/E20/N17/W20) | **PASS** |
| All mask apertures are 60 × 60 µm | **PASS** |
| 0fe GDS layer 37/0 equals 792 GDS layer 37/0 | **PASS** — XOR empty |
| Pad cell footprints unchanged (75 × 350 µm; 355 × 355 µm corner) | **PASS** |
| Need to edit `slot_1x1` | **NO** |
| Need to edit pad-ring positions or die/core floorplan | **NO** |
| Need to edit `mask_1x1.gds` | **NO** |
| Remaining work | LEF pin-access/DRC revalidation during routing; full precheck after a real assembled GDS |

## Limitations

This comparison used the IO library GDS/LEF and the slot/mask assets directly. It
did not assemble a new pad-ring GDS, run the precheck, or run any flow step. A
full precheck still has to run on the eventual `chip_top.gds`; that is not a
pad-ring or floorplan edit.

The temporary 0fe PDK volume used for this comparison was removed after the
comparison. No project file other than the recorded baseline artifacts and
records was changed.
