// npu_dpi_test.cc - Example grxcp backend test against NPU RTL.
// Demonstrates how to:
//   1. Load A/B data into DDR
//   2. Configure NPU CSRs
//   3. Trigger GEMM
//   4. Wait for completion
//   5. Read back C results
//
// Build: see Makefile verilate target, or:
//   verilator --cc --exe -Wno-fatal --top-module c930_npu_dpi \
//     sim/c930_npu_dpi.sv sim/npu_dpi.cc sim/npu_dpi_test.cc \
//     rtl/*.sv

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "npu_dpi.h"

// ---- Example: INT8 GEMM C = A * B ----
// A is M x K, B is K x N, C is M x N
// All in row-major layout, 1 byte per element (INT8)

static void load_matrix_a(int M, int K, int base_addr) {
    // Fill A with values: A[i][j] = (i * K + j) % 127 - 63
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < K; j++) {
            int8_t val = (int8_t)((i * K + j) % 127 - 63);
            npu_write_int8(base_addr + i * K + j, val);
        }
    }
    printf("[TEST] Loaded A (%dx%d) at 0x%04x\n", M, K, base_addr);
}

static void load_matrix_b(int K, int N, int base_addr) {
    // Fill B with values: B[i][j] = (i * N + j + 1) % 127 - 63
    for (int i = 0; i < K; i++) {
        for (int j = 0; j < N; j++) {
            int8_t val = (int8_t)((i * N + j + 1) % 127 - 63);
            npu_write_int8(base_addr + i * N + j, val);
        }
    }
    printf("[TEST] Loaded B (%dx%d) at 0x%04x\n", K, N, base_addr);
}

// Reference GEMM (software)
static void reference_gemm(int M, int N, int K,
                           int8_t *A, int8_t *B, int32_t *C_ref) {
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            int64_t sum = 0;
            for (int k = 0; k < K; k++) {
                sum += (int64_t)A[i * K + k] * B[k * N + j];
            }
            C_ref[i * N + j] = (int32_t)sum;
        }
    }
}

int main(int argc, char **argv) {
    printf("=== NPU DPI Backend Test ===\n");

    // ---- Configuration ----
    const int M = 2, N = 2, K = 2;
    const uint32_t A_ADDR = 0x8000;
    const uint32_t B_ADDR = 0x8400;
    const uint32_t C_ADDR = 0x8800;

    // ---- Load data into DDR ----
    load_matrix_a(M, K, A_ADDR);
    load_matrix_b(K, N, B_ADDR);

    // ---- Configure NPU CSRs ----
    npu_write_csr(NPU_CSR_DIM_M,  M);
    npu_write_csr(NPU_CSR_DIM_N,  N);
    npu_write_csr(NPU_CSR_DIM_K,  K);
    npu_write_csr(NPU_CSR_A_BASE, A_ADDR);
    npu_write_csr(NPU_CSR_B_BASE, B_ADDR);
    npu_write_csr(NPU_CSR_C_BASE, C_ADDR);
    npu_write_csr(NPU_CSR_PREC,   NPU_PREC_INT8);

    // ---- Trigger GEMM ----
    npu_write_csr(NPU_CSR_START, 1);
    printf("[TEST] NPU triggered: M=%d N=%d K=%d INT8\n", M, N, K);

    // ---- Wait for completion (in real sim, poll STATUS) ----
    // In a standalone test, we'd clock the design and poll o_done.
    // Here we just compute the reference result.
    printf("[TEST] NOTE: In RTL sim, poll NPU_CSR_STATUS until DONE\n");

    // ---- Compute reference ----
    int8_t A_buf[M * K];
    int8_t B_buf[K * N];
    int32_t C_ref[M * N];

    for (int i = 0; i < M * K; i++)
        A_buf[i] = (int8_t)((i) % 127 - 63);
    for (int i = 0; i < K * N; i++)
        B_buf[i] = (int8_t)((i + 1) % 127 - 63);

    reference_gemm(M, N, K, A_buf, B_buf, C_ref);

    printf("[TEST] Reference C:\n");
    for (int i = 0; i < M; i++) {
        printf("  ");
        for (int j = 0; j < N; j++) {
            printf("%8d", C_ref[i * N + j]);
        }
        printf("\n");
    }

    // ---- Read NPU results (after RTL completes) ----
    printf("[TEST] C results from DDR:\n");
    for (int i = 0; i < M; i++) {
        printf("  ");
        for (int j = 0; j < N; j++) {
            printf("%8d", npu_read32(C_ADDR + (i * N + j) * 4));
        }
        printf("\n");
    }

    printf("=== Test complete ===\n");
    return 0;
}
