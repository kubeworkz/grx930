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

## DetailedRouting and the antenna repair (tag `ffctl01`, continued)

The comparison above stops where the chain's limit was. The same tag was then resumed with
`-F OpenROAD.CheckAntennas -T OpenROAD.DetailedRouting` (`ws/logs/ws_chain.drt_ffctl01.nohup`,
23:02 UTC), so the database GRT wrote is the one the antenna repair and DRT read: no re-run and no
second placement. `MEMWATCH_FORCE=1` was needed again (no swap on this box); 186 GB was free at
launch.

### The antenna repair terminates on this netlist

`OpenROAD.CheckAntennas` (5:24) found **2,673 net and 4,797 pin violations** after GRT, which
`OpenROAD.RepairAntennas` then worked in six iterations:

| iteration | inserted | violations after |
|---|---|---|
| 1 | 4,314 jumpers, 2,211 nets | 1,261 |
| 2 | 2,897 diodes | 1,337 |
| 3 | 1,786 jumpers, 1,095 nets | 448 |
| 4 | 919 diodes | 364 |
| 5 | 713 jumpers, 343 nets | 62 |
| 6 | 104 diodes | — recheck: **47 net / 69 pin** |

23:33 of insertion plus 4:58 of recheck = 28:32 for the step, with 6,813 jumpers and **3,920
diodes** (1.2 % of the 333,118 instances GRT saw). The recheck leaves 47 net (1.8 %) and 69 pin
(1.4 %): the repair clears 98.2 % / 98.6 % and stops with a bounded residue.

Two details, because both were misread while the die runs were being diagnosed:

- **`GRT-0243 Unable to repair antennas on net with diodes` appears exactly once** in the
  insertion log and is not a step failure. It names the nets that iteration's diode pass cannot
  fix; the loop continues, adds jumpers, and converges. The die run that never converged has the
  same single warning. What separates a converged repair from a failing one is not the warning but
  whether the count keeps falling — 2,963 → 1,261 → 1,337 → 448 → 364 → 62 here.
- The counts are large, but they land *before* routing on a database that still has free tracks.
  The repair that costs is the one over a finished route, below.

### DetailedRouting: pin access is not what fails

Pin access takes 33 s (`DRT-0165` → `DRT-0166`; 8:15 of CPU across 24 threads), the first track
assignment places 616,335 vertical and 963,759 horizontal wires, and neither the step log nor
`warning.log` contains a single `PA-*` message. Metal2 at 56.20 % does not stop pins from getting
an access pattern.

Iterations, read at 02:12 UTC on 29 Oct with pass 4 still in flight (90 %):

| pass | violations | Metal2 markers | M2 shorts | M3 | M4 | M1 | M5 | wall |
|---|---|---|---|---|---|---|---|---|
| 0 | 727,148 | 544,595 (74.9 %) | 497,770 | 121,082 | 27,849 | 31,618 | 1,058 | 15:51 |
| 1 | 522,249 | 397,562 (76.1 %) | 363,469 | 90,503 | 24,564 | 8,358 | 1,080 | 14:20 |
| 2 | 501,062 | 378,319 (75.5 %) | 346,026 | 86,532 | 27,110 | 7,774 | 1,170 | 14:15 |
| 3 | 329,768 | 221,370 (67.1 %) | 202,337 | 73,986 | 26,566 | 4,536 | 3,080 | 48:05 |
| 4 | 302,184 at 90 % | — | — | — | — | — | — | — |

What the table says:

- **Three quarters of the DRC is Metal2, and 91 % of that is shorts** (497,770 of 544,595 in pass
  0). At 56.20 % the layer does not overflow at GRT, but it has no room left to escape in, so the
  router's first answer is to short and its next ones are to pull wire back off Metal2: M2
  wirelength falls 12,425,735 → 10,933,388 µm (−12 %) between pass 0 and pass 3 while its markers
  fall 59 %, and M3–M5 gain markers as the wire moves up (M5 1,058 → 3,080).
- **The curve flattens the way a saturated layer makes it flatten**: 727 k → 522 k → 501 k → 330 k,
  and pass 3 costs 48:05 against pass 1–2's ~14 min because the cheap shorts are gone and what is
  left is rip-up. Pass 4 also stalls *inside* itself — 302,784 at 70 %, then 302,184 at both 80 %
  and 90 % — so the count is no longer responding within a pass either. Peak memory 9.8 GB, so the
  28 GB headroom was never the limit.
- **It does not converge**: pass 8 is the last one the step runs (below), and it ends at 228,958.
  The useful reference is the die netlist at the same knobs (`dielb01`, old box): 493,072 at pass 0
  to 75,459 at pass 8, and even that residue did not survive the next paragraph. `ffctl01`'s pass 4
  finished at 293,189 where the die's finished at 115,794, and its pass 8 at 228,958 against the
  die's 75,459.

### The wall after the first route

LibreLane's DRT step does not stop when `detailed_route` converges. It runs `check_antennas` on the
routed database, repairs what the *routing itself* created, and then re-routes the whole design
with those diodes in place. `dielb01` (die netlist, old box, same DRT step) is the measured
example of what that costs:

| | first route | after the post-route repair |
|---|---|---|
| pass 0 | 493,072 | 577,541 |
| pass 1 | 273,018 | 297,670 |
| pass 2 | 251,238 | 275,717 |
| pass 3 | 145,610 | 258,713 |
| pass 4 | 115,794 | 252,020 |
| pass 5 | 100,323 | 246,719 |
| pass 6 | 89,865 | 242,753 |
| pass 7 | 83,375 | 239,227 |
| pass 8 | 75,459 (`DRT-0198 Complete detail routing`) | in flight, 60 % at 238,120 when the arm was stopped |

Between the two routes: `ANT-0002/0001 Found 1,055 net / 1,341 pin violations` — created by the
routing, not inherited from GRT — then `GRT-0012 Found 1,269`, one `GRT-0243`, `Inserted 1,710
diodes`.

The second route starts **above** the first (577,541 against 493,072) from a database that already
holds a converged 75,459 route. Its pass 4 finishes at 252,020 where the first route finished at
115,794; pass 7 ends at 239,227; and pass 8 is still at 238,120 when it is 60 % done — the count
has stopped responding to rip-up. That is the wall, and it is the one the die arms spent days
against: the first route is the cheap part, the second is the expensive one because every diode
is a new cell whose pin needs Metal2 on a net that was already over the antenna ratio.

`ffctl01` reached it at 05:13 on 29 Oct and arrived at the second route with more to repair than
the die had: 1,494 net / 2,140 pin and 2,615 diodes against the die's 1,055 / 1,341 and 1,710.
What the three routes that followed measured is next.

### Past pass 8: three routes, and none of them converges

Whether the first route converges *if it is allowed past pass 8* is decided by the step's own
script, not by the curve. LibreLane's `drt.tcl` routes once and then loops:

```tcl
while {$i <= $::env(DRT_ANTENNA_REPAIR_ITERS) && [log_cmd check_antennas]} {
    set diodes_inserted [log_cmd repair_antennas {*}$arg_list]
    if {$diodes_inserted || $::env(DRT_ANTENNA_REPAIR_JUMPER_ONLY)} {
        drt_run $i {*}$drt_args
    } else { break }
    incr i
}
```

Every `drt_run` carries `-droute_end_iter $DRT_OPT_ITERS`, and both knobs are set: `DRT_OPT_ITERS`
8 and `DRT_ANTENNA_REPAIR_ITERS` 10 (`grx930_overrides.yaml`). So **no route in this flow can run
past pass 8** — it stops on iteration count, not on convergence — and what follows is not a retry
but a repair and a restart. The answer is no: the first route exhausts its budget at 228,958
violations, 31.5 % of its pass-0 count. The run has been through the loop three times.

| pass | route 0 (`drt-run-0`) | route 1 (`drt-run-1`) | route 2 (`drt-run-2`) |
|---|---|---|---|
| 0 | 727,148 | 1,026,436 | 1,314,859 |
| 1 | 522,249 | 748,790 | 1,133,696 |
| 2 | 501,062 | 716,330 | 1,111,370 |
| 3 | 329,768 | 655,479 | 1,070,822 |
| 4 | 293,189 | 634,612 | 1,052,063 |
| 5 | 273,202 | 620,213 | in flight |
| 6 | 256,396 | 608,932 | — |
| 7 | 244,347 | 601,260 | — |
| 8 | **228,958** | **588,901** | — |
| cleared | 68.5 % | 42.6 % | 20.0 % at pass 4 |
| route wall | 5:16:02 | 6:32:34 | 2:35:17 so far |

Pass walls in the same order — route 0: 15:51, 14:20, 14:15, 48:05, 44:48, 45:43, 43:29, 43:07,
46:11; route 1: 9:44, 7:13, 6:00, 59:11, 59:43, 1:00:11, 57:14, 59:40, 1:13:23; route 2: 7:30,
5:52, 4:50, 1:08:02, 1:09:03. The shape inverts between the first route and the re-routes: route 0
pays for a full route in pass 0 (15:51) and then settles at ~45 min once the cheap shorts are gone,
while routes 1 and 2 arrive with a routed database, spend 5–10 min on passes 0–2, and cost ~1 h per
pass from pass 3 — more than route 0's, because they are ripping up a database that already carries
600 k–1.1 M markers. Counts read at 14:47 UTC on 29 Oct, route 2's pass 5 having started at 14:37.

Between the routes the antenna repair keeps working and keeps losing ground on the DRC:

| after | `ANT-0002` / `ANT-0001` | `GRT-0012` | diodes inserted | `GRT-0243` |
|---|---|---|---|---|
| route 0 | 1,494 net / 2,140 pin | 1,709 | 2,615 | 1 |
| route 1 | 658 net / 845 pin | 817 | 1,089 | 1 |

The antenna count falls 56 % and 60 % across the two rounds and 3,704 post-route diodes are now in
the design, while each following route starts *above* what the last one ended at: 1,026,436 against
228,958 (4.5 ×), then 1,314,859 against 588,901 (2.2 ×). The fraction cleared per route falls
68.5 % → 42.6 % → 20.0 %. That is the die's second-route wall, reproduced on a bigger netlist, and
it is not a stall the curve guard should stop: every pass of route 2 still improves by
1.7 %–13.8 %, against a plateau threshold of 0.25 %, and neither the 2 h per-iteration nor the 8 h
per-route budget has been reached (`stall=0` throughout).

### Why each restart starts worse: 50 `buf_12`s carrying 7,409 loads

The database each repair hands back is not the one the previous route met. Step 35
(`openroad-resizertimingpostcts`) inserted 50 buffers whose names begin `split`, every one a
`gf180mcu_fd_sc_mcu7t5v0__buf_12`, and their outputs carry **7,409 loads between them**, from 11
pins to 1,072. There are none at `openroad-cts` (step 33) and 50 after it.

| instance | source net | loads |
|---|---|---|
| `split` | `u_core.u_rom.line_p1[2]` | 1,072 |
| `split4` | `…pipe_instr_if_id.o_pipe_out[15]` | 659 |
| `split2` | `u_core.u_rom.line_p1[2]` | 537 |
| `split10` | `…pipe_instr_if_id.o_pipe_out[20]` | 415 |
| `split39` | `…pipe_instr_if_id.o_pipe_out[15]` | 330 |
| `split487` | `…pipe_instr_if_id.o_pipe_out[16]` | 323 |
| `split3` | `u_core.u_rom.line_p1[3]` | 323 |
| `split5` | `u_core.u_rom.line_p1[2]` | 269 |

The ROM decode is `i_chip_core.u_core.u_rom.line_p1[*]` and the IF/ID pipeline register is
`i_chip_core.u_core.u_cpu.u_riscv_core_pipe_instr_if_id.o_pipe_out[*]`. The five copies of
`line_p1[2]` split its 2,083 sinks into groups of 1,072, 537, 269, 136 and 69: the split is one
level deep and the largest group is never split again. `o_pipe_out[15]`'s three copies carry 1,155.
`MAX_FANOUT_CONSTRAINT` is 10 in that step's own environment, so the constraint is not what
governed the group size.

This is the pattern the reset fix removed one instance of: `split25` was the reset's buffer with
2,132 loads on a 21–47 ns transition, and constraining reset nets before CTS so a real tree gets
built is what took it out. Nothing constrains the ROM decode or the IF/ID pipeline outputs, so the
post-CTS resizer splits them once and stops, and DRT inherits the result; `split25` itself is back
in this netlist, driving `line_p1[4]` with 144 loads.

The antenna repair then works on exactly those nets. Both rounds log `GRT-0281 Net net has a large
fanout of 1072 terminals` and name `net2` 537, `net3` 323, `net4` 659, `net5` 269, `net6` 243,
`net9` 165, `net10` 415 — the same buffers, within three pins of the netlist count. Every diode
inserted there is one more pin on a net that already has a thousand, so the repair and the re-route
work against each other: round 1 adds 2,615 diodes and the next route starts 4.5 × higher, round 2
adds 1,089 and it starts 2.2 × higher again.

### What past pass 8 settles

- **The first route does not converge, and cannot in this flow.** It stops at pass 8 with 228,958
  because `DRT_OPT_ITERS` is 8; nothing re-enters DRT to finish it, because the only re-entry point
  is after an antenna repair has changed the netlist.
- **A re-route is a worse restart, not a continuation.** 1,026,436 and 1,314,859 at pass 0 against
  228,958 and 588,901 at the previous route's pass 8, with the fraction cleared per route falling
  68.5 % → 42.6 % → 20.0 %.
- **The step's worst case is 11 routes.** With `DRT_ANTENNA_REPAIR_ITERS` 10 the loop can repair ten
  times; at the 5–7 h these three have taken, that is 55–75 h inside a single step. The curve
  guard's 8 h per-route ceiling bounds that, and bounds it the other way too: a route that overruns
  is stopped rather than allowed to finish, so with this guard the loop will not reach ten repairs.
- **The FF column's DRT failure is overdetermined.** It carries both the Metal2 saturation recorded
  above and 7,409 sinks on 50 single-gate nets. This run cannot separate them, so it is not evidence
  that Metal2 at 56.20 % is unroutable *on its own* — a gate output with 1,072 pins is a routing
  problem on any layer, and at 56.20 % there is no Metal2 to absorb it. The fanout constraint is the
  cheaper of the two to fix and the one to fix first; until it is, the macro column's case rests on
  GRT headroom (Metal2 25.89 % against 56.20 %) rather than on DRT experience, because `sram03` has
  not been through this step at all.

The pass that tests that last point is wired: `ws/tools/librelane_fanout_split_patch.py` puts a
fanout-only `repair_design` into the post-CTS resizer — the transition and capacitance limits raised
for the call and restored after it, so fanout is the only violation class it answers — armed by
`WS_FANOUT_SPLIT=1` and forwarded by `build/ws_chain.sh`. Arm `fanout01` (launched 15:25 UTC on
29 Oct, `WS_FANOUT_SPLIT_PASSES=2`) measured what the pass does to this netlist:

| | nets over 10 loads | worst net |
|---|---|---|
| before the pass | 2,272 | 1,071 (`net`, the `split` buffer's output) |
| after `repair_design` pass 1 | 2,123 | 15 (`clknet_leaf_912_clk_PAD2CORE`) |
| after pass 2 | 2,123 | 15 |

`[RSZ-0038] Inserted 10267 buffers in 3517 nets` — 10,291 cells in total, +3.0 % of the 340k
instances — and the second call moved nothing, so the loop stopped there. The four-digit nets are
gone; what survives is the CTS clock leaves at 11-15 loads, which the second call does not touch.
On the die the same pass stopped at 172 after three levels (`ws/probe/reset_tree_fix.tcl`), so 15 is
this netlist's floor, not a general claim about `repair_design`.

The arm was resumed at `OpenROAD.GlobalRouting` at 19:43 UTC and **never reached DRT**. At 19:57 it
aborted inside the antenna-repair composite's diode insertion:

```
[INFO GRT-0015] Inserted 2120 diodes.
[WARNING GRT-0243] Unable to repair antennas on net with diodes.
[ERROR GRT-0183] Net clknet_leaf_2609_clk_PAD2CORE: heap underflow during 3D maze routing.
Error: antenna_repair.tcl, 27 GRT-0183                       (WS_EXIT:2)
```

That arm produced no pass-0 count of its own. What it did measure is the whole pre-DRT path on
ffctl01's image, config and knobs, with only the fanout split added — and the short count was then
measured on a tag forked from this one, with the repair step out of the way (below):

| | ffctl01 (no split) | fanout01 (split) | delta |
|---|---|---|---|
| instances at CheckAntennas | 333,118 | 343,409 | +10,291 (+3.0 %) |
| die area | 20.14 mm² | 20.14 mm² | — |
| `antenna__violating__nets` | 2,673 | 2,461 | −212 (−7.9 %) |
| `antenna__violating__pins` | 4,797 | 3,448 | −1,349 (−28.1 %) |
| CheckAntennas wall | 5:24 | 3:18 | −2:06 |
| diodes inserted | 3,920 (2,897 + 919 + 104, one call) | 2,120, then abort | — |
| GRT overflow, all layers | 0 | 0 | — |
| Metal2 usage at GRT | 56.20 % | 57.01 % | +0.81 pp |
| DRT pass 0 | 727,148 | not reached in this arm | below |

Two things follow. **The split is the first change on this netlist to move the antenna metric**: a
quarter of the violating pins and an eighth of the nets, for 0.81 pp of Metal2 (the 10,291 cells) and
no overflow anywhere. And **the crash is an engine bug, not a design verdict**: `GRT-0183 heap
underflow during 3D maze routing` is the same abort that stopped the die at
`RUN_ANTENNA_REPAIR=false`, it happens inside OpenROAD's own maze router, and ffctl01's tree has no
`GRT-0183` in it at all — ffctl01 hit only the tolerated `GRT-0243` and finished the repair in 28:32.
The net it died on, `clknet_leaf_2609_clk_PAD2CORE`, is one of the 2,123 CTS clock leaves left at
11-15 loads after the split; whether that particular net was one of the ones re-buffered is not
something the log says.

### Catching GRT-0183 does not save the step

`ws/tools/librelane_antenna_catch_patch.py` (wired by `lln_antenna_catch.sh` into `ws_exec.sh`) wraps
the `log_cmd repair_antennas` call in `catch`, so the abort ends the call instead of the process. It
works — the step log carries `PATCH_LNN_ANTENNA status=caught error="GRT-0183"` and the step writes a
database with all 2,120 diodes in it. It is not enough, for a reason the abort's message does not say:

**`repair_antennas` rips up global routing before it legalizes the diodes it inserted.** A call that
aborts therefore leaves the database *unrouted*, and the composite's next sub-step fails with
`[ANT-0008] No detailed or global routing found` — a different error, from a different step, on a
database that looks complete. Two levers were measured to see whether the abort could be avoided
instead of survived, both on the routed pre-repair database, both still fatal:

| override | iterations | allow_congestion | outcome |
|---|---|---|---|
| none (the original arm) | 3 | yes | GRT-0183 after 2,120 diodes |
| `GRT_ANTENNA_REPAIR_ITERS=1` | 1 | yes | GRT-0183 after 2,120 diodes |
| `GRT_ANTENNA_REPAIR_ITERS=1` + `GRT_ALLOW_CONGESTION=false` | 1 | no | GRT-0183 after 2,120 diodes |

So the crash is inside the *first* iteration's legalize re-route (GRT-0015 prints its diode count
before that re-route, which is why the count looks like a completed iteration), and it is not the
congestion allowance: the router underflows with the budget open or closed. Catching it and then
re-running global routing inside the catch would put a second router in the flow and change the very
distribution DRT is being asked about, so the pair below skips the composite on **both** tags
(`-c RUN_ANTENNA_REPAIR=false`) instead, and runs one optimization pass on each (`-c DRT_OPT_ITERS=1`)
so the step finishes and OpenROAD prints its per-layer table.

The two arms are the same engine, config, seed (`-or_seed 42`), image and step sequence; the only
difference between them is the post-CTS fanout pass. `ffctl02` is `ffctl01`'s tree forked at its last
pre-repair step (the repair-composite step removed), `fanout02` is `fanout01`'s forked the same way.

| pass 0 | ffctl02 (no split) | fanout02 (split) | delta |
|---|---|---|---|
| violations | 336,176 | 356,363 | +20,187 (+6.0 %) |
| Metal2 markers | 268,293 (79.8 %) | 283,766 (79.6 %) | +15,473 (+5.8 %) |
| Metal2 shorts | 234,502 | 249,307 | +14,805 (+6.3 %) |
| Metal3 shorts | 34,675 | 38,923 | +4,248 (+12.3 %) |
| Metal1 shorts | 10,070 | 8,751 | −1,319 (−13.1 %) |
| Metal2 spacing | 19,424 | 19,982 | +558 |
| wirelength | 33.17 mm | 33.78 mm | +1.8 % |
| vias | 1,810,830 | 1,875,888 | +3.6 % |
| pass wall / cpu | 10:00 / 2:25:05 | 10:21 / 2:33:36 | +21 s / +5.9 % |

**The split costs 6 % more DRC, it does not save it.** The pass bounded 2,272 over-fanout nets and
removed the 1,072-pin `split` buffer the previous section named as the routing problem, and pass 0
got worse: Metal2 shorts +6.3 %, Metal3 shorts +12.3 %, wirelength +1.8 %, vias +3.6 %. The only
column that improved is Metal1 shorts, and that is the layer with the most room. Ten thousand extra
buffers are ten thousand extra pins in a design whose Metal2 is at 56 % before they arrive; bounding
a fanout moves the shorts rather than removing them.

That leaves the bigger number the same pair exposes. Running the *same* netlist with the antenna
repair applied (`ffctl01`, 3,920 diodes and jumpers plus the repair's own re-route) cost:

| pass 0 | ffctl02 (no repair) | ffctl01 (repair applied) | delta |
|---|---|---|---|
| violations | 336,176 | 727,148 | +116 % (2.16 ×) |
| Metal2 markers | 268,293 (79.8 %) | 544,595 (74.9 %) | 2.03 × |
| Metal2 shorts | 234,502 | 497,770 | 2.12 × |
| wirelength | 33.17 mm | 33.45 mm | +0.8 % |
| vias | 1,810,830 | 1,887,507 | +4.2 % |
| pass wall | 10:00 | 15:51 | +59 % |

Same netlist, same engine, same seed, 0.8 % more wire — and more than twice the DRC. 3,920 diode and
jumper insertions on 2,461 nets that are already the densest in the design are the largest single
term measured in this whole column, larger than the fanout nets and larger than the Metal2
utilisation change the split caused. The die's own record says the same thing in the other direction:
every re-route after a repair started above where the previous one ended.

### What this changes

- **Antenna repair is not the blocker the die runs made it look like, on ffctl01's netlist.** It
  converges in six iterations and 28:32 to a 47/69 residue. The repair that fails there is the one
  over a finished route, not the one over the GRT database. The exception is the split netlist
  above, which aborts inside the diode insertion before it can report a residue at all.
- **5LM pin access is proven at Metal2 56.20 %.** Every pin gets an access pattern; no `PA-*` in
  the log or in `warning.log`.
- **Metal2 at 56.20 % is not, however, a routing-viable utilisation.** Three quarters of the DRC is
  Metal2, 91 % of that is shorts, one pass costs 48 minutes, and the curve is roughly twice the
  die's at the same pass. That is the macro bank's case made by DRT rather than by GRT headroom:
  `sram03` sits at Metal2 25.89 % / 13.44 % total and has the room this column does not. The
  qualification that used to sit here — that this column also carries 50 single-gate nets with 7,409
  sinks, so the shorts could not be attributed to the layer alone — is now measured rather than open:
  bounding those nets costs 6 % more DRC (pass 0, above), so they are not what produced 727,148.
- **The fanout constraint is not the DRT fix.** It is worth what it costs the antenna metric (−28.1 %
  pins for +0.81 pp of Metal2) and nothing at DRT (+6.0 % violations, +6.3 % Metal2 shorts). The two
  changes that would move the short count are a database that does not carry 3,920 post-route diode
  insertions (2.16 × the DRC) and a column that is not at 56 % Metal2 before routing starts.

## What this does not prove

- **Scale.** Eight macros in one bank is not 320 tiled across four cores. It proves the plumbing,
  not the floorplan of the quad-core.
- **Placement quality.** The bank is fixed by hand in a corner; nothing here says that is where a
  real memory should go, only that a corner bank of this size can be placed, strapped and routed.
- **The macro column past global routing.** `ffctl01` has now been through antenna repair and into
  DRT (above); `sram03` has not. Nothing here says a macro bank at Metal2 25.89 % routes cleanly —
  only that it has the headroom the FF column did not. That comparison needs `sram03` resumed the
  same way, with the same two patches and the same `-F`/`-T` pair.
- **A finished DRT on either column.** `ffctl01` has now been through three routes and none of them
  converged (above), and the die's post-route re-route did not either. Route 2 is still running and
  `sram03` has not been through this step at all, so the second-route wall is measured on the die
  netlist and on this tag, not on the macro column.
- **The macro's own DRC/LVS.** The flow reads the PDK's GDS/LEF for the macro; the macro itself is
  the foundry's, so what is unproven is our stitching, not the cell.
