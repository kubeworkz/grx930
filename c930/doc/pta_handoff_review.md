# Review: grxcp's PTA handoff (three register-map items)

Reviewed 2026-10-16 against our tree at `npu/shim-tile-model`'s tip `211b351` — the harness was
rewritten underneath this review in the meantime (a multi-layer walk, the light source, the gate's
references), so §3's walk description and its line numbers were re-derived against that tip rather
than layered on the base this review first read — and against the document the handoff summarizes —
`grxcp/docs/designs/pta_fotonix_baseline.md` §5 and §7, whose wording the handoff reproduces
faithfully. `pta_handoff_grx930.md` arrived as a copy and is committed beside this review as our
record of it.

Method: each claim was checked against the artifact that implements it (RTL, DPI shim, driver
header, harness), not against our own prose. The handoff's own claims are quoted before being
answered. Every line number below was re-checked at `211b351` with this review's own edits in the
tree, so it names the line it claims; `sim/pta_mnist.c`'s numbers are the ones the seed seam below
left in place, not the ones this review first read.

## Verdict, and what each item needs from us

| # | handoff asks | answer | who moves |
|---|---|---|---|
| 1 | is `PTA_CAPS0.DIN_W` the datapath width that bounds `PTA_CAL_CFG`? | **Yes** — and the bound is `[DIN_W − B_a, DIN_W − 2]`, so one register read is one term short | we reply; no RTL change |
| 2 | wire `PTA_ID` = `0x50540100` and `PTA_CAPS2` bits 31/30/29 | **Three collisions**, one of which makes the acceptance unsatisfiable and one of which contradicts grxcp's own test in our tree | both; map decision first |
| 3 | pin the commit behind `gemm_seed()` | ready to pin: blob `2c653ad8…`, whose derivation last changed in `e47e251` and whose calibration phase's base in `b1a6e1b`; the premise is wrong, and the numbering — which no hash can capture — is now pinned by the harness's selftest (check 3b) | we reply with the hash and the index semantics |

## 1. `PTA_CAPS0.DIN_W` — yes, and the handoff is one term short

`PTA_CAPS0` carries it, in the core, the shim and the driver, all at `[25:20]`:

* `rtl/c930_npu_core.sv:522` (field map) and `:548` `assign o_pta_caps0 = {6'(ACC_W), 6'(DIN_W), …}`
* `sim/npu_dpi_shim.c:94-96` — the twin reports **its own** `NPU_DIN_W`, which is the whole point of
  the word (the model is 4 × 4 with its own widths; `c930_soc_top` has been 8 × 8)
* `sw/c930_npu_driver.h:119` `PTA_CAPS0_DIN_W(c) = ((c) >> 20) & 0x3F`

The amplitude bound the handoff is asking about is
`rtl/pta/c930_pta_cal.sv:221-223`:

```verilog
wire [4:0] qh = (i_quant && i_act_bits != 4'd0 && int'(i_act_bits) < DIN_W)
              ? 5'(DIN_W - int'(i_act_bits)) : 5'd0;
wire       amp_ok = (int'(i_amp_log2) <= DIN_W - 2) && (5'(i_amp_log2) >= qh);
```

So the legal range is **`[DIN_W − B_a, DIN_W − 2]` where `B_a` is `PTA_BITS[3:0]`**. The upper
bound is `CAPS0` alone; the lower bound is not. "Firmware then computes the legal amplitude range
from CAPS0" is right for the ceiling and wrong for the floor, and a driver that reads only `CAPS0`
can still pick a value the engine refuses. Both registers are already in the map, so the fix is
still "zero map change": read `CAPS0` and `PTA_BITS`, or take the ceiling `amp = DIN_W − 2`, which
satisfies the floor whenever `B_a ≥ 2` and is the value `sw/c930_npu_driver.h:141` names
`PTA_CAL_AMP_MAX`.

Better than a plausible answer, our own SoC test already *measures* it. `sw/pta_test.c:147`
`cal_amp_find()` still searches the way firmware would — top-down from 14, taking the first
amplitude the engine accepts, with the refusal read from `CAL_ERR` and cleared by `MODEL_RST` — and
T8 then asserts the search lands exactly on the CAPS0-derived ceiling (`:447`):

```c
ok &= (cal_amp_found == (int)PTA_CAL_AMP_MAX(caps0));   /* DIN_W - 2 */
```

So an independent search on the 16-bit SoC tile agrees with `CAPS0.DIN_W − 2`, which is the
decode check baseline §7 is waiting on, already run. The driver derives both bounds from `CAPS0`
(`sw/c930_npu_driver.h:138-142`).

Three places said the gap was still open, and they are the reason this question was asked at all.
All three are now marked answered against the RTL and the test that pins it, each citing
`PTA_CAPS0[25:20]` and `sw/pta_test.c`'s T8: `doc/pta_error_model_design_note.md` §7 item 5, this
handoff's own §1 (`pta_handoff_grx930.md`, our copy), and `cal_amp_find`'s comment in
`sw/pta_test.c` — which also now says why the search stays, as T8's cross-check rather than as
driver firmware's route. The fourth was baseline §7's parenthetical ("pending the `PTA_CAPS0.DIN_W`
decode check") and is closed in their tree as well: the baseline's v0.4 §7 now names
`PTA_CAPS0[25:20]`, and `pta_chiplet_regmap.md` §4's note, which still read "nothing here reports
`DIN_W`", is marked closed with the field position and the pin. Those two edits are mirrored into
grxcp's working tree on request and are the only changes we have made there.

One correction to the acceptance as written: "no `CAL_ERR`, on both the bench tile and the SoC
tile". The twin has **no calibration engine** — `NPU_CSR_PTA_CAPS2`'s cal bit is 0 for every shim
build (`sim/npu_dpi_shim.c:115-118`, and the shim's header: "no calibration engine (`PTA_CAL_*`,
`PTA_GAIN`, `PTA_OFFS`, `PTA_TRIM` read zero)"). On the twin `CAL_ERR` cannot be raised at all, so
that half of the acceptance passes vacuously and proves nothing. The bench-tile half has to be run
where the engine exists (`tb/tb_c930_npu.sv`).

## 2. `PTA_ID` and `PTA_CAPS2` — three collisions

**The address convention is fine and needs no change.** The handoff's `0x000`/`0x00C` are
block-relative; our SoC window base is `0x4000_0100`, the CSR block sits at `0x100`, and
`sw/c930_npu_driver.h:108-111` maps `PTA_REG_ID = PTA_BASE + 0x00`, `CAPS0 +0x04`, `CAPS1 +0x08`,
`CAPS2 +0x0c` — matching `rtl/c930_npu_csr.sv:309-312` (`A_PTA_ID = 8'h40` → `0x100` … `CAPS2` →
`0x10C`) and baseline §4's "only the base differs per target". Worth stating out loud so nobody
"fixes" a non-problem.

**Collision 1 — the ID word itself.** Baseline §7: "Bits [31:16] magic `0x5054` ("PT"); bits [15:8]
map version `0x01`; bits [7:0] reserved, zero. Reset value: `0x50540100`. A driver that reads
anything else is not talking to this map."

We ship `0x50544101` — `[31:8]` = `"PTA"`, `[7:0]` = version — asserted in eight places:

| where | value |
|---|---|
| `rtl/c930_npu_csr.sv:315` | `PTA_ID_VALUE = 32'h5054_4101` |
| `sw/c930_npu_driver.h:113-115` | `PTA_ID_MAGIC 0x50544100`, `IS_PTA(id) = ((id) & 0xFFFFFF00) == 0x50544100`, `VERSION(id) = id & 0xFF` |
| `sim/npu_dpi_shim.h:171` | `NPU_PTA_ID_VALUE 0x50544101` (the twin) |
| `sim/test_grxcp_fixes.c:61,73` | `== 0x50544101` |
| `sim/test_shim_pta.c:179` | `== 0x50544101` |
| `sim/tb_soc4.cc:1204` | golden `{"PTA_ID", id, 0x50544101}` |
| `tb/tb_c930_npu.sv:714,739` | `pta_expect(P_ID, v, 32'h5054_4101)` |
| `sw/pta_test.c:420` | `PTA_ID_IS_PTA(id) && PTA_ID_VERSION(id) == 1` |

Those assertions are live, not aspirational: `make shim_test` (2026-10-16, wsl + `HOST_CC`) builds
both shim tests and runs them green — `test_grxcp_fixes` **32 passed, 0 failed** with "PTA_ID is the
magic, map version 1", `test_shim_pta` **56 passed, 0 failed** with "PTA_ID". So the word below is
what grxcp's own test in this repo currently requires.

Two consequences worth putting in front of them. `0x50540100` fails our `IS_PTA` mask
(`0x50540100 & 0xFFFFFF00 = 0x50540100 ≠ 0x50544100`), so under their sentence our word is "not
talking to this map" and under ours theirs is not; exactly one of the two can be right. And their
encoding **drops the "A"** — magic `0x5054` is `"PT"`, where ours spells `"PTA"`. The cheap
resolution is theirs: `0x50540100 → 0x50544101` keeps their intent (magic + version 1) and matches
`test_grxcp_fixes.c`, which is a grxcp-facing test already in this repo — i.e. an earlier grxcp
requirement and this handoff disagree with each other. If instead the magic is normative at two
bytes, then the version moves to `[15:8]`, and our `IS_PTA` mask, `VERSION()` extractor and two
test expectations change: that is a map-version bump, not the "wiring" the handoff promises.

**Collision 2 — `PTA_CAPS2`'s bit assignments collide, and their reserved window covers our live
fields.** Baseline §7: "Bit 31 `TWIN`; bit 30 calibration engine present; bit 29 activation stage
present; bits [28:16] reserved, zero; bits [15:0] shot rate as built in MHz."

| bit | baseline §7 | ours (core / shim / driver, all three agree) |
|---|---|---|
| 31 | `TWIN` | `EMULATED` — model build; `npu_dpi_shim.c:117` sets `0x80000000 \| …, core computes `(PTA_BUILT != 0)` |
| 30 | cal engine present | reserved 0 |
| 29 | act stage present | reserved 0 |
| 28:20 | reserved, zero | 0 |
| [19:18] | *inside their reserved window* | **tile kind** — 0 none, 1 PTM-C, 2 PTM-B, 3 the model alone |
| [17] | *inside their reserved window* | **`PTA_CAPS2_HAS_ACT`** (`0x00020000`) |
| [16] | *inside their reserved window* | **`PTA_CAPS2_HAS_CAL`** (`0x00010000`) |
| 15:0 | shot rate MHz | shot rate MHz — we report 0 |

As written the two cannot both hold: the twin sets bit 30 while their own spec says `[28:16]` is
zero, and our driver's `PTA_CAPS2_TILE/HAS_CAL/HAS_ACT` decode reads bits their twin is told to
zero. The layout is otherwise identical in *information*, only in different places, and it is
documented on our side in three artifacts plus `pta_test.c` T8, which asserts the tile-kind and
emulated fields. One decision, then one edit each: either keep our `[17:16]`/`[19:18]` and move
`TWIN`/cal/act to `[31]`/`[30]`/`[29]` with `[28:20]` reserved, or drop their bits 30/29 in favour
of ours. Also worth naming: `TWIN` and our `EMULATED` are the same fact under two names, and our
core derives it from `PTA_BUILT != 0` — for a photonic tile that builds impairments that bit would
also read 1, so the reliable "this is a twin" discriminator is the tile-kind field (3), not bit 31.

**Collision 3 — "the twin reports TWIN with the modelled rate".** The twin does set the bit we call
`EMULATED` (`npu_dpi_shim.c:115-118`). It does **not** report a rate: it reports 0, because the
emulation's shot is `PTA_TS` core cycles and the shim has no timing at all (`npu_dpi_shim.h`:
"`PTA_TW` and `PTA_TS` read zero"). And baseline §5 rules that "a green twin run proves the digital
architecture and the register contract — **never** device physics, photonic throughput"; §7's field
documentation is photonic shot rates ("covers the 0.1 and 1 GS/s candidates: 100 and 1000"). A
twin that publishes `100` in that field is claiming photonic throughput, and one that publishes 0
fails the acceptance clause. So the clause needs a third option — "0, with the modelled rate
available from `PTA_TS` × clock" — or it should read "reports `TWIN` and zero rate", which is what
`CAPS2`'s own comment on our side already says. This is a decision for grxcp, not a wiring task.

## 3. The seed pin — ready, with one thing the hash does not capture

The text is verbatim as the handoff describes (`sim/pta_mnist.c:363-367`, over `splitmix64` at
`:349-355`): `splitmix64` over `((uint64_t)base << 32) | index`, high 32 bits returned, index low.

**The premise is wrong for that file.** `git diff --quiet -- c930/sim/pta_mnist.c` exits 0 — it is
clean against the branch tip — so the text they read *is* the committed text and the pin is
unambiguous. (Worth telling them plainly: there is nothing to reconcile. The one change this branch
makes to that file is the seed seam below, and it leaves `gemm_seed()` character for character.)

Pin, ready to paste into the provenance flag:

| what | id |
|---|---|
| the harness's file as this review read it | blob **`2c653ad8d3b10ba4e53ff5c86008294612bd823c`** (`sim/pta_mnist.c` at `211b351`) |
| last change to the derivation's text | **`e47e251`** (2026-09-16), "NPU: gate C1(a), the accuracy sweep on the D3 network" — `git log -L:gemm_seed:c930/sim/pta_mnist.c` traces both `gemm_seed()` and `splitmix64` back to the commit that created the file, and nothing has touched either since, this review's own edits included. **This row corrects this review's first reading**, which attributed the derivation to `b1a6e1b` |
| last change to the calibration phase's share of it | **`b1a6e1b44006ffba2f3ab64b65e2a1e3113a8a2c`** (2026-09-22), "NPU: C3's correction in the C reference, and the trim measured" — it added `calibrate_bank()` and the `seed ^ 0xCA11B` base on the eval path |
| branch tip for the surrounding harness | `211b351` (2026-10-16), whose subject is the flow's filler, not the harness |

Recommend they cite the **blob** plus those two commits: a rebase or cherry-pick changes a commit
id and leaves the blob alone, so the blob is what "whose text is normative" actually means, and the
two commits say which half of the provenance — the derivation, or the phase that shares its
counter — last moved.

**What the hash does not capture, and will silently diverge.** The index is not the GEMM number in
the layer. `sim/pta_mnist.c:3035` declares one `uint32_t gemm = 0` per run, and the evaluate path
hands it to `tile_batch` (`:3371`); `tile_batch` takes it by pointer and consumes one index per
issued tile command — every layer past the ones the host runs is cut into
`ceil(out / gemm_n) * ceil(in / gemm_k)` commands, one per `(N-tile, K-tile)` pair (`:1253`) — and
`calibrate_bank` consumes one per calibration repeat from the same counter (`:1695`, inside
`for (rep = 0; rep < repeats; ++rep)` at `:1691`), seeded with
`gemm_seed(seed ^ PTA_CAL_SEED_XOR, i)`. A third stream exists and is deliberately outside that
counter: the level probe shots the tile at its own index from `seed ^ 0x1E7E1u` (`:1769`), on a
counter of its own (`:1770`), so `--levelprobe` adds commands to a run without moving the run's
numbering. So the normative index is *the cumulative count of issued tile commands since the run
began, 0-based, calibration included and the level probe excluded*, with two seed bases (`seed` for
the GEMM phase, `seed ^ PTA_CAL_SEED_XOR` for calibration).

**That is the harness's numbering, and it is not the tile's** — a correction to this review's own
first reading. The tile's calibration is the engine's own: `rtl/pta/c930_pta_cal.sv:265` computes
`PTA_CAL_SEED ^ (j * 0x9E3779B1)` with `j` the `PTA_CAL_CT` value before that calibration runs, and
`rtl/pta/c930_ptm_c.sv:422-424` loads the streams from it for a calibration and only for a
calibration — which is what the register at `0x0DC` (`PTA_REG_CAL_SEED`, `sw/c930_npu_driver.h:175`,
written by `sw/pta_test.c:316`) is for, and what grxcp's regmap row says. The harness has no engine
to call, so it models the probe host-side and numbers it into the run's counter; the two agree on
the GEMM function and disagree on every calibration seed. So the normative GEMM index is *the GEMM
commands the chiplet has seeded since the last `PTA_SEED` write, 0-based* — the chiplet's
`PTA_GEMM_CT` — and calibration commands are not in it.

Baseline §7 said "`i` the `PTA_GEMM_CT` value at that GEMM's start", which was wrong twice over:
**our c930 side has no `GEMM_CT`** — not in `c930_npu_csr.sv`'s PTA block, not in `npu_dpi_shim.h`,
not in `c930_npu_driver.h`; the chiplet map's `0x018` is the only place such a register exists —
and the counter it names never holds a calibration's number. Both grxcp documents now separate the
two: their §2 seed bullet and §7 give the GEMM counter and the engine's own calibration seeding,
and the regmap's `0x0DC` prose says the same.

### The numbering is now pinned in the tree, not only in prose (2026-10-16)

A hash pins the function and nothing about the sequence, so `sim/pta_mnist.c`'s selftest now
carries a check of its own, numbered `3b` (`:3846`): the harness's selftest had grown to checks 1–13
by the time this was ported onto it, so a new one takes a sub-letter, the file's own convention
(`5b`, `8b`). It sits after check 3 and drives that check's walk — both banks calibrated, then two
batches of 37 — through a single `seed_take()`, which records every issued command, and holds the
transcript to the derivation grxcp's §7 pins, entry by entry: the base of the command's phase, the
index equal to the entry's position (so this harness's calibration has to consume its counter), and
the seed equal to a deliberate second transcription of §7 (`normative_seed()`), pinned by five
hard-coded words as well. What it pins is *the harness's* numbering, the C1 model's; the tile's
calibration seeds are the engine's, from `PTA_CAL_SEED ^ (j * 0x9E3779B1)`, and this model does not
imitate them. Two words of the transcript itself are pinned beside them — the first
calibration command, `0xDE5D6D61`, and the first command after it, `0x76078299` at index 96 — so a
change to the calibration base or to the numbering has to face a number rather than agree with its
own definition.

| | |
|---|---|
| run it | `make pta_mnist_selftest` (WSL `gcc`, no MNIST data needed), or `sim/pta_mnist.sh`, which runs `selftest` before it trains anything |
| green as it stands | `D=8` and `D=16` each issue 204 commands, 204 expected (2 × 48 calibrated, 2 × 54 in 2 batches), no divergence |
| not vacuous | `make pta_seed_seq_check` — `sim/pta_seed_seq_mutants.py` builds four mutations (one bit of the derivation, calibration ignoring the counter, the base off by one, numbering restarting per batch) and requires each to be red; each is, at index 0, index 1, the pinned word, and index 96 respectively |
| what it does not cover | the order of the phases in `cmd_eval`, which is visible there; the tile's calibration seeds, which are the engine's (`PTA_CAL_SEED ^ (j * 0x9E3779B1)`) and not this model's; and what a real MNIST run prints. That last was checked separately, twice: by dumping the previous tree's `(base, index)` pairs at the same sites and finding them exactly the first 216 of the new tree's 216 + 408, and — after the port onto the rewritten harness — by building the tip's `pta_mnist.c` and this branch's and diffing their `selftest` output, which agrees line for line except for check 3b's two added lines, so the seam moved no number anywhere in the harness |

## What is already right, so the reply can say so

The four-word identity block and read-only-ignored-writes; block-relative offsets; "the c930 window
base is `0x4000_0100`, only the base differs per target"; §7's corrected seed *function* (which
matches our text character for character); the `DIN_W` gap being closed without a new register; and
the two handoff items we owe are genuinely small — the ID is one line plus six assertions, `CAPS2`
is one assignment plus three masks, and item 1 is a reply rather than a change.
