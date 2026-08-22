# GRX930 SoC — Architecture Specification

**Status:** Implemented (RTL verified, bitstream on Arty A7-35T).
**Target audience:** grxcp Phase 7 backend authors, SoC integrators, verification.
**Companion:** `c930/rtl/` (RTL), `c930/tb/` (testbenches), `c930/synth_xilinx/` (Vivado flow).

---

## 1. Overview

The GRX930 is a RISC-V 64-bit SoC integrating:

- **RV64IMAC core** — 5-stage in-order, with I/D caches, AMO, LR/SC, MMIO bridge
- **INT8 systolic-array NPU** — weight-stationary GEMM engine with AXI4 DMA
- **Unified DDR** — 64 KB byte-addressable memory (cache-line organized)
- **Clock divider** — configurable ÷N for safe operation below routed Fmax

The NPU is a **memory-mapped accelerator** on the CPU's AXI fabric. The CPU
programs it over MMIO; the NPU autonomously fetches A/B from DDR, runs the
GEMM, and writes C back — no CPU data staging required.

```
                    ┌──────────────────────────────────────────────┐
                    │              GRX930 SoC                      │
                    │                                              │
  i_clk (100 MHz)──┤──► clk_div (÷N) ──► core_clk                │
  i_rst_n ─────────┤                                              │
                    │  ┌──────────────┐    ┌──────────────────┐   │
                    │  │ riscv_core   │    │  c930_npu_top    │   │
                    │  │   top        │    │  ┌────────────┐  │   │
                    │  │  (RV64IMAC)  │    │  │ CSR (MMIO) │  │   │
                    │  │              │    │  │ AXI4-Lite  │──┼──► 0x4000_0000
                    │  │  ┌─cache────┐│    │  ├────────────┤  │   │
                    │  │  │ I$/D$    ││    │  │ DMA Master │──┼──► AXI4 full
                    │  │  └────┬─────┘│    │  │ (fetch A/B,│  │   │ (DDR data plane)
                    │  │       │      │    │  │  write C)  │  │   │
                    │  └───┬───┘──────┘    │  ├────────────┤  │   │
                    │      │              │  │ GEMM Core  │  │   │
                    │  ┌───▼───────────┐  │  │ (systolic) │  │   │
                    │  │ MMIO Bridge   │  │  └────────────┘  │   │
                    │  │ (CPU uncached │  └──────────────────┘   │
                    │  │  ↔ AXI4-Lite)│                          │
                    │  └───────────────┘    ┌──────────────────┐ │
                    │                       │ DDR (64 KB)      │ │
                    │  ┌───────────────┐    │ unified byte-    │ │
                    │  │ NPU status    │◄───│ addressable      │ │
                    │  │ o_npu_busy/done│   │ (BRAM banks)     │ │
                    │  │ o_npu_error   │    └──────────────────┘ │
                    │  │ o_npu_irq     │                          │
                    │  └───────────────┘                          │
                    └──────────────────────────────────────────────┘
```

---

## 2. Memory Map

Flat, byte-addressed, 64-bit addresses (zero-extended from 32-bit):

| Range | Size | Region | Access |
|-------|------|--------|--------|
| `0x0000_0000 .. 0x0000_FFFF` | 64 KB | DDR (code + data + NPU A/B/C buffers) | Cached (CPU) / AXI4 (NPU DMA) |
| `0x4000_0000 .. 0x4000_001F` | 32 B | NPU MMIO control/status | Uncached (CPU MMIO bridge → AXI4-Lite) |
| `0x4000_0020 .. 0xFFFF_FFFF` | — | Reserved | — |

### DDR region (0x0000_0000 – 0x0000_FFFF)

The CPU's data cache and the NPU's AXI4 DMA master both access DDR.
The cache port has priority over the AXI4 slave port. Byte-addressed,
cache-line organized (32 bytes/line, 8 words/line).

**Suggested layout for grxcp backend:**

| Offset | Size | Content |
|--------|------|---------|
| `0x0000` | — | Code / stack (CPU firmware) |
| `0x9000` | M×K bytes | A matrix (INT8, row-major, packed 4 per 32-bit word) |
| `0x9100` | K×N bytes | B matrix (INT8, row-major, packed 4 per 32-bit word) |
| `0x9200` | M×N×4 bytes | C result (INT32, one word per element) |

These offsets are conventions from the testbench; the NPU itself only
requires that A/B/C buffers fit within the DDR and do not overlap.

---

## 3. CPU Core

The CPU is the reference `riscv_core_top` (RV64IMAC, 5-stage in-order):

- **ISA:** RV64IMA (no F/D/C extensions; 32-bit fixed-width instructions)
- **Pipeline:** IF → ID → EX → MEM → WB, 5 stages
- **Caches:** I-cache and D-cache, parameterized (default 32B lines, 128 lines)
- **Memory ports:** separate icache/dcache read ports + dcache write port to DDR
- **MMIO port:** uncached, for addresses ≥ `MMIO_BASE`
- **AMO/LR/SC:** hardware-supported, byte-level atomics
- **CSR unit:** mstatus, mtvec, mepc, mcause, mie, mip, mcycle, minstret
- **Trap handling:** mtvec-based, supports illegal instruction and ecall traps

### Clock configuration

The `CLK_DIV` parameter on `c930_soc_top` divides the input clock:

| `CLK_DIV` | Core clock | Notes |
|------------|-----------|-------|
| 1 | = input clock | Default (Icarus testbenches, ECP5 flow) |
| 2 | input / 2 | Arty A7-35T (100 MHz → 50 MHz) |

The `DONT_TOUCH` attribute on the divider FFs preserves the clock-generation
hierarchy through Vivado synthesis. Even if the generated-clock XDC constraint
cannot find the renamed divider FF, the design passes timing at 100 MHz
(WNS > 0), guaranteeing closure at 50 MHz.

---

## 4. NPU Architecture

### 4.1 Systolic array

Weight-stationary dataflow (TPU-style). Default configuration: 4×4 PEs.

```
         activations (A rows) ──►  left → right
              │
   ┌───────┬───────┬───────┬───────┐
   │ PE00  │ PE01  │ PE02  │ PE03  │  ◄── row k=0  (weight B[0][*])
   ├───────┼───────┼───────┼───────┤
   │ PE10  │ PE11  │ PE12  │ PE13  │  ◄── row k=1
   ├───────┼───────┼───────┼───────┤
   │ PE20  │ PE21  │ PE22  │ PE23  │  ◄── row k=2
   ├───────┼───────┼───────┼───────┤
   │ PE30  │ PE31  │ PE32  │ PE33  │  ◄── row k=3
   └───────┴───────┴───────┴───────┘
          │       │       │       │
          ▼       ▼       ▼       ▼
      C[m][0]  C[m][1]  C[m][2]  C[m][3]   ◄── partial sums flow top → bottom
```

- **PE (k, n):** holds weight `B[k][n]`, computes `partial_sum += A[m][k] × B[k][n]`
- **Activation skew:** row k's activation pulse delayed by k cycles
- **Accumulator skew:** column n's accumulator injected delayed by n cycles
- **Result capture:** bottom-edge outputs captured in staggered window over
  `NUM_ROWS + NUM_COLS` cycles

### 4.2 Tiling

The NPU handles arbitrary M/N/K through three nested loops:

- **K-tiling:** `ceil(K / NUM_ROWS)` tiles; accumulator feeds back into top edge
- **N-tiling:** `ceil(N / NUM_COLS)` column tiles; fresh accumulator per tile
- **M-tiling:** output rows looped sequentially

With default parameters (NUM_ROWS=4, NUM_COLS=4, MAX_M=8, MAX_K=16, MAX_N=12):

| Dimension | Range | Tiling passes |
|-----------|-------|---------------|
| M | 1–8 | M passes (1 each) |
| N | 1–12 | 1–3 N-tile passes (4 columns each) |
| K | 1–16 | 1–4 K-tile passes (4 rows each) |

### 4.3 Precision

- **Input:** INT8 (signed, 2's complement), 4 elements packed per 32-bit AXI beat
- **Accumulation:** INT32 (signed), one word per output element
- **INT16/FP16:** Precision-aware datapath (PREC CSR at 0x20: 0=INT8, 1=INT16, 2=FP16)

### 4.4 Modules

| File | Role |
|------|------|
| `c930_tensor_pe.sv` | One multiply-accumulate PE (weight-stationary) |
| `c930_systolic_array.sv` | NUM_ROWS × NUM_COLS PE mesh with weight-load addressing |
| `c930_npu_core.sv` | GEMM FSM, A/B/C buffers, K/N-tiling, skew + capture |
| `c930_npu_csr.sv` | MMIO register file + AXI4-Lite slave |
| `c930_npu_dma.sv` | AXI4 full master: burst-fetch A/B, burst-write C |
| `c930_npu_top.sv` | Accelerator IP top (CSR + DMA + core + IRQ) |

---

## 5. NPU Register Map (AXI4-Lite Slave)

Base address: `0x4000_0000` (byte-addressed; register offsets are word-aligned).

### Register summary

| Offset | Name | Access | Reset | Description |
|--------|------|--------|-------|-------------|
| `0x00` | **CTRL** | W | `0x0000_0000` | Control register |
| `0x04` | **STATUS** | R | `0x0000_0000` | Status register |
| `0x08` | **DIM_M** | R/W | `0x0000_0000` | Output rows (M) |
| `0x0C` | **DIM_N** | R/W | `0x0000_0000` | Output columns (N) |
| `0x10` | **DIM_K** | R/W | `0x0000_0000` | Reduction length (K) |
| `0x14` | **A_BASE** | R/W | `0x0000_0000` | A matrix base address (byte) |
| `0x18` | **B_BASE** | R/W | `0x0000_0000` | B matrix base address (byte) |
| `0x1C` | **C_BASE** | R/W | `0x0000_0000` | C result base address (byte) |
| `0x20` | **PREC** | R/W | `0x0000_0000` | Precision mode (0=INT8, 1=INT16, 2=FP16, 3=BF16) |

### CTRL (0x00) — Write-only

| Bit | Name | Description |
|-----|------|-------------|
| [0] | **START** | Write 1 to launch a GEMM. Cleared automatically. Ignored if BUSY=1. Writing START also clears DONE. |
| [31:1] | — | Reserved (read as 0) |

### STATUS (0x04) — Read-only

| Bit | Name | Description |
|-----|------|-------------|
| [0] | **BUSY** | 1 while the NPU is executing a GEMM (DMA fetch through GEMM through DMA write). |
| [1] | **DONE** | Latched 1 after a GEMM completes. Cleared by writing START. Read to acknowledge. |
| [2] | **ERROR** | Latched 1 if an invalid dimension was programmed (any dim = 0 or exceeds MAX). Cleared by writing START. |
| [31:3] | — | Reserved (read as 0) |

### DIM_M (0x08) — Read/Write

| Bits | Description |
|------|-------------|
| [15:0] | Number of output rows. Must be ≥ 1 and ≤ MAX_M (default 8). |
| [31:16] | Reserved (read as 0; writes ignored) |

### DIM_N (0x0C) — Read/Write

| Bits | Description |
|------|-------------|
| [15:0] | Number of output columns. Must be ≥ 1 and ≤ MAX_N (default 12). |
| [31:16] | Reserved |

### DIM_K (0x10) — Read/Write

| Bits | Description |
|------|-------------|
| [15:0] | Reduction length. Must be ≥ 1 and ≤ MAX_K (default 16). |
| [31:16] | Reserved |

### A_BASE (0x14) — Read/Write

| Bits | Description |
|------|-------------|
| [31:0] | Byte address of the A matrix in DDR. The NPU DMA reads M×K INT8 elements from this address (row-major, packed 4 per 32-bit word, little-endian). Must be word-aligned (bits [1:0] = 0). |

### B_BASE (0x18) — Read/Write

| Bits | Description |
|------|-------------|
| [31:0] | Byte address of the B matrix in DDR. The NPU DMA reads K×N INT8 elements from this address (row-major, packed 4 per 32-bit word, little-endian). Must be word-aligned. |

### C_BASE (0x1C) — Read/Write

| Bits | Description |
|------|-------------|
| [31:0] | Byte address of the C result buffer in DDR. The NPU DMA writes M×N INT32 elements to this address (row-major, one word per element). Must be word-aligned. |

### PREC (0x20) — Read/Write

| Bits | Name | Description |
|------|------|-------------|
| [1:0] | **MODE** | Precision mode: 0=INT8 (default), 1=INT16, 2=FP16, 3=BF16 |
| [31:2] | — | Reserved (read as 0) |

The precision mode controls the element width of the systolic array PEs:
- **INT8 (0):** 8-bit signed multiply-accumulate, 4 elements per AXI beat
- **INT16 (1):** 16-bit signed multiply-accumulate, 2 elements per AXI beat
- **FP16 (2):** half-precision IEEE 754 × FP32 multiply-accumulate, 2 elements per AXI beat
- **BF16 (3):** bfloat16 (planned, not yet implemented)

The precision mode must be set before writing CTRL.START. Changing precision
while the engine is busy is undefined.

---

## 6. NPU Data Format and Byte Layout

### A matrix (M × K, INT8, row-major, packed)

Element A[m][k] (signed INT8) lives at byte offset `m * K + k` from `A_BASE`.
Four elements are packed per 32-bit AXI word, little-endian:

```
Word at byte offset (m*K + k) & ~3:
  bits [7:0]   = A[m][k]     where (m*K + k) % 4 == 0
  bits [15:8]  = A[m][k+1]   where (m*K + k) % 4 == 1
  bits [23:16] = A[m][k+2]   where (m*K + k) % 4 == 2
  bits [31:24] = A[m][k+3]   where (m*K + k) % 4 == 3
```

**Total bytes:** `M × K`. **Total AXI read beats:** `ceil(M × K / 4)`.

### B matrix (K × N, INT8, row-major, packed)

Element B[k][n] lives at byte offset `k * N + n` from `B_BASE`.
Same packing as A.

**Total bytes:** `K × N`. **Total AXI read beats:** `ceil(K × N / 4)`.

### C result (M × N, INT32, row-major, unpacked)

Element C[m][n] (signed INT32) is one full 32-bit word at offset `(m * N + n) * 4`
from `C_BASE`.

**Total bytes:** `M × N × 4`. **Total AXI write beats:** `M × N`.

---

## 7. NPU DMA Master (AXI4 Full)

The DMA is the data-plane engine that makes the NPU autonomous.
The CPU never writes operand data — it only programs the CSR registers.

### 7.1 Operation sequence

```
 1. IDLE          ←等待 START
 2. READ_A        ← burst-read M×K bytes from A_BASE, unpack into A buffer
 3. READ_B        ← burst-read K×N bytes from B_BASE, unpack into B buffer
 4. LAUNCH        ← pulse core_start, wait for core_done
 5. WRITE_C       ← burst-write M×N words to C_BASE
 6. DONE          ← pulse o_done / o_irq
```

### 7.2 AXI4 burst parameters

| Parameter | Read (A/B) | Write (C) |
|-----------|-----------|-----------|
| Burst type | INCR (`2'b01`) | INCR (`2'b01`) |
| Beat size | 4 bytes (`BEAT_SIZE = 2`) | 4 bytes |
| Beat count | `ceil(elements / 4)` | `M × N` |
| Max arlen/awlen | 255 (8-bit) | 255 |

### 7.3 Backpressure

- The R channel is back-pressured while each beat's 4 bytes are unpacked
  into the core's A/B buffers (one byte per cycle). Read throughput is
  naturally throttled by the unpacking rate.
- The W channel is driven beat-by-beat from the C buffer read port.

### 7.4 Constraints

- A, B, C base addresses must be word-aligned (bits [1:0] = 0).
- DIM_M, DIM_N, DIM_K must each be ≥ 1 and ≤ their respective MAX
  parameters. Violation sets ERROR in STATUS and skips execution.
- A and B buffers are internal to the core (MAX_M × MAX_K and
  MAX_K × MAX_N INT8 elements). C buffer is MAX_M × MAX_N INT32 elements.
- The NPU does **not** check for DDR address overlap between A, B, and C.
  The software driver must ensure non-overlapping buffers.

---

## 8. Interrupt Model

The NPU completion signal:

| Signal | Behavior |
|--------|----------|
| `o_irq` | Pulses for one core clock cycle when DONE is set (GEMM complete) |
| `o_done` | Same as `o_irq` — both are driven by the DMA's `done` signal |

The IRQ is a **level-sensitive pulse**, not a sticky interrupt. The CPU
must poll STATUS or register an interrupt handler before launching the GEMM.

**Current implementation:** the IRQ output is wired to the SoC top-level
LED outputs (`o_npu_busy`, `o_npu_done`, `o_npu_error`, `o_npu_irq`) for
board-level visibility. There is no APLIC/IMSIC integration yet — the
CPU polls STATUS in the current firmware.

**For grxcp Phase 7:** the recommended polling pattern is:

```c
// 1. Program dimensions and base addresses
NPU_CSR_DIM_M  = M;
NPU_CSR_DIM_N  = N;
NPU_CSR_DIM_K  = K;
NPU_CSR_A_BASE = a_ddr_addr;
NPU_CSR_B_BASE = b_ddr_addr;
NPU_CSR_C_BASE = c_ddr_addr;

// 2. Launch (also clears DONE and ERROR)
NPU_CSR_CTRL = 1;

// 3. Poll until done
while (!(NPU_CSR_STATUS & STATUS_DONE))
    ;

// 4. C is now valid at c_ddr_addr
```

---

## 9. AXI4-Lite Slave Interface (CSR Port)

The CSR slave accepts one outstanding transaction at a time.
The AW and W channels are paired: a write commits when both AWVALID
and WVALID are simultaneously high.

### 9.1 Write protocol

```
CPU store → MMIO bridge → AXI4-Lite AW+W (paired) → CSR accepts → BVALID response
```

Latency: 2–3 core clock cycles per MMIO store (bridge staging + CSR commit + response).

### 9.2 Read protocol

```
CPU load → MMIO bridge → AXI4-Lite AR → CSR returns RDATA → bridge returns to CPU
```

Latency: 2–3 core clock cycles per MMIO load.

### 9.3 Bus errors

All transactions return `BRESP = OKAY` / `RRESP = OKAY`. There is no
error response — accessing undefined offsets returns 0 on read and
is silently ignored on write.

---

## 10. SoC Integration (for grxcp Phase 7)

### 10.1 What grxcp needs to build

The `src/backends/npu_c930/` backend in grxcp must implement:

1. **Device enumeration** — detect the NPU by probing `STATUS` at `0x4000_0004`
   (a non-zero read indicates the NPU is present).
2. **Capability profile** — report `GRX_CAP_STREAMS | GRX_CAP_MEMCPY | GRX_CAP_GEMM`
   (no `GRX_CAP_KERNEL_LAUNCH` — the NPU has no SIMT pipeline).
3. **Memory management** — allocate A/B/C buffers in DDR, translate host pointers
   to physical DDR addresses for `A_BASE/B_BASE/C_BASE`.
4. **GEMM dispatch** — program DIM_M/N/K and A/B/C_BASE, write CTRL.START,
   poll STATUS.DONE (or wait on `o_irq` if AIA is wired).
5. **Result readback** — C is written to DDR by the DMA; the backend reads it
   back through the normal memory path.

### 10.2 Register access patterns

All register accesses are 32-bit word-aligned MMIO loads/stores.
The CPU's MMIO bridge converts uncached stores into AXI4-Lite write
transactions and uncached loads into AXI4-Lite read transactions.

**Byte order:** little-endian (RV64 native). The AXI4-Lite bus is also
little-endian. No byte-swapping is needed.

### 10.3 DMA address translation

The NPU DMA issues AXI4 transactions using the physical byte addresses
written to `A_BASE`, `B_BASE`, `C_BASE`. In the current implementation
(no MMU/IOMMU), these are direct physical DDR addresses.

For grxcp integration, the backend must ensure:
- Base addresses are within the DDR region (`0x0000_0000 – 0x0000_FFFF`)
- A, B, C buffers do not overlap each other
- Base addresses are 4-byte aligned (bits [1:0] = 0)

### 10.4 Streaming interface

The NPU does not have a streaming/DMA-submission interface. All programming
is through the MMIO CSR registers. For grxcp's stream-ordered execution model:

1. The backend programs the NPU on the calling stream.
2. It records an event after `STATUS.DONE` is observed.
3. Downstream work on the same stream waits on that event.

This gives correct ordering without hardware stream concurrency (which
the NPU does not support).

---

## 11. FPGA Resource Utilization (Artix-7-35T)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| Slice LUTs | 15,731 | 20,800 | 75.6% |
| Slice Registers | 12,722 | 41,600 | 30.6% |
| DSP48E1 | 3 | 90 | 3.3% |
| RAMB36E1 | 17 | 50 | 34.0% |
| Distributed RAM | 604 | 9,600 | 6.3% |

**Core clock:** 50 MHz (100 MHz / CLK_DIV=2).
**Routed Fmax:** >587 MHz (WNS +8.30 ns at 100 MHz timing constraint).
**DRC:** 0 errors, 29 warnings (all benign).

---

## 12. Verification

### 12.1 Testbenches

| Testbench | Scope | What it checks |
|-----------|-------|----------------|
| `tb_c930_soc.sv` | Full SoC | 22 randomized GEMM shapes (M/N/K sweep), MMIO stress, store ordering, LR/SC, AMO, memory consistency, stranded-LR, two-trap handler |
| `tb_kickoff.sv` | Bitstream design | Boots firmware from BRAM stub, NPU runs GEMM, C={1,2,5,6} verified |
| `tb_hazard_csrflush.sv` | Hazard unit | CSR flush deferral, load-use stall, operand hold |

### 12.2 Sweep coverage

The SoC testbench sweeps GEMM shapes including:
- Edge cases: K=1, M=1, N=1
- Exact tiling boundaries: K=NUM_ROWS, N=NUM_COLS
- N-tiling: N > NUM_COLS (multiple column passes)
- K-tiling: K > NUM_ROWS (multiple reduction passes)
- Maximum dimensions: M=MAX_M, N=MAX_N, K=MAX_K
- Randomized: LCG-seeded M/N/K within parameter bounds

### 12.3 Stress tests

- **MMIO drain stall:** back-to-back MMIO stores to the same CSR register
- **Store ordering:** interleaved AMOs, LR/SC, and regular stores to the same cache line
- **Memory consistency:** multi-line AMO/regular access interleaving
- **Stranded LR/SC:** icache-miss freeze between LR and its dependent read
- **Two-trap handler:** illegal instruction + ecall, cold icache line each time
- **CSR dependency:** trap mepc write under stall, no re-execution corruption

---

## 13. Roadmap

| Step | Description | Status |
|------|-------------|--------|
| 1 | INT8 systolic GEMM + CSR + testbench | ✅ Done |
| 2 | AXI4 DMA master for data plane | ✅ Done |
| 3 | INT16 / FP16 datapaths + precision CSR | ✅ Done |
| 4 | RVV 1.0 vector unit + fused vector→matrix dispatch | Planned |
| 5 | CHI coherent NPU port (SVM with CPU) | Planned |
| 6 | Wide out-of-order core, DDR5/HBM, PCIe/CXL, IOMMU/AIA | Planned |
| 7 | grxcp Phase 7 backend integration | **Ready** (this doc) |
