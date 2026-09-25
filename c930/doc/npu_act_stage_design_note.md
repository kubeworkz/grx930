# S_ACT: an activation stage in the c930 NPU

**Status: RTL through gate A2** (§6). `rtl/c930_npu_act.sv` and the S_ACT state
in `rtl/c930_npu_core.sv`, driven directly by `sim/tb_core_verilator.cc` and tied
off in `c930_npu_top`. Next is chain mode, gate A3. No DMA, CSR or firmware
change until A3 has reported.
**Date:** September 2026
**Built against:** the loop-interchange core, now on main (§2 is why that
matters).
**Companions:** grxcp `docs/designs/pta_tpaqcn_review.md` §4.5–6 (why this
experiment exists, and its kill criterion); grxcp
`docs/designs/pta_cpu_integration.md` §3–4 (the CSR plan, the error model, the
determinism rule).

---

## 1. What it is for

One question: **how many all-optical activations can be chained before a
network's output diverges from its digital reference**, as a function of the
photons each activation carries and of fabrication detuning.

That number is the reset interval N, and it bounds everything an all-optical
activation could ever win. With an O-E-O reset every N layers, a layer costs
`E_opt + E_OEO / N`, so the advantage over any O-E-O path is at most N however
cheap the optics get (review §5.2). Nobody has measured N for any material.

It needs no photonics. In emulation an activation is a numerics block: a
transfer curve from the coupled-mode solver, the shot noise its light carries,
a per-unit detuning, and an optional requantisation standing in for the O-E-O
reset. The curve and the noise are hypotheses about published devices; nothing
this stage produces is a statement about one, exactly as
`pta_cpu_integration.md` says of the tile.

---

## 2. Where it goes, and why not where the review put it

The review places S_ACT "between S_WRITE and the next output row". Under the
loop order about to land, that is wrong on every K tile but the last:

```
for nt:                         N tile
  for kt:                       K tile
    S_WLOAD                     load B[kt][nt] once
    for m:                      output row, innermost
      S_AROW / S_ACCLD          wait for A[m]; acc[] <- C[m][nt] when kt > 0
      S_RUN                     accumulate this K tile
      S_WRITE                   C[m][nt] <- acc[]     a partial sum unless kt is last
```

`c_mem` carries the running K accumulation between K tiles, and `S_ACCLD`
restores it before each run. `C[m][nt]` is a complete sum only when `S_WRITE`
runs with `kt_reg == num_k_tiles - 1`. An activation applied any earlier is
applied to a partial sum.

So **S_ACT replaces S_WRITE on the last K tile**, when the stage is enabled:

```
S_RUN --[kt_reg != last  or  !act_en]--> S_WRITE    unchanged
S_RUN --[kt_reg == last  and  act_en]--> S_ACT  --> the row / tile advance S_WRITE performs
```

Three properties make that the right cut.

- **`acc[]` already holds the complete sums** when `S_RUN` exits; `S_WRITE`'s
  store is a plain copy of them. S_ACT reads `acc[]`, which is flops, so
  `c_mem` gains no read port and keeps the one-read, one-write shape the core's
  comment relies on for BRAM inference beside the DMA readback.
- **It writes through `S_WRITE`'s port to the same `c_idx`**, so the DMA's C
  writeback reads activated values with no DMA change at all.
- **With the stage disabled, the FSM is cycle-identical** to the staged core.
  That is gate A0.

Two details in `S_WRITE`'s exit that S_ACT has to inherit rather than
re-derive:

- On a row advance `S_WRITE` clears `acc[]` when `kt_reg == 0`. On a
  single-K-tile GEMM that tile is also the last, so the clear must run *after*
  S_ACT has consumed `acc[]`: the advance logic becomes one block shared by both
  states and runs at their exit.
- `done_cond` is keyed on `state == S_WRITE`. It needs an S_ACT term, or
  `o_done` never fires on an activated GEMM and the bench times out rather than
  failing.

---

## 3. The datapath

Per element, with `j = n_cnt` the physical column (`0 .. nc-1`):

```
stage 1   x  = sat( acc[j] * XS[j] >>> XSHIFT )      table domain; XS[j] = XSCALE * s_j
stage 2   σ  = k_shot * isqrt(|x|)                    shot-noise scale for this element
stage 3   x2 = x + σ * g                              g ~ N(0, 1)
stage 4   y[i], y[i+1] <- BRAM[i], BRAM[i+1]          i = x2's top 10 bits
stage 5   y  = y[i] + ((y[i+1] - y[i]) * f >>> 14)    f = x2's low 14 bits
stage 6   c  = requant ? sat(round(y*r_j / LSB_adc), 2^(B-1)) * LSB_adc : y*r_j
          C[m][n_base + j] <- sat32( c <<< YSHIFT )
```

At most one multiply per registered stage, six stages, with the write index
travelling alongside the data. **Two of them are split for timing, so the
implemented latency `ACT_P` is 8, not 6**: stage 2 into 2a (root and draw) and 2b
(the `k_shot` multiply), and stage 6 into 6a (the `r_j` multiply) and 6b
(requantise, scale, saturate). Both splits were made against a measured path,
not a guess — §5. `nc` elements enter on consecutive cycles, so S_ACT lasts
`nc + ACT_P` cycles per row: the element is registered on entry, and the last
sub-stage is the `c_mem` write itself. The output scale and the table's output full
scale are powers of two, so the output scale and `LSB_adc` both cost shifts. The
detuning's output factor `r_j` is applied before requantisation, because a real
reset digitises what the unit actually emits.

**The fixed point, as built.** The header of `rtl/c930_npu_act.sv` states the
contract, and the harness's `act_element()` implements it; gate A2 holds the two
to bitwise agreement. The choices the stages above leave open:

- `XS[j]` is unsigned, and the stage-1 product is the full 48 × 32 bits.
- `√` is `isqrt4`: a leading-zero count normalises `|x|` to [1, 4), and a
  four-entry table of `2^11·√1 … 2^11·√4` is interpolated on six fraction
  bits. It is within about 1.5 % of the true root, and a scale on shot noise
  needs no more.
- `g` is the sum of the four bytes of one xorshift32 step, less 510, times 443:
  that sum has a standard deviation of 147.8, and 443 / 2^16 brings it to
  0.999. One step per element. So stage 2 carries two small multiplies beside
  `k_shot · √`: the constant 443, and `isqrt4`'s 10 × 6-bit interpolation.
- Stage 3 rounds the noise (`+2^23`, then `>>> 24`); the interpolation and the
  `r_j` product floor; requantisation rounds half up; `YSHIFT` above 32 acts
  as 32. Stage 1, stage 3 and the 32-bit output saturate independently, and
  `o_act_sat_count` counts each event.

**The table.** 1024 uniform segments over the signed 24-bit input, 1025 signed
24-bit breakpoints at `x_i = -2^23 + i·2^14`, in one dual-port BRAM read at `i`
and `i+1` together. The difference needs 25 bits and the fraction 14, so
interpolation is one DSP48 multiply with the pre-adder forming the difference.
The shift floors. `c930/sim/act_table_gen.py`'s docstring is the normative
statement of the format, and its `pwl()` is the reference both the RTL and the C
model must match bit for bit.

The segment count was measured, not chosen. Chord error falls as 1/segments²,
so the generator compares its worst error within two knees against the shot
noise the unit carries there, and rejects a table whose error exceeds a quarter
of σ. Against that test, 64 segments are up to 17× too coarse, for the as-built
unit at a 1 ps clock. 256 still fail that unit (1.18×). 1024 pass every preset
at every clock, worst 0.08×, for the price of a RAMB36 of breakpoints instead of
a RAMB18. So piecewise-quadratic is not needed.

Written through an indirect port while the core is idle. One table per design
point: a curve from the solver — or later from the diffusion model — is data,
not RTL. The physics lives entirely in the generator: whether C is read as
optical power or as field amplitude, and whether the unit outputs the second
harmonic or the depleted fundamental.

**κ only sets the watt scale.** With full scale tied to the knee, the
coupled-mode equations depend on power only through `κ²P`. The generated tables
for the TPA-QCN and compound 4 units at 6 mm are therefore bit-identical, and a
curve's shape depends only on loss × length and mismatch × length. κ reaches the
experiment through one place: the photon count at the knee.

**Detuning.** Physical, so indexed by `j`, not by output index: N tiles reuse
the same columns, and a real tile reuses the same activation units. To first
order a phase-matching detuning scales the efficiency, `η → s·η`, and the
coupled-mode equations then give exactly `f_s(x) = f(s·x) / s` for either
output, loss included (scale the field amplitudes by `√s` and they return to the
nominal equations). Hence `s_j` on the input axis and `r_j = 1/s_j` on the
output, in the table's own encoding — for a field-amplitude table the harness
loads `√s` and `1/√s`. The harness folds `s_j` into the per-column input scale
`XS[j]` and computes `r_j` itself, so the RTL never divides. It draws them from
a strip-width distribution using the published device's measured anchors
(review §5.1): +50 nm of width moves the peak +22 nm against an acceptance of
about 12 nm FWHM, so

```
s(Δw) = sinc²( 1.39 · 0.44·Δw / (FWHM/2) )
```

and 14 nm of width gives `s ≈ 0.5`. A large `Δβ` also caps conversion below one,
which a scale cannot express. §8 records that.

**Noise.** One term in this phase: shot noise on the light entering the unit,
`σ = k·√|x|`, the same form as `PTA_SIGMA_SH`. `k` carries the experiment's main
axis. If the table's knee sits at `x_knee` and the knee carries `n` photons,
then `k = √(x_knee / n)`. For scale, 6.5×10⁵ photons is the 83.5 fJ knee of the
compound 4 unit at 100 fs in review §4.5, and the sweep runs 10³ to 10⁶. The
Gaussian is an Irwin–Hall sum of four uniform draws; `√` is a leading-zero count
and a four-entry interpolation LUT; both as `pta_cpu_integration.md` §4.3
specifies. The `√|x|` form holds when the table reads C as optical power. For a
field-amplitude table shot noise is constant in `x` (it is `√P` on `P = x²`),
which the same stage produces with the square root bypassed to the constant
2^12, selected by `i_act_noise_const`. The generator emits `i_act_k_shot` for
both cases at every photon count it is asked for.

The tile's own impairments — weight programming, crosstalk, thermal noise,
drift — belong to PTA phase C1 and are **not a dependency**. S_ACT measures the
activation chain's contribution on an exact digital MAC, and borrows C1's
primitives once they exist rather than waiting for them.

**Determinism.** The draws come from xorshift32 (shifts 13, 17, 5), the
generator `sim/tb_core_verilator.cc` already uses for its operands. It costs a
few dozen flops and XORs in RTL, and it is loaded from a seed at `i_start`. The
FSM fixes the draw order: `nt`, then `m`, then `j`, on the last K tile only. A C
reference that consumes draws in that order makes RTL parity a bitwise question,
which is the rule `pta_cpu_integration.md` §4.3 sets for every stochastic term.

**Requantisation.** The stand-in for an O-E-O reset: round and saturate to
`B_adc` bits over the table's output range — the `d_j` expression of
`pta_cpu_integration.md` §4.3. It is **per GEMM**, not a period. The core does
not know which layer a GEMM is, and a queue need not hold one network's layers
in order, so a counter inside the NPU would be a guess. The harness sets it on
every N-th layer.

**Readback.** `o_c_rdata` truncates `c_mem` to 32 bits. S_ACT saturates to 32
bits and counts it, so an activated value can never wrap silently on the way
out.

**Precision scope.** INT8 and INT16 operands only. FP16 and BF16 accumulate
normalized FP32, and a table over those codes is a separate design. `act_en`
with an FP precision raises `o_error` at start, the same way an out-of-range
dimension does.

---

## 4. Ports

Core-level. Every scalar is sampled at `i_start`, like `i_precision`.

| Port | Width | Meaning |
|---|---|---|
| `i_act_en` | 1 | route the last K tile through S_ACT |
| `i_act_requant` | 1 | this GEMM is an O-E-O reset |
| `i_act_adc_bits` | 4 | `B_adc` for requantisation |
| `i_act_xs` | 32 × NUM_COLS | per-column input scale `XSCALE · s_j` |
| `i_act_xshift` | 6 | `acc` → table domain |
| `i_act_r` | 16 × NUM_COLS | per-column output factor `r_j`, Q4.12 (so `s ≥ 1/16`) |
| `i_act_yshift` | 6 | table output → C, a power-of-two scale |
| `i_act_k_shot` | 16 | `k`, Q8.8; 0 disables noise |
| `i_act_noise_const` | 1 | constant σ, for field-amplitude tables |
| `i_act_seed` | 32 | xorshift32 seed |
| `i_act_tbl_wen`, `_waddr`, `_wdata` | 1, 11, 24 | breakpoint write, idle only |
| `o_act_count` | 32 | elements activated |
| `o_act_sat_count` | 32 | saturations, table domain and 32-bit readback |
| `o_act_cycles` | 32 | cycles spent in S_ACT |

`o_act_cycles` is honesty instrumentation, not a diagnostic.
`doc/c930_architecture.md` decomposes `CYCLE_COUNT` into weight movement,
`S_RUN` and `S_WRITE` with an exact identity; the interchange already makes that
identity stale, and S_ACT adds a term. The counter is what lets it close again.

**When this reaches the CSR** it goes into the widened decode
`pta_cpu_integration.md` §3 proposes. The PTA block ends at `0xCC`, which leaves
twelve words, `0xD0`–`0xFC`: enough for the scalars and counters, with the table
and the per-column scales behind an indirect address.

`i_act_requant` is the exception, because it is per command. A live CSR bit
would apply to whichever command dispatched next — the live-versus-snapshot
hazard the CSR header's completion contract exists to prevent — so it belongs in
the command snapshot beside `precision`, taking `CMD_W` from 147 bits to 148.

---

## 5. Cost

**Cycles.** S_ACT's `nc` writes replace `S_WRITE`'s on the last K tile, so a
GEMM pays `M · Nt · P` extra cycles. At `M=64, N=8, K=256` that is 384 cycles
against 71,734.

*Gate A1 encodes that as an equality, and what it was telling us was mostly
right.* Measured at `ACT_P = 7`, before the stage-6 split, a GEMM paid **+98**
cycles where `M · Nt · P` was 112 for `M=8 N=12 K=8`, and 38 against 42 for
`M=3 N=12 K=2` — 13 failures, and the same 13 on the unmodified stage, so not a
regression. It was tempting to call the bench mis-specified and move on. Taking
the cut settled it the other way: at `ACT_P = 8` those same shapes pay **exactly**
`M · Nt · P` (+128 of 128, +48 of 48) and A1 is down to **5 failures**, all of
them ±1 cycle and all on shapes where `N` is not a multiple of `NUM_COLS` or
`M` is 1:

| shape | paid | `M · Nt · ACT_P` |
|---|---|---|
| `M=8 N=12 K=16` | +128 | 128 ✓ |
| `M=8 N=12 K=8` | +128 | 128 ✓ |
| `M=3 N=12 K=2` | +48 | 48 ✓ |
| `M=5 N=11 K=8` | +79 | 80 |
| `M=1 N=12 K=16` | +17 | 16 |
| `M=8 N=9 K=16` | +127 | 128 |

`act_cycles` agrees exactly in every case, before and after (208/208 then
224/224), so the stage's own accounting was never in doubt. What is left is a
±1 boundary effect on a ragged last tile, one cycle either way. That is worth
finding, and it is a much smaller thing than the paragraph this replaces
claimed. **A1 is still red and still a gate; it is closer to green than it has
been, and the residue is a real off-by-one, not a wrong expectation.**

**Area — measured.** A-synth, C4(b), 2026-09-24: `c930_npu_act` alone, out of
context on `xc7a200tfbg484-1` through synthesis, placement and routing with a
10 ns clock (`make -f` nothing; `bash synth_xilinx/run_ooc_c4b.sh act`).

| | estimated above | measured |
|---|---|---|
| LUTs | ~2,000 | 1,701 cells |
| DSP48E1 | 5 | **13** |
| RAMB | 1 | **4** (3 tiles routed) |
| FF | — | 775 |
| CARRY4 | — | 120 |

The LUT estimate held. The DSP count did not: "five multiplies" counts the
multiplies in the arithmetic, not the DSP48E1s Vivado spends on them — the
48-bit stage-1 product and the 64-bit stage-6 shift each take more than one.
Nor did the BRAM: 1025 entries of 24 bits is one RAMB36 of data, but the bench
reads two adjacent entries every cycle and writes a third port while idle, and
that is built from four.

**Timing — measured, and it does not close.** The claim above is true and was
answering a different question. S_ACT does not lengthen the PE path; it is its
own path, and nobody had timed it:

| | WNS at 10 ns | Fmax | worst path | levels |
|---|---|---|---|---|
| as written | −14.286 ns | **41.2 MHz** | `col5_reg[1]` → `o_sat_count_reg[31]` | 37 |
| stage 6 shortened | −9.539 ns | **51.2 MHz** | `col5_reg[2]` → `o_sat_count_reg[29]` | 27 |

141 of 504 endpoints failed in the first. The cone is stage 6, which in one
cycle did: an 8:1 mux selecting `r_r[col5]` (which is why the path starts at a
`col5` bit), a DSP multiply, **three variable shifts** including a 64-bit one, a
clamp against bounds recomputed from `adc_bits` every cycle, two 64-bit
comparators, and the saturation counter's accumulate hanging off the end. Not
the wide stage-1 multiply that `pta_cpu_integration.md` §6.1 and the program
plan both named as the risk.

Shortening it cost no latency and no accuracy. `sh`, the round addend, the
quantiser mask, the clamp bounds and the capped `YSHIFT` all come from the
configuration, which is sampled at `cfg_load`, so they are registers now. And
two of the three shifts cancel: `(x >>> s) <<< s` clears x's low s bits, which
is an AND with a mask, and a clamp commutes with a monotone left shift, so the
bounds are held already shifted. One variable shift is left.
`sim/act_stage6_equiv.py` checks the two forms agree over 99,900
combinations of `adc_bits`, `YSHIFT`, `requant` and operands, including the
29-bit wrap the intermediate width allows; gate A2 agrees in RTL, saturation
counts included. `ACT_P` is still 7.

**The cut, taken.** 51.2 MHz is not 100 MHz and the rest needed latency. The
measured path was 19.5 ns over 27 levels, so stage 6 splits after the multiply:
**6a** is the `r_r[col5]` mux and the DSP product — the DSP48E1 carries its own
output register, so this costs only the pipeline slot — and **6b** is the mask,
the clamp, the shift and the saturate. `ACT_P` 7 → 8. The saturation counter
moves to 6b with the data, so each element is still counted once, and gate A2
passes unchanged with the counts exact.

If 6b is still long, the next split is before the 64-bit shift, which with the
two 64-bit saturation comparators is most of the remaining carry chain
(`ACT_P` 8 → 9). Whether it is needed is a measurement, not a guess, and it has
not been made yet — **the routed Fmax of the split stage is still owed**, because
Vivado here takes WSL's network down for the duration (`synth_xilinx/README.md`).

A cut goes into `ACT_P` and, where they apply, `PTA_TS` and §2.1's model, never
around them (program plan §5). `ACT_P` is updated in `c930_npu_core.sv` and in
`sim/tb_core_verilator.cc`, the two places that hold it. `PTA_TS` is the *tile's*
modelled shot latency, not this stage's, and §2.1's cost model has no S_ACT
term — so neither moves for this cut, which is said here rather than left as a
silence.

---

## 6. Gates

Each can fail, and each names its ablation, in the style of
`pta_cpu_integration.md` §6.

**A0 — disabled is invisible.** `i_act_en = 0`: all 14 cases in
`sim/tb_core_verilator.cc` pass with C, `CYCLE_COUNT`, `OP_COUNT` and
`STALL_COUNT` identical to the staged core. *Ablation:* route a disabled GEMM
through S_ACT anyway; the cycle count must move.
*Met:* the harness's output is byte-identical to the same harness on the core
without S_ACT. The ablation is A1's cycle check, which sees the move.

**A1 — identity is exact.** `act_identity.hex`, noise off, `s = r = 1`,
requantisation off, unit scales: C bit-identical to the harness's `cref` at
every shape of the INT8 build, and `CYCLE_COUNT` equal to the A0 figure plus
`M · Nt · P` exactly, closed by `o_act_cycles`. The identity table is exact
below its top segment, `x < 2^23 - 2^14`, and an INT8 sum at `K = 256` reaches
at most 4,194,304, so no scaling is needed and none can hide an error. The
generator's self-test checks both facts. *Ablation:* move one breakpoint by one
LSB; the bench must name the element.
*Met* at all 14 shapes: C bit-identical, `CYCLE_COUNT` up by exactly
`M · Nt · 6` (384 at `M=64, N=8, K=256`, on 71,168 in this core-only harness),
`OP_COUNT` and `STALL_COUNT` unchanged, `o_act_cycles` equal to
`M · Σ(nc + 6)`. Enabling S_ACT with FP16 or BF16 raises `o_error` at start,
and the next valid start clears it. The ablation has a direction: the
interpolation floors, so one LSB *added* to an identity breakpoint is absorbed
by every input except one exactly on it, while one LSB *taken off* moves both
neighbouring segments. `--perturb` subtracts, and the bench names each moved
element with its sum.

**A2 — RTL and C agree bitwise.** A solver-derived curve with noise, detuning
and requantisation all on, fixed seed, every shape: a C reference added beside
`cref` matches `o_c_rdata` bit for bit. *Ablation:* change one xorshift shift in
the RTL; parity must fail on the first activated element.
*Met* at all 14 shapes on the compound 4 unit's second harmonic, power encoding:
every element moved off its sum, requantisation on alternate cases, constant σ
on three, and two cases run hot enough to saturate (7 and 14 events), their
counts equal to the model's. The ablation (shift 13 → 12) fails
10 of the 14 shapes. In the other four the changed noise never reaches C: 6-bit
requantisation, or the flat foot of a second-harmonic power curve, absorbs it —
so "the first activated element" is too strong a promise for this operating
point, and the gate is per shape.

**A3 — the measurement, reported rather than gated.** A `--chain` mode in the
harness runs L layers, feeding each activated C back as the next layer's A
through a fixed shift, with requantisation every N layers. Sweep
`N ∈ {1, 2, 4, 8, ∞}` × photons at the knee `10³ … 10⁶` × width σ
`∈ {0, 7, 14} nm` × curve shape, and report divergence from the noiseless
digital chain against depth. The shape axis is short, because κ drops out of it:
loss × length, output (ff or sh), and encoding. The four presets span only three
loss budgets. Synthetic weights come first, from the same xorshift stream, so
the mechanism is measured before any dataset is involved. The small MLP
`pta_cpu_integration.md` §9 asks for comes second. The output is the
N-versus-photons curve review §5.2 needs, and it is what the kill criterion in
review §6.2 is evaluated on.

---

## 7. Order

1. ~~**Land the interchange.**~~ **Done**, on main, with main reconciled first.
   Landing it also fixed two float bugs and a DMA abort bug; see the commits.
2. ~~**Table generator.**~~ **Done:** `c930/sim/act_table_gen.py`, standard
   library only. It ports the RK4 coupled-mode integrator from grxcp's
   `pta_tpaqcn_measured.py`, adding a complex path for phase mismatch, so the
   tables and the review's energy analysis share one set of physics. Its
   self-test checks the lossless closed form, power conservation under
   mismatch, the knees of all four presets against the review, identity
   exactness and determinism. `--all` writes every preset in both outputs and
   both encodings to `c930/build/act_tables/`, in eight seconds, byte-identical
   run to run. Each `.hex` is a `$readmemh` image; each `.json` records the
   design point, the knee, the interpolation error, and `i_act_k_shot` against
   photon count, with the error-over-σ check. `--compare-seg-bits` reproduces
   the segment-count evidence in §3.
3. ~~**RTL and C reference**, through gates A0, A1 and A2, in that order.~~
   **Done:** `rtl/c930_npu_act.sv`, the S_ACT state, and `--act identity` and
   `--act full` in `sim/tb_core_verilator.cc`.
4. **Chain mode**, A3.
5. **Only then** the CSR mapping, the snapshot bit and firmware.

---

## 8. Open questions

1. **Where does the noise enter?** Photon statistics apply to the light at every
   stage; this phase puts them at the unit's input. A pumped unit — the only kind
   with gain — adds noise at its output as well. Measure input-referred first,
   and add an output term only if A3 shows N is insensitive to the first.
2. **Power or amplitude?** Reading C as optical power, with negative sums clamped
   to zero, and reading it as field amplitude, `P = x²`, describe different
   networks. The generator decides; every A3 run records which.
3. **What is the transport rule between layers?** The harness maps C into the
   next A with a fixed shift at INT16. That rule has to be stated once and held
   fixed, or A3's depth axis mixes activation error with transport rounding.
4. **Does a scale model detuning well enough?** `f(s·x)/s` is exact for an
   efficiency change and wrong once `Δβ` reshapes the curve. The generator
   already emits a table per `Δβ` (`--dbeta`), and building one shows how soon
   that happens. With a mismatch, conversion rises and falls with power, so the
   knee is defined as the *first* half-conversion crossing. At `Δβ·L = 30 rad` a
   6 mm unit first converts half at 617 W, where a naive bisection had found a
   later crossing at 1146 W. That curve oscillates too fast for 1024 segments
   at the noise level it would carry, and the generator flags it. If A3 finds N
   sensitive to detuning, per-`Δβ` tables replace the scales, and strongly
   mismatched units need a narrower full scale.
