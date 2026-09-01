// -----------------------------------------------------------------------------
// npu_tile.c - External tiling implementation for the C930 NPU.
//
// See npu_tile.h for the API and DDR layout documentation.
// Algorithms follow c930_architecture.md §14.7.
// -----------------------------------------------------------------------------

#include "npu_tile.h"

// ---- Static state ----

static npu_read_fn  s_read  = 0;
static npu_write_fn s_write = 0;

static inline void csr_write(unsigned int reg, unsigned int val) {
    s_write(reg, val);
}

static inline unsigned int csr_read(unsigned int reg) {
    return s_read(reg);
}

// ---- Init ----

void npu_tile_init(npu_read_fn read_fn, npu_write_fn write_fn) {
    s_read  = read_fn;
    s_write = write_fn;
}

// ---- DDR memory copy helpers (byte-granularity, works on any RISC-V) ----

static void mem_copy(unsigned int dst, const void *src, int len) {
    const unsigned char *s = (const unsigned char *)src;
    unsigned char *d = (unsigned char *)dst;
    for (int i = 0; i < len; i++)
        d[i] = s[i];
}

// Add src[] += addend[] for len/4 words (32-bit accumulation for K-tiling).
// Operates on raw bytes but accumulates as 32-bit integers.
static void mem_add32(unsigned int dst, unsigned int addend, int num_words) {
    volatile unsigned int *d = (volatile unsigned int *)dst;
    volatile unsigned int *s = (volatile unsigned int *)addend;
    for (int i = 0; i < num_words; i++)
        d[i] += s[i];
}

// ---- NPU trigger and wait ----

static void npu_trigger_and_wait(void) {
    csr_write(NPU_REG_CTRL, NPU_CTRL_START);
    while (!(csr_read(NPU_REG_STATUS) & NPU_STATUS_DONE))
        ;
}

// ---- Tiling plan computation ----

int npu_tile_plan(int M, int N, int K, int prec, npu_tile_plan_t *plan) {
    plan->total_m = M;
    plan->total_n = N;
    plan->total_k = K;
    plan->prec = prec;
    plan->num_tiles = 0;

    int tiles_m = (M + NPU_MAX_M - 1) / NPU_MAX_M;
    int tiles_n = (N + NPU_MAX_N - 1) / NPU_MAX_N;
    int tiles_k = (K + NPU_MAX_K - 1) / NPU_MAX_K;

    for (int tm = 0; tm < tiles_m; tm++) {
        for (int tn = 0; tn < tiles_n; tn++) {
            for (int tk = 0; tk < tiles_k; tk++) {
                if (plan->num_tiles >= NPU_TILE_MAX_TILES)
                    return -1;

                npu_tile_t *t = &plan->tiles[plan->num_tiles];
                t->m_lo = tm * NPU_MAX_M;
                t->m_hi = t->m_lo + NPU_MAX_M;
                if (t->m_hi > M) t->m_hi = M;
                t->mc = t->m_hi - t->m_lo;

                t->n_lo = tn * NPU_MAX_N;
                t->n_hi = t->n_lo + NPU_MAX_N;
                if (t->n_hi > N) t->n_hi = N;
                t->nc = t->n_hi - t->n_lo;

                t->k_lo = tk * NPU_MAX_K;
                t->k_hi = t->k_lo + NPU_MAX_K;
                if (t->k_hi > K) t->k_hi = K;
                t->kc = t->k_hi - t->k_lo;

                t->is_first_k = (tk == 0);
                t->is_last_k  = (tk == tiles_k - 1);

                plan->num_tiles++;
            }
        }
    }
    return 0;
}

// ---- Execute one tile (internal helper) ----
// Copies A/B tiles from source matrices, triggers NPU, returns C in buf_c.
// The caller handles accumulation and scattering to the output matrix.
static void npu_tile_exec_one(int mc, int nc, int kc,
                              int m_lo, int n_lo, int k_lo,
                              int total_m, int total_n, int total_k, int prec,
                              unsigned int a_src, unsigned int b_src,
                              unsigned int buf_a, unsigned int buf_b,
                              unsigned int buf_c) {
    int es = npu_tile_elem_size(prec);

    // Copy A tile: A[m_lo:m_hi, k_lo:k_hi] -> buf_a
    // A is row-major with stride total_k
    for (int r = 0; r < mc; r++) {
        unsigned int src = a_src + (unsigned int)(m_lo + r) * total_k * es + k_lo * es;
        unsigned int dst = buf_a + r * kc * es;
        mem_copy(dst, (void *)src, kc * es);
    }

    // Copy B tile: B[k_lo:k_hi, n_lo:n_hi] -> buf_b
    // B is row-major with stride total_n
    for (int r = 0; r < kc; r++) {
        unsigned int src = b_src + (unsigned int)(k_lo + r) * total_n * es + n_lo * es;
        unsigned int dst = buf_b + r * nc * es;
        if (nc < NPU_MAX_N) {
            // Zero-pad the trailing columns so the NPU reads zeros
            volatile unsigned char *d = (volatile unsigned char *)dst;
            const unsigned char *s = (const unsigned char *)src;
            for (int c = 0; c < nc * es; c++)
                d[c] = s[c];
            for (int c = nc * es; c < NPU_MAX_N * es; c++)
                d[c] = 0;
        } else {
            mem_copy(dst, (void *)src, nc * es);
        }
    }

    // Configure and trigger NPU
    csr_write(NPU_REG_DIM_M,  mc);
    csr_write(NPU_REG_DIM_N,  nc);
    csr_write(NPU_REG_DIM_K,  kc);
    csr_write(NPU_REG_A_BASE, buf_a);
    csr_write(NPU_REG_B_BASE, buf_b);
    csr_write(NPU_REG_C_BASE, buf_c);

    npu_trigger_and_wait();
}

// ---- High-level GEMM with tiling ----

void npu_tile_gemm(int M, int N, int K, int prec,
                   unsigned int a_src, unsigned int b_src,
                   unsigned int c_dst, unsigned int tmp_buf) {
    // Compute buffer offsets within tmp_buf
    int es = npu_tile_elem_size(prec);
    unsigned int buf_a   = tmp_buf;
    unsigned int buf_b   = tmp_buf + NPU_TILE_A_SIZE(NPU_MAX_M, NPU_MAX_K, es);
    unsigned int buf_c   = buf_b + NPU_TILE_B_SIZE(NPU_MAX_K, NPU_MAX_N, es);
    unsigned int buf_acc = buf_c + NPU_TILE_C_SIZE(NPU_MAX_M, NPU_MAX_N);

    // Zero the accumulation buffer
    {
        int acc_size = NPU_TILE_C_SIZE(NPU_MAX_M, NPU_MAX_N);
        volatile unsigned int *zero = (volatile unsigned int *)buf_acc;
        for (int i = 0; i < acc_size / 4; i++)
            zero[i] = 0;
    }

    // Compute tiling parameters
    int tiles_m = (M + NPU_MAX_M - 1) / NPU_MAX_M;
    int tiles_n = (N + NPU_MAX_N - 1) / NPU_MAX_N;
    int tiles_k = (K + NPU_MAX_K - 1) / NPU_MAX_K;

    // Set precision once (it doesn't change per tile)
    csr_write(NPU_REG_PREC, prec);
    { volatile unsigned int _b; _b = csr_read(NPU_REG_PREC); (void)_b; }

    for (int tm = 0; tm < tiles_m; tm++) {
        for (int tn = 0; tn < tiles_n; tn++) {
            // Zero accumulation buffer for this (m,n) output tile
            {
                int acc_size = NPU_TILE_C_SIZE(NPU_MAX_M, NPU_MAX_N);
                volatile unsigned int *zero = (volatile unsigned int *)buf_acc;
                for (int i = 0; i < acc_size / 4; i++)
                    zero[i] = 0;
            }

            int m_lo = tm * NPU_MAX_M;
            int m_hi = m_lo + NPU_MAX_M;
            if (m_hi > M) m_hi = M;
            int mc = m_hi - m_lo;

            int n_lo = tn * NPU_MAX_N;
            int n_hi = n_lo + NPU_MAX_N;
            if (n_hi > N) n_hi = N;
            int nc = n_hi - n_lo;

            // ---- K-tiling loop ----
            for (int tk = 0; tk < tiles_k; tk++) {
                int k_lo = tk * NPU_MAX_K;
                int k_hi = k_lo + NPU_MAX_K;
                if (k_hi > K) k_hi = K;
                int kc = k_hi - k_lo;

                // Copy A/B tiles, trigger NPU, result in buf_c
                npu_tile_exec_one(mc, nc, kc, m_lo, n_lo, k_lo,
                                  M, N, K, prec,
                                  a_src, b_src, buf_a, buf_b, buf_c);

                // Accumulate C into buf_acc (32-bit word addition)
                mem_add32(buf_acc, buf_c, mc * nc);
            }

            // Write accumulated result: scatter from contiguous buf_acc
            // to strided c_dst layout C[row][col] at c_dst + (row*N + col)*4
            for (int r = 0; r < mc; r++) {
                unsigned int dst = c_dst + (unsigned int)(m_lo + r) * N * 4 + n_lo * 4;
                unsigned int src = buf_acc + r * nc * 4;
                mem_copy(dst, (void *)src, nc * 4);
            }
        }
    }
}

// ---- Stats ----

void npu_tile_get_stats(npu_tile_stats_t *stats) {
    stats->cycles     = csr_read(NPU_REG_CYCLE);
    stats->dma_cycles = csr_read(NPU_REG_DMA_CT);
    stats->ops        = csr_read(NPU_REG_OP_CNT);
    stats->stalls     = csr_read(NPU_REG_STALL);
}
