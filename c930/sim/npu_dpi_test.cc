// npu_dpi_test.cc - Standalone NPU DPI test for grxcp backend.
//
// This test uses the NPU DPI wrapper to demonstrate CSR configuration
// and DDR memory access patterns. It computes a reference GEMM and
// shows the expected DDR layout.
//
// NOTE: This test runs in software only (no RTL). For RTL-accurate
// testing, use tb_grxcp_ref.cc against the full SoC Verilator model.
//
// Build: see Makefile verilate-npu target

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "npu_dpi.h"

// ---- Software reference GEMM (INT8) ----
static void ref_gemm_i8(int M, int N, int K,
                         const int8_t *A, const int8_t *B, int32_t *C) {
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) {
            int64_t sum = 0;
            for (int k = 0; k < K; k++)
                sum += (int64_t)A[i*K+k] * B[k*N+j];
            C[i*N+j] = (int32_t)sum;
        }
}

// ---- Software reference GEMM (INT16) ----
static void ref_gemm_i16(int M, int N, int K,
                          const int16_t *A, const int16_t *B, int32_t *C) {
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) {
            int64_t sum = 0;
            for (int k = 0; k < K; k++)
                sum += (int64_t)A[i*K+k] * B[k*N+j];
            C[i*N+j] = (int32_t)sum;
        }
}

// ---- Generate deterministic test data ----
static void gen_matrix_i8(int8_t *M, int rows, int cols, int seed) {
    for (int i = 0; i < rows * cols; i++)
        M[i] = (int8_t)((i * 7 + seed * 13 + 3) % 127 - 63);
}

static void gen_matrix_i16(int16_t *M, int rows, int cols, int seed) {
    for (int i = 0; i < rows * cols; i++)
        M[i] = (int16_t)((i * 137 + seed * 251 + 42) % 32767 - 16383);
}

// ---- Run a single GEMM test case ----
static int run_gemm_test(const char *label, int M, int N, int K, int prec) {
    const uint32_t A_ADDR = 0x8000;
    const uint32_t B_ADDR = 0x8400;
    const uint32_t C_ADDR = 0x8800;

    printf("  [%s] M=%d N=%d K=%d prec=%d ... ", label, M, N, K, prec);

    // ---- Step 1: Load A into DDR ----
    if (prec == 0) {  // INT8
        int8_t A[M * K];
        gen_matrix_i8(A, M, K, 0);
        for (int i = 0; i < M * K; i++)
            npu_write_int8(A_ADDR + i, A[i]);
    } else if (prec == 1) {  // INT16
        int16_t A[M * K];
        gen_matrix_i16(A, M, K, 0);
        for (int i = 0; i < M * K; i++)
            npu_write_int16(A_ADDR + i * 2, A[i]);
    }

    // ---- Step 2: Load B into DDR ----
    if (prec == 0) {  // INT8
        int8_t B[K * N];
        gen_matrix_i8(B, K, N, 1);
        for (int i = 0; i < K * N; i++)
            npu_write_int8(B_ADDR + i, B[i]);
    } else if (prec == 1) {  // INT16
        int16_t B[K * N];
        gen_matrix_i16(B, K, N, 1);
        for (int i = 0; i < K * N; i++)
            npu_write_int16(B_ADDR + i * 2, B[i]);
    }

    // ---- Step 3: Configure NPU CSRs ----
    npu_write_csr(NPU_CSR_DIM_M,  M);
    npu_write_csr(NPU_CSR_DIM_N,  N);
    npu_write_csr(NPU_CSR_DIM_K,  K);
    npu_write_csr(NPU_CSR_A_BASE, A_ADDR);
    npu_write_csr(NPU_CSR_B_BASE, B_ADDR);
    npu_write_csr(NPU_CSR_C_BASE, C_ADDR);
    npu_write_csr(NPU_CSR_PREC,   prec);

    // ---- Step 4: Trigger GEMM ----
    npu_write_csr(NPU_CSR_START, 1);

    // ---- Step 5: In RTL, poll STATUS until DONE ----
    // while (!(npu_read_csr(NPU_CSR_STATUS) & 0x2));

    // ---- Step 6: Compute reference ----
    int32_t C_ref[M * N];
    if (prec == 0) {
        int8_t A[M * K], B[K * N];
        gen_matrix_i8(A, M, K, 0);
        gen_matrix_i8(B, K, N, 1);
        ref_gemm_i8(M, N, K, A, B, C_ref);
    } else if (prec == 1) {
        int16_t A[M * K], B[K * N];
        gen_matrix_i16(A, M, K, 0);
        gen_matrix_i16(B, K, N, 1);
        ref_gemm_i16(M, N, K, A, B, C_ref);
    }

    // ---- Step 7: Read NPU results from DDR ----
    int errors = 0;
    for (int i = 0; i < M * N; i++) {
        int32_t npu_val = npu_read32(C_ADDR + i * 4);
        if (npu_val != C_ref[i]) {
            errors++;
            if (errors <= 3) {
                printf("\n    MISMATCH [%d][%d]: got %d, expected %d",
                       i / N, i % N, npu_val, C_ref[i]);
            }
        }
    }

    if (errors == 0) {
        printf("PASS");
    } else {
        printf("FAIL (%d mismatches)", errors);
    }
    printf("\n");

    return errors;
}

int main(int argc, char **argv) {
    printf("=================================================================\n");
    printf("  NPU DPI Backend Test (software reference only)\n");
    printf("  For RTL-accurate testing, use tb_grxcp_ref.cc\n");
    printf("=================================================================\n\n");

    int total_errors = 0;

    // ---- INT8 tests ----
    printf("--- INT8 GEMM Tests ---\n");
    total_errors += run_gemm_test("INT8-smoke", 2, 2, 2, 0);
    total_errors += run_gemm_test("INT8-4x4",   4, 4, 4, 0);
    total_errors += run_gemm_test("INT8-8x8",   8, 8, 8, 0);
    total_errors += run_gemm_test("INT8-8x12x16", 8, 12, 16, 0);

    // ---- INT16 tests ----
    printf("\n--- INT16 GEMM Tests ---\n");
    total_errors += run_gemm_test("INT16-smoke", 2, 2, 2, 1);
    total_errors += run_gemm_test("INT16-4x4",   4, 4, 4, 1);
    total_errors += run_gemm_test("INT16-8x8",   8, 8, 8, 1);

    // ---- Summary ----
    printf("\n=================================================================\n");
    if (total_errors == 0) {
        printf("  [PASS] All %d test cases passed\n", 7);
    } else {
        printf("  [FAIL] %d test cases had errors\n", total_errors);
    }
    printf("=================================================================\n");

    return total_errors > 0 ? 1 : 0;
}
