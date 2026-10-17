# ws_v2 template run — landed

**Verdict (2026-10-13 06:49:39 UTC): the run is dead.** It is **not** a stream-out and **not** a
DRC failure. LibreLane aborted at **step 31 of 83**, `OpenROAD.RepairDesignPostGPL`, with a single
OpenROAD error:

```
[DPL-0036] Detailed placement failed.
```

Nothing physical was written: a full walk of the run tree finds **no `.gds`, no `.oas`, no `.spef`**.
The only GDS files anywhere under `ws/` are the five template **input** macro layouts
(`ip/gf180mcu_ws_ip__{project_id,marker,logo,qrcode_id,shuttle_id}/gds/*.gds`, 0.8–106 kB), which
ship with the template and are read, not produced. The only layouts the flow wrote are the 9
intermediate `chip_top.def` files, the newest being step 27's global-placement DEF — 13, 16, 17,
18, 19, 20, 22, 25, 27, and **nothing from steps 28–31**.
31 step directories exist out of 83; the flow never reached CTS, global route, detailed route or
stream-out.

## The evidence, from the run's own files

Run tree: `/home/ubuntu/grx930_ol2/ws/template/librelane/runs/ws_v2` on `ubuntu@49.13.6.8`.

### 1. The abort itself

`31-openroad-repairdesignpostgpl/or_metrics_out.json` (the step's own metrics):

```json
{
  "timing__drv__floating__nets": 0,
  "timing__drv__floating__pins": 0,
  "flow__warnings__count": 52,
  "flow__errors__count": 1,
  "flow__warnings__count:STA-1140": 52,
  "flow__warnings__type_count": 1
}
```

`runs/ws_v2/error.log` (run-level, entire file — one line):

```
[DPL-0036] Detailed placement failed.
```

`runs/ws_v2/flow.log` tail and `logs/ws_flow.ws_v2.log` tail agree, and the chain log carries the
LibreLane-level attribution and the process status:

```
[06:49:38] ERROR  The following error was encountered while running the flow:
                  OpenROAD.RepairDesignPostGPL failed with the following errors:
                  [DPL-0036] Detailed placement failed.
[06:49:38] ERROR  LibreLane will now quit.        __main__.py:190
WS_EXIT:2
```

The 52 warnings are all `[STA-1140] ... library ... already exists` (duplicate Liberty reads) — noise,
not the cause.

### 2. Where in step 31 it died

`31-.../openroad-repairdesignpostgpl.log`, in order:

```
136:  + repair_design -verbose -max_wire_length 0 -slew_margin 20 -cap_margin 20
137:  Iteration |   Area    | Resized | Buffers | Nets repaired | Remaining
      ... 209000 iterations of the RSZ meter, Area climbing +31.2 % then +31.9 % ...
      final |    +79.9% |    6043 |   97969  |     17652     |     0
351:  [INFO RSZ-0034] Found 17577 slew violations.
352:  [INFO RSZ-0035] Found 98 fanout violations.
353:  [INFO RSZ-0036] Found 6776 capacitance violations.
354:  [INFO RSZ-0039] Resized 6043 instances.
355:  [INFO RSZ-0038] Inserted 97969 buffers in 17652 nets.
356:  [INFO RSZ-0042] Inserted 178 tie gf180mcu_fd_sc_mcu7t5v0__tiel instances.
357:  [INFO RSZ-0042] Inserted 125 tie gf180mcu_fd_sc_mcu7t5v0__tieh instances.
358:  + detailed_placement -max_displacement  1500 500
359:  [INFO DPL-0034] Detailed placement failed on the following 23 instances:
      ... 23 × [INFO DPL-0035] names (_205142_, _271738_, _204056_, _205638_, _270153_, ...) ...
383:  [ERROR DPL-0036] Detailed placement failed.
384:  Error: repair_design.tcl, 71 DPL-0036
```

So the landing is: repair inserts **97,969 buffers into 17,652 nets** — the net count goes
~32 k → **97,969**, area **+79.9 %** — and the detailed placement that step 31 runs immediately
afterwards cannot legalize 23 of the resulting instances and fails the flow.

`-max_displacement 1500 500` is this design's own knob, `PL_MAX_DISPLACEMENT_X: 1500` /
`PL_MAX_DISPLACEMENT_Y: 500` from
[grx930_overrides.yaml](../c930/asic_gf180mcu/wafer_space_integration/grx930_overrides.yaml).

### 3. Why the repair exploded — the two steps before it

**Step 30, `openroad-stamidpnr`** (mid-PnR STA, before repair) already reported a design drowning
in drive-strength violations:

```
max slew violation count 157453
max cap  violation count   5945
max fanout violation count   99
```

and in the `.rpt` sidecars:

| Metric | Value | Constraint |
|---|---|---|
| `report_clock_min_period` on `clk_PAD` | **614.47 ns** (fmax 1.63 MHz) | 40 ns (25 MHz) |
| WNS (setup, `nom_tt_025C_5v00`) | **−574.47 ns** | 0 |
| TNS (setup, `nom_tt_025C_5v00`) | **−1 928 283.5 ns** | 0 |

157 k slew violations is what the resizer is answering when it inserts 98 k buffers. The ~614 ns
min period matches the −574 ns WNS, i.e. one real long path — worth checking against the pad-ring/
clock not yet being propagated (`unpropagated.rpt` is 0 bytes) before treating it as a true core
path.

**Step 27, `openroad-globalplacement`** handed a congested, over-inflated placement to that repair:

```
[INFO GPL-0089] Routability finished. Reverting to minimal observed routing congestion, could not reach target.
[INFO GPL-1005] Routability final weighted congestion: 1.2517        (> 1 = congested)
[INFO GPL-1002] Placed Cell Area             6551627.0584
[INFO GPL-1004] Minimum Feasible Density     0.4300
[INFO GPL-1007]   - For 90% usage of free space: 0.5808
[INFO GPL-1012] Total routability artificial inflation: 775090.73 (+14.60%)
[INFO GPL-1014] Final placement area: 6551627.06 (+23.42%)
```

Density itself is *not* the problem — minimum feasible is 0.43 against the 0.55 target — but
routability explicitly **could not reach target**, and placement area was inflated +23.42 % before
the resizer then grew it another +79.9 % on top.

### 4. Timeline

| Event | UTC |
|---|---|
| Container start | 2026-10-12 23:03:34 |
| Step 31 begins (`repair_design` running) | 23:49:04 |
| RSZ finishes, DPL begins | 00:16:50 |
| DPL fails, flow aborts | 06:49:38 |
| Container end | 2026-10-13 06:49:39 |
| `docker inspect` | `running=false exit=0 oom=false` |

Total 7 h 46 m. Step 31 alone was **7 h 00 m**, of which **6 h 33 m** was the single-threaded
`detailed_placement` that then failed — CPU time tracked wall time 1:1 on one core throughout, and
`ws_v2.errors.log` stayed 0 bytes until the abort line was emitted at 06:49:37. Both watchers caught
the finish on their own: the 1-min landing watcher at 06:49:44Z, the 10-min heartbeat at 06:53:12Z
(its own previous poll had been 06:43, i.e. still mid-DPL).

**Gotcha for the harness:** `docker inspect` reports `ExitCode=0` even though the flow failed,
because `ws_exec.sh`'s last command is `echo "WS_EXIT:$?"` — the script always exits with `echo`'s
status. The real status is in the chain log (`WS_EXIT:2`, same as `ws_v1`) and in the presence of
`runs/<tag>/error.log`. Any script that keys off `docker run`'s exit code will call this run a
success.

### 5. Contrast with ws_v1

| Run | Landed at | Cause |
|---|---|---|
| `ws_v1` | step **11/83**, `OpenROAD.CheckMacroInstances` | `No macro instance i_chip_core.sram_0 found.` / `sram_1` → `WS_EXIT:2` |
| `ws_v2` | step **31/83**, `OpenROAD.RepairDesignPostGPL` | `[DPL-0036] Detailed placement failed.` → `WS_EXIT:2` |

The fixed RTL (SRAM actually instantiated) carried the run 20 steps further: through lint, synth,
pad ring, tap/endcap, PDN, macro placement, and the power-grid checker. The wall it hit is new and
sits in placement/repair, not in the netlist.

## What this implies for the next attempt

- The failure is a **repair-induced placement blow-up**, not a routing or sign-off failure, and it
  happens before CTS — so nothing downstream has been exercised yet.
- Cheapest first lever: the post-GPL repair is inserting 98 k buffers to chase 157 k slew
  violations that exist *before* CTS and with the clock not yet propagated. Bounding that repair
  (`RSZ_*` limits / skipping `RepairDesignPostGPL` / a `--skip` for the step) is likely to let the
  flow through to CTS and routing, where the real congestion verdict lives.
- Second lever: widen or drop `PL_MAX_DISPLACEMENT_X/Y` — the DPL that failed is running with the
  design's own ±1500/±500 µm window, which is exactly what constrains legalizing 98 k fresh buffers.
- Third: attribute the −574 ns WNS / 614 ns min period before treating it as the core's fault; a
  non-propagated clock in mid-PnR STA is a classic phantom long path.
- Everything in this file is evidence from one run's own logs. No step of it is CI-verified, and no
  physical result (GDS, DRC, LVS) exists yet to verify.

## Watchers (both finished cleanly, `PPID 1`, logs durable)

| Log | Content |
|---|---|
| `ws/logs/ws_v2.landing.log` | 27 kB — 1-min poll, then the `FINAL` block at 06:49:44Z with container state, 31 step dirs, last 4 steps' listings + log tails + ERROR lines, `flow.log` tail, disk |
| `ws/logs/ws_v2.watch.log` | 12 kB — 10-min heartbeat through to the chain's own end marker `[Tue Oct 13 06:50:03 AM UTC 2026] WS_CHAIN_COMPLETE`, then `line 47: FINAL exit=0 oom=false finished=2026-10-13T06:49:39` |
| `ws/logs/ws_v2.errors.log` | the three abort lines, first written 06:49:37Z |
