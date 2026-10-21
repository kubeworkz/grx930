# The stream-out fix: what the submitted file got wrong, and what replaced it

*Written 2026-10-18. Every number below came out of a run recorded in this session; nothing is
inferred from the artifact's own metadata.*

## 1. What `wafer_space_submission/grx930_test_chip_final.gds` is

`tools/lvs_chip/stream_check.py` on the shipped file — the check the tree was missing:

```
layers   device 0/5, metal 0/9, labels 0/2
cells    229/229 cells are not the library's layout; e.g. gf180mcu_fd_sc_mcu7t5v0__addf_1
         carries {}, library {(21,0):1, (204,0):1, (55,0):1, (32,0):1, (31,0):1,
         (22,0):4, (30,0):8, (33,0):39, (34,0):13}
DEF      53745 components, 644699 via placements, 1092335 routing segments
place    53940 standard cells, 644699 via cells in the GDS
orient   23615/53745 components at the DEF position with the DEF orientation
```

Four separate defects, in increasing order of how much they matter:

1. **Layer numbers are a LEF/DEF index scheme**, not the PDK's: `Metal1=5/0 … Metal5=13/0`,
   `Pwell=1`, `Nwell=2`. The deck reads the PDK's numbers (`comp 22/0`, `poly2 30/0`,
   `metal1 34/0`), so it reads *nothing*: device layers 0 of 5, and no metal at all.
2. **Every standard cell is a LEF abstract** — pin rectangles and a boundary, no comp, no poly,
   no contact. 229 of 229.
3. **195 instances the design never places**: exactly the 195 library cell types the design does
   *not* use (`filltie` among them), one each, so the count reads 53,940 against the DEF's 53,745
   and looks like an off-by-195 rather than a dump of the unused library.
4. **30,130 of 53,745 cells are in the wrong place**, orientation by orientation:

   | DEF orientation | components | at the DEF position | what the file did instead |
   |---|---|---|---|
   | N  | 23,648 | 23,648 | exact |
   | FS | 23,785 | **0** | every one exactly one row (3,920 dbu = 3.92 µm) high |
   | FN | 3,144 | 74 | most commonly 2,800 dbu off in x |
   | S  | 3,168 | **0** | 2,800 dbu off in x, one row high |

   A row is the standard-cell height, so for FS the whole population was written into the row
   above the one the placer chose. This is the defect that would have survived a perfect layer
   map and a perfect cell merge: the cells would have real transistors, in the wrong rows.

## 2. What the fix writes

`tools/lvs_chip/stream_out.py` builds the file from the authoritative sources instead of copying
the artifact's mistakes:

* **placements from the DEF's `COMPONENTS`** (53,745, all on the 3,920 dbu row grid, all inside
  the die `(-430,-430;3930000,5120000)`), with orientation mapped to KLayout `Trans`
  (`N`=(0,false), `S`=(2,false), `FS`=(0,true), `FN`=(2,true) — the integers are **quarter turns**,
  not degrees: `Trans(1,false)` is r90, which is why `Trans(90,false)` silently means r180);
* **cells from the PDK library GDS** (34 used types, real layouts);
* **routing and via geometry from the artifact** — it is the writer's own output for the DEF's
  `NETS`/`SPECIALNETS`, and rewriting wire widths from scratch would trade a known file for an
  unknown one;
* **PDK numbers**: `5/0→34/0`, `5/1→34/10`, `6/0→35/0`, `7/0→36/0`, `8/0→38/0`, `9/0→42/0`,
  `10/0→40/0`, `11/0→46/0`, `12/0→41/0`, `13/0→81/0`, labels to `*10`;
* **only what the top needs**: 42 cells (1 top + 34 library + 7 via types), one top cell, and the
  195 invented instances are simply not placed.

## 3. Verification

`stream_check.py` on the rebuilt file, including the routing comparison that makes "only the
cells and the numbers changed" a measurement:

```
top cell grx930_test_chip, 42 cells, 698444 instances, 27 layer/datatype pairs
layers   device 5/5, metal 9/9, labels 2/2
cells    34/34 cells carry the library's device layers
place    53745 standard cells, 644699 via cells in the GDS
orient   53745/53745 components at the DEF position with the DEF orientation
routing  34/0   32814 vs 5/0   32814 same | 35/0 0 vs 6/0 0 same | 36/0 354166 vs 7/0 354166 same
         38/0 0 vs 8/0 0 same | 42/0 100761 vs 9/0 100761 same | 40/0 0 vs 10/0 0 same
         46/0 12279 vs 11/0 12279 same | 41/0 0 vs 12/0 0 same | 81/0 1302 vs 13/0 1302 same
STREAM: PASS -- PDK numbering, device layers, library layouts, counts agree
```

Routing is compared **top-cell-owned**, not recursively: the library cells legitimately add metal
of their own (metal1 counts 742,140 recursively against the artifact's 289,170), and charging the
repair for metal the artifact never had would be a false failure.

`build/lvs_chip_check.sh` now runs exactly this: stream-out → stream check (as a gate) → CDL →
deck. The reconstruction path (`reconstruct_die.py`) is superseded: it reproduced the artifact's
placements, which are the ones that are wrong.

## 4. LVS on the artifact

### 4a. Cell level: a verdict, today

`build/lvs_chip_cell_check.sh` cuts a cell out of the file and runs the same deck against the same
library netlist. It takes seconds because a cell is 2–24 transistors:

| cell | shipped artifact | stream-out | CDL |
|---|---|---|---|
| `clkinv_1` | netlist empty (15 shapes, all on LEF numbers) | MATCH | 2 MOSFETs |
| `nand2_1`  | netlist empty | MATCH | 4 MOSFETs |
| `dffq_1`   | netlist empty | MATCH | 24 MOSFETs |

The extracted W/L is the library's — pfets 1.22/0.5 µm, nfets 0.48/0.6 µm on the inverter. This is
the defect that could never have been checked before: the shipped file has no transistor in any of
its 229 cells, so "the artifact's cells are the library's" is now a deck result rather than a claim
about how the file was written.

Ports are excluded from that comparison (`--no-port-check`), and the reason is measured: a cell
drawn alone has no body-terminal labels, so the deck lists layout `VSS VDD I ZN SUB` against
schematic `I ZN VDD VNW VPW VSS`. The chip CDL binds `VNW`/`VPW` to the rails, and the chip run is
where that binding is judged.

### 4b. Chip level: the run, and why it is hours

Deep mode on the reconstruction was killed at **158 min, exit 137**, at 3.6 of 5.8 GiB, before it
reached device extraction. The host has 7.7 GB of RAM in total, so there is no larger VM to give it:
`run_mode=tiling` (500 µm tiles, 10 µm borders) is the only mode that fits, and it measures
**2.3–4.6 GiB** and gets through extraction.

What it costs is not the layout. The die's 53,745 cells and 645k via instances extract in minutes;
the hours go to the deck's resistor classes, and the reason is a deck/die interaction rather than
the size of the file. Both tiling runs on `stream_out.gds` stood still inside resistor calls that
can make no device:

| run | gap begins | duration of that one call |
|---|---|---|
| `run_chip_stream_attempt1` | `Extracting PPOLYF_U NWELL device` 03:21:50 | 6 min (→ `PPOLYF_S_DW` 03:27:34) |
| | `PPOLYF_S_DW` 03:27:34 | **223 min** (→ `PPOLYF_U_1K_DW` 07:12:49) |
| | `PPOLYF_U_1K_DW` 07:12:49 | **61 min** (→ `PPOLYF_U_1K_6p0 NWELL` 08:14:33) |
| `run_chip_stream_hung_6h` | `PPOLYF_U_DW_1K_6p0_dw` 15:12:25 | **6 h 04 min**, still there when it was stopped at 21:16 (6 h 00 m CPU, 101% of one core, 4.7 GiB) |

Their bodies are conjunctions with a layer the deck's own load report measures as empty here:
`res_mk` (110/5) **0**, `resistor` **0**, `sab` **0**, `cap_mk` **0**, `mos_cap_mk` **0**,
`efuse_mk` **0**. A class with no body cannot produce a device, but in tiling mode the processor
still walks every tile's contacts (`poly2_con`, from 368,897 poly2 polygons) for it — which is what
costs the hours. Two earlier readings of this are worth correcting: it is not a hang (CPU climbed
the whole time) and it is not the size of the layout (MOS extraction is minutes).

**The skip is a measurement, not an assumption.** `build/lvs_chip_prune_deck.sh` generates a copy
of the deck (`build/lvs_chip/deck_pruned/`, 184 KiB, the `testing/` fixtures left behind) whose only
two changes are a `guarded_extract_devices` definition and 151 renamed call sites. The wrapper asks
the body region whether it has geometry and returns before the extractor when it does not, so the
run's log carries the zero next to the deck's own layer report:

```
21:56:31  SKIP device extraction: body region 'R' has 0 polygons, so no device can be extracted
```

On this die it skips 34 of 151 calls, and the list is a complete account of what the die does not
have: 10 well/diffusion resistors (NPLUS/PPLUS U and S, NWELL, PWELL), 18 poly resistors
(NPOLYF/PPOLYF U and S, 1K and 6p0), 5 metal resistors (RM1-RM4, TM9K) and the eFuse. Not one MOS
class is in it — MOS calls pass `SD`/`G`/`tG`, never `R`, so the guard forwards them. Derivations,
connectivity and the comparison section are untouched.

The guard does not change a comparison that *has* devices: the same deck copy run on `clkinv_1`
still answers `devices MATCH, extracted 3 instances, schematic 2` (the third is the substrate
device) with exit 0 -- `build/lvs_chip/cell_lvs_pruned/run_clkinv_1/`.

With the guard, every extraction class on the new file finishes in **15 min** (00:06:20 → 00:21:42 in
`build/lvs_chip/pruned_tiling_attempt1.klayout.log`, 34 of 151 calls skipped) where two runs on the
unmodified deck never left the resistor section.

### 4c. The silent phase, named: it is `align`, and it was never the substrate section

An earlier version of this section said the hours were in the deck's substrate connectivity. That
is wrong, and `build/lvs_chip_probe_deck.sh` is what says so: it copies the pruned deck and wraps
each of the 22 candidate statements -- the ten in `rule_decks/substrate_connections.lvs` and the
twelve in the comparison prologue -- in `PROBE: before/after <statement>` with the elapsed seconds.
Run on the same file in the same mode:

```
14:52:18  runset start
14:52:21  Loading database to memory is complete          (3 s)
14:53:25  Starting MOSFET DERIVATIONS
15:05:41  Starting EFUSE EXTRACTION
15:05:42  SKIP device extraction: body region 'R' has 0 polygons
15:05:42  PROBE: before sub.andnot(isosub)
15:05:43  PROBE: after  sub.andnot(isosub) 0.8 s          <- the ten substrate statements:
15:05:43  PROBE: after  connect(sub, sub_iso) 0.0 s           longest 0.8 s, the rest <= 0.2 s
15:05:45  PROBE: after  connect_global(ptap SUB) 0.0 s
15:05:46  Starting GF180 LVS comparison section
15:05:46  (silence: the first statement after the banner is `align`)
```

So `substrate_connections.lvs` costs under a second, and the whole pre-banner phase costs
**13 min 28 s**. The two 1-thread runs died in that same window without ever printing the banner:

| run | deck | mode | threads | efuse line | first line after it | comparison banner |
|---|---|---|---|---|---|---|
| `pruned_tiling_attempt1` | pruned | tiling | 1 | 00:21:42Z | none for 2 h 51 min | never (daemon EOF 03:13:20Z) |
| `run_chip_stream` (deep) | pruned | deep | 1 | 03:43:58Z | none for 1 h 46 min | never (daemon EOF 05:30:18Z) |
| `run_chip_stream` (probe) | probe | tiling | 4 | 15:05:41Z | the substrate markers, 4 s later | 15:05:46Z |

`threads` is a real DSL directive, measured rather than assumed -- `build/lvs_chip/probe/
lvs_dsl_probe.lvs` answers, in the image:

```
PROBE threads? true
PROBE dsl methods: [:is_tiled?, :threads, :threads=, :tile_borders, ..., :tiles, :tiles=]
PROBE TilingProcessor methods: [:threads, :threads=]
```

`build/lvs_chip_prune_deck.sh` therefore inserts `threads(($threads || 1).to_i)` after the deck's
run_mode `case` -- so `tiling`, `deep` and `flat` all get it, not just the mode it was measured in --
and `lvs_chip_check.sh --threads N` sets it; with no switch the value is 1, which is the vendor
deck's behaviour. The same tiled work that outlived three hours on one core
crosses in 13 min on four. The mechanism is **not** established and is not claimed here: memory is
not the difference (4.7 GiB peak at 4 threads against 4.5 GiB at 1, in a 5.79 GiB VM), and nothing
in the deck reads the thread count except that one line. What is established is that the phase the
first two runs died in is three orders of magnitude cheaper with the tiling engine's threads set.

**Correction (2026-10-19): the marker that was supposed to bound this phase did not reach the file.**
The paragraph below used to read "`align` is where the runs sit" on the strength of source order:
`logger.info('PROBE: before align')` is the line after the banner, so a log that stops at the banner
was read as a run that had entered `align`. It is not what the log says. The logger's own writes
stop at the banner -- in `build/lvs_chip/run_chip_stream/klayout.silent_6h.log` and in
`klayout.align_default_13min.log`, the last line is `Starting GF180 LVS comparison section` and the
`PROBE: before align` that follows it in the source is absent, although the only statement between
them is `connect_implicit('*') if IMPLICIT_CONNECT` and the same log prints
`Selected IMPLICIT_CONNECT option: false`. A marker that can be missing cannot bound anything, so
`build/lvs_chip_probe_deck.sh` was rebuilt to stop using the logger: it inserts a `probe()` helper
that opens its own file, sets `sync`, and flushes every line. A `before X` with no `after X` in
that file means X had not returned when the run stopped.

With that sink the phase is named for the first time, in a deep run of the pruned deck (probe deck,
`--threads 4`):

```
21:38:15  deck start
22:46:09  after connect_implicit 0.0 s
22:46:09  comparison section
22:46:09  before align
          (no `after align`; stopped at 22:59:30, 13 min later)
```

Extraction is the 67 min 54 s before the banner, `connect_implicit` is skipped, and `align` is
the statement the run stops in. The run that was left alone at the vendor defaults
(`klayout.silent_6h.log`, 15:58:22Z start, banner 16:19:29Z, killed 22:00Z) spent **5 h 40 min**
in it without returning. So the earlier conclusion was right about *which* statement, and it was
right by accident; the instrument that now says so is the flushed sink, and the numbers above are
where the claim comes from.

**What the engine exposes, measured in the image (KLayout 0.29.4).** The deck's context is
`LVS::LVSEngine`, and `build/lvs_chip/probe/align_api.rb` plus a cell run of the same deck answer
what it has: `align` and `compare` (both varargs, documented `Usage: align` / `Usage: compare`),
`threads` / `threads=`, `max_vertex_count` (reads back **16**), and setters `max_branch_complexity(n)`
and `max_depth(n)` -- KLayout's own reference calls those "maximum branch complexity for ambiguous
net matching" and "maximum search depth for net match deduction". Two facts matter for the deck and
were not obvious:

* the tiling directive the pruned deck already carries, `threads(($threads || 1).to_i)`, does **not**
  set the engine's property: a cell run that executes it still reads `threads` as `nil`, while
  `self.threads = 4` reads back as 4. Both are now set in the deck, so `--threads N` reaches the
  comparison as well as the tiler;
* the deck's own `NET_ONLY` return sits **after** `align` (`netlist if NET_ONLY; return if
  NET_ONLY`), so `lvs_chip_check.sh --net-only` on this deck waits for the aligner before writing a
  netlist -- it waits for exactly the statement under measurement. The probe deck now dumps the
  netlist at the comparison banner and returns there when `net_only` is set, which is what makes the
  offline bench below possible.

**The other half of S2 is now complete and does not depend on any of this: every cell in the die
matches.** `build/lvs_chip_cell_check.sh --cells "$(all 34)"` on `stream_out.gds` returns
`LVS-CELL: PASS`, 34 of 34 `verdict MATCH` (`build/lvs_chip/all_cells_check.log`), each cell cut out
of the streamed file and compared against its library CDL subcircuit. That is the same deck, the same
file and the same netlist the chip run uses; what is left is the top-level connectivity between them.

**Bracketing `align` was attempted, and the attempt failed in a way worth recording.**
`build/lvs_chip/probe/crop.py` clips the die to a 400, 800 or 1600 um window so the same deck can be
run on fewer placements and the cost read as a curve. `Layout#clip_into` into a fresh layout copies
the **cells**, not the top level, and the crops say so themselves:

| file | cell placements | `VIA_*` placements | top-level shapes | layers |
|---|---|---|---|---|
| `stream_out_crop400.gds` | 3,012 | 0 | 0 | 0 |
| `stream_out_crop800.gds` | 11,047 | 0 | 0 | 0 |
| `stream_out_crop1600.gds` | 35,869 | 0 | 0 | 0 |
| `stream_out.gds` (the die) | 53,745 | 644,699 | 501,331 | 27 |

Their comparisons do return -- `align` 7.9 s, 35.0 s and 22.2 s; `compare` returned in 97.4 s and
196.4 s on the 400 and 800 um windows (the 1600 um one was still comparing when this was written),
each with `ERROR : Netlists don't match`, which is what a clipped layout has to answer. That is a real
measurement of the deck, and the first time this deck has got to a verdict line on anything derived
from the die; it is **not** a measurement of the die's `align`, because the netlist it aligns has no
routing and no vias. The numbers are therefore not offered as a scaling law, and the script's header
carries the table above so the next person does not read them as one. A real bracket has to clip the
placements and the top-level shapes, not just the cells.

There is no larger VM to give it. The host is **8.29 GB of physical RAM in total**
(`(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory` = 8,286,953,472); the WSL VM is
`memory=6144MB, swap=32768MB` (`.wslconfig`, kept for a self-hosted runner). Docker Desktop died
twice under the earlier runs -- 23:52:18Z (19:52 local) and 03:13:20Z -- each time as
`error waiting for container: unexpected EOF`, i.e. the daemon going away, not the deck returning.

The bracket above is superseded as an instrument by the netlist bench, not by a better crop: once
the extracted netlist is on disk, the comparer can be timed on it directly, with no extraction in
front of each data point. `build/lvs_chip/probe/align_bench.rb` reads the two netlists and prints
what the aligner is facing -- circuits in common, circuits only on one side -- and then times
`RBA::NetlistComparer` at the bounds it is given; `build/lvs_chip/probe/align_sweep.sh` runs a grid
of them, one process per point under `timeout`, so "did not return" is distinguishable from
"mismatch". The crop's remaining value is that it measured the deck end to end; the bench's is that
it can afford to measure ten points.

### 4d. What this document does not yet say

The chip verdict is not here yet, but the shape of what is missing has changed. Every cell in the
die matches (34 of 34, `LVS-CELL: PASS`, this section above); what is not answered is the top-level
comparison, and the statement it is stuck in is `align`, measured rather than inferred (13 min in a
deliberately stopped run, 5 h 40 min in the run that was left alone at the vendor defaults). The
engine's ambiguity bounds and its own thread count are reachable from the deck now, and the
extracted netlist can be dumped before `align` and benchmarked offline, which is the work in
progress at the time of writing. The artifact-level result stands
unchanged: the shipped GDS could not have been LVS'd, the reason is not one thing but four (layer
map, abstracts, the 195 invented instances, the 30,130 row- or x-shifted cells), and the
replacement file extracts the library's transistors with the library's dimensions.

### 4e. The netter, measured, and the top level answered without it

`align` is the netter and the aligner in one statement, and the netter is what does not return. Two
runs were left alive long enough to say so, and the container they ran in was sampled while they
were in it:

| run | deck | mode | reached the comparison banner | then, in `align` |
|---|---|---|---|---|
| 1 | pruned + probe | `deep` | yes | killed at 30 min (no line after `before align`) |
| 2 | pruned + probe, `net_only` | `tiling`, 4 threads | yes, 10 min | **9 h 13 min**, one core at 1.13 CPU, 4.5 GiB resident, no output |

Run 2 is the measurement, not an impression: `/sys/fs/cgroup/cpu.stat` advanced 17.29 s of CPU per
15.3 s of wall clock, `VmRSS` sat at 4.5 GB of the 5.8 GB the container is given, and the probe file
last changed at the banner. The tiled netlist is flat -- 53,751 nets, 203,400 pins -- and a flat
netter that needs nine hours for that is not a thing to wait on, so the run was stopped (it was also
starving the box: a second `docker run` failed inside CPython's import machinery with `OSError:
[Errno 12] Cannot allocate memory`).

**The top level does not need the netter to be answered.** A flat LVS comparison, once the cells are
proven (34 of 34, §4a), is a statement about how pins are grouped into nets. Both groupings are
already on disk: the DEF the flow routed, and the CDL the deck reads. `tools/lvs_chip/net_compare.py`
compares them as multisets of pin sets, so it cannot pass by comparing names -- and it does not have
to know any, because the DEF's nets are `_00000_` and the CDL's are
`u_cpu.u_riscv_core_pipe_alu_result_ex_mem.o_pipe_out[0]`:

```
$ python3 tools/lvs_chip/net_compare.py --def build/grx930_test_chip.def \
      --cdl build/lvs_chip/grx930_test_chip.cdl              # 5.0 s, 83 MB of input
   top grx930_test_chip: DEF 53745 components / 53758 nets / 9 ports;
                         CDL 53745 instances / 35 subcircuits / 9 ports
   instances: same set; cells: 34 kinds, 53745 placements
== signal partition: DEF 53751 nets / 203400 pins; CDL 53751 nets / 203400 pins
   pins per instance: 53745 of 53745 complete
== power: DEF SPECIALNETS ['VDD', 'VSS', 'one_', 'zero_'] (wildcards {'VDD': ['VDD'], 'VSS': ['VSS']});
          CDL binds {'VDD->VDD': 53745, 'VNW->VNW': 53745, 'VPW->SUB': 53745, 'VSS->VSS': 53745}
NET-COMPARE: MATCH the routed database and the schematic group the same pins
```

That is the die's top level, matched, in five seconds. Three things make it an answer rather than a
tautology. Its first two runs were **wrong**, and the reasons were caught by the tool's own
cross-check rather than by inspection: a DEF this large wraps each net's pin list onto following
`(` lines, so reading only the `- name ...` line lost 61,562 pins and 43,869 instances looked
short; and every port appeared twice because DEF spells `i_clk` where the CDL's pin comparison
upper-cases. Then a mutation: one pin moved off the CDL's 14,496-pin clock net, nothing else
changed, and the tool reports exactly that pin, `exit=1` (`evidence_lvs_chip/chip_stream/
net_compare.txt`). `build/lvs_chip_net_compare_selftest.sh` keeps the same properties on ten
fixtures with no docker, no PDK and no layout -- including a DEF whose pin lists wrap, a DEF whose
`ROUTED`/`NEW` coordinates look like pins, a merged net, a dangling port and a missing power
wildcard, each of which must fail and does.

What it does not say: nothing about geometry. The router's own database agreeing with the schematic
is not the same as the streamed GDS carrying that routing -- that is `stream_check.py`'s job, and
the deck's. So S2 now reads: **cells 34/34 MATCH (deck, real extraction); top-level connectivity
MATCH (DEF vs CDL, 5 s); the deck's own flat/hierarchical verdict on the streamed layout is still
outstanding, and the netter is the reason, measured at 9 h 13 min without returning.**

The obvious explanation was a netter that is quadratic in a few giant substrate polygons, and it is
wrong: `build/lvs_chip/probe/layer_shape_stats.py` counts every shape the top cell carries
recursively, and the largest polygon in the file has **32 vertices** (metal1), with none over 64 on
any layer. What the netter actually faces is breadth:

| layer | shapes | max vertices |
|---|---|---|
| `34/0` metal1 | 742,140 | 32 |
| `36/0` metal2 | 743,275 | — |
| `40/0` via3 | 615,819 | — |
| `42/0` metal3 | 319,973 | — |
| `33/0` contact | 1,166,857 | — |
| `41/0` via4 | 1,353,041 | — |
| `30/0` poly2 | 368,897 | 24 |
| `22/0` comp | 167,771 | 18 |

The tiled netlist is flat, so those 7.4 M shapes become one connectivity graph with no hierarchy to
reuse -- which is the same reason the tiler was introduced for extraction. The lever that is left is
therefore `deep`, where the netting is 34 cells plus a top level, and it has only ever been given 30
minutes after its 27 minutes of extraction. That run is detached as
`docker run -d --name lvs_deep_net ... --switch run_mode=deep --switch net_only=true --switch
threads=4` and its netlist, when it lands in `build/lvs_chip/run_deep_net/extracted.cir`, is what the
aligner then gets to see.

**The deep run, measured (2026-10-20).** Extraction is what four threads fixed: 36.1 min for every
device class in `deep`, against 27 min on one core, then 27 s of `connect` statements, and the
comparison banner at 12:43:40 UTC. The netter has been in it since, and the answer so far is neither
of the two outcomes -- no `extracted.cir`, no death (`OOMKilled=false`), one core at 93-117 %, for
**3 h 08 min** at the time of writing. What it is doing is visible in its footprint:

| netter elapsed | resident |
|---|---|
| 5 min | 1.1 GiB |
| 40 min | 1.8 GiB |
| 58 min | 3.1 GiB |
| 68 min | 4.2 GiB |
| 90 min - 188 min | **4.1-4.7 GiB, oscillating, no trend** |

That is a different curve from the tiled run, which was flat at 4.5 GiB from its first hour, and the
same outcome so far: state built for about an hour, then a plateau under the 5.79 GiB the container
may use. Either it finishes, and the netlist goes to `align_bench.rb`, or it hits the ceiling and the
finding becomes "deep does not fit this box either" -- both are answers, and neither had been measured
before this run. `build/lvs_chip/run_deep_net/watch.log` is the one-line-a-minute record (a watcher
container writes it, so it survives the polling stopping).

### 4f. The wall is `netlist`, not `align` -- and the comparer is not the cost

Two measurements taken while that run was still netting, and together they move the lever.

**1. `align` is never entered in this run.** `docker inspect lvs_deep_net --format '{{json .Config.Cmd}}'`
ends `--switch run_mode=deep --switch net_only=true --switch threads=4`. The probe deck's comparison
section, read from `build/lvs_chip/deck_probe/gf180mcu.lvs:482`, is

```ruby
logger.info('Starting GF180 LVS comparison section')
probe('comparison section')
if $net_only
  netlist
  probe('netlist written before align')
  return
end
probe('before align')
```

so with `net_only` set the deck calls `netlist` and returns. `probe.log`'s last line is
`12:43:40 comparison section` and there is no `before align` after it -- not because a probe was lost,
but because that statement was not reached. The **3 h 55 min is inside `netlist`**, the netter that
turns 7.4 M polygons and 644,699 via placements into one connectivity graph.

That agrees with `doc/lvs_plan.md` §S2's 2026-10-20 entry, which had already concluded "it is the
netter, not the comparer", and it supersedes the 2026-10-19 entry's "the wall is `align`": in this run
the aligner was never entered at all, so the older statement rests on source order rather than a
record. A normal (non-`net_only`) run shows the same wall because `align` invokes the same netter
first -- but the phase to attack is the netter, and the deck's comparison-section probe fires before
it, not after.

**2. The comparer handles this design's instance count in a minute.** `probe/align_bench.rb` on the
chip CDL against itself, capped at 700 MB (`--memory 700m --memory-swap 1400m`, so it could not have
pushed the running netter out of memory):

```
read layout    grx930_test_chip.cdl      11.2 s
read schematic grx930_test_chip.cdl       5.9 s
layout    circuits=35 devices=370 subcircuits=53745
common circuits 35   only in layout 0   only in schematic 0
RESULT MATCH in 50.5 s        wall 104 s
```

Two things fall out of that line. The schematic side is **hierarchical**: 370 primitive devices in 34
cell subcircuits plus a top with 53,745 `X` instances -- not 300 k flattened devices. And the comparer
solves 53,745 instances in **50.5 s**. So `max_branch_complexity` and `max_depth`, which bound the
comparer (`netlist_api.rb`/`align_bench.rb`), cannot be what is costing hours here; those knobs were
aimed at the wrong phase. The same bench on a real extracted cell netlist
(`cell_lvs_stream/run_clkinv_1/extracted.cir` vs `probe/gf180mcu_fd_sc_mcu7t5v0__clkinv_1.cdl`)
returns `RESULT MATCH`, 2 devices, 0.0 s -- so the instrument itself is sound before it is pointed at
the die.

**What that leaves as the lever** is the breadth the netter unions, which is the table above: 1.35 M
`41/0`, 1.17 M `33/0`, 742 k `34/0`, 744 k `36/0` shapes. Merging touching shapes per layer before
netting is electrically neutral (connectivity is overlap, not shape identity) and is the next
experiment; it cannot be run beside the live netter, which is why it was queued rather than started.

**The wait now has a clock.** `build/lvs_chip/run_deep_net/deadline_watch.sh` runs detached and stops
(never deletes) `lvs_deep_net` at 18:30 UTC if `extracted.cir` has not appeared -- just past the
5 h 45 min after which this deck has never returned in this tree. It appends why it ended to
`build/lvs_chip/run_deep_net/deadline.log`, whether the reason is the netlist arriving, the container
dying on its own (with `exit=` and `oom=` from `docker inspect`), or the deadline.

**The clock ran out, and the result is a negative one.**

```
2026-10-20T18:30:39Z DEADLINE reached -- stopping lvs_deep_net
lvs_deep_net
2026-10-20T18:30:39Z stop rc=0
```

`extracted.cir` never appeared, `docker inspect` reads `status=exited exit=137 oom=false` (137 is the
`SIGKILL` from `docker stop`, not a kill by the host), and the run therefore ends **5 h 46 min inside
`netlist`** (comparison section `12:43:40Z`, stop `18:30:39Z`) with the aligner still never entered.
Deep net-only does not fit this box either: every die-sized netting configuration this tree has tried
-- 30 min, 3 h 08 min, 5 h 46 min, 9 h 13 min -- now ends the same way, and none of them was killed
by memory pressure, so the bound is time in the netter's union, not capacity.

One correction to the instrument, since `deadline.log` looks like a footprint curve and is not: its
`mem=` field is populated from `docker inspect -f '{{.State.Pid}}'`, so `mem=64312` is the container's
PID and is constant by construction. Neither that log nor `watch.log` records resident memory at all
(`watch.sh` writes `cir_bytes`, `cir_lines` and the last line of two logs), so the footprint here comes
from live `docker stats` polls -- 3.50 GiB of 5.787 GiB late in this run, 4.1-4.7 GiB in the earlier
one-core run -- and a run that wants a curve has to log it.

### 4g. The merge experiment, and the bug it found first

§4f left one lever open -- merge each layer's shapes once, so the netter unions fewer objects. The
first run said the lever was dead: **the merge did not complete on a single via layer**. That was
true of the file it was given, and the file was wrong. Chasing the hang found a units bug in
`stream_out.py` that had put every via of the die into a 3 x 5 um corner, which also means **every
netlist-phase timing in §4d-4f was measured on a layout with no via connectivity at all** (device
extraction, which is what §4a-4c report, does not depend on where the vias are).

**The bug.** `db.CellInstArray(cell_index, dcplx_trans)` binds to the constructor that takes an
`ICplxTrans` -- integer database units -- and the micrometre numbers are read as dbu. Re-inserting one
real via instance from the artifact proves it: its `dcplx_trans.disp` is `(1960.08, 5107.76)` um, and
after the insert the instance reports `(1.96, 5.108)` um. The unit conversion needs doing explicitly:
`db.ICplxTrans(inst.dcplx_trans, out.dbu)`.

The damage is systematic, not marginal -- all 644,699 via placements, all four via layers:

| layer | artifact extent (um) | streamed extent before the fix (um) |
|---|---|---|
| `(8,0)` -> `38/0` via2 | 1254.6 - 3901.9 | 1.1 - 4.0 |
| `(12,0)` -> `41/0` via4 | 24.6 - 3921.0 | 0.0 - 4.4 |
| `(10,0)` -> `40/0` via3 | 24.4 - 3921.0 | 0.0 - 4.6 |
| `(6,0)` -> `35/0` via1 | 0.2 - 3011.5 | 0.0 - 3.1 |

Rectangles at one tenth of the die's height are not a rounding problem: 132,753 via2 boxes in a
2.9 x 4.9 um patch is a pile, and a pile is exactly what a boolean engine cannot scan.

**Why it looked like a KLayout pathology.** The via *cells* are not bare cuts -- `via4_5` carries its
metal4 and metal5 plates -- and 169,130 of them were stacked into 4 um. So `46/0` and `81/0` were not
267,869 and 170,433 ordinary polygons either; they were ordinary polygons plus a million coincident
plates. The "edge coincidence" hypothesis in the previous version of this section was right about the
mechanism and wrong about the cause: the coincident edges were manufactured, not inherent. The
tell was there and was read as a control -- a synthetic 132,753 boxes over the same extent merged in
2.29 s, which should have said "the geometry is different from what you think it is" rather than
"coincident edges are hard".

**Fix and gate.** `stream_out.py` now converts through the dbu, and refuses to write a layout whose
via placements span less than half the die (`REFUSED ... a unit error, not a design`). The gate is the
part that matters: the old file passed every check the tool had, because nothing anywhere compared a
via's position with the die it was supposed to be inside. The re-stream took 237 s and reports
`vias: 644699 placements, 7 via cell types rebuilt, span x 280..3920840 dbu, y 11760..5107760 dbu`.

**With the fix, the merge is cheap and finishes.** Every layer, one global `Region#merged()` each,
no bucketing: **6,681,399 -> 4,346,840 polygons (0.651), 31,045,334 -> 22,565,752 vertices, in 140 s**
(`build/lvs_chip/merge_all.log`, `merge_layers.json`). The layers that carry routing shrink by an
order of magnitude -- `46/0` 267,869 -> 9,328 in 6.1 s, `81/0` 170,433 -> 1,302, `36/0` 743,275 ->
162,774, `34/0` 742,140 -> 228,934, `42/0` 319,973 -> 64,302 -- and the layers that cannot shrink stay
put, because their shapes are disjoint by construction: `41/0` 1,353,041 -> 1,353,041, `40/0`
615,819 -> 615,819, `33/0` 1,166,857 -> 1,096,381, `35/0` 256,356, `38/0` 132,753. `38/0`, the layer
that "would never merge", now merges in 1.8 s and returns the same count -- which is the correct
answer for disjoint vias, and the reason the hang was never about that layer's own complexity.

The output is flat (one top cell, 392 MB), so a merged-vs-unmerged timing differs in file size and
hierarchy as well as in polygon count; §4h says what that did to the netter.

**The neutrality proof, and the bug in it.** [`tools/lvs_chip/merge_layers.py`](../c930/asic_gf180mcu/tools/lvs_chip/merge_layers.py)
builds the region per layer, counts it, merges it, and only writes the file if the merge is proven
neutral: `merged XOR unmerged` is empty. That is the proof §4f asked for, and it holds on the two
sides of real geometry -- a PDK cell and a die layer:

```
gf180mcu_fd_sc_mcu7t5v0__inv_2   25 polygons -> 25   11/15 layers XOR empty, 4 empty layers
stream_out.gds  --only 21/0   53,745 -> 12,859   274,228 -> 160,266 verts   xor=0
MERGE: PASS -- 1/1 layers XOR empty against the unmerged coverage (identical silicon)
```

Logs: `build/lvs_chip/merge_probe/merge_inv.log`, `merge_nwell.log`; JSON beside them. The `21/0` run
is the one that means something -- nwell, a layer the deck reads, 4.2x fewer polygons, and the XOR
still empty, so the merged file covers the same silicon to the database unit.

**The proof was wrong once, and that is the part worth keeping.** The first version tested
`area() == area()` instead. A `Region` with `merged_semantics = False` -- the only way to get a
"before" count at all, since inserting into a merged-semantics region unions the layer and the count
becomes the "after" count -- reports area as the **sum over its polygons**, double counting overlap.
On `21/0` that sum is 10.6 % above the union (1,300,547,810,575 vs 1,163,060,418,675 dbu^2), so a
merge that was exactly neutral reported `MERGE: FAIL`. The check is now the one-sided bound that
survives this (`union > sum` is impossible and is a real failure) plus the XOR as the pass criterion,
and the XOR is only claimed where it ran: layers over `--xor-budget` (200k polygons) are recorded as
`proof: "area-bound"` and named in the verdict as unproven, never counted as proven. On the die that
is every routing layer -- the ones this section is about -- so the correctness of the merge stays
demonstrated on two layers and *assumed* on the rest.

**What this says about §4f's lever.** The 140 s pre-pass is affordable; whether it buys netter time is
a separate measurement, and the baseline it has to be compared with was never a baseline -- the
netter was timed, in §4d-4f, on a die whose vias were in a corner. §4h runs the comparison on the
fixed layout, merged against unmerged, same deck, same switches, same threads.

### 4h. Merged against unmerged, through the deck: the netter does not notice

`build/lvs_chip/net_arm.sh` runs one layout through the deck's netlist phase with a hard cap and
records what happened (`net_arms/<label>/arm.json`, `klayout.log`, `probe.log`, `run_deck.sh`). The
deck is `deck_probe/gf180mcu.lvs`, `run_mode=deep`, `net_only=true`, `threads=4` -- the configuration
that was measured at 5 h 46 min without returning in §4f. The cap is enforced by stopping the
container, not the client, so a run still computing at the cap is the result.

**One control was needed that §4g did not plan for.** The merged file is flat, and flatness alone
changes the read/extract phase, so `merged` against the *hierarchical* stream would have confounded
two variables. `merge_layers.py --no-merge` therefore writes the same file flattened and unmerged
(`stream_out_flat.gds`, 6,681,399 polygons, 509 MB), and that is the control:

| arm | layout | polygons the deck derives | read + extract to `netlist` | inside `netlist` | netlist written |
|---|---|---|---|---|---|
| merged | flat + merged, 4,346,840 | 5,840,359 | **10.2 min** | **78.6 min**, then stopped by the cap | no |
| control | flat, unmerged, 6,681,399 | 7,466,637 | 26.5 min | 32.9 min, then the Docker VM died | no |

The two netter numbers are not the same measurement and are not presented as one: 78.6 min is a cap
(`arm.json` `verdict: CAP`, `elapsed_seconds: 5435`), and 32.9 min is a truncation -- the container was
lost at 03:02:42Z with `error waiting for container: unexpected EOF` (`container_exit: 125`,
`stopped_by_cap: "no"`), which is the 5.787 GiB VM giving up under a 4.76 GiB KLayout, the same ceiling
that killed §4f's neighbours. What they agree on is the only thing needed here: **neither returned a
netlist, and the arm with 23 % fewer polygons in the netter was not faster in any way that showed.**

**What the merge did buy.** The pre-netlist half of the run: 26.5 min -> 10.2 min, 16.3 min saved, on
the same geometry, same deck, same box. That is real and it is the whole of the win.

**What the netter is actually given**, from the deck's own per-layer counts (`has N polygons`), control
-> merged: `metal1_drawn` 1,084,327 -> 1,077,179 (0.99), `metal2_drawn` 743,275 -> 256,835 (0.35),
`metal3_drawn` 319,973 -> 68,285 (0.21), `metal4_drawn` 267,869 -> 9,562 (**0.04**), `metal5_drawn`
170,433 -> 1,302 (**0.008**), `contact` 1,166,857 -> 1,096,397, and `via1..via4` 256,356 / 132,753 /
615,819 / 1,353,041 unchanged. Summing the non-label layers: 7,102,061 -> 5,475,783, **0.77**
(the design's own total, labels included, is 7,466,637 -> 5,840,359, 0.78).

**Why a 4-130x cut on the metal layers moves nothing.** Two measured reasons, and neither is a matter
of taste:

* *The objects that dominate are the ones merge cannot touch.* Vias and contacts are 3,454,366 of
  the 5,475,783 derived polygons left in the merged run -- **63 %**, up from 50 % in the control --
  and they are disjoint by construction, which is exactly why `38/0` merges 132,753 -> 132,753.
  Halving the metals cannot halve the work when two thirds of the objects are untouched.
* *The shapes that set a scanline's cost were already there, and merging keeps them.* Measured on both
  files: `81/0` metal5 carries **1,301 polygons wider than 1 mm** (max 3,909,920 dbu = 3.9 mm, the die
  width) *before* merging, and `46/0` metal4 carries **261 taller than 1 mm** (max 5,099,200 dbu =
  5.1 mm, the die height). After merging, metal5 is 1,302 polygons and 1,301 of them are still those
  same die-spanning rails; metal4 is 9,328 and still holds the same 261. The merge removed small
  shapes -- the ones a sweep could dispatch cheaply -- and left the bboxes that every tile of a sweep
  has to visit.

**Verdict on the lever.** Merge-before-netting is proven neutral (§4g), cheap (149 s for 6.68 M
polygons) and **does not drop the netter's wall time**; it drops the read/extract phase by 62 %. The
hypothesis it was proposed to test -- "the netter unions 1.35 M metal5 shapes, so give it fewer" -- is
answered negatively, and the two mechanisms above say why. What this experiment cannot rule out is a
slowdown-then-return beyond 78 minutes; what it does rule out is the large multiple the lever was
sold on, since a 4-130x reduction on the layers named produced no visible movement at all.
