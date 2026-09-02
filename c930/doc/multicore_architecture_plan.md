# C930 Multi-Core Architecture Plan

## Executive Summary

The C930 SoC currently has a single RV64IMAC core and an 8×8 systolic NPU.
This document outlines a path to a dual-core architecture, covering resource
budget, bus coherence, NPU scheduling, and FPGA feasibility.

**Recommendation:** Add a second core only after completing three higher-
leverage optimizations: (1) NPU command queue (done), (2) DDR bandwidth
doubling, and (3) NPU command coalescing. A second core costs ~20K LUTs
and requires bus coherence logic — it fits on Artix-7-200T but not on the
current Arty A7-100T.

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

## 2. Dual-Core Architecture

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

### 3.3 Future: Dual-Core NPU Scheduling

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

### Phase 1: Current (done)
- [x] 8×8 systolic array
- [x] 4-entry NPU command queue
- [x] DDR3L MIG controller
- [x] Arty A7-100T board bring-up firmware
- [x] ECP5 and Artix-7 synthesis flows

### Phase 2: Bandwidth (next)
- [ ] DMA prefetch optimization (already implemented)
- [ ] NPU command coalescing (software-level in grxcp backend)
- [ ] Wider DDR bus (board change)

### Phase 3: Multi-Core (future)
- [ ] Upgrade to Arty A7-200T ($180, same family)
- [ ] Add second RV64IMAC core
- [ ] Shared-bus round-robin arbiter
- [ ] Dual-port icache/dcache
- [ ] Core 1 I/O offload firmware
- [ ] Core 1 DMA prefetch manager

### Phase 4: Advanced (long-term)
- [ ] Cache coherence (MESI protocol) if needed
- [ ] NPU hardware scheduler (auto-dispatch from DDR-resident queue)
- [ ] DDR4 upgrade for higher bandwidth
- [ ] Linux support on Core 1 (Core 0 runs bare-metal NPU firmware)

---

## 6. Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Artix-7-200T doesn't fit 2 cores | Blocks Phase 3 | Low (35% utilization projected) | Use Nexys Video (same part) |
| Bus contention slows dual-core | Reduces benefit | Medium | Round-robin arbiter, Core 1 handles I/O only |
| DDR bandwidth still bottleneck | NPU underutilized | High (already 5:1 ratio) | DMA prefetch, command coalescing |
| Cache coherence bugs | Data corruption | Low (v1 uses shared cache) | No coherence needed for shared-bus model |
| grxcp backend doesn't coalesce | Missed optimization | Medium | Document coalescing API for grxcp team |

---

## 7. Recommendations

1. **Don't add a second core yet.** The three higher-leverage optimizations
   (command queue ✅, DMA prefetch ✅, command coalescing) have better
   ROI and don't require a bigger FPGA.

2. **Upgrade to Arty A7-200T when ready.** Same board family, $50 more,
   2.5× the LUTs. The 2-core design fits at ~35% utilization.

3. **Use shared-bus round-robin for v1.** No coherence needed. Core 0
   runs NPU firmware, Core 1 handles I/O and prefetch.

4. **Let grxcp handle command coalescing.** The NPU already supports
   arbitrary M/N/K. The backend should batch small GEMMs into larger ones.

5. **Defer cache coherence.** The grxcp workload is NPU-bound, not
   CPU-bound. Two cores sharing DDR3L through a round-robin arbiter is
   sufficient.
