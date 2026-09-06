# C930 Multi-Core Architecture Plan

## Executive Summary

The C930 SoC now has **two RV64IMAC cores, two 8×8 systolic NPUs**, a
4-master AXI crossbar, and a dual-core MMIO arbiter.  The dual-core
groundwork is complete and verified end-to-end: CPU1 boots from the boot
ROM, parks in a `CORE1_RELEASE` poll loop, and both cores can program the
NPUs and exchange mailboxes through the shared crossbar (Test 9 in
`tb_c930_soc_full.sv`).  This document records that work and the roadmap
for the ambitious **Phase 3: 4-core + 2-NPU**.

**Phase 3 scope (agreed):**

- 4 cores (CPU0-3), 2 NPUs (already done), MESI directory-based cache
  coherence, 64 KB shared L2, RISC-V AIA APLIC for interrupt routing,
  and DDR command reordering for mixed CPU/NPU traffic.

**Estimated effort: ~6-8 weeks.**  The dual-core and 2-NPU halves are
banked; the coherence stack (MESI directory + shared L2) is the bulk of
what remains and is architectural, not incremental.

---

## 1. Current Architecture

### 1.1 Components

| Component | Type | Count | Purpose |
|-----------|------|-------|---------|
| RV64IMAC core | 5-stage in-order CPU | 1 | Control flow, DMA setup, MMIO |
| 8×8 systolic array | Fixed-function GEMM | 1 | 64 MACs/cycle |
| MIG DDR3L controller | Memory interface | 1 | 256 MB DDR3L |
| MMIO bridge | Interconnect | 1 | CPU ↔ NPU CSR |
| Command queue | FIFO | 1 | 4-deep GEMM queue |

### 1.2 Resource Budget (Artix-7-100T)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUTs | ~50,000 | 63,400 | ~79% |
| FFs | ~25,000 | 126,800 | ~20% |
| DSPs | ~150 | 240 | ~63% |
| BRAMs | ~24 | 135 | ~18% |

### 1.3 Memory Map

```
0x0000_0000 .. 0x0000_FFFF : DDR3L (64 KB used by firmware)
0x0001_0000 .. 0x0FFF_FFFF : DDR3L (remainder)
0x4000_0000 .. 0x4000_003F : NPU MMIO CSR (command queue)
```

---

## 2. Dual-Core Architecture (IMPLEMENTED ✅)

Status: CPU1 boots at boot-ROM `0x10020`, parks polling `CORE1_RELEASE`
(`0x4000_0FF4`), and jumps to a worker entry address when armed.  Both
cores read `HART_ID` (`0x4000_0FF0`) to branch on identity.  Verified by
Test 9 (dual-core HART_ID + RELEASE handshake, per-core GEMM
verification) in the full-SoC suite.

Resource budget (analysis from the original design):

### 2.1 Resource Budget

Adding a second RV64IMAC core:

| Component | LUTs | FFs | BRAMs |
|-----------|------|-----|-------|
| RV64IMAC core | ~15,000 | ~8,000 | 0 |
| I-cache (4 KB) | ~2,000 | ~500 | 4 |
| D-cache (4 KB) | ~2,000 | ~500 | 4 |
| Bus arbiter | ~500 | ~200 | 0 |
| **Total added** | **~20,000** | **~9,200** | **8** |

**Projected utilization on Artix-7-100T:**

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUTs | ~70,000 | 63,400 | **110%** ❌ |
| FFs | ~34,000 | 126,800 | 27% ✅ |
| DSPs | ~150 | 240 | 63% ✅ |
| BRAMs | ~32 | 135 | 24% ✅ |

**Does not fit on Arty A7-100T.** Needs Artix-7-200T (215K LUTs) or larger.

### 2.2 FPGA Options

| Board | Part | LUTs | FFs | DSPs | BRAMs | Cost |
|-------|------|------|-----|------|-------|------|
| **Arty A7-100T** | XC7A100T | 63K | 127K | 240 | 135 | $130 |
| **Arty A7-200T** | XC7A200T | 215K | 430K | 740 | 365 | $180 |
| **Nexys Video** | XC7A200T | 215K | 430K | 740 | 365 | $250 |
| **Genesys ZU** | ZU3EG | 154K+ARM | — | — | — | $350 |

**Recommendation:** Arty A7-200T ($180) — same board family, same pinout,
2.5× the LUTs, fits 2 cores + 8×8 NPU at ~35% utilization.

### 2.3 Bus Architecture

Two cores need shared access to DDR3L. Options:

**Option A: Shared bus with round-robin arbiter (simplest)**
```
Core 0 ─┐
         ├─ Bus Arbiter ─ MIG DDR3L
Core 1 ─┘
NPU DMA ─┘
```
- Single DDR3L port, round-robin arbitration
- Lowest latency for single-core, serialized for dual-core
- ~500 LUTs overhead
- **No coherence needed** if both cores share the same cache (single-bank)

**Option B: Separate DDR3L ports (highest bandwidth)**
- MIG with multiple AXI slave ports
- Each core gets its own DDR3L port
- Needs coherence protocol between cores
- Higher resource cost (MIG IP duplication)

**Option C: Shared bus with snooping (moderate coherence)**
- Cores snoop each other's caches
- Coherence directory in the arbiter
- ~2K LUTs overhead
- Moderate complexity

**Recommendation:** Option A for v1. Shared bus, round-robin, single cache.
The NPU already dominates DDR3L bandwidth; adding a second core doesn't
increase NPU throughput. A second core helps with control flow parallelism
(scheduling NPU commands, processing I/O), not compute.

### 2.4 Cache Coherence

For v1 (shared bus, single cache model):
- Both cores share the same physical DDR3L
- No private caches — both read/write through the shared bus
- No coherence protocol needed
- Simplest implementation: two cores share one icache and one dcache
  (dual-port or time-multiplexed)

For v2 (private caches):
- Needs MESI or MOESI protocol
- Snooping bus or directory-based coherence
- ~5-10K LUTs overhead
- Only needed if cores have independent workloads with shared data

**Recommendation:** Skip cache coherence for v1. The grxcp workload is
NPU-bound, not CPU-bound. A second core only needs to handle I/O and
scheduling, not high-bandwidth data processing.

---

## 3. NPU Scheduling

### 3.1 Current: Command Queue (done)

The 4-entry command queue in `c930_npu_csr.sv` allows the CPU to submit
GEMMs without waiting:

```c
// CPU programs GEMM #1
CSR_DIM_M = 8; CSR_DIM_N = 8; CSR_DIM_K = 16;
CSR_A_BASE = addr_a; CSR_B_BASE = addr_b; CSR_C_BASE = addr_c;
CSR_CTRL = CSR_START;  // dispatches immediately (idle)

// CPU programs GEMM #2 (while #1 runs)
CSR_DIM_M = 4; CSR_DIM_N = 4; CSR_DIM_K = 8;
CSR_A_BASE = addr_a2; CSR_B_BASE = addr_b2; CSR_C_BASE = addr_c2;
CSR_CTRL = CSR_START;  // queued (engine busy)

// CPU programs GEMM #3 (while #1 runs)
CSR_DIM_M = 2; CSR_DIM_N = 2; CSR_DIM_K = 4;
CSR_CTRL = CSR_START;  // queued (FIFO has entry)

// GEMM #1 completes → GEMM #2 dispatches automatically
// GEMM #2 completes → GEMM #3 dispatches automatically
```

### 3.2 Future: NPU Command Coalescing

For grxcp's GPGPU workload, multiple small GEMMs from the same CTB can be
coalesced into a single larger GEMM:

```
GEMM 1: A[4×8] × B[8×4] = C[4×4]   (tile 0,0)
GEMM 2: A[4×8] × B[8×4] = C[4×4]   (tile 0,1)
GEMM 3: A[4×8] × B[8×4] = C[4×4]   (tile 1,0)
GEMM 4: A[4×8] × B[8×4] = C[4×4]   (tile 1,1)
```

Can be coalesced into:
```
GEMM:   A[8×8] × B[8×8] = C[8×8]   (single larger GEMM)
```

**Benefit:** 4× fewer DMA round-trips, 4× fewer command dispatches.

**Implementation:** Software-level in the grxcp backend, not in the NPU RTL.
The NPU already supports arbitrary M/N/K up to MAX_M/MAX_N/MAX_K. The
backend's tiling logic should batch small GEMMs into larger ones.

### 3.3 Dual-Core NPU Scheduling (IMPLEMENTED ✅)

Two cores and two NPUs now exist; the scheduling model is:

With two cores, scheduling becomes:

```
Core 0 (primary):          Core 1 (secondary):
├── Boot, init DDR3L      ├── Idle (waiting for work)
├── Load firmware          ├── 
├── GEMM #1 → NPU queue   ├── 
├── GEMM #2 → NPU queue   ├── 
├── GEMM #3 → NPU queue   ├── 
├── Wait for completions   ├── Process I/O
├── Post-process results   ├── Handle interrupts
├── Write results to DDR   ├── Manage DMA prefetch
└── Done                   └── Done
```

Core 1 offloads:
- I/O processing (UART, SPI, Ethernet)
- DMA prefetch (load next tile while NPU computes current)
- Interrupt handling
- Memory management (allocator for NPU buffers)

---

## 4. DDR Bandwidth

### 4.1 Current Bottleneck

The DDR3L bus is 16-bit (MT41K128M16JT-125). With the 64-bit AXI DMA:
- Read: 64-bit beats (8 bytes/cycle at 200 MHz = 1.6 GB/s peak)
- Write: 32-bit beats (4 bytes/cycle at 200 MHz = 0.8 GB/s peak)
- Actual: ~60% utilization due to arbitration = ~1.0 GB/s effective

### 4.2 Impact on 8×8 NPU

For an 8×8 INT8 GEMM (M=8, N=8, K=16):
- A: 8×16 = 128 bytes
- B: 16×8 = 128 bytes
- C: 8×8 = 64 bytes (INT32)
- Total DDR transfer: ~320 bytes
- DDR time: ~320 ns (at 1 GB/s)
- NPU compute time: ~8 cycles × 8 ns = ~64 ns (at 125 MHz)

**DDR is 5× slower than compute.** The NPU spends most of its time waiting
for DDR.

### 4.3 Optimization: DMA Prefetch

The current DMA prefetches the next row of A while computing the current
row. This overlaps DDR reads with NPU compute, reducing effective DDR
latency by ~50%.

### 4.4 Optimization: Double-Buffer DDR

For v2, a second DDR3L chip (or wider bus) would double bandwidth:
- 32-bit DDR3L: 3.2 GB/s peak → NPU compute-bound instead of DDR-bound
- Board change required (Arty A7-100T has only one DDR3L chip)

---

## 5. Implementation Roadmap

### Phase 1: Single-core SoC (done)
- [x] 8×8 systolic array
- [x] 4-entry NPU command queue
- [x] DDR3L MIG controller
- [x] Arty A7-100T board bring-up firmware
- [x] ECP5 and Artix-7 synthesis flows

### Phase 2: Dual-core + 2-NPU groundwork (done)
- [x] Second RV64IMAC core (CPU1, boots at 0x10020, `CORE_RESET_PC`)
- [x] Second NPU (NPU1 through the DMA arbiter)
- [x] 4-master AXI crossbar (CPU0 I/D, CPU1 I/D, NPU DMA arbiter)
- [x] Dual-core MMIO arbiter (`c930_mmio_arb`) with `HART_ID`
- [x] Boot-ROM parking loop + `CORE1_RELEASE` handshake
- [x] I-cache fetch-PC race fix (`post_fill` refresh; kills the +2 slip)
- [x] MMIO bridge special-transaction path (HART_ID/RELEASE at
      registered AXI timing)
- [x] Dual-core firmware test (Test 9: handshake + per-core GEMM verify)

### Phase 3: 4-core + 2-NPU (ambitious, ~6-8 weeks)

Target: 4 cores, 2 NPUs, coherent memory hierarchy, real interrupt
routing, and a memory controller that copes with mixed CPU/NPU traffic.

- [ ] Cores 2-3: same boot-ROM poll architecture, new `CORE_RESET_PC`
      values + per-core RELEASE slots (mechanical; independent of
      coherence work)
- [ ] **64 KB shared L2** (point of coherence between per-core L1s and
      DDR)
- [ ] **MESI directory-based coherency**: per-core L1 ownership states,
      home directory in the crossbar/L2, invalidation + writeback flows
- [ ] **APLIC** (RISC-V AIA, machine level, minimal subset) at
      `0x4000_4000`: 3-source priority encoder (NPU0/NPU1/UART) with
      claim/complete
- [ ] **DDR command reordering** for mixed CPU/NPU traffic (bank-aware
      scheduling in a new memory-controller front-end)

Sequencing: APLIC → L2 → MESI directory → DDR reorder (coherence is
first built against the L2, then made multi-core).  Cores 3-4 can be
added at any point.

**Feasibility note:** 4 cores + 64 KB L2 + MESI directory will not fit
Arty A7-200T (2 cores alone project ~35%).  Phase 3 is ASIC-class or
requires a larger part (e.g. Nexys Video at ~$250).

### Phase 4: Advanced (long-term)
- [ ] NPU hardware scheduler (auto-dispatch from DDR-resident queue)
- [ ] DDR4 upgrade for higher bandwidth
- [ ] Linux support on Core 1 (Core 0 runs bare-metal NPU firmware)
- [ ] Coherence extensions (MOESI / scoped coherence, see GRXIConnect)

---

## 6. Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| 4 cores + 64KB L2 + MESI don't fit Arty A7-200T | Blocks Phase 3 on current board | High | Use Nexys Video (same part) or target ASIC flow |
| MESI directory subtle bugs (lost invalidations, stale ownership) | Data corruption | Medium | Formal verification on the coherence FSM; directed multi-core mailbox tests |
| Shared L2 becomes the new bottleneck | NPU underutilized | Medium | DDR reordering; wider data path |
| DDR bandwidth still bottleneck | NPU underutilized | High (already 5:1 ratio) | DMA prefetch, command coalescing, DDR reorder |
| APLIC interrupt storms / lost claims | System hangs | Low | Claim/complete protocol, edge vs level source config, TB stress tests |
| grxcp backend doesn't coalesce | Missed optimization | Medium | Document coalescing API for grxcp team |

---

## 7. Recommendations

1. **Dual-core and 2-NPU are banked.**  The remaining Phase 3 work is
   the coherence stack, APLIC, and DDR reordering — architectural, not
   incremental.

2. **Build in this order: APLIC → shared L2 → MESI directory → DDR
   reorder.**  APLIC is self-contained (good warm-up), the L2 is the
   coherence point, MESI makes it multi-core, and reordering only pays
   off once the L2 aggregates traffic.

3. **Cores 3-4 are independent of coherence.**  Add them whenever;
   they reuse the verified boot/poll architecture.

4. **Plan the board now.**  Phase 3 exceeds the A7-200T; decide between
   Nexys Video and the ASIC flow before the coherence work lands.

5. **Let grxcp handle command coalescing.**  The NPU already supports
   arbitrary M/N/K. The backend should batch small GEMMs into larger
   ones (documented for the grxcp team).

6. **Use the NPU queue lock pattern.**  Both cores can queue GEMMs to
   the shared NPU CSRs; production firmware should take a software
   spinlock around queue programming.
