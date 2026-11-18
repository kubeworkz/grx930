# Pad-ring and precheck-mask comparison — 0fe vs CIEL 792

**Status: PASS — NO PAD-RING OR FLOORPLAN EDIT REQUIRED; `cor` LEF PIN/OBS
WAIVER RECORDED.**
**Date: 2026-11-18.** This is a geometry comparison and LEF pin/OBS waiver
record, not a flow run. No synthesis,
P&R, DRT, stream-out, ECO insertion, or RCX was started. The submission package
remains **VOID — DO NOT SUBMIT**.

## Conclusion

The 0fe → 792 IO change does **not** require an edit to `slot_1x1`, the pad ring,
the die/core floorplan, or `mask_1x1.gds`.

The GDS pad-opening layer is identical between the two PDK versions. The only
changed **pad-opening** geometry is the LEF `PAD` pin on the signal pads, and the
precheck reads the GDS opening layer, not the LEF pin.

792 also changes non-opening LEF pin exposure on the power/analog pads and the
corner cell, and introduces 13 `gf180mcu_fd_io__cor` pin/OBS overlaps. Those
overlaps are recorded below as a LEF-only waiver; they do not change the GDS or
pad-ring geometry and do not block the corner rail pins.

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
| 792 `cor` LEF | in-image `gf180mcuD/libs.ref/gf180mcu_fd_io/lef/gf180mcu_fd_io__cor.lef` |

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

The PAD-pin change is therefore a **LEF pin-aperture change**, not a change in
the physical pad opening, cell footprint, pad order, or pad count.

## LEF pin/OBS waiver — `gf180mcu_fd_io__cor` (792)

**Waiver ID: `COR-LEF-PIN-OBS-001`. Disposition: ACCEPTED; no LEF, GDS,
pad-ring, or floorplan edit.**

### Finding

The 792 `cor` LEF contains 13 pin RECTs that are fully inside same-layer OBS
obstructions. They total **1.0192 µm²** (13 × 0.0784 µm²), distributed as
**9 Metal3, 3 Metal4, 1 Metal5** and **7 DVDD, 3 DVSS, 2 VDD, 1 VSS**. All are
0.28 × 0.28 µm and fully covered, not partially clipped.

| Pin | Layer | LEF line | RECT (µm) |
|---|---|---:|---|
| DVDD | Metal3 | 347 | 297.360 351.005 297.640 351.285 |
| DVDD | Metal3 | 353 | 281.360 350.980 281.640 351.260 |
| DVDD | Metal3 | 403 | 337.360 351.070 337.640 351.350 |
| DVDD | Metal3 | 409 | 273.360 350.970 273.640 351.250 |
| DVDD | Metal3 | 415 | 209.360 351.095 209.640 351.375 |
| DVDD | Metal4 | 301 | 172.040 350.980 172.320 351.260 |
| DVDD | Metal5 | 435 | 351.950 265.690 352.230 265.970 |
| DVSS | Metal3 | 735 | 329.370 351.050 329.650 351.330 |
| DVSS | Metal3 | 741 | 201.360 351.065 201.640 351.345 |
| DVSS | Metal3 | 771 | 305.360 351.020 305.640 351.300 |
| VDD | Metal3 | 887 | 313.360 351.025 313.640 351.305 |
| VDD | Metal4 | 869 | 352.585 257.030 352.865 257.310 |
| VSS | Metal4 | 953 | 352.580 249.690 352.860 249.970 |

Each of the 13 has a 0.26 × 0.26 µm VIA3/VIA4 cut at its center; the 0.28 µm
pin is the cut plus a 0.01 µm LEF halo. These are interior via-tap abstractions,
not the actual rail-edge ports.

### Why the corner rails are not blocked

The `cor` cell's corner-abutment rail pins are the north/east edge strips. The
LEF also contains interior vertical rail strips and the 13 via taps; the
overlap affects only the latter. The north-rail OBS does not reach the edge
strips at y = 354–355, and the east-side edge strips at x = 354–355 are
uncovered. Examples: DVDD
`(342, 354)–(348.39, 355)`, VDD `(310, 354)–(317, 355)`, VSS
`(318, 354)–(325, 355)`. `pad_ring.cfg` places `cor` at all four corners
(lines 135–138), using those exposed edges.

After subtracting same-layer OBS:

| Net | Edge shapes/layer | Edge-tap area M3 / M4 / M5 (µm²) | Total exposed pin area M3 / M4 / M5 (µm²) |
|---|---:|---:|---:|
| DVDD | 23 | 233.000 / 233.000 / 240.379 | 238.698 / 417.012 / 414.560 |
| DVSS | 20 | 202.780 / 202.780 / 202.780 | 202.780 / 376.059 / 372.625 |
| VDD | 4 | 28.000 / 28.000 / 28.000 | 28.000 / 33.398 / 57.481 |
| VSS | 4 | 28.000 / 28.000 / 28.000 | 28.000 / 33.320 / 38.411 |

All edge pin shapes are fully outside OBS. The total-exposed column also
includes the interior vertical rail strips, which is why it is larger than the
edge-tap area. The 13 covered shapes sit at roughly y ≈ 351 or x ≈ 352, in the
rail interior. Those 13 interior via taps are fully covered by same-layer OBS in
the LEF, so they are not open for pin access; that is not the intended rail
connection. The named nets retain exposed edge/rail pins. The overlap is a LEF
abstraction artifact, not a GDS geometry change. This review did not run LVS, so
it does not establish physical net connectivity.

### Re-open conditions

Re-open `COR-LEF-PIN-OBS-001` if any of the following occurs:

- A router or pin-access check reports a blocked `cor` pin that cannot use an
  exposed edge tap.
- `cor` is used in a non-abutted configuration, or signal routing is attempted
  to one of the interior via taps.
- A LEF reader/lint or signoff gate requires zero pin/OBS overlap.
- The 792 PDK, `cor` LEF, or `cor` OBS geometry changes, or an edge-rail pin
  becomes clipped by a future OBS change.

If reopened only for a hard LEF lint, the minimal exit is to delete the 13 pin
RECT lines listed above and leave every companion metal RECT and all OBS
untouched. A read-only simulation of that deletion gave **0 pin/OBS overlaps and
0 empty PORTs**. Do not trim OBS or change GDS.

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
| `cor` LEF pin/OBS overlap | **WAIVED** — `COR-LEF-PIN-OBS-001`; 13 taps, 1.0192 µm² |
| Need GDS or LEF geometry edit | **NO** — waiver accepted; no edge-rail pin is blocked |
| Remaining work | Router pin-access/DRC revalidation during routing; full precheck after a real assembled GDS |

## Limitations

This comparison used the IO library GDS/LEF and the slot/mask assets directly. It
did not assemble a new pad-ring GDS, run the precheck, or run any flow step. A
full precheck still has to run on the eventual `chip_top.gds`; that is not a
pad-ring or floorplan edit.

The `cor` waiver is based on direct LEF/GDS geometry, not a router pin-access
run. It covers only the LEF pin/OBS abstraction; it does not waive physical DRC
or LVS. The full assembled-ring DRC/LVS/precheck remains to be run.

The temporary 0fe PDK volume used for this comparison was removed after the
comparison. No project file other than the recorded baseline artifacts and
records was changed.
