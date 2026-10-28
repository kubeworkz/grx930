# The die's timing on two engines: why the same design reads −0.06 ns and −8.65 ns

Date: 2026-10-27. Asked: reproduce the die's post-repair STA on the pinned engine so the
−8.65 ns reading (26Q4) and the −345 ns reading in the readiness register (pinned, 13 Oct)
can be reconciled into one defensible figure.

**Answer, in one paragraph.** The −345 ns was never a competing measurement: it was taken at
`STAMidPNR-1`, *before* the post-CTS resizer, and the flow's own next STA step reads −0.100 ns
on the same database. Reproducing the post-repair STA on the pinned build (dcf36133) gives
**−0.0640 ns / TNS −0.62 / 28 endpoints** where the 26Q4 build reads **−8.646 ns / TNS −6,808 /
2,393 endpoints** — and the difference is not the design. It is one net: `split25`, a
`clkbuf_16` driving **2,132 loads** with a transition of **21–47 ns against a 3 ns limit**. Both
engines flag that transition as illegal; they extrapolate the delay that follows from it
differently (0.387 ns against 18.55 ns at the load pin) and they time the recovery check itself
differently (required 35.06 ns against 24.59 ns). Neither WNS is a sign-off number. What is
defensible is narrower and more useful: **the 40 ns data paths close (−0.064 ns); the reset
distribution does not, and it is a physical fix, not a frequency decision.**

## 1. The ladder that the −345 ns came from

Every number from the run's own `or_metrics_out.json`, one flow, tt corner, 40 ns constraint:

| step | what it is | setup WNS | setup TNS |
|---|---|---|---|
| `ws_v3/30` | `STAMidPNR`, pre-CTS | −574.467 | −1,928,280 |
| `ws_v3/34` | `STAMidPNR-1`, post-CTS | **−345.198** | −1,183,940 |
| `ws_v3/35` | `ResizerTimingPostCTS` | inserts 27,575 hold buffers, no STA | — |
| `ws_v3/36` | `STAMidPNR-2`, post-resizer | **−0.0999734** | −2.01037 |

So the register's "30,490 violations, WNS −345 ns" is a snapshot from before the resizer. The
flow already carried a later, better reading on the same database, and that reading is what the
caption in `ws_run3_readiness_gaps.md` §"pre-CTS → post-CTS A/B" should have quoted once step 36
existed. **The −345 ns is superseded, not contradicted.**

## 2. Reproducing the post-repair STA on the pinned engine

The pinned engine is the image's own OpenROAD, `dcf36133a369abc8f3c5e5738cd4d82e4903c0e0`
(rev-date 2026-02-17). It cannot be exercised on the flow box without racing the live DRT arm for
memory, so the run was made on the ARM box (`ubuntu@2.31.100.64`), whose `gf180mcu-precheck:arm64`
ships the same commit — verified with `openroad -version`, not assumed.

The instrument is **LibreLane itself**, not a hand-built script: the step is resumed with
`-F/-T OpenROAD.STAMidPNR-3` from the step's own `state_in.json`, against the die's own staged
configs (`grx930_overrides.yaml` byte-identical to the flow box's, md5 `131b9ebf…`). That matters:
a first attempt at reproducing the STA by sourcing the step's `_env.tcl` by hand read −10.13 ns on
a database the flow calls −0.10 ns, because LibreLane passes several `_`-prefixed variables
(`_SDC_IN`, `_PNR_LIBS`, `_PNR_EXCLUDED_CELLS`, `_LIB_CORNER_*`) in the process environment that
`_env.tcl` does not record. A harness that cannot reproduce its own control is not evidence; it is
recorded here only as the reason the method is LibreLane and not Tcl.

### The control, and it matches to the digit

The same single-step resume on the post-resizer database the flow's step 36 measured
(`ws_v3/35/chip_top.odb`), pinned engine, on the ARM box:

| metric | flow step 36 (x86, pinned, 13 Oct) | replica (ARM, pinned, 27 Oct) |
|---|---|---|
| setup WNS | −0.0999734 | **−0.0999734** |
| setup TNS | −2.01037 | **−2.01037** |
| setup violating endpoints | 43 | **43** |
| hold WNS | −2.42652 | **−2.42652** |

Identical, on a different host, five weeks later. The method is sound.

### The schema barrier, and the conversion it forces

The post-repair database was written by the 26Q4 build and is **schema 0.141**; the pinned build
reads up to **0.126**, and refuses it:

```
[ERROR] incompatible database schema revision 0.141 > 0.126
```

That is a finding in its own right: the two engines cannot be handed the same ODB, so a
like-for-like comparison has to pass through an engine-neutral carrier. The repair step also wrote
a DEF, so the conversion is `read_lef` (tech, cells, pads, the five ws_ip macros) → `read_def` →
`write_db` on the pinned build, and the identical netlist and floorplan are then readable.
Artifact: `state/chip_top_repair_pin.odb`, 163 MB (340,141 components), written with
`DEF2ODB_DONE` and a clean DEF read.

Known limit of that step, stated rather than hidden: the DEF does not carry the 26Q4 ODB's routing
data, so the pinned run estimates parasitics from placement (`-placement`) where the 26Q4 run may
have estimated from global routing. That would move caps and slews — and it does not: `max_cap`
violations are 7,036 against 7,190 and `max_slew` 79,417 against 81,776, within 2 %. The
difference below is not a parasitic-source artifact.

## 3. The measurement

Same design, same SDC (`chip_top.sdc`, md5 `c2a22074…`), same corner (tt), same corner script,
same image, same host class. Only the binary differs:

| metric | pinned `dcf36133` (DEF-converted DB) | 26Q4 `geb14e40b7b` (native DB) |
|---|---|---|
| setup WNS | **−0.0640 ns** | **−8.6457 ns** |
| setup TNS | −0.6219 ns | −6,807.63 ns |
| setup violating endpoints | **28** | **2,393** |
| hold WNS | −2.44103 ns | −2.46154 ns |
| max-slew violations | 79,417 | 81,776 |
| max-cap violations | 7,036 | 7,190 |
| max-fanout violations | 4,282 | 4,282 |
| worst path (both) | `rst_n_PAD` → recovery at `_351675_/RN` | same |

Hold agrees to 0.02 ns across engines, so **hold is a design item, not an instrument artifact**.
Setup does not agree, and the next table says exactly where.

## 4. Where the 8.6 ns is

The same path, both reports, ns:

| point | pinned | 26Q4 |
|---|---|---|
| `split25/I` slew in | 10.098 | 11.629 |
| `split25/Z` delay (2,132 fanout) | 13.490 | 9.137 |
| slew out of `split25/Z` | 21.276 | 22.185 |
| **slew at `_351675_/RN`** | **21.297** | **46.791** |
| **delay charged at that pin** | **0.387** | **18.550** |
| data arrival | 27.437 | 33.234 |
| **data required** | **35.060** | **24.588** |
| slack | **+7.62** | **−8.65** |

Two separate engine behaviours compound here, and both are about a net that is already illegal:

1. **Slew propagation through 2,132 loads.** The 26Q4 build carries a 46.8 ns slew into the load
   pin and charges 18.55 ns for it; the pinned build carries 21.3 ns and charges 0.387 ns. With
   `MAX_TRANSITION_CONSTRAINT: 3`, both slews are 7–16× the limit, so both numbers are
   extrapolations outside the characterised table, not physics. The pins agree the transition is
   violated (`max_slew` 79k against 81k) and disagree only about what to charge for it.
2. **The required time for a recovery check** differs by 10.47 ns (35.06 against 24.59) on an
   otherwise identical clock tree (`clk_PAD`, 40 ns, latency 3.60 against 3.60, skew 0.137
   against 0.146). That is an OpenSTA change in recovery timing between the two builds, not a
   property of the design.

The 2,393 violating endpoints against 28 are consistent with the first effect: the 2,132 loads
behind `split25` are what becomes violating when the pin delay is charged as 18.55 ns instead of
0.39 ns.

## 5. The one defensible statement

* **The 40 ns clock closes on the data paths.** The worst `clk_PAD`-group path is −0.0640 ns on the
  pinned engine, and the design was −0.0999734 ns there before the antenna repair. The repair did
  not move it materially.
* **The reset distribution does not close, on either engine.** `split25` is a single
  `clkbuf_16` driving 2,132 loads — present in the post-CTS database (21 occurrences in both the
  `ws_v3/35` and the repaired DEFs), so it is a CTS/resizer artifact, not something the antenna
  repair introduced. Both engines report the transition violation; only the delay they charge for
  it differs.
* **Neither WNS is a sign-off number.** Quoting −8.65 ns implies a 20.6 MHz part; quoting −0.064 ns
  implies a 40 MHz part that has an illegal 2,132-load reset buffer in it. The honest figure is
  that **40 ns is achievable once the reset tree is buffered properly**, and no frequency claim
  should be made until that net is fixed and both engines agree.
* **Hold is independent of the engine** (−2.44 ns on both), so it is a real item for the resizer.

What would change this verdict: fix the reset fanout (constrain reset nets in CTS/`repair_design`,
or let the resizer see them at all), rerun both engines on the same database, and expect them to
agree within a few hundred ps. If they still disagree on recovery required times, that is an
OpenSTA defect to file upstream, not a design datum.

## 6. Reproducing it

On a box with the pinned image and the state files staged under `/work/ws/repro_sta/state/`
(the repair ODB or its DEF, the post-resizer ODB, `chip_top.sdc`, `nl`, `pnl`, `vh`, `json_h`,
the three SDFs and `state_in.json` with the paths re-pointed):

```
# 1. the control: post-resizer database, pinned engine -- must read -0.0999734
docker run --rm --user 0:0 -e HOME=/root -v $PWD:/work gf180mcu-precheck:arm64 \
  sh -lc 'cd /work/ws/template && librelane --pdk gf180mcuD --pdk-root /workspace/gf180mcu \
    --manual-pdk --scl gf180mcu_fd_sc_mcu7t5v0 --pad gf180mcu_fd_io --run-tag stacts01 \
    -F OpenROAD.STAMidPNR-3 -T OpenROAD.STAMidPNR-3 -i /work/ws/repro_sta/state/state36.json \
    librelane/slots/slot_1x1.yaml librelane/macros/macros_grx930.yaml \
    librelane/config.yaml librelane/grx930_overrides.yaml'

# 2. the schema conversion: the 26Q4 ODB cannot be read, its DEF can
openroad -no_init -exit def2odb.tcl     # read_lef ... ; read_def ... ; write_db chip_top_repair_pin.odb

# 3. the post-repair STA on the pinned engine
docker run --rm --user 0:0 -e HOME=/root -v $PWD:/work gf180mcu-precheck:arm64 \
  sh -lc 'cd /work/ws/template && librelane ... -i /work/ws/repro_sta/state/state_repair_pin.json ...'
```

Artifacts on `ubuntu@2.31.100.64`: `/home/ubuntu/grx930_ol2/ws/repro_sta/` (`run.sh`, `def2odb.sh`,
`env_*.tcl`, `state/`, and the LibreLane run trees `stacts01`, `starepair01` with their `max.rpt`,
`wns.max.rpt`, `tns.max.rpt` and `or_metrics_out.json`).

## 7. What this note does not establish

* One corner (tt), one clock (40 ns), one seed. The ss/ff corners were not re-run.
* The pinned run reads a DEF round-trip, not the 26Q4 ODB itself; §2's cap/slew comparison bounds
  that risk but does not eliminate it.
* Nothing here says the design routes better or worse — the DRT arm's live count is unaffected by
  which STA build reads it.
* The recovery-required-time difference is documented as an engine behaviour, not diagnosed to a
  specific upstream commit.
