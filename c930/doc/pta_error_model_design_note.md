# PTA C1: the tile's error model

**Status: all six of C1's impairments built and gated (§5), 2026-09-15.**
Decisions E1–E4 were settled on 2026-09-14 and E5–E8 on 2026-09-15.
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

**What stays exact.** With every bit clear, `out = (y + 2^7) >>> 8` and
`y = (sum of a_r * w_rn) << 8`, so `out` is the exact integer sum and PTM-C is
the array again. QUANT with `B_a`, `B_w` and `B_adc` all zero is also exact, as
is DRIFT from a model reset until its first step.

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

The CPU document's gate C1(b) names the NPU DPI wrapper. The configuration is
not on a CSR until C4, so the wrapper cannot reach it yet; the core harness
carries the parity gate until then, and the wrapper takes it when C4 maps the
ports. Gate C1(a), the accuracy sweep, runs on the D3 network once every
impairment is green.

---

## 6. Order

1. ~~QUANT, THERMAL, SHOT and PROG_ERR, through P0–P4, with the refusals.~~
   **Done** (§5).
2. ~~DRIFT and XTALK, through P5 and P6.~~ **Done** (§5).
3. Gate C1(a) on the D3 network, with the drift settings fitted to TFLT and
   TFLN (§7).
4. Only then the CSR mapping and firmware (C4).

---

## 7. Open questions

1. **Drift's settings.** The CPU document's §4.4 fits `PTA_DRIFT` to TFLT, with
   TFLN as the stress case, and anchors both to a 46-hour test. Under E5 a fit
   needs a shot rate — how many shots the emulated tile runs in an hour — which
   is a statement about the workload, not the device. Gate C1(a) and C3 have to
   state one.
2. **Error units at 16-bit operands.** The programming-error and drift σ, and
   the drift clamp, are Q8.8 in weight LSB, so they top out at 256 LSB. That is
   an 8-bit weight's whole range but under 1% of a 16-bit one's, and a drift of
   TFLN's size — 11–15 LSB at 6 bits, about 15,000 LSB at 16 — cannot be set.
   Before a 16-bit sweep, either the fields widen or the unit becomes a fraction
   of full scale.
3. **MZM_NL** has a bit but no phase. It is not in C1's list.
4. **Crosstalk beyond first order.** E8 couples nearest neighbours only, and a
   neighbour's crosstalk does not couple on again. An MZI mesh would couple
   along its triangular structure instead (CPU document §8 item 5); that is a
   different matrix, and a hypothesis this program has no ground truth for.
