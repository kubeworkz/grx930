# Phase 7 Roadmap: NPU Device Integration

This document answers: *What does the grxcp team need to build, what has the
c930 team delivered, and what remains to close Phase 7?*

## Current state (as of 3070806 / d78ec6b)

### What c930 has delivered

| Deliverable | Status | Location |
|-------------|--------|----------|
| NPU DPI shim (register-model-accurate) | ✅ Complete, all 5 defects fixed | `sim/npu_dpi_shim.c/h` |
| Verilator build target (cycle-accurate RTL sim) | ✅ Works, boots firmware | `make verilate-grxcp` |
| NPU DPI wrapper (Verilator C++ interface) | ✅ Complete | `sim/npu_dpi.h/cc` |
| Grxcp integration reference test | ✅ Complete | `sim/tb_grxcp_ref.cc` |
| Tiling library with `_ctx` API | ✅ Complete | `sw/npu_tile.h/c` |
| Architecture doc with full register map | ✅ Complete (14-entry index map) | `doc/c930_architecture.md §5` |
| STATUS.BUSY confirmed driven by RTL | ✅ Proven in simulation | `tb/tb_status_busy.sv` |
| Grxcp response doc (defect fixes + evidence) | ✅ Complete | `doc/grxcp_shim_fix_response.md` |

### What grxcp told us they need (three blockers)

From `reply_to_grx930_team.md`:

> Three things on our list before an end-to-end `grxblasGemmEx` run is possible:
> 1. An NPU allocator over the 64 KB DDR window
> 2. A seam so a model can be attached to the *enumerated* device
> 3. Deriving the device's `backend` field instead of hardcoding `GRX_BACKEND_SILICON`

---

## Blocker 1: NPU Memory Allocator

### What grxcp needs to build

`grxMalloc` on an NPU device currently reaches `vx_buffer_create(nullptr, …)`
and returns `VX_ERR_INVALID_VALUE`. The NPU device has no allocator.

The allocator needs to:
- Manage a 64 KB byte-addressable DDR window (0x0000–0xFFFF in NPU address space)
- Support `grxMalloc(size)` → returns a DDR offset within the window
- Support `grxFree(ptr)` → returns the offset to the free pool
- Handle alignment (A/B matrices must be word-aligned for DMA)
- Reject allocations that would exceed the 64 KB window

### What c930 can provide

**A reference allocator implementation.** The c930 tiling library already manages
DDR buffer placement (see `npu_tile.h` — `npu_tile_init()` takes base addresses).
We can provide a minimal bump allocator or first-fit allocator as a drop-in:

```c
// npu_ddr_alloc.h — minimal allocator for NPU's 64 KB DDR window
void  npu_ddr_alloc_init(uint32_t base, uint32_t size);
void *npu_ddr_alloc(uint32_t size, uint32_t alignment);
void  npu_ddr_free(void *ptr);
```

This would live in `c930/sim/npu_ddr_alloc.c` and be usable by both firmware
(test harness) and grxcp (host-side testing).

### Complexity: Low

A bump allocator is ~50 lines. A first-fit with free list is ~150 lines. The
grxcp team can write this themselves in an afternoon, but having a reference
implementation avoids ambiguity about alignment rules and DMA constraints.

---

## Blocker 2: Device Model Seam

### What grxcp needs to build

Today the runtime and `grxblas.cpp` each hold their own `npu_c930_device_t`.
There's no way to attach a register model (shim or RTL-backed) to the
*enumerated* device that the runtime hands to application code.

The seam needs to:
- Allow a register model to be injected after device enumeration
- Route all `npu_c930_read/write` calls through the injected model
- Support swapping models at runtime (for testing absent/dead/live/never-finishes)
- Not break the existing four models (absent, dead bus, live, never-finishes)

### What c930 can provide

**Not much directly** — this is a grxcp architectural decision. But we can:

1. **Ensure the shim's API matches their hook signatures.** The shim already
   exposes `npu_dpi_csr_read/write` and `npu_dpi_mem_read/write` with
   `void* ctx` parameters. This is the same shape as their
   `npu_c930_read_fn`/`npu_c930_write_fn`. The grxcp team confirmed: *"the
   `_ctx` form is the right shape and it is the same seam our backend uses
   (`npu_c930_attach_model`)."*

2. **Provide a thin adapter** if their hook signatures differ. If they need
   `uint32_t read(void* ctx, uint32_t offset)` instead of
   `uint32_t read(uint32_t addr)`, we can add a 10-line wrapper.

3. **Document the exact call sequence.** The grxcp backend dispatches:
   ```
   attach_model(ctx, read_fn, write_fn)
   → grxMalloc(NPU) → allocate DDR buffers
   → write CSRs via write_fn
   → poll STATUS via read_fn
   → read C via mem_read_fn
   → grxFree(NPU)
   ```
   We can provide a reference implementation of this sequence using the shim.

### Complexity: Medium

The seam itself is a grxcp design decision. The c930 contribution is ensuring
the shim plugs in cleanly and providing a reference integration sequence.

---

## Blocker 3: Backend Field Derivation

### What grxcp needs to build

The device's `backend` field is hardcoded to `GRX_BACKEND_SILICON`. When the
shim is attached, this would report the software GEMM model as silicon —
dishonest and dangerous for benchmarking.

The fix needs to:
- Derive `backend` from the attached model (shim → `GRX_BACKEND_EMULATION`,
  Verilator → `GRX_BACKEND_SIMULATION`, real hardware → `GRX_BACKEND_SILICON`)
- Update benchmarks to report the correct backend
- Not break existing code that assumes `backend == SILICON`

### What c930 can provide

**Not directly** — this is purely a grxcp runtime concern. But we can:

1. **Suggest an enum value.** If grxcp doesn't already have
   `GRX_BACKEND_EMULATION` or `GRX_BACKEND_SIMULATION`, we can propose one.

2. **Tag the shim.** The shim header could define a constant:
   ```c
   #define NPU_DPI_BACKEND GRX_BACKEND_EMULATION  // or similar
   ```
   This gives grxcp a value to use when attaching the shim model.

### Complexity: Low

A one-line enum addition and a conditional in device initialization.

---

## The Phase 7 Exit Gate

From `phase_ledger.md`:

> Exit gate **needs a c930** — it requires both devices present at once.

The gate is: *the same host program runs an INT8 GEMM on the GPU device and
on the NPU device by changing only `grxSetDevice`.*

### Two paths to close it

#### Path A: Shim-backed (grxcp's current path)

```
grxSetDevice(GRX_DEVICE_NPU)
  → device has allocator (Blocker 1)
  → device has model seam (Blocker 2)
  → backend field correct (Blocker 3)
  → grxblasGemmEx runs against shim
  → C matches reference
```

**Honest claim:** "The host backend drives the NPU register map correctly."
**Cannot claim:** "The NPU works."

#### Path B: RTL-backed (requires Verilator)

```
make verilate-grxcp   → builds Vc930_soc_verilator
./Vc930_soc_verilator → boots firmware, runs GEMM
  → grxSetDevice(GRX_DEVICE_NPU)
  → device has allocator + seam + backend
  → grxblasGemmEx runs against Verilator
  → C matches reference (cycle-accurate)
```

**Honest claim:** "The NPU executes a GEMM correctly in RTL simulation."
**Cannot claim:** "The NPU works on silicon." (needs actual FPGA or tapeout)

This path requires grxcp to install Verilator. The c930 team has already
verified the Verilator build works (`make verilate-grxcp` boots firmware
at 60K cycles/sec).

---

## What we can do right now (c930 side)

### Immediate (this week)

1. **Write `npu_ddr_alloc.c/h`** — a reference allocator for the 64 KB DDR
   window. Drop-in for grxcp to use or adapt. ~100 lines.

2. **Write a Phase 7 integration guide** — step-by-step recipe showing how
   to attach the shim to a grxcp device, allocate buffers, run a GEMM, and
   verify the result. ~200 lines of C pseudocode.

3. **Add a `NPU_DPI_BACKEND` constant** to the shim header so grxcp has a
   value for the backend field.

### Medium-term (next sprint)

4. **Install Verilator in grxcp's CI** — this is the single highest-leverage
   change. The Verilator build already works; it just needs to be available
   in their environment. Once it is, the RTL-backed path closes the exit gate.

5. **Write a grxcp-NPU integration test** that exercises the full
   `grxMalloc → CSR configure → trigger → poll → read C → grxFree` sequence
   against both the shim and Verilator, as a reference for grxcp.

### Long-term (Phase 7 completion)

6. **Tensor unit multi-CTA** (gap 7.12) — the single-CTA workaround limits
   the NPU to one output tile per launch. This is a c930 RTL change that
   unblocks three of five benchmark shapes. Not blocking Phase 7's first
   green run, but blocking full performance.

7. **Real hardware** — an FPGA bitstream for the Arty A7-35T (we have
   Vivado results at 587 MHz) would close the exit gate definitively.

---

## Summary: who does what

| Item | Owner | Effort | Blocking? |
|------|-------|--------|-----------|
| NPU allocator over 64KB DDR | grxcp (or c930 reference) | Low | Yes — first malloc fails |
| Device model seam | grxcp | Medium | Yes — can't attach shim to enumerated device |
| Backend field derivation | grxcp | Low | Yes — would report shim as silicon |
| Shim defect fixes | c930 ✅ Done | — | — |
| STATUS.BUSY confirmation | c930 ✅ Done | — | — |
| CYCLE_COUNT width answer | c930 ✅ Done | — | — |
| Architecture doc updates | c930 ✅ Done | — | — |
| DDR allocator reference | c930 (proposed) | Low | No (grxcp can write their own) |
| Integration guide | c930 (proposed) | Medium | No (helps grxcp) |
| Verilator in grxcp CI | grxcp + c930 | Low (install) | Yes (for RTL-backed path) |
| Multi-CTA tensor unit | c930 | High | No (Phase 7 first green doesn't need it) |
