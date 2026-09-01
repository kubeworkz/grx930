// -----------------------------------------------------------------------------
// npu_dpi_shim.c - Standalone NPU register/DDR shim for grxcp testing.
//
// See npu_dpi_shim.h for the API.
//
// This implements a register-model-accurate NPU without Verilator.
// CSR reads/writes update internal state; npu_dpi_run() advances the
// NPU's internal state machine to simulate GEMM execution.
//
// The shim computes the GEMM result in software (INT8 -> INT32) and
// writes it to DDR, mimicking what the hardware DMA would do.
// -----------------------------------------------------------------------------

#include "npu_dpi_shim.h"
#include <string.h>

// ---- DDR storage (flat 64KB byte array) ----
static uint8_t ddr[65536];

// ---- NPU CSR state ----
static uint32_t csr[16];   // 16 x 32-bit registers at 0x40000000 + 4*i
static int      npu_busy;  // 1 = GEMM in progress
static int      npu_cycles_left;  // countdown for npu_dpi_run()

// ---- CSR field extractors ----
#define DIM_M   (csr[2] & 0xFFFF)
#define DIM_N   (csr[3] & 0xFFFF)
#define DIM_K   (csr[4] & 0xFFFF)
#define A_BASE  (csr[5])
#define B_BASE  (csr[6])
#define C_BASE  (csr[7])
#define PREC    (csr[8] & 0xF)

// ---- Init ----
void npu_dpi_init(void) {
    memset(csr, 0, sizeof(csr));
    memset(ddr, 0, sizeof(ddr));
    npu_busy = 0;
    npu_cycles_left = 0;
    csr[1] = 0;  // STATUS = 0 (not done)
}

// ---- CSR access ----
void npu_dpi_csr_write(uint32_t addr, uint32_t data) {
    int idx = (addr - 0x40000000u) >> 2;
    if (idx < 0 || idx > 15) return;

    // START bit (CTRL register, bit 0) triggers the NPU
    if (idx == 0 && (data & 1)) {
        if (!npu_busy) {
            // Start GEMM: compute cycle count and begin
            uint32_t m = DIM_M, n = DIM_N, k = DIM_K;
            uint32_t a = A_BASE, b = B_BASE, c = C_BASE;

            if (m == 0 || n == 0 || k == 0) return;

            // Simulate GEMM: compute C = A x B in software
            for (uint32_t i = 0; i < m; i++) {
                for (uint32_t j = 0; j < n; j++) {
                    int32_t sum = 0;
                    for (uint32_t p = 0; p < k; p++) {
                        int8_t a_val = (int8_t)ddr[a + i * k + p];
                        int8_t b_val = (int8_t)ddr[b + p * n + j];
                        sum += (int32_t)a_val * (int32_t)b_val;
                    }
                    // Write INT32 result to DDR (little-endian)
                    uint32_t c_addr = c + (i * n + j) * 4;
                    ddr[c_addr + 0] = (sum >>  0) & 0xFF;
                    ddr[c_addr + 1] = (sum >>  8) & 0xFF;
                    ddr[c_addr + 2] = (sum >> 16) & 0xFF;
                    ddr[c_addr + 3] = (sum >> 24) & 0xFF;
                }
            }

            // Compute cycle count (matches hardware formula)
            // M-tiles * K-tiles * (NUM_ROWS + NUM_COLS + 2)
            uint32_t m_tiles = (m + 7) / 8;  // NUM_ROWS = 8
            uint32_t k_tiles = (k + 7) / 8;
            uint32_t nc = (n > 12) ? 12 : n;  // MAX_N = 12
            uint32_t n_tiles = (n + nc - 1) / nc;
            npu_cycles_left = m_tiles * n_tiles * k_tiles * (8 + 8 + 2);

            npu_busy = 1;
            csr[1] = 0;  // Clear DONE
            csr[9] = 0;  // CYCLE_COUNT = 0
            csr[10] = 0; // OP_COUNT = 0
            csr[11] = 0; // STALL_COUNT = 0
            csr[12] = 0; // DMA_CT = 0
        }
    }

    csr[idx] = data;
}

uint32_t npu_dpi_csr_read(uint32_t addr) {
    int idx = (addr - 0x40000000u) >> 2;
    if (idx < 0 || idx > 15) return 0;
    return csr[idx];
}

// ---- DDR byte access ----
void npu_dpi_mem_write(uint32_t addr, uint32_t data, uint32_t strb) {
    if (addr >= 65532) return;
    if (strb & 0x1) ddr[addr + 0] = data & 0xFF;
    if (strb & 0x2) ddr[addr + 1] = (data >> 8) & 0xFF;
    if (strb & 0x4) ddr[addr + 2] = (data >> 16) & 0xFF;
    if (strb & 0x8) ddr[addr + 3] = (data >> 24) & 0xFF;
}

int npu_dpi_mem_read(uint32_t addr) {
    if (addr >= 65536) return 0;
    return (int)ddr[addr];
}

// ---- Cycle advancement ----
void npu_dpi_run(int n_cycles) {
    if (!npu_busy) return;

    csr[9] += n_cycles;  // CYCLE_COUNT

    npu_cycles_left -= n_cycles;
    if (npu_cycles_left <= 0) {
        // GEMM complete
        npu_busy = 0;
        csr[1] |= 2;  // Set STATUS.DONE

        // Update OP_COUNT: M * N * K * 2 (multiply + accumulate)
        uint32_t m = DIM_M, n = DIM_N, k = DIM_K;
        csr[10] = m * n * k * 2;

        // STALL_COUNT = 0 (no stalls in this model)
        csr[11] = 0;

        // DMA_CT = cycle_count (DMA runs the whole time in this model)
        csr[12] = csr[9];
    }
}

int npu_dpi_expected_cycles(void) {
    uint32_t m = DIM_M, n = DIM_N, k = DIM_K;
    if (m == 0 || n == 0 || k == 0) return 0;
    uint32_t m_tiles = (m + 7) / 8;
    uint32_t k_tiles = (k + 7) / 8;
    uint32_t nc = (n > 12) ? 12 : n;
    uint32_t n_tiles = (n + nc - 1) / nc;
    return m_tiles * n_tiles * k_tiles * (8 + 8 + 2);
}

// ---- High-level GEMM ----
int npu_dpi_run_gemm(uint32_t m, uint32_t n, uint32_t k, uint32_t prec,
                     uint32_t a_addr, uint32_t b_addr, uint32_t c_addr) {
    npu_dpi_csr_write(NPU_CSR_DIM_M,  m);
    npu_dpi_csr_write(NPU_CSR_DIM_N,  n);
    npu_dpi_csr_write(NPU_CSR_DIM_K,  k);
    npu_dpi_csr_write(NPU_CSR_A_BASE, a_addr);
    npu_dpi_csr_write(NPU_CSR_B_BASE, b_addr);
    npu_dpi_csr_write(NPU_CSR_C_BASE, c_addr);
    npu_dpi_csr_write(NPU_CSR_PREC,   prec);

    int expected = npu_dpi_expected_cycles();
    npu_dpi_run(expected + 10);  // +10 for pipeline drain

    return expected + 10;
}
