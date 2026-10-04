/*
 * test_shim_pta.c -- npu_dpi_shim as a build WITH the tile.
 *
 * The tile build puts sim/pta_tile_model.c behind the shim's register map, and
 * the model is not what is under test here: the RTL is held to it by
 * `make core_pta_gates`, and it is held to its own frozen answers by
 * `make pta_vectors_check`.  What is new, and what can be wrong, is the path
 * between a register write and a pta_cfg field, between a DDR byte and an
 * operand, and between a 48-bit sum and the 32-bit word the DMA stores.
 *
 * So every impaired GEMM is run twice.  Once through the shim, as a driver
 * would: registers written, operands put in DDR, CTRL.START, C read back.  And
 * once by calling pta_gemm() directly with the configuration written out by
 * hand, on a second device that is taken through the same history.  They must
 * agree in every element.
 *
 * Two things keep that from being vacuous.  Each impaired case must differ
 * from the exact product somewhere, or a shim that ignored PTA_IMPAIR and ran
 * its exact loop would pass.  And drift is device state: the drift cases run
 * two GEMMs and require the second to differ from the first, so a shim that
 * rebuilt its tile per GEMM fails -- as does one whose MODEL_RST did nothing.
 *
 * Built by `make shim_test`, with -DNPU_DPI_WITH_PTA.  C99.
 */
#include "npu_dpi_shim.h"
#include "pta_tile_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int pass = 0, fail = 0;
static void check(const char *name, int cond)
{
    if (cond) { printf("  [PASS] %s\n", name); pass++; }
    else      { printf("  [FAIL] %s\n", name); fail++; }
}

/* This model's tile, written out again rather than read from the shim: the
 * test's reference must not take its geometry from the thing it is checking. */
static const pta_tile GEOM = { 4, 4, 16, 48 };

#define A_ADDR 0x1000u
#define B_ADDR 0x2000u
#define C_ADDR 0x3000u

static uint32_t rng_state = 0x1234567u;
static int32_t rnd(int lo, int hi)
{
    rng_state = pta_xorshift32(rng_state);
    return lo + (int32_t)(rng_state % (uint32_t)(hi - lo + 1));
}

static void put8(uint32_t addr, int32_t v)
{
    npu_dpi_mem_write(addr & ~3u, ((uint32_t)(uint8_t)v) << (8 * (addr & 3u)), 1u << (addr & 3u));
}

static int32_t get32(uint32_t addr)
{
    uint32_t v = 0;
    int i;
    for (i = 0; i < 4; i++) v |= ((uint32_t)npu_dpi_mem_read(addr + (uint32_t)i)) << (8 * i);
    return (int32_t)v;
}

/* Operands into DDR in the precision's packing, and into the host's arrays. */
static void load(int32_t *A, int32_t *B, int m, int n, int k, uint32_t prec, int lo, int hi)
{
    int i;
    for (i = 0; i < m * k; i++) A[i] = rnd(lo, hi);
    for (i = 0; i < k * n; i++) B[i] = rnd(lo, hi);
    if (prec == NPU_PREC_INT16) {
        for (i = 0; i < m * k; i++) { put8(A_ADDR + 2u * i, A[i]); put8(A_ADDR + 2u * i + 1, A[i] >> 8); }
        for (i = 0; i < k * n; i++) { put8(B_ADDR + 2u * i, B[i]); put8(B_ADDR + 2u * i + 1, B[i] >> 8); }
    } else if (prec == NPU_PREC_INT4) {
        /* Two elements a byte, the even one in the low nibble. */
        for (i = 0; i < m * k; i += 2)
            put8(A_ADDR + (uint32_t)(i / 2),
                 (A[i] & 0xF) | ((i + 1 < m * k ? A[i + 1] & 0xF : 0) << 4));
        for (i = 0; i < k * n; i += 2)
            put8(B_ADDR + (uint32_t)(i / 2),
                 (B[i] & 0xF) | ((i + 1 < k * n ? B[i + 1] & 0xF : 0) << 4));
    } else {
        for (i = 0; i < m * k; i++) put8(A_ADDR + (uint32_t)i, A[i]);
        for (i = 0; i < k * n; i++) put8(B_ADDR + (uint32_t)i, B[i]);
    }
}

/* The registers a pta_cfg corresponds to, written as a driver writes them. */
static void program(const pta_cfg *c)
{
    npu_dpi_csr_write(NPU_CSR_PTA_IMPAIR, c->impair);
    npu_dpi_csr_write(NPU_CSR_PTA_BITS, c->act_bits | (c->w_bits << 4) | (c->adc_bits << 8) |
                                        (c->adc_shift << 12));
    npu_dpi_csr_write(NPU_CSR_PTA_SEED, c->seed);
    npu_dpi_csr_write(NPU_CSR_PTA_SIGMA_TH, c->sigma_th);
    npu_dpi_csr_write(NPU_CSR_PTA_SIGMA_SH, c->k_shot);
    npu_dpi_csr_write(NPU_CSR_PTA_SIGMA_PR, c->sigma_pr);
    npu_dpi_csr_write(NPU_CSR_PTA_DRIFT, c->drift_sigma | (c->drift_log2 << 16));
    npu_dpi_csr_write(NPU_CSR_PTA_XTALK, c->xtalk);
    npu_dpi_csr_write(NPU_CSR_PTA_DRIFT_MAX, c->drift_max);
}

/* One GEMM through the shim.  Returns STATUS afterwards. */
static uint32_t launch(int m, int n, int k, uint32_t prec)
{
    npu_dpi_run_gemm((uint32_t)m, (uint32_t)n, (uint32_t)k, prec, A_ADDR, B_ADDR, C_ADDR);
    return npu_dpi_csr_read(NPU_CSR_STATUS);
}

static void exact(const int32_t *A, const int32_t *B, int m, int n, int k, int32_t *C)
{
    int i, j, p;
    for (i = 0; i < m; i++)
        for (j = 0; j < n; j++) {
            int64_t s = 0;
            for (p = 0; p < k; p++) s += (int64_t)A[i * k + p] * B[p * n + j];
            C[i * n + j] = (int32_t)s;
        }
}

typedef struct {
    const char *name;
    pta_cfg     cfg;
    uint32_t    prec;
    int         lo, hi;      /* operand range */
    int         gemms;       /* 2 where drift has to carry */
} tcase;

#define M 8
#define N 9          /* three N tiles, the last one a single column */
#define K 14         /* four K tiles, the last one two rows */

int main(void)
{
    /* B_a 13 and B_w 14 of a 16-bit word are 5 and 6 bits of an INT8 operand,
     * which sits in the low byte: the quantiser works on the top of DIN_W.  An
     * 8-bit setting here would round every INT8 operand to zero. */
    static const tcase cases[] = {
        { "quant",   { PTA_QUANT, 13, 14, 6, 11, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
          NPU_PREC_INT8, -128, 127, 1 },
        { "thermal", { PTA_QUANT | PTA_THERMAL, 0, 0, 7, 10, 2, 256, 0, 0, 0, 0, 0, 0, 0, 0 },
          NPU_PREC_INT8, -128, 127, 1 },
        { "shot",    { PTA_QUANT | PTA_SHOT, 0, 0, 7, 10, 3, 0, 148, 0, 0, 0, 0, 0, 0, 0 },
          NPU_PREC_INT8, -128, 127, 1 },
        { "prog",    { PTA_PROG_ERR, 0, 0, 0, 0, 4, 0, 0, 1024, 0, 0, 0, 0, 0, 0 },
          NPU_PREC_INT8, -128, 127, 1 },
        { "xtalk",   { PTA_XTALK, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 26, 0, 0 },
          NPU_PREC_INT8, -128, 127, 1 },
        { "drift",   { PTA_DRIFT, 0, 0, 0, 0, 6, 0, 0, 0, 512, 0, 0x0C00, 0, 0, 0 },
          NPU_PREC_INT8, -128, 127, 2 },
        { "all",     { 0x5F, 14, 14, 7, 10, 7, 64, 47, 256, 256, 2, 0x0C00, 5, 0, 0 },
          NPU_PREC_INT8, -128, 127, 2 },
        { "int16",   { PTA_QUANT | PTA_THERMAL, 6, 5, 7, 27, 8, 128, 0, 0, 0, 0, 0, 0, 0, 0 },
          NPU_PREC_INT16, -20000, 20000, 1 },
        { "int4",    { PTA_PROG_ERR | PTA_XTALK, 0, 0, 0, 0, 9, 0, 0, 512, 0, 0, 0, 40, 0, 0 },
          NPU_PREC_INT4, -8, 7, 1 },
    };
    const int ncases = (int)(sizeof cases / sizeof cases[0]);
    static int32_t A[M * K], B[K * N], Cx[M * N], first[M * N];
    static int64_t Cm[M * N];
    pta_device ref;
    uint32_t st, shots0, wload0;
    int ci, i, g;
    char name[160];

    printf("=== The build is a choice, and not this file's default ===\n");
    check("a fresh shim is the array", npu_dpi_tile() == NPU_DPI_TILE_NONE);
    check("an unknown kind is refused and changes nothing",
          npu_dpi_set_tile(7) == -1 && npu_dpi_tile() == NPU_DPI_TILE_NONE);
    check("the tile is accepted", npu_dpi_set_tile(NPU_DPI_TILE_MODEL) == 0);
    npu_dpi_init();
    check("and npu_dpi_init() does not undo it", npu_dpi_tile() == NPU_DPI_TILE_MODEL);

    printf("\n=== What the tile build says it is ===\n");
    /* By hand: 4 x 4, 16-bit operands, 48-bit sums; all but MZM_NL built,
     * twelve banks, 15 / 15 / 15 the widest bits; emulated, kind 3. */
    check("PTA_ID", npu_dpi_csr_read(NPU_CSR_PTA_ID) == 0x50544101u);
    check("CAPS0 is the same 4 x 4, 16 and 48",
          npu_dpi_csr_read(NPU_CSR_PTA_CAPS0) == 0xC1001004u);
    check("CAPS1: 0x5f built, twelve banks, 15/15/15",
          npu_dpi_csr_read(NPU_CSR_PTA_CAPS1) == 0x0FFF0C5Fu);
    check("CAPS2: emulated, kind 3, no engine and no stage",
          npu_dpi_csr_read(NPU_CSR_PTA_CAPS2) == 0x800C0000u);

    printf("\n=== The configuration registers, at the RTL's widths ===\n");
    npu_dpi_csr_write(NPU_CSR_PTA_SIGMA_TH, 0xFFFFFFFFu);
    npu_dpi_csr_write(NPU_CSR_PTA_SIGMA_SH, 0xFFFFFFFFu);
    npu_dpi_csr_write(NPU_CSR_PTA_SIGMA_PR, 0xFFFFFFFFu);
    npu_dpi_csr_write(NPU_CSR_PTA_DRIFT, 0xFFFFFFFFu);
    npu_dpi_csr_write(NPU_CSR_PTA_XTALK, 0xFFFFFFFFu);
    npu_dpi_csr_write(NPU_CSR_PTA_DRIFT_MAX, 0xFFFFFFFFu);
    check("the sigmas are 16 bits",
          npu_dpi_csr_read(NPU_CSR_PTA_SIGMA_TH) == 0xFFFFu &&
          npu_dpi_csr_read(NPU_CSR_PTA_SIGMA_SH) == 0xFFFFu &&
          npu_dpi_csr_read(NPU_CSR_PTA_SIGMA_PR) == 0xFFFFu);
    check("DRIFT is 21: a 16-bit sigma and a 5-bit log2",
          npu_dpi_csr_read(NPU_CSR_PTA_DRIFT) == 0x1FFFFFu);
    check("XTALK is 8, DRIFT_MAX is 16",
          npu_dpi_csr_read(NPU_CSR_PTA_XTALK) == 0xFFu &&
          npu_dpi_csr_read(NPU_CSR_PTA_DRIFT_MAX) == 0xFFFFu);
    npu_dpi_csr_write(NPU_CSR_PTA_CTRL, 0xFFFFFFFFu);
    check("CTRL keeps EN; MODEL_RST is a pulse and reads zero",
          npu_dpi_csr_read(NPU_CSR_PTA_CTRL) == 0x1u);

    printf("\n=== Unimpaired, the tile is the exact product ===\n");
    npu_dpi_init();
    load(A, B, M, N, K, NPU_PREC_INT8, -128, 127);
    exact(A, B, M, N, K, Cx);
    shots0 = npu_dpi_csr_read(NPU_CSR_PTA_SHOT_CT);
    wload0 = npu_dpi_csr_read(NPU_CSR_PTA_WLOAD_CT);
    st = launch(M, N, K, NPU_PREC_INT8);
    {
        int bad = 0;
        for (i = 0; i < M * N; i++) bad += (get32(C_ADDR + 4u * i) != Cx[i]);
        check("C is the integer GEMM, every element", st == 2 && bad == 0);
    }
    /* N = 9 over 4 columns is 3 N tiles, K = 14 over 4 rows is 4 K tiles. */
    check("12 programmings and 96 shots: one a tile, and M a tile",
          npu_dpi_csr_read(NPU_CSR_PTA_WLOAD_CT) - wload0 == 12u &&
          npu_dpi_csr_read(NPU_CSR_PTA_SHOT_CT) - shots0 == 96u);
    check("no saturation counted, STATUS.SAT clear",
          npu_dpi_csr_read(NPU_CSR_PTA_SAT_CT) == 0u &&
          (npu_dpi_csr_read(NPU_CSR_PTA_STATUS) & NPU_PTA_STATUS_SAT) == 0u);

    printf("\n=== Impaired: the registers against pta_gemm() called directly ===\n");
    for (ci = 0; ci < ncases; ci++) {
        const tcase *t = &cases[ci];
        int mism = 0, moved = 0, carried = 0, sat_ok = 1;

        /* Both tiles from reset, so each case's history is its own. */
        npu_dpi_init();
        if (pta_device_init(&ref, &GEOM) != 0) { check("reference device", 0); return 1; }
        load(A, B, M, N, K, t->prec, t->lo, t->hi);
        exact(A, B, M, N, K, Cx);
        program(&t->cfg);

        for (g = 0; g < t->gemms; g++) {
            long sats = pta_gemm(&t->cfg, &GEOM, &ref, 0, M, N, K, A, B, Cm);
            st = launch(M, N, K, t->prec);
            if (st != 2) mism = M * N;
            for (i = 0; i < M * N; i++) {
                const int32_t got = get32(C_ADDR + 4u * i);
                if (got != (int32_t)(uint32_t)(uint64_t)Cm[i]) mism++;
                if (got != Cx[i]) moved++;
                if (g == 0) first[i] = got;
                else if (got != first[i]) carried++;
            }
            if (npu_dpi_csr_read(NPU_CSR_PTA_SAT_CT) != (uint32_t)sats) sat_ok = 0;
            if (((npu_dpi_csr_read(NPU_CSR_PTA_STATUS) & NPU_PTA_STATUS_SAT) != 0) != (sats != 0))
                sat_ok = 0;
        }
        pta_device_free(&ref);

        snprintf(name, sizeof name, "%-8s the shim's C is pta_gemm()'s, all %d elements%s",
                 t->name, M * N * t->gemms, t->gemms > 1 ? " over two GEMMs" : "");
        check(name, mism == 0);
        snprintf(name, sizeof name, "%-8s and it is not the exact product (%d of %d moved)",
                 t->name, moved, M * N * t->gemms);
        check(name, moved > 0);
        snprintf(name, sizeof name, "%-8s PTA_SAT_CT and STATUS.SAT are the model's count",
                 t->name);
        check(name, sat_ok);
        if (t->gemms > 1) {
            snprintf(name, sizeof name,
                     "%-8s the second GEMM differs from the first: drift carried (%d moved)",
                     t->name, carried);
            check(name, carried > 0);
        }
    }

    printf("\n=== MODEL_RST returns the tile to a known state, and it is PTA_SEED's ===\n");
    {
        const tcase *t = &cases[5];          /* drift */
        static int32_t r1[M * N];
        int mism = 0, diff2 = 0, same3 = 0, same4 = 0;

        npu_dpi_init();
        if (pta_device_init(&ref, &GEOM) != 0) { check("reference device", 0); return 1; }
        load(A, B, M, N, K, t->prec, t->lo, t->hi);
        program(&t->cfg);

        /* A reset first.  It reloads the drift generator from PTA_SEED, which
         * is not where power-on leaves it, so this is a different tile from
         * the one the case above ran on -- and the reference has to agree. */
        npu_dpi_csr_write(NPU_CSR_PTA_CTRL, NPU_PTA_CTRL_MODEL_RST);
        pta_model_reset(&ref, t->cfg.seed);
        pta_gemm(&t->cfg, &GEOM, &ref, 0, M, N, K, A, B, Cm);
        launch(M, N, K, t->prec);
        for (i = 0; i < M * N; i++) {
            r1[i] = get32(C_ADDR + 4u * i);
            mism += (r1[i] != (int32_t)(uint32_t)(uint64_t)Cm[i]);
        }
        check("after MODEL_RST the shim's GEMM is pta_gemm()'s after pta_model_reset()",
              mism == 0);
        pta_device_free(&ref);

        launch(M, N, K, t->prec);
        for (i = 0; i < M * N; i++) diff2 += (get32(C_ADDR + 4u * i) != r1[i]);
        check("a second GEMM drifts away from it", diff2 > 0);

        npu_dpi_csr_write(NPU_CSR_PTA_CTRL, NPU_PTA_CTRL_MODEL_RST);
        launch(M, N, K, t->prec);
        for (i = 0; i < M * N; i++) same3 += (get32(C_ADDR + 4u * i) == r1[i]);
        check("and MODEL_RST brings the first one back, element for element",
              same3 == M * N);

        /* The same through a full reset, which clears DDR and the registers as
         * well: put the operands and the configuration back, then reset the
         * model to the same seed. */
        launch(M, N, K, t->prec);
        npu_dpi_init();
        for (i = 0; i < M * K; i++) put8(A_ADDR + (uint32_t)i, A[i]);
        for (i = 0; i < K * N; i++) put8(B_ADDR + (uint32_t)i, B[i]);
        program(&t->cfg);
        npu_dpi_csr_write(NPU_CSR_PTA_CTRL, NPU_PTA_CTRL_MODEL_RST);
        launch(M, N, K, t->prec);
        for (i = 0; i < M * N; i++) same4 += (get32(C_ADDR + 4u * i) == r1[i]);
        check("npu_dpi_init() leaves no drift behind either", same4 == M * N);
    }

    printf("\n=== The tile refuses what the core's tile refuses ===\n");
    npu_dpi_init();
    load(A, B, M, N, K, NPU_PREC_INT8, -128, 127);
    exact(A, B, M, N, K, Cx);
    launch(M, N, K, NPU_PREC_INT8);
    {
        static const struct { const char *what; uint32_t impair, bits, prec; } r[3] = {
            { "MZM_NL, which no build implements", PTA_QUANT | PTA_MZM_NL, 0x0000A600u, NPU_PREC_INT8 },
            { "an ADC shift of 41",                PTA_QUANT, (41u << 12) | 0x600u,   NPU_PREC_INT8 },
            { "an impairment at FP16",             PTA_THERMAL, 0x0000A700u,          NPU_PREC_FP16 },
        };
        for (i = 0; i < 3; i++) {
            npu_dpi_mem_write(C_ADDR, 0xA5, 1);
            shots0 = npu_dpi_csr_read(NPU_CSR_PTA_SHOT_CT);
            npu_dpi_csr_write(NPU_CSR_PTA_IMPAIR, r[i].impair);
            npu_dpi_csr_write(NPU_CSR_PTA_BITS, r[i].bits);
            st = launch(M, N, K, r[i].prec);
            snprintf(name, sizeof name, "%s: ERROR, no DONE, C untouched, no shot counted", r[i].what);
            check(name, st == 4 && npu_dpi_mem_read(C_ADDR) == 0xA5 &&
                        npu_dpi_csr_read(NPU_CSR_PTA_SHOT_CT) == shots0);
        }
    }
    npu_dpi_csr_write(NPU_CSR_PTA_IMPAIR, 0);
    npu_dpi_csr_write(NPU_CSR_PTA_BITS, 0);
    st = launch(M, N, K, NPU_PREC_INT8);
    check("and the next clean start clears the error and runs",
          st == 2 && get32(C_ADDR) == Cx[0]);

    printf("\n=== Back to the array ===\n");
    check("the array is accepted again", npu_dpi_set_tile(NPU_DPI_TILE_NONE) == 0);
    npu_dpi_init();
    check("CAPS1 and CAPS2 say nothing is built",
          npu_dpi_csr_read(NPU_CSR_PTA_CAPS1) == 0x00000C00u &&
          npu_dpi_csr_read(NPU_CSR_PTA_CAPS2) == 0u);
    for (i = 0; i < M * K; i++) put8(A_ADDR + (uint32_t)i, A[i]);
    for (i = 0; i < K * N; i++) put8(B_ADDR + (uint32_t)i, B[i]);
    npu_dpi_csr_write(NPU_CSR_PTA_IMPAIR, PTA_QUANT);
    st = launch(M, N, K, NPU_PREC_INT8);
    check("and an impairment is refused, as on any build with no tile", st == 4);
    shots0 = npu_dpi_csr_read(NPU_CSR_PTA_SHOT_CT);
    npu_dpi_csr_write(NPU_CSR_PTA_IMPAIR, 0);
    st = launch(M, N, K, NPU_PREC_INT8);
    check("a clean GEMM runs and counts no shots: there is no tile to shoot",
          st == 2 && npu_dpi_csr_read(NPU_CSR_PTA_SHOT_CT) == shots0);

    printf("\n=== RESULT: %d passed, %d failed ===\n", pass, fail);
    return fail;
}
