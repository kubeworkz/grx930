/*
 * pta_tile_model.c - C reference for the PTA tile's error model (phase C1).
 * See pta_tile_model.h and doc/pta_error_model_design_note.md section 4.
 *
 * Arithmetic shifts of negative values are written out (asr64), because C
 * leaves them to the implementation, and nothing wider than 64 bits is needed:
 * where the RTL forms an 80-bit z, the ADC's floor division is split so both
 * halves stay in range (see pta_element).
 */
#include "pta_tile_model.h"

#include <stdlib.h>

#define K_THERMAL 0x9E3779B9u
#define K_SHOT    0x3C6EF372u
#define K_PROG    0xDAA66D2Bu
#define K_DRIFT   0x78DDE6E4u

/* floor(x / 2^s), for 0 <= s <= 62 */
static int64_t asr64(int64_t x, int s)
{
    return x >= 0 ? (x >> s) : ~((~x) >> s);
}

/* The low w bits of u, sign-extended. */
static int64_t sext(uint64_t u, int w)
{
    const uint64_t mask = (w >= 64) ? ~0ull : ((1ull << w) - 1u);
    u &= mask;
    if (w < 64 && ((u >> (w - 1)) & 1u))
        u |= ~mask;
    return (int64_t)u;
}

uint32_t pta_xorshift32(uint32_t s)
{
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

int32_t pta_gauss(uint32_t s)
{
    const int32_t g = (int32_t)((s >> 24) & 0xFFu) + (int32_t)((s >> 16) & 0xFFu) +
                      (int32_t)((s >> 8) & 0xFFu)  + (int32_t)(s & 0xFFu) - 510;
    return g * 443;
}

uint32_t pta_isqrt4(uint32_t a)
{
    static const uint32_t T4[4] = {2048u, 2896u, 3547u, 4096u};
    int p, e, seg;
    uint32_t t, lo, hi, rn;
    if (a == 0)
        return 0;
    p = 31;
    while (((a >> p) & 1u) == 0)
        --p;
    e   = p >> 1;
    t   = (a << (22 - 2 * e)) & 0xFFFFFFu;
    seg = (int)(t >> 22) - 1;
    lo  = T4[seg];
    hi  = T4[seg + 1];
    rn  = lo + (((hi - lo) * ((t >> 16) & 0x3Fu)) >> 6);
    return rn >> (11 - e);
}

int32_t pta_quant(int32_t x, uint32_t bits, int din_w)
{
    int h;
    int64_t v, lim;
    if (bits == 0 || (int)bits >= din_w)
        return x;
    h   = din_w - (int)bits;
#ifdef PTA_MODEL_ABLATE_QROUND
    v   = asr64((int64_t)x, h);             /* ablation: no rounding term, as the RTL's */
#else
    v   = asr64((int64_t)x + ((int64_t)1 << (h - 1)), h);
#endif
    lim = (int64_t)1 << (bits - 1);
    if (v > lim - 1) v = lim - 1;
    if (v < -lim)    v = -lim;
    return (int32_t)(v * ((int64_t)1 << h));
}

static uint32_t stream_seed(uint32_t seed, uint32_t k)
{
    return (seed ^ k) == 0 ? k : (seed ^ k);
}

/* One Gaussian step of sigma (Q8.8) from a stream: (sigma * gs + 2^15) >>> 16. */
static int64_t gauss_step(uint32_t *s, uint32_t sigma)
{
    *s = pta_xorshift32(*s);
    return asr64((int64_t)sigma * pta_gauss(*s) + 32768, 16);
}

int pta_device_init(pta_device *dev, const pta_tile *tile)
{
    const size_t n = (size_t)tile->rows * (size_t)tile->cols;
    dev->rows     = tile->rows;
    dev->cols     = tile->cols;
    dev->drift[0] = (int32_t *)calloc(n, sizeof *dev->drift[0]);
    dev->drift[1] = (int32_t *)calloc(n, sizeof *dev->drift[1]);
    dev->trim[0]  = (int32_t *)calloc(n, sizeof *dev->trim[0]);
    dev->trim[1]  = (int32_t *)calloc(n, sizeof *dev->trim[1]);
    dev->gain     = (int32_t *)calloc((size_t)tile->cols, sizeof *dev->gain);
    dev->offs     = (int32_t *)calloc((size_t)tile->cols, sizeof *dev->offs);
    dev->rng      = K_DRIFT;
    dev->count    = 0;
    if (!dev->drift[0] || !dev->drift[1] || !dev->trim[0] || !dev->trim[1] ||
        !dev->gain || !dev->offs) {
        pta_device_free(dev);
        return -1;
    }
    pta_cal_reset(dev);
    return 0;
}

void pta_cal_reset(pta_device *dev)
{
    int b, i;
    for (b = 0; b < 2; ++b)
        for (i = 0; i < dev->rows * dev->cols; ++i)
            dev->trim[b][i] = 0;
    for (i = 0; i < dev->cols; ++i) {
        dev->gain[i] = 256;                      /* unity, Q8.8 */
        dev->offs[i] = 0;
    }
}

/* The DAC's own resolution: round away from zero at the half step.  Shared
 * with pta_cal_bank(), which needs to know whether a write will clamp. */
static int64_t trim_round(uint32_t step, int64_t v)
{
    const int64_t st = (int64_t)step;
    int64_t mag;
    if (st <= 1)
        return v;
    mag = v < 0 ? -v : v;
    mag = ((mag + st / 2) / st) * st;
    return v < 0 ? -mag : mag;
}

int32_t pta_trim_write(pta_device *dev, const pta_cfg *cfg, int bank, int row, int col,
                       int64_t q88)
{
    const int64_t lim  = (int64_t)cfg->trim_max;
    int64_t v = trim_round(cfg->trim_step, q88);
    if (v > lim)  v = lim;
    if (v < -lim) v = -lim;
    dev->trim[bank][row * dev->cols + col] = (int32_t)v;
    return (int32_t)v;
}

void pta_column_cal(pta_device *dev, int col, int32_t gain_q88, int32_t offs)
{
    dev->gain[col] = gain_q88;
    dev->offs[col] = offs;
}

int64_t pta_affine(const pta_device *dev, const pta_tile *tile, int col, int64_t out)
{
    const int64_t g = dev->gain[col];
    int64_t v = out;
    if (g != 256)
        v = asr64(v * g + 128, 8);
    v += dev->offs[col];
    return sext((uint64_t)v, tile->acc_w);
}

void pta_device_free(pta_device *dev)
{
    free(dev->drift[0]);
    free(dev->drift[1]);
    free(dev->trim[0]);
    free(dev->trim[1]);
    free(dev->gain);
    free(dev->offs);
    dev->drift[0] = dev->drift[1] = NULL;
    dev->trim[0] = dev->trim[1] = NULL;
    dev->gain = dev->offs = NULL;
}

/*
 * rtl/pta/c930_pta_cal.sv's engine, in C.  Every step is the RTL's: the same
 * probe, the same shot order, the same weight writes into the same streams, the
 * same estimator, the same auto-ranging.  Gate P8 holds the two to the same
 * trims, which is only possible because neither reloads a stream here.
 */
int64_t pta_cal_bank(pta_device *dev, const pta_cfg *cfg, const pta_tile *tile, int bank,
                     pta_streams *st, const pta_cal_cfg *cal, long *sats, int *clamped,
                     int64_t *found)
{
    const int R    = tile->rows;
    const int NC   = tile->cols;
    const int alog = (int)cal->amp_log2;
    const int rlog = (int)cal->reps_log2;
    const int quant = (cfg->impair & PTA_QUANT) != 0;
    /* q(x, B) is the identity on multiples of 2^h inside its range, so the
     * probe's amplitude has to be one: the engine refuses anything else. */
    const int h = (quant && cfg->act_bits != 0 && (int)cfg->act_bits < tile->din_w)
                ? tile->din_w - (int)cfg->act_bits : 0;
    const int quantised = quant && cfg->adc_bits != 0;
    const int64_t codes = quantised ? (((int64_t)1 << (cfg->adc_bits - 1)) - 1) : 0;
    const int32_t amp = (int32_t)1 << alog;
    int64_t *sum, *wa;
    int32_t *e, *a;
    int64_t range, worst = 0, resid = 0;
    pta_cfg c = *cfg;
    int pass, rep, r, n, shot, i;

    if (R < 1 || NC < 1 || bank < 0 || bank > 1 || cal->passes < 1 ||
        dev->rows != R || dev->cols != NC)
        return -1;
    if (alog > tile->din_w - 2 || alog < h)
        return -1;                               /* the engine's own refusal */

    sum = (int64_t *)calloc((size_t)R * (size_t)NC, sizeof *sum);
    wa  = (int64_t *)calloc((size_t)R, sizeof *wa);
    e   = (int32_t *)calloc((size_t)R * (size_t)NC, sizeof *e);
    a   = (int32_t *)calloc((size_t)R, sizeof *a);
    if (!sum || !wa || !e || !a) {
        free(sum); free(wa); free(e); free(a);
        return -1;
    }

    range = ((int64_t)cfg->trim_max << alog) >> 8;   /* what a trim can hold */
    for (pass = 0; pass < (int)cal->passes; ++pass) {
        int s = 0;
        while (quantised && s < 40 && range > (codes << s))
            ++s;
        c.adc_shift = (uint32_t)(quantised ? s : 0);
        for (i = 0; i < R * NC; ++i)
            sum[i] = 0;
        worst = 0;
        resid = 0;
        for (rep = 0; rep < (1 << rlog); ++rep) {
            /* S_WLOAD, every weight of the bank to zero: each write redraws
             * that cell's programming error, which is what averaging beats. */
            for (r = 0; r < R; ++r)
                for (n = 0; n < NC; ++n)
                    e[r * NC + n] = pta_weight_write(st, cfg);
            for (shot = 0; shot < R; ++shot) {
                if (cfg->impair & PTA_DRIFT)
                    pta_shot_start(dev, cfg);
                for (r = 0; r < R; ++r)
                    a[r] = (r == shot) ? amp : 0;
                for (n = 0; n < NC; ++n) {
                    int sat;
                    for (r = 0; r < R; ++r)
                        wa[r] = pta_analog_weight_t(cfg, tile->din_w, 0, e[r * NC + n],
                                                    dev->drift[bank][r * NC + n],
                                                    dev->trim[bank][r * NC + n]);
                    sum[shot * NC + n] += pta_affine(dev, tile, n,
                        pta_element(st, &c, tile, a, wa, R, &sat));
                    if (sats)
                        *sats += sat;
                }
            }
        }
        /* The estimator, row major, exactly the order the engine walks. */
        for (i = 0; i < R * NC; ++i) {
            const int64_t v    = sum[i];
            const int64_t mag  = v < 0 ? -v : v;
            const int64_t q    = (mag << 8) >> (alog + rlog);
            const int64_t left = mag >> rlog;
            int64_t req = (int64_t)dev->trim[bank][i] + (v < 0 ? q : -q);
            if (q > resid)    resid = q;
            if (left > worst) worst = left;
            if (req >  2147483647LL) req =  2147483647LL;   /* as the RTL saturates */
            if (req < -2147483648LL) req = -2147483648LL;
            if (clamped) {
                const int64_t rq = trim_round(cfg->trim_step, req);
                if (rq > (int64_t)cfg->trim_max || rq < -(int64_t)cfg->trim_max)
                    *clamped = 1;
            }
            pta_trim_write(dev, cfg, bank, i / NC, i % NC, req);
        }
        if (found && pass == 0)
            *found = resid > 0xFFFFFF ? 0xFFFFFF : resid;
        if (!quantised)
            break;                               /* the probe read it exactly */
        range = worst * 4 + 8;
    }

    free(sum); free(wa); free(e); free(a);
    return resid > 0xFFFFFF ? 0xFFFFFF : resid;  /* PTA_ERR_MAX is 24 bits */
}

void pta_model_reset(pta_device *dev, uint32_t seed)
{
    int b, i;
    for (b = 0; b < 2; ++b)
        for (i = 0; i < dev->rows * dev->cols; ++i)
            dev->drift[b][i] = 0;
    dev->rng   = stream_seed(seed, K_DRIFT);
    dev->count = 0;
}

/* One drift step: every cell of both banks. */
static void drift_step(pta_device *dev, const pta_cfg *cfg)
{
    const int64_t lim = (int64_t)cfg->drift_max;
    int b, i;
    /* bank, then row, then column: row-major storage is that order */
    for (b = 0; b < 2; ++b)
        for (i = 0; i < dev->rows * dev->cols; ++i) {
            int64_t d = (int64_t)dev->drift[b][i] + gauss_step(&dev->rng, cfg->drift_sigma);
            if (d > lim)  d = lim;
            if (d < -lim) d = -lim;
            dev->drift[b][i] = (int32_t)d;
        }
}

void pta_shot_start(pta_device *dev, const pta_cfg *cfg)
{
    if ((uint64_t)dev->count + 1u < (1ull << cfg->drift_log2)) {
        ++dev->count;
        return;
    }
    dev->count = 0;
    drift_step(dev, cfg);
}

void pta_drift_age(pta_device *dev, const pta_cfg *cfg, uint64_t steps)
{
    /* From a count c, 2^k shot starts step once and return the count to c, so
     * steps * 2^k of them are these steps with the count untouched. */
    while (steps-- > 0)
        drift_step(dev, cfg);
}

void pta_start(pta_streams *st, uint32_t seed)
{
    st->thermal = stream_seed(seed, K_THERMAL);
    st->shot    = stream_seed(seed, K_SHOT);
    st->prog    = stream_seed(seed, K_PROG);
}

int32_t pta_weight_write(pta_streams *st, const pta_cfg *cfg)
{
    return (int32_t)gauss_step(&st->prog, cfg->sigma_pr);
}

int64_t pta_analog_weight(const pta_cfg *cfg, int din_w, int32_t w, int32_t e, int32_t d)
{
    const int64_t wq = (cfg->impair & PTA_QUANT) ? pta_quant(w, cfg->w_bits, din_w) : w;
    return wq * 256 + ((cfg->impair & PTA_PROG_ERR) ? e : 0) + ((cfg->impair & PTA_DRIFT) ? d : 0);
}

int64_t pta_analog_weight_t(const pta_cfg *cfg, int din_w, int32_t w, int32_t e, int32_t d,
                            int32_t trim)
{
    return pta_analog_weight(cfg, din_w, w, e, d) + trim;
}

int64_t pta_element(pta_streams *st, const pta_cfg *cfg, const pta_tile *tile,
                    const int32_t *a, const int64_t *wa, int kr, int *sat)
{
    const int quant = (cfg->impair & PTA_QUANT) != 0;
    const int S     = (int)cfg->adc_shift;
    int64_t   y     = 0;
    int64_t   n_th, n_sh, nsum, out;
    uint64_t  v;
    int32_t   gs_th, gs_sh;
    int       r;

    for (r = 0; r < tile->rows; ++r) {
        const int64_t xa = quant ? pta_quant(a[r], cfg->act_bits, tile->din_w) : a[r];
        int64_t wx = wa[r];
        if (cfg->impair & PTA_XTALK) {
            /* the input's light also passes the neighbouring rows' rings */
            int64_t nb = 0;
            if (r > 0 && r - 1 < kr)
                nb += wa[r - 1];
            if (r < tile->rows - 1 && r + 1 < kr)
                nb += wa[r + 1];
            wx += asr64((int64_t)cfg->xtalk * nb + 128, 8);
        }
        y += xa * wx;                                       /* Q.8, tile units */
    }

    st->thermal = pta_xorshift32(st->thermal);
    st->shot    = pta_xorshift32(st->shot);
    gs_th       = pta_gauss(st->thermal);
    gs_sh       = pta_gauss(st->shot);

    v = (uint64_t)(y < 0 ? -y : y) >> S;                   /* Q.8, ADC LSB */
    if (v > 8388608u)
        v = 8388608u;
    n_th = asr64((int64_t)cfg->sigma_th * gs_th + 32768, 16);
    n_sh = asr64((int64_t)cfg->k_shot * (int64_t)pta_isqrt4((uint32_t)v) * gs_sh + 524288, 20);
    nsum = ((cfg->impair & PTA_THERMAL) ? n_th : 0) + ((cfg->impair & PTA_SHOT) ? n_sh : 0);

    *sat = 0;
    if (quant && cfg->adc_bits != 0) {
        /*
         * floor((y + nsum*2^S + 2^(7+S)) / 2^(8+S)) = floor((floor(y/2^S) + nsum + 2^7) / 2^8):
         * the remainder y - 2^S*floor(y/2^S) is below 2^S, so it cannot carry
         * the numerator past a multiple of 2^(8+S).
         */
        const int64_t lim = (int64_t)1 << (cfg->adc_bits - 1);
        int64_t tq = asr64(asr64(y, S) + nsum + 128, 8);
        if (tq > lim - 1) { tq = lim - 1; *sat = 1; }
        if (tq < -lim)    { tq = -lim;    *sat = 1; }
        out = tq * ((int64_t)1 << S);
    } else if (S >= 8) {
        /* nsum*2^S is a multiple of 2^8: it passes the floor untouched.  Only
         * the low acc_w bits survive, so the sum may wrap. */
        out = (int64_t)((uint64_t)asr64(y + 128, 8) + ((uint64_t)nsum << (S - 8)));
    } else {
        out = asr64(y + nsum * ((int64_t)1 << S) + 128, 8);
    }
    return sext((uint64_t)out, tile->acc_w);
}

long pta_gemm(const pta_cfg *cfg, const pta_tile *tile, pta_device *dev, int bank,
              int M, int N, int K, const int32_t *A, const int32_t *B, int64_t *C)
{
    pta_streams st;
    pta_start(&st, cfg->seed);
    return pta_gemm_st(&st, cfg, tile, dev, bank, M, N, K, A, B, C);
}

long pta_gemm_st(pta_streams *st, const pta_cfg *cfg, const pta_tile *tile, pta_device *dev,
                 int bank, int M, int N, int K, const int32_t *A, const int32_t *B, int64_t *C)
{
    const int R  = tile->rows;
    const int NC = tile->cols;
    int32_t *w, *e, *a;
    int64_t *wa;
    long sats = 0;
    int i, n_base, k_base, m, n, r;

    if (M < 1 || N < 1 || K < 1 || R < 1 || NC < 1 || tile->acc_w < 2 || tile->acc_w > 64 ||
        bank < 0 || bank > 1 || dev->rows != R || dev->cols != NC)
        return -1;
    w  = (int32_t *)calloc((size_t)R * (size_t)NC, sizeof *w);
    e  = (int32_t *)calloc((size_t)R * (size_t)NC, sizeof *e);
    a  = (int32_t *)calloc((size_t)R, sizeof *a);
    wa = (int64_t *)calloc((size_t)R, sizeof *wa);
    if (!w || !e || !a || !wa) {
        free(w); free(e); free(a); free(wa);
        return -1;
    }

    for (i = 0; i < M * N; ++i)
        C[i] = 0;

    for (n_base = 0; n_base < N; n_base += NC) {
        const int nc = (N - n_base < NC) ? N - n_base : NC;
        for (k_base = 0; k_base < K; k_base += R) {
            const int kr = (K - k_base < R) ? K - k_base : R;
            /* S_WLOAD: this tile's weights, row by row */
            for (r = 0; r < kr; ++r)
                for (n = 0; n < nc; ++n) {
                    w[r * NC + n] = B[(k_base + r) * N + n_base + n];
                    e[r * NC + n] = pta_weight_write(st, cfg);
                }
            for (m = 0; m < M; ++m) {
                /* One shot.  Rows past the K tile carry no activation, and no
                 * weight for crosstalk, so their stale values never matter. */
                if (cfg->impair & PTA_DRIFT)
                    pta_shot_start(dev, cfg);
                for (r = 0; r < R; ++r)
                    a[r] = (r < kr) ? A[m * K + k_base + r] : 0;
                for (n = 0; n < nc; ++n) {
                    int sat;
                    int64_t out;
                    int64_t *cell = &C[m * N + n_base + n];
                    for (r = 0; r < R; ++r)
                        wa[r] = pta_analog_weight_t(cfg, tile->din_w, w[r * NC + n],
                                                    e[r * NC + n],
                                                    dev->drift[bank][r * NC + n],
                                                    dev->trim[bank][r * NC + n]);
                    /* the affine belongs to the column's receiver, which is
                     * the tile's column n, not the GEMM's n_base + n */
                    out   = pta_affine(dev, tile, n,
                                       pta_element(st, cfg, tile, a, wa, kr, &sat));
                    *cell = sext((uint64_t)*cell + (uint64_t)out, tile->acc_w);
                    sats += sat;
                }
            }
        }
    }

    free(w); free(e); free(a); free(wa);
    return sats;
}
