#define NPU_DDR_ALLOC_IMPL
#include "npu_dpi_shim.h"
#include "npu_ddr_alloc.h"
#include <stdio.h>

static int pass = 0, fail = 0;
static void check(const char *name, int cond) {
    if (cond) { printf("  [PASS] %s\n", name); pass++; }
    else      { printf("  [FAIL] %s\n", name); fail++; }
}

int main() {
    printf("=== STATUS.DONE is a real latch ===\n");
    npu_dpi_init();
    npu_dpi_csr_write(NPU_CSR_DIM_M, 0);
    npu_dpi_csr_write(NPU_CSR_CTRL, 1);
    uint32_t st = npu_dpi_csr_read(NPU_CSR_STATUS);
    check("Refused start: DONE=0", !(st & 2));

    uint8_t A[] = {1,2,3,4}, B[] = {5,6,7,8};
    for (int i = 0; i < 4; i++) { npu_dpi_mem_write(0x8000+i, A[i], 1); npu_dpi_mem_write(0x8400+i, B[i], 1); }
    npu_dpi_run_gemm(2, 2, 2, 0, 0x8000, 0x8400, 0x8800);
    st = npu_dpi_csr_read(NPU_CSR_STATUS);
    check("After GEMM: DONE=1", st & 2);

    npu_dpi_csr_write(NPU_CSR_DIM_M, 0);
    npu_dpi_csr_write(NPU_CSR_CTRL, 1);
    st = npu_dpi_csr_read(NPU_CSR_STATUS);
    check("START clears DONE", !(st & 2));

    printf("\n=== Wrap-safe bounds checks ===\n");
    npu_dpi_init();
    npu_dpi_csr_write(NPU_CSR_DIM_M, 1); npu_dpi_csr_write(NPU_CSR_DIM_N, 1);
    npu_dpi_csr_write(NPU_CSR_DIM_K, 1);
    npu_dpi_csr_write(NPU_CSR_A_BASE, 0xFFFFFFFF);
    npu_dpi_csr_write(NPU_CSR_B_BASE, 0x8400);
    npu_dpi_csr_write(NPU_CSR_C_BASE, 0x8800);
    npu_dpi_csr_write(NPU_CSR_CTRL, 1);
    st = npu_dpi_csr_read(NPU_CSR_STATUS);
    check("Wrap-around A_BASE: ERROR", st & 4);

    npu_dpi_init();
    npu_dpi_mem_write(0xFFFFFFFF, 0xDEADBEEF, 0x0F);
    st = npu_dpi_csr_read(NPU_CSR_STATUS);
    check("mem_write at 0xFFFFFFFF: ERROR", st & 4);

    // Wrapping base near end of uint32_t (grxcp's recommended smoke case)
    npu_dpi_init();
    npu_dpi_csr_write(NPU_CSR_DIM_M, 1); npu_dpi_csr_write(NPU_CSR_DIM_N, 1);
    npu_dpi_csr_write(NPU_CSR_DIM_K, 1);
    npu_dpi_csr_write(NPU_CSR_A_BASE, 0xFFFFFFF0);
    npu_dpi_csr_write(NPU_CSR_B_BASE, 0x8400);
    npu_dpi_csr_write(NPU_CSR_C_BASE, 0x8800);
    npu_dpi_csr_write(NPU_CSR_CTRL, 1);
    st = npu_dpi_csr_read(NPU_CSR_STATUS);
    check("Base 0xFFFFFFF0: ERROR (wrap)", st & 4);

    printf("\n=== The PTA block, on a build with no tile ===\n");
    npu_dpi_init();
    check("PTA_ID is the magic, map version 1",
          npu_dpi_csr_read(NPU_CSR_PTA_ID) == 0x50544101u);
    {
        uint32_t c0 = npu_dpi_csr_read(NPU_CSR_PTA_CAPS0);
        uint32_t c1 = npu_dpi_csr_read(NPU_CSR_PTA_CAPS1);
        uint32_t c2 = npu_dpi_csr_read(NPU_CSR_PTA_CAPS2);
        /* 4 rows, 4 columns, 16-bit operands, 48-bit sums -- by hand. */
        check("CAPS0 is this model's 4 x 4, 16 and 48", c0 == 0xC1001004u);
        check("CAPS1: no impairment built, twelve banks", c1 == 0x00000C00u);
        check("CAPS2: no engine, no stage, no tile", c2 == 0u);
        npu_dpi_csr_write(NPU_CSR_PTA_ID, 0xFFFFFFFFu);
        npu_dpi_csr_write(NPU_CSR_PTA_CAPS1, 0xFFFFFFFFu);
        check("the identity words are read-only",
              npu_dpi_csr_read(NPU_CSR_PTA_ID) == 0x50544101u &&
              npu_dpi_csr_read(NPU_CSR_PTA_CAPS1) == c1);
    }
    npu_dpi_csr_write(NPU_CSR_PTA_BITS, 0xFFFFFFFFu);
    npu_dpi_csr_write(NPU_CSR_PTA_SEED, 0x12345678u);
    npu_dpi_csr_write(NPU_CSR_PTA_CTRL, 0xFFFFFFFFu);
    check("BITS reads back at 18 bits", npu_dpi_csr_read(NPU_CSR_PTA_BITS) == 0x3FFFFu);
    check("SEED reads back", npu_dpi_csr_read(NPU_CSR_PTA_SEED) == 0x12345678u);
    check("CTRL keeps EN and nothing else", npu_dpi_csr_read(NPU_CSR_PTA_CTRL) == 0x1u);
    check("the block did not alias onto DIM_M", npu_dpi_csr_read(NPU_CSR_DIM_M) == 0);

    /* The refusal.  A good GEMM first, so DONE is latched going in: a refused
     * start has to clear it, and the result buffer must be left alone. */
    for (int i = 0; i < 4; i++) { npu_dpi_mem_write(0x8000+i, A[i], 1); npu_dpi_mem_write(0x8400+i, B[i], 1); }
    npu_dpi_csr_write(NPU_CSR_PTA_BITS, 0);
    npu_dpi_run_gemm(2, 2, 2, 0, 0x8000, 0x8400, 0x8800);
    check("exact GEMM runs with IMPAIR clear", npu_dpi_csr_read(NPU_CSR_STATUS) == 2);
    check("and counted one weight programming", npu_dpi_csr_read(NPU_CSR_PTA_WLOAD_CT) == 1);
    for (int b = 0; b < 7; b++) {
        char name[64];
        npu_dpi_mem_write(0x8800, 0xA5, 1);            /* poison C[0] */
        npu_dpi_csr_write(NPU_CSR_PTA_IMPAIR, 1u << b);
        npu_dpi_run_gemm(2, 2, 2, 0, 0x8000, 0x8400, 0x8800);
        st = npu_dpi_csr_read(NPU_CSR_STATUS);
        snprintf(name, sizeof name, "IMPAIR bit %d refused: ERROR, no DONE, C untouched", b);
        check(name, st == 4 && npu_dpi_mem_read(0x8800) == 0xA5);
    }
    check("IMPAIR reads back what was written", npu_dpi_csr_read(NPU_CSR_PTA_IMPAIR) == 0x40u);
    check("no programming counted for a refused start", npu_dpi_csr_read(NPU_CSR_PTA_WLOAD_CT) == 1);
    npu_dpi_csr_write(NPU_CSR_PTA_IMPAIR, 0);
    npu_dpi_run_gemm(2, 2, 2, 0, 0x8000, 0x8400, 0x8800);
    check("and the next clean start clears the error and runs",
          npu_dpi_csr_read(NPU_CSR_STATUS) == 2 && npu_dpi_mem_read(0x8800) == 19);

    printf("\n=== Allocator fixes ===\n");
    npu_ddr_alloc_t ddr;
    npu_ddr_alloc_init(&ddr, 0x0000, 0x10000);

    uint32_t failed = npu_ddr_alloc(&ddr, 0, 4);
    check("Zero-size alloc fails", failed == NPU_DDR_ALLOC_FAILED);

    uint32_t o1 = npu_ddr_alloc(&ddr, 10, 4);
    uint32_t o2 = npu_ddr_alloc(&ddr, 10, 4);
    check("Two allocs succeed", o1 != NPU_DDR_ALLOC_FAILED && o2 != NPU_DDR_ALLOC_FAILED);
    check("No overlap", o1 + 10 <= o2 || o2 + 10 <= o1);

    npu_ddr_alloc_reset(&ddr);
    uint32_t sum = 0;
    for (int i = 0; i < 100; i++) {
        uint32_t o = npu_ddr_alloc(&ddr, 10, 4);
        if (o == NPU_DDR_ALLOC_FAILED) break;
        sum += 10;
    }
    check("Arena stays within 64KB", sum <= 0x10000);

    int past = 0;
    for (int i = 0; i < ddr.num_blocks; i++)
        if (ddr.blocks[i].offset + ddr.blocks[i].total > 0x10000) past = 1;
    check("No block past end of DDR", !past);

    printf("\n=== RESULT: %d passed, %d failed ===\n", pass, fail);
    return fail;
}
