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
 * A network may have more hidden layers than D3's one (train --hidden H), each
 * 100 wide: layer l runs on weight bank l & 1, and each hidden layer has its own
 * rescale.  At one hidden layer everything here is what it was -- the files,
 * the trained weights and every output line -- and deeper ones are how the
 * budget is asked whether it holds with depth (design note section 5).
 *
 * And the probe (--probe 1), which measures how far each layer's sums are from
 * the network's own, as a fraction of their rms, and asks whether that error is
 * all there is to the accuracy.  It exists because the noise options are in LSB
 * of whichever ADC a run configures: "--thermal 1" is four times the noise at
 * six bits that it is at eight.  --thermal8 and --photons8 state the same two in
 * LSB of an 8-bit ADC whatever the ADC is, and the probe reports every run in
 * both.  doc/pta_error_model_design_note.md section 5 has what that changed.
 *
 * And the tile itself (eval --rows, --cols) with the cut of a layer into GEMMs
 * (--maxk, --maxn).  Everything above was measured on the c930 core's 8 x 8
 * tile in GEMMs that core accepts, and those are still the defaults, so a line
 * printed without the four options is the line it always was.  grxcp's board
 * puts the tile on a chiplet that may be 256 x 64 and takes a layer as one
 * command, and design note section 5 has what the budget costs there.
 *
 *   pta_mnist selftest
 *   pta_mnist train --data DIR --din D --wbits B --seed S --out NET [--from NET] [--hidden H]
 *   pta_mnist eval  --data DIR --net NET [options]        (pta_mnist help)
 */
#include "pta_tile_model.h"

#include <math.h>
#include <stddef.h>
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
#define MAX_HID     8           /* hidden layers a network may have; D3 has one */
#define MAX_L       (MAX_HID + 1)

/* The core's NUM_ROWS, NUM_COLS, MAX_M, MAX_K, MAX_N and ACC_W. */
#define ROWS        8
#define COLS        8
#define MAX_M       64
#define MAX_K       256
#define MAX_N       8
#define ACC_W       48

/*
 * The tile and the cut as a run has them: the core's, above, unless eval is
 * told otherwise.  The tile is what a shot is -- tile_rows inputs summed into
 * each of tile_cols outputs, through one ADC conversion each.  The cut is where
 * one GEMM ends and the next begins, gemm_k inputs by gemm_n outputs at most,
 * and it is kept to whole tiles so that a shot sees the same operands however
 * a layer is cut.  It then matters to one thing: each GEMM draws its noise
 * from its own seed.
 */
static int tile_rows = ROWS, tile_cols = COLS, gemm_k = MAX_K, gemm_n = MAX_N;

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

/* PTAMLP2 is one hidden layer, laid out as it always was; PTAMLP3 says how many. */
static const char MAGIC[8] = "PTAMLP2", MAGIC_DEEP[8] = "PTAMLP3";

typedef struct {
    int      n;
    uint8_t *x;                 /* n x 784 pixels */
    uint8_t *y;                 /* n labels */
} dataset;

/*
 * A network: `hidden` hidden layers, each N_HID wide, and so hidden + 1 weight
 * layers.  D3 has one.  Everything before `hidden` is the file's header, and at
 * one hidden layer a file is that header and then w and b, layer by layer:
 * byte for byte what this harness has always written.
 */
typedef struct {
    char     magic[8];
    int      din, wbits, seed, epochs;
    int      from_bits, from_epochs;  /* the network it started from, or 0 */
    double   val_acc, test_acc; /* digital, on the quantised weights */
    int      hidden;
    float   *w[MAX_L];          /* layer l, row n: its output n's input weights */
    float   *b[MAX_L];
} mlp;

/* The network as the host drives the tile. */
typedef struct {
    int      din, hidden;
    int32_t *w[MAX_L];          /* weight operands, w * 2^(D-1) */
    int64_t *b[MAX_L];          /* biases in their layer's output units */
    int      sh[MAX_HID];       /* hidden layer l's rescale: a = round(h / 2^sh[l]) */
} host_net;

/* One image's sums and operands, layer by layer. */
typedef struct {
    int64_t  y[MAX_L][N_HID];   /* layer l's sums before its bias; N_OUT of them in the last */
    int32_t  a[MAX_L][N_HID];   /* a[l], l >= 1: the operands layer l is given */
} image_ws;

/* The same for a batch of up to MAX_M images, each layer row-major by image. */
typedef struct {
    int64_t  y[MAX_L][MAX_M * N_HID];
    int32_t  a[MAX_L][MAX_M * N_HID];
} batch_ws;

static int layer_in(int l)
{
    return l == 0 ? N_IN : N_HID;
}

static int layer_out(int hidden, int l)
{
    return l == hidden ? N_OUT : N_HID;
}

static int layer_size(int hidden, int l)
{
    return layer_in(l) * layer_out(hidden, l);
}

static void mlp_free(mlp *net)
{
    int l;
    for (l = 0; l < MAX_L; ++l) {
        free(net->w[l]);
        free(net->b[l]);
        net->w[l] = NULL;
        net->b[l] = NULL;
    }
}

/* Zeroed weights and biases for a network of this depth.  Returns 0, or -1. */
static int mlp_alloc(mlp *net, int hidden)
{
    int l;
    net->hidden = hidden;
    for (l = 0; l < MAX_L; ++l)
        net->w[l] = net->b[l] = NULL;
    for (l = 0; l <= hidden; ++l) {
        net->w[l] = (float *)calloc((size_t)layer_size(hidden, l), sizeof(float));
        net->b[l] = (float *)calloc((size_t)layer_out(hidden, l), sizeof(float));
        if (!net->w[l] || !net->b[l]) {
            mlp_free(net);
            return -1;
        }
    }
    return 0;
}

static void host_free(host_net *hn)
{
    int l;
    for (l = 0; l < MAX_L; ++l) {
        free(hn->w[l]);
        free(hn->b[l]);
        hn->w[l] = NULL;
        hn->b[l] = NULL;
    }
}

static int host_alloc(host_net *hn, int din, int hidden)
{
    int l;
    memset(hn, 0, sizeof *hn);
    hn->din    = din;
    hn->hidden = hidden;
    for (l = 0; l <= hidden; ++l) {
        hn->w[l] = (int32_t *)calloc((size_t)layer_size(hidden, l), sizeof(int32_t));
        hn->b[l] = (int64_t *)calloc((size_t)layer_out(hidden, l), sizeof(int64_t));
        if (!hn->w[l] || !hn->b[l]) {
            host_free(hn);
            return -1;
        }
    }
    return 0;
}

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

/* The network on quantised weights wq, as a digital computer runs it. */
static int classify(const mlp *net, float *const *wq, const uint8_t *px)
{
    const int H = net->hidden;
    float x[N_IN], h[2][N_HID], z, best_z = 0.0f;
    const float *in;
    int nz[N_IN], cnt = 0, n, k, o, l, best = 0;
    for (k = 0; k < N_IN; ++k)
        if (px[k]) {
            nz[cnt]  = k;
            x[cnt++] = px[k] / 255.0f;
        }
    for (n = 0; n < N_HID; ++n) {
        const float *row = wq[0] + n * N_IN;
        z = net->b[0][n];
        for (k = 0; k < cnt; ++k)
            z += row[nz[k]] * x[k];
        h[0][n] = z > 0.0f ? z : 0.0f;
    }
    for (l = 1; l < H; ++l) {
        float *out = h[l & 1];
        in = h[(l - 1) & 1];
        for (n = 0; n < N_HID; ++n) {
            const float *row = wq[l] + n * N_HID;
            z = net->b[l][n];
            for (k = 0; k < N_HID; ++k)
                z += row[k] * in[k];
            out[n] = z > 0.0f ? z : 0.0f;
        }
    }
    in = h[(H - 1) & 1];
    for (o = 0; o < N_OUT; ++o) {
        z = net->b[H][o];
        for (n = 0; n < N_HID; ++n)
            z += wq[H][o * N_HID + n] * in[n];
        if (o == 0 || z > best_z) {
            best_z = z;
            best   = o;
        }
    }
    return best;
}

static double digital_accuracy(const mlp *net, float *const *wq, const dataset *d, int first,
                               int count)
{
    int i, right = 0;
    for (i = first; i < first + count; ++i)
        right += classify(net, wq, d->x + (size_t)i * N_IN) == d->y[i];
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

/* Trains net, already allocated for its depth, at wbits: from Glorot or, if
 * start is given, from start's weights. */
static void train(mlp *net, const dataset *tr, const dataset *te, int din, int wbits, int seed,
                  const mlp *start, int verbose)
{
    const int H = net->hidden, L = H + 1;
    uint64_t ri = 0x243F6A8885A308D3ull ^ (uint64_t)(uint32_t)seed;                /* init */
    uint64_t rs = 0x13198A2E03707344ull ^ (uint64_t)(uint32_t)seed ^ ((uint64_t)wbits << 32);
    float *wq[MAX_L], *g[MAX_L], *m[MAX_L], *v[MAX_L];
    float gb[MAX_L][N_HID], mb[MAX_L][N_HID], vb[MAX_L][N_HID];
    int *order = (int *)malloc(N_TRAIN * sizeof(int));
    double best = -1.0;
    long t = 0;
    int i, l, epoch;

    for (l = 0; l < L; ++l) {
        const size_t P = (size_t)layer_size(H, l);
        wq[l] = (float *)malloc(P * sizeof(float));
        g[l]  = (float *)malloc(P * sizeof(float));
        m[l]  = (float *)calloc(P, sizeof(float));
        v[l]  = (float *)calloc(P, sizeof(float));
    }
    memset(mb, 0, sizeof mb);
    memset(vb, 0, sizeof vb);

    memcpy(net->magic, H == 1 ? MAGIC : MAGIC_DEEP, sizeof MAGIC);
    net->din   = din;
    net->wbits = wbits;
    net->seed  = seed;
    if (start) {
        for (l = 0; l < L; ++l) {
            memcpy(net->w[l], start->w[l], (size_t)layer_size(H, l) * sizeof(float));
            memcpy(net->b[l], start->b[l], (size_t)layer_out(H, l) * sizeof(float));
        }
        net->from_bits   = start->wbits;
        net->from_epochs = start->epochs;
    } else {
        for (l = 0; l < L; ++l) {
            const double lim = sqrt(6.0 / (layer_in(l) + layer_out(H, l)));
            const int P = layer_size(H, l);
            for (i = 0; i < P; ++i)
                net->w[l][i] = (float)((2.0 * uniform01(&ri) - 1.0) * lim);  /* Glorot uniform */
            memset(net->b[l], 0, (size_t)layer_out(H, l) * sizeof(float));
        }
    }
    for (i = 0; i < N_TRAIN; ++i)
        order[i] = i;

    for (epoch = 0; epoch < MAX_EPOCHS; ++epoch) {
        int first;
        for (i = N_TRAIN - 1; i > 0; --i) {
            const int j = (int)(splitmix64(&rs) % (uint64_t)(i + 1));
            const int s = order[i];
            order[i] = order[j];
            order[j] = s;
        }
        for (first = 0; first < N_TRAIN; first += BATCH) {
            const int bs = (N_TRAIN - first < BATCH) ? N_TRAIN - first : BATCH;
            int j;
            for (l = 0; l < L; ++l) {
                quantise(net->w[l], wq[l], layer_size(H, l), din, wbits);
                memset(g[l], 0, (size_t)layer_size(H, l) * sizeof(float));
                memset(gb[l], 0, sizeof gb[l]);
            }
            for (j = 0; j < bs; ++j) {
                const int idx = order[first + j];
                const uint8_t *px = tr->x + (size_t)idx * N_IN;
                float x[N_IN], z[MAX_HID][N_HID], h[MAX_HID][N_HID], dl[MAX_HID][N_HID];
                float z2[N_OUT], dz2[N_OUT], zmax, sum;
                int nz[N_IN], cnt = 0, n, k, o;
                for (k = 0; k < N_IN; ++k)
                    if (px[k]) {
                        nz[cnt]  = k;
                        x[cnt++] = px[k] / 255.0f;
                    }
                for (n = 0; n < N_HID; ++n) {
                    const float *row = wq[0] + n * N_IN;
                    float zz = net->b[0][n];
                    for (k = 0; k < cnt; ++k)
                        zz += row[nz[k]] * x[k];
                    z[0][n] = zz;
                    h[0][n] = zz > 0.0f ? zz : 0.0f;
                }
                for (l = 1; l < H; ++l)
                    for (n = 0; n < N_HID; ++n) {
                        const float *row = wq[l] + n * N_HID;
                        float zz = net->b[l][n];
                        for (k = 0; k < N_HID; ++k)
                            zz += row[k] * h[l - 1][k];
                        z[l][n] = zz;
                        h[l][n] = zz > 0.0f ? zz : 0.0f;
                    }
                zmax = -1e30f;
                for (o = 0; o < N_OUT; ++o) {
                    float zz = net->b[H][o];
                    for (n = 0; n < N_HID; ++n)
                        zz += wq[H][o * N_HID + n] * h[H - 1][n];
                    z2[o] = zz;
                    if (zz > zmax)
                        zmax = zz;
                }
                sum = 0.0f;
                for (o = 0; o < N_OUT; ++o)
                    sum += (float)exp(z2[o] - zmax);
                for (o = 0; o < N_OUT; ++o) {
                    const float p = (float)exp(z2[o] - zmax) / sum;
                    dz2[o] = (p - (o == tr->y[idx] ? 1.0f : 0.0f)) / (float)bs;
                    gb[H][o] += dz2[o];
                    for (n = 0; n < N_HID; ++n)
                        g[H][o * N_HID + n] += dz2[o] * h[H - 1][n];
                }
                /* straight through: the rounded weights carry the gradient back,
                 * and it lands on the real-valued ones */
                for (l = H - 1; l >= 0; --l) {
                    const float *wn = wq[l + 1];            /* the layer above */
                    const float *dn = (l == H - 1) ? dz2 : dl[l + 1];
                    const int on = layer_out(H, l + 1);
                    for (n = 0; n < N_HID; ++n) {
                        float dh = 0.0f;
                        float *row;
                        dl[l][n] = 0.0f;
                        if (z[l][n] <= 0.0f)
                            continue;
                        for (o = 0; o < on; ++o)
                            dh += wn[o * N_HID + n] * dn[o];
                        dl[l][n] = dh;
                        gb[l][n] += dh;
                        if (l == 0) {
                            row = g[0] + n * N_IN;
                            for (k = 0; k < cnt; ++k)
                                row[nz[k]] += dh * x[k];
                        } else {
                            row = g[l] + n * N_HID;
                            for (k = 0; k < N_HID; ++k)
                                row[k] += dh * h[l - 1][k];
                        }
                    }
                }
            }
            ++t;
            for (l = 0; l < L; ++l) {
                adam(net->w[l], g[l], m[l], v[l], layer_size(H, l), t);
                adam(net->b[l], gb[l], mb[l], vb[l], layer_out(H, l), t);
            }
        }
        for (l = 0; l < L; ++l)
            quantise(net->w[l], wq[l], layer_size(H, l), din, wbits);
        net->val_acc = digital_accuracy(net, wq, tr, N_TRAIN, N_ALL - N_TRAIN);
        net->epochs  = epoch + 1;
        if (verbose)
            fprintf(stderr, "  epoch %d: held out %.2f%%\n", epoch + 1, net->val_acc);
        if (net->val_acc > best)
            best = net->val_acc;
        else if (epoch > 0)
            break;
    }
    net->test_acc = digital_accuracy(net, wq, te, 0, N_TEST);

    for (l = 0; l < L; ++l) {
        free(wq[l]);
        free(g[l]);
        free(m[l]);
        free(v[l]);
    }
    free(order);
}

/* ------------------------------------------------------------------------- */

/* The weight operands as the DAC holds them at B bits, into q[l] for each layer. */
static void quant_weights(const host_net *hn, int wbits, int32_t *const *q)
{
    int i, l;
    for (l = 0; l <= hn->hidden; ++l) {
        const int P = layer_size(hn->hidden, l);
        for (i = 0; i < P; ++i)
            q[l][i] = contract_quant(hn->w[l][i], wbits, hn->din);
    }
}

/* One image through the network in integers, with no tile, on weights from
 * quant_weights(): the sums the tile computes exactly when only QUANT's
 * operand quantisers are on.  q(0, B) is 0, so zero inputs are skipped. */
static void direct_image(const host_net *hn, int32_t *const *q, int abits, const int32_t *a0,
                         image_ws *ws)
{
    const int D = hn->din, H = hn->hidden;
    const int64_t amax = ((int64_t)1 << (D - 1)) - 1;
    int64_t xa[N_IN];
    int nz[N_IN], cnt = 0, n, k, l;
    for (k = 0; k < N_IN; ++k)
        if (a0[k]) {
            nz[cnt]   = k;
            xa[cnt++] = contract_quant(a0[k], abits, D);
        }
    for (l = 0; l <= H; ++l) {
        const int out = layer_out(H, l);
        if (l > 0)
            for (k = 0; k < N_HID; ++k)
                xa[k] = contract_quant(ws->a[l][k], abits, D);
        for (n = 0; n < out; ++n) {
            const int32_t *row = q[l] + n * layer_in(l);
            int64_t s = 0, v;
            if (l == 0)
                for (k = 0; k < cnt; ++k)
                    s += xa[k] * row[nz[k]];
            else
                for (k = 0; k < N_HID; ++k)
                    s += xa[k] * row[k];
            ws->y[l][n] = s;
            if (l < H) {
                v = s + hn->b[l][n];
                v = round_shift(v > 0 ? v : 0, hn->sh[l]);
                ws->a[l + 1][n] = (int32_t)(v > amax ? amax : v);
            }
        }
    }
}

/*
 * A GEMM's operands and its result, sized for the run's cut and for the
 * calibration probe, which is tile_rows one-hot rows against one tile.
 */
typedef struct {
    int32_t *A;
    int32_t *B;
    int64_t *C;
} gemm_buf;

static void gemm_free(gemm_buf *g)
{
    if (!g)
        return;
    free(g->A);
    free(g->B);
    free(g->C);
    free(g);
}

static gemm_buf *gemm_alloc(void)
{
    const size_t m = (size_t)(MAX_M > tile_rows ? MAX_M : tile_rows);
    const size_t k = (size_t)(gemm_k > tile_rows ? gemm_k : tile_rows);
    const size_t n = (size_t)(gemm_n > tile_cols ? gemm_n : tile_cols);
    gemm_buf *g = (gemm_buf *)calloc(1, sizeof *g);

    if (!g)
        return NULL;
    g->A = (int32_t *)malloc(m * k * sizeof *g->A);
    g->B = (int32_t *)malloc(k * n * sizeof *g->B);
    g->C = (int64_t *)malloc(m * n * sizeof *g->C);
    if (!g->A || !g->B || !g->C) {
        gemm_free(g);
        return NULL;
    }
    return g;
}

/*
 * M images, their input operands a0 (M x 784), through the tile: bw->y[l] are
 * layer l's GEMM sums before the biases and bw->a[l], for l >= 1, the operands
 * layer l was given.  Layer l runs on weight bank l & 1, and every GEMM takes
 * the next seed.  Returns ADC saturations, or -1.
 */
static long tile_batch(const host_net *hn, const pta_cfg *cfg, const pta_tile *tile,
                       pta_device *dev, uint32_t seed, uint32_t *gemm, gemm_buf *g, int M,
                       const int32_t *a0, batch_ws *bw)
{
    const int H = hn->hidden;
    const int64_t amax = ((int64_t)1 << (hn->din - 1)) - 1;
    long sats = 0, r;
    int l, n0, k0, m, n, k;
    pta_cfg c;

    for (l = 0; l <= H; ++l) {
        const int in = layer_in(l), out = layer_out(H, l);
        const int32_t *src = l == 0 ? a0 : bw->a[l];
        int64_t *y = bw->y[l];
        memset(y, 0, (size_t)M * out * sizeof *y);
        for (n0 = 0; n0 < out; n0 += gemm_n) {
            const int N = (out - n0 < gemm_n) ? out - n0 : gemm_n;
            for (k0 = 0; k0 < in; k0 += gemm_k) {
                const int K = (in - k0 < gemm_k) ? in - k0 : gemm_k;
                for (m = 0; m < M; ++m)
                    for (k = 0; k < K; ++k)
                        g->A[m * K + k] = src[m * in + k0 + k];
                for (k = 0; k < K; ++k)
                    for (n = 0; n < N; ++n)
                        g->B[k * N + n] = hn->w[l][(n0 + n) * in + k0 + k];
                c      = cfg[l];
                c.seed = gemm_seed(seed, (*gemm)++);
                if ((r = pta_gemm(&c, tile, dev, l & 1, M, N, K, g->A, g->B, g->C)) < 0)
                    return -1;
                sats += r;
                for (m = 0; m < M; ++m)
                    for (n = 0; n < N; ++n)
                        y[m * out + n0 + n] += g->C[m * N + n];
            }
        }
        if (l < H)
            for (m = 0; m < M; ++m)
                for (n = 0; n < N_HID; ++n) {
                    int64_t v = y[m * N_HID + n] + hn->b[l][n];
                    v = round_shift(v > 0 ? v : 0, hn->sh[l]);
                    bw->a[l + 1][m * N_HID + n] = (int32_t)(v > amax ? amax : v);
                }
    }
    return sats;
}

/* ------------------------------------------------------------------------- */

/*
 * The probe: how far the tile's sums are from the network's own, layer by
 * layer, in a unit no ADC defines.  The reference is the network as trained and
 * as a digital host runs it -- weights at the network's width, activations
 * unquantised -- so everything the tile does to a sum counts, quantisers
 * included.
 *
 *   e1, e2, ...  each layer's GEMM on its own: against the exact product of
 *                the operands the tile itself gave it.  Layer 1's inputs are
 *                the image, so e1 is also its whole error
 *   eprop        everything before the last layer as it arrives at the
 *                outputs, through exact weights
 *   elog         all of it, at the outputs: rms(y - reference) / rms(reference)
 *   t1, t2, ...  the same measure at every layer, for a network of more than
 *                one hidden layer: how the error grows on the way through
 *
 * and then whether that error is all there is to the accuracy.  Three
 * predictions, each perturbing the reference outputs with Gaussian noise and
 * counting what is still classified correctly:
 *
 *   pred_iid  independent noise of the measured rms and nothing else.  If the
 *             tile's accuracy is this, accuracy is a function of how much
 *             error there is and not of what made it
 *   pred_cov  the error's measured mean and its covariance across the outputs
 *   pred_res  the same, of the part a decision can see.  An argmax does not
 *             move when every output shifts together, nor when they all scale,
 *             so each image's common shift is taken out and so is the gain: the
 *             slope of the error against the outputs themselves, fitted over
 *             the run.  eres is what is left, as a fraction like the others.
 */
#define PROBE_DRAWS 32

typedef struct {
    int     hidden;
    double  e[MAX_L], r[MAX_L]; /* sums of squares: a layer's own error, and the
                                   product it is measured against */
    double  t[MAX_L], rt[MAX_L];/* its whole error, and the reference's sums */
    double  ep;                 /* what arrives at the outputs from before them */
    double  mean[N_OUT];        /* the total error's sum, per output */
    double  cov[N_OUT][N_OUT];  /* and its raw second moments */
    double  cm[N_OUT], lm[N_OUT];   /* sums, per output: the error and the reference,
                                       each less its image's mean over the outputs */
    double  cc[N_OUT][N_OUT];   /* their second moments: error with error, */
    double  cl[N_OUT][N_OUT];   /* error with reference, */
    double  ll[N_OUT][N_OUT];   /* reference with reference */
    double *logit;              /* reference outputs with their biases, images x N_OUT */
    double *margin;             /* reference top-1 less top-2, per image */
    int     images, ref_right, agree;
} probe;

static int probe_init(probe *p, int images, int hidden)
{
    memset(p, 0, sizeof *p);
    p->hidden = hidden;
    p->logit  = (double *)malloc((size_t)images * N_OUT * sizeof(double));
    p->margin = (double *)malloc((size_t)images * sizeof(double));
    return (p->logit && p->margin) ? 0 : -1;
}

static void probe_free(probe *p)
{
    free(p->logit);
    free(p->margin);
}

/* M images: their operands, what tile_batch() left in bw for them, and the
 * reference weights from quant_weights() at the network's own width. */
static void probe_batch(probe *p, const host_net *hn, int32_t *const *q, int M, const int32_t *a0,
                        const batch_ws *bw, const uint8_t *labels)
{
    const int H = hn->hidden;
    image_ws ws;
    int m, n, k, o, j, l;
    for (m = 0; m < M; ++m) {
        double err[N_OUT], *lg = p->logit + (size_t)p->images * N_OUT, em = 0.0, gm = 0.0;
        const int64_t *y2 = bw->y[H] + m * N_OUT;
        int best = 0, second = -1, tile_best = 0;
        direct_image(hn, q, 0, a0 + m * N_IN, &ws);
        for (l = 0; l < H; ++l)
            for (n = 0; n < N_HID; ++n) {
                const int64_t yt = bw->y[l][m * N_HID + n];
                int64_t loc = ws.y[l][n];
                double d;
                if (l > 0) {
                    loc = 0;
                    for (k = 0; k < N_HID; ++k)
                        loc += (int64_t)bw->a[l][m * N_HID + k] * q[l][n * N_HID + k];
                }
                d = (double)(yt - loc);
                p->e[l]  += d * d;
                p->r[l]  += (double)loc * (double)loc;
                d = (double)(yt - ws.y[l][n]);
                p->t[l]  += d * d;
                p->rt[l] += (double)ws.y[l][n] * (double)ws.y[l][n];
            }
        for (o = 0; o < N_OUT; ++o) {
            int64_t loc = 0;
            double dl, dp;
            for (k = 0; k < N_HID; ++k)
                loc += (int64_t)bw->a[H][m * N_HID + k] * q[H][o * N_HID + k];
            dl     = (double)(y2[o] - loc);
            dp     = (double)(loc - ws.y[H][o]);
            err[o] = (double)(y2[o] - ws.y[H][o]);
            p->e[H]  += dl * dl;
            p->r[H]  += (double)loc * (double)loc;
            p->ep    += dp * dp;
            p->t[H]  += err[o] * err[o];
            p->rt[H] += (double)ws.y[H][o] * (double)ws.y[H][o];
            lg[o]  = (double)(ws.y[H][o] + hn->b[H][o]);
            if (y2[o] + hn->b[H][o] > y2[tile_best] + hn->b[H][tile_best])
                tile_best = o;
        }
        for (o = 0; o < N_OUT; ++o) {
            em += err[o] / N_OUT;
            gm += lg[o] / N_OUT;
        }
        for (o = 0; o < N_OUT; ++o) {
            p->mean[o] += err[o];
            p->cm[o]   += err[o] - em;
            p->lm[o]   += lg[o] - gm;
            for (j = 0; j < N_OUT; ++j) {
                p->cov[o][j] += err[o] * err[j];
                p->cc[o][j]  += (err[o] - em) * (err[j] - em);
                p->cl[o][j]  += (err[o] - em) * (lg[j] - gm);
                p->ll[o][j]  += (lg[o] - gm) * (lg[j] - gm);
            }
            if (lg[o] > lg[best])
                best = o;
        }
        for (o = 0; o < N_OUT; ++o)
            if (o != best && (second < 0 || lg[o] > lg[second]))
                second = o;
        p->margin[p->images] = lg[best] - lg[second];
        p->ref_right += best == labels[m];
        p->agree     += best == tile_best;
        ++p->images;
    }
}

static double gauss01(uint64_t *s)
{
    double u = uniform01(s);
    const double v = uniform01(s);
    if (u < 1e-300)
        u = 1e-300;
    return sqrt(-2.0 * log(u)) * cos(2.0 * PI * v);
}

/* The lower Cholesky factor of a symmetric matrix.  A pivot that is not
 * positive -- a covariance of rank under ten, which a noiseless run has --
 * leaves its column at zero rather than failing. */
static void cholesky(double a[N_OUT][N_OUT], double l[N_OUT][N_OUT])
{
    int i, j, k;
    memset(l, 0, sizeof(double) * N_OUT * N_OUT);
    for (j = 0; j < N_OUT; ++j) {
        double d = a[j][j];
        for (k = 0; k < j; ++k)
            d -= l[j][k] * l[j][k];
        if (d <= 1e-12 * (a[j][j] > 1.0 ? a[j][j] : 1.0))
            continue;
        l[j][j] = sqrt(d);
        for (i = j + 1; i < N_OUT; ++i) {
            double s = a[i][j];
            for (k = 0; k < j; ++k)
                s -= l[i][k] * l[j][k];
            l[i][j] = s / l[j][j];
        }
    }
}

static int cmp_double(const void *a, const void *b)
{
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

typedef struct {
    double ref, agree, e[MAX_L], t[MAX_L], eprop, elog, sigma, margin, pred_iid, pred_cov;
    double gain, eres, pred_res;
} probe_result;

/* Closes the probe: the ratios, and the three predictions drawn PROBE_DRAWS
 * times an image on a generator of the probe's own. */
static void probe_finish(probe *p, const uint8_t *labels, uint32_t seed, probe_result *r)
{
    const int H = p->hidden;
    const double n = (double)p->images;
    double mean[N_OUT], cov[N_OUT][N_OUT], l[N_OUT][N_OUT], z[N_OUT];
    double rmean[N_OUT], rcov[N_OUT][N_OUT], rl[N_OUT][N_OUT], num = 0.0, den = 0.0, rss = 0.0;
    uint64_t rs = ((uint64_t)seed << 32) ^ 0x50524F4245ull;
    long iid = 0, cv = 0, rv = 0;
    int i, d, o, j;

    r->ref    = 100.0 * p->ref_right / n;
    r->agree  = 100.0 * p->agree / n;
    for (i = 0; i <= H; ++i) {
        r->e[i] = p->r[i] > 0 ? sqrt(p->e[i] / p->r[i]) : 0.0;
        r->t[i] = p->rt[i] > 0 ? sqrt(p->t[i] / p->rt[i]) : 0.0;
    }
    r->eprop  = p->rt[H] > 0 ? sqrt(p->ep / p->rt[H]) : 0.0;
    r->elog   = p->rt[H] > 0 ? sqrt(p->t[H] / p->rt[H]) : 0.0;
    r->sigma  = sqrt(p->t[H] / (n * N_OUT));
    for (o = 0; o < N_OUT; ++o)
        mean[o] = p->mean[o] / n;
    for (o = 0; o < N_OUT; ++o)
        for (j = 0; j < N_OUT; ++j)
            cov[o][j] = p->cov[o][j] / n - mean[o] * mean[j];
    cholesky(cov, l);
    /* The gain: least squares of the centred error on the centred outputs. */
    for (o = 0; o < N_OUT; ++o) {
        num += p->cl[o][o];
        den += p->ll[o][o];
    }
    r->gain = den > 0.0 ? num / den : 0.0;
    for (o = 0; o < N_OUT; ++o)
        rmean[o] = (p->cm[o] - r->gain * p->lm[o]) / n;
    for (o = 0; o < N_OUT; ++o) {
        for (j = 0; j < N_OUT; ++j)
            rcov[o][j] = (p->cc[o][j] - r->gain * (p->cl[o][j] + p->cl[j][o])
                          + r->gain * r->gain * p->ll[o][j]) / n - rmean[o] * rmean[j];
        rss += p->cc[o][o] - 2.0 * r->gain * p->cl[o][o] + r->gain * r->gain * p->ll[o][o];
    }
    r->eres = (p->rt[H] > 0 && rss > 0) ? sqrt(rss / p->rt[H]) : 0.0;
    cholesky(rcov, rl);
    for (i = 0; i < p->images; ++i) {
        const double *lg = p->logit + (size_t)i * N_OUT;
        for (d = 0; d < PROBE_DRAWS; ++d) {
            double x, bx = 0.0, y, by = 0.0, w, bw = 0.0;
            int bi = 0, bc = 0, br = 0;
            for (o = 0; o < N_OUT; ++o)
                z[o] = gauss01(&rs);
            for (o = 0; o < N_OUT; ++o) {
                x = lg[o] + r->sigma * gauss01(&rs);
                y = lg[o] + mean[o];
                w = lg[o] + rmean[o];
                for (j = 0; j <= o; ++j) {
                    y += l[o][j] * z[j];
                    w += rl[o][j] * z[j];
                }
                if (o == 0 || x > bx) { bx = x; bi = o; }
                if (o == 0 || y > by) { by = y; bc = o; }
                if (o == 0 || w > bw) { bw = w; br = o; }
            }
            iid += bi == labels[i];
            cv  += bc == labels[i];
            rv  += br == labels[i];
        }
    }
    r->pred_iid = 100.0 * (double)iid / (n * PROBE_DRAWS);
    r->pred_cov = 100.0 * (double)cv / (n * PROBE_DRAWS);
    r->pred_res = 100.0 * (double)rv / (n * PROBE_DRAWS);
    qsort(p->margin, (size_t)p->images, sizeof(double), cmp_double);
    r->margin = p->margin[p->images / 2];
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
 *
 * Returns 0, or -1 if it could not run.  It used to return nothing, and to do
 * nothing on a tile of more than 64 cells: on the 8 x 8 tile that was every
 * tile there was.
 */
static int calibrate_bank(pta_device *dev, const pta_cfg *cfg, const pta_tile *tile, int bank,
                          uint32_t seed, uint32_t *gemm, int repeats, gemm_buf *g)
{
    enum { PASSES = 3 };
    const int k = tile->rows, n = tile->cols;
    const int32_t probe = (int32_t)((((int64_t)1 << (tile->din_w - 1)) - 1));
    const int64_t pa = (cfg->impair & PTA_QUANT)
                     ? contract_quant(probe, (int)cfg->act_bits, tile->din_w) : probe;
    const int quantised = (cfg->impair & PTA_QUANT) && cfg->adc_bits != 0;
    const int64_t codes = quantised ? (((int64_t)1 << (cfg->adc_bits - 1)) - 1) : 0;
    int64_t *sum, *total;
    int64_t range = pa * (int64_t)cfg->trim_max / 256;   /* cover what a trim can hold */
    pta_cfg c = *cfg;
    int r, col, rep, pass, s_probe;

    if (pa == 0)
        return 0;                       /* nothing a probe could read */
    sum   = (int64_t *)malloc((size_t)k * n * sizeof *sum);
    total = (int64_t *)calloc((size_t)k * n, sizeof *total);
    if (!sum || !total) {
        free(sum);
        free(total);
        return -1;
    }

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
            if (pta_gemm(&c, tile, dev, bank, k, n, k, g->A, g->B, g->C) < 0) {
                free(sum);
                free(total);
                return -1;
            }
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
    free(sum);
    free(total);
    return 0;
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
 * each hidden layer's rescale, set on training images with the weights as
 * trained.  A layer's rescale needs the layers before it settled, so they are
 * set in order.  Allocates hn.  Returns 0, or -1 if out of memory.
 */
static int host_setup(host_net *hn, const mlp *net, const dataset *tr)
{
    const int D = net->din, H = net->hidden;
    const double a_s = ldexp(1.0, D - 1) - 1.0, w_s = ldexp(1.0, D - 1);
    const int64_t amax = ((int64_t)1 << (D - 1)) - 1;
    int32_t a1[N_IN], *q[MAX_L];
    image_ws *ws = (image_ws *)malloc(sizeof *ws);
    double scale = a_s;         /* operand units per unit of this layer's input */
    int i, n, k, l;

    if (!ws || host_alloc(hn, D, H) != 0)
        return -1;
    for (l = 0; l <= H; ++l) {
        const int P = layer_size(H, l);
        q[l] = (int32_t *)malloc((size_t)P * sizeof(int32_t));
        if (!q[l])
            return -1;
        for (i = 0; i < P; ++i)
            hn->w[l][i] = weight_operand(net->w[l][i], D);
    }
    quant_weights(hn, net->wbits, q);
    for (l = 0; l < H; ++l) {
        long hist[64] = {0}, total = 0;
        for (n = 0; n < N_HID; ++n)
            hn->b[l][n] = llround(net->b[l][n] * scale * w_s);
        hn->sh[l] = 0;
        for (i = 0; i < N_CAL_HID; ++i) {
            for (k = 0; k < N_IN; ++k)
                a1[k] = pixel_operand(tr->x[(size_t)i * N_IN + k], D);
            direct_image(hn, q, 0, a1, ws);
            for (n = 0; n < N_HID; ++n) {
                const int64_t v = ws->y[l][n] + hn->b[l][n];
                if (v > 0) {
                    ++hist[shift_needed(v, amax)];
                    ++total;
                }
            }
        }
        hn->sh[l] = shift_for(hist, total);
        scale = scale * w_s / ldexp(1.0, hn->sh[l]);
    }
    for (n = 0; n < N_OUT; ++n)
        hn->b[H][n] = llround(net->b[H][n] * scale * w_s);
    for (l = 0; l <= H; ++l)
        free(q[l]);
    free(ws);
    return 0;
}

/*
 * Each layer's ADC shift for adc_bits B: the smallest that clips no more than
 * CLIP_FRAC of the K-tile sums, with the weights as trained, on training
 * images.  The ADC rounds a sum s to round(s / 2^S), which saturates past
 * 2^(B-1) - 1.
 */
static void adc_setup(const host_net *hn, const mlp *net, const dataset *tr, int adc_bits, int *S)
{
    const int D = hn->din, H = hn->hidden;
    const int64_t lim = ((int64_t)1 << (adc_bits - 1)) - 1;
    long hist[MAX_L][64];
    long total[MAX_L];
    int32_t a1[N_IN], *q[MAX_L];
    image_ws *ws = (image_ws *)malloc(sizeof *ws);
    int i, n, k, r, l;

    memset(hist, 0, sizeof hist);
    memset(total, 0, sizeof total);
    for (l = 0; l <= H; ++l)
        q[l] = (int32_t *)malloc((size_t)layer_size(H, l) * sizeof(int32_t));
    quant_weights(hn, net->wbits, q);
    for (i = 0; i < N_CAL_ADC; ++i) {
        for (k = 0; k < N_IN; ++k)
            a1[k] = pixel_operand(tr->x[(size_t)i * N_IN + k], D);
        direct_image(hn, q, 0, a1, ws);
        for (l = 0; l <= H; ++l) {
            const int in = layer_in(l), out = layer_out(H, l);
            const int32_t *src = l == 0 ? a1 : ws->a[l];
            for (n = 0; n < out; ++n)
                for (k = 0; k < in; k += tile_rows) {
                    int64_t s = 0;
                    for (r = k; r < k + tile_rows && r < in; ++r)
                        s += (int64_t)src[r] * q[l][n * in + r];
                    ++hist[l][shift_needed(s < 0 ? -s : s, lim)];
                    ++total[l];
                }
        }
    }
    for (l = 0; l <= H; ++l) {
        S[l] = shift_for(hist[l], total[l]);
        free(q[l]);
    }
    free(ws);
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

/* The bytes before a network's weights: the header, and nothing else. */
#define HEAD_BYTES  offsetof(mlp, hidden)

static long net_bytes(int hidden)
{
    long n = (long)HEAD_BYTES + (hidden > 1 ? (long)sizeof(int) : 0);
    int l;
    for (l = 0; l <= hidden; ++l)
        n += (long)sizeof(float) * (layer_size(hidden, l) + layer_out(hidden, l));
    return n;
}

/* The header, then the depth if it is more than one, then w and b by layer. */
static int save_net(const char *path, const mlp *net)
{
    FILE *f = fopen(path, "wb");
    int l, ok = f && fwrite(net, HEAD_BYTES, 1, f) == 1;
    if (net->hidden > 1)
        ok = ok && fwrite(&net->hidden, sizeof(int), 1, f) == 1;
    for (l = 0; ok && l <= net->hidden; ++l) {
        const size_t P = (size_t)layer_size(net->hidden, l), B = (size_t)layer_out(net->hidden, l);
        ok = fwrite(net->w[l], sizeof(float), P, f) == P &&
             fwrite(net->b[l], sizeof(float), B, f) == B;
    }
    if (f && fclose(f) != 0)
        ok = 0;
    return ok ? 0 : -1;
}

/* Reads a network and allocates it.  Returns 0, or -1 with a message. */
static int load_net(const char *path, mlp *net)
{
    FILE *f = fopen(path, "rb");
    int hidden = 1, l, ok;
    memset(net, 0, sizeof *net);
    ok = f && fread(net, HEAD_BYTES, 1, f) == 1;
    if (ok && memcmp(net->magic, MAGIC_DEEP, sizeof MAGIC_DEEP) == 0)
        ok = fread(&hidden, sizeof(int), 1, f) == 1 && hidden > 1 && hidden <= MAX_HID;
    else
        ok = ok && memcmp(net->magic, MAGIC, sizeof MAGIC) == 0;
    ok = ok && mlp_alloc(net, hidden) == 0;
    for (l = 0; ok && l <= hidden; ++l) {
        const size_t P = (size_t)layer_size(hidden, l), B = (size_t)layer_out(hidden, l);
        ok = fread(net->w[l], sizeof(float), P, f) == P &&
             fread(net->b[l], sizeof(float), B, f) == B;
    }
    ok = ok && fgetc(f) == EOF;
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
        "--verbose", "--hidden", NULL};
    const char *data = opt(argc, argv, "--data", NULL), *out = opt(argc, argv, "--out", NULL);
    const char *from = opt(argc, argv, "--from", NULL);
    const int din = atoi(opt(argc, argv, "--din", "16")), wbits = atoi(opt(argc, argv, "--wbits", "0"));
    const int seed = atoi(opt(argc, argv, "--seed", "1"));
    const int hidden = atoi(opt(argc, argv, "--hidden", "1"));
    dataset tr, te;
    mlp net, from_net, *start = NULL;
    if (check_opts(argc, argv, names) != 0 || !data || !out || (din != 8 && din != 16) ||
        wbits < 0 || wbits > din || hidden < 1 || hidden > MAX_HID) {
        fprintf(stderr, "pta_mnist train: --data DIR --din 8|16 --wbits 0..D --seed S --out NET "
                        "[--from NET] [--hidden 1..%d]\n", MAX_HID);
        return 2;
    }
    if (from) {
        start = &from_net;
        if (load_net(from, start) != 0)
            return 2;
        if (start->din != din || start->seed != seed || start->hidden != hidden) {
            fprintf(stderr, "pta_mnist: %s is not a DIN_W %d network of seed %d and %d hidden "
                            "layer%s\n", from, din, seed, hidden, hidden == 1 ? "" : "s");
            return 2;
        }
    }
    if (load_mnist(data, &tr, &te) != 0)
        return 2;
    memset(&net, 0, sizeof net);
    if (mlp_alloc(&net, hidden) != 0)
        return 2;
    train(&net, &tr, &te, din, wbits, seed, start, atoi(opt(argc, argv, "--verbose", "0")));
    if (save_net(out, &net) != 0) {
        fprintf(stderr, "pta_mnist: cannot write %s\n", out);
        return 2;
    }
    printf("din=%d wbits=%d seed=%d from=%d from_epochs=%d epochs=%d held_out=%.2f digital=%.2f",
           din, wbits, seed, net.from_bits, net.from_epochs, net.epochs, net.val_acc, net.test_acc);
    if (hidden > 1)
        printf(" hidden=%d", hidden);
    printf("\n");
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

/* "11,9": a list of ints as the output line carries it. */
static void join_ints(char *buf, size_t size, const int *v, int n)
{
    size_t used = 0;
    int i;
    buf[0] = '\0';
    for (i = 0; i < n && used < size; ++i)
        used += (size_t)snprintf(buf + used, size - used, i ? ",%d" : "%d", v[i]);
}

static int cmd_eval(int argc, char **argv)
{
    static const char *const names[] = {"--data", "--net", "--images", "--seed", "--impair",
        "--wbits", "--abits", "--adcbits", "--thermal", "--photons", "--prog", "--xtalk",
        "--drift", "--hours", "--calibrate", "--trimstep", "--trimmax", "--post-hours",
        "--probe", "--thermal8", "--photons8", "--rows", "--cols", "--maxk", "--maxn", NULL};
    const char *data = opt(argc, argv, "--data", NULL), *path = opt(argc, argv, "--net", NULL);
    const char *drift = opt(argc, argv, "--drift", "none");
    const int images = atoi(opt(argc, argv, "--images", "10000"));
    const uint32_t seed = (uint32_t)strtoul(opt(argc, argv, "--seed", "1"), NULL, 0);
    const double photons = atof(opt(argc, argv, "--photons", "0"));
    const double hours = atof(opt(argc, argv, "--hours", "0"));
    const double post_hours = atof(opt(argc, argv, "--post-hours", "0"));
    const int calibrate = atoi(opt(argc, argv, "--calibrate", "0"));
    const int probing = atoi(opt(argc, argv, "--probe", "0"));
    const char *thermal8 = opt(argc, argv, "--thermal8", NULL);
    const char *photons8 = opt(argc, argv, "--photons8", NULL);
    probe pr;
    int32_t *pq[MAX_L] = {NULL};
    int S[MAX_L] = {0}, S8[MAX_L] = {0};
    dataset tr, te;
    mlp net_s, *net = &net_s;
    host_net hn_s, *hn = &hn_s;
    gemm_buf *g;
    batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
    int32_t *a1 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t));
    pta_cfg cfg[MAX_L];
    pta_tile tile;
    pta_device dev;
    char s_txt[64], sh_txt[64], s8_txt[64];
    uint32_t gemm = 0;
    uint64_t steps = 0, post_steps = 0;
    long sats = 0, elements = 0, per_image = 0, r;
    int right = 0, base, m, k, o, l, H;

    memset(&pr, 0, sizeof pr);
    if (check_opts(argc, argv, names) != 0 || !data || !path || images < 1 || images > N_TEST) {
        fprintf(stderr, "pta_mnist eval: --data DIR --net NET [options] (pta_mnist help)\n");
        return 2;
    }
    /* The tile, and the cut.  The cut is whole tiles: a GEMM that ended inside
     * one would give its last shot fewer inputs than the tile has, and the same
     * layer would then be a different set of shots at every cut. */
    tile_rows = atoi(opt(argc, argv, "--rows", "8"));
    tile_cols = atoi(opt(argc, argv, "--cols", "8"));
    /* On the core's tile the cut is the core's.  On any other it is a whole
     * layer, which is how a tile that is not the core's is given its work. */
    if (tile_rows == ROWS && tile_cols == COLS) {
        gemm_k = MAX_K;
        gemm_n = MAX_N;
    } else if (tile_rows >= 1 && tile_cols >= 1) {
        gemm_k = tile_rows * ((N_IN + tile_rows - 1) / tile_rows);
        gemm_n = tile_cols * ((N_HID + tile_cols - 1) / tile_cols);
    }
    if (opt(argc, argv, "--maxk", NULL))
        gemm_k = atoi(opt(argc, argv, "--maxk", NULL));
    if (opt(argc, argv, "--maxn", NULL))
        gemm_n = atoi(opt(argc, argv, "--maxn", NULL));
    if (tile_rows < 1 || tile_rows > 1023 || tile_cols < 1 || tile_cols > 1023 ||
        gemm_k < tile_rows || gemm_k > 65536 || gemm_k % tile_rows != 0 ||
        gemm_n < tile_cols || gemm_n > 65536 || gemm_n % tile_cols != 0) {
        fprintf(stderr, "pta_mnist: --rows and --cols are 1 to 1023, and --maxk and --maxn are "
                        "whole tiles of them\n");
        return 2;
    }
    g = gemm_alloc();
    if (!g || !bw || !a1 || load_net(path, net) != 0 || load_mnist(data, &tr, &te) != 0)
        return 2;
    H = net->hidden;

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

    if (host_setup(hn, net, &tr) != 0)
        return 2;
    if (cfg[0].adc_bits != 0)
        adc_setup(hn, net, &tr, (int)cfg[0].adc_bits, S);
    for (l = 1; l <= H; ++l)
        cfg[l] = cfg[0];
    for (l = 0; l <= H; ++l)
        cfg[l].adc_shift = (uint32_t)S[l];

    /*
     * Noise in LSB of an 8-bit ADC, whatever ADC the run has.  The clip rule
     * gives every width its own shift, so the same receiver noise is a
     * different number of LSB at each, and so is the same light: a layer's
     * 8-bit shift is found the way its own was, and the two differ by the
     * ratio of the LSBs.
     */
    if (thermal8 || photons8 || probing) {
        if ((thermal8 && atof(opt(argc, argv, "--thermal", "0")) != 0.0) ||
            (photons8 && photons > 0.0) || ((thermal8 || photons8) && cfg[0].adc_bits == 0)) {
            fprintf(stderr, "pta_mnist: --thermal8 and --photons8 need --adcbits, and replace "
                            "--thermal and --photons\n");
            return 2;
        }
        if (cfg[0].adc_bits != 0)
            adc_setup(hn, net, &tr, 8, S8);
        for (l = 0; l <= H; ++l) {
            const double lsb = ldexp(1.0, S[l] - S8[l]);     /* this ADC's LSB, in 8-bit LSB */
            if (thermal8 && q88("--thermal8", atof(thermal8) / lsb, 65535, &cfg[l].sigma_th) != 0)
                return 2;
            if (photons8 && atof(photons8) > 0.0 &&
                q88("--photons8", 1.0 / sqrt(atof(photons8) * lsb), 65535, &cfg[l].k_shot) != 0)
                return 2;
        }
    }
    if (probing) {
        for (l = 0; l <= H; ++l) {
            pq[l] = (int32_t *)malloc((size_t)layer_size(H, l) * sizeof(int32_t));
            if (!pq[l])
                return 2;
        }
        if (probe_init(&pr, images, H) != 0)
            return 2;
        quant_weights(hn, net->wbits, pq);
    }

    tile.rows  = tile_rows;
    tile.cols  = tile_cols;
    tile.din_w = net->din;
    tile.acc_w = ACC_W;
    if (pta_device_init(&dev, &tile) != 0)
        return 2;
    pta_model_reset(&dev, seed);
    if (cfg[0].impair & PTA_DRIFT)
        pta_drift_age(&dev, &cfg[0], steps);
    if (calibrate > 0 &&
        (calibrate_bank(&dev, &cfg[0], &tile, 0, seed ^ 0xCA11B, &gemm, calibrate, g) != 0 ||
         calibrate_bank(&dev, &cfg[1], &tile, 1, seed ^ 0xCA11B, &gemm, calibrate, g) != 0)) {
        fprintf(stderr, "pta_mnist: the calibration could not run\n");
        return 2;
    }
    if ((cfg[0].impair & PTA_DRIFT) && post_steps)
        pta_drift_age(&dev, &cfg[0], post_steps);

    for (l = 0; l <= H; ++l)
        per_image += (long)layer_out(H, l) * ((layer_in(l) + tile_rows - 1) / tile_rows);
    for (base = 0; base < images; base += MAX_M) {
        const int M = (images - base < MAX_M) ? images - base : MAX_M;
        const int64_t *y2 = bw->y[H];
        for (m = 0; m < M; ++m)
            for (k = 0; k < N_IN; ++k)
                a1[m * N_IN + k] = pixel_operand(te.x[(size_t)(base + m) * N_IN + k], net->din);
        if ((r = tile_batch(hn, cfg, &tile, &dev, seed, &gemm, g, M, a1, bw)) < 0) {
            fprintf(stderr, "pta_mnist: pta_gemm refused a GEMM\n");
            return 2;
        }
        sats += r;
        elements += (long)M * per_image;
        if (probing)
            probe_batch(&pr, hn, pq, M, a1, bw, te.y + base);
        for (m = 0; m < M; ++m) {
            int best = 0;
            for (o = 1; o < N_OUT; ++o)
                if (y2[m * N_OUT + o] + hn->b[H][o] > y2[m * N_OUT + best] + hn->b[H][best])
                    best = o;
            right += best == te.y[base + m];
        }
    }

    join_ints(s_txt, sizeof s_txt, S, H + 1);
    join_ints(sh_txt, sizeof sh_txt, hn->sh, H);
    printf("din=%d net_wbits=%d net_seed=%d from=%d epochs=%d digital=%.2f impair=0x%02x wbits=%u abits=%u "
           "adcbits=%u S=%s sh=%s thermal=%g photons=%g prog=%g xtalk=%g drift=%s hours=%g "
           "steps=%llu sigma_d=%u d_max=%u cal=%d trimstep=%g trimmax=%g post_hours=%g "
           "seed=%u images=%d correct=%d acc=%.2f sats=%ld elements=%ld",
           net->din, net->wbits, net->seed, net->from_bits, net->epochs, net->test_acc, cfg[0].impair, cfg[0].w_bits,
           cfg[0].act_bits, cfg[0].adc_bits, s_txt, sh_txt, cfg[0].sigma_th / 256.0, photons,
           cfg[0].sigma_pr / 256.0, cfg[0].xtalk / 256.0, drift, hours, (unsigned long long)steps,
           cfg[0].drift_sigma, cfg[0].drift_max, calibrate, cfg[0].trim_step / 256.0,
           cfg[0].trim_max / 256.0, post_hours, seed, images, right, 100.0 * right / images, sats,
           elements);
    if (H > 1)
        printf(" hidden=%d", H);
    /* Said only when it is not the core's, so that a line at the defaults is
     * the line it was before the tile could be anything else. */
    if (tile_rows != ROWS || tile_cols != COLS || gemm_k != MAX_K || gemm_n != MAX_N)
        printf(" tile=%dx%d gemm=%dx%d", tile_rows, tile_cols, gemm_k, gemm_n);
    if (probing) {
        probe_result pv;
        /* The run's noise in LSB of an 8-bit ADC, layer 1's, however it was asked for. */
        const double lsb = cfg[0].adc_bits ? ldexp(1.0, S[0] - S8[0]) : 0.0;
        const double ks = cfg[0].k_shot / 256.0;
        probe_finish(&pr, te.y, seed, &pv);
        join_ints(s8_txt, sizeof s8_txt, S8, H + 1);
        printf(" S8=%s thermal8=%g photons8=%g ref=%.2f agree=%.2f", s8_txt,
               cfg[0].sigma_th / 256.0 * lsb, (ks > 0.0 && lsb > 0.0) ? 1.0 / (ks * ks * lsb) : 0.0,
               pv.ref, pv.agree);
        for (l = 0; l <= H; ++l)
            printf(" e%d=%.5f", l + 1, pv.e[l]);
        printf(" eprop=%.5f elog=%.5f sigma=%.1f margin=%.1f pred_iid=%.2f pred_cov=%.2f gain=%+.4f "
               "eres=%.5f pred_res=%.2f",
               pv.eprop, pv.elog, pv.sigma, pv.margin, pv.pred_iid, pv.pred_cov, pv.gain, pv.eres,
               pv.pred_res);
        if (H > 1)
            for (l = 0; l <= H; ++l)
                printf(" t%d=%.5f", l + 1, pv.t[l]);
        probe_free(&pr);
        for (l = 0; l <= H; ++l)
            free(pq[l]);
    }
    printf("\n");
    pta_device_free(&dev);
    host_free(hn);
    mlp_free(net);
    gemm_free(g);
    free(bw);
    free(a1);
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
     *    quantisers, at both widths and then at three hidden layers, over a
     *    partial last batch */
    for (di = 0; di < 3; ++di) {
        const int D = dins[di < 2 ? di : 0], H = di < 2 ? 1 : 3;
        const int32_t lo = -(1 << (D - 1)), span = 1 << D;
        const pta_tile tile = {ROWS, COLS, D, ACC_W};
        host_net hn;
        gemm_buf *g = gemm_alloc();
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
        image_ws *ws = (image_ws *)malloc(sizeof *ws);
        int32_t *a1 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t)), *q[MAX_L];
        int pass, i, m, l, bad = 0;
        pta_device dev;
        pta_device_init(&dev, &tile);
        host_alloc(&hn, D, H);
        for (l = 0; l <= H; ++l) {
            const int P = layer_size(H, l);
            q[l] = (int32_t *)malloc((size_t)P * sizeof(int32_t));
            for (i = 0; i < P; ++i)
                hn.w[l][i] = lo + (int32_t)(splitmix64(&rs) % (uint64_t)span);
        }
        for (l = 0; l < H; ++l) {
            for (i = 0; i < N_HID; ++i)
                hn.b[l][i] = (int64_t)(splitmix64(&rs) % (1ull << (2 * D + 6))) - (1ll << (2 * D + 5));
            hn.sh[l] = D + 3 - l;       /* a different rescale a layer: an index off by one shows */
        }
        for (pass = 0; pass < 2; ++pass) {
            pta_cfg cfg[MAX_L];
            uint32_t gemm = 0;
            const int M = 37;
            memset(cfg, 0, sizeof cfg);
            if (pass == 1) {
                cfg[0].impair   = PTA_QUANT;
                cfg[0].w_bits   = 3;
                cfg[0].act_bits = (uint32_t)D - 3;
            }
            for (l = 1; l <= H; ++l)
                cfg[l] = cfg[0];
            for (i = 0; i < M * N_IN; ++i)
                a1[i] = (int32_t)(splitmix64(&rs) % (uint64_t)(1 << (D - 1)));
            if (tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0)
                ++bad;
            quant_weights(&hn, (int)cfg[0].w_bits, q);
            for (m = 0; m < M; ++m) {
                direct_image(&hn, q, (int)cfg[0].act_bits, a1 + m * N_IN, ws);
                for (l = 0; l <= H; ++l) {
                    const int out = layer_out(H, l);
                    bad += memcmp(ws->y[l], bw->y[l] + m * out, (size_t)out * sizeof(int64_t)) != 0;
                    if (l < H)
                        bad += memcmp(ws->a[l + 1], bw->a[l + 1] + m * N_HID,
                                      N_HID * sizeof(int32_t)) != 0;
                }
            }
            if (H == 1)
                printf("selftest: D=%d %s, %d images in %u GEMMs against direct sums: %d differ\n", D,
                       pass ? "QUANT B_w=3 B_a=D-3" : "no impairments", M, gemm, bad);
            else
                printf("selftest: D=%d %s, %d hidden layers, %d images in %u GEMMs against direct "
                       "sums: %d differ\n", D, pass ? "QUANT B_w=3 B_a=D-3" : "no impairments", H, M,
                       gemm, bad);
        }
        if (bad)
            errors += fail("the GEMM walk does not compute the network");
        pta_device_free(&dev);
        host_free(&hn);
        for (l = 0; l <= H; ++l)
            free(q[l]);
        gemm_free(g);
        free(bw);
        free(ws);
        free(a1);
    }

    /* 4. the probe: nothing impaired is no error at all, an impairment in one
     *    layer shows in that layer's own term and in no other's, nothing
     *    before it is disturbed, and what it does reaches the outputs as
     *    eprop and as nothing else -- at one hidden layer and at three */
    for (di = 0; di < 2; ++di) {
        const int D = 8, M = 37, H = di ? 3 : 1;
        const int32_t lo = -(1 << (D - 1)), span = 1 << D;
        const pta_tile tile = {ROWS, COLS, D, ACC_W};
        host_net hn;
        gemm_buf *g = gemm_alloc();
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
        int32_t *a1 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t)), *q[MAX_L];
        uint8_t labels[MAX_M];
        int which, i, l, bad = 0;
        pta_device dev;
        pta_device_init(&dev, &tile);
        host_alloc(&hn, D, H);
        for (l = 0; l <= H; ++l) {
            const int P = layer_size(H, l);
            q[l] = (int32_t *)malloc((size_t)P * sizeof(int32_t));
            for (i = 0; i < P; ++i)
                hn.w[l][i] = lo + (int32_t)(splitmix64(&rs) % (uint64_t)span);
        }
        for (l = 0; l < H; ++l)
            hn.sh[l] = D + 3 - l;
        quant_weights(&hn, 0, q);
        for (i = 0; i < M * N_IN; ++i)
            a1[i] = (int32_t)(splitmix64(&rs) % (uint64_t)(1 << (D - 1)));
        for (i = 0; i < M; ++i)
            labels[i] = (uint8_t)(splitmix64(&rs) % N_OUT);
        for (which = 0; which <= H + 1; ++which) {      /* nothing, then each layer alone */
            pta_cfg cfg[MAX_L];
            uint32_t gemm = 0;
            probe p;
            int ok = 1;
            memset(cfg, 0, sizeof cfg);
            if (which) {
                cfg[which - 1].impair   = PTA_QUANT;
                cfg[which - 1].act_bits = (uint32_t)D - 3;
            }
            probe_init(&p, M, H);
            if (tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0)
                ++bad;
            probe_batch(&p, &hn, q, M, a1, bw, labels);
            for (l = 0; l <= H; ++l) {
                ok &= (p.e[l] > 0.0) == (l == which - 1);       /* its own term, no other's */
                if (which == 0 || l < which - 1)
                    ok &= p.t[l] == 0.0;                        /* nothing before it moved */
            }
            if (which == 0)
                ok &= p.ep == 0.0 && p.agree == M;
            else if (which - 1 < H)
                ok &= p.ep > 0.0 && p.t[H] == p.ep;             /* it arrives, and only so */
            else
                ok &= p.ep == 0.0 && p.t[H] == p.e[H];
            if (which == 0)
                printf("selftest: probe, %d hidden, nothing impaired: no error anywhere: %s\n", H,
                       ok ? "as it should be" : "WRONG");
            else
                printf("selftest: probe, %d hidden, layer %d only: in its own term alone, %s at the "
                       "outputs: %s\n", H, which,
                       which - 1 < H ? "propagated" : "its own", ok ? "as it should be" : "WRONG");
            bad += !ok;
            probe_free(&p);
        }
        if (bad)
            errors += fail("the probe does not put an error in the layer that made it");
        pta_device_free(&dev);
        host_free(&hn);
        for (l = 0; l <= H; ++l)
            free(q[l]);
        gemm_free(g);
        free(bw);
        free(a1);
    }

    /* 5. the probe's own arithmetic: its Gaussian has unit variance, and its
     *    Cholesky factor multiplies back to the matrix it was given */
    {
        double a[N_OUT][N_OUT], b[N_OUT][N_OUT], l[N_OUT][N_OUT], s1 = 0.0, s2 = 0.0, worst = 0.0;
        const int draws = 200000;
        int i, j, k;
        for (i = 0; i < draws; ++i) {
            const double x = gauss01(&rs);
            s1 += x;
            s2 += x * x;
        }
        s1 /= draws;
        s2 = s2 / draws - s1 * s1;
        for (i = 0; i < N_OUT; ++i)
            for (j = 0; j < N_OUT; ++j)
                b[i][j] = uniform01(&rs) - 0.5;
        for (i = 0; i < N_OUT; ++i)
            for (j = 0; j < N_OUT; ++j) {
                a[i][j] = i == j ? 0.5 : 0.0;
                for (k = 0; k < N_OUT; ++k)
                    a[i][j] += b[i][k] * b[j][k];
            }
        cholesky(a, l);
        for (i = 0; i < N_OUT; ++i)
            for (j = 0; j < N_OUT; ++j) {
                double s = -a[i][j];
                for (k = 0; k < N_OUT; ++k)
                    s += l[i][k] * l[j][k];
                if (fabs(s) > worst)
                    worst = fabs(s);
            }
        printf("selftest: probe, %d Gaussian draws: mean %+.4f variance %.4f; Cholesky off by %.1e\n",
               draws, s1, s2, worst);
        if (fabs(s1) > 0.01 || fabs(s2 - 1.0) > 0.02 || worst > 1e-9)
            errors += fail("the probe's Gaussian or its Cholesky factor is wrong");
    }

    /* 6. a network of one hidden layer is laid out as this harness always
     *    wrote it: 48 bytes of header, then w and b for each layer */
    {
        const long want = 48 + 4L * (N_HID * N_IN + N_HID + N_OUT * N_HID + N_OUT);
        const int ok = net_bytes(1) == want && want == 318088 && HEAD_BYTES == 48 &&
                       net_bytes(2) == want + 4 + 4L * (N_HID * N_HID + N_HID);
        printf("selftest: a one-hidden-layer network is %ld bytes after a %d-byte header: %s\n",
               net_bytes(1), (int)HEAD_BYTES, ok ? "as it always was" : "CHANGED");
        if (!ok)
            errors += fail("the network file's layout has moved");
    }

    /* 7. the tile and the cut.  With nothing impaired a network's sums are
     *    the same on every tile at every cut.  With the quantisers on they
     *    depend on the tile, which is what a shot is, and not on the cut,
     *    which is only where one GEMM ends and the next begins. */
    {
        static const int geo[][4] = {     /* rows, cols, most K, most N */
            {8, 8, 256, 8},     /* the core's, as everything before was run */
            {8, 8, 784, 104},   /* its tile, a layer a GEMM */
            {256, 64, 1024, 128},
            {256, 64, 256, 64}, /* that tile, a tile a GEMM */
            {64, 8, 832, 104},
            {16, 4, 32, 8},
        };
        enum { GEOS = sizeof geo / sizeof geo[0] };
        const int D = 8, M = 19, H = 2;
        const int32_t lo = -(1 << (D - 1)), span = 1 << D;
        host_net hn;
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
        int64_t *first = (int64_t *)malloc(2 * GEOS * M * N_OUT * sizeof *first);
        int32_t *a1 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t));
        int gi, quant, i, l, clear_same = 1, cut_same = 1, tile_matters = 0, ran = 1;

        host_alloc(&hn, D, H);
        for (l = 0; l <= H; ++l)
            for (i = 0; i < layer_size(H, l); ++i)
                hn.w[l][i] = lo + (int32_t)(splitmix64(&rs) % (uint64_t)span);
        for (l = 0; l < H; ++l)
            hn.sh[l] = D + 3 - l;
        for (i = 0; i < M * N_IN; ++i)
            a1[i] = (int32_t)(splitmix64(&rs) % (uint64_t)(1 << (D - 1)));
        for (quant = 0; quant < 2; ++quant)
            for (gi = 0; gi < GEOS; ++gi) {
                int64_t *y = first + (size_t)(quant * GEOS + gi) * M * N_OUT;
                pta_tile tile;
                pta_device dev;
                pta_cfg cfg[MAX_L];
                gemm_buf *g;
                uint32_t gemm = 0;
                tile_rows = geo[gi][0];
                tile_cols = geo[gi][1];
                gemm_k    = geo[gi][2];
                gemm_n    = geo[gi][3];
                tile.rows = tile_rows;
                tile.cols = tile_cols;
                tile.din_w = D;
                tile.acc_w = ACC_W;
                g = gemm_alloc();
                pta_device_init(&dev, &tile);
                pta_model_reset(&dev, 0);
                memset(cfg, 0, sizeof cfg);
                for (l = 0; quant && l <= H; ++l) {
                    cfg[l].impair    = PTA_QUANT;
                    cfg[l].act_bits  = 6;
                    cfg[l].w_bits    = 6;
                    cfg[l].adc_bits  = 7;
                    cfg[l].adc_shift = 14;   /* for a 256-input sum; coarse for 8, and the same for all */
                }
                if (!g || tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0)
                    ran = 0;
                memcpy(y, bw->y[H], (size_t)M * N_OUT * sizeof *y);
                pta_device_free(&dev);
                gemm_free(g);
            }
        for (gi = 1; gi < GEOS; ++gi)
            clear_same &= memcmp(first, first + (size_t)gi * M * N_OUT,
                                 (size_t)M * N_OUT * sizeof *first) == 0;
        /* quantised: 0 and 1 are one tile at two cuts, and so are 2 and 3 */
        {
            const int64_t *q0 = first + (size_t)GEOS * M * N_OUT;
            const size_t one = (size_t)M * N_OUT, bytes = one * sizeof *first;
            cut_same &= memcmp(q0, q0 + one, bytes) == 0;
            cut_same &= memcmp(q0 + 2 * one, q0 + 3 * one, bytes) == 0;
            tile_matters = memcmp(q0, q0 + 2 * one, bytes) != 0 &&
                           memcmp(q0, q0 + 4 * one, bytes) != 0 &&
                           memcmp(q0 + 2 * one, q0 + 4 * one, bytes) != 0;
        }
        printf("selftest: %d tiles and cuts, nothing impaired: the last layer's sums are the same on "
               "all: %s\n", (int)GEOS, ran && clear_same ? "as it should be" : "WRONG");
        printf("selftest: the quantisers on: one tile at two cuts %s, and three tiles %s\n",
               cut_same ? "agrees" : "DISAGREES", tile_matters ? "do not" : "AGREE, which they should not");
        if (!ran || !clear_same)
            errors += fail("a network's sums depend on the tile or the cut with nothing impaired");
        if (!cut_same)
            errors += fail("a layer's cut into GEMMs changes what its shots see");
        if (!tile_matters)
            errors += fail("the tile's size does not reach the quantised sums");
        host_free(&hn);
        free(bw);
        free(first);
        free(a1);
    }

    /* 8. the calibration, on a tile of more than 64 cells.  Drift alone, so a
     *    probe reads each cell exactly: after it, a probe reads what the trim's
     *    step leaves, on every cell and not on the first 64. */
    {
        const int D = 8;
        pta_tile tile;
        pta_device dev;
        pta_cfg cfg;
        gemm_buf *g;
        uint32_t gemm = 0;
        int64_t before = 0, after = 0, after_late = 0, before_late = 0;
        int pass, r, c, rc;

        tile_rows = 16;
        tile_cols = 12;                 /* 192 cells */
        gemm_k = 16;
        gemm_n = 12;
        tile.rows = tile_rows;
        tile.cols = tile_cols;
        tile.din_w = D;
        tile.acc_w = ACC_W;
        g = gemm_alloc();
        pta_device_init(&dev, &tile);
        pta_model_reset(&dev, 99);
        memset(&cfg, 0, sizeof cfg);
        cfg.impair = PTA_DRIFT;
        drift_fit(&cfg, 5.0);                           /* TFLN's, the larger */
        cfg.trim_step = 64;                             /* a quarter of a weight LSB */
        cfg.trim_max  = 128 << 8;
        pta_drift_age(&dev, &cfg, hours_to_steps(TEST_HOURS));
        rc = g ? 0 : -1;
        for (pass = 0; rc == 0 && pass < 2; ++pass) {
            int64_t worst = 0, late = 0;
            memset(g->B, 0, (size_t)tile_rows * tile_cols * sizeof g->B[0]);
            memset(g->A, 0, (size_t)tile_rows * tile_rows * sizeof g->A[0]);
            for (r = 0; r < tile_rows; ++r)
                g->A[r * tile_rows + r] = (1 << (D - 1)) - 1;
            cfg.seed = gemm_seed(5, gemm++);
            if (pta_gemm(&cfg, &tile, &dev, 0, tile_rows, tile_cols, tile_rows, g->A, g->B, g->C) < 0)
                rc = -1;
            for (r = 0; r < tile_rows; ++r)
                for (c = 0; c < tile_cols; ++c) {
                    const int64_t v = g->C[r * tile_cols + c] < 0 ? -g->C[r * tile_cols + c]
                                                                  : g->C[r * tile_cols + c];
                    if (v > worst)
                        worst = v;
                    if (r * tile_cols + c >= 64 && v > late)
                        late = v;
                }
            if (pass == 0) {
                before = worst;
                before_late = late;
                if (calibrate_bank(&dev, &cfg, &tile, 0, 5, &gemm, 1, g) != 0)
                    rc = -1;
            } else {
                after = worst;
                after_late = late;
            }
        }
        /* a probe of 127 on a residue of at most half a trim step, 32 / 256 of an LSB */
        printf("selftest: calibration on a %d x %d tile: a probe read %lld before and %lld after; past "
               "the 64th cell, %lld and %lld: %s\n", tile_rows, tile_cols, (long long)before,
               (long long)after, (long long)before_late, (long long)after_late,
               rc == 0 && before > 200 && before_late > 200 && after <= 16 && after_late <= 16
                   ? "corrected, all of it" : "WRONG");
        if (rc != 0 || before <= 200 || before_late <= 200 || after > 16 || after_late > 16)
            errors += fail("the calibration does not reach every cell of a tile");
        pta_device_free(&dev);
        gemm_free(g);
    }
    tile_rows = ROWS;
    tile_cols = COLS;
    gemm_k = MAX_K;
    gemm_n = MAX_N;

    printf("selftest %s\n", errors ? "FAILED" : "passed");
    return errors ? 1 : 0;
}

static void help(void)
{
    printf("pta_mnist selftest\n"
           "pta_mnist train --data DIR --din 8|16 --wbits B --seed S --out NET [--from NET] [--verbose 1]\n"
           "  --hidden H      hidden layers, each 100 wide (1, which is D3; up to 8)\n"
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
           "  --thermal8 X    thermal sigma in LSB of an 8-bit ADC, whatever --adcbits is\n"
           "  --photons8 P    photons per LSB of an 8-bit ADC, likewise\n"
           "  --rows R --cols C   the tile: inputs a shot sums, outputs it yields (8, 8)\n"
           "  --maxk K --maxn N   the most a GEMM takes, in whole tiles (256, 8 on the 8 x 8\n"
           "                  tile; a whole layer on any other, which is one command)\n"
           "  --probe 1       add each layer's error against the network's own sums, the run's\n"
           "                  noise in 8-bit LSB, and the accuracy that error alone predicts\n"
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
