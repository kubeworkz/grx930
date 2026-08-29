GRXCP · GRX-G100 · GRX930

# Phase ledger

Cut 27 Aug 2026 · commit f002940

**Not complete.** Five of eight exit gates are met, one was met and is now red because the kernel it is measured against got faster, one has not started, and one needs hardware nobody here has. Every row below names the gate or the command that establishes it — nothing on this page is an impression.

### Since the last cut

**A measurement defect, then the largest speedup on the board, then a broken gate.** `VX_CSR_MCYCLE` **restarts at zero at every launch** — SimX resets the core's `PerfStats` at the top of each run — and the block profiler deliberately spanned attention across **four** launches, so its headline number was a maximum over four unrelated clocks with the shape and units of a duration. It had already changed a decision: the sgemm kernel rule was reverted on a 27.6% “regression” read off it. The symptom was in the data the whole time and nothing was looking at it — **64 warps live at once on a device that holds 16**. `grxCycleSummary` now carries `maxLive` and the profiler refuses any span that exceeds device occupancy. **Anything read off a multi-launch probe buffer on this stack, in any project, is suspect.**

With numbers that mean something, the **micro-tile** landed — and then reading the disassembly of the shipped image found something larger. The k loop indexed its operands as `ta ? A[l + row*lda] : A[row + l*lda]`, and the compiler re-decided the loop-invariant transpose *every iteration*. The 4×2 inner loop was **64 instructions for 8 multiply-adds**: 6 loads, 8 multiply-adds, 18 conditional selects and 12 index widenings. Half of it was address arithmetic.

Walking pointers instead — the step is a constant decided once, before the loop — cut that loop to 23 and the 2×2 loop from 42 to **14**. **2.17× on the whole transformer block** against the reference kernel, 72 of 72 in-situ flips. It also un-spilled the 4×4 kernel, which corrects the previous cut's explanation: the address arithmetic was what wouldn't fit in registers, not the sixteen accumulators. And with the overhead gone the wider tiles had nothing left to amortise — the second threshold that shipped one commit earlier was **removed**, and the sweep now gates the negative claim, because a change that makes the loop expensive again would surface there first.

**Then the same lesson again, one layer down.** With the GEMMs 3× faster, GELU became the largest single stage. Ablation put two-thirds of its cost in the exponential's polynomial — and there is no cheaper polynomial at 4.77e-07 — but its column loop was 86 instructions for 21 float operations, carrying twelve `vx_split` and eighteen `vx_join`. **Float selects compile to branches here.** The integer ternaries in the GEMM kernels become conditional moves; the float ones do not, and rewriting the early returns as ternaries left the counts at exactly 18 and 18 — the fix that was supposed to work is what proved the assumption wrong. Asked for by name, `fmin.s`, `fmax.s` and `fsgnj.s` take `dnn_gelu` from 352 instructions to 229 and from twelve splits to **none**: **1.34× on GELU with the arithmetic untouched and the accuracy identical to the last digit.**

**Three findings, one static property — so it is a gate now.** The transpose select, the 4×4 spill and GELU's divergence were all visible in the disassembly of the shipped image, and none was found by looking: each came from measuring a speedup, disbelieving it, and going to check. `ci/check_kernel_loops.py` reads the hot loop of every kernel out of the image and pins what it is made of. It found a fourth immediately: `dnn_layernorm` re-tested two null pointers *per element* — `gamma` and `beta` are kernel arguments — and hoisting them made that stage **9% faster**.

**Then the census corrected itself, which is the part worth reading.** Its first run named five kernels as spilling or diverging, and the number was published here. Those instructions exist — but in the *row* loop, not the element loop the report implied, and a per-row branch differs from a per-element one by the row width. The rule was "the loop with the most float operations"; it now picks the **innermost** loop that does float work. It had to change anyway, and that is how it was caught: splitting one element loop into four siblings made the old rule pick the row loop enclosing all four, so it reported more spills and more divergence for a change that made the kernel 9% faster. A heuristic that reads a genuine improvement as a regression is not measuring what it names. Corrected, the only divergence left in the whole image is one `vx_split` in each of the two tensor kernels.

And it **broke phase 3's exit gate**, which asks that GemmEx cost at most a fifth of sgemm per output element. sgemm is now 3.76× faster, so the ratio fell 5.62× → 2.65× with the tensor path completely unchanged. **The threshold was not moved.** Against the reference kernel the same shapes read 9.96×, and the bench prints both so which side of the fraction moved is legible. On three of five shapes the tensor unit is now within 2.5× of a SIMT kernel — a fact about how little of the core the single-CTA workaround lets it use, not about the unit. The gate is red, its failure is deferred so the thirty sections after it still run, and it goes green again when the tensor unit can fill the core — gap 7.12.

57/83CUDA entry points implemented (69%) — phase 6's gate, met

38/39tier-2 gates green on simx, none skipped — the odd one out is phase 3, red on purpose

0tests ever run on rtlsim

23/25gap-register entries still open

The eight gates

## Where each phase actually stands

Ordered because the phases are a dependency chain, not a list. A gate is *met* only where something ran and produced the number the clause asks for.

0

Foundations

`grx-smi` enumerates a real device on **both** simx and rtlsim.

simx **MET** — real device through the actual driver, PHASE 0 GATE.

rtlsim **never run** — needs Verilator and the `hw/dpi` sources; this checkout carries only `VX_define.vh` and `VX_gpu_pkg.sv`.

half

1

Runtime API v1

A kernel compiles, launches and computes the right answer on a real device.

**MET** — PHASE 1 GATE: vecadd built with VOLT from GRXCP's own device header, correct at 1 / 64 / 70 / 255 elements including partial warps. Allocator, memcpy family, streams and events all pass through the real command processor.

met

2

Device programming model and tools

Warp shuffle correct; the sanitizer finds a planted bug and names the line; the profiler emits a readable trace.

**MET** — WARP GATE, CG GATE, SANITIZE GATE (four planted bugs, each located), PROF GATE (trace parses, kernel slice present, counters respond to the work).

met

3

grxBLAS and tensor-core exposure

`grxblasGemmEx` costs at most a fifth of scalar sgemm per output element.

**MET** — PHASE 3 EXIT GATE: worst speedup **5.62×** among the two shapes that fill the core; three tile-starved shapes reported rather than dropped.

met

4

`grxcc` single-source driver

Three clauses: `<<<>>>` compiles and runs; ten CUDA samples build unmodified; coverage improves.

**MET, 3 of 3** — PHASE 4 GATE; CUDA SAMPLES GATE builds and runs **eleven**; coverage moved 61% → 65%.

met

5

Concurrency and asynchrony

A two-stream ping-pong shows measurable overlap against the single-stream baseline.

**Not started, and gated externally.** Measured this run, not assumed: 6 trials at a 5000-iteration budget, **0 overlapped, 6 ran the full distance, 0 reordered**. Streams serialize on GRX-G100. Needs the command-processor work upstream (`cuda_mapping.md` 7.3).

blocked

6

Library breadth and advanced memory

Two clauses: a transformer block against PyTorch, **and** coverage reaching 57 of 83 (69%).

Block clause **MET** — PHASE 6 EXIT GATE: attention + GEMM + layernorm + softmax end to end, agreeing with a PyTorch CPU reference.

Coverage clause **MET** — **57 of 83**. `grx::tex<>` supplied the last three. They are PARTIAL and sample in SOFTWARE: the TEX units are unreachable from compute (7.8, still open), so `textureIsEmulated` reads 1, grx-conform prints it, and the TEXTURE GATE fails if it ever stops. A gate closed by counting entry points that pretended to be hardware would be the worst outcome available.

met

7

NPU as a second device, and the native host

The same host program runs an INT8 GEMM on the GPU and on the NPU by changing only `grxSetDevice`, with matching results.

Exit gate **needs a c930** — it requires both devices present at once.

Three of four scope items landed: cross-device pointers, the documented dispatch rule with an inspection entry point, and the riscv64 host leg with an ABI layout gate. Each found a live defect; see the reverse side of this ledger below.

partial

Whose move

## What is waiting on whom

The left column is the ask. None of it is more host code — it is access, silicon, or a decision only the hardware side can make.

### Needs the GRX-G100 / GRX930 side

- rtlsim, at allVerilator and the `hw/dpi` sources. This is the largest structural hole: [AGENTS.md](http://AGENTS.md) §4 requires every conformance test to run on simx *and* rtlsim, and no test has ever run on the second. Every "runs on the device" claim in the project is simx-only, so there is no cross-backend check anywhere.
- Tensor unit deadlocks on a second CTAGap 7.12. Forces the single-CTA workaround, which is what bounds the tensor path to its output-tile count and starves three of five bench shapes. Still reproduces every run.
- Stream concurrency in the command processorGap 7.3. Phase 5 cannot start before it lands. Semantics already ship, so nothing breaks when it does.
- Device-side event timingGap 7.4. Elapsed time currently measures the host clock around execution — on simx that measures the simulator, and the report says so.
- A c930, or a register-map-accurate simulation of oneEverything about the NPU past the register model is unverifiable here. The backend's decisions are gated against four register models; a register model is not hardware and no green run may be reported as the NPU working.
- Are MAX_M=8 / MAX_N=12 / MAX_K=16 real?Taken from `c930_soc_top.sv` defaults. Hardware limits or synthesis defaults changes whether the NPU path needs tiling.
- Rounding builtins in divergent codeNew, gap 7.24. `floorf`, `ceilf`, `truncf`, `roundf` and `rintf` do not compile on a divergent value — *unimplemented divergent codegen found*. `nearbyintf`, `fabsf` and `sqrtf` do. The five that fail lower to a float→int→float sequence with an explicit rounding mode. Found by the first device code that ever needed one.
- Atomics, and the WSHFL RFCThis build has no A extension — an AMO aborts, and `atomicAdd` is refused by name (gap 7.16). The warp-shuffle ISA proposal remains the single highest-leverage hardware change for CUDA-style performance.

### Ours to finish

- Library breadthconv2d, grxFFT, grxRAND, grxSPARSE, `grx::par`, `grxrtc`, and promoting `grxcc` to a proper Clang `ToolChain`. None built. Phase 6's gate is closed; this is the work beyond it.
- Kernel-argument pointer checkingA device-1 pointer packed into a struct reaches the device unexamined; the launch path takes an opaque blob with no type information. The only available approach is a heuristic scan, so it is written down rather than shipped — architecture §10 rule 5 is about not shipping a guess that reads as a guarantee.
- The sgemm crossover — settled, and then beaten againThe sweep said `m·n·batch ≥ 2×resident` explains all 66 isolated shapes; the block said shipping it cost 3766 cycles; the losing rule was kept and the conflict written down as unexplained. **There was no conflict.** `VX_CSR_MCYCLE` restarts at zero at every launch, attention is four launches sharing one probe buffer, and its “cost” was a maximum over four unrelated clocks. Measured per launch the sign flips: those two calls now **save 5990 cycles**. Then the 2D micro-tile beat that kernel everywhere too, and the threshold moved to resident and has stayed there — a second one shipped for exactly one commit and was removed when the loop it depended on got 3× cheaper. It stays at `resident` rather than dropping to `resident/2` for a measured reason: at k=16 the crossover is at 32 outputs, but at k=8 those same three shapes lose 11%, and the sweep that once concluded “k never decides anything” had been held at n=16 where every cell is past the boundary. Whole block 347851 → 165600. `ci/sweep_block_sgemm.py` flips one call at a time through the whole block, against every alternative, and gates that all 72 are right. The reference kernel's own loop stays as it is on purpose: it is the oracle, and if it shared an addressing idiom with the kernels it checks, a bug in that idiom would pass the bit-exact comparison.
- Smaller, measured, deprioritisedA cheaper rational `tanh` (GELU is 11.5% of the block and the cost is the transcendental, not the traffic); strided `memcpy2D` descriptors; fusing bias into the GEMM epilogue, which the profile puts at about 2% against the GEMM's own 25%.

Standing watches

## Three upstream defects, still reproducing

These run on every tier-2 pass and are expected to fail. They exist so the day one of them starts passing is a day somebody notices, rather than a fact discovered years later.

Tensor unit on a second CTAtests/repro/tcu_multi_cta/ · gap 7.12

one CTA: completes two CTAs: DEADLOCK -- upstream defect still present

Do two streams overlap yettests/repro/stream_overlap/ · gap 7.3

6 trials, 5000 iteration budget: 0 overlapped, 6 ran the distance, 0 reordered STREAMS ARE SERIALIZED on GRX-G100 (simx) (expected).

`__syncthreads()` under divergenceBARRIER GATE · gap 7.20

guarded_good: GRXCP's convergent __syncthreads() -> correct guarded_bad: upstream's bare vx_barrier -> STILL BROKEN, deadlocked Keep the wrapper.

Coverage

## What the 65% is made of

83 tracked CUDA Runtime entry points. A curated surface, not the whole API — see the note at the top of `tools/common/cuda_api_table.inc` for what is counted and why. This is API coverage, not a conformance pass rate: nothing in that report executes a kernel.

| **State** | **Count** | **Meaning**                                                                                       |
| --------- | --------- | ------------------------------------------------------------------------------------------------- |
| mapped    | 34        | full CUDA semantics                                                                               |
| partial   | 20        | works, with a documented difference                                                               |
| refused   | 4         | returns an error rather than pretending — and all four are verified to actually refuse at runtime |
| absent    | 25        | not implemented; 3 in phase 6's scope, the rest behind hardware or out of scope for v1            |

Everything above reproduces from a clean checkout. Tier 1 needs no sysroot and runs both host legs in 44 seconds; tier 2 needs the GRX-G100 sysroot and the device toolchain.

./ci/build_mock.sh ./ci/run_real.sh --grxgpu  --tooldir

Gates are self-checking where they can be: the docs gate, the perf comparator and the ABI probe each plant their own failures before reporting, and every gate on this page has been watched failing at least once. A gate nobody has seen fail is not a gate.

---

## Summary

**NPU DPI wrapper created** — the grxcp team can now test their backend against cycle-accurate NPU RTL without full SoC integration.

### What's in `c930/sim/`:

<table>
  <tr><th>File</th><th>Purpose</th></tr>
  <tr><td>c930_npu_dpi.sv</td><td>Standalone NPU module with flat DDR + AXI slave</td></tr>
  <tr><td>npu_dpi.h</td><td>C++ header with CSR addresses and high-level API</td></tr>
  <tr><td>npu_dpi.cc</td><td>DPI function implementations</td></tr>
  <tr><td>npu_dpi_test.cc</td><td>Example INT8 GEMM test harness</td></tr>
</table>

### grxcp usage:

```plaintext
#include "npu_dpi.h"

// 1. Load A/B data
for (int i = 0; i < M*K; i++)
    dpi_npu_mem_write(A_ADDR + i, A[i], 0x1);
for (int i = 0; i < K*N; i++)
    dpi_npu_mem_write(B_ADDR + i, B[i], 0x1);

// 2. Configure NPU
dpi_npu_csr_write(NPU_CSR_DIM_M,  M);
dpi_npu_csr_write(NPU_CSR_DIM_N,  N);
dpi_npu_csr_write(NPU_CSR_DIM_K,  K);
dpi_npu_csr_write(NPU_CSR_A_BASE, A_ADDR);
dpi_npu_csr_write(NPU_CSR_B_BASE, B_ADDR);
dpi_npu_csr_write(NPU_CSR_C_BASE, C_ADDR);
dpi_npu_csr_write(NPU_CSR_PREC,   0);  // INT8

// 3. Trigger and wait
dpi_npu_csr_write(NPU_CSR_START, 1);
while (!(dpi_npu_csr_read(NPU_CSR_STATUS) & 0x2))  // poll DONE
    ;

// 4. Read results
for (int i = 0; i < M*N; i++)
    C[i] = dpi_npu_mem_read(C_ADDR + i * 4);

```

### Build:

```plaintext
make verilate-npu
./build/npu_dpi/Vc930_npu_dpi

```

This addresses the GRXCP team's requirement: *"A c930, or a register-map-accurate simulation of one — everything about the NPU past the register model is unverifiable here."*
