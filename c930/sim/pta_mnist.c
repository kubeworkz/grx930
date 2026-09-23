/*
 * pta_mnist.c - gate C1(a): the D3 network through the PTA tile's C reference.
 *
 * The network is grxcp's decision D3, a 784-100-10 MLP with ReLU on MNIST,
 * trained as Gorsline, Smith and Merkel trained theirs (arXiv:2105.00227,
 * section 4), whose Fig. 3(c) is the published accuracy-vs-bits curve the gate
 * compares against: Adam, softmax with cross entropy, batches of 32, the last
 * 10% of the training set held out, and training stopped at the first epoch
 * whose held-out accuracy does not improve (Keras' EarlyStopping defaults).
 * Weights and biases stay in [-1, 1], and the forward pass rounds the weights
 * with the contract's quantiser at the width under test.  One step differs:
 * the quantiser rounds weights inside +-2^-B to zero, which at B <= 3 is every
 * Glorot-initialised layer-1 weight, so a network at B bits starts from its
 * seed's network trained at B = D (--from) rather than from Glorot.
 *
 * Evaluation runs the test set through pta_gemm() in GEMMs the core accepts -
 * at most 64 rows, 256 inputs and 8 outputs, each with its own seed - with
 * layer 1 on weight bank 0 and layer 2 on bank 1.  Biases, ReLU and the hidden
 * layer's rescale to operands are the host's, and digital.
 *
 * doc/pta_error_model_design_note.md section 5 states the gate, and
 * sim/pta_mnist.sh runs it.  C99 and libm, single-threaded.
 *
 * C3's calibration is here too, on the host's side of the line: a probe GEMM
 * with zero weights and one-hot activations reads every cell's programming
 * error and drift at once, and the trim that answers it goes to the DAC.
 *
 *   pta_mnist selftest
 *   pta_mnist train --data DIR --din D --wbits B --seed S --out NET [--from NET]
 *   pta_mnist eval  --data DIR --net NET [options]        (pta_mnist help)
 */
#include "pta_tile_model.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N_IN        784
#define N_HID       100
#define N_OUT       10
#define N_ALL       60000
#define N_TRAIN     54000       /* validation_split = 0.1 holds out the last 6,000 */
#define N_TEST      10000
#define N_CAL_HID   10000       /* training images the hidden rescale is set on */
#define N_CAL_ADC   1000        /* and the ADC shifts */
#define CLIP_FRAC   1e-4        /* the fraction either may clip */
#define BATCH       32
#define MAX_EPOCHS  100

/* The core's NUM_ROWS, NUM_COLS, MAX_M, MAX_K, MAX_N and ACC_W. */
#define ROWS        8
#define COLS        8
#define MAX_M       64
#define MAX_K       256
#define MAX_N       8
#define ACC_W       48

/*
 * Drift runs at grxcp's EO-res point (pta_cpu_integration.md section 6.2):
 * 2,048 shots in each 25.6 us GEMM, flat out, with a step every 2^31 shots, so
 * the 46-hour test is 6,169 steps.  A fit puts a material's RMS drift at 46
 * hours on the upper reading of pta_material_scorecard.py's bracket and clamps
 * at twice that (design note section 5).
 */
#define SHOTS_PER_S 80000000.0
#define DRIFT_LOG2  31
#define TEST_HOURS  46.0
#define PI          3.14159265358979323846

static const char MAGIC[8] = "PTAMLP2";

typedef struct {
    int      n;
    uint8_t *x;                 /* n x 784 pixels */
    uint8_t *y;                 /* n labels */
} dataset;

typedef struct {
    char     magic[8];
    int      din, wbits, seed, epochs;
    int      from_bits, from_epochs;  /* the network it started from, or 0 */
    double   val_acc, test_acc; /* digital, on the quantised weights */
    float    w1[N_HID * N_IN];  /* row n: hidden unit n's input weights */
    float    b1[N_HID];
    float    w2[N_OUT * N_HID];
    float    b2[N_OUT];
} mlp;

/* The network as the host drives the tile. */
typedef struct {
    int      din;
    int32_t  w1[N_HID * N_IN];  /* weight operands, w * 2^(D-1) */
    int32_t  w2[N_OUT * N_HID];
    int64_t  b1[N_HID];         /* biases in their layer's output units */
    int64_t  b2[N_OUT];
    int      sh;                /* hidden rescale: a2 = round(h / 2^sh) */
} host_net;

/* ------------------------------------------------------------------------- */

static uint64_t splitmix64(uint64_t *s)
{
    uint64_t z = (*s += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

static double uniform01(uint64_t *s)
{
    return (double)(splitmix64(s) >> 11) * (1.0 / 9007199254740992.0);
}

/* Each GEMM's PTA_SEED, from the run's seed and the GEMM's index. */
static uint32_t gemm_seed(uint32_t base, uint32_t index)
{
    uint64_t s = ((uint64_t)base << 32) | index;
    return (uint32_t)(splitmix64(&s) >> 32);
}

/*
 * The contract's q(x, B) (design note section 4), kept apart from pta_quant()
 * so that training rounds as the contract does even when the model is built
 * ablated; selftest holds the two equal.
 */
static int32_t contract_quant(int32_t x, int bits, int din)
{
    int h;
    int64_t v, lim;
    if (bits == 0 || bits >= din)
        return x;
    h   = din - bits;
    v   = (int64_t)x + ((int64_t)1 << (h - 1));
    v   = v >= 0 ? (v >> h) : ~((~v) >> h);
    lim = (int64_t)1 << (bits - 1);
    if (v > lim - 1) v = lim - 1;
    if (v < -lim)    v = -lim;
    return (int32_t)(v * ((int64_t)1 << h));
}

/* A value in [-1, 1] as a D-bit operand at 2^(D-1) per unit, rounded half up
 * and saturated. */
static int32_t weight_operand(double w, int din)
{
    const double s = ldexp(1.0, din - 1);
    double v = floor(w * s + 0.5);
    if (v > s - 1.0) v = s - 1.0;
    if (v < -s)      v = -s;
    return (int32_t)v;
}

/* A pixel as a D-bit operand at 2^(D-1) - 1 per unit. */
static int32_t pixel_operand(uint8_t p, int din)
{
    const int64_t a_s = ((int64_t)1 << (din - 1)) - 1;
    return (int32_t)(((int64_t)p * a_s + 127) / 255);
}

/* round(v / 2^s) for v >= 0 */
static int64_t round_shift(int64_t v, int s)
{
    return s == 0 ? v : (v + ((int64_t)1 << (s - 1))) >> s;
}

static void quantise(const float *w, float *wq, int n, int din, int bits)
{
    const double s = ldexp(1.0, din - 1);
    int i;
    for (i = 0; i < n; ++i)
        wq[i] = (float)(contract_quant(weight_operand(w[i], din), bits, din) / s);
}

/* ------------------------------------------------------------------------- */

static uint8_t *read_file(const char *path, long *len)
{
    FILE *f = fopen(path, "rb");
    uint8_t *buf;
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    *len = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = (uint8_t *)malloc((size_t)*len + 1);
    if (buf && fread(buf, 1, (size_t)*len, f) != (size_t)*len) {
        free(buf);
        buf = NULL;
    }
    fclose(f);
    return buf;
}

static uint32_t be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

/* One MNIST split from its two uncompressed idx files. */
static int load_set(const char *dir, const char *images, const char *labels, int count, dataset *d)
{
    char path[1024];
    long li = 0, ll = 0;
    uint8_t *bi, *bl;
    snprintf(path, sizeof path, "%s/%s", dir, images);
    bi = read_file(path, &li);
    snprintf(path, sizeof path, "%s/%s", dir, labels);
    bl = read_file(path, &ll);
    if (!bi || !bl || li != 16 + (long)count * N_IN || ll != 8 + (long)count ||
        be32(bi) != 2051 || be32(bl) != 2049 || be32(bi + 4) != (uint32_t)count ||
        be32(bl + 4) != (uint32_t)count || be32(bi + 8) != 28 || be32(bi + 12) != 28) {
        fprintf(stderr, "pta_mnist: %s/%s and %s missing or not MNIST's\n", dir, images, labels);
        free(bi);
        free(bl);
        return -1;
    }
    d->n = count;
    d->x = (uint8_t *)malloc((size_t)count * N_IN);
    d->y = (uint8_t *)malloc((size_t)count);
    memcpy(d->x, bi + 16, (size_t)count * N_IN);
    memcpy(d->y, bl + 8, (size_t)count);
    free(bi);
    free(bl);
    return 0;
}

/* ------------------------------------------------------------------------- */

/* The network on quantised weights, as a digital computer runs it. */
static int classify(const float *wq1, const float *b1, const float *wq2, const float *b2,
                    const uint8_t *px)
{
    float x[N_IN], h[N_HID], z, best_z = 0.0f;
    int nz[N_IN], cnt = 0, n, k, o, best = 0;
    for (k = 0; k < N_IN; ++k)
        if (px[k]) {
            nz[cnt]  = k;
            x[cnt++] = px[k] / 255.0f;
        }
    for (n = 0; n < N_HID; ++n) {
        const float *row = wq1 + n * N_IN;
        z = b1[n];
        for (k = 0; k < cnt; ++k)
            z += row[nz[k]] * x[k];
        h[n] = z > 0.0f ? z : 0.0f;
    }
    for (o = 0; o < N_OUT; ++o) {
        z = b2[o];
        for (n = 0; n < N_HID; ++n)
            z += wq2[o * N_HID + n] * h[n];
        if (o == 0 || z > best_z) {
            best_z = z;
            best   = o;
        }
    }
    return best;
}

static double digital_accuracy(const mlp *net, const float *wq1, const float *wq2,
                               const dataset *d, int first, int count)
{
    int i, right = 0;
    for (i = first; i < first + count; ++i)
        right += classify(wq1, net->b1, wq2, net->b2, d->x + (size_t)i * N_IN) == d->y[i];
    return 100.0 * right / count;
}

/* Keras' Adam (lr 1e-3, epsilon 1e-7), then the [-1, 1] constraint. */
static void adam(float *w, const float *g, float *m, float *v, int n, long t)
{
    const double b1 = 0.9, b2 = 0.999;
    const float lr_t = (float)(1e-3 * sqrt(1.0 - pow(b2, (double)t)) / (1.0 - pow(b1, (double)t)));
    int i;
    for (i = 0; i < n; ++i) {
        m[i] = 0.9f * m[i] + 0.1f * g[i];
        v[i] = 0.999f * v[i] + 0.001f * g[i] * g[i];
        w[i] -= lr_t * m[i] / (sqrt(v[i]) + 1e-7f);
        if (w[i] > 1.0f)  w[i] = 1.0f;
        if (w[i] < -1.0f) w[i] = -1.0f;
    }
}

/* Trains net at wbits, from Glorot or, if start is given, from start's weights. */
static void train(mlp *net, const dataset *tr, const dataset *te, int din, int wbits, int seed,
                  const mlp *start, int verbose)
{
    enum { P1 = N_HID * N_IN, P2 = N_OUT * N_HID };
    const double lim1 = sqrt(6.0 / (N_IN + N_HID)), lim2 = sqrt(6.0 / (N_HID + N_OUT));
    uint64_t ri = 0x243F6A8885A308D3ull ^ (uint64_t)(uint32_t)seed;                /* init */
    uint64_t rs = 0x13198A2E03707344ull ^ (uint64_t)(uint32_t)seed ^ ((uint64_t)wbits << 32);
    float *wq1 = (float *)malloc(P1 * sizeof(float)), *wq2 = (float *)malloc(P2 * sizeof(float));
    float *g1  = (float *)malloc(P1 * sizeof(float)), *g2  = (float *)malloc(P2 * sizeof(float));
    float *m1  = (float *)calloc(P1, sizeof(float)),  *v1  = (float *)calloc(P1, sizeof(float));
    float *m2  = (float *)calloc(P2, sizeof(float)),  *v2  = (float *)calloc(P2, sizeof(float));
    float gb1[N_HID], gb2[N_OUT], mb1[N_HID] = {0}, vb1[N_HID] = {0}, mb2[N_OUT] = {0}, vb2[N_OUT] = {0};
    int *order = (int *)malloc(N_TRAIN * sizeof(int));
    double best = -1.0;
    long t = 0;
    int i, epoch;

    memcpy(net->magic, MAGIC, sizeof MAGIC);
    net->din   = din;
    net->wbits = wbits;
    net->seed  = seed;
    if (start) {
        memcpy(net->w1, start->w1, sizeof net->w1);
        memcpy(net->b1, start->b1, sizeof net->b1);
        memcpy(net->w2, start->w2, sizeof net->w2);
        memcpy(net->b2, start->b2, sizeof net->b2);
        net->from_bits   = start->wbits;
        net->from_epochs = start->epochs;
    } else {
        for (i = 0; i < P1; ++i)
            net->w1[i] = (float)((2.0 * uniform01(&ri) - 1.0) * lim1);  /* Glorot uniform */
        for (i = 0; i < P2; ++i)
            net->w2[i] = (float)((2.0 * uniform01(&ri) - 1.0) * lim2);
        memset(net->b1, 0, sizeof net->b1);
        memset(net->b2, 0, sizeof net->b2);
    }
    for (i = 0; i < N_TRAIN; ++i)
        order[i] = i;

    for (epoch = 0; epoch < MAX_EPOCHS; ++epoch) {
        int start;
        for (i = N_TRAIN - 1; i > 0; --i) {
            const int j = (int)(splitmix64(&rs) % (uint64_t)(i + 1));
            const int s = order[i];
            order[i] = order[j];
            order[j] = s;
        }
        for (start = 0; start < N_TRAIN; start += BATCH) {
            const int bs = (N_TRAIN - start < BATCH) ? N_TRAIN - start : BATCH;
            int j;
            quantise(net->w1, wq1, P1, din, wbits);
            quantise(net->w2, wq2, P2, din, wbits);
            memset(g1, 0, P1 * sizeof(float));
            memset(g2, 0, P2 * sizeof(float));
            memset(gb1, 0, sizeof gb1);
            memset(gb2, 0, sizeof gb2);
            for (j = 0; j < bs; ++j) {
                const int idx = order[start + j];
                const uint8_t *px = tr->x + (size_t)idx * N_IN;
                float x[N_IN], z1[N_HID], h[N_HID], z2[N_OUT], dz2[N_OUT], zmax, sum;
                int nz[N_IN], cnt = 0, n, k, o;
                for (k = 0; k < N_IN; ++k)
                    if (px[k]) {
                        nz[cnt]  = k;
                        x[cnt++] = px[k] / 255.0f;
                    }
                for (n = 0; n < N_HID; ++n) {
                    const float *row = wq1 + n * N_IN;
                    float z = net->b1[n];
                    for (k = 0; k < cnt; ++k)
                        z += row[nz[k]] * x[k];
                    z1[n] = z;
                    h[n]  = z > 0.0f ? z : 0.0f;
                }
                zmax = -1e30f;
                for (o = 0; o < N_OUT; ++o) {
                    float z = net->b2[o];
                    for (n = 0; n < N_HID; ++n)
                        z += wq2[o * N_HID + n] * h[n];
                    z2[o] = z;
                    if (z > zmax)
                        zmax = z;
                }
                sum = 0.0f;
                for (o = 0; o < N_OUT; ++o)
                    sum += (float)exp(z2[o] - zmax);
                for (o = 0; o < N_OUT; ++o) {
                    const float p = (float)exp(z2[o] - zmax) / sum;
                    dz2[o] = (p - (o == tr->y[idx] ? 1.0f : 0.0f)) / (float)bs;
                    gb2[o] += dz2[o];
                    for (n = 0; n < N_HID; ++n)
                        g2[o * N_HID + n] += dz2[o] * h[n];
                }
                /* straight through: the rounded weights carry the gradient back,
                 * and it lands on the real-valued ones */
                for (n = 0; n < N_HID; ++n) {
                    float dh = 0.0f;
                    float *row;
                    if (z1[n] <= 0.0f)
                        continue;
                    for (o = 0; o < N_OUT; ++o)
                        dh += wq2[o * N_HID + n] * dz2[o];
                    gb1[n] += dh;
                    row = g1 + n * N_IN;
                    for (k = 0; k < cnt; ++k)
                        row[nz[k]] += dh * x[k];
                }
            }
            ++t;
            adam(net->w1, g1, m1, v1, P1, t);
            adam(net->b1, gb1, mb1, vb1, N_HID, t);
            adam(net->w2, g2, m2, v2, P2, t);
            adam(net->b2, gb2, mb2, vb2, N_OUT, t);
        }
        quantise(net->w1, wq1, P1, din, wbits);
        quantise(net->w2, wq2, P2, din, wbits);
        net->val_acc = digital_accuracy(net, wq1, wq2, tr, N_TRAIN, N_ALL - N_TRAIN);
        net->epochs  = epoch + 1;
        if (verbose)
            fprintf(stderr, "  epoch %d: held out %.2f%%\n", epoch + 1, net->val_acc);
        if (net->val_acc > best)
            best = net->val_acc;
        else if (epoch > 0)
            break;
    }
    net->test_acc = digital_accuracy(net, wq1, wq2, te, 0, N_TEST);

    free(wq1); free(wq2); free(g1); free(g2);
    free(m1); free(v1); free(m2); free(v2);
    free(order);
}

/* ------------------------------------------------------------------------- */

/* The weight operands as the DAC holds them at B bits. */
static void quant_weights(const host_net *hn, int wbits, int32_t *q1, int32_t *q2)
{
    int i;
    for (i = 0; i < N_HID * N_IN; ++i)
        q1[i] = contract_quant(hn->w1[i], wbits, hn->din);
    for (i = 0; i < N_OUT * N_HID; ++i)
        q2[i] = contract_quant(hn->w2[i], wbits, hn->din);
}

/* One image through the network in integers, with no tile, on weights from
 * quant_weights(): the sums the tile computes exactly when only QUANT's
 * operand quantisers are on.  q(0, B) is 0, so zero inputs are skipped. */
static void direct_image(const host_net *hn, const int32_t *q1, const int32_t *q2, int abits,
                         const int32_t *a1, int64_t *y1, int32_t *a2, int64_t *y2)
{
    const int D = hn->din;
    const int64_t amax = ((int64_t)1 << (D - 1)) - 1;
    int64_t xa[N_IN];
    int nz[N_IN], cnt = 0, n, k, o;
    for (k = 0; k < N_IN; ++k)
        if (a1[k]) {
            nz[cnt]   = k;
            xa[cnt++] = contract_quant(a1[k], abits, D);
        }
    for (n = 0; n < N_HID; ++n) {
        const int32_t *row = q1 + n * N_IN;
        int64_t s = 0, v;
        for (k = 0; k < cnt; ++k)
            s += xa[k] * row[nz[k]];
        y1[n] = s;
        v = s + hn->b1[n];
        v = round_shift(v > 0 ? v : 0, hn->sh);
        a2[n] = (int32_t)(v > amax ? amax : v);
    }
    for (o = 0; o < N_OUT; ++o) {
        int64_t s = 0;
        for (k = 0; k < N_HID; ++k)
            s += (int64_t)contract_quant(a2[k], abits, D) * q2[o * N_HID + k];
        y2[o] = s;
    }
}

typedef struct {
    int32_t A[MAX_M * MAX_K];
    int32_t B[MAX_K * MAX_N];
    int64_t C[MAX_M * MAX_N];
} gemm_buf;

/*
 * M images, their input operands a1 (M x 784), through the tile: y1 (M x 100)
 * and y2 (M x 10) are the GEMMs' sums before the biases, a2 the hidden
 * operands.  Every GEMM takes the next seed.  Returns ADC saturations, or -1.
 */
static long tile_batch(const host_net *hn, const pta_cfg cfg[2], const pta_tile *tile,
                       pta_device *dev, uint32_t seed, uint32_t *gemm, gemm_buf *g, int M,
                       const int32_t *a1, int64_t *y1, int32_t *a2, int64_t *y2)
{
    const int64_t amax = ((int64_t)1 << (hn->din - 1)) - 1;
    long sats = 0, r;
    int n0, k0, m, n, k;
    pta_cfg c;

    memset(y1, 0, (size_t)M * N_HID * sizeof *y1);
    for (n0 = 0; n0 < N_HID; n0 += MAX_N) {
        const int N = (N_HID - n0 < MAX_N) ? N_HID - n0 : MAX_N;
        for (k0 = 0; k0 < N_IN; k0 += MAX_K) {
            const int K = (N_IN - k0 < MAX_K) ? N_IN - k0 : MAX_K;
            for (m = 0; m < M; ++m)
                for (k = 0; k < K; ++k)
                    g->A[m * K + k] = a1[m * N_IN + k0 + k];
            for (k = 0; k < K; ++k)
                for (n = 0; n < N; ++n)
                    g->B[k * N + n] = hn->w1[(n0 + n) * N_IN + k0 + k];
            c      = cfg[0];
            c.seed = gemm_seed(seed, (*gemm)++);
            if ((r = pta_gemm(&c, tile, dev, 0, M, N, K, g->A, g->B, g->C)) < 0)
                return -1;
            sats += r;
            for (m = 0; m < M; ++m)
                for (n = 0; n < N; ++n)
                    y1[m * N_HID + n0 + n] += g->C[m * N + n];
        }
    }
    for (m = 0; m < M; ++m)
        for (n = 0; n < N_HID; ++n) {
            int64_t v = y1[m * N_HID + n] + hn->b1[n];
            v = round_shift(v > 0 ? v : 0, hn->sh);
            a2[m * N_HID + n] = (int32_t)(v > amax ? amax : v);
        }

    memset(y2, 0, (size_t)M * N_OUT * sizeof *y2);
    for (n0 = 0; n0 < N_OUT; n0 += MAX_N) {
        const int N = (N_OUT - n0 < MAX_N) ? N_OUT - n0 : MAX_N;
        for (k = 0; k < N_HID; ++k)
            for (n = 0; n < N; ++n)
                g->B[k * N + n] = hn->w2[(n0 + n) * N_HID + k];
        c      = cfg[1];
        c.seed = gemm_seed(seed, (*gemm)++);
        if ((r = pta_gemm(&c, tile, dev, 1, M, N, N_HID, a2, g->B, g->C)) < 0)
            return -1;
        sats += r;
        for (m = 0; m < M; ++m)
            for (n = 0; n < N; ++n)
                y2[m * N_OUT + n0 + n] += g->C[m * N + n];
    }
    return sats;
}

/*
 * C3's cell calibration, as X3 specifies it: probe with zero weights so that a
 * cell reports its programming error and its drift alone, and one-hot
 * activations so that every column reports at once.  `repeats` averages the
 * draws that do not persist -- programming error is redrawn at every weight
 * write, while drift stays -- and the trim that goes back is the negative of
 * what is left.
 *
 * The probe reads at the ADC's finest setting: a network's shift is calibrated
 * for sums thousands of units wide, and a cell's error is a handful.  A real
 * tile changes range the same way.
 */
static void calibrate_bank(pta_device *dev, const pta_cfg *cfg, const pta_tile *tile, int bank,
                           uint32_t seed, uint32_t *gemm, int repeats, gemm_buf *g)
{
    enum { PASSES = 3 };
    const int k = tile->rows, n = tile->cols;
    const int32_t probe = (int32_t)((((int64_t)1 << (tile->din_w - 1)) - 1));
    const int64_t pa = (cfg->impair & PTA_QUANT)
                     ? contract_quant(probe, (int)cfg->act_bits, tile->din_w) : probe;
    const int quantised = (cfg->impair & PTA_QUANT) && cfg->adc_bits != 0;
    const int64_t codes = quantised ? (((int64_t)1 << (cfg->adc_bits - 1)) - 1) : 0;
    int64_t sum[64], total[64];
    int64_t range = pa * (int64_t)cfg->trim_max / 256;   /* cover what a trim can hold */
    pta_cfg c = *cfg;
    int r, col, rep, pass, s_probe;

    if (k * n > (int)(sizeof sum / sizeof sum[0]) || pa == 0)
        return;
    for (r = 0; r < k * n; ++r)
        total[r] = 0;

    for (pass = 0; pass < PASSES; ++pass) {
        int64_t worst = 0;
        /* The probe picks its own range, as an instrument would: wide enough
         * for what is left to measure, and no wider. */
        for (s_probe = 0; quantised && s_probe < 40 && range > (codes << s_probe); ++s_probe)
            ;
        c.adc_shift = (uint32_t)(quantised ? s_probe : 0);
        for (r = 0; r < k * n; ++r)
            sum[r] = 0;
        memset(g->B, 0, (size_t)k * n * sizeof g->B[0]);            /* zero weights */
        for (rep = 0; rep < repeats; ++rep) {
            memset(g->A, 0, (size_t)k * k * sizeof g->A[0]);
            for (r = 0; r < k; ++r)
                g->A[r * k + r] = probe;                            /* one-hot rows */
            c.seed = gemm_seed(seed, (*gemm)++);
            if (pta_gemm(&c, tile, dev, bank, k, n, k, g->A, g->B, g->C) < 0)
                return;
            for (r = 0; r < k; ++r)
                for (col = 0; col < n; ++col)
                    sum[r * n + col] += g->C[r * n + col];
        }
        for (r = 0; r < k; ++r)
            for (col = 0; col < n; ++col) {
                /* out ~ q_a(probe) * (e + d + trim) / 256, so invert it and
                 * fold the answer into the trim this cell already holds */
                const int64_t avg = sum[r * n + col];
                const int64_t left = avg / repeats;
                total[r * n + col] += -(avg * 256) / (pa * repeats);
                total[r * n + col] = pta_trim_write(dev, cfg, bank, r, col, total[r * n + col]);
                if (left > worst)  worst = left;
                if (-left > worst) worst = -left;
            }
        if (!quantised)
            break;                      /* nothing to refine: the probe read it exactly */
        range = worst * 4 + 8;          /* next pass measures what this one left */
    }
}

/* ------------------------------------------------------------------------- */

/* The smallest shift s for which round(v / 2^s) <= lim. */
static int shift_needed(int64_t v, int64_t lim)
{
    int s = 0;
    while (round_shift(v, s) > lim)
        ++s;
    return s;
}

/* The smallest shift that clips no more than CLIP_FRAC of a histogram's count. */
static int shift_for(const long *hist, long total)
{
    long over = total;
    int s;
    for (s = 0; s < 63; ++s) {
        over -= hist[s];
        if (over <= (long)(CLIP_FRAC * total))
            return s;
    }
    return 63;
}

/*
 * The host's view of a trained network: operands, biases in output units, and
 * the hidden rescale set on training images with the weights as trained.
 */
static void host_setup(host_net *hn, const mlp *net, const dataset *tr)
{
    const int D = net->din;
    const double a_s = ldexp(1.0, D - 1) - 1.0, w_s = ldexp(1.0, D - 1);
    const int64_t amax = ((int64_t)1 << (D - 1)) - 1;
    long hist[64] = {0}, total = 0;
    int32_t a1[N_IN], a2[N_HID], *q1 = (int32_t *)malloc(N_HID * N_IN * sizeof(int32_t));
    int32_t q2[N_OUT * N_HID];
    int64_t y1[N_HID], y2[N_OUT];
    int i, n, k;

    hn->din = D;
    for (i = 0; i < N_HID * N_IN; ++i)
        hn->w1[i] = weight_operand(net->w1[i], D);
    for (i = 0; i < N_OUT * N_HID; ++i)
        hn->w2[i] = weight_operand(net->w2[i], D);
    for (n = 0; n < N_HID; ++n)
        hn->b1[n] = llround(net->b1[n] * a_s * w_s);
    hn->sh = 0;
    quant_weights(hn, net->wbits, q1, q2);
    for (i = 0; i < N_CAL_HID; ++i) {
        for (k = 0; k < N_IN; ++k)
            a1[k] = pixel_operand(tr->x[(size_t)i * N_IN + k], D);
        direct_image(hn, q1, q2, 0, a1, y1, a2, y2);
        for (n = 0; n < N_HID; ++n) {
            const int64_t v = y1[n] + hn->b1[n];
            if (v > 0) {
                ++hist[shift_needed(v, amax)];
                ++total;
            }
        }
    }
    hn->sh = shift_for(hist, total);
    for (n = 0; n < N_OUT; ++n)
        hn->b2[n] = llround(net->b2[n] * a_s * w_s / ldexp(1.0, hn->sh) * w_s);
    free(q1);
}

/*
 * Each layer's ADC shift for adc_bits B: the smallest that clips no more than
 * CLIP_FRAC of the K-tile sums, with the weights as trained, on training
 * images.  The ADC rounds a sum s to round(s / 2^S), which saturates past
 * 2^(B-1) - 1.
 */
static void adc_setup(const host_net *hn, const mlp *net, const dataset *tr, int adc_bits, int S[2])
{
    const int D = hn->din;
    const int64_t lim = ((int64_t)1 << (adc_bits - 1)) - 1;
    long hist[2][64] = {{0}}, total[2] = {0, 0};
    int32_t a1[N_IN], a2[N_HID], *q1 = (int32_t *)malloc(N_HID * N_IN * sizeof(int32_t));
    int32_t q2[N_OUT * N_HID];
    int64_t y1[N_HID], y2[N_OUT];
    int i, n, k, r;

    quant_weights(hn, net->wbits, q1, q2);
    for (i = 0; i < N_CAL_ADC; ++i) {
        for (k = 0; k < N_IN; ++k)
            a1[k] = pixel_operand(tr->x[(size_t)i * N_IN + k], D);
        direct_image(hn, q1, q2, 0, a1, y1, a2, y2);
        for (n = 0; n < N_HID; ++n)
            for (k = 0; k < N_IN; k += ROWS) {
                int64_t s = 0;
                for (r = k; r < k + ROWS && r < N_IN; ++r)
                    s += (int64_t)a1[r] * q1[n * N_IN + r];
                ++hist[0][shift_needed(s < 0 ? -s : s, lim)];
                ++total[0];
            }
        for (n = 0; n < N_OUT; ++n)
            for (k = 0; k < N_HID; k += ROWS) {
                int64_t s = 0;
                for (r = k; r < k + ROWS && r < N_HID; ++r)
                    s += (int64_t)a2[r] * q2[n * N_HID + r];
                ++hist[1][shift_needed(s < 0 ? -s : s, lim)];
                ++total[1];
            }
    }
    S[0] = shift_for(hist[0], total[0]);
    S[1] = shift_for(hist[1], total[1]);
    free(q1);
}

/* ------------------------------------------------------------------------- */

/* pta_material_scorecard.py's upper reading of a quadrature-biased modulator's
 * power swing, as phase, in LSBs of a 6-bit code over [0, pi]. */
static double drift_lsb6(double swing_db)
{
    const double r = pow(10.0, swing_db / 10.0);
    return asin(1.0 - 1.0 / r) / (PI / 64.0);
}

static uint64_t hours_to_steps(double hours)
{
    return (uint64_t)llround(hours * 3600.0 * SHOTS_PER_S / ldexp(1.0, DRIFT_LOG2));
}

/* A drift fit at 8-bit operands, where a 6-bit LSB is four weight LSB. */
static void drift_fit(pta_cfg *cfg, double swing_db)
{
    const double rms = 4.0 * drift_lsb6(swing_db);
    cfg->drift_log2  = DRIFT_LOG2;
    cfg->drift_sigma = (uint32_t)llround(rms * 256.0 / sqrt((double)hours_to_steps(TEST_HOURS)));
    cfg->drift_max   = (uint32_t)llround(2.0 * rms * 256.0);
}

/* ------------------------------------------------------------------------- */

static int load_net(const char *path, mlp *net)
{
    FILE *f = fopen(path, "rb");
    int ok = f && fread(net, sizeof *net, 1, f) == 1 && memcmp(net->magic, MAGIC, sizeof MAGIC) == 0;
    if (f)
        fclose(f);
    if (!ok)
        fprintf(stderr, "pta_mnist: %s is not a network this build wrote\n", path);
    return ok ? 0 : -1;
}

static const char *opt(int argc, char **argv, const char *name, const char *dflt)
{
    int i;
    for (i = 2; i + 1 < argc; i += 2)
        if (strcmp(argv[i], name) == 0)
            return argv[i + 1];
    return dflt;
}

static int check_opts(int argc, char **argv, const char *const *names)
{
    int i, j;
    for (i = 2; i < argc; i += 2) {
        int known = 0;
        for (j = 0; names[j]; ++j)
            known |= strcmp(argv[i], names[j]) == 0;
        if (!known || i + 1 >= argc) {
            fprintf(stderr, "pta_mnist: bad option %s (pta_mnist help)\n", argv[i]);
            return -1;
        }
    }
    return 0;
}

static int load_mnist(const char *dir, dataset *tr, dataset *te)
{
    if (load_set(dir, "train-images-idx3-ubyte", "train-labels-idx1-ubyte", N_ALL, tr) != 0 ||
        load_set(dir, "t10k-images-idx3-ubyte", "t10k-labels-idx1-ubyte", N_TEST, te) != 0)
        return -1;
    return 0;
}

static int cmd_train(int argc, char **argv)
{
    static const char *const names[] = {"--data", "--din", "--wbits", "--seed", "--out", "--from",
        "--verbose", NULL};
    const char *data = opt(argc, argv, "--data", NULL), *out = opt(argc, argv, "--out", NULL);
    const char *from = opt(argc, argv, "--from", NULL);
    const int din = atoi(opt(argc, argv, "--din", "16")), wbits = atoi(opt(argc, argv, "--wbits", "0"));
    const int seed = atoi(opt(argc, argv, "--seed", "1"));
    dataset tr, te;
    mlp *net, *start = NULL;
    FILE *f;
    if (check_opts(argc, argv, names) != 0 || !data || !out || (din != 8 && din != 16) ||
        wbits < 0 || wbits > din) {
        fprintf(stderr, "pta_mnist train: --data DIR --din 8|16 --wbits 0..D --seed S --out NET [--from NET]\n");
        return 2;
    }
    if (from) {
        start = (mlp *)calloc(1, sizeof *start);
        if (load_net(from, start) != 0)
            return 2;
        if (start->din != din || start->seed != seed) {
            fprintf(stderr, "pta_mnist: %s is not a DIN_W %d network of seed %d\n", from, din, seed);
            return 2;
        }
    }
    if (load_mnist(data, &tr, &te) != 0)
        return 2;
    net = (mlp *)calloc(1, sizeof *net);
    train(net, &tr, &te, din, wbits, seed, start, atoi(opt(argc, argv, "--verbose", "0")));
    f = fopen(out, "wb");
    if (!f || fwrite(net, sizeof *net, 1, f) != 1) {
        fprintf(stderr, "pta_mnist: cannot write %s\n", out);
        return 2;
    }
    fclose(f);
    printf("din=%d wbits=%d seed=%d from=%d from_epochs=%d epochs=%d held_out=%.2f digital=%.2f\n",
           din, wbits, seed, net->from_bits, net->from_epochs, net->epochs, net->val_acc, net->test_acc);
    return 0;
}

static int parse_impair(const char *s, uint32_t *bits)
{
    static const struct { const char *name; uint32_t bit; } tab[] = {
        {"quant", PTA_QUANT}, {"thermal", PTA_THERMAL}, {"shot", PTA_SHOT},
        {"drift", PTA_DRIFT}, {"xtalk", PTA_XTALK}, {"prog", PTA_PROG_ERR}};
    char buf[256], *tok;
    *bits = 0;
    if (strcmp(s, "none") == 0)
        return 0;
    snprintf(buf, sizeof buf, "%s", s);
    for (tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        size_t i;
        int found = 0;
        for (i = 0; i < sizeof tab / sizeof tab[0]; ++i)
            if (strcmp(tok, tab[i].name) == 0) {
                *bits |= tab[i].bit;
                found = 1;
            }
        if (!found)
            return -1;
    }
    return 0;
}

static int q88(const char *what, double v, uint32_t max, uint32_t *field)
{
    const double f = floor(v * 256.0 + 0.5);
    if (v < 0.0 || f > (double)max) {
        fprintf(stderr, "pta_mnist: %s %g does not fit its field\n", what, v);
        return -1;
    }
    *field = (uint32_t)f;
    return 0;
}

static int cmd_eval(int argc, char **argv)
{
    static const char *const names[] = {"--data", "--net", "--images", "--seed", "--impair",
        "--wbits", "--abits", "--adcbits", "--thermal", "--photons", "--prog", "--xtalk",
        "--drift", "--hours", "--calibrate", "--trimstep", "--trimmax", "--post-hours", NULL};
    const char *data = opt(argc, argv, "--data", NULL), *path = opt(argc, argv, "--net", NULL);
    const char *drift = opt(argc, argv, "--drift", "none");
    const int images = atoi(opt(argc, argv, "--images", "10000"));
    const uint32_t seed = (uint32_t)strtoul(opt(argc, argv, "--seed", "1"), NULL, 0);
    const double photons = atof(opt(argc, argv, "--photons", "0"));
    const double hours = atof(opt(argc, argv, "--hours", "0"));
    const double post_hours = atof(opt(argc, argv, "--post-hours", "0"));
    const int calibrate = atoi(opt(argc, argv, "--calibrate", "0"));
    dataset tr, te;
    mlp *net = (mlp *)calloc(1, sizeof *net);
    host_net *hn = (host_net *)calloc(1, sizeof *hn);
    gemm_buf *g = (gemm_buf *)malloc(sizeof *g);
    pta_cfg cfg[2];
    pta_tile tile;
    pta_device dev;
    int32_t a1[MAX_M * N_IN], a2[MAX_M * N_HID];
    int64_t y1[MAX_M * N_HID], y2[MAX_M * N_OUT];
    uint32_t gemm = 0;
    uint64_t steps = 0, post_steps = 0;
    long sats = 0, elements = 0, r;
    int S[2] = {0, 0}, right = 0, base, m, k, o;

    if (check_opts(argc, argv, names) != 0 || !data || !path || images < 1 || images > N_TEST) {
        fprintf(stderr, "pta_mnist eval: --data DIR --net NET [options] (pta_mnist help)\n");
        return 2;
    }
    if (load_net(path, net) != 0 || load_mnist(data, &tr, &te) != 0)
        return 2;

    memset(cfg, 0, sizeof cfg);
    if (parse_impair(opt(argc, argv, "--impair", "quant"), &cfg[0].impair) != 0) {
        fprintf(stderr, "pta_mnist: --impair takes none or a list of quant,thermal,shot,prog,drift,xtalk\n");
        return 2;
    }
    cfg[0].w_bits   = (uint32_t)atoi(opt(argc, argv, "--wbits", "-1"));
    if ((int)cfg[0].w_bits < 0)
        cfg[0].w_bits = (uint32_t)net->wbits;
    cfg[0].act_bits = (uint32_t)atoi(opt(argc, argv, "--abits", "0"));
    cfg[0].adc_bits = (uint32_t)atoi(opt(argc, argv, "--adcbits", "0"));
    if (cfg[0].w_bits > 15 || cfg[0].act_bits > 15 || cfg[0].adc_bits > 15 ||
        q88("--thermal", atof(opt(argc, argv, "--thermal", "0")), 65535, &cfg[0].sigma_th) != 0 ||
        q88("--prog", atof(opt(argc, argv, "--prog", "0")), 65535, &cfg[0].sigma_pr) != 0 ||
        q88("--xtalk", atof(opt(argc, argv, "--xtalk", "0")), 255, &cfg[0].xtalk) != 0 ||
        (photons > 0.0 && q88("--photons", 1.0 / sqrt(photons), 65535, &cfg[0].k_shot) != 0) ||
        q88("--trimstep", atof(opt(argc, argv, "--trimstep", "0.25")), 65535, &cfg[0].trim_step) != 0 ||
        q88("--trimmax", atof(opt(argc, argv, "--trimmax", "128")), 1 << 30, &cfg[0].trim_max) != 0)
        return 2;
    if (strcmp(drift, "tflt") == 0 || strcmp(drift, "tfln") == 0) {
        if (net->din != 8) {
            fprintf(stderr, "pta_mnist: drift fits are in 8-bit weight LSB (design note section 7)\n");
            return 2;
        }
        drift_fit(&cfg[0], strcmp(drift, "tflt") == 0 ? 1.0 : 5.0);
        steps = hours_to_steps(hours);
        post_steps = hours_to_steps(post_hours);
    } else if (strcmp(drift, "none") != 0) {
        fprintf(stderr, "pta_mnist: --drift takes none, tflt or tfln\n");
        return 2;
    }

    host_setup(hn, net, &tr);
    if (cfg[0].adc_bits != 0)
        adc_setup(hn, net, &tr, (int)cfg[0].adc_bits, S);
    cfg[1]           = cfg[0];
    cfg[0].adc_shift = (uint32_t)S[0];
    cfg[1].adc_shift = (uint32_t)S[1];

    tile.rows  = ROWS;
    tile.cols  = COLS;
    tile.din_w = net->din;
    tile.acc_w = ACC_W;
    if (pta_device_init(&dev, &tile) != 0)
        return 2;
    pta_model_reset(&dev, seed);
    if (cfg[0].impair & PTA_DRIFT)
        pta_drift_age(&dev, &cfg[0], steps);
    if (calibrate > 0) {
        calibrate_bank(&dev, &cfg[0], &tile, 0, seed ^ 0xCA11B, &gemm, calibrate, g);
        calibrate_bank(&dev, &cfg[1], &tile, 1, seed ^ 0xCA11B, &gemm, calibrate, g);
    }
    if ((cfg[0].impair & PTA_DRIFT) && post_steps)
        pta_drift_age(&dev, &cfg[0], post_steps);

    for (base = 0; base < images; base += MAX_M) {
        const int M = (images - base < MAX_M) ? images - base : MAX_M;
        for (m = 0; m < M; ++m)
            for (k = 0; k < N_IN; ++k)
                a1[m * N_IN + k] = pixel_operand(te.x[(size_t)(base + m) * N_IN + k], net->din);
        if ((r = tile_batch(hn, cfg, &tile, &dev, seed, &gemm, g, M, a1, y1, a2, y2)) < 0) {
            fprintf(stderr, "pta_mnist: pta_gemm refused a GEMM\n");
            return 2;
        }
        sats += r;
        elements += (long)M * (N_HID * ((N_IN + ROWS - 1) / ROWS) + N_OUT * ((N_HID + ROWS - 1) / ROWS));
        for (m = 0; m < M; ++m) {
            int best = 0;
            for (o = 1; o < N_OUT; ++o)
                if (y2[m * N_OUT + o] + hn->b2[o] > y2[m * N_OUT + best] + hn->b2[best])
                    best = o;
            right += best == te.y[base + m];
        }
    }

    printf("din=%d net_wbits=%d net_seed=%d from=%d epochs=%d digital=%.2f impair=0x%02x wbits=%u abits=%u "
           "adcbits=%u S=%d,%d sh=%d thermal=%g photons=%g prog=%g xtalk=%g drift=%s hours=%g "
           "steps=%llu sigma_d=%u d_max=%u cal=%d trimstep=%g trimmax=%g post_hours=%g "
           "seed=%u images=%d correct=%d acc=%.2f sats=%ld elements=%ld\n",
           net->din, net->wbits, net->seed, net->from_bits, net->epochs, net->test_acc, cfg[0].impair, cfg[0].w_bits,
           cfg[0].act_bits, cfg[0].adc_bits, S[0], S[1], hn->sh, cfg[0].sigma_th / 256.0, photons,
           cfg[0].sigma_pr / 256.0, cfg[0].xtalk / 256.0, drift, hours, (unsigned long long)steps,
           cfg[0].drift_sigma, cfg[0].drift_max, calibrate, cfg[0].trim_step / 256.0,
           cfg[0].trim_max / 256.0, post_hours, seed, images, right, 100.0 * right / images, sats,
           elements);
    pta_device_free(&dev);
    return 0;
}

/* ------------------------------------------------------------------------- */

static int fail(const char *what)
{
    printf("selftest FAIL: %s\n", what);
    return 1;
}

static int cmd_selftest(void)
{
    static const int dins[2] = {8, 16};
    uint64_t rs = 12345;
    int di, bits, errors = 0;

    /* 1. training's quantiser is the model's */
    for (di = 0; di < 2; ++di) {
        const int D = dins[di];
        long bad = 0;
        int32_t x;
        for (bits = 0; bits <= 16; ++bits)
            for (x = -(1 << (D - 1)); x < (1 << (D - 1)); ++x)
                bad += contract_quant(x, bits, D) != pta_quant(x, (uint32_t)bits, D);
        printf("selftest: q(x, B) at D=%d, B=0..16, every x: %ld differ\n", D, bad);
        if (bad)
            errors += fail("training's quantiser differs from pta_quant()");
    }

    /* 2. aging is shot starts: 3 + steps * 2^k + 3 starts against 3 + age + 3,
     *    with the clamp reached */
    {
        static const uint32_t logs[3] = {0, 3, 5};
        const pta_tile tile = {ROWS, COLS, 8, ACC_W};
        int li;
        for (li = 0; li < 3; ++li) {
            pta_cfg cfg;
            pta_device d1, d2;
            const uint64_t steps = 57;
            uint64_t i;
            int b, c, same, clamped = 0;
            memset(&cfg, 0, sizeof cfg);
            cfg.impair      = PTA_DRIFT;
            cfg.drift_sigma = 3000;
            cfg.drift_max   = 9000;
            cfg.drift_log2  = logs[li];
            pta_device_init(&d1, &tile);
            pta_device_init(&d2, &tile);
            pta_model_reset(&d1, 0xC0FFEE);
            pta_model_reset(&d2, 0xC0FFEE);
            for (i = 0; i < 3; ++i) {
                pta_shot_start(&d1, &cfg);
                pta_shot_start(&d2, &cfg);
            }
            for (i = 0; i < (steps << logs[li]); ++i)
                pta_shot_start(&d1, &cfg);
            pta_drift_age(&d2, &cfg, steps);
            for (i = 0; i < 3; ++i) {
                pta_shot_start(&d1, &cfg);
                pta_shot_start(&d2, &cfg);
            }
            same = d1.rng == d2.rng && d1.count == d2.count;
            for (b = 0; b < 2; ++b)
                for (c = 0; c < ROWS * COLS; ++c) {
                    same &= d1.drift[b][c] == d2.drift[b][c];
                    clamped |= d1.drift[b][c] == 9000 || d1.drift[b][c] == -9000;
                }
            printf("selftest: %llu steps at 2^%u shots each against pta_drift_age(): %s, clamp %s\n",
                   (unsigned long long)steps, logs[li], same ? "same" : "DIFFERENT",
                   clamped ? "reached" : "NOT REACHED");
            if (!same || !clamped)
                errors += fail("pta_drift_age() is not the shot starts it stands for");
            pta_device_free(&d1);
            pta_device_free(&d2);
        }
    }

    /* 3. the GEMM walk: random operands through tile_batch() against the
     *    direct sums, all impairments clear and with QUANT's operand
     *    quantisers, at both widths, over a partial last batch */
    for (di = 0; di < 2; ++di) {
        const int D = dins[di];
        const int32_t lo = -(1 << (D - 1)), span = 1 << D;
        const pta_tile tile = {ROWS, COLS, D, ACC_W};
        host_net *hn = (host_net *)calloc(1, sizeof *hn);
        gemm_buf *g = (gemm_buf *)malloc(sizeof *g);
        int32_t a1[MAX_M * N_IN], a2[MAX_M * N_HID], d_a2[N_HID];
        int32_t *q1 = (int32_t *)malloc(N_HID * N_IN * sizeof(int32_t)), q2[N_OUT * N_HID];
        int64_t y1[MAX_M * N_HID], y2[MAX_M * N_OUT], d_y1[N_HID], d_y2[N_OUT];
        int pass, i, m, bad = 0;
        pta_device dev;
        pta_device_init(&dev, &tile);
        hn->din = D;
        for (i = 0; i < N_HID * N_IN; ++i)
            hn->w1[i] = lo + (int32_t)(splitmix64(&rs) % (uint64_t)span);
        for (i = 0; i < N_OUT * N_HID; ++i)
            hn->w2[i] = lo + (int32_t)(splitmix64(&rs) % (uint64_t)span);
        for (i = 0; i < N_HID; ++i)
            hn->b1[i] = (int64_t)(splitmix64(&rs) % (1ull << (2 * D + 6))) - (1ll << (2 * D + 5));
        hn->sh = D + 3;
        for (pass = 0; pass < 2; ++pass) {
            pta_cfg cfg[2];
            uint32_t gemm = 0;
            const int M = 37;
            memset(cfg, 0, sizeof cfg);
            if (pass == 1) {
                cfg[0].impair   = PTA_QUANT;
                cfg[0].w_bits   = 3;
                cfg[0].act_bits = (uint32_t)D - 3;
            }
            cfg[1] = cfg[0];
            for (i = 0; i < M * N_IN; ++i)
                a1[i] = (int32_t)(splitmix64(&rs) % (uint64_t)(1 << (D - 1)));
            if (tile_batch(hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, y1, a2, y2) < 0)
                ++bad;
            quant_weights(hn, (int)cfg[0].w_bits, q1, q2);
            for (m = 0; m < M; ++m) {
                direct_image(hn, q1, q2, (int)cfg[0].act_bits, a1 + m * N_IN, d_y1, d_a2, d_y2);
                bad += memcmp(d_y1, y1 + m * N_HID, sizeof d_y1) != 0;
                bad += memcmp(d_a2, a2 + m * N_HID, sizeof d_a2) != 0;
                bad += memcmp(d_y2, y2 + m * N_OUT, sizeof d_y2) != 0;
            }
            printf("selftest: D=%d %s, %d images in %u GEMMs against direct sums: %d differ\n", D,
                   pass ? "QUANT B_w=3 B_a=D-3" : "no impairments", M, gemm, bad);
        }
        if (bad)
            errors += fail("the GEMM walk does not compute the network");
        pta_device_free(&dev);
        free(hn);
        free(g);
        free(q1);
    }

    printf("selftest %s\n", errors ? "FAILED" : "passed");
    return errors ? 1 : 0;
}

static void help(void)
{
    printf("pta_mnist selftest\n"
           "pta_mnist train --data DIR --din 8|16 --wbits B --seed S --out NET [--from NET] [--verbose 1]\n"
           "pta_mnist eval  --data DIR --net NET [options]\n"
           "  --images N      first N test images (10000)\n"
           "  --seed S        model reset and per-GEMM seeds (1)\n"
           "  --impair LIST   none, or quant,thermal,shot,prog,drift,xtalk (quant)\n"
           "  --wbits B       weight bits (the network's)   --abits B   activation bits (0)\n"
           "  --adcbits B     ADC bits (0); each layer's shift is set on training images\n"
           "  --thermal X     thermal sigma, ADC LSB         --photons P  photons per ADC LSB\n"
           "  --prog X        programming sigma, weight LSB  --xtalk X    crosstalk chi\n"
           "  --drift tflt|tfln --hours H   drift fitted at EO-res, aged H hours\n"
           "  --calibrate M   C3's cell calibration after the ageing, averaging M probes\n"
           "  --trimstep X    the weight DAC's step below the weight LSB, in weight LSB (0.25)\n"
           "  --trimmax X     the trim's clamp, in weight LSB (128)\n"
           "  --post-hours H  age H more hours after calibrating, to see how long it holds\n"
           "DIR holds MNIST's four idx files, uncompressed.\n");
}

int main(int argc, char **argv)
{
    if (argc >= 2 && strcmp(argv[1], "selftest") == 0)
        return cmd_selftest();
    if (argc >= 2 && strcmp(argv[1], "train") == 0)
        return cmd_train(argc, argv);
    if (argc >= 2 && strcmp(argv[1], "eval") == 0)
        return cmd_eval(argc, argv);
    help();
    return argc >= 2 && strcmp(argv[1], "help") == 0 ? 0 : 2;
}
