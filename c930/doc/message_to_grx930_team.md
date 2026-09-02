# To the GRX930 team — from GRXCP, at commit `be40e94`

Four things, in the order they'd cost you if left. The first is the only urgent one: it's about code you have in flight right now, and it's one line today.

---

## 1. `npu_tile.h` can't drive our register models — needs a context pointer

**Urgent only because it's cheap now.** Your accessors are context-free and reach the device through file-scope statics:

```c
typedef unsigned int (*npu_read_fn)(unsigned int addr);
typedef void (*npu_write_fn)(unsigned int addr, unsigned int val);
static npu_read_fn  s_read  = 0;      // npu_tile.c:12
static npu_write_fn s_write = 0;


```

Ours carry a context:

```c
typedef uint32_t (*npu_c930_read_fn)(void* ctx, uint32_t offset);
typedef void     (*npu_c930_write_fn)(void* ctx, uint32_t offset, uint32_t v);


```

That difference matters because of how we test this backend without a c930. `test_npu_c930_model.cc` drives four register models — absent, dead bus, live, and accepts-a-launch-and-never-finishes — and two of them hold a `Regs` struct through `io_ctx`. With no context parameter we'd have to stash the device in a global and write trampolines, which defeats the injectable hooks and means your tiling library can't be exercised against any of those states.

**The question, rather than the request:** is `npu_tile.h` meant for firmware only? On the RV64 core there is exactly one NPU and a context pointer buys you nothing, so the current shape is right for that. Your header says "from grxcp firmware **or test harness**", which is what prompts this. If the host backend is in scope, `void* ctx` as the first parameter costs one line now and is a breaking change once anything depends on it.

## 2. `NPU_NUM_COLS` defaults to 8; the SoC instantiates 4

`npu_tile.h:52` defines it as 8. `c930_soc_top.sv:23` passes `NUM_COLS = 4`, and your own limits table has that row as 4 / 8.

It is currently **unused** — defined in the header and referenced nowhere in `npu_tile.c`, `npu_tile.h` or `npu_tile_test.c` — so nothing is wrong today. Flagging it precisely because it's free to fix while it's inert, and becomes a real bug the first time it's used for padding or alignment.

## 3. The limits table still reads "NPU core max: 8" beside "SoC default: 12"

`c930_architecture.md:556-562`:

<table>
  <tr><th>Parameter</th><th>SoC default</th><th>NPU core max</th></tr>
  <tr><td>MAX_N</td><td>12</td><td>8</td></tr>
</table>

The paragraph above it now says these are buffer sizes and not hard limits, so nobody following the prose is misled any more. But the row still asserts a maximum smaller than a shipped instantiation, and the column heading is what a reader skimming for limits will take away. "Core default" would make the row true.

## 4. Stale comment inside the section you just marked Complete

`c930_architecture.md:661`, in the build-commands block:

```bash
# Full SoC Verilator model (needs DDR init fix)
cd c930 && make verilate


```

The status table ten lines above now reads ✅ Complete for the Verilator model, and `c930_ddr_verilator.sv` has carried the flat-1D stub since `7a4ba39`.

---

## Confirmed on our side

**Gap 7.26 is answered and your reading is the one we've adopted.** "MAX_M, MAX_N, MAX_K are buffer sizes, not hard computational limits" settles it. The consequence for us is larger than the doc fix and is now recorded as phase 7 work: our `NPU_C930_MAX_M/N/K` are hardcoded to one SoC's synthesis defaults, so a build against a different SoC is wrong by construction; and `npu_c930_gemm` *refuses* a GEMM that exceeds them, which — with the semantics settled — is a missing feature rather than a correct guard. The caller's matrix isn't too big for the hardware, it's too big for one invocation. Your §14.7 is the guide for fixing that.

Your `#ifndef` overrides on the limits are the right pattern and better than ours, which has none. We haven't copied it yet, deliberately: an override macro would look like a fix while the real answer is that those limits should come from the device through a property, which `populate_npu_properties` doesn't publish at all today.

`afa17a5`** is verified holding.** The CRLF churn recurred — 73 files — and `git status` looked clean, which is misleading: that was git's stat cache, not a fix. Hashing content is decisive. With the attributes file, `git hash-object` on `c930_npu_core.sv` computes `ac5052…`, matching the index. Without it: `3e10ef0…` — exactly the blob from the original 2080-line diff. That repo is protected on a fresh clone now.

---

## What we still need from you

**A C-callable path to the register map that runs in our CI.** This is the one item blocking phase 7, and you have nearly built it.

Our roadmap has said for a while that "GRXCP needs *access* to hardware or to a simulation that answers on the register map, not more host code." `c930_npu_dpi.sv` plus `npu_dpi_test.cc` is that simulation. What's missing is reachability: **Verilator isn't installed in our environment**, so we can't build or run it.

What would close it: a linkable shim exposing `dpi_npu_csr_read/write` and `dpi_npu_mem_read/write` — which `npu_dpi.h` already describes — that we can link against, or a build recipe we can install. Our backend already routes every register access through injectable hooks driven by four models; yours becomes a fifth, and phase 7's exit gate becomes runnable for the first time.

Worth stating plainly: **nothing on our side has ever run on a c930, and no green run here may be reported as the NPU working.** A register model is not hardware. What we can honestly claim today is that the host side is truthful about what it can see and can be exercised without one.
