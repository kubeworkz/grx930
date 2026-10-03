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
//
// The tile build (grxcp's S2).  Compiled with NPU_DPI_WITH_PTA and linked with
// pta_tile_model.c, npu_dpi_set_tile() makes this a build that HAS the tile.
// The tile's arithmetic is not written here: it is pta_gemm(), the reference
// the RTL is gated against, so there is one error model and this file is a
// register map in front of it.  Without the macro nothing below changes and the
// file still links against nothing.
// -----------------------------------------------------------------------------

#include "npu_dpi_shim.h"
#include <string.h>
#ifdef NPU_DPI_WITH_PTA
#include <stdlib.h>
#include "pta_tile_model.h"
#endif

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
static uint32_t pta_sig_th;    // PTA_SIGMA_TH[15:0]
static uint32_t pta_sig_sh;    // PTA_SIGMA_SH[15:0]
static uint32_t pta_sig_pr;    // PTA_SIGMA_PR[15:0]
static uint32_t pta_drift;     // PTA_DRIFT[20:0]
static uint32_t pta_xtalk;     // PTA_XTALK[7:0]
static uint32_t pta_dmax;      // PTA_DRIFT_MAX[15:0]
static uint32_t pta_shot_ct;   // PTA_SHOT_CT
static uint32_t pta_sat_ct;    // PTA_SAT_CT

// What this model is built as.  Not reset by npu_dpi_init().
static int tile_kind = NPU_DPI_TILE_NONE;

// The impairments the tile build implements: all but MZM_NL, which is the
// RTL's PTA_BUILT (c930_npu_core.sv).
#define NPU_PTA_BUILT_TILE 0x5Fu

#ifdef NPU_DPI_WITH_PTA
// The tile itself.  Its geometry is this model's, the same one PTA_CAPS0
// reports, and its drift lives here from one GEMM to the next.
static const pta_tile tile_geom = { NPU_NUM_ROWS, NPU_NUM_COLS, NPU_DIN_W, NPU_ACC_W };
static pta_device     tile_dev;
static int            tile_dev_live;
#endif

// The words c930_npu_core drives as o_pta_caps0..2, for this model's geometry.
// Banks are the SoC's rule: one per (N tile, K tile) of the largest shape.
#define NPU_PTA_BANKS \
    (((NPU_MAX_N + NPU_NUM_COLS - 1) / NPU_NUM_COLS) * \
     ((NPU_MAX_K + NPU_NUM_ROWS - 1) / NPU_NUM_ROWS))
#define NPU_PTA_CAPS0 \
    ((uint32_t)NPU_NUM_ROWS | ((uint32_t)NPU_NUM_COLS << 10) | \
     ((uint32_t)NPU_DIN_W << 20) | ((uint32_t)NPU_ACC_W << 26))
// The widest activation and weight bits that quantise: DIN_W - 1, capped by the
// four bits PTA_BITS has.  As the core computes PTA_QMAX.
#define NPU_PTA_QMAX ((NPU_DIN_W - 1 > 15) ? 15u : (uint32_t)(NPU_DIN_W - 1))

static uint32_t pta_built(void) {
    return (tile_kind == NPU_DPI_TILE_MODEL) ? NPU_PTA_BUILT_TILE : 0u;
}

static uint32_t pta_caps1(void) {
    uint32_t caps = (uint32_t)NPU_PTA_BANKS << 8;
    if (tile_kind == NPU_DPI_TILE_MODEL)
        caps |= NPU_PTA_BUILT_TILE | (NPU_PTA_QMAX << 16) | (NPU_PTA_QMAX << 20) |
                (15u << 24);
    return caps;
}

// An emulated tile of kind 3 -- the model on its own -- or nothing at all.
// Neither build has a calibration engine or an activation stage.
static uint32_t pta_caps2(void) {
    return (tile_kind == NPU_DPI_TILE_MODEL)
               ? (0x80000000u | ((uint32_t)NPU_DPI_TILE_MODEL << 18)) : 0u;
}

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
    pta_sig_th = 0;
    pta_sig_sh = 0;
    pta_sig_pr = 0;
    pta_drift = 0;
    pta_xtalk = 0;
    pta_dmax = 0;
    pta_shot_ct = 0;
    pta_sat_ct = 0;
#ifdef NPU_DPI_WITH_PTA
    // The tile as the RTL leaves reset: no drift, its generator on its
    // constant, and the correction stores clear.
    if (tile_dev_live) {
        pta_model_reset(&tile_dev, 0);
        pta_cal_reset(&tile_dev);
    }
#endif
}

// ---- The build ----
int npu_dpi_set_tile(int kind) {
    if (kind == NPU_DPI_TILE_NONE) {
        tile_kind = NPU_DPI_TILE_NONE;
        return 0;
    }
#ifdef NPU_DPI_WITH_PTA
    if (kind == NPU_DPI_TILE_MODEL) {
        if (!tile_dev_live) {
            if (pta_device_init(&tile_dev, &tile_geom) != 0) return -1;
            tile_dev_live = 1;
        }
        tile_kind = NPU_DPI_TILE_MODEL;
        return 0;
    }
#endif
    return -1;
}

int npu_dpi_tile(void) {
    return tile_kind;
}

// ---- The PTA block ----
// Returns 1 if addr is one of the block's modelled words and was handled.
static int pta_csr_write(uint32_t addr, uint32_t data) {
    switch (addr) {
        case NPU_CSR_PTA_CTRL:
            pta_en = data & NPU_PTA_CTRL_EN;
#ifdef NPU_DPI_WITH_PTA
            // Honoured only while idle, as the core's is: a reset under a
            // running GEMM would change the tile it is running on.
            if ((data & NPU_PTA_CTRL_MODEL_RST) && !npu_busy && tile_dev_live) {
                pta_model_reset(&tile_dev, pta_seed);
                pta_cal_reset(&tile_dev);
            }
#endif
            return 1;
        case NPU_CSR_PTA_IMPAIR:    pta_impair = data & 0x7Fu;     return 1;
        case NPU_CSR_PTA_BITS:      pta_bits   = data & 0x3FFFFu;  return 1;
        case NPU_CSR_PTA_SEED:      pta_seed   = data;             return 1;
        case NPU_CSR_PTA_SIGMA_TH:  pta_sig_th = data & 0xFFFFu;   return 1;
        case NPU_CSR_PTA_SIGMA_SH:  pta_sig_sh = data & 0xFFFFu;   return 1;
        case NPU_CSR_PTA_SIGMA_PR:  pta_sig_pr = data & 0xFFFFu;   return 1;
        case NPU_CSR_PTA_DRIFT:     pta_drift  = data & 0x1FFFFFu; return 1;
        case NPU_CSR_PTA_XTALK:     pta_xtalk  = data & 0xFFu;     return 1;
        case NPU_CSR_PTA_DRIFT_MAX: pta_dmax   = data & 0xFFFFu;   return 1;
        default: return 0;
    }
}

static int pta_csr_read(uint32_t addr, uint32_t *data) {
    switch (addr) {
        case NPU_CSR_PTA_ID:        *data = NPU_PTA_ID_VALUE; return 1;
        case NPU_CSR_PTA_CAPS0:     *data = NPU_PTA_CAPS0;    return 1;
        case NPU_CSR_PTA_CAPS1:     *data = pta_caps1();      return 1;
        case NPU_CSR_PTA_CAPS2:     *data = pta_caps2();      return 1;
        case NPU_CSR_PTA_CTRL:      *data = pta_en;           return 1;
        case NPU_CSR_PTA_STATUS:
            *data = (npu_busy ? NPU_PTA_STATUS_BUSY : 0u) |
                    (pta_sat_ct ? NPU_PTA_STATUS_SAT : 0u);
            return 1;
        case NPU_CSR_PTA_IMPAIR:    *data = pta_impair;       return 1;
        case NPU_CSR_PTA_BITS:      *data = pta_bits;         return 1;
        case NPU_CSR_PTA_SEED:      *data = pta_seed;         return 1;
        case NPU_CSR_PTA_SIGMA_TH:  *data = pta_sig_th;       return 1;
        case NPU_CSR_PTA_SIGMA_SH:  *data = pta_sig_sh;       return 1;
        case NPU_CSR_PTA_SIGMA_PR:  *data = pta_sig_pr;       return 1;
        case NPU_CSR_PTA_DRIFT:     *data = pta_drift;        return 1;
        case NPU_CSR_PTA_XTALK:     *data = pta_xtalk;        return 1;
        case NPU_CSR_PTA_SHOT_CT:   *data = pta_shot_ct;      return 1;
        case NPU_CSR_PTA_WLOAD_CT:  *data = pta_wload_ct;     return 1;
        case NPU_CSR_PTA_SAT_CT:    *data = pta_sat_ct;       return 1;
        case NPU_CSR_PTA_DRIFT_MAX: *data = pta_dmax;         return 1;
        default: return 0;
    }
}

#ifdef NPU_DPI_WITH_PTA
// One operand element out of DDR, as the exact path below reads it.  The tile
// is refused for FP16 and BF16 before this is reached, so only the integer
// packings appear.
static int32_t tile_operand(uint32_t base, uint32_t idx, uint32_t prec) {
    if (prec == NPU_PREC_INT16) {
        uint32_t off = base + idx * 2;
        return (int16_t)(ddr[off] | (ddr[off + 1] << 8));
    }
    if (prec == NPU_PREC_INT4) {
        int nib = (ddr[base + idx / 2] >> ((idx & 1) * 4)) & 0xF;
        return (nib >= 8) ? nib - 16 : nib;
    }
    return (int8_t)ddr[base + idx];
}

// The GEMM, on the tile: the registers become a pta_cfg, the operands come out
// of DDR, and pta_gemm() does the arithmetic.  Returns 0, or -1 if memory ran
// out or the model declined the shape -- in which case C has not been touched.
static int gemm_tile(uint32_t m, uint32_t n, uint32_t k, uint32_t prec) {
    pta_cfg  cfg;
    int32_t *A, *B;
    int64_t *C;
    long     sats;

    memset(&cfg, 0, sizeof cfg);
    cfg.impair      = pta_impair;
    cfg.act_bits    = pta_bits & 0xFu;
    cfg.w_bits      = (pta_bits >> 4) & 0xFu;
    cfg.adc_bits    = (pta_bits >> 8) & 0xFu;
    cfg.adc_shift   = (pta_bits >> 12) & 0x3Fu;
    cfg.seed        = pta_seed;
    cfg.sigma_th    = pta_sig_th;
    cfg.k_shot      = pta_sig_sh;
    cfg.sigma_pr    = pta_sig_pr;
    cfg.drift_sigma = pta_drift & 0xFFFFu;
    cfg.drift_log2  = (pta_drift >> 16) & 0x1Fu;
    cfg.drift_max   = pta_dmax;
    cfg.xtalk       = pta_xtalk;
    /* trim_step and trim_max stay zero: there is no calibration engine here,
     * and with both zero the tile is the one C1 built. */

    A = (int32_t *)malloc((size_t)m * k * sizeof *A);
    B = (int32_t *)malloc((size_t)k * n * sizeof *B);
    C = (int64_t *)malloc((size_t)m * n * sizeof *C);
    if (!A || !B || !C) { free(A); free(B); free(C); return -1; }

    for (uint32_t i = 0; i < m * k; i++) A[i] = tile_operand(CSR_A_BASE, i, prec);
    for (uint32_t i = 0; i < k * n; i++) B[i] = tile_operand(CSR_B_BASE, i, prec);

    // Bank 0: no command queue here, so nothing ever flips the bank.
    sats = pta_gemm(&cfg, &tile_geom, &tile_dev, 0, (int)m, (int)n, (int)k, A, B, C);
    if (sats < 0) { free(A); free(B); free(C); return -1; }

    // C is the low 32 bits of each ACC_W-bit sum, which is what the DMA writes.
    for (uint32_t i = 0; i < m * n; i++) {
        uint32_t v = (uint32_t)(uint64_t)C[i];
        uint32_t c_addr = CSR_C_BASE + i * 4;
        ddr[c_addr + 0] = (uint8_t)(v >>  0);
        ddr[c_addr + 1] = (uint8_t)(v >>  8);
        ddr[c_addr + 2] = (uint8_t)(v >> 16);
        ddr[c_addr + 3] = (uint8_t)(v >> 24);
    }
    pta_sat_ct = (uint32_t)sats;
    free(A); free(B); free(C);
    return 0;
}
#endif

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

            // The core's refusal (c930_npu_core.sv, pta_bad), which is the
            // same expression in both builds because the built mask is what
            // differs.  With no tile the mask is empty, so any impairment is
            // refused: this model could only return the exact product, and
            // doing that with PTA_IMPAIR set would hand back exact results
            // under an analog label.  With the tile it refuses what the tile
            // cannot model -- a bit it does not implement, a float precision,
            // or an ADC shift past 40.
            if (pta_impair != 0) {
                int fp = (prec == NPU_PREC_FP16 || prec == NPU_PREC_BF16);
                uint32_t shift = (pta_bits >> 12) & 0x3Fu;
                if ((pta_impair & ~pta_built()) != 0 || fp || shift > 40) {
                    npu_error = 1;
                    return;
                }
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

            // The tile, if this build has one and the GEMM is impaired.  An
            // unimpaired GEMM on a tile is the exact product -- the RTL's C0
            // gate is that swap being bit-identical -- so it takes the loop
            // below, as every GEMM does on the array.  Before the counters:
            // a GEMM the model declines has not run and counts nothing.
            int tile_ran = 0;
            pta_sat_ct = 0;
#ifdef NPU_DPI_WITH_PTA
            if (tile_kind == NPU_DPI_TILE_MODEL && pta_impair != 0) {
                if (gemm_tile(m, n, k, prec) != 0) {
                    npu_error = 1;
                    return;
                }
                tile_ran = 1;
            }
#endif

            // One weight programming per (N tile, K tile), as the core counts
            // them in every build, and on a tile a shot per output row of each.
            pta_wload_ct += n_tiles * k_tiles;
            if (tile_kind == NPU_DPI_TILE_MODEL)
                pta_shot_ct += m * n_tiles * k_tiles;

            // Simulate GEMM: compute C = A x B in software
            for (uint32_t i = 0; !tile_ran && i < m; i++) {
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
