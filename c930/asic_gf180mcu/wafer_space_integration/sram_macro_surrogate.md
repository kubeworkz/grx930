# The 1×1 macro surrogate — first contact with the foundry SRAM

The quad-core scope lists "first-macro-flow risk" as one of its open risks (§6 #5): place­ment,
PDN straps over a macro, 5LM pin access, antenna, and STA against the vendor `.lib` have never
been exercised, and the quad-core part needs **320 `sram512x8` blocks**. Its §7 step 3 asks for
the cheapest thing that retires it: swap part of the 1×1 part's flip-flop cache array for foundry
macros, and force the whole macro path through the flow **at the utilisation this part already
routes** (46 %). This note records that experiment.

It is a surrogate, not a submission candidate: the tapeout configuration still builds the FF
array, and `USE_SRAM_MACRO` is only ever set by this experiment's own config file.

## What was built

`grx930_sram_64kb` keeps its ports and gains a second implementation behind `USE_SRAM_MACRO`:

| | default (tapeout) | `USE_SRAM_MACRO` |
|---|---|---|
| storage | 256 × 64-bit flip-flop array | 8 × `gf180mcu_fd_ip_sram__sram512x8m8wm1`, byte-sliced |
| line read | 4 words in one cycle, 2-cycle latency | 4 beats, 5-cycle latency |
| write | byte-strobed, same cycle as a read | one buffered write, applied between fills |
| area of the storage | ~2.1 mm² at the tree's 7.7 kbit/mm² | 8 × 0.2094 = **1.675 mm²** |

The macro is 512 × 8 with one synchronous port, so a 64-bit word is eight byte slices that share
an address, and a 256-bit cache line is four beats of that word. `o_wr_done` is registered from
the write; `o_busy` is high from the moment a write is buffered until it has been applied, which
is what lets a one-deep buffer suffice — the d-cache holds its write request until it sees done.

That latency difference (ROM 2 cycles, macro SRAM 5) is why `grx930_test_chip`'s read handshake
changed: one access in flight at a time, owner and memory-select latched at the accept and held
for the access's lifetime, and each memory's own done strobe routed to that owner. The old code
pipelined the owner two cycles deep, which only works while both memories answer in exactly two.

## Four defects it found before any flow time was spent

1. **The write mask was 8 bits where eight macros need 64.** `m_wen` was declared `[7:0]` and each
   macro was handed `m_wen[8i +: 8]` — out-of-range part-selects that iverilog silently resolved
   to zeros, so every store wrote byte 0 of the word only. The boot test caught it as
   `0xxxxxxxxxxxxxxx34`: banner and instruction fetch worked, the data store did not. The fix is
   `~{8{wb_strobe}}` — one strobe bit repeated across its slice's eight data bits.
2. **A combinational loop in the new accept logic.** `sram_rd_addr` selected on `accept_d`,
   `rom_hit` decodes `sram_rd_addr`, and `accept_d` tested `rom_hit`. Yosys `check` reported
   "found logic loop", and `Checker.YosysSynthChecks` stopped the flow at step 8 of 83 — which is
   the intended behaviour of that check, and the reason it is worth leaving on. Selecting on the
   request priority instead is equivalent on every accept cycle and has no path back.
3. **The macro instance path is the netlist's, not the RTL's.** LibreLane resolves `instances:`
   against the flattened netlist, so an instance inside `chip_top`'s `chip_core` is
   `i_chip_core.u_core.u_sram.u_macro_N` — the same shape as the template's own
   `i_chip_core.sram_0`. A path that starts at `u_core` never matches, and
   `OpenROAD.CheckMacroInstances` is the step that says so.
4. **A staging assertion hard-coded that prefix** and reported 0 instances after the rename. It
   now counts leaf names (`u_macro_[0-7]:`), so a rename cannot make the check silently pass on
   an empty list.

The first two were caught by `make sim` and by the flow's own check step, before either cost
hours. That is the argument for running the surrogate this way rather than starting at the
quad-core.

Two things about the run itself are worth recording, because both cost time:

- **`-F <step>` re-runs that step, against that step's own saved output.** Resuming the tag at
  `OpenROAD.GeneratePDN` fed `pdngen` a database that already had the grid; the step that takes
  57 s spent 15 minutes and 9 GB inserting a second set of rails before it was killed. The safe
  continuation is a fresh tag (what was done) or `-F` on the step *after* the one you want kept.
- **The disk-guard tripwire did not see this chain.** `drt_disk_guard_selftest.sh`'s "unclassified
  flow arm" check matched the *exec script* names it knew (`ws_exec.sh`, `die_predrt_exec.sh`,
  `die_drt_exec.sh`), so a chain launching a new runner was neither wired to the guard nor
  exempted, and the check that exists to force that decision stayed green. The chain now starts
  and stops `disk_guard_start "$TAG" sram_surrogate` like any other arm (it writes the same run
  tree), it is listed in `GUARD_ARMS`, and the tripwire's pattern includes
  `sram_surrogate_exec.sh` so the next new runner cannot slip past it either.

## Simulation evidence

`make sim` compiles `openlane2_rtl/src` + `tb/gf180mcu_fd_ip_sram__sram512x8m8wm1.v` (a
behavioural model: the PDK ships the macro as LEF/GDS/lib plus a blackbox stub, and a blackbox
cannot boot a testbench). Both configurations pass — banner, SRAM store/load-back through the
d-cache, heartbeat:

```
make sim                              -> RESULT: PASS
make sim SIM_DEFS=-DUSE_SRAM_MACRO    -> RESULT: PASS
```

The macro configuration is the stronger test: the arrays start as X, as the real macro's do, and
the testbench **skips the SRAM preload** for it (`dut.u_sram.mem` does not exist). So the boot
runs entirely out of the 1 KB ROM, with every instruction fetch going through the 5-cycle fill
and every store through the byte-masked macro write. It was this run that failed on defect 1 and
then passed on the fix.

## Flow wiring

| file | role |
|---|---|
| `macros_grx930_sram.yaml` | `macros_grx930.yaml`'s ws_ip block **plus** the SRAM: eight instances at fixed locations, 4 × 2 in the south-west corner of the core, 60 µm inside the core boundary and 20 µm apart; `PDN_MACRO_CONNECTIONS` for all eight |
| `pdn_cfg_grx930_sram.tcl` | `pdn_cfg_grx930.tcl` unchanged, then the template's per-instance macro grid (Metal4 edge straps at the macro's own width, plus the bridging set) for each slice |
| `grx930_sram_surrogate.yaml` | `VERILOG_DEFINES: [USE_SRAM_MACRO]` and `PDN_CFG` pointing at the file above — nothing else |
| `ws/sram_surrogate_exec.sh` | container side: the same two patches as the routing runs (line-buffered step logs, reset into CTS), then LibreLane with those three files |
| `build/sram_surrogate_chain.sh` | host side: stages the RTL and configs into `ws/template`, asserts 8 instances and the define are in the tree, gates, starts the DRT disk guard for the tag, runs, and leaves the verdict lines in `ws/logs/` |

Run tag `sram02`, flow box `ubuntu@2.31.100.64`, image
`ghcr.io/wafer-space/gf180mcu-precheck` (LibreLane 3.1.0.dev1, gf180mcuD). Only the two files
above differ from a routing run, so the two tags are comparable.

The box has no swap, so `build/memwatch.sh`'s 512 MB swap floor refuses every job on it; the
chains are launched with `MEMWATCH_FORCE=1`, which records the override in the log
(`MEM_PREFLIGHT FORCED past the refusal`). 28 GB was available against a ~7 GB peak.

## What the flow proved (tag `sram02`, stopped after `OpenROAD.GeneratePDN`)

- **`Checker.YosysSynthChecks` clear** once defect 2 was fixed — 0 check errors.
- **`OpenROAD.CheckMacroInstances` passed**: all eight instance paths resolve in the netlist.
- **`Odb.ManualMacroPlacement`: "Successfully placed 13 instances"** — 8 SRAM + 5 ws_ip cells.
  The DEF shows all eight `+ FIXED` at the configured coordinates
  (`u_macro_0` 502,502 → `u_macro_7` 1857.58,1006.88 µm).
- **`OpenROAD.GeneratePDN`: `All shapes on net VDD are connected. All shapes on net VSS are
  connected.`** and both `VDD-grid-errors.rpt` / `VSS-grid-errors.rpt` empty. The macro's
  Metal1-3 edge rails are strapped to the core grid by the per-instance grids; this is the
  specific thing that had never been exercised.
- At that step: 192,563 instances (191,432 stdcells), 5.27 mm² of instance area on the 12.92 mm²
  core = **40.8 %**; the macros are 1.68 mm² of it.
- **STA read the macro's own liberty in all three corners** (`tt_025C_5v00`, `ff_n40C_5v50`,
  `ss_125C_4v50`) at `STAPrePNR` and again at the mid-PNR stages. The `lib:` map in the macro
  declaration is what decides that; had the corner globs been wrong, STA would have treated the
  macro as a black box with no timing arcs, which is a silently wrong timing report rather than
  an error.
- **The reset reached CTS here too** (`reset-cts: i_chip_core.rst_n declared as a CTS clock root`,
  then `CTS-0007 Net "i_chip_core.rst_n" found for clock "ws_reset_1"`), so the reset-tree fix
  from the routing runs applies unchanged with a macro on the die — the two runs' CTS
  assumptions match.

One inherited warning, recorded so it is not mistaken for a defect later: `[STA-1140] library ...
 sram512x8m8wm1__ss_125C_4v50 already exists`. The template's `SRAM_gf180mcu_fd_ip_sram` define
puts the PDK's SRAM liberty into `LIB`, and this macro declaration names the same file; the ws_ip
cells log the same warning for the same reason. OpenSTA keeps the first definition, both are the
same file, and the netlist is unaffected.

## Routing (the measurement this was for)

The knobs are the routing runs' own — `PL_TARGET_DENSITY_PCT 55`, `GRT_ADJUSTMENT` 0.1,
`GRT_ALLOW_CONGESTION true` — so the run is the same flow on one tag, with only the memory's
implementation swapped.

**Both columns are measured on this tag.** `sram03` completed `OpenROAD.GlobalRouting` at 06:27
UTC and stopped at the chain's `-T OpenROAD.GlobalRouting` limit with `SRAM_EXIT:0`; `ffctl01`
ran the same staged tree, image, two flow patches (line-buffered step logs, reset into CTS) and
routing knobs -- `resolved.json` shows `PL_TARGET_DENSITY_PCT 55`, `GRT_ADJUSTMENT 0.1`,
`GRT_ALLOW_CONGESTION true` and a `PDN_CFG` with no macro grids -- to `Flow complete.` at the
same limit. The only difference between the tags is the file pair: `macros_grx930_sram.yaml` +
`grx930_sram_surrogate.yaml` instead of `macros_grx930.yaml` + `grx930_overrides.yaml`. That the
FF tag really was the FF configuration is in its own GRT header: `GRT-0003 Macros: 5` (the ws_ip
cells) against `13` in `sram03` (the same five plus the eight SRAM macros). Records are
`runs/sram03/` and `runs/ffctl01/`. (`sram02` is the run killed at the `-F` mistake above;
`sram01` is the pre-fix one that died at Yosys step 8.)

`ffctl01` cost one thing `sram03` did not: its post-CTS resizer ran 32,120 iterations over
2 h 06 m (16:13 → 18:19 UTC) against 17,240 over 1 h 14 m, and left 30,903 timing-repair buffers
against 13,404. That is the flop array being timed, before routing starts.

| | FF array (1×1, 0.1) | macro surrogate (1×1, 0.1) |
|---|---|---|
| tag | `ffctl01` | `sram03` |
| macros at GRT (`GRT-0003`) | 5 (ws_ip only) | 13 (5 ws_ip + 8 SRAM) |
| instances / netlist | 333,118 | 210,385 |
| sequential cells | 33,868 | 17,658 |
| timing-repair buffers | 30,903 | 13,404 |
| routed nets (`GRT-0014`) | 244,108 | 133,410 |
| GRT extra iterations | 5 of 50 | 5 of 50 |
| final overflow, M1–M5 | 0 / 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 / 0 |
| total GRT usage (peak layer) | 39.57 % (Metal2 56.20 %) | 13.44 % (Metal2 25.89 %) |
| GRT wirelength | 38,304,655 µm | 13,858,798 µm |
| wirelength per routed net | 157 µm | 104 µm |
| `GRT-0115` / `GRT-0183` | absent / absent | absent / absent |
| `GRT-0281` large fanout | 1 net, 1,072 terminals | none |
| GRT runtime | 00:02:03 | 00:00:48 |

**What the table says about feasibility.** The macro bank is not a precondition for global
routing. FF storage reaches overflow 0 on all five layers in the same five extra iterations, with
no `GRT-0115` or `GRT-0183`, so on this tag the router closes either way. The macro bank's value
here is cost, not feasibility.

**What it says about that cost.** The FF column is a larger design — 244 k routed nets against
133 k, 333 k instances against 210 k — so most of the 2.76 × wirelength is the memory being built
out of flops at all, and must not be quoted as router inefficiency. The figure that does not
scale away is utilisation: 39.57 % total with Metal2 at 56.20 %, against 13.44 % and 25.89 %.
Metal2 is where DRT has to jog and escape both macro and standard-cell pins and where antenna
repair adds its detours, and it is the step this family of runs keeps dying in; the FF
configuration leaves it nearly saturated before the first iteration. The 17,500 extra repair
buffers are also ~1.0 mm² of new cells to place, connect and keep on the grid, plus the two hours
of resizer wall clock above.

Wirelength per routed net (157 against 104 µm) is kept in the table because it does not cancel
with size. It is consistent with the flop array's wide read/write cones and the repair buffers'
chains, but it is a property of the netlist, not a congestion verdict.

What this establishes: on one tag and one set of knobs, the memory's implementation changes how
much design the router has to fit (2.76 × wirelength, 2.9 × total utilisation, Metal2 56 % against
26 %) and what the post-CTS repair costs, but not whether global routing converges — both columns
reach zero overflow in five extra iterations with no `GRT-0115` or `GRT-0183`.

## What this does not prove

- **Scale.** Eight macros in one bank is not 320 tiled across four cores. It proves the plumbing,
  not the floorplan of the quad-core.
- **Placement quality.** The bank is fixed by hand in a corner; nothing here says that is where a
  real memory should go, only that a corner bank of this size can be placed, strapped and routed.
- **DRT, antenna repair and 5LM pin access.** Those live in steps this run has not reached. The
  macro's pins are Metal2, which is also where DRT has to jog and escape, so that is the next
  real risk, not a formality.
- **The macro's own DRC/LVS.** The flow reads the PDK's GDS/LEF for the macro; the macro itself is
  the foundry's, so what is unproven is our stitching, not the cell.
