# Phase 7 Integration Guide: NPU Device for grxcp

This guide walks through attaching the NPU DPI shim to a grxcp device,
allocating DDR buffers, running a GEMM, and verifying the result. It is
intended as a reference implementation that the grxcp team can adapt.

## Prerequisites

```bash
cd c930/sim
gcc -c npu_dpi_shim.c && ar rcs libnpu_dpi_shim.a npu_dpi_shim.o
```

## Step 1: Include the headers

```c
#include "npu_dpi_shim.h"
#include "npu_ddr_alloc.h"

// The DDR allocator is header-only; define the impl in exactly one .c file:
// #define NPU_DDR_ALLOC_IMPL
// #include "npu_ddr_alloc.h"
```

## Step 2: Initialize the NPU and allocator

```c
// Reset the shim (clears all CSR state and DDR contents)
npu_dpi_init();

// Initialize the DDR allocator over the NPU's 64KB window
npu_ddr_alloc_t ddr;
npu_ddr_alloc_init(&ddr, 0x0000, 0x10000);
```

## Step 3: Allocate buffers for A, B, C

For an M×N GEMM with K reduction, INT8 inputs produce INT32 outputs:

```c
uint32_t M = 4, N = 4, K = 8;

// Allocate A (M × K bytes), B (K × N bytes), C (M × N × 4 bytes)
// All must be 4-byte aligned for the DMA master
uint32_t a_off = npu_ddr_alloc(&ddr, M * K, 4);
uint32_t b_off = npu_ddr_alloc(&ddr, K * N, 4);
uint32_t c_off = npu_ddr_alloc(&ddr, M * N * 4, 4);

if (!a_off || !b_off || !c_off) {
    // Not enough DDR space
    return -1;
}
```

## Step 4: Fill A and B with data

```c
// Fill A with 1s
for (uint32_t i = 0; i < M * K; i++)
    npu_dpi_mem_write(a_off + i, 1, 0xFF);

// Fill B with 1s
for (uint32_t i = 0; i < K * N; i++)
    npu_dpi_mem_write(b_off + i, 1, 0xFF);
```

## Step 5: Configure CSRs and trigger GEMM

```c
// Configure dimensions and base addresses
npu_dpi_csr_write(NPU_CSR_DIM_M,  M);
npu_dpi_csr_write(NPU_CSR_DIM_N,  N);
npu_dpi_csr_write(NPU_CSR_DIM_K,  K);
npu_dpi_csr_write(NPU_CSR_A_BASE, a_off);
npu_dpi_csr_write(NPU_CSR_B_BASE, b_off);
npu_dpi_csr_write(NPU_CSR_C_BASE, c_off);
npu_dpi_csr_write(NPU_CSR_PREC,   0);  // INT8

// Trigger the GEMM
npu_dpi_csr_write(NPU_CSR_CTRL, 1);
```

## Step 6: Wait for completion

Two options:

**Option A — Poll STATUS (recommended for shim):**
```c
// Run cycles until STATUS.DONE is set
int expected = npu_dpi_expected_cycles();
npu_dpi_run(expected + 20);

// Check completion
uint32_t status = npu_dpi_csr_read(NPU_CSR_STATUS);
if (status & NPU_STATUS_DONE) {
    // GEMM complete
}
```

**Option B — Poll BUSY (matches silicon behavior):**
```c
// Run cycles and check BUSY transitions
npu_dpi_run(1);
uint32_t status = npu_dpi_csr_read(NPU_CSR_STATUS);
while (status & NPU_STATUS_BUSY) {
    npu_dpi_run(1);
    status = npu_dpi_csr_read(NPU_CSR_STATUS);
}
// DONE is now set
```

## Step 7: Read results from DDR

```c
// Read C matrix from DDR
for (uint32_t i = 0; i < M; i++) {
    for (uint32_t j = 0; j < N; j++) {
        uint32_t c_addr = c_off + (i * N + j) * 4;
        int32_t c_val = (int32_t)npu_dpi_mem_read(c_addr)
                      | ((int32_t)npu_dpi_mem_read(c_addr + 1) << 8)
                      | ((int32_t)npu_dpi_mem_read(c_addr + 2) << 16)
                      | ((int32_t)npu_dpi_mem_read(c_addr + 3) << 24);
        // Verify against reference
    }
}
```

## Step 8: Read performance counters

```c
uint32_t cycles = npu_dpi_csr_read(NPU_CSR_CYCLE);
uint32_t ops    = npu_dpi_csr_read(NPU_CSR_OP_COUNT);
uint32_t stalls = npu_dpi_csr_read(NPU_CSR_STALL);
uint32_t dma    = npu_dpi_csr_read(NPU_CSR_DMA_CT);

printf("Cycles: %u, Ops: %u, Stalls: %u, DMA: %u\n", cycles, ops, stalls, dma);
// Expected: ops = M * N * K * 2
```

## Step 9: Free buffers

```c
npu_ddr_free(&ddr, a_off);
npu_ddr_free(&ddr, b_off);
npu_ddr_free(&ddr, c_off);
```

## Step 10: Software reference GEMM for verification

```c
// Compute reference: C[i][j] = sum_k A[i][k] * B[k][j]
for (uint32_t i = 0; i < M; i++) {
    for (uint32_t j = 0; j < N; j++) {
        int32_t sum = 0;
        for (uint32_t k = 0; k < K; k++) {
            int8_t a_val = (int8_t)npu_dpi_mem_read(a_off + i * K + k);
            int8_t b_val = (int8_t)npu_dpi_mem_read(b_off + k * N + j);
            sum += (int32_t)a_val * (int32_t)b_val;
        }
        uint32_t c_addr = c_off + (i * N + j) * 4;
        int32_t hw_val = (int32_t)npu_dpi_mem_read(c_addr)
                       | ((int32_t)npu_dpi_mem_read(c_addr + 1) << 8)
                       | ((int32_t)npu_dpi_mem_read(c_addr + 2) << 16)
                       | ((int32_t)npu_dpi_mem_read(c_addr + 3) << 24);
        if (hw_val != sum) {
            printf("MISMATCH C[%u][%u]: hw=%d ref=%d\n", i, j, hw_val, sum);
            return -1;
        }
    }
}
printf("All %u elements match\n", M * N);
```

## Integration with grxcp device model seam

The grxcp team needs to route `npu_c930_read/write` calls through the shim.
The shim's API matches their hook signature:

```c
// grxcp hook signature (from their codebase)
typedef uint32_t (*npu_c930_read_fn)(void* ctx, uint32_t offset);
typedef void     (*npu_c930_write_fn)(void* ctx, uint32_t offset, uint32_t v);

// Shim functions (from npu_dpi_shim.h)
void     npu_dpi_csr_write(uint32_t addr, uint32_t data);
uint32_t npu_dpi_csr_read(uint32_t addr);
void     npu_dpi_mem_write(uint32_t addr, uint32_t data, uint32_t strb);
int      npu_dpi_mem_read(uint32_t addr);

// Adapter: wrap shim functions to match grxcp hook signature
static uint32_t shim_csr_read(void* ctx, uint32_t offset) {
    (void)ctx;
    return npu_dpi_csr_read(0x40000000u + offset);
}

static void shim_csr_write(void* ctx, uint32_t offset, uint32_t val) {
    (void)ctx;
    npu_dpi_csr_write(0x40000000u + offset, val);
}

// Attach to device
npu_c930_attach_model(device, NULL, shim_csr_read, shim_csr_write);
```

## Backend field

When the shim is attached, set the device backend to avoid reporting
the software model as silicon:

```c
// From npu_dpi_shim.h
#define NPU_DPI_BACKEND_EMULATION  0x10  // shim / software model

device->backend = NPU_DPI_BACKEND_EMULATION;
```

## Complete minimal example

```c
// See sim/tb_grxcp_ref.cc for a full working example that:
// 1. Boots the C930 SoC in Verilator
// 2. Monitors o_done
// 3. Prints the complete register map
// 4. Runs a GEMM and verifies the result
```

## Register map reference

| Index | Offset | Name | Width | Access |
|-------|--------|------|-------|--------|
| 0 | 0x00 | CTRL | 32 | W (bit 0 = START) |
| 1 | 0x04 | STATUS | 32 | R ({29'd0, error, done, busy}) |
| 2 | 0x08 | DIM_M | 16 | R/W |
| 3 | 0x0C | DIM_N | 16 | R/W |
| 4 | 0x10 | DIM_K | 16 | R/W |
| 5 | 0x14 | A_BASE | 32 | R/W (byte address) |
| 6 | 0x18 | B_BASE | 32 | R/W (byte address) |
| 7 | 0x1C | C_BASE | 32 | R/W (byte address) |
| 8 | 0x20 | PREC | 3 | R/W (0=INT8, 1=INT16, 2=FP16, 3=BF16, 4=INT4) |
| 9 | 0x24 | CYCLE_COUNT | 32 | R (free-running, 32-bit) |
| 10 | 0x28 | *(reserved)* | — | R (always 0, dead code in RTL) |
| 11 | 0x2C | OP_COUNT | 32 | R (M×N×K×2) |
| 12 | 0x30 | STALL_COUNT | 32 | R |
| 13 | 0x34 | DMA_CT | 32 | R |

## Timing model

For SoC defaults (4×4 array, MAX_N=12):

```
INT8/INT16/INT4:  cycles = ceil(M/4) × ceil(N'/4) × ceil(K/4) × (4 + 0 + 4 + 2)
FP16/BF16:        cycles = ceil(M/4) × ceil(N'/4) × ceil(K/4) × (4 + 4 + 4 + 2)

where N' = min(N, 12), and N-tiling handles N > NUM_COLS internally.
```

For N > MAX_N: the caller must tile externally (see `npu_tile.h` §14.7).
