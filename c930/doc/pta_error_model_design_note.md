# PTA C1: the tile's error model

**Status: C1 closed, 2026-09-16.** All six impairments are built and gated,
and gate C1(a) has run: it missed at 3 bits, and the miss is recorded (§5).
**C3 is built.** Its correction entered the C reference on 2026-09-22 and the
RTL on 2026-09-23: a trim per cell and an affine per column in PTM-C, the
calibration engine and its four schedulers in `rtl/pta/c930_pta_cal.sv`, and the
`cal_busy` dispatch guard in `rtl/c930_npu_csr.sv` (§4, §5).
Decisions E1–E4 were settled on 2026-09-14 and E5–E8 on 2026-09-15.
**The budget was rerun in a unit no ADC defines on 2026-10-03** (§5, at its
end): the sweep's noise rows cost 1.5 points together, as they do summed, and
the 11 to 13 points grxcp's joint runs reported were four times the noise.
**And at depth, the same day** (§5, after that): on networks of up to eight
hidden layers v1 costs what it costs on D3, v0 costs twice as much and its rows
stop adding — by 40% at eight layers — and it is deterministic error that
accumulates, not noise.
**And on other tiles, 2026-10-04** (§5, at its end): everything before that was
measured on the core's 8 × 8 tile. On the tiles grxcp's chiplet may have, up to
256 × 128, v1 costs what it costs here, v0 costs a quarter to a half more, and
drift costs far less — in a model whose cells drift independently.
**And the light, 2026-10-05** (§5, at its end): the model has no term for a
source, and one was added on the host's side of the line, outside the contract.
A source's noise costs under a tenth of a point up to 5% rms a shot if a column
reads a weight through a balanced pair, and twenty times less of it costs the
same if it reads through an offset.
This is phase C1 of grxcp `docs/designs/pta_cpu_integration.md` (§6): the
error model of that document's §4.3, built into PTM-C
(`rtl/pta/c930_ptm_c.sv`), with a C reference (`sim/pta_tile_model.c`) that
agrees with the RTL bit for bit. This note is the contract both implement.

---

## 1. What it is for

PTM-C is exact (C0). C1 makes it an analog tile: each captured result becomes
what a photonic dot product would deliver after its DACs, its device and
detector errors, and its ADC. Two properties make the result usable:

- **Every impairment is behind its own `PTA_IMPAIR` bit**, so a sweep can
  attribute an accuracy loss to one mechanism. With every bit clear, PTM-C is
  still bit-identical to the systolic array, and C0's gate keeps checking that.
- **Every stochastic term is reproducible from the seed**, with no `$random`
  anywhere (CPU document §4.3). A C reference that consumes draws in the same
  order makes RTL parity a bitwise question, and lets grxcp's host predict an
  analog GEMM exactly (CPU document §7, gate 1).

## 2. Decisions

E1–E4 were settled on 2026-09-14 and E5–E8 on 2026-09-15, all as recommended.

- **E1 — the core marks each captured element.** The tile does not draw on its
  own clock. The core tells it when a column is about to be captured, and draws
  are consumed in the core's loop order: N tile, K tile, output row `m`,
  column. A result then depends only on the seed, the shape and the operands —
  not on DMA stalls, queueing or idle cycles.
- **E2 — the per-GEMM generators reload from the seed at every GEMM start**, as
  S_ACT's do. Queued GEMMs are independent; a driver that wants different noise
  per layer writes a different seed.
- **E3 — weight errors act after the DAC:** the analog weight is
  `q_w(w) + eps + delta`. The DAC chooses a level and the device's error then
  moves it, which is how an electro-optic TFLT weight behaves. This corrects the
  CPU document's §4.3, which wrote `q_w(w + eps + delta)`.
- **E4 — the ADC's scale is a shift chosen per GEMM:** `LSB_adc = 2^S`. Software
  sets `S` from the layer's range, which is the activation-scaling knob of the
  CPU document's §4.3 and §5.2. It adds a field to the proposed `PTA_BITS`.
- **E5 — drift's clock is optical shots.** A shot is one core run: one output
  row over one K tile. Drift steps every `2^k` shots, so it tracks the work the
  tile does, and a result stays a function of the seed and the sequence of
  GEMMs. A cycle clock would bring back the timing dependence E1 removes, and
  the CPU document's §6.2 already says absolute cycle counts are not a claim.
- **E6 — drift is device state.** It accumulates across GEMMs until a model
  reset (`PTA_CTRL.MODEL_RST`, and from C3 a calibration), and its generator
  reloads only there. This is the one exception to E2: a host predicts a
  drifting GEMM by replaying the GEMMs since the last reset, and C3's
  calibration study needs drift that builds up across a workload.
- **E7 — drift is clamped** at ±`d_max`, a new configuration field in weight
  LSB. The CPU document's §4.3 calls drift a bounded random walk without giving
  the bound.
- **E8 — crosstalk couples neighbouring inputs within an output's bank.** In a
  microring bank, input `r`'s light also passes the rings of rows `r − 1` and
  `r + 1` in the same column, so it sees `chi` times their analog weights. A row
  outside the K tile holds no weight for its neighbour, as a ring tuned off
  resonance would not. This corrects both the CPU document's §4.3, whose
  formula multiplied the neighbour's own input, and its §8 item 5, which named
  the column index.

Taken as defaults, following S_ACT and the program plan:

- **Integer precisions only.** A start with any impairment bit set and FP16 or
  BF16 raises `o_error`, like a bad dimension. The float modes accumulate
  normalised FP32, which this fixed-point model does not describe.
- **One xorshift32 stream per stochastic impairment.** THERMAL, SHOT and
  PROG_ERR step whether or not their impairment is enabled, so turning one on
  never changes another's draws. DRIFT's stream steps only when drift does,
  which is only in a GEMM with DRIFT set: a device whose drift is switched off
  does not age.
- **An impairment the build cannot model is refused, not ignored.** A start
  raises `o_error` if it sets MZM_NL, which has no model yet, or any bit at all
  when the core was built with the digital array.
- **Crosstalk couples analog weights**, errors and drift included, since what
  couples is the neighbour's actual state.

---

## 3. Where it goes

PTM-C already evaluates each column in one pass (C0). C1 adds the model to that
pass, so the core's schedule and the DMA are untouched. The core gains
configuration inputs and these signals to the tile:

- `pta_cfg_load`, the cycle a start is accepted: the tile samples its
  configuration and loads its per-GEMM generators.
- `pta_shot_start`, the hop window with `t == 0` in `S_RUN`: a shot starts, and
  in a GEMM with DRIFT set the tile counts it on the drift clock.
- `pta_shot` and `pta_shot_col`: during the hop window whose shot the core
  captures for column `n` — `t == 2·NUM_ROWS + 2n` in `S_RUN`, for `n < nc` —
  the tile applies the model to that column, and steps its THERMAL and SHOT
  generators on the hop edge that registers it. The other columns register
  their exact sums that window, which the core never reads.
- The model reset, passed on only while the core is idle.

Weight writes are already logical events on the array's write port, in
`S_WLOAD`'s order, so PROG_ERR needs no new signal, and the K tile's rows are
already on it as `i_row_en`, which is all crosstalk needs.

**Build selection.** C0 swapped PTM-C in under the array's module name. The
tile now has ports the array does not, so the core instantiates `c930_ptm_c`
under `` `ifdef PTM_C `` and the systolic array otherwise; `make <bench> PTM_C=1`
defines it. The digital array is not modified.

**Ports** (core level; every scalar sampled when a start is accepted; tied off
in `c930_npu_top` until C4 maps them onto the widened CSR decode):

| Port | Width | Meaning | CSR field (C4) |
|---|---|---|---|
| `i_pta_impair` | 7 | bit 0 QUANT, 1 THERMAL, 2 SHOT, 3 DRIFT, 4 XTALK, 5 MZM_NL, 6 PROG_ERR | `PTA_IMPAIR` |
| `i_pta_act_bits` | 4 | `B_a`; 0 means unquantised | `PTA_BITS[3:0]` |
| `i_pta_w_bits` | 4 | `B_w`; 0 means unquantised | `PTA_BITS[7:4]` |
| `i_pta_adc_bits` | 4 | `B_adc`; 0 means no ADC quantisation | `PTA_BITS[11:8]` |
| `i_pta_adc_shift` | 6 | `S`, `LSB_adc = 2^S`, 0..40 | `PTA_BITS[17:12]`, new |
| `i_pta_seed` | 32 | seed for every generator | `PTA_SEED` |
| `i_pta_sigma_th` | 16 | thermal σ, Q8.8 in ADC LSB | `PTA_SIGMA_TH` |
| `i_pta_k_shot` | 16 | shot coefficient `k`, Q8.8 | `PTA_SIGMA_SH` |
| `i_pta_sigma_pr` | 16 | programming-error σ, Q8.8 in weight LSB | `PTA_SIGMA_PR` |
| `i_pta_drift_sigma` | 16 | drift step σ, Q8.8 in weight LSB | `PTA_DRIFT[15:0]` |
| `i_pta_drift_log2` | 5 | `k`: drift steps every `2^k` shots | `PTA_DRIFT[31:16]` |
| `i_pta_drift_max` | 16 | `d_max`, the drift clamp, Q8.8 in weight LSB | new |
| `i_pta_xtalk` | 8 | `chi`, Q0.8 | `PTA_XTALK` |
| `i_pta_model_rst` | 1 | a pulse, honoured while idle: drift and its clock return to zero and its generator reloads from `i_pta_seed` | `PTA_CTRL.MODEL_RST` |
| `o_pta_sat_count` | 32 | ADC saturations among captured elements | `PTA_SAT_CT` |

---

## 4. The contract

`D` is `DIN_W`, `R` is `NUM_ROWS`. Shifts of signed values are arithmetic, so
`>>>` floors. Everything is integer.

**Draws.** `xorshift32` is S_ACT's (shifts 13, 17, 5). A draw steps the stream
and reads the new state:

```
s   = xorshift32(s)
g   = s[31:24] + s[23:16] + s[15:8] + s[7:0] - 510
gs  = g * 443                                  ~ N(0,1) * 2^16, sd 0.999
```

Each stream loads `seed ^ K`, or `K` itself if that is zero: THERMAL
`K = 0x9E3779B9`, SHOT `0x3C6EF372` and PROG_ERR `0xDAA66D2B` at every GEMM
start, and DRIFT `0x78DDE6E4` at a model reset only. Out of reset every stream
holds its `K` and every drift is zero.

- PROG_ERR draws once per weight write, in `S_WLOAD`'s order: N tile, K tile,
  row, column.
- THERMAL and SHOT each draw once per captured element, in the order N tile,
  K tile, output row `m`, column `n < nc`.
- DRIFT draws once per cell at each drift step: bank 0 then bank 1, row, column,
  every cell of the tile, written or not.

**Per weight write** of `w` to (bank, row, column):

```
e = (sigma_pr * gs_pr + 2^15) >>> 16           Q.8, weight LSB; stored with w
```

A write leaves its cell's drift alone.

**Per shot start** in a GEMM with DRIFT set, with the clock `n` persisting:

```
if n + 1 >= 2^k:
    n = 0
    every cell:  d = clamp(d + ((sigma_d * gs_dr + 2^15) >>> 16), -d_max, d_max)
else:
    n = n + 1
```

**Quantiser** over the `D`-bit operand range:

```
q(x, B) = x                                     if B == 0 or B >= D
        = clamp((x + 2^(h-1)) >>> h, B) << h    otherwise, h = D - B
clamp(v, B) limits v to [-2^(B-1), 2^(B-1) - 1]
```

so it rounds half up and saturates. A 4-bit quantiser keeps the top four bits
of an 8-bit operand; data that uses only the bottom four bits quantises to
zero, which is the scaling question the sweep exists to ask.

**Per captured element**, column `n` of one run, with activations `a_r` (zero
for rows outside the K tile), the stored `w_rn` and `e_rn`, the cell's drift
`d_rn`, and `kr` rows in the K tile:

```
xa_r = QUANT ? q(a_r, B_a) : a_r
wa_r = ((QUANT ? q(w_rn, B_w) : w_rn) << 8)
       + (PROG_ERR ? e_rn : 0) + (DRIFT ? d_rn : 0)                       Q.8, weight LSB
wx_r = wa_r + (XTALK ? (chi * (wa_(r-1) + wa_(r+1)) + 2^7) >>> 8 : 0)
       with wa_i taken as zero for i < 0 or i >= kr
y    = sum over r of xa_r * wx_r                                          Q.8, tile units

v    = min(|y| >>> S, 2^23)                     Q.8, ADC LSB
rt   = isqrt4(v)                                 Q.4; S_ACT's root, same table
n_th = (sigma_th * gs_th + 2^15) >>> 16          Q.8, ADC LSB
n_sh = (k_shot * rt * gs_sh + 2^19) >>> 20       Q.8, ADC LSB
z    = y + (((THERMAL ? n_th : 0) + (SHOT ? n_sh : 0)) << S)              Q.8, tile units

out  = clamp((z + 2^(7+S)) >>> (8+S), B_adc) << S    if QUANT and B_adc != 0
     = (z + 2^7) >>> 8                                otherwise
```

`out` wraps to `ACC_W` bits and is added to the column's seed, the running sum
the core restored from C, exactly as the array adds its products. A clamp in the
first form counts one saturation.

Shot noise is taken on the signal before thermal noise, since it belongs to the
light, not the amplifier. Its root is taken in ADC LSB with eight fraction
bits, because `isqrt4` of an integer LSB count is too coarse at the low end.

**C3's correction**, in the C reference since 2026-09-22 and in the RTL since
2026-09-23. The error model makes error; C3 takes it away, and the contract has
to say where the correction enters:

```
wa_r = ((QUANT ? q(w_rn, B_w) : w_rn) << 8)
       + (PROG_ERR ? e_rn : 0) + (DRIFT ? d_rn : 0) + trim_rn      Q.8, weight LSB
out' = ((out * gain_n + 2^7) >>> 8) + offs_n                       when not identity
```

`trim_rn` is the weight DAC's, below the weight code's LSB: a write quantises
it to `trim_step` and clamps it to ±`trim_max`, both Q.8 weight LSB, which is
what a DAC of finite resolution can hold. `gain_n` is Q8.8 with 256 for unity
and `offs_n` is in the accumulator's units. Trim zero, gain 256 and offset zero
are what a device holds out of `pta_device_init()`, and they change nothing —
which is why C1's gates still pass unaltered.

Calibration measures what to write there: a probe with zero weights and one-hot
activations, where every column reports its cell at once (grxcp's
`pta_chiplet_calibration.md`). On this core the engine that runs it is
`rtl/pta/c930_pta_cal.sv`, and the core grants it the tile — `S_CAL` — at a
point where nothing is in flight.

**What a calibration does to the streams.** It is not a GEMM start, but it needs
a start's reproducibility, so the THERMAL, SHOT and PROG_ERR streams load once
at its beginning from a seed of its own and then run through the whole of it,
every repeat and every pass. Running through is the point: it is what makes one
repeat differ from the next, which is the only reason averaging them helps.
Nothing else moves — not the configuration, not the saturation count, and not
drift, which is device state and goes on accumulating through a probe exactly as
it would through a GEMM. The seed for calibration `j` is
`cal_seed ^ (j * 0x9E3779B1)`, with `j` the value of `PTA_CAL_CT` before it
runs, so no two calibrations draw the same noise and any of them can be
reproduced from one word.

**What the RTL restricts, and why.** The estimator's one division is by the
probe amplitude times the repeat count, and the DAC rounds a write to its own
step. In the RTL all three are powers of two — amplitude `1 << AMP_LOG2`,
repeats `1 << REPS_LOG2`, step `1 << TRIM_LOG2` — so the division is a shift and
the rounding is a mask, and the tile carries no divider. A real weight DAC's
resolution is a power of two anyway. The amplitude also has to survive the
activation quantiser untouched, since the estimator divides by what the tile
actually saw, and `q(x, B)` is the identity only on multiples of `2^(DIN_W - B)`
inside its range; that bounds it to `DIN_W - B_a <= AMP_LOG2 <= DIN_W - 2`.
Outside those bounds the engine refuses the calibration and raises
`PTA_IRQ_STATUS.ERR` rather than write trims it cannot read back. The C
reference carries the general case and agrees with the RTL everywhere the RTL is
defined.

**What stays exact.** With every bit clear, `out = (y + 2^7) >>> 8` and
`y = (sum of a_r * w_rn) << 8`, so `out` is the exact integer sum and PTM-C is
the array again. QUANT with `B_a`, `B_w` and `B_adc` all zero is also exact, as
is DRIFT from a model reset until its first step. So is any run whose trim is
zero and whose affine is identity.

---

## 5. Gates

In the style of the CPU document's §6: each can fail, and each names its
ablation. Parity runs in `sim/tb_core_verilator.cc`, where S_ACT's gate A2 runs,
over its 14 shapes at `DIN_W` 8 and 16; the C reference is
`sim/pta_tile_model.{h,c}`, plain C so grxcp and grxgpu can vendor it (D1). A
`pta_device` carries drift from one modelled GEMM to the next, as the RTL does.

- **P0 — off is exact.** Every bit clear, PTM-C build: C equals the digital
  reference at every shape, and C0's benches still pass with `PTM_C=1`.
  *Ablation:* C0's own.
- **P1 — QUANT.** Several `B_a`, `B_w`, `B_adc`, `S` settings, some chosen to
  saturate: C and the saturation count match the model at every shape, and a
  directed case pins the rounding at a half-LSB boundary. *Ablation:* drop the
  quantiser's rounding term; parity fails.
- **P2 — THERMAL, P3 — SHOT, P4 — PROG_ERR.** Each alone, then all together:
  C and saturations match the model at every shape, and elements move off
  their exact sums. *Ablation:* xorshift32's first shift 13 → 12 in the RTL;
  parity fails.
- **P5 — DRIFT.** The 14 shapes run in sequence on one device, drift stepping
  every 1, 2, 4 or 8 shots and clamping tightly on every fifth: C and
  saturations match the model at every shape. The sequence includes a GEMM
  with DRIFT clear, which must neither apply nor advance drift; a model reset
  pulsed while the core is busy, which must be ignored; and one while idle.
  Directed cases: zero drift from a reset until the clock first fills; nearly
  every cell pinned at the bound under a huge step; drift held unchanged when
  its step σ is zero; zero again after another reset. *Ablation:* clear drift
  at every GEMM start; parity fails from the first GEMM that follows drift.
- **P6 — XTALK.** At every shape, alone and with QUANT and DRIFT: C matches the
  model. Directed cases: two rows of weights 10 and 20 at `chi = 0.5` give 45
  where the exact sum is 30; and the same GEMM after a `K = 3` GEMM has left
  100 in row 2 still gives 45, because row 2 lies outside the K tile.
  *Ablation:* let rows outside the K tile couple; the stale-row case gives 95.
- **Refusals.** MZM_NL, any impairment with FP16 or BF16, and `S` above 40
  raise `o_error` at start, and the next valid start clears it. In a
  digital-array build, every impairment is refused.
- **P7 — the correction paths** (C3(b)). A trim per cell and an affine per
  column, written into the RTL's stores and the model's together: C and the
  saturation count match `pta_gemm()` at every shape. Directed cases pin the
  DAC's step and clamp and the affine's rounding against values worked out by
  hand from §4, not from the model. And with every impairment clear a loaded
  correction must change nothing, which is P0 again with the stores full.
  *Ablations:* write a trim without the DAC's step; apply the affine before the
  ADC instead of after. Both fail a directed case.
- **P8 — the calibration engine** (C3(b)). Drift and programming error
  accumulate over several GEMMs, the engine calibrates, and every trim it wrote
  has to be the one `pta_cal_bank()` computed — checked by reading the tile back
  a cell at a time, where a single disagreement shows, and by the residual
  `PTA_ERR_MAX` reports. Then its refusals: an amplitude the probe cannot read
  back is refused with `PTA_IRQ_STATUS.ERR` and no trim written, a START that
  reaches the core while `CAL_BUSY` is set is reported rather than taken or
  dropped, a `MODEL_RST` during a calibration is refused, and a trim that cannot
  reach what the estimator asked for raises `DRIFT_ALARM`. *Ablation:* a probe
  that keeps the GEMM's ADC range instead of taking its own — which is what
  C3(a) measured the cost of — and parity fails.
- **P9 — the schedulers** (C3(b)). Off, periodic, drift-predictive and shadow, on
  the same GEMM sequence with the same operands and the same A-row arrivals, with
  the rows arriving slowly enough that the tile waits on them — which is what
  makes an idle window long enough to hide a calibration in, and is what X2 says
  the chiplet's link does to the tile anyway. C3's gate: the shadow scheduler
  costs less wall-clock than the periodic one at the same accuracy, where
  accuracy is the tile read back a cell at a time with calibration off.
- **The dispatch guard** (C3(b), `tb/tb_npu_cal_queue.sv`, `make cal_queue`).
  Three STARTs back to back while `CAL_BUSY` is set: each queues, the occupancy
  is checked at every step, nothing dispatches into the calibrating tile, and
  `occupancy == 0 && busy == 0` never reads "finished" with work outstanding.
  *Ablation:* `CAL_GUARD_ABLATE` drops calibration from the dispatch condition,
  and the bench fails — a START dispatches into the tile and the queue strands.

*Met*, 2026-09-15, at `DIN_W` 8 and 16:

- P0: all 14 shapes exact in a PTM-C build. With `PTM_C=1`, `make npu` passes,
  `make npu_float` passes 24/24, `make npu_feed`'s log is byte-identical to the
  array's, and `make ptm_c_lockstep` still finds no difference.
- The directed cases: the model matches the hand-worked values, and the RTL
  matches the model, including the ADC's two saturations.
- P1–P4, and all four together: C and the saturation count match
  `pta_gemm()` at all 14 shapes, `M=64, N=8, K=256` included, and every shape
  moves off its exact sum.
- P5: the 14 shapes on one device, drift alone and with QUANT and PROG_ERR:
  C and the saturation count match at every shape, and every shape moves. The
  GEMM that holds drift, the model reset pulsed while busy, and the one pulsed
  while idle all behave: the model, which resets only on the second, stays in
  step. The directed cases hold too — zero drift for the 16 shots after a
  reset, all 128 results off zero and none past the bound under a huge step,
  every result unchanged when σ is zero, and zero again after another reset.
- P6: crosstalk alone and with QUANT and DRIFT matches at every shape. The
  directed case gives 45 where the exact sum is 30, and still 45 when row 2
  holds 100 from an earlier K = 3 GEMM.
- Refusals: MZM_NL, QUANT with FP16, THERMAL with BF16, DRIFT with FP16, XTALK
  with BF16 and `S = 41` are refused, and the next valid start runs. A
  digital-array build refuses every impairment.
- *Ablations, red:* the xorshift32 shift fails every shape in the thermal,
  shot, programming-error, drift and combined runs. Dropping the rounding term
  fails both hand-worked quantiser cases and 10 of the 14 quantised shapes;
  three of the other four quantise only in the ADC, whose rounding the ablation
  leaves alone, and the fourth is the one-element shape, whose single result it
  happens not to move. Clearing drift at every GEMM start fails 13 of the 14
  drift shapes and two directed cases — drift at its bound, and drift held,
  which is then no longer held. Letting rows outside the K tile couple fails
  the stale-row case, and exactly the three gate shapes whose K tiles are
  partial: K = 1, 13 and 2.

*Re-run on grx930 main 8e49242*, 2026-09-16. That commit turned PTM-C's
`return` statements into assignments for Yosys. In `int_column`, the early
return for an unmodelled column became a fall-through, so the modelled path
overwrote the exact sum with the sum divided by 256, and P0 failed at all 14
shapes. With the `else` back, P0–P6, the directed cases and the refusals pass
again at `DIN_W` 8 and 16, and the four ablations fail exactly as before. With
`PTM_C=1`, `make npu`, `make npu_float` (24/24) and `make ptm_c_lockstep`
pass, and the row-3 ablation is red.

*Re-run with C3's correction in the model*, 2026-09-22: with every trim zero
and every affine at identity, P0–P6, the directed cases and the refusals pass
unchanged at `DIN_W` 8 and 16, and the four ablations are red as before. The
model gained a path; no result moved.

*Met, C3(b)*, 2026-09-23, at `DIN_W` 8 and 16. The figures below are the 8-bit
run's; at 16 bits every gate passes, but the read-back that measures a tile has
to take a range of its own to see a cell at all — at a 16-bit GEMM's ADC shift a
dozen weight LSB of drift is under one code, which is question 2 of §7 arriving
in a measurement rather than in an argument:

- P7: the directed cases match the values worked out by hand — a DAC of step 4
  and clamp 16 turns ±6 into ±8, 5 and 2 into 4, 1 into 0 and ±100 into ±16, and
  a column of gain 1.5 and offset 7 turns an out of 10 into 22 and −10 into −8 —
  and at all 14 shapes, with a trim on every cell and an affine on every column,
  C and the saturation count match `pta_gemm()`. With every impairment clear and
  both stores loaded, the exact sums are still exact: P0 holds with the
  correction in place.
- P8: one calibration of four repeats over three passes takes 7,321 cycles and
  writes the trims `pta_cal_bank()` computes, cell for cell, with both published
  numbers matching — 3,584 found and 4,608 left, Q.8 weight LSB. The 14 shapes
  then match the model again with those trims in place. The refusals hold: an
  amplitude of `2^(DIN_W−1)` is refused with the error bit set and `PTA_CAL_CT`
  unmoved, a trim clamped at a quarter of a weight LSB raises `DRIFT_ALARM`
  exactly where the reference says it should, and a START and a `MODEL_RST` that
  arrived while `CAL_BUSY` was set were neither taken nor lost — `BUSY` stayed
  clear and the error bit was raised.
- P8's recovery: with the programming error off, because no trim can anticipate
  an error redrawn at every weight write, and drift held still while the probe
  runs, the tile read back a cell at a time goes from a mean of 408 to **0.00** at
  the ADC's resolution — 3,328 found, 256 left. With the programming error on the
  same calibration halves the error and no more, which is the floor the redraw
  sets rather than the trim's limit.
- P9: four GEMMs whose A rows arrive every 1,200 cycles against rows that take
  about 80 cycles to compute, so the tile waits on its operands and an idle
  window is long enough to hide a calibration in. Every mode ran the same work
  with the same operands and the same arrivals. The periodic and shadow
  schedulers each took 4 calibrations and spent the same 8,540 cycles in them,
  and the difference is entirely in what that cost: 8,792 cycles of wall-clock
  for the periodic scheduler against 2,198 for the shadow, so 75% of the
  calibration was free. The shadow left 76.00 per cell, the periodic one 172.00,
  and an uncalibrated tile 340.00. The drift-predictive scheduler fired twice at
  the threshold it was given and left 284.00, which is a tuning question rather
  than a gate.
- The dispatch guard, `make cal_queue`: 14 checks pass. Three STARTs during a
  calibration queue at occupancy 1, 2 and 3, nothing dispatches into the tile,
  and `occupancy == 0 && busy == 0` never reads "finished" with work
  outstanding.
- *Ablations, red:* a trim written without the DAC's step gives 24 where 32 is
  right at five of the eight directed columns, and fails P7 seven times over; the
  affine applied before the ADC gives 15 where 22 is right and fails fifteen
  times, which is the directed case and every shape; and a probe that keeps the
  GEMM's ADC range instead of taking its own — the thing C3(a) measured the cost
  of — fails P8 eighteen times, writing trims the reference does not.
  `CAL_GUARD_ABLATE` fails the queue regression, dispatching into the calibrating
  tile and stranding the queue.
- With `PTM_C=1`, `make npu`, `make npu_float` (24/24) and `make ptm_c_lockstep`
  pass, the row-3 ablation is red, and the digital-array build passes both.

*Four things C3(b) found the hard way.* Three are recorded in grxcp's
`pta_chiplet_calibration.md` §5: the drift-predictive scheduler cannot
extrapolate a *residual*, because a calibration that worked leaves almost nothing
and the rate it implies is almost zero; a rate of zero has to count as one unit
or the scheduler switches itself off for good; and the interval needs a floor,
because the measurement's own noise does not divide out and a short interval
therefore reads as a steep rate, which shortens the interval again. The fourth
was in this RTL rather than in any document: `CAL_BUSY` has to cover the handover
back to the core as well as the work, or there is exactly one cycle in which a
dispatcher believes the tile is free and the command it sends is lost.

The CPU document's gate C1(b) names the NPU DPI wrapper. The core harness
carried the parity gate while the configuration was core-level only; C4(a) put it
on the CSR — the PTA register block at `0x100`, see `rtl/c930_npu_csr.sv`'s header
— so the wrapper can reach it now, and `make pta_test PTM_C=1` is firmware doing
exactly that through MMIO. The parity gate stays in the core harness, which is
where bit-for-bit comparison against the C reference belongs.

### Gate C1(a): the accuracy sweep

**The network** is grxcp's D3, fixed here: a 784-100-10 MLP with ReLU on
MNIST, trained as Gorsline, Smith and Merkel trained the network of their
Fig. 3(c) (arXiv:2105.00227, §4). That means Adam at Keras' defaults, softmax
with cross entropy, batches of 32, and the last 6,000 training images held out.
Training stops at the first epoch whose held-out accuracy does not rise.
Weights and biases stay in [−1, 1], and the forward pass rounds the weights to
B bits. Here that rounding is the contract's `q`, applied to weights held as
D-bit operands at 2^(D−1) per unit, so a network trained at B bits is exactly
what the tile holds at `B_w = B`. Biases are added digitally at operand
precision, since the paper's axis is weight bits.

One step differs from the paper. The contract's quantiser rounds any weight
inside ±2^(−B) to zero. Glorot's initial weights for this network lie within
±0.082 in layer 1 and ±0.234 in layer 2, so at B ≤ 3 every initial layer-1
weight rounds to zero. The hidden layer then starts at exactly zero, where ReLU
passes no gradient, and only the output biases ever learn. The paper does not
give its quantiser, and one with no zero level would not stall this way. So
each network here starts from its seed's network trained at B = D, where only
the operand grid rounds, and trains on at B bits by the same recipe, with Adam
restarted. This was settled, and written here, after the criterion below and
before any network was trained.

`sim/pta_mnist.c` trains and
evaluates the network, and `sim/pta_mnist.sh` runs everything below. MNIST is
the four idx files from the CVDF mirror, checked against the MD5s torchvision
lists.

**How the tile runs it.** Pixels become operands at 2^(D−1) − 1 per unit and
weights at 2^(D−1). Each layer runs as GEMMs the core accepts — at most 64
rows, 256 inputs and 8 outputs — so a batch of 64 images takes 54 GEMMs, each
with its own `PTA_SEED`. Layer 1 uses weight bank 0 and layer 2 bank 1. Every K
tile is already its own shot and ADC read, so spreading 784 inputs over GEMMs of
256 changes no arithmetic. The host adds the biases, applies ReLU, and rescales
the hidden layer to operands by a power of two, set on the first 10,000 training
images to clip at most 0.01% of activations. `pta_mnist selftest` holds this
walk to direct integer sums, bit for bit, at `DIN_W` 8 and 16.

**The criterion, fixed on 2026-09-16 before any network was trained.** At
`DIN_W` 16, five networks are trained per weight width B = 1 … 10, with seeds
1–5, and each runs the test set through the tile with QUANT at `B_w = B` and
nothing else. The reference is Fig. 3(c)'s zero-attack curve, read from the
PDF's vector coordinates: 94.85, 96.41, 97.59, 97.76, 97.67, 97.81, 97.83,
97.61, 97.81 and 97.73% for B = 1 … 10.

- *Pass:* for every B from 3 to 10, the five-network mean through the tile is
  within 0.5 points of the curve, and at B = 2 within 1.0 point.
- B = 1 is reported, not gated. At one bit the contract's quantiser has the
  levels −1 and 0 only, which is not the paper's one-bit weight, whatever
  that was.
- Each network's digital accuracy — the same rounded weights, with
  floating-point activations — is reported beside the tile's.

*Ablation:* the model built with `PTA_MODEL_ABLATE_QROUND`, the RTL ablation's
missing rounding term, runs the same networks. Training keeps the contract's
rounding, so the tile truncates what the networks learned rounded, and the gate
must fail.

**Reported, not gated.** Five networks are trained at `DIN_W` 8 and
`B_w = 6`, seeds 1–5, each from its seed's network at B = 8, and each setting
runs once on each:

- activation bits `B_a` from 2 to 7, alone;
- ADC bits from 4 to 12, alone. Each layer's `S` is set on 1,000 training
  images to clip at most 0.01% of K-tile sums;
- with an 8-bit ADC set that way:
  - thermal σ from 0.25 to 8 ADC LSB;
  - shot noise from 100 down to 0.3 photons per ADC LSB (`k = 1/√p`);
  - programming σ from 0.5 to 8 weight LSB;
  - crosstalk χ from 1% to 20%;
- drift at the TFLT and TFLN fits below, after 0.1, 1, 4, 12 and 46 hours.
  The modelled device is aged by `pta_drift_age()`, which `selftest` holds
  equal to the shot starts it replaces.

**Drift's settings** answer §7's first question. The shot rate is grxcp's
EO-res point run flat out: 2,048 shots per 25.6 µs GEMM, or 80 M shots/s. A
step every 2^31 shots comes every 26.8 s, so the 46-hour test is 6,169 steps.
Each fit sets the step σ so the RMS drift at 46 hours equals the upper reading
of `pta_material_scorecard.py`'s bracket, in 8-bit weight LSB (four per 6-bit
LSB), and clamps at twice that:

| Fit | Swing over 46 h | RMS at 46 h | `PTA_DRIFT` σ | `PTA_DRIFT_MAX` |
|---|---|---|---|---|
| TFLT | under 1 dB | 16.9 LSB | 55 (0.21 LSB) | 8,643 (33.8 LSB) |
| TFLN | 5 dB | 61.4 LSB | 200 (0.78 LSB) | 31,413 (122.7 LSB) |

These are 8-bit units; §7's second question still stands for 16-bit operands.

*Not met*, 2026-09-16. The miss is recorded, and C1 closes on it.

| B | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| Tile, mean of five | 89.98 | 95.91 | 96.98 | 97.41 | 97.50 | 97.54 | 97.49 | 97.62 | 97.65 | 97.50 |
| Fig. 3(c) | 94.85 | 96.41 | 97.59 | 97.76 | 97.67 | 97.81 | 97.83 | 97.61 | 97.81 | 97.73 |
| Difference | −4.87 | −0.50 | **−0.61** | −0.35 | −0.17 | −0.27 | −0.34 | +0.01 | −0.16 | −0.23 |
| Ablated | 64.67 | 9.58 | 10.65 | 28.43 | 86.88 | 96.43 | 97.25 | 97.56 | 97.66 | 97.50 |

- At B = 3 the mean is 0.61 points under the curve, outside the 0.5 allowed;
  its five networks span 96.66–97.21%. Every other gated width is inside its
  band.
- The tile is not where the points went. On 48 of the 50 networks the tile's
  accuracy equals the digital network's exactly. On the other two, both at
  B = 2, it differs by one image in 10,000, once each way, where the host's
  integer rescale meets floating point. The shortfall is in the networks: at
  4 to 10 bits they average 0.22 points under the curve, and at 3 bits 0.61.
  The paper gives neither its quantiser nor its stopping rule beyond early
  stopping, so training and a different 3-bit quantiser cannot be told apart
  here.
- *Ablation, red:* truncating instead of rounding fails the gate at every width
  from 2 to 7 — 9.6% at 2 bits, 28% at 4, 96.4% at 6 — and passes from 8 up,
  where half a step no longer matters.

**Reported results.** At `DIN_W` 8 and `B_w = 6`, with nothing else impaired,
the tile gives 97.45%, the digital networks' own accuracy. Each figure is a
mean of five networks, each run on its own seed:

| Bits | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 10 | 12 |
|---|---|---|---|---|---|---|---|---|---|
| `B_a` | 22.33 | 93.86 | 96.84 | 97.29 | 97.38 | 97.43 | | | |
| `B_adc` | | | 92.28 | 96.66 | 97.24 | 97.46 | 97.42 | 97.46 | 97.45 |

With the 8-bit ADC, 97.42% before any noise:

| Thermal σ, ADC LSB | 0.25 | 0.5 | 1 | 2 | 4 | 8 |
|---|---|---|---|---|---|---|
| | 97.42 | 97.36 | 97.16 | 96.21 | 89.97 | 65.23 |

| Shot noise, photons per ADC LSB | 100 | 30 | 10 | 3 | 1 | 0.3 |
|---|---|---|---|---|---|---|
| | 97.42 | 97.38 | 97.32 | 96.97 | 96.25 | 91.85 |

| Programming σ, weight LSB | 0.5 | 1 | 2 | 4 | 8 |
|---|---|---|---|---|---|
| | 97.44 | 97.38 | 97.37 | 97.15 | 96.27 |

| Crosstalk χ | 1% | 2% | 5% | 10% | 20% |
|---|---|---|---|---|---|
| | 97.43 | 97.41 | 97.41 | 97.26 | 96.48 |

| Hours of drift | 0.1 | 1 | 4 | 12 | 46 |
|---|---|---|---|---|---|
| TFLT fit | 97.38 | 96.96 | 92.63 | 74.10 | 33.03 |
| TFLN fit | 96.46 | 75.97 | 40.84 | 16.45 | 10.94 |

- Two activation bits collapse the network. The contract's quantiser is signed
  and ReLU's outputs are not, so two bits leave a single magnitude level.
- Without drift, ADC saturations stay under 8 per 100,000 elements, against
  the 0.01% of training K-tile sums the shifts were set to clip.
- Drift is the result C3 needs. At TFLT's fit, accuracy holds within half a
  point for about an hour and is 4.8 points down by 4 hours; at TFLN's, it
  loses about a point in six minutes. Drift belongs to a cell, and every weight
  a GEMM loads into that cell carries its offset, so a device's 128 offsets
  move whole groups of weights together. That is why the five runs spread
  widely — 84.0–96.6% at TFLT's 4 hours: each is a different device.
- The first sweep ran all five networks on seed 1, so they shared one drifting
  device, and TFLT's curve rose between 4 and 12 hours. The results above
  rerun each network on its own seed; settings without drift moved by at most
  0.14 points.

### The budget, in a unit the ADC does not move

*Added 2026-10-03.* `sim/pta_mnist.sh MNIST WORK budget`: 44 settings on the
five `B_w = 6` networks, 220 evaluations, ten minutes on five jobs. Reported,
not gated.

**Why it was run.** `--thermal` and `--photons` are in LSB of whichever ADC a
run configures, because that is the contract's unit (§4). The clip rule gives
each width its own shift, and on all five networks and both layers a `b`-bit
ADC's shift is exactly `8 − b` more than the 8-bit ADC's. So one LSB of a 6-bit
ADC is four of an 8-bit one's. The sweep above measured thermal and shot noise
at an 8-bit ADC. grxcp's X1 then ran those rows together with
`sim/pta_mnist.sh joint`, at a 6-bit ADC, as `--thermal 1 --photons 3` — which
at six bits is **four times that receiver noise and a quarter of that light**.
Its "v0 entire" was not v0's rows together.

Two options state the two in LSB of an 8-bit ADC whatever the ADC is,
`--thermal8` and `--photons8`, and `--probe 1` reports every run's noise in
that unit however it was asked for.

**The rows, alone and together.** Means of five, against 97.45% on the host:

| Setting | Accuracy | Loss | Thermal, photons, in 8-bit LSB |
|---|---|---|---|
| Nothing but the 8-bit ADC | 97.42 | 0.03 | none |
| v0's five rows, one at a time at that ADC: 5 activation bits, thermal 1, 3 photons, programming 4, crosstalk 10% | 97.28, 97.16, 96.97, 97.15, 97.26 | 0.14, 0.26, 0.45, 0.27, 0.16 under it: **1.28 summed** | 1, 3 |
| All five at once, at that ADC | 96.04 | **1.38** under it | 1, 3 |
| All five at v0's own 6-bit ADC, the same noise | 95.96 | **1.49**, where the rows and the ADC's own 0.21 sum to 1.49 | 1, 3 |
| As X1 ran it: `--adcbits 6 --thermal 1 --photons 3` | 86.37 | 11.08 | **4, 0.75** |
| v1 as X1 ran it: `--adcbits 7 --thermal 0.25 --photons 30` | 97.20 | 0.25 | 0.5, 15 |
| v1 with its 0.25 and 30 taken as 8-bit LSB | 97.27 | 0.18 | 0.25, 30 |
| v0 at the same noise, after an hour of TFLT drift; after six minutes | 94.87; 95.77 | 2.58; 1.68 | 1, 3 |

**On this network the rows add.** Together they cost what they cost one at a
time, to a tenth of a point, at either ADC. The same holds between the two
versions, one row at a time from each end:

| Row, v0 ↔ v1 | Tightened from v0 | Relaxed from v1 |
|---|---|---|
| Activation DAC, 5 ↔ 6 bits | +0.10 | −0.10 |
| ADC, 6 ↔ 7 bits | +0.09 | −0.12 |
| Receiver noise, 1 ↔ 0.5 LSB of an 8-bit ADC | +0.18 | −0.19 |
| Light, 3 ↔ 15 photons per such LSB | +0.34 (at 30, and the same with no shot noise at all) | −0.34 |
| Programming error, 4 ↔ 1 weight LSB | +0.42 | −0.33 |
| Crosstalk, 10% ↔ 2% | +0.08 | −0.16 |
| Summed | 1.21 | 1.24 |

The two versions are 1.24 apart. Two settings were predicted by adding these
before they were run: v1's noise at v0's converters, 96.98 predicted and 96.97
measured; and v0 with only its light and its programming error tightened, 96.72
and 96.65.

**The probe** measures each layer's sums against the network's own — weights
at the network's width, activations unquantised — as a fraction of their rms,
so the result does not depend on any ADC. Layer 1's GEMM is 22.8% off and layer
2's 20.1% at v0, 8.0% and 7.7% at v1, and 49.5% and 30.0% as X1 ran v0. It then
asks whether the error at the ten outputs is all there is to the accuracy, by
perturbing the reference outputs with Gaussian noise and counting what is still
classified correctly.

- **For noise it is.** Thermal, shot and programming error, each alone and each
  turned up until the outputs are equally wrong, give the same accuracy:

  | Output error | Thermal | Shot | Programming | Independent noise of that rms predicts |
  |---|---|---|---|---|
  | 18 to 19% | 96.21 | 96.25 | 96.27 | 96.15, 95.92, 95.94 |
  | 35 to 39% | 89.97 | 91.85 | 89.92 | 90.59, 90.64, 88.71 |
  | 63 to 88% | 65.23 | 73.97 | 57.15 | 69.39, 74.47, 60.57 |

  So what decides the cost of these three is how much error they put on the
  outputs, in quadrature, and not which of them it was.
- **Crosstalk is not noise.** At 10% it puts 26% of error on the outputs and
  costs 0.16 points, where noise of that size would cost about three. Most of it
  is a gain — the outputs come back 17% large — and an argmax does not see a
  gain. With each image's common shift and the fitted gain taken out, 10.9% is
  left and the prediction is 97.13 against 97.26. At 20% and 40% crosstalk even
  that under-predicts, by 1.5 and by 16 points: what is left is still a
  deterministic function of the image, and noise is the wrong model for it.
- **So accuracy is not a function of total error**, which is what this was run
  to find out. All of v0 puts 33% of error on the outputs and loses 1.5 points;
  thermal noise alone at 35% loses 7.5. The joint points are under-predicted by
  one point at v0 and three as X1 ran it, for the crosstalk in them.

**What this is not.** One 784-100-10 network on MNIST, five trainings of it.
That the rows add here says nothing about a deeper network, where a layer's
error is the next layer's input many times over. Programming error is in 8-bit
weight LSB and drift in the fits above; neither was restated. And it prices
rows, it does not choose between them: what a bit of ADC or a halving of
receiver noise costs in silicon and in laser is grxcp's to weigh against these.

### Does the budget hold with depth?

*Added 2026-10-03.* `sim/pta_mnist.sh MNIST WORK depth`. Reported, not gated.

**Why.** The rows add on D3, and D3 has one hidden layer: a layer's error is the
next layer's input once. grxcp's board plan asks whether the budget holds on a
second workload (its §8, question 7), and the withdrawn claim that analog error
compounds would, if it were true anywhere, be true of depth.

**The networks.** 784 inputs, then H hidden layers of 100, then 10 outputs, for
H = 2, 4 and 8, trained by D3's rule and from D3's seeds — five of each, at
`B_w = 6` from its seed's network at 8 — with D3's own five as H = 1. On their
host they score 97.45, 97.61, 97.27 and 96.91%. The deeper ones are not better
because the rule stops at the first epoch that does not improve, which is a
few epochs in; that is the rule's doing and nothing here depends on it.

**The harness.** `pta_mnist.c` now takes any number of hidden layers up to
eight (`train --hidden H`). Layer `l` runs on weight bank `l & 1`, and every
hidden layer has its own rescale, set in order on training images. At one
hidden layer nothing moved, and that was checked rather than assumed: three
networks retrained from scratch are byte for byte the stored ones, and ten
evaluation lines — the probe, drift and calibration among them — are byte for
byte the previous build's.

**What it ran.** Eighteen settings on each of the twenty networks: v0's five
rows alone and together, v0 and v1 with and without shot noise, and each of
v1's six rows relaxed to v0's. 360 evaluations, 29 minutes on five jobs. Noise
is in LSB of an 8-bit ADC throughout. Losses are in points against the same
networks on their host, with the standard error over the five:

| | H = 1 | H = 2 | H = 4 | H = 8 |
|---|---|---|---|---|
| v1 | 0.26 ± 0.06 | 0.23 ± 0.03 | 0.30 ± 0.05 | 0.30 ± 0.03 |
| v0, at its 6-bit ADC | 1.49 ± 0.05 | 1.96 ± 0.10 | 2.44 ± 0.29 | 3.19 ± 0.29 |
| v0's five rows at the 8-bit ADC, summed | 1.30 | 1.53 | 1.90 | 1.95 |
| The same five together | 1.38 | 1.81 | 2.24 | 2.76 |
| Together, less the sum | +0.08 ± 0.16 | +0.28 ± 0.10 | +0.34 ± 0.21 | **+0.81 ± 0.15** |

- **v1 holds.** It costs a quarter to a third of a point at every depth.
- **v0 does not hold as well, and its rows stop adding.** Its cost doubles from
  one hidden layer to eight, and at eight the five rows together cost 1.4 times
  what they cost one at a time, five standard errors clear of adding. So analog
  error does compound with depth — by 40% at eight layers. It was withdrawn at
  the factor of six it was first reported at, and that stays withdrawn.

**What accumulates is not the noise.** Each row alone, as its loss and as the
error it puts on the outputs (percent of their rms):

| Row, alone | Loss at H = 1, 2, 4, 8 | Output error at H = 1, 2, 4, 8 |
|---|---|---|
| Thermal, 1 LSB | 0.29, 0.37, 0.25, 0.24 | 9.3, 10.6, 9.2, 10.9 |
| Shot, 3 photons | 0.49, 0.36, 0.27, 0.26 | 11.2, 11.7, 11.6, 13.7 |
| Programming error, 4 LSB | 0.30, 0.32, 0.52, 0.51 | 9.7, 12.1, 16.2, 19.1 |
| Crosstalk, 10% | 0.19, 0.32, 0.35, 0.32 | 26.2, 28.3, 22.4, 18.2 |
| 5 activation bits | 0.17, 0.26, 0.40, 0.53 | 7.7, 11.7, 16.7, 31.5 |

Thermal and shot noise put the same error on the outputs of a nine-layer
network as of a two-layer one, and cost no more. The probe's error after each
layer shows why. For thermal noise alone at H = 8 it runs 7.4, 8.9, 8.9, 9.5,
9.0, 9.6, 10.3, 11.0, 10.9: a layer's noise does not survive the next layer
undiminished, so what is on any layer's output is mostly that layer's own. For
the activation quantiser it runs 4.6, 10.2, 11.7, 14.2, 16.7, 19.6, 24.1, 27.4,
31.5: three points and more a layer, every layer. The quantiser's error is a
function of the signal and not a draw, the same function at every layer, and it
adds up. Programming error sits between: fresh at every weight write, but one
draw for all 64 rows of a GEMM.

Why a layer attenuates noise and not a quantiser's error is not something this
measures. That a trained layer carries its signal along directions the noise is
not on is a reading, and nothing here tests it.

**The menu moves with depth.** v1's rows relaxed to v0's, one at a time:

| Row | H = 1 | H = 2 | H = 4 | H = 8 |
|---|---|---|---|---|
| Receiver noise, 0.5 → 1 LSB | 0.18 | 0.38 | 0.23 | 0.22 |
| Light, 15 → 3 photons | 0.34 | 0.31 | 0.23 | 0.21 |
| Programming error, 1 → 4 LSB | 0.33 | 0.42 | 0.53 | 0.59 |
| Crosstalk, 2% → 10% | 0.16 | 0.35 | 0.35 | 0.34 |
| Activation DAC, 6 → 5 bits | 0.09 | 0.27 | 0.32 | 0.54 |
| ADC, 7 → 6 bits | 0.12 | 0.21 | 0.11 | 0.20 |
| Summed, against the gap between the versions | 1.21, 1.23 | 1.94, 1.73 | 1.78, 2.14 | 2.10, 2.89 |

Standard errors are 0.02 to 0.14 on a row and 0.1 to 0.3 on a sum. At one hidden
layer the activation DAC's sixth bit was the cheapest row there is; at eight it
is six times that, and with programming error it is one of the two dearest.
The two rows whose price is a laser and a converter — receiver noise and the
ADC's bit — stay near a fifth of a point at every depth.

**What was predicted, and was wrong.** Written down before the run: that the
error on the outputs would grow as the square root of the number of layers, as
independent errors that pass through unchanged would; that v1 would then cost a
point and a half to two points at eight hidden layers, and v0 ten or more. v1
costs 0.30 and v0 3.19. The assumption was that a layer passes its input's
error on, and for noise it does not.

**What this is not.** Fully connected layers of 100 on MNIST, and nothing with
a convolution, a residual path or attention in it. One training rule. The
hidden layers' rescale is the host's and exact, where grxcp's B4 puts the
activation stage on the chiplet. And the networks were trained without the
impairments: a network trained with them in the loop may tolerate more.

### Does the budget hold on another tile?

*Added 2026-10-04.* `sim/pta_mnist.sh MNIST WORK geometry`. Reported, not gated.

**Why.** Every figure in this section was measured on the core's 8 × 8 tile, in
GEMMs of at most 64 rows, 256 inputs and 8 outputs. grxcp's board plan puts the
tile on a chiplet whose candidates run from 64 × 8 to 256 × 128, gives it a
layer as one command, and holds its interface chip to v1 on these figures.
Nothing had asked whether they carry to another tile.

**The harness.** `pta_mnist eval` takes the tile (`--rows`, `--cols`) and the
cut of a layer into GEMMs (`--maxk`, `--maxn`, in whole tiles). Off the core's
tile the cut defaults to a whole layer. At the defaults nothing moved, and that
was checked: all 220 lines of the budget's record are byte for byte what this
build prints, and on the 26 settings of `calib` and the 9 of `joint` it prints
what the build before it prints. Two things underneath had to follow the tile.
Each layer's ADC shift is set on the K-tile sums of the tile in use. And the
calibration, which kept its sums in 64-entry arrays and returned without a word
on a tile of more than 64 cells, now runs on any tile and says when it cannot.
On the 8 × 8 tile 64 cells was every cell there was, so no figure above is
affected.

**What it ran.** Sixteen settings on D3's five networks, on six tiles: the
core's at the core's cut, as every figure above was run; the core's with a layer
a GEMM; and 64 × 8, 128 × 64, 256 × 64 and 256 × 128 with a layer a GEMM. 480
evaluations, 24 minutes on five jobs. Noise is in LSB of an 8-bit ADC
throughout. Losses are in points against the same weights on the host, with the
standard error over the five networks:

| | 8 × 8, core's cut | 8 × 8, a layer | 64 × 8 | 128 × 64 | 256 × 64 | 256 × 128 |
|---|---|---|---|---|---|---|
| The quantisers, 8-bit ADC | 0.03 ± 0.02 | 0.03 ± 0.02 | 0.02 ± 0.04 | 0.02 ± 0.04 | 0.01 ± 0.04 | 0.01 ± 0.04 |
| The same, 6-bit ADC | 0.22 ± 0.06 | 0.22 ± 0.06 | 0.33 ± 0.16 | 0.43 ± 0.18 | 0.31 ± 0.16 | 0.31 ± 0.16 |
| v0's rows alone: 5 activation bits | 0.17 ± 0.05 | 0.17 ± 0.05 | 0.17 ± 0.06 | 0.13 ± 0.06 | 0.11 ± 0.03 | 0.11 ± 0.03 |
| thermal 1 | 0.29 ± 0.02 | 0.23 ± 0.03 | 0.30 ± 0.10 | 0.28 ± 0.06 | 0.19 ± 0.07 | 0.21 ± 0.07 |
| 3 photons | 0.49 ± 0.03 | 0.42 ± 0.03 | 0.67 ± 0.13 | 0.68 ± 0.04 | 0.61 ± 0.05 | 0.62 ± 0.04 |
| programming 4 | 0.30 ± 0.02 | 0.23 ± 0.04 | 0.25 ± 0.02 | 0.20 ± 0.10 | 0.24 ± 0.08 | 0.24 ± 0.07 |
| crosstalk 10% | 0.19 ± 0.07 | 0.19 ± 0.07 | 0.24 ± 0.08 | 0.21 ± 0.05 | 0.21 ± 0.06 | 0.21 ± 0.06 |
| v0's rows together, 8-bit ADC | 1.41 ± 0.09 | 1.32 ± 0.09 | 1.65 ± 0.30 | 1.83 ± 0.04 | 1.48 ± 0.05 | 1.57 ± 0.08 |
| v0, at its 6-bit ADC | 1.49 ± 0.06 | 1.46 ± 0.08 | 2.05 ± 0.40 | 2.17 ± 0.12 | 1.86 ± 0.17 | 1.78 ± 0.13 |
| **v1** | 0.26 ± 0.06 | 0.24 ± 0.04 | 0.33 ± 0.11 | 0.34 ± 0.07 | 0.20 ± 0.05 | 0.23 ± 0.05 |
| v1, an hour of TFLT's drift | 0.81 ± 0.21 | 0.80 ± 0.23 | 0.56 ± 0.09 | 0.51 ± 0.07 | 0.24 ± 0.06 | 0.43 ± 0.15 |
| v1, six minutes of it | 0.37 ± 0.04 | 0.36 ± 0.05 | 0.32 ± 0.12 | 0.33 ± 0.09 | 0.21 ± 0.04 | 0.23 ± 0.06 |
| v1, four hours of it | 5.18 ± 2.31 | 5.18 ± 2.21 | 1.17 ± 0.07 | 0.74 ± 0.07 | 0.77 ± 0.16 | 1.18 ± 0.30 |
| v1, 46 hours of it | 65.54 ± 5.06 | 65.59 ± 5.08 | 27.88 ± 5.97 | 9.36 ± 0.96 | 12.02 ± 2.84 | 10.46 ± 1.54 |
| v1, an hour of TFLN's | 22.62 ± 4.79 | 22.49 ± 4.79 | 4.24 ± 0.28 | 2.81 ± 0.22 | 1.92 ± 0.25 | 3.53 ± 0.99 |
| v1, an hour of TFLT's, then calibrated | 0.22 ± 0.05 | 0.27 ± 0.05 | 0.32 ± 0.08 | 0.21 ± 0.05 | 0.20 ± 0.05 | 0.25 ± 0.07 |

One evaluation's accuracy moves by 0.07 to 0.10 points with its seed (sixteen
seeds on one network, below), so a tenth of a point between two columns of one
row is a draw.

**v1 holds on every tile.** 0.20 to 0.34 against 0.26, none of them a standard
error and a half away. Its error on layer 1 is larger off the core's tile, 9.1%
of the sums' rms at 256 × 64 against 8.0%, and the accuracy does not see it.

**v0 does not.** 1.49 on the core's tile and 1.78 to 2.17 on the others, and at
128 × 64 that is five standard errors. Its rows do not all move the same way,
which is the four paragraphs after the next: the receiver's noise costs less,
the light more, crosstalk a little more, the ADC's own bit more.

**The cut changes nothing.** The two 8 × 8 columns differ in where one GEMM ends
and the next begins: 54 GEMMs a batch against 2. Every row with no draw in it is
the same to the last digit, in its loss and in both of the probe's errors. The
three noise rows differ by 0.06 to 0.07, all the same way, which looked like
more than chance and was not. On one network over sixteen seeds the thermal row
scores 97.23 ± 0.02 at the core's cut and 97.21 ± 0.02 with a layer a GEMM, and
the programming row 97.20 ± 0.03 and 97.24 ± 0.02.

**The ADC's shift is a whole number of bits, and the tile decides where the sums
fall in it.** A noise row is so many LSB a conversion. The LSB is `2^S`, and a
layer's sum is `T` conversions added up, so the error the row leaves on a layer
goes as `√T · 2^S`. The thermal row's, on layer 1, in percent of the sums' rms:

| Tile | Conversions a sum, `T` | Shift `S` | `√T · 2^S`, against the core's | Predicted | Measured |
|---|---|---|---|---|---|
| 8 × 8 | 98 | 9 | 1 | | 10.55 |
| 64 × 8, three of the networks | 13 | 10 | 0.73 | 7.7 | 7.8, 7.9, 8.3 |
| 64 × 8, the other two | 13 | 11 | 1.46 | 15.4 | 14.3, 14.9 |
| 128 × 64 | 7 | 11 | 1.07 | 11.3 | 11.23 |
| 256 × 64 | 4 | 11 | 0.81 | 8.5 | 8.50 |

The clip rule sets `S`, and it lands where it lands. 128 inputs need the shift
256 need and take nearly twice the conversions, so 128 × 64 is the worst of
these tiles for receiver noise and 256 × 64 the best. At 64 × 8 the rule puts
three networks on one side of a bit and two on the other, and that row's
standard error is seven times its neighbours'. **So "thermal 1 LSB" is not one
amount of noise from tile to tile: it is one within a factor of two.** It was
already known not to be one from ADC to ADC, which is why this section's unit is
the 8-bit LSB. This is the same fact in the other direction, and no unit removes
it, because the shift is the tile's own.

**The light costs more on a larger tile.** The photons row's error on layer 1
is 9.6% on the core's tile and 13.6 to 15.1% on the others, and it is the one
row of v0's whose loss grows: 0.49, against 0.61 to 0.68. Shot noise is the one
noise here that follows the signal. An 8-input tile is dark for much of an
MNIST image and a 256-input one never is. That is offered as the reason and was
not tested.

**Crosstalk's error grows by 14%**, 16.6% to 19.0%, and its loss does not move.
An input couples to the inputs beside it in its K tile. In a tile of 8, two of
the eight have one neighbour; in a tile of 256, two of 256 do.

**The ADC's own bit costs more.** A 6-bit ADC alone leaves 7.2% of error on
layer 1 on the core's tile and 8.2 to 10.7% on the others. Its loss, 0.22
against 0.31 to 0.43, has standard errors too wide to say more.

**Drift costs far less on a large tile**, and nothing predicted it. An hour of
TFLT's drift costs 0.55 points beyond v1 on the core's tile and 0.04 at
256 × 64. Four hours cost 5.18 and 0.77. An hour of TFLN's costs 22.6 and 1.9.
With v1's own error taken out in quadrature, drift leaves 19.6% on layer 1 after
an hour on the core's tile and 6.9% at 256 × 64; after four hours, 41.9 and
14.5; after 46, 147 and 46. That is 2.8 to 3.2 times less at every age, and
drift's error grows as the root of the time, so **a 256 × 64 tile after eight
hours is the core's tile after one.**

The reason is how the tile is used and not how it drifts. Layer 1 is 78,400
weights. On the 8 × 8 tile every one of them passes through the same 64 cells
of a bank, 1,225 weights a cell, and a cell's drift is the same error on all of
them. At 256 × 64 a bank has 16,384 cells and a cell carries 8 at most.

**This is the model's drift, and the model draws every cell's on its own.** If a
real tile's drift is common to neighbouring cells, as a temperature would be, a
larger tile gains less than this, and nothing here says how much less. The
figure to carry away is not "eight times longer between calibrations". It is
that the 8 × 8 tile was the worst case for drift, and the calibration interval
grxcp sized on it is on the safe side.

**The calibration works at every size.** An hour of drift and then C3's
calibration returns every tile to within a tenth of a point of its own v1. At
256 × 128 that is 32,768 cells a bank, which before this change would have been
reported as calibrated and left as it was.

**What was predicted.** Written down while the first run was going and before
any of it was read, but after a prototype on one network at 256 × 64, which had
shown v1 0.06 lower and v0 0.38 lower than on the core's tile. Five things.

1. That the cut would not matter, each pair of columns agreeing within its
   standard errors on every row. Wrong as written: three rows differed by more.
   Right in substance, on sixteen seeds.
2. That v1 at 256 × 64 would cost within 0.15 points of what it costs at 8 × 8.
   It costs 0.06 less.
3. That v0 would cost 0.2 to 0.6 points more there. It costs 0.37 more.
4. That the two noise rows would grow and the others would not. Half right: the
   light grows and the receiver's noise falls. The reasoning counted the last
   K tile, which at 256 inputs is 16 inputs carrying a whole conversion's noise,
   and did not count the shift.
5. That the growth would be monotone in the tile's inputs. Wrong: 128 is the
   worst and 256 the best, for the reason in the table above.

Nothing was predicted about drift, which moved most.

**What this is not.** One family of networks, on MNIST. One rule for the ADC's
shift, the smallest that clips one sum in ten thousand, and one shift a layer;
another rule puts the sums elsewhere in the converter. Drift that is independent
from cell to cell. The plan's candidate tiles and no others. And a model: none
of it is a measurement of a tile.

### What may the light do?

*Added 2026-10-05.* `sim/pta_mnist.sh MNIST WORK source`. Reported, not gated.

**Why.** The model has six impairments, and every one of them is the tile's or
its receiver's. Nothing in it is the light's. That was harmless while the
source was one laser of whatever noise it had. grxcp's board plan has since
made the tile 256 × 64 at 1 GS/s, a ring bank on four buses lit by a comb with
an amplifier behind it (its B10 to B12), and it holds that source to an
intensity noise it could only assume: the receiver's own allowance applied to
the light, 0.2% rms of full scale. Nothing had measured what a source's noise
costs.

**The harness.** `pta_mnist eval` takes three things a source does to a line's
power, each as an rms fraction of it:

| Option | What moves | When |
|---|---|---|
| `--src` | Every line together | Anew each shot: a pump's noise, or an amplifier's |
| `--srcline` | Each line on its own | Anew each shot |
| `--srcflat` | Each line's level | Once, for the run: lines that are not level |

`--buses` cuts the tile's rows into runs that share their lines, since a line
lights one row on every bus. And `--srcsign` says what a line's light reaches a
column through, because that turns on how the tile signs a weight, which
nothing has settled: `pair`, the weight alone, as a balanced pair of
photodiodes has it; or `offset`, the weight and an offset the host takes off
again from the operands it sent, as one photodiode would have it.

**It is not in the contract.** The term is added on the host's side of the
line, to the sums the tile returns: `a × (w + offset) × error`, summed over a
shot's rows, with `a` and `w` as the tile quantises them. §4 is untouched and
so are PTM-C and the RTL. What follows from where it sits are the model's
limits. It is first order: the error meets the weight as written, not its
programming error, its drift or its neighbours. It is added after the
converter, where it is neither clipped nor quantised. And under `offset` the
converter would also have to span the offset, which is not modelled. A shot's
draws are its image's, its layer's and its tile's, so neither the cut nor the
batch moves one. The self-test holds that, and fifteen errors planted in the
term one at a time each fail it. At the defaults nothing moved: nine settings of the budget's record and
eight of `geometry`'s are byte for byte what this build prints.

**What it costs.** On the 256 × 64 tile, a layer a GEMM, four buses, over v1.
Points lost against the same weights on the host, five networks, mean and
standard error. v1 with no light's error loses 0.20 ± 0.05.

Through a pair:

| rms, a shot | Every line together | Each line on its own | A line's level |
|---|---|---|---|
| 0.2% | 0.21 ± 0.04 | 0.20 ± 0.05 | |
| 0.5% | 0.20 ± 0.05 | | |
| 1% | 0.25 ± 0.04 | 0.21 ± 0.05 | 0.25 ± 0.04 |
| 2% | 0.24 ± 0.04 | 0.23 ± 0.05 | 0.24 ± 0.02 |
| 5% | 0.28 ± 0.04 | 0.26 ± 0.05 | 0.27 ± 0.01 |
| 10% | 0.45 ± 0.06 | 0.36 ± 0.03 | 0.34 ± 0.04 |
| 20% | | 0.76 ± 0.06 | 0.65 ± 0.07 |

Through an offset:

| rms, a shot | Every line together | Each line on its own | A line's level |
|---|---|---|---|
| 0.2% | 0.30 ± 0.08 | 0.20 ± 0.06 | |
| 0.5% | 0.40 ± 0.10 | | |
| 1% | 0.94 ± 0.21 | 0.20 ± 0.06 | 0.23 ± 0.05 |
| 2% | 3.75 ± 0.70 | 0.35 ± 0.05 | 0.32 ± 0.03 |
| 5% | | 0.71 ± 0.12 | 0.55 ± 0.18 |

And together: 2% with 5% a line and 5% of level, through a pair, loses
0.30 ± 0.04; 5% of each loses 0.35 ± 0.05; and through an offset 0.2% with 1% a
line and 1% of level loses 0.33 ± 0.08. They do not compound. Each set costs
no more than its three rows summed, which over v1's 0.20 are 0.17, 0.21 and
0.13, and the errors on layer 1's sums add in quadrature: 9.77% and 10.98%
through a pair, which is what the three alone predict to the last figure.

**Through a pair a source may be noisy.** Up to 5% rms a shot costs under a
tenth of a point whichever of the three it is, and 10% costs 0.25, 0.16 and
0.14. As three rows of one budget, 2% together with 5% a line and 5% of level
cost a tenth of a point between them. The 0.2% the board plan assumed costs
nothing that can be seen.

**Through an offset it may not.** There 0.5% together costs what 10% does
through a pair, 0.40 for 0.45, and it puts the same error on layer 1's sums,
14.26% of their rms for 14.28%. That is a factor of twenty. The offset is every
lit input at a weight of one, and the weights it sits beside are small. So how
the tile signs a weight is worth twenty times in the source's noise, and at an
offset the plan's 0.2% is about what the budget can stand: it costs a tenth of
a point.

**Noise a line is worth 0.42 of noise together**, at the sums. Layer 1's error
grows as if `--src` added its own fraction of the sums' rms in quadrature, and
`--srcline` 0.42 of its own: 10.06% at 10% a line, where together gives 14.28%.
That is not the eighth that 64 independent lines on equal weights would leave,
and not the whole. And the buses do not enter: 5% a line on one bus loses
0.28 ± 0.04 and on four 0.26 ± 0.05, with the same 9.38% on layer 1's sums.

**A line's level is a weight error that C3's calibration cannot see.** Level
costs what noise a line costs, because to a column it is one: every weight in
a row off by the same fraction. But the probe GEMM reads each cell through a
weight of zero (§4), and a line's power multiplies that zero. So
nothing built here measures a line's level, and it has to be levelled by
something else or read by a probe with weights in it. This is an argument from
how the probe is made and not a measurement: in this model the term is outside
the tile, where the probe does not go.

**What was predicted.** Written while the first run was going and before any of
it was read. Six things.

1. That through a pair, noise together would cost under a tenth of a point up
   to 5%, and 0.1 to 0.4 at 10%. Right: 0.08 and 0.25.
2. That noise a line would be as large at the sums as noise together, signed
   weights leaving a sum no larger than its terms' root sum of squares. Wrong:
   it is 0.42 of it. A trained network's sums are larger than that, by the
   2.4 this measures. So the losses predicted at 10% and 20% a line, 0.2 to
   0.5 and 1 to 2.5, were too high: 0.16 and 0.56.
3. That the buses would not matter. Right.
4. That a line's level would cost what its noise does. Right: 0.14 for 0.16 at
   10%, and 0.45 for 0.56 at 20%.
5. That through an offset, noise together would cost 0 to 0.1 at 0.2%, 0.1 to
   0.4 at 0.5%, 0.5 to 2 at 1% and 2 to 8 at 2%. Right on all four: 0.10, 0.20,
   0.74 and 3.55. The error it predicted on the sums was twice what it is.
6. That through an offset 2% a line would cost under a tenth. A little low:
   0.15.

**What this is not.** One family of networks, on MNIST. First order, and after
the converter. Noise with no memory from one shot to the next: a source whose
power wanders slowly is a level that moves between calibrations, and that was
not run. An offset taken off digitally: a column of rings at a weight of zero
that reads the same light would take the offset's noise off with the offset,
and is the pair again. And a model: none of it is a measurement of a source.

---

## 6. Order

1. ~~QUANT, THERMAL, SHOT and PROG_ERR, through P0–P4, with the refusals.~~
   **Done** (§5).
2. ~~DRIFT and XTALK, through P5 and P6.~~ **Done** (§5).
3. ~~Gate C1(a) on the D3 network, with the drift settings fitted to TFLT and
   TFLN.~~ **Run, not met at 3 bits, recorded** (§5).
4. ~~C3's correction: in the C reference and measured (grxcp's board plan,
   C3(a)); then the RTL, the calibration engine and the schedulers.~~
   **Done** (§5, gates P7-P9).
5. Only then the CSR mapping and firmware (C4), which is what the engine's
   configuration and its two published errors are still waiting for: they are
   ports on the core, not registers (grxcp's `pta_chiplet_regmap.md` §4).

---

## 7. Open questions

1. ~~**Drift's settings.**~~ *Answered in §5*: grxcp's EO-res rate, 80 M
   shots/s, with the fits in the table there. The CPU document's §4.4 fits
   `PTA_DRIFT` to TFLT, with TFLN as the stress case, and anchors both to a
   46-hour test. Under E5 a fit needs a shot rate — how many shots the emulated
   tile runs in an hour — which is a statement about the workload, not the
   device.
2. **Error units at 16-bit operands.** The programming-error and drift σ, and
   the drift clamp, are Q8.8 in weight LSB, so they top out at 256 LSB. That is
   an 8-bit weight's whole range but under 1% of a 16-bit one's, and a drift of
   TFLN's size — 11–15 LSB at 6 bits, about 15,000 LSB at 16 — cannot be set.
   Before a 16-bit sweep, either the fields widen or the unit becomes a fraction
   of full scale.
3. **MZM_NL** has a bit but no phase. It is not in C1's list.
4. **The affine has nothing to estimate.** C3(b) built both of C3's correction
   paths, but this contract has no per-column error for the column loop to find:
   every impairment is either a cell's or a shot's. So the affine is written from
   outside, exercised only by P7's directed cases, and the engine's one estimator
   is the cell trim. Either the contract gains a receiver's gain and offset — a
   per-column multiplier and addend, drawn once at a model reset, which is what a
   real receiver has — or the column loop stays a path with no measurement behind
   it. grxcp's `pta_chiplet_calibration.md` §2 says the same from the other side.
5. **The probe amplitude is an absolute bit position.** `PTA_CAL_CFG.amp` is a
   shift, and the engine takes it only in `[DIN_W - B_a, DIN_W - 2]`, because the
   activation quantiser has to leave the probe alone. Nothing in the register map
   reports `DIN_W`, so the same value is right on one build and refused on
   another: 6 is right for `tb_c930_npu`'s eight-bit tile and refused by the
   SoC's sixteen-bit one, which ends the calibration in two cycles with
   `CAL_ERR` set and `CAL_CT` unmoved. `sw/pta_test.c` finds one the tile accepts
   the way a driver would have to — the refusal is observable and `MODEL_RST`
   clears it — but firmware should not have to search for a number the hardware
   knows. Either the map gains a read-only field for the datapath width, or
   `amp` is specified relative to it and the tile does the arithmetic. grxcp's
   `pta_chiplet_regmap.md` §4 records it against the map.
6. **A line the CPU has written is outside the L2's directory.** Not this
   contract's problem, but it decides what firmware driving this block may do.
   `c930_l2.sv` records a sharer on a read fill and is write-through with no
   allocate: on a write it invalidates the sharers it knows and drops its own
   copy. The D-cache keeps the written data. So after the CPU writes a line, the
   L2 no longer tracks it, and the NPU DMA's later write to that line invalidates
   nobody — the CPU reads its own stale value for ever. `sw/pta_test.c` cleared C
   before each GEMM and then read back the zeros it had written, which made an
   impaired GEMM look right (C all zero) and an exact one look wrong (C zero, not
   K). It only reads C now. The general fix is one of: keep the writer as a
   sharer, invalidate the writer's own line, or make the L1 write no-allocate.
7. **Crosstalk beyond first order.** E8 couples nearest neighbours only, and a
   neighbour's crosstalk does not couple on again. An MZI mesh would couple
   along its triangular structure instead (CPU document §8 item 5); that is a
   different matrix, and a hypothesis this program has no ground truth for.
8. **The noise fields are in ADC LSB, and a requirement cannot be.**
   `PTA_SIGMA_TH` and `PTA_SIGMA_SH` are in LSB of the ADC the same block
   configures, which is the right unit for a model that adds noise at the ADC.
   It is the wrong unit to hand anyone: the same receiver is 1 LSB at eight
   bits and a quarter at six, and §5's budget records what that cost. A
   requirement on a receiver or on the light has to name the ADC it stands
   beside, or be in a unit of the signal. `pta_mnist --probe` prints both.
