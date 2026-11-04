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
must all resolve. `tools/lvs_chip/mk_chip_cdl.py` is the converter: it refuses a
statement it cannot map to a library cell — a parameter or delay override, a
macro, a second module, a behavioural block — rather than dropping it, and its
header carries the sha256 of the library CDL and of the appended cell
definitions, so an answer is tied to the device sizes it was compared against.
Then the deck:

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
`tools/lvs_chip/stream_out.py`. That last judgement is **reversed below**: the 3.92 um offset on
`FS`/`S` is the box anchor a DEF row needs, the artifact's placement is the legal one, and it is
`stream_out.py` that drops the offset. The artifact is superseded for its LEF-abstract cells, not
for where it put them.

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

**`max_vertex_count` was raised to 64 and the wall did not move (2026-11-01).** Three measurements
decide it. It is reachable from the deck: `build/lvs_chip/probe/vertex_api.lvs` answers
`dsl_default: 16` and readback `64` through `max_vertex_count=`, and the die run logs
`NETTER polygon limit: max_vertex_count=64` at startup, so the switch reaches the engine rather than
being silently ignored. It governs very little of this layout: of the 6,681,399 shapes in
`stream_out.gds`, **65,771 (0.98 %) have more than 16 vertices and none has more than 32**
(`probe/layer_shape_stats.py`; `34/0` holds 59,913 of them at up to 32 vertices, `30/0` 3,919 at 24,
`22/0` 1,939 at 18). And it cannot be the lever for a structural reason: in KLayout 0.29.4
`LayoutToNetlist::set_max_vertex_count` only calls `dss().set_max_vertex_count`, i.e. it controls how
the deep shape store splits polygons above the limit -- connectivity is unaffected.

Then the run. Pruned deck, `tiling`, 8 threads, on the 16-core/30 GB server, with
`-rd max_vertex_count=64` (above every polygon the die has) against the same deck without it. The two
reach the last empty-class skip 8 min 58 s and 9 min 32 s after starting (18:29:53Z and 17:29:47Z) and
neither prints `Starting GF180 LVS comparison section`. The default run has been in that statement
for >2 h; the 64 run was stopped after **82 minutes** there, RSS flat at 4.98 GB and 100-105 % of one
core against the default's 5.23 GB at the same rate. Evidence: `build/lvs_chip/run_vertex/` beside
`run_pruned/`. The knob is now a switch on the generated deck
(`build/lvs_chip_prune_deck.sh` -> `-rd max_vertex_count=<n>`, default the vendor's 16) so the negative
is reproducible rather than a lost one-off, and `DECK_OUT=<dir>` lets a second copy sit beside a
running one.

**The hours are in the comparer, not the netter (2026-11-01, stack sample).** Instead of another timed
run, the live `tiling` process was sampled where it stood: 20 stacks from `gdb` attached on the host
(the container has no `CAP_SYS_PTRACE`; host root does, and `ptrace_scope=1` permits it), through
`build/lvs_chip/probe/sample_stack.gdb`. All 20 land in the same place:
`db::NetlistCompareCore::derive_node_identities`, innermost frame `db::Transition::operator==` (which
calls `db::DeviceClass::equal`). The chain is `NetlistComparer::compare` -> `compare_impl` ->
`compare_circuits` -> `derive_node_identities_for_edges` -> `derive_node_identities_from_node_set` ->
`derive_node_identities_from_singular_match` -> `derive_node_identities`; one earlier sample had
`..._from_ambiguity_group` in place of `..._from_singular_match`. **No sample holds a `db::Netter`
frame.**

So the substrate question is answered independently of timing: `substrate_connections.lvs` was
measured at under a second with the unbuffered probe (the whole pre-banner phase is 13 min 28 s), and
the engine is not in the netter at all. It is deriving net identities from device transitions -- the
comparer's ambiguous-match search, which is what `max_branch_complexity` and `max_depth` bound and
which no core count helps: `NLWP` is 1 with `threads=8`, so 15 of 16 cores idle while one runs the
comparison.

Two readings this corrects. The deck's log cannot bound the phase: `run_pruned/klayout.log` stops at
17:29:47 and never moves while the stack is inside `compare`, because `logger` writes to `$stdout` and
Ruby block-buffers it to a file -- the banner and `align` are past, not missing, so "no banner" means
"nothing flushed since", not "not yet comparing". And the benchmark that had cleared the comparer
(`align_bench.rb`, CDL against itself, 50.5 s) compares a hierarchical netlist to itself; the die
compares a flat layout netlist carrying millions of nets, most with generated names (`_27880_`), all
promoted to top-level pins by `TOP_LVL_PINS`, against the hierarchical CDL. That is the expensive case,
and it is the one the die is in.

The `deep` run prices the same section from the other side: banner 16:48:57Z, verdict 19:25:34Z,
**2 h 36 m 37 s**, with `ERROR : Netlists don't match`. It then spent 53 minutes writing
`extracted.cir` and reached **176,599,826,432 bytes** before `errno=28` filled the disk -- the head of
that file is a single `* pin` line listing every net (first 65 KB kept in
`build/lvs_chip/run_chip_stream/netlist_head.txt`, log beside it). The 176 GB file was deleted to
recover the server; nothing else from that run was lost.

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

**The comparer's own bounds produce a verdict; `max_branch_complexity` is the working knob and
`max_depth` is not (2026-11-01).** `build/lvs_chip/probe/bounds_api.lvs` shows both DSL calls exist
and take exactly one argument, and that the installed comparer carries `max_branch_complexity =
18446744073709551615` (unlimited) and `max_depth = 500`. KLayout 0.29.4's reference says both are
unlimited from 0.27 on, and that they may be reduced "in cases where runtimes need to be limited at
the cost [of] less elaborate matching evaluation". `build/lvs_chip_bounds_test.sh` runs the die on
the pruned deck, tiling, 8 threads, one knob per run. With `max_branch_complexity=1`, the section
runs 21:57:42Z -> 22:04:48Z, **7 min 06 s**, and returns `ERROR : Netlists don't match` (total
1009.938283 s); with `=1000`, 22:46:13Z -> 22:53:19Z, the same **7 min 06 s** and the same verdict
(total 987.376428 s). That identity is the result: the search's variable cost is gone, and what
remains is the deck's own `align`/`make_top_level_pins` work, not the comparer. The unbounded
tiling control (`run_pruned`, same deck and switches) spent **4 h 44 m** in the section without a
verdict and was stopped at 22:14Z; the unbounded deep run returned a mismatch in **2 h 36 m 37 s**.
With `max_depth=1` alone, the compare does not return: it aborts with **`std::bad_alloc in
LayoutVsSchematic::compare`** after ~35 min (clean at 22:27:38, error present by 22:35:59), with the
branch count still unlimited -- a shallow
depth removes the deductions that prune ambiguity, it does not bound the search. So depth is not a
runtime knob for this die; the branch cap is.

The useful value was then bracketed (2026-11-02), one cap per run on the same deck: 1000 -> 7 m 06 s,
3162 -> 7 m 12 s, 10000 -> 7 m 13 s, 11500 -> 7 m 17 s, **12300 -> 7 m 22 s**, every one
`ERROR : Netlists don't match`. Above that the wall returns: 12600 did not return in **20 min**,
12900 in 43, 13335 in 28, 17783 in 24.5, 25119 in 24.5, 31623 in **66**, and 1000000 in 40 (100000 and
316227 were stopped at 12 min once the trend was clear). So **12300 is the largest cap that returns a
verdict**, and the cliff sits between it and 12600 -- the first ambiguity group carries about 1.24e4
options, and below it the search aborts after a fixed ~7.4 min of `align`/pin work. No cap produced a
match: every returning run says `Netlists don't match`, the same word as the unbounded deep run's
2 h 36 m verdict, so the bound did not turn a match into a mismatch -- it only cut the wait, and the
verdict it gives is still the bound-limited one. Logs: `build/lvs_chip/evidence_bounds/<cap>/`.

**What the 12,300 report actually contains (2026-11-02).** `build/lvs_chip/probe/lvsdb_xref.rb` reads
the lvsdb and partitions every pair by status. `align` flattened both sides to one circuit pair
(`grx930_test_chip`), and the compare paired **nothing**: 0 of 819,808 device pairs (both sides
counted) and 0 of 472,950 net pairs have both sides, the circuit pair is `NoMatch`, and only the pins
are reported `Match` (37,738 entries, 9 of them on the schematic side). So the report holds no
item-level mismatch to inspect -- the cap stopped the
top-level match before it established a mapping, and that part of the verdict is bound-induced.

The two inputs already differ in size, which is not. The layout netlist carries **128,798 devices**
(`pfet_05v0` 84,476, `nfet_05v0` 44,322) against the schematic's **691,010** (`NFET_05V0` 345,505,
`PFET_05V0` 345,505), and 102,108 layout nets in the cross-reference (of 409,406 in the netlist)
against 370,842. Both are after the
deck's `combine=true`; `simplify`, `purge` and `purge_nets` default to false. So the layout side
supplies **18.6 % of the schematic's devices before any matching happens**, and the skew (24.4 % of
PFETs survive, 12.8 % of NFETs) says the loss is not uniform. That is the real defect the report
exposes: not a wrong net pairing, but a layout netlist missing four fifths of its devices, NFETs
worst. Whether extraction or the combine step causes it was measured next, below. Evidence:
`build/lvs_chip/evidence_bounds/12300/xref.txt`.

**The shortfall is extraction's; `combine_devices` accounts for 7.5 % of it (2026-11-02).**
`build/lvs_chip_census.sh` inserts a census around the deck's COMBINE_DEVICE section
and exits before the comparison (no lvsdb, no 176 GB dump). On the die, with the same deck and
switches as the 12300 run (tiling, 8 threads, `metal_level=5LM`, `combine=true`), runset start to
comparison section took **9 min 22 s**:

| stage | layout devices | PFET / NFET | nets | schematic devices |
|---|---:|---:|---:|---:|
| pre-combine | **171,109** | 112,864 / 58,245 | 409,406 | 691,010 |
| post-combine | **128,798** | 84,476 / 44,322 | 409,406 | 691,010 |

The post-combine count is exactly the cross-reference's 128,798, which validates the census. Of the
562,212-device gap, **519,901 (92.5 %) is already missing before `combine_devices` runs** and
42,311 (7.5 %) is what combine removes. The 42,311 is the pass doing its job, not losing data: it
leaves the net count identical and is a **no-op on the schematic** (691,010 before and after), whose
cells are already finger-combined. `klayout_lvs.py` forces `combine=true` for that reason -- KLayout's
extraction emits one device per finger, and a multi-finger cell cannot match without the merge. The
removal is also class-neutral (25.1 % of PFETs, 23.9 % of NFETs), so it does not create the skew: the
extracted netlist is already PFET-heavy at 1.94:1 against the schematic's exact 1:1.

A second run with `--stage pre-align` rules out the aligner. Before `align`, the layout netlist is
already **one flat circuit of 171,109 devices** (0 subcircuits), while the schematic is 35 circuits
and 53,745 subcircuit instances that flatten to 691,010. So extraction itself delivered 3.2 devices
per placed cell against the schematic's 12.9, and `align` had nothing to flatten. That the layout
side is a single circuit even before alignment is why the netlist has no per-cell breakdown to
localise the loss further. Logs: `build/lvs_chip/evidence_census/{die-combine,die-pre-align}/`.
Both counts belong to the mis-anchored stream-out, not to extraction: with the placement anchor
fixed the same census returns **691,010 pre *and* post** (below, 2026-11-02).

**No cell type is short; the loss exists only in the assembled die (2026-11-02).**
`build/lvs_chip_cell_census.sh` cuts each placed type out of `stream_out.gds` (a standard cell is a
leaf cell, so it can be its own top) and runs the same censused deck on it in the die's tiling mode,
then weights the count by the DEF's placements. All **34 placed types over 53,745 placements
(100 % of the population)** extract exactly their CDL's device count, before *and* after
`combine_devices`, which is a no-op on a single cell:

| | devices |
|---|---:|
| sum(placements x extracted), 34/34 types | **691,010** |
| sum(placements x CDL) | 691,010 |
| die, pre-combine | 171,109 |
| die, post-combine | 128,798 |

The biggest types are exact too -- `mux2_1` 12/12 over 14,778 placements, `dffq_1` 24/24 over
12,544 -- so no cell's geometry is responsible. Two controls say the same from the layout side.
`build/lvs_chip/probe/die_geometry_census.py` counts the assembled layout's flattened `comp`,
`poly2` and `nwell` polygons: **167,771 / 368,897 / 53,745**, exactly the placement-weighted sums of
the cell definitions and exactly the deck's own count lines, so every placed cell's active and gate
geometry is in the die. And every cell is exactly 1:1 PFET:NFET (370 devices over the 34
definitions), so the die's 112,864:58,245 -- 32.7 % of PFETs recovered against 16.9 % of NFETs --
cannot be any cell type's ratio. The class-selective loss is produced by the die-level extraction
path itself.

That moves the question from "which cells lose transistors" to "what does the assembled die do that
an isolated cell does not". Evidence: `build/lvs_chip/evidence_cell_census/{cell_census.tsv,
die_geometry_census.txt}`, per-cell logs `build/lvs_chip/evidence_census/cell-*/`.

**Adjacency does not lose the devices; the stream-out's anchor for mirrored cells does
(2026-11-02).** `build/lvs_chip/probe/row_probe.py` builds the neighbour case from one cell
definition -- copies at the LEF pitches (`mux2_1` 7.28 x 3.92 um), so they abut exactly as in a DEF
row -- and the censused deck extracts each layout up to the pre-`align` census:

| synthetic layout | placements | expected | extracted | PFET / NFET |
|---|---:|---:|---:|---:|
| `mux2_1` row, abutting | 256 | 3,072 | **3,072** | 1,536 / 1,536 |
| `mux2_1` row, 1 um gaps | 256 | 3,072 | **3,072** | 1,536 / 1,536 |
| `dffq_1` row, abutting | 128 | 3,072 | **3,072** | 1,536 / 1,536 |
| `mux2_1` grid 16x16, all N | 256 | 3,072 | 1,632 | 1,536 / 96 |
| `mux2_1` grid 16x16, N/FS, raw DEF anchor | 256 | 3,072 | **0** | 0 / 0 |
| `mux2_1` grid 16x16, N/FS, box anchor | 256 | 3,072 | **3,072** | 1,536 / 1,536 |

Horizontal adjacency is harmless, and so is vertical stacking *provided* each mirrored cell is
anchored at its row box (`FS` at `+h`, `S` at `+w,+h`, `FN` at `+w`). Anchored at the raw DEF
position instead -- a mirror about the origin, which is what `tools/lvs_chip/stream_out.py` does
(`Trans(angle, mirror)` with `disp` = the DEF x,y) -- the mirrored grid extracts **zero**, and an
all-N stack, whose opposite wells collide at every row boundary, loses all but one row's NFETs
(**96 of 1,536**). That is the die's signature: class-selective, NFETs first.

The DEF's y is the row bottom and the LEF cell is 3.92 um tall, so the raw anchor puts an `FS` cell
one row low and an `S` cell one row low and one width left. `build/lvs_chip/probe/
def_vs_artifact_placement.py` measures where each file actually puts them, over 300 samples per
orientation: the September artifact anchors `FS` at (0, +3920) dbu in 298 of 300 samples, `S` at
(+width, +3920), `FN` at (+width, 0) and `N` at (0, 0), while
`stream_out.gds` returns (0, 0) for every orientation. The streamed die therefore places **30,097
of its 53,745 standard cells** (FS 23,785, S 3,168, FN 3,144; 56.0 %) one row or one column off,
and their wells and diffusions overlap a neighbour. That, not extraction and not the cells, is what
leaves 171,109 devices.

Evidence: `build/lvs_chip/evidence_census/row-*/census.txt`, layouts and logs in
`build/lvs_chip/row_census/`.

**The fix is in the placer, and it closes the gap (2026-11-02).** `tools/lvs_chip/stream_out.py` now
anchors each oriented instance at its box corner, using the cell's layer 0/0 boundary (`FS` +h, `S`
+w,+h, `FN` +w) rather than the GDS bbox, and refuses to write a layout whose row boxes overlap.
The re-stream moved **30,097 of 53,745** copies (FN 3,144, FS 23,785, S 3,168), and the new file
carries the artifact's offsets (FS (0, +3920) dbu in 297 of 300 samples, S (+width, +3920), FN
(+width, 0), N (0, 0)). The die census on it returns:

| stage | layout devices | PFET / NFET | nets | schematic |
|---|---:|---:|---:|---:|
| pre-combine | **691,010** | 345,505 / 345,505 | 424,912 | 691,010 |
| post-combine | **691,010** | 345,505 / 345,505 | 424,912 | 691,010 |

so the placement anchor was the whole deficit -- 171,109 to 691,010 -- and the class skew is gone.
`combine_devices` now removes nothing on the die either, which says the 42,311 it removed from the
broken layout were devices the overlapping rows had created, not finger copies. `build/lvs_chip/
stream_out.gds` is the anchored stream; the mis-anchored file is kept as
`stream_out_pre_anchor.gds`. Evidence: `build/lvs_chip/evidence_census/die-anchored/`.
The full LVS comparison against the CDL has now been run on it (below); it is still a mismatch,
and the net-level probe that follows says the remaining gap is the netlist's connectivity, not the
comparer's bound.

**The first full comparison on the anchored die is again bound-limited (2026-11-02).**
`build/lvs_chip_bounds_test.sh anchored-b12300 --branch 12300 --threads 8` ran on the anchored
layout (sha256 `a5c59c15...`) with the pruned deck: **27 m 56 s** total, of which the comparison
section is **12 m 28 s** (16:24:12 to 16:36:40), and a 691 MB lvsdb. Verdict: **mismatch**. The
cross-reference now has equal netlists -- 691,010 devices on both sides, 345,505 of each class --
and the comparer paired **9,872 devices (1.4 %)** and 9,246 nets, of which 1,954 device pairs and
6,327 net pairs are `Match`. The rest are single-sided: 681,138 layout-only and 681,138
schematic-only devices. Every itemised example is `layout=(nil)` -- a schematic item with no
layout counterpart, which is the cap stopping the search, not a device whose class or parameters
disagree. The 7,918 both-sided device pairs left unconfirmed are all same-class (4,591
`pfet -> PFET`, 3,327 `nfet -> NFET`), so the report contains no wrong-class device.

One difference is not bound-induced: the layout netlist carries **424,912 nets against the
schematic's 370,842** (+54,070, against 53,745 placed cells) and **82,223 pins against 9**. That is
the lead for a deeper run or a net-level probe; it is not a device-count defect, and at this bound
it cannot be separated from the comparer's ambiguity. Evidence:
`build/lvs_chip/evidence_lvs/anchored-b12300/{verdict.json,klayout.log,xref.txt}`; the 691 MB
lvsdb itself stays on the build server in `build/lvs_chip/anchored-b12300b/`.

**The 54,070-net surplus is classified, and it is not a bound (2026-11-02).** Four probes on the
existing lvsdb, with no new extraction. `build/lvs_chip/probe/lvsdb_netclasses.rb` partitions each
side's nets by `Net#terminal_count` (device terminals, not pins) and by name;
`lvsdb_net_hist.rb` gives the full histogram with the supply nets removed. The two netlists hold
exactly the same terminals -- 2,764,040 on each side -- so nothing is missing or extra; only the
partition differs.

| class | layout | schematic | surplus | kind |
|---|---:|---:|---:|---|
| nets with 0 device terminals | 13,437 | 1 | +13,436 | bookkeeping |
| nets with 1 device terminal | 1,205 | 0 | +1,205 | dangling |
| `VDD` | 14,175 | 1 | +14,174 | real partition |
| `VSS` | 14,160 | 1 | +14,159 | real partition |
| everything else | 381,935 | 370,839 | +11,096 | finer partition |
| **total** | **424,912** | **370,842** | **+54,070** | |

Of that, **14,641 nets (27 %) are bookkeeping**: they have no device terminal at all
(13,435 of the zero-terminal nets are anonymous; the two named ones are a `VDD` and a `VSS` label on
isolated shapes) or exactly one, so they cannot carry a connection. The CDL has one equivalent net,
the unused `i_ext_irq` port.

The other **39,429 are real connectivity, not net-list noise**, and the supply split is exact: the
layout's 14,175 `VDD` nets carry **225,664** terminals and its 14,160 `VSS` nets **220,242** --
the same numbers as the CDL's single `VDD` and `VSS` nets. The comparer is looking at the same pins
in more pieces. `SUB` (the NFET bodies) is one net on both sides, 345,505 terminals; `VNW` (the
PFET bodies, 345,505 in the CDL) has no layout net of that size at all -- the bodies sit on the
separate nwell islands.

Three geometry measurements say where the pieces come from, and none of them is an extractor
artefact:

* the die's `nwell` layer merges into **12,165 islands** (`probe/well_islands.rb`), the same order
  as the `VDD` fragment count (the rails are 7.28 um wide and the nwell 8.14 um, so more metal
  islands than well islands is the expected direction);
* the placement is genuinely scattered: 671 of the DEF's 1,300 rows are used, and one populated row
  (DEF y 4,805,920) has 136 cells in ~86 runs over 1,627 um, so a row's rail is broken every few
  cells rather than running its length;
* no well-tie or fill cell is placed at all -- `filltie`, `decap`, `tiel`, `tieh` and `tap` match
  **0** lines in the DEF -- and the full-width metal5/metal4 grid has no via1 connection down to
  the metal1 rails in the bands probed at a populated row (`probe/pdn_probe.rb`: metal5 131
  shapes, via4 520, via3 14, via2 52, **via1 0**), so at those rows the grid does not reach the
  rails.

So the layout under test has ~14 k separate VDD/VSS rail islands and ~12 k separate wells, and the
PFET bodies are on those wells instead of one `VNW`. That is why 681,138 layout devices and 681,138
schematic devices share only 9,872 pairs: a PFET whose bulk is on a local well cannot be matched to
one whose bulk is on the global `VNW`. Raising `max_branch_complexity` further cannot close this;
the next useful run is one with the rails and wells actually tied (tap/fill cells placed, PDN
stitched to the rails), not another bound. That pass has now been placed and measured, next.

Evidence: `build/lvs_chip/evidence_lvs/anchored-b12300/{netclasses.txt,net_hist.txt,rail_continuity.txt}`;
probes in `build/lvs_chip/probe/{lvsdb_netclasses.rb,lvsdb_net_hist.rb,well_islands.rb,pdn_probe.rb,rail_geometry.rb}`.

**The tap/fill pass was placed and measured: the islands collapse to 522, not to one (2026-11-03).**
`tools/lvs_chip/fill_def.py` tiles the routed DEF's empty sites with `fill_*` and `filltie`, reading
the DEF's own Metal1 routes first. That ordering matters: the first version tiled every empty site,
landed **10,093 rails on routing in 720 nets**, and the census put both supplies on one
1.29 M-terminal net (`evidence_census/die-filled/`, kept as the counter-example). The legal pass
places **94,160 cells** (19,574 `filltie`, the rest `fill_*`) into 525,923 sites, leaves 8,148 sites
blocked by metal1, and re-checks **0 rail/route overlaps** from the written DEF
(`probe/fill_route_short.py`). It changes no device: **691,010** before and after `combine_devices`,
on both sides.

| | unfilled | filled |
|---|---:|---:|
| layout nets | 424,912 | **374,826** |
| surplus over the CDL | 54,070 | **3,984** |
| nwell islands (`probe/well_islands.rb`) | 12,165 | **514** |
| `VDD` nets / terminals | 14,175 / 225,664 | **522 / 520,448** |
| `VSS` nets / terminals | 14,160 / 220,242 | **56 / 353** |
| largest layout net | 345,505 (`SUB`) | **565,670** |

The supply pins did not disappear, they moved. All **345,505** NFET bodies now sit on **one
565,670-terminal net** -- the deck's substrate global, carrying 220,165 terminals besides the bodies
against the CDL's 220,242 `VSS` pins -- and only 56 `VSS` fragments (353 terminals) stay untied. On
the PFET side, 294,784 of the 345,505 bodies are on `VDD`-named nets (520,448 terminals = 225,664
pins + 294,784 bodies) and 50,721 are on nets that carry no supply name at all -- wells the filler
could not tap. The two supplies are still **separate nets**: `VDD` keeps its 522 fragments and
520,448 terminals, and does not appear among the merged net's labels, so this is not the
1.29 M-terminal short of the first attempt. One arithmetic gap is left open: 565,670 + 353 =
566,023 is 276 (0.05 %) above the CDL's `SUB` + `VSS`; the merged net carries hundreds of labels and
`TOP_LVL_PINS` materialises pins for them, which is the likely source, but counts alone do not
settle it and the comparison run is what will.

What does not collapse, and cannot from the filler: `VDD` stays at 522 because the nwell comes in
**one island per N/FS row pair** (671 populated rows; a fill that could tile every site measured
337 = 671/2), the pairs are separated by the `VSS` rail on metal1, and the metal4/metal5 grid has
no via1 down to the rails. `VNW` never exists on the layout side at all, in either die: the PFET
bodies are on nwell nets, so a CDL that keeps `VNW` separate cannot match by more fill -- the
converter now ties `VNW` to `VDD` and `VPW` to `VSS` (next section), and that alone does not pair
them either.

Two costs of this pass that are not LVS: taps go only where a two-site box is clear of metal1, so
the worst cell-to-tap distance is **272.72 um** against the 20.00 um DF.13_LV target, and 4 populated
rows get no tap at all; 6,655 island sites are left empty because a filler there would draw a rail
with no device on it. Closing the latch-up rule needs a tap column the router leaves clear, which is
a PDN change, not a filler change.

Evidence: `build/lvs_chip/evidence_census/{die-filled-metal1,die-filled-metal1-nets,die-filled}/`
(census, deck log, `fill_report.txt`, `well_islands.txt`, `rail_route_check.txt`, and a README with
the DEF/GDS hashes and the three commands).

**The comparison on the filled die is a mismatch with nothing paired (2026-11-03).**
`bash build/lvs_chip_bounds_test.sh filled-b12300 --branch 12300 \
--layout build/lvs_chip/stream_out_filled_metal1.gds --threads 8` ran the same deck, CDL and
switches as `anchored-b12300b`: 1,679 s (28 min), 758 MB lvsdb, device-level (ports skipped, no
netlist dump). Verdict: **mismatch**. The pairing is the finding:

| | anchored (unfilled) | filled |
|---|---:|---:|
| paired nets | 9,246 | **0** |
| paired devices | 9,872 | **0** |
| layout pins / nets | 82,223 / 424,912 | 54,440 / 374,826 |

Zero devices pair on either side (`a-only 691,010` each), so the report localises nothing: it is one
total partition mismatch, not a list of defects. That is the census seen from the comparer's side --
a device pairs only if its nets correspond, and here no NFET body net can (layout: one 565,670-
terminal `VSS`+`SUB` net; CDL: `VSS` 220,242 and `SUB` 345,505, kept apart) and no PFET body net can
(layout: 522 `VDD` fragments plus 50,721 bodies on unnamed wells; CDL: one `VDD` 225,664 and one
`VNW` 345,505). The anchored die paired 9,872 devices under the same deck and the same 12,300 bound,
so the change is the layout's, not the bound's.

Two consequences for the next run. A CDL that ties `VNW` to `VDD` and `VPW` to `VSS` is necessary --
the deck's substrate global is one net, so the schematic has to be one net too -- and it is not
sufficient: the 522 `VDD` islands have no counterpart in a one-net CDL, so the PDN has to join them
first (via1 from the metal4/metal5 grid down to the rails, or a strap that reaches every row pair).
Until then, more fill and other bounds cannot produce a verdict that means anything.

Evidence: `build/lvs_chip/evidence_lvs/filled-b12300/{verdict.json,klayout.log,xref.txt,config,driver.log}`;
the 758 MB lvsdb stays on the build server in `build/lvs_chip/filled-b12300/`.

**Tying the bulks in the CDL is necessary, and it is not enough (2026-11-03).**
`tools/lvs_chip/mk_chip_cdl.py` now maps `VNW`->`VDD` and `VPW`->`VSS` in its `POWER` table, so the
schematic states the partition the die intends instead of one the layout cannot have. Read back with
`build/lvs_chip/probe/cdl_nets.rb`, the new CDL is 370,840 nets: **one `VDD` net with 571,169
terminals, one `VSS` net with 565,747, no `VNW` and no `SUB` net at all**, and the same 691,010
devices (345,505 per class). The appended library block still hashes to `97c45126...`, so the device
sizes come from the same library revision. CDL sha256 `f86a5635...`; the previous file is kept on
the build server as `grx930_test_chip_vnwsub.cdl` (`bf66c757...`) so `filled-b12300` stays
reproducible.

Same command, same 12,300 bound, same GDS, only the CDL changed: `filled-vnwvd-b12300`, **2,265 s
(38 min)**, 735 MB lvsdb, device-level, verdict **mismatch**.

| | filled, old CDL | filled, tied CDL |
|---|---:|---:|
| paired nets | 9,246 | **279** |
| paired devices | 9,872 | **42** |
| run time | 1,679 s | 2,265 s |

Devices do pair now -- 42 of 691,010 -- but the top-level correspondence got worse, not better, and
`probe/supply_pairing.rb` says why: every supply net on both sides is `Mismatch` (a candidate exists,
identity unconfirmed). The layout's 521 nets named `VDD` meet one schematic net of 571,169 (the
candidate the comparer tried was a 2,261-terminal fragment); its 55 nets named `VSS` meet one of
565,747. **A one-to-521 partition cannot be bijected by any bound**, and the two merged hubs spend
the 12,300 branch budget earlier than the four separate supply nets did, which is why fewer signal
nets resolve (279 against 9,246) and the comparison took 21 min instead of 12. That is search
progress, not correctness: the earlier 9,872 pairs were devices matched around a schematic whose
supplies did not correspond to the layout at all. All three both-sided device mismatches in the new
run are PFETs; everything else is unpaired.

The remaining defect therefore has one name, and it is on the layout side: **522 `VDD` islands (521
by name) plus 50,721 PFET bodies on untapped wells, against one schematic net of 571,169 = 520,448
+ 50,721 exactly.** Joining them is a PDN change -- via1 from the metal4/metal5 grid down to the
rails, or a strap reaching every row pair -- and until it exists no CDL, fill pass or bound can
produce a verdict that means anything.

Evidence: `build/lvs_chip/evidence_lvs/filled-vnwvd-b12300/{verdict.json,klayout.log,xref.txt,supply.txt,config,driver.log}`;
the 735 MB lvsdb stays on the build server in `build/lvs_chip/filled-vnwvd-b12300/`.

One hazard the runs also close: the deck always writes an extracted netlist in `_finish`, after the
verdict -- to `target_netlist` when given, otherwise to a default `<topcell>_extracted.cir`. The
die's is the 176 GB file above, and a directory at the path is not a guard: KLayout's writer renamed
it to `extracted.cir.~backup` and wrote 17 GB and 26.7 GB anyway before being stopped.
`build/lvs_chip_prune_deck.sh` now renames both `target_netlist` call sites to a wrapper honouring
`-rd write_netlist=false`, so a comparison-only run never sets a target and the dump never starts
(measured on the clkinv fixture: with the switch no `extracted.cir`, without it the file appears),
and `klayout_lvs.py --no-extracted-netlist` stops the runner naming one either. The 561 MB
`report.lvsdb` is still written after the verdict, so a run stopped during it has the verdict in
`klayout.log` but no `verdict.json`.

**The rails are stitched, the supplies pair, and the residue is the clock (2026-11-03).**
`tools/lvs_chip/pdn_stitch.py` joins every metal1 rail island to the metal3 supply grid with a
via1/metal2/via2 strap on the grid's own 20 um column pitch. Nothing is placed blind: a candidate
is rejected unless its metal2 landing is clear of existing metal2 (the first version tested overlap
and not touching, and silently missed 539 edge-abutting straps), its via1 pad lies inside the
island's own rail band, and its via2 pad inside the target stripe; after writing, the tool re-reads
the GDS and refuses unless merged metal2 components grew by exactly the number of straps placed
(162,774 -> 163,796, +1,022 = 968 `VDD` + 54 `VSS`) and every pad is still on its own net. Five
islands (3 `VDD`, 2 `VSS`) have no stripe inside the clearance and are left alone.

Census and comparison on `stream_out_filled_stitched.gds` (same deck, CDL, switches and 12,300
bound as `filled-vnwvd-b12300`):

| | filled, tied CDL | filled + stitched |
|---|---:|---:|
| `VDD` nets / terminals | 521 / 520,448 | **3 / 5** |
| `VSS` nets / terminals | 55 / 353 | **2 / 4** |
| layout nets | 374,826 | **374,220** |
| devices pre / post-combine | 691,010 / 691,010 | **691,010 / 691,010** |
| paired nets | 279 | **369,884** |
| paired devices | 42 | **659,416** (95.4 %) |
| both-sided device non-matches | 3 | **328** |
| run time | 2,265 s | **1,756 s** |

The verdict is still **mismatch**, but for the first time the supplies correspond: `VDD` is one net
of 600,232 terminals against the schematic's 571,169, and `VSS` is one of 565,670 against 565,747.
659,088 device pairs resolve `Match`, 31,594 on each side stay single-sided, 63,516 devices sit in
ambiguous pairs and 328 both-sided pairs disagree (166 `pfet -> PFET`, 162 `nfet -> NFET`). The
comparison section also drops from 21 min to 13 min, because the merged hubs no longer spend the
branch budget on a partition that cannot be bijected.

**The remaining VDD difference is the clock, and the short predates the strap.** A terminal-by-
terminal walk of the layout's largest net (`probe/net_composition.rb`) gives **345,255 PFET bodies
+ 225,719 PFET source/drain + 29,204 gate terminals + 54 NFET source/drain**; the schematic's `VDD`
is 345,505 bodies + 225,664 source/drain with no gate on it, and its `I_CLK` is 28,988 terminals.
So the die's `VDD` net carries the clock. That was already true before any strap: in the pre-stitch
census the clock net was named `CLK,VDD,i_clk` and carried **29,484** terminals -- 28,988 plus 496,
which is one rail island's worth of cell `VDD` terminals. A `VDD` rail island was therefore already
sitting on the clock net, and the strap is what joined that island to the other 967; it turned a
496-terminal defect into a 29,204-terminal one rather than causing it. Locating that island in the
routed DEF is the next measurement, and it is a routing defect the LVS has now isolated to one
net rather than a partition problem.

**The island is two islands, and both are fill cells placed under the clock's metal1 (2026-11-03).**
A terminal walk of the pre-stitch net (`probe/lvsdb_clk_composition.rb` on
`filled-vnwvd-b12300/report.lvsdb`) splits the 29,484 into 14,494 `nfet_05v0/1` + 14,494
`pfet_05v0/1` gates -- the 28,988 clock loads -- and **301 `pfet_05v0/3` bodies + 122 `/0` + 73 `/2`
source/drains**. Bodies come from a well, so the clock did not meet a rail edge by accident: it met
the supply *pin* that taps the well. `probe/clock_vs_supply_pins.py` rebuilds the clock's metal1
from the routed DEF (14,494 CLK pin rectangles, 556 `( x y ) RECT ( ... )` pin-access shapes, 4,622
centrelines, 22,668 via1 pads at the tech LEF's enclosures) and intersects it with all 617,570
POWER/GROUND pin rectangles: **exactly two contacts, both 135 x 135 dbu (0.0675 um square)**.

| contact | fill cell | rail line | VDD island |
|---|---|---|---|
| (2200.105..2200.240, 1536.805..1536.940) um | `FILL_ROW_388_00081` `fill_2` N at (2199.120,1532.720) | y = 1536.640 | x 2192.960..2210.230 (17.270 um) |
| (1755.465..1755.600, 2242.405..2242.540) um | `FILL_ROW_568_00025` `fill_1` N at (1755.040,2238.320) and `FILL_ROW_569_00032` `fill_2` FS at (1754.480,2242.240) | y = 2242.240 | x 1426.880..1757.750 (330.870 um) |

Both are the same shape: a clock via1's metal1 pad enlargement, DEF `( 4401040 3073840 ) RECT
( -830 -230 0 230 )` and `( 3511760 4485040 ) RECT ( -830 -230 0 230 )`, reaching 415 dbu left of
its via and 230 dbu tall, so it enters the fill site and clips the fill's `VDD` rail at the row
line. The GDS says the same thing without the DEF: at the first site the clock via1 at (2200.520,
1536.920) sits in a metal1 component that is 39.580 x 0.820 um in `stream_out.gds` (the clock's jog
alone) and 39.580 x 2.360 um in `stream_out_filled_metal1.gds`, having swallowed the rail
2199.120..2200.240; at the second the same via1's component grows from 12.700 x 0.820 to 330.870 x
3.980 um.

The island identities are checked by counting the PFETs of the cells whose `VDD` pin abuts each
rail line (`probe/island_bodies.py`, library device counts from the appended CDL): the 330.870 um
island has 96 cells and **301 bodies + 194 VDD source/drains**, the 17.270 um island 4 cells and 2
bodies + 1 source/drain -- 303/195 against the netlist's 301/195, and the 301 bodies of the clock
net are that long island exactly.

**The cause is `fill_def.py`'s DEF parser, and it is the same bug twice.** `POINT_RE` matches only
`( x y )`, so a `( x y ) RECT ( dx1 dy1 dx2 dy2 )` metal1 shape collapses to its anchor point and is
padded by `VIA_HALF = 400` DEF units: an 0.4 x 0.4 um box starting 0.2 um right of the anchor.
The real shape is 0.415 x 0.230 um and starts at the anchor, so the modelled obstruction ends 0.08
um past the fill site's edge while the stub crosses it by 0.135 um. Both contacts have that 0.08 um
miss exactly, and the fill pass reports those sites as rail-clear. A correct RECT parse (or the
DRAWN metal1 from the stream, which is what the fill is actually dodging) rejects both sites.

Evidence: `build/lvs_chip/probe/{lvsdb_clk_composition.rb,clock_vs_supply_pins.py,
clk_rail_short_report.py,island_bodies.py,window_dump.py}`; the feed/landing geometry is in
`build/lvs_chip/filled/grx930_test_chip_filled_metal1.def` and `build/lvs_chip/stream_out*.gds`.

**The fill reads RECT shapes exactly now, and the clock is its own net (2026-11-04).**
`fill_def.py` parses Metal1 as statements rather than points: `+ ROUTED <layer>` opens a block,
`NEW <layer>` starts another wire in it, `;` closes it (the 53,713 `+` continuation lines used to
cut wires at the line break), a `RECT` is the point plus its four offsets exactly, a via is a
`VIA_HALF` pad, a wire is a `METAL1_HALF`-widened centreline. Anything it does not model -- `MASK`,
`DO BY`, a RECT with more than one anchor point, a point after a via or RECT on the same wire, an
unknown layer, text after `;` -- refuses the run instead of guessing. On this DEF that is 2,009
RECTs + 30,805 wire segments + 256,356 via pads, which are the file's own statement counts.

The re-fill places 94,154 cells with 19,543 taps (was 94,160 / 19,574). At (1755.040, 2238.320) um
the site is now empty; at (2199.120, 1532.720) um a `fill_1` replaces the `fill_2`, so the rail ends
at x 2199.680 while the clock stub starts at 2200.105. `probe/clock_vs_supply_pins.py`, whose parser
is separate from the fill's, finds **0** clock-metal1/supply-pin contacts (556 rect shapes, 4,622
segments, 22,668 via pads against 617,496 POWER/GROUND pin rectangles; it found the two above
before the fix). Streamed: 147,899 cells, and the layer census moves by 314 polygons in total
(8,238,327 -> 8,238,013; metal1 merged components 371,620 -> 371,706).

Census on `stream_out_filled_rect.gds` (`evidence_census/die-filled-rect-nets`, stage=combine,
same deck hash `01dc791b5cacf929`, 12 threads, 35 min) against the shorted run:

| | `die-filled-metal1-nets` | `die-filled-rect-nets` |
|---|---:|---:|
| layout devices pre / post-combine | 691,010 / 691,010 | **691,010 / 691,010** |
| layout nets | 374,826 | **374,891** |
| net named `VDD` | 522 nets / 520,448 term | **559 / 570,919** |
| net named `VSS` | 56 nets / 353 term | **59 / 565,747** |
| the clock net | `CLK,VDD,i_clk` = **29,484** | `CLK,i_clk` = **28,988** |

The clock net is now **28,988 terminals, exactly the schematic's `I_CLK`**, and no supply name is on
it. The supply side also lands: `VSS` is 565,747 layout terminals against 565,747 schematic (this CDL
ties `VPW` to `VSS`), and `VDD` is 570,919 against 571,169 -- 250 short, where the shorted run was
50,721 short. The 65 extra layout nets are the fragments that used to be merged into the clock.

One operational note: this die cannot be censused on this workstation. In the local Docker VM
(5.8 GB total, ~0.4 GB free against a 32 GB swap) KLayout enters the inter-layer connectivity setup
and stays there -- 2 h 05 m with no output past EFUSE extraction, single-threaded at 100 % CPU, and
the *baseline* GDS stalls at the same line when run beside it, so it is the host and not the fill.
On the build server (16 cores, 30 GB) the same command finishes in 35 min, which is where the earlier
censuses ran too.

**The full comparison on that die: 271 net pairs, 42 device pairs, and the clock is not why
(2026-11-04).** `build/lvs_chip_bounds_test.sh filled-rect-b12300 --branch 12300` on
`stream_out_filled_rect.gds`, 12 threads, 2,209.7 s (comparison section 1,212 s), deck
`15a5f750...`, runner verdict **mismatch**; evidence in `evidence_lvs/filled-rect-b12300/`.

The xref partition (`probe/lvsdb_xref.rb`): 742,169 net pairs of which **271 `Match` / 741,898
`Mismatch`**, and 1,381,975 device pairs of which **42 `Match` / 1,381,933 `Mismatch`**. Only 280
nets and 45 devices have a candidate on both sides at all. Among the pairs that do have both sides,
**9 nets and 3 devices disagree** -- the devices are all `pfet_05v0 -> PFET_05V0` (`$163460` vs
`_64467_._TP8`, `$135394` vs `_44911_._I_3`, `$137395` vs `_45407_._I_4`).

The clock is clean and the comparer still cannot confirm it: `probe/lvsdb_clk_pair.rb` shows the
pair **`CLK,i_clk` 28,988 terminals <-> `I_CLK` 28,988 terminals, status `Mismatch`**. Identical
terminal counts on both sides, no supply name on the layout net -- the status is the comparer
declining to pin an identity when its neighbours cannot be resolved.

What cannot be resolved is the supply, and this die has no PDN stitches: the layout carries **558
nets named `VDD` (largest 2,261 terminals)** and **58 named `VSS`** (565,384 of them in the big net,
363 outside it) against one `VDD` (571,169) and one `VSS` (565,747) in the schematic.
`tools/lvs_chip/pdn_stitch.py` was run on the metal1 fill, not on this one, so the via1/metal2/via2
straps that collapse 162,774 metal2 islands into the grid are simply absent here. That is the same
wall the unstitched die hit before the fill fix -- 279 nets / 42 devices at this bound -- so the
fill fix does not regress anything and gains a little (280 / 45); the stitched die is what moves
(369,884 paired nets, 659,416 paired devices).

Verdict and remaining mismatches, then: **mismatch**, caused by the unstitched PDN partition (558
`VDD` and 58 `VSS` fragments against one of each), plus 9 both-sided nets and 3 both-sided PFET
pairs. The clock defect that this work was about no longer appears anywhere in it. The 735 MB
`report.lvsdb` stays on the build server at `build/lvs_chip/filled-rect-b12300/`; the text evidence
(`verdict.json`, `klayout.log`, `pairing.txt`, `xref.txt`, `clk_pair.txt`) is copied back.

**Stitched, the clock is one net pair away from `Match` (2026-11-04).** `pdn_stitch.py` on the
same DEF and GDS (`--allow-unstitched 5`, the same 5 islands the metal1 fill left) places **1,034
straps -- 979 `VDD`, 55 `VSS`**, and its own re-read of the written file counts 1,034 straps as
1,034 merged metal2 components with 0 dbu^2 within 1 dbu of existing metal2. Comparison on
`stream_out_filled_rect_stitched.gds`, same bound, 12 threads: **1,777.1 s**, verdict still
**mismatch**, evidence in `evidence_lvs/filled-rect-stitched-b12300/`.

| | rect fill, unstitched | rect fill, stitched | metal1 fill, stitched |
|---|---:|---:|---:|
| net pairs `Match` | 271 | **370,046** | 369,884 |
| device pairs `Match` | 42 | **690,114** | 659,416 |
| both-sided non-Match nets / devices | 9 / 3 | **791 / 242** | -- / 328 |
| run time | 2,209.7 s | **1,777.1 s** | 1,756 s |

The clock is **still `Mismatch`**, and now the reason is countable rather than structural:
`probe/lvsdb_clk_terminals.rb` walks both sides of the `CLK,i_clk` <-> `I_CLK` pair and finds
**28,952 of 28,988 terminals on `Match` devices and 36 on mismatched ones** -- 23 NFET + 13 PFET on
each side, the same split, so the two sides agree with each other about the clock and disagree only
about those 36 terminals' devices.

Those devices are not a geometry problem. `probe/lvsdb_dev_params.rb` compares every parameter of
every both-sided non-Match device pair and reports **242 of 242 with no parameter difference at all**;
`probe/lvsdb_dev_terminals.rb` then shows what does differ -- the nets under their terminals:
`$690947` <-> `_75713_._TN13` has its gate on `$373931` against `_75713_.NCKI` and its drain on
`$373917` against `_75713_.CKI`, and `$690948` <-> `_75713_._TN11` has `D,Z,_32101_` against
`_32101_` and `$373932` against `_75713_.NET10`. The layout calls those nets `$373931`-style because
nothing in the GDS labelled them at that point; the schematic names them inside the cell. The residue
is therefore net/terminal identity around a small set of cells whose internal `CKI`/`NCKI` nets were
unlabelled in the layout, not a device, a well, a rail or the clock's own shape -- and the labelling
test below settles whether naming them is what fixes it. It is not.

The supplies pair as far as the partition allows: `VDD` is 4 layout nets with 570,914 terminals
against the schematic's 571,169 (255 short) and `VSS` 4 nets with 565,384 against 565,747 (363
short) -- the 5 unstitched islands' terminals plus the tap difference, where the unstitched die had
558 and 58 fragments.

**Labelled, and the residue turns out not to be naming at all (2026-11-04).**
`tools/lvs_chip/label_cell_nets.py` writes an `<instance>.<net>` label for every cell-internal net the
schematic names, at a position taken from that net's own drawn metal (`probe/cell_label_map.rb`), in
the top cell so the flatten keeps the instance prefix. Two measurements on the written file:
`probe/gds_label_census.rb` finds **148,716 dotted names in the top cell, 133,478 of them the
instance-qualified ones** (485 texts stay in the 42 cell definitions, the PDK's own);
`probe/lvsdb_label_pairs.rb` asks whether each label names the net the comparer paired with the same
name and gets **133,478 agreements and 0 disagreements**. The 15,237 `differ` lines are the DEF-named
routing nets -- layout `A1,A2,A3,A4,B,D,I,I0,ZN,u_cpu.csr_src_ex` against schematic
`U_CPU.CSR_SRC_EX[26]`, the same net apart from the bus bit. The labelling round-trip is exact.

The partition does not move. `stream_out_filled_rect_stitched_lab2.gds` (sha256 `d5efc816…`), same
deck (`15a5f750…`), same switches and bound, 12 threads: **1,744.5 s**, **370,046 net pairs /
690,114 device pairs / 791 and 242 both-sided non-Match** -- the unlabelled stitched die to the pair
and to the device -- and `CLK,i_clk` <-> `I_CLK` still **`Mismatch` with 28,952 `Match` + 36
`Mismatch` terminals**. Evidence in `evidence_lvs/filled-rect-stitched-lab2-b12300/`.

`probe/lvsdb_dev_namecheck.rb` counts why instead of sampling: of the 242, **27 have identical names
on every terminal** and are still `Mismatch` (all `nfet_05v0`), and **215 differ on at least one
terminal** (102 on one, 72 on two, 39 on three, 2 on four) -- but what differs is a *crowded* name,
not a missing one: `D,Z,_32101_` against `_32101_`, `A1,I0,Q,u_cpu.u_riscv_core` against
`U_CPU.U_RISCV_CORE_MUL_DIV`. `probe/gds_def_labels.rb` names the source: the 42 PDK cells carry 485
texts in their definitions over **33 distinct strings** -- `VDD VSS VNW VPW`, four frame strings, and
the pin names `A1 A2 A3 A4 B B1 B2 C C1 C2 CLK D I I0 I1 I2 I3 Q RN S S0 S1 SETN Z ZN`. A flatten
drops the instance prefix, so `D` and `Z` name thousands of nets and identify none; KLayout's
`consider_net_names` (on by default) cannot use a name many nets share, and the unique label added
here shares its net with those generic ones. The ambiguity wins.

So the remaining 242 pairs are not a labelling defect and not a geometry defect: they are the PDK's
generic pin names colliding at die scale, which is also why the 36 clock terminals stay on `Mismatch`
devices. Naming cannot lift the clock to `Match`. The alternatives left are to compare
*hierarchically*, where each cell's interior is matched inside its own circuit and no name has to
compete across 39,328 instances, or to suppress the library cells' definition labels without losing
the pin naming -- and neither is worth doing before the `tpl02` wrapper run, which is what the
submission actually depends on.

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
