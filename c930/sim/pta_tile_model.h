/*
 * pta_tile_model.h - C reference for the PTA tile's error model (phase C1).
 *
 * doc/pta_error_model_design_note.md section 4 is the contract.
 * rtl/pta/c930_ptm_c.sv implements the same steps, and sim/tb_core_verilator.cc
 * holds the two to bitwise agreement.  Plain C99 with 64-bit integers only, so
 * grxcp and grxgpu can vendor it (grxcp pta_program_plan.md, decision D1).
 *
 * Every stochastic term comes from seeded xorshift32 streams, reloaded at each
 * GEMM start and consumed in the core's loop order, so an integer GEMM's
 * result is a function of the configuration, the tile's geometry and the
 * operands alone: pta_gemm() computes it exactly.
 */
#ifndef PTA_TILE_MODEL_H
#define PTA_TILE_MODEL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* PTA_IMPAIR bits (grxcp pta_cpu_integration.md section 3.1) */
#define PTA_QUANT     0x01u
#define PTA_THERMAL   0x02u
#define PTA_SHOT      0x04u
#define PTA_DRIFT     0x08u   /* not built yet: the core refuses it */
#define PTA_XTALK     0x10u   /* not built yet: the core refuses it */
#define PTA_MZM_NL    0x20u   /* not built yet: the core refuses it */
#define PTA_PROG_ERR  0x40u

/* What a start samples.  Field meanings as the core's i_pta_* ports. */
typedef struct {
    uint32_t impair;      /* PTA_* bits */
    uint32_t act_bits;    /* B_a, 0 = unquantised */
    uint32_t w_bits;      /* B_w, 0 = unquantised */
    uint32_t adc_bits;    /* B_adc, 0 = no ADC quantisation */
    uint32_t adc_shift;   /* S: LSB_adc = 2^S, 0..40 */
    uint32_t seed;
    uint32_t sigma_th;    /* thermal sigma, Q8.8 ADC LSB (16 bits) */
    uint32_t k_shot;      /* shot coefficient k, Q8.8 (16 bits) */
    uint32_t sigma_pr;    /* programming-error sigma, Q8.8 weight LSB (16 bits) */
} pta_cfg;

/* The core's NUM_ROWS, NUM_COLS, DIN_W and ACC_W. */
typedef struct {
    int rows, cols, din_w, acc_w;
} pta_tile;

/* One xorshift32 state per stochastic impairment. */
typedef struct {
    uint32_t thermal, shot, prog;
} pta_streams;

uint32_t pta_xorshift32(uint32_t s);
int32_t  pta_gauss(uint32_t s);                     /* (byte sum - 510) * 443 */
uint32_t pta_isqrt4(uint32_t a);                    /* S_ACT's root, a <= 2^23 */
int32_t  pta_quant(int32_t x, uint32_t bits, int din_w);

/* A GEMM start: every stream loads seed ^ K, or K if that is zero. */
void     pta_start(pta_streams *st, uint32_t seed);

/* One weight write: steps the PROG_ERR stream, returns e (Q.8 weight LSB). */
int32_t  pta_weight_write(pta_streams *st, const pta_cfg *cfg);

/*
 * One captured element: tile->rows activations a[] (zero outside the K tile),
 * the column's weights w[] and their stored errors e[].  Steps the THERMAL and
 * SHOT streams once each.  Returns out, the value added to the running sum,
 * reduced to tile->acc_w bits and sign-extended; *sat is set to 1 if the ADC
 * clamped and 0 otherwise.
 */
int64_t  pta_element(pta_streams *st, const pta_cfg *cfg, const pta_tile *tile,
                     const int32_t *a, const int32_t *w, const int32_t *e, int *sat);

/*
 * An integer GEMM, C = A * B with A M x K and B K x N (row-major), walked in
 * the core's order: N tile, K tile (its weight writes, rows then columns),
 * output row, column.  Each C element holds its acc_w-bit running sum,
 * sign-extended.  Returns the number of ADC saturations, or -1 if a dimension
 * or the tile is out of range.
 */
long     pta_gemm(const pta_cfg *cfg, const pta_tile *tile, int M, int N, int K,
                  const int32_t *A, const int32_t *B, int64_t *C);

#ifdef __cplusplus
}
#endif

#endif /* PTA_TILE_MODEL_H */
