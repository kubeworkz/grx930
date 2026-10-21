# Plan: a real LVS, starting from what we already own

**Status: plan, a spike, and its first green.** Written 2026-10-17. §1 is
inventory verified on this box; §6 records the spike, the deck defect it found,
and the first matching LVS — the PDK's own device fixture. No GRX930 LVS has run
yet; that is S2.

## 0. The goal, stated so it cannot be fudged

A green LVS line must mean: *a layout was extracted into devices, a schematic
was read into devices, and the two netlists compared equal under the PDK's own
rules.* Not "a script exited 0", not "netgen printed no ERROR", not "the flow's
LVS step was skipped because `RUN_LVS` was unset".

Today the answer to "did we do LVS on GRX930" is **no**; the answer to "do we own
a working LVS" is yes, for the PDK's fixture only (§6). This plan closes the gap
in stages that each fail loudly.

## 1. What we already have (verified on this box, 2026-10-17)

| what | path | state |
|---|---|---|
| Toolchain | `ghcr.io/efabless/openlane2:2.3.10` (local image, already the flow's pin) | `magic`, `netgen`, `klayout`, `openroad`, `yosys` all on PATH inside it |
| PDK | `c930/asic_gf180mcu/pdk/share/pdk/gf180mcuA` (994 MB, open_pdks install) | std cells have `mag/`, `gds/`, `cdl/`, `spice/`, `verilog/` views; `gf180mcu_fd_io` and `gf180mcu_fd_ip_sram` present |
| Tech files | `c930/asic_gf180mcu/libs.tech/{magic,netgen,klayout}` | `gf180mcuA.magicrc`, `gf180mcuA_setup.tcl` (netgen), KLayout LVS deck `klayout/tech/lvs/gf180mcu.lvs` + `run_lvs.py` |
| Layout | `c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds` (77 MB, 2026-09-21) | top cell **`grx930_test_chip`** confirmed by scanning the GDS; **no** `gf180mcu_fd_io`, **no** `gf180mcu_fd_ip_sram`, **no** `sealring` strings — a core-only layout |
| Netlist | `c930/asic_gf180mcu/build/grx930_test_chip_routed.v` (9.6 MB, 2026-09-20) | top module `grx930_test_chip`, 6 ports, **53,745 instances** over 34 distinct std cells; netgen parses it (verified: `netgen -batch lvs` read it and created placeholder cells for the 34 library modules) |

Two facts that shape everything below:

* **The pair may not be the same run.** The netlist is 2026-09-20 23:05, the GDS
  2026-09-21 11:55, and the GDS is from the campaign that `SUPERSEDED.md` voids.
  LVS is exactly the check that settles whether they agree; a mismatch on this
  pair is a finding about *the pair*, and the pipeline is still proven.
* **The layout is core-only.** No pads, no macro, no seal ring. That is the
  easiest possible full-chip LVS: pure standard-cell logic. The IO/SRAM models
  are not needed until the wrapper (`tpl02`) or the real die.

## 2. Two engines, and why both

| engine | what it gives | cost | used for |
|---|---|---|---|
| **KLayout LVS** (`gf180mcu.lvs`, or `run_lvs.py` around it) | the PDK's own deck, fast, parallel, identical silicon semantics (`variant=C` = 5LM stack); needs no device-model wiring | needs a **SPICE/CDL schematic**, not Verilog, so the netlist must be converted (yosys `write_spice` against the library CDL, or the flow's own export) | S1a (deck proof), S2, S3, S4 |
| **magic + netgen** | the path LibreLane's `RUN_LVS` took on the OL2 runs; device-level extraction, comparison against the Verilog with the library CDL | full-chip extraction of 53 k instances is hours and RAM-bound; **blocked until the primitive models are wired** (§6) | S1b (cell proof), then S2/S3 as the independent second opinion |

Order matters and it changed after the spike (§6): KLayout runs first because its
extraction already works and it needs no device-model wiring; magic+netgen
follows once S1b is green, as an engine that shares no code with the deck. A
disagreement between the two is a bug in one of them and must be chased, not
averaged.

## 3. Stages

### S0 — environment proof (minutes, cheap, no design)

```sh
# from the repo root; MSYS_NO_PATHCONV=1 only matters on Windows
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/work" -w /work/c930/asic_gf180mcu \
  ghcr.io/efabless/openlane2:2.3.10 bash -lc '
    magic --version; netgen -batch version 2>&1 | head -1; klayout -b -v | head -1'
```

**Acceptance:** three versions recorded in the report. If any tool is missing,
stop — this is an environment finding, not an LVS failure.

### S1 — prove the deck on a known-good pair (minutes)

The single most important step: a standard cell whose layout and schematic both
exist in the PDK. It isolates "deck + models + tech" from "our design". **Two
halves, because the spike in §6 showed they fail differently:**

**S1a — KLayout deck on the PDK's own fixture.** `libs.tech/klayout/tech/lvs/testing/unit/`
ships matched `layout/*.gds.gz` + `netlist/*.cdl` pairs (e.g. `mos_devices/netlist/nfet_05v0.cdl`)
with the expected verdicts. This is the cleanest proof that the deck runs and
*discriminates*.

```sh
bash c930/asic_gf180mcu/tools/klayout_lvs.sh                     # nfet_05v0, ~20 s of deck time
bash c930/asic_gf180mcu/tools/klayout_lvs_selftest.sh            # 16 assertions, four arms
```

**Acceptance:** `verdict.json` says `match`, and the selftest's three negative
arms say `mismatch`/setup error. **S1a is green as of 2026-10-17** — evidence and the
settled deck defect in §6 — so the deck is not the problem and every later failure
is ours.

**S1b — magic + netgen on a std cell.** A cell whose GDS, magic view and CDL all
exist (`gf180mcu_fd_sc_mcu7t5v0__inv_1` is the spike's choice):

```sh
CELL=gf180mcu_fd_sc_mcu7t5v0__inv_1
P=/work/c930/asic_gf180mcu/pdk/share/pdk/gf180mcuA/libs.ref/gf180mcu_fd_sc_mcu7t5v0

MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/work" -w /work/c930/asic_gf180mcu \
  ghcr.io/efabless/openlane2:2.3.10 bash -lc "
    cd /tmp && printf '%s\n' \
      'addpath $P/mag' \
      'gds read $P/gds/$CELL.gds' \
      'load $CELL' \
      'extract' 'ext2spice lvs' 'ext2spice' 'quit' \
      | magic -dnull -noconsole -rcfile libs.tech/magic/gf180mcuA.magicrc

    netgen -batch lvs \"/tmp/$CELL.spice $CELL\" \"$P/cdl/gf180mcu_fd_sc_mcu7t5v0.cdl $CELL\" \
      libs.tech/netgen/gf180mcuA_setup.tcl"
```

**Acceptance:** netgen prints *Circuits match uniquely*. **Failure triage:**
if it says *placeholder cell* / *not found*, the library path or the CDL top
name is wrong — fix that before touching our design, because every later
failure would be ambiguous. **S1b is blocked today** — see §6: the extracted
netlist instantiates `nfet_05v0`/`pfet_05v0`, and netgen has no definition for
them, so it compares placeholders and reports a mismatch that says nothing about
the layout.

### S2 — our core (hours; the first real answer)

**The netlist has to become SPICE first.** KLayout reads a CDL/SPICE schematic,
and our artifact is Verilog; converting it is a step in its own right
(`yosys read_verilog <netlist>; write_spice` leaves the 34 library cells as
subcircuit calls, which the PDK's library CDL defines). Check the conversion
before trusting it: the cell instance count must be 53,745 and the 34 cell types
must all resolve. Then the deck:

```sh
klayout -b -r libs.tech/klayout/tech/lvs/gf180mcu.lvs \
  -rd thr=<cores> -rd run_mode=deep -rd variant=C ... \
  -rd input=<gds> -rd topcell=grx930_test_chip -rd schematic=<converted.cdl> \
  -rd report=<out.lvsdb> -rd target_netlist=<out.cir>
```

bypassing `run_lvs.py` (it needs `docopt`, absent from the image) and with the
`pmap` shim §6 calls for. The **second** run is magic+netgen on the same pair,
and it is the one that gives an extraction-time and peak-memory number (KLayout's
runtime is not a guide to magic's). It only counts once S1b is green:

```sh
CELL=grx930_test_chip
GDS=/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds
V=/work/c930/asic_gf180mcu/build/grx930_test_chip_routed.v
OUT=/work/c930/asic_gf180mcu/build/lvs   # mkdir first
```

1. **extract** — `magic -dnull -noconsole -rcfile libs.tech/magic/gf180mcuA.magicrc`
   with `gds read $GDS`, `load $CELL`, `extract all`, `ext2spice lvs`,
   `ext2spice hierarchy on`, writing `$OUT/$CELL.spice`. Record wall time and
   peak RSS; on this box that is the difference between "workable" and "needs
   the flow server".
2. **compare** — `netgen -batch lvs "$OUT/$CELL.spice $CELL" "$V $CELL"
   libs.tech/netgen/gf180mcuA_setup.tcl`, with the library CDL loaded so the
   Verilog side is device-level too.
3. **keep the report** — `$OUT/lvs.rpt` (netgen's own), the extracted SPICE, the
   compare log, and the two file hashes, under
   `Claude outputs/evidence_lvs/` so the claim survives the box.

**Acceptance:** the deck's own report says the netlists match (and netgen prints
*Circuits match uniquely* when the second engine runs), with device counts
plausible against 53,745 instances and every cell type resolved. **Expected non-failures to triage, in
order:** power/ground net naming (`VDD`/`VSS` vs `VPWR`/`VGND`), a `well`/substrate
mismatch, and — if the GDS and netlist are from different revisions — real
topology differences. Distinguish the third from the first two by checking a
single module first: extract `u_core.u_alu` (or any small sub-block) and compare
just that, which also gives an extraction-time estimate for the full chip.

**S2 status (2026-10-18): the artifact has been rebuilt; its cells now LVS.**
`wafer_space_submission/grx930_test_chip_final.gds` is left exactly as it was submitted — it is
the evidence — and `tools/lvs_chip/stream_out.py` writes the file the flow should have written:
`build/lvs_chip/stream_out.gds`, 59.5 MB, built from the DEF's 53,745 `COMPONENTS` (all on the
row grid, all inside the die), the PDK library's 34 used cells, the routing the die already had,
and the PDK's layer numbers. `tools/lvs_chip/stream_check.py` measures it: device layers 5/5,
metal 9/9, labels 2/2, 34/34 cells carrying the library's device layers, 53,745/53,745 placements
at the DEF position with the DEF orientation, and every routing layer identical to the artifact's
(34/0 32,814; 36/0 354,166; 42/0 100,761; 46/0 12,279; 81/0 1,302 — all top-cell-owned, because
the library cells legitimately add metal of their own).

`build/lvs_chip_cell_check.sh` is the fast half of S2 and it runs in seconds: it cuts a cell out of
the file and runs the same deck against the same library netlist. On the repaired stream the
`clkinv_1`, `nand2_1` and `dffq_1` layouts extract 2, 4 and 24 transistors — exactly the counts in
the CDL, with the library's W/L (pfet 1.22/0.5, nfet 0.48/0.6 on the inverter). With `--old` the
same command on the shipped artifact extracts **no transistor cards at all** from all three. The
port comparison is skipped in that check (`--no-port-check`) and the reason is measured rather than
assumed: a standard cell drawn alone has no body-terminal labels, so the deck lists layout
`VSS VDD I ZN SUB` against schematic `I ZN VDD VNW VPW VSS`; the chip CDL binds `VNW`/`VPW` to the
rails, and the chip run is where that binding is judged.

The chip run itself is `build/lvs_chip_check.sh` → `build/lvs_chip_collect.sh`, deck switches
`run_mode=tiling metal_level=5LM`, output in `build/lvs_chip/run_chip_stream/`. `deep` was killed
at 158 min (exit 137) at 3.6 of 5.8 GiB before it reached device extraction; tiling measures
2.3–4.6 GiB and gets through it, at the cost of walking 500 µm tiles for every device class —
hours, one core. Evidence lands in `Claude outputs/evidence_lvs_chip/chip_stream/`.

**S2 status until 2026-10-17: the artifact could not be LVS'd at all, and the reason was in the file.**
`grx930_test_chip_final.gds` carries no device geometry: its standard cells are LEF abstracts
(pin rectangles, wells, a `SIZE` boundary — `clkinv_1` has the LEF's six Metal1 pin shapes and
nothing on comp, poly2, contact, nplus, pplus or dualgate, where the PDK library GDS for the same
cell has all of them), and its layer numbers are a LEF/DEF index scheme (`Metal1 = 5/0` …
`Metal5 = 13/0`, Pwell 1, Nwell 2) rather than the PDK's (comp 22/0, poly2 30/0, contact 33/0,
metal1 34/0, via1 35/0 … metal5 81/0). The deck therefore reads
`Total no. of polygons in the design is 0` from it — see `Claude outputs/evidence_lvs_chip/`,
where the die's numbering is derived from the DEF's own `VIAS` definitions (the via cells' cut
arrays of 9 and 8 are the DEF's `ROWCOL 3 3` and `4 2`) instead of being taken from
`wafer_space_submission/verify_layers.py`, which asserts a map that is off by one from Metal1
onward. That paragraph is kept because it is what the tree believed until the stream-out was
rebuilt; `tools/lvs_chip/reconstruct_die.py` reproduced the artifact's placements, which are the
ones that are wrong (30,130 of 53,745, and every `FS` cell one row high), so it is superseded by
`tools/lvs_chip/stream_out.py`.

**S2 status (2026-10-18), the deck run:** the chip run stopped twice inside the deck's resistor
classes, and the reason is in the deck's own load report — `res_mk` 0, `resistor` 0, `sab` 0,
`cap_mk` 0, `mos_cap_mk` 0, `efuse_mk` 0 polygons on this die. A class whose body region is empty
cannot produce a device, yet in `run_mode=tiling` each one still walks the contacts of all 88
tiles: measured gaps of 6, **223** and **61** minutes between one call and the next in
`build/lvs_chip/run_chip_stream_attempt1/klayout.log`, and **6 h 04 min** in
`PPOLYF_U_DW_1K_6p0_dw` in the run that was stopped at 21:16 (6 h CPU, one core, 4.7 GiB).
`build/lvs_chip_prune_deck.sh` generates a deck copy whose extractions return early when the body
has no polygons and log the zero; on this die that skips 34 of 151 calls (all resistor classes plus
the eFuse, no MOS), and extraction then finishes in **12 minutes**. `build/lvs_chip_check.sh
--deck build/lvs_chip/deck_pruned/gf180mcu.lvs` is the run to use; the unmodified deck is not a
ten-minute job on this die and is not a hang.

**S2 status (2026-10-19), the cells: 34 of 34 match.** `build/lvs_chip_cell_check.sh` with every
cell the netlist uses (`--cells "$(cat build/lvs_chip/all_cells.txt)"`) cuts each one out of
`build/lvs_chip/stream_out.gds` and compares it against its library CDL subcircuit through the same
deck: `LVS-CELL: PASS`, 34 `verdict MATCH` (`build/lvs_chip/all_cells_check.log`). Three of them were
the first evidence; all of them are the die's whole standard-cell population, so what the chip run
owes is the top-level connectivity between them and nothing inside them.

**S2 status (2026-10-19), the top level: the wall is `align`, and it is now bounded rather than
inferred.** Two earlier runs were reported as "stuck in align" from source order, because the marker
the probe deck printed through the deck's logger never reached the log — the last line in both was
the comparison banner. `build/lvs_chip_probe_deck.sh` now inserts a `probe()` that writes and flushes
its own file, and in a deep run of the pruned deck the record reads `22:46:09 comparison section`,
`22:46:09 before align`, then nothing for the 13 minutes the run was left alive; the run that was
left alone at the vendor defaults spent **5 h 40 min** in that statement. The engine's own knobs are
reachable (KLayout 0.29.4, `LVS::LVSEngine`): `max_vertex_count` = 16, setters
`max_branch_complexity(n)` and `max_depth(n)`, and `threads=`, which is a *different* property from
the tiler's `threads(n)` — the pruned deck now sets both. Two consequences are already wired:
`build/lvs_chip_check.sh --threads N` reaches the comparison, and the probe deck dumps the extracted
netlist at the comparison banner and returns there when `net_only` is set, because the deck's own
`NET_ONLY` return sits after `align`. `build/lvs_chip/probe/align_bench.rb` and `align_sweep.sh` time
the comparer on that netlist pair offline, which is where the bounds are being measured.

**S2 status (2026-10-20), the top level: answered, and the deck's own verdict is the part still open.**
The netter was given a leash long enough to settle the question: a `tiling` net-only run of the pruned
probe deck reached the comparison banner in 10 min and then spent **9 h 13 min** in `netlist` with the
cgroup's `usage_usec` advancing 17.29 s per 15.3 s of wall and `VmRSS` flat at 4.5 GiB of the 5.8 GiB
the container is allowed -- computing, one core, not deadlocked, not finishing. It was stopped, and a
second container could not even start (`OSError: [Errno 12] Cannot allocate memory` from CPython's
import machinery) while it held the box. So `deep` (30 min, no line after `before align`) and `tiling`
(9 h 13 min) both fail on the same statement, and it is the netter, not the comparer.

`tools/lvs_chip/net_compare.py` answers what the netter was being asked, from the two netlists that
already exist: **the routed DEF and the CDL, compared as a multiset of pin sets.** Names cannot make it
pass -- the DEF's nets are `_00000_`, the CDL's are `u_cpu....o_pipe_out[0]` -- and the outcome is
`NET-COMPARE: MATCH`: 53,745 instances on both sides, 34 cell kinds, 53,751 signal nets and **203,400
pins** each, every instance's pins complete against its cell's declared ports, in **5.0 s** for 83 MB
of input. Power travels beside it: the DEF wildcards VDD/VSS over all 53,745 instances and leaves the
wells unrouted, the CDL binds VNW/VPW the way the deck's `connect_global` expects. Evidence:
`Claude outputs/evidence_lvs_chip/chip_stream/net_compare.{json,txt}`. It is not vacuous: its first two
runs were wrong (a wrapped pin list cost 61,562 pins; port case doubled every port) and its own
completeness check caught both; on a CDL with one pin moved off the 14,496-pin clock net it names that
pin and returns 1; and `bash build/lvs_chip_net_compare_selftest.sh` holds ten fixtures -- wrapping,
`ROUTED` coordinates that look like pins, a merged net, a dangling port, a missing power wildcard --
with no docker, no PDK and no layout. What it does not cover is geometry: whether the streamed GDS
carries that routing is `stream_check.py`'s and the deck's question, so **S2 now reads: cells 34/34
MATCH by the deck, top-level connectivity MATCH by the DEF, and the deck's own flat verdict on the
streamed layout still CANNOT-RUN -- the netter, measured at 9 h 13 min without returning.** The next
lever is not patience: it is the netter's `max_vertex_count` (16) and the per-layer polygon counts,
because quadratic behaviour in substrate-sized polygons would look exactly like this.

**Two measurements since then close off that guess and name a different lever (2026-10-20).**
`build/lvs_chip/probe/align_bench.rb` compares the chip CDL against itself -- 35 circuits, 370
primitive devices, 53,745 subcircuits -- in **50.5 s**, capped at 700 MB so it could not disturb the
live run. The comparer is therefore not the cost, and neither can be its bounds:
`max_branch_complexity` and `max_depth` only bound the comparer. Nor is any polygon substrate-sized --
the worst vertex count anywhere in `stream_out.gds` is **32** (`Claude outputs/stream_out_fix.md` §4e),
so `max_vertex_count` = 16 has little left to bound. What remains is breadth: 1.35 M shapes on `41/0`,
1.17 M on `33/0`, 742 k on `34/0`, 744 k on `36/0`, all of which the netter must union into one graph.
Per-layer `merge` before netting is the lever that reduces that without changing connectivity, since
connectivity is overlap, not shape identity. The argv evidence that the aligner is never reached in a
`net_only` run, and these two numbers, are recorded in `Claude outputs/stream_out_fix.md` §4f.

The deep run has since closed that line negatively: it reached the comparison section at 12:43:40Z,
was stopped by its own deadline at 18:30:39Z, wrote no netlist, and exited 137 with `oom=false` -- so
`deep` is another configuration that does not return, and the netter is the bound rather than the
box.

**The merge-before-netting experiment ran, and the answer is no (2026-10-21).** It also found a real
bug on the way: `stream_out.py` was inserting via instances through the integer `CellInstArray`
overload, so all 644,699 via placements landed at 1/1000 of their coordinates -- every via layer of
the streamed die was a 3 x 5 um pile. That pile is what made `Region#merged()` appear unable to finish
(§4g of `Claude outputs/stream_out_fix.md`). With the transform converted through the dbu, the merge
is cheap and provable: 6,681,399 -> 4,346,840 polygons and 31.0 M -> 22.6 M vertices in **149 s**,
XOR-identical on 18 of 27 layers and area-bounded on the 9 routing layers.

The netter does not care. Two flat layouts, same deck, same switches, same thread count, 90-minute
cap: merged (5,840,359 polygons as the deck derives them) spent **78.6 min inside `netlist`** and was
stopped with no netlist; the flat unmerged control (7,466,637) was still inside `netlist` at 32.9 min
when the Docker VM died. What the merge does buy is the read/extract half: **26.5 min -> 10.2 min**.
The reason the netter does not move is measured: 63 % of what it is given is vias and contacts, which
are disjoint and merge cannot touch, and the polygons that dominate a sweep are the die-spanning
rails, which were already there before merging (1,301 shapes wider than 1 mm on `81/0`, 261 taller
than 1 mm on `46/0`) and remain after it. The lever is closed; `build/lvs_chip/net_arm.sh` is the
harness that closes it, and §4h of `Claude outputs/stream_out_fix.md` carries the numbers.

The two horizons became wall times on a tile (2026-10-21). `tools/lvs_chip/crop_tile.py` cuts a window
out of a flat layout while keeping the layer table and the top-level shapes (not `clip_into`, which
drops both), and the netter returns on it: **41 s** of `netlist` on a 1 mm window (1,049,143 objects),
**150-207 s** on 1.5 mm (2,052,787), against 78.6 min that never returned on the die. The ratio is
**1.29x at 1 mm** -- merged 41 s twice, flat 54 s and 52 s -- and **nothing detectable at 1.5 mm**,
where merged ran 150/207 s and flat 178/197 s. The tile also settles a question the die could not
answer: its XOR is empty on every layer the crop carries (23 entries, 19 with shapes), routing
included, where the die could only prove 18. And it prices the one explanation left standing. A strip 320 um wide and the die's full height
(5,119.885 um) keeps the vertical rails at **5.099 mm**, the same length they have on the die -- 22 of
them, over 64 % more area than the 1 mm square -- and nets in **36-45 s** against that square's
41 s/41 s. The mirror window is cut full-width (3,929.8 um) and 650 um tall so `81/0` keeps its die
length -- **3.910 mm**, 166 of them, 991,731 objects, 1 % fewer than the vertical strip -- and nets in
**41-62 s**: no extent penalty in either direction. So net *extent* is not what the die pays for, and
the neighbouring idea that chip-wide nets
are the cost has no measurement left. What the four windows do show is a steep cost in object count
with an exponent the spread does not identify (1.9 to 4.1 depending on the pair of points), which
places the die's >78 min inside the range a tile can produce rather than 4x above it. §4i and §4j of
`Claude outputs/stream_out_fix.md`.

**If S2 matches:** we own a proven LVS pipeline and a stated fact about the
September artifact. If it mismatches with a small diff, that is the most
informative result available today (it is a stale-pair finding, and the
pipeline is still proven). If it cannot even extract, the tech files are the
problem and S3 is pointless until they are fixed.

### S3 — the wrapper artifact (`tpl02`), once it is here

The template GDS is the artifact the real submission inherits: pad ring, seal
ring, ID cells, PDK filler. It needs the IO and SRAM models, and the seal ring
will contribute dummy devices:

* LVS the **core** hierarchical cell first, then the top.
* Expect the seal ring's devices to appear on the layout side only; either
  exclude its cells in the deck or record them as an accepted difference —
  never by deleting geometry from the GDS.
* This is the run that decides whether the submission's wrapper can pass LVS
  at all, so it matters more than S2's answer about a void artifact.

### S4 — the real die, and the gate

1. In the flow: `KLAYOUT_LVS_SCRIPT` is already wired
   (`libs.tech/librelane/config.tcl:177`), and the readiness note records
   `ERROR_ON_KLAYOUT_LVS` true on the live run — so the first sign-off run will
   produce an LVS verdict whether or not this plan runs. Keep its report.
2. Independently: magic+netgen on the streamed GDS, as the second opinion.
3. **The gate is built and wired** (`build/lvs_check.sh`, table row
   `lvs-fixture`). It judges a verdict report with three statuses, not two —
   **0** pass, **1** mismatch (devices, ports with the missing names printed, or
   a report about *different* inputs than the ones on disk), **2** cannot-run (no
   report, unreadable report, a missing field, or a port check that was skipped).
   `chip_gates.sh` shows that status in its failure row and in the gate's own log,
   so "no verdict" and "bad verdict" stay distinguishable in a summary somebody
   reads months later. Default report: `build/lvs/lvs_fixtures_verdict.json`, the
   committed **fixture family** (51 fixtures over MOSFETs, resistors, MIM caps, BJTs,
   diodes and MOS caps,
   the list is `build/lvs_fixtures.tsv`, §6), judged against the on-disk inputs by
   sha256 whenever the PDK install is present. A chip run is the same gate in its live mode:
   `bash build/lvs_check.sh --live --layout <gds> --netlist <cdl>`. Its own test
   is `bash build/lvs_check_selftest.sh` (15 assertions, no docker, no PDK).

## 4. Rules this plan holds itself to

* **No green without a report.** The deliverable of every stage is a netgen
  report or a KLayout database, kept in the repo's evidence directory.
* **Extraction failure is not an LVS result.** If magic cannot read the GDS or
  the models are not found, the stage is *blocked*, and says so.
* **A mismatch is a finding.** It gets triaged and written down; it is not a
  reason to change the netlist until the two sides agree.
* **Pin the inputs, and keep re-checking the pin.** Record the GDS and netlist
  hashes with every result; `grx930_test_chip_final.gds` is not reproducible from
  the tree today, so the hash is the identity. The fixture evidence goes further,
  because its inputs come from a repository this tree does not track: it names the
  PDK commit it came from (`355b9ee6b6f6`, whose deck and fixture hash to exactly
  what the report records), `build/lvs_fetch_pdk_subset.sh` re-fetches that commit
  and refuses to continue on any disagreement, and the `LVS evidence` workflow
  re-runs the harness against it -- weekly and whenever the LVS files change -- to
  answer one question: *is the committed verdict still what the harness produces?*
  A stale report fails that run instead of ageing quietly behind a green gate.

## 5. Cost, honestly

| stage | this box | notes |
|---|---|---|
| S0 | seconds | one container start |
| S1 | minutes | small cell; proves the deck |
| S2 extraction | hours, unmeasured | 77 MB GDS, 53 k instances; measure on a sub-block first |
| S2 compare | minutes to an hour | netgen on ~1 M devices |
| S3 | hours | plus IO/SRAM model wiring |
| S4 | falls out of the flow | the gate is a day's work once S2/S3 are trustworthy |

## 6. What the first spike already showed (2026-10-17)

Run to test the plan's assumptions, not to claim a result. Everything below is a
measured line from this box.

**The engine works.**

* **S0 passes.** The pinned image carries `magic`, `netgen` (1.5.278), `klayout`,
  `openroad`, `yosys`; `libs.tech/magic` and `libs.tech/netgen` are where the
  rcfile and setup expect them.
* **Magic extraction works.** `gf180mcu_fd_sc_mcu7t5v0__inv_1.gds` → SPICE with
  **2 devices** (`nfet_05v0` w=0.82u, `pfet_05v0` w=1.22u), 14 nets, so tech,
  `addpath` and `ext2spice` all function.
* **Netgen reads our design netlist.** On `build/grx930_test_chip_routed.v` it
  parsed the top module and placeholdered the 34 library modules. The Verilog
  path is not a blocker.
* **The KLayout deck runs end to end**: it extracted, wrote a 40 KB layout
  netlist and a 1.4 MB `.lvsdb` on the PDK's own device fixture, and now reports
  a match on it (§ "S1a is green" below). It needs four things this environment
  does not give it for free (below).

**Four defects between the tooling and a verdict** — each one costs minutes to
work around, and every one must be in the harness, not typed by hand:

1. **`pmap` is absent from the image.** The deck's logger calls it for a memory
   line, gets an empty string, and dies as `undefined method 'strip' for nil`
   before reading any layout. A one-line `pmap` shim on `PATH` clears it.
2. **The PDK copy under `pdk/share/pdk/.../lvs/testing` is binary-corrupted** —
   `nfet_05v0.gds.gz` starts `1f ef bf bd` (UTF-8 replacement characters), not
   `1f 8b`. The `libs.tech/...` copy is valid gzip. Use the `libs.tech` tree for
   fixtures; the `pdk/` tree cannot be trusted for binary files.
3. **The fixture's top cell is not the file name.** It is
   `sample_nfet_05v0` in both the layout and the CDL; `-rd topcell=nfet_05v0`
   fails with *cell name not found*. Read the top cell, do not assume it.
4. **The deck's port check has never run, in any copy** (settled 2026-10-17; the
   spike's first reading of this — "a version skew between deck and runner" — was
   wrong, and so was its claim that the `check_ports=false` mismatch was caused by
   ports).

   The comparison section ends `result &= flag_missing_ports if CHECK_PORTS`, and
   `flag_missing_ports` is assigned *nowhere*: not in this tree's deck
   (sha256 `00019ed0…`), not in any `rule_decks/*.lvs` beside it, and not at upstream
   `main` of `fossi-foundation/globalfoundries-pdk-libs-gf180mcu_fd_pv` — commits
   9ba05b0 ("implement flag_missing_ports") and 355b9ee ("do not use shortcut logic
   for flag_missing_ports", both 2026-07-17) add the reference without the
   definition. The 13 GB `gf180mcu-pdk` image ships this exact deck (same sha256),
   so there is no matching pair to go and find.

   `CHECK_PORTS` defaults to **true**, and `run_lvs.py` has no `--check_ports`
   (`grep -c check_ports run_lvs.py` → 0; `top_lvl_pins` appears five times), so the
   PDK's documented path dies with `undefined local variable 'flag_missing_ports'`
   on every design. The check has never executed; it is not a setting we got wrong.

   The spike's old mismatch with `check_ports=false` had a different cause:
   `combine` defaults to false, which leaves every MOSFET finger a separate device.
   With `combine=true` — the PDK's own per-device setting for `nfet_05v0` in
   `testing/unit/mos_devices/config/default.yaml` — the pair matches.

**S1b's blocker, precisely.** The extracted inverter instantiates
`nfet_05v0`/`pfet_05v0`; netgen has no definition for them (`Call to undefined
subcircuit … Creating placeholder cell`, `Unable to permute model nfet_05v0 pins
1, 3`), so the compare is placeholder-against-placeholder and its verdict is
meaningless. This PDK install has no ngspice model directory
(`libs.tech/` = `irsim klayout librelane magic netgen`) and
`libs.ref/gf180mcu_fd_pr/` has only `gds mag maglef`. The primitive `.cdl`
definitions live in the KLayout LVS fixtures
(`lvs/testing/unit/mos_devices/netlist/*.cdl`), and OL2's own LVS step is
`netgen -batch source` over a generated script (`openlane/steps/netgen.py`), not
a bare `lvs` call.

**So the order changes.** KLayout is the primary engine, not the second
opinion: it needs no device-model wiring, its extraction already works, and the
only thing between it and a trustworthy verdict is a matched deck/runner pair.
Magic+netgen comes after S1a is green, using OL2's generated script as the
reference implementation.

**S1a is green (2026-10-17) — the first LVS verdict in this repo**

`bash c930/asic_gf180mcu/tools/klayout_lvs.sh` on the PDK's own `nfet_05v0` fixture:

| | |
|---|---|
| device comparison | **match** — `combine=true`; 99 extracted vs 104 schematic instances (combined fingers, not a discrepancy) |
| port comparison | **pass** — 295 schematic ports, 295 layout pins, none missing (our check; the deck's is dead) |
| deck runtime | 20.96 s |
| verdict | **MATCH**, exit 0 |

A second fixture, `pfet_05v0`, also matches (`--implicit-connect`, the switch its own PDK config
asks for; with `combine` alone it does not, and that is a deck setting, not a layout defect).

Evidence in `Claude outputs/evidence_lvs_fixture/` — `verdict.json`, the deck log with its
`INFO : Congratulations! Netlists match.` line, the extracted netlist, the `.lvsdb`, and a
README. The green is fenced by four arms of `tools/klayout_lvs_selftest.sh` (16 assertions):
deleting one MOSFET makes it *mismatch*; renaming one top-level port makes the **ports** fail
while the devices still match; a missing layout exits **2** and writes no verdict.

What that green is *not*: it is the deck plus the tooling on a device fixture. It says nothing
about the September GDS, the routed netlist or the wrapper, and the port check is ours — which is
why `verdict.json` carries `"deck_variable_defined": false`. The report is committed as
`build/lvs/lvs_fixtures_verdict.json` and judged on every gate run by `build/lvs_check.sh`
(§ S4 item 3); a green there can only come from evidence whose hashes match the inputs on disk.

**Widened to a family, then to six (same day).** One fixture proves the deck; it does not prove the
other kinds of device the deck extracts. `build/lvs_fixtures.tsv` now names 51 fixtures over six
families: four MOSFETs (including a deep-nwell one), seven resistors (diffusion, poly, well,
top-metal, two non-default `poly_res`), three MIM capacitors (A/3LM, B/5LM, B/6LM), and the whole of
`bjt_devices` (10), `diode_devices` (15) and `moscap_devices` (12) — for those three, every fixture
the PDK ships, so a fixture added upstream is a diff rather than a silent omission. Each runs with
the switches the PDK's own per-fixture config asks for, since `combine`, `implicit_connect`,
`consider_dn_dw_features`, `poly_res`, `metal_top`, `metal_level` and `mim_cap` each decide a
different family's extraction — and the three added families are where that stops being a formality:
7 of the 15 diodes and 4 of the 12 MOS caps carry a non-default switch at all, and inside a family
it is not uniform: four of the diodes and four of the MOS caps need `consider_dn_dw_features`
(without it their DN/DW tubs are not part of the device), the two `pw2dw` diodes need
`implicit_connect` (their anode wells never join otherwise), and the Schottky diode and the smallest
NPN need `combine`. Every one of those 51 switch sets is what the pin's
`testing/unit/<category>/config/default.yaml` says for that fixture, and that is now asserted rather
than read by eye: `tools/lvs_switch_check.py` compares each line with the config by key and by
value (51 of 51 equal today; 26 lines carry switches, 25 run on the harness defaults), and the
refresh and the CI job run it before the first fixture. A line that disagrees stops the refresh at
exit 1 with the fixture and key named, runs nothing, and survives neither `--update` (which accepts
a stale family, not an unauthorized switch) nor `--only` (which narrows what runs, not what is
checked). A config it cannot parse — a flow mapping, a third level, tab indentation — is
CANNOT-RUN, never agreement, so an upstream dialect change cannot quietly turn the check into
decoration.

That the check can fail is its own test, not an assumption: `build/lvs_switch_check_selftest.sh`
provokes each disagreement on a synthetic pin of the PDK's shape, removes one diode's
`consider_dn_dw_features` from the real manifest (named, exit 1), and drives the refresh on a pin
whose config disagrees — which stops before a fixture runs, creates no output directory, and still
stops under `--update` and `--only`. 21 cases, all green, about a second, no docker. So a green
cannot come from a switch somebody invented, a guard that never fires, or one a reader cannot see.

All 51 come back green (“LVS: PASS family=51 match=51”, 2026-10-17), and the refresh job
re-runs the whole set rather than the one device: `build/lvs_refresh_evidence.sh` runs each manifest
line under docker, judges it with the gate's own judge, aggregates with `tools/lvs_family.py`, and
compares field by field with the committed file — `CURRENT`, or `STALE` naming the fields that
moved. The `pfet` and every resistor and MIM entry are in that loop, so a deck change that breaks
an n-well or a top-metal resistor is caught by the same job that catches an nfet. Measured: a
re-run reproduces the committed aggregate byte for byte, and moving one field
(`fixtures[7].devices.instances_extracted`) makes the comparison answer
`DIFF fixtures[7].devices.instances_extracted`, exit 1, with `--update` the only way to accept it.
`build/lvs_fetch_pdk_subset.sh` ties the pin to all of it: 103 hashes — the deck plus two per
fixture — before the first docker pull.

`--only` is what made that widening affordable: it runs one family's lines and builds the aggregate
from just those, so a family's switches can be worked out without re-running the other 40 fixtures
(the manifest it builds from is kept beside the runs). Measured while adding the three families: one
fixture in ~36 s, and the full 51 in 30 minutes of wall time (14:00:46 to 14:31:19 on this box), all
green on the first full refresh.

**Next actions, in order**

1. S2's verdict on the rebuilt stream-out (`bash build/lvs_chip_check.sh`, then
`bash build/lvs_chip_collect.sh`), which is the closest
   thing to a chip LVS available until the flow streams out real cells; the artifact itself is
   not LVS-able (see the S2 status above).
2. S1b (magic+netgen) stays blocked until this PDK install has device models; its
   placeholder mismatch is not a layout finding.

## 7. What this plan does not prove

That the September artifact is submittable (it is void for reasons LVS cannot
see), or that the real die will pass — only that the deck, the extraction and
the comparison work on our own data, before the die that matters exists. The
pre-check has no LVS stage, so a green LVS here is *our* evidence and has to be
carried in the submission package as such.
