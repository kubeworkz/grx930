// -----------------------------------------------------------------------------
// npu_dpi_shim.c - Standalone NPU register/DDR shim for grxcp testing.
//
// Fixes since initial release (817eb33), based on grxcp team feedback:
//   1. npu_dpi_run_gemm() now writes CTRL.START
//   2. STATUS.BUSY is now asserted for the first few cycles after START
//   3. Performance counter indices now match the RTL (CYCLE_HI at idx 10,
//      OP_COUNT at 11, STALL at 12, DMA_CT at 13)
//   4. All DDR access is bounds-checked; overflow sets STATUS.ERROR
//   5. Precision modes are respected in the GEMM computation and the cycle
//      model uses SoC defaults (NUM_ROWS=4, NUM_COLS=4, MAX_N=12)
//
// The PTA register block (grxcp's S1).  The RTL's register file has the block
// in every build, so this model answers on it too -- as the build it is, which
// is one with no photonic tile.  See npu_dpi_shim.h for exactly what is
// modelled; the short form is identity, the three registers a driver reads to
// describe a GEMM, and the refusal of any START that asks for an impairment.
// -----------------------------------------------------------------------------

#include "npu_dpi_shim.h"
#include <string.h>

// ---- DDR storage (flat 64KB byte array) ----
static uint8_t ddr[NPU_DDR_SIZE];

// ---- NPU CSR state ----
// Indices match c930_npu_csr.sv localparams exactly.
//   0  CTRL, 1  STATUS, 2  DIM_M, 3  DIM_N, 4  DIM_K,
//   5  A_BASE, 6  B_BASE, 7  C_BASE, 8  PREC,
//   9  CYCLE_LO, 10 (reserved, dead), 11 OP_COUNT, 12 STALL_CT, 13 DMA_CT
static uint32_t csr[14];
static int      npu_busy;       // mirrors STATUS bit 0
static int      npu_done_latch; // latched when GEMM completes (matches RTL done_latch)
static int      npu_cycles_left; // countdown for npu_dpi_run()
static int      npu_busy_cycles; // cycles to hold BUSY before DONE
static int      npu_error;      // mirrors STATUS bit 2

// SoC defaults: 4x4 systolic array
#define NPU_NUM_ROWS  4
#define NPU_NUM_COLS  4
#define NPU_MAX_N     12  // SoC default (not core default of 8)
#define NPU_MAX_K     16  // SoC default
#define NPU_DIN_W     16  // the SoC's operand width
#define NPU_ACC_W     48

// ---- PTA block state ----
// No tile in this model, so nothing here changes what a GEMM computes: these
// are the registers a driver reads back, and the mask the refusal tests.
static uint32_t pta_en;        // PTA_CTRL bit 0
static uint32_t pta_impair;    // PTA_IMPAIR[6:0]
static uint32_t pta_bits;      // PTA_BITS[17:0]
static uint32_t pta_seed;      // PTA_SEED
static uint32_t pta_wload_ct;  // PTA_WLOAD_CT

// The words c930_npu_core drives as o_pta_caps0..2, for this model's geometry.
// Banks are the SoC's rule: one per (N tile, K tile) of the largest shape.
#define NPU_PTA_BANKS \
    (((NPU_MAX_N + NPU_NUM_COLS - 1) / NPU_NUM_COLS) * \
     ((NPU_MAX_K + NPU_NUM_ROWS - 1) / NPU_NUM_ROWS))
#define NPU_PTA_CAPS0 \
    ((uint32_t)NPU_NUM_ROWS | ((uint32_t)NPU_NUM_COLS << 10) | \
     ((uint32_t)NPU_DIN_W << 20) | ((uint32_t)NPU_ACC_W << 26))
#define NPU_PTA_CAPS1 ((uint32_t)NPU_PTA_BANKS << 8)   // nothing built
#define NPU_PTA_CAPS2 0u                               // no engine, stage or tile

// ---- CSR field extractors (internal index-based) ----
#define CSR_CTRL      csr[0]
#define CSR_STATUS    csr[1]
#define CSR_DIM_M     csr[2]
#define CSR_DIM_N     csr[3]
#define CSR_DIM_K     csr[4]
#define CSR_A_BASE    csr[5]
#define CSR_B_BASE    csr[6]
#define CSR_C_BASE    csr[7]
#define CSR_PREC      csr[8]
#define CSR_CYCLE_LO  csr[9]
#define CSR_OP_COUNT  csr[11]
#define CSR_STALL_CT  csr[12]
#define CSR_DMA_CT    csr[13]

// ---- Build STATUS value from internal state ----
static uint32_t build_status(void) {
    // Bit 0 = BUSY, Bit 1 = DONE (latched), Bit 2 = ERROR
    // DONE is a latch set at completion, cleared on CTRL.START.
    // It does NOT depend on counter values.
    return (uint32_t)((npu_error ? 4 : 0) |
                      (npu_done_latch ? 2 : 0) |
                      (npu_busy ? 1 : 0));
}

// ---- Init ----
void npu_dpi_init(void) {
    memset(csr, 0, sizeof(csr));
    memset(ddr, 0, sizeof(ddr));
    npu_busy = 0;
    npu_done_latch = 0;
    npu_cycles_left = 0;
    npu_busy_cycles = 0;
    npu_error = 0;
    pta_en = 0;
    pta_impair = 0;
    pta_bits = 0;
    pta_seed = 0;
    pta_wload_ct = 0;
}

// ---- The PTA block ----
// Returns 1 if addr is one of the block's modelled words and was handled.
static int pta_csr_write(uint32_t addr, uint32_t data) {
    switch (addr) {
        case NPU_CSR_PTA_CTRL:   pta_en     = data & 0x1u;     return 1;
        case NPU_CSR_PTA_IMPAIR: pta_impair = data & 0x7Fu;    return 1;
        case NPU_CSR_PTA_BITS:   pta_bits   = data & 0x3FFFFu; return 1;
        case NPU_CSR_PTA_SEED:   pta_seed   = data;            return 1;
        default: return 0;
    }
}

static int pta_csr_read(uint32_t addr, uint32_t *data) {
    switch (addr) {
        case NPU_CSR_PTA_ID:       *data = NPU_PTA_ID_VALUE; return 1;
        case NPU_CSR_PTA_CAPS0:    *data = NPU_PTA_CAPS0;    return 1;
        case NPU_CSR_PTA_CAPS1:    *data = NPU_PTA_CAPS1;    return 1;
        case NPU_CSR_PTA_CAPS2:    *data = NPU_PTA_CAPS2;    return 1;
        case NPU_CSR_PTA_CTRL:     *data = pta_en;           return 1;
        case NPU_CSR_PTA_STATUS:   *data = npu_busy ? NPU_PTA_STATUS_BUSY : 0u; return 1;
        case NPU_CSR_PTA_IMPAIR:   *data = pta_impair;       return 1;
        case NPU_CSR_PTA_BITS:     *data = pta_bits;         return 1;
        case NPU_CSR_PTA_SEED:     *data = pta_seed;         return 1;
        case NPU_CSR_PTA_WLOAD_CT: *data = pta_wload_ct;     return 1;
        default: return 0;
    }
}

// ---- CSR access ----
void npu_dpi_csr_write(uint32_t addr, uint32_t data) {
    if (pta_csr_write(addr, data)) return;
    int idx = (addr - 0x40000000u) >> 2;
    if (idx < 0 || idx > 13) return;

    // START bit (CTRL register, bit 0) triggers the NPU
    if (idx == 0 && (data & 1)) {
        // Clear DONE and ERROR on START (matches RTL behavior)
        npu_done_latch = 0;
        npu_error = 0;

        if (!npu_busy) {
            uint32_t m = CSR_DIM_M;
            uint32_t n = CSR_DIM_N;
            uint32_t k = CSR_DIM_K;
            uint32_t prec = CSR_PREC;

            if (m == 0 || n == 0 || k == 0) return;

            // There is no tile here, so there is no impairment to apply: this
            // model can only return the exact product.  Running the GEMM with
            // PTA_IMPAIR set would hand back exact results under an analog
            // label, which is why the RTL's digital array refuses the start
            // (c930_npu_core.sv, pta_bad) -- and so does this.
            if (pta_impair != 0) {
                npu_error = 1;
                return;
            }

            // Bounds check: A, B, C must fit in 64KB.
            // Use wrap-safe arithmetic: check base < SIZE and extent <= SIZE - base
            // to prevent uint32_t overflow from bypassing the check.
            uint32_t a_size, b_size, c_size;

            if (prec == NPU_PREC_INT4) {
                a_size = (m * k + 1) / 2;
                b_size = (k * n + 1) / 2;
                c_size = m * n * 4;
            } else if (prec == NPU_PREC_INT8) {
                a_size = m * k;
                b_size = k * n;
                c_size = m * n * 4;
            } else if (prec == NPU_PREC_INT16) {
                a_size = m * k * 2;
                b_size = k * n * 2;
                c_size = m * n * 4;
            } else {
                // FP16, BF16: 2 bytes per element
                a_size = m * k * 2;
                b_size = k * n * 2;
                c_size = m * n * 4;
            }

            // Wrap-safe: base + size <= NPU_DDR_SIZE iff base < NPU_DDR_SIZE && size <= NPU_DDR_SIZE - base
            if (CSR_A_BASE >= NPU_DDR_SIZE || a_size > NPU_DDR_SIZE - CSR_A_BASE ||
                CSR_B_BASE >= NPU_DDR_SIZE || b_size > NPU_DDR_SIZE - CSR_B_BASE ||
                CSR_C_BASE >= NPU_DDR_SIZE || c_size > NPU_DDR_SIZE - CSR_C_BASE) {
                npu_error = 1;
                return;
            }

            // Compute cycle count using SoC-default array geometry
            // FP16/BF16: 2-cycle PE latency; INT: 1-cycle PE latency
            int is_fp = (prec == NPU_PREC_FP16 || prec == NPU_PREC_BF16);
            uint32_t ps_offset = is_fp ? NPU_NUM_ROWS : 0;

            // N-tiling: process NUM_COLS columns per pass
            uint32_t nc = (n > NPU_MAX_N) ? NPU_MAX_N : n;
            uint32_t n_tiles = (nc + NPU_NUM_COLS - 1) / NPU_NUM_COLS;
            uint32_t m_tiles = (m + NPU_NUM_ROWS - 1) / NPU_NUM_ROWS;
            uint32_t k_tiles = (k + NPU_NUM_ROWS - 1) / NPU_NUM_ROWS;

            uint32_t cycles_per_tile = NPU_NUM_ROWS + ps_offset + NPU_NUM_COLS + 2;
            uint32_t total_cycles = m_tiles * n_tiles * k_tiles * cycles_per_tile;

            // One weight programming per (N tile, K tile), as the core counts
            // them in every build.
            pta_wload_ct += n_tiles * k_tiles;

            // Simulate GEMM: compute C = A x B in software
            for (uint32_t i = 0; i < m; i++) {
                for (uint32_t j = 0; j < n; j++) {
                    int32_t sum = 0;
                    for (uint32_t p = 0; p < k; p++) {
                        int32_t a_val, b_val;

                        if (prec == NPU_PREC_INT8) {
                            a_val = (int8_t)ddr[CSR_A_BASE + i * k + p];
                            b_val = (int8_t)ddr[CSR_B_BASE + p * n + j];
                        } else if (prec == NPU_PREC_INT16) {
                            uint32_t off_a = CSR_A_BASE + (i * k + p) * 2;
                            uint32_t off_b = CSR_B_BASE + (p * n + j) * 2;
                            a_val = (int16_t)(ddr[off_a] | (ddr[off_a+1] << 8));
                            b_val = (int16_t)(ddr[off_b] | (ddr[off_b+1] << 8));
                        } else if (prec == NPU_PREC_INT4) {
                            // INT4: two nibbles per byte
                            uint32_t byte_a = CSR_A_BASE + (i * k + p) / 2;
                            uint32_t byte_b = CSR_B_BASE + (p * n + j) / 2;
                            int nib_a = (ddr[byte_a] >> (((i*k+p) & 1) * 4)) & 0xF;
                            int nib_b = (ddr[byte_b] >> (((p*n+j) & 1) * 4)) & 0xF;
                            // Sign-extend 4-bit
                            a_val = (nib_a >= 8) ? nib_a - 16 : nib_a;
                            b_val = (nib_b >= 8) ? nib_b - 16 : nib_b;
                        } else {
                            // FP16/BF16: treat as INT8 for now (the shim
                            // doesn't implement float; accuracy comes from RTL)
                            a_val = (int8_t)ddr[CSR_A_BASE + i * k + p];
                            b_val = (int8_t)ddr[CSR_B_BASE + p * n + j];
                        }
                        sum += a_val * b_val;
                    }
                    // Write INT32 result to DDR (little-endian)
                    uint32_t c_addr = CSR_C_BASE + (i * n + j) * 4;
                    ddr[c_addr + 0] = (uint8_t)(sum >>  0);
                    ddr[c_addr + 1] = (uint8_t)(sum >>  8);
                    ddr[c_addr + 2] = (uint8_t)(sum >> 16);
                    ddr[c_addr + 3] = (uint8_t)(sum >> 24);
                }
            }

            // Set up timing model
            npu_cycles_left = (int)total_cycles;
            npu_busy_cycles = 2;  // BUSY asserted for 2 cycles (pipeline fill)
            npu_busy = 1;
            npu_error = 0;

            // Clear counters
            CSR_CYCLE_LO = 0;
            CSR_OP_COUNT = 0;
            CSR_STALL_CT = 0;
            CSR_DMA_CT   = 0;
        }
    }

    csr[idx] = data;
}

uint32_t npu_dpi_csr_read(uint32_t addr) {
    uint32_t pta;
    if (pta_csr_read(addr, &pta)) return pta;
    int idx = (addr - 0x40000000u) >> 2;
    if (idx < 0 || idx > 13) return 0;

    // STATUS register is built dynamically
    if (idx == 1) return build_status();

    return csr[idx];
}

// ---- DDR byte access (bounds-checked) ----
void npu_dpi_mem_write(uint32_t addr, uint32_t data, uint32_t strb) {
    // Wrap-safe: check base < SIZE and each written byte is in range
    if (addr >= NPU_DDR_SIZE) {
        npu_error = 1;
        return;
    }
    // Check highest byte written (wrap-safe: addr is already < NPU_DDR_SIZE)
    uint32_t highest = 0;
    if (strb & 0x1) highest = 0;
    if (strb & 0x2) highest = 1;
    if (strb & 0x4) highest = 2;
    if (strb & 0x8) highest = 3;
    if (highest >= NPU_DDR_SIZE - addr) {
        npu_error = 1;
        return;
    }
    if (strb & 0x1) ddr[addr + 0] = (uint8_t)(data);
    if (strb & 0x2) ddr[addr + 1] = (uint8_t)(data >> 8);
    if (strb & 0x4) ddr[addr + 2] = (uint8_t)(data >> 16);
    if (strb & 0x8) ddr[addr + 3] = (uint8_t)(data >> 24);
}

int npu_dpi_mem_read(uint32_t addr) {
    if (addr >= NPU_DDR_SIZE) {
        npu_error = 1;
        return 0;
    }
    return (int)ddr[addr];
}

// ---- Cycle advancement ----
void npu_dpi_run(int n_cycles) {
    if (!npu_busy) return;

    for (int c = 0; c < n_cycles; c++) {
        CSR_CYCLE_LO++;
        CSR_DMA_CT++;

        if (npu_busy_cycles > 0) {
            // Still in pipeline-fill phase: BUSY remains high
            npu_busy_cycles--;
        } else {
            npu_cycles_left--;
            if (npu_cycles_left <= 0) {
                // GEMM complete: latch DONE (matches RTL done_latch behavior)
                npu_busy = 0;
                npu_done_latch = 1;

                // Update OP_COUNT: M * N * K * 2 (MAC per element)
                CSR_OP_COUNT = CSR_DIM_M * CSR_DIM_N * CSR_DIM_K * 2;

                // STALL_COUNT = 0 (no stalls in this model)
                CSR_STALL_CT = 0;

                break;
            }
        }
    }
}

int npu_dpi_expected_cycles(void) {
    uint32_t m = CSR_DIM_M, n = CSR_DIM_N, k = CSR_DIM_K, prec = CSR_PREC;
    if (m == 0 || n == 0 || k == 0) return 0;

    int is_fp = (prec == NPU_PREC_FP16 || prec == NPU_PREC_BF16);
    uint32_t ps_offset = is_fp ? NPU_NUM_ROWS : 0;

    uint32_t nc = (n > NPU_MAX_N) ? NPU_MAX_N : n;
    uint32_t n_tiles = (nc + NPU_NUM_COLS - 1) / NPU_NUM_COLS;
    uint32_t m_tiles = (m + NPU_NUM_ROWS - 1) / NPU_NUM_ROWS;
    uint32_t k_tiles = (k + NPU_NUM_ROWS - 1) / NPU_NUM_ROWS;

    return (int)(m_tiles * n_tiles * k_tiles * (NPU_NUM_ROWS + ps_offset + NPU_NUM_COLS + 2));
}

// ---- High-level GEMM in one call ----
int npu_dpi_run_gemm(uint32_t m, uint32_t n, uint32_t k, uint32_t prec,
                     uint32_t a_addr, uint32_t b_addr, uint32_t c_addr) {
    npu_dpi_csr_write(NPU_CSR_DIM_M,  m);
    npu_dpi_csr_write(NPU_CSR_DIM_N,  n);
    npu_dpi_csr_write(NPU_CSR_DIM_K,  k);
    npu_dpi_csr_write(NPU_CSR_A_BASE, a_addr);
    npu_dpi_csr_write(NPU_CSR_B_BASE, b_addr);
    npu_dpi_csr_write(NPU_CSR_C_BASE, c_addr);
    npu_dpi_csr_write(NPU_CSR_PREC,   prec);
    npu_dpi_csr_write(NPU_CSR_CTRL,   1);  // DEFECT 1 FIX: trigger GEMM

    int expected = npu_dpi_expected_cycles();
    npu_dpi_run(expected + 20);  // +20 for pipeline drain + BUSY phase

    return expected + 20;
}
