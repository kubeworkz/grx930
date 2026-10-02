/*
 * pta_vectors_check.c -- the gate on G0's conformance suite.
 *
 * Diffing a file against the program that wrote it proves only that nothing
 * changed, which is worth having and is not a gate.  This checks four things,
 * and the last three are what stop the suite being a dump of numbers nobody can
 * refute:
 *
 *   1. REPRODUCIBLE.  Re-running the model reproduces the committed file
 *      exactly.  A diff, and the regression guard.
 *
 *   2. THE CLEAR CASE IS A GEMM.  With every impairment off the model must equal
 *      a plain integer A*B, computed here independently of pta_tile_model.c.
 *      If that fails, nothing else in the file means anything.
 *
 *   3. NO CASE IS VACUOUS.  Every impairment case must differ from the clear
 *      case at the same shape.  A case whose impairment changes nothing is a
 *      case that cannot catch a vendored copy ignoring that impairment, and a
 *      suite full of those passes anything.
 *
 *   4. DEVICE STATE CARRIES.  Every gemms=2 case must differ between its two
 *      GEMMs.  Drift persists until a model reset; a vendored copy that resets
 *      per GEMM has to fail here, and it only can if the case moves.
 *
 * Build and run, from c930/:
 *     make pta_vectors_check
 *
 * Standard C99.  No Verilator, no RTL, no C++ -- which is the point: this is the
 * check a vendoring repository can run.
 */
#include "pta_tile_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define T_ROWS  8
#define T_COLS  8
#define T_DIN_W 8
#define T_ACC_W 48

#define MAXC 4096

static int fails;

static void fail(const char *case_name, const char *what)
{
    printf("[G0] FAIL %-14s %s\n", case_name, what);
    fails++;
}

/* The same generator pta_vectors.c uses.  Duplicated on purpose: if it were
 * shared, a change to it would move the vectors and the check together. */
static void gen_operands(uint32_t seed, int32_t *v, int n)
{
    uint32_t s = seed ^ 0x2545f491u;
    int i;
    for (i = 0; i < n; i++) {
        s = pta_xorshift32(s);
        v[i] = (int32_t)(s % 15u) - 7;
    }
}

/*
 * A plain integer GEMM, written here and not taken from the model, so claim 2 is
 * an independent statement rather than the model agreeing with itself.
 */
static void int_gemm(int M, int N, int K, const int32_t *A, const int32_t *B,
                     int64_t *C)
{
    int m, n, kk;
    for (m = 0; m < M; m++)
        for (n = 0; n < N; n++) {
            int64_t acc = 0;
            for (kk = 0; kk < K; kk++)
                acc += (int64_t)A[m * K + kk] * B[kk * N + n];
            C[m * N + n] = acc;
        }
}

/* One parsed case: what the file says, and what the model says now. */
typedef struct {
    char     name[64];
    pta_cfg  cfg;
    int      M, N, K, bank, gemms;
    uint32_t op_seed;
    int64_t  file_c[2][MAXC];       /* per GEMM */
    long     file_sats[2];
    int      have[2];
} parsed;

static int parse(const char *path, parsed *out, int max, int *n_out)
{
    FILE *f = fopen(path, "r");
    char line[512];
    int n = -1, g = -1;

    if (!f) {
        printf("[G0] FAIL (file)        cannot read %s\n", path);
        return 1;
    }
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#')
            continue;
        if (!strncmp(line, "case ", 5)) {
            if (++n >= max) { fclose(f); return 1; }
            memset(&out[n], 0, sizeof out[n]);
            sscanf(line, "case %63s", out[n].name);
            g = -1;
            continue;
        }
        if (n < 0)
            continue;
        if (!strncmp(line, "shape ", 6)) {
            sscanf(line, "shape M=%d N=%d K=%d bank=%d op_seed=%u gemms=%d",
                   &out[n].M, &out[n].N, &out[n].K, &out[n].bank,
                   &out[n].op_seed, &out[n].gemms);
        } else if (!strncmp(line, "cfg impair=", 11)) {
            sscanf(line, "cfg impair=0x%x act_bits=%u w_bits=%u adc_bits=%u"
                         " adc_shift=%u seed=%u",
                   &out[n].cfg.impair, &out[n].cfg.act_bits, &out[n].cfg.w_bits,
                   &out[n].cfg.adc_bits, &out[n].cfg.adc_shift, &out[n].cfg.seed);
        } else if (!strncmp(line, "cfg sigma_th=", 13)) {
            sscanf(line, "cfg sigma_th=0x%x k_shot=0x%x sigma_pr=0x%x"
                         " drift_sigma=0x%x drift_log2=%u drift_max=0x%x xtalk=0x%x",
                   &out[n].cfg.sigma_th, &out[n].cfg.k_shot, &out[n].cfg.sigma_pr,
                   &out[n].cfg.drift_sigma, &out[n].cfg.drift_log2,
                   &out[n].cfg.drift_max, &out[n].cfg.xtalk);
        } else if (!strncmp(line, "cfg trim_step=", 14)) {
            sscanf(line, "cfg trim_step=%u trim_max=%u",
                   &out[n].cfg.trim_step, &out[n].cfg.trim_max);
        } else if (!strncmp(line, "gemm ", 5)) {
            long s;
            if (sscanf(line, "gemm %d sats=%ld", &g, &s) == 2 && g >= 0 && g < 2) {
                out[n].file_sats[g] = s;
                out[n].have[g] = 1;
            }
        } else if (!strncmp(line, "  c[", 4)) {
            int idx;
            long long v;
            if (g >= 0 && g < 2 &&
                sscanf(line, "  c[%d] %lld", &idx, &v) == 2 &&
                idx >= 0 && idx < MAXC)
                out[n].file_c[g][idx] = (int64_t)v;
        }
    }
    fclose(f);
    *n_out = n + 1;
    return 0;
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "sim/pta_vectors.txt";
    const pta_tile tile = { T_ROWS, T_COLS, T_DIN_W, T_ACC_W };
    static parsed cs[64];
    int ncase = 0, i, g, e;
    const parsed *clear = NULL;

    if (parse(path, cs, 64, &ncase))
        return 2;
    printf("[G0] %s: %d cases\n", path, ncase);
    if (ncase == 0) {
        printf("[G0] FAIL (file)        no cases parsed\n");
        return 2;
    }

    for (i = 0; i < ncase; i++) {
        parsed *c = &cs[i];
        int32_t *A = malloc((size_t)c->M * c->K * sizeof *A);
        int32_t *B = malloc((size_t)c->K * c->N * sizeof *B);
        int64_t *C = malloc((size_t)c->M * c->N * sizeof *C);
        pta_device dev;

        if (!A || !B || !C) { fprintf(stderr, "out of memory\n"); return 2; }
        gen_operands(c->op_seed, A, c->M * c->K);
        gen_operands(c->op_seed ^ 0x9e3779b9u, B, c->K * c->N);

        if (pta_device_init(&dev, &tile) != 0) {
            fprintf(stderr, "pta_device_init failed\n");
            return 2;
        }
        pta_model_reset(&dev, c->cfg.seed);

        /* ---- 1. reproducible ------------------------------------------- */
        for (g = 0; g < c->gemms; g++) {
            long sats = pta_gemm(&c->cfg, &tile, &dev, c->bank,
                                 c->M, c->N, c->K, A, B, C);
            if (!c->have[g]) { fail(c->name, "the file has no record of a GEMM"); continue; }
            if (sats != c->file_sats[g]) {
                char m[128];
                snprintf(m, sizeof m, "gemm %d saturations %ld, file says %ld",
                         g, sats, c->file_sats[g]);
                fail(c->name, m);
            }
            for (e = 0; e < c->M * c->N; e++)
                if (C[e] != c->file_c[g][e]) {
                    char m[160];
                    snprintf(m, sizeof m, "gemm %d c[%d] = %lld, file says %lld",
                             g, e, (long long)C[e], (long long)c->file_c[g][e]);
                    fail(c->name, m);
                    break;
                }
            /* Keep the last GEMM's values for claims 2 and 4. */
            memcpy(c->file_c[g], C, (size_t)c->M * c->N * sizeof *C);
        }

        /* ---- 2. the clear case is a plain integer GEMM ------------------ */
        if (c->cfg.impair == 0) {
            int64_t *R = malloc((size_t)c->M * c->N * sizeof *R);
            if (!R) { fprintf(stderr, "out of memory\n"); return 2; }
            int_gemm(c->M, c->N, c->K, A, B, R);
            for (e = 0; e < c->M * c->N; e++)
                if (c->file_c[0][e] != R[e]) {
                    char m[160];
                    snprintf(m, sizeof m, "c[%d] = %lld but A*B is %lld:"
                             " the model with no impairment is not a GEMM", e,
                             (long long)c->file_c[0][e], (long long)R[e]);
                    fail(c->name, m);
                    break;
                }
            free(R);
            if (!clear) clear = c;
        }

        /* ---- 4. device state carries forward --------------------------- */
        if (c->gemms == 2) {
            int moved = 0;
            for (e = 0; e < c->M * c->N; e++)
                if (c->file_c[0][e] != c->file_c[1][e]) { moved = 1; break; }
            if (!moved)
                fail(c->name, "two GEMMs after one reset are identical, so this"
                              " case cannot catch a model that resets per GEMM");
        }

        pta_device_free(&dev);
        free(A); free(B); free(C);
    }

    /* ---- 3. no case is vacuous ----------------------------------------- */
    if (!clear) {
        fail("(suite)", "no case has every impairment clear, so there is nothing"
                        " to compare the others against");
    } else {
        for (i = 0; i < ncase; i++) {
            const parsed *c = &cs[i];
            int same = 1;
            if (c->cfg.impair == 0)
                continue;
            if (c->M != clear->M || c->N != clear->N || c->K != clear->K ||
                c->op_seed != clear->op_seed)
                continue;            /* a different shape or operands: not comparable */
            for (e = 0; e < c->M * c->N; e++)
                if (c->file_c[0][e] != clear->file_c[0][e]) { same = 0; break; }
            if (same)
                fail(c->name, "identical to the clear case, so its impairment"
                              " changes nothing and the case cannot catch a copy"
                              " that ignores it");
        }
    }

    if (fails) {
        printf("[G0] %d FAILURES\n", fails);
        return 1;
    }
    printf("[G0] all pass: reproducible, the clear case is a GEMM, no case is"
           " vacuous, and device state carries\n");
    return 0;
}
