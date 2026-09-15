# PTA C1: the tile's error model

**Status: QUANT, THERMAL, SHOT and PROG_ERR built and gated (§5), 2026-09-15;
decisions settled 2026-09-14.** Phase C1 of grxcp
`docs/designs/pta_cpu_integration.md` (§6): the error model of that document's
§4.3, built into PTM-C (`rtl/pta/c930_ptm_c.sv`), with a C reference
(`sim/pta_tile_model.c`) that agrees with the RTL bit for bit. This note is the
contract both implement. DRIFT and XTALK have open questions (§7) and come
next.

---

## 1. What it is for

PTM-C is exact (C0). C1 makes it an analog tile: each captured result becomes
what a photonic dot product would deliver after its DACs, its detector noise
and its ADC. Two properties make the result usable:

- **Every impairment is behind its own `PTA_IMPAIR` bit**, so a sweep can
  attribute an accuracy loss to one mechanism. With every bit clear, PTM-C is
  still bit-identical to the systolic array, and C0's gate keeps checking that.
- **Every stochastic term is reproducible from the seed**, with no `$random`
  anywhere (CPU document §4.3). A C reference that consumes draws in the same
  order makes RTL parity a bitwise question, and lets grxcp's host predict an
  analog GEMM exactly (CPU document §7, gate 1).

## 2. Decisions

Settled on 2026-09-14, all as recommended.

- **E1 — the core marks each captured element.** The tile does not draw on its
  own clock. The core tells it when a column is about to be captured, and draws
  are consumed in the core's loop order: N tile, K tile, output row `m`,
  column. A result then depends only on the seed, the shape and the operands —
  not on DMA stalls, queueing or idle cycles.
- **E2 — the generators reload from the seed at every GEMM start**, as S_ACT's
  do. Queued GEMMs are independent; a driver that wants different noise per
  layer writes a different seed.
- **E3 — weight errors act after the DAC:** the analog weight is
  `q_w(w) + eps + delta`. The DAC chooses a level and the device's error then
  moves it, which is how an electro-optic TFLT weight behaves. This corrects the
  CPU document's §4.3, which writes `q_w(w + eps + delta)`.
- **E4 — the ADC's scale is a shift chosen per GEMM:** `LSB_adc = 2^S`. Software
  sets `S` from the layer's range, which is the activation-scaling knob of the
  CPU document's §4.3 and §5.2. It adds a field to the proposed `PTA_BITS`.

Taken as defaults, following S_ACT and the program plan:

- **Integer precisions only.** A start with any impairment bit set and FP16 or
  BF16 raises `o_error`, like a bad dimension. The float modes accumulate
  normalised FP32, which this fixed-point model does not describe.
- **One xorshift32 stream per stochastic impairment**, each stepping whether or
  not its impairment is enabled. Turning one impairment on never changes
  another's draws, so a one-at-a-time sweep compares like with like.
- **An impairment the build cannot model is refused, not ignored.** A start
  raises `o_error` if it sets a bit whose impairment is not built yet, or any
  bit at all when the core was built with the digital array.

---

## 3. Where it goes

PTM-C already evaluates each column in one pass (C0). C1 adds the model to that
pass, so the core's schedule and the DMA are untouched. The core gains
configuration inputs and two signals to the tile:

- `pta_cfg_load`, the cycle a start is accepted: the tile samples its
  configuration and loads its generators.
- `pta_shot` and `pta_shot_col`: during the hop window whose shot the core
  captures for column `n` — `t == 2·NUM_ROWS + 2n` in `S_RUN`, for `n < nc` —
  the tile applies the model to that column, and steps its generators on the
  hop edge that registers it. The other columns register their exact sums
  that window, which the core never reads.

Weight writes are already logical events on the array's write port, in
`S_WLOAD`'s order, so PROG_ERR needs no new signal.

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

At a start, each stream loads `seed ^ K`, or `K` itself if that is zero:
THERMAL `K = 0x9E3779B9`, SHOT `0x3C6EF372`, PROG_ERR `0xDAA66D2B`.

- PROG_ERR draws once per weight write, in `S_WLOAD`'s order: N tile, K tile,
  row, column.
- THERMAL and SHOT each draw once per captured element, in the order N tile,
  K tile, output row `m`, column `n < nc`.

**Per weight write** of `w` to (bank, row, column):

```
e = (sigma_pr * gs_pr + 2^15) >>> 16           Q.8, weight LSB; stored with w
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
for rows outside the K tile) and the stored `w_rn`, `e_rn`:

```
xa_r = QUANT ? q(a_r, B_a) : a_r
wa_r = ((QUANT ? q(w_rn, B_w) : w_rn) << 8) + (PROG_ERR ? e_rn : 0)       Q.8
y    = sum over r of xa_r * wa_r                                          Q.8, tile units

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
the array again. QUANT with `B_a`, `B_w` and `B_adc` all zero is also exact.

---

## 5. Gates

In the style of the CPU document's §6: each can fail, and each names its
ablation. Parity runs in `sim/tb_core_verilator.cc`, where S_ACT's gate A2 runs,
over its 14 shapes at `DIN_W` 8 and 16; the C reference is
`sim/pta_tile_model.{h,c}`, plain C so grxcp and grxgpu can vendor it (D1).

- **P0 — off is exact.** Every bit clear, PTM-C build: C equals the digital
  reference at every shape, and C0's benches still pass with `PTM_C=1`.
  *Ablation:* C0's own.
- **P1 — QUANT.** Several `B_a`, `B_w`, `B_adc`, `S` settings, some chosen to
  saturate: C and the saturation count match the model at every shape, and a
  directed case pins the rounding at a half-LSB boundary. *Ablation:* drop the
  quantiser's rounding term; parity fails.
- **P2 — THERMAL, P3 — SHOT, P4 — PROG_ERR.** Each alone, then all four
  together: C and saturations match the model at every shape, and elements move
  off their exact sums. *Ablation:* xorshift32's first shift 13 → 12 in the RTL;
  parity fails.
- **Refusals.** Any impairment with FP16 or BF16, an unbuilt bit, or `S` above
  40 raises `o_error` at start, and the next valid start clears it. In a
  digital-array build, any bit is refused.

*Met,* 2026-09-15, at `DIN_W` 8 and 16:

- P0: all 14 shapes exact in a PTM-C build. With `PTM_C=1`, `make npu` passes,
  `make npu_float` passes 24/24, `make npu_feed`'s log is byte-identical to the
  array's, and `make ptm_c_lockstep` still finds no difference.
- The directed cases: the model matches the hand-worked values, and the RTL
  matches the model, including the ADC's two saturations.
- P1–P4, and all four together: C and the saturation count match
  `pta_gemm()` at all 14 shapes, `M=64, N=8, K=256` included, and every shape
  moves off its exact sum.
- Refusals: DRIFT, XTALK and MZM_NL, QUANT with FP16, THERMAL with BF16 and
  `S = 41` are refused, and the next valid start runs. A digital-array build
  refuses each of the four built impairments.
- *Ablations, red:* the xorshift32 shift fails every shape in the thermal,
  shot, programming-error and combined runs. Dropping the rounding term fails
  both hand-worked quantiser cases and 10 of the 14 quantised shapes. Three of
  the other four quantise only in the ADC, whose rounding the ablation leaves
  alone; the fourth is the one-element shape, whose single result it happens
  not to move.

The CPU document's gate C1(b) names the NPU DPI wrapper. The configuration is
not on a CSR until C4, so the wrapper cannot reach it yet; the core harness
carries the parity gate until then, and the wrapper takes it when C4 maps the
ports. Gate C1(a), the accuracy sweep, runs on the D3 network once the four
impairments above are green.

---

## 6. Order

1. ~~QUANT, THERMAL, SHOT and PROG_ERR, through P0–P4, with the refusals.~~
   **Done** (§5).
2. DRIFT, once §7's clock and bound are settled.
3. XTALK, once §7's topology question is settled.
4. Gate C1(a) on the D3 network.
5. Only then the CSR mapping and firmware (C4).

---

## 7. Open questions

1. **Drift's clock.** The CPU document's §4.3 steps `delta` every
   `2^PTA_DRIFT[31:16]` cycles. A cycle clock makes results depend on DMA
   timing, which E1 exists to avoid. Counting drift time in captured elements
   keeps parity exact, and the CPU document's §6.2 already says absolute cycle
   counts are not a claim. The random walk also needs a bound, which §4.3 names
   and does not give, and drift persists across GEMMs, so E2's per-GEMM reload
   cannot apply to its state.
2. **Crosstalk's topology.** §4.3's formula sums over neighbouring rows `i'`,
   while the CPU document's §8 item 5 speaks of the column index. A column
   neighbour past `nc` holds stale weights that the host never wrote, so either
   the coupling stops at `nc` or those weights must be defined.
3. **MZM_NL** has a bit but no phase. It is not in C1's list.
