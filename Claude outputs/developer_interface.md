# The GRXCP developer interface

**Status: a proposal, and the case for a decision that has not been made.**
Nothing here is built. The numbers are measured or marked as estimates, and the
recommendation is separable from them — if the arithmetic in section 3 is wrong,
the recommendation should change.

## 1. The toolkit mostly exists, which is not the interesting part

| GRXCP | CUDA equivalent |
|---|---|
| `grxcc` | `nvcc` |
| `grx-smi` | `nvidia-smi` |
| `grx-prof` | Nsight Compute / Systems |
| `grx-sanitize` | Compute Sanitizer |
| `grxblas` / `grxdnn` | cuBLAS / cuDNN |
| `grx_cg.h`, `grx_wmma.h`, `grx_warp.h` | cooperative_groups, `mma.h` |
| `grxify` | `hipify` |
| **`grx-conform`** | **none — NVIDIA is the specification** |

So the question is not which components to build. It is who the developer is,
and the three candidates want almost disjoint things:

1. **Porting existing CUDA.** Wants `grxify`, `grx_cuda_compat.h`, and the
   conformance number. Served by what we have.
2. **Writing new kernels.** Wants `grxcc`, the device headers, `grx-prof`.
   Smallest group, most toolkit-shaped.
3. **Never writing a kernel.** Calls a framework and wants it to land on our
   silicon.

**This document proposes (3), keeps (2) in reserve on the reasoning in section
8, and does not pursue (1).** The porting audience is a bet that developers have
CUDA they want to move. That bet ages badly and it anchors us to a 2007
execution model; see section 3 for why that model is specifically bad for this
machine.

## 2. What (3) actually requires, and the trap in it

Implementing PyTorch's operator set directly is not the shape of this work.
There are thousands of ATen operators and nobody implements them. The route is
to ingest below the framework, where the set is already decomposed — a
`torch.compile` backend receives a graph reduced to a few hundred core ops and
mostly pointwise, reduction and matmul; StableHLO or ONNX give a closed set.
Either way the primitive count is tens.

**We have most of those primitives already.** grxBLAS gives GEMM in fp32, fp16
via the tensor unit, and int8 via the NPU. grxDNN gives softmax, layer norm,
gelu, add-bias and fused attention. That is not a coincidence — it is the
transformer's primitive set, arrived at by building a transformer block.

What is missing is not compute. It is ingestion.

## 3. Graph-first is forced by the machine, not preferred on taste

**A launch costs 2776 cycles before it touches an element.** Measured by
sweeping `grxdnnAddBiasForward` over column counts at the block's own row count,
least squares over nine points: `cycles = 2776 + 4.33 * elements`. An
independent two-point fit from the block's own bias stages gave `2716 + 4.25`
and predicted a held-out third shape to 1.5%. The two agree.

**One transformer block is 23 launches** at `H=2`:

| stage | launches | | stage | launches |
|---|---|---|---|---|
| layer norm 1 | 1 | | out projection | 2 (`H` GEMMs) |
| qkv projection | 3 GEMMs | | out bias | 1 |
| qkv bias | 6 (`3 x H`) | | residual | 1 |
| attention | 4 (2 GEMMs, mask, softmax) | | layer norm 2 | 1 |
| mlp GEMM 1 | 1 | | mlp bias | 1 |
| gelu | 1 | | mlp GEMM 2 | 1 |

Nine of those are GEMMs, and that half is **measured** — `GRXBLAS_SGEMM_TRACE`
on a block run reports exactly nine, which is what makes the structural count
credible for the other fourteen.

At 2776 cycles each, 23 launches is **63848 cycles of fixed cost against a
302961-cycle block at S=16 — 21% spent before any element is touched.**

An eager operator-by-operator backend does not issue 23 launches per block. It
issues far more, far smaller ones — that is what the decomposed graph in section
2 looks like before fusion. **So eager dispatch is not a slower option for this
machine, it is a non-starter**, and the conclusion does not depend on the exact
launch count: at 2776 cycles fixed, any design whose unit of work is one
operator loses.

Two consequences worth stating plainly:

- The ingestion layer must take a **graph** and fuse it, not a stream of ops.
- The fusion work already in the gap register stops being an optimisation. The
  qkv bias fusion blocked by 7.27 is worth 5.9% of a block at S=16 as a
  point improvement; as the mechanism this strategy rests on it is worth
  considerably more, and the VOLT report should be weighted accordingly.

## 4. Which ingestion point

Not decided here. The two candidates:

**`torch.compile` / Inductor backend.** Meets developers where they are, needs
no model conversion step, and inherits PyTorch's decompositions. Costs a
dependency on a fast-moving internal interface, and the graphs arrive with
dynamic shapes.

**StableHLO or ONNX ingest.** A closed, versioned op set and a stable contract,
which suits a platform that wants to publish coverage honestly. Costs the
developer a conversion step and loses eager-mode debugging.

What would settle it is not argument but a survey: take three or four models the
company actually intends to run, and count how many primitives each route needs
that we do not have. That is a day of work and it replaces a design meeting.

## 5. bf16 is the blocker with the longest lead time

Modern inference runs in bf16. The situation on this hardware is asymmetric and
worth escalating on its own:

- **The GPU's tensor unit has no bf16 in any configuration.** `grxblas.h` states
  it directly: not a type this tensor unit has, in any build, with no knob to
  enable.
- **The c930 NPU does have it.** `c930_npu_core.sv` declares
  `i_precision` with `3 = BF16`, and `c930_bf16_mul.sv` is a real multiplier in
  the tree.

So the datapath the strategy needs exists on the accelerator and not on the GPU.
And the NPU cannot currently carry it at scale: its dimension bounds are
`MAX_M=8, MAX_N=12, MAX_K=16`, and as of today its command queue cannot pipeline
two back-to-back commands (see `tests/repro/npu_cmd_queue/`).

**bf16 at useful scale is presently reachable on neither device.** This is cheap
to address before tape-out and impossible afterwards, which makes it the item on
this page with the least schedule slack. It should go to the hardware teams
independently of whether the rest of this proposal is adopted.

## 6. The metric changes, and improves

`grx-conform` publishes coverage of the CUDA runtime surface — **57 of 83
tracked entry points, 69%**. That is the right honesty instrument for audience
(1), and if we are not pursuing (1) it measures something nobody is buying.

The report says so itself, in its own words: *"This is an API coverage number.
It is not a conformance pass rate: nothing in this report executes a kernel."*
That caveat is the argument for replacing it rather than a defect in it.

Its successor for audience (3) is a **numerics contract**: *this model produces
the same answers as the reference, within a stated tolerance, and here is the
fraction of models for which that holds.* We already do this at the kernel
level — grxDNN is gated against PyTorch-generated vectors in
`tests/libs/*_ref.bin`, and gelu carries a measured 5.36e-07 rather than a
quoted one. Scaling it to whole models keeps the posture and changes the
subject to one the buyer cares about.

It is also a better engineering gate. Coverage counts entry points that exist;
a numerics contract fails when an answer is wrong.

## 7. What this proposal does not build

- **Training and autograd.** Doubles the operator surface and needs the bf16 we
  do not have. Inference first.
- **An eager dispatch backend.** Section 3.
- **A CUDA porting story.** `grxify` and the compat header stay because they
  cost nothing to keep; they stop being a roadmap item.

## 8. Audience (2), and why AI-authored kernels invert its requirements

The kernel-writing audience is small, and there is a plausible argument that
assistants make it larger. If they do, the thing that changes is not the volume
of kernels but the ratio: **more kernels, less scrutiny per kernel.**

That inverts what the toolkit owes them. Authoring ergonomics matter less when
authoring is cheap; what matters is whether anyone can tell a kernel is wrong.

This is not speculative. On 2026-09-02 a correct-looking fused epilogue was
added to `micro_tile_body` and VOLT emitted **zero** `vx_split`/`vx_join` for
one instantiation — the kernel was exactly right on uniform shapes and silently
wrong the moment a branch diverged (gap 7.27). No diagnostic, at any warning
level. Reading the source would not have found it; counting instructions in the
emitted binary did.

So for audience (2) the deliverables are oracles and structural checks by
default, not a nicer `grxcc`:

- **Differential testing as the default**, the way `test_grxblas_rb` compares
  every tiling against the reference kernel over identical operands. A new
  kernel should arrive with a reference and a comparison, or not arrive.
- **Structural verification of emitted code.** `tests/repro/sgemm_4x4_splits/count_splits.sh`
  should become a tool — every kernel has reconvergence, no inner loop has stack
  traffic, entry points resolve, ABI versions match. This is a class of defect
  CUDA developers do not see because nvcc is eighteen years old. Ours is not.
- **Silence is a bug.** The library change on the same day that made
  `read_sgemm_shape` report when a module goes quiet is the pattern: a fallback
  that cannot fail is a fallback that cannot report.

## 9. Open questions

1. Which ingestion point (section 4), settled by the model survey rather than
   by discussion.
2. Whether bf16 can reach the GPU tensor unit, or whether the strategy routes
   all bf16 matmul through the NPU — which needs its bounds and its command
   queue addressed first.
3. What "a model runs" means as a gate. Suggested: end to end against a
   PyTorch reference at a stated tolerance, on a named backend, with the backend
   printed beside every number — the discipline the cycle benches already use.
4. Whether any of this precedes hardware. Phase 7 is unmet, multi-core is
   broken (7.37), and phase 3's tensor gate reads 2.51x against a 5x threshold.
   A developer preview on a simulator and an SDK for a part you can buy are
   different products with different bars, and this document does not say which
   one is being built.
