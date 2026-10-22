# Where the 157,453 pre-CTS slew violations come from

Question: is it the unpropagated clock, a slew margin, or real high-fanout nets in the core?

**Answer: roughly a quarter is the unpropagated clock and reset (structural to pre-CTS), three
quarters is real fanout in the synthesized core — and the margin is not a contributor at all.**
The single worst *setup* path in the design turns out to be one of the same nets, which is what
makes this worth reading rather than arguing about.

Everything below comes from the ws_v2 run tree on `ubuntu@49.13.6.8`
(`/home/ubuntu/grx930_ol2/ws/template/librelane/runs/ws_v2`), mostly from step 30
(`30-openroad-stamidpnr`, the last step before the failure) and from the step-27 global-placement
netlist. Nothing here is modelled or scaled.

## 1. The measurement and its limit

The count itself is a LibreLane metric, one corner, pin-level:

```
30-.../openroad-stamidpnr.log:
  max slew violation count 157453
  Writing metric design__max_slew_violation__count__corner:nom_tt_025C_5v00: 157453
  max fanout violation count 99
  Writing metric design__max_fanout_violation__count__corner:nom_tt_025C_5v00: 99
  max cap violation count 5945
```

`157,453` is the `nom_tt_025C_5v00` corner alone, not a sum over corners. The step's
`report_check_types -max_slew -max_cap -max_fanout -violators` listing (in the same 29 MB log)
gives each violating pin with its limit and its actual slew:

```
_276882_/A1                             3.000000  963.210266 -960.210327 (VIOLATED)
```

so in force the limit is **3.000000 ns** and the violations are **10x to 300x over it**. Where the
3 comes from, from the design's own resolved config and the PDK:

| fact | value | source |
|---|---|---|
| `MAX_TRANSITION_CONSTRAINT` | 3 (ns, since `time_unit = 1ns`) | resolved config; applied by the template's SDC |
| library per-pin `max_transition` | 4 on 836 pins; no `default_max_transition` | `gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib` |
| SDC line | `set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]` | `librelane/chip_top.sdc:36` |

The tighter of the two applies, which is the SDC's 3 ns — matching the listing exactly. A design
rule of 3 ns on a 40 ns clock is not a mis-set constraint; it is the template's, and the library
agrees to within 1 ns.

## 2. Decomposition: pins grouped by identical slew value

Two pins on the same net see the same slew, so grouping the violating pins by their slew value
separates nets. From the step-30 log:

| rank | pins | slew (ns) | net | share |
|---|---|---|---|---|
| 1 | **33,868** | 278.127594 | `clk_PAD2CORE` — the clock | 21.5 % |
| 2 | **4,265** | 66.947853 | `i_chip_core.rst_n` — the reset | 2.7 % |
| 3 | 2,228 | 963.210266 | `u_core.u_rom.line_p1[2]` | 1.4 % |
| 4 | 1,299 | 429.254730 | `u_cpu.pipe_instr_if_id.o_pipe_out[15]` | 0.8 % |
| 5 | 814 | 296.325195 | `...pipe_instr_if_id.o_pipe_out[20]` | 0.5 % |
| 6 | 713 | 406.082733 | `u_core.u_rom.line_p1[3]` | 0.5 % |
| 7 | 670 | 265.095245 | `...pipe_instr_if_id.o_pipe_out[16]` | 0.4 % |
| 8 | 502 | 223.545242 | `...pipe_instr_if_id.o_pipe_out[21]` | 0.3 % |

The same two nets appear at the head of the step-27 `max.rpt` path report, which is where their
fanouts are printed:

```
 33868  194.810135  278.127594 ...  clk_pad/Y (gf180mcu_fd_io__in_s)      -> clk_PAD2CORE (net)
  4265   42.269146   66.947853 ...  rst_n_pad/Y (gf180mcu_fd_io__in_c)    -> i_chip_core.rst_n (net)
  2227   21.165524  963.210266 ...  _351819_/Q (dffrnq_1)                -> u_rom.line_p1[2] (net)
```

## 3. Cross-check against the netlist

Counting connections per net in `27-openroad-globalplacement/chip_top.nl.v` (38 MB, 687,550
connections):

```
>10 connections : 13,180 nets carrying 195,934 pins
>100            :     30 nets carrying  49,026 pins
>1000           :      4 nets carrying  41,662 pins
```

**157,453 of those 195,934 pins violate = 80 %.** The violating set *is* the high-fanout set; the
three biggest nets alone (clock, reset, `line_p1[2]`) carry 40,361 pins.

The 30 nets over 100 connections, by hierarchy:

```
33869 clk_PAD2CORE                             4266 i_chip_core.rst_n
2228 u_rom.line_p1[2]                           713 u_rom.line_p1[3]              362 u_rom.line_p1[4]
1299 u_cpu.pipe_instr_if_id.o_pipe_out[15]      814 ...[20]    670 ...[16]    502 ...[21]   157 ...[17]   129 ...[18]
 479 u_cpu.pipe_alu_result_ex_mem.o_pipe_out[0] 135 ...[1]
 366 u_cpu.pipe_pcf_if.o_pipe_out[0]            158 ...[1]
 307 u_cpu.pipe_isword_id_ex.o_pipe_out[0]      176 u_cpu.pipe_alucontrol_id_ex.o_pipe_out[0]  150 ...[1]
 252 u_sram.rd_addr_p1[7]                       203 u_sram.rd_valid_p1
 260 u_uart.tx_fifo_rd_ptr[0]                   131 ...[1]     69 ...[2]   133 u_uart.rx_fifo_rd_ptr[0]
 243 u_cpu.mul_div.booth.state_reg              111 u_cpu.mul_div.non_restoring.state_reg
 234 u_cpu.csr_unit.current_state               226 u_cpu.dcache_top.dcache_controller.STATE[3]
 150 u_cpu.mul_div.srcA_reg[63]                 140 u_cpu.csr_unit.mstatus[8]   163 line_from_rom
```

These are ordinary RTL broadcasts — pipeline register bits consumed by a wide datapath, the RTL
SRAM's address/valid, UART FIFO pointers, cache and CSR state. Not a coding error; exactly what a
buffer tree is for.

## 4. The three hypotheses, scored

**The unpropagated clock: real, and exactly one fifth.** `30-.../clock.rpt`:

```
Clock: clk_PAD
Sources: clk_pad/Y
Generated: no
Virtual: yes
Propagated: no
Period: 40.000000
```

Pre-CTS the clock is one ideal net, and `clk_pad/Y` drives all 33,868 flops directly, so every one
of their CK pins violates — 21.5 % of the total, the single largest bucket. CTS replaces that net
with a tree; this category exists only in the pre-CTS netlist. The reset is the same shape (one
pad input to 4,266 async reset pins), another 2.7 %. **Together 24 % — real, quantified, and
self-correcting at CTS for the clock at least.**

Worth flagging separately: the clock is created on the *pin* `clk_pad/Y`, not on the port
(`CLOCK_PORT: clk_PAD`, `CLOCK_NET: clk_pad/Y` in the template's config, so the SDC's
`else` branch runs), and OpenSTA reports it `Virtual: yes, Propagated: no` while the path reports
in `max.rpt`/`checks.rpt` annotate a *propagated* clock network delay. Both cannot be literally
true. The post-CTS `clock.rpt` in the running ws_v3 run (step 38) settles it; if it still reads
`Propagated: no` after CTS, the sign-off STA is using an ideal clock and that is its own bug,
independent of this question.

**The slew margin: not a contributor.** LibreLane's `DESIGN_REPAIR_MAX_SLEW_PCT` (default 20) only
derates the target to `limit × (1 − margin/100)` = 2.4 ns. Against actual slews of 278/429/963 ns
it changes nothing, and that is measured, not argued: setting both margins to 0 in the isolated
step-31 probe (`wafer_space_integration/probe_step31.sh`, same input ODB, same step logic) moved
the flagged count 17,577 → 12,676 and the buffer insertion 97,969 → 88,590, i.e. −9.6 % buffers.
Raising the *constraint* instead is not a fix either: to clear the worst nets it would have to
exceed 1000 ns, four orders of magnitude away from the library's own 4 ns.

**Real high-fanout nets in the core: the remaining ~76 %.** 13,180 nets over the flow's own
10-fanout rule carry 195,934 pins, and 80 % of those pins violate. The mass is in the ROM's line
address, the instruction pipeline's broadcast bits, the RTL SRAM's address/valid, and the
cache/CSR/UART state listed above.

## 5. The same nets are also the worst timing path

`30-.../max.rpt`, the first path of `report_checks -path_delay max (Setup)` — i.e. the WNS path,
which ends at slack −574.47 matching the reported `timing__setup__wns`:

```
 ^ _351819_/Q (gf180mcu_fd_sc_mcu7t5v0__dffrnq_1)    2227  21.165524  963.210266  100.282181  100.347794
             i_chip_core.u_core.u_rom.line_p1[2] (net)
 ^ _290535_/A1 (gf180mcu_fd_sc_mcu7t5v0__aoi211_1)                             346.205719  398.199585
 v _290566_/A2 ...                              57.375698   94.969948  593.883850
 ...
                                            610.599792   data arrival time     (period 40.000000)
```

So `u_rom.line_p1[2]` is simultaneously the third-largest slew violator, the reason the 614 ns
`report_clock_min_period` and the −574 ns WNS exist, and the biggest single driver of the resizer's
buffer insertion. The earlier caveat that the WNS might be a phantom of the non-propagated clock is
resolved: the worst path is genuine and it is the ROM decode.

## 6. Recommendation

1. **Leave the slew/cap margins alone.** Measured as a 9.6 % effect; not the lever. Do not loosen
   `MAX_TRANSITION_CONSTRAINT` either — it would need >1000 ns to matter.
2. **Do not read 157,453 as a design-quality number pre-CTS.** ~24 % is clock and reset, which
   CTS owns. The comparable figure is the post-CTS `STAMidPNR` count in the running ws_v3 run.
3. **Fix the fanout at its source before the next full run**, in value order:
   - **The ROM.** `u_rom.line_p1[2]` drives 2,228 gate inputs because `rom_line(line_p1)` is a wide
     `case` compiled into a decode plane, and each address bit appears in a large fraction of its
     product terms. Mapping the ROM to the foundry macro the template already provisions
     (`gf180mcu_fd_ip_sram__sram512x8m8wm1` — the very SRAM grid we strip in
     `pdn_cfg_grx930.tcl`) removes the plane, and with it the WNS path, the min-period number and
     the biggest slew violator in one move.
   - **The reset.** 4,266 async reset pins from one pad. Nothing in the default flow buffers it
     after CTS: `rsz_timing_postcts.tcl` is a *timing* resizer (`repair_timing -setup/-hold`), the
     design-rule repairs are `RepairDesignPostGPL` (now disabled) and `RepairDesignPostGRT`
     (`RUN_POST_GRT_DESIGN_REPAIR`, default false). Either give it a tree or expect a real
     violation there.
   - **Broadcast nets generally.** They need a buffer tree *before* placement. Post-GPL is the
     worst possible place: it inflates the placement by 74-80 % and DPL aborts (ws_v2). The Chip
     flow has no pre-placement design-repair step, so this needs a substituted step or
     synthesis-level fanout control — not another margin.
4. **If the goal is simply to reach sign-off, living with the slew remainder is viable** — but the
   four timing checkers do not share a default, and one of them is fatal. The whole path through
   `steps/checker.py` first:

   `Checker.MaxSlewViolations` sets `corner_override = [""]`, and `get_corner_wildcards()` strips
   exactly that entry (`if wildcard is not self.match_none_wildcard`), so with no
   `MAX_SLEW_VIOLATION_CORNERS` configured the wildcard list is **empty**. The threshold defaults to
   `Decimal(0)`, so every nonzero count is "violating" — but with no corner *matched*, those
   corners land in `warn_violating_corner`, and `err_msg` is only filled by (a) a configured
   wildcard that matches no corner, or (b) violations at a *matched* corner. With an empty list
   neither fires, the method ends in `self.warn(...)`, and its only `raise` is guarded by
   `if err_msg:`. So the flow warns and continues. All four verified defaults:

   | checker | `corner_override` | consequence by default |
   |---|---|---|
   | `Checker.MaxSlewViolations` | `[""]` | warn — the 157,453 will not stop the run |
   | `Checker.MaxCapViolations` | `[""]` | warn — likewise the 5,945 cap violations |
   | `Checker.SetupViolations` | *none* → falls back to the PDK base var | **error** — see the correction below |
   | `Checker.HoldViolations` | `["*"]` | **error — any nonzero hold count at any corner aborts the run** |

   **Correction (2026-10-13, read back from the live ws_v3 run).** The Setup row above originally
   said `[""]` / warn. That was wrong. `SetupViolations` declares no `corner_override` at all, so
   `get_corner_wildcards()` falls through to `TIMING_VIOLATION_CORNERS` — and the **gf180mcuD PDK
   itself** sets that to `"*tt*"` (`libs.tech/librelane/config.tcl:48`; LibreLane's
   `config/pdk_compat.py:316` does the same). The live run's `resolved.json` confirms the resolved
   pair: `SETUP_VIOLATION_CORNERS: null`, `TIMING_VIOLATION_CORNERS: ["*tt*"]`. A non-empty list that
   *matches* the tt corner puts those corners in `err_violating_corner` (checker.py:586-630), so the
   run's 30,490 setup violations at `nom_tt_025C_5v00` raise `DeferredStepError`, not a warning.
   Slew and cap are unaffected: their `corner_override = [""]` is truthy, wins over the PDK value, and
   then filters to an empty wildcard list — warn only, as measured.

   So what can still kill this flow at sign-off is **hold and setup**: ws_v2's own
   `violator_list.rpt` listed 2,003 `[hold reg-reg]` entries pre-CTS, and hold depends on the clock
   network that CTS will have just built — and it is the one class of violation a slower clock
   cannot fix. Setup is the second hard gate, and the only honest remedies are an explicit
   `SETUP_VIOLATION_CORNERS: [""]` with the true fmax published next to it, or a design that closes
   40 ns (this one does not).
   The mirror-image trap: setting `MAX_SLEW_VIOLATION_CORNERS` (or `TIMING_VIOLATION_CORNERS`) to a
   real wildcard such as `*` promotes every one of the warning rows above to a hard error.

## 7. One loose end, recorded rather than papered over

The flow's fanout check reports **99** violations while the same netlist has **13,180 nets over the
10-fanout rule** (`MAX_FANOUT_CONSTRAINT: 10`, and the library sets `default_fanout_load : 1.0`, so
fanout should equal pin count). 99 is not reconcilable with 13,180 from the report files alone, and
I have not resolved it. Consequence either way: the fanout rule is not the instrument that surfaces
these nets — the slew rule is — so any plan that assumes the flow is already "checking fanout" and
will therefore keep nets small is resting on something unverified.
