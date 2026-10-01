# GF180MCU area budget — review of the 1×1 slot numbers

**Reviews:** `c930/asic_gf180mcu/AREA_ANALYSIS.md`, `PLAN_B_netlist_rework.md`,
`pad_ring.cfg`, `openlane2_rtl/config.json`, `wafer_space_checklist.md`, `README.md`
**Date:** 2026-09-30
**Status:** read-only review. No file under `asic_gf180mcu/` was modified.

---

## 0. The finding

Three documents in `asic_gf180mcu/` quote **12.92 mm²** as the 1×1 slot's core
area. The OpenLane flow floorplans **19.93 mm²**. Both numbers are in the tree at
once and nothing reconciles them, so `design__instance__utilization = 84.35%` —
the number Plan B's whole argument rests on — is measured against the wrong
denominator.

**12.92 mm² is correct.** It is wafer.space's own published core area for the
slot. Against it the design is at **130% utilisation**, not 84.35%, and Plan B's
gates are 1.54× tighter than it thinks. **None of Plan B's five options as
written clears its own ≤30% line.**

## 1. The authoritative numbers

From wafer.space's Run 3 slot specification (GF180MCU, 180 nm mixed-signal,
1P5M26ML, 1,000 dies per slot):

| Slot | Die (mm) | Usable silicon | Core area | I/O pads |
|---|---|---:|---:|---:|
| **1×1 (Full)** | **3.93 × 5.12** | **19.67 mm²** | **12.92 mm²** | 56 |
| 1×0.5 (Half-height) | 3.93 × 2.53 | 9.62 mm² | 5.02 mm² | 56 |
| 0.5×1 (Half-width) | 1.94 × 5.12 | 9.55 mm² | 4.46 mm² | 56 |
| 0.5×0.5 (Quarter) | 1.94 × 2.53 | 4.67 mm² | 1.73 mm² | 48 |

Full slot: $7,000 (Run 3) — the figure `AREA_ANALYSIS.md` records as "early bird".

> **Design constraint:** *you must provide your own pad ring and ESD protection.*

That sentence settles a question `pad_ring.cfg` leaves open. Its comment —
"This configuration uses the wafer.space default pad ring" — reads as though
wafer.space supplies the pads and you submit a core-only GDS. They do not. The
56 pads are the slot's bond-out budget; the pad **cells** are yours to
instantiate, along with the ESD. So pads occupy your die, and the area left for
logic is the 12.92 mm² core, not the 19.67 mm² of usable silicon.

**The slot table was never the problem.** `AREA_ANALYSIS.md` lists all four core
areas correctly, 12.92 mm² included. Two other things went wrong independently:
its design-side estimate (30K cells, 8.76 mm², assuming SRAM macros that were
never generated) and the flow's floorplan.

## 2. Where 19.93 mm² comes from

`openlane2_rtl/config.json`:

```
"DIE_AREA":   "0 0 3930 5120",
"FP_SIZING":  "absolute",
```

with no `CORE_AREA` and every pad-related setting null. OpenLane therefore takes
the whole die as placeable, less a default margin of about 11 µm — a seal ring's
worth and nothing more. That yields 19.93 mm².

Note what that is: **19.93 mm² is essentially wafer.space's *usable silicon*
(19.67 mm²), and 0.26 mm² over even that.** The floorplan does not merely omit
the pad ring; it spills past the seal-ring boundary. As it stands the GDS is not
submittable, independently of how full it is.

Geometry from the PDK, for the record:

| | µm | mm² |
|---|---|---:|
| Die | 3930 × 5120 | 20.12 |
| less 26 µm seal ring each side | 3878 × 5068 | 19.65 |
| less 350 µm pad depth (`gf180mcu_fd_io` LEF `SIZE 75 BY 350`) | 3178 × 4368 | 13.88 |
| **wafer.space's published core** | **3048 × 4238** | **12.92** |

19.65 against the published 19.67 — close enough that a uniform 26 µm seal is
about right, not exact. Working back from 12.92 gives a **415 µm** inset: the
350 µm pad plus ~65 µm of I/O power ring and routing channel. Which is what
"provide your own ESD" costs.

## 3. 12.92 mm² is the right area but `pad_ring.cfg` has the wrong shape

`pad_ring.cfg` states:

```
#   Pad ring: ~100µm each side
#   Core: ~3.73mm × 3.47mm (with default pad ring)
```

3.73 × 3.47 = 12.94 mm², so the **area** matches wafer.space. The **shape** does
not. A uniform inset from a 3.93 × 5.12 die cannot produce a core narrower than
it is tall; the real core is **3.05 × 4.24 mm**, aspect ratio 0.72 against the
config's 1.07. The height has been reduced by 1.4 mm to make the product come
out at 12.92. And 100 µm is not the pad depth — the PDK says 350 µm.

So the right number is in the tree for the wrong reasons, which is why it never
propagated to the floorplan.

**Fix:** keep `DIE_AREA` and add the core rectangle explicitly.

```
"DIE_AREA":  "0 0 3930 5120",
"CORE_AREA": "441 441 3489 4679",
```

441 = 26 µm seal + 415 µm ring; 3489 − 441 = 3048 and 4679 − 441 = 4238.

## 4. Plan B re-scored against 12.92 mm²

Plan B's gates, restated against the real core:

| Gate | Plan B used | Correct |
|---|---:|---:|
| ≤ 30% utilisation | ≤ 5.98 mm² of cells | **≤ 3.88 mm²** |
| ≤ 15k cells/mm² | ≤ 299K placed | **≤ 194K placed** |

Current density is **55.9k cells/mm²** (722,223 / 12.92), not the 36k Plan B
reports — above the 50k it calls the library's theoretical maximum, and 2.5×
the best design that has ever routed on this shuttle (Cloneless1, 22k).

Scenario areas, calibrated from Plan B's own run — 23.1 µm² per flat cell
(12.02 mm² / 520,182) and 1.399× P&R inflation (16.81 / 12.02) — with macro
areas read from the PDK LEFs (§5):

| Scenario | Flat cells | Macro | Logic | Total | Util vs 12.92 | |
|---|---:|---:|---:|---:|---:|---|
| Current (8 KB FF array) | 520,182 | — | *measured* | 16.81 | **130%** | impossible |
| B (2 KB FF, caches halved) | ~230K | — | 7.43 | 7.43 | **58%** | fails |
| B-aggressive (1 KB FF) | ~180K | — | 5.82 | 5.82 | **45%** | fails |
| A (8 KB PDK SRAM macro) | ~150K | 3.35 | 4.85 | 8.20 | **63%** | fails |
| A+B (2 KB PDK SRAM macro) | ~110K | 0.84 | 3.55 | 4.39 | **34%** | marginal |
| **A+B+B′ (2 KB macro, no caches)** | ~73K | 0.84 | 2.36 | **3.20** | **25%** | **passes** |

The calibration reproduces Plan B's own estimates for the options it costed
without macros — 7.43 against its 6–7.5 mm² for B, 5.82 against its ~5.8 for
B-aggressive — so the method is its arithmetic, not a competing one. What
changes is the denominator and the macro area.

Three consequences for Plan B's §5 recommended path:

1. **Option B is not a sufficient first move.** Plan B picks it as Phase 1 on
   the strength of "util ≈ 30–37%, inside the Run-1 shipped envelope". Against
   the real core it is 58%, above every design that has shipped on this shuttle.
   It remains the cheapest *measurement* — hours of work, and the yosys probe in
   its §7 settles the cell count without a flow run — but it should be costed as
   a step toward the target, not as arrival at it.
2. **Option A alone also fails**, for a reason Plan B could not have seen: at the
   full 8 KB the macro is 3.35 mm², a quarter of the core on its own (§5).
3. **The capacity cut and the macro are both required**, and on these estimates
   even A+B lands at 34% — over its own line. Clearing 30% wants B′ as well
   (delete the caches, which Plan B holds in reserve). That makes B′ part of the
   plan rather than a contingency, and its §8 item 6 — the cache index/tag
   decomposition bug — argues the same way from the correctness side.

**One gate stops being meaningful once a macro lands.** The ≤15k cells/mm²
envelope was calibrated on Run-1 designs with zero macros. A+B is ~150K placed
cells = 11.6k/mm², which passes, while its area utilisation does not. The two
gates diverge because a macro contributes area but no placed standard cells.
Area utilisation is the one to hold to; the density figure needs recalibrating
against macro-bearing designs before it is used again.

## 5. The PDK already ships SRAM macros

Plan B's Option A proposes generating an OpenRAM 64 Kbit macro, budgeted at
**2–4 days** with "first-time macro flow" risk, OpenRAM install, hardening,
LEF/GDS/LIB generation and macro LVS/DRC.

`gf180mcu_fd_ip_sram` is in the PDK, vendor-hardened, with `lef gds lib spice
cdl mag maglef verilog` views already present. Areas from the LEF `SIZE` lines:

| Macro | Size (µm) | mm² | kbit/mm² |
|---|---|---:|---:|
| `sram64x8m8wm1` | 431.86 × 232.88 | 0.1006 | 5.1 |
| `sram128x8m8wm1` | 431.86 × 268.88 | 0.1161 | 8.8 |
| `sram256x8m8wm1` | 431.86 × 340.88 | 0.1472 | 13.9 |
| `sram512x8m8wm1` | 431.86 × 484.88 | 0.2094 | 19.6 |

Every macro is 431.86 µm wide whatever its depth, so periphery is the fixed cost
and only the deepest one is dense. Tiling for the two capacities in play:

| Capacity | Tiling | Datapath | Beats per 256-bit line | mm² |
|---|---|---:|---:|---:|
| 8 KB | 32 × `sram256x8` | 256-bit | 1 | 4.71 |
| 8 KB | **16 × `sram512x8`** | 128-bit | 2 | **3.35** |
| 2 KB | 8 × `sram256x8` | 64-bit | 4 | 1.18 |
| 2 KB | **4 × `sram512x8`** | 32-bit | 8 | **0.84** |

Two things follow.

**The tooling risk in Option A is smaller than budgeted.** No OpenRAM install,
no hardening, no macro-level DRC/LVS. The flow already has the macro steps
(`11-openroad-checkmacroinstances`, `16-openroad-manualmacroplacement`) and the
`MACROS` / `FP_MACRO_PLACEMENT` keys. What remains is real but ordinary: PDN
straps over the macro, pin access on 5LM, antenna, and STA against the vendor
`.lib`.

**The area win is smaller too.** Option A's estimate of 0.5–1.0 mm² for 64 Kbit
implies 66–131 kbit/mm². The PDK's own hardened macro reaches 19.6. The
estimate's basis — "Run-1 data: 4 Kbit ≈ 0.023 mm² core + periphery" — works out
to 178 kbit/mm², while the PDK's 4 Kbit macro (`sram512x8`) is 0.209 mm², **9.1×
larger**. Whatever the Run-1 figure measured, it was not a hardened macro of
that capacity at this node. Against the FF array's 7.7 kbit/mm² the macro is a
genuine 2.5× win — just not the order of magnitude Option A assumes.

**Caveat to confirm on the server:** the SRAM IP is present in the `gf180mcuA`
install in this tree, and that is the only variant installed here. The flow
targets `"PDK": "gf180mcuD"` (5LM). Whether `gf180mcu_fd_ip_sram` ships with the
D variant on the build box has to be checked before planning around it. If it
does not, the choice between OpenRAM and retargeting is a real one.

Also worth noting: this changes the datapath question in Option A's RTL work.
Its path (a) — a 256-bit-wide macro keeping the single-cycle line read — costs
4.71 mm² at 8 KB. Path (b) — narrow and burst — is both cheaper and, at 2 KB on
four macros, the only option in the table that fits comfortably. The 2-cycle
read contract the cache controllers depend on is the constraint to design
against, and §8 item 6's index/tag bug has to be fixed first either way.

## 6. Secondary errors in `pad_ring.cfg`

The ring now has to be built, so these matter:

1. **The pad cell names cannot be instantiated.** The config lists
   `gf180mcu_fd_sc_mcu7t5v0__dvdd`, `__in`, `__out`, `__inout`, `__cp`, `__bidi`
   — the *standard cell* library prefix (7-track 5 V) with I/O suffixes. The I/O
   library is `gf180mcu_fd_io`, and its cells are `gf180mcu_fd_io__dvdd`,
   `__dvss`, `__bi_t`, `__bi_24t`, `__asig_5p0`.
2. **The pad pitch arithmetic is wrong by 3.7×.** "Top row: 14 pads (0.28mm × 14
   = 3.92mm ≈ die width)". Pads are 75 µm wide, not 280 µm: 14 of them span
   1.05 mm, leaving 2.2 mm of the top edge empty.
3. **Corners and fill are missing.** A ring needs `gf180mcu_fd_io__cor`
   (355 × 355 µm) at each corner and `__fill1` (1 × 350 µm) between pads;
   neither appears. The corners are what make the 56-pad budget plausible —
   at 75 µm pitch between 355 µm corners the die has room for about 200 pad
   sites (42 per horizontal edge, 58 per vertical), which is also why the
   config's note about a LibreLane custom ring reaching 168 is consistent.
4. **Power breaks.** `__brk2` / `__brk5` exist for splitting I/O power domains;
   whether this design needs them is a decision, but it should be a recorded one.

**The pad budget itself is comfortable** and is not a constraint on the design:
the config assigns 9 signals (4 GPIO, UART TX/RX, interrupt, clock, reset)
against 36 available after 20 power pads, with 56 the slot's limit.

## 7. Actions

In the order they unblock each other:

1. **Set `CORE_AREA`** (§3). Every utilisation number the flow has produced is
   against the wrong rectangle until this lands, including any future gate.
2. **Correct 19.93 → 12.92 mm²** in `PLAN_B_netlist_rework.md`'s target line and
   its §1 root-cause paragraph, and restate the two gates as ≤3.88 mm² and
   ≤194K placed cells.
3. **Replace `AREA_ANALYSIS.md`'s verdict.** "Design FITS with 32–49% margin"
   rests on a 30K-cell estimate against a netlist that synthesised to 520,182.
   Its slot table is right and worth keeping.
4. **Re-plan Phase 1 as B *and* A together** (§4), with B′ in scope rather than
   in reserve, and the §8 item 6 cache index/tag fix before any of it.
5. **Confirm `gf180mcu_fd_ip_sram` under `gf180mcuD`** on the build box (§5).
   This decides whether Option A is a day's work or OpenRAM's 2–4.
6. **Rebuild `pad_ring.cfg`** against `gf180mcu_fd_io` (§6), as a pad ring the
   design owns rather than one it expects to be given.
7. **Recalibrate or retire the cells/mm² gate** before applying it to a
   macro-bearing netlist (§4).

Not actions, but recorded: the smaller slots are no escape. A half-width slot's
4.46 mm² core wants ≤1.34 mm² of cells at 30%; A+B+B′ at 3.20 mm² is 2.4× too
large for it. The full slot is the target whatever happens to the netlist.

One platform note from the Run 3 specification, for whoever buys the slot:
wafer.space's `calculate_slot_size` had `HALF_WIDTH` and `HALF_HEIGHT` swapped,
affecting slot metadata for top-row and Column H slots on the G801/G802
shuttles. Harmless at the 1×1 slot, where both halves are the same thing — but
the two half slots differ in core area (4.46 vs 5.02 mm²) *and* in aspect ratio
(1.94 × 5.12 against 3.93 × 2.53), so a swapped assignment would hand you a
floorplan of the wrong shape, not merely the wrong size. Verify the slot size
assignment against the order if their tooling is in the loop.

## 8. Reproduction

Pad and SRAM geometry, from the PDK in this tree:

```sh
cd c930/asic_gf180mcu/pdk/share/pdk/gf180mcuA/libs.ref
for n in bi_t dvdd dvss cor fill1 asig_5p0; do
  printf '%-34s %s\n' "gf180mcu_fd_io__$n" \
    "$(grep -m1 '^ *SIZE' gf180mcu_fd_io/lef/gf180mcu_fd_io__$n.lef)"
done
for f in gf180mcu_fd_ip_sram/lef/*.lef; do
  printf '%-40s %s\n' "$(basename "$f" .lef)" "$(grep -m1 '^ *SIZE' "$f")"
done
```

Core rectangle, from the published 12.92 mm² and a uniform inset:

```sh
python3 -c "
import math
W,H,seal = 3930.0, 5120.0, 26.0
uw,uh = W-2*seal, H-2*seal
a,b,c = 4.0, -2*(uw+uh), uw*uh - 12.92e6
p = (-b - math.sqrt(b*b - 4*a*c)) / (2*a)
print('inset %.0f um -> core %.0f x %.0f um = %.2f mm2' % (p, uw-2*p, uh-2*p, (uw-2*p)*(uh-2*p)/1e6))
print('CORE_AREA \"%.0f %.0f %.0f %.0f\"' % (seal+p, seal+p, W-seal-p, H-seal-p))"
```

Utilisation, from the metrics Plan B §7 already cites
(`runs/RUN_2026-09-24_04-18-20/52-openroad-globalrouting/state_out.json`):
`design__instance__area` 16,808,300 µm² ÷ 12.92 mm² = **130.1%**;
`design__instance__count` 722,223 ÷ 12.92 mm² = **55.9k cells/mm²**.

## 9. What this does not settle

- **The scenario table in §4 is an estimate**, built from Plan B's own cell
  counts and per-cell area. Only the "current" row is measured. The yosys probe
  in its §7 is the cheap way to replace the estimates with counts, and should be
  run before any flow run is committed to.
- **Routability, not area, is what failed.** 25% utilisation is necessary, not
  sufficient: the GRT and DRT gates in Plan B §6 still decide, and a 5LM process
  with M2 overflow at 103% has failed at area figures that looked comfortable.
- **The firmware's footprint against 2 KB** is Plan B's §8 item 1 and is
  untouched here.
- **The PTA tile's own area** is not in any of these numbers. The test chip
  excludes the NPU, so none of this bounds what a PTA-bearing die would need —
  that is still the open row in the PTA program plan's C4(b).
