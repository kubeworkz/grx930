// -----------------------------------------------------------------------------
// npu_tile.h - External tiling library for the C930 NPU.
//
// When a GEMM dimension exceeds the on-chip MAX_M/MAX_N/MAX_K, the firmware
// must split it into tiles that fit within the NPU's buffer limits.  This
// library implements the tiling algorithms from c930_architecture.md §14.7.
//
// Usage (from grxcp firmware or test harness):
//
//   #include "npu_tile.h"
//
//   // Set up NPU accessors (required once at startup)
//   npu_tile_init(npu_read32, npu_write32);
//
//   // Run a GEMM that may exceed MAX_M/MAX_N/MAX_K
//   npu_tile_gemm(M, N, K, prec, a_src, b_src, c_dst, tmp_buf);
//
//   // Or use the step-by-step API for custom DDR management
//   npu_tile_plan(M, N, K, &plan);
//   for (int t = 0; t < plan.num_tiles; t++)
//       npu_tile_exec_one(&plan.tiles[t], a_src, b_src, c_dst, tmp_buf);
//
// DDR layout assumed by the library (caller must ensure no overlap):
//
//   tmp_buf + 0x0000 : A tile buffer  (MAX_M * MAX_K * elem_size bytes)
//   tmp_buf + A_SIZE : B tile buffer  (MAX_K * MAX_N * elem_size bytes)
//   tmp_buf + A_SIZE + B_SIZE : C tile buffer (MAX_M * MAX_N * 4 bytes)
//   tmp_buf + A_SIZE + B_SIZE + C_SIZE : C accumulation buffer (same size)
//
// Total tmp_buf size = NPU_TILE_TMP_SIZE(M, N, K, prec) bytes.
// -----------------------------------------------------------------------------

#ifndef NPU_TILE_H
#define NPU_TILE_H

#ifdef __cplusplus
extern "C" {
#endif

// Hardware limits (must match RTL parameters).
// Override these before including this header if your SoC uses different values.
#ifndef NPU_MAX_M
#define NPU_MAX_M   8
#endif
#ifndef NPU_MAX_N
#define NPU_MAX_N   12
#endif
#ifndef NPU_MAX_K
#define NPU_MAX_K   16
#endif
#ifndef NPU_NUM_COLS
#define NPU_NUM_COLS 8
#endif

// Precision modes
#define NPU_PREC_INT8   0
#define NPU_PREC_INT16  1
#define NPU_PREC_FP16   2
#define NPU_PREC_BF16   3
#define NPU_PREC_INT4   4

// Element size in bytes for each precision
static inline int npu_tile_elem_size(int prec) {
    switch (prec) {
        case NPU_PREC_INT4:  return 1;  // nibble-packed, 2 elements/byte
        case NPU_PREC_INT8:  return 1;
        case NPU_PREC_INT16: return 2;
        case NPU_PREC_FP16:  return 2;
        case NPU_PREC_BF16:  return 2;
        default:             return 1;
    }
}

// Buffer sizes for one tile
#define NPU_TILE_A_SIZE(m, k, es) ((m) * (k) * (es))
#define NPU_TILE_B_SIZE(k, n, es) ((k) * (n) * (es))
#define NPU_TILE_C_SIZE(m, n)     ((m) * (n) * 4)  // always 32-bit output

// Total temporary buffer size needed for tiling
#define NPU_TILE_TMP_SIZE(m, n, k, prec) \
    (NPU_TILE_A_SIZE(NPU_MAX_M, NPU_MAX_K, npu_tile_elem_size(prec)) + \
     NPU_TILE_B_SIZE(NPU_MAX_K, NPU_MAX_N, npu_tile_elem_size(prec)) + \
     NPU_TILE_C_SIZE(NPU_MAX_M, NPU_MAX_N) * 2)

// Maximum temporary buffer size (for stack allocation)
#define NPU_TILE_TMP_MAX \
    (NPU_TILE_A_SIZE(NPU_MAX_M, NPU_MAX_K, 2) + \
     NPU_TILE_B_SIZE(NPU_MAX_K, NPU_MAX_N, 2) + \
     NPU_TILE_C_SIZE(NPU_MAX_M, NPU_MAX_N) * 2)

// ---- NPU register access (caller provides read/write functions) ----

typedef unsigned int (*npu_read_fn)(unsigned int addr);
typedef void (*npu_write_fn)(unsigned int addr, unsigned int val);

// Register addresses (byte-addressed, matching c930_npu_csr.sv)
#define NPU_REG_CTRL    0x40000000u
#define NPU_REG_STATUS  0x40000004u
#define NPU_REG_DIM_M   0x40000008u
#define NPU_REG_DIM_N   0x4000000cu
#define NPU_REG_DIM_K   0x40000010u
#define NPU_REG_A_BASE  0x40000014u
#define NPU_REG_B_BASE  0x40000018u
#define NPU_REG_C_BASE  0x4000001cu
#define NPU_REG_PREC    0x40000020u
#define NPU_REG_CYCLE   0x40000024u
#define NPU_REG_OP_CNT  0x4000002cu
#define NPU_REG_STALL   0x40000030u
#define NPU_REG_DMA_CT  0x40000034u

#define NPU_CTRL_START  0x1u
#define NPU_STATUS_DONE 0x2u

// ---- Tile descriptor ----

typedef struct {
    int m_lo, m_hi;       // row range [m_lo, m_hi) in the output
    int n_lo, n_hi;       // col range [n_lo, n_hi) in the output
    int k_lo, k_hi;       // reduction range [k_lo, k_hi)
    int mc, nc, kc;        // tile dimensions (m_hi-m_lo, etc.)
    int is_first_k;        // 1 if this is the first K-tile (initialize C)
    int is_last_k;         // 1 if this is the last K-tile (no more accumulation)
} npu_tile_t;

// ---- Plan ----

#define NPU_TILE_MAX_TILES 64  // max tiles for one GEMM

typedef struct {
    int total_m, total_n, total_k;
    int prec;
    int num_tiles;
    npu_tile_t tiles[NPU_TILE_MAX_TILES];
} npu_tile_plan_t;

// ---- API ----

// Initialize the library with NPU access functions.
// Must be called before any other npu_tile_* function.
void npu_tile_init(npu_read_fn read_fn, npu_write_fn write_fn);

// Compute a tiling plan for a GEMM of size M x N x K.
// Returns 0 on success, -1 if the plan exceeds NPU_TILE_MAX_TILES.
int npu_tile_plan(int M, int N, int K, int prec, npu_tile_plan_t *plan);

// High-level: execute a full GEMM with automatic tiling.
// a_src/b_src/c_dst are byte addresses in DDR.
// tmp_buf is the temporary buffer.
void npu_tile_gemm(int M, int N, int K, int prec,
                   unsigned int a_src, unsigned int b_src,
                   unsigned int c_dst, unsigned int tmp_buf);

// Read NPU performance counters after the last tile execution.
typedef struct {
    unsigned int cycles;
    unsigned int dma_cycles;
    unsigned int ops;
    unsigned int stalls;
} npu_tile_stats_t;

void npu_tile_get_stats(npu_tile_stats_t *stats);

#ifdef __cplusplus
}
#endif

#endif // NPU_TILE_H
