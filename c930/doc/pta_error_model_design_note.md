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
**And the seventh, the same day** (§5, at its end): a probe that reads a comb
line's level, `eval --levelprobe`, a row at full scale through a full-scale
weight. Left alone, lines 20% off cost the reference networks 0.35, 0.40 and
1.63 of a point and lines 40% off 2.01, 2.26 and 7.79. Read first with
sixteen shots a row, both cost what level lines do. The probe takes none of
the run's seeds, so the two rows of a pair meet the same noise.
**And the eighth, the same day** (§5, at its end): the reading applied where a
chip could apply it, `eval --levelfix`, and not taken off the model's own
line. On the weights a row at a time, written at 8 bits, lines 20% off end
within 0.11 of a point of level lines on all three sets. At the tile's 6
bits they end 0.07, 0.13 and 0.21 over. Scaled to the dimmest line, so that
nothing is raised past a rail, a correction costs 2.8 dB of light and on
Fashion-MNIST more than the comb did.
**And the ninth, 2026-10-09** (§5, at its end): grxcp moved its source's third
row to lines 20% off, read and corrected on the weights at 8 bits, and the
working point is run as the chip is now held. Held for six minutes the
reference networks lose 0.09 ± 0.03 of a point more on MNIST than with lines
5% off and left alone, and nothing that can be told on the other two sets. A
six-minute cycle with a source lit, which had been run on one draw and not
read over its own, ends 0.07, 0.04 and 0.30 over the probes-only row of its
draw. And `eval`'s trim step is a quarter of an 8-bit weight's LSB,
a sixteenth of a 6-bit code, which is two bits finer than the DAC grxcp's
calibration note asks for; at that DAC's step a cycle moves by 0.06 of a
point at the most.
**And the tenth, 2026-10-10** (§5, at its end): grxcp kept the weight DAC at 8
bits, and the cycle its interval rests on is run on that DAC, with a source
lit and without, at three minutes and at six, over ten draws. With no source
the reference networks' six-minute cycle ends 0.00, 0.04 and 0.15 of a point
over the probes-only row of its draw and a three-minute one 0.00, 0.03 and
0.11: on the inverted set neither holds a tenth, where at the finer step
three minutes did. With the source lit six minutes ends 0.05, 0.12 and 0.32
over and three 0.06, 0.07 and 0.27. Six minutes over three is clear nowhere
for them.
**And the eleventh, the same day** (§5, at its end): grxcp kept its interval
at six minutes, and the source's rows are run apart on the chip as it is
held. On the inverted set about half of what the source adds at the end of a
cycle is there with no noise at all: a comb 20% off, read and corrected,
adds 0.08 ± 0.04 of the 0.15. Of the noise, a line's own is the part that
shows: at 2% for its 5% it buys the reference networks 0.02, 0.06 and 0.06
of a point, none of them clear, and at 1% 0.04, 0.08 and 0.05, all of them
clear.
**And the twelfth, the same day** (§5, at its end): what a corrected comb
leaves is told apart. `eval --levelpart` leaves the tile the network as it
was and adds to its sums, after the converter, the parts asked for of what
the rewritten weights would be off by: what the reading missed, what writing
a weight at 8 bits dropped, and what a weight at the rail could not be
raised by. On the inverted set it is the rail in the first layer: 0.07 ±
0.02 of a point for the reference networks, on every network and on every
draw, from 31 of that layer's 65,000 weights. The read and the round leave
nothing there. All three at once leave 0.04 ± 0.03, half of the 0.08 ± 0.04
the comb has when it is corrected on the tile, and neither is clear.
**And the thirteenth, 2026-10-13** (§5, at its end): the last layer of the
first board's classifier. grxcp's B18 made the first development board the
GRXGPU charter's, whose first demonstration runs a 64-64-64-16 classifier with
its last layer on the PTA. It holds that layer to a raw error against a
reference in its declared format, and the chain to that reference's class.
`eval --host N` runs a network's first layers on the host, exactly, and `--gate
1` measures the last against that reference. The network's shape is a build's.
A stand-in for the classifier, ours and not grxgpu's, was trained on the three
data sets pooled to 8 × 8. As budgeted the tile is off its declared format by
1.43 to 1.83 steps of its converter, rms: 4.2 to 4.8% of the reference's rms
and 1.3 to 1.7% of the largest the reference is. Its largest error of 16,000
outputs is 7.2 to 8.4% of that largest, and is within the demonstration's 2.0%
in no run. For the reference networks it gives its declared reference's class
on 99.49, 96.85 and 99.10% of the first thousand images: at the demonstration's
99.5% on MNIST, where 13 runs of 25 pass, and under it on the other two.
**And the fourteenth, the same day** (§5, at its end): the same layer with a
range that clips nothing. `eval --gatefit F` sets the last layer's converter
range from its declared reference on the images that are run, where every other
run has it from training images, by a rule written for the class. Fitted, no
sum is past the range in any run, with the noise or without it. The format
alone is then within half a step of its reference everywhere, and within the
demonstration's 2.0% in every run. As budgeted the largest error is the noise's
alone: 7.2 to 8.4% of the largest the reference is, and 9.7% at the most where
it was 24.1%. It is still within 2.0% in no run. Fitting moves five networks of
thirty by a bit, and costs each a fifth more rms error. A bit of range to spare
costs every network a quarter more again, and the reference networks 0.10, 0.94
and 0.17 of a point. And the same tile then reads better as a share of its
converter's full scale: 20, 45 and 150 runs of 150 within 1.0%, as the range
grows.
**And the fifteenth, the same day** (§5, at its end): the same layer with a
converter of one more bit, which is the other way to buy a range that clips
nothing. `eval --gatebits B` gives the last layer's converter B bits at the
step it has. With nine at the step training's rule gives, no sum is past the
range in any of 600 runs, where 70 were; nothing is fitted, and no golden
manifest is read. And the error is the one it had: 530 of the 600 runs are
their run with eight bits, figure for figure, and the five networks whose range
clipped have 0.995 to 1.000 times the rms error they had, where fitted with
eight bits they have 1.20 to 1.24 times. The largest error is then the noise's,
7.2 to 8.4% of the largest the reference is and 9.7% at the most, and the class
is what it was. Spent on finer steps over the fitted range instead, the bit
halves the rounding and leaves the noise: 0.97 to 0.99 times the error of eight
bits fitted. grxcp prices the bit: 4.2 to 10.8 mW a converter where eight is
4.2 to 5.3.
**And the sixteenth, the same day** (§5, at its end): the same layer with a
light source switched on. The harness would not light a tile that had only some
of a network's layers; it now does, and a source lights the tile's layers
alone. With the source as grxcp holds it, 1% rms a shot for the lines together,
5% for a line on its own and lines 20% off that are read and corrected on the
weights, the reference networks' last layer is 5.18, 5.34 and 5.27% of the
reference's rms off its declared format, where with no source it was 4.46, 4.67
and 4.18%: a seventh more, in the mean of thirty networks. Its largest error
grows by more, and the class is the declared reference's on 99.44, 96.45 and
98.89% where it was on 99.59, 96.78 and 99.23%. The dear row is the lines'
level. Left alone it adds 5.7 to 7.7% in squares. Read, it still adds as much
as a line's own noise, because the rail holds back 1 to 11% of the weights a
dim line needs raised. And what that leaves is not noise: the source by itself
is further off than what it adds to the tile.
**And the seventeenth, the same day** (§5, at its end): that layer's budget a
row at a time. Four sections had moved its error by a quarter at the most and
none had said what it is made of. With no source, of version 2's four rows the
crosstalk alone adds 3.45, 3.26 and 3.01% of the reference's rms to the format,
in squares, and the shot noise 2.56, 2.99 and 2.61; the receiver's noise and
the programming error add 0.61, 0.89 and 0.66 and 0.61, 0.49 and 0.67. The two
large rows are 89 to 93% of the tile's squared error, and the rows add in
squares. But the class is the shot noise's: left out of the tile it gives the
declared reference's class on 0.15, 1.02 and 0.29 of a point more images, where
the crosstalk left out gives 0.01, 0.03 and 0.05. Most of the crosstalk is a
gain on every output, +0.0220 to +0.0281, which a class does not see. A source
read and corrected on the weights takes gain off, and that is what the section
before found and could not name: on two of the three sets the lit tile is
nearer its reference with the crosstalk than without. And against the
demonstration's 1.0% the format alone, an 8-bit converter with no row of the
budget, is already 0.71, 1.04 and 0.76% of the reference's rms off.
**And the eighteenth, 2026-10-14** (§5, at its end): that layer with one scale
on its outputs. The section before found most of the crosstalk to be a gain on
every output, and could not say what one constant would buy at the
demonstration's gate. `eval --gatescale M` now fixes one scale at calibration,
the least-squares slope of the declared reference on the tile's outputs over M
images the network was not trained on, and gives the gate's figures again with
the outputs times it. Fixed on a thousand, the scale is 0.967 to 0.974 wherever
the crosstalk is, and within 0.0011 of one where it is not. It takes the tile
as budgeted from 4.46, 4.67 and 4.18 to 3.13, 3.46 and 3.14% of the reference's
rms, about half its squared error, and the crosstalk alone from 3.52, 3.42 and
3.10 to 1.65, 1.58 and 1.55%. It is within 0.0016 of the scale the test images
would fit themselves, in every run with no source. Lit, it buys 0.34, 0.18 and
0.13 of a point: the source had already taken gain off. It moves no class, and
it brings no run within the demonstration's 1.0%.
**And the nineteenth, the same day** (§5, at its end): the first board's
canary, trained and run. grxcp's B20 fixed it: MNIST pooled to 8 × 8, its first
two layers the host's at eight bits and trained with no tile noise, its last
trained for the tile at six, and seed 1's network the canary, by a rule its
owner made before any network was trained. `train --host N` now trains such a
network. Five were trained and each run as the section before ran the reference
networks. At the gate the canary is the stand-in: as budgeted its five are
4.47% of the reference's rms off, where the stand-in's are 4.46, and no
difference of error is clear in any row. The canary itself is 4.61% on the
gate's thousand as budgeted and 5.09% lit and fitted, and gives its declared
reference's class on 99.74 and 99.42% of it. What the recipe gives up is a
tenth of a point of accuracy on 10,000 images.
**And the twentieth, the same day** (§5, at its end): the first board's canary,
its golden tensors. Its owner ruled that FC3's declared reference is the 8-bit
converter's codes, and that one output scale, fixed at calibration on a set of
its own, may be applied. `pta_mnist golden` writes the canary's integer
weights, its 1,000 acceptance vectors and 1,000 calibration vectors, each
stage's output in the declared format, FC3's codes and classes, and a
double-precision pass. Written twice they are the same byte for byte; the tile
with its format alone gives every code, and no code is held at the range. grxcp
holds them with a candidate manifest and a checker written apart from this
harness.
**And the twenty-first, 2026-10-15** (§5, at its end): the first board's
canary, its band. `eval --gateref codes` holds the last layer to its
converter's codes, the reference the owner ruled, and the format alone is then
its reference exactly. `band` runs the canary on 1,000 draws a row: its budget
dark and lit, lit at 0.4 to 1.4 times every row of the budget, and lit on ten
sources a hundred times each. Lit at its budget, with the scale, the canary is
4.04 to 7.21% of the reference's rms off; on one source the figure moves 0.043
points from repeat to repeat, and from source to source 0.497. grxcp proposed,
by a rule written before the sweep, and the owner ruled a band of 2.5 to 7.3%,
a class of 98.5% and a tail of at most 16 outputs 17 or more codes off. A tile
at 1.2 times its budget still passes on 92% of draws.
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
*Since 2026-10-08 there is a fourth option, `--levelprobe P`, which reads
each line's level before the first image and takes it off: §5, at its end.
And `--levelfix` and `--levelref`, which say where: off the model's own line,
or on the weights or the inputs as a host would scale them.*
*And since 2026-10-10 `--levelpart` and `--levellayer`, which tell apart what
a correction on the weights leaves: §5, at its end.*

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
*A probe with weights in it was built on 2026-10-08: §5, at its end, "A
line's level, and a probe that reads it".*

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

### A line's level, and a probe that reads it

*Added 2026-10-08.* `sim/pta_mnist.sh DIR WORK reflevel`, and `pta_mnist eval
--levelprobe P`. Reported, not gated.

**Why.** "What may the light do?" found that a comb line's level is a weight
error the cell calibration cannot see: that probe reads each cell through a
weight of zero, which a line's power multiplies. It said the level would have
to be levelled by something else or read by a probe with weights in it.
grxcp's plan asks for lines level to 5%, 0.2 dB, and records that nothing
measures them. This is the probe with weights in it.

**The probe.** `eval --levelprobe P`, after the light is set up and before the
first image. Two patterns: the rows of one parity at a full-scale weight on
every column and the rest at zero, then the other parity. Under each, one row
a shot at full scale, P shots a row. A lit row's neighbours hold a weight of
zero, so crosstalk brings it nothing. A shot's sum over what was asked for is
one plus its line's error: its level, and the source's noise that shot. A
line lights a row on every bus, so a line's reading is the mean over its
rows, the shots and every column. What is read is taken off the line's
level, to a step of 1/256. A run prints `levelprobe`, `level_found` and
`level_left`, the lines' rms before and after, and only when the option is
given: every line printed without it is what it was.

Three things about how it is built.

- **It draws from a seed of its own** and takes none of the run's GEMM seeds.
  So a run meets the same noise with the probe and without it, and the two
  can be read against each other. The cell calibration is not built that way,
  which is what the section before the last one found the hard way. Checked
  by hand: with a source so still that there is nothing to read, the line a
  probed run prints is the unprobed run's but for the probe's three fields.
- **It leaves the tile as it found it.** It writes no trim and ages nothing.
  With drift on, its shots are counted on the drift clock as any shot is, P
  times the tile's rows of them, against a step of 2^31.
- **It is on the host's side of the line, as the light's term is.** The
  light's share of a probe shot is added after the converter, as it is in an
  evaluation, and what is read is taken off the model's own record of the
  line. §4 is untouched and so are PTM-C and the RTL: the engine has no such
  mode.

The self-test holds four things: that with a still source, and crosstalk on,
the light's share of every row's sum as `light_add()` has it is within half a
step once the probe has run; that with a line's own noise on, what is left is
that noise over the root of the shots a line gets, and is a line's own and
not one error on them all; that level lines are left level and a light
through an offset is refused; and that a GEMM gives the same sums before the
probe and after it on a tile that has drifted. 16 errors planted in the probe's code
one at a time each stop it. As first written it passed three of those: it
checked the probe's own record and not the term an evaluation uses, it took
its tolerance from the step it was checking, and it could not tell one error
on every line from an error a line. It was tightened until none passed. One
change that would be an error on a chip is none here and is not among them: a
shot credited to another line, the line it then draws its light from. In
this model a row's light is its line's and nothing else of the row's.

**What it runs.** The seventh mode on the reference networks. Version 2 on the
128 × 64 tile on two buses, thirteen rows on each of three draws. As
budgeted. Lit, with the source's noise at grxcp's two rows, 1% for the lines
together and 5% for a line on its own, and the lines level, or 5%, 20% or 40%
rms off, each as it is and each read first with sixteen shots a row. The
lines 20% off read with one shot a row and with sixty-four. And held as grxcp
holds the chip, six minutes of TFLT's drift and the source's three rows at
1%, 5% and 5%, as it is and read first. A lit row is read over the level row
of its draw, and the level row and the two held rows over the as-budgeted
row of their draw. The networks trained before run beside the reference row
for row. That is 390 evaluations a data set, and 1.8 hours for the three side
by side on four jobs each.

The mode checks every network and every run against its place, as the six
before it do: a run's name says its draw, whether it is lit, how far from
level its lines are, whether they were read and with how many shots a row,
and whether it drifted, and those have to be what it was asked and what its
line printed. A row that was read also has to have found what its name says
is there. 157 more errors planted one at a time each fail: 94 in a training's
line or a run's, after the fact; 31 in the script; and 32 in the tables' own code,
which the check does not see and which each move the tables. The
planted-error runs take two draws and not three.

Of the lines, 60 on each data set are byte for byte what `refdraws` wrote for
the same runs: the as-budgeted row and the held row of draws 0 to 2. The
sweep ran on the build before the self-test was tightened. Six of its lines,
two a data set, run again on the build that is committed are byte for byte
the same.

**What came of it.** What a row adds over the row it is read over: the mean
of three draws, with its standard error from the five networks, each averaged
over its draws. In bold, what five networks put outside chance at one in
twenty.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| The level row, over the as-budgeted row of its draw | +0.049 ± 0.019 | **+0.031 ± 0.008** | **+0.161 ± 0.037** | +0.014 ± 0.036 | **+0.229 ± 0.044** | +0.056 ± 0.031 |
| Lines 5% off, over the level row of its draw | −0.011 ± 0.033 | +0.002 ± 0.008 | −0.036 ± 0.047 | −0.039 ± 0.035 | +0.097 ± 0.114 | +0.157 ± 0.076 |
| read first, sixteen shots a row | +0.011 ± 0.006 | **−0.021 ± 0.004** | −0.024 ± 0.015 | −0.002 ± 0.015 | +0.043 ± 0.025 | +0.006 ± 0.009 |
| Lines 20% off | **+0.411 ± 0.047** | **+0.347 ± 0.012** | **+0.615 ± 0.159** | **+0.395 ± 0.134** | **+1.689 ± 0.383** | **+1.631 ± 0.538** |
| read first | +0.003 ± 0.005 | **−0.021 ± 0.004** | −0.015 ± 0.016 | +0.005 ± 0.017 | +0.050 ± 0.034 | −0.007 ± 0.007 |
| Lines 40% off | **+2.431 ± 0.192** | **+2.006 ± 0.072** | **+3.189 ± 0.754** | **+2.265 ± 0.448** | **+8.380 ± 1.159** | **+7.791 ± 2.261** |
| read first | +0.010 ± 0.006 | **−0.021 ± 0.002** | −0.027 ± 0.015 | +0.002 ± 0.011 | +0.053 ± 0.028 | −0.002 ± 0.008 |
| Level lines, read | +0.007 ± 0.005 | **−0.020 ± 0.003** | −0.025 ± 0.015 | −0.003 ± 0.014 | +0.043 ± 0.029 | +0.003 ± 0.009 |
| Lines 20% off, read with one shot a row | **+0.023 ± 0.006** | −0.000 ± 0.017 | −0.032 ± 0.044 | +0.053 ± 0.050 | +0.149 ± 0.108 | +0.051 ± 0.024 |
| read with sixty-four | +0.011 ± 0.007 | −0.002 ± 0.005 | −0.003 ± 0.011 | **+0.016 ± 0.005** | +0.017 ± 0.010 | −0.007 ± 0.013 |
| Held, over the as-budgeted row of its draw | +0.069 ± 0.031 | +0.012 ± 0.015 | +0.175 ± 0.107 | +0.043 ± 0.072 | **+0.530 ± 0.172** | **+0.280 ± 0.066** |
| held, and read first | +0.063 ± 0.029 | +0.010 ± 0.026 | **+0.207 ± 0.073** | +0.050 ± 0.040 | **+0.543 ± 0.141** | **+0.103 ± 0.028** |

What a read buys: a read row less the row it was read from.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Level lines, read | −0.007 ± 0.005 | **+0.020 ± 0.003** | +0.025 ± 0.015 | +0.003 ± 0.014 | −0.043 ± 0.029 | −0.003 ± 0.009 |
| Lines 5% off, read | −0.022 ± 0.039 | **+0.023 ± 0.008** | −0.012 ± 0.058 | −0.037 ± 0.022 | +0.054 ± 0.115 | +0.151 ± 0.074 |
| Lines 20% off, read | **+0.408 ± 0.049** | **+0.367 ± 0.013** | **+0.630 ± 0.167** | **+0.390 ± 0.127** | **+1.639 ± 0.368** | **+1.639 ± 0.541** |
| Lines 40% off, read | **+2.421 ± 0.191** | **+2.027 ± 0.070** | **+3.216 ± 0.763** | **+2.263 ± 0.442** | **+8.327 ± 1.151** | **+7.793 ± 2.268** |
| Lines 20% off, read with one shot a row | **+0.389 ± 0.050** | **+0.347 ± 0.012** | **+0.647 ± 0.147** | +0.342 ± 0.141 | **+1.540 ± 0.354** | **+1.580 ± 0.548** |
| read with sixty-four | **+0.400 ± 0.049** | **+0.349 ± 0.012** | **+0.619 ± 0.164** | **+0.379 ± 0.134** | **+1.672 ± 0.378** | **+1.638 ± 0.531** |
| Held, and read | +0.006 ± 0.012 | +0.002 ± 0.026 | −0.031 ± 0.048 | −0.007 ± 0.047 | −0.013 ± 0.112 | +0.177 ± 0.090 |

The lines themselves. They are the tile's and the seed's, and the same for
both kinds of network and all three data sets.

| | Found, rms | Left, rms | Should leave, by count |
|---|---|---|---|
| Level lines, read | 0.00% | 0.91% | 0.91% |
| Lines 5% off, read | 5.02% | 0.92% | 0.91% |
| Lines 20% off, read | 20.08% | 0.91% | 0.91% |
| Lines 40% off, read | 40.17% | 0.92% | 0.91% |
| Lines 20% off, read with one shot a row | 20.08% | 3.61% | 3.61% |
| read with sixty-four | 20.08% | 0.45% | 0.46% |
| Held, and read | 5.02% | 0.92% | 0.91% |

**Left alone, a comb that is not level costs more than the tile does.** With
lines 20% off the reference networks lose 0.35 ± 0.01, 0.40 ± 0.13 and 1.63 ±
0.54 of a point more than with level lines, and with lines 40% off 2.01 ±
0.07, 2.26 ± 0.45 and 7.79 ± 2.26. The tile as budgeted costs them 0.13, 0.50
and 0.48 on these draws. Twice as far from level costs 5.8, 5.7 and 4.8 times
as much. One comb at 40% costs one reference network 22.4 points on the
inverted set, and one old network 16.0. Training for the tile's noise buys
little against it: seed by seed, lines 20% off cost a reference network −0.06
± 0.05, −0.22 ± 0.17 and −0.06 ± 0.62 against the old one, none of them clear.

**At 5% it costs nothing that can be told on two sets, and may cost on the
third.** 0.00 ± 0.01, −0.04 ± 0.04 and 0.16 ± 0.08 for the reference networks,
and −0.01 ± 0.03, −0.04 ± 0.05 and 0.10 ± 0.11 for the old ones. None of the
six is clear.

**Read first, a comb costs nothing that can be seen, however far off it
was.** At 5%, 20% and 40% alike the reference networks end within 0.03 of a
point of level lines on every set, and the old ones within 0.06. The read
buys what the comb cost: 0.37, 0.39 and 1.64 at 20%, and 2.03, 2.26 and 7.79
at 40%.

**What the probe leaves is the source's noise over its shots, and not the
comb.** Sixteen shots a row leave 0.91% to 0.92% whatever was there, and on
any one comb 0.79% to 1.05%. Counted, they should leave 0.91%: a shot's noise
of 5.1% over the root of 32, and the rounding of the step. One shot a row
leaves 3.61% for a count of 3.61%, and sixty-four 0.45% for 0.46%. By that
count 14 shots a row leave a line within 1%.

**One shot a row already takes back nearly all of it.** With lines 20% off and
read with one shot the reference networks end 0.00 ± 0.02, 0.05 ± 0.05 and
0.05 ± 0.02 over level lines, and the old ones 0.02 ± 0.01, −0.03 ± 0.04 and
0.15 ± 0.11.

**Held, the read buys nothing on two sets and may buy on the third.** Holding
adds 0.01 ± 0.02, 0.04 ± 0.07 and 0.28 ± 0.07 to what the reference networks
lose as budgeted, and 0.01 ± 0.03, 0.05 ± 0.04 and 0.10 ± 0.03 with the lines
read first. On the inverted set the read buys 0.18 ± 0.09, which is 2.0 of
its errors and not clear. It buys the old networks nothing on any set.

**A read costs level lines nothing, and one cell says otherwise.** With lines
that are level already, the six cells are within 0.05 of a point read or
not. One is clear by five networks' rule: the reference networks on MNIST
are right 0.020 ± 0.003 more often read, which is two images in ten thousand.
It should not be there. What sixteen shots leave on a comb is centred on
nothing: on a scratch build that prints it, the mean over a comb's 64 lines
is 0.007% over the mode's fifteen combs, and never over 0.11% on one. So the
two rows were run by hand on seven more draws, MNIST and the reference
networks only: −0.011 ± 0.006, the other way, and over all ten −0.002 ± 0.004.
Of the 36 read rows set beside level lines, 6 are clear by that rule, none by
more than 0.03 of a point, and they go both ways. Four of the six are that
one cell seen four times: the sixteen-shot rows of a network on a draw take
the same probe draws whatever the lines' level, and what is left on them is
the same to 0.07%. That is the rule misfiring on differences of an image or
two, where five networks happen to agree, as the section before the last
found of it.

**What was predicted.** Written before the probe was written or anything was
run for it, on 2026-10-08. Five things.

1. That left alone, lines 20% off cost the reference networks 0.1 to 0.6 of a
   point on MNIST, 0.2 to 1.2 on Fashion-MNIST and 0.8 to 4 on the inverted
   set, and lines 40% off 0.6 to 3, 1 to 6 and 4 to 15. Right on all six, in
   bands that wide: 0.35, 0.40 and 1.63, and 2.01, 2.26 and 7.79.
2. That read with sixteen shots a row they are within 0.05, 0.08 and 0.10 of
   level lines on the three sets, at 5%, 20% and 40% alike. Right: within
   0.03 on every set.
3. That what the probe leaves is 0.8% to 1.1% whatever was there. Right:
   0.91% to 0.92%.
4. That at 5% the read buys nothing that can be seen on MNIST and
   Fashion-MNIST, within 0.04, and 0.00 to 0.20 on the inverted set. Right:
   0.02, −0.04 and 0.15.
5. That held, the read moves the reference networks by less than 0.05 on
   MNIST and 0.08 on Fashion-MNIST, and buys 0.00 to 0.20 on the inverted
   set. Right: 0.00, −0.01 and 0.18.

Not predicted: that one shot a row would be enough, or that one comb could
cost one network 22 points.

**What this is not.** A correction that is built. What the probe reads is
taken off the line's level in the model, exactly, to its step. Where a chip
would apply it is not modelled: on the weights as they are written, on a
row's drive, or on a row's inputs at the host, and each would cost something
this does not count. It is first order, as the light's own term is, and a line's
light does not pass the converter. A line 40% rms off is a Gaussian here,
which puts one line in 160 at less than no light: that row is a stress and
not a comb. The three levels are one comb scaled, and not three combs. The
levels are fixed for a run. An error that scales a row and is not its line's
would read the same. Three draws of five networks. Version 1, or another
tile.

### A line's level, corrected where a chip could

*Added 2026-10-08.* `sim/pta_mnist.sh DIR WORK reffix`, and `pta_mnist eval
--levelfix weights|weights8|inputs --levelref dimmest`. Reported, not gated.

**Why.** The section before this one read a comb's lines and took what it
read off the model's own record of each line, exactly. No chip can do that.
grxcp named three places one could apply a reading and what each would cost,
by reasoning, and asked for the correction to be modelled where a chip can
apply it, the weights as written first: do their 6 bits eat the gain?

**The corrections.** With `--levelfix` the level probe keeps its reading and
leaves the model's lines as they are, and the reading r of a row's line is
applied to the row at the host:

| `--levelfix` | What the host does | What then quantises it |
|---|---|---|
| `ideal` | Nothing: the reading is taken off the model's line, as before | |
| `weights` | Writes every weight of the row as w / (1 + r) | The tile, to its 6 bits, as any weight |
| `weights8` | Takes the 6-bit weights the network was trained for, scales those, and writes them at the operand's 8 bits | Nothing more: the tile runs at 8-bit weights |
| `inputs` | Sends every input of the row as a / (1 + r) | The tile, to its 6 bits, as any input |

A dim line's row has to be raised, and a weight or an input at the rail
cannot be. `--levelref none` holds it at the rail, and that much is left
uncorrected. `--levelref dimmest` scales every row down to the dimmest
line's, so that nothing is raised, and divides every sum by what that took
off. The converter's range and the receiver's noise are left where they
were, so the light that is lost is lost. A run prints `levelfix`, `levelref`,
`level_gain`, which is what was left of every sum, and `level_clip`, the
share of what it scaled, of what was not zero, that it raised and a rail
held back. A line read at under a twentieth of its level is refused.

Like the probe, it is on the host's side of the line: §4, PTM-C and the RTL
are untouched, and a line printed without the option is what it was. No
correction takes a seed of the run's.

The self-test puts a random network on the working tile under a still source
with its lines 8% off. Left alone a layer's sums are 8% and 10% off. With the
tile unquantised every correction leaves the rounding of one operand, under
1.4%, on both layers; scaled to the dimmest line the sums come back as they
were and nothing is held at a rail. With the tile at 6 bits, the weights
written at 8 leave 0.6% and the weights left to the tile's 6 leave 3.0%,
which is the count below. Inputs at full scale, and weights at the rail, are
half of them held and their rows left as they were, and levelled when scaled
to the dimmest. A line at 3% of its level is refused, and so is a reading
that was not kept. A rewritten network keeps its biases and its rescale. And
the rail is the contract's quantiser's. 32 errors planted in that code one at
a time each stop it. Over two passes it had passed four: a reading that was
not kept, a weight past the rail, and a value held a unit out of range, for
each of which a check was added; and a scale set where nothing read it, which
was taken out. All of that was before the sweep.

**The 6-bit grid, counted.** A 6-bit code is 4 LSB of an 8-bit weight. A
weight that should move by d LSB, rounded to a code again, stays where it
was with probability 1 − d/4 and is left d off, or goes to the next code and
is left 4 − d off the other way: a mean square of 4d − d². That is more than
the d² it started with when d is under 2, half a code. So a correction on
6-bit weights makes a weight worse unless the line is off by enough to move
it half a code, and past a whole code it leaves a fresh rounding against the
one the network was trained with, 1.63 LSB rms. Seed 1's reference networks
have first-layer weights of 24.4, 23.8 and 14.9 LSB rms, by hand: a line 5%
off moves 10%, 9% and 3% of them half a code, and 1.63 LSB is what lines 7%,
7% and 11% off would do. Written at 8 bits a weight is left 0.29 LSB.

**What it runs.** The eighth mode on the reference networks. Version 2 on the
128 × 64 tile on two buses, twenty rows on each of three draws, which are the
section before's draws and its rows again where the two share them. As
budgeted. Lit with level lines. Lines 5% and 20% off: left alone; read, with
the reading taken off the model's line; and corrected five ways, on the
weights at the tile's bits, at 8 bits, at 8 bits to the dimmest, on the
inputs, and on the inputs to the dimmest. And held as grxcp holds the chip:
left alone, read, on the weights at 8 bits, and on the inputs to the
dimmest. Lines 40% off are not run: a Gaussian comb that uneven has lines at
no light, which nothing scales back. A lit row is read over the level row of
its draw, and the level row and the held rows over the as-budgeted row of
their draw. The networks trained before run beside the reference row for
row. That is 600 evaluations a data set, and 2.3 to 2.4 hours for the three
side by side on four jobs each.

The mode checks every network and every run against its place, as the seven
before it do: a run's name says its draw, whether it is lit, how far from
level its lines are, whether they were read, where the reading was applied
and whether to the dimmest line, and whether it drifted. A run corrected at
8 bits has to have run the tile at 8-bit weights, and no other may. One
scaled to the dimmest has to have taken something off its sums and held
nothing at a rail, and one that was not has to have taken nothing off.
198 more errors planted one at a time each fail: 119 in a training's
line or a run's, after the fact; 42 in the script; and 37 in the tables' own code,
which the check does not see. Of those, 36 move the tables, and one stops the
script on a row there is none of. The planted-error runs take two draws and
not three.

Of the lines, 240 on each data set are byte for byte what `reflevel` wrote
for the same runs: its eight rows that this mode has too, on all three draws.

**What came of it.** What a row adds over the row it is read over: the mean
of three draws, with its standard error from the five networks, each averaged
over its draws. In bold, what five networks put outside chance at one in
twenty.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| The level row, over the as-budgeted row of its draw | +0.049 ± 0.019 | **+0.031 ± 0.008** | **+0.161 ± 0.037** | +0.014 ± 0.036 | **+0.229 ± 0.044** | +0.056 ± 0.031 |
| Lines 5% off, over the level row of its draw | −0.011 ± 0.033 | +0.002 ± 0.008 | −0.036 ± 0.047 | −0.039 ± 0.035 | +0.097 ± 0.114 | +0.157 ± 0.076 |
| read, and taken off the model's own line | +0.011 ± 0.006 | **−0.021 ± 0.004** | −0.024 ± 0.015 | −0.002 ± 0.015 | +0.043 ± 0.025 | +0.006 ± 0.009 |
| on the weights, at the tile's 6 bits | +0.005 ± 0.019 | +0.004 ± 0.015 | −0.062 ± 0.070 | +0.064 ± 0.027 | +0.161 ± 0.129 | +0.067 ± 0.062 |
| on the weights, at 8 bits | −0.006 ± 0.009 | **−0.015 ± 0.005** | −0.032 ± 0.035 | +0.051 ± 0.032 | +0.009 ± 0.059 | +0.035 ± 0.025 |
| on the weights at 8 bits, to the dimmest | +0.020 ± 0.019 | +0.003 ± 0.018 | +0.074 ± 0.057 | **+0.101 ± 0.036** | **+0.159 ± 0.045** | **+0.151 ± 0.020** |
| on the inputs | +0.003 ± 0.012 | −0.018 ± 0.008 | −0.066 ± 0.055 | +0.057 ± 0.036 | −0.033 ± 0.028 | +0.082 ± 0.030 |
| on the inputs, to the dimmest | +0.013 ± 0.017 | **+0.078 ± 0.010** | +0.023 ± 0.035 | +0.064 ± 0.058 | −0.033 ± 0.043 | +0.009 ± 0.023 |
| Lines 20% off | **+0.411 ± 0.047** | **+0.347 ± 0.012** | **+0.615 ± 0.159** | **+0.395 ± 0.134** | **+1.689 ± 0.383** | **+1.631 ± 0.538** |
| read, and taken off the model's own line | +0.003 ± 0.005 | **−0.021 ± 0.004** | −0.015 ± 0.016 | +0.005 ± 0.017 | +0.050 ± 0.034 | −0.007 ± 0.007 |
| on the weights, at the tile's 6 bits | +0.045 ± 0.041 | **+0.066 ± 0.019** | −0.133 ± 0.078 | +0.135 ± 0.061 | +0.032 ± 0.202 | +0.209 ± 0.141 |
| on the weights, at 8 bits | +0.034 ± 0.030 | **+0.049 ± 0.017** | −0.034 ± 0.018 | +0.024 ± 0.034 | **+0.090 ± 0.028** | +0.104 ± 0.040 |
| on the weights at 8 bits, to the dimmest | **+0.273 ± 0.045** | **+0.132 ± 0.040** | **+0.716 ± 0.097** | **+0.648 ± 0.082** | **+0.888 ± 0.166** | **+0.746 ± 0.094** |
| on the inputs | +0.078 ± 0.028 | +0.032 ± 0.017 | +0.057 ± 0.072 | +0.095 ± 0.037 | +0.271 ± 0.130 | **+0.436 ± 0.142** |
| on the inputs, to the dimmest | **+0.325 ± 0.073** | **+0.245 ± 0.019** | **+0.869 ± 0.114** | **+0.803 ± 0.132** | **+0.842 ± 0.175** | **+0.688 ± 0.099** |
| Held, over the as-budgeted row of its draw | +0.069 ± 0.031 | +0.012 ± 0.015 | +0.175 ± 0.107 | +0.043 ± 0.072 | **+0.530 ± 0.172** | **+0.280 ± 0.066** |
| held: read, and taken off the model's own line | +0.063 ± 0.029 | +0.010 ± 0.026 | **+0.207 ± 0.073** | +0.050 ± 0.040 | **+0.543 ± 0.141** | **+0.103 ± 0.028** |
| held: on the weights, at 8 bits | +0.065 ± 0.033 | **+0.032 ± 0.009** | +0.149 ± 0.093 | +0.067 ± 0.053 | **+0.559 ± 0.177** | **+0.119 ± 0.021** |
| held: on the inputs, to the dimmest | +0.089 ± 0.033 | **+0.069 ± 0.012** | **+0.252 ± 0.076** | +0.071 ± 0.076 | **+0.544 ± 0.177** | **+0.154 ± 0.010** |

What a read or a correction buys: the row less the row left alone.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| read, and taken off the model's own line | −0.022 ± 0.039 | **+0.023 ± 0.008** | −0.012 ± 0.058 | −0.037 ± 0.022 | +0.054 ± 0.115 | +0.151 ± 0.074 |
| on the weights, at the tile's 6 bits | −0.016 ± 0.046 | −0.002 ± 0.012 | +0.026 ± 0.052 | **−0.103 ± 0.030** | −0.065 ± 0.080 | +0.090 ± 0.114 |
| on the weights, at 8 bits | −0.005 ± 0.041 | **+0.017 ± 0.006** | −0.004 ± 0.017 | −0.090 ± 0.035 | +0.088 ± 0.156 | +0.122 ± 0.101 |
| on the weights at 8 bits, to the dimmest | −0.031 ± 0.024 | −0.001 ± 0.023 | **−0.110 ± 0.038** | **−0.141 ± 0.045** | −0.062 ± 0.086 | +0.007 ± 0.078 |
| on the inputs | −0.015 ± 0.026 | +0.020 ± 0.010 | +0.030 ± 0.030 | −0.096 ± 0.035 | +0.129 ± 0.111 | +0.075 ± 0.050 |
| on the inputs, to the dimmest | −0.025 ± 0.048 | **−0.076 ± 0.009** | **−0.059 ± 0.017** | −0.103 ± 0.064 | +0.130 ± 0.118 | +0.149 ± 0.080 |
| read, and taken off the model's own line | **+0.408 ± 0.049** | **+0.367 ± 0.013** | **+0.630 ± 0.167** | **+0.390 ± 0.127** | **+1.639 ± 0.368** | **+1.639 ± 0.541** |
| on the weights, at the tile's 6 bits | **+0.367 ± 0.076** | **+0.281 ± 0.028** | **+0.749 ± 0.144** | +0.261 ± 0.116 | **+1.657 ± 0.342** | +1.423 ± 0.592 |
| on the weights, at 8 bits | **+0.377 ± 0.044** | **+0.297 ± 0.017** | **+0.649 ± 0.147** | **+0.371 ± 0.125** | **+1.599 ± 0.400** | **+1.527 ± 0.521** |
| on the weights at 8 bits, to the dimmest | +0.138 ± 0.059 | **+0.215 ± 0.051** | −0.101 ± 0.170 | −0.253 ± 0.137 | **+0.801 ± 0.251** | +0.885 ± 0.491 |
| on the inputs | **+0.333 ± 0.037** | **+0.315 ± 0.017** | **+0.559 ± 0.094** | +0.301 ± 0.126 | **+1.419 ± 0.362** | **+1.195 ± 0.404** |
| on the inputs, to the dimmest | +0.086 ± 0.074 | **+0.102 ± 0.012** | −0.254 ± 0.177 | −0.407 ± 0.165 | **+0.847 ± 0.270** | +0.943 ± 0.499 |
| held: read, and taken off the model's own line | +0.006 ± 0.012 | +0.002 ± 0.026 | −0.031 ± 0.048 | −0.007 ± 0.047 | −0.013 ± 0.112 | +0.177 ± 0.090 |
| held: on the weights, at 8 bits | +0.005 ± 0.013 | −0.020 ± 0.011 | +0.026 ± 0.028 | −0.025 ± 0.043 | −0.029 ± 0.155 | +0.161 ± 0.077 |
| held: on the inputs, to the dimmest | −0.019 ± 0.014 | −0.057 ± 0.021 | −0.077 ± 0.057 | −0.029 ± 0.048 | −0.014 ± 0.099 | +0.126 ± 0.074 |

What a correction did to the lines and to the sums. The first two columns
are the tile's and the seed's, and the same for both kinds of network and all
three data sets.

| | Left on the lines, rms | Of every sum, left | Held at a rail, the reference networks: MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|---|---|
| on the weights, at the tile's 6 bits | 0.93% | 1.0000 | 0.02% | 0.05% | 0.00% |
| on the weights, at 8 bits | 0.93% | 1.0000 | 0.03% | 0.07% | 0.01% |
| on the weights at 8 bits, to the dimmest | 0.93% | 0.8792 | 0.00% | 0.00% | 0.00% |
| on the inputs | 0.93% | 1.0000 | 16.16% | 2.62% | 39.61% |
| on the inputs, to the dimmest | 0.93% | 0.8792 | 0.00% | 0.00% | 0.00% |
| on the weights, at the tile's 6 bits | 0.98% | 1.0000 | 0.12% | 0.22% | 0.04% |
| on the weights, at 8 bits | 0.98% | 1.0000 | 0.14% | 0.25% | 0.05% |
| on the weights at 8 bits, to the dimmest | 0.98% | 0.5242 | 0.00% | 0.00% | 0.00% |
| on the inputs | 0.98% | 1.0000 | 20.52% | 11.57% | 42.84% |
| on the inputs, to the dimmest | 0.98% | 0.5242 | 0.00% | 0.00% | 0.00% |
| held: on the weights, at 8 bits | 0.93% | 1.0000 | 0.03% | 0.07% | 0.01% |
| held: on the inputs, to the dimmest | 0.93% | 0.8794 | 0.00% | 0.00% | 0.00% |

**Written at 8 bits, the weights take back nearly all a comb cost.** With
lines 20% off and left alone the reference networks lose 0.35 ± 0.01, 0.40 ±
0.13 and 1.63 ± 0.54 of a point to level lines. With the weights scaled and
written at 8 bits they end 0.05 ± 0.02, 0.02 ± 0.03 and 0.10 ± 0.04 over:
within 0.11 of a point on every set, at 20% and at 5% alike, and 86%, 94%
and 94% of what the comb cost. Against the model's own correction that
leaves 0.07 ± 0.02, 0.02 ± 0.03 and 0.11 ± 0.04. The rail holds 0.14%, 0.25%
and 0.05% of the weights back. Of the five it is the only one that ends at a
tenth or under on all three sets at 20%.

**At the tile's 6 bits the grid does not eat the gain at 20%, and at 5% there
is none to eat.** The scaled weights end 0.07 ± 0.02, 0.13 ± 0.06 and 0.21 ±
0.14 over level lines at 20%: 81%, 66% and 87% taken back. The two more bits
buy 0.02 ± 0.02, 0.11 ± 0.04 and 0.10 ± 0.13 on top of that, none of them
clear. At 5% the 6-bit correction buys 0.00, −0.10 ± 0.03 and 0.09 ± 0.11:
nothing, and on Fashion-MNIST a tenth lost, which is clear and which the
count above says to expect.

**Scaled to the dimmest line a correction pays in light, and on one set more
than it buys.** With lines 20% off the dimmest line leaves 0.52 of every
sum, 2.8 dB, and on a single comb 0.36 to 0.65. So scaled, the 8-bit weights
end 0.13 ± 0.04, 0.65 ± 0.08 and 0.75 ± 0.09 over level lines and the inputs
0.24 ± 0.02, 0.80 ± 0.13 and 0.69 ± 0.10. On Fashion-MNIST both are worse
than leaving the comb alone, by 0.25 ± 0.14 and 0.41 ± 0.16. Held at the rail
does better than scaled to the dimmest on every set, in either place. At 5%
the dimmest line leaves 0.88 of a sum, 0.6 dB.

**On the inputs, held at full scale, it works where few inputs are at full
scale.** At 20% it ends 0.03 ± 0.02, 0.09 ± 0.04 and 0.44 ± 0.14 over level
lines, with 21%, 12% and 43% of the inputs that are not zero held at the
rail. On the inverted set, where 80.8% of pixels are at full scale, it still
takes back 73% of what the comb cost.

**At 5% there is little to buy, and what is clear is mostly cost.** Of the
fifteen figures for what a place buys the reference networks there, four are
clear, and three of those are costs: the 6-bit weights and the 8-bit ones to
the dimmest on Fashion-MNIST, and the inputs to the dimmest on MNIST. The
one that buys is two images in ten thousand on MNIST, the same two the
section before found a read to buy there and seven more draws did not.

**Held, the weights at 8 bits buy what the model's own correction bought.**
0.16 ± 0.08 on the inverted set for the model's 0.18 ± 0.09, neither clear,
and −0.02 ± 0.01 and −0.02 ± 0.04 on the other two. So corrected, the held
tile ends 0.03, 0.07 and 0.12 over the tile as budgeted, where left alone it
ends 0.01, 0.04 and 0.28.

**For the networks trained before, the 6 bits do as well as the 8.** At 20%
they end 0.04 ± 0.04, −0.13 ± 0.08 and 0.03 ± 0.20 over level lines at the
tile's bits, and 0.03 ± 0.03, −0.03 ± 0.02 and 0.09 ± 0.03 at 8.

**A comb 20% off and corrected at 8 bits costs half a tenth more than a comb
5% off and left alone, on two sets.** Seed by seed, 0.05 ± 0.01, 0.06 ± 0.01
and −0.05 ± 0.06 more: clear on MNIST and Fashion-MNIST and not on the
inverted set. 5% is the row grxcp's plan asks of a comb.

**What was predicted.** Written before any correction was written, on
2026-10-08. Six things, and a seventh added after the corrections were
tried by hand on one network and before the mode was written.

1. That at the tile's 6 bits a correction buys nothing at 5%: within 0.05 of
   the row left alone on MNIST and Fashion-MNIST, and 0.05 to 0.30 over level
   lines on the inverted set. Right on MNIST and the inverted set, 0.00 and
   0.07. Wrong on Fashion-MNIST, where it is a tenth worse than the row left
   alone.
2. That at 20% it ends 0.02 to 0.15, 0.02 to 0.20 and 0.25 to 0.90 over level
   lines. Right on MNIST and Fashion-MNIST, 0.07 and 0.13. On the inverted
   set it does better than predicted, 0.21.
3. That at 8 bits it ends within 0.05, 0.08 and 0.10 of level lines at 5% and
   within 0.08, 0.12 and 0.20 at 20%. Right on all six: −0.02, 0.05 and 0.04,
   and 0.05, 0.02 and 0.10.
4. That on the inputs at 20% it ends 0.03 to 0.20 and 0.02 to 0.20 over on
   MNIST and Fashion-MNIST, and 0.5 to 1.3 on the inverted set with less than
   half taken back, since four pixels in five are at full scale there. Right
   on the first two, 0.03 and 0.09. Wrong on the inverted set: 0.44, and 73%
   taken back. And that at 5% it ends within 0.05 and 0.08 and 0.05 to 0.25
   over: right, −0.02, 0.06 and 0.08.
5. That scaled to the dimmest the inputs lose 0.85 to 0.92 of a sum at 5% and
   0.40 to 0.65 at 20%, and at 20% end 0.10 to 0.45, 0.3 to 1.2 and 0.2 to
   1.0 over: no better than leaving the lines alone on the first two sets,
   and better by half or more on the third. Right in every band: 0.88 and
   0.52 of a sum, and 0.24, 0.80 and 0.69. Right about Fashion-MNIST and the
   inverted set. Wrong about MNIST, where it buys a tenth.
6. That held, the weights at 8 bits move the reference networks by less than
   0.05 and 0.08 on MNIST and Fashion-MNIST and buy 0.00 to 0.25 on the
   inverted set, and the inputs to the dimmest cost 0.00 to 0.10 and 0.00 to
   0.25 and are within 0.15 on the third. Right: −0.02, −0.02 and 0.16, and
   costs of 0.06 and 0.03 and 0.13 bought.
7. That the 8-bit weights scaled to the dimmest cost what the inputs do so
   scaled, the light and not the grid: within 0.10, 0.10 and 0.25 of them at
   20%, and 0.05, 0.08 and 0.10 at 5%. Wrong on four of the six. At 20% the
   inputs end 0.11 ± 0.06, 0.15 ± 0.06 and −0.06 ± 0.03 over the weights, none
   of them clear.

Not predicted, and seen in the try by hand: that a second layer's large
weights on dim lines are what the rail holds, a few of a thousand.

**What this is not.** A chip: the scaling is at the host, in the harness.
Written at 8 bits the weights take the bits below the code that a trim would
use, and the two are not modelled together. The correction is to the
reading alone, and its error over what it scaled by is left. The source's
noise is a share of a line's nominal light here, so a dim row raised has its
noise raised with it. Scaled to the dimmest, a laser turned up to give the
light back is not modelled, nor a converter ranged again. A correction held
in the trim, a cell at a time, was not run: the tile holds one trim a cell
and a GEMM here is seven tiles of weights. Lines 40% off. Levels fixed for a
run. Three draws of five networks. Version 1, or another tile.

### The working point, with the source's third row moved

*Added 2026-10-09.* `sim/pta_mnist.sh DIR WORK refpoint`. Reported, not gated.
Nothing in `pta_mnist.c` changed for it.

**Why.** grxcp moved its source's third row that day. A comb's lines are now
level to 20% as they reach the tile, where the row had 5%; they are read at
each calibration; and every row's weights are scaled by what its line read
and written at 8 bits, which is the section before's `--levelfix weights8`.
Two things here then wanted running. Every row a mode calls held has its
lines 5% off and left alone. And a cycle was run with a source lit once:
`refcycle`'s held cycle, on its one draw, read as how often right and not
over the probes-only row of its draw, which `refcal` then found is how a
cycle has to be read. `refcal` and `refdraws` cycle a tile with no light. So
the working point grxcp quotes had not been run as the chip is now held, and
its cycle with a source on no more than one draw.

**What it runs.** The ninth mode on the reference networks. Version 2 on the
128 × 64 tile on two buses, ten rows on each of five draws, which are
`refdraws`'s first five.

| Row | What it is |
|---|---|
| As budgeted | Version 2 and nothing else |
| Held as it was | Six minutes of TFLT's drift from weights as written, and a source at 1%, 5% and lines 5% off |
| Held, lines 20% off | The same with the comb the row now allows, and left alone |
| Held as it now is | The same, read with sixteen shots a row and corrected on the weights at 8 bits |
| Probes only | A calibration's 16 probes taken and no trim written |
| A cycle | Aged six minutes, calibrated, aged six minutes again, with no source: `refdraws`'s |
| A cycle, the source as it was | The same with the source at 1%, 5% and lines 5% off |
| A cycle as it is now run | The same with lines 20% off, read and corrected on the weights at 8 bits |
| A cycle, trim at 8 bits | The cycle with no source again, with `--trimstep 1` |
| A cycle as it is now run, trim at 8 bits | The cycle as it is now run again, with `--trimstep 1` |

A held row and the probes-only one are read over the as-budgeted row of
their draw, and a cycle over the probes-only row of its draw: each pair
meets the same noise, and neither the read nor the correction takes a seed
of the run's. The networks trained before run beside the reference row for
row. That is 500 evaluations a data set.

**The trim's step.** The last two rows were added while the first eight were
running, on reading `eval` for how a cycle's trim and the corrected weights
meet in the DAC. They do not share its bits there. A trim is held in steps
of `--trimstep`, in LSB of the operand, and the operand is an 8-bit weight
whatever `B_w` is: `q(w, B_w)` keeps a weight at the operand's scale. The
default is a quarter of one, which is a sixteenth of a 6-bit code, four bits
below it. grxcp's calibration note asks for an 8-bit DAC behind a 6-bit code,
whose step is a quarter of a code, one 8-bit LSB, and `calib` measured that
step at version 1 alone. Every calibrated row of every mode since has run at
the default. So a cycle as it is now run has its weights on the DAC's 8 bits
and its trim two bits below them, which no 8-bit DAC holds. With `--trimstep
1` the weights and the trim are on the same 8 bits. A trim rounded to one LSB
is left 0.29 of one rms and one rounded to a quarter 0.07, beside a
programming error of one that is drawn again at every write.

**When the lines are read.** `eval` reads them when the evaluation starts.
In a held row that is after six minutes of drift from weights as written,
and in a cycle it is six minutes after the calibration, through what those
six minutes left. A chip that reads at its calibration reads through a
fresher tile. The lines do not move here, so that is all the difference
there is.

**How it ran.** In two parts. The first eight rows took 1.6 hours for the
three data sets side by side on four jobs each. The two rows more took 34
minutes, with the mode as it now stands running those two rows alone beside
the 400 lines a data set the first part had written, and its check and its
tables then taken over all ten. Those 400 lines were byte for byte the same
after the second part as before it. Of them, 200 on each data set are byte
for byte what `refdraws` wrote for the same runs: its four rows that this
mode has too, on five draws. And the cycle with the source as it was, on the
first draw, is byte for byte `refcycle`'s held cycle, ten lines a data set.

The mode checks every network and every run against its place, as the eight
before it do: a run's name says its draw, whether it is held or cycled,
whether a source is lit and how far from level its lines are, whether they
were read and corrected at 8 bits, and whether its trim is at 8 bits. A held
row has to have drifted and not been calibrated; a cycle to have been aged,
calibrated with its trims written, and aged again; and the probes-only row to
have taken its probes and written nothing. A corrected row has to have run
the tile at 8-bit weights and taken nothing off its sums, and no other row
may have been read at all. A cycle whose name says its trim is at 8 bits has
to have been asked a step of one and printed it, and every other row to have
been asked none and printed a quarter.

239 errors planted one at a time each fail: 146 in a training's line or a
run's, after the fact; 53 in the script; and 40 in the tables' own code, which
the check does not see and which each move the tables. A doctored line is put
to the mode's check of the network it belongs to, twenty runs, with the check
of all ten networks taken before the first and after the last. A changed
script runs in a directory of its own, and a run it asks for that was already
made, of the same network with the same options, is not made again. The
planted-error runs are of 200 images, on two draws for the lines and the
tables and on one for the script but where a change is to a draw's seed.

**What came of it.** What a row adds over the row it is read over: the mean
of five draws, with its standard error from the five networks, each averaged
over its draws. In bold, what five networks put outside chance at one in
twenty.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Held as it was: lines 5% off, left alone | +0.058 ± 0.028 | +0.000 ± 0.009 | **+0.231 ± 0.066** | +0.056 ± 0.061 | **+0.592 ± 0.212** | **+0.302 ± 0.057** |
| Held, lines 20% off, left alone | **+0.490 ± 0.047** | **+0.403 ± 0.030** | **+0.991 ± 0.152** | **+0.461 ± 0.163** | **+2.201 ± 0.332** | **+1.770 ± 0.441** |
| Held as it now is: lines 20% off, on the weights at 8 bits | **+0.096 ± 0.019** | **+0.086 ± 0.024** | **+0.222 ± 0.052** | +0.062 ± 0.050 | **+0.634 ± 0.187** | **+0.267 ± 0.016** |
| Probes only | −0.015 ± 0.017 | +0.006 ± 0.017 | −0.038 ± 0.033 | +0.012 ± 0.023 | +0.038 ± 0.027 | +0.014 ± 0.019 |
| A cycle, no source | +0.030 ± 0.031 | −0.013 ± 0.019 | +0.095 ± 0.052 | +0.046 ± 0.037 | +0.289 ± 0.141 | **+0.142 ± 0.045** |
| A cycle, the source as it was | **+0.084 ± 0.029** | +0.029 ± 0.027 | **+0.224 ± 0.038** | +0.052 ± 0.024 | **+0.617 ± 0.143** | **+0.321 ± 0.074** |
| A cycle as it is now run | **+0.128 ± 0.007** | +0.065 ± 0.027 | **+0.186 ± 0.055** | +0.043 ± 0.030 | **+0.574 ± 0.176** | **+0.302 ± 0.046** |
| A cycle, no source, trim at 8 bits | +0.042 ± 0.030 | +0.010 ± 0.019 | +0.070 ± 0.048 | +0.032 ± 0.040 | +0.300 ± 0.134 | **+0.178 ± 0.041** |
| A cycle as it is now run, trim at 8 bits | **+0.111 ± 0.016** | +0.049 ± 0.022 | **+0.226 ± 0.058** | +0.087 ± 0.038 | **+0.632 ± 0.182** | **+0.332 ± 0.060** |

How often right, percent.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| As budgeted | 97.304 ± 0.101 | 97.611 ± 0.047 | 86.966 ± 0.168 | 87.357 ± 0.144 | 92.655 ± 0.567 | 94.910 ± 0.349 |
| Held as it was: lines 5% off, left alone | 97.245 ± 0.104 | 97.611 ± 0.042 | 86.735 ± 0.132 | 87.301 ± 0.092 | 92.063 ± 0.568 | 94.608 ± 0.397 |
| Held, lines 20% off, left alone | 96.814 ± 0.102 | 97.208 ± 0.062 | 85.975 ± 0.063 | 86.896 ± 0.036 | 90.454 ± 0.513 | 93.140 ± 0.744 |
| Held as it now is: lines 20% off, on the weights at 8 bits | 97.208 ± 0.099 | 97.525 ± 0.059 | 86.744 ± 0.125 | 87.295 ± 0.097 | 92.021 ± 0.622 | 94.643 ± 0.334 |
| Probes only | 97.319 ± 0.098 | 97.604 ± 0.040 | 87.004 ± 0.141 | 87.346 ± 0.147 | 92.617 ± 0.564 | 94.896 ± 0.350 |
| A cycle, no source | 97.289 ± 0.112 | 97.617 ± 0.057 | 86.909 ± 0.191 | 87.300 ± 0.181 | 92.328 ± 0.697 | 94.754 ± 0.369 |
| A cycle, the source as it was | 97.235 ± 0.110 | 97.576 ± 0.066 | 86.780 ± 0.154 | 87.294 ± 0.144 | 92.000 ± 0.699 | 94.574 ± 0.412 |
| A cycle as it is now run | 97.190 ± 0.100 | 97.539 ± 0.059 | 86.818 ± 0.179 | 87.302 ± 0.124 | 92.043 ± 0.736 | 94.594 ± 0.351 |
| A cycle, no source, trim at 8 bits | 97.277 ± 0.109 | 97.595 ± 0.056 | 86.934 ± 0.188 | 87.313 ± 0.173 | 92.317 ± 0.680 | 94.718 ± 0.371 |
| A cycle as it is now run, trim at 8 bits | 97.208 ± 0.099 | 97.556 ± 0.055 | 86.778 ± 0.183 | 87.258 ± 0.148 | 91.985 ± 0.737 | 94.564 ± 0.348 |

One row over another on the same draws: how often right in the second, less
in the first, network by network.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Held as it now is, over held as it was | +0.038 ± 0.029 | **+0.086 ± 0.027** | −0.009 ± 0.030 | +0.006 ± 0.030 | +0.042 ± 0.089 | −0.035 ± 0.069 |
| Held with the lines left alone, over held as it was | **+0.432 ± 0.024** | **+0.403 ± 0.038** | **+0.760 ± 0.116** | **+0.405 ± 0.105** | **+1.609 ± 0.154** | **+1.468 ± 0.387** |
| Held as it now is, over held with the lines left alone | **−0.394 ± 0.038** | **−0.317 ± 0.032** | **−0.769 ± 0.118** | **−0.399 ± 0.117** | **−1.567 ± 0.227** | **−1.503 ± 0.452** |
| A cycle with the source as it was, over a cycle with none | +0.054 ± 0.038 | +0.042 ± 0.015 | +0.128 ± 0.051 | +0.006 ± 0.049 | **+0.328 ± 0.076** | **+0.180 ± 0.062** |
| A cycle as it is now run, over a cycle with no source | **+0.098 ± 0.033** | **+0.078 ± 0.017** | **+0.090 ± 0.032** | −0.003 ± 0.062 | **+0.285 ± 0.063** | **+0.160 ± 0.036** |
| A cycle as it is now run, over a cycle with the source as it was | +0.044 ± 0.025 | +0.036 ± 0.018 | −0.038 ± 0.037 | −0.008 ± 0.043 | −0.043 ± 0.062 | −0.019 ± 0.066 |
| A cycle with its trim at 8 bits, over a cycle | +0.012 ± 0.005 | **+0.022 ± 0.007** | −0.025 ± 0.011 | −0.014 ± 0.022 | +0.011 ± 0.031 | +0.036 ± 0.017 |
| A cycle as it is now run, its trim at 8 bits, over one as it is now run | −0.017 ± 0.014 | −0.016 ± 0.008 | **+0.041 ± 0.013** | +0.044 ± 0.043 | +0.058 ± 0.033 | +0.030 ± 0.025 |
| A cycle as it is now run, its trim at 8 bits, over a cycle with its trim at 8 bits | **+0.070 ± 0.022** | **+0.039 ± 0.011** | **+0.156 ± 0.042** | +0.055 ± 0.040 | **+0.332 ± 0.072** | **+0.154 ± 0.048** |

What the probe found on the lines and what its reading would leave, rms, and
the share of ~~the first layer's weights~~ *the network's weights that are
not zero, in both layers: corrected 2026-10-10* the correction left at the
rail. The first two are the tile's and the seed's, and the same for both
kinds of network and all three data sets.

| | Found on the lines, rms | Left by the reading | Held at the rail, trained before: MNIST | Fashion-MNIST | Inverted | Reference: MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|---|---|---|---|---|
| Held as it now is: lines 20% off, on the weights at 8 bits | 20.13% | 1.00% | 0.041% | 0.071% | 0.009% | 0.140% | 0.255% | 0.049% |
| A cycle as it is now run | 20.13% | 0.99% | 0.041% | 0.071% | 0.009% | 0.141% | 0.255% | 0.049% |
| A cycle as it is now run, trim at 8 bits | 20.13% | 1.00% | 0.041% | 0.071% | 0.009% | 0.141% | 0.255% | 0.049% |

**Held, the move costs the reference networks 0.09 ± 0.03 of a point on
MNIST, and nothing that can be told on the other two sets.** Held as it now
is they are right 97.52, 87.30 and 94.64% of the time and lose 0.23, 0.59
and 0.74 of a point to the tile; held as it was, 97.61, 87.30 and 94.61%,
and 0.14, 0.58 and 0.78. Seed by seed the move is 0.09 ± 0.03, 0.01 ± 0.03
and −0.04 ± 0.07: clear on MNIST alone, where it is under a tenth and five
networks put it between 0.01 and 0.16. The section before had it at 0.05,
0.06 and −0.05, with no drift and on three draws. For the networks trained
before it is 0.04 ± 0.03, −0.01 ± 0.03 and 0.04 ± 0.09, none of them clear.

**The read and the correction are part of the row.** Held with lines 20% off
and left alone the reference networks lose 0.40 ± 0.03, 0.46 ± 0.16 and 1.77
± 0.44 more than as budgeted, which is 0.40 ± 0.04, 0.41 ± 0.10 and 1.47 ±
0.39 more than held as it was. The correction takes 0.32, 0.40 and 1.50 of
that back.

**A cycle with a source lit ends 0.30 of a point over on the inverted set,
and under a tenth on the other two.** With no source a six-minute cycle ends
−0.01 ± 0.02, 0.05 ± 0.04 and 0.14 ± 0.04 over the probes-only row of its
draw on these five draws, where `refdraws`'s ten have −0.01, 0.07 and 0.12.
With the source as it was it ends 0.03 ± 0.03, 0.05 ± 0.02 and 0.32 ± 0.07
over, and as it is now run 0.07 ± 0.03, 0.04 ± 0.03 and 0.30 ± 0.05. So the
source's rows add 0.04 ± 0.02, 0.01 ± 0.05 and 0.18 ± 0.06 at the end of a
cycle as they were and 0.08 ± 0.02, −0.00 ± 0.06 and 0.16 ± 0.04 as they now
are, clear on the inverted set either way and on MNIST as they now are. The
move itself is 0.04 ± 0.02, −0.01 ± 0.04 and −0.02 ± 0.07 there, clear on no
set. On the inverted set the cycle as it is now run is a tenth or more over
on every one of the five draws: drift has 0.14 of its 0.30 and the source
0.16. The networks trained before end 0.13 ± 0.01, 0.19 ± 0.05 and 0.57 ±
0.18 over, a tenth or more on every set.

**At the DAC's own step a cycle moves by 0.06 of a point at the most.** With
`--trimstep 1` the cycle with no source costs the reference networks 0.02 ±
0.01, −0.01 ± 0.02 and 0.04 ± 0.02 more and the cycle as it is now run −0.02
± 0.01, 0.04 ± 0.04 and 0.03 ± 0.03; for the networks trained before, 0.01 ±
0.01, −0.02 ± 0.01 and 0.01 ± 0.03, and −0.02 ± 0.01, 0.04 ± 0.01 and 0.06 ±
0.03. Of the twelve, two are clear: the reference networks' cycle with no
source on MNIST, and the old networks' cycle as it is now run on
Fashion-MNIST. At that step a cycle as it is now run ends 0.05 ± 0.02, 0.09
± 0.04 and 0.33 ± 0.06 over for the reference networks and the cycle with no
source 0.01 ± 0.02, 0.03 ± 0.04 and 0.18 ± 0.04. For them no set changes
sides of a tenth; for the old networks the cycle with no source on
Fashion-MNIST does, from 0.10 to 0.07.

**A trim and a correction on the same 8 bits do little to each other.** What
the coarser trim costs the corrected cycle, less what it costs the cycle with
no source, is −0.04 ± 0.01, 0.06 ± 0.05 and −0.01 ± 0.02 for the reference
networks and −0.03 ± 0.01, 0.07 ± 0.02 and 0.05 ± 0.02 for the old ones:
within 0.07 of a point, of both signs, and clear on MNIST for the first and
on Fashion-MNIST for the second.

**Six minutes of drift do nothing to the read.** The probe found the lines
20.1% off, rms. Its reading would leave them 1.00% off where the tile was
held from weights as written and 0.99% six minutes after a calibration,
between 0.82% and 1.17% on any one run. On the three draws the section
before read through a tile that had not drifted, sixteen shots a row left
0.98% there and 0.99% here. The rail holds 0.14%, 0.25% and 0.05% of the
reference networks' weights back.

**What was predicted.** Seven things, written before the mode was written.
Two more with the two rows that were added, written while the first eight
rows ran and before any of them was read. What was written with the seven
said that no cycle had been run with a source lit. That was wrong: `refcycle`
ran one, on one draw. No prediction used it, and the fourth could have.

1. That held as it now is, the reference networks lose 0.04 to 0.14, 0.02 to
   0.18 and 0.10 to 0.32 more than as budgeted. Right on all three: 0.09,
   0.06 and 0.27.
2. That this is within 0.08 of the old holding on MNIST and 0.12 on
   Fashion-MNIST, either way, and on the inverted set between 0.20 better and
   0.05 worse. Right on the last two, 0.01 worse and 0.04 better. Wrong on
   MNIST by under a hundredth: 0.086.
3. That held with lines 20% off and left alone they lose 0.30 to 0.60, 0.30
   to 0.90 and 1.2 to 2.6 more than as budgeted. Right: 0.40, 0.46 and 1.77.
4. That a six-minute cycle with the source as it was ends 0.00 to 0.10, 0.03
   to 0.20 and 0.20 to 0.50 over the probes-only row of its draw. Right:
   0.03, 0.05 and 0.32.
5. That a cycle as it is now run ends 0.03 to 0.14, 0.03 to 0.20 and 0.12 to
   0.38 over, and on no set under the cycle with no source. Right in every
   band: 0.07, 0.04 and 0.30. Wrong about Fashion-MNIST in the second part,
   by three thousandths: −0.003 ± 0.062.
6. That with the source on, the cycle is over a tenth on the inverted set,
   under it on MNIST, and within 0.04 of it on Fashion-MNIST. Right on the
   first two. Wrong on Fashion-MNIST, where it is 0.06 under.
7. That the probe, read through a tile calibrated six minutes before, leaves
   the lines 0.8% to 1.1% off, and the rail holds 0.05% to 0.30% of the
   weights. Right of the mean, 0.99%, and of the rail to the two places it
   was written to: 0.14%, 0.25% and 0.05%, the last of them 0.049%. A single
   run leaves as much as 1.17%.
8. That a cycle with no source and its trim at 8 bits ends within 0.03 of the
   cycle as it has been run on MNIST and Fashion-MNIST, and between 0.02
   better and 0.06 worse on the inverted set. Right on all three: 0.02 worse,
   0.01 better and 0.04 worse.
9. That a cycle as it is now run with its trim at 8 bits ends within 0.03 of
   the one with the finer trim on MNIST and Fashion-MNIST and within 0.06 on
   the inverted set; and that what the coarser trim costs it, less what it
   costs the cycle with no source, is within 0.04 on every set. Right on
   MNIST and the inverted set, 0.02 better and 0.03 worse, and −0.04 and
   −0.01. Wrong on Fashion-MNIST in both: 0.04 worse, and 0.06.

Not predicted: that the trim at 8 bits would be clear anywhere. It is two
images in ten thousand on MNIST.

**What this is not.** A chip: the weights are scaled at the host, in the
harness, and the model's DAC has no rail for a weight and its trim together.
A comb whose lines move: they are fixed for a run, so nothing here says how
often they have to be read. A schedule: one calibration. A calibration that
sees a source's noise: the probes are taken before the light is lit, as in
every mode. Lines further off than 20%. Five draws and not ten, of the same
five networks. A trim step between a quarter of an LSB and one, or coarser
than one. Version 1, or another tile.

### How long a calibration holds, on the DAC as it is specified

*Added 2026-10-10.* `sim/pta_mnist.sh DIR WORK refhold`. Reported, not gated.
Nothing in `pta_mnist.c` changed for it.

**Why.** The section before found `eval`'s trim two bits finer than the DAC
grxcp's calibration note asks for, and ran a six-minute cycle at that DAC's
step on five draws. grxcp then kept the weight DAC at 8 bits. Its interval,
six minutes, rests on `refdraws`: ten draws of a cycle with no source and the
finer trim, at three minutes and at six. So that interval rested on a DAC
the chiplet is not held to, and on a tile with no source. grxcp asked for
the cycle on the DAC as it is specified, with the source lit, over the full
ten draws.

**What it runs.** The tenth mode on the reference networks. Version 2 on the
128 × 64 tile on two buses, six rows on each of ten draws, which are
`refdraws`'s.

| Row | What it is |
|---|---|
| As budgeted | Version 2 and nothing else |
| Probes only | A calibration's 16 probes taken and no trim written |
| A cycle, no source | Aged an interval, calibrated, aged the interval again: three minutes, and six |
| A cycle, the source lit | The same with the source at 1% and 5%, its lines 20% off, read with sixteen shots a row and corrected on the weights at 8 bits: three minutes, and six |

Every cycle is run with `--trimstep 1`, the step an 8-bit DAC behind a 6-bit
code holds. A cycle is read over the probes-only row of its draw, which
meets its noise. The networks trained before run beside the reference row
for row. That is 600 evaluations a data set, and 2.3 to 2.4 hours for the
three side by side on four jobs each. A first run of it stopped fifty runs
in when the machine slept, and it was begun again from its first run.

The mode checks every network and every run against its place, as the nine
before it do: a run's name says its draw, whether it is a cycle and of what
interval, and whether a source is lit. A cycle has to have been aged its
interval, calibrated with its trims written and aged its interval again,
and its interval to be one of those asked for. Every cycle has to have been
asked a trim step of one and printed it, and the other two rows to have been
asked none and printed a quarter. A cycle with a source lit has to have its
lines as far from level as the mode was asked, to have been read and
corrected at 8 bits, and to have run the tile at 8-bit weights; and no other
row may be lit, or read.

182 errors planted one at a time each fail: 99 in a training's line or a
run's, after the fact; 45 in the script; and 38 in the tables' own code, which
the check does not see and which each move the tables. As for the mode before,
a doctored line is put to the mode's check of the network it belongs to,
with the check of all ten networks taken before the first and after the
last; and a changed script is handed a run it asks for that was already
made, of the same network with the same options. The planted-error runs are
of 200 images, on two draws for the lines and the tables and on one for the
script but where a change is to a draw's seed.

Of the lines, 300 on each data set are byte for byte what two modes before
wrote for the same runs: `refdraws`'s as-budgeted and probes-only rows on all
ten draws, and `refpoint`'s two six-minute cycles at this step on its five.

**What came of it.** What a row adds over the row it is read over: the mean
of ten draws, with its standard error from the five networks, each averaged
over its draws. In bold, what five networks put outside chance at one in
twenty.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Probes only | −0.003 ± 0.011 | +0.001 ± 0.012 | +0.030 ± 0.017 | +0.028 ± 0.022 | **+0.030 ± 0.008** | −0.014 ± 0.012 |
| A three-minute cycle, no source | −0.002 ± 0.011 | +0.001 ± 0.010 | +0.012 ± 0.028 | +0.034 ± 0.020 | **+0.407 ± 0.114** | **+0.114 ± 0.025** |
| A three-minute cycle, the source lit | **+0.110 ± 0.020** | +0.063 ± 0.031 | **+0.175 ± 0.025** | +0.075 ± 0.039 | **+0.700 ± 0.168** | **+0.267 ± 0.037** |
| A six-minute cycle, no source | +0.012 ± 0.018 | +0.004 ± 0.010 | +0.082 ± 0.035 | +0.038 ± 0.019 | **+0.436 ± 0.058** | **+0.148 ± 0.017** |
| A six-minute cycle, the source lit | **+0.106 ± 0.005** | +0.049 ± 0.021 | **+0.226 ± 0.056** | **+0.120 ± 0.015** | **+0.733 ± 0.076** | **+0.317 ± 0.040** |

How often right, percent.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| As budgeted | 97.303 ± 0.104 | 97.612 ± 0.048 | 86.999 ± 0.162 | 87.359 ± 0.141 | 92.648 ± 0.575 | 94.896 ± 0.347 |
| Probes only | 97.306 ± 0.097 | 97.611 ± 0.044 | 86.968 ± 0.163 | 87.331 ± 0.151 | 92.618 ± 0.574 | 94.911 ± 0.352 |
| A three-minute cycle, no source | 97.308 ± 0.103 | 97.610 ± 0.049 | 86.956 ± 0.174 | 87.296 ± 0.153 | 92.211 ± 0.673 | 94.797 ± 0.335 |
| A three-minute cycle, the source lit | 97.196 ± 0.106 | 97.548 ± 0.064 | 86.794 ± 0.157 | 87.256 ± 0.130 | 91.918 ± 0.698 | 94.643 ± 0.330 |
| A six-minute cycle, no source | 97.294 ± 0.099 | 97.607 ± 0.051 | 86.886 ± 0.192 | 87.292 ± 0.162 | 92.182 ± 0.606 | 94.762 ± 0.347 |
| A six-minute cycle, the source lit | 97.200 ± 0.099 | 97.562 ± 0.058 | 86.742 ± 0.200 | 87.211 ± 0.141 | 91.886 ± 0.619 | 94.593 ± 0.342 |

One row over another on the same draws: how often right in the second, less
in the first, network by network.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| A three-minute cycle with the source lit, over one with none | **+0.112 ± 0.027** | +0.062 ± 0.027 | **+0.162 ± 0.045** | +0.041 ± 0.050 | **+0.293 ± 0.070** | **+0.153 ± 0.043** |
| A six-minute cycle with the source lit, over one with none | **+0.094 ± 0.018** | **+0.045 ± 0.015** | **+0.144 ± 0.050** | **+0.082 ± 0.024** | **+0.297 ± 0.036** | **+0.169 ± 0.030** |
| With no source, a six-minute cycle over a three-minute one | +0.014 ± 0.016 | +0.003 ± 0.007 | **+0.070 ± 0.020** | +0.004 ± 0.025 | +0.029 ± 0.094 | +0.034 ± 0.033 |
| With the source lit, a six-minute cycle over a three-minute one | −0.004 ± 0.016 | −0.014 ± 0.010 | +0.052 ± 0.055 | +0.045 ± 0.042 | +0.032 ± 0.125 | +0.050 ± 0.036 |

Against `refdraws`, which ran the same ten draws of the cycle with no source
at the default step, a quarter of an LSB: how often right there, less here,
network by network. grxcp's model derives it from the two modes' lines, whose
probes-only rows are the same lines.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| What `--trimstep 1` costs a three-minute cycle with no source, over `refdraws`'s | +0.007 ± 0.008 | +0.003 ± 0.008 | −0.005 ± 0.021 | +0.004 ± 0.012 | +0.112 ± 0.064 | +0.038 ± 0.017 |
| and a six-minute one | +0.002 ± 0.009 | **+0.010 ± 0.004** | −0.005 ± 0.012 | −0.028 ± 0.010 | +0.025 ± 0.045 | +0.029 ± 0.027 |

What the probe found on the lines and what its reading would leave, rms, and
the share of ~~the first layer's weights~~ *the network's weights that are
not zero, in both layers: corrected 2026-10-10* the correction left at the
rail.

| | Found on the lines, rms | Left by the reading | Held at the rail, trained before: MNIST | Fashion-MNIST | Inverted | Reference: MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|---|---|---|---|---|
| A three-minute cycle, the source lit | 19.88% | 1.00% | 0.038% | 0.064% | 0.009% | 0.132% | 0.239% | 0.048% |
| A six-minute cycle, the source lit | 19.88% | 1.00% | 0.038% | 0.065% | 0.009% | 0.132% | 0.239% | 0.048% |

**With no source, neither interval holds a tenth on the inverted set.** The
reference networks' six-minute cycle ends 0.00 ± 0.01, 0.04 ± 0.02 and 0.15
± 0.02 over the probes-only row of its draw, and a three-minute one 0.00 ±
0.01, 0.03 ± 0.02 and 0.11 ± 0.03. On the inverted set six minutes is 2.9 of
its errors over a tenth, which five networks put outside chance, and three
minutes 0.6 over, which they do not. By grxcp's rule, the longest interval
whose cycle ends under a tenth with the shorter doing so too, a calibration
holds six minutes on MNIST and Fashion-MNIST and no interval that was run on
the inverted set.

**The DAC's step is what moved three minutes there.** At the default step
`refdraws` had −0.01 ± 0.01, 0.07 ± 0.02 and 0.12 ± 0.03 at six minutes and
−0.00, 0.03 and 0.08 at three, and three minutes held on the inverted set.
Seed for seed, `--trimstep 1` costs the reference networks 0.01, −0.03 and
0.03 at six minutes and 0.00, 0.00 and 0.04 at three. Over both kinds all
twelve such figures are within 0.12 of a point, and one is clear, a
hundredth on MNIST. The inverted set's are not clear, and they are enough to
cross a tenth.

**With the source lit, six minutes holds on MNIST alone.** The cycle ends
0.05 ± 0.02, 0.12 ± 0.01 and 0.32 ± 0.04 over at six minutes and 0.06 ± 0.03,
0.07 ± 0.04 and 0.27 ± 0.04 at three. On Fashion-MNIST six minutes is 1.4 of
its errors over a tenth and three 0.6 under, neither of them clear. On the
inverted set both are clear of it, and the five networks' mean is at a tenth
or over on every one of the ten draws at either interval. So held, the
reference networks lose 0.19, 0.68 and 0.79 of a point to the tile at the
end of six minutes and 0.20, 0.63 and 0.74 at the end of three.

**Six minutes over three is clear nowhere for the reference networks.** 0.00
± 0.01, 0.00 ± 0.03 and 0.03 ± 0.03 with no source, and −0.01 ± 0.01, 0.04 ±
0.04 and 0.05 ± 0.04 with the source lit. On the inverted set, with no
source, the last three of six minutes are 0.03 of the 0.15 a cycle ends
over. For the networks trained before one of the six is clear: 0.07 ± 0.02
on Fashion-MNIST with no source.

**What the source adds does not depend on the interval.** 0.04 ± 0.02, 0.08 ±
0.02 and 0.17 ± 0.03 at the end of six minutes, clear on all three sets, and
0.06 ± 0.03, 0.04 ± 0.05 and 0.15 ± 0.04 at the end of three.

**The draws.** From draw to draw the five networks' mean of the six-minute
cycle with the source lit has a standard deviation of 0.04, 0.09 and 0.10,
and on the inverted set it runs from 0.14 to 0.45. The five draws the
section before ran have 0.05, 0.09 and 0.33, and the other five 0.05, 0.15
and 0.30.

**The networks trained before.** Their six-minute cycle ends 0.01 ± 0.02,
0.08 ± 0.04 and 0.44 ± 0.06 over with no source and 0.11 ± 0.00, 0.23 ± 0.06
and 0.73 ± 0.08 with the source lit. By the rule, with no source a
calibration holds six minutes on MNIST and Fashion-MNIST for them and no
interval on the inverted set, and with the source lit no interval on any
set.

**The read.** The probe found the lines 19.9% off, rms, and its reading would
leave them 1.00% off at either interval, between 0.78% and 1.37% on any one
run. The rail holds 0.13%, 0.24% and 0.05% of the reference networks'
weights back.

**What was predicted.** Nine things, written before the mode was run, for
the reference networks.

1. That with no source a six-minute cycle ends −0.02 to 0.05, 0.02 to 0.12
   and 0.10 to 0.22 over. Right: 0.00, 0.04 and 0.15.
2. That with no source a three-minute one ends −0.03 to 0.04, 0.00 to 0.08
   and 0.05 to 0.16 over, and that six minutes costs 0.00 to 0.10 more than
   three on the inverted set and within 0.04 on the other two. Right: 0.00,
   0.03 and 0.11, and 0.03 more on the inverted set and 0.00 on each of the
   other two.
3. That with the source lit a six-minute cycle ends 0.02 to 0.10, 0.04 to
   0.14 and 0.24 to 0.40 over. Right: 0.05, 0.12 and 0.32.
4. That with the source lit a three-minute one ends 0.01 to 0.09, 0.02 to
   0.12 and 0.18 to 0.36 over. Right: 0.06, 0.07 and 0.27.
5. That what the source's rows add does not depend on the interval: at six
   minutes 0.02 to 0.08, −0.02 to 0.10 and 0.10 to 0.22, and at three within
   0.05 of that on every set. Right: 0.04, 0.08 and 0.17, and 0.06, 0.04 and
   0.15.
6. That by the rule, with no source, a calibration holds six minutes on
   MNIST and Fashion-MNIST and three minutes or none on the inverted set;
   and with the source lit, six minutes on MNIST, none on the inverted set,
   and Fashion-MNIST within 0.04 of a tenth at six minutes. Right: none on
   the inverted set either way, and 0.12 on Fashion-MNIST.
7. That on the inverted set with no source the six-minute cycle's mean is
   over a tenth, and that five networks do not put it over one. Right about
   the mean, 0.148. Wrong about the five networks, by two thousandths: they
   put it over 0.102.
8. That the trim at 8 bits costs the cycle with no source within 0.04 of what
   the finer trim did on the same ten draws, on every set at both intervals,
   and under 0.03 on MNIST and Fashion-MNIST at six minutes. Right: 0.01,
   −0.03 and 0.03, and 0.00, 0.00 and 0.04. For the networks trained before,
   which the prediction was not of, it is 0.11 ± 0.06 on the inverted set at
   three minutes.
9. That the probe leaves the lines 0.9% to 1.1% off in the mean at both
   intervals, and that the rail holds 0.14%, 0.25% and 0.05% of the
   reference networks' weights to 0.02%. Right: 1.00%, and 0.13%, 0.24% and
   0.05%.

Not predicted: that the DAC's step, which no one figure shows clearly, is
what decides whether three minutes holds on the inverted set.

**What this is not.** A schedule: one calibration, where a tile in use has
had hundreds. Other intervals than three minutes and six: what a cycle ends
over on the inverted set is mostly there at three, and nothing here says
what one minute would do. A trim step between a quarter of an LSB and one. A
calibration that sees a source's noise: the probes are taken before the
light is lit. A comb whose lines move. A chip: the weights are scaled at the
host, and the model's DAC has no rail for a weight and its trim together.
The ten draws are of the same five networks. Version 1, or another tile.

### The source's rows, on the chip as it is held

*Added 2026-10-10.* `sim/pta_mnist.sh DIR WORK refrows`. Reported, not gated.
Nothing in `pta_mnist.c` changed for it.

**Why.** The section before found that at the end of a six-minute cycle the
source's rows add 0.04, 0.08 and 0.17 of a point for the reference networks,
and on the inverted set more than the cycle's drift does. Which of the rows
it is had only been run a row at a time: `source`, `refsource` and
`reflaser` light a tile that was not calibrated, with its lines 5% off and
left alone. grxcp kept its interval at six minutes and asked what tightening
a line's own noise would buy on the chip as it is now held.

**What it runs.** The eleventh mode on the reference networks. Version 2 on
the 128 × 64 tile on two buses, ten rows on each of five draws, which are
`refpoint`'s. The tile as budgeted; a calibration's probes taken and nothing
written; a six-minute cycle with no source; and that cycle with a source
lit, its lines 20% off, read with sixteen shots a row and corrected on the
weights at 8 bits, once for each of seven pairs of noise:

| `--src` | `--srcline` | What it is |
|---|---|---|
| 0.01 | 0.05 | The chip as grxcp holds it |
| 0.01 | 0.02 | A line's own noise tightened |
| 0.01 | 0.01 | |
| 0.01 | 0 | The shared row alone |
| 0 | 0.05 | A line's own noise alone |
| 0 | 0 | A comb 20% off, read and corrected, and no noise |
| 0.02 | 0.05 | The shared row as it was before grxcp's B16 |

Every cycle has `--trimstep 1`. A cycle is read over the probes-only row of
its draw. The lit rows of a draw meet the same seeds, and differ in how much
noise is drawn and not in which. The networks trained before run beside the
reference row for row. That is 500 evaluations a data set, and two hours
for the three side by side on four jobs each.

The mode checks every network and every run against its place, as the ten
before it do: a run's name says its draw, whether it is a cycle, whether a
source is lit, and the source's noise for its lines together and for a line,
which have to be what it was asked and what its line printed, and one of the
pairs the mode was asked for. A lit cycle has to have its lines as far from
level as the mode was asked, to have been read and corrected at 8 bits, and
to have run the tile at 8-bit weights; and no other row may be lit, or read.

196 errors planted one at a time each fail: 116 in a training's line or a
run's, after the fact; 43 in the script; and 37 in the tables' own code, which
the check does not see and which each move the tables. As for the two modes
before, a doctored line is put to the mode's check of the network it belongs
to, and a changed script is handed a run it asks for that was already made.

Of the lines, 200 on each data set are byte for byte what `refhold` wrote for
the same runs: its as-budgeted and probes-only rows and its two six-minute
cycles, on these five draws.

**What came of it.** What a row adds over the row it is read over: the mean
of five draws, with its standard error from the five networks, each averaged
over its draws. In bold, what five networks put outside chance at one in
twenty.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Probes only | −0.015 ± 0.017 | +0.006 ± 0.017 | −0.038 ± 0.033 | +0.012 ± 0.023 | +0.038 ± 0.027 | +0.014 ± 0.019 |
| A cycle, no source | +0.042 ± 0.030 | +0.010 ± 0.019 | +0.070 ± 0.048 | +0.032 ± 0.040 | +0.300 ± 0.134 | **+0.178 ± 0.041** |
| A cycle: together 1%, a line 5%: the chip as it is held | **+0.111 ± 0.016** | +0.049 ± 0.022 | **+0.226 ± 0.058** | +0.087 ± 0.038 | **+0.632 ± 0.182** | **+0.332 ± 0.060** |
| A cycle: together 1%, a line 2% | **+0.074 ± 0.024** | +0.025 ± 0.028 | **+0.200 ± 0.062** | +0.024 ± 0.034 | **+0.524 ± 0.163** | **+0.273 ± 0.052** |
| A cycle: together 1%, a line 1% | +0.082 ± 0.031 | +0.008 ± 0.024 | **+0.191 ± 0.062** | +0.006 ± 0.020 | **+0.489 ± 0.149** | **+0.278 ± 0.058** |
| A cycle: together 1%, a line none | +0.082 ± 0.032 | +0.038 ± 0.024 | **+0.193 ± 0.062** | +0.047 ± 0.022 | **+0.462 ± 0.152** | **+0.249 ± 0.058** |
| A cycle: together none, a line 5% | **+0.121 ± 0.026** | +0.066 ± 0.037 | **+0.232 ± 0.057** | +0.037 ± 0.020 | **+0.579 ± 0.173** | **+0.297 ± 0.053** |
| A cycle: no noise | **+0.086 ± 0.026** | +0.018 ± 0.030 | **+0.162 ± 0.056** | +0.033 ± 0.022 | **+0.424 ± 0.142** | **+0.259 ± 0.066** |
| A cycle: together 2%, a line 5% | **+0.134 ± 0.008** | +0.055 ± 0.025 | **+0.238 ± 0.066** | +0.063 ± 0.034 | **+0.726 ± 0.191** | **+0.384 ± 0.073** |

How often right, percent.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| As budgeted | 97.304 ± 0.101 | 97.611 ± 0.047 | 86.966 ± 0.168 | 87.357 ± 0.144 | 92.655 ± 0.567 | 94.910 ± 0.349 |
| Probes only | 97.319 ± 0.098 | 97.604 ± 0.040 | 87.004 ± 0.141 | 87.346 ± 0.147 | 92.617 ± 0.564 | 94.896 ± 0.350 |
| A cycle, no source | 97.277 ± 0.109 | 97.595 ± 0.056 | 86.934 ± 0.188 | 87.313 ± 0.173 | 92.317 ± 0.680 | 94.718 ± 0.371 |
| A cycle: together 1%, a line 5%: the chip as it is held | 97.208 ± 0.099 | 97.556 ± 0.055 | 86.778 ± 0.183 | 87.258 ± 0.148 | 91.985 ± 0.737 | 94.564 ± 0.348 |
| A cycle: together 1%, a line 2% | 97.245 ± 0.108 | 97.579 ± 0.059 | 86.804 ± 0.186 | 87.321 ± 0.163 | 92.094 ± 0.718 | 94.623 ± 0.366 |
| A cycle: together 1%, a line 1% | 97.237 ± 0.108 | 97.597 ± 0.058 | 86.813 ± 0.184 | 87.340 ± 0.146 | 92.128 ± 0.707 | 94.618 ± 0.349 |
| A cycle: together 1%, a line none | 97.236 ± 0.108 | 97.566 ± 0.054 | 86.811 ± 0.189 | 87.298 ± 0.140 | 92.155 ± 0.708 | 94.647 ± 0.360 |
| A cycle: together none, a line 5% | 97.198 ± 0.114 | 97.538 ± 0.070 | 86.772 ± 0.183 | 87.308 ± 0.136 | 92.038 ± 0.732 | 94.598 ± 0.362 |
| A cycle: no noise | 97.233 ± 0.107 | 97.586 ± 0.062 | 86.842 ± 0.188 | 87.312 ± 0.140 | 92.193 ± 0.699 | 94.637 ± 0.363 |
| A cycle: together 2%, a line 5% | 97.185 ± 0.099 | 97.549 ± 0.054 | 86.766 ± 0.190 | 87.283 ± 0.138 | 91.891 ± 0.748 | 94.512 ± 0.345 |

What a source adds: a lit cycle less the cycle with no source on the same
draws, network by network.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Together 1%, a line 5%: the chip as it is held | **+0.070 ± 0.022** | **+0.039 ± 0.011** | **+0.156 ± 0.042** | +0.055 ± 0.040 | **+0.332 ± 0.072** | **+0.154 ± 0.048** |
| Together 1%, a line 2% | +0.032 ± 0.022 | +0.016 ± 0.016 | **+0.129 ± 0.042** | −0.008 ± 0.042 | **+0.223 ± 0.053** | +0.095 ± 0.038 |
| Together 1%, a line 1% | +0.040 ± 0.025 | −0.002 ± 0.012 | +0.120 ± 0.044 | −0.027 ± 0.038 | **+0.189 ± 0.049** | +0.100 ± 0.043 |
| Together 1%, a line none | +0.041 ± 0.024 | +0.029 ± 0.012 | **+0.122 ± 0.038** | +0.015 ± 0.050 | **+0.162 ± 0.048** | +0.071 ± 0.038 |
| Together none, a line 5% | **+0.079 ± 0.019** | +0.057 ± 0.022 | **+0.161 ± 0.039** | +0.005 ± 0.041 | **+0.279 ± 0.070** | **+0.120 ± 0.033** |
| No noise | +0.044 ± 0.022 | +0.008 ± 0.017 | **+0.092 ± 0.032** | +0.001 ± 0.043 | +0.124 ± 0.049 | +0.081 ± 0.044 |
| Together 2%, a line 5% | **+0.092 ± 0.031** | +0.046 ± 0.018 | **+0.168 ± 0.045** | +0.030 ± 0.039 | **+0.426 ± 0.080** | **+0.206 ± 0.062** |

What a row buys over the chip as it is held: how often right in it, less on
the chip.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| Together 1%, a line 2% | **+0.038 ± 0.012** | +0.024 ± 0.010 | +0.027 ± 0.018 | +0.063 ± 0.026 | +0.109 ± 0.047 | +0.059 ± 0.024 |
| Together 1%, a line 1% | +0.029 ± 0.018 | **+0.041 ± 0.006** | +0.036 ± 0.018 | **+0.082 ± 0.021** | **+0.143 ± 0.045** | **+0.054 ± 0.013** |
| Together 1%, a line none | +0.029 ± 0.018 | +0.010 ± 0.011 | +0.034 ± 0.016 | +0.040 ± 0.028 | **+0.170 ± 0.043** | **+0.083 ± 0.016** |
| Together none, a line 5% | −0.010 ± 0.016 | −0.018 ± 0.017 | −0.005 ± 0.009 | +0.050 ± 0.026 | **+0.053 ± 0.019** | +0.034 ± 0.023 |
| No noise | +0.026 ± 0.014 | **+0.031 ± 0.009** | **+0.064 ± 0.018** | +0.054 ± 0.033 | **+0.208 ± 0.053** | **+0.073 ± 0.017** |
| Together 2%, a line 5% | −0.022 ± 0.012 | −0.006 ± 0.007 | −0.012 ± 0.012 | +0.024 ± 0.015 | **−0.094 ± 0.018** | −0.052 ± 0.025 |

What the probe found on the lines and what its reading would leave, rms,
beside what the count says it should leave; and the share of ~~the first
layer's weights~~ *the network's weights that are not zero, in both layers:
corrected 2026-10-10* the correction left at the rail.

| | Found on the lines, rms | Left by the reading | Counted | Held at the rail, the reference networks: MNIST | Fashion-MNIST | Inverted |
|---|---|---|---|---|---|---|
| Together 1%, a line 5%: the chip as it is held | 20.13% | 1.00% | 0.91% | 0.141% | 0.255% | 0.049% |
| Together 1%, a line 2% | 20.13% | 0.47% | 0.41% | 0.140% | 0.254% | 0.049% |
| Together 1%, a line 1% | 20.13% | 0.31% | 0.27% | 0.141% | 0.254% | 0.049% |
| Together 1%, a line none | 20.13% | 0.25% | 0.21% | 0.142% | 0.255% | 0.049% |
| Together none, a line 5% | 20.13% | 0.96% | 0.89% | 0.139% | 0.251% | 0.048% |
| No noise | 20.13% | 0.15% | 0.11% | 0.142% | 0.255% | 0.049% |
| Together 2%, a line 5% | 20.13% | 1.06% | 0.96% | 0.140% | 0.255% | 0.049% |

**On the inverted set, about half of what the source adds is not noise.**
The chip's source adds the reference networks 0.04 ± 0.01, 0.05 ± 0.04 and
0.15 ± 0.05. The same comb with no noise at all, read and corrected, adds
0.01 ± 0.02, 0.00 ± 0.04 and 0.08 ± 0.04, none of them clear. The noise is
the rest, 0.03 ± 0.01, 0.05 ± 0.03 and 0.07 ± 0.02: clear on MNIST and on the
inverted set, where it is under half of the whole. `reffix` had the same
correction 0.11 ± 0.04 from the model's own on that set, with no drift.

**Of the noise, a line's own is the part that shows.** The chip less the
same source with no line noise is 0.01 ± 0.01, 0.04 ± 0.03 and 0.08 ± 0.02,
clear on the inverted set. The chip less the same source with no shared
noise is −0.02 ± 0.02, 0.05 ± 0.03 and 0.03 ± 0.02, clear on none.

**A line at 2% buys half a tenth that five networks do not quite see, and at
1% they see it.** 2% buys 0.02 ± 0.01, 0.06 ± 0.03 and 0.06 ± 0.02, at 2.3,
2.4 and 2.5 of its errors. 1% buys 0.04 ± 0.01, 0.08 ± 0.02 and 0.05 ± 0.01,
clear on all three. With a line at 2% a cycle ends 0.03 ± 0.03, 0.02 ± 0.03
and 0.27 ± 0.05 over the probes-only row of its draw, where as the chip is
held it ends 0.05, 0.09 and 0.33. On the inverted set it ends over a tenth
with every row that was run: 0.26 ± 0.07 with no noise, and 0.18 ± 0.04 with
no source.

**The shared row at 2% costs the reference networks nothing that can be
seen.** 0.01 ± 0.01, −0.02 ± 0.02 and 0.05 ± 0.02 more than at 1%, clear on
none. For the networks trained before it costs 0.09 ± 0.02 on the inverted
set, which is clear.

**The read follows the count, a tenth over it.** A reading leaves the lines
1.00% off with a line at 5%, 0.47% at 2%, 0.31% at 1%, 0.25% with the shared
row alone and 0.15% with no noise, where the count has 0.91%, 0.41%, 0.27%,
0.21% and 0.11%. With no noise what is left is the tile's own.

**The networks trained before.** The chip's source adds them 0.07 ± 0.02,
0.16 ± 0.04 and 0.33 ± 0.07, and the comb with no noise 0.04 ± 0.02, 0.09 ±
0.03 and 0.12 ± 0.05. A line at 2% buys them 0.04 ± 0.01, 0.03 ± 0.02 and
0.11 ± 0.05, clear on MNIST, and with it their cycle ends 0.07, 0.20 and
0.52 over.

**What was predicted.** Seven things, written before the mode was run. The
expectation behind most of them was that a line's own noise is nearly all of
what the source adds, and it was wrong: on the inverted set about half of it
is not noise.

1. That with no line noise the shared row alone adds within 0.04 of nothing
   on every set, and that with no shared noise a line at 5% adds within 0.04
   of what the chip does. Wrong on the inverted set in the first: 0.03, 0.01
   and 0.07. Wrong on Fashion-MNIST in the second, by a hundredth: 0.02, 0.05
   and 0.03 apart.
2. That at 2% the source adds under half of what it does at 5% on the
   inverted set, 0.00 to 0.08, and at 1% within 0.04 of what it adds with no
   line noise. Wrong in the first: 0.095, which is 62% of it. In the second
   right on MNIST and the inverted set and wrong on Fashion-MNIST by two
   thousandths.
3. That with a line at 2% a cycle ends 0.16 to 0.28 over on the inverted
   set, and 0.02 to 0.10 on Fashion-MNIST. Right: 0.27 and 0.02.
4. That a comb 20% off with no noise, read and corrected, adds −0.03 to 0.05
   on every set. Right on MNIST and Fashion-MNIST, 0.01 and 0.00. Wrong on
   the inverted set: 0.08.
5. That the shared row at 2% adds within 0.05 of what it does at 1% on every
   set. Right on MNIST and Fashion-MNIST, 0.01 and −0.02. Wrong on the
   inverted set by two thousandths: 0.052.
6. That a reading leaves the lines 1.0% off with a line at 5%, 0.35% to
   0.50% at 2%, 0.22% to 0.33% at 1%, 0.16% to 0.26% with the shared row
   alone and 0.08% to 0.25% with no noise. Right on all five: 1.00%, 0.47%,
   0.31%, 0.25% and 0.15%.
7. That for the networks trained before a line at 2% takes back more than
   half of what the source adds on the inverted set. Wrong: 0.11 of 0.33, a
   third.

**What this is not.** A comb: no row here is a source that exists. Why the
corrected comb costs what it does on the inverted set: ~~the rail, the
rounding to 8 bits and the read are not told apart here,~~ *told apart in
the section after this one, the same day: of the three it is the rail;* and
0.08 ± 0.04 is not itself clear. Noise that goes with a line's own power:
here it is a share of a line's nominal light. A level other than 20%, or an
interval other than six minutes. A calibration that sees a source's noise.
Five draws, of the same five networks. Version 1, or another tile.

### What a corrected comb leaves, told apart

*Added 2026-10-10.* `sim/pta_mnist.sh DIR WORK refcomb`, and `pta_mnist eval
--levelpart none|LIST --levellayer N`. Reported, not gated.

**Why.** The section before found a comb 20% off with no noise at all, read
and corrected on the weights at 8 bits, adding 0.08 ± 0.04 of a point for the
reference networks on the inverted set: about half of what the chip's source
adds there, not itself clear, and with nothing to say what in the correction
leaves it. grxcp asked which it is: the rail, the rounding to 8 bits, or the
read.

**The three parts.** A weight the network was trained for, q, on a line at
1 + e that was read as 1 + r, is written as c = rail(round(u)) with u = q /
(1 + r), and through its line it comes to (1 + e) c. That is off q by three
things, which add to it:

| Part | What it is | |
|---|---|---|
| `read` | (1 + e) u − q | What the reading missed |
| `round` | (1 + e) (round(u) − u) | What writing the weight at 8 bits dropped |
| `rail` | (1 + e) (c − round(u)) | What a weight at the rail was not raised by |

**The option.** `--levelpart LIST`, with `--levelfix weights8` held at the
rail and a source with no noise, works the three out for every weight and
rewrites nothing. The tile keeps the network as it was, at its own 6 bits,
and a layer's sums take the parts listed in place of the light's share:
after the converter, as the light's share is. `--levellayer N` puts them in
layer N alone, from 1, and nothing in the others. `--levelpart none` is no
part. So a run with a part is the run with no source, shot for shot, but for
that part: no weight on the tile moved, and no draw met another weight. With
all three in every layer it is `weights8`'s correction as a detector would
see it, which is not as this model's tile does: that converts the sums of
the weights as rewritten, and has the light's share added after. A run
prints `levelpart` and `levellayer`, and `level_moved` and `level_held`: a
layer's weights that are not zero, and those of them the rail held back,
counted as `level_clip` counts them whatever part was asked for. It is
refused with noise on the source, through an offset, scaled to the dimmest
line, or without `weights8`.

Like the probe and the corrections it is on the host's side of the line:
§4, PTM-C and the RTL are untouched, and a line printed without the option is
what it was. The self-test's 36 lines are as they were, with one more.

The self-test puts a network whose first layer has every weight there is on
the working tile, under a still source with its lines 8% off, unquantised
and at 6 bits. The three parts add to the weight as `weights8` rewrites it
through its line, weight for weight. 2,447 of 78,161 weights are held at the
rail, all in the first layer, as `level_apply()` counts them. A rounding is
0.498 of a unit at most and a read 0.0019 of its weight, and the rail takes
only from a weight it held. A layer alone leaves the other nothing. No part
gives the sums of a run with no source. With every part a run's sums are the
tile's and the parts' share exactly, and the rewritten weights' own first
sums. And noise, an offset, a reading not kept, a part or a layer there is
none of, and a line at 3% are refused. 46 errors planted in that code one at a
time each fail it. That was before the sweep.

**What it runs.** The twelfth mode on the reference networks. Version 2 on
the 128 × 64 tile on two buses, ten rows on each of five draws, which are
`refrows`'s. Every row is a six-minute cycle with `--trimstep 1`:

| Row | What it is |
|---|---|
| no source | The cycle and nothing else |
| on the tile | A still comb 20% off, read with sixteen shots a row and corrected on the weights at 8 bits: `refrows`'s row with no noise |
| on the model | The same comb, with the reading taken off the model's own line |
| apart, none | Told apart, with no part |
| apart, read,round,rail | All three, in both layers |
| apart, read | The read, in both layers |
| apart, round, layer 1; and layer 2 | The round, a layer at a time |
| apart, rail, layer 1; and layer 2 | The rail, a layer at a time |

A row is read over the cycle with no source of its draw. The networks
trained before run beside the reference row for row. That is 500 evaluations
a data set, and 2.9 hours for the three side by side on four jobs each, on a
machine that was doing other work.

The mode checks every network and every run against its place, as the eleven
before it do: a run's name says its draw, whether a source is lit, where its
reading was applied, and for a row told apart the parts and the layer, which
have to be what it was asked and what its line printed, and one of those the
mode was asked for. A row told apart has to have run the tile at its 6 bits,
and what its reading would leave and the share the rail held have to be the
row on the tile's of its draw, with its count of the rail a layer coming to
that share. And told apart with no part, a run has to have got right what
the cycle with no source of its draw did, with as many saturations.

230 errors planted one at a time each fail: 136 in a training's line or a
run's, after the fact; 51 in the script, 5 of which ask for a run the
harness refuses; and 43 in the tables' own code, which the check does not see
and which each move the tables. One more change to the tables' code cannot
move them: it prints the read for one kind of network twice, and what the
probe finds and leaves is the same for both, a comb being its seed's and its
draw's. As for the modes before, a doctored line is put to the mode's check
of the network it belongs to, and a changed script is handed a run it asks
for that was already made.

One line of the check was added after the sweep: a row told apart has to
print its part and its layer, where a line that printed no layer had passed
for one in every layer. The check and the tables were then run again from
the script as it now is, on the lines the sweep wrote and with nothing run
again. The check says yes on all three data sets, and the tables are the
sweep's byte for byte.

Of the lines, 100 on each data set are byte for byte what `refrows` wrote for
the same runs: its cycle with no source and its cycle with no noise, on
these five draws.

**What came of it.** What a row leaves over the cycle with no source of its
draw: the mean of five draws, with its standard error from the five
networks, each averaged over its draws. In bold, what five networks put
outside chance at one in twenty.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| The comb corrected on the tile | +0.044 ± 0.022 | +0.008 ± 0.017 | **+0.092 ± 0.032** | +0.001 ± 0.043 | +0.124 ± 0.049 | +0.081 ± 0.044 |
| The reading taken off the model's own line | +0.005 ± 0.005 | +0.004 ± 0.003 | +0.014 ± 0.008 | +0.003 ± 0.003 | +0.005 ± 0.006 | −0.004 ± 0.004 |
| Told apart: no part | +0.000 ± 0.000 | +0.000 ± 0.000 | +0.000 ± 0.000 | +0.000 ± 0.000 | +0.000 ± 0.000 | +0.000 ± 0.000 |
| Told apart: all three | +0.030 ± 0.011 | +0.015 ± 0.014 | +0.029 ± 0.023 | +0.013 ± 0.018 | +0.072 ± 0.053 | +0.043 ± 0.028 |
| The read | +0.004 ± 0.004 | +0.000 ± 0.003 | +0.016 ± 0.006 | +0.002 ± 0.004 | +0.004 ± 0.006 | −0.003 ± 0.004 |
| The round, first layer | +0.008 ± 0.009 | **−0.019 ± 0.005** | +0.016 ± 0.012 | **+0.031 ± 0.010** | +0.024 ± 0.032 | −0.003 ± 0.009 |
| The round, last layer | +0.010 ± 0.005 | −0.003 ± 0.002 | +0.012 ± 0.019 | −0.028 ± 0.013 | +0.004 ± 0.018 | −0.002 ± 0.021 |
| The rail, first layer | +0.006 ± 0.004 | +0.010 ± 0.005 | −0.002 ± 0.003 | +0.012 ± 0.026 | +0.020 ± 0.027 | **+0.069 ± 0.018** |
| The rail, last layer | +0.014 ± 0.010 | +0.014 ± 0.009 | +0.000 ± 0.004 | +0.012 ± 0.007 | +0.027 ± 0.021 | −0.005 ± 0.004 |

How often right, percent.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| A cycle with no source | 97.277 ± 0.109 | 97.595 ± 0.056 | 86.934 ± 0.188 | 87.313 ± 0.173 | 92.317 ± 0.680 | 94.718 ± 0.371 |
| The comb corrected on the tile | 97.233 ± 0.107 | 97.586 ± 0.062 | 86.842 ± 0.188 | 87.312 ± 0.140 | 92.193 ± 0.699 | 94.637 ± 0.363 |
| The reading taken off the model's own line | 97.272 ± 0.113 | 97.591 ± 0.058 | 86.920 ± 0.183 | 87.310 ± 0.176 | 92.312 ± 0.685 | 94.722 ± 0.372 |
| Told apart: no part | 97.277 ± 0.109 | 97.595 ± 0.056 | 86.934 ± 0.188 | 87.313 ± 0.173 | 92.317 ± 0.680 | 94.718 ± 0.371 |
| Told apart: all three | 97.248 ± 0.106 | 97.580 ± 0.066 | 86.904 ± 0.190 | 87.300 ± 0.170 | 92.244 ± 0.705 | 94.675 ± 0.364 |
| The read | 97.274 ± 0.112 | 97.594 ± 0.058 | 86.918 ± 0.184 | 87.311 ± 0.175 | 92.313 ± 0.686 | 94.721 ± 0.372 |
| The round, first layer | 97.269 ± 0.112 | 97.614 ± 0.060 | 86.918 ± 0.192 | 87.282 ± 0.178 | 92.293 ± 0.709 | 94.721 ± 0.373 |
| The round, last layer | 97.268 ± 0.112 | 97.598 ± 0.055 | 86.922 ± 0.191 | 87.341 ± 0.167 | 92.312 ± 0.682 | 94.720 ± 0.354 |
| The rail, first layer | 97.271 ± 0.108 | 97.585 ± 0.056 | 86.935 ± 0.190 | 87.301 ± 0.166 | 92.297 ± 0.674 | 94.649 ± 0.375 |
| The rail, last layer | 97.263 ± 0.103 | 97.580 ± 0.063 | 86.933 ± 0.186 | 87.302 ± 0.169 | 92.290 ± 0.675 | 94.723 ± 0.369 |

One row over another on the same draws: how often right in the second, less
in the first.

| | MNIST: trained before | Reference | Fashion-MNIST: trained before | Reference | Inverted: trained before | Reference |
|---|---|---|---|---|---|---|
| On the tile, over told apart: no part | +0.044 ± 0.022 | +0.008 ± 0.017 | **+0.092 ± 0.032** | +0.001 ± 0.043 | +0.124 ± 0.049 | +0.081 ± 0.044 |
| On the tile, over told apart: all three | +0.014 ± 0.015 | −0.007 ± 0.010 | +0.062 ± 0.041 | −0.012 ± 0.041 | +0.052 ± 0.025 | +0.038 ± 0.022 |
| On the tile, over the read | +0.040 ± 0.023 | +0.008 ± 0.018 | +0.076 ± 0.034 | −0.002 ± 0.045 | +0.120 ± 0.046 | +0.084 ± 0.047 |
| On the tile, over the round, first layer | +0.036 ± 0.025 | +0.027 ± 0.018 | **+0.076 ± 0.026** | −0.030 ± 0.044 | +0.100 ± 0.052 | +0.084 ± 0.039 |
| On the tile, over the round, last layer | +0.034 ± 0.021 | +0.012 ± 0.018 | +0.080 ± 0.037 | +0.028 ± 0.039 | **+0.120 ± 0.041** | +0.083 ± 0.047 |
| On the tile, over the rail, first layer | +0.038 ± 0.021 | −0.002 ± 0.018 | +0.093 ± 0.034 | −0.011 ± 0.046 | +0.104 ± 0.039 | +0.012 ± 0.030 |
| On the tile, over the rail, last layer | +0.030 ± 0.017 | −0.006 ± 0.012 | +0.091 ± 0.033 | −0.011 ± 0.038 | +0.097 ± 0.038 | +0.086 ± 0.044 |
| On the model, over told apart: no part | +0.005 ± 0.005 | +0.004 ± 0.003 | +0.014 ± 0.008 | +0.003 ± 0.003 | +0.005 ± 0.006 | −0.004 ± 0.004 |
| On the model, over told apart: all three | −0.025 ± 0.011 | −0.012 ± 0.014 | −0.016 ± 0.019 | −0.010 ± 0.019 | −0.067 ± 0.050 | −0.047 ± 0.030 |
| On the model, over the read | +0.001 ± 0.001 | +0.003 ± 0.001 | −0.002 ± 0.004 | +0.000 ± 0.003 | +0.001 ± 0.001 | −0.001 ± 0.000 |
| On the model, over the round, first layer | −0.004 ± 0.006 | **+0.022 ± 0.005** | −0.002 ± 0.013 | **−0.028 ± 0.009** | −0.019 ± 0.027 | −0.001 ± 0.010 |
| On the model, over the round, last layer | −0.005 ± 0.006 | +0.007 ± 0.004 | +0.002 ± 0.017 | +0.030 ± 0.014 | +0.001 ± 0.018 | −0.002 ± 0.021 |
| On the model, over the rail, first layer | −0.002 ± 0.005 | −0.006 ± 0.007 | +0.015 ± 0.010 | −0.009 ± 0.027 | −0.015 ± 0.027 | **−0.073 ± 0.021** |
| On the model, over the rail, last layer | −0.010 ± 0.011 | −0.011 ± 0.009 | +0.013 ± 0.007 | −0.009 ± 0.010 | −0.022 ± 0.022 | +0.001 ± 0.007 |

What the rail held back, a mean over the runs. Every row told apart of a
network and a draw counts the same.

| | First layer: held at the rail | Share of its weights that are not zero | Last layer: held at the rail | Share |
|---|---|---|---|---|
| MNIST, the reference networks | 76.5 | 0.107% | 26.7 | 2.746% |
| MNIST, trained before | 16.7 | 0.024% | 12.9 | 1.338% |
| Fashion-MNIST, the reference networks | 164.6 | 0.229% | 21.1 | 2.205% |
| Fashion-MNIST, trained before | 33.3 | 0.048% | 17.0 | 1.772% |
| MNIST, inverted, the reference networks | 30.7 | 0.047% | 1.7 | 0.178% |
| MNIST, inverted, trained before | 4.4 | 0.007% | 1.5 | 0.157% |

The probe found the lines 20.13% off, and its reading would leave 0.15% on
the tile and 0.14% on the model, on every data set and for both kinds of
network: a comb is its seed's and its draw's.

**Told apart with no part, a run is the cycle with no source.** In every one
of the 150 runs it gets right the images that cycle does, with as many
saturations. So a part is read against the same shots on the same weights.

**On the inverted set it is the rail in the first layer.** It leaves the
reference networks 0.010 ± 0.005, 0.012 ± 0.026 and 0.069 ± 0.018: clear on
the inverted set, at 3.8 of its errors. Each of the five networks loses to
it there, 0.114, 0.046, 0.024, 0.110 and 0.050, and so does each of the five
draws, 0.050, 0.046, 0.094, 0.096 and 0.058. The other four leave −0.003 ±
0.004, −0.003 ± 0.009, −0.002 ± 0.021 and −0.005 ± 0.004 on that set: the
read, the round in each layer, and the rail in the last. None is clear, and
none is as much as a hundredth.

**It is thirty weights of sixty-five thousand.** On the inverted set the
rail holds back 31 of the first layer's 65,469 weights that are not zero,
0.05% of them, and 1.7 of the last layer's 940, with five there at the most
and none at the fewest. On MNIST it holds 76 and 27 and on Fashion-MNIST 165
and 21, and in both layers it leaves those sets 0.024 ± 0.009 and 0.024 ±
0.027. A weight held at the rail is short by a fixed amount, and on the
inverted set its pixel is lit on almost every image: that is reasoned, and
not run. A layer's own error does not say it. On the inverted set the first
layer's is 0.5% larger for its rail, and the last layer's 5.5% for the 1.7
weights held there, which leave nothing.

**The read leaves nothing.** Told apart it leaves 0.000 ± 0.003, 0.002 ±
0.004 and −0.003 ± 0.004, and the reading taken off the model's own line
0.004 ± 0.003, 0.003 ± 0.003 and −0.004 ± 0.004. The two are 0.003, 0.000
and −0.001 apart.

**The round to 8 bits is two or three images either way, and nothing on the
inverted set.** In the first layer it leaves −0.019 ± 0.005, 0.031 ± 0.010
and −0.003 ± 0.009: clear on MNIST, where the networks are right more often
for it, and on Fashion-MNIST, where less. In the last layer −0.003 ± 0.002,
−0.028 ± 0.013 and −0.002 ± 0.021, clear on none; and in both, which grxcp's
model adds network by network, −0.022 ± 0.006, 0.004 ± 0.014 and −0.004 ±
0.023. So of the fifteen figures for a part in a layer on a set, three are
clear, where one in twenty would be by chance: those two, of opposite signs,
and the first layer's rail on the inverted set.

**All three at once leave half of what the comb has on the tile, and
neither is clear.** After the converter all three leave 0.015 ± 0.014, 0.013
± 0.018 and 0.043 ± 0.028. The comb corrected on the tile, which is
`refrows`'s row, has 0.008 ± 0.017, 0.001 ± 0.043 and 0.081 ± 0.044, and
less all three −0.007 ± 0.010, −0.012 ± 0.041 and 0.038 ± 0.022, clear on
none. What the tile's own way of converting the rewritten weights adds is
not told from nothing here.

**The five add up, to within 0.02.** Added network by network in grxcp's
model, the read, the two rounds and the two rails are 0.003 ± 0.011, 0.030 ±
0.019 and 0.056 ± 0.022, and all three at once less that 0.012 ± 0.007,
−0.016 ± 0.008 and −0.013 ± 0.009, clear on none. So on the inverted set all
three at once leave less than the first layer's rail does alone, by 0.026 ±
0.023, which is not clear.

**On the tile the first layer's own error grows more than the three parts
make it.** The probe's `e1` is 4.3%, 0.4% and 3.3% larger with the weights
rewritten on the tile, and 1.3%, −2.1% and 1.2% with all three parts after
the converter. A part is of a weight through its own line. What a row's
light meets in its neighbours' rings, which were rewritten too, is not one
of them: reasoned, and not run. In images it is the paragraph before last's,
and not clear.

**The networks trained before.** All three parts leave them 0.030 ± 0.011,
0.029 ± 0.023 and 0.072 ± 0.053: the rail 0.021 ± 0.012, −0.001 ± 0.005 and
0.047 ± 0.046, the round 0.018 ± 0.008, 0.027 ± 0.022 and 0.028 ± 0.032, and
the read 0.004 ± 0.004, 0.016 ± 0.006 and 0.004 ± 0.006. None of those is
clear. Corrected on the tile the comb has 0.044 ± 0.022, 0.092 ± 0.032 and
0.124 ± 0.049, clear on Fashion-MNIST. The rail holds 17, 33 and 4 of their
first layer's weights and 13, 17 and 1.5 of their last's.

**What was predicted.** Eight things, written on 2026-10-10 at 22:30 UTC,
when the option and its self-test existed and no network had been run
through it. Six were right. The two that were wrong are the two that said
where the rail would be: the last layer was expected, and it is the first.

1. That told apart with no part, a run gets right what the cycle with no
   source of its draw does, in every pair. Right, in all 150. The prediction
   wrote 300, which is a miscount of the same runs.
2. That the read alone is within 0.01 of nothing on every set, and so is the
   reading taken off the model's own line, and the two within 0.01 of each
   other. Right: 0.000, 0.002 and −0.003; 0.004, 0.003 and −0.004; and 0.003,
   0.000 and −0.001 apart.
3. That all three parts after the converter leave 0.00 to 0.03, 0.00 to 0.04
   and 0.04 to 0.12. Right on all three: 0.015, 0.013 and 0.043.
4. That the comb corrected on the tile, less all three after the converter,
   is within 0.04 of nothing on every set and clear on none. Right: −0.007,
   −0.012 and 0.038.
5. That on the inverted set the rail in the last layer is the largest of the
   five, 0.03 or more and over half of all three; that the round is 0.02 or
   less in each layer on every set, and the rail in the first layer too; and
   that on MNIST and Fashion-MNIST each of the five is 0.02 or less. Wrong
   in all but the last on MNIST. On the inverted set the largest is the rail
   in the first layer, 0.069, and the rail in the last is −0.005. The round
   in the first layer is 0.031 on Fashion-MNIST.
6. That on the inverted set the last layer has 0.5% to 3.7% of its weights
   held at the rail, ten times the first layer's share or more. Wrong: 0.18%,
   which is 3.8 times the first layer's.
7. That the five add to all three together within 0.02 on every set. Right:
   0.012, 0.016 and 0.013 off.
8. That for the networks trained before all three leave 0.00 to 0.06, 0.02
   to 0.14 and 0.04 to 0.18, and that on the inverted set the rail in the
   last layer is the largest of the five for them. Right: 0.030, 0.029 and
   0.072, and the rail in the last layer is the largest there at 0.027 ±
   0.021, which is not clear.

**What this is not.** A remedy: nothing here raises a weight past its rail,
and no network here was trained to keep clear of it. A chip: the parts are
added at the host, after the converter, and are first order as the light's
share is. A comb with noise: a shot's noise would meet the weights as
written, and the parts are told apart for a still source only. What the
tile adds when the weights are rewritten on it. A level other than 20%, or
an interval other than six minutes. Five draws, of the same five networks.
Version 1, or another tile.

### The first board's last layer

*Added 2026-10-13.* `SHAPE=chain sim/pta_mnist.sh DIR WORK chain`, and
`pta_mnist eval --host N --gate 1` and `pta_mnist pool`. Reported, not gated.

**Why.** grxcp's B18 made the first development board the GRXGPU charter's
modular carrier. Its first demonstration runs one classifier, 64-64-64-16, on
three engines: the first layer on this core's NPU, the second on the G100, and
the third, 64 inputs to 16 outputs, on the PTA, with the CPU converting between
them. Its Gate F holds the PTA's raw outputs to "normalized RMS error ≤ 1.0%
and maximum absolute error ≤ 2.0% of the reference full-scale output" against
"its declared-format reference", and the final class to that reference's on
99.5% of 1,000 vectors. Nothing said what the tile does on those terms. Every
figure this note had was of D3, 784-100-10 with both layers on the tile, in
points of accuracy lost. And the demonstration does not say what its rms is
divided by.

**A stand-in.** Nobody has that classifier yet. What is run here has its shape
and is ours, not grxgpu's: trained by this harness on the three data sets it
already uses, each image pooled from 28 × 28 to 8 × 8, which is 64 inputs. It
has 16 outputs, of which ten are ever a label. Its weights are 6 bits on an
8-bit operand grid, as every network here has them, where the demonstration's
are int8. Every figure below moves with the network, as the three data sets
show.

**The shape is a build's.** `-DN_SIDE`, `-DN_HID` and `-DN_OUT` set the images'
side, the hidden layers' width and the outputs. D3's are the default, and
everything this note quotes before this section was run on it. A network's file
is as long as its shape makes it, and a build of another shape refuses it for
its length. `SHAPE=chain` has the script build with 8, 64 and 16 and gives a
new work directory its images pooled: `pta_mnist pool IN OUT` cuts the middle
24 × 24 of each image into 64 blocks of nine and takes each block's mean, to
the nearest. Such a directory is marked, runs `chain` and nothing else, and
`chain` runs in no other.

**The options.** `--host N` runs a network's first N layers on the host and the
rest on the tile. A host layer's sums are the exact product of its operands as
they are and its weights as its own quantiser has them, with no shot, no
converter and no GEMM launched: what a digital engine gives. It is refused with
~~a light source,~~ `--thermalline`, `--hidshift` or `--w1gain`, which are
written for a network that is all on the tile. *A light source is taken since
the same day: this section's last part, "with a light source switched on".*
`--gate 1`, with `--probe`, measures the
last layer against a second reference, in its declared format: the exact
product of the activations at the tile's own bits and the weights as the
network has them. A run prints `gate_bits`; `gate_rms`, its rms error over that
reference's rms; `gate_rmsfs`, the same over the largest that reference is,
`gate_peak`; `gate_maxfs`, its largest error over that largest; `gate8_rmsfs`,
`gate8_maxfs` and `gate8_peak`, the last three against the operands as they
were given, where the probe's `e3` is already the rms over the rms; `gate_ref`,
how often the declared reference is right; and `gate_agree`, how often the
class the tile gives is the class that reference gives, where `agree` is
against the host's.

Like the probe they are on the host's side of the line: §4, PTM-C and the RTL
are untouched, and a line printed without them is what it was. The self-test's
37 lines are as they were, with three more. A build of another shape runs the
tests that are of any shape and says in a line that it has not run the rest,
which are written to D3's layers, its file's length and tiles chosen for it: 25
lines in all. And with the script and the binary as they now are, `refcomb`'s
check and its tables alone, on the lines its own sweep wrote for MNIST, say yes
and print the 97 lines that sweep printed.

The self-test runs a three-layer network of made-up weights with none, the
first and the first two of its layers on the host, with the quantisers and
without, 37 images each: every sum is the network's as it was asked for, only
the tile's layers are launched, and a programming error reaches its own layer
and no layer the host runs. For the gate's figures: with nothing impaired there
is no error against either reference; with the quantisers on and no converter
the tile is its declared format exactly and is off the operands as given; and
with a programming error as well the figures are the ones worked out there from
the sums, 0.0125 of the declared reference's rms, 0.0060 and at the most 0.0114
of its largest. For the class, the network's outputs are levelled so that an
error moves it: with activations of 2 bits the tile gives its declared
reference's class on all 37 images where that reference and the host part on
all 37, and with a programming error of 32 LSB the tile and its reference part
on 27. And `pool`: two made-up images to 8 × 8, to 14 × 14 and to 28 × 28, with
the margin not counted, and sides and files it cannot pool refused.

65 errors planted in that code one at a time were each built at both shapes. 63
fail the self-test where they have to: 61 at both shapes, and the two that are
of one shape, at theirs. The other two each fail at one shape and pass at the
other. The largest error taken with its sign passes at the chain's shape, where
that error is above zero and the same either way. And the declared reference
counted right where the tile is right passes at D3's, where no image of the 37
tells the two apart.

**What it runs.** The thirteenth mode, on a network of its own shape. Five
seeds, and two kinds as before: 6-bit weights from that seed's 8-bit network as
the plan's were trained, and the reference recipe, eight epochs with noise of
10% on all three layers' sums. Version 2 on the 128 × 64 tile, with `--host 2
--probe 1 --gate 1`: the first two layers on the host and the last on the tile,
which is one launch of sixteen sums an image. Six rows on each of five draws:

| Row | What it is |
|---|---|
| format only | The tile's declared format and nothing else: `--impair quant --abits 6 --adcbits 8` |
| as budgeted | Version 2, every row of its budget on |
| cycle | That, aged six minutes, calibrated with sixteen probes and its trims written, and aged six minutes again, with `--trimstep 1` |
| each of them, a thousand | The same on the test set's first thousand images, `--images 1000` |

No source is lit: the harness lights whole networks, and a layer the host runs
has no light. The tile as budgeted is read over the format alone of its draw,
and a cycle over the tile as budgeted. That is 300 evaluations a data set. The
three ran side by side on four jobs each in 4.4 minutes, on 2026-10-13 at 02:55
UTC. It was the second run: the first, on 2026-10-11 at 17:07 UTC, was before
`gate_ref` and `gate_agree` existed, and all 900 of its lines are the second's
but for those two fields.

The mode checks every network and every run against its place, as the twelve
before it do. A network has two hidden layers, 6-bit weights and its seed, and
came from that seed's 8-bit one; a reference was trained for eight epochs with
the noise it was asked on all three layers. A run's name says its draw, whether
it is the format alone, the tile as budgeted or a cycle, and whether it is of a
thousand images or of all, which have to be what it was asked and what its line
printed. Every run has its first two layers on the host and the last on the
tile: the first two layers' own error is nothing and the last's is something,
its sums are sixteen an image, and no more than one in a hundred of them is
past the converter's range. It has the gate's figures, with no rms over a
largest value past the largest error over it, and a declared reference that is
right as often as in the format alone of the first draw, since no draw moves
it. The format alone has the quantisers and nothing else, and on every draw
gets right what it gets right on the first.

206 errors planted one at a time each fail: 98 in a training's line or a run's
line, against the check with nothing run again; 45 in the script, each run in a
directory of its own on 400 images and on 100; and 63 in the tables' own code,
which the check does not see and which each have to move a table.

**In steps of the converter the tile is a step and a half off its declared
format.** A row's rms error against its declared format, a mean over its 25
runs, on 10,000 images unless it says:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone: rms, % of the reference's rms | 0.96 | 0.71 | 0.91 | 1.04 | 0.85 | 0.76 |
| As budgeted | 4.81 | 4.46 | 4.54 | 4.67 | 4.28 | 4.18 |
| A cycle | 4.84 | 4.50 | 4.55 | 4.69 | 4.33 | 4.23 |
| As budgeted: % of the largest the reference is | 1.67 | 1.57 | 1.28 | 1.27 | 1.47 | 1.48 |
| As budgeted: in steps of the converter | 1.45 | 1.83 | 1.44 | 1.43 | 1.55 | 1.60 |
| As budgeted: % of the converter's full scale | 1.14 | 1.44 | 1.13 | 1.13 | 1.22 | 1.26 |
| As budgeted, the first thousand images: % of the reference's rms | 4.87 | 4.52 | 4.54 | 4.67 | 4.34 | 4.24 |
| % of the largest the reference is | 1.79 | 1.72 | 1.42 | 1.42 | 1.59 | 1.54 |
| % of the converter's full scale | 1.11 | 1.40 | 1.13 | 1.12 | 1.19 | 1.22 |

As budgeted that is 1.43 to 1.83 steps, and 1.43 to 1.84 at the end of a cycle,
which is never under the tile as budgeted and never more than 0.02 of a step
over it. The format alone is 0.289 to 0.307 of a step, which is a converter's
rounding, 0.289, and more only where a sum is past the range. The steps are
grxcp's arithmetic on these lines (`docs/designs/pta_board_chain.py`):
`gate_rmsfs` times `gate_peak`, over two to the last layer's shift.

**What that is in percent is what it is divided by.** 4.2 to 4.8% of the
reference's rms, 1.3 to 1.7% of the largest the reference is, 1.1 to 1.4% of
the converter's full scale of 127 steps, and 0.56 to 0.72% of its whole span.
The demonstration's 1.0% is under three of those and over the fourth. Of the
150 runs as budgeted, 0, 0, 20 and 150 are within 1.0%; of the 150 on the first
thousand images, 0, 0, 25 and 150. The 20 are four networks whose converter has
the larger step, which the same error is fewer steps of.

**The largest error is within 2.0% on none of them.** Against the declared
format, percent of the largest the reference is:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone: a mean over the runs | 0.58 | 2.14 | 0.45 | 7.22 | 3.16 | 0.47 |
| the most in any run | 0.67 | 8.88 | 0.48 | 24.05 | 11.78 | 0.51 |
| As budgeted: a mean | 8.44 | 8.02 | 7.20 | 11.53 | 8.60 | 7.44 |
| the most | 9.70 | 8.97 | 8.19 | 24.05 | 11.78 | 8.59 |
| in the row's own rms errors | 5.1 | 5.1 | 5.6 | 9.5 | 5.9 | 5.0 |
| As budgeted, the first thousand images: a mean | 8.42 | 7.69 | 7.18 | 7.53 | 7.47 | 7.16 |
| the most | 9.72 | 9.97 | 8.42 | 9.40 | 9.98 | 8.59 |
| in the row's own rms errors | 4.7 | 4.5 | 5.1 | 5.3 | 4.7 | 4.6 |
| % of the converter's full scale, a mean | 5.22 | 6.24 | 5.72 | 5.96 | 5.51 | 5.67 |

As budgeted its mean is 7.2 to 11.5% on 10,000 images and 7.2 to 8.4% on the
first thousand; 5.2 to 6.2% of the converter's full scale there, and 2.6 to
3.1% of its span. No run of the 300 is within 2.0% on any of the three, and the
least any run has is 6.1% of the largest the reference is.

**Because a largest error is a tail.** On the first thousand images it is 4.5
to 5.3 of the row's own rms errors. The largest of 16,000 figures with Gaussian
noise on them sits about 4.4 rms out, and of 160,000 about 4.9. A bound on the
largest at twice the bound on the rms is one a digital engine meets and noise
does not. It binds first, by 2.2 times, and it moves with how many outputs are
looked at.

**The format alone meets both where no sum is past the converter's range.** Its
rms is 0.71 to 1.04% of the reference's rms, 120 runs of 150 within 1.0%, and
0.25 to 0.33% of the largest the reference is, all 150. In the 125 runs with no
sum past the range its largest error is 0.40 to 0.67%.

**And the range decides the rest.** The harness sets a converter's range on a
thousand training images, to pass all but one sum in ten thousand:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| Networks of five whose reference reaches past full scale | 0 | 1 | 0 | 2 | 2 | 0 |
| The farthest any reaches, of full scale | 0.80 | 1.11 | 0.97 | 1.33 | 1.14 | 0.94 |
| The format alone: the most sums past the range in a run, of 160,000 | 0 | 14 | 0 | 77 | 26 | 0 |
| its largest error with none past it, % | 0.67 | 0.49 | 0.48 | 0.58 | 0.60 | 0.51 |
| and with some | none | 8.88 | none | 24.05 | 11.78 | none |
| As budgeted: the most sums past it in a run | 0 | 27 | 0 | 161 | 52 | 0 |

5 of the 30 networks have a declared reference that reaches past the
converter's full scale on the test set, to 1.03 to 1.33 of it, and 2 on its
first thousand images. With the format alone and no noise their largest error
is 2.2 to 24.1% of the largest the reference is, from 3 to 77 sums of 160,000.
It is what the reference is past the converter's last code by, to the rounding.
No run has more than 0.18% of its sums past the range. That rule was written
for the class, which a clipped sum seldom moves. A gate on the largest error
needs a range that clips nothing, and a step that is larger for it. ~~That was
not run.~~ *Run the same day: the section after this one.*

**The class, as the gate has it.** How often the class the tile gives is the
class its declared reference gives, percent, a mean over a row's runs; and in
brackets the runs of 25 at 99.5% or more:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone | 99.74 (25) | 99.85 (25) | 98.16 (0) | 98.49 (0) | 99.54 (15) | 99.73 (25) |
| As budgeted | 99.40 (2) | 99.59 (23) | 95.92 (0) | 96.78 (0) | 98.86 (0) | 99.23 (0) |
| A cycle | 99.36 (4) | 99.57 (24) | 95.92 (0) | 96.75 (0) | 98.86 (0) | 99.21 (0) |
| The format alone, the first thousand images | 99.74 (25) | 99.76 (25) | 97.96 (0) | 98.58 (0) | 99.56 (10) | 99.64 (20) |
| As budgeted, the first thousand | 99.25 (6) | 99.49 (13) | 96.01 (0) | 96.85 (0) | 98.80 (2) | 99.10 (1) |
| A cycle, the first thousand | 99.31 (5) | 99.47 (14) | 95.72 (0) | 96.76 (0) | 98.79 (0) | 99.12 (5) |

On the first thousand images the reference networks are at 99.49, 96.85 and
99.10% as budgeted, and 13, 0 and 1 runs of 25 pass. So on MNIST they are at
the gate, and it is a draw which side of it a run falls. The networks trained
before are under it there, and on the other two sets every mean is under it, by
0.3 to 3.6 points.

**A converter's rounding already moves the class.** The format alone is off its
declared reference by the rounding of an 8-bit converter and by the sums past
its range, and nothing else. For the reference networks it gives that
reference's class on 99.85, 98.49 and 99.73% of 10,000 images. Of the images
the tile and its declared reference part on as budgeted, 0.41, 3.22 and 0.77%,
that is 36, 47 and 35%.

**Against the host it is less, and most of that is the format.** The host has
the activations at 8 bits, where the tile's declared format has 6:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone | 99.60 (25) | 99.57 (25) | 96.80 (0) | 97.73 (0) | 99.01 (0) | 99.30 (0) |
| As budgeted | 99.30 (0) | 99.43 (5) | 95.14 (0) | 96.37 (0) | 98.53 (0) | 98.97 (0) |
| A cycle | 99.27 (0) | 99.41 (3) | 95.06 (0) | 96.34 (0) | 98.53 (0) | 98.96 (0) |
| The format alone, the first thousand images | 99.56 (20) | 99.42 (15) | 96.76 (0) | 97.84 (0) | 98.64 (0) | 99.08 (5) |
| As budgeted, the first thousand | 99.20 (5) | 99.34 (9) | 95.23 (0) | 96.46 (0) | 98.31 (0) | 98.79 (1) |
| A cycle, the first thousand | 99.20 (5) | 99.29 (6) | 95.02 (0) | 96.40 (0) | 98.30 (0) | 98.71 (0) |

Of the images the reference networks' tile and host part on as budgeted, 0.57,
3.63 and 1.03% of 10,000, the format alone has 75, 62 and 68%. The tile gives
its declared reference's class more often than its host's in every row.

**How often right.** The host, the declared reference and the format alone on
the tile, percent; and what a row adds over the row it is read over, in points
lost, with what five networks put outside chance at one in twenty in bold:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| On the host, % | 96.92 | 97.09 | 83.35 | 83.82 | 94.04 | 95.39 |
| The declared reference, % | 96.87 | 97.01 | 83.17 | 83.76 | 93.91 | 95.31 |
| The format alone, % | 96.85 | 97.00 | 83.18 | 83.64 | 93.82 | 95.21 |
| As budgeted adds | 0.07 ± 0.03 | 0.03 ± 0.02 | **0.33 ± 0.04** | **0.17 ± 0.04** | 0.00 ± 0.05 | 0.02 ± 0.03 |
| A cycle adds | 0.02 ± 0.01 | 0.01 ± 0.02 | 0.01 ± 0.04 | 0.02 ± 0.06 | 0.03 ± 0.01 | 0.01 ± 0.02 |

As budgeted the tile loses 0.03 ± 0.02, 0.17 ± 0.04 and 0.02 ± 0.03 for the
reference networks over the format alone: clear on Fashion-MNIST for both
kinds, and nowhere else. The end of a cycle adds 0.01 ± 0.02, 0.02 ± 0.06 and
0.01 ± 0.02, clear on none. Against their host the reference networks lose
0.12, 0.35 and 0.19.

**The reference networks.** They give their declared reference's class more
often than the networks trained before give theirs, by 0.18, 0.86 and 0.38 of a
point as budgeted, on the same error: 4.2 to 4.7% of the reference's rms where
the others have 4.3 to 4.8%. It is the margin that training with noise buys,
and not a quieter tile.

**What was predicted.** Nine things, written on 2026-10-11 at 17:06 UTC, when
the options, the mode and their self-tests existed and no network of this shape
had been trained or run. And three more on 2026-10-13 at 02:54 UTC, after the
first run was read and before the class against the declared reference was
counted in any. All are for the reference networks. Four of the twelve were
right as written. Of the eight that were not, seven were right in part, as each
says.

1. That the rms over the reference's rms is 3.5 to 7% as budgeted, and no run
   is within 1.0%. Right: 4.46, 4.67 and 4.18, and none of 75.

2. That over the largest the reference is it is 0.5 to 2.0%, with the 1.0% line
   among a set's runs. Wrong: the size is right, 1.57, 1.27 and 1.48, and no
   run is within 1.0%.

3. That the largest error is 2.5 to 8% of the largest the reference is on
   10,000 images, and 2 to 6% on the first thousand, with no run of all within
   2.0% and at most five of a thousand. Wrong on its size: 8.02, 11.53 and
   7.44, and 7.69, 7.53 and 7.16 on the first thousand. No run is within 2.0%.

4. That against the operands as given the rms is 6 to 9% of the rms, a third or
   more of it the format's. Right: 7.24, 7.28 and 6.49, and the format alone is
   half of it.

5. That the class is the host's on 99.0 to 99.7, 96.5 to 98.5 and 98.5 to 99.6%
   of 10,000 images, and that on the first thousand 5 to 20 runs of 25 are at
   99.5% on MNIST, none on Fashion-MNIST and 1 to 15 on the inverted set.
   Wrong, by Fashion-MNIST's mean: 99.43, 96.37 and 98.97, and 9, 0 and 1 runs.

6. That the format alone agrees with the host on 99.5 to 99.95% on MNIST and
   98.5 to 99.6% on Fashion-MNIST, and is a third or more of what the tile
   disagrees on. Wrong, by Fashion-MNIST's again: 99.57 and 97.73. The share is
   two thirds.

7. That the tile loses 0.00 to 0.15, 0.10 to 0.50 and 0.00 to 0.25 of a point
   to its host, and a cycle adds 0.05, 0.10 and 0.15 at the most, clear on
   none. Right: 0.12, 0.35 and 0.19, and 0.01, 0.02 and 0.01.

8. That the reference networks agree with their host at least as often as those
   trained before agree with theirs, on two sets or on all. Right, on all
   three.

9. That the largest the declared reference is, is 0.6 to 1.05 of the
   converter's full scale. Wrong: three of the fifteen reach past that, to
   1.33. It is the one that mattered: the largest errors come from there.

10. That the tile gives its declared reference's class on 99.45 to 99.70, 97.0
    to 97.9 and 99.0 to 99.4% of 10,000 images, and that on the first thousand
    8 to 20 runs of 25 are at 99.5% on MNIST, none on Fashion-MNIST and 0 to 6
    on the inverted set. Wrong, by Fashion-MNIST's mean, a fifth of a point
    under: 99.59, 96.78 and 99.23, and 13, 0 and 1 runs.

11. That the format alone gives its declared reference's class on 99.85 to
    99.97, 99.1 to 99.7 and 99.7 to 99.92%. Wrong, by Fashion-MNIST's: 99.85,
    98.49 and 99.73. A converter's rounding parts more of that set's images
    from their class than its error's size said.

12. That the declared reference is right within 0.05 of a point as often as the
    format alone is on the tile. Wrong on two sets: 0.02, 0.11 and 0.10 of a
    point apart.

**What this is not.** grxgpu's classifier, its data or its thresholds. A chip.
The chain: the NPU and the G100 are taken as exact, and the CPU's conversions
as this harness's own rescale. A lit tile: grxcp's source rows add to all of
it, and are not in these figures. *They are run the same day: "with a light
source switched on", below.* Int8 weights. A range set for the gate: the
converter's is the one this harness has always set, for the class. A ruling on
what full scale is: that is grxgpu's, and three readings of it are priced. Five
draws, of the same five networks. Version 1, or another tile.

### The first board's last layer, with a range that clips nothing

*Added 2026-10-13.* `SHAPE=chain sim/pta_mnist.sh DIR WORK chainfit`, and
`pta_mnist eval --gatefit F`. Reported, not gated.

**Why.** The section before found the largest error of the first board's last
layer decided, in five networks of thirty, by the converter's range and not by
noise. This harness sets a range on a thousand training images, to pass all but
one sum in ten thousand: a rule for the class, which a clipped sum seldom
moves. The charter's demonstration holds the layer's raw outputs to a
reference, and says to "define full scale from the frozen golden manifest".
That was not run. This is it.

**The option.** `--gatefit F`, with `--gate`, `--adcbits` and every layer but
the last on the host. With those layers on the host the last layer's declared
reference is known before a shot is taken. The host works it out over the
images that are to be run, takes the largest a tile's sum of it is, and gives
the last converter the smallest shift at which that largest is within the share
F of its full scale: of 127 codes for an 8-bit converter with F of 1, which
fits it, and of 63 with F of 0.5, which leaves a bit to spare. A run prints
`gate_fit`, the share, and `gate_was`, the shift training's rule had given; `S`
and `S8` have the fitted one. After the run it holds the probe's largest
reference to the one it fitted to, where the last layer is one tile's sum and
the two are the same thing, and stops if they differ.

**What a range costs, as it is modelled.** A noise figure in LSB names its
converter. grxcp's version 2 has the receiver's noise at 0.25 of an LSB of an
8-bit converter and the light at 30 photons an LSB. A converter's range is
hardware, and a sum is brought inside it by turning the light or the gain down.
So the fitted converter's noise is in its own LSB: `S8`, which names the LSB
the noise is in, is fitted with `S`. With a step twice as large the rounding
and the receiver's noise are twice as large in a sum's own units and the shot
noise root two times; the programming error and the crosstalk, which go with
the sum, are what they were. A converter with a bit more, at the step it had,
is the other way to buy range, and is not this. *It is the section after this
one, run the same day.*

Like the probe it is on the host's side of the line: §4, PTM-C and the RTL are
untouched, and a line printed without it is what it was. The self-test's 40
lines are as they were, with one more, and a build of the chain's shape prints
26 lines. It refuses a share of nothing, a share over all of full scale and one
that leaves the converter no code, and refuses to run without the gate's
figures, without a converter, or with any layer but the last on the tile: 7
refusals, each tried. And with the script and the binary as they now are,
`refcomb`'s and `chain`'s checks and tables alone, on the lines their own
sweeps wrote for MNIST, say yes and print what those sweeps printed.

The self-test puts a three-layer network of made-up weights on the 128 × 64
tile, which takes its last layer whole, with the first two layers on the host.
The largest its declared reference is over 37 images is found all at once or a
batch at a time, with nothing launched, and is the probe's. The fitted shift,
11, is the smallest at which it is within full scale, and 12 within half of it.
With the format alone no sum is past the fitted range and none is off its
reference by more than half a step; two steps under it 151 sums are, and one by
141 of that step. 17 errors planted in that code one at a time were each built
at both shapes, and each fails the self-test at both.

The option's code inside `cmd_eval` is reached by no self-test, so it is tested
through the mode. 11 errors planted in it one at a time were each built into
the harness and the mode run with it, as written, on 400 images and on 100.
Each fails: 8 at the mode's check, and 3 where the run stops itself because the
probe's reference is not the one the range was fitted to.

**What it runs.** The fourteenth mode, in `chain`'s work directories and on its
networks, tile and draws. Twelve rows on each of five draws:

| Row | What it is |
|---|---|
| format only; as budgeted | `chain`'s two rows, with the range training's rule gives: its own runs |
| each of them, fitted | With `--gatefit 1`: the smallest step at which the largest the declared reference is, is within the converter's 127 codes |
| each of them, a bit spare | With `--gatefit 0.5`: within half of them, which is one bit of headroom over fitted |
| each of those six, a thousand | The same on the test set's first thousand images, each fitted to those thousand |

A fitted row is read over its own row with training's range, and a row with a
bit spare over the fitted one, draw for draw. That is 600 evaluations a data
set. The rows with training's range are `chain`'s own runs, and where a
directory has what `chain` wrote the mode holds each to that line, byte for
byte: 200 a data set, all the same.

It was run twice, on 2026-10-13. The first run, at 13:39 UTC and 7.9 minutes
for the three data sets side by side, wrote its 1,800 lines and stopped at the
mode's own check, which was wrong: it held the format alone, fitted, to getting
right what the format alone gets right with training's range, where a fitted
step that moved rounds differently. The check was put right, to hold a format
row to its own row's first draw, and the mode run again at 13:55 UTC, 18.4
minutes on a machine that was doing other work. Every line of the first run is
the second's, byte for byte.

The mode checks every network and every run against its place, as `chain` does
its own. A run's name says its draw, whether it is the format alone or the tile
as budgeted, whether its range is training's, fitted or with a bit spare, and
whether it is of a thousand images or of all, which have to be what it was
asked and what its line printed. A run with training's range says nothing of a
fit. A fitted run says the share it was asked and the shift training's rule had
given, which has to be the one the format alone of the first draw has. Its last
shift has to be the smallest at which the largest its declared reference is, is
within that share of 127 codes, worked out again from the line, and has to be
its 8-bit shift too. That largest has to be the one the row with training's
range has, since a range does not move a reference. The format alone, fitted or
with a bit spare, may have no sum past its range. A fitted run whose shift is
the one it had has to be the run with training's range of its draw, figure for
figure. And a run with a bit spare has to have a larger shift than the fitted
run of its draw.

149 errors planted one at a time each fail: 72 in a training's line or a run's
line, against the check with nothing run again, one of them a row with
training's range that is not the line `chain` wrote; 30 in the script, each run
in a directory of its own on 400 images and on 100; and 47 in the tables' own
code, which the check does not see and which each have to move a table.

**Fitted, no sum is past the range, with the noise or without it.** Not one, in
any of the 600 fitted runs, where 70 of the same 600 with training's range had
one:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| Networks of five whose step is larger, fitted | 0 | 1 | 0 | 2 | 2 | 0 |
| on the first thousand images | 0 | 0 | 0 | 1 | 1 | 0 |
| Training's range, as budgeted: the most sums past it in a run, of 160,000 | 0 | 27 | 0 | 161 | 52 | 0 |
| Fitted | 0 | 0 | 0 | 0 | 0 | 0 |
| A bit spare | 0 | 0 | 0 | 0 | 0 | 0 |

Fitting moves the step of 5 networks of 30 on 10,000 images and of 2 on the
first thousand, by one bit each, and makes none smaller. They are the networks
whose reference reached past training's range. The others' fitted runs are the
runs they were. With a bit spare every network has one bit more than fitted.
That the noise pushes no sum past a fitted range was not expected: the largest
sums are few, and 0.97 of full scale at the most.

**The format alone then meets the 2.0% in every run.** Its largest error is
0.40 to 0.77% of the largest the reference is, where it was as much as 24.05%:
half a step of a converter at the most. All 300 runs are within 2.0%, where 270
were.

**As budgeted the largest error is then the noise's alone, and is still not
within 2.0%.** Percent of the largest the reference is, on 10,000 images unless
it says:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| Training's range: a mean over the runs | 8.44 | 8.02 | 7.20 | 11.53 | 8.60 | 7.44 |
| the most in any run | 9.70 | 8.97 | 8.19 | 24.05 | 11.78 | 8.59 |
| Fitted: a mean over the runs | 8.44 | 7.95 | 7.20 | 7.92 | 8.33 | 7.44 |
| the most in any run | 9.70 | 8.97 | 8.19 | 8.95 | 9.64 | 8.59 |
| A bit spare: a mean over the runs | 11.16 | 10.23 | 9.33 | 10.55 | 11.02 | 9.63 |
| the most in any run | 13.38 | 12.70 | 10.57 | 11.84 | 13.89 | 11.40 |
| Fitted, the first thousand images: a mean | 8.42 | 7.69 | 7.18 | 7.60 | 7.93 | 7.16 |
| the most | 9.72 | 9.97 | 8.42 | 9.40 | 10.16 | 8.59 |
| The format alone, fitted: the most in any run | 0.67 | 0.71 | 0.48 | 0.70 | 0.76 | 0.51 |

Fitted, its mean over a set's runs is 7.2 to 8.4%, where it was 7.2 to 11.5%,
and the most in any run 9.7%, where it was 24.1%. In the run's own rms errors
it is 4.9 to 5.8, where it was 5.0 to 9.5: within an rms of where the largest
of 160,000 figures with Gaussian noise on them sits, on every set. No run of
the 300 as budgeted is within 2.0%, and the least is 6.1%.

**What it costs is a fifth more error, for the networks it moves.** A row's rms
error against its declared format, as budgeted on 10,000 images:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| Training's range: rms, % of the reference's rms | 4.81 | 4.46 | 4.54 | 4.67 | 4.28 | 4.18 |
| Fitted | 4.81 | 4.64 | 4.54 | 5.05 | 4.61 | 4.18 |
| A bit spare | 6.05 | 5.75 | 5.75 | 6.75 | 6.05 | 5.23 |
| Training's range: in steps of its own converter | 1.45 | 1.83 | 1.44 | 1.43 | 1.55 | 1.60 |
| Fitted | 1.45 | 1.67 | 1.44 | 1.15 | 1.24 | 1.60 |
| A bit spare | 0.91 | 1.03 | 0.91 | 0.77 | 0.82 | 1.00 |
| Training's range: % of its converter's full scale | 1.14 | 1.44 | 1.13 | 1.13 | 1.22 | 1.26 |
| Fitted | 1.14 | 1.32 | 1.13 | 0.91 | 0.98 | 1.26 |
| A bit spare | 0.72 | 0.81 | 0.72 | 0.61 | 0.64 | 0.79 |

A network whose step grew by a bit has 1.20 to 1.24 times the rms error it had,
in the sum's own units: its error against one reference with the larger step,
over its error with the smaller, draw for draw. So a set's rms goes from 4.46
to 4.64% of the reference's rms for MNIST's reference networks, of which one
moves; from 4.67 to 5.05% for Fashion-MNIST's, two; and from 4.28 to 4.61% for
the inverted set's networks trained before, two. The other three sets of five
are what they were.

**A bit spare costs a quarter more again, and every network pays it.** With one
more bit of range than fits, a network has 1.21 to 1.38 times its fitted rms
error, 1.28 in the mean of the thirty. The rms is then 5.2 to 6.8% of the
reference's rms, and the largest error 9.3 to 11.2% of the largest the
reference is.

**And as a share of full scale it reads better.** The same error is 1.43 to
1.83 steps of the converter with training's range, 1.15 to 1.67 fitted and 0.77
to 1.03 with a bit spare, each in the steps of the converter the row has. Of
the 150 runs as budgeted, 20, 45 and 150 are within 1.0% of the converter's
full scale, and 0, 0 and 0 within 1.0% of the reference's rms. A bound that is
a share of full scale, or a number of steps, is met by declaring a larger full
scale, while the tile gets worse.

**The class.** How often the class the tile gives is the class its declared
reference gives, percent, and in brackets the runs of 25 at 99.5% or more; on
10,000 images unless it says:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| Training's range, as budgeted | 99.40 (2) | 99.59 (23) | 95.92 (0) | 96.78 (0) | 98.86 (0) | 99.23 (0) |
| Fitted | 99.40 (2) | 99.55 (20) | 95.92 (0) | 96.20 (0) | 98.66 (0) | 99.23 (0) |
| A bit spare | 98.94 (0) | 99.26 (1) | 93.18 (0) | 93.20 (0) | 97.73 (0) | 98.83 (0) |
| Training's range, the first thousand images | 99.25 (6) | 99.49 (13) | 96.01 (0) | 96.85 (0) | 98.80 (2) | 99.10 (1) |
| Fitted | 99.25 (6) | 99.49 (13) | 96.01 (0) | 96.60 (0) | 98.65 (2) | 99.10 (1) |
| A bit spare | 98.73 (0) | 99.22 (3) | 93.27 (0) | 94.11 (0) | 97.69 (0) | 98.57 (0) |
| Training's range, the format alone | 99.74 (25) | 99.85 (25) | 98.16 (0) | 98.49 (0) | 99.54 (15) | 99.73 (25) |
| Fitted | 99.74 (25) | 99.81 (25) | 98.16 (0) | 97.97 (0) | 99.36 (5) | 99.73 (25) |
| A bit spare | 99.38 (5) | 99.59 (20) | 95.70 (0) | 95.31 (0) | 98.54 (0) | 99.43 (10) |

As budgeted and fitted the reference networks give that class on 99.55, 96.20
and 99.23% of 10,000 images, where they gave it on 99.59, 96.78 and 99.23%. On
the first thousand it is 99.49, 96.60 and 99.10%, with 13, 0 and 1 runs of 25
at 99.5%: on MNIST and on the inverted set no reference network moves there,
and those are the runs they were. With a bit spare it is 99.26, 93.20 and
98.83% of 10,000, and 3, 0 and 0 runs on the first thousand. The format alone
with a bit spare is at 99.59, 95.31 and 99.43%: a converter that rounds twice
as coarsely moves the class by itself.

**In points of accuracy.** What a row adds over the row it is read over, in
points lost, with what five networks put outside chance at one in twenty in
bold:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| With training's range, as budgeted, % | 96.79 | 96.97 | 82.85 | 83.47 | 93.82 | 95.19 |
| Fitted adds | 0.00 ± 0.00 | 0.02 ± 0.02 | 0.00 ± 0.00 | 0.12 ± 0.07 | 0.08 ± 0.06 | 0.00 ± 0.00 |
| A bit spare adds, over fitted | **0.18 ± 0.05** | 0.10 ± 0.04 | **0.75 ± 0.13** | **0.94 ± 0.12** | **0.44 ± 0.11** | **0.17 ± 0.02** |
| The format alone: fitted adds | 0.00 ± 0.00 | 0.01 ± 0.01 | 0.00 ± 0.00 | 0.01 ± 0.02 | 0.06 ± 0.04 | 0.00 ± 0.00 |
| a bit spare adds, over fitted | 0.11 ± 0.05 | 0.05 ± 0.02 | 0.46 ± 0.20 | **0.57 ± 0.18** | 0.21 ± 0.14 | 0.02 ± 0.05 |

Fitting loses the reference networks 0.02 ± 0.02, 0.12 ± 0.07 and 0.00 ± 0.00,
clear on none. A bit spare loses them 0.10 ± 0.04, 0.94 ± 0.12 and 0.17 ± 0.02
more: clear on Fashion-MNIST and on the inverted set.

**What was predicted.** Nine things, written on 2026-10-13 at 13:38 UTC, when
the option, the mode and their self-tests existed and the option had run no
network. All are for the reference networks. Four were right as written.

1. That fitted, the step grows for 5 networks of 30 on 10,000 images and for 2
   on the first thousand, by a bit each, and shrinks for none; and that with a
   bit spare every step is one bit more than fitted. Right.

2. That the format alone, fitted, has a largest error of 0.4 to 0.85% in every
   one of its 150 runs, all within 2.0% where 125 were, and 90 to 100 runs
   within 1.0% of the reference's rms where 120 were. Right: 0.40 to 0.76%, and
   95 runs.

3. That a step a bit larger costs 1.3 to 1.5 times in rms, so that fitted the
   rms is 4.6 to 5.0, 5.1 to 5.6 and 4.18% of the reference's rms, and with a
   bit spare 6.3 to 7.1, 7.0 to 8.0 and 5.6 to 6.2%. Wrong: it costs 1.20 to
   1.24 times, and the rms is 4.64, 5.05 and 4.18 fitted and 5.75, 6.75 and
   5.23 with a bit spare. The shot noise was taken for more of the error than
   it is.

4. That the runs of 150 within 1.0% of the converter's full scale are 20 with
   training's range, 38 to 46 fitted and 135 to 150 with a bit spare, and that
   none is within 1.0% of the reference's rms. Right: 20, 45 and 150, and none.

5. That as budgeted and fitted the largest error is 7.3 to 9.0% of the largest
   the reference is on every set and kind, under 12.5% in every run, and within
   2.0% in none. Wrong, by one set's mean: Fashion-MNIST's networks trained
   before are at 7.20%, which no fit moved and `chain` had already printed. The
   most in any run is 9.70%, and none is within 2.0%.

6. That as budgeted and fitted 5 to 40 runs of 150 still have a sum past the
   range, for the noise, and with a bit spare none. Wrong: fitted, none has
   one.

7. That fitted, the class is the declared reference's on 99.52 to 99.59, 96.1
   to 96.6 and 99.23% of 10,000 images, and on the first thousand on 99.49%
   with 13 runs at 99.5%, 96.5 to 96.85%, and 99.10% with 1. Right: 99.55,
   96.20 and 99.23, and 99.49, 96.60 and 99.10.

8. That with a bit spare the class is the declared reference's on 99.33 to
   99.46, 94.6 to 95.5 and 98.82 to 98.97% of 10,000 images, with 3 to 9 runs
   of 25 at 99.5% on MNIST's first thousand. Wrong: 99.26, 93.20 and 98.83.
   Fashion-MNIST is a point and a half under what was written.

9. That fitting adds 0.00 to 0.03, 0.02 to 0.15 and nothing in points of
   accuracy, clear on none, and a bit spare 0.00 to 0.06, 0.08 to 0.30 and 0.00
   to 0.08 more, clear on Fashion-MNIST alone. Right of fitting. Wrong of a bit
   spare: 0.10, 0.94 and 0.17, three times what was written on Fashion-MNIST,
   and clear on the inverted set too.

**What this is not.** Everything the section before says of itself: a stand-in
classifier, in a model, with the chain's other engines taken as exact and no
source lit. A range a board could set without its golden manifest: this one is
fitted to the very images it is then run on. A converter with more bits. A
remedy for the largest error, which is the noise's and is where it was. Five
draws, of the same five networks.

### The first board's last layer, with a converter of one more bit

*Added 2026-10-13.* `SHAPE=chain sim/pta_mnist.sh DIR WORK chainbit`, and
`pta_mnist eval --gatebits B`. Reported, not gated.

**Why.** The section before bought a range that clips nothing by fitting the
last converter to its declared reference, and found the price: the five
networks of thirty whose range it widens have a fifth more rms error, because
the noise is in the converter's LSB and a wider range at eight bits is a larger
LSB. It said the other way to buy range was not run: a converter with one more
bit, at the step it had. This is that, and with it the other thing a ninth bit
can be spent on.

**The option.** `--gatebits B`, with `--gate` and `--adcbits`, and B from
`--adcbits`' value to 15. The last layer's converter has B bits and the others
what `--adcbits` gives them. Its shift is still the one `adc_setup()` found for
the run's width, so one bit more is twice the codes at the same step: 255 where
there were 127. `S` and `S8` are what they were, and so is the noise, which is
in that LSB. With `--gatefit` the fit is made for B bits: `S` has the smallest
shift at which the largest the declared reference is, is within B bits' codes,
and `S8` the smallest at which it is within 127, so the noise is in the LSB of
the 8-bit converter of that range. A run prints `gate_adcbits`, and without the
option a line is what it was. Given the width the others have, a run is the run
without it, but for that field.

**What each is, in light.** grxcp's version 2 has the receiver's noise at 0.25
of an LSB of an 8-bit converter and the light at 30 photons to one. With nine
bits at the same LSB a sum has the light it had and the noise it had; what
changes is that the receiver has to stay linear to twice the photocurrent, and
the converter to resolve one more bit of it. That is a converter of nine
effective bits. Fitted with nine bits, the top of the range has the light it
had with eight, as it has fitted with eight: a network whose fitted range is
twice training's has half the light to a sum, and only the rounding is finer.
The two are different things to ask of a chip, and the mode runs both.

Like the probe it is on the host's side of the line: §4, PTM-C and the RTL are
untouched. The self-test's 41 lines are as they were, with one more, and a
build of the chain's shape prints 27. The option refuses to run without the
gate's figures or without a converter, and refuses a width under the others' or
over 15: 4 refusals, each tried. And with the script and the harness as they
now are, `refcomb`'s, `chain`'s and `chainfit`'s checks and tables alone, on
the lines their own sweeps wrote for MNIST, say yes and print what those sweeps
printed.

The self-test uses the network of the block before it, with the format alone.
At the fitted step a 9-bit converter gives the 8-bit one's sums, every one. A
step under it the 8-bit one has sums past its range and the 9-bit one has none,
and none off its reference by more than half of that step. And the range is
twice and no more. A reference of 255 fits a step of one with nine bits and one
of 256 does not. Fitted for itself the 9-bit converter's shift is the smallest
at which the reference is within 255 codes; a step under that it has sums past
its range, each held at 255 of that step or at 256 under nought; and a 10-bit
converter at that step has none past its own, and gives another sum for each of
them and for no other.

The last three of those were not in the self-test as first written. 11 errors
were planted one at a time in what a converter of another width leans on, the
rule that fits a reference to a width's codes and the tile model's own
converter, each built at both shapes. Two got past the first self-test: a rule
that fits nine bits to 191 codes, and a 9-bit converter that is held at 191. It
was made to hold the rule at its edge and the last code exactly, and then one
more got past at the chain's shape: a converter that is held at the top of its
range and does not say so. It was made to count them. Now 10 fail the self-test
at both shapes, and one at the chain's alone: a 9-bit converter that is not
held at the bottom of its range, which D3's network of made-up weights cannot
show, since none of its sums is past the bottom. The chain's shape is the one
this mode builds.

The option's code inside `cmd_eval` is reached by no self-test, so it is tested
through the mode. 8 errors planted in it one at a time were each built into the
harness and the mode run with it, as written, on 400 images and on 100. Each
fails at the mode's check.

**What it runs.** The fifteenth mode, in `chain`'s work directories and on its
networks, tile and draws. Sixteen rows on each of five draws:

| Row | What it is |
|---|---|
| format only; as budgeted | `chain`'s two rows, with eight bits and the range training's rule gives: its own runs |
| each of them, fitted | `chainfit`'s, with `--gatefit 1` and eight bits: its own runs |
| each of them, nine bits | With `--gatebits 9`: the step training's rule gives, and 255 codes where there were 127 |
| each of them, nine bits, fitted | With `--gatebits 9 --gatefit 1`: the smallest step at which the largest the declared reference is, is within 255 codes |
| each of those eight, a thousand | The same on the test set's first thousand images |

A row with nine bits is read over its own row with eight at the same range,
draw for draw. That is 800 evaluations a data set. The rows with eight bits are
`chain`'s and `chainfit`'s own runs, and where a directory has what they wrote
the mode holds each to that line, byte for byte: 400 a data set, all the same.

It was run four times on 2026-10-13, and every line of the first run is the
last's, byte for byte. The first, at 15:44 UTC, took 20 minutes for the three
data sets side by side on a machine doing other work, and its check said yes.
The check then gained the two conditions on sums past a range that are in the
next paragraph, and the mode was run again at 16:06. The self-test was made
stronger twice, as above, and the mode run with each harness, at 16:22 and at
16:39 UTC; the last took 12.9 minutes. The figures here are the last run's.

The mode checks every network and every run against its place, as `chainfit`
does its own. A run's name says its draw, whether it is the format alone or the
tile as budgeted, whether its last converter has eight bits or nine, whether
its range is training's or fitted, and whether it is of a thousand images or of
all, which have to be what it was asked and what its line printed. A run with
eight bits says nothing of its last converter's width, and one with nine says
nine. A run that is not fitted says nothing of a fit: its last shift is the one
the format alone of the first draw has, whatever its width, and is its 8-bit
shift too. The format alone has no sum past its range wherever its reference is
within its converter's codes. A run with nine bits has no more sums past its
range than the run with eight of its draw, and where that one had none it is
that run, figure for figure. A fitted run says the share and the shift
training's rule had given; its last shift is the smallest at which the largest
its declared reference is, is within 127 codes or 255, worked out again from
the line, and its 8-bit shift the smallest at which it is within 127. With nine
bits that 8-bit shift has to be the shift of the fitted run with eight of its
draw, and its own shift under it. The format alone, fitted, has no sum past its
range, and gets right on every draw what its own row gets right on the first.

152 errors were planted one at a time, and all but one fail. 78 in a training's
line, a run's line or the row a row is held against, against the check with
nothing run again, two of them a row with eight bits that is not the line
`chain` or `chainfit` wrote. 25 in the script, each run in a directory of its
own on 400 images and on 100. And 49 in the tables' own code, which the check
does not see and which have to move a table. The one that does not is the 2.0%
bar on the largest error put at 1.0%: on the two draws of MNIST the test takes,
no run's largest error is between the two. Put at 0.5% it moves the table, and
that is one of the 49.

**With nine bits at the same step, no sum is past the range.** Not one, in any
of its 600 runs, with the noise or without it, where 70 of the same 600 with
eight bits had one:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| Networks of five whose reference reaches past the 8-bit range | 0 | 1 | 0 | 2 | 2 | 0 |
| The most sums past the range in a run as budgeted, of 160,000: eight bits, training's range | 0 | 27 | 0 | 161 | 52 | 0 |
| Eight bits, fitted | 0 | 0 | 0 | 0 | 0 | 0 |
| Nine bits, training's step | 0 | 0 | 0 | 0 | 0 | 0 |
| Nine bits, fitted | 0 | 0 | 0 | 0 | 0 | 0 |
| The furthest a reference reaches into the range: eight bits, training's | 0.80 | 1.11 | 0.97 | 1.33 | 1.14 | 0.94 |
| nine bits, training's step | 0.40 | 0.55 | 0.48 | 0.66 | 0.57 | 0.47 |

Nothing is fitted. The step is the one training's rule gave, on training's
images, and no golden manifest is read. The largest any of the thirty networks'
declared references is, is 0.66 of the 9-bit converter's full scale, where it
was 1.33 of the 8-bit one's. That is room, and not a rule: nothing says a
network's reference never reaches past twice the range training's images gave
it.

**And the error is the one it had.** A network's rms error as budgeted on
10,000 images, one way over another, in the sum's own units: both are against
one reference.

| A network's rms error as budgeted, one way over another | The 5 whose range fitting widens | The other 25 |
|---|---|---|
| Nine bits at training's step, over eight | 0.995 to 1.000 | 1.000 to 1.000 |
| Eight bits fitted, over nine at training's step | 1.202 to 1.236 | 1.000 to 1.000 |
| Nine bits fitted, over nine at training's step | 1.170 to 1.197 | 0.973 to 0.989 |
| Nine bits fitted, over eight fitted | 0.968 to 0.974 | 0.973 to 0.989 |

Of the 600 runs with nine bits at training's step, 530 are their run with
eight, figure for figure: every one whose run with eight had no sum past its
range. The five networks that had some have 0.995 to 1.000 times the rms error
they had. It is not always under: a converter that clips also holds a sum the
noise had pushed past its range, which is no error, and MNIST's reference
networks have a thousandth of a percent more rms with nine bits than with
eight. Fitted with eight bits those five have 1.20 to 1.24 times the error they
have with nine. The fifth more that fitting costs is not paid.

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| As budgeted, rms, % of the reference's rms: eight bits, training's range | 4.81 | 4.46 | 4.54 | 4.67 | 4.28 | 4.18 |
| Eight bits, fitted | 4.81 | 4.64 | 4.54 | 5.05 | 4.61 | 4.18 |
| Nine bits, training's step | 4.81 | 4.46 | 4.54 | 4.67 | 4.28 | 4.18 |
| Nine bits, fitted | 4.72 | 4.57 | 4.45 | 4.91 | 4.49 | 4.12 |
| The format alone: eight bits, training's range | 0.96 | 0.71 | 0.91 | 1.04 | 0.85 | 0.76 |
| Eight bits, fitted | 0.96 | 0.84 | 0.91 | 1.27 | 1.07 | 0.76 |
| Nine bits, training's step | 0.96 | 0.71 | 0.91 | 1.00 | 0.84 | 0.76 |
| Nine bits, fitted | 0.48 | 0.42 | 0.46 | 0.64 | 0.54 | 0.38 |

**The largest error is then the noise's, as it is fitted.** Percent of the
largest the reference is, on 10,000 images:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| As budgeted, a mean over the runs: eight bits, training's range | 8.44 | 8.02 | 7.20 | 11.53 | 8.60 | 7.44 |
| the most in any run | 9.70 | 8.97 | 8.19 | 24.05 | 11.78 | 8.59 |
| Eight bits, fitted | 8.44 | 7.95 | 7.20 | 7.92 | 8.33 | 7.44 |
| the most in any run | 9.70 | 8.97 | 8.19 | 8.95 | 9.64 | 8.59 |
| Nine bits, training's step | 8.44 | 7.57 | 7.20 | 7.19 | 7.55 | 7.44 |
| the most in any run | 9.70 | 8.97 | 8.19 | 8.65 | 8.86 | 8.59 |
| Nine bits, fitted | 8.33 | 7.81 | 7.11 | 7.76 | 8.13 | 7.41 |
| the most in any run | 9.91 | 8.61 | 7.95 | 8.95 | 10.07 | 8.87 |
| The format alone, the most in any run: eight bits, training's range | 0.67 | 8.88 | 0.48 | 24.05 | 11.78 | 0.51 |
| Eight bits, fitted | 0.67 | 0.71 | 0.48 | 0.70 | 0.76 | 0.51 |
| Nine bits, training's step | 0.67 | 0.49 | 0.48 | 0.58 | 0.60 | 0.51 |
| Nine bits, fitted | 0.34 | 0.36 | 0.24 | 0.35 | 0.38 | 0.25 |

The format alone with nine bits at training's step has a largest error of 0.30
to 0.71% in its 300 runs, where it was as much as 24.05%, and all are within
2.0%, where 270 were. As budgeted its mean over a set's runs is 7.2 to 8.4%,
where it was 7.2 to 11.5%, and the most in any run 9.7%, where it was 24.1%. No
run of the 300 as budgeted is within 2.0%: the least is 6.0%. A bit does
nothing for the noise.

**The class is what it was.** How often the class the tile gives is the class
its declared reference gives, percent, and in brackets the runs of 25 at 99.5%
or more; on 10,000 images unless it says:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| As budgeted: eight bits, training's range | 99.40 (2) | 99.59 (23) | 95.92 (0) | 96.78 (0) | 98.86 (0) | 99.23 (0) |
| Eight bits, fitted | 99.40 (2) | 99.55 (20) | 95.92 (0) | 96.20 (0) | 98.66 (0) | 99.23 (0) |
| Nine bits, training's step | 99.40 (2) | 99.59 (23) | 95.92 (0) | 96.78 (0) | 98.86 (0) | 99.23 (0) |
| Nine bits, fitted | 99.45 (6) | 99.57 (20) | 96.36 (0) | 96.63 (0) | 98.76 (0) | 99.26 (0) |
| The first thousand images: eight bits, training's range | 99.25 (6) | 99.49 (13) | 96.01 (0) | 96.85 (0) | 98.80 (2) | 99.10 (1) |
| Eight bits, fitted | 99.25 (6) | 99.49 (13) | 96.01 (0) | 96.60 (0) | 98.65 (2) | 99.10 (1) |
| Nine bits, training's step | 99.25 (6) | 99.49 (13) | 96.01 (0) | 96.85 (0) | 98.80 (2) | 99.10 (1) |
| Nine bits, fitted | 99.34 (7) | 99.50 (15) | 96.47 (0) | 97.01 (0) | 98.87 (4) | 99.14 (3) |
| The format alone: eight bits, training's range | 99.74 (25) | 99.85 (25) | 98.16 (0) | 98.49 (0) | 99.54 (15) | 99.73 (25) |
| Eight bits, fitted | 99.74 (25) | 99.81 (25) | 98.16 (0) | 97.97 (0) | 99.36 (5) | 99.73 (25) |
| Nine bits, training's step | 99.74 (25) | 99.85 (25) | 98.16 (0) | 98.49 (0) | 99.54 (15) | 99.73 (25) |
| Nine bits, fitted | 99.88 (25) | 99.91 (25) | 99.05 (0) | 99.05 (0) | 99.71 (25) | 99.87 (25) |

With nine bits at training's step the reference networks give that class on
99.59, 96.78 and 99.23% of 10,000 images: what they gave with eight bits and
training's range, to a hundredth of a point on every set and kind, where fitted
with eight they gave it on 99.55, 96.20 and 99.23%. On the first thousand it is
99.49, 96.85 and 99.10%, with 13, 0 and 1 runs of 25 at 99.5%. A clipped sum
seldom moves a class, which is why training's rule lets one in ten thousand
clip. What fitting lost was to its larger step.

**Spent on finer steps, the bit halves the rounding and leaves the noise.**
Fitted with nine bits every network's step is one bit finer than fitted with
eight, and the range is the same but for one step. The format alone then has
0.38 to 0.64% of the reference's rms, where it had 0.76 to 1.27: half, to a
hundredth. All 150 of its runs are within 1.0%, where 95 were, and its largest
error is 0.38% at the most. As budgeted a network has 0.97 to 0.99 times its
rms error fitted with eight, every one of the thirty: 4.57, 4.91 and 4.12% of
the reference's rms for the reference networks, where it was 4.64, 5.05 and
4.18%. And the five networks whose fitted range is twice training's still have
1.17 to 1.20 times the error they have with nine bits at training's step.

For those five the two ways with nine bits are one converter: the same step,
and so the same range. What differs is the light. Fitted, the top of the range
has the light it had with eight, so a sum has half; at the same LSB a sum has
what it had, and the receiver sees twice as much at the top of the range. For
the other twenty-five, fitted with nine bits is the 8-bit range in steps half
the size.

The class moves with the rounding more than was expected. Fitted with nine bits
and as budgeted the reference networks give their declared reference's class on
99.57, 96.63 and 99.26%: 0.02 ± 0.01, 0.43 ± 0.10 and 0.03 ± 0.02 points over
fitted with eight, clear on Fashion-MNIST. The format alone gives it on 99.91,
99.05 and 99.87%, where fitted with eight it gave it on 99.81, 97.97 and
99.73%. On the first thousand as budgeted, 15, 0 and 3 runs of 25 are at 99.5%.

**As a share of full scale it passes, with nothing better about it.** A row's
rms error against its declared format, as budgeted on 10,000 images, in the
steps and the full scale of the converter it has:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| rms, in steps of its own converter: eight bits, training's range | 1.45 | 1.83 | 1.44 | 1.43 | 1.55 | 1.60 |
| Eight bits, fitted | 1.45 | 1.67 | 1.44 | 1.15 | 1.24 | 1.60 |
| Nine bits, training's step | 1.45 | 1.83 | 1.44 | 1.43 | 1.55 | 1.60 |
| Nine bits, fitted | 2.84 | 3.30 | 2.82 | 2.24 | 2.42 | 3.14 |
| rms, % of its converter's full scale: eight bits, training's range | 1.14 | 1.44 | 1.13 | 1.13 | 1.22 | 1.26 |
| Eight bits, fitted | 1.14 | 1.32 | 1.13 | 0.91 | 0.98 | 1.26 |
| Nine bits, training's step | 0.57 | 0.72 | 0.56 | 0.56 | 0.61 | 0.63 |
| Nine bits, fitted | 1.12 | 1.29 | 1.11 | 0.88 | 0.95 | 1.23 |
| Runs of 25 within 1.0% of full scale: eight bits, training's range | 0 | 0 | 0 | 15 | 5 | 0 |
| Eight bits, fitted | 0 | 5 | 0 | 25 | 15 | 0 |
| Nine bits, training's step | 25 | 25 | 25 | 25 | 25 | 25 |
| Nine bits, fitted | 0 | 5 | 0 | 25 | 19 | 0 |

With nine bits at training's step the error is 1.43 to 1.83 steps rms, as it
was, and that is 0.56 to 0.72% of a full scale twice as large. All 150 runs as
budgeted are within 1.0% of the converter's full scale, where 20 were with
eight bits. None is within 1.0% of the reference's rms, as none was. It is the
section before's finding again: a bound that is a share of full scale is met by
a wider full scale.

**What the bit costs** is grxcp's to say, and its model does
(`docs/designs/pta_board_bits.py`, from its `pta_power.py` and
`pta_tighten.py`): the best and the fifth-best published converter of at least
that many effective bits at 1 GS/s.

| | Eight effective bits | Nine |
|---|---|---|
| One converter at 1 GS/s, mW | 4.19 to 5.35 | 4.19 to 10.81 |
| The tile's 64, W | 0.27 to 0.34 | 0.27 to 0.69 |
| The interface chip, W | 0.64 to 4.18 | 0.64 to 4.53 |

The best published part is the same part, and the fifth-best takes twice the
energy. Not priced: a receiver that is linear to twice the photocurrent at the
noise it had. grxcp's plan has one figure for a receiver, whatever its range.

**What was predicted.** Ten things, written on 2026-10-13 at 15:29 UTC, when
the option, the mode and their self-tests existed and the option had run no
network. All are for the reference networks. Seven were right as written.

1. That with nine bits at training's step no sum is past the range in any of
   its 600 runs. Right.

2. That the 530 of those runs whose run with eight bits had no sum past its
   range are that run, figure for figure. Right: 530, and the mode's check
   holds each to it.

3. That its rms as budgeted is within 0.03 of what it was with eight bits and
   never over it: 4.46, 4.64 to 4.67 and 4.18% of the reference's rms. Wrong,
   by a thousandth: it is 4.464, 4.669 and 4.183, where it was 4.463, 4.674 and
   4.183, and MNIST's is over. A clipped sum is not always a worse one.

4. That its largest error as budgeted is 7.2 to 8.5% of the largest the
   reference is on every set and kind, 9.70% at the most, and within 2.0% in no
   run. Wrong, by one set's mean: Fashion-MNIST's reference networks are at
   7.19%. The most is 9.70%, and none is within 2.0%.

5. That the class is the declared reference's on 99.59 to 99.60, 96.78 to 96.82
   and 99.23%, and on MNIST's first thousand on 99.49% with 13 runs of 25 at
   99.5%. Right: 99.59, 96.78 and 99.23.

6. That for the five networks fitting moved, the run fitted with eight bits has
   1.20 to 1.27 times the rms error of the run with nine at training's step.
   Right: 1.20 to 1.24.

7. That fitted with nine bits every step is one bit finer than fitted with
   eight, and the format alone has 0.36 to 0.64% of the reference's rms where
   it had 0.76 to 1.27, all 150 runs within 1.0% where 95 were, and a largest
   error of 0.39% at the most. Right: 0.42, 0.64 and 0.38, and 0.38%.

8. That fitted with nine bits and as budgeted the rms is 1 to 3% under what it
   is fitted with eight: 4.50 to 4.60, 4.90 to 5.00 and 4.06 to 4.15%. Right:
   4.57, 4.91 and 4.12.

9. That the class is then the declared reference's 0.00 to 0.03 of a point more
   often than fitted with eight on MNIST and on the inverted set, and 0.03 to
   0.12 more on Fashion-MNIST. Wrong on Fashion-MNIST: 0.43 of a point more,
   four times what was written. The rounding moves that set's class more than
   its share of the rms says.

10. That the format alone, fitted with nine bits, gives its declared
    reference's class on 99.88 to 99.93, 98.7 to 99.1 and 99.82 to 99.90% of
    10,000 images. Right: 99.91, 99.05 and 99.87.

**What this is not.** Everything the two sections before say of themselves: a
stand-in classifier, in a model, with the chain's other engines taken as exact
and no source lit. A range that holds by rule: with nine bits at training's
step nothing was clipped in these thirty networks, and nothing says none ever
is. A receiver: the bit is modelled as a converter's, and the front end that
has to stay linear to twice the photocurrent is not modelled and not priced. A
remedy for the largest error, which is the noise's and is where it was. Five
draws, of the same five networks.

### The first board's last layer, with a light source switched on

*Added 2026-10-13.* `SHAPE=chain sim/pta_mnist.sh DIR WORK chainlit`, and
`pta_mnist eval --host` with a source. Reported, not gated.

**Why.** Three sections have run the first board's last layer on the tile, and
every run had the tile's own noise and no source. Each said so: the harness lit
whole networks, and refused a light where the host had layers. The largest
error of that layer is the noise's, and it is what keeps the tile outside the
demonstration's 2.0%. A source adds to it, and by how much was not known.

**The change.** `eval --host N` now takes a light. A source's share is added to
the sums of the layers the tile runs and to no other. What a host does for its
lines is the tile's too: a reading put on the weights rewrites the tile's
layers' weights and leaves the host's as they are, at the width they had; a
reading put on the inputs scales the tile's layers' inputs alone; and where
every row is scaled to the dimmest line, what that takes off is divided back
out of the tile's sums alone. `--thermalline`, `--hidshift`, `--w1gain` and
`--levelpart` are still refused where the host has layers. A line's `wbits` is
now the last layer's weights' width, which in every run before this was every
layer's. A line printed without `--host` and a source together is what it was.

**How the light is modelled**, which is this harness's way and is first order.
A shot's sum gains, for each row, its product times its line's error, and that
share is added after the converter: it is neither rounded nor held at the
range. A correction on the weights rewrites them before the tile, so the
converter sees the sums of the rewritten weights and the light's share then
brings them back. A chip's converter sees the two together. So where a row's
weights were raised for a dim line, this model's converter sees a sum larger
than a chip's would, and can hold it at the range where a chip would not.

The self-test's 42 lines are as they were, with one more, and a build of the
chain's shape prints 28. The new block uses the made-up network of the two
before it, with its first two layers on the host. Lit, the host's layers' sums
are the ones they were. With lines that are not level and no noise, each of the
last layer's sums gains its rows' lines' levels times what each row carries,
worked out there from the lines. With noise on the source the last layer's sums
move and the host's do not. And with the lines read and corrected three ways,
on the weights at 8 bits, on them with every row scaled to the dimmest line,
and on the inputs, the host's weights, widths and sums are what they were, the
last layer's weights are 8 bits wide where they are rewritten, and its sums are
nearer the unlit ones than the uncorrected were.

15 errors were planted one at a time in that code and built at both shapes,
before the mode was written or anything swept: the light on every layer, on the
host's alone, on all but the tile's first; a correction's gain, its scaled
inputs and its rewritten weights reaching the host's layers, or missing the
tile's; a width set for the wrong layers; and the light's share through the
wrong weights, the wrong activations, the wrong line, or rounded down. Each
fails the self-test at both shapes.

What the change did inside `cmd_eval` is reached by no self-test, so it is
tested through the mode. 2 errors planted there, the refusal put back and the
width taken from the first layer, were each built into the harness and the mode
run with it, as written, on 400 images and on 100. Each fails. A source over
two host layers is taken, and each of the 4 options still refused with host
layers is refused. And with the script and the harness as they now are,
`refcomb`'s, `chain`'s, `chainfit`'s and `chainbit`'s checks and tables alone,
on the lines their own sweeps wrote for MNIST, say yes and print what those
sweeps printed. Ten runs those modes and the ones before them made were also
run again with it, and each is the line its sweep wrote, byte for byte: eight
of them lit with every layer on the tile, held and in a cycle, with the lines
read and put on the weights, on the weights at 8 bits, on the inputs, scaled to
the dimmest line, and told apart.

**What it runs.** The sixteenth mode, in `chain`'s work directories and on its
networks, tile and draws, on the 8-bit converter grxcp's B14 keeps. Ten rows on
each of five draws, and each again on a thousand images:

| Row | What it is |
|---|---|
| format only; as budgeted | `chain`'s two rows, with no source and the range training's rule gives: its own runs |
| as budgeted, fitted | `chainfit`'s row, with no source and `--gatefit 1`: its own runs |
| as budgeted, lit: shared | With `--src 0.01`: the lines together, 1% rms a shot |
| as budgeted, lit: a line | With `--srcline 0.05 --buses 2`: a line on its own, 5% rms a shot |
| as budgeted, lit: level, left | With `--srcflat 0.2 --buses 2`: lines 20% off, rms, and left alone |
| as budgeted, lit: level | The same with `--levelprobe 16 --levelfix weights8`: read at sixteen shots a row, and put on the weights at 8 bits |
| as budgeted, lit | All three, read and corrected: the source |
| as budgeted, lit, fitted | The source, with `--gatefit 1` |
| format only, lit | The source over the format alone |
| each of those ten, a thousand | The same on the test set's first thousand images |

The source's rows are grxcp's B16 as it stands: 1%, 5%, and lines 20% off that
are read at each calibration and corrected on the weights at 8 bits; on two
buses, which at this tile's 128 rows is 64 lines. A lit row is read over its
own row with no source, at the same range and of its draw. That is 1,000
evaluations a data set. The rows with no source are `chain`'s and `chainfit`'s
own runs, and where a directory has what they wrote the mode holds each to that
line, byte for byte: 300 a data set, all the same.

It was run once, on 2026-10-13 at 19:57 UTC, and took 14.5 minutes for the
three data sets side by side. Before it the mode was run on two draws of MNIST,
to see its check say yes, and the check then gained one condition: that a lit
run is not its run with no source, figure for figure. The harness did not
change after its planted errors were run.

The mode checks every network and every run against its place, as `chainbit`
does its own. A run's name says its draw, whether it is the format alone or the
tile as budgeted, which of the source's rows are lit, whether its range is
training's or fitted, and whether it is of a thousand images or of all, which
have to be what it was asked and what its line printed. A run with no source
says nothing of one. A lit run says its three rows, each what its name lights
and nought for the others, its buses, and that a weight is read through a pair.
Where the lines are read it says the probe's sixteen shots, what the lines
were, within a half of the 20% they were drawn at, and what the reading leaves,
under a quarter of that; that the reading went on the weights at 8 bits with
nothing scaled to the dimmest line; and its weights are 8 bits wide where every
other run's are 6. Its first two layers, the host's, are not off their operands
at all. A lit run's range is its row with no source's. Where no weight is
rewritten it has that run's sums past the range, as many. And it is not that
run: its error and its class are not that run's, figure for figure.

213 errors were planted one at a time, and all but two fail. 115 in a
training's line, a run's line or the row a row is held against, against the
check with nothing run again, two of them a row with no source that is not the
line `chain` or `chainfit` wrote. 42 in the script, each run in a directory of
its own on 400 images and on 100. And 56 in the tables' own code, which the
check does not see and which have to move a table. Two of those cannot, in this
mode. One counts the runs whose step moved in bits where it should count runs,
and here every step that moves, moves by one bit. The other takes what a
reading leaves as a mean over every run and not over the runs that read the
lines, and in every row all of them do or none does.

**The source costs the last layer a seventh more error.** A row's rms error
against its declared format, percent of the reference's rms, on 10,000 images:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| No source: the tile as budgeted | 4.81 | 4.46 | 4.54 | 4.67 | 4.28 | 4.18 |
| The shared row, 1% | 4.92 | 4.57 | 4.65 | 4.78 | 4.40 | 4.30 |
| A line's own noise, 5% | 5.06 | 4.79 | 4.78 | 4.94 | 4.65 | 4.63 |
| Lines 20% off, left alone | 7.37 | 7.75 | 7.54 | 8.06 | 8.16 | 8.61 |
| Lines 20% off, read and corrected | 4.70 | 4.73 | 4.48 | 4.97 | 4.40 | 4.76 |
| The source, all three | 5.10 | 5.18 | 4.84 | 5.34 | 4.89 | 5.27 |
| No source, range fitted | 4.81 | 4.64 | 4.54 | 5.05 | 4.61 | 4.18 |
| The source, range fitted | 5.10 | 5.33 | 4.84 | 5.66 | 5.18 | 5.27 |
| The format alone, no source | 0.96 | 0.71 | 0.91 | 1.04 | 0.85 | 0.76 |
| The format alone, with the source | 3.49 | 4.12 | 4.55 | 4.96 | 4.72 | 5.27 |

As budgeted and lit the reference networks are 5.18, 5.34 and 5.27% off, where
with no source they were 4.46, 4.67 and 4.18%. A network has 0.98 to 1.40 times
the rms error it had, 1.14 in the mean of the thirty. No run of the 150 is
within 1.0%, as none was.

**Row by row, in squares.** What a lit row adds to its row with no source: the
root of its rms squared less the other's, run for run and then a mean. It is
what the row would add if its error and the tile's were independent.

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The shared row, 1% | 1.00 | 1.00 | 1.01 | 1.00 | 1.00 | 1.00 |
| A line's own noise, 5% | 1.56 | 1.74 | 1.48 | 1.60 | 1.81 | 1.98 |
| Lines 20% off, left alone | 5.75 | 6.51 | 6.33 | 6.84 | 7.17 | 7.73 |
| Lines 20% off, read and corrected | −0.99 | 1.60 | 0.42 | 1.93 | 1.17 | 2.40 |
| The source, all three | 1.70 | 2.65 | 1.87 | 2.73 | 2.42 | 3.29 |
| The source, range fitted | 1.70 | 2.66 | 1.87 | 2.71 | 2.41 | 3.29 |
| The source, on the format alone | 3.43 | 4.13 | 4.68 | 5.10 | 4.76 | 5.36 |

The shared 1% adds 1.00 to 1.01 on every set and kind, which is itself: 1% of
every sum of a shot. A line's own 5% adds 1.48 to 1.98, since a sum's rows do
not all err one way. Lines 20% off and left alone add 5.75 to 7.73. The same
lines read and corrected add 1.60, 1.93 and 2.40 for the reference networks,
and the source, all three, adds 2.65, 2.73 and 3.29.

**The reading is good, and what it leaves is the rail.**

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| What the lines were, rms | 0.201 | 0.201 | 0.201 | 0.201 | 0.201 | 0.201 |
| What the reading leaves, no noise on the source | 0.0013 | 0.0013 | 0.0013 | 0.0013 | 0.0013 | 0.0013 |
| What it leaves with the source's noise | 0.0099 | 0.0099 | 0.0099 | 0.0099 | 0.0099 | 0.0099 |
| Weights the rail held back, % of those scaled: a mean | 3.6 | 4.5 | 6.3 | 6.8 | 4.5 | 5.3 |
| the most in any run | 6.4 | 7.4 | 10.4 | 11.3 | 6.0 | 6.8 |

The probe finds the lines 0.16 to 0.23 off, rms, and its reading leaves 0.0011
to 0.0015 with no noise on the source and 0.008 to 0.011 with it. But a dim
line's row has to be raised, and a weight at full scale cannot be. Of the
weights the reading scales, the rail holds back 1.3 to 11.3%, and 5.2% in the
mean. Nothing in training keeps a weight clear of it.

**It does not add in squares, because not all of it is noise.** The format
alone with the source is 4.12, 4.96 and 5.27% of the reference's rms off. That
is the source by itself, and it is more than the 2.65, 2.73 and 3.29 the same
source adds to the tile as budgeted. On the inverted set the format alone, lit,
is as far off as the whole tile, lit. And for MNIST's networks trained before,
the tile with its lines read is nearer its reference than the tile with no
source: 4.70% against 4.81%. What the rail leaves comes out the same way in
every shot, and it meets something in the tile that comes out the other way.

What that is was looked for in one network and not in the mode: MNIST's
reference network of seed 3, its first 2,000 images and one draw, by hand, with
the tile's impairments one at a time. Percent of the reference's rms. No check
holds these figures and grxcp's model does not have them.

| The tile's impairments, of one network | No source | The source | It adds, in squares | Lines read alone add |
|---|---|---|---|---|
| The format alone | 0.80 | 4.14 | 4.06 | 3.44 |
| and the receiver's noise | 1.05 | 4.19 | 4.06 | 3.47 |
| and the shot noise | 2.82 | 5.00 | 4.12 | 3.49 |
| and the programming error | 1.01 | 4.20 | 4.08 | 3.48 |
| and the crosstalk | 3.64 | 4.78 | 3.10 | 2.18 |
| All of them: as budgeted | 4.66 | 5.59 | 3.09 | 2.09 |

The source adds 4.1% under the format alone and under each of three
impairments, and 3.1% under the crosstalk, alone or with the rest. A
neighbour's ring passes some of a row's light, which swells a sum whose weights
run the same way; a weight held at the rail on a dim line shrinks it. That is
one network. *All thirty were run the same day, with the probe's gain to say
which way each comes out: "its budget a row at a time", below.* The same look
tried the other correction this harness has, every
row scaled down to the dimmest line, where no weight is raised and the rail
holds none. Under the format alone it leaves 1.7% where 3.5% was. Under the
tile as budgeted it leaves the layer 6.2% off where the correction on the
weights leaves 5.1%: it takes half the light, and the tile's noise is in LSB.

**The largest error grows more than the rms does.** Percent of the largest the
reference is, on 10,000 images:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| No source: a mean over the runs | 8.44 | 8.02 | 7.20 | 11.53 | 8.60 | 7.44 |
| the most in any run | 9.70 | 8.97 | 8.19 | 24.05 | 11.78 | 8.59 |
| the most in a run with no sum past the range | 9.70 | 8.97 | 8.19 | 8.65 | 8.86 | 8.59 |
| The source: a mean over the runs | 10.44 | 11.91 | 9.40 | 14.91 | 13.07 | 12.76 |
| the most in any run | 13.25 | 19.57 | 15.06 | 34.03 | 26.15 | 19.48 |
| the most in a run with no sum past the range | 13.25 | 14.99 | 12.56 | 14.50 | 14.07 | 19.48 |
| No source, range fitted: a mean over the runs | 8.44 | 7.95 | 7.20 | 7.92 | 8.33 | 7.44 |
| the most in any run | 9.70 | 8.97 | 8.19 | 8.95 | 9.64 | 8.59 |
| the most in a run with no sum past the range | 9.70 | 8.97 | 8.19 | 8.95 | 9.64 | 8.59 |
| The source, range fitted: a mean over the runs | 10.44 | 11.40 | 9.40 | 10.16 | 11.54 | 12.76 |
| the most in any run | 13.25 | 14.99 | 15.06 | 14.50 | 16.23 | 19.48 |
| the most in a run with no sum past the range | 13.25 | 14.99 | 12.56 | 14.50 | 16.23 | 19.48 |

With the source its mean over a set's runs is 9.4 to 14.9%, where it was 7.2 to
11.5%, and the most in any run with no sum past the converter's range is 19.5%,
where it was 9.7%. A weight the rail held back is off by as much in every shot,
so the sums it feeds are off by a fixed share and not by a draw. No run of the
600 with the source is within 2.0%.

**The sums past the range in a row whose lines are read are the model's
order.**

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| No source: runs of 25 with a sum past the range | 0 | 5 | 0 | 10 | 10 | 0 |
| Lines left alone: runs of 25 with a sum past the range | 0 | 5 | 0 | 10 | 10 | 0 |
| Lines read: runs of 25 with a sum past the range | 0 | 8 | 4 | 10 | 10 | 0 |
| The source: runs of 25 with a sum past the range | 0 | 8 | 4 | 10 | 10 | 0 |
| No source, range fitted: runs of 25 with a sum past the range | 0 | 0 | 0 | 0 | 0 | 0 |
| The source, range fitted: runs of 25 with a sum past the range | 0 | 3 | 4 | 0 | 0 | 0 |
| No source: the most sums past it in a run, of 160,000 | 0 | 27 | 0 | 161 | 52 | 0 |
| The source: the most sums past it in a run, of 160,000 | 0 | 83 | 2 | 346 | 228 | 0 |
| The source, range fitted: the most sums past it in a run, of 160,000 | 0 | 2 | 2 | 0 | 0 | 0 |

A lit run with no weight rewritten has its unlit run's sums past the range, as
many, in all 900 such runs: the light's share is added after the converter.
With the lines read, 28 of the 150 runs as budgeted have more than their run
with no source and 4 have fewer, and fitted, 7 runs have some where none had.
That is the converter seeing the rewritten weights' sums before the light
brings them back. The largest error in a run with a sum past the range is not a
source's, and the table before this one gives it apart.

**The class.** How often the class the tile gives is the class its declared
reference gives, percent, and in brackets the runs of 25 at 99.5% or more; on
10,000 images unless it says:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| No source | 99.40 (2) | 99.59 (23) | 95.92 (0) | 96.78 (0) | 98.86 (0) | 99.23 (0) |
| The shared row, 1% | 99.40 (2) | 99.59 (23) | 95.91 (0) | 96.77 (0) | 98.86 (0) | 99.24 (0) |
| A line's own noise, 5% | 99.33 (0) | 99.52 (16) | 95.85 (0) | 96.69 (0) | 98.69 (0) | 99.11 (0) |
| Lines 20% off, left alone | 98.67 (0) | 98.91 (0) | 94.24 (0) | 95.36 (0) | 97.08 (0) | 97.99 (0) |
| Lines 20% off, read and corrected | 99.33 (0) | 99.50 (13) | 95.81 (0) | 96.58 (0) | 98.63 (0) | 99.00 (0) |
| The source, all three | 99.26 (0) | 99.44 (8) | 95.59 (0) | 96.45 (0) | 98.47 (0) | 98.89 (0) |
| No source, range fitted | 99.40 (2) | 99.55 (20) | 95.92 (0) | 96.20 (0) | 98.66 (0) | 99.23 (0) |
| The source, range fitted | 99.26 (0) | 99.41 (8) | 95.59 (0) | 95.90 (0) | 98.29 (0) | 98.89 (0) |
| The first thousand images: no source | 99.25 (6) | 99.49 (13) | 96.01 (0) | 96.85 (0) | 98.80 (2) | 99.10 (1) |
| the source | 99.16 (4) | 99.33 (8) | 95.74 (0) | 96.41 (0) | 98.37 (0) | 98.66 (0) |
| the source, range fitted | 99.16 (4) | 99.33 (8) | 95.74 (0) | 96.17 (0) | 98.26 (0) | 98.66 (0) |

As budgeted and lit the reference networks give that class on 99.44, 96.45 and
98.89%, where with no source they gave it on 99.59, 96.78 and 99.23%. On the
first thousand it is 99.33, 96.41 and 98.66%, with 8, 0 and 0 runs of 25 at
99.5%, where 13, 0 and 1 were. With the lines left alone it is 98.91, 95.36 and
97.99% of 10,000.

**In points of accuracy.** What a lit row adds over its row with no source, in
points lost, with what five networks put outside chance at one in twenty in
bold:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| With no source, as budgeted, % | 96.79 | 96.97 | 82.85 | 83.47 | 93.82 | 95.19 |
| The shared row adds | 0.00 ± 0.00 | 0.00 ± 0.00 | −0.01 ± 0.00 | 0.00 ± 0.00 | −0.01 ± 0.01 | −0.01 ± 0.01 |
| A line's own noise adds | 0.01 ± 0.02 | 0.01 ± 0.01 | 0.04 ± 0.04 | 0.03 ± 0.03 | −0.01 ± 0.03 | −0.01 ± 0.01 |
| Lines left alone add | **0.25 ± 0.06** | **0.23 ± 0.07** | **0.53 ± 0.13** | **0.37 ± 0.12** | **0.94 ± 0.20** | **0.45 ± 0.06** |
| Lines read add | 0.04 ± 0.02 | 0.02 ± 0.01 | 0.10 ± 0.09 | 0.08 ± 0.05 | 0.11 ± 0.05 | **0.08 ± 0.02** |
| The source adds | 0.05 ± 0.03 | **0.03 ± 0.01** | 0.15 ± 0.08 | **0.13 ± 0.04** | **0.15 ± 0.03** | **0.11 ± 0.01** |

The source costs the reference networks 0.03 ± 0.01, 0.13 ± 0.04 and 0.11 ±
0.01, clear on all three. Lines left alone cost every set and kind a quarter of
a point to nearly one.

**What was predicted.** Eleven things, written on 2026-10-13 at 19:49 UTC, when
the change, the mode and the self-test existed and no network had been lit with
layers on the host. All are for the reference networks, on 10,000 images with
training's range unless said. Two were right as written. Most of the rest put
the source's cost too high.

1. That the shared row alone adds 1.0% in quadrature, to a tenth, taking the
   rms to 4.55 to 4.60, 4.75 to 4.80 and 4.27 to 4.32%, and leaves the class
   where it was to 0.02 of a point. Right: 4.57, 4.78 and 4.30.

2. That a line's own 5% alone takes the rms to 5.0 to 6.5%, which is 2.3 to
   4.7% in quadrature. Wrong: 4.79, 4.94 and 4.63, which is 1.74, 1.60 and
   1.98. A sum's rows cancel more than was allowed for.

3. That lines 20% off and left alone take the rms to 10 to 20% and the class to
   97.5 to 99.2, 91 to 95.5 and 96.5 to 98.8%. Wrong on the rms, 7.75, 8.06 and
   8.61, for the same reason. The class is 98.91, 95.36 and 97.99%.

4. That read and corrected the lines cost little: an rms within 0.5 of the tile
   with no source, lines found 0.17 to 0.23 off and left 0.006 to 0.013, and
   the rail holding back under 1% of the weights it scales. Wrong three ways.
   The inverted set's rms is 0.58 over. Some runs' lines are 0.156 off, and
   with no noise on the source the reading leaves 0.0011. And the rail holds
   back 1.3 to 11.3%.

5. That the source takes the rms to 5.3 to 6.8% on every set, 1.2 to 1.5 times
   the tile with no source. Wrong, by a little, low: 5.18, 5.34 and 5.27.

6. That its largest error is 9 to 12.5% in a set's mean on every set and kind,
   17% at the most, and within 2.0% in no run. Wrong: 9.4 to 14.9% in a set's
   mean, and 34.0% at the most in a run with sums past the range, 19.5% in one
   with none. None is within 2.0%.

7. That the class with the source is 99.35 to 99.50, 95.0 to 96.0 and 98.75 to
   99.05%, and on MNIST's first thousand 99.28 to 99.44% with 3 to 10 runs at
   99.5%. Wrong on Fashion-MNIST, which is better: 99.44, 96.45 and 98.89.

8. That in points of accuracy the source costs 0.00 to 0.08, 0.02 to 0.25 and
   0.02 to 0.20, clear on none or on one. Wrong on the last clause: 0.03, 0.13
   and 0.11, and clear on all three.

9. That the format alone with the source is 3.0 to 4.8% of the reference's rms,
   and its square within a fifth of what the source adds to the tile. Wrong,
   and it is this section's finding: 4.12, 4.96 and 5.27, against 2.65, 2.73
   and 3.29 added to the tile.

10. That a lit run with no weight rewritten has its unlit run's sums past the
    range, as many, and that with the weights rewritten the most in a run is
    within 15 of what it was. Right of the first. Wrong of the second: 83, 346
    and 0, where it was 27, 161 and 0. The model's order was not thought
    through.

11. That fitted, the source adds what it adds with training's range, to a tenth
    in squares. Right: 2.66, 2.71 and 3.29, against 2.65, 2.73 and 3.29.

**What this is not.** Everything the three sections before say of themselves: a
stand-in classifier, in a model, with the chain's other engines taken as exact.
A converter that sees the light: this model's sees the rewritten weights' sums,
and the light after. A source through an offset. A cycle of calibrations or a
drifted tile: this is the source over the tile as budgeted, as written. An
account of what in the tile the rail's share cancels against: one network was
looked at. *The section after this one has it for all thirty.* A remedy for
either. Five draws, of the same five networks.

### The first board's last layer, its budget a row at a time

*Added 2026-10-13.* `SHAPE=chain sim/pta_mnist.sh DIR WORK chainrows`.
Reported, not gated. The harness is not changed: `pta_mnist.c` and the tile's
model are the ones the section before ran.

**Why.** Four sections have run the first board's last layer on the tile and
moved its error by a quarter at the most: with a range fitted, a ninth bit, a
source. None said what the error is made of. Against its declared format the
tile is off by its converter's rounding and by four rows of grxcp's version 2:
the receiver's noise, the shot noise, the programming error and the crosstalk.
And the section before found that a source adds less to the tile than it is by
itself, looked at one network by hand, and saw the crosstalk in it. That look
was one network, 2,000 images and one draw.

**What it runs.** The seventeenth mode, in `chain`'s work directories and on
its networks, tile and draws, on 10,000 images. Every row is one the harness
could already run: an impairment is in a run if `--impair` names it, at the
figure its own option gives.

| Row | What it runs |
|---|---|
| format only | `--impair quant`: the tile's format and nothing drawn. `chain`'s row, its own runs |
| only thermal | and the receiver's noise, `--thermal8 0.25` |
| only shot | and the shot noise, `--photons8 30` |
| only prog | and the programming error, `--prog 1` |
| only xtalk | and the crosstalk, `--xtalk 0.02` |
| less thermal, less shot, less prog, less xtalk | The tile as budgeted with that one row left out |
| less shot, xtalk | The tile as budgeted with those two left out: the format, the receiver's noise and the programming error |
| as budgeted | All four. `chain`'s row, its own runs |
| each of those eleven, lit | The same with `chainlit`'s source: `--src 0.01 --srcline 0.05 --srcflat 0.2 --buses 2 --levelprobe 16 --levelfix weights8`. The format alone and the tile as budgeted, lit, are `chainlit`'s own runs |

That is twenty-two rows on each of five draws, 1,100 evaluations a data set. A
row with one row of the budget alone is read over the format alone, a row with
one left out over the tile as budgeted, and a lit row over its own row with no
source, each of its draw. Four of the twenty-two are runs `chain` and
`chainlit` made, and where a directory has what they wrote the mode holds each
to that line, byte for byte: 200 a data set, all the same.

**The probe's gain.** Each run is made with `--probe 1`, as every run of the
four sections was, and its line has two figures no table had printed. The probe
measures a run's error against the host's own network, weights at the network's
width and activations as the host has them, which is not the declared format.
Of that error it fits a gain: the slope of the error on the outputs themselves
over the run, with each image's common shift taken out first. A positive gain
is a last layer whose every output is that fraction too large. And it gives
what is left with the shift and the gain out, `eres`, as a fraction of the
reference's rms. A class does not move with a shift or with a gain. The
declared format has a gain of its own against the host's network, so a row's
gain is read against the format alone's.

**How it was run.** The mode's check and ten predictions were written first. It
was then run on two draws of MNIST, to see the check say yes, and the check
gained a condition: a row with nothing drawn in it is the same run on every
draw, figure for figure and not only in what it gets right. It was swept on
2026-10-13 at 23:22 UTC. Its eight tables did not print the gain, which was
then looked at by hand in the lines. A ninth table was added to print it, with
a condition in the check that a run has the probe's figures and that what is
left is no more than all of its error. The sweep was run again with the script
as it now is, at 23:56 UTC, and took 20 minutes for the three data sets side by
side. Every line of the second sweep is the line the first wrote, byte for
byte, and the figures here are the second's.

The mode checks every network and every run against its place, as `chainlit`
does its own. A run's name says its draw, which rows of the budget are in it,
and whether the source is lit, which have to be what it was asked and what its
line printed: the impairments it names and no other, each at version 2's figure
and nought for the ones left out. A lit run says the source's three rows, its
buses and its lines' reading as `chainlit` holds them, and its weights are 8
bits wide where every other run's are 6. Every run's range and its largest
reference are the format alone's of the first draw. A run is not the run it is
read over, figure for figure. The format alone has no sum past its range
wherever its reference is within its codes. And the two rows with nothing drawn
in them, the format alone and the crosstalk alone with no source, are on every
draw the run they are on the first.

203 errors were planted one at a time and every one fails. 103 in a training's
line, a run's line or the row a row is held against, against the check with
nothing run again, four of them a row that is not the line `chain` or
`chainlit` wrote. 44 in the script, each run in a directory of its own on 400
images. And 56 in the tables' own code, which the check does not see and which
have to move a table. With the script as it now is, `refcomb`'s, `chain`'s,
`chainfit`'s, `chainbit`'s and `chainlit`'s checks and tables alone, on the
lines their own sweeps wrote for MNIST, say yes and print what those sweeps
printed.

**The crosstalk and the shot noise are nine tenths of it.** A row's rms error
against its declared format, percent of the reference's rms, with no source:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone | 0.96 | 0.71 | 0.91 | 1.04 | 0.85 | 0.76 |
| and the receiver's noise | 1.27 | 0.94 | 1.21 | 1.35 | 1.12 | 1.00 |
| and the shot noise | 3.08 | 2.66 | 2.99 | 3.15 | 2.82 | 2.72 |
| and the programming error | 1.12 | 0.94 | 1.02 | 1.15 | 1.08 | 1.01 |
| and the crosstalk | 3.64 | 3.52 | 3.38 | 3.42 | 3.14 | 3.10 |
| As budgeted, less the receiver's noise | 4.74 | 4.42 | 4.47 | 4.59 | 4.21 | 4.13 |
| less the shot noise | 3.78 | 3.63 | 3.51 | 3.57 | 3.30 | 3.24 |
| less the programming error | 4.77 | 4.42 | 4.51 | 4.65 | 4.23 | 4.13 |
| less the crosstalk | 3.25 | 2.80 | 3.13 | 3.30 | 2.99 | 2.88 |
| less the shot noise and the crosstalk | 1.39 | 1.12 | 1.29 | 1.44 | 1.30 | 1.20 |
| As budgeted: all four | 4.81 | 4.46 | 4.54 | 4.67 | 4.28 | 4.18 |

And what each row of the budget adds to the format alone, squares for squares:
the root of the mean, over its 25 runs, of its rms squared less the format's of
the same network and draw. It is what the row would add if its error and the
format's were independent.

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The crosstalk alone adds | 3.52 | 3.45 | 3.26 | 3.26 | 3.02 | 3.01 |
| left out of the tile, it takes off | 3.55 | 3.48 | 3.29 | 3.30 | 3.05 | 3.04 |
| The shot noise alone adds | 2.93 | 2.56 | 2.85 | 2.99 | 2.71 | 2.61 |
| left out of the tile, it takes off | 2.98 | 2.59 | 2.88 | 3.03 | 2.75 | 2.64 |
| The receiver's noise alone adds | 0.83 | 0.61 | 0.79 | 0.89 | 0.75 | 0.66 |
| left out of the tile, it takes off | 0.84 | 0.62 | 0.80 | 0.90 | 0.76 | 0.66 |
| The programming error alone adds | 0.58 | 0.61 | 0.46 | 0.49 | 0.64 | 0.67 |
| left out of the tile, it takes off | 0.61 | 0.64 | 0.49 | 0.51 | 0.66 | 0.67 |
| The format and the four, were they independent | 4.79 | 4.44 | 4.52 | 4.66 | 4.27 | 4.17 |
| The tile as budgeted | 4.82 | 4.47 | 4.54 | 4.69 | 4.29 | 4.18 |

For the reference networks the crosstalk alone adds 3.45, 3.26 and 3.01, the
shot noise 2.56, 2.99 and 2.61, the receiver's noise 0.61, 0.89 and 0.66 and
the programming error 0.61, 0.49 and 0.67, where the format alone is 0.71, 1.04
and 0.76 off. The crosstalk is the largest of the four on every set and kind
and the shot noise the second. The two are 89 to 93% of the tile's squared
error, and the other two 4 to 5%.

**With no source the rows add in squares.** The root of the squares of the
format and of what the four add is 0.994 to 0.995 of the tile as budgeted's, on
every set and kind. A row left out of the tile takes off what it adds alone and
a little more, under 0.05 everywhere. So the budget can be read a row at a
time, with no source.

**Against the demonstration's 1.0%, the converter's own rounding is at the
bar.** The demonstration's draft asks for a normalized rms error within 1.0%
and does not say what it divides by. Both readings, with the runs of 25 that
are within 1.0% in brackets:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| Over the reference's rms: the format alone | 0.96 (20) | 0.71 (25) | 0.91 (25) | 1.04 (10) | 0.85 (15) | 0.76 (25) |
| Over the reference's rms: with the receiver's noise | 1.27 (0) | 0.94 (20) | 1.21 (0) | 1.35 (7) | 1.12 (10) | 1.00 (12) |
| Over the reference's rms: with the programming error | 1.12 (0) | 0.94 (25) | 1.02 (5) | 1.15 (10) | 1.08 (10) | 1.01 (13) |
| Over the reference's rms: the tile less the shot noise and the crosstalk | 1.39 (0) | 1.12 (0) | 1.29 (0) | 1.44 (0) | 1.30 (0) | 1.20 (0) |
| Over the reference's rms: the tile as budgeted | 4.81 (0) | 4.46 (0) | 4.54 (0) | 4.67 (0) | 4.28 (0) | 4.18 (0) |
| Over the largest the reference is: the format alone | 0.33 (25) | 0.25 (25) | 0.26 (25) | 0.28 (25) | 0.29 (25) | 0.27 (25) |
| Over the largest the reference is: the tile less the shot noise and the crosstalk | 0.48 (25) | 0.39 (25) | 0.37 (25) | 0.39 (25) | 0.45 (25) | 0.43 (25) |
| Over the largest the reference is: the tile less the crosstalk | 1.13 (5) | 0.98 (15) | 0.88 (25) | 0.90 (15) | 1.03 (10) | 1.02 (10) |
| Over the largest the reference is: the tile less the shot noise | 1.31 (0) | 1.28 (0) | 0.99 (10) | 0.97 (15) | 1.14 (0) | 1.15 (0) |
| Over the largest the reference is: the tile as budgeted | 1.67 (0) | 1.57 (0) | 1.28 (0) | 1.27 (0) | 1.47 (0) | 1.48 (0) |

The format alone is 0.71, 1.04 and 0.76% of the reference's rms off, and 120 of
its 150 runs are within 1.0%. With the shot noise and the crosstalk both out,
the receiver's noise and the programming error take it to 1.12, 1.44 and 1.20%,
and no run of the 150 is within. So if `normalized` means over the reference's
rms, the converter alone uses most of the bound or all of it, and no figure for
the two large rows passes this layer with the other two as budgeted. Over the
largest the reference is, the tile as budgeted is 1.57, 1.27 and 1.48% and no
run is within; less the crosstalk it is 0.98, 0.90 and 1.02%, with 80 of 150
runs within; and less the shot noise 1.28, 0.97 and 1.15%, with 25.

**The largest error is the shot noise's before it is the crosstalk's.** Percent
of the largest the reference is, with the runs of 25 within the demonstration's
2.0% in brackets:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone: a mean over the runs (runs of 25 within 2.0%) | 0.58 (25) | 2.14 (20) | 0.45 (25) | 7.22 (15) | 3.16 (15) | 0.47 (25) |
| the most in a run with no sum past the range | 0.67 | 0.49 | 0.48 | 0.58 | 0.60 | 0.51 |
| With the receiver's noise: a mean over the runs (runs of 25 within 2.0%) | 1.46 (25) | 2.69 (20) | 1.13 (25) | 7.75 (15) | 3.70 (15) | 1.18 (25) |
| the most in a run with no sum past the range | 1.67 | 1.29 | 1.29 | 1.52 | 1.57 | 1.33 |
| With the programming error: a mean over the runs (runs of 25 within 2.0%) | 1.56 (25) | 3.00 (20) | 1.19 (25) | 7.67 (15) | 3.73 (15) | 1.57 (25) |
| the most in a run with no sum past the range | 1.90 | 1.84 | 1.32 | 1.50 | 1.72 | 1.98 |
| With the crosstalk: a mean over the runs (runs of 25 within 2.0%) | 4.05 (0) | 4.87 (0) | 3.63 (0) | 9.02 (0) | 5.16 (0) | 3.46 (0) |
| the most in a run with no sum past the range | 4.65 | 4.32 | 4.04 | 3.64 | 3.51 | 3.61 |
| With the shot noise: a mean over the runs (runs of 25 within 2.0%) | 5.51 (0) | 5.57 (0) | 4.53 (0) | 10.00 (0) | 6.62 (0) | 4.94 (0) |
| the most in a run with no sum past the range | 6.21 | 5.46 | 4.96 | 5.54 | 5.85 | 5.57 |
| The tile less the shot noise and the crosstalk: a mean over the runs (runs of 25 within 2.0%) | 2.00 (12) | 3.25 (16) | 1.50 (25) | 7.90 (15) | 4.00 (9) | 1.84 (19) |
| the most in a run with no sum past the range | 2.32 | 2.18 | 1.77 | 1.88 | 2.27 | 2.30 |
| The tile less the crosstalk: a mean over the runs (runs of 25 within 2.0%) | 5.90 (0) | 5.80 (0) | 4.81 (0) | 10.14 (0) | 6.90 (0) | 5.27 (0) |
| the most in a run with no sum past the range | 6.84 | 5.67 | 5.45 | 5.85 | 6.68 | 5.89 |
| The tile less the shot noise: a mean over the runs (runs of 25 within 2.0%) | 4.64 (0) | 5.44 (0) | 4.21 (0) | 9.41 (0) | 5.70 (0) | 4.15 (0) |
| the most in a run with no sum past the range | 5.20 | 5.20 | 4.63 | 4.57 | 4.39 | 4.47 |
| The tile as budgeted: a mean over the runs (runs of 25 within 2.0%) | 8.44 (0) | 8.02 (0) | 7.20 (0) | 11.53 (0) | 8.60 (0) | 7.44 (0) |
| the most in a run with no sum past the range | 9.70 | 8.97 | 8.19 | 8.65 | 8.86 | 8.59 |

In a run with no sum past the converter's range the largest error is at the
most 0.7% for the format alone, 1.7 with the receiver's noise, 2.0 with the
programming error, 4.6 with the crosstalk, 6.2 with the shot noise and 9.7 as
budgeted. With the shot noise and the crosstalk both out it is 2.3%, and 96 of
the 150 runs are within 2.0%; with either of the two in, none is. A sum past
the range is its own error whatever the row. Where the format alone has one,
that sum's error is the largest of its run in every row with no source. And the
crosstalk makes more of them: 150 in a run at the most, where the format alone
has 77.

**The class is the shot noise's.** How often the class the tile gives is the
class its declared reference gives, percent, and in brackets the runs of 25 at
99.5% or more:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone | 99.74 (25) | 99.85 (25) | 98.16 (0) | 98.49 (0) | 99.54 (15) | 99.73 (25) |
| With the crosstalk alone | 99.69 (25) | 99.79 (25) | 97.84 (0) | 98.29 (0) | 99.45 (10) | 99.58 (25) |
| With the shot noise alone | 99.46 (8) | 99.64 (25) | 96.41 (0) | 97.18 (0) | 98.99 (0) | 99.35 (1) |
| The tile as budgeted | 99.40 (2) | 99.59 (23) | 95.92 (0) | 96.78 (0) | 98.86 (0) | 99.23 (0) |
| The tile less the crosstalk | 99.41 (3) | 99.60 (25) | 96.00 (0) | 96.81 (0) | 98.89 (0) | 99.28 (0) |
| The tile less the shot noise | 99.60 (23) | 99.74 (25) | 97.22 (0) | 97.80 (0) | 99.24 (0) | 99.52 (14) |
| The tile less both | 99.64 (24) | 99.78 (25) | 97.40 (0) | 97.92 (0) | 99.31 (4) | 99.60 (24) |

Leaving the shot noise out of the tile gives the reference networks that class
on 0.15 ± 0.02, 1.02 ± 0.08 and 0.29 ± 0.01 of a point more of the images,
clear on all three sets. Leaving the crosstalk out gives it on 0.01 ± 0.01,
0.03 ± 0.07 and 0.05 ± 0.02, clear on one. The crosstalk is the largest row of
the rms and next to nothing to the class.

**Because most of the crosstalk is a gain.** In the tile's model an input's
light also passes the two neighbouring rows' rings, so a row's weight is its
own and 5/256 of each neighbour's. Summed over a column, that is the column's
own weights times the neighbours' activations. Were every activation the same
it would be the sum itself times twice that fraction: a gain of 0.0391. The
last layer's inputs are a ReLU's outputs and none is below nought, so they
share a level. The probe:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone: its gain against the host's network | +0.0189 | +0.0250 | +0.0332 | +0.0266 | +0.0233 | +0.0219 |
| what is left with the shift and the gain out, % | 1.58 | 2.08 | 2.15 | 1.96 | 2.00 | 2.00 |
| The crosstalk alone: its gain, less the format's | +0.0281 | +0.0246 | +0.0258 | +0.0244 | +0.0240 | +0.0221 |
| what it adds to what is left, in squares | 1.53 | 1.82 | 1.27 | 1.38 | 1.48 | 1.59 |
| what it adds against the declared format | 3.52 | 3.45 | 3.26 | 3.26 | 3.02 | 3.01 |
| The shot noise alone: its gain, less the format's | −0.0001 | +0.0000 | −0.0001 | −0.0001 | +0.0000 | +0.0000 |
| what it adds to what is left, in squares | 2.90 | 2.55 | 2.85 | 2.98 | 2.69 | 2.59 |
| what it adds against the declared format | 2.93 | 2.56 | 2.85 | 2.99 | 2.71 | 2.61 |
| The tile as budgeted: its gain, less the format's | +0.0281 | +0.0246 | +0.0258 | +0.0244 | +0.0240 | +0.0220 |
| what is left, % | 3.80 | 3.88 | 3.95 | 3.97 | 3.84 | 3.78 |

Every row with the crosstalk in it and no source has a gain +0.0220 to +0.0281
above the format alone's, which is 0.56 to 0.72 of twice the fraction. Every
run of a row without it is within 0.0005 of the format's: no noise is a gain.
With the shift and the gain out, the crosstalk adds 1.82, 1.38 and 1.59 to what
is left of the format alone, where against the declared format it adds 3.45,
3.26 and 3.01. The shot noise adds 2.55, 2.98 and 2.59, which is all of its
2.56, 2.99 and 2.61.

**A source adds one thing over a row with the crosstalk and another over a row
without.** What `chainlit`'s source adds to a row, squares for squares, and the
lit tile with the crosstalk and without:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The source adds: over the format alone | 3.43 | 4.13 | 4.68 | 5.10 | 4.76 | 5.36 |
| The source adds: over the receiver's noise alone | 3.44 | 4.14 | 4.70 | 5.12 | 4.78 | 5.37 |
| The source adds: over the shot noise alone | 3.50 | 4.17 | 4.73 | 5.14 | 4.81 | 5.39 |
| The source adds: over the programming error alone | 3.46 | 4.15 | 4.71 | 5.13 | 4.80 | 5.39 |
| The source adds: over the tile less the crosstalk | 3.50 | 4.17 | 4.73 | 5.14 | 4.81 | 5.40 |
| The source adds: over the crosstalk alone | 1.75 | 2.69 | 1.88 | 2.74 | 2.42 | 3.29 |
| The source adds: over the tile less the shot noise | 1.62 | 2.61 | 1.85 | 2.72 | 2.40 | 3.28 |
| The source adds: over the tile as budgeted | 1.70 | 2.65 | 1.87 | 2.73 | 2.42 | 3.29 |
| Lit, rms error, %: the tile as budgeted | 5.10 | 5.18 | 4.84 | 5.34 | 4.89 | 5.27 |
| the tile less the crosstalk | 4.74 | 4.98 | 5.53 | 5.97 | 5.59 | 6.02 |

Over the format alone the source adds 4.13, 5.10 and 5.36 for the reference
networks, and over every row with no crosstalk in it the same to 0.08. Over the
crosstalk alone it adds 2.69, 2.74 and 3.29, and over every row with the
crosstalk in it the same to 0.13. So on Fashion-MNIST and on the inverted set
the lit tile is nearer its reference with the crosstalk than without, and on
MNIST it is not. Of the thirty networks 22 are nearer with it.

**Because the source takes gain off, and the crosstalk puts it on.**

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The source's gain: the format alone lit, less the format alone | −0.0065 | −0.0052 | −0.0232 | −0.0218 | −0.0226 | −0.0230 |
| runs of 25 where it is below nought | 18 | 16 | 25 | 25 | 25 | 25 |
| Weights the rail held back, % of those scaled, a mean | 3.6 | 4.5 | 6.3 | 6.8 | 4.6 | 5.4 |
| The crosstalk's gain, with no source | +0.0281 | +0.0246 | +0.0258 | +0.0244 | +0.0240 | +0.0221 |
| The two together: the crosstalk alone, lit | +0.0231 | +0.0209 | +0.0032 | +0.0033 | +0.0017 | −0.0007 |
| The lit tile as budgeted | +0.0220 | +0.0200 | +0.0022 | +0.0023 | +0.0007 | −0.0017 |
| What is left with the shift and the gain out, %: the lit tile | 4.77 | 5.35 | 4.89 | 5.22 | 4.89 | 5.24 |
| the lit tile less the crosstalk | 4.36 | 4.77 | 4.63 | 4.88 | 4.68 | 4.96 |

The format alone, lit, has a gain −0.0052, −0.0218 and −0.0230 from the format
alone's for the reference networks, and −0.074 to +0.007 in a run: below nought
in 134 of the 150 runs. It goes with the share of the weights the rail held
back, r = −0.57 over the 150. A weight raised for a dim line and held at the
rail is a weight too small, and the sums it feeds are too small with it. The
two gains add: the crosstalk alone, lit, is within 0.0015 of the sum of the two
on every set and kind. On MNIST the rail takes little off and most of the
crosstalk's gain is left. On the other two sets the two nearly cancel.

It is two errors of opposite sign, and not a remedy. With the shift and the
gain out the lit tile is 5.35, 5.22 and 5.24% of the reference's rms off with
the crosstalk and 4.77, 4.88 and 4.96% without: the worse with it on every set
and kind. The share of the weights at the rail explains about a third of how
much gain a run's source takes off, and these runs do not say what the rest
goes with.

**What these runs do not say.** The gain is the probe's, against the host's
network. None was fitted against the declared format, which is what the
demonstration compares. And no row had a gain taken out of its outputs before
that comparison, so what one constant would buy at the gate is not measured.
*The section after this one measures it.*
What is left against the host's network says the four rows would add 3.28, 3.47
and 3.20 where they add 4.41, 4.57 and 4.12: an estimate, from another
reference. The model's crosstalk is the same fraction of each neighbour in
every column, and a chip's need not come out as a gain.

**What was predicted.** Ten things, written on 2026-10-13 at 23:11 UTC, when
the mode and its check existed and no row of it had run. They were informed by
the one network the section before looked at, and say so. All are for the
reference networks, a mean over the runs of 10,000 images, percent of the
reference's rms and in squares unless said. Five were right as written.

1. That the crosstalk alone adds 3.0 to 4.0 over the format on every set, and
   is the largest of the four on every set and kind. Right: 3.45, 3.26 and
   3.01.

2. That the shot noise alone adds 2.3 to 3.0 on every set and is the second.
   Right: 2.56, 2.99 and 2.61.

3. That the receiver's noise alone adds 0.55 to 0.80 and the programming error
   alone 0.50 to 0.75. Wrong on Fashion-MNIST, both ways: 0.61, 0.89 and 0.66,
   and 0.61, 0.49 and 0.67.

4. That with no source the root of the squares of the format and of what the
   four add is within 3% of the tile as budgeted, on every set and kind. Right:
   within 0.6%.

5. That leaving the crosstalk out takes the tile to 2.2 to 3.3%, leaving the
   shot noise out to 3.2 to 3.9%, and leaving out the receiver's noise or the
   programming error moves it by under 0.12. Wrong, by 0.0002: less the
   crosstalk, Fashion-MNIST is 3.3002. The rest held: 2.80, 3.30 and 2.88, and
   3.63, 3.57 and 3.24.

6. That with the shot noise and the crosstalk both out it is 1.1 to 1.4%, with
   no run of the 150 within 1.0% of the reference's rms and every one within
   1.0% of the largest the reference is. Wrong on Fashion-MNIST: 1.12, 1.44 and
   1.20. Both counts held.

7. That lit, the source adds over the receiver's noise, the shot noise and the
   programming error alone what it adds over the format alone, to 0.15; that
   over the crosstalk alone it adds 0.7 to 1.5 less; and that with the
   crosstalk left out of the lit tile it adds what it adds over the format
   alone, to 0.25. Right of the first and the third. Wrong of the second on two
   sets, where it adds more than 2 less: 2.69, 2.74 and 3.29, against 4.13,
   5.10 and 5.36. The one network looked at was MNIST's.

8. That with no source, leaving the shot noise out gives the declared
   reference's class 0.12 to 0.35 of a point more often on MNIST and on the
   inverted set and 0.6 to 1.6 more on Fashion-MNIST, and leaving the crosstalk
   out under 0.08 more on MNIST and on the inverted set. Right: 0.15, 1.02 and
   0.29, and 0.01, 0.03 and 0.05.

9. That the largest error, a mean over a set's runs, is 2.5 to 5.5% of the
   largest the reference is with the crosstalk alone and 4.5 to 6.8 with the
   shot noise alone; and that leaving the crosstalk out of the tile takes under
   1.5 off it, where leaving the shot noise out takes 1.5 to 4. Wrong.
   Fashion-MNIST has sums past its range, and its means are theirs: 4.87, 9.02
   and 3.46, and 5.57, 10.00 and 4.94. And leaving the crosstalk out takes
   2.22, 1.39 and 2.17 off, more than was allowed.

10. That the mode's check says yes, that 200 lines a data set are `chain`'s and
    `chainlit`'s own, byte for byte, and that the crosstalk alone with no
    source is one run whatever the draw. Right.

**What this is not.** Everything the four sections before say of themselves: a
stand-in classifier, in a model, with the chain's other engines taken as exact.
A device's crosstalk. A gain against the declared format, or a tile with its
gain calibrated out. A source through an offset, a cycle of calibrations or a
drifted tile. A remedy for the crosstalk, the shot noise or the rail. Five
draws, of the same five networks.

### The first board's last layer, with one scale on its outputs

*Added 2026-10-14.* `SHAPE=chain sim/pta_mnist.sh DIR WORK chaingain`.
Reported, not gated. The harness gains `eval --gatescale M`, and nothing else
it prints moves.

**Why.** The section before found that most of the crosstalk's error is a gain
on every output, and that a source read and corrected on the weights takes gain
off. Its gain was the probe's, fitted against the host's own network, and the
demonstration holds the layer to its declared format. No row had a gain taken
out before that comparison, so what one constant would buy at the gate was not
measured. The demonstration's owner put the question of an output scale off
until it was (grxcp's B19, 2026-10-13).

**What the harness does.** `eval --gatescale M`, with `--gate`, runs M more
images through the same tile after the test images: the first M of the 6,000
the network was not trained on, from training image 54,000, with the light's
shots numbered past the test images'. Over their last layer it fixes one scale,
the least-squares slope of the declared reference on the tile's outputs, with
no offset: the sum of each output times its reference, over the sum of the
outputs squared. It then gives the gate's figures again with the test images'
outputs times that scale: the rms error over the reference's rms, over the
largest the reference is, and the largest error over that; and how often the
class, of the outputs times the scale and the biases, is the declared
reference's. Beside them it gives the scale the test images would fit
themselves, which no calibration knows and no scale betters, and what that
leaves. The scale is applied on the host's side, exactly. Every other figure
the line prints is what it was, and a line with no `--gatescale` says nothing
of one.

The self-test's 43 lines are as they were, with one more, and a build of the
chain's shape prints 29, one more. The new block uses the made-up network of
the blocks before it, its first two layers on the host and the last layer's
biases nought but one. At a scale of one the gate's figures are the probe's
own. The scale fixed on 37 other images is the one the probe fits on them. With
the format alone it is within a hundredth of one, and with 2% of crosstalk
under it, nearer the reference. The scale the images fit themselves leaves the
least, the outputs times two or times nought are as far off as their reference
is large, and times nought they give the biases' class. And what `eval` reports
is that scale on the images it was given, its shots numbered past the test
images', with the gate's figures at it and at the best. 25 errors were planted
one at a time in that code and built at both shapes: the scale's sums, the
reference's width, the best scale, the scaled error and its three figures, the
class with and without the biases, what the probe keeps, the calibration's
images and shots, and what is reported. Each fails the self-test at both
shapes.

**What it runs.** The eighteenth mode, in `chain`'s work directories and on its
networks, tile and draws: nine rows, on 10,000 images and on the first
thousand, on five draws, with `--host 2 --probe 1 --gate 1 --gatescale 1000`.
That is 900 evaluations a data set.

| Row | What it runs |
|---|---|
| format only | `--impair quant`: the tile's format and nothing drawn. `chain`'s row |
| only xtalk | and the crosstalk, `--xtalk 0.02`. `chainrows`' row |
| only shot | and the shot noise, `--photons8 30`. `chainrows`' row |
| less xtalk, less shot | The tile as budgeted with that row left out. `chainrows`' rows |
| as budgeted | All four of version 2's rows. `chain`'s row |
| as budgeted, fitted | With the last layer's range fitted, `--gatefit 1`. `chainfit`'s row |
| as budgeted, lit; as budgeted, lit, fitted | With `chainlit`'s source, read and corrected on the weights at 8 bits. `chainlit`'s rows |
| each of those nine, a thousand | The same on the test set's first thousand images, the gate's own. The four of `chainrows`' rows are new there |

Fourteen of the eighteen are runs `chain`, `chainfit`, `chainrows` and
`chainlit` made. The scale leaves a run as it was, and the mode holds each of
those lines, up to the scale's figures, to the line that mode wrote: 700 a data
set, all the same.

**How it was run.** The mode's check and ten predictions were written first,
the predictions at 15:23 UTC. It was run on two draws of MNIST to see the check
say yes, and it said no: in 7 runs of 360 the fixed scale and the test images'
own were the same to five places, which a condition had said they could not be.
The condition was a wrong one, and was taken out. It was then swept. Looking at
it, the mode's check could not see a mistake in how `cmd_eval` called the
calibration or printed it, so the reporting was moved into a function the
self-test reaches and the line gained the first image the scale was fixed on;
the sweep was run again, and every line but for that field was the line it had
been. The check was then made to hold the calibration to a thousand images from
image 54,000 whatever the script asks, and the fixed scale to within a
hundredth of the test images' own, where it had allowed two. The sweep was run
a third time, at 16:28 UTC, and took 33 minutes for the three data sets side by
side, beside the planted errors. Each of its 2,700 lines is the line the second
wrote, byte for byte, and the figures here are the third's. One of the planted
errors then found a gap, below, and the check was changed where it holds a run
to the line a mode before wrote: a line that is not there is now one that is
not the same. The mode's check and tables alone, with the script as it now is,
on each data set's sweep, say yes, hold the same 700 lines and print what the
sweep printed.

The mode checks every network and every run against its place, as `chainrows`
does its own. A run's name says its row, its draw and how many images, and its
line has to say the same: the impairments it names and no other, at version 2's
figures, the source's rows where it is lit, a range fitted where it says so.
Every run's scale was fixed on 1,000 images from image 54,000, is between a
half and one and a half, and is within a hundredth of the test images' own;
what the test images' own leaves is no more than no scale leaves or the fixed
one, and the scaled rms over the largest reference is no more than the scaled
largest error. And a run with nothing drawn in it, the format alone and the
crosstalk alone with no source, is on every draw the run it is on the first,
the scale's figures with the rest.

157 errors were planted one at a time, and all but 2 fail. 25 in the harness's
new code, against the self-test. 67 in a training's line, a run's line or the
line a run is held to, against the check with nothing run again. Of the seven
first planted that hold a run to a mode before, one found the gap: rows held to
the lines of a mode that never ran them were counted out, and not counted
against. Another was no error: it held the fitted rows to `chainlit`'s lines,
and `chainlit` ran those rows too, its lines `chainfit`'s byte for byte. It was
put in place of one that holds them to `chainrows`', a line `chainlit` wrote
was put aside to be missed, and those eight were run again with the check as it
now is: each fails. The rest never reach the part changed. 31 in the script,
each run in a directory of its own. 6 in how `cmd_eval` reaches the
calibration, each built into the harness and the mode run with it on one draw:
the scale fixed on the test images, on the training images, on as many images
as were tested, through the network as written and not as the source's
correction rewrote it, its figures printed in each other's place, and the
outputs not kept. Each fails, the last by a crash and not by a check. A scale
fixed on all 6,000 held-out images is taken, and one with no `--gate`, or on
none or on 6,001, is refused. And 28 in the tables' own code, which the check
does not see and which have to move a table. The 2 that do not are the class's
columns: the least with no scale printed for the least with it, and the runs at
99.5% with and without the scale exchanged. With no source the scale moves no
run's class, so on the lines they were tried on the two columns are the same
and a table cannot show it. With the script and the harness as they now are,
`refcomb`'s, `chain`'s, `chainfit`'s, `chainbit`'s, `chainlit`'s and
`chainrows`' checks and tables alone, on the lines their own sweeps wrote for
MNIST, say yes and print what those sweeps printed. Ten runs those modes and
the ones before them made were also run again with it, and each is the line its
sweep wrote, byte for byte.

**The scale.** Fixed on the held-out thousand, a mean over a row's 25 runs on
10,000 images:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone | 1.0001 | 1.0002 | 1.0002 | 1.0002 | 1.0002 | 1.0003 |
| The crosstalk alone | 0.9682 | 0.9698 | 0.9701 | 0.9707 | 0.9729 | 0.9738 |
| The shot noise alone | 0.9991 | 0.9993 | 0.9991 | 0.9991 | 0.9992 | 0.9993 |
| As budgeted, less the crosstalk | 0.9989 | 0.9992 | 0.9989 | 0.9989 | 0.9990 | 0.9991 |
| less the shot noise | 0.9681 | 0.9697 | 0.9700 | 0.9706 | 0.9727 | 0.9736 |
| As budgeted | 0.9673 | 0.9691 | 0.9692 | 0.9696 | 0.9720 | 0.9730 |
| As budgeted, fitted | 0.9673 | 0.9690 | 0.9692 | 0.9692 | 0.9717 | 0.9730 |
| As budgeted, lit | 0.9799 | 0.9841 | 0.9981 | 0.9996 | 0.9997 | 1.0033 |
| As budgeted, lit, fitted | 0.9799 | 0.9840 | 0.9981 | 0.9990 | 0.9994 | 1.0033 |
| The most a run's scale is from the test images' own, any row | 0.0032 | 0.0028 | 0.0036 | 0.0041 | 0.0038 | 0.0039 |

With no source every row with the crosstalk in it has a scale 0.967 to 0.974,
and every row without it a scale within 0.0011 of one. Lit, it is 0.984, 1.000
and 1.003 for the reference networks. In every run with no source the fixed
scale is within 0.0016 of the one the test images would fit themselves, and lit
within 0.0041. In no run does it leave more than 0.004 of a point more of the
reference's rms than theirs would, 0.016 lit. So a thousand images the gate is
not judged on fix it as well as the gate's own would.

**What it buys.** The rms error against the declared format, percent of the
reference's rms, on 10,000 images: with no scale, and with the outputs times
the scale.

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| The format alone | 0.96 → 0.96 | 0.71 → 0.71 | 0.91 → 0.91 | 1.04 → 1.04 | 0.85 → 0.85 | 0.76 → 0.76 |
| The crosstalk alone | 3.64 → 1.58 | 3.52 → 1.65 | 3.38 → 1.38 | 3.42 → 1.58 | 3.14 → 1.47 | 3.10 → 1.55 |
| The shot noise alone | 3.08 → 3.08 | 2.66 → 2.66 | 2.99 → 2.99 | 3.15 → 3.14 | 2.82 → 2.82 | 2.72 → 2.72 |
| As budgeted, less the crosstalk | 3.25 → 3.25 | 2.80 → 2.79 | 3.13 → 3.13 | 3.30 → 3.30 | 2.99 → 2.99 | 2.88 → 2.88 |
| less the shot noise | 3.78 → 1.86 | 3.63 → 1.86 | 3.51 → 1.65 | 3.57 → 1.86 | 3.30 → 1.76 | 3.24 → 1.80 |
| As budgeted | 4.81 → 3.43 | 4.46 → 3.13 | 4.54 → 3.25 | 4.67 → 3.46 | 4.28 → 3.18 | 4.18 → 3.14 |
| As budgeted, fitted | 4.81 → 3.43 | 4.64 → 3.35 | 4.54 → 3.25 | 5.05 → 3.92 | 4.61 → 3.59 | 4.18 → 3.14 |
| As budgeted, lit | 5.10 → 4.58 | 5.18 → 4.84 | 4.84 → 4.66 | 5.34 → 5.16 | 4.89 → 4.76 | 5.27 → 5.15 |
| As budgeted, lit, fitted | 5.10 → 4.58 | 5.33 → 4.99 | 4.84 → 4.66 | 5.66 → 5.49 | 5.18 → 5.05 | 5.27 → 5.15 |
| As budgeted: the share of the squared error the scale takes off | 0.49 | 0.51 | 0.49 | 0.45 | 0.45 | 0.43 |
| As budgeted, lit: the same | 0.19 | 0.13 | 0.07 | 0.07 | 0.05 | 0.05 |

As budgeted, with no source, the scale takes the reference networks from 4.46,
4.67 and 4.18 to 3.13, 3.46 and 3.14%: 0.43 to 0.51 of the squared error. That
is within 0.33, 0.16 and 0.27 of the tile with the crosstalk left out and no
scale. The crosstalk alone goes from 3.52, 3.42 and 3.10 to 1.65, 1.58 and
1.55%. Over the format alone, squares for squares, it still adds 1.49, 1.19 and
1.36, where with no scale it adds 3.45, 3.26 and 3.01: the rest of it is not
one gain on every output. Where the crosstalk is not, the scale moves the rms
by under 0.002: the shot noise and the format are no gain.

The scale is the gain the probe measured against the host's network. One and
the format alone's gain over one and the row's is the scale to 0.0089 in every
run with no source, and the scale is below it by 0.0035 to 0.0089 in every run
with the crosstalk in it. The probe took each image's common shift out before
it fitted its gain, and the scale takes none out.

**Lit, it buys little.** With the source the scale is 0.984, 1.000 and 1.003,
and it takes the lit tile from 5.18, 5.34 and 5.27 to 4.84, 5.16 and 5.15%:
0.34, 0.18 and 0.13 of a point, where with no source it took off 1.33, 1.21 and
1.04, and 0.05 to 0.13 of the squared error. The source had already taken gain
off, as the section before found, and the lit tile's scale is nearest one where
it took most. With the scale the lit tile is still further from its reference
than the tile with no source and no scale, on every set, for the reference
networks.

**At the gate.** On the test set's first thousand images, the gate's own, with
the runs of 25 within the demonstration's bounds in brackets:

| | MNIST, before | MNIST, reference | Fashion-MNIST, before | Fashion-MNIST, reference | Inverted, before | Inverted, reference |
|---|---|---|---|---|---|---|
| As budgeted: rms over the reference's rms, no scale (runs within 1.0%) | 4.87 (0) | 4.52 (0) | 4.54 (0) | 4.67 (0) | 4.34 (0) | 4.24 (0) |
| with the scale | 3.49 (0) | 3.18 (0) | 3.25 (0) | 3.46 (0) | 3.24 (0) | 3.21 (0) |
| rms over the largest the reference is, no scale (runs within 1.0%) | 1.79 (0) | 1.72 (0) | 1.42 (0) | 1.42 (0) | 1.59 (0) | 1.54 (0) |
| with the scale | 1.29 (0) | 1.21 (0) | 1.01 (15) | 1.05 (10) | 1.19 (0) | 1.17 (0) |
| largest error over the largest the reference is, no scale (runs within 2.0%) | 8.42 (0) | 7.69 (0) | 7.18 (0) | 7.53 (0) | 7.47 (0) | 7.16 (0) |
| with the scale | 5.79 (0) | 5.69 (0) | 4.80 (0) | 6.15 (0) | 5.52 (0) | 5.33 (0) |
| Lit, fitted: rms over the reference's rms, no scale | 5.16 (0) | 5.22 (0) | 4.86 (0) | 5.48 (0) | 5.06 (0) | 5.31 (0) |
| with the scale | 4.63 (0) | 4.87 (0) | 4.68 (0) | 5.30 (0) | 4.94 (0) | 5.19 (0) |
| rms over the largest the reference is, no scale | 1.90 (0) | 1.99 (0) | 1.52 (0) | 1.67 (0) | 1.85 (0) | 1.93 (0) |
| with the scale | 1.70 (0) | 1.86 (0) | 1.46 (0) | 1.61 (0) | 1.81 (0) | 1.89 (0) |
| largest error, no scale | 9.89 (0) | 10.43 (0) | 8.77 (0) | 9.49 (0) | 10.65 (0) | 11.31 (0) |
| with the scale | 9.62 (0) | 10.89 (0) | 8.33 (0) | 8.96 (0) | 10.39 (0) | 11.04 (0) |

No run of the 150 is within 1.0% of the reference's rms with the scale, with no
source or lit, as no run was without it. Over the largest the reference is, the
tile with no source goes from 1.72, 1.42 and 1.54 to 1.21, 1.05 and 1.17%, and
25 of its 150 runs are then within 1.0%, all of them Fashion-MNIST's. Lit and
fitted, it goes from 1.99, 1.67 and 1.93 to 1.86, 1.61 and 1.89%, and none is.
With no source the scale leaves the largest error 0.67 to 0.82 of what it was
on the gate's thousand and 0.68 to 0.97 on 10,000 images: a gain's error grows
with the output, and some of the largest was a gain's. Lit and fitted it leaves
it 0.95 to 1.04 of what it was, either way. No run of the 300 is within 2.0%
with it.

**The class does not move.** One scale on every output changes which is the
largest only through the biases. With it the class is the declared reference's
as often as with none, to 0.004 of a point, in every row, set and kind, and
with no source in no run at all. Of 25 runs 23, 0 and 0 are at the
demonstration's 99.5% as budgeted, as without it.

**What these runs do not say.** The scale is applied to the outputs exactly, on
the host's side. A chip would write it into the weights or into the converter's
codes, which rounds, and that is not modelled. It is one scale for all sixteen
of the layer's outputs, and for the last layer alone; a scale an output was not
tried. The images it is fixed on are the training set's own, held out: a board
would need a calibration set of its own, declared and frozen with the workload.
A tile that drifts after calibration, or a scale fixed again in a cycle, is not
modelled. And whether the demonstration's reference may carry a scale is its
owner's to rule.

**What was predicted.** Ten things, written on 2026-10-14 at 15:23 UTC, when
the harness change, its self-test and its planted errors, the mode and its
check existed and nothing of the mode had run. Eight runs made by hand on
MNIST, to see every earlier field unchanged, informed them, and they say so.
All are for the reference networks, a mean over the runs of 10,000 images,
percent of the reference's rms, unless said. 7 were right as written.

1. That the scale fixed on the held-out thousand is within 0.003 of the test
   images' own in every run with no source, and within 0.01 in every lit run.
   Right: 0.0016 and 0.0041.

2. That with no source the scale is 0.96 to 0.98 in every row with the
   crosstalk in it, and within 0.005 of one in every row without it. Right:
   0.967 to 0.974, and 0.0011.

3. That it takes the tile as budgeted to 3.0 to 3.6% on every set. Right: 3.13,
   3.46 and 3.14.

4. That with the shot noise alone, and with the format alone, the rms with the
   scale is within 0.02 of the rms without it. Right: within 0.001.

5. That with the crosstalk alone it takes the rms to 1.5 to 2.0 on every set.
   Right: 1.65, 1.58 and 1.55.

6. That lit, the scale is 0.97 to 0.995 at training's range, and takes the lit
   tile to 4.7 to 5.2; that lit and fitted, on the first thousand, it takes it
   to 5.0 to 5.4; and that it helps less lit than dark. Wrong. The scale is
   0.984, 1.000 and 1.003: on Fashion-MNIST and on the inverted set the source
   had taken off as much gain as the crosstalk put on. Lit and fitted on MNIST
   it goes to 4.87. The rest held: 4.84, 5.16 and 5.15, and less lit than dark.

7. That as budgeted with no source the class is the declared reference's on 0.0
   to 0.3 of a point more of the images with the scale. Right: on none more,
   and none fewer.

8. That on the first thousand, as budgeted with no source, no run of the 150 is
   within 1.0% of the reference's rms with the scale, and over the largest the
   reference is the rms is 1.0 to 1.25% on MNIST and on the inverted set and
   0.85 to 1.0% on Fashion-MNIST. Wrong on Fashion-MNIST: 1.21, 1.05 and 1.17.
   No run is within.

9. That the largest error is the shot noise's tail, and the scale leaves it 0.8
   to 1.0 of what it was, on every set and kind. Wrong: 0.68 to 0.97. Some of
   the largest error is a gain's.

10. That the mode's check says yes, and 700 lines a data set are the earlier
    modes' own, byte for byte, up to the scale's figures. Right.

**What this is not.** Everything the five sections before say of themselves: a
stand-in classifier, in a model, with the chain's other engines taken as exact.
A scale written into a chip. A calibration of the gain an output at a time, or
with an offset. A ruling on the demonstration's reference. Five draws, of the
same five networks.

### The first board's canary

*Added 2026-10-14.* `train --host 2`, then `SHAPE=chain sim/pta_mnist.sh DIR
WORK canary`. Reported, not gated. The harness gains `train --host N`; a
network trained with it says so in its file, and eval holds it to that.

**Why.** grxcp's B20 fixed the first board's canary on 2026-10-14: MNIST pooled
to 8 × 8; its first two layers the host's, at eight bits and trained with no
tile noise; its last trained for the tile at six bits; all three trained in one
run of this harness. Until now every network here had one weight width for all
its layers, and the reference networks (grxcp's B17) were trained with the
tile's noise on every layer's sums.

**What the harness does.** `train --host N` trains a network whose first N
layers are a digital engine's, as `eval --host N` runs them. Their weights are
rounded at the full D bits in training's forward pass and their sums get no
`--sumnoise`; the layers after are at `--wbits` with the noise, as before. Such
a network is written as `PTAMLP4`: the header, the depth, N, then the weights.
A network with none of the host's is the file it always was. Eval refuses it
under any `--host` but N, runs its host's layers at D bits, and prints
`net_host` and `host_wbits`, the width it ran them at. Every other file and
line is what it was.

The self-test's 44 lines are as they were, with one more, and a build of the
chain's shape prints 30, one more. The new block writes a network with two of
the host's to a temporary file and reads it back, writes one with none and
finds the file it always was, and is refused a file that says none or every
layer. It holds the host's view of the widths, 8 bits for the host's layers and
6 for the last. And it trains on made-up images for an epoch: with noise, none
goes on the host's layers' sums and a tenth of their rms on the last's; with no
noise at eight bits a network with two of the host's and one with none are the
same weight for weight, and at six they are not; what training reports is the
accuracy at each layer's width; and a network of one hidden layer, the host's,
is read back as written. 18 errors were planted one at a time in the new code
and built at both shapes. The first time, 15 failed the self-test, 2 did not
and one was not placed: the host's layers trained at the network's width, and
the depth not written for a network of one hidden layer. The last three of the
self-test's checks above were written for them, and all 18 fail it now.

**What it runs.** The nineteenth mode, in `chain`'s work directory for MNIST.
It trains five networks, seeds 1 to 5, each from its seed's 8-bit network:
`train --din 8 --wbits 6 --host 2 --hidden 2 --sumnoise 0.1 --epochs 8`, B17's
recipe with the noise on the last layer alone. Then it runs each as `chaingain`
runs the reference networks, with `--host 2 --probe 1 --gate 1 --gatescale
1000`, on five draws: 250 runs.

| Row | What it runs |
|---|---|
| format only | `--impair quant`: the tile's format and nothing drawn |
| as budgeted | All four of version 2's rows |
| as budgeted, fitted | With the last layer's range fitted, `--gatefit 1` |
| as budgeted, lit; as budgeted, lit, fitted | With `chainlit`'s source, read and corrected on the weights at 8 bits |
| each of those five, a thousand | The same on the test set's first thousand images, the gate's own |

**How it was run.** The rule for which network is the canary was ruled before
any was trained, at 21:39 UTC: seed 1's, with the other four reported beside
it. Ten predictions were written at 21:50 UTC, before any canary network
existed. A run on one draw, in a directory of its own, trained the five and its
check said yes. Writing the planted errors showed that no field said what width
eval ran the host's layers at, so the line gained `host_wbits` and the check
holds it to eight. The mode was then swept, its check said yes, and a table's
column was widened; the sweep was run again with the script as it now is, and
took 2 minutes. Each of its 250 lines is the first sweep's, byte for byte, and
the five networks it trained are the first run's, byte for byte: training is
the same each time.

The mode checks each network and each run against its place, as `chaingain`
does. A network was trained from its seed's 8-bit one for eight epochs, at six
bits, its first two layers the host's: none of the noise on their sums and a
tenth of their rms, to 5%, on the last's. A run says its network's first two
layers are the host's, that they ran at eight bits, and the rest of what
`chaingain` holds a run to: its row, draw, images, impairments, source, range
and scale.

93 errors were planted one at a time, and all but 1 fail. 18 in the new C,
against the self-test. 29 in a network's training line or a run's line, against
the check with nothing run again. 22 in the script, each run in a directory of
its own. 8 in what `cmd_eval` and `cmd_train` do with it, each built into the
harness and the mode run with it on one draw: the host's layers run at the
network's width, their width printed as the last layer's, nothing said of the
network's host's layers, the host's layers not passed to training, one fewer
passed, and nothing said of them in training's line; and the refusals taken
away. A canary run with any other `--host`, and training with every layer or a
layer below nought the host's, are refused. And 16 in the tables' own code. The
1 that does not is the class's column with the scale for the one without it,
which print the same wherever the scale moves no class, as in `chaingain`. With
the script and the harness as they now are, the checks and tables of `refcomb`,
`chain`, `chainfit`, `chainbit`, `chainlit`, `chainrows` and `chaingain` alone,
on the lines their own sweeps wrote for MNIST, say yes and print what those
sweeps printed. Eleven runs those modes made were run again, and each is its
line. And four networks they trained were trained again, three of the chain's
shape and a reference network of D3's, and each is its file and its training's
line, byte for byte.

**The networks.** Held-out and test accuracy on the host, and the noise
training put on the last layer's sums in its last epoch:

| Seed | Held out, % | Test images on the host, % | Noise on the last layer's sums, of their rms |
|---|---|---|---|
| 1 (the canary) | 97.52 | 96.84 | 0.0999 |
| 2 | 97.30 | 96.76 | 0.1000 |
| 3 | 97.57 | 97.14 | 0.0999 |
| 4 | 97.17 | 96.93 | 0.0999 |
| 5 | 97.28 | 97.16 | 0.1001 |

The five are 96.76 to 97.16% right on the test images on the host, a mean of
96.97; the stand-in's reference networks of the same seeds, as their training
logs say, are 96.87 to 97.40, a mean of 97.09.

**At the gate.** The last layer against its declared format, the canary and the
five beside the stand-in's reference networks of the same seeds, as `chaingain`
ran them; and the class:

| | rms error, % of the reference's rms: the canary, seed 1 | the five | the stand-in's five | the five less the stand-in's, by seed | Class the declared reference's, %: the canary (draws at 99.5%) | the five (runs at 99.5%) | The scale, the five |
|---|---|---|---|---|---|---|---|
| format only | 0.74 | 0.72 | 0.71 | +0.01 ± 0.01 | 99.84 (5 of 5) | 99.86 (25 of 25) | 1.0002 |
| as budgeted | 4.54 | 4.47 | 4.46 | +0.01 ± 0.02 | 99.60 (5 of 5) | 99.58 (22 of 25) | 0.9692 |
| as budgeted, fitted | 4.54 | 4.65 | 4.64 | +0.01 ± 0.02 | 99.60 (5 of 5) | 99.52 (17 of 25) | 0.9691 |
| as budgeted, lit | 5.04 | 5.30 | 5.18 | +0.12 ± 0.05 | 99.40 (0 of 5) | 99.38 (4 of 25) | 0.9859 |
| as budgeted, lit, fitted | 5.04 | 5.45 | 5.33 | +0.12 ± 0.05 | 99.40 (0 of 5) | 99.35 (3 of 25) | 0.9858 |
| format only, a thousand | 0.78 | 0.75 | 0.74 | +0.02 ± 0.01 | 99.90 (5 of 5) | 99.86 (25 of 25) | 1.0002 |
| as budgeted, a thousand | 4.61 | 4.53 | 4.52 | +0.01 ± 0.02 | 99.74 (5 of 5) | 99.56 (18 of 25) | 0.9693 |
| as budgeted, fitted, a thousand | 4.61 | 4.53 | 4.52 | +0.01 ± 0.02 | 99.74 (5 of 5) | 99.56 (18 of 25) | 0.9693 |
| as budgeted, lit, a thousand | 5.09 | 5.34 | 5.22 | +0.12 ± 0.05 | 99.42 (2 of 5) | 99.39 (10 of 25) | 0.9861 |
| as budgeted, lit, fitted, a thousand | 5.09 | 5.34 | 5.22 | +0.12 ± 0.05 | 99.42 (2 of 5) | 99.39 (10 of 25) | 0.9861 |

At the gate the canary is the stand-in. Network for network, the five less the
stand-in's are +0.007 ± 0.015 of the reference's rms as budgeted on 10,000
images and +0.117 ± 0.048 lit and fitted on the gate's thousand, and no
difference of rms, of rms over the largest the reference is, or of the largest
error is clear in any row. The scale is the stand-in's to 0.0019. The canary,
seed 1, is 4.61% on the gate's thousand as budgeted and 5.09% lit and fitted,
where the five are 4.53 and 5.34.

What the recipe gives up is a tenth of a point. On 10,000 images the five are
right on the tile 0.10 ± 0.03 of a point less often than the stand-in's with
the format alone and 0.12 ± 0.03 lit and fitted, clear in 4 of the ten rows.
Lit, their class is the declared reference's 0.05 ± 0.02 of a point less often,
clear in 2. On the gate's thousand no difference of accuracy or class is clear.

**What these runs do not say.** The canary is trained and run, not frozen: no
golden tensor exists, and whether FC3's declared reference is the sum before
the 8-bit converter, as here, or the converter's codes is not settled. Its
first two layers run on the host, exactly, at eight bits: B20's contract, and
not a GRX930 NPU's or a G100's output. The canary's own figures are five draws
of one network.

**What was predicted.** Ten things, written on 2026-10-14 at 21:50 UTC, when
the harness change, its self-test and the mode existed and no canary network
had been trained. They were put beside the stand-in's figures on MNIST, and say
so. 10 were right as written.

1. That every canary network is 96.6 to 97.6% right on the host, and the five's
   mean within 0.3 of the stand-in's 97.09. Right: 96.76 to 97.16, a mean of
   96.97.

2. That training puts none of its noise on the first two layers' sums and 0.095
   to 0.105 of their rms on the last's. Right: 0.0999 to 0.1001.

3. That the format alone, on 10,000 images, is 0.6 to 0.9. Right: 0.72.

4. That as budgeted the five are 4.0 to 5.0 on 10,000 images and the scale 0.96
   to 0.98. Right: 4.47 and 0.9692.

5. That lit and fitted, on the gate's thousand, the five are 4.8 to 5.8, and
   the scale lit 0.97 to 1.01. Right: 5.34 and 0.9859.

6. That on the gate's thousand the class is the declared reference's on 99.3 to
   99.8% as budgeted and 99.1 to 99.7% lit and fitted. Right: 99.56 and 99.39.

7. That no run of the 25 is within 1.0% of the reference's rms in any row with
   the budget in it, and at least 20 are with the format alone on 10,000
   images. Right: none, and all 25.

8. That as budgeted on the gate's thousand the largest error is 6 to 9.5% of
   the largest the reference is, and no run within 2.0%. Right: 7.51, and none.

9. That the canary is within 0.3 of the five's mean as budgeted on 10,000
   images. Right: 4.54 against 4.47.

10. That the mode's check says yes on its first sweep of five draws. Right.

**What this is not.** Everything the six sections before say of themselves: a
stand-in task, in a model, with the chain's other engines taken as exact. A
frozen canary, or its golden tensors. A band for Gate F. Five draws, of five
networks.

### The first board's canary, its golden tensors

*Added 2026-10-14.* `SHAPE=chain sim/pta_mnist.sh DIR WORK golden`, after
`canary`. Reported, not gated. The harness gains `pta_mnist golden`.

**Why.** With the canary trained, its golden tensors were next. grxgpu's
golden-generation plan asks for its weights and inputs, each stage's output in
the declared format, FC3's declared reference, the classes, a high-precision
pass, and their digests. The owner ruled three things for them on 2026-10-14,
as grxcp recommended (its B21), recorded at 23:37 UTC before any was written.
FC3's declared reference is the 8-bit converter's codes of FC3's exact sum,
rounded half up at the layer's step and held to −128 … 127; every figure in the
sections before reads the sum before the converter. One output scale for FC3
may be applied, fixed once at calibration on the first 1,000 held-out training
images, 54,000 to 54,999, and never on the gate's vectors; Gate F is reported
with it and without, and the band is set on the figure with it. And the tensors
are kept in grxcp, `docs/designs/canary/`.

**What the harness does.** `pta_mnist golden --data DIR --net NET --out DIR
--abits 6 --adcbits 8 --rows 128 --cols 64` reads a network trained with
`--host 2` and sets it up as eval does: the host's layers at eight bits with
their rescales, and the last layer's step by training's rule on the tile. It
writes headerless little-endian files: each layer's integer weights and int32
biases, FC3's weights as 6-bit codes; and for the first 1,000 test images and
for the calibration set, the pixels, inputs and labels, FC1's and FC2's
outputs, FC3's activation codes, its exact sums, its codes, the classes and a
double-precision pass. Its own pass, `golden_image()`, is integer arithmetic
alone: each hidden layer's sum with its bias, the ReLU, the rescale rounded
half up and held at 127; FC3's codes from its activation and weight codes,
floor(s / 32 + 1/2) of its sum s, held to the range; and the class the largest
code at its step with its bias, the first of two the same. The double-precision
pass is the network as trained, on the pixels over 255, each sum its bias first
and then each product in order. The command also runs every image through the
tile with its format alone, the hidden layers on the host, and fails if a code
is held at the range, if a code at its step is not the tile's output, or if an
operand is not the host's.

The self-test's 45 lines are as they were, with one more, and a build of the
chain's shape prints 31, one more. The new check, 5j, takes the same network
with its two hidden layers made the host's, at the fitted step and two steps
under. Image for image, `golden_image()` gives the operands the host gives the
hidden layers and the activation codes it gives the last; each code at its step
is the tile's output with the format alone; the class is the rule's; and two
steps under, the codes held are the sums the tile says are past its range. The
canary's vectors have no tie for the largest output, so 5j hands the class rule
four ties made for it.

21 errors were planted one at a time in the new code and built at the chain's
shape. Each has to be stopped by the self-test, by the command, or by grxcp's
checker run on a bundle made of what the command wrote. The first time, 19
were. One was not placed, and one, the class sent to the last of two the same,
passed all three: neither thousand has a tie. The ties in 5j were written for
it, and all 21 are stopped now: 12 by the self-test, 3 by the command and 6 by
the checker. With the script and the harness as they now are, the checks and
tables of `refcomb`, `chain`, `chainfit`, `chainbit`, `chainlit`, `chainrows`,
`chaingain` and `canary` alone, on the lines their own sweeps wrote for MNIST,
say yes and print what those sweeps printed. Thirteen runs those modes made
were run again, two of them the canary's, and each is its line. Five networks
they trained were trained again, the canary among them, and each is its file
and its training's line, byte for byte.

**What it runs.** The twentieth mode, in `canary`'s work directory. It needs
the canary that `canary` trained, seed 1's, and writes its tensors twice, into
`out/golden.a` and `out/golden.b`, and holds the two to each other byte for
byte. It took 16 seconds.

**What it wrote.**

| The canary's golden tensors | |
|---|---|
| The network | Seed 1's, `h2_d8_b6_host2_s1_n0.1_e8.net`, as `canary` trained it |
| The steps | FC1 and FC2 rescaled by 2⁹; FC3's converter step 2⁹ of its operands' sum, 32 of its codes' |
| FC3's codes | −96 to 67 on the acceptance vectors and −100 to 67 on the calibration set; none held |
| Against the tile with its format alone | 0 of 32,000 codes differ, and 0 of 256,000 hidden operands |
| Right, of the acceptance vectors | 96.60% with the declared format, 96.80% in double precision; the same class on 99.20% |
| Ties for the largest output | None, in either thousand |
| Written twice | The same, byte for byte; and written again after 5j was changed, the same |

grxcp keeps them in `docs/designs/canary/`, 23 artifacts of 730,780 bytes, with
a candidate manifest and a `SHA256SUMS`, and a checker written apart from this
harness, `pta_board_canary_golden.py`. It works every integer tensor out again
from the inputs and the integer weights, and the double-precision logits from
the network's file, to the last bit. Its own planted errors, 23 in its code and
a byte changed in each of the bundle's 25 files, the manifest and `SHA256SUMS`
among them, are all caught.

**What this is not.** A frozen canary: the manifest is a candidate, and the
freeze is Gridworkz's, on 2026-11-25. The band: no PTA run is in it, and the
canary's run against these codes, and the band from it, come next. FC1's and
FC2's engines: their tensors are the declared format, which a GRX930 NPU and a
G100 have to give. The scale: no tensor carries one; it is fitted on the PTA's
codes against `cal_fc3_codes_int8.bin`.

### The first board's canary, its band

*Added 2026-10-15.* `SHAPE=chain sim/pta_mnist.sh DIR WORK band`, after
`golden`. Reported, not gated. The harness gains `eval --gateref codes` and
`eval --lightseed N`.

**Why.** grxcp's B19 replaced the demonstration's 1.0% with a band, set once
the frozen canary had been through the model, and B21 made FC3's declared
reference the converter's codes and allowed one output scale. Every gate figure
in the sections before reads the exact sum before the converter.

**What the harness does.** `eval --gateref codes`, with `--gate`, holds the
last layer to the converter's code of the declared format's exact sum at the
last layer's step, floor(s / 2^S + 1/2) held to its codes, times 2^S: what the
golden pass writes. The probe's figures, the class and the scale's fit are all
against it, and the line gains `gate_codes`, the step; `gate_maxcode`, the
largest error in codes; and `gate_tail`, how many outputs are 1 to 32 codes off
or more, with the scale's own two beside the scale's figures. The light is
added after the converter, so a lit output need not be a code, and an output
counts as t codes off or more when it is more than t − 1/2 off. `--gateref
codes` is refused with `--gatefit` or `--gatebits`, which move the step or the
width, and without the tile's format. `eval --lightseed N` draws a light's line
levels, which are a source's own and do not move from one run of the vectors to
the next, from a seed of their own, where every shot's noise stays the run's;
the line gives the seed and the levels' rms, `light_levels`. It is refused
without a light.

The self-test's 46 lines are as they were, with two more, and a build of the
chain's shape prints 33, two more. One holds `gate_reference()` to cases worked
by hand at a step's edges, and the probe to the golden codes: with the format
alone, at the fitted step and two steps under, the probe's reference is
`golden_image()`'s codes image for image, held codes among them, and the tile
is that reference exactly; with noise and crosstalk its figures, largest error
and tail are those worked out apart, and the scale's sums and figures are
against the codes. The other holds the light's two seeds apart: with no level
the light is the shots' seed's, with no shot's noise the levels', and one seed
for both is the light every run before had. 23 errors were planted one at a
time in the new C, each built at the chain's shape and held to the self-test,
to the mode on twelve draws, and to the four refusals run by hand. The first
time 22 were stopped: a refusal taken away was still refused by a later check,
with another message, so the refusals were then held to their own messages. All
23 are stopped now: 12 by the self-test, 7 by the mode and 4 by a refusal.

**What it runs.** The twenty-first mode, in `canary`'s work directory, after
`golden`, whose line the canary's reference is held to. Every run is on the
gate's thousand with the scale fixed on the calibration set's thousand, and the
format alone runs once a network.

| Row | What it runs |
|---|---|
| format only | The tile's format and nothing drawn |
| as budgeted | Version 2's four rows |
| as budgeted, lit | The same, with B16's source read and corrected on the weights at 8 bits: the board's case |
| lit, 0.4 to 1.4 of the budget | Every row of the budget, the source's three among them, that many times its size |
| as budgeted, lit, ten sources | The lit row on the line levels of its first ten draws, each source on every tenth draw |

The canary runs every row on `BAND_DRAWS` draws, 1,000; the other four networks
the budget's two rows on `BAND_OTHER`, 100. 8,805 runs. A draw is another run
of the same vectors: the tile programmed again at every load of its weights,
every shot drawn again, and, but for the ten sources, the source's lines drawn
again. A run whose source has a line all but dark, which the reading of its
lines cannot correct, is refused, as a board's calibration would refuse that
source, and its file says so.

**How it was run.** The rule for the band and nine predictions were written at
01:13 UTC, after three runs of the canary on one draw and before any sweep. A
run on twelve draws showed the lit rows' spread to be the source's: so the
harness gained `--lightseed` and the mode the ten sources. The first sweep
stopped short of its check, on 20 runs of the 1.4 row refused for a dark line,
which the mode did not yet record; it records them now, and the second sweep
wrote every line of the first, byte for byte, and the 20 refusals. The rule's
tail could not be read from it: the harness counted to eight codes, and the
worst lit draw at the budget had 385 outputs eight or more off. The tail now
counts to 32, and a third sweep's lines are the second's field for field but
for the tails, whose first eight counts are the second's. It took 25 minutes
beside other work on the machine.

The mode checks each run against its place: the network, as `canary` trained
it; the draw's seed; each impairment at its factor of version 2's figure, the
crosstalk to its 1/256 step and the photons to 6%; a lit run's source, its
lines' reading near their factor's flatness, and the reading applied at 8 bits;
the reference in codes at its network's step, the canary's the golden line's;
how often the reference is right, and its largest value, its network's with the
format alone, the canary's 96.60%, the golden line's; the format alone exact;
tails that fall and say what the largest error says; a ten-sources run's levels
the same as every run of its source's and no other source's, and on its
source's own draw the lit run, byte for byte; and a refusal only in a lit row,
and only for a dark line. 50 errors were planted in the mode, and all are
caught: 22 doctored lines, judged by the check alone; 15 changes to the script,
each run on twelve draws; and 13 changes to the tables' code, each of which
prints other tables than the script's own, and grxcp's model, which works the
tables out again from the runs, refuses them.

With the script and the harness as they now are, the checks and tables of
`refcomb`, `chain`, `chainfit`, `chainbit`, `chainlit`, `chainrows`,
`chaingain` and `canary` alone, on the lines their own sweeps wrote for MNIST,
say yes and print what those sweeps printed. Thirteen runs those modes made
were run again, and each is its line; five networks they trained were trained
again, the canary among them, and each is its file. And `golden` writes again
the 19 tensors grxcp keeps, byte for byte.

**What it found.** The canary over its draws, with the scale:

| The canary, 1,000 draws a row | rms error with the scale, %: mean | sd | least | median | 99th percentile | most | Class with the scale, %: least | Largest error, codes: most | Refused |
|---|---|---|---|---|---|---|---|---|---|
| as budgeted | 3.322 | 0.020 | 3.260 | 3.321 | 3.367 | 3.385 | 99.1 | 7.79 | 0 |
| as budgeted, lit | 5.180 | 0.533 | 4.040 | 5.129 | 6.598 | 7.212 | 98.5 | 21.91 | 0 |
| lit, 0.4 of the budget | 2.219 | 0.156 | 1.909 | 2.195 | 2.652 | 2.881 | 99.3 | 9.27 | 0 |
| lit, 0.6 of the budget | 3.118 | 0.271 | 2.567 | 3.084 | 3.886 | 4.257 | 99.0 | 12.99 | 0 |
| lit, 0.8 of the budget | 4.101 | 0.399 | 3.261 | 4.058 | 5.204 | 5.686 | 98.8 | 17.29 | 0 |
| lit, 1.2 of the budget | 6.283 | 0.680 | 4.789 | 6.223 | 8.090 | 8.788 | 98.1 | 26.34 | 0 |
| lit, 1.4 of the budget | 7.424 | 0.829 | 5.534 | 7.370 | 9.599 | 10.408 | 97.6 | 31.13 | 20 |
| as budgeted, lit, ten sources | 4.879 | 0.474 | 4.170 | 4.784 | 5.763 | 5.823 | 98.5 | 15.21 | 0 |

With the format alone every network is its reference exactly, and how often
that reference is right, 96.20 to 96.70%, is the tile's accuracy. With no
source the canary is 3.32% of the reference's rms off, ± 0.02 from draw to
draw. Lit, it is 5.18%, ± 0.53, and 4.04 to 7.21%; without the scale 5.54%. The
lit spread is the source's: on one source the figure moves 0.043 points from
repeat to repeat, where the ten sources' means are 4.27 to 5.70%, 0.497 points
apart. The rows rise with the factor, and the tail with them: lit at the budget
the worst draw has 20 outputs 16 or more codes off and 16 at 17.

**The band.** By the rule: its upper edge the lit row's worst draw, rounded up
to a tenth of a point, 7.3%; its lower edge the 0.6 row's best, rounded down,
2.5%; the class the lit row's worst, 98.5%; and the tail the fewest codes at
which the lit row's worst draw has at most 16 outputs off, 17, with 16 allowed.
grxcp's model applies it, and how often the canary's draws pass:

| The canary's draws | Inside the band, % | Class, % | Tail, % | All three, % |
|---|---|---|---|---|
| as budgeted | 100.0 | 100.0 | 100.0 | 100.0 |
| as budgeted, lit | 100.0 | 100.0 | 100.0 | 100.0 |
| lit, 0.4 of the budget | 5.2 | 100.0 | 100.0 | 5.2 |
| lit, 0.6 of the budget | 100.0 | 100.0 | 100.0 | 100.0 |
| lit, 0.8 of the budget | 100.0 | 100.0 | 100.0 | 100.0 |
| lit, 1.2 of the budget | 92.0 | 98.6 | 99.5 | 91.6 |
| lit, 1.4 of the budget (20 refused) | 46.0 | 88.2 | 95.5 | 44.3 |
| as budgeted, lit, ten sources | 100.0 | 100.0 | 100.0 | 100.0 |

A tile at 0.6 to 1.0 of its budget passes on every draw, and one at 0.4 fails
on all but 5.2%, as more likely a wrong measurement than so good a tile. At 1.2
times its budget it still passes on 91.6% of draws, and at 1.4 on 44.3%: a
fixed band cannot tell a tile a fifth over its budget from one at it, because
most of the spread is which source a board has. The other four networks, lit at
the budget, pass on 99 to 100% of their draws. The owner ruled the band, the
class and the tail as the rule gives them, at 15:01 UTC, and left a band set
per board, from a board's measured source, as an open question (grxcp's B22).

**What was predicted.** Nine things, with the rule. 5 were right as written.

1. That with the format alone every network is exact, and the canary's
   reference right on 96.60%, the golden line's figure. Right.

2. That lit at its budget the canary is 4.5 to 4.9%, with a standard deviation
   of 0.05 to 0.25 and a largest of at most 5.5. Wrong: 5.18, 0.53 and 7.21;
   the spread was put at the noise's, and it is the source's.

3. That with no source it is 3.1 to 3.5%. Right: 3.32.

4. That the lit rows rise with the factor, the 0.6 row's mean 2.4 to 3.3%.
   Right: 3.12.

5. That the 1.2 row is 5.3 to 6.0%, and under a tenth of it at or under the
   budget's worst. Wrong: 6.28, and 89.9% of it is.

6. That the class lit at the budget is 99.1 to 99.6%, at least 98.5. Right:
   99.36, and 98.5.

7. That lit at the budget a run has 2 to 20 outputs eight or more codes off, at
   most 60. Wrong: 38.3 and 385.

8. That the other four networks lit at the budget are within 0.6 points of the
   canary. Right.

9. That the mode's check says yes on its first sweep. Wrong: the first sweep
   stopped on its refusals.

**What this is not.** Everything the sections before say of themselves: a
model, with FC1 and FC2 the host's, exactly. A board's source: B16's is drawn
here, and a board's own may sit anywhere in this spread, or outside it. A band
for any network but the canary. A converter that sees the light: the light is
added after it. A refused run is a calibration's fault and not Gate F's, and
the band says nothing of how often a board's source would be refused.

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
