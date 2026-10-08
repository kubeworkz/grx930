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
**And the laser, the same day** (§5, at its end): the budget gives the
receiver's noise in LSB a layer at a time, as if each layer had the light its
own sums ask for. Given as one laser fixes it, a laser sized the way grxcp's
board plan sizes one loses 39 points on a 256 × 64 tile, and it takes sixteen
times that laser to come within a tenth of a point of v1.
**And half of that laser is the host's to give back** (§5, at its end): the
hidden layer's rescale, set one bit under the clip rule, clips 0.65% of the
units that fire, costs 0.02 points, and loses at any laser what the rule's
rescale loses at twice it. A second bit buys nothing, and a gain on the first
layer's weights does not pay.
**And on another workload, the same day** (§5, at its end): all of the above
is MNIST. On Fashion-MNIST, and on MNIST with every pixel inverted, v1 costs
1.2 points on a 128 × 64 tile where it costs 0.34 on MNIST. Every row of the
budget costs two to seven times as much, the dear rows are different ones,
and the laser that was enough is not.
**And what tightening v1 would buy, 2026-10-06** (§5, at its end): on
Fashion-MNIST v1's point is in three of its six rows, the ADC's bit and the
two noise rows. All six a notch tighter cost 0.39 points there, 0.50 on the
inverted set and 0.06 on MNIST. One more bit of ADC with both noise rows
halved is four fifths of that on the two harder sets.
**And drift and a source at that set, which grxcp adopted as its version 2,
the same day** (§5, at its end): drift adds to version 2 what it adds to v1,
at every age on every data set, so after an hour it is most of what the
harder sets lose. A source's three rows hold at version 2 on MNIST and on
Fashion-MNIST, and cost three to four tenths of a point on the inverted set
at either version. grxcp then set the calibration to every six minutes and
the lines together to 1%. With everything it is then held to, version 2 loses
0.19, 0.60 and 1.09 points on the three sets.
**And a network trained for the tile, the same day** (§5, at its end): every
network above was trained on its host and stopped early. Trained for eight
epochs, the inverted set's networks are two points better on the tile, with
no noise in the training at all. Noise on the sums as they train is worth
half a point on Fashion-MNIST and nothing that five networks can tell on the
other two. And version 2 buys a trained network what it bought the others.
grxcp kept its version 2 on that, and made the networks trained for eight
epochs with 10% of noise the reference (its B17): a mode added to this
harness after 2026-10-06 runs those, and every mode before it is of the
networks trained before.
**And the first mode on the reference networks, 2026-10-07** (§5, at its end):
grxcp holds the row a source's lines share to 1% and not 2%, on what the
networks trained before lose on the inverted set. Held as grxcp holds the
chip, the 1% buys the reference networks nothing on any of the three sets.
grxcp kept the 1% all the same. **And the second, the same day** (§5, at its
end): version 2's rows under a laser. Training with noise does not buy laser.
Over its own budget a reference network loses what an old one does, and the
laser the brightest workload needs is 16 times grxcp's B5 for both kinds.
**And the third** (§5, at its end): drift from three minutes to four hours.
Under heavy drift a reference network loses half to two thirds of what an
old one does. At grxcp's six minutes nothing can be told between them, and
after a calibration the reference networks are about a tenth of a point
short of their budget on two data sets.
**And the fourth** (§5): the operating cycle, an interval that starts from a
calibration. It read a calibration as costing the reference networks 0.08 ±
0.01 of a point on MNIST by itself. **The fifth, 2026-10-08** (§5, at its end)
took that apart, and it was not the calibration. A calibrated run's probes
put every image onto other draws of noise than it meets as budgeted, the tile
as budgeted on those draws is as far short, and the trims a calibration
writes add 0.02 ± 0.02. A row of this note moves by 0.02 to 0.07 of a point
when nothing changes but its draw.
**And the sixth, the same day** (§5, at its end): the working point on ten
draws, each row read over a row that meets its noise. On the inverted set
the reference networks' six-minute cycle ends 0.12 ± 0.03 of a point over, and
a three-minute one 0.08 ± 0.02; on the other two sets six minutes is inside a
tenth. Held as grxcp holds the chip, over ten draws, they are right 97.59,
87.30 and 94.65% of the time. What training for the tile buys is in what
holding adds.
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

### What does a laser of a given size cost?

*Added 2026-10-05.* `sim/pta_mnist.sh MNIST WORK laser`. Reported, not gated.

**Why.** A receiver's noise is a current. This section has given it in LSB,
`--thermal` in the run's own ADC's and `--thermal8` in an 8-bit ADC's, and
both give it a layer at a time, each at that layer's own shift. That is as if
every layer had the light its own sums ask for. A tile has one laser.

grxcp's board plan sizes that laser (its B5) from a detector's full scale: the
receiver's noise, held to the budget's share of an 8-bit LSB, makes the 256 LSB
of a full scale so much light, and the laser is that for every column. The
method takes the light at a detector when its converter reads full scale to be
the light the column was sent. It is not. A column is sent every line at full
power whatever the inputs are, an input passes its activation's share of a
line, and a ring sends what is left to one photodiode of a pair or the other.
A converter's full scale is set where the sums fall, and nothing had run the
budget at a laser sized that way.

**The harness.** `--thermalline X` gives the receiver's noise as a fraction of
one line's light at a detector: an input at full scale through a weight of one,
127 × 128 of a sum's units at 8-bit operands. It is the same X in every layer,
so each layer's noise in its own LSB follows from its own shift, and a layer
whose sums are small has more of it. A run's line then also says what that
noise is in each layer's LSB (`thermal_l`), and the light a shot sends a
column, in lines (`lit`, `litmax`). A laser of B5's size is `X = rows / 512`
under v1's half an LSB: its full scale is the tile's rows at a line each.

Nothing else moved. A line printed without the option is byte for byte what it
was, on a sample of the recorded budget, `geometry` and `source` runs. The
self-test holds the unit and the light's count, the `laser` mode checks every
layer of every run against the fraction it was asked for, and ten errors
planted one at a time each fail one or the other.

**The fill.** A converter's full scale, 256 LSB at the shift the clip rule
gives a layer, over the light the tile's rows can send a column:

| Tile | 8-bit shifts, layers 1 and 2 | Fill, layer 1 | Layer 2 | A laser of B5's size leaves the receiver |
|---|---|---|---|---|
| 8 × 8 | 9, 7 | 1.01 | 0.25 | 0.50 and 1.98 LSB |
| 64 × 8 | 10, 8 | 0.25 | 0.063 | 1.98 and 7.94 |
| 128 × 64 | 11, 9 | 0.25 | 0.063 | 1.98 and 7.94 |
| 256 × 64 | 11, 9 | 0.126 | 0.031 | 3.97 and 15.88 |
| 256 × 128 | 11, 9 | 0.126 | 0.031 | 3.97 and 15.88 |

B5's method takes the fill for one, and on the core's tile, on the first layer,
it is: eight lines are a full scale. Sums do not grow as a tile's rows do, and
the light does. At 64 × 8 the rule gave two of the five networks other shifts,
(11, 8) and (11, 9).

**What it costs.** v1's other rows as they are, and the receiver's as a laser
of B5's size fixes it, and of 2 to 64 times that. Points lost against the same
weights on the host, five networks, mean and standard error, with the
receiver's noise on each layer in LSB of the 8-bit ADC at that layer's shift.

| Laser | 256 × 64 | Its noise, layers 1 and 2 | 128 × 64 | Its noise |
|---|---|---|---|---|
| v1 as budgeted | 0.20 ± 0.05 | 0.50, 0.50 | 0.34 ± 0.07 | 0.50, 0.50 |
| B5's | 39.19 ± 1.87 | 3.97, 15.88 | 13.56 ± 1.14 | 1.98, 7.94 |
| 2 times it | 12.53 ± 1.14 | 1.98, 7.94 | 2.74 ± 0.19 | 0.99, 3.97 |
| 4 times | 2.44 ± 0.24 | 0.99, 3.97 | 0.75 ± 0.07 | 0.50, 1.98 |
| 8 times | 0.60 ± 0.07 | 0.50, 1.98 | 0.35 ± 0.06 | 0.25, 0.99 |
| 16 times | 0.28 ± 0.06 | 0.25, 0.99 | 0.22 ± 0.04 | 0.12, 0.50 |
| 32 times | 0.23 ± 0.06 | 0.12, 0.50 | 0.20 ± 0.06 | 0.06, 0.25 |
| 64 times | 0.19 ± 0.06 | 0.06, 0.25 | 0.19 ± 0.05 | 0.03, 0.12 |

**A laser of B5's size loses 39 points on the 256 × 64 tile.** It is within a
tenth of a point of v1 at 16 times that laser and matches it at 32. On
128 × 64 it loses 14, and is at that tile's own v1 at 8 times.

**v1 as budgeted is no one laser.** Half an LSB on the first layer is this
sweep at 8 times B5's laser, and half an LSB on the second is it at 32. The
error that reaches the outputs from the first layer says the same: 6.89% of
their rms as budgeted, and 6.89% at 8 times. The second layer's sums are a
quarter the size of the first's on every tile, two bits of shift, so its LSB
is a quarter the light and it asks four times the laser.

**The rows cost light.** At any multiple 128 × 64 loses what 256 × 64 loses at
twice that, within their errors: the same receiver noise is half the fraction
of a line when a column's light is split over half as many. The laser for
each MAC a second is then the same on both.

**The light a pair carries.** A shot sends a column 25.8 lines on the first
layer at the mean and 133 at the most, of 256, and 6.7 and 12 on the second.
On 128 × 64 it is 14.8 and 83 of 128. That is the inputs summed, whatever the
weights, and under a balanced pair it is what the two photodiodes carry
between them: what their shot noise follows, where this model's follows the
difference.

**What was predicted.** Written before the first run was read. Four things.

1. That the 256 × 64 tile would lose 5 to 20 points at B5's laser, 1.5 to 6 at
   twice it, 0.5 to 2 at four times, 0.3 to 0.6 at eight, 0.2 to 0.35 at
   sixteen, within 0.05 of v1 at thirty-two and 0.15 to 0.2 at sixty-four.
   Wrong at the first three, and low each time: 39.19, 12.53 and 2.44. Right
   at the other four: 0.60, 0.28, 0.23 and 0.19. The second layer's 16 LSB had
   been counted and what 16 LSB does had not.
2. That 128 × 64 at a multiple would lose what 256 × 64 loses at twice it.
   Right, within their errors, at every multiple.
3. That the second layer's noise would be four times the first's in LSB.
   Right, and it is the shifts' doing.
4. That v1 as budgeted would be the first layer at 8 times and the second at
   32. Right.

**What this is not.** One family of networks, on MNIST, whose images are
mostly dark: a workload that lights more of its inputs fills more of the
light. One rule for a converter's shift. The receiver's row alone: the photon
row is left at v1's 15 an LSB of each layer's own, which at these lasers is
far fewer photons than there are. A receiver whose noise does not depend on
how many photodiodes are on its input. And a model: none of it is a
measurement of a tile or of a laser.

### How a network is put on the tile

*Added 2026-10-05.* `sim/pta_mnist.sh MNIST WORK fill`. Reported, not gated.

**Why.** The section above found a converter's full scale to be a fraction of
the light a column is sent, and the laser to follow from that fraction. The
fraction is the network's as much as the tile's: a layer's sums fall where its
operands do. The host sets two of them. Each hidden layer's rescale, which
this harness sets by the clip rule, so that one firing unit in ten thousand
reaches full scale. And the scale the first layer's weights are written at,
which training leaves with an rms of 0.14 of their range. Either can be made
larger, and either then clips. Nothing had asked what that buys.

**The harness.** `--hidshift D` adds D to every hidden layer's rescale after
the clip rule has set it: −1 hands the next layer operands twice as large.
`--w1gain B` writes the first layer's weights 2^B as large, saturating at the
ends of their range. The hidden rescale takes that gain back through the clip
rule, so the network is what it was except in the weights that clipped. A
run's line then says what each clipped (`hidclip`, `w1clip`).

Neither is in the contract, and neither is the tile's. On grxcp's chiplet the
first is the activation stage's shift, which is a field of a command, and the
second is how a weight set is written. A line printed without the options is
byte for byte what it was, on thirty recorded lines across four sweeps. The self-test
holds both on a made-up network whose weights a doubling keeps on their grid:
a bit of gain is one more bit of rescale and moves no hidden operand. The
`fill` mode checks that every run was put on the tile as it was asked to be,
and twelve errors planted one at a time each fail one or the other.

**What it costs and what it buys.** On the 128 × 64 tile, a layer a GEMM, with
v1's other rows and the receiver's noise as a laser of 2, 4 and 8 times
grxcp's B5 fixes it. Points lost against the network as trained, five
networks, mean and standard error.

| Hidden rescale | Weight gain | Firing units that clip | Weights that clip | The scaling alone, on the host | Laser × 2 | × 4 | × 8 |
|---|---|---|---|---|---|---|---|
| The rule's | None | 0.00% | 0.00% | 0.00 ± 0.01 | 2.74 ± 0.19 | 0.75 ± 0.07 | 0.35 ± 0.06 |
| The rule's | One bit | 0.00% | 0.38% | 0.14 ± 0.08 | 2.90 ± 0.21 | 0.83 ± 0.12 | 0.50 ± 0.16 |
| The rule's | Two bits | 0.00% | 7.91% | 1.46 ± 0.33 | 5.65 ± 0.31 | 2.62 ± 0.34 | 2.05 ± 0.33 |
| **One bit less** | **None** | 0.65% | 0.00% | 0.02 ± 0.01 | 0.92 ± 0.06 | **0.35 ± 0.06** | 0.22 ± 0.06 |
| One bit less | One bit | 0.55% | 0.38% | 0.14 ± 0.08 | 0.83 ± 0.12 | 0.41 ± 0.13 | 0.34 ± 0.10 |
| One bit less | Two bits | 0.30% | 7.91% | 1.49 ± 0.35 | 2.64 ± 0.32 | 2.04 ± 0.29 | 1.89 ± 0.30 |
| Two bits less | None | 13.45% | 0.00% | 0.26 ± 0.05 | 0.99 ± 0.11 | 0.60 ± 0.08 | 0.46 ± 0.06 |
| Two bits less | One bit | 12.24% | 0.38% | 0.33 ± 0.08 | 0.79 ± 0.12 | 0.63 ± 0.12 | 0.52 ± 0.13 |
| Two bits less | Two bits | 9.57% | 7.91% | 1.94 ± 0.42 | 2.67 ± 0.46 | 2.50 ± 0.45 | 2.41 ± 0.47 |

The first row is the `laser` mode's at 128 × 64, as it should be.

**One bit less of hidden rescale is half the laser.** It clips 0.65% of the
units that fire, and by itself costs 0.02 points. The second layer's operands
are twice as large, its 8-bit shift goes from 9 to 10, and its noise in LSB
halves at any laser. At 4 and at 8 times B5's laser the network then loses
0.35 and 0.22, which is what the rule's rescale loses at 8 and at 16. So it is
within a tenth of a point of v1 at 4 times B5's laser, where it took 8.

**It gives back the second layer's share and not the first's.** At twice B5's
laser it loses 0.92, where the rule's rescale at four times loses 0.75. The
first layer's noise is then an LSB, and nothing done to the hidden layer's
operands reaches it.

**A second bit buys nothing.** It clips 13% of the units that fire and costs a
quarter of a point by itself, and the second layer's shift does not move
again.

**A gain on the first layer's weights does not pay.** One bit saturates 0.38%
of them and that alone costs 0.14 ± 0.08. It does raise the first layer's
shift from 11 to 12 and halve its noise in LSB, and at twice B5's laser, with
the rescale down, it is the best there is: 0.79 and 0.83 against 0.92, which
is inside their errors. Everywhere else it loses more than it gains. It also
leaves the hidden operands smaller, 6.1 lines of light a shot for 6.7, so the
second layer's noise goes up as the first's comes down: 2.8 LSB for 2.0 at 4
times B5's laser. Two bits
saturate 8% of the weights and cost a point and a half.

**So the clip rule was a converter's rule.** One unit in ten thousand at full
scale wastes none of an operand's range. Under a laser the range is not what
is short. The light is, and one unit in a hundred and fifty at full scale is
worth a factor of two of it.

**What was predicted.** Written before the first run was read. Six things.

1. That a bit less of rescale would raise the second layer's shift from 9 to
   10 and halve its noise, and two bits take it to 11. Right for one. Wrong
   for two: it stays at 10.
2. That under 1% of firing units would clip at one bit and several percent at
   two. Right at one, 0.65%. Low at two: 13%.
3. That the clipping alone would cost under 0.05 points at one bit and 0.1 to
   0.4 at two. Right: 0.02 and 0.26.
4. That a bit of weight gain would saturate about half a percent of the
   weights and cost under 0.1 by itself, and two bits several percent and 0.2
   to 1. Right about the shares, 0.38% and 7.9%. Low about what they cost:
   0.14 and 1.46.
5. That a bit of weight gain would raise the first layer's shift by one and
   halve its noise. Right.
6. That at 4 times B5's laser the best of the nine would be a bit of each,
   losing 0.38 to 0.50, and that none would be within a tenth of a point of
   v1. Wrong on both: the best is the rescale alone, at 0.35, and that is
   within a tenth.

**What this is not.** One family of networks, on MNIST, with one hidden
layer. Networks trained with neither clip in the loop: one trained to it might
take a second bit. A gain that is the same for every unit of the first layer:
a gain a unit, each to its own largest weight, would clip none, and needs a
rescale a unit to take it back, where the stage on grxcp's chiplet has one a
command. One tile. And a model: none of it is a measurement of a tile.

### Does the budget hold on another workload?

*Added 2026-10-05.* `sim/pta_mnist.sh DIR WORK geometry`, `budget`, `laser`
and `fill`, with `DIR` another data set's four files, or MNIST's and
`PIXELS=inverted`. Reported, not gated.

**Why.** Every figure in this section is MNIST's: one data set, on which a
784-100-10 network is right 97.5% of the time and most of an image is dark.
grxcp's board plan holds its interface chip to v1 on those figures, sizes a
laser on them, and asks in its open question 7 whether they survive a second
workload. Depth was tried, above, and v1 held. Nothing had tried another data
set.

**The two.** Fashion-MNIST (Xiao, Rasul and Vollgraf, arXiv:1708.07747) is ten
kinds of clothing in MNIST's format, file for file: 60,000 and 10,000 images
of 28 × 28 under the same four names, as its repository
(`zalandoresearch/fashion-mnist`) serves them. The harness takes it as it is.
And MNIST inverted, every pixel taken from 255: the same digits with the page
lit and the ink dark. It was meant as a control, the same task with more
light.

**The harness.** `pta_mnist invert IN OUT` writes an idx image file with every
pixel taken from 255, and `PIXELS=inverted` has the script make a new work
directory's images that way. A work directory records which it holds, in
`data/pixels`, and the script refuses to run it the other way, because its
networks were trained on what it holds. `FILL_TIMES` sets the lasers `fill`
runs.

Nothing else changed, and that was checked. The 80 lines of `laser` on MNIST
and the 40 on each new workload were printed by the harness as it stood before
this and again by this one, and are byte for byte the same; so are the 135
lines of `fill` on Fashion-MNIST and both its tables. What `PIXELS=inverted` writes was compared
with the same inversion done separately in Python, and the four files are the
same. The self-test holds `invert` on three made-up images, and six errors
planted in it one at a time each fail it.

The networks are the harness's own: `train` as it stands, five seeds, 8-bit
weights and then 6. Nothing was retuned.

**What it ran.** On each workload, `geometry` on the core's tile both ways and
on 128 × 64, which grxcp's B10 has as its working tile; `budget` on the core's
tile; `laser` on 128 × 64; and `fill` there at 2, 4, 8 and 16 times grxcp's
B5. That is 680 evaluations a workload and about an hour on five jobs.

| | MNIST | Fashion-MNIST | MNIST, inverted |
|---|---|---|---|
| The five networks, on the host | 97.17 to 97.81% | 86.87 to 87.99% | 91.32 to 94.46% |
| Mean pixel of the test images, of full scale | 0.13 | 0.29 | 0.87 |
| Light a shot sends a column on layer 1 of a 128 × 64 tile, in lines: the mean and the most | 14.8, 83.0 | 32.3, 115.8 | 95.0, 125.0 |
| The same on layer 2 | 6.7, 12.0 | 3.8, 10.5 | 3.5, 5.6 |
| The 8-bit ADC's shift there, layer 1 | 11 on all five | 11 on four, 12 on one | 12 on three, 11 on two |
| Layer 2 | 9 on all five | 9 on four, 8 on one | 8 on three, 7 on two |

The light is the pixels. A 128-row tile takes the 784 inputs in seven shots,
and the mean pixel times 784 over seven is 14.8, 32.1 and 97.2 lines.

**The inverted set is not a clean control.** The trainer does worse on it:
93.4% at the mean, for the same digits that give 97.5%. It does not take its
inputs less their mean, which is the likely reason and was not tested. So two
things differ from MNIST there, the light and the network, and nothing here
separates them.

**v1 does not hold.** Points lost against the same weights on the host, five
networks, mean and standard error. The core's tile is at the core's cut; with
a layer a GEMM it reads the same to within its errors.

| | MNIST, 8 × 8 | 128 × 64 | Fashion-MNIST, 8 × 8 | 128 × 64 | Inverted, 8 × 8 | 128 × 64 |
|---|---|---|---|---|---|---|
| The quantisers, 8-bit ADC | 0.03 ± 0.02 | 0.02 ± 0.04 | 0.13 ± 0.06 | 0.06 ± 0.07 | 0.17 ± 0.11 | −0.01 ± 0.05 |
| The same, 6-bit ADC | 0.22 ± 0.06 | 0.43 ± 0.18 | 1.24 ± 0.37 | 1.51 ± 0.28 | 0.85 ± 0.30 | 1.08 ± 0.33 |
| v0's rows alone: 5 activation bits | 0.17 ± 0.05 | 0.13 ± 0.06 | 0.59 ± 0.13 | 0.51 ± 0.11 | 0.71 ± 0.19 | 0.65 ± 0.12 |
| thermal 1 | 0.29 ± 0.02 | 0.28 ± 0.06 | 1.35 ± 0.39 | 1.38 ± 0.31 | 0.82 ± 0.20 | 0.65 ± 0.12 |
| 3 photons | 0.49 ± 0.03 | 0.68 ± 0.04 | 1.15 ± 0.23 | 2.16 ± 0.14 | 1.60 ± 0.19 | 3.05 ± 0.48 |
| programming 4 | 0.30 ± 0.02 | 0.20 ± 0.10 | 0.89 ± 0.11 | 0.80 ± 0.12 | 1.83 ± 0.24 | 1.57 ± 0.16 |
| crosstalk 10% | 0.19 ± 0.07 | 0.21 ± 0.05 | 1.24 ± 0.30 | 0.96 ± 0.24 | 1.27 ± 0.44 | 1.32 ± 0.40 |
| v0's rows together, 8-bit ADC | 1.41 ± 0.09 | 1.83 ± 0.04 | 4.09 ± 0.61 | 4.65 ± 0.50 | 6.59 ± 1.00 | 8.04 ± 0.71 |
| v0, at its 6-bit ADC | 1.49 ± 0.06 | 2.17 ± 0.12 | 4.73 ± 0.66 | 5.27 ± 0.43 | 7.14 ± 1.18 | 8.57 ± 0.63 |
| **v1** | 0.26 ± 0.06 | 0.34 ± 0.07 | **1.06 ± 0.26** | **1.16 ± 0.14** | **1.10 ± 0.22** | **1.23 ± 0.13** |
| v1, six minutes of TFLT's drift | 0.37 ± 0.04 | 0.33 ± 0.09 | 1.18 ± 0.18 | 1.24 ± 0.18 | 2.70 ± 0.73 | 1.42 ± 0.35 |
| v1, an hour of it | 0.81 ± 0.21 | 0.51 ± 0.07 | 4.39 ± 0.89 | 1.84 ± 0.39 | 23.52 ± 5.81 | 3.18 ± 1.27 |
| v1, four hours of it | 5.18 ± 2.31 | 0.74 ± 0.07 | 19.55 ± 3.07 | 3.50 ± 0.41 | 62.76 ± 5.08 | 17.77 ± 3.02 |
| v1, 46 hours of it | 65.54 ± 5.06 | 9.36 ± 0.96 | 62.48 ± 5.86 | 23.26 ± 1.48 | 81.98 ± 0.99 | 68.12 ± 2.92 |
| v1, an hour of TFLN's | 22.62 ± 4.79 | 2.81 ± 0.22 | 45.48 ± 4.91 | 8.37 ± 1.47 | 75.65 ± 2.39 | 38.58 ± 5.56 |
| v1, an hour of TFLT's, then calibrated | 0.22 ± 0.05 | 0.21 ± 0.05 | 1.04 ± 0.20 | 1.18 ± 0.09 | 1.31 ± 0.51 | 1.14 ± 0.18 |

On 128 × 64, v1 costs 3.4 times what it costs on MNIST on one and 3.6 times
on the other, which is five and six standard errors from MNIST's. On the
core's tile it is four times. v0 costs 5.3 and 8.6 points where it cost 2.2.

**On Fashion-MNIST the tile is no worse. The network has less to spare.** The
probe gives the error that reaches the ten outputs, in percent of their rms,
on 128 × 64:

| | MNIST | Fashion-MNIST | MNIST, inverted |
|---|---|---|---|
| v1 | 7.9 | 7.8 | 12.4 |
| Thermal 1, alone | 8.1 | 7.4 | 9.8 |
| 3 photons, alone | 10.8 | 9.0 | 20.3 |
| Programming 4, alone | 7.1 | 6.9 | 14.7 |
| Crosstalk 10%, alone | 18.8 | 16.5 | 19.3 |
| v1, an hour of TFLT's drift | 9.4 | 10.6 | 25.1 |
| v1, four hours of it | 13.6 | 19.8 | 42.1 |
| The median image's lead under v1, in multiples of the rms error at the outputs | 7.8 ± 0.2 | 3.6 ± 0.2 | 5.4 ± 0.4 |

Fashion-MNIST's outputs come back about as wrong as MNIST's do, under v1 and
under each row alone, and it loses three and a half times the points. Only
under four hours of drift are they half again as wrong. What differs is the
last line: the
probe's `margin`, an image's largest output less its next, over its `sigma`.
The median image leads by 7.8 errors on MNIST and by 3.6 on Fashion-MNIST. A
network that is right 87% of the time has its answers closer together, and the
same error turns more of them.

The inverted set has both. Its lead is 5.4, and its outputs are half again as
wrong under v1. The rows that do it are the ones that scale with light:
programming error and shot noise each put twice the error on its outputs that
they put on MNIST's, and an hour's drift more than that, where crosstalk and
thermal noise put about the same. A weight's error reaches a sum by what the
weight is lit with, and that set lights three rows in four.

**And the loss does not follow the light.** Fashion-MNIST lights 2.2 times the
rows MNIST does and the inverted set 6.4 times, and the two lose the same.

**Every row costs more, and the dear ones are not the same.** `budget`, on the
core's tile, means of five. One row at a time from each end, as above:

| Row, v0 ↔ v1 | MNIST: relaxed from v1 | Fashion-MNIST | MNIST, inverted |
|---|---|---|---|
| Activation DAC, 5 ↔ 6 bits | −0.10 | −0.30 | −0.59 |
| ADC, 6 ↔ 7 bits | −0.12 | −0.59 | −0.79 |
| Receiver noise, 1 ↔ 0.5 LSB of an 8-bit ADC | −0.19 | **−0.86** | −0.65 |
| Light, 3 ↔ 15 photons per such LSB | **−0.34** | −0.69 | −1.35 |
| Programming error, 4 ↔ 1 weight LSB | −0.33 | −0.65 | **−1.87** |
| Crosstalk, 10% ↔ 2% | −0.16 | −0.78 | −1.05 |
| Summed | 1.24 | 3.87 | 6.30 |
| The same six tightened from v0, summed | 1.21 | 3.76 | 5.68 |
| v0's five rows alone at an 8-bit ADC, summed | 1.28 | 4.54 | 5.38 |
| The five at once | 1.38 | 3.95 | 6.42 |

No row was worth more than 0.34 on MNIST. On Fashion-MNIST the dearest is the
receiver's noise, at 0.86, and then crosstalk. On the inverted set it is
programming error, at 1.87, and then the light. The two rows that were cheapest
on MNIST were the converters' bits, a tenth of a point each. They are 0.30 and
0.59 on one and 0.59 and 0.79 on the other.

**And they do not add the same way.** On MNIST v0's five rows at once cost
their sum, 1.38 for 1.28. On Fashion-MNIST they cost 0.87 of it, and on the
inverted set 1.19 of it.

Inside v1, shot noise at 15 photons is worth 0.23 and 0.28 by itself. Both
noise rows halved again, a quarter of an LSB and 30 photons, buy 0.19 and
0.22. So more than half of v1's point is not its noise. It is what is left:
its two converters, its programming error and its crosstalk.

**Drift costs more, and on the inverted set far more.** What it adds to v1 on
128 × 64:

| | MNIST | Fashion-MNIST | MNIST, inverted |
|---|---|---|---|
| Six minutes of TFLT's | −0.01 | +0.08 | +0.19 |
| An hour | +0.17 | +0.68 | +1.95 |
| Four hours | +0.40 | +2.34 | +16.54 |
| An hour, then calibrated | −0.13 | +0.02 | −0.09 |

Calibration returns all three to their v1. How long one holds is the
workload's: an hour on the inverted set costs five times what four hours cost
on MNIST. On the core's tile it is worse again on every one, as it was.

**The laser.** `laser`, on 128 × 64: v1's other rows, and the receiver's noise
as a laser of that many times grxcp's B5 fixes it.

| | MNIST | Fashion-MNIST | MNIST, inverted |
|---|---|---|---|
| v1 as budgeted | 0.34 ± 0.07 | 1.16 ± 0.14 | 1.23 ± 0.13 |
| B5's laser, times 1 | 13.56 ± 1.14 | 23.90 ± 3.49 | 40.87 ± 4.46 |
| times 2 | 2.74 ± 0.19 | 10.38 ± 2.19 | 17.47 ± 2.89 |
| times 4 | 0.75 ± 0.07 | 4.16 ± 0.89 | 5.35 ± 0.90 |
| times 8 | **0.35 ± 0.06** | 1.93 ± 0.29 | 1.99 ± 0.27 |
| times 16 | 0.22 ± 0.04 | 1.26 ± 0.14 | **1.27 ± 0.18** |
| times 32 | 0.20 ± 0.06 | **1.04 ± 0.13** | 1.15 ± 0.16 |
| times 64 | 0.19 ± 0.05 | 1.00 ± 0.14 | 1.04 ± 0.14 |
| The receiver's noise at B5's laser, layer 1 and 2, in 8-bit LSB | 1.98, 7.94 | 1.79, 9.53 | 1.39, 22.23 |

Eight times B5's laser came within a tenth of a point of v1 on MNIST. Each of
the others is three quarters of a point over there. The inverted set is within
a tenth at 16. Fashion-MNIST at 16 is 0.10 over, which is the line and inside
its scatter, and under at 32.

Half an LSB of receiver's noise a layer, which is the budget's row, costs 0.15,
0.16 and 0.19 over none. That much held. A second half does not: 0.19, 0.86
and 0.65, in the table of rows above.

**How the network is put on the tile.** `fill`, on 128 × 64. No gain on the
first layer's weights:

| | Firing units that clip | The scaling alone | Laser × 2 | × 4 | × 8 | × 16 |
|---|---|---|---|---|---|---|
| Fashion-MNIST, the rule's rescale | 0.01% | 0.03 ± 0.01 | 10.38 ± 2.19 | 4.16 ± 0.89 | 1.93 ± 0.29 | 1.26 ± 0.14 |
| One bit less | 0.90% | 0.02 ± 0.01 | 4.39 ± 0.91 | 1.93 ± 0.34 | **1.19 ± 0.13** | 0.96 ± 0.07 |
| Two bits less | 10.32% | 0.21 ± 0.08 | 2.28 ± 0.27 | 1.29 ± 0.14 | 0.98 ± 0.08 | 0.89 ± 0.07 |
| Inverted, the rule's rescale | 0.00% | 0.02 ± 0.02 | 17.47 ± 2.89 | 5.35 ± 0.90 | 1.99 ± 0.27 | 1.27 ± 0.18 |
| One bit less | 2.75% | 0.04 ± 0.04 | 6.01 ± 0.87 | 2.29 ± 0.29 | 1.37 ± 0.16 | **1.17 ± 0.12** |
| Two bits less | 22.27% | 0.61 ± 0.33 | 3.57 ± 0.42 | 2.22 ± 0.37 | 1.86 ± 0.36 | 1.81 ± 0.37 |

A bit less of rescale is still half the laser. At 4 times B5's it loses 1.93
on Fashion-MNIST, which is what the rule's rescale loses at 8, and 2.29 against
1.99 on the inverted set. Within a tenth of a point of v1 then takes 8 times
B5's laser on Fashion-MNIST and 16 on the inverted set, where MNIST took 4.

A second bit bought MNIST nothing. On Fashion-MNIST it pays at every laser
run: 1.29 at 4 times for 1.93. On the inverted set it pays at 2, is level at
4 and costs at 8 and 16, and it clips 22% of the units that fire.

A gain on the first layer's weights is worse than none at every laser on all
three. On the inverted set it is ruinous:

| One bit of gain, the rule's rescale | Weights that clip | That alone | Laser × 8 |
|---|---|---|---|
| MNIST | 0.38% | 0.14 ± 0.08 | 0.50 ± 0.16 |
| Fashion-MNIST | 0.73% | 0.34 ± 0.08 | 2.67 ± 0.43 |
| MNIST, inverted | 0.15% | 3.05 ± 0.82 | 5.83 ± 1.14 |

Fifteen weights in ten thousand saturate and three points go. On that set an
8-bit ADC's full scale is about 32 or 64 lines' worth of sum, and the mean
shot lights 95. Its sums are small differences of a great deal of light, and a
weight that clips is light that no longer cancels. Two bits clip 2.1% and cost
26 points.

**What was predicted.** Written before each run was read. Fourteen things.

1. That the inverted networks would train to about MNIST's accuracy. Wrong:
   91.3 to 94.5%.
2. That a shot would light about 111 lines of 128 on their first layer.
   Partly: 95. The 784 inputs go in seven shots, and the last is 16 rows.
3. That their first layer's 8-bit shift would rise to 12 or 13. Partly: 12 on
   three networks, 11 on two.
4. That their second layer's shift would stay at 9 or go to 10. Wrong: it
   fell, to 8 or 7.
5. That 8 or 4 times B5's laser would still do on the inverted set. Wrong: 16.
6. That v1 would cost within 0.15 of MNIST's 0.34 there. Wrong: 1.23.
7. That Fashion-MNIST's networks would reach 85 to 88%. Right: 86.9 to 88.0.
8. That a shot would light about 32 lines on its first layer and at most about
   110. Right: 32.3 and 115.8.
9. That v1 would cost 0.8 to 1.5 points on it. Right: 1.16.
10. That it would be within a tenth of v1 at 8 or 16 times B5's laser. Partly:
    at 16 it is on the line, 0.10 over.
11. That a bit less of rescale would still halve the laser on Fashion-MNIST
    and would not on the inverted set, whose second layer's shift had already
    fallen. Right for one and wrong for the other: it halves both.
12. That crosstalk would be the dearest of v0's rows on 128 × 64 on both, by a
    wide margin on the inverted set. Wrong: the light is, on both, 2.16 and
    3.05 against crosstalk's 0.96 and 1.32. It was the dearest on MNIST too.
13. That v1 on the core's tile would cost 0.8 to 1.2 on Fashion-MNIST and
    about 1 on the inverted set. Right: 1.06 and 1.10.
14. That the dearest row to relax from v1 would be a converter's bit on
    Fashion-MNIST and crosstalk on the inverted set. Wrong on both: the
    receiver's noise, and programming error.

Four right, four partly, six wrong. Every one about the inverted set's
network was wrong or partly so: it is not MNIST with more light.

**What this is not.** A network trained for the tile: none of these was
trained with the tile's errors in the loop, and one that was may take more of
them. A network trained well: the trainer is MNIST's, unchanged, and a better
one would move the inverted set's figures most. Another kind of network:
Fashion-MNIST is MNIST's size and shape, and no convolution, residual path or
attention has been run. A version of the budget that holds: nothing here says
what tightening which rows would buy. The drift is the fits' and the cells
still drift independently. And a model: none of it is a measurement of a tile.

### What would tightening v1 buy?

*Added 2026-10-06.* `sim/pta_mnist.sh DIR WORK tighten`. Reported, not gated.

**Why.** The section above found v1 at over a point on two data sets, and
could not say where in v1 the point is. Every sweep before this measured a row
relaxed towards v0, or all of v1 at once, and none measured v1 with a row made
better. grxcp's board plan has to decide whether to hold its interface chip to
something tighter than v1, and tighter in what.

**What it runs.** On the 128 × 64 tile, 38 settings on a data set's five
networks: 190 evaluations, about a quarter of an hour on five jobs.

- v1.
- Each of v1's six rows taken away alone, which is the most that tightening
  that row could buy. The activation DAC at all 8 of an operand's bits, the
  ADC at 12 bits, and each noise row and each of a weight's rows switched off.
- Each row one notch tighter alone: a bit more in a converter, and half the
  noise or the error. Crosstalk's field has a step of 1/256, so half of v1's
  2% is run as 1.2%, and half of that as 0.4%.
- Those notches in pairs, in threes and all six; and all six, two notches.
- The two converters with nothing else.
- v1's rows and two tighter sets under a laser of 4 to 64 times grxcp's B5,
  with the hidden rescale a bit down.

No option is new, and `pta_mnist.c` is untouched. The mode checks every run
against its own row: the tile, the converters, which rows are on, each row's
size to the Q8.8 it is held in, that a row which is on has a size and one
which is off has none, that a row named for a laser is that laser, and that
the first row is v1 as every mode before this ran it. 28 errors planted one at
a time each fail it: 21 in a result's line after the fact, and 7 in the script
itself. On each data set v1's five lines are byte for byte the `geometry`
mode's. The sweep was run twice, the second time with eight settings more,
and the 150 lines the two share are byte for byte alike on all three sets.

**What a row buys.** v1's loss less the setting's, network by network, mean
and standard error over the five:

| | MNIST | Fashion-MNIST | MNIST, inverted |
|---|---|---|---|
| v1 loses | 0.34 ± 0.07 | 1.16 ± 0.14 | 1.23 ± 0.13 |
| One row gone: the activation DAC's | 0.06 ± 0.03 | −0.01 ± 0.03 | 0.06 ± 0.05 |
| the ADC's, at 12 bits | 0.08 ± 0.08 | **0.26 ± 0.09** | 0.15 ± 0.06 |
| the receiver's noise | **0.17 ± 0.03** | **0.31 ± 0.14** | 0.20 ± 0.07 |
| the shot noise | **0.20 ± 0.03** | **0.26 ± 0.11** | **0.52 ± 0.14** |
| programming error | 0.05 ± 0.03 | −0.04 ± 0.07 | 0.12 ± 0.06 |
| crosstalk | −0.01 ± 0.03 | −0.08 ± 0.11 | 0.13 ± 0.09 |
| One row a notch: 7 activation bits | 0.03 ± 0.02 | 0.02 ± 0.05 | 0.10 ± 0.08 |
| an 8-bit ADC | 0.07 ± 0.08 | 0.29 ± 0.06 | 0.15 ± 0.08 |
| receiver noise 0.25 LSB | 0.13 ± 0.05 | 0.10 ± 0.07 | 0.17 ± 0.04 |
| 30 photons | 0.12 ± 0.03 | 0.11 ± 0.11 | 0.26 ± 0.07 |
| programming error 0.5 LSB | 0.04 ± 0.02 | −0.05 ± 0.07 | 0.13 ± 0.04 |
| crosstalk 1.2% | 0.02 ± 0.03 | −0.06 ± 0.08 | 0.06 ± 0.07 |
| A notch together: both converters | 0.14 ± 0.05 | 0.24 ± 0.07 | 0.26 ± 0.03 |
| both noise rows | 0.17 ± 0.04 | 0.30 ± 0.12 | 0.43 ± 0.10 |
| both of a weight's rows | 0.03 ± 0.03 | 0.08 ± 0.07 | 0.08 ± 0.02 |
| the ADC and both noise rows | 0.19 ± 0.06 | **0.62 ± 0.10** | **0.61 ± 0.06** |
| the other three | 0.09 ± 0.05 | 0.04 ± 0.03 | 0.11 ± 0.07 |
| all six | 0.28 ± 0.05 | 0.76 ± 0.07 | 0.72 ± 0.06 |
| All six, two notches | 0.31 ± 0.07 | 0.98 ± 0.07 | 1.01 ± 0.11 |

And what is then lost, against the same weights on the host:

| | MNIST | Fashion-MNIST | MNIST, inverted |
|---|---|---|---|
| v1 | 0.34 ± 0.07 | 1.16 ± 0.14 | 1.23 ± 0.13 |
| The ADC and both noise rows a notch tighter | 0.15 ± 0.02 | 0.54 ± 0.22 | 0.62 ± 0.07 |
| All six a notch tighter | **0.06 ± 0.02** | **0.39 ± 0.15** | **0.50 ± 0.08** |
| All six, two notches | 0.03 ± 0.02 | 0.18 ± 0.08 | 0.22 ± 0.06 |
| The ADC and both noise rows gone | 0.11 ± 0.03 | 0.22 ± 0.12 | 0.48 ± 0.06 |
| The converters alone: v1's 6 activation bits and 7-bit ADC | 0.12 ± 0.07 | 0.37 ± 0.08 | 0.27 ± 0.06 |
| a notch tighter, 7 and 8 | 0.02 ± 0.04 | 0.02 ± 0.09 | 0.10 ± 0.06 |

**On Fashion-MNIST v1's point is in three rows.** The ADC's quantisation, the
receiver's noise and the shot noise are each worth a quarter to a third of a
point taken away. The activation DAC's sixth bit, programming error at 1 LSB
and crosstalk at 2% are worth nothing there: −0.01, −0.04 and −0.08, each
inside its error. The section above could not see this. Relaxed to v0, those
three rows cost 0.30, 0.65 and 0.78 on the core's tile. They are dear to
loosen and free to hold.

**One more bit is all the ADC has to give.** On Fashion-MNIST an 8-bit ADC
buys 0.29 and a 12-bit one 0.26. With nothing else on the tile, v1's two
converters cost 0.37 there, and a notch tighter 0.02.

**The inverted set spreads it.** Its shot noise is half a point by itself.
Every other row is between 0.06 and 0.20, and with the ADC and both noise
rows gone it still loses 0.48, where Fashion-MNIST loses 0.22 and MNIST 0.11.
Programming error and crosstalk are worth an eighth of a point each there and
little or nothing on the other two, which is the light again: those are the
errors a weight carries to a sum by what it is lit with.

**On MNIST it is the two noise rows**, 0.17 and 0.20, and little else.

**The rows do not add, and not the same way.** Taken away one at a time, the
six buy 0.55, 0.70 and 1.18 summed, where v1 loses 0.34, 1.16 and 1.23. On
MNIST either noise row gone gets half or more of what there is. On
Fashion-MNIST no one row gets a third: the ADC and both noise rows gone
together buy 0.93, and singly 0.83.

**All six a notch tighter cost 0.06, 0.39 and 0.50.** That puts Fashion-MNIST
where v1 puts MNIST. Two notches halve it again.

**The ADC and both noise rows are four fifths of it.** A notch on those three
buys 0.62 of the 0.76 on Fashion-MNIST and 0.61 of the 0.72 on the inverted
set, and 0.19 of the 0.28 on MNIST. A notch on the other three, by itself,
buys 0.04 to 0.11.

**Under a laser.** The receiver's noise as a laser of that many times grxcp's
B5 fixes it, the hidden rescale a bit down, and the other rows at v1's; at
v1's with an 8-bit ADC and 30 photons; and all a notch tighter. "As budgeted"
is each set at the rule's rescale with the receiver's noise the budget's.

| MNIST | v1's rows | The ADC and the light | All six |
|---|---|---|---|
| As budgeted | 0.34 ± 0.07 | 0.15 ± 0.02 | 0.06 ± 0.02 |
| Laser × 4 | **0.35 ± 0.06** | 0.25 ± 0.06 | 0.23 ± 0.04 |
| × 8 | 0.22 ± 0.06 | **0.11 ± 0.03** | **0.08 ± 0.03** |
| × 16 | 0.19 ± 0.06 | 0.09 ± 0.04 | 0.12 ± 0.03 |
| × 32 | 0.19 ± 0.07 | 0.12 ± 0.04 | 0.11 ± 0.02 |
| × 64 | 0.18 ± 0.09 | 0.09 ± 0.04 | 0.09 ± 0.01 |

| Fashion-MNIST | v1's rows | The ADC and the light | All six |
|---|---|---|---|
| As budgeted | 1.16 ± 0.14 | 0.54 ± 0.22 | 0.39 ± 0.15 |
| Laser × 4 | 1.93 ± 0.34 | 1.57 ± 0.35 | 1.44 ± 0.32 |
| × 8 | **1.19 ± 0.13** | 0.74 ± 0.20 | 0.68 ± 0.17 |
| × 16 | 0.96 ± 0.07 | **0.55 ± 0.17** | **0.40 ± 0.15** |
| × 32 | 0.88 ± 0.10 | 0.42 ± 0.18 | 0.38 ± 0.13 |
| × 64 | 0.84 ± 0.10 | 0.40 ± 0.15 | 0.31 ± 0.16 |

| MNIST, inverted | v1's rows | The ADC and the light | All six |
|---|---|---|---|
| As budgeted | 1.23 ± 0.13 | 0.62 ± 0.07 | 0.50 ± 0.08 |
| Laser × 4 | 2.29 ± 0.29 | 1.76 ± 0.22 | 1.63 ± 0.25 |
| × 8 | 1.37 ± 0.16 | 0.91 ± 0.14 | 0.75 ± 0.13 |
| × 16 | **1.17 ± 0.12** | **0.64 ± 0.11** | **0.54 ± 0.12** |
| × 32 | 1.12 ± 0.13 | 0.63 ± 0.12 | 0.53 ± 0.12 |
| × 64 | 1.11 ± 0.11 | 0.67 ± 0.11 | 0.49 ± 0.09 |

In bold, the least laser within a tenth of a point of that column's own
budget. v1's rows take 4, 8 and 16 times B5's, as the sections above found.
Either tighter set takes 8, 16 and 16: twice the laser on MNIST and on
Fashion-MNIST, and no more at all on the inverted set.

**The rows are worth more than the laser.** At 8 times B5's laser
Fashion-MNIST loses 1.19 at v1's rows, and 0.74 with an 8-bit ADC and 30
photons. Eight times more laser at v1's rows gets it to 0.84. The inverted
set is the same: 1.37, then 0.91, against 1.11. Of the two, the bit is the
larger on Fashion-MNIST, 0.29 alone as budgeted against 0.11, and the photons
on the inverted set, 0.26 against 0.15.

**What was predicted.** Ten things before the first run was read, and three
more before the second.

1. That on Fashion-MNIST the ADC's row gone would buy 0.25 to 0.4. Right:
   0.26.
2. That the shot noise gone would buy 0.2 to 0.35. Right: 0.26.
3. That the receiver's noise gone would buy 0.1 to 0.2. High of it, 0.31, and
   inside its error.
4. That the activation DAC's row gone would buy 0.1 to 0.2. Wrong: nothing.
5. That programming error and crosstalk gone would each buy under a tenth.
   Right: nothing.
6. That all six a notch tighter would lose 0.45 to 0.6 on Fashion-MNIST, 0.5
   to 0.7 on the inverted set and 0.10 to 0.18 on MNIST. Right for the
   inverted set, 0.50. A little better on Fashion-MNIST, 0.39, and better on
   MNIST, 0.06.
7. That two notches would lose 0.2 to 0.3 on Fashion-MNIST. Just under: 0.18.
8. That v1's two converters with nothing else would cost 0.4 to 0.6 there,
   half of v1's point. Just under, and a third of it: 0.37.
9. That on the inverted set the shot noise gone would buy the most and
   programming error next. Right about the first, 0.52. Wrong about the
   second: programming error is fifth of the six.
10. That the tighter rows would take twice v1's laser on each set: 8, 16 and
    32. Right on two. On the inverted set they take 16, which is v1's.
11. That a notch on the ADC and both noise rows would buy 0.55 to 0.7 of what
    all six buy on Fashion-MNIST. Right: 0.62 of 0.76.
12. That a notch on the other three would buy under a tenth. Right on two
    sets, 0.04 and 0.09, and 0.11 on the inverted one.
13. That those three rows under a laser would be within a tenth of their own
    budget at 16 times B5's on Fashion-MNIST. Right.

Five right, seven partly, one wrong. The wrong one is the finding: the
activation DAC's sixth bit costs nothing here.

**What this is not.** A price. It says what a bit or a halving buys in points,
and what one costs in silicon and in light is grxcp's to set beside it. A
network trained for the tile, or trained well, as above: these are the same
fifteen networks. The light's row under a laser as a laser would have it: the
row is photons per LSB, held where the budget puts it while the laser
multiplies, and a real laser moves both; a pair's shot noise also follows all
the light it is lit with, which this model does not have. One notch of
crosstalk is 1.2% and not 1%. One tile. And a model: none of it is a
measurement of a tile.

### Drift and a source's rows at grxcp's version 2

*Added 2026-10-06.* `sim/pta_mnist.sh DIR WORK v2`. Reported, not gated.

**Why.** grxcp's board plan chose from the section above. Its B14 holds the
interface chip to its version 2: v1 with an 8-bit ADC, half the receiver's
noise and twice the photons, which is that section's "the ADC and both noise
rows". Drift was measured at v1 and nowhere else, and so were a source's rows,
and on one data set. A budget that loses half as much has less for either to
hide in.

**What it runs.** On the 128 × 64 tile on two buses, twenty rows at each
version on a data set's five networks: 200 evaluations, a quarter of an hour
on five jobs. Each version as budgeted. After six minutes, an hour, four hours
and 46 hours of TFLT's drift, an hour of TFLN's, and an hour and then C3's
calibration. With a source's noise through a balanced pair: the lines together
at 1, 2, 5 and 10% rms a shot, a line on its own at 2, 5, 10 and 20%, and the
lines' level at 2, 5 and 10%. And the three together, as grxcp budgets them
and at 5% each.

No option is new, and `pta_mnist.c` is untouched. The mode checks every run
against its row, three ways. The version's six rows are written out a second
time in the check and held to the options. The drift, the hours, the
calibration and the source's three sizes are read from the row's name and held
to the options. And each of those is held to the line the run printed. 42
errors planted one at a time each fail it: 29 in a result's line after the
fact, and 13 in the script. v1's lines are byte for byte what the modes before
this wrote: 35 of `geometry`'s on each data set, 70 of `source`'s on MNIST,
and on each data set the ten that `tighten` wrote for the two versions as
budgeted.

**Drift adds what it added.** What a row adds to its own version as budgeted,
network by network, mean and standard error:

| | MNIST, v1 | v2 | Fashion-MNIST, v1 | v2 | Inverted, v1 | v2 |
|---|---|---|---|---|---|---|
| As budgeted, points lost | 0.34 ± 0.07 | 0.15 ± 0.02 | 1.16 ± 0.14 | 0.54 ± 0.22 | 1.23 ± 0.13 | 0.62 ± 0.07 |
| Six minutes of TFLT's drift adds | −0.01 ± 0.02 | −0.06 ± 0.04 | 0.08 ± 0.10 | 0.08 ± 0.06 | 0.20 ± 0.26 | 0.28 ± 0.27 |
| An hour | 0.17 ± 0.05 | 0.12 ± 0.05 | 0.69 ± 0.33 | 0.67 ± 0.31 | 1.95 ± 1.29 | 1.99 ± 1.26 |
| Four hours | 0.40 ± 0.08 | 0.37 ± 0.08 | 2.34 ± 0.43 | 2.36 ± 0.57 | 16.54 ± 3.01 | 16.07 ± 3.09 |
| 46 hours | 9.02 ± 0.97 | 8.69 ± 0.85 | 22.10 ± 1.38 | 22.60 ± 1.38 | 66.89 ± 2.99 | 67.51 ± 2.97 |
| An hour of TFLN's | 2.47 ± 0.20 | 2.35 ± 0.17 | 7.22 ± 1.48 | 7.29 ± 1.50 | 37.35 ± 5.63 | 37.38 ± 5.74 |
| An hour of TFLT's, then calibrated | −0.13 ± 0.03 | −0.06 ± 0.03 | 0.03 ± 0.15 | 0.02 ± 0.11 | −0.09 ± 0.08 | −0.01 ± 0.05 |
| So after an hour, points lost | 0.51 ± 0.07 | 0.27 ± 0.06 | 1.84 ± 0.39 | 1.21 ± 0.28 | 3.18 ± 1.27 | 2.61 ± 1.25 |

At every age and on every data set drift adds to version 2 what it adds to
v1. The two differ by at most eight hundredths of a point where the figures
are small, and by under half a standard error where they are large. A tighter
converter and a quieter receiver neither hide drift nor expose it: in points,
it is its own. And calibration returns version 2 to its budget, as it
returned v1.

**So at version 2 an hour's drift is most of what the harder sets lose.** On
Fashion-MNIST it adds 0.67 to a budget of 0.54, and on the inverted set 1.99
to one of 0.62. At six minutes it adds 0.08 and 0.28. Version 2 bought half
the budget's loss, and an hourly calibration gives more than that back on
either.

**A source's rows.** The same, for a source's noise through a balanced pair.
The sizes are rms fractions of a line's power:

| | MNIST, v1 | v2 | Fashion-MNIST, v1 | v2 | Inverted, v1 | v2 |
|---|---|---|---|---|---|---|
| The lines together, 1% | 0.00 ± 0.02 | 0.01 ± 0.02 | 0.06 ± 0.06 | 0.04 ± 0.04 | 0.10 ± 0.06 | 0.13 ± 0.08 |
| **2%** | −0.06 ± 0.03 | 0.02 ± 0.02 | 0.05 ± 0.02 | 0.03 ± 0.04 | **0.16 ± 0.06** | **0.24 ± 0.05** |
| 5% | 0.04 ± 0.04 | 0.02 ± 0.05 | 0.12 ± 0.04 | 0.01 ± 0.08 | 0.82 ± 0.05 | 0.90 ± 0.13 |
| 10% | 0.19 ± 0.04 | 0.18 ± 0.04 | 0.16 ± 0.03 | 0.25 ± 0.10 | 3.20 ± 0.21 | 3.23 ± 0.31 |
| A line on its own, 2% | 0.02 ± 0.05 | 0.05 ± 0.03 | 0.04 ± 0.09 | −0.01 ± 0.07 | 0.06 ± 0.07 | 0.13 ± 0.04 |
| **5%** | 0.09 ± 0.07 | 0.05 ± 0.05 | 0.11 ± 0.14 | 0.14 ± 0.12 | 0.11 ± 0.13 | **0.25 ± 0.07** |
| 10% | 0.22 ± 0.07 | 0.16 ± 0.05 | 0.27 ± 0.12 | 0.34 ± 0.09 | 0.39 ± 0.18 | 0.54 ± 0.09 |
| 20% | 0.59 ± 0.07 | 0.55 ± 0.08 | 0.73 ± 0.15 | 0.75 ± 0.14 | 1.81 ± 0.25 | 1.88 ± 0.23 |
| The lines' level, 2% | 0.03 ± 0.05 | 0.05 ± 0.03 | 0.09 ± 0.05 | −0.01 ± 0.04 | −0.03 ± 0.04 | 0.01 ± 0.02 |
| **5%** | 0.05 ± 0.06 | 0.03 ± 0.03 | 0.09 ± 0.08 | 0.01 ± 0.07 | 0.05 ± 0.11 | 0.17 ± 0.06 |
| 10% | 0.10 ± 0.10 | 0.12 ± 0.04 | 0.22 ± 0.12 | 0.20 ± 0.15 | 0.21 ± 0.15 | 0.29 ± 0.10 |
| **All three, as grxcp budgets them: 2%, 5%, 5%** | 0.03 ± 0.11 | 0.06 ± 0.03 | 0.06 ± 0.11 | 0.09 ± 0.13 | **0.29 ± 0.17** | **0.37 ± 0.07** |
| All three at 5% | 0.12 ± 0.08 | 0.09 ± 0.03 | 0.20 ± 0.12 | 0.15 ± 0.12 | 0.98 ± 0.18 | 0.93 ± 0.17 |

**They hold at version 2 on MNIST and on Fashion-MNIST.** grxcp's three rows
together add 0.06 and 0.09, where at v1 they add 0.03 and 0.06: all under the
tenth of a point the rows were sized to. Row by row the two versions differ by
a tenth of a point at most, and not one way.

**They do not hold on the inverted set, at either version.** The three add
0.29 at v1 and 0.37 at version 2. And the dear row is the one the lines share.
At 2% it adds 0.16 and 0.24, at 5% over four fifths of a point, and at 10%
over three points, where on the other two sets 10% adds about a fifth. For
that row to cost a tenth there it has to be 1%. The lines together are drawn
once a shot and scale that shot's sum, and a layer goes through this tile in
seven shots. If those seven partial sums are large and nearly cancel, seven
separate draws leave what does not. That is what sums that are small
differences of a great deal of light would do, and it was not measured shot
by shot.

**On the inverted set a source costs a little more at version 2.** A tenth
more on each row that costs anything: 0.24 for 0.16, 0.25 for 0.11, 0.17 for
0.05. On the other two sets the versions do not differ one way. Drift did
not do this.

**grxcp then chose, and two rows were added.** *The same day.* Its B15
calibrates version 2 every six minutes, and its B16 holds the lines together
to 1% and not 2%. The mode gained the two rows that say what that is: a
source's three at 1%, 5% and 5%, and the same at the end of six minutes of
drift, which is a version with everything it is held to. That is 22 rows a
version and 220 evaluations. The 200 lines the mode wrote before are byte for
byte the same on each data set. The check now lets one row both drift and be
lit, and 51 errors planted one at a time each fail it, 34 in a line and 17 in
the script.

| | MNIST, v1 | v2 | Fashion-MNIST, v1 | v2 | Inverted, v1 | v2 |
|---|---|---|---|---|---|---|
| The three at 2%, 5% and 5% add | 0.03 ± 0.11 | 0.06 ± 0.03 | 0.06 ± 0.11 | 0.09 ± 0.13 | 0.29 ± 0.17 | 0.37 ± 0.07 |
| At 1%, 5% and 5% | 0.04 ± 0.10 | 0.04 ± 0.04 | 0.14 ± 0.11 | 0.04 ± 0.11 | 0.15 ± 0.12 | 0.28 ± 0.06 |
| And after six minutes of TFLT's drift | 0.06 ± 0.06 | 0.04 ± 0.02 | 0.21 ± 0.13 | 0.06 ± 0.15 | 0.37 ± 0.40 | 0.48 ± 0.29 |
| Which is, in points lost | 0.40 ± 0.03 | **0.19 ± 0.03** | 1.37 ± 0.23 | **0.60 ± 0.23** | 1.60 ± 0.50 | **1.09 ± 0.36** |

On MNIST and on Fashion-MNIST version 2 with everything it is held to loses
0.19 and 0.60, which is 0.04 and 0.06 over its budget. A source and an
interval's drift together cost it less than a tenth of a point.

On the inverted set it loses 1.09, half a point over. Halving the row the
lines share took the three from 0.37 to 0.28 and no further. The two rows a
line carries are 0.25 and 0.17 by themselves there, and at 1% they are most of
what a source costs.

**What was predicted.** Written before the runs were read. Eight things.

1. That an hour's drift would add to version 2 about what it adds to v1 or a
   little less: 0.1 to 0.2 on MNIST, 0.4 to 0.7 on Fashion-MNIST, 1.3 to 2.0 on
   the inverted set. Right: 0.12, 0.67 and 1.99.
2. That four hours would be within 30% of v1's. Right: within 8%.
3. That six minutes would add under a tenth on MNIST and Fashion-MNIST, and
   0.1 to 0.2 on the inverted set. Right on two, and 0.28 on the third, inside
   its error.
4. That calibration would return version 2 to within a tenth of its budget.
   Right, to within 0.06.
5. That on MNIST each of a source's rows would add under a tenth at both
   versions, and the three under 0.15 at version 2. Right.
6. The same on Fashion-MNIST. Right for two rows. A line on its own at 5% adds
   0.11 and 0.14, which its error covers.
7. That on the inverted set the two rows a line carries would each add 0.2 to
   0.5 and the row the lines share under a tenth. Wrong, and the wrong way
   round: the shared row is the dear one, and a line's two are 0.05 to 0.25.
8. That no row within a tenth at v1 would be over two tenths at version 2.
   Right.

Five right, two partly, one wrong.

And three more, before the two rows were run.

9. That the three at 1%, 5% and 5% would add 0.03 to 0.08 to version 2 on
   MNIST, 0.05 to 0.15 on Fashion-MNIST and 0.2 to 0.3 on the inverted set.
   Right on two, and just under on Fashion-MNIST: 0.04, 0.04 and 0.28.
10. That with six minutes of drift as well they would add under a tenth on
    MNIST, 0.1 to 0.25 on Fashion-MNIST and 0.4 to 0.6 on the inverted set.
    Right on two, and under on Fashion-MNIST: 0.04, 0.06 and 0.48.
11. That version 2 would then lose about 0.2, 0.7 and 1.1. Right: 0.19, 0.60
    and 1.09.

**What this is not.** A measurement of a source or of a drift: the source's
term is first order and added on the host's side of the line, the drift is the
fits', and every cell still drifts on its own. A pair only: the offset reading
was not rerun. Two buses, one tile, and the same fifteen networks, none
trained for the tile. And version 2 is grxcp's name for a set of rows this
harness ran. Nothing here says it is the right set.

### A network trained for the tile

*Added 2026-10-06.* `pta_mnist train --sumnoise F --epochs N`, and
`sim/pta_mnist.sh DIR WORK trained`. Reported, not gated.

**Why.** Every network in this note was trained on its host and then run on a
tile it had never seen. Each section since the second data set says so, and
§7's item 9 calls training with the errors in the loop the usual remedy and
says this harness cannot tell what it would give back. grxcp's B14 lists it
first among the things that would reopen its version 2.

**The trainer.** `--sumnoise F` gives every sum of every layer, before its
bias, Gaussian noise of F times that layer's rms, drawn afresh for each image
at each step. That is a tile as a network being trained can be shown it: the
probe puts a tile's error at about a tenth of its sums' rms at v1. The rms is
the layer's own, tracked as training moves it, and the gradient is taken
through the noisy sums. `--epochs N` runs N epochs, where the trainer has
always stopped at the first whose held-out accuracy fails to rise.

That rule turned out to matter more than the noise. A noisy network stops at
once by it: the first try, at a tenth, ran two epochs and came out half a
point worse on its host than the network it was meant to improve. So every
network here is trained for eight epochs, and one of them with no noise, to
tell the noise from the epochs.

With neither option the trainer is what it was. Two networks trained again
without them, one on MNIST and one on Fashion-MNIST, are byte for byte the
files this note has used, and their training lines are the same lines. With
`--sumnoise` a training's line says what was put on each layer's sums over
its last epoch: 4.98 to 4.99%, 9.96 to 9.98% and 19.87 to 19.96% of their rms
for 5, 10 and 20% asked.

**What it runs.** On each data set, each seed's 6-bit network again from the
same 8-bit one, for eight epochs, with no noise and with 5, 10 and 20% of it:
twenty networks. Then all twenty-five, those and the five trained before, on
the 128 × 64 tile on two buses at grxcp's v1 and its version 2, as budgeted
and held: with a source's three rows at 1%, 5% and 5%, at the end of six
minutes of drift. 100 evaluations, and with the training about a quarter of
an hour on five jobs, or twice that on the inverted set, whose images are
dense.

The mode checks every network and every run against its place. A training's
line has to say its epochs and its noise, and the noise put on each layer has
to be what was asked to a twentieth, and none where none was asked. A run has
to be of the network its training wrote, by its accuracy on the host and its
epochs, and its rows are written out a second time in the check. 44 errors
planted one at a time each fail: 8 in the trainer's noise, against the
self-test; 26 in a training's line or a run's, after the fact; and 10 in the
script. The twenty lines a data set's old networks give here are byte for
byte what `v2` wrote for the same runs.

**What came of it.** Accuracy, percent, five networks, mean and standard
error.

| Fashion-MNIST | On its host | v1 | Version 2 | v1, held | Version 2, held |
|---|---|---|---|---|---|
| Trained as before | 87.48 ± 0.19 | 86.32 ± 0.18 | 86.94 ± 0.20 | 86.11 ± 0.14 | 86.88 ± 0.09 |
| 8 epochs, no noise | 87.66 ± 0.16 | 86.30 ± 0.22 | 87.13 ± 0.13 | 86.28 ± 0.18 | 87.04 ± 0.16 |
| 8 epochs, noise of 5% | 87.75 ± 0.15 | 86.60 ± 0.25 | 87.21 ± 0.24 | 86.47 ± 0.12 | 87.13 ± 0.14 |
| 8 epochs, noise of 10% | **87.89 ± 0.16** | 86.77 ± 0.26 | **87.41 ± 0.13** | 86.69 ± 0.25 | **87.27 ± 0.13** |
| 8 epochs, noise of 20% | 87.27 ± 0.14 | **86.82 ± 0.15** | 87.06 ± 0.16 | **86.88 ± 0.14** | 87.03 ± 0.11 |

| MNIST, inverted | On its host | v1 | Version 2 | v1, held | Version 2, held |
|---|---|---|---|---|---|
| Trained as before | 93.36 ± 0.54 | 92.13 ± 0.56 | 92.74 ± 0.55 | 91.76 ± 0.65 | 92.27 ± 0.63 |
| 8 epochs, no noise | **95.55 ± 0.36** | 94.17 ± 0.59 | **94.88 ± 0.46** | 93.63 ± 0.70 | 94.51 ± 0.53 |
| 8 epochs, noise of 5% | 95.48 ± 0.35 | 93.98 ± 0.53 | 94.83 ± 0.43 | 93.69 ± 0.62 | 94.45 ± 0.51 |
| 8 epochs, noise of 10% | 95.38 ± 0.33 | **94.42 ± 0.37** | 94.86 ± 0.36 | **94.18 ± 0.54** | **94.63 ± 0.53** |
| 8 epochs, noise of 20% | 94.12 ± 0.47 | 93.45 ± 0.45 | 93.74 ± 0.47 | 93.32 ± 0.46 | 93.60 ± 0.47 |

| MNIST | On its host | v1 | Version 2 | v1, held | Version 2, held |
|---|---|---|---|---|---|
| Trained as before | 97.45 ± 0.10 | 97.11 ± 0.13 | 97.30 ± 0.11 | 97.05 ± 0.10 | 97.26 ± 0.10 |
| 8 epochs, no noise | 97.74 ± 0.10 | **97.52 ± 0.10** | 97.66 ± 0.10 | 97.46 ± 0.10 | 97.57 ± 0.09 |
| 8 epochs, noise of 5% | 97.75 ± 0.08 | 97.52 ± 0.08 | 97.60 ± 0.08 | 97.44 ± 0.10 | 97.54 ± 0.08 |
| 8 epochs, noise of 10% | 97.75 ± 0.06 | 97.49 ± 0.06 | **97.68 ± 0.04** | 97.44 ± 0.04 | **97.64 ± 0.07** |
| 8 epochs, noise of 20% | **97.76 ± 0.03** | 97.50 ± 0.02 | 97.63 ± 0.04 | **97.48 ± 0.03** | 97.60 ± 0.04 |

And the same as this note has always given it, points lost against the
network's own accuracy on its host:

| | Fashion-MNIST: v1 | Version 2 | Inverted: v1 | Version 2 | MNIST: v1 | Version 2 |
|---|---|---|---|---|---|---|
| Trained as before | 1.16 ± 0.14 | 0.54 ± 0.22 | 1.23 ± 0.13 | 0.62 ± 0.07 | 0.34 ± 0.07 | 0.15 ± 0.02 |
| 8 epochs, no noise | 1.35 ± 0.16 | 0.53 ± 0.08 | 1.37 ± 0.25 | 0.67 ± 0.11 | 0.21 ± 0.04 | 0.08 ± 0.05 |
| 8 epochs, noise of 5% | 1.14 ± 0.13 | 0.54 ± 0.11 | 1.50 ± 0.21 | 0.65 ± 0.11 | 0.23 ± 0.03 | 0.15 ± 0.01 |
| 8 epochs, noise of 10% | 1.12 ± 0.22 | 0.47 ± 0.13 | 0.97 ± 0.06 | 0.52 ± 0.05 | 0.26 ± 0.05 | 0.07 ± 0.05 |
| 8 epochs, noise of 20% | 0.46 ± 0.10 | 0.21 ± 0.11 | 0.67 ± 0.08 | 0.38 ± 0.08 | 0.25 ± 0.04 | 0.13 ± 0.02 |

**The epochs matter more than the noise.** Eight of them with no noise raise a
network's accuracy on its host by 0.18 of a point on Fashion-MNIST, 0.29 on
MNIST and 2.19 on the inverted set, and its accuracy on a v1 tile by nothing,
0.41 and 2.04. The inverted set's networks were not trained: by the rule this
harness has always stopped on, they ran four epochs and came out at 93.4%,
and at eight they are at 95.5%. That is half of what the section on a second
workload put down to their inputs. Every accuracy this note gives for that
set is two points low for it.

**What those networks lose is still what was said.** A network's loss against
its own host accuracy moves little: 1.35 for 1.16 on Fashion-MNIST at v1,
1.37 for 1.23 on the inverted set, and 0.21 for 0.34 on MNIST, which is the
one that moves. The budget's price in points was not the artefact. The
accuracies were.

**Noise at the tile's own size buys half a point on Fashion-MNIST.** At 10%,
on a v1 tile, a network is right 0.47 of a point more often than the same
network trained without noise on Fashion-MNIST, 0.25 more on the inverted
set, and no more on MNIST. The 0.25 is inside its error (below). It costs
nothing on the host: those
networks are the best there on Fashion-MNIST and within a fifth of a point of
the best on the other two. Held, with a source and an interval's drift, it is
worth 0.41 and 0.55.

**Twice the tile's size cuts the loss by two thirds and gives up accuracy to
do it.** At 20% a network loses 0.46 points to a v1 tile on Fashion-MNIST
where the others lose 1.1 to 1.35, and 0.67 for 1.0 to 1.5 on the inverted
set. It also starts 0.4 to 0.6 of a point lower on its host than the other
eight-epoch networks on Fashion-MNIST, and 1.3 to 1.4 lower on the inverted
set. On the tile it is level with the 10%
network at v1 on Fashion-MNIST and a point behind it on the inverted set. A
smaller loss is not a better network, and points lost is the wrong score for
this.

**Version 2 buys a trained network what it bought the others.** With 10% of
noise, version 2 is 0.64 of a point over v1 on Fashion-MNIST, 0.44 on the
inverted set and 0.19 on MNIST. For the networks trained before it is 0.62,
0.61 and 0.19. Training and the tighter rows add: the 10% network at version
2 is 1.09, 2.73 and 0.57 points over the old one at v1.

**And training alone is about what version 2 was.** On a v1 tile the 10%
network is at 86.77 on Fashion-MNIST, where the old one at version 2 is at
86.94: 0.17 short, and inside their errors. On the other two sets the trained
network at v1 is ahead of the old one at version 2, by 0.19 on MNIST and 1.68
on the inverted set, and on both it is the epochs that do it.

**How sure.** A row's error above is the scatter of its five networks, and
most of that scatter is the networks' own: on the inverted set seed 4 is the
lowest of all four rows trained here. Two rows of the same seeds are better
compared seed by seed, where a
difference has its own error. The mode does not print those. grxcp's
`docs/designs/pta_trained.py` holds each network's figures as this mode's
lines gave them, computes these tables from them again cell for cell, and
takes the differences:

| Seed by seed | MNIST | Fashion-MNIST | MNIST, inverted |
|---|---|---|---|
| Eight epochs with no noise, over trained as before: on the host | +0.29 ± 0.14 | +0.18 ± 0.28 | **+2.19 ± 0.49** |
| On a v1 tile | +0.41 ± 0.15 | −0.02 ± 0.22 | **+2.04 ± 0.68** |
| Noise of 10%, over none: on a v1 tile | −0.03 ± 0.07 | +0.46 ± 0.18 | +0.24 ± 0.28 |
| At version 2 | +0.02 ± 0.06 | **+0.29 ± 0.07** | −0.02 ± 0.18 |
| v1, held | −0.01 ± 0.10 | +0.41 ± 0.21 | +0.54 ± 0.26 |
| Version 2 over v1, the same network: trained as before | **+0.19 ± 0.06** | **+0.62 ± 0.10** | **+0.61 ± 0.06** |
| With noise of 10% | **+0.19 ± 0.04** | **+0.65 ± 0.15** | **+0.44 ± 0.03** |
| The 10% network at v1, over the old one at version 2 | +0.19 ± 0.10 | −0.17 ± 0.24 | **+1.67 ± 0.46** |

With five networks a difference has to be 2.8 of its own errors to be outside
chance at one in twenty, and those in bold are. So, of what is said above.
The epochs are clear on the inverted set, two to three errors on MNIST, and
not shown on Fashion-MNIST. The noise's half point on Fashion-MNIST is 2.5
errors at v1 and clear at version 2; on the inverted set it is not shown at
either, and held it is two errors. What version 2 buys is clear for every
kind of network. And a figure here can differ in the last digit from the
paragraphs above, which subtract two rounded means.

**What was predicted.** Written before the runs were read. Four things.

1. That eight epochs would raise Fashion-MNIST's accuracy on the host by 0.3
   to 0.7, with or without noise, and that 10% of noise would stay within 0.3
   of none. Partly: 0.18 without and 0.41 with, and the two are 0.23 apart.
2. That the network with no noise would lose about what the old ones lose,
   and 10% of noise would halve it: 0.4 to 0.7 on Fashion-MNIST, under 0.2 on
   MNIST, 0.5 to 0.8 on the inverted set. Right about the first. Wrong about
   the second: 1.12, 0.26 and 0.97. It takes 20% to halve it.
3. That on Fashion-MNIST a network trained with noise would be at least as
   accurate on a v1 tile as an old one at version 2. Not quite: 0.17 short at
   10% and 0.12 at 20%, inside their errors.
4. That held at version 2 on the inverted set a network trained with noise
   would lose 0.6 to 0.9. Right at 10%, 0.76.

And nothing here predicted the epochs. The run was designed to measure noise,
and the control put in to hold the epochs still is the larger result.

**What this is not.** The tile in the loop. The noise is Gaussian, the same
fraction on every layer, and independent from sum to sum. A tile's error has a
quantiser's steps in it, a crosstalk that follows the image and a programming
error that stays put for a GEMM, and none of those was shown to a network
here. A tuned trainer: eight epochs was chosen once and not searched, and so
were the three sizes of noise. A full grid: noise under the old stopping rule
was tried once, on one network, and stopped at two epochs. Another kind of
network, or a tile, as everywhere above.

**grxcp then chose, and nothing here was run again.** *The same day.* Two
things. Its B14 stands: the interface chip is held to version 2, because
version 2 is worth to a trained network what it was worth to the others. And
its B17 makes the networks trained for eight epochs with 10% of noise the
reference: a sweep run from 2026-10-06 uses them, and no sweep before it is
run again.

In this harness the reference networks are `nets/d8_b6_sN_n0.1_e8.net`, one a
seed, and

    TRAINED_NOISES=0.1 sim/pta_mnist.sh DIR WORK trained

makes them in a work directory and prints the two tables above with two rows
each, the networks trained before and the reference. That is 40 evaluations
and three to four minutes on five jobs where the networks exist. Run on MNIST's
and on Fashion-MNIST's work directories it passed its check and wrote the
lines it had written before, byte for byte.

What that leaves as it was. Every mode above this section runs the networks
trained before and its recorded lines are theirs: `budget`, `geometry`,
`source`, `laser`, `fill`, `tighten`, `v2` and the rest. None was run on the
reference networks, and each still reproduces what it recorded. A mode added
after that date runs the reference networks, and the script's header says so
where the next one will be written. What a tile costs the reference networks
is in the tables above, at 128 × 64 on two buses, at v1 and at version 2, as
budgeted and held, and nowhere else.

### Does a trained network need the 1%?

*Added 2026-10-07.* `sim/pta_mnist.sh DIR WORK refsource`. Reported, not
gated.

**Why.** grxcp's B16 holds the row a source's lines share to 1% rms a shot and
not 2%. It was chosen on what the networks trained before lose on the inverted
set, where a source's three rows add 0.37 of a point at 2% and 0.28 at 1%, and
it lists a network trained for the tile among what would reopen it. Its B17
has since made such networks the reference, and the section above held them at
the 1% and at nothing else.

**What it runs.** The first mode on the reference networks, which is what the
script's header says of a mode added after 2026-10-06. The script now names
them in one place, `ref_net`, and trains them where they are not there,
`train_ref`. In a work directory with none, the five it trained and their
training lines are byte for byte the files `trained` wrote.

On each data set, at grxcp's version 2 on the 128 × 64 tile on two buses,
eleven rows: as budgeted; the lines together at 1, 2 and 5%; a line on its own
at 5% and the lines' level at 5%; the three at 2%, 5%, 5% and at 1%, 5%, 5%;
six minutes of TFLT's drift; and six minutes with each of those two. The last
is the chip as grxcp holds it. The networks trained before run beside the
reference row for row, because the 1% was chosen on them. That is 110
evaluations and seven to nine minutes on five jobs.

The mode checks every network and every run against its place. A reference
network's training line has to say the header's eight epochs and its noise of
0.1, and the noise put on each layer to a twentieth; one trained before has to
say neither. A run has to be of the network that training wrote, by its
accuracy on the host and its epochs, its six rows have to be version 2's,
written out again in the check, and its drift and its source's three sizes
have to be the ones its row's name says, in what it was asked and in the line
it printed. 84 errors planted one at a time each fail: 54 in a training's
line or a run's, after the fact; 20 in the script, six of them in how a
reference network is trained, each run in a directory that had to train its
own; and 10 in the tables' own code, which the check does not see and which
each move the tables. Of the script's, the check fails all but one, and that
one the trainer refuses before the check is reached: a network started from
another seed's.

Of the lines, 50 of the old networks' on each data set are byte for byte what
`v2` wrote for the same runs, the other five being the one row `v2` did not
have, six minutes with the three at 2%. And the ten of the reference networks'
that `trained` also ran are byte for byte its.

**What came of it.** Five networks of each kind, mean and standard error.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| As budgeted, points lost | 0.15 ± 0.02 | 0.07 ± 0.05 | 0.54 ± 0.22 | 0.47 ± 0.13 | 0.62 ± 0.07 | 0.52 ± 0.05 |

What a row adds to that, in points, network by network:

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| The lines together, 1% | 0.01 ± 0.02 | 0.03 ± 0.02 | 0.04 ± 0.04 | 0.02 ± 0.03 | 0.13 ± 0.08 | 0.00 ± 0.03 |
| 2% | 0.02 ± 0.02 | 0.06 ± 0.03 | 0.03 ± 0.04 | −0.06 ± 0.02 | 0.24 ± 0.05 | 0.05 ± 0.05 |
| 5% | 0.02 ± 0.05 | 0.08 ± 0.03 | 0.01 ± 0.08 | 0.06 ± 0.03 | 0.90 ± 0.13 | 0.46 ± 0.10 |
| A line on its own, 5% | 0.05 ± 0.05 | 0.04 ± 0.04 | 0.14 ± 0.12 | 0.16 ± 0.08 | 0.25 ± 0.07 | 0.00 ± 0.03 |
| The lines' level, 5% | 0.03 ± 0.03 | 0.02 ± 0.02 | 0.01 ± 0.07 | 0.02 ± 0.05 | 0.17 ± 0.06 | 0.12 ± 0.20 |
| All three: 2%, 5%, 5% | 0.06 ± 0.03 | 0.06 ± 0.03 | 0.09 ± 0.13 | 0.06 ± 0.06 | 0.37 ± 0.07 | 0.24 ± 0.24 |
| All three: 1%, 5%, 5% | 0.04 ± 0.04 | 0.07 ± 0.04 | 0.04 ± 0.11 | 0.03 ± 0.05 | 0.28 ± 0.06 | 0.16 ± 0.19 |
| Six minutes of TFLT's drift | −0.06 ± 0.04 | 0.01 ± 0.01 | 0.08 ± 0.06 | 0.07 ± 0.09 | 0.28 ± 0.27 | 0.08 ± 0.11 |
| Six minutes and 2%, 5%, 5% | 0.09 ± 0.02 | 0.02 ± 0.04 | 0.07 ± 0.14 | 0.11 ± 0.09 | 0.59 ± 0.32 | 0.20 ± 0.20 |
| Six minutes and 1%, 5%, 5% | 0.04 ± 0.02 | 0.04 ± 0.03 | 0.06 ± 0.15 | 0.15 ± 0.08 | 0.48 ± 0.29 | 0.24 ± 0.20 |

And the question itself. How often a network is right with the row the lines
share at 1%, less how often at 2%, in points, network by network:

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| The lines together, alone | +0.02 ± 0.02 | +0.03 ± 0.01 | −0.01 ± 0.03 | **−0.08 ± 0.02** | +0.11 ± 0.06 | +0.04 ± 0.03 |
| Among the three | +0.02 ± 0.02 | −0.01 ± 0.01 | +0.05 ± 0.02 | +0.03 ± 0.03 | **+0.09 ± 0.02** | +0.08 ± 0.06 |
| Held: the three, six minutes on | **+0.04 ± 0.00** | −0.02 ± 0.02 | +0.01 ± 0.04 | −0.03 ± 0.04 | +0.12 ± 0.06 | −0.04 ± 0.04 |
| Held, right, percent: the shared row at 2% | 97.22 | 97.66 | 86.87 | 87.30 | 92.15 | 94.67 |
| Held, right, percent: the shared row at 1% | 97.26 | 97.64 | 86.88 | 87.27 | 92.27 | 94.63 |

The two rows of a pair run from one seed. The source's draws are seeded from
it and not from their size, so a pair shares them at half the size, and a
pair's difference has an error of a few hundredths of a point. A hundredth is
one image in the ten thousand. With five networks a difference has to be 2.8
of its errors to be outside chance at one in twenty, and those in bold are.
One of them is four images.

**Held as grxcp holds the chip, the 1% buys the reference networks nothing.**
At the end of six minutes, with a line and the level at 5%, they are right
97.66, 87.30 and 94.67% of the time with the shared row at 2% and 97.64, 87.27
and 94.63% at 1%. The difference is the wrong way on all three sets and clear
on none.

**As budgeted it may buy them what it bought the old ones, and that is not
shown.** With no drift, among the three rows, the 1% is worth 0.08 ± 0.06 to
the reference networks on the inverted set. It was worth 0.09 ± 0.02 to the
networks trained before, which is the 0.09 grxcp's B16 has and is five of its
errors. The same size, at nearly four times the error.

**One result is the other way.** With the row alone on Fashion-MNIST the
reference networks are right eight images more often at 2% than at 1%, and by
the rule above that is clear. Among the three and held it is not there. A
network can be right a little more often for a little more noise on a sum
that sits at a quantiser's edge; nothing here was run to say that is what
this is.

**The rows themselves cost a trained network less on the inverted set.** The
lines together at 2% add 0.05 of a point where they add 0.24 to the networks
trained before, and at 5% 0.46 for 0.90. A line on its own at 5% adds nothing
for 0.25. Seed by seed that last is 0.24 ± 0.05 less, and it is the one row of
the ten there whose difference is clear (grxcp's `pta_shared_row.py` takes
them).

**And the three together are still not shown inside a tenth there.** 0.24 ±
0.24 at 2% and 0.16 ± 0.19 at 1%, each with an error its own size. It is one
network of the five: the lines' level at 5% costs seed 4 0.86 of a point, and
the other four between 0.26 gained and 0.17 lost. On MNIST and on
Fashion-MNIST the three add 0.06 at 2%.

**What was predicted.** Written before the mode was run on anything, on
2026-10-07. Five things.

1. That on MNIST and on Fashion-MNIST the 1% would buy the reference networks
   nothing that can be told: inside a tenth either way, with and without the
   drift. Right: −0.01 and −0.02 on MNIST, +0.03 and −0.03 on Fashion-MNIST.
2. That on the inverted set the three rows at 2%, 5%, 5% would add 0.15 to
   0.30 to the reference networks' budget, where they add 0.37 to the old
   ones'. Right, 0.24, and with an error of 0.24 it could not well have been
   wrong.
3. That on the inverted set the 1% would buy the reference networks less than
   the 0.09 it bought the old ones: 0.00 to 0.08, as budgeted. At its edge:
   0.08 ± 0.06, which is not less than 0.09 in any way that can be told.
4. That held at 2% and not at 1% the reference networks would lose 0.78 to
   0.90 on the inverted set, where held at 1% they lose 0.76. Wrong: 0.72.
   Held, the 2% is the better of the two there, inside its error.
5. That a network trained for the tile needs the 1% less than the old ones
   did, and that on no set does it buy one a tenth of a point. The second is
   right: 0.08 at the most, in nine cells. The first is suggested and not
   shown: held, the 1% is worth 0.06, 0.05 and 0.16 less to a reference
   network than to the old one of its seed, and only MNIST's six images are
   clear.

**What this is not.** A source: the term is first order and on the host's
side of the line, as in the section on a source's noise. A tile trained
against a source: the reference networks were trained with Gaussian noise on
their sums. The two rows a line carries at any size but 5%. v1, another tile,
or a source through an offset. And whether grxcp keeps its 1% is grxcp's to
say: this says what it buys. *grxcp kept it, the same day: its B16 stands,
with the 2% recorded as a way back if a comb cannot be had at the 1%.*

### The laser a trained network needs

*Added 2026-10-07.* `sim/pta_mnist.sh DIR WORK reflaser`. Reported, not
gated.

**Why.** The laser is most of what a MAC costs on grxcp's board. `tighten`
put version 2's rows under lasers on the networks trained before, with the
hidden rescale a bit down, and grxcp reads them as needing 8, 16 and 16 times
its B5 on the three data sets: the least laser at which they are within a
tenth of a point of what they lose as budgeted. A reference network was
trained with Gaussian noise on its sums, and a receiver's noise is Gaussian
noise on a sum. If training for the tile buys any hardware back, this is
where it should.

**What it runs.** The second mode on the reference networks. At version 2's
rows on the 128 × 64 tile, eleven rows: as budgeted; and under lasers of 2, 4,
8, 16 and 32 times B5's, with the hidden rescale a bit down and at the rule's.
Under a laser the receiver's noise is `--thermalline`, rows / 512 of one
line's light over the multiple and the same in every layer, and the light's
row stays the budget's 30 photons, as in `tighten`. The networks trained
before run beside the reference row for row. That is 110 evaluations and
eight to eleven minutes on five jobs.

The mode checks every network and every run against its place, as `refsource`
does, and a run's laser besides: the noise it was asked for has to be the
multiple its name says, every layer of the line it printed has to be at that
fraction of a line to the Q8.8 it is held in, the hidden rescale has to be a
bit down where its name says and the rule's where it does not, and as
budgeted there is no laser. 70 errors planted one at a time each fail:
44 in a training's line or a run's, after the fact; 17 in the script; and 9 in the
tables' own code, which the check does not see and which each move the
tables.

Of the lines, 25 of the old networks' on each data set are byte for byte what
`tighten` wrote for the same runs, as budgeted and at 4 to 32 times a bit
down, and both kinds' as budgeted are byte for byte what `refsource` wrote.

**What came of it.** Five networks of each kind, mean and standard error.
What a network loses under a laser, less what the same network loses as
budgeted, in points:

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| As budgeted, points lost | 0.15 ± 0.02 | 0.07 ± 0.05 | 0.54 ± 0.22 | 0.47 ± 0.13 | 0.62 ± 0.07 | 0.52 ± 0.05 |
| Over that, the rescale a bit down: 2 times B5's laser | +0.67 ± 0.06 | +0.65 ± 0.10 | +3.53 ± 0.89 | +4.06 ± 0.32 | +4.68 ± 0.82 | +4.23 ± 0.35 |
| 4 times | +0.10 ± 0.05 | +0.18 ± 0.03 | +1.03 ± 0.30 | +1.10 ± 0.13 | +1.14 ± 0.16 | +0.96 ± 0.12 |
| 8 times | −0.04 ± 0.03 | +0.03 ± 0.02 | +0.20 ± 0.14 | +0.09 ± 0.06 | +0.30 ± 0.10 | +0.17 ± 0.07 |
| 16 times | −0.06 ± 0.04 | +0.03 ± 0.02 | +0.01 ± 0.08 | −0.10 ± 0.10 | +0.02 ± 0.08 | −0.02 ± 0.06 |
| 32 times | −0.03 ± 0.04 | +0.02 ± 0.03 | −0.12 ± 0.06 | −0.17 ± 0.08 | +0.01 ± 0.07 | −0.08 ± 0.04 |

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Over its budget, at the rule's rescale: 2 times B5's laser | +2.31 ± 0.16 | +2.72 ± 0.71 | +9.52 ± 2.14 | +11.94 ± 0.52 | +16.78 ± 3.07 | +18.18 ± 1.08 |
| 4 times | +0.45 ± 0.06 | +0.56 ± 0.10 | +3.32 ± 0.87 | +3.92 ± 0.34 | +4.56 ± 0.90 | +4.12 ± 0.36 |
| 8 times | +0.07 ± 0.02 | +0.14 ± 0.02 | +0.91 ± 0.33 | +1.05 ± 0.11 | +1.05 ± 0.19 | +0.86 ± 0.07 |
| 16 times | −0.03 ± 0.03 | +0.07 ± 0.02 | +0.20 ± 0.10 | +0.29 ± 0.05 | +0.27 ± 0.03 | +0.23 ± 0.06 |
| 32 times | −0.05 ± 0.03 | +0.06 ± 0.02 | +0.03 ± 0.11 | +0.08 ± 0.05 | +0.07 ± 0.04 | +0.05 ± 0.04 |

grxcp's rule, read as its `pta_tighten.py` reads it, on means to the
hundredth:

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| The laser it needs, a bit down | 8 times | 8 times | 16 times | 8 times | 16 times | 16 times |
| At the rule's rescale | 8 times | 16 times | 32 times | 32 times | 32 times | 32 times |

**Training with noise does not buy laser.** Under each laser a reference
network is over its own budget by what an old one is over its own. At 4 times,
a bit down, it is 0.18, 1.10 and 0.96 of a point for 0.10, 1.03 and 1.14.
Seed by seed, on the two harder sets, not one of the twenty differences is
clear of chance for five networks, and the largest is 1.3 of its errors
(grxcp's `pta_reference_laser.py` takes them).

**So by the rule one laser of the three is halved, and by a hundredth of a
point.** The reference networks need 8, 8 and 16 times for the old ones' 8,
16 and 16. On Fashion-MNIST at 8 times they are 0.09 ± 0.06 over their budget,
against a tenth. The laser the brightest workload needs is 16 times for both
kinds. And the rule reads to the hundredth: the old networks' 8 on MNIST is
0.096 over at 4 times, which it reads as a tenth and not within one.

**It is not that the noise was the wrong size to have trained for.** The
probe puts the error on the second layer's sums, of their rms and averaged
over five networks (the runs' `e2`), at 7 to 8% as budgeted for both kinds on
all three sets. At 4 times a bit down it is 8% on MNIST, 9% on Fashion-MNIST
and 14% on the inverted set, for both kinds. These networks were trained with
10% on every sum. A network trained with noise the size of what a small laser
puts on its sums loses to that laser what one trained with none does. Why is
not known, and nothing here was run to say.

| | MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|
| The networks trained before, right, percent: 16 times, a bit down | 97.36 | 86.92 | 92.72 |
| The networks trained before, right, percent: 8 times, a bit down | 97.34 | 86.74 | 92.45 |
| 8 times less 16, network by network | −0.02 ± 0.02 | −0.19 ± 0.08 | **−0.28 ± 0.05** |
| The reference networks, right, percent: 16 times, a bit down | 97.65 | 87.51 | 94.88 |
| The reference networks, right, percent: 8 times, a bit down | 97.65 | 87.33 | 94.70 |
| 8 times less 16, network by network | −0.01 ± 0.02 | −0.19 ± 0.08 | **−0.19 ± 0.02** |
| The reference at 8, less the old ones at 16, seed by seed | **+0.29 ± 0.09** | +0.40 ± 0.17 | **+1.97 ± 0.56** |
| Over its budget at 8 times: the reference less the old, seed by seed | +0.07 ± 0.04 | −0.11 ± 0.13 | −0.13 ± 0.13 |

**Half the laser costs a reference network a fifth of a point on the two
harder sets**, 0.19 on each, and at half the laser it is still ahead of an old
network at all of it: by 0.29, 0.40 and 1.97 points. That is what the eight
epochs and the noise bought on the host, carried through. None of it is the
laser's.

**The rescale a bit down still halves the laser at version 2.** At the rule's
rescale the networks trained before need 8, 32 and 32 times and the reference
16, 32 and 32. Only the old networks on MNIST get nothing from the bit.

**What was predicted.** Written before the mode was written out, on
2026-10-07. Four things.

1. That with the rescale a bit down the reference networks would need half
   the laser the old ones do on the two harder sets, 8 times and not 16, and
   on MNIST 4 and not 8. Wrong on two of the three: 8, 8 and 16. Right on
   Fashion-MNIST, by a hundredth of a point.
2. That at 4 times, on the two harder sets, the reference networks would be
   over their budget by 0.2 to 0.5 of a point, where the old ones are over
   theirs by 1.0 and 1.1. Wrong: 1.10 and 0.96.
3. That at the rule's rescale the reference networks would need twice the
   laser they need a bit down. Right on MNIST, 16 for 8, and on the inverted
   set, 32 for 16. On Fashion-MNIST it is four times, 32 for 8, the 8 being
   the one that turns on a hundredth.
4. That in how often they are right the reference networks at 8 times would
   be ahead of the old ones at 16 on all three sets. Right: 0.29, 0.40 and
   1.97, the first and the last outside their errors.

The run was designed to find a smaller laser, and did not find one.

**What this is not.** A laser: the receiver's noise is Gaussian and the
light's row does not move with it, where a real laser moves both. A fine
scale: the multiples are octaves, and "8 times" is somewhere above 4 and no
more than 8. Held: no drift and no source's noise under any laser. v1,
another tile, or the first layer's weights written larger, which `fill` ran
for the networks trained before. And a network trained against a receiver's
noise as the tile makes it, a layer at a time and by the light: these were
trained with one fraction of every sum's rms.

### How long a calibration holds for a trained network

*Added 2026-10-07.* `sim/pta_mnist.sh DIR WORK refdrift`. Reported, not
gated.

**Why.** grxcp calibrates its version 2 every six minutes (its B15). That was
chosen on the networks trained before, for which an hour of TFLT's drift adds
0.67 and 1.99 points on the two harder data sets, and it left unrun the
interval that would hold a tenth of a point on the inverted set, where six
minutes adds 0.28. `refsource` drifted the reference networks for six minutes
and no longer.

**What it runs.** The third mode on the reference networks. At version 2 on
the 128 × 64 tile on two buses, thirteen rows: as budgeted; after 3, 6, 15
and 30 minutes and 1, 2 and 4 hours of TFLT's fitted drift; after an hour of
it and then a calibration; after an hour of TFLN's; and held, with a source's
three rows at 1%, 5% and 5%, at the end of 6 minutes, 30 minutes and an hour.
The networks trained before run beside the reference row for row, which
gives them four intervals `v2` did not. That is 130 evaluations and ten to
eleven minutes on five jobs.

The mode checks every network and every run against its place, as the two
before it do: a run has to have drifted for the hours its name says, by
TFLT's fit unless its name says TFLN's, to have taken steps of drift if it
drifted at all, to have been calibrated only where its name says, and to
have a source's three rows if it is held and none if it is not. 80 errors
planted one at a time each fail: 52 in a training's line or a run's, after the
fact; 19 in the script; and 9 in the tables' own code, which the check does not
see and which each move the tables.

Of the lines, 35 of the old networks' on each data set are byte for byte what
`v2` wrote for the same runs, and the 30 that both kinds share with
`refsource` are byte for byte its.

**What came of it.** Five networks of each kind, mean and standard error.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| As budgeted, points lost | 0.15 ± 0.02 | 0.07 ± 0.05 | 0.54 ± 0.22 | 0.47 ± 0.13 | 0.62 ± 0.07 | 0.52 ± 0.05 |
| What a row adds to that: 3 minutes of TFLT's drift | −0.00 ± 0.03 | +0.03 ± 0.01 | −0.01 ± 0.10 | +0.08 ± 0.04 | +0.14 ± 0.11 | −0.01 ± 0.07 |
| 6 minutes | −0.06 ± 0.04 | +0.01 ± 0.01 | +0.08 ± 0.06 | +0.07 ± 0.09 | +0.28 ± 0.27 | +0.08 ± 0.11 |
| 15 minutes | +0.00 ± 0.03 | +0.07 ± 0.03 | +0.19 ± 0.08 | +0.08 ± 0.04 | +0.33 ± 0.44 | +0.46 ± 0.25 |
| 30 minutes | +0.04 ± 0.03 | +0.11 ± 0.02 | +0.27 ± 0.14 | +0.18 ± 0.08 | +0.54 ± 0.56 | +0.64 ± 0.22 |
| An hour | +0.12 ± 0.05 | +0.07 ± 0.03 | +0.67 ± 0.31 | +0.32 ± 0.09 | +1.99 ± 1.26 | +1.26 ± 0.46 |
| 2 hours | +0.25 ± 0.04 | +0.13 ± 0.04 | +1.41 ± 0.28 | +0.57 ± 0.04 | +5.75 ± 1.75 | +3.30 ± 0.93 |
| 4 hours | +0.37 ± 0.08 | +0.36 ± 0.03 | +2.36 ± 0.57 | +1.31 ± 0.26 | +16.07 ± 3.09 | +7.18 ± 1.53 |
| An hour, then calibrated | −0.06 ± 0.03 | +0.09 ± 0.02 | +0.02 ± 0.11 | +0.13 ± 0.10 | −0.01 ± 0.05 | −0.01 ± 0.05 |
| An hour of TFLN's | +2.35 ± 0.17 | +1.11 ± 0.18 | +7.29 ± 1.50 | +4.23 ± 1.00 | +37.38 ± 5.74 | +25.12 ± 5.09 |
| Held, with a source at 1%, 5%, 5%: 6 minutes | +0.04 ± 0.02 | +0.04 ± 0.03 | +0.06 ± 0.15 | +0.15 ± 0.08 | +0.48 ± 0.29 | +0.24 ± 0.20 |
| 30 minutes | +0.15 ± 0.06 | +0.08 ± 0.04 | +0.39 ± 0.13 | +0.20 ± 0.08 | +0.76 ± 0.67 | +0.87 ± 0.39 |
| An hour | +0.19 ± 0.03 | +0.12 ± 0.03 | +0.82 ± 0.34 | +0.29 ± 0.12 | +2.26 ± 1.34 | +1.53 ± 0.60 |

Seed by seed, with those outside chance at one in twenty for five networks in
bold (grxcp's `pta_reference_drift.py` takes them):

| | MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|
| What drift adds, the reference less the old, seed by seed: 30 minutes | +0.06 ± 0.04 | −0.09 ± 0.12 | +0.10 ± 0.45 |
| What drift adds, the reference less the old, seed by seed: an hour | −0.06 ± 0.08 | −0.35 ± 0.23 | −0.74 ± 0.90 |
| What drift adds, the reference less the old, seed by seed: 2 hours | −0.11 ± 0.05 | **−0.83 ± 0.25** | −2.45 ± 1.46 |
| What drift adds, the reference less the old, seed by seed: 4 hours | −0.02 ± 0.08 | −1.05 ± 0.77 | −8.89 ± 3.63 |
| What drift adds, the reference less the old, seed by seed: an hour of TFLN's | **−1.24 ± 0.30** | **−3.06 ± 0.79** | **−12.26 ± 4.30** |
| An hour, then calibrated: the reference less the old | **+0.15 ± 0.05** | +0.10 ± 0.12 | +0.00 ± 0.07 |

**Under heavy drift a reference network loses half to two thirds of what an
old one does.** An hour of TFLN's adds 1.11, 4.23 and 25.12 points for 2.35,
7.29 and 37.38, and that is clear on all three sets. Of TFLT's, two hours on
Fashion-MNIST is clear, 0.57 for 1.41. An hour of it is 0.32 for 0.67 and
1.26 for 1.99 and is not clear, and four hours on the inverted set is 7.18
for 16.07 at two and a half errors. The section before this one found that
the same networks buy nothing back of a laser. They do of drift, where there
is a lot of it.

**At half an hour and under nothing can be told between them.** None of the
twelve differences is clear. On the inverted set the reference networks are
no better at a quarter of an hour, 0.46 for 0.33, or at half, 0.64 for 0.54.

**At six minutes the reference networks are inside a tenth of a point on all
three sets, in the mean.** 0.01, 0.07 and 0.08, where the old ones are at
−0.06, 0.08 and 0.28. Two of those three have errors their own size. For the
old networks on the inverted set three minutes adds 0.14 ± 0.11: no interval
that was run holds a tenth there.

**A calibration does not quite return a reference network to where it
started.** After an hour of drift and a calibration the old networks are
−0.06, 0.02 and −0.01 of a point from their budget, and the reference
networks 0.09, 0.13 and −0.01. MNIST's 0.09 ± 0.02 is clear and is nine
images in ten thousand; on that set a calibrated reference network is no
better off than one left to drift for the hour, 0.09 for 0.07. Fashion-MNIST's
0.13 ± 0.10 is not clear. Why is not known. And every drift row in this note
starts from weights as they were written, not from a calibration, so what a
calibrated and then drifted tile costs has not been run for either kind:
`eval --post-hours` is there for it. *Corrected 2026-10-08: it does return
it. A calibrated row and the row as budgeted do not meet the same draws of
noise, and this tenth of a point was the draws: the last section of this
one.*

| | MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|
| The reference networks held, right, percent: 6 minutes | 97.64 | 87.27 | 94.63 |
| The reference networks held, right, percent: 30 minutes | 97.61 | 87.21 | 93.99 |
| The reference networks held, right, percent: an hour | 97.57 | 87.12 | 93.33 |
| The networks trained before held, 6 minutes | 97.26 | 86.88 | 92.27 |
| The reference at an hour, less the old at 6 minutes, seed by seed | +0.31 ± 0.12 | +0.24 ± 0.13 | +1.06 ± 1.04 |

**Held at the end of an hour, a reference network is level with an old one
held at the end of six minutes, or ahead of it.** 0.31, 0.24 and 1.06 points
ahead in the mean, and clear on none of the three. Against itself at six
minutes it gives up 0.07, 0.15 and 1.30.

**What was predicted.** Written before the mode was written out, on
2026-10-07. Five things.

1. That an hour of drift would add less to the reference networks' budget
   than to the old ones' on the inverted set: 0.5 to 1.0 of a point, for 1.99.
   Less, yes, at 1.26, which is outside what was said; and seed by seed the
   difference is not clear.
2. That on Fashion-MNIST an hour would add 0.3 to 0.6, for 0.67, and on MNIST
   under a tenth, for 0.12. Right: 0.32 and 0.07.
3. That a calibration after an hour would return the reference networks to
   their budget, within a tenth on all three sets. Wrong on Fashion-MNIST,
   0.13, and right by a hundredth on MNIST, 0.09. What it missed is the
   finding above.
4. That on the inverted set the reference networks would be over their
   budget by 0.1 to 0.3 at a quarter of an hour and 0.2 to 0.6 at half. Wrong
   twice: 0.46 and 0.64.
5. That in how often they are right the reference networks held at the end
   of an hour would be ahead of the old ones held at the end of six minutes
   on all three sets. Right in the mean, and clear on none.

**What this is not.** A ring's drift: both fits are a Mach-Zehnder's bias,
every cell drifts on its own, and none drift together. An interval between
the seven that were run. A network trained against a drifted weight: these
were trained with Gaussian noise on their sums. The predictive and shadow
schedulers, v1, or another tile. And an interval that starts from a
calibration, as every interval on a tile does.

### An interval that starts from a calibration

*Added 2026-10-07.* `sim/pta_mnist.sh DIR WORK refcycle`. Reported, not
gated.

**Corrected 2026-10-08, by the section after this one.** A calibrated row
here and a row that is not do not meet the same draws of noise: a
calibration's probes are GEMMs, and every GEMM of a run takes the next seed.
So each figure below that sets one against the other is the draws as well as
what it names. That is a calibration's cost, a cycle over the row as
budgeted, a cycle against weights as written, and held against held. What
this section reads as the calibration's own cost was the draws. Its figures
stand, and so does what it reads between two calibrated rows.

**Why.** Every drift row in this note aged a tile from weights as they were
written. A tile in use is never that. It is calibrated, drifts for an
interval and is calibrated again, so what grxcp's six minutes end in is a
calibrated tile and six minutes of drift. The section before this one found
the reference networks 0.09 and 0.13 of a point short of their budget after
an hour of drift and a calibration, and could not say whether that was the
calibration or the hour.

**What it runs.** The fourth mode on the reference networks. At version 2 on
the 128 × 64 tile on two buses, with TFLT's fitted drift, nineteen rows: as
budgeted; calibrated as written, with no drift at all; aged six minutes and
an hour and then calibrated; a cycle, which is a tile aged an interval,
calibrated, and aged the interval again, at 3, 6, 15 and 30 minutes and an
hour; aged an hour, calibrated, and six minutes more; aged from weights as
written for 6 and 30 minutes and an hour; and held, with a source's three
rows at 1%, 5% and 5%, at the end of each of those three intervals from
weights as written and as a cycle. A cycle is `eval --hours H --calibrate 16
--post-hours H`. The calibration is C3's as `eval` has had it: 16 probes a
cell, three passes, a trim step of a quarter of a weight's LSB, and taken
before the light is set up, so that it sees no source. The networks trained
before run beside the reference row for row. That is 190 evaluations, and
19 to 45 minutes a data set on five jobs: a calibrated run is slower.

The mode checks every network and every run against its place, as the three
before it do: a run has to have drifted for the hours its name says before
its calibration and after it, by TFLT's fit, to have taken steps of drift if
it drifted at all, to have been calibrated with 16 probes where its name
says calibrated or a cycle and not at all elsewhere, and to have a source's
three rows if it is held and none if it is not. 94 errors planted one at
a time each fail: 63 in a training's line or a run's, after the fact; 22 in the
script; and 9 in the tables' own code, which the check does not see and which
each move the tables.

Of the lines, 80 on each data set, eight rows of both kinds, are byte for byte
what `refdrift` wrote for the same runs.

**What came of it.** Five networks of each kind, mean and standard error.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| As budgeted, points lost | 0.15 ± 0.02 | 0.07 ± 0.05 | 0.54 ± 0.22 | 0.47 ± 0.13 | 0.62 ± 0.07 | 0.52 ± 0.05 |
| What a row adds to that: calibrated as written, no drift | −0.05 ± 0.04 | +0.08 ± 0.01 | +0.03 ± 0.11 | +0.15 ± 0.12 | +0.06 ± 0.06 | −0.05 ± 0.04 |
| Aged 6 minutes, then calibrated | −0.04 ± 0.05 | +0.09 ± 0.01 | +0.02 ± 0.08 | +0.13 ± 0.13 | +0.14 ± 0.07 | +0.00 ± 0.06 |
| Aged an hour, then calibrated | −0.06 ± 0.03 | +0.09 ± 0.02 | +0.02 ± 0.11 | +0.13 ± 0.10 | −0.01 ± 0.05 | −0.01 ± 0.05 |
| A cycle of 3 minutes | −0.04 ± 0.04 | +0.07 ± 0.03 | +0.06 ± 0.07 | +0.14 ± 0.10 | +0.34 ± 0.33 | +0.02 ± 0.07 |
| A cycle of 6 minutes | −0.05 ± 0.04 | +0.08 ± 0.04 | +0.16 ± 0.06 | +0.16 ± 0.08 | +0.14 ± 0.25 | +0.09 ± 0.08 |
| A cycle of 15 minutes | −0.02 ± 0.06 | +0.08 ± 0.04 | +0.10 ± 0.22 | +0.23 ± 0.12 | +0.14 ± 0.32 | +0.25 ± 0.10 |
| A cycle of 30 minutes | −0.01 ± 0.05 | +0.14 ± 0.02 | +0.37 ± 0.12 | +0.05 ± 0.10 | +0.98 ± 0.64 | +0.45 ± 0.27 |
| A cycle of an hour | +0.08 ± 0.08 | +0.14 ± 0.04 | +0.50 ± 0.18 | +0.38 ± 0.12 | +2.34 ± 0.21 | +1.58 ± 0.39 |
| Aged an hour, calibrated, 6 minutes more | −0.04 ± 0.06 | +0.09 ± 0.02 | −0.04 ± 0.12 | +0.10 ± 0.13 | +0.35 ± 0.24 | +0.28 ± 0.10 |
| From weights as written: 6 minutes | −0.06 ± 0.04 | +0.01 ± 0.01 | +0.08 ± 0.06 | +0.07 ± 0.09 | +0.28 ± 0.27 | +0.08 ± 0.11 |
| 30 minutes | +0.04 ± 0.03 | +0.11 ± 0.02 | +0.27 ± 0.14 | +0.18 ± 0.08 | +0.54 ± 0.56 | +0.64 ± 0.22 |
| An hour | +0.12 ± 0.05 | +0.07 ± 0.03 | +0.67 ± 0.31 | +0.32 ± 0.09 | +1.99 ± 1.26 | +1.26 ± 0.46 |
| Held, from weights as written: 6 minutes | +0.04 ± 0.02 | +0.04 ± 0.03 | +0.06 ± 0.15 | +0.15 ± 0.08 | +0.48 ± 0.29 | +0.24 ± 0.20 |
| 30 minutes | +0.15 ± 0.06 | +0.08 ± 0.04 | +0.39 ± 0.13 | +0.20 ± 0.08 | +0.76 ± 0.67 | +0.87 ± 0.39 |
| An hour | +0.19 ± 0.03 | +0.12 ± 0.03 | +0.82 ± 0.34 | +0.29 ± 0.12 | +2.26 ± 1.34 | +1.53 ± 0.60 |
| Held, at the end of a cycle: 6 minutes | +0.02 ± 0.03 | +0.11 ± 0.06 | +0.12 ± 0.11 | +0.11 ± 0.10 | +0.29 ± 0.31 | +0.28 ± 0.21 |
| 30 minutes | +0.07 ± 0.04 | +0.12 ± 0.04 | +0.48 ± 0.19 | +0.25 ± 0.09 | +1.30 ± 0.66 | +0.61 ± 0.24 |
| An hour | +0.14 ± 0.08 | +0.17 ± 0.04 | +0.55 ± 0.18 | +0.33 ± 0.13 | +2.39 ± 0.28 | +1.87 ± 0.38 |

Seed by seed, with those outside chance at one in twenty for five networks in
bold (grxcp's `pta_reference_cycle.py` takes them):

| | MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|
| Calibrated as written: the reference less the old | **+0.13 ± 0.04** | +0.12 ± 0.15 | −0.11 ± 0.06 |
| What an hour of drift first adds to a calibration, the reference | +0.01 ± 0.01 | −0.02 ± 0.04 | +0.04 ± 0.02 |
| and the old networks | −0.01 ± 0.02 | −0.01 ± 0.04 | **−0.07 ± 0.02** |
| A 6-minute cycle less the calibrated tile, the reference | +0.00 ± 0.04 | +0.02 ± 0.04 | +0.14 ± 0.09 |
| A cycle less the same interval from weights as written, the reference: 6 minutes | +0.08 ± 0.04 | +0.09 ± 0.10 | +0.02 ± 0.04 |
| A cycle less the same interval from weights as written, the reference: 30 minutes | +0.04 ± 0.04 | −0.13 ± 0.10 | −0.19 ± 0.28 |
| A cycle less the same interval from weights as written, the reference: an hour | +0.07 ± 0.04 | +0.06 ± 0.12 | +0.33 ± 0.68 |
| and the old networks: 6 minutes | +0.02 ± 0.01 | +0.08 ± 0.04 | −0.14 ± 0.16 |
| and the old networks: 30 minutes | −0.06 ± 0.05 | +0.10 ± 0.14 | +0.44 ± 0.69 |
| and the old networks: an hour | −0.05 ± 0.10 | −0.17 ± 0.27 | +0.34 ± 1.28 |
| An hour, calibrated, 6 minutes more, less the 6-minute cycle: the reference | +0.01 ± 0.03 | −0.06 ± 0.08 | +0.18 ± 0.10 |
| and the old networks | +0.01 ± 0.04 | −0.20 ± 0.10 | +0.21 ± 0.29 |

~~**The shortfall is the calibration's own, and not the hour's.**~~ *Not the
hour's, and not the calibration's: the draws'.* A tile
calibrated as it was written, with no drift at all, costs the reference
networks 0.08 ± 0.01 of a point on MNIST, 0.15 ± 0.12 on Fashion-MNIST and
−0.05 ± 0.04 on the inverted set, and the old networks −0.05, 0.03 and 0.06.
MNIST's is clear: each of the five networks loses, 5 to 11 images in ten
thousand. An hour of drift before the calibration adds 0.01 ± 0.01, −0.02 ±
0.04 and 0.04 ± 0.02 to that for the reference networks. One of the twelve
such figures is clear, the old networks' on the inverted set after an hour,
and it is a gain; one in twelve is what chance gives.

**On MNIST it is not that the calibrated tile's sums are further off.** *Nor
is the tile any worse: the next section.* The probe, in the same runs:

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| The first layer's sums, off by, % of their rms (`e1`): as budgeted | 7.12 | 6.18 | 6.75 | 6.86 | 7.99 | 4.62 |
| calibrated | 7.17 | 6.22 | 6.85 | 6.92 | 8.45 | 4.78 |
| The second's (`e2`): as budgeted | 7.10 | 7.36 | 7.37 | 7.94 | 6.81 | 7.11 |
| calibrated | 7.12 | 7.38 | 7.37 | 7.92 | 6.90 | 7.18 |
| Right, as the probe predicts from the error, % (`pred_res`): as budgeted | 97.27 | 97.56 | 86.46 | 86.95 | 92.59 | 94.83 |
| calibrated | 97.28 | 97.56 | 86.47 | 86.94 | 92.58 | 94.85 |
| Right, as run, %: as budgeted | 97.30 | 97.68 | 86.94 | 87.41 | 92.74 | 94.86 |
| calibrated | 97.35 | 97.60 | 86.91 | 87.27 | 92.68 | 94.91 |

On MNIST the reference networks' first layer is off by 6.18% of its sums'
rms as budgeted and 6.22% calibrated, the second by 7.36% and 7.38%, and the
accuracy the probe predicts from that error is 97.56% for both. As run they
are right 97.68% of the time as budgeted and 97.60% calibrated. What a
calibration leaves in a cell stays there until the next calibration, where a
programming error is drawn again at every weight write: that is a difference
between the two tiles that a sum's rms does not see. Whether it is the cause
is not known, and nothing here was run to say. On the inverted set the first
layer's sums are 4 to 6% further off calibrated, and there a calibration
costs neither kind anything that is clear.

**At the end of a six-minute cycle the reference networks are 0.08, 0.16 and
0.09 over their budget.** *Over the row as budgeted, which is the draws as
well. Over the tile as budgeted on the cycle's own draws it is 0.02, 0.02 and
0.11: the next section.* From weights as written six minutes left them 0.01,
0.07 and 0.08 over. None of the three is clear. Against the calibrated tile
the six minutes add 0.00 ± 0.04, 0.02 ± 0.04 and 0.14 ± 0.09: on MNIST and
Fashion-MNIST what the cycle ends over by is the calibration's, and on the
inverted set it is the interval's. A three-minute cycle ends 0.07, 0.14 and
0.02 over, so a shorter interval buys none of the calibration's back.

**A cycle ends where the same interval from weights as written does, to what
five networks tell.** None of the eighteen differences is clear. So the
drift rows of the sections before this one stand as the ends of intervals.
On MNIST the reference networks' three are all over, by 0.04 to 0.08.

**Two draws of the same six minutes are as much as two tenths apart.** In
this model a cell's drift is a random walk, and what it walked before a
calibration does not enter what it walks after. So a tile aged an hour,
calibrated and aged six minutes more is another draw of the six-minute
cycle's end. They differ by 0.01 on MNIST for both kinds, and by −0.20 and
0.21 for the old networks and −0.06 and 0.18 for the reference on the other
two sets, none of it clear. On the inverted set the reference networks' six
minutes is now drawn three times: 0.08 ± 0.11 from weights as written, 0.09 ±
0.08 at the end of the cycle, and 0.28 ± 0.10 after the hour's calibration.

| | MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|
| The reference networks held at the end of a cycle, right, percent: 6 minutes | 97.57 | 87.30 | 94.58 |
| The reference networks held at the end of a cycle, right, percent: 30 minutes | 97.56 | 87.16 | 94.25 |
| The reference networks held at the end of a cycle, right, percent: an hour | 97.51 | 87.09 | 92.99 |
| The same held from weights as written, 6 minutes | 97.64 | 87.27 | 94.63 |
| The cycle less that, seed by seed | +0.06 ± 0.05 | −0.03 ± 0.11 | +0.05 ± 0.02 |
| The networks trained before, held at the end of a 6-minute cycle | 97.28 | 86.82 | 92.46 |
| The reference less those, seed by seed | +0.30 ± 0.12 | **+0.48 ± 0.15** | **+2.12 ± 0.72** |

**Held at the end of a six-minute cycle the reference networks are where
they were held from weights as written.** Within 0.07 of a point on all
three sets, and none of the differences clear. They are 0.30, 0.48 and 2.12
points ahead of the old networks held the same way, and ahead of them in the
mean in every one of the nineteen rows on every set.

**What was predicted.** Written before the mode was written out, on
2026-10-07. Five things.

1. That the shortfall is the calibration's own: that a tile calibrated as
   written would leave the reference networks 0.05 to 0.13 short on MNIST
   and 0.05 to 0.20 on Fashion-MNIST, and within 0.05 on the inverted set,
   and the old networks within 0.07 on all three. Right: 0.08, 0.15 and
   −0.05, the last at its edge, and −0.05, 0.03 and 0.06.
2. That a six-minute cycle would end 0.08 to 0.14 over on MNIST, 0.15 to
   0.25 on Fashion-MNIST and 0.00 to 0.15 on the inverted set for the
   reference networks, and so over a tenth on Fashion-MNIST. Right in the
   mean, 0.08, 0.16 and 0.09, and Fashion-MNIST's is not clear of a tenth.
3. That a three-minute cycle would be within 0.05 of a six-minute one on
   MNIST and Fashion-MNIST. Right: 0.07 for 0.08 and 0.14 for 0.16.
4. That what a tile was before its calibration would not matter: an hour,
   a calibration and six minutes within a tenth of the six-minute cycle on
   all three sets for both kinds. Wrong in three cells of six, by 0.18 to
   0.21, and clear in none. What it missed is how far apart two draws are.
5. That held at the end of a six-minute cycle the reference networks would
   be ahead of the old ones by at least 0.2, 0.2 and 1.5 points. Right:
   0.30, 0.48 and 2.12.

**What this is not.** A schedule: it is one calibration, where a tile in use
has had hundreds, and nothing here says the shortfall does or does not
build. Another calibration: more probes, a finer trim, or one taken with the
light lit. The cause of what a calibration costs a trained network. A ring's
drift: the fit is a Mach-Zehnder's bias and every cell drifts on its own.
The predictive and shadow schedulers, v1, or another tile.

### What a calibration costs: its trims, and its draws

*Added 2026-10-08.* `sim/pta_mnist.sh DIR WORK refcal`. Reported, not gated.

**Why.** The section before this one found that a tile calibrated as it was
written, with no drift at all, costs the reference networks 0.08 ± 0.01 of a
point on MNIST, and read that as the calibration's own cost. grxcp asked what
in the calibration it was, before making it a row of its budget. Reading
`eval` for that turned up a second difference between the two runs.

A calibrated run writes trims. With no drift a cell's trim is minus the mean
of the programming errors its last pass of probes happened to meet, rounded
to the trim's step: about a quarter of an LSB at 16 probes, where the
programming error it averaged is one LSB and is drawn again at every weight
load. It is nothing the cell will meet again.

And a calibrated run meets other draws. Each probe is six GEMMs, three
passes on each of two banks, and every GEMM of a run takes the run's next
seed. So the first batch of images in a run calibrated with 16 probes meets
the noise and the programming errors of the 97th GEMM, where the run as
budgeted meets the first's. The two rows the section before compared differ
in both, and it took them for one.

**What it runs.** The fifth mode on the reference networks. Version 2 on the
128 × 64 tile with no drift anywhere, twenty-two rows: as budgeted;
calibrated with 1, 4, 16 and 64 probes a cell; *probes only* at each of
those, which is `eval --calibrate N --trimmax 0`, the probes taken and a trim
that can hold nothing written, and so the calibrated run's draws on the tile
as budgeted; 16 probes at a trim step of a sixteenth and of a 256th of a
weight's LSB, and 64 at a 256th; and other draws, the tile seeded with the
network's seed and 10 D more, as budgeted on six of them and calibrated and
probes only, at 16 probes, on the first two. A calibrated row less its
probes-only row is the trims and nothing else. And the tile as budgeted on
twelve other draws, the six other seeds and the six probes-only rows, says
how far a network moves when nothing changes but its draw. The networks
trained before run beside the reference row for row. That is 220
evaluations, and 23 to 50 minutes a data set on five jobs with other runs
beside them.

The mode checks every network and every run against its place, as the four
before it do: a run's name says whether it was calibrated, with how many
probes, whether its trims were written, at what trim step and on which draw,
and those have to be what it was asked and what its line printed; nothing in
it drifts, and no source is lit. 109 errors planted one at a time each fail:
64 in a training's line or a run's, after the fact; 24 in the script; and 21
in the tables' own code, which the check does not see and which each move the
tables. The planted-error runs calibrate with 16, 1 and 2 probes, since a
calibration takes as long on 200 images as on ten thousand: the rows are the
same code with other numbers in their names.

Of the lines, 20 on each data set, the row as budgeted and the one calibrated
with 16 probes for both kinds, are byte for byte what `refcycle` wrote.

**What came of it.** Five networks of each kind, mean and standard error,
with those outside chance at one in twenty for five networks in bold. First
what the trims add: how often right with the same probes taken and nothing
written, less right calibrated, network by network. The two runs meet the
same draws.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Calibrated with 1 probe a cell | −0.03 ± 0.03 | +0.01 ± 0.04 | +0.18 ± 0.09 | +0.15 ± 0.13 | +0.70 ± 0.58 | +0.24 ± 0.19 |
| 4 probes | −0.03 ± 0.02 | +0.01 ± 0.02 | +0.12 ± 0.05 | −0.09 ± 0.05 | +0.06 ± 0.14 | +0.02 ± 0.05 |
| 16 probes | +0.02 ± 0.02 | +0.02 ± 0.02 | +0.06 ± 0.02 | +0.01 ± 0.05 | −0.05 ± 0.06 | −0.03 ± 0.05 |
| 64 probes | +0.00 ± 0.02 | +0.00 ± 0.01 | −0.02 ± 0.03 | −0.04 ± 0.04 | +0.05 ± 0.06 | +0.01 ± 0.02 |
| 16 probes, a trim step of 1/16 LSB | +0.02 ± 0.02 | +0.01 ± 0.02 | +0.01 ± 0.03 | +0.02 ± 0.04 | −0.04 ± 0.04 | +0.00 ± 0.06 |
| 16 probes, 1/256 | +0.01 ± 0.02 | +0.01 ± 0.01 | +0.00 ± 0.02 | +0.00 ± 0.04 | −0.03 ± 0.04 | −0.01 ± 0.06 |
| 64 probes, 1/256 | +0.01 ± 0.02 | +0.01 ± 0.02 | −0.02 ± 0.03 | −0.02 ± 0.05 | +0.08 ± 0.03 | +0.03 ± 0.02 |
| 16 probes, on draw 1 | −0.01 ± 0.02 | −0.04 ± 0.03 | +0.02 ± 0.08 | +0.01 ± 0.04 | +0.06 ± 0.05 | +0.06 ± 0.03 |
| 16 probes, on draw 2 | +0.01 ± 0.03 | −0.02 ± 0.02 | **+0.06 ± 0.02** | −0.02 ± 0.04 | +0.05 ± 0.12 | +0.01 ± 0.02 |
| 16 probes, a network's mean over the three draws | +0.01 ± 0.01 | −0.01 ± 0.01 | +0.05 ± 0.03 | +0.00 ± 0.03 | +0.02 ± 0.04 | +0.01 ± 0.03 |

**It is not the trims.** At 16 probes they add 0.02 ± 0.02, 0.01 ± 0.05 and
−0.03 ± 0.05 to what the reference networks lose, and over the three draws
that were calibrated on −0.01 ± 0.01, 0.00 ± 0.03 and 0.01 ± 0.03, with 0.01,
0.05 and 0.02 for the old networks. More probes and a finer trim change
nothing that can be seen. With one probe a cell the trim a cell is left with
is as large as its programming error, and the trims add 0.01, 0.15 and 0.24
to the reference networks and −0.03, 0.18 and 0.70 to the old ones: more on
the harder sets, and clear on none. Of the 54 differences in this table one
is outside chance at one in twenty, the old networks' on Fashion-MNIST's
second draw at 0.06 ± 0.02, where chance gives 2.7.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Calibrated with 16 probes, less as budgeted | −0.05 ± 0.04 | **+0.08 ± 0.01** | +0.03 ± 0.11 | +0.15 ± 0.12 | +0.06 ± 0.06 | −0.05 ± 0.04 |
| The same probes and nothing written, less as budgeted: the draws | −0.07 ± 0.05 | **+0.07 ± 0.02** | −0.03 ± 0.12 | +0.14 ± 0.09 | +0.11 ± 0.05 | −0.02 ± 0.08 |
| The first less the second: the trims | +0.02 ± 0.02 | +0.02 ± 0.02 | +0.06 ± 0.02 | +0.01 ± 0.05 | −0.05 ± 0.06 | −0.03 ± 0.05 |

**It was the draws.** For the reference networks the same probes with
nothing written are 0.07 ± 0.02, 0.14 ± 0.09 and −0.02 ± 0.08 short of the row
as budgeted, which is nearly all of what the calibrated row is. MNIST's is
3.8 of its errors: outside chance by the test, and chance all the same, as
the next table and the check after it show.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Right on the twelve other draws, percent | 97.32 | 97.60 | 86.97 | 87.34 | 92.63 | 94.90 |
| The row as budgeted, less a network's mean over them | −0.014 ± 0.042 | **+0.078 ± 0.027** | −0.037 ± 0.116 | +0.072 ± 0.078 | +0.115 ± 0.048 | −0.042 ± 0.047 |
| A network's standard deviation from draw to draw | 0.063 | 0.051 | 0.145 | 0.135 | 0.094 | 0.107 |
| The five networks' mean's | 0.036 | 0.023 | 0.071 | 0.057 | 0.057 | 0.036 |
| Points lost to the tile: the row as budgeted | 0.15 ± 0.02 | 0.07 ± 0.05 | 0.54 ± 0.22 | 0.47 ± 0.13 | 0.62 ± 0.07 | 0.52 ± 0.05 |
| over all thirteen draws | 0.14 ± 0.04 | 0.14 ± 0.03 | 0.51 ± 0.12 | 0.54 ± 0.07 | 0.72 ± 0.11 | 0.48 ± 0.06 |

**A row moves when nothing changes but its draw.** A network's accuracy on
the tile as budgeted has a standard deviation from draw to draw of 0.05 to
0.14 of a point, and the five networks' mean of 0.02 to 0.07. Two rows that
do not share their draws differ by 0.03, 0.08 and 0.05 for the reference
networks at one standard deviation, with nothing else changed. In every mode
of this note a calibrated row and a row that is not are two such rows. Rows
that are both calibrated with as many probes share theirs, and so do rows
that are both not: drift and a source have streams of their own, and a
laser's size scales the ones there are.

**The row as budgeted is one draw, and on MNIST a favourable one for the
reference networks.** It is 0.08 ± 0.03 above their mean over the twelve
other draws, 2.9 of its errors, and the calibrated run's draws are one of the
twelve: that is where the 0.08 of the section before this one came from.
Over all thirteen draws the reference
networks lose 0.14, 0.54 and 0.48 of a point to the tile, and the networks
trained before 0.14, 0.51 and 0.72. Seed by seed that difference is 0.01 ±
0.04, 0.03 ± 0.10 and −0.24 ± 0.13: on MNIST and Fashion-MNIST a network
trained for the tile loses to the tile as budgeted what one that was not
does.

A tile's seed in the row as budgeted is the seed its network was trained
with, and in the other draws it is not. Nothing in the trainer or the model
ties the two: the trainer's noise is its own generator's and the tile's
streams are seeded from the run's seed and a GEMM's index. But 2.9 errors
asked for a check, and it was made by hand: five networks of each kind that
no sweep had run, seeds 6 to 10, trained as `train_one` and `train_ref` train
them, on MNIST, each on the tile as budgeted at its own seed and at six
others.

| | The tile at the network's own seed | At six other seeds, mean | The first less the second, network by network |
|---|---|---|---|
| Five new networks trained as the reference are, seeds 6 to 10 | 97.57 | 97.55 | +0.02 ± 0.03 |
| Five trained as the old ones are | 97.23 | 97.28 | −0.05 ± 0.04 |

It is not there. The five networks of the sweeps had a favourable draw.

**The cycle's rows again, each over the tile as budgeted on its own draws.**
`refcycle`'s calibrated rows all calibrate with 16 probes, so the row here
that took 16 probes and wrote nothing is the tile as budgeted on their draws.
What each adds to it, in place of what it adds to the row as budgeted:

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Calibrated as written | +0.02 ± 0.02 | +0.02 ± 0.02 | +0.06 ± 0.02 | +0.01 ± 0.05 | −0.05 ± 0.06 | −0.03 ± 0.05 |
| Aged 6 minutes, then calibrated | +0.03 ± 0.02 | +0.02 ± 0.01 | +0.05 ± 0.04 | −0.01 ± 0.06 | +0.03 ± 0.05 | +0.01 ± 0.05 |
| Aged an hour, then calibrated | +0.01 ± 0.02 | +0.02 ± 0.02 | +0.06 ± 0.02 | −0.01 ± 0.02 | −0.12 ± 0.04 | +0.01 ± 0.05 |
| A cycle of 3 minutes | +0.03 ± 0.02 | +0.00 ± 0.03 | +0.09 ± 0.10 | +0.00 ± 0.03 | +0.23 ± 0.31 | +0.04 ± 0.04 |
| A cycle of 6 minutes | +0.02 ± 0.03 | +0.02 ± 0.04 | +0.19 ± 0.07 | +0.02 ± 0.02 | +0.03 ± 0.21 | +0.11 ± 0.09 |
| A cycle of 15 minutes | +0.05 ± 0.04 | +0.01 ± 0.05 | +0.14 ± 0.14 | +0.09 ± 0.07 | +0.04 ± 0.34 | **+0.26 ± 0.07** |
| A cycle of 30 minutes | **+0.06 ± 0.01** | **+0.08 ± 0.02** | **+0.41 ± 0.08** | −0.09 ± 0.06 | +0.87 ± 0.63 | +0.47 ± 0.27 |
| A cycle of an hour | +0.14 ± 0.06 | +0.07 ± 0.04 | **+0.54 ± 0.17** | +0.24 ± 0.09 | **+2.23 ± 0.24** | **+1.60 ± 0.42** |
| Aged an hour, calibrated, 6 minutes more | +0.03 ± 0.02 | +0.03 ± 0.02 | +0.00 ± 0.05 | −0.04 ± 0.09 | +0.24 ± 0.25 | **+0.30 ± 0.09** |

At the end of a six-minute cycle the reference networks are 0.02 ± 0.04, 0.02
± 0.02 and 0.11 ± 0.09 over, where the section before had 0.08, 0.16 and 0.09.
Fashion-MNIST, where no interval that was run ended within a tenth, is
within one at 3, 6, 15 and 30 minutes. On the inverted set a three-minute
cycle ends 0.04 over and a six-minute one 0.11. That set's six minutes for
the reference networks is now drawn three times, each over its own draws:
0.08 ± 0.11 from weights as written, 0.11 ± 0.09 at the end of the cycle, and
0.30 ± 0.09 after an hour and a calibration. For the old networks on
Fashion-MNIST a six-minute cycle ends 0.19 ± 0.07 over.

**What was wrong in the section before this one, and what was not.** The test
was not wrong about the 0.08. One in twenty is wrong once in twenty, and this
note has read some hundreds of such differences; one of them at 2.9 errors is
not a surprise. What was wrong was to read the calibrated rows of `refcycle`,
which share their draws, as so many findings of the same cost. That section's
figures stand. So does what it reads between two calibrated rows: an
interval's own, what came before a calibration, what holding adds. And its
probe was right, that the calibrated tile's sums are no further off.

**What was predicted.** Written before anything was run for this, on
2026-10-07. Five things, and a sixth before the check by hand.

1. That it is not the trims: that the probes taken and nothing written would
   leave the reference networks 0.05 to 0.11 short on MNIST, and the trims
   themselves add within 0.03 there and within 0.08 on the other two sets.
   Right: 0.07, and 0.02, 0.01 and −0.03.
2. That more probes would not buy it back: the trims within 0.05 on MNIST at
   4, 64 and 256 probes, and at one probe adding 0.00 to 0.10 on MNIST and
   0.05 to 0.60 on the inverted set. Right where it was run, 0.01 and 0.00 and,
   at one probe, 0.01 and 0.24; 256 probes were not run.
3. That a finer trim step would do nothing, within 0.03 on MNIST. Right.
4. That the row as budgeted is a favourable draw for the reference networks
   on MNIST, by 0.02 to 0.09 over the other draws. Right: 0.08.
5. That for the networks trained before the trims at 16 probes are within
   0.06 on MNIST, and nothing they show on any set is clear. Right on the
   first, 0.02. On the second, one of their 27 differences is clear.
6. That it was chance: that for five new reference networks the tile at
   their own seed would be within 0.05 of their mean over six others, and
   not 0.08 above. Right: 0.02 ± 0.03.

**What this is not.** A calibration with something to correct: nothing here
drifts, and what a calibration is worth when there is drift to take out is
`refcycle`'s rows, as the last table has them. Another calibration than C3's
as `eval` has it. The held rows, with a source's rows lit: those are one
draw each as well, and were not run on others. The check by hand is MNIST
only, and not a mode. Version 1, or another tile.

### The working point over draws

*Added 2026-10-08.* `sim/pta_mnist.sh DIR WORK refdraws`. Reported, not gated.

**Why.** The section before this one found that a row moves when nothing
changes but its draw, and that every row of this note before it is one draw.
It left two things on one draw each. A six-minute cycle on the inverted set
for the reference networks, which is what sizes grxcp's B15, had been drawn
three times, at 0.08, 0.11 and 0.30 of a point over the tile as budgeted, and
a tenth was not pinned between them. And the rows grxcp quotes for the chip
as it is held, with six minutes of drift and a source's rows, were one draw.
grxcp asked for the first to be pinned before it decided anything, and the
second folded in.

**What it runs.** The sixth mode on the reference networks. Version 2 on the
128 × 64 tile on two buses, five rows on each of ten draws: as budgeted;
held, which is six minutes of TFLT's drift from weights as written and a
source's three rows at 1%, 5% and 5%; probes only, a calibration's 16 probes
taken and nothing written; and a cycle, aged an interval, calibrated and aged
it again, of three minutes and of six. Draw D seeds the tile with the
network's seed and 10 D more, which moves its noise, its drift's walk and its
source; draw 0 is the one every mode before this ran. A cycle is read over
the probes-only row of its draw, and the held row and the probes-only one
over the as-budgeted row of their draw: each pair meets the same noise. The
networks trained before run beside the reference row for row. That is 500
evaluations a data set, and 2.9 hours for the three side by side on four jobs
each.

The mode checks every network and every run against its place, as the five
before it do: a run's name says its draw, whether it drifted and for how long
before a calibration and after, whether its probes were taken and its trims
written, and whether a source is lit, and those have to be what it was asked
and what its line printed. 111 errors planted one at a time each fail:
69 in a training's line or a run's, after the fact; 24 in the script; and 18
in the tables' own code, which the check does not see and which each move the
tables. The planted-error runs take two draws and not ten.

Of the lines, 130 on each data set are byte for byte what `refcal` and
`refcycle` wrote for the same runs: the five rows of draw 0, the as-budgeted
row of draws 1 to 6, and the probes-only row of draws 1 and 2.

**What came of it.** What a row adds over the row it is read over: the mean
of ten draws, with its standard error from the five networks, each averaged
over its ten draws. In bold, what five networks put outside chance at one in
twenty.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| A cycle of 3 minutes, over the probes-only row of its draw: the mean of ten draws | −0.008 ± 0.011 | −0.002 ± 0.012 | +0.017 ± 0.021 | +0.031 ± 0.016 | **+0.295 ± 0.064** | **+0.076 ± 0.019** |
| the standard deviation from draw to draw | 0.037 | 0.028 | 0.068 | 0.085 | 0.165 | 0.059 |
| draws of the ten at a tenth or over | 0 | 0 | 1 | 2 | 10 | 4 |
| A cycle of 6 minutes: the mean of ten draws | +0.010 ± 0.017 | −0.007 ± 0.009 | +0.087 ± 0.038 | **+0.066 ± 0.019** | **+0.411 ± 0.078** | **+0.119 ± 0.030** |
| the standard deviation from draw to draw | 0.033 | 0.023 | 0.121 | 0.083 | 0.205 | 0.057 |
| draws of the ten at a tenth or over | 0 | 0 | 5 | 5 | 8 | 8 |
| Probes only, over the as-budgeted row of its draw | −0.003 ± 0.011 | +0.001 ± 0.012 | +0.030 ± 0.017 | +0.028 ± 0.022 | **+0.030 ± 0.008** | −0.014 ± 0.012 |

The inverted set, draw by draw: the five networks' mean of what a cycle adds.

| | Draw 0 | Draw 1 | Draw 2 | Draw 3 | Draw 4 | Draw 5 | Draw 6 | Draw 7 | Draw 8 | Draw 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| The reference networks, a cycle of 3 minutes | +0.04 | +0.12 | +0.05 | +0.03 | +0.03 | +0.00 | +0.15 | +0.17 | +0.04 | +0.13 |
| The reference networks, a cycle of 6 minutes | +0.11 | +0.18 | +0.12 | +0.18 | +0.12 | +0.10 | +0.01 | +0.05 | +0.19 | +0.13 |
| The networks trained before, a cycle of 3 minutes | +0.23 | +0.45 | +0.36 | +0.18 | +0.20 | +0.69 | +0.20 | +0.27 | +0.13 | +0.24 |
| The networks trained before, a cycle of 6 minutes | +0.03 | +0.43 | +0.46 | +0.07 | +0.45 | +0.47 | +0.44 | +0.65 | +0.48 | +0.62 |

**On the inverted set a six-minute cycle ends over a tenth of a point in the
mean, and a three-minute one under it.** 0.12 ± 0.03 and 0.08 ± 0.02 for the
reference networks, and the five networks' mean is at a tenth or over on 8 of
the ten draws at six minutes and on 4 at three. Neither is far from a tenth:
six minutes is 0.6 of its errors over it and three 1.3 under, and six costs
0.04 ± 0.04 more than three. From draw to draw the six-minute figure has a
standard deviation of 0.06 and runs from 0.01 to 0.19; draw 0, the one the
section before had, is 0.11.

**On MNIST and Fashion-MNIST six minutes is inside a tenth.** −0.01 ± 0.01 and
0.07 ± 0.02 for the reference networks. On Fashion-MNIST the five networks'
mean is at a tenth or over on 5 of the ten draws.

**For the networks trained before, neither interval is inside a tenth on the
inverted set.** A three-minute cycle ends 0.30 ± 0.06 over and a six-minute
one 0.41 ± 0.08. On Fashion-MNIST their six minutes is 0.09 ± 0.04.

**Probes taken and nothing written move nothing.** Over the as-budgeted row
of the same seed the probes-only row is within 0.03 of a point on every set
for both kinds. The two do not share draws, and over ten the draws average
out. One of the six is outside chance by the test, the old networks' on the
inverted set at 0.030 ± 0.008. Nothing in the model tells the two rows apart
but their draws, and one in six at that size is no more than the section
before this one found of such tests.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Held: right, percent, on draw 0, which is every mode's before this | 97.26 | 97.64 | 86.88 | 87.27 | 92.27 | 94.63 |
| over ten draws | 97.227 ± 0.105 | 97.586 ± 0.046 | 86.794 ± 0.138 | 87.297 ± 0.117 | 91.965 ± 0.645 | 94.645 ± 0.356 |
| the standard deviation from draw to draw | 0.075 | 0.033 | 0.110 | 0.073 | 0.234 | 0.069 |
| What holding adds, over the as-budgeted row of its draw | **+0.075 ± 0.026** | **+0.025 ± 0.007** | **+0.205 ± 0.037** | +0.062 ± 0.039 | **+0.683 ± 0.141** | **+0.251 ± 0.038** |
| Points lost to the tile so held, over ten draws | 0.22 ± 0.01 | 0.17 ± 0.03 | 0.68 ± 0.11 | 0.59 ± 0.09 | 1.40 ± 0.24 | 0.74 ± 0.08 |
| As budgeted: right, over ten draws | 97.303 ± 0.104 | 97.612 ± 0.048 | 86.999 ± 0.162 | 87.359 ± 0.141 | 92.648 ± 0.575 | 94.896 ± 0.347 |

**The chip as it is held, over ten draws.** The reference networks are right
97.59, 87.30 and 94.65% of the time and lose 0.17, 0.59 and 0.74 of a point to
the tile; on draw 0 they are right 97.64, 87.27 and 94.63 and lose 0.11, 0.62
and 0.76. The networks trained before are right 97.23, 86.79 and 91.96% of
the time and lose 0.22, 0.68 and 1.40, for draw 0's 97.26, 86.88 and 92.27,
and 0.19, 0.60 and 1.09. In none of the six cells is draw 0 clear of a
network's mean over the other nine; the farthest is the old networks' on the
inverted set, 0.34 ± 0.20 above.

| | MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|
| The reference less the old, seed by seed, over ten draws: right, held | **+0.36 ± 0.09** | **+0.50 ± 0.12** | **+2.68 ± 0.59** |
| right, as budgeted | **+0.31 ± 0.09** | +0.36 ± 0.17 | **+2.25 ± 0.51** |
| what holding adds | −0.05 ± 0.02 | **−0.14 ± 0.04** | −0.43 ± 0.17 |
| what a 6-minute cycle adds | −0.02 ± 0.01 | −0.02 ± 0.05 | **−0.29 ± 0.07** |
| what a 3-minute cycle adds | +0.01 ± 0.01 | +0.01 ± 0.03 | −0.22 ± 0.08 |
| A 6-minute cycle over a 3-minute one, the reference | +0.00 ± 0.01 | +0.04 ± 0.03 | +0.04 ± 0.04 |

**What training for the tile buys is in what holding adds.** The section
before this one found that as budgeted a network trained for the tile loses
what one that was not does. Six minutes of drift and a source's rows add
0.03, 0.06 and 0.25 of a point to what the reference networks lose on the
same draws, and 0.08, 0.20 and 0.68 to the old ones: less on all three sets,
and clear on Fashion-MNIST. A six-minute cycle costs a reference network 0.29
± 0.07 of a point less than the old one of its seed on the inverted set. Held,
the reference networks are right 0.36, 0.50 and 2.68 points more often, clear
on all three, where as budgeted they are 0.31, 0.36 and 2.25.

**What was predicted.** Written before the mode was written out, on
2026-10-08. Five things.

1. That on the inverted set six minutes does not hold a tenth in the mean:
   the reference networks' six-minute cycle 0.10 to 0.22 over and their
   three-minute one 0.01 to 0.09. Right: 0.12 and 0.08.
2. That on MNIST and Fashion-MNIST the six-minute mean is under 0.06. Right
   on MNIST, −0.01. Wrong by a hundredth on Fashion-MNIST, 0.07, which is
   still inside a tenth.
3. That from draw to draw the inverted set's six-minute figure has a standard
   deviation of 0.06 to 0.15. Right, at its edge: 0.06.
4. That held, over ten draws, the reference networks are right 97.52 to
   97.62, 87.12 to 87.32 and 94.50 to 94.80% of the time. Right: 97.59, 87.30
   and 94.65.
5. That holding adds 0.02 to 0.08, 0.05 to 0.20 and 0.15 to 0.35 of a point to
   what the reference networks lose, and that held they are right 0.20 to
   0.40, 0.25 to 0.55 and 2.0 to 2.6 points more often than the old ones.
   Right on five of the six: 0.03, 0.06 and 0.25, and 0.36 and 0.50. The lead
   on the inverted set is 2.68.

**What this is not.** More networks: the ten draws are of the same five, and
the errors here are those five's. Other intervals than three minutes and
six. A draw of the drift alone: a draw moves the noise, the walk and the
source together, and the pairing takes out the noise. A schedule: it is one
calibration. Version 1, or another tile.

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
9. **Nothing here is trained for the tile.** *Tried on 2026-10-06, §5, at its
   end: Gaussian noise on the sums as a network trains is worth half a point
   on Fashion-MNIST and nothing that can be told on the other two, and how
   long a network is trained mattered more. The tile itself has still not
   been in a training's forward pass. Those networks are the reference since
   that day (grxcp's B17).* As this item stood: `pta_mnist train` trains on the
   host, and the tile is only ever evaluated. §5's last section found v1 at
   over a point on two data sets, and every figure in it is a network that
   never saw the errors it is then run under. Training with the model in the
   forward pass is the usual remedy, and this harness cannot say what it would
   give back. Its trainer also takes its inputs as they come: on images that
   are mostly lit it reaches 93% where the same digits, dark, give 97.5%.
