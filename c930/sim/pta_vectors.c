/*
 * pta_vectors.c -- a frozen conformance suite for the PTA error model (G0).
 *
 * grxcp pta_program_plan.md, track G, step G0: `VX_tcu_fedp_analog`, vendoring
 * the c930 error model.  The model is already vendorable -- pta_tile_model.c is
 * C99 with <stdint.h> and <stdlib.h> and nothing else, as decision D1 asked --
 * but a header a second repository can compile is not the same as a contract it
 * can be held to.  This is that contract: a deterministic vector file emitted by
 * the model, which any implementation of it must reproduce bit for bit.
 *
 * WHY A VECTOR FILE AND NOT "RUN OUR BENCH".  The c930's P gates already hold
 * rtl/pta/c930_ptm_c.sv and pta_tile_model.c to bitwise agreement, and they are
 * the reason to believe the model.  They need Verilator, the RTL and a Windows
 * plus WSL build, none of which a SimX backend should have to stand up to check
 * its arithmetic.  So the gated model emits its answers once and they are
 * committed; a vendoring repository then needs a C compiler and nothing else.
 * The chain is: P gates hold the RTL to the model, this program emits the model,
 * the file holds whoever vendors it to the same place.
 *
 * WHAT IS COVERED.  One case per impairment and one with every impairment clear,
 * then the combinations the design note's section 4 says interact: thermal with
 * shot (both are per-shot noise on the same accumulator), drift with programming
 * error (both perturb the weight, one persistently), and crosstalk with a K tile
 * shorter than the array (the case where a row holds no weight).  Each case runs
 * a small GEMM at a fixed seed with operands from the file's own generator, so a
 * reader needs no operand data either.
 *
 * Drift is device state and the note says so: THERMAL, SHOT and PROG_ERR reload
 * at each GEMM start, but drift persists until a model reset.  The drift cases
 * therefore run TWO GEMMs and record both, because the second is the one that
 * can only be reproduced by a model that carries the state forward.  A vendored
 * copy that resets per GEMM passes the first and fails the second.
 *
 * Build and run, from c930/:
 *     make pta_vectors          regenerate sim/pta_vectors.txt
 *     make pta_vectors_check    the committed file still matches
 *
 * Standard C99.  No Verilator, no RTL, no C++.
 */
#include "pta_tile_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The c930's tile, which is what the model is gated against. */
#define T_ROWS  8
#define T_COLS  8
#define T_DIN_W 8
#define T_ACC_W 48

/* The file's format version.  Bump it when a field is added, never when a
 * number changes: a changed number is either a model fix or a regression, and
 * the point of the file is that it cannot be both silently. */
#define VEC_VERSION 1

/*
 * Operands, from the file's own generator so a reader needs no data.  The same
 * xorshift the model uses, with a different constant, and the [-7, 7] range the
 * chain and A2 gates use -- small enough that an 8-bit operand never saturates
 * on its way in, so a mismatch is the impairment and not the input.
 */
static void gen_operands(uint32_t seed, int32_t *v, int n)
{
    uint32_t s = seed ^ 0x2545f491u;
    int i;
    for (i = 0; i < n; i++) {
        s = pta_xorshift32(s);
        v[i] = (int32_t)(s % 15u) - 7;
    }
}

typedef struct {
    const char *name;
    const char *what;        /* why this case is in the suite */
    pta_cfg     cfg;
    int         M, N, K;
    int         bank;
    uint32_t    op_seed;
    int         gemms;       /* 2 where device state has to carry forward */
} vec_case;

/*
 * The suite.  A case is named for what it isolates, and `what` says why it is
 * here -- a case nobody can explain is a case nobody will maintain.
 */
static vec_case cases[] = {
    { "clear", "every impairment off: the model must be an exact integer GEMM",
      { 0 }, 4, 4, 8, 0, 1, 1 },

    { "quant-act", "activation quantisation alone, B_a = DIN_W - 4",
      { .impair = PTA_QUANT, .act_bits = T_DIN_W - 4, .seed = 1 },
      4, 4, 8, 0, 1, 1 },

    { "quant-w", "weight quantisation alone, B_w = DIN_W - 4",
      { .impair = PTA_QUANT, .w_bits = T_DIN_W - 4, .seed = 1 },
      4, 4, 8, 0, 1, 1 },

    { "quant-adc", "the ADC alone: B_adc with a non-zero shift, which is where"
                   " saturation lives",
      { .impair = PTA_QUANT, .adc_bits = 4, .adc_shift = 2, .seed = 1 },
      4, 4, 8, 0, 1, 1 },

    { "thermal", "thermal noise alone, one xorshift step per element",
      { .impair = PTA_THERMAL, .sigma_th = 0x0180, .seed = 7 },
      4, 4, 8, 0, 2, 1 },

    { "shot", "shot noise alone, whose sigma follows the signal",
      { .impair = PTA_SHOT, .k_shot = 0x0200, .seed = 7 },
      4, 4, 8, 0, 2, 1 },

    { "prog-err", "programming error alone: a per-weight-write perturbation,"
                  " reloaded at each start",
      { .impair = PTA_PROG_ERR, .sigma_pr = 0x0140, .seed = 3 },
      4, 4, 8, 0, 3, 1 },

    { "xtalk", "crosstalk alone, with K = rows so every row holds a weight",
      { .impair = PTA_XTALK, .xtalk = 0x14, .seed = 1 },
      4, 4, 8, 0, 4, 1 },

    { "xtalk-short-k", "crosstalk with K < rows, the case where a row holds no"
                       " weight and kr bounds the coupling",
      { .impair = PTA_XTALK, .xtalk = 0x14, .seed = 1 },
      4, 4, 5, 0, 4, 1 },

    { "thermal-shot", "both per-shot noises on one accumulator, which share the"
                      " element and must not share a stream",
      { .impair = PTA_THERMAL | PTA_SHOT, .sigma_th = 0x0180,
        .k_shot = 0x0200, .seed = 7 },
      4, 4, 8, 0, 2, 1 },

    { "drift", "drift alone, TWO GEMMs: it is device state and the second GEMM"
               " is the one a per-GEMM model gets wrong",
      { .impair = PTA_DRIFT, .drift_sigma = 0x0100, .drift_log2 = 2,
        .drift_max = 0x0800, .seed = 5 },
      4, 4, 8, 0, 5, 2 },

    { "drift-prog", "drift and programming error together: both perturb the"
                    " weight, one persistently and one per start",
      { .impair = PTA_DRIFT | PTA_PROG_ERR, .drift_sigma = 0x0100,
        .drift_log2 = 2, .drift_max = 0x0800, .sigma_pr = 0x0140, .seed = 5 },
      4, 4, 8, 0, 5, 2 },

    { "bank1", "the second weight bank, whose drift is its own",
      { .impair = PTA_DRIFT, .drift_sigma = 0x0100, .drift_log2 = 2,
        .drift_max = 0x0800, .seed = 5 },
      4, 4, 8, 1, 5, 2 },

    /*
     * Every impairment at once, at settings where each is still EXPRESSIBLE.
     * The first version of this case ran act_bits = w_bits = 4 with the ADC at
     * LSB 2, which collapsed the output onto a grid of 2 at a magnitude of about
     * 4 -- so a drift of one weight LSB could not move it, the two GEMMs came
     * back identical, and pta_vectors_check.c rejected the case.  A combined
     * case that cannot see drift cannot catch a copy that ignores drift.
     */
    { "all", "every impairment at once, at settings where each is still"
             " expressible: the case most likely to catch a subtle error",
      { .impair = PTA_QUANT | PTA_THERMAL | PTA_SHOT | PTA_DRIFT |
                  PTA_XTALK | PTA_PROG_ERR,
        .act_bits = T_DIN_W - 1, .w_bits = T_DIN_W - 1,
        .adc_bits = 12, .adc_shift = 0,
        .sigma_th = 0x0180, .k_shot = 0x0200, .sigma_pr = 0x0140,
        .drift_sigma = 0x0100, .drift_log2 = 2, .drift_max = 0x0800,
        .xtalk = 0x14, .seed = 11 },
      4, 4, 8, 0, 6, 2 },

    /*
     * The aggressive settings kept as a stress case, with gemms = 1 because it
     * is not claiming to see drift -- labelled rather than quietly dropped, so
     * the coarse corner is still covered and nothing pretends otherwise.
     */
    { "all-coarse", "the same impairments at settings coarse enough to collapse"
                    " the output: a stress corner, NOT drift-sensitive",
      { .impair = PTA_QUANT | PTA_THERMAL | PTA_SHOT | PTA_DRIFT |
                  PTA_XTALK | PTA_PROG_ERR,
        .act_bits = T_DIN_W - 4, .w_bits = T_DIN_W - 4,
        .adc_bits = 6, .adc_shift = 1,
        .sigma_th = 0x0180, .k_shot = 0x0200, .sigma_pr = 0x0140,
        .drift_sigma = 0x0100, .drift_log2 = 2, .drift_max = 0x0800,
        .xtalk = 0x14, .seed = 11 },
      4, 4, 8, 0, 6, 1 },

    { "wide", "a shape past one N tile and one K tile, so the loop order is"
              " exercised rather than assumed",
      { .impair = PTA_THERMAL | PTA_SHOT, .sigma_th = 0x0180,
        .k_shot = 0x0200, .seed = 7 },
      8, 12, 16, 0, 8, 1 },
};

#define NCASES ((int)(sizeof cases / sizeof cases[0]))

static void emit_cfg(FILE *f, const pta_cfg *c)
{
    /* Every field, named, in a fixed order: a reader must be able to build the
     * same configuration without this program. */
    fprintf(f, "cfg impair=0x%02x act_bits=%u w_bits=%u adc_bits=%u"
               " adc_shift=%u seed=%u\n",
            c->impair, c->act_bits, c->w_bits, c->adc_bits, c->adc_shift,
            c->seed);
    fprintf(f, "cfg sigma_th=0x%04x k_shot=0x%04x sigma_pr=0x%04x"
               " drift_sigma=0x%04x drift_log2=%u drift_max=0x%04x xtalk=0x%02x\n",
            c->sigma_th, c->k_shot, c->sigma_pr, c->drift_sigma,
            c->drift_log2, c->drift_max, c->xtalk);
    fprintf(f, "cfg trim_step=%u trim_max=%u\n", c->trim_step, c->trim_max);
}

/* Returns 0 on success, 1 if the model refused a case. */
static int run_case(FILE *f, const vec_case *vc)
{
    const pta_tile tile = { T_ROWS, T_COLS, T_DIN_W, T_ACC_W };
    pta_device dev;
    int32_t *A, *B;
    int64_t *C;
    int g, rc = 0;

    A = malloc((size_t)vc->M * vc->K * sizeof *A);
    B = malloc((size_t)vc->K * vc->N * sizeof *B);
    C = malloc((size_t)vc->M * vc->N * sizeof *C);
    if (!A || !B || !C) {
        fprintf(stderr, "out of memory\n");
        exit(2);
    }
    gen_operands(vc->op_seed, A, vc->M * vc->K);
    gen_operands(vc->op_seed ^ 0x9e3779b9u, B, vc->K * vc->N);

    if (pta_device_init(&dev, &tile) != 0) {
        fprintf(stderr, "pta_device_init failed\n");
        exit(2);
    }
    /* A model reset is where a drift case starts, so the state it carries is
     * the state the file describes and not whatever ran before. */
    pta_model_reset(&dev, vc->cfg.seed);

    fprintf(f, "\ncase %s\n", vc->name);
    fprintf(f, "why %s\n", vc->what);
    fprintf(f, "tile rows=%d cols=%d din_w=%d acc_w=%d\n",
            tile.rows, tile.cols, tile.din_w, tile.acc_w);
    fprintf(f, "shape M=%d N=%d K=%d bank=%d op_seed=%u gemms=%d\n",
            vc->M, vc->N, vc->K, vc->bank, vc->op_seed, vc->gemms);
    emit_cfg(f, &vc->cfg);

    for (g = 0; g < vc->gemms; g++) {
        long sats = pta_gemm(&vc->cfg, &tile, &dev, vc->bank,
                             vc->M, vc->N, vc->K, A, B, C);
        int i;
        if (sats < 0) {
            fprintf(f, "gemm %d REFUSED\n", g);
            rc = 1;
            continue;
        }
        fprintf(f, "gemm %d sats=%ld\n", g, sats);
        for (i = 0; i < vc->M * vc->N; i++)
            fprintf(f, "  c[%d] %lld\n", i, (long long)C[i]);
    }

    pta_device_free(&dev);
    free(A); free(B); free(C);
    return rc;
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "sim/pta_vectors.txt";
    FILE *f = fopen(path, "w");
    int i, refused = 0;

    if (!f) {
        fprintf(stderr, "cannot write %s\n", path);
        return 2;
    }

    fprintf(f, "# PTA error-model conformance vectors\n");
    fprintf(f, "# Emitted by sim/pta_vectors.c from sim/pta_tile_model.c, the\n");
    fprintf(f, "# model rtl/pta/c930_ptm_c.sv is held to bitwise by gates P0-P9\n");
    fprintf(f, "# (`make core_pta` in grx930).  Any implementation of the error\n");
    fprintf(f, "# model must reproduce every number below exactly.\n");
    fprintf(f, "#\n");
    fprintf(f, "# Operands come from this file's own generator: the model's\n");
    fprintf(f, "# xorshift32 seeded with op_seed ^ 0x2545f491 for A and\n");
    fprintf(f, "# op_seed ^ 0x2545f491 ^ 0x9e3779b9 for B, each value taken as\n");
    fprintf(f, "# (s %% 15) - 7.  So a reader needs no operand data.\n");
    fprintf(f, "#\n");
    fprintf(f, "# A case with gemms=2 runs two GEMMs after ONE model reset.\n");
    fprintf(f, "# Drift is device state, so the second GEMM is the one a model\n");
    fprintf(f, "# that resets per GEMM gets wrong.\n");
    fprintf(f, "version %d\n", VEC_VERSION);
    fprintf(f, "cases %d\n", NCASES);

    for (i = 0; i < NCASES; i++)
        refused += run_case(f, &cases[i]);

    fclose(f);
    printf("[G0] %s: %d cases", path, NCASES);
    if (refused)
        printf(", %d refused", refused);
    printf("\n");
    return refused ? 1 : 0;
}
