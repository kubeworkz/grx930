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
    v   = asr64((int64_t)x + ((int64_t)1 << (h - 1)), h);
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
    dev->rng      = K_DRIFT;
    dev->count    = 0;
    if (!dev->drift[0] || !dev->drift[1]) {
        pta_device_free(dev);
        return -1;
    }
    return 0;
}

void pta_device_free(pta_device *dev)
{
    free(dev->drift[0]);
    free(dev->drift[1]);
    dev->drift[0] = dev->drift[1] = NULL;
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

void pta_shot_start(pta_device *dev, const pta_cfg *cfg)
{
    const int64_t lim = (int64_t)cfg->drift_max;
    int b, i;
    if ((uint64_t)dev->count + 1u < (1ull << cfg->drift_log2)) {
        ++dev->count;
        return;
    }
    dev->count = 0;
    /* bank, then row, then column: row-major storage is that order */
    for (b = 0; b < 2; ++b)
        for (i = 0; i < dev->rows * dev->cols; ++i) {
            int64_t d = (int64_t)dev->drift[b][i] + gauss_step(&dev->rng, cfg->drift_sigma);
            if (d > lim)  d = lim;
            if (d < -lim) d = -lim;
            dev->drift[b][i] = (int32_t)d;
        }
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
    const int R  = tile->rows;
    const int NC = tile->cols;
    pta_streams st;
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

    pta_start(&st, cfg->seed);
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
                    e[r * NC + n] = pta_weight_write(&st, cfg);
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
                        wa[r] = pta_analog_weight(cfg, tile->din_w, w[r * NC + n], e[r * NC + n],
                                                  dev->drift[bank][r * NC + n]);
                    out   = pta_element(&st, cfg, tile, a, wa, kr, &sat);
                    *cell = sext((uint64_t)*cell + (uint64_t)out, tile->acc_w);
                    sats += sat;
                }
            }
        }
    }

    free(w); free(e); free(a); free(wa);
    return sats;
}
