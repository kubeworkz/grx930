/*
 * pta_tile_model.h - C reference for the PTA tile's error model (phase C1).
 *
 * doc/pta_error_model_design_note.md section 4 is the contract.
 * rtl/pta/c930_ptm_c.sv implements the same steps, and sim/tb_core_verilator.cc
 * holds the two to bitwise agreement.  Plain C99 with 64-bit integers only, so
 * grxcp and grxgpu can vendor it (grxcp pta_program_plan.md, decision D1).
 *
 * Every stochastic term comes from seeded xorshift32 streams consumed in the
 * core's loop order.  THERMAL, SHOT and PROG_ERR reload at each GEMM start, so
 * for them a result is a function of the configuration, the tile's geometry
 * and the operands alone.  Drift is device state: it persists across GEMMs
 * until a model reset, so a drifting GEMM also depends on the GEMMs run since
 * then, which a pta_device carries from one pta_gemm() call to the next.
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
#define PTA_DRIFT     0x08u
#define PTA_XTALK     0x10u
#define PTA_MZM_NL    0x20u   /* not built: the core refuses it */
#define PTA_PROG_ERR  0x40u

/* What a start samples.  Field meanings as the core's i_pta_* ports. */
typedef struct {
    uint32_t impair;       /* PTA_* bits */
    uint32_t act_bits;     /* B_a, 0 = unquantised */
    uint32_t w_bits;       /* B_w, 0 = unquantised */
    uint32_t adc_bits;     /* B_adc, 0 = no ADC quantisation */
    uint32_t adc_shift;    /* S: LSB_adc = 2^S, 0..40 */
    uint32_t seed;
    uint32_t sigma_th;     /* thermal sigma, Q8.8 ADC LSB (16 bits) */
    uint32_t k_shot;       /* shot coefficient k, Q8.8 (16 bits) */
    uint32_t sigma_pr;     /* programming-error sigma, Q8.8 weight LSB (16 bits) */
    uint32_t drift_sigma;  /* drift step sigma, Q8.8 weight LSB (16 bits) */
    uint32_t drift_log2;   /* log2 shots per drift step, 0..31 */
    uint32_t drift_max;    /* drift clamp, Q8.8 weight LSB (16 bits) */
    uint32_t xtalk;        /* crosstalk chi, Q0.8 (8 bits) */
} pta_cfg;

/* The core's NUM_ROWS, NUM_COLS, DIN_W and ACC_W. */
typedef struct {
    int rows, cols, din_w, acc_w;
} pta_tile;

/* One xorshift32 state per per-GEMM stochastic impairment. */
typedef struct {
    uint32_t thermal, shot, prog;
} pta_streams;

/*
 * What outlives a GEMM: every cell's drift, for both weight banks, with the
 * drift clock and its generator.  Initialise one per modelled tile.
 */
typedef struct {
    int      rows, cols;
    int32_t *drift[2];     /* Q8.8 weight LSB, row-major, rows x cols */
    uint32_t rng;
    uint32_t count;        /* shots counted since the last step */
} pta_device;

uint32_t pta_xorshift32(uint32_t s);
int32_t  pta_gauss(uint32_t s);                     /* (byte sum - 510) * 443 */
uint32_t pta_isqrt4(uint32_t a);                    /* S_ACT's root, a <= 2^23 */
int32_t  pta_quant(int32_t x, uint32_t bits, int din_w);

/* The device as the RTL leaves reset: no drift.  Returns 0, or -1 if out of memory. */
int      pta_device_init(pta_device *dev, const pta_tile *tile);
void     pta_device_free(pta_device *dev);

/* A model reset: drift and its clock to zero, its generator loads seed ^ K. */
void     pta_model_reset(pta_device *dev, uint32_t seed);

/* A shot starting in a GEMM with DRIFT set: count it, and step every cell when
 * the count reaches 2^drift_log2. */
void     pta_shot_start(pta_device *dev, const pta_cfg *cfg);

/* A GEMM start: every per-GEMM stream loads seed ^ K, or K if that is zero. */
void     pta_start(pta_streams *st, uint32_t seed);

/* One weight write: steps the PROG_ERR stream, returns e (Q.8 weight LSB). */
int32_t  pta_weight_write(pta_streams *st, const pta_cfg *cfg);

/* A cell's analog weight, Q.8 weight LSB: the DAC's level for w, plus its
 * programming error e and its drift d as the configuration enables them. */
int64_t  pta_analog_weight(const pta_cfg *cfg, int din_w, int32_t w, int32_t e, int32_t d);

/*
 * One captured element: tile->rows activations a[] (zero outside the K tile),
 * the column's analog weights wa[] from pta_analog_weight(), and kr, the rows
 * in the K tile, past which a row holds no weight for crosstalk.  Steps the
 * THERMAL and SHOT streams once each.  Returns out, the value added to the
 * running sum, reduced to tile->acc_w bits and sign-extended; *sat is set to 1
 * if the ADC clamped and 0 otherwise.
 */
int64_t  pta_element(pta_streams *st, const pta_cfg *cfg, const pta_tile *tile,
                     const int32_t *a, const int64_t *wa, int kr, int *sat);

/*
 * An integer GEMM, C = A * B with A M x K and B K x N (row-major), computed
 * with weight bank `bank` on device `dev`, walked in the core's order: N tile,
 * K tile (its weight writes, rows then columns), output row (a shot), column.
 * Each C element holds its acc_w-bit running sum, sign-extended.  Returns the
 * number of ADC saturations, or -1 if a dimension, the bank or the tile is out
 * of range.
 */
long     pta_gemm(const pta_cfg *cfg, const pta_tile *tile, pta_device *dev, int bank,
                  int M, int N, int K, const int32_t *A, const int32_t *B, int64_t *C);

#ifdef __cplusplus
}
#endif

#endif /* PTA_TILE_MODEL_H */
