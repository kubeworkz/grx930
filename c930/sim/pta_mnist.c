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
 * And the light, which is not the tile's (eval --src, --srcline, --srcflat).
 * grxcp's board makes the tile a ring bank lit by a comb, and the error model
 * has no term for a source at all.  Its error is added here, on the host's
 * side of the line, to the sums the tile returns: first order, and outside
 * the contract.  Design note section 5 has what a source may do before it
 * costs what a row of the budget does.  A comb's lines can be read (eval
 * --levelprobe), the reading applied where a chip could apply it
 * (--levelfix), and what that leaves told apart (--levelpart, --levellayer).
 *
 * And the receiver's noise as one laser fixes it (eval --thermalline).  A
 * receiver's noise is a current.  --thermal and --thermal8 give it in LSB, a
 * layer at a time and each at that layer's own shift, which is as if every
 * layer had the light its own sums ask for.  A tile has one laser, and an
 * input at full scale through a weight of one puts the same light on a
 * detector whatever the layer.  --thermalline gives the noise as a fraction of
 * that, the same in every layer, and design note section 5 has what a laser
 * of a given size then costs.
 *
 * And how a network is put on the tile, where the host has a choice (eval
 * --hidshift, --w1gain).  A converter's full scale is set where a layer's sums
 * fall, and they fall where its operands do, so operands that are small leave
 * most of a tile's light unused.  The host sets two of them: each hidden
 * layer's rescale, and the scale the first layer's weights are written at.
 * Both can be made larger, and both then clip.  Design note section 5 has what
 * that buys of a laser.
 *
 *   pta_mnist selftest
 *   pta_mnist train --data DIR --din D --wbits B --seed S --out NET [--from NET] [--hidden H]
 *                   [--sumnoise F] [--epochs N]
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
 * How a network is put on the tile, where the host has a choice:
 *
 *   hid_shift  added to every hidden layer's rescale, after the clip rule has
 *              set it.  -1 hands the next layer operands twice as large, and
 *              the largest of them clip at full scale
 *   w1_gain    the first layer's weights written 2^w1_gain as large,
 *              saturating at the ends of their range.  The hidden rescale
 *              takes the gain back, so the network is what it was except in
 *              the weights that clipped
 *
 * Both are zero unless eval is told, and host_setup() is then what it was.
 * It leaves what each clipped here: of the hidden units that fire, the share
 * that reach full scale, a layer; and of the first layer's weights, the share
 * that saturate.
 */
static int    hid_shift = 0, w1_gain = 0;
static double hid_clip[MAX_HID], w1_clip;

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

/* An idx image file, in memory, with every pixel taken from 255: the same
 * pictures with the page lit and the ink dark.  Nothing else about a workload
 * changes, so what a run on it does differently is what the light does.
 * Returns the pixels inverted, or -1 if b is not 28 x 28 images. */
static long invert_idx(uint8_t *b, long len)
{
    long i;
    if (!b || len < 16 || be32(b) != 2051 || be32(b + 8) != 28 || be32(b + 12) != 28 ||
        len != 16 + (long)be32(b + 4) * N_IN)
        return -1;
    for (i = 16; i < len; ++i)
        b[i] = (uint8_t)(255 - b[i]);
    return len - 16;
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

static double gauss01(uint64_t *s);

#define SUM_TRACK 0.01          /* how fast a layer's mean square follows its batches */

/* One sum's noise in training: frac of the layer's rms, sqrt(ms).  Adds the
 * sum's square to the batch's and the noise's square to the epoch's, so that
 * what was put on can be reported beside what was asked for. */
static float sum_noise(double sum, double frac, double ms, uint64_t *rng, double *bsq, double *nsq)
{
    const double e = frac * sqrt(ms) * gauss01(rng);
    *bsq += sum * sum;
    *nsq += e * e;
    return (float)e;
}

/* What train() did besides train: the noise it put on each layer's sums, as a
 * fraction of their rms, over the last epoch it ran.  Zeros if it put none. */
typedef struct {
    double got[MAX_L];
} train_report;

/* Trains net, already allocated for its depth, at wbits: from Glorot or, if
 * start is given, from start's weights.
 *
 * sumnoise is the tile, as a network being trained can be shown it.  A tile
 * returns each layer's sums with an error on them, and the probe measures that
 * error as a fraction of the sums' rms (section 5: about a tenth at v1).  With
 * sumnoise F every sum of every layer, before its bias, is given Gaussian noise
 * of F times that layer's rms, drawn afresh for each image at each step.  The
 * rms is the layer's own, tracked as training moves it.  The gradient is taken
 * through the noisy sums.  Nothing else changes, and at F of zero nothing does:
 * no draw is made and the network is the one this always trained.
 *
 * epochs, if it is not zero, is how many to run, in place of stopping when the
 * held-out accuracy first fails to rise. */
static void train(mlp *net, const dataset *tr, const dataset *te, int din, int wbits, int seed,
                  const mlp *start, int verbose, double sumnoise, int epochs, train_report *rep)
{
    const int H = net->hidden, L = H + 1;
    uint64_t ri = 0x243F6A8885A308D3ull ^ (uint64_t)(uint32_t)seed;                /* init */
    uint64_t rs = 0x13198A2E03707344ull ^ (uint64_t)(uint32_t)seed ^ ((uint64_t)wbits << 32);
    uint64_t rn = 0xA4093822299F31D0ull ^ (uint64_t)(uint32_t)seed ^ ((uint64_t)wbits << 32);  /* noise */
    double ms[MAX_L], bsq[MAX_L], nsq[MAX_L], ssq[MAX_L];    /* a layer's mean square; a batch's, the epoch's */
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
    memset(rep, 0, sizeof *rep);
    memset(ms, 0, sizeof ms);

    for (epoch = 0; epoch < MAX_EPOCHS; ++epoch) {
        int first;
        memset(nsq, 0, sizeof nsq);
        memset(ssq, 0, sizeof ssq);
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
            memset(bsq, 0, sizeof bsq);
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
                    if (sumnoise > 0.0)
                        zz += sum_noise(zz - net->b[0][n], sumnoise, ms[0], &rn, &bsq[0], &nsq[0]);
                    z[0][n] = zz;
                    h[0][n] = zz > 0.0f ? zz : 0.0f;
                }
                for (l = 1; l < H; ++l)
                    for (n = 0; n < N_HID; ++n) {
                        const float *row = wq[l] + n * N_HID;
                        float zz = net->b[l][n];
                        for (k = 0; k < N_HID; ++k)
                            zz += row[k] * h[l - 1][k];
                        if (sumnoise > 0.0)
                            zz += sum_noise(zz - net->b[l][n], sumnoise, ms[l], &rn, &bsq[l], &nsq[l]);
                        z[l][n] = zz;
                        h[l][n] = zz > 0.0f ? zz : 0.0f;
                    }
                zmax = -1e30f;
                for (o = 0; o < N_OUT; ++o) {
                    float zz = net->b[H][o];
                    for (n = 0; n < N_HID; ++n)
                        zz += wq[H][o * N_HID + n] * h[H - 1][n];
                    if (sumnoise > 0.0)
                        zz += sum_noise(zz - net->b[H][o], sumnoise, ms[H], &rn, &bsq[H], &nsq[H]);
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
            /* a layer's mean square follows the batches: the first sets it, and
             * so the first batch of all is trained without noise */
            if (sumnoise > 0.0)
                for (l = 0; l < L; ++l) {
                    const double now = bsq[l] / ((double)bs * layer_out(H, l));
                    ssq[l] += bsq[l];
                    ms[l] = (t == 1) ? now : (1.0 - SUM_TRACK) * ms[l] + SUM_TRACK * now;
                }
        }
        for (l = 0; l < L; ++l)
            rep->got[l] = ssq[l] > 0.0 ? sqrt(nsq[l] / ssq[l]) : 0.0;
        for (l = 0; l < L; ++l)
            quantise(net->w[l], wq[l], layer_size(H, l), din, wbits);
        net->val_acc = digital_accuracy(net, wq, tr, N_TRAIN, N_ALL - N_TRAIN);
        net->epochs  = epoch + 1;
        if (verbose)
            fprintf(stderr, "  epoch %d: held out %.2f%%\n", epoch + 1, net->val_acc);
        if (epochs > 0) {
            if (epoch + 1 >= epochs)
                break;
        } else if (net->val_acc > best)
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
 * The light.  A source does three things to a line's power, and each is an rms
 * fraction of it:
 *
 *   all    every line together, anew each shot: a pump's noise, or an amplifier's
 *   line   each line on its own, anew each shot
 *   flat   each line on its own and fixed for the run: lines that are not level
 *
 * A line lights one input row on every bus, so the rows of a tile are cut into
 * `buses` equal runs and rows a run apart share a line.  And what a line's
 * light reaches a column through depends on how the tile signs a weight, which
 * nothing has settled: through the weight alone, as a balanced pair of
 * photodiodes has it, or through the weight and an offset the host takes off
 * again, as one photodiode would.
 *
 * So a shot's sum gains  sum over rows of  a * (w + offset) * error(row's line),
 * with a and w as the tile quantises them.  It is first order: the error meets
 * the weight as written, not its programming error, its drift or its
 * neighbours.  And it is added after the converter, where it is neither
 * clipped nor quantised; with half an LSB of receiver noise ahead of it a
 * converter would pass it in the mean.  Under the offset reading the converter
 * would also have to span the offset, which this does not model.
 *
 * A shot's draws are its image's, its layer's and its tile's, so neither the
 * cut nor the batch moves one.  With no light set up, tile_batch() is what it
 * was.
 *
 * What the level probe reads can also be applied where a chip could apply it,
 * in place of being taken off this model's own record of a line: on the
 * weights as the host writes them, or on the inputs as it sends them, a row at
 * a time.  level_apply() sets that up, and with none set up tile_batch() is
 * again what it was.
 *
 * And what a correction on the weights leaves can be told apart: the tile
 * keeps the network it was given, and the sums take what the rewritten
 * weights would have been off by, a part of it at a time.  level_parts() sets
 * that up.
 */
enum { FIX_NONE = 0, FIX_WEIGHTS, FIX_WEIGHTS8, FIX_INPUTS };

/* what a correction on the weights leaves, a part at a time: level_parts() */
enum { PART_READ = 1, PART_ROUND = 2, PART_RAIL = 4, PART_ALL = 7 };

static struct {
    int      on;
    double   all, line, flat;
    int      buses, offset;
    uint32_t seed;
    int      base;              /* the batch's first image: the caller's to set */
    int      lines;             /* tile_rows / buses */
    double  *level;             /* flat's draw, a line */
    double  *eps;               /* a shot's error, a line */
    double  *ae;                /* and its activations, each times its line's error */
    int32_t *wq[MAX_L];         /* the weights as the tile quantises them */
    /* a correction from what the level probe read: level_apply() */
    int      keep;              /* the probe keeps its readings and leaves the lines alone */
    int      fix;               /* where they are applied: FIX_NONE, or one of the others */
    double  *read;              /* a line's level as the probe read it */
    double  *scale;             /* what that line's rows are scaled by */
    double   gain;              /* what the scaling takes off every sum; 1 if nothing */
    int32_t *as;                /* a layer's inputs as scaled, a batch of them */
    long     scaled, clipped;   /* weights or inputs scaled, of those not zero; and of
                                   those, the ones raised and held back by the rail */
    /* what a correction on the weights leaves, told apart: level_parts() */
    int      apart;             /* the tile keeps the network, and the sums take dw */
    double  *dw[MAX_L];         /* a layer's weights: what is left on each, in its LSB */
    long     moved[MAX_L];      /* a layer's weights that are not zero */
    long     held[MAX_L];       /* and of those, the ones raised and held back by the rail */
} light;

static double gauss01(uint64_t *s);

static void light_free(void)
{
    int l;
    free(light.level);
    free(light.eps);
    free(light.ae);
    free(light.read);
    free(light.scale);
    free(light.as);
    for (l = 0; l < MAX_L; ++l) {
        free(light.wq[l]);
        free(light.dw[l]);
    }
    memset(&light, 0, sizeof light);
}

/* The weights as the tile quantises them, for the light's term: a network's, or
 * the same network's as a correction has rewritten them.  Returns 0, or -1. */
static int light_weights(const host_net *hn, const pta_cfg *cfg)
{
    int i, l;

    for (l = 0; l <= hn->hidden; ++l) {
        const int P = layer_size(hn->hidden, l);
        const int quant = (cfg[l].impair & PTA_QUANT) != 0;
        if (!light.wq[l])
            light.wq[l] = (int32_t *)malloc((size_t)P * sizeof(int32_t));
        if (!light.wq[l])
            return -1;
        for (i = 0; i < P; ++i)
            light.wq[l][i] = quant ? contract_quant(hn->w[l][i], (int)cfg[l].w_bits, hn->din)
                                   : hn->w[l][i];
    }
    return 0;
}

/* Returns 0, or -1 if the buses do not divide the tile's rows or memory ran out.
 * cfg is the run's, a layer each: the term uses each layer's own quantisers. */
static int light_setup(const host_net *hn, const pta_cfg *cfg, uint32_t seed, double all,
                       double line, double flat, int buses, int offset)
{
    uint64_t s = ((uint64_t)seed << 32) | 0x11697u;
    int i;

    light_free();
    if (buses < 1 || tile_rows % buses != 0)
        return -1;
    light.all    = all;
    light.line   = line;
    light.flat   = flat;
    light.buses  = buses;
    light.offset = offset;
    light.seed   = seed;
    light.lines  = tile_rows / buses;
    light.level  = (double *)malloc((size_t)light.lines * sizeof *light.level);
    light.eps    = (double *)malloc((size_t)light.lines * sizeof *light.eps);
    light.ae     = (double *)malloc((size_t)tile_rows * sizeof *light.ae);
    light.read   = (double *)calloc((size_t)light.lines, sizeof *light.read);
    light.scale  = (double *)calloc((size_t)light.lines, sizeof *light.scale);
    if (!light.level || !light.eps || !light.ae || !light.read || !light.scale ||
        light_weights(hn, cfg) != 0) {
        light_free();
        return -1;
    }
    for (i = 0; i < light.lines; ++i)
        light.level[i] = flat * gauss01(&s);
    light.on = 1;
    return 0;
}

/* Layer l's share, for M images whose operands are a: added to its sums y. */
static void light_add(const host_net *hn, const pta_cfg *c, int l, int M, const int32_t *a,
                      int64_t *y)
{
    const int in = layer_in(l), out = layer_out(hn->hidden, l), D = hn->din;
    const int quant = (c->impair & PTA_QUANT) != 0;
    const double off = light.offset ? ldexp(1.0, D - 1) : 0.0;   /* a weight of one */
    int n0, k0, m, n, k;

    for (n0 = 0; n0 < out; n0 += tile_cols)
        for (k0 = 0; k0 < in; k0 += tile_rows) {
            const int N = (out - n0 < tile_cols) ? out - n0 : tile_cols;
            const int K = (in - k0 < tile_rows) ? in - k0 : tile_rows;
            for (m = 0; m < M; ++m) {
                /* one shot */
                uint64_t s = ((uint64_t)light.seed << 32) | (uint32_t)(light.base + m);
                const uint64_t h = splitmix64(&s);
                double all;
                int live = 0;
                s = h ^ (((uint64_t)l << 48) | ((uint64_t)(n0 / tile_cols) << 24) |
                         (uint64_t)(k0 / tile_rows));
                all = light.all > 0.0 ? light.all * gauss01(&s) : 0.0;
                for (k = 0; k < light.lines; ++k)
                    light.eps[k] = light.level[k] + all +
                                   (light.line > 0.0 ? light.line * gauss01(&s) : 0.0);
                for (k = 0; k < K; ++k) {
                    const int32_t av = a[m * in + k0 + k];
                    const int32_t xa = quant ? contract_quant(av, (int)c->act_bits, D) : av;
                    /* told apart, a weight's share is worked out already: level_parts() */
                    light.ae[k] = light.apart ? (double)xa : xa * light.eps[k % light.lines];
                    live |= xa != 0;
                }
                if (!live)
                    continue;
                for (n = 0; n < N; ++n) {
                    const int32_t *w = light.wq[l] + (size_t)(n0 + n) * in + k0;
                    double d = 0.0;
                    if (light.apart) {
                        const double *dw = light.dw[l] + (size_t)(n0 + n) * in + k0;
                        for (k = 0; k < K; ++k)
                            d += light.ae[k] * dw[k];
                    } else {
                        for (k = 0; k < K; ++k)
                            d += light.ae[k] * (w[k] + off);
                    }
                    y[m * out + n0 + n] += (int64_t)floor(d + 0.5);
                }
            }
        }
}

/* Whether a value rounded to `bits` as the contract rounds it would pass the
 * rail and be held there.  bits = 0 is the operand's own width. */
static int past_rail(double v, int bits, int din)
{
    const int b = (bits == 0 || bits >= din) ? din : bits;
    const int h = din - b;
    const double code = floor((v + (h ? ldexp(1.0, h - 1) : 0.0)) / ldexp(1.0, h));
    const double lim = ldexp(1.0, b - 1);
    return code > lim - 1.0 || code < -lim;
}

/* A value held inside an operand's range. */
static int32_t in_range(double v, int din)
{
    const double hi = ldexp(1.0, din - 1) - 1.0, lo = -ldexp(1.0, din - 1);
    return (int32_t)(v > hi ? hi : v < lo ? lo : v);
}

/*
 * A layer's operands as a host that has read the lines sends them: each scaled
 * for its row's line, rounded, and held at full scale where that would take it
 * past.  c is the layer's: an activation the tile quantises is at the rail when
 * its code is.  Counted as held back: one the scaling raised and the rail then
 * stopped.
 */
static const int32_t *level_inputs(const host_net *hn, const pta_cfg *c, int M, int in,
                                   const int32_t *a)
{
    const int bits = (c->impair & PTA_QUANT) ? (int)c->act_bits : 0;
    int m, j;

    for (m = 0; m < M; ++m)
        for (j = 0; j < in; ++j) {
            const int32_t av = a[m * in + j];
            const double v = floor(av * light.scale[(j % tile_rows) % light.lines] + 0.5);
            if (av != 0) {
                ++light.scaled;
                light.clipped += fabs(v) > fabs((double)av) && past_rail(v, bits, hn->din);
            }
            light.as[m * in + j] = in_range(v, hn->din);
        }
    return light.as;
}

/*
 * M images, their input operands a0 (M x 784), through the tile: bw->y[l] are
 * layer l's GEMM sums before the biases and bw->a[l], for l >= 1, the operands
 * layer l was given.  Layer l runs on weight bank l & 1, and every GEMM takes
 * the next seed.  Returns ADC saturations, or -1.  If a light is set up its
 * share is in the sums, and so in every operand after the first layer's.  If a
 * correction for its lines is applied on the inputs, a layer's operands are
 * scaled before they are sent, and what the scaling takes off its sums is
 * divided out of them: bw->a[l] stays what the host worked out, unscaled.
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
        if (light.on && light.fix == FIX_INPUTS)
            src = level_inputs(hn, &cfg[l], M, in, src);
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
        if (light.on)
            light_add(hn, &cfg[l], l, M, src, y);
        if (light.on && light.fix != FIX_NONE && light.gain != 1.0)
            for (m = 0; m < M * out; ++m)
                y[m] = (int64_t)floor((double)y[m] / light.gain + 0.5);
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

/*
 * The level probe.  Nothing else here measures a line's level: the cell probe
 * above reads each cell through a weight of zero, which a line's power
 * multiplies and so says nothing of.  This reads it through a weight that is
 * not zero.  A row at full scale against a full-scale weight on every column,
 * with its neighbours' weights at zero so that crosstalk brings it nothing,
 * and a shot's sum over what was asked for is one plus that line's error: its
 * level, and the source's noise that shot.  `repeats` shots a row average the
 * noise; a line lights a row on every bus, and every column of a shot reads
 * it.
 *
 * What it reads it takes off the line's level, to a step of 1 / LEVEL_STEP:
 * the host scales that line's inputs by it.  First order, as the light's own
 * term is.
 *
 * It draws from a seed of its own and takes none of the run's GEMM seeds, so
 * a run meets the same noise with the probe and without it.  The cell
 * calibration is not built that way, and `refcal` is what that cost to find.
 * It writes no trim and ages nothing.  With drift on, its shots are counted on
 * the drift clock as any shot is, `repeats` times the tile's rows of them,
 * against a step of 2^31.
 *
 * Returns 0, or -1 if it could not run: no light, a light through an offset,
 * or no shots.  *found and *left are the rms of the lines' levels before it
 * and after.
 *
 * With light.keep set it takes nothing off: the lines stay as they are, what
 * it read is kept for level_apply(), and *left is what scaling each line's
 * rows by its reading would leave.
 */
#define LEVEL_STEP 256.0
#define LEVEL_FLOOR 0.05        /* a line read under this share of its level is not scaled back */

static int level_probe(pta_device *dev, const pta_cfg *cfg, const pta_tile *tile, uint32_t seed,
                       int repeats, gemm_buf *g, double *found, double *left)
{
    const int k = tile->rows, n = tile->cols;
    const int32_t full = (int32_t)((((int64_t)1 << (tile->din_w - 1)) - 1));
    const int quant = (cfg->impair & PTA_QUANT) != 0;
    const int64_t pa = quant ? contract_quant(full, (int)cfg->act_bits, tile->din_w) : full;
    const int64_t pw = quant ? contract_quant(full, (int)cfg->w_bits, tile->din_w) : full;
    const int quantised = quant && cfg->adc_bits != 0;
    const int64_t codes = quantised ? (((int64_t)1 << (cfg->adc_bits - 1)) - 1) : 0;
    const double asked = (double)pa * (double)pw;
    const uint32_t own = seed ^ 0x1E7E1u;
    uint32_t count = 0;                 /* its own GEMMs: the run's counter is not touched */
    double *sum;
    pta_cfg c = *cfg;
    int parity, rep, r, col, shot, s, i;

    if (!light.on || light.offset || repeats < 1 || pa == 0 || pw == 0 || k < 2)
        return -1;
    sum = (double *)calloc((size_t)light.lines, sizeof *sum);
    if (!sum)
        return -1;
    /* a range with room for a line at twice its level */
    for (s = 0; quantised && s < 40 && 2 * pa * pw > (codes << s); ++s)
        ;
    c.adc_shift = (uint32_t)(quantised ? s : 0);
    *found = 0.0;
    for (i = 0; i < light.lines; ++i)
        *found += light.level[i] * light.level[i];
    for (parity = 0; parity < 2; ++parity) {
        const int rows = (k - parity + 1) / 2;          /* the rows of this parity */
        memset(g->B, 0, (size_t)k * n * sizeof g->B[0]);
        for (r = parity; r < k; r += 2)
            for (col = 0; col < n; ++col)
                g->B[r * n + col] = (int32_t)pw;
        memset(g->A, 0, (size_t)rows * k * sizeof g->A[0]);
        for (shot = 0; shot < rows; ++shot)
            g->A[shot * k + parity + 2 * shot] = full;  /* one row a shot */
        for (rep = 0; rep < repeats; ++rep) {
            c.seed = gemm_seed(own, count);
            if (pta_gemm(&c, tile, dev, 0, rows, n, k, g->A, g->B, g->C) < 0) {
                free(sum);
                return -1;
            }
            for (shot = 0; shot < rows; ++shot) {
                const int line = (parity + 2 * shot) % light.lines;
                uint64_t st = ((uint64_t)own << 32) | (uint32_t)(count * (uint32_t)k + (uint32_t)shot);
                double eps, lit, got = 0.0;
                st = splitmix64(&st);
                eps = light.level[line] + (light.all > 0.0 ? light.all * gauss01(&st) : 0.0);
                eps += light.line > 0.0 ? light.line * gauss01(&st) : 0.0;
                lit = floor(asked * eps + 0.5);         /* the light's share, as light_add() rounds it */
                for (col = 0; col < n; ++col)
                    got += (double)g->C[shot * n + col] + lit;
                sum[line] += got / (n * asked) - 1.0;
            }
            ++count;
        }
    }
    *left = 0.0;
    for (i = 0; i < light.lines; ++i) {
        const double read = floor(sum[i] / ((double)repeats * light.buses) * LEVEL_STEP + 0.5) / LEVEL_STEP;
        if (light.keep) {
            const double after = 1.0 + read < LEVEL_FLOOR ? 1.0 : (1.0 + light.level[i]) / (1.0 + read) - 1.0;
            light.read[i] = read;
            *left += after * after;
        } else {
            light.level[i] -= read;
            *left += light.level[i] * light.level[i];
        }
    }
    *found = sqrt(*found / light.lines);
    *left  = sqrt(*left / light.lines);
    free(sum);
    return 0;
}

/*
 * What the level probe read, applied where a chip could apply it.  The model
 * above takes a reading off its own record of the line, exactly; no chip can.
 * A host that has read the lines can do two things with a reading r, and both
 * are a row at a time, a row's line being its own on every bus:
 *
 *   on the weights  write every weight of the row as w / (1 + r).  FIX_WEIGHTS
 *                   scales the weights as the host has them and leaves the
 *                   tile to quantise them to its w_bits, as it does any
 *                   weight.  FIX_WEIGHTS8 quantises them first, to the weights
 *                   the network was trained for, scales those, and writes them
 *                   at the operand's full width: the 8 bits grxcp's
 *                   calibration note puts behind a 6-bit weight code
 *   on the inputs   send every input of the row as a / (1 + r): FIX_INPUTS
 *
 * A dim line's row has to be raised, and a weight or an input at the rail
 * cannot be.  Either it is held there, and that much is left uncorrected; or,
 * with to_dimmest, every row is scaled down to the dimmest line's, nothing is
 * raised, and every sum comes out smaller by that line's 1 + r, which
 * tile_batch() divides out again.  That costs light: the converter sees less
 * of everything.
 *
 * out receives the rewritten network when the weights are, and cfg its w_bits
 * for FIX_WEIGHTS8.  Returns the network to give the tile, which is hn itself
 * when the inputs are scaled; or NULL if it could not: no reading kept, a
 * light through an offset, a line read under LEVEL_FLOOR of its level, or no
 * memory.
 */
static const host_net *level_apply(host_net *out, const host_net *hn, pta_cfg *cfg, int fix,
                                   int to_dimmest)
{
    const int D = hn->din, H = hn->hidden;
    double ref;
    int i, l, n, j;

    if (!light.on || !light.keep || light.offset || fix == FIX_NONE)
        return NULL;
    ref = 1.0 + light.read[0];
    for (i = 0; i < light.lines; ++i) {
        if (1.0 + light.read[i] < LEVEL_FLOOR)
            return NULL;
        if (1.0 + light.read[i] < ref)
            ref = 1.0 + light.read[i];
    }
    if (!to_dimmest)
        ref = 1.0;
    for (i = 0; i < light.lines; ++i)
        light.scale[i] = ref / (1.0 + light.read[i]);
    light.gain   = ref;
    light.fix    = fix;
    light.scaled = light.clipped = 0;
    if (fix == FIX_INPUTS) {
        light.as = (int32_t *)malloc((size_t)MAX_M * N_IN * sizeof(int32_t));
        return light.as ? hn : NULL;
    }
    if (host_alloc(out, D, H) != 0)
        return NULL;
    for (l = 0; l < H; ++l)
        out->sh[l] = hn->sh[l];
    for (l = 0; l <= H; ++l) {
        const int in = layer_in(l), outs = layer_out(H, l);
        const int bits = (cfg[l].impair & PTA_QUANT) ? (int)cfg[l].w_bits : 0;
        for (n = 0; n < outs; ++n) {
            out->b[l][n] = hn->b[l][n];
            for (j = 0; j < in; ++j) {
                const int32_t w = hn->w[l][n * in + j];
                const int32_t from = fix == FIX_WEIGHTS8 ? contract_quant(w, bits, D) : w;
                const double v = floor(from * light.scale[(j % tile_rows) % light.lines] + 0.5);
                if (from != 0) {
                    ++light.scaled;
                    light.clipped += fabs(v) > fabs((double)from) &&
                                     past_rail(v, fix == FIX_WEIGHTS8 ? 0 : bits, D);
                }
                out->w[l][n * in + j] = in_range(v, D);
            }
        }
    }
    if (fix == FIX_WEIGHTS8)
        for (l = 0; l <= H; ++l)
            cfg[l].w_bits = (uint32_t)D;
    return light_weights(out, cfg) == 0 ? out : NULL;
}

/*
 * What a correction on the weights at 8 bits leaves, told apart.  A weight the
 * network was trained for, q, on a line at 1 + e that was read as 1 + r, is
 * written as c = rail(round(u)) with u = q / (1 + r), and through its line it
 * comes to (1 + e) c.  That is off q by three things, which add to it:
 *
 *   the read    (1 + e) u - q               what the reading missed
 *   the round   (1 + e) (round(u) - u)      what writing it at 8 bits dropped
 *   the rail    (1 + e) (c - round(u))      what a weight at the rail was not
 *                                           raised by
 *
 * level_parts() works them out for every weight and rewrites nothing: the tile
 * keeps the network as it was, at the tile's own bits.  light_add() then adds
 * the parts asked for to a layer's sums in place of the light's share, in the
 * one layer asked for or in every layer, and nothing in the others.  So a run
 * with no part is the run with no source, shot for shot, and a run with a
 * part differs from it by that part and by nothing else: no weight on the
 * tile moved, so no draw met another weight.  It is after the converter, as
 * the light's share is.  With all three in every layer it is FIX_WEIGHTS8's
 * correction as a detector would see it, which is not as this model's tile
 * does: that converts the sums of the weights as rewritten and has the
 * light's share added after.
 *
 * For a still source only: a shot's noise would meet the weights as written.
 * `layer` is a layer from 0, or -1 for every layer.  The rail is counted as
 * level_apply() counts it, a layer at a time, whatever was asked for.  Returns
 * 0, or -1 if it could not: no reading kept, a light through an offset, noise
 * on the source, a part or a layer there is none of, a line read under
 * LEVEL_FLOOR of its level, or no memory.
 */
static int level_parts(const host_net *hn, const pta_cfg *cfg, int parts, int layer)
{
    const int D = hn->din, H = hn->hidden;
    int i, l, n, j;

    if (!light.on || !light.keep || light.offset || light.all != 0.0 || light.line != 0.0 ||
        parts < 0 || (parts & ~PART_ALL) || layer < -1 || layer > H)
        return -1;
    for (i = 0; i < light.lines; ++i)
        if (1.0 + light.read[i] < LEVEL_FLOOR)
            return -1;
    for (i = 0; i < light.lines; ++i)
        light.scale[i] = 1.0 / (1.0 + light.read[i]);
    light.gain   = 1.0;
    light.scaled = light.clipped = 0;
    for (l = 0; l <= H; ++l) {
        const int in = layer_in(l), outs = layer_out(H, l);
        const int bits = (cfg[l].impair & PTA_QUANT) ? (int)cfg[l].w_bits : 0;
        const int here = layer < 0 || layer == l;
        if (!light.dw[l])
            light.dw[l] = (double *)malloc((size_t)outs * in * sizeof(double));
        if (!light.dw[l])
            return -1;
        light.moved[l] = light.held[l] = 0;
        for (n = 0; n < outs; ++n)
            for (j = 0; j < in; ++j) {
                const int line = (j % tile_rows) % light.lines;
                const double q = (double)contract_quant(hn->w[l][n * in + j], bits, D);
                const double u = q * light.scale[line];
                const double v = floor(u + 0.5);
                const double c = (double)in_range(v, D);
                const double lit = 1.0 + light.level[line];
                double d = 0.0;
                if (q != 0.0) {
                    ++light.moved[l];
                    light.held[l] += fabs(v) > fabs(q) && past_rail(v, 0, D);
                }
                if (here && (parts & PART_READ))
                    d += lit * u - q;
                if (here && (parts & PART_ROUND))
                    d += lit * (v - u);
                if (here && (parts & PART_RAIL))
                    d += lit * (c - v);
                light.dw[l][n * in + j] = d;
            }
        light.scaled  += light.moved[l];
        light.clipped += light.held[l];
    }
    light.apart = 1;
    return 0;
}

/* --levelpart's list: the parts it names, as PART_* together, and 0 for
 * "none"; or -1 if it is not one: a name there is none of, a part named
 * twice, or nothing. */
static int part_list(const char *s)
{
    static const char *const name[3] = {"read", "round", "rail"};
    int parts = 0, i;

    if (strcmp(s, "none") == 0)
        return 0;
    for (;;) {
        const char *e = strchr(s, ',');
        const size_t n = e ? (size_t)(e - s) : strlen(s);
        for (i = 0; i < 3; ++i)
            if (strlen(name[i]) == n && strncmp(s, name[i], n) == 0)
                break;
        if (i == 3 || (parts & (1 << i)))
            return -1;
        parts |= 1 << i;
        if (!e)
            return parts;
        s = e + 1;
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
 * each hidden layer's rescale, set on training images with the weights as
 * trained.  A layer's rescale needs the layers before it settled, so they are
 * set in order.  Allocates hn.  Returns 0, or -1 if out of memory.
 */
static int host_setup(host_net *hn, const mlp *net, const dataset *tr)
{
    const int D = net->din, H = net->hidden;
    const double a_s = ldexp(1.0, D - 1) - 1.0, w_s = ldexp(1.0, D - 1);
    const int64_t amax = ((int64_t)1 << (D - 1)) - 1;
    int32_t a1[N_IN], *q[MAX_L] = {NULL};
    image_ws *ws = (image_ws *)malloc(sizeof *ws);
    double scale = a_s;         /* operand units per unit of this layer's input */
    int i, n, k, l;

    if (!ws || host_alloc(hn, D, H) != 0)
        return -1;
    for (l = 0; l <= H; ++l) {
        const int P = layer_size(H, l);
        const double g = l == 0 ? ldexp(1.0, w1_gain) : 1.0;
        long clipped = 0;
        q[l] = (int32_t *)malloc((size_t)P * sizeof(int32_t));
        if (!q[l])
            return -1;
        for (i = 0; i < P; ++i) {
            const double v = floor(net->w[l][i] * g * w_s + 0.5);
            hn->w[l][i] = weight_operand(net->w[l][i] * g, D);
            clipped += v > w_s - 1.0 || v < -w_s;
        }
        if (l == 0)
            w1_clip = (double)clipped / P;
    }
    quant_weights(hn, net->wbits, q);
    for (l = 0; l < H; ++l) {
        const double g = l == 0 ? ldexp(1.0, w1_gain) : 1.0;
        long hist[64] = {0}, total = 0, over = 0;
        int s;
        for (n = 0; n < N_HID; ++n)
            hn->b[l][n] = llround(net->b[l][n] * scale * w_s * g);
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
        hn->sh[l] = shift_for(hist, total) + hid_shift;
        if (hn->sh[l] < 0)
            hn->sh[l] = 0;
        for (s = hn->sh[l] + 1; s < 64; ++s)
            over += hist[s];
        hid_clip[l] = total ? (double)over / total : 0.0;
        scale = scale * w_s * g / ldexp(1.0, hn->sh[l]);
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
        "--verbose", "--hidden", "--sumnoise", "--epochs", NULL};
    const char *data = opt(argc, argv, "--data", NULL), *out = opt(argc, argv, "--out", NULL);
    const char *from = opt(argc, argv, "--from", NULL);
    const int din = atoi(opt(argc, argv, "--din", "16")), wbits = atoi(opt(argc, argv, "--wbits", "0"));
    const int seed = atoi(opt(argc, argv, "--seed", "1"));
    const int hidden = atoi(opt(argc, argv, "--hidden", "1"));
    const char *noise_opt = opt(argc, argv, "--sumnoise", NULL), *epochs_opt = opt(argc, argv, "--epochs", NULL);
    const double sumnoise = noise_opt ? atof(noise_opt) : 0.0;
    const int epochs = epochs_opt ? atoi(epochs_opt) : 0;
    train_report rep;
    dataset tr, te;
    mlp net, from_net, *start = NULL;
    int l;
    if (check_opts(argc, argv, names) != 0 || !data || !out || (din != 8 && din != 16) ||
        wbits < 0 || wbits > din || hidden < 1 || hidden > MAX_HID ||
        sumnoise < 0.0 || sumnoise > 1.0 || epochs < 0 || epochs > MAX_EPOCHS) {
        fprintf(stderr, "pta_mnist train: --data DIR --din 8|16 --wbits 0..D --seed S --out NET "
                        "[--from NET] [--hidden 1..%d] [--sumnoise 0..1] [--epochs 0..%d]\n",
                MAX_HID, MAX_EPOCHS);
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
    train(&net, &tr, &te, din, wbits, seed, start, atoi(opt(argc, argv, "--verbose", "0")), sumnoise,
          epochs, &rep);
    if (save_net(out, &net) != 0) {
        fprintf(stderr, "pta_mnist: cannot write %s\n", out);
        return 2;
    }
    printf("din=%d wbits=%d seed=%d from=%d from_epochs=%d epochs=%d held_out=%.2f digital=%.2f",
           din, wbits, seed, net.from_bits, net.from_epochs, net.epochs, net.val_acc, net.test_acc);
    if (hidden > 1)
        printf(" hidden=%d", hidden);
    /* Said only when asked for, so that a line without them is the line it was. */
    if (noise_opt) {
        printf(" sumnoise=%g got=", sumnoise);
        for (l = 0; l <= hidden; ++l)
            printf("%s%.4f", l ? "," : "", rep.got[l]);
    }
    if (epochs_opt)
        printf(" fixed_epochs=%d", epochs);
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

/* One line's light at a detector, in a sum's units: an input at full scale
 * through a weight of one. */
static double line_light(int din)
{
    return (ldexp(1.0, din - 1) - 1.0) * ldexp(1.0, din - 1);
}

/* Noise that is `x` of that, in LSB of an ADC whose LSB is 2^S of a sum's units. */
static double line_lsb(double x, int din, int S)
{
    return x * line_light(din) / ldexp(1.0, S);
}

/*
 * The light a shot sends a column, in lines: its inputs summed, each as a
 * fraction of full scale.  It does not depend on the weights.  A ring sends a
 * line's light to one photodiode of a pair or to the other, so this is what
 * the pair carries between them whatever the sum comes to, and it is what
 * their shot noise and their currents follow.  One figure a shot: an image and
 * a K tile.
 */
typedef struct {
    double sum[MAX_L], max[MAX_L];
    long   shots[MAX_L];
} lit_stats;

static void lit_batch(lit_stats *ls, const host_net *hn, const pta_cfg *cfg, int M,
                      const int32_t *a0, const batch_ws *bw)
{
    const double full = ldexp(1.0, hn->din - 1) - 1.0;
    int l, m, k0, k;

    for (l = 0; l <= hn->hidden; ++l) {
        const int in = layer_in(l);
        const int32_t *a = l == 0 ? a0 : bw->a[l];
        const int quant = (cfg[l].impair & PTA_QUANT) != 0;
        for (m = 0; m < M; ++m)
            for (k0 = 0; k0 < in; k0 += tile_rows) {
                const int K = (in - k0 < tile_rows) ? in - k0 : tile_rows;
                double s = 0.0;
                for (k = 0; k < K; ++k) {
                    const int32_t av = a[m * in + k0 + k];
                    s += quant ? contract_quant(av, (int)cfg[l].act_bits, hn->din) : av;
                }
                s /= full;
                ls->sum[l] += s;
                ++ls->shots[l];
                if (s > ls->max[l])
                    ls->max[l] = s;
            }
    }
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
        "--probe", "--thermal8", "--photons8", "--rows", "--cols", "--maxk", "--maxn", "--src",
        "--srcline", "--srcflat", "--buses", "--srcsign", "--thermalline", "--hidshift",
        "--w1gain", "--levelprobe", "--levelfix", "--levelref", "--levelpart", "--levellayer",
        NULL};
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
    const char *thermalline = opt(argc, argv, "--thermalline", NULL);
    const char *hidshift = opt(argc, argv, "--hidshift", NULL);
    const char *w1gain = opt(argc, argv, "--w1gain", NULL);
    lit_stats lit_s;
    const double src_all = atof(opt(argc, argv, "--src", "0"));
    const double src_line = atof(opt(argc, argv, "--srcline", "0"));
    const double src_flat = atof(opt(argc, argv, "--srcflat", "0"));
    const char *src_sign = opt(argc, argv, "--srcsign", "pair");
    const int buses = atoi(opt(argc, argv, "--buses", "1"));
    const int levelprobe = atoi(opt(argc, argv, "--levelprobe", "0"));
    const char *levelfix = opt(argc, argv, "--levelfix", "ideal");
    const char *levelref = opt(argc, argv, "--levelref", "none");
    const int fix = strcmp(levelfix, "weights") == 0 ? FIX_WEIGHTS
                  : strcmp(levelfix, "weights8") == 0 ? FIX_WEIGHTS8
                  : strcmp(levelfix, "inputs") == 0 ? FIX_INPUTS : FIX_NONE;
    const int to_dimmest = strcmp(levelref, "dimmest") == 0;
    const char *levelpart = opt(argc, argv, "--levelpart", NULL);
    const int parts = levelpart ? part_list(levelpart) : -1;
    const int levellayer = atoi(opt(argc, argv, "--levellayer", "0"));
    const int lit = src_all != 0.0 || src_line != 0.0 || src_flat != 0.0;
    probe pr;
    int32_t *pq[MAX_L] = {NULL};
    int S[MAX_L] = {0}, S8[MAX_L] = {0};
    dataset tr, te;
    mlp net_s, *net = &net_s;
    host_net hn_s, *hn = &hn_s;
    host_net hf_s;
    const host_net *ht = hn;    /* the network the tile is given: hn, or hn as a correction rewrote it */
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
    double level_found = 0.0, level_left = 0.0;
    int right = 0, base, m, k, o, l, H;

    memset(&pr, 0, sizeof pr);
    memset(&lit_s, 0, sizeof lit_s);
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
    if (src_all < 0.0 || src_all >= 1.0 || src_line < 0.0 || src_line >= 1.0 || src_flat < 0.0 ||
        src_flat >= 1.0 || buses < 1 || tile_rows % buses != 0 ||
        (strcmp(src_sign, "pair") != 0 && strcmp(src_sign, "offset") != 0)) {
        fprintf(stderr, "pta_mnist: --src, --srcline and --srcflat are rms fractions under 1, "
                        "--buses divides --rows, and --srcsign is pair or offset\n");
        return 2;
    }
    if ((fix == FIX_NONE && strcmp(levelfix, "ideal") != 0) ||
        (!to_dimmest && strcmp(levelref, "none") != 0) || (fix == FIX_NONE && to_dimmest) ||
        (fix != FIX_NONE && levelprobe <= 0)) {
        fprintf(stderr, "pta_mnist: --levelfix is ideal, weights, weights8 or inputs, --levelref is "
                        "none or dimmest, and anything but ideal and none needs --levelprobe\n");
        return 2;
    }
    if ((levelpart && (parts < 0 || fix != FIX_WEIGHTS8 || to_dimmest || src_all != 0.0 ||
                       src_line != 0.0)) ||
        levellayer < 0 || (!levelpart && levellayer != 0)) {
        fprintf(stderr, "pta_mnist: --levelpart is none or a list of read, round and rail, and needs "
                        "--levelfix weights8 held at the rail and a source with no noise; "
                        "--levellayer is a layer from 1, or 0 for every layer, and needs --levelpart\n");
        return 2;
    }
    /* The probe GEMM reads a cell through a weight of zero, where a pair sees
     * no light at all and an offset sees the offset's: not modelled. */
    if (lit && calibrate > 0 && strcmp(src_sign, "offset") == 0) {
        fprintf(stderr, "pta_mnist: --calibrate is not modelled under --srcsign offset\n");
        return 2;
    }
    g = gemm_alloc();
    if (!g || !bw || !a1 || load_net(path, net) != 0 || load_mnist(data, &tr, &te) != 0)
        return 2;
    H = net->hidden;
    if (levellayer > H + 1) {
        fprintf(stderr, "pta_mnist: --levellayer is a layer of the network, from 1\n");
        return 2;
    }

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

    hid_shift = hidshift ? atoi(hidshift) : 0;
    w1_gain   = w1gain ? atoi(w1gain) : 0;
    if (hid_shift < -8 || hid_shift > 8 || w1_gain < 0 || w1_gain > 6) {
        fprintf(stderr, "pta_mnist: --hidshift is -8 to 8 and --w1gain is 0 to 6\n");
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
    /*
     * And noise as a laser fixes it: one fraction of a line's light, and so a
     * different number of LSB in each layer.  A layer whose sums are small has
     * a fine LSB and more of them.
     */
    if (thermalline) {
        if (thermal8 || atof(opt(argc, argv, "--thermal", "0")) != 0.0 || cfg[0].adc_bits == 0) {
            fprintf(stderr, "pta_mnist: --thermalline needs --adcbits, and replaces --thermal and "
                            "--thermal8\n");
            return 2;
        }
        for (l = 0; l <= H; ++l)
            if (q88("--thermalline", line_lsb(atof(thermalline), net->din, S[l]), 65535,
                    &cfg[l].sigma_th) != 0)
                return 2;
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

    if (lit && light_setup(hn, cfg, seed, src_all, src_line, src_flat, buses,
                           strcmp(src_sign, "offset") == 0) != 0)
        return 2;
    if (lit)
        light.keep = fix != FIX_NONE;
    /* The lines' levels, read once the light is lit and before the first image. */
    if (levelprobe != 0 &&
        (levelprobe < 0 || !lit ||
         level_probe(&dev, &cfg[0], &tile, seed, levelprobe, g, &level_found, &level_left) != 0)) {
        fprintf(stderr, "pta_mnist: --levelprobe takes shots a row, and needs a light through a pair\n");
        return 2;
    }
    /* And applied where a chip could, if it is not to come off the model's own line. */
    if (fix != FIX_NONE && !levelpart &&
        (ht = level_apply(&hf_s, hn, cfg, fix, to_dimmest)) == NULL) {
        fprintf(stderr, "pta_mnist: --levelfix could not be applied: a line was read under a "
                        "twentieth of its level\n");
        return 2;
    }
    /* Or told apart: the tile keeps the network, and its sums take what was asked for. */
    if (levelpart && level_parts(hn, cfg, parts, levellayer - 1) != 0) {
        fprintf(stderr, "pta_mnist: --levelpart could not be applied: a line was read under a "
                        "twentieth of its level\n");
        return 2;
    }
    for (l = 0; l <= H; ++l)
        per_image += (long)layer_out(H, l) * ((layer_in(l) + tile_rows - 1) / tile_rows);
    for (base = 0; base < images; base += MAX_M) {
        const int M = (images - base < MAX_M) ? images - base : MAX_M;
        const int64_t *y2 = bw->y[H];
        light.base = base;
        for (m = 0; m < M; ++m)
            for (k = 0; k < N_IN; ++k)
                a1[m * N_IN + k] = pixel_operand(te.x[(size_t)(base + m) * N_IN + k], net->din);
        if ((r = tile_batch(ht, cfg, &tile, &dev, seed, &gemm, g, M, a1, bw)) < 0) {
            fprintf(stderr, "pta_mnist: pta_gemm refused a GEMM\n");
            return 2;
        }
        sats += r;
        elements += (long)M * per_image;
        if (probing)
            probe_batch(&pr, hn, pq, M, a1, bw, te.y + base);
        if (thermalline)
            lit_batch(&lit_s, hn, cfg, M, a1, bw);
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
    /* And the light only when there is some. */
    if (lit)
        printf(" src=%g srcline=%g srcflat=%g buses=%d srcsign=%s", src_all, src_line, src_flat,
               buses, src_sign);
    /* And the level probe only when it was taken: what the lines were, and what it left. */
    if (levelprobe)
        printf(" levelprobe=%d level_found=%.4f level_left=%.4f", levelprobe, level_found,
               level_left);
    /* And where it was applied, when that is not the model's own line: what the scaling
     * took off every sum, and the share of what it scaled that the rail held back. */
    if (fix != FIX_NONE)
        printf(" levelfix=%s levelref=%s level_gain=%.4f level_clip=%.5f", levelfix, levelref,
               light.gain, light.scaled ? (double)light.clipped / light.scaled : 0.0);
    /* And what of that was told apart, and where: with a layer's weights that are
     * not zero, and those of them the rail held back. */
    if (levelpart) {
        printf(" levelpart=%s levellayer=%d level_moved=", levelpart, levellayer);
        for (l = 0; l <= H; ++l)
            printf("%s%ld", l ? "," : "", light.moved[l]);
        printf(" level_held=");
        for (l = 0; l <= H; ++l)
            printf("%s%ld", l ? "," : "", light.held[l]);
    }
    /* The noise as a laser fixes it, and what that is in each layer's own LSB:
     * `thermal` earlier in the line is the first layer's. */
    if (thermalline) {
        printf(" thermalline=%g thermal_l=", atof(thermalline));
        for (l = 0; l <= H; ++l)
            printf("%s%g", l ? "," : "", cfg[l].sigma_th / 256.0);
        /* and the light a shot sends a column, in lines: mean and most, a layer */
        printf(" lit=");
        for (l = 0; l <= H; ++l)
            printf("%s%.3f", l ? "," : "", lit_s.shots[l] ? lit_s.sum[l] / lit_s.shots[l] : 0.0);
        printf(" litmax=");
        for (l = 0; l <= H; ++l)
            printf("%s%.2f", l ? "," : "", lit_s.max[l]);
    }
    /* How the network was put on the tile, and what that clipped, when asked. */
    if (hidshift || w1gain) {
        printf(" hidshift=%d hidclip=", hid_shift);
        for (l = 0; l < H; ++l)
            printf("%s%.5f", l ? "," : "", hid_clip[l]);
        printf(" w1gain=%d w1clip=%.5f", w1_gain, w1_clip);
    }
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
    light_free();
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

/* selftest's: is d[i] one fraction of y[i] for every i of n, to the rounding
 * of a sum and of the fraction itself?  *frac is that fraction. */
static int same_fraction(const int64_t *d, const int64_t *y, int n, double *frac)
{
    int i, ref = 0;
    for (i = 1; i < n; ++i)
        if (llabs(y[i]) > llabs(y[ref]))
            ref = i;
    *frac = y[ref] ? (double)d[ref] / (double)y[ref] : 0.0;
    for (i = 0; i < n; ++i)
        if (fabs((double)d[i] - *frac * (double)y[i]) > 1.0 + 1e-9)
            return 0;
    return 1;
}

/* selftest's: M images from `base` through a fresh device, with whatever light
 * is set up.  Returns 0, or -1. */
static int light_run(const host_net *hn, const pta_cfg *cfg, const pta_tile *tile, int M, int base,
                     const int32_t *a, batch_ws *bw)
{
    gemm_buf *g = gemm_alloc();
    pta_device dev;
    uint32_t gemm = 0;
    int rc;

    if (!g || pta_device_init(&dev, tile) != 0) {
        gemm_free(g);
        return -1;
    }
    pta_model_reset(&dev, 0);
    light.base = base;
    rc = tile_batch(hn, cfg, tile, &dev, 7, &gemm, g, M, a, bw) < 0 ? -1 : 0;
    pta_device_free(&dev);
    gemm_free(g);
    return rc;
}

/* selftest's: how far a run's sums are from the exact product of the operands
 * it was given with the weights the network was trained for, a layer at a
 * time: rms over rms.  hn and cfg are the network's and the tile's as they were
 * before any correction rewrote them. */
static void level_error(const host_net *hn, const pta_cfg *cfg, int M, const int32_t *a0,
                        const batch_ws *bw, double *e)
{
    const int D = hn->din, H = hn->hidden;
    int l, m, n, j;

    for (l = 0; l <= H; ++l) {
        const int in = layer_in(l), out = layer_out(H, l);
        const int quant = (cfg[l].impair & PTA_QUANT) != 0;
        const int32_t *src = l == 0 ? a0 : bw->a[l];
        double se = 0.0, sy = 0.0;
        for (m = 0; m < M; ++m)
            for (n = 0; n < out; ++n) {
                int64_t exact = 0;
                double d;
                for (j = 0; j < in; ++j) {
                    const int32_t av = src[m * in + j], wv = hn->w[l][n * in + j];
                    exact += (int64_t)(quant ? contract_quant(av, (int)cfg[l].act_bits, D) : av) *
                             (quant ? contract_quant(wv, (int)cfg[l].w_bits, D) : wv);
                }
                d = (double)bw->y[l][m * out + n] - (double)exact;
                se += d * d;
                sy += (double)exact * (double)exact;
            }
        e[l] = sy > 0.0 ? sqrt(se / sy) : 0.0;
    }
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

    /* 8b. the level probe.  With crosstalk on, nothing else impaired and the
     *     source still, a shot through a full-scale weight reads its line's
     *     level exactly, its neighbours' weights being zero.  So after it the
     *     light's share of a row's sum, as light_add() has it, is within half
     *     the probe's step on every row: the line the probe corrected is the
     *     line that lights that row.  With a line's own noise on, what it
     *     leaves is that noise over the root of the shots a line gets, a row
     *     on every bus, and a line's own: not one error on them all.  Level
     *     lines are left level.  It refuses a light it
     *     cannot read: none, or one through an offset.  And it leaves the
     *     tile as it found it. */
    {
        const int D = 8, H = 1, R = 16, NB = 4;
        const int32_t full = (1 << (D - 1)) - 1;
        const double sigma = 0.2, noise = 0.05;
        const double step = 1.0 / 256.0;        /* the probe's, written out: its own cannot move this */
        pta_tile tile;
        pta_device dev;
        pta_cfg cfg[MAX_L];
        host_net hz;
        gemm_buf *g;
        int32_t *a;
        int64_t *y;
        double found = 0.0, left = 0.0, before = 0.0, worst = 0.0, quiet = 0.0, noisy = 0.0;
        double flat = 1.0, apart = 0.0, mean = 0.0, want;
        int ran = 1, refused = 1, pass, r, c, i;

        tile_rows = 64;
        tile_cols = 12;
        gemm_k = 64;
        gemm_n = 12;
        tile.rows = tile_rows;
        tile.cols = tile_cols;
        tile.din_w = D;
        tile.acc_w = ACC_W;
        g = gemm_alloc();
        ran &= host_alloc(&hz, D, H) == 0;
        a = (int32_t *)calloc((size_t)layer_in(0), sizeof *a);
        y = (int64_t *)calloc((size_t)layer_out(H, 0), sizeof *y);
        pta_device_init(&dev, &tile);
        pta_model_reset(&dev, 99);
        memset(cfg, 0, sizeof cfg);
        ran &= g != NULL && a != NULL && y != NULL;
        /* a first layer whose first tile is all weights of full scale */
        for (c = 0; ran && c < tile_cols; ++c)
            for (r = 0; r < tile_rows; ++r)
                hz.w[0][c * layer_in(0) + r] = full;
        /* no light, and a light through an offset */
        light_free();
        refused &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) != 0;
        ran &= light_setup(&hz, cfg, 7, 0.0, 0.0, sigma, NB, 1) == 0;
        refused &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) != 0;
        /* a still source, through a tile whose rows leak 2% into their
         * neighbours: one shot a row reads it.  The light's share of each
         * row's sum, over what the row asked for, before the probe and after */
        cfg[0].impair = PTA_XTALK;
        cfg[0].xtalk  = 5;
        ran &= light_setup(&hz, cfg, 7, 0.0, 0.0, sigma, NB, 0) == 0;
        for (pass = 0; ran && pass < 2; ++pass) {
            double most = 0.0;
            for (r = 0; r < tile_rows; ++r) {
                memset(a, 0, (size_t)layer_in(0) * sizeof *a);
                memset(y, 0, (size_t)layer_out(H, 0) * sizeof *y);
                a[r] = full;
                light.base = 0;
                light_add(&hz, &cfg[0], 0, 1, a, y);
                for (c = 0; c < tile_cols; ++c) {
                    const double share = fabs((double)y[c]) / ((double)full * full);
                    if (share > most)
                        most = share;
                }
            }
            if (pass == 0) {
                before = most;
                ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &quiet, &left) == 0;
            } else {
                worst = most;
            }
        }
        /* a line's own noise: R shots a row, on NB buses */
        ran &= light_setup(&hz, cfg, 7, 0.0, noise, sigma, NB, 0) == 0;
        ran &= level_probe(&dev, &cfg[0], &tile, 7, R, g, &found, &noisy) == 0;
        /* and line by line: what is left on one line is not what is left on the next */
        for (i = 0; ran && i < light.lines; ++i)
            mean += light.level[i] / light.lines;
        for (i = 0; ran && i < light.lines; ++i)
            apart += (light.level[i] - mean) * (light.level[i] - mean) / (light.lines - 1);
        apart = sqrt(apart);
        /* level lines */
        ran &= light_setup(&hz, cfg, 7, 0.0, 0.0, 0.0, NB, 0) == 0;
        ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &flat) == 0;
        want = sqrt(noise * noise / (R * NB) + step * step / 12.0);
        printf("selftest: the level probe: lines %.3f rms off put up to %.3f of a row's sum on it, and "
               "%.5f once read with the source still; with a line's noise of %.2f, %d shots a row on %d "
               "buses leave %.4f, and %.4f from line to line, for %.4f; level lines are left %.5f; no "
               "light, or an offset's: %s: %s\n",
               quiet, before, worst, noise, R, NB, noisy, apart, want, flat,
               refused ? "refused" : "TAKEN",
               ran && refused && quiet > sigma / 2 && before > sigma / 2 && worst <= 0.5 * step + 1e-4 &&
               noisy > want / 1.3 && noisy < want * 1.3 && apart > want / 1.3 && apart < want * 1.3 &&
               flat == 0.0 ? "as it should be" : "WRONG");
        if (!ran || !refused || quiet <= sigma / 2 || before <= sigma / 2 || worst > 0.5 * step + 1e-4)
            errors += fail("the level probe does not read a still line's level");
        if (noisy <= want / 1.3 || noisy >= want * 1.3 || apart <= want / 1.3 || apart >= want * 1.3 ||
            flat != 0.0)
            errors += fail("the level probe leaves more or less than the source's noise");
        /* And it leaves the tile as it found it.  Drifted and with a
         * programming error on, a GEMM at one seed gives the same sums before
         * the probe and after it; and the drift clock has counted the probe's
         * shots, R times the tile's rows, and nothing else. */
        {
            int64_t *was = (int64_t *)malloc((size_t)tile_rows * tile_cols * sizeof *was);
            uint32_t clock0 = 0, clock1 = 0;
            int same = 1;

            cfg[0].impair   = PTA_DRIFT | PTA_PROG_ERR;
            cfg[0].sigma_pr = 256;
            drift_fit(&cfg[0], 5.0);
            pta_drift_age(&dev, &cfg[0], hours_to_steps(TEST_HOURS));
            ran &= was != NULL && light_setup(&hz, cfg, 7, 0.0, noise, sigma, NB, 0) == 0;
            for (pass = 0; ran && pass < 2; ++pass) {
                memset(g->A, 0, (size_t)tile_rows * tile_rows * sizeof g->A[0]);
                for (r = 0; r < tile_rows; ++r) {
                    g->A[r * tile_rows + r] = full;
                    for (c = 0; c < tile_cols; ++c)
                        g->B[r * tile_cols + c] = (r * 7 + c * 3) % 31 - 15;
                }
                cfg[0].seed = gemm_seed(5, 0);
                ran &= pta_gemm(&cfg[0], &tile, &dev, 0, tile_rows, tile_cols, tile_rows, g->A, g->B,
                                g->C) >= 0;
                for (i = 0; i < tile_rows * tile_cols; ++i) {
                    if (pass == 0)
                        was[i] = (int64_t)g->C[i];
                    else
                        same &= was[i] == (int64_t)g->C[i];
                }
                if (pass == 0) {
                    clock0 = dev.count;
                    ran &= level_probe(&dev, &cfg[0], &tile, 7, R, g, &found, &left) == 0;
                    clock1 = dev.count;
                }
            }
            printf("selftest: the level probe leaves the tile as it found it: drifted and with a "
                   "programming error on, a GEMM's sums are %s before it and after, and the drift "
                   "clock counted %u shots for %d: %s\n", same ? "the same" : "DIFFERENT",
                   (unsigned)(clock1 - clock0), R * tile_rows,
                   ran && same && clock1 - clock0 == (uint32_t)(R * tile_rows) ? "as it should be"
                                                                                : "WRONG");
            if (!ran || !same || clock1 - clock0 != (uint32_t)(R * tile_rows))
                errors += fail("the level probe does not leave the tile as it found it");
            free(was);
        }
        light_free();
        host_free(&hz);
        free(a);
        free(y);
        pta_device_free(&dev);
        gemm_free(g);
    }
    /* 8c. what the probe reads, applied where a chip could.  A random network
     *     on the working tile, two buses, a still source with its lines 8% off
     *     and nothing else amiss, so that a layer's sums are the exact product
     *     but for the light and for what a correction leaves.  Left alone they
     *     are 8% off.  With the tile unquantised every correction leaves the
     *     rounding of one operand and no more, on both layers, and holds
     *     nothing at a rail; scaled to the dimmest line the sums come back as
     *     they were.  With the tile at 6 bits, the weights written at 8 are
     *     as good and the weights left to its 6 are not: the grid's rounding
     *     is what is left.  Inputs at full scale cannot be raised: half are
     *     held at the rail and their rows left as they were, unless every row
     *     is scaled to the dimmest; and so with weights at the rail.  A line
     *     read at 3% of its level is refused, and so is a reading that was
     *     taken off and not kept.  A probe that keeps its reading leaves the
     *     lines.  And a network that was rewritten is the one it came from in
     *     its biases and its rescale. */
    {
        enum { F_W6 = 0, F_W8, F_IN, F_DIM, F_WDIM, F_N };
        static const int fixes[F_N] = {FIX_WEIGHTS, FIX_WEIGHTS8, FIX_INPUTS, FIX_INPUTS, FIX_WEIGHTS8};
        const int D = 8, H = 1, M = 16, NB = 2;
        const double sigma = 0.08;
        const double LEVEL_WORST = 0.016;       /* a fifth of what is there: the rounding of an operand */
        const pta_tile tile = {128, 64, 8, ACC_W};
        const size_t all_in = (size_t)MAX_M * N_IN * sizeof(int32_t);
        host_net hn, hf, hw;
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
        int32_t *a1 = (int32_t *)malloc(all_in);
        pta_cfg cfg[MAX_L], run[MAX_L];
        pta_device dev;
        gemm_buf *g;
        double found = 0.0, left = 0.0, none[2][2], e[2][F_N][2], full[2][2], gain[2] = {0.0, 0.0};
        double clip_full = 0.0, was[64], left_most = 0.0, wfull[2][2], clip_w = 0.0;
        long clipped = 0;                       /* by a correction scaled to the dimmest line: none */
        int ran = 1, refused = 0, kept = 1, rest = 1, rails = 1, quant, kind, i, l, m;

        /* the rail, as the contract's quantiser has it: a value is past it when
         * rounding it and holding it in range are not the same thing */
        for (i = -300; i <= 300; ++i) {
            const double code6 = floor((i + 2) / 4.0) * 4.0;
            rails &= past_rail(i, 6, D) == (code6 != (double)contract_quant(i, 6, D));
            rails &= past_rail(i, 0, D) == (i > 127 || i < -128);
            rails &= in_range(i, D) == (i > 127 ? 127 : i < -128 ? -128 : i);
        }
        tile_rows = tile.rows;
        tile_cols = tile.cols;
        gemm_k    = tile.rows * ((N_IN + tile.rows - 1) / tile.rows);
        gemm_n    = tile.cols * ((N_HID + tile.cols - 1) / tile.cols);
        g = gemm_alloc();
        ran &= g != NULL && bw != NULL && a1 != NULL && host_alloc(&hn, D, H) == 0;
        ran &= pta_device_init(&dev, &tile) == 0;
        pta_model_reset(&dev, 0);
        /* weights and inputs that a quarter more would not take to the rail */
        for (l = 0; ran && l <= H; ++l)
            for (i = 0; i < layer_size(H, l); ++i)
                hn.w[l][i] = (int32_t)(splitmix64(&rs) % 193u) - 96;
        hn.sh[0] = D + 3;
        for (l = 0; ran && l <= H; ++l)
            for (i = 0; i < layer_out(H, l); ++i)
                hn.b[l][i] = (int64_t)(i * 37) - 900;
        memset(a1, 0, all_in);
        for (m = 0; ran && m < M; ++m)
            for (i = 0; i < N_IN; ++i)
                a1[m * N_IN + i] = (int32_t)(splitmix64(&rs) % 97u);
        for (quant = 0; ran && quant < 2; ++quant) {
            memset(cfg, 0, sizeof cfg);
            for (l = 0; quant && l <= H; ++l) {
                cfg[l].impair   = PTA_QUANT;
                cfg[l].act_bits = 6;
                cfg[l].w_bits   = 6;
            }
            light_free();
            ran &= light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
            ran &= light_run(&hn, cfg, &tile, M, 0, a1, bw) == 0;
            level_error(&hn, cfg, M, a1, bw, none[quant]);
            for (kind = 0; ran && kind < F_N; ++kind) {
                const host_net *ht;
                memcpy(run, cfg, sizeof run);
                ran &= light_setup(&hn, run, 11, 0.0, 0.0, sigma, NB, 0) == 0;
                for (i = 0; ran && i < light.lines; ++i)
                    was[i] = light.level[i];
                light.keep = 1;
                ran &= level_probe(&dev, &run[0], &tile, 7, 1, g, &found, &left) == 0;
                for (i = 0; ran && i < light.lines; ++i)
                    kept &= light.level[i] == was[i] && light.lines == 64;
                if (left > left_most)
                    left_most = left;
                ht = ran ? level_apply(&hf, &hn, run, fixes[kind], kind == F_DIM || kind == F_WDIM) : NULL;
                ran &= ht != NULL && (ht == &hn) == (fixes[kind] == FIX_INPUTS);
                /* a rewritten network is the one it came from in everything but its weights */
                for (l = 0; ran && ht == &hf && l <= H; ++l) {
                    rest &= l == H || hf.sh[l] == hn.sh[l];
                    for (i = 0; i < layer_out(H, l); ++i)
                        rest &= hf.b[l][i] == hn.b[l][i];
                }
                ran &= ran && light_run(ht, run, &tile, M, 0, a1, bw) == 0;
                level_error(&hn, cfg, M, a1, bw, e[quant][kind]);
                if (kind == F_DIM || kind == F_WDIM) {
                    ran &= kind == F_DIM || light.gain == gain[quant];
                    gain[quant] = light.gain;
                    clipped += light.clipped;
                } else {
                    ran &= light.gain == 1.0;
                }
                ran &= light.scaled > 0;
                if (ht == &hf)
                    host_free(&hf);
            }
        }
        /* inputs at full scale: held at the rail, or scaled to the dimmest.  And
         * to the dimmest once more with the tile at its 6 bits, where an input
         * that is lowered and still rounds to the top code is not one the rail
         * held back */
        for (m = 0; ran && m < M; ++m)
            for (i = 0; i < N_IN; ++i)
                a1[m * N_IN + i] = (1 << (D - 1)) - 1;
        for (kind = 0; ran && kind < 3; ++kind) {
            memset(cfg, 0, sizeof cfg);
            for (l = 0; kind == 2 && l <= H; ++l) {
                cfg[l].impair   = PTA_QUANT;
                cfg[l].act_bits = 6;
                cfg[l].w_bits   = 6;
            }
            ran &= light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
            light.keep = 1;
            ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
            ran &= ran && level_apply(&hf, &hn, cfg, FIX_INPUTS, kind != 0) == &hn;
            ran &= ran && light_run(&hn, cfg, &tile, M, 0, a1, bw) == 0;
            if (kind < 2)
                level_error(&hn, cfg, M, a1, bw, full[kind]);
            /* the first layer's inputs, which are all at full scale, and not the second's */
            if (kind == 0 && ran) {
                long up = 0;
                for (i = 0; i < N_IN; ++i)
                    up += light.scale[(i % tile_rows) % light.lines] > 1.006;
                clip_full = (double)up / N_IN;
                ran &= light.clipped >= (long)M * up;
            } else if (ran) {
                ran &= light.clipped == 0;
            }
        }
        /* and weights at the rail, the same two ways: a first layer of them */
        memset(cfg, 0, sizeof cfg);
        for (m = 0; ran && m < M; ++m)
            for (i = 0; i < N_IN; ++i)
                a1[m * N_IN + i] = (int32_t)(splitmix64(&rs) % 97u);
        ran &= ran && host_alloc(&hw, D, H) == 0;
        for (l = 0; ran && l <= H; ++l) {
            for (i = 0; i < layer_size(H, l); ++i)
                hw.w[l][i] = l == 0 ? (1 << (D - 1)) - 1 : hn.w[l][i];
            hw.sh[0] = D + 6;
        }
        for (kind = 0; ran && kind < 2; ++kind) {
            const host_net *ht;
            ran &= light_setup(&hw, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
            light.keep = 1;
            ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
            ht = ran ? level_apply(&hf, &hw, cfg, FIX_WEIGHTS, kind) : NULL;
            ran &= ht == &hf;
            ran &= ran && light_run(ht, cfg, &tile, M, 0, a1, bw) == 0;
            level_error(&hw, cfg, M, a1, bw, wfull[kind]);
            if (kind == 0 && ran)
                clip_w = (double)light.clipped / light.scaled;
            else if (ran)
                ran &= light.clipped == 0;
            if (ht == &hf)
                host_free(&hf);
        }
        if (ran)
            host_free(&hw);
        /* a line at 3% of its level; and a reading that was taken off and not kept */
        ran &= ran && light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
        if (ran) {
            light.level[5] = -0.97;
            light.keep = 1;
            ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
            refused = level_apply(&hf, &hn, cfg, FIX_INPUTS, 1) == NULL &&
                      level_apply(&hf, &hn, cfg, FIX_WEIGHTS, 0) == NULL;
        }
        ran &= ran && light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
        ran &= ran && level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
        refused &= ran && level_apply(&hf, &hn, cfg, FIX_INPUTS, 0) == NULL;
        {
            /* unquantised: the most any correction leaves on either layer, and the
             * two ways of writing the weights, which are then one */
            double worst = 0.0;
            int one = 1;
            for (kind = 0; kind < F_N; ++kind)
                for (l = 0; l <= H; ++l)
                    if (e[0][kind][l] > worst)
                        worst = e[0][kind][l];
            for (l = 0; l <= H; ++l)
                one &= e[0][F_W6][l] == e[0][F_W8][l];
            printf("selftest: a line's level applied where a chip could: left alone the sums are %.3f "
                   "and %.3f off; unquantised, on the weights leaves %.4f and %.4f, on the inputs "
                   "%.4f and %.4f, to the dimmest %.4f and %.4f on the inputs and %.4f and %.4f on "
                   "the weights, with %.2f of the sums taken off and put back and %ld held at a "
                   "rail; at 6 bits, the weights written at 8 leave %.4f and at the tile's 6, %.4f; "
                   "inputs at full scale: %.2f held and %.3f off, for %.4f to the dimmest; weights "
                   "at the rail: %.2f held and %.3f off, for %.4f; a line at 3%%, and a reading "
                   "not kept: %s; the lines as they were: %s, with %.4f to be left; the rest of a "
                   "rewritten network: %s; the rail: %s: %s\n",
                   none[0][0], none[0][1], e[0][F_W6][0], e[0][F_W6][1], e[0][F_IN][0],
                   e[0][F_IN][1], e[0][F_DIM][0], e[0][F_DIM][1], e[0][F_WDIM][0], e[0][F_WDIM][1],
                   gain[0], clipped, e[1][F_W8][0], e[1][F_W6][0], clip_full, full[0][0], full[1][0],
                   clip_w, wfull[0][0], wfull[1][0],
                   refused ? "refused" : "TAKEN", kept ? "kept" : "MOVED", left_most,
                   rest ? "the same" : "DIFFERENT", rails ? "the contract's" : "NOT THE CONTRACT'S",
                   ran && refused && kept && rest && rails && left_most < 0.003 && one &&
                   none[0][0] > 0.05 && none[0][1] > 0.05 &&
                   worst < LEVEL_WORST && clipped == 0 && gain[0] > 0.7 && gain[0] < 0.95 &&
                   e[1][F_W8][0] < LEVEL_WORST && e[1][F_W6][0] > 1.5 * e[1][F_W8][0] &&
                   e[1][F_W6][0] < none[1][0] && e[1][F_IN][0] < none[1][0] &&
                   clip_full > 0.3 && clip_full < 0.7 && full[0][0] > 3.0 * full[1][0] &&
                   full[1][0] < LEVEL_WORST && clip_w > 0.3 && clip_w < 0.7 &&
                   wfull[0][0] > 3.0 * wfull[1][0] && wfull[1][0] < LEVEL_WORST
                       ? "as it should be" : "WRONG");
            if (!ran || !refused || !kept || !rest || !rails || left_most >= 0.003 || !one ||
                none[0][0] <= 0.05 || none[0][1] <= 0.05 ||
                worst >= LEVEL_WORST || clipped != 0 || gain[0] <= 0.7 || gain[0] >= 0.95)
                errors += fail("a correction for a line's level does not level it");
            if (e[1][F_W8][0] >= LEVEL_WORST || e[1][F_W6][0] <= 1.5 * e[1][F_W8][0] ||
                e[1][F_W6][0] >= none[1][0] || e[1][F_IN][0] >= none[1][0])
                errors += fail("a correction on the weights is not what its bits allow");
            if (clip_full <= 0.3 || clip_full >= 0.7 || full[0][0] <= 3.0 * full[1][0] ||
                full[1][0] >= LEVEL_WORST)
                errors += fail("inputs at full scale are not held at the rail, or not levelled to the dimmest");
            if (clip_w <= 0.3 || clip_w >= 0.7 || wfull[0][0] <= 3.0 * wfull[1][0] ||
                wfull[1][0] >= LEVEL_WORST)
                errors += fail("weights at the rail are not held there, or not levelled to the dimmest");
        }
        light_free();
        host_free(&hn);
        free(bw);
        free(a1);
        pta_device_free(&dev);
        gemm_free(g);
    }
    /* 8d. what a correction on the weights leaves, told apart.  The tile and
     *     the still source of 8c, and a network whose first layer reaches the
     *     rail and whose second does not.  The read, the round and the rail
     *     add to what the weights as FIX_WEIGHTS8 rewrites them are off by
     *     through their lines, weight for weight, and the rail is counted as
     *     level_apply() counts it.  A weight's rounding is half a unit at
     *     most, its rail is nothing where it was not held and takes from it
     *     where it was, and its read is the reading's own error.  In one layer
     *     the other is left nothing.  A run with no part is the run with no
     *     source, sum for sum; a run with every part is the tile's sums and
     *     the parts' share, sum for sum, and within a unit a tile of the
     *     rewritten weights' own.  And it is refused with noise on the source,
     *     through an offset, with no reading kept, for a part or a layer there
     *     is none of, and for a line at 3%. */
    {
        static const int one[3] = {PART_READ, PART_ROUND, PART_RAIL};
        const int D = 8, H = 1, M = 16, NB = 2;
        const double sigma = 0.08;
        const pta_tile tile = {128, 64, 8, ACC_W};
        const size_t all_in = (size_t)MAX_M * N_IN * sizeof(int32_t);
        host_net hn, hf;
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw), *b0 = (batch_ws *)malloc(sizeof *b0);
        batch_ws *bf = (batch_ws *)malloc(sizeof *bf);
        int32_t *a1 = (int32_t *)malloc(all_in);
        double *whole[MAX_L] = {NULL}, *part[3][MAX_L] = {{NULL}};
        pta_cfg cfg[MAX_L], run[MAX_L];
        pta_device dev;
        gemm_buf *g;
        uint64_t r8 = 0x8D8D8Dull;              /* its own, so that 9's draws stay */
        double found = 0.0, left = 0.0, round_most = 0.0, read_most = 0.0, off_most = 0.0;
        long held = 0, moved = 0;
        int ran = 1, adds = 1, counts = 1, bounds = 1, alone = 1, dark = 1, sums = 1, refused = 1;
        int lists = 1, ok, quant, p, i, l, m, n, k, k0;

        tile_rows = tile.rows;
        tile_cols = tile.cols;
        gemm_k    = tile.rows * ((N_IN + tile.rows - 1) / tile.rows);
        gemm_n    = tile.cols * ((N_HID + tile.cols - 1) / tile.cols);
        g = gemm_alloc();
        ran &= g != NULL && bw != NULL && b0 != NULL && bf != NULL && a1 != NULL &&
               host_alloc(&hn, D, H) == 0;
        ran &= pta_device_init(&dev, &tile) == 0;
        pta_model_reset(&dev, 0);
        /* a first layer of every weight there is, and a second that a line at
         * six tenths of its level would not take to the rail */
        for (l = 0; ran && l <= H; ++l) {
            for (i = 0; i < layer_size(H, l); ++i)
                hn.w[l][i] = l == 0 ? (int32_t)(splitmix64(&r8) % 256u) - 128
                                    : (int32_t)(splitmix64(&r8) % 129u) - 64;
            whole[l] = (double *)malloc((size_t)layer_size(H, l) * sizeof(double));
            ran &= whole[l] != NULL;
            for (p = 0; p < 3; ++p) {
                part[p][l] = (double *)malloc((size_t)layer_size(H, l) * sizeof(double));
                ran &= part[p][l] != NULL;
            }
        }
        hn.sh[0] = D + 3;
        for (l = 0; ran && l <= H; ++l)
            for (i = 0; i < layer_out(H, l); ++i)
                hn.b[l][i] = (int64_t)(i * 37) - 900;
        if (a1)
            memset(a1, 0, all_in);
        for (m = 0; ran && m < M; ++m)
            for (i = 0; i < N_IN; ++i)
                a1[m * N_IN + i] = (int32_t)(splitmix64(&r8) % 97u);
        for (quant = 0; ran && quant < 2; ++quant) {
            const int bits = quant ? 6 : 0;
            long rail_cells = 0;
            memset(cfg, 0, sizeof cfg);
            for (l = 0; quant && l <= H; ++l) {
                cfg[l].impair   = PTA_QUANT;
                cfg[l].act_bits = 6;
                cfg[l].w_bits   = 6;
            }
            /* with no source at all */
            light_free();
            ran &= light_run(&hn, cfg, &tile, M, 0, a1, b0) == 0;
            /* the weights as rewritten, and their sums through the tile */
            memcpy(run, cfg, sizeof run);
            ran &= ran && light_setup(&hn, run, 11, 0.0, 0.0, sigma, NB, 0) == 0;
            if (!ran)
                break;
            light.keep = 1;
            ran &= level_probe(&dev, &run[0], &tile, 7, 1, g, &found, &left) == 0;
            if (!ran || level_apply(&hf, &hn, run, FIX_WEIGHTS8, 0) != &hf) {
                ran = 0;
                break;
            }
            held  = light.clipped;
            moved = light.scaled;
            ran &= light_run(&hf, run, &tile, M, 0, a1, bf) == 0;
            /* told apart on the same reading: every part of it */
            ran &= ran && light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
            if (ran) {
                light.keep = 1;
                ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
            }
            ran &= ran && level_parts(&hn, cfg, PART_ALL, -1) == 0;
            if (!ran) {
                host_free(&hf);
                break;
            }
            counts &= light.apart && light.gain == 1.0 && held > 0 && light.clipped == held &&
                      light.scaled == moved && light.held[0] == held && light.held[1] == 0 &&
                      light.moved[1] > 0 && light.moved[0] + light.moved[1] == moved;
            for (l = 0; l <= H; ++l) {
                const int in = layer_in(l);
                for (i = 0; i < layer_size(H, l); ++i) {
                    const int line = ((i % in) % tile_rows) % light.lines;
                    const double q = (double)contract_quant(hn.w[l][i], bits, D);
                    whole[l][i] = light.dw[l][i];
                    adds &= fabs(whole[l][i] - ((1.0 + light.level[line]) * hf.w[l][i] - q)) < 1e-9;
                }
            }
            /* a run with every part: the tile's sums and the parts' share, a
             * tile's rows at a time as light_add() rounds it */
            ran &= light_run(&hn, cfg, &tile, M, 0, a1, bw) == 0;
            for (l = 0; ran && l <= H; ++l) {
                const int in = layer_in(l), out = layer_out(H, l);
                const int32_t *src = l == 0 ? a1 : bw->a[l];
                for (m = 0; m < M; ++m)
                    for (n = 0; n < out; ++n) {
                        int64_t want = 0;
                        for (k0 = 0; k0 < in; k0 += tile_rows) {
                            double d = 0.0;
                            for (k = k0; k < in && k < k0 + tile_rows; ++k) {
                                const int32_t av = src[m * in + k];
                                const int32_t xa = quant ? contract_quant(av, 6, D) : av;
                                want += (int64_t)xa * contract_quant(hn.w[l][n * in + k], bits, D);
                                d += (double)xa * whole[l][n * in + k];
                            }
                            want += (int64_t)floor(d + 0.5);
                        }
                        sums &= bw->y[l][m * out + n] == want;
                    }
            }
            /* and the rewritten weights' own first sums, to a unit a tile */
            for (i = 0; ran && i < M * N_HID; ++i) {
                const double d = fabs((double)(bw->y[0][i] - bf->y[0][i]));
                if (d > off_most)
                    off_most = d;
            }
            /* each part on its own: they add, and each is what it is called */
            for (p = 0; ran && p < 3; ++p) {
                ran &= level_parts(&hn, cfg, one[p], -1) == 0;
                for (l = 0; ran && l <= H; ++l)
                    memcpy(part[p][l], light.dw[l], (size_t)layer_size(H, l) * sizeof(double));
                counts &= light.clipped == held && light.held[0] == held && light.held[1] == 0;
            }
            for (l = 0; ran && l <= H; ++l) {
                const int in = layer_in(l);
                for (i = 0; i < layer_size(H, l); ++i) {
                    const int line = ((i % in) % tile_rows) % light.lines;
                    const double lit = 1.0 + light.level[line];
                    const double q = (double)contract_quant(hn.w[l][i], bits, D);
                    const double v = floor(q * light.scale[line] + 0.5);
                    const double rd = part[0][l][i], ro = part[1][l][i], ra = part[2][l][i];
                    adds &= fabs(rd + ro + ra - whole[l][i]) < 1e-9;
                    bounds &= fabs(rd - q * (lit / (1.0 + light.read[line]) - 1.0)) < 1e-9;
                    bounds &= fabs(ro) <= 0.5 * lit + 1e-9;
                    bounds &= (ra != 0.0) == ((double)hf.w[l][i] != v) && ra * q <= 0.0;
                    rail_cells += ra != 0.0;
                    if (fabs(ro) / lit > round_most)
                        round_most = fabs(ro) / lit;
                    if (q != 0.0 && fabs(rd / q) > read_most)
                        read_most = fabs(rd / q);
                }
            }
            counts &= rail_cells == held;
            /* a layer alone leaves the other nothing */
            for (p = 0; ran && p <= H; ++p) {
                ran &= level_parts(&hn, cfg, PART_ALL, p) == 0;
                for (l = 0; ran && l <= H; ++l)
                    for (i = 0; i < layer_size(H, l); ++i)
                        alone &= light.dw[l][i] == (l == p ? whole[l][i] : 0.0);
            }
            /* the last layer's rail alone is nothing, since nothing was held there */
            ran &= ran && level_parts(&hn, cfg, PART_RAIL, H) == 0;
            for (l = 0; ran && l <= H; ++l)
                for (i = 0; i < layer_size(H, l); ++i)
                    alone &= light.dw[l][i] == 0.0;
            /* and no part is no source */
            ran &= ran && level_parts(&hn, cfg, 0, -1) == 0;
            ran &= ran && light_run(&hn, cfg, &tile, M, 0, a1, bw) == 0;
            for (l = 0; ran && l <= H; ++l)
                for (i = 0; i < M * layer_out(H, l); ++i)
                    dark &= bw->y[l][i] == b0->y[l][i];
            host_free(&hf);
        }
        /* refused: noise on the source, of either kind; a light through an
         * offset; a reading taken off and not kept; a part or a layer there is
         * none of; and a line at 3% of its level */
        memset(cfg, 0, sizeof cfg);
        for (p = 0; ran && p < 2; ++p) {
            ran &= light_setup(&hn, cfg, 11, p ? 0.0 : 0.01, p ? 0.01 : 0.0, sigma, NB, 0) == 0;
            if (ran) {
                light.keep = 1;
                ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
                refused &= level_parts(&hn, cfg, PART_ALL, -1) != 0 && !light.apart;
            }
        }
        ran &= ran && light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 1) == 0;
        if (ran) {
            light.keep = 1;
            refused &= level_parts(&hn, cfg, PART_ALL, -1) != 0 && !light.apart;
        }
        ran &= ran && light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
        ran &= ran && level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
        refused &= ran && level_parts(&hn, cfg, PART_ALL, -1) != 0 && !light.apart;
        ran &= ran && light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
        if (ran) {
            light.keep = 1;
            ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
            refused &= level_parts(&hn, cfg, PART_ALL + 1, -1) != 0 &&
                       level_parts(&hn, cfg, -1, -1) != 0 &&
                       level_parts(&hn, cfg, PART_ALL, H + 1) != 0 &&
                       level_parts(&hn, cfg, PART_ALL, -2) != 0 && !light.apart;
        }
        ran &= ran && light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, NB, 0) == 0;
        if (ran) {
            light.level[5] = -0.97;
            light.keep = 1;
            ran &= level_probe(&dev, &cfg[0], &tile, 7, 1, g, &found, &left) == 0;
            refused &= level_parts(&hn, cfg, PART_ALL, -1) != 0 && !light.apart;
        }
        /* and --levelpart's list */
        lists &= part_list("none") == 0 && part_list("read") == PART_READ &&
                 part_list("round") == PART_ROUND && part_list("rail") == PART_RAIL &&
                 part_list("read,round,rail") == PART_ALL &&
                 part_list("rail,read") == (PART_RAIL | PART_READ) &&
                 part_list("") == -1 && part_list("read,") == -1 && part_list(",read") == -1 &&
                 part_list("read,read") == -1 && part_list("all") == -1 &&
                 part_list("none,rail") == -1 && part_list("rai") == -1 &&
                 part_list("rails") == -1 && part_list("read round") == -1;
        ok = ran && adds && counts && bounds && alone && dark && sums && refused && lists &&
             off_most <= 7.0 && round_most > 0.45 && round_most <= 0.5 + 1e-9 &&
             read_most > 0.0005 && read_most < 0.003;
        printf("selftest: what a correction on the weights leaves, told apart: the read, the round "
               "and the rail add to the rewritten weight through its line: %s; %ld of %ld weights "
               "held at the rail, all in the first layer, as level_apply() counts them: %s; a "
               "rounding is %.3f of a unit at most, a read %.4f of its weight, and the rail takes "
               "only from a weight it held: %s; a layer alone leaves the other nothing: %s; no part "
               "is no source: %s; with every part a run's sums are the tile's and the parts' share: "
               "%s, and within %.0f of the rewritten weights' own; noise, an offset, a reading not "
               "kept, a part or a layer there is none of, and a line at 3%%: %s; the lists: %s: %s\n",
               adds ? "they do" : "THEY DO NOT", held, moved, counts ? "the same" : "DIFFERENT",
               round_most, read_most, bounds ? "so" : "NOT SO", alone ? "nothing" : "SOMETHING",
               dark ? "the same sums" : "OTHER SUMS", sums ? "exactly" : "NOT SO", off_most,
               refused ? "refused" : "TAKEN", lists ? "read" : "MISREAD",
               ok ? "as it should be" : "WRONG");
        if (!ok)
            errors += fail("what a correction on the weights leaves does not come apart");
        light_free();
        host_free(&hn);
        for (l = 0; l <= H; ++l) {
            free(whole[l]);
            for (p = 0; p < 3; ++p)
                free(part[p][l]);
        }
        free(bw);
        free(b0);
        free(bf);
        free(a1);
        pta_device_free(&dev);
        gemm_free(g);
    }
    /* 9. the light.  Its share is the exact product of the operands with each
     *    line's error, so where the tile's own sums are exact it can be read
     *    back: one fraction for a whole shot when the lines move together, one
     *    for a line however many buses it lights, one that stays put when it is
     *    a line's level, and the offset's when a weight is signed with one.
     *    And neither the cut nor the batch moves a draw. */
    {
        const int D = 8, H = 1, T = 10, M = 40;
        const int32_t lo = -(1 << (D - 1)), span = 1 << D;
        const double sigma = 0.02;
        const pta_tile tile = {256, 64, 8, ACC_W};
        const size_t all_in = (size_t)MAX_M * N_IN * sizeof(int32_t);
        host_net hn, hz;
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw), *b0 = (batch_ws *)malloc(sizeof *b0);
        int32_t *a1 = (int32_t *)malloc(all_in);
        pta_cfg cfg[MAX_L];
        int64_t d[N_HID];
        double sum = 0.0, sq = 0.0, f0 = 0.0, f1 = 0.0, mean, sd, shot_frac[MAX_M];
        long shots = 0, apart = 0, layers = 0;
        int ran = 1, together = 1, split = 0, shared = 1, alone = 0, level = 1, offs = 1;
        int moved = 1, nothing = 1, quant, t, i, l, m, n;

        tile_rows = tile.rows;
        tile_cols = tile.cols;
        gemm_k    = 1024;
        gemm_n    = 128;
        host_alloc(&hn, D, H);
        host_alloc(&hz, D, H);                  /* hz: every weight zero */
        for (l = 0; l <= H; ++l)
            for (i = 0; i < layer_size(H, l); ++i)
                hn.w[l][i] = lo + (int32_t)(splitmix64(&rs) % (uint64_t)span);
        hn.sh[0] = hz.sh[0] = D + 3;

        /* together: inputs in one K tile only, each in turn and the short last
         * one too, so a shot is an image and an N tile, and the first layer's
         * two N tiles are two shots */
        for (quant = 0; quant < 2; ++quant) {
            memset(cfg, 0, sizeof cfg);
            for (l = 0; quant && l <= H; ++l) {
                cfg[l].impair   = PTA_QUANT;
                cfg[l].act_bits = 6;
                cfg[l].w_bits   = 6;
            }
            for (t = 0; t < T; ++t) {
                const int k_lo = (t % 4) * tile_rows;
                const int k_n = (N_IN - k_lo < tile_rows) ? N_IN - k_lo : tile_rows;
                memset(a1, 0, all_in);
                for (m = 0; m < MAX_M; ++m)
                    for (i = 0; i < k_n; ++i)
                        a1[m * N_IN + k_lo + i] =
                            (int32_t)(splitmix64(&rs) % (uint64_t)(1 << (D - 1)));
                light_free();
                ran &= light_run(&hn, cfg, &tile, MAX_M, t * MAX_M, a1, b0) == 0;
                ran &= light_setup(&hn, cfg, 11, sigma, 0.0, 0.0, 1, 0) == 0;
                ran &= light_run(&hn, cfg, &tile, MAX_M, t * MAX_M, a1, bw) == 0;
                for (m = 0; m < MAX_M; ++m) {
                    const int64_t *y = b0->y[0] + m * N_HID;
                    for (n = 0; n < N_HID; ++n)
                        d[n] = bw->y[0][m * N_HID + n] - y[n];
                    together &= same_fraction(d, y, tile_cols, &f0);
                    together &= same_fraction(d + tile_cols, y + tile_cols, N_HID - tile_cols, &f1);
                    apart += fabs(f0 - f1) > 1e-4;
                    sum += f0;
                    sq  += f0 * f0;
                    ++shots;
                    /* the second layer is one shot an image, of the operands this
                     * run gave it: its share against their product, worked here */
                    {
                        int64_t yx[N_OUT], d1[N_OUT];
                        double f2 = 0.0;
                        for (n = 0; n < N_OUT; ++n) {
                            int64_t sx = 0;
                            for (i = 0; i < N_HID; ++i) {
                                const int32_t av = bw->a[1][m * N_HID + i];
                                const int32_t wv = hn.w[1][n * N_HID + i];
                                sx += (int64_t)(quant ? contract_quant(av, 6, D) : av) *
                                      (quant ? contract_quant(wv, 6, D) : wv);
                            }
                            yx[n] = sx;
                            d1[n] = bw->y[1][m * N_OUT + n] - sx;
                        }
                        together &= same_fraction(d1, yx, N_OUT, &f2);
                        layers += fabs(f2 - f0) > 1e-4;
                    }
                }
            }
        }
        mean = sum / shots;
        sd   = sqrt(sq / shots - mean * mean);
        /* and with inputs in two K tiles a sum is two shots: no one fraction */
        memset(a1, 0, all_in);
        for (m = 0; m < MAX_M; ++m)
            for (i = 0; i < 2 * tile_rows; ++i)
                a1[m * N_IN + i] = (int32_t)(splitmix64(&rs) % (uint64_t)(1 << (D - 1)));
        memset(cfg, 0, sizeof cfg);
        light_free();
        ran &= light_run(&hn, cfg, &tile, MAX_M, 0, a1, b0) == 0;
        ran &= light_setup(&hn, cfg, 11, sigma, 0.0, 0.0, 1, 0) == 0;
        ran &= light_run(&hn, cfg, &tile, MAX_M, 0, a1, bw) == 0;
        for (m = 0; m < MAX_M; ++m) {
            for (n = 0; n < tile_cols; ++n)
                d[n] = bw->y[0][m * N_HID + n] - b0->y[0][m * N_HID + n];
            split += !same_fraction(d, b0->y[0] + m * N_HID, tile_cols, &f0);
        }
        printf("selftest: the light, every line together: %ld shots each one fraction of their sums, "
               "rms %.4f for %.2f, mean %+.5f; two N tiles apart in %ld and two layers in %ld; two "
               "K tiles no one fraction in %d of %d: %s\n", shots, sd, sigma, mean, apart, layers,
               split, MAX_M,
               ran && together && fabs(sd / sigma - 1.0) < 0.1 &&
               fabs(mean) < 4.0 * sigma / sqrt((double)shots) && apart > shots * 9 / 10 &&
               layers > shots * 9 / 10 && split > MAX_M * 9 / 10 ? "as it should be" : "WRONG");
        if (!ran || !together)
            errors += fail("light that moves together is not one fraction of a shot's sums");
        if (fabs(sd / sigma - 1.0) >= 0.1 || fabs(mean) >= 4.0 * sigma / sqrt((double)shots))
            errors += fail("the light's noise is not the size it was asked for");
        if (apart <= shots * 9 / 10 || layers <= shots * 9 / 10 || split <= MAX_M * 9 / 10)
            errors += fail("two shots share the light's draw");

        /* a line: rows 3 and 3 + 64 share one on four buses, and not on one */
        for (t = 0; t < 2; ++t) {
            memset(a1, 0, all_in);
            for (m = 0; m < MAX_M; ++m) {
                a1[m * N_IN + 3]      = 100;
                a1[m * N_IN + 3 + 64] = 90;
            }
            light_free();
            ran &= light_run(&hn, cfg, &tile, MAX_M, 0, a1, b0) == 0;
            ran &= light_setup(&hn, cfg, 11, 0.0, sigma, 0.0, t == 0 ? 4 : 1, 0) == 0;
            ran &= light_run(&hn, cfg, &tile, MAX_M, 0, a1, bw) == 0;
            for (m = 0; m < MAX_M; ++m) {
                int ok;
                for (n = 0; n < tile_cols; ++n)
                    d[n] = bw->y[0][m * N_HID + n] - b0->y[0][m * N_HID + n];
                ok = same_fraction(d, b0->y[0] + m * N_HID, tile_cols, &f0);
                if (t == 0)
                    shared &= ok;
                else
                    alone += !ok;
            }
        }
        /* a level: the same image twice reads the same, and two lines differ */
        memset(a1, 0, all_in);
        a1[0 * N_IN + 5] = a1[1 * N_IN + 5] = a1[2 * N_IN + 6] = 100;
        light_free();
        ran &= light_run(&hn, cfg, &tile, 3, 0, a1, b0) == 0;
        ran &= light_setup(&hn, cfg, 11, 0.0, 0.0, sigma, 1, 0) == 0;
        ran &= light_run(&hn, cfg, &tile, 3, 0, a1, bw) == 0;
        level &= memcmp(bw->y[0], bw->y[0] + N_HID, N_HID * sizeof(int64_t)) == 0;
        for (n = 0; n < tile_cols; ++n)
            d[n] = bw->y[0][n] - b0->y[0][n];
        level &= same_fraction(d, b0->y[0], tile_cols, &f0);
        for (n = 0; n < tile_cols; ++n)
            d[n] = bw->y[0][2 * N_HID + n] - b0->y[0][2 * N_HID + n];
        level &= same_fraction(d, b0->y[0] + 2 * N_HID, tile_cols, &f1);
        level &= f0 != 0.0 && fabs(f0 - f1) > 1e-4;
        printf("selftest: the light, a line: rows a bus apart move as one on four buses (%s) and "
               "not on one (%d of %d); a line's level stays put and differs from its neighbour's "
               "(%+.4f, %+.4f): %s\n", shared ? "all" : "NOT ALL", alone, MAX_M, f0, f1,
               ran && shared && alone > MAX_M * 9 / 10 && level ? "as it should be" : "WRONG");
        if (!ran || !shared || alone <= MAX_M * 9 / 10)
            errors += fail("a line's light does not follow its buses");
        if (!level)
            errors += fail("a line's level is not fixed for the run");

        /* the offset: through weights of zero a pair passes no light, and one
         * photodiode passes the offset's, the same to every column of a shot */
        memset(a1, 0, all_in);
        for (m = 0; m < MAX_M; ++m)
            for (i = 0; i < tile_rows; ++i)
                a1[m * N_IN + i] = (int32_t)(splitmix64(&rs) % (uint64_t)(1 << (D - 1)));
        light_free();
        ran &= light_run(&hn, cfg, &tile, MAX_M, 0, a1, b0) == 0;
        ran &= light_setup(&hn, cfg, 11, sigma, 0.0, 0.0, 1, 0) == 0;
        ran &= light_run(&hn, cfg, &tile, MAX_M, 0, a1, bw) == 0;
        for (m = 0; m < MAX_M; ++m) {
            for (n = 0; n < tile_cols; ++n)
                d[n] = bw->y[0][m * N_HID + n] - b0->y[0][m * N_HID + n];
            same_fraction(d, b0->y[0] + m * N_HID, tile_cols, &shot_frac[m]);
        }
        ran &= light_setup(&hz, cfg, 11, sigma, 0.0, 0.0, 1, 1) == 0;
        ran &= light_run(&hz, cfg, &tile, MAX_M, 0, a1, bw) == 0;
        for (m = 0; m < MAX_M; ++m) {
            /* the same shot's draw, on the offset alone: a weight of one a row */
            double lit_sum = 0.0;
            for (i = 0; i < tile_rows; ++i)
                lit_sum += a1[m * N_IN + i];
            lit_sum *= ldexp(1.0, D - 1);
            offs &= bw->y[0][m * N_HID] != 0;
            offs &= fabs((double)bw->y[0][m * N_HID] / lit_sum - shot_frac[m]) < 1e-4;
            for (n = 1; n < tile_cols; ++n)
                offs &= bw->y[0][m * N_HID + n] == bw->y[0][m * N_HID];
        }
        ran &= light_setup(&hz, cfg, 11, sigma, 0.0, 0.0, 1, 0) == 0;
        ran &= light_run(&hz, cfg, &tile, MAX_M, 0, a1, bw) == 0;
        for (i = 0; i < MAX_M * N_HID; ++i)
            offs &= bw->y[0][i] == 0;

        /* the cut and the batch: all three, four buses, the quantisers on */
        for (l = 0; l <= H; ++l) {
            cfg[l].impair   = PTA_QUANT;
            cfg[l].act_bits = 6;
            cfg[l].w_bits   = 6;
        }
        for (i = 0; i < M * N_IN; ++i)
            a1[i] = (int32_t)(splitmix64(&rs) % (uint64_t)(1 << (D - 1)));
        ran &= light_setup(&hn, cfg, 11, sigma, sigma, sigma, 4, 0) == 0;
        ran &= light_run(&hn, cfg, &tile, M, 0, a1, b0) == 0;
        gemm_k = 256;
        gemm_n = 64;
        ran &= light_run(&hn, cfg, &tile, 23, 0, a1, bw) == 0;
        moved &= memcmp(bw->y[0], b0->y[0], 23 * N_HID * sizeof(int64_t)) == 0;
        moved &= memcmp(bw->y[1], b0->y[1], 23 * N_OUT * sizeof(int64_t)) == 0;
        ran &= light_run(&hn, cfg, &tile, M - 23, 23, a1 + 23 * N_IN, bw) == 0;
        moved &= memcmp(bw->y[0], b0->y[0] + 23 * N_HID, (M - 23) * N_HID * sizeof(int64_t)) == 0;
        moved &= memcmp(bw->y[1], b0->y[1] + 23 * N_OUT, (M - 23) * N_OUT * sizeof(int64_t)) == 0;
        /* and a light of nothing is no light */
        ran &= light_setup(&hn, cfg, 11, 0.0, 0.0, 0.0, 4, 0) == 0;
        ran &= light_run(&hn, cfg, &tile, 23, 0, a1, bw) == 0;
        light_free();
        ran &= light_run(&hn, cfg, &tile, 23, 0, a1, b0) == 0;
        nothing &= memcmp(bw->y[0], b0->y[0], 23 * N_HID * sizeof(int64_t)) == 0;
        nothing &= memcmp(bw->y[1], b0->y[1], 23 * N_OUT * sizeof(int64_t)) == 0;
        printf("selftest: the light, an offset: the same to every column of a shot, and none through "
               "a pair at weights of zero: %s; at another cut and in two batches: %s; a light of "
               "nothing: %s\n", ran && offs ? "as it should be" : "WRONG",
               moved ? "the same sums" : "DIFFERENT", nothing ? "changes nothing" : "CHANGES THEM");
        if (!ran || !offs)
            errors += fail("the offset's light is not the offset's");
        if (!moved)
            errors += fail("the cut or the batch moves the light's draws");
        if (!nothing)
            errors += fail("a light of nothing changes the sums");
        host_free(&hn);
        host_free(&hz);
        free(bw);
        free(b0);
        free(a1);
    }
    tile_rows = ROWS;
    tile_cols = COLS;
    gemm_k = MAX_K;
    gemm_n = MAX_N;

    /* 10. a line's light: an input at full scale through a weight of one, and
     *     noise that is a sixteenth of it, which at 8-bit operands and a shift
     *     of 11 is half an LSB and at a shift of 9 is two */
    {
        const double l8 = line_light(8), l16 = line_light(16);
        const double a = line_lsb(0.0625, 8, 11), b = line_lsb(0.0625, 8, 9);
        const int ok = l8 == 127.0 * 128.0 && l16 == 32767.0 * 32768.0 && fabs(a - 0.49609375) < 1e-12 &&
                       fabs(b - 4.0 * a) < 1e-12 && fabs(line_lsb(0.5, 8, 11) - 8.0 * a) < 1e-12;
        printf("selftest: a line's light is %.0f at 8 bits and %.0f at 16; a sixteenth of it is %.4f "
               "LSB at a shift of 11 and %.4f at 9: %s\n", l8, l16, a, b, ok ? "as it should be" : "WRONG");
        if (!ok)
            errors += fail("a line's light, or noise as a fraction of it, is not what it should be");
    }
    /*     and the light a shot sends a column: ten inputs at full scale in one
     *     K tile of the first layer's four on a 256-row tile is ten lines there
     *     and none in the others; five hidden operands at full scale is five */
    {
        host_net hn;
        batch_ws *bw = (batch_ws *)calloc(1, sizeof *bw);
        int32_t *a1 = (int32_t *)calloc(2 * N_IN, sizeof(int32_t));
        pta_cfg cfg[MAX_L];
        lit_stats ls;
        int i, ok;

        memset(cfg, 0, sizeof cfg);
        memset(&ls, 0, sizeof ls);
        host_alloc(&hn, 8, 1);
        tile_rows = 256;
        for (i = 0; i < 10; ++i)
            a1[300 + i] = 127;                  /* image 0, the second K tile */
        for (i = 0; i < 5; ++i)
            bw->a[1][N_HID + i] = 127;          /* image 1's hidden operands */
        lit_batch(&ls, &hn, cfg, 2, a1, bw);
        ok = ls.shots[0] == 8 && ls.shots[1] == 2 && fabs(ls.sum[0] - 10.0) < 1e-12 &&
             fabs(ls.max[0] - 10.0) < 1e-12 && fabs(ls.sum[1] - 5.0) < 1e-12 &&
             fabs(ls.max[1] - 5.0) < 1e-12;
        /* the same through a 6-bit activation DAC: 127 is quantised to 124 */
        memset(&ls, 0, sizeof ls);
        cfg[0].impair = cfg[1].impair = PTA_QUANT;
        cfg[0].act_bits = cfg[1].act_bits = 6;
        lit_batch(&ls, &hn, cfg, 2, a1, bw);
        ok = ok && fabs(ls.sum[0] - 10.0 * 124.0 / 127.0) < 1e-12 &&
             fabs(ls.max[1] - 5.0 * 124.0 / 127.0) < 1e-12;
        printf("selftest: the light a shot sends a column, in lines, over two images: %s\n",
               ok ? "as it should be" : "WRONG");
        if (!ok)
            errors += fail("the light a shot sends a column is not its inputs summed");
        tile_rows = ROWS;
        host_free(&hn);
        free(bw);
        free(a1);
    }

    /* 11. how a network is put on the tile.  A made-up network whose weights sit
     *     on a grid a doubling keeps, and made-up images.  A gain on the first
     *     layer's weights is taken back by the hidden rescale: one more bit of
     *     shift, and every hidden operand what it was.  One bit less of rescale
     *     doubles what the next layer is handed and its biases, and clips more.
     *     And a gain too large for a weight saturates it and says so. */
    {
        const int D = 8, H = 1;
        mlp net;
        host_net h0, h1, h2, h3;
        dataset tr;
        image_ws *w0 = (image_ws *)malloc(sizeof *w0), *w2 = (image_ws *)malloc(sizeof *w2);
        int32_t *q0[MAX_L], *q2[MAX_L], a1[N_IN];
        double c0, c1, wc2, wc3;
        long differ = 0, grew = 0, units = 0;
        int i, k, l, n, ok;

        memset(&net, 0, sizeof net);
        net.din   = D;
        net.wbits = 6;
        mlp_alloc(&net, H);
        for (l = 0; l <= H; ++l)
            for (i = 0; i < layer_size(H, l); ++i)
                net.w[l][i] = (float)((int)(splitmix64(&rs) % 13) - 6) / 16.0f;     /* -6/16 .. 6/16 */
        for (n = 0; n < N_OUT; ++n)
            net.b[H][n] = (float)((int)(splitmix64(&rs) % 9) - 4) / 64.0f;
        for (n = 0; n < N_HID; ++n)
            net.b[0][n] = (float)((int)(splitmix64(&rs) % 9) - 4) / 64.0f;
        tr.n = N_CAL_HID;
        tr.x = (uint8_t *)calloc((size_t)N_CAL_HID * N_IN, 1);
        tr.y = NULL;
        for (i = 0; i < N_CAL_HID; ++i)
            for (k = 0; k < 24; ++k)
                tr.x[(size_t)i * N_IN + splitmix64(&rs) % N_IN] = (uint8_t)(1 + splitmix64(&rs) % 255);

        hid_shift = 0;  w1_gain = 0;  ok = host_setup(&h0, &net, &tr) == 0;  c0 = hid_clip[0];
        hid_shift = -1; w1_gain = 0;  ok &= host_setup(&h1, &net, &tr) == 0; c1 = hid_clip[0];
        hid_shift = 0;  w1_gain = 1;  ok &= host_setup(&h2, &net, &tr) == 0; wc2 = w1_clip;
        hid_shift = 0;  w1_gain = 2;  ok &= host_setup(&h3, &net, &tr) == 0; wc3 = w1_clip;
        hid_shift = 0;  w1_gain = 0;

        /* one bit less of rescale: the same weights, the next layer's biases doubled */
        ok &= h0.sh[0] >= 2 && h1.sh[0] == h0.sh[0] - 1 && c0 <= CLIP_FRAC && c1 > c0;
        ok &= memcmp(h1.w[0], h0.w[0], (size_t)layer_size(H, 0) * sizeof(int32_t)) == 0;
        for (n = 0; n < N_OUT; ++n)
            ok &= llabs(h1.b[H][n] - 2 * h0.b[H][n]) <= 1;
        /* a bit of gain: every weight doubled and none clipped, one more bit of
         * shift, and the last layer's biases what they were */
        ok &= wc2 == 0.0 && h2.sh[0] == h0.sh[0] + 1;
        for (i = 0; i < layer_size(H, 0); ++i)
            ok &= h2.w[0][i] == 2 * h0.w[0][i];
        for (n = 0; n < N_HID; ++n)
            ok &= h2.b[0][n] == 2 * h0.b[0][n] && h1.b[0][n] == h0.b[0][n];
        ok &= memcmp(h2.w[H], h0.w[H], (size_t)layer_size(H, H) * sizeof(int32_t)) == 0;
        ok &= memcmp(h2.b[H], h0.b[H], N_OUT * sizeof(int64_t)) == 0;
        /* and two bits: 4/16 and up times four is past the range's top, and -5/16
         * and down past its bottom: five weights of the thirteen saturate */
        ok &= fabs(wc3 - 5.0 / 13.0) < 0.01;
        for (i = 0; i < layer_size(H, 0); ++i) {
            const int32_t w = h0.w[0][i], g = h3.w[0][i];
            ok &= g == (4 * w > 127 ? 127 : 4 * w < -128 ? -128 : 4 * w);
        }
        /* the hidden operands, image by image: the gain changes none of them,
         * and a bit less of rescale never makes one smaller */
        for (l = 0; l <= H; ++l) {
            q0[l] = (int32_t *)malloc((size_t)layer_size(H, l) * sizeof(int32_t));
            q2[l] = (int32_t *)malloc((size_t)layer_size(H, l) * sizeof(int32_t));
        }
        quant_weights(&h0, net.wbits, q0);
        quant_weights(&h2, net.wbits, q2);
        for (i = 0; i < 200; ++i) {
            for (k = 0; k < N_IN; ++k)
                a1[k] = pixel_operand(tr.x[(size_t)i * N_IN + k], D);
            direct_image(&h0, q0, 0, a1, w0);
            direct_image(&h2, q2, 0, a1, w2);
            for (n = 0; n < N_HID; ++n)
                differ += w0->a[1][n] != w2->a[1][n];
            direct_image(&h1, q0, 0, a1, w2);
            for (n = 0; n < N_HID; ++n) {
                differ += w2->a[1][n] < w0->a[1][n] || w2->a[1][n] > 2 * w0->a[1][n] + 1;
                grew   += w2->a[1][n] > w0->a[1][n];
                units  += w0->a[1][n] > 0;
            }
        }
        ok &= differ == 0 && units > 1000 && grew > units / 2;
        printf("selftest: a network put on the tile: a bit of gain on the first layer's weights is one "
               "more of rescale (%d for %d) and no operand moves; a bit less of rescale clips %.4f of "
               "the units that fire for %.5f; two bits of gain saturate %.3f of the weights: %s\n",
               h2.sh[0], h0.sh[0], c1, c0, wc3, ok ? "as it should be" : "WRONG");
        if (!ok)
            errors += fail("the host's choices in putting a network on the tile are not what they say");
        for (l = 0; l <= H; ++l) {
            free(q0[l]);
            free(q2[l]);
        }
        host_free(&h0);
        host_free(&h1);
        host_free(&h2);
        host_free(&h3);
        mlp_free(&net);
        free(tr.x);
        free(w0);
        free(w2);
    }

    /* 12. invert.  Three made-up images: every pixel is 255 less what it was,
     *     the header is untouched, twice is the file it started as, and a file
     *     that is not 28 x 28 images, or is short of the images its header
     *     counts, is refused and left alone. */
    {
        static uint8_t src[16 + 3 * N_IN], got[16 + 3 * N_IN];
        int i, flipped, twice, refused;
        memset(src, 0, sizeof src);
        src[2] = 8; src[3] = 3; src[7] = 3; src[11] = 28; src[15] = 28;
        for (i = 16; i < (int)sizeof src; ++i)
            src[i] = (uint8_t)((i * 37 + i / 7) & 255);
        memcpy(got, src, sizeof src);
        flipped = invert_idx(got, sizeof got) == 3 * N_IN && memcmp(got, src, 16) == 0;
        for (i = 16; i < (int)sizeof src; ++i)
            if (got[i] + src[i] != 255)
                flipped = 0;
        twice = invert_idx(got, sizeof got) == 3 * N_IN && memcmp(got, src, sizeof src) == 0;
        got[15] = 27;                               /* 28 x 27: not ours */
        refused = invert_idx(got, sizeof got) == -1 && invert_idx(src, sizeof src - 1) == -1 &&
                  memcmp(got + 16, src + 16, sizeof src - 16) == 0 &&
                  src[16] == (uint8_t)((16 * 37 + 16 / 7) & 255);
        if (!flipped || !twice || !refused)
            ++errors;
        printf("  invert: %d pixels, each 255 less what it was under the header it had: %s; twice is "
               "the file it started as: %s; 28 x 27 images and a file a byte short are refused "
               "and left alone: %s\n", 3 * N_IN, flipped ? "as it should be" : "WRONG",
               twice ? "as it should be" : "WRONG", refused ? "as it should be" : "WRONG");
    }

    /* 13. the noise a network is trained with.  200,000 sums of a layer whose
     *     rms is 2, at a tenth: the noise's rms is a fifth and its mean is
     *     none, whatever the sum; the two accumulators hold the sums' squares
     *     and the noise's; and a layer whose rms is not yet known gets none. */
    {
        uint64_t rng = 20261006;
        double bsq = 0.0, nsq = 0.0, mean = 0.0, own = 0.0, sums = 0.0, with = 0.0;
        const int N = 200000;
        int i, ok;
        for (i = 0; i < N; ++i) {
            const double sum = (double)(i % 5) - 2.0;
            const double e = sum_noise(sum, 0.1, 4.0, &rng, &bsq, &nsq);
            mean += e;
            own  += e * e;
            sums += sum * sum;
            with += e * sum;
        }
        ok = fabs(sqrt(own / N) - 0.2) < 0.002 && fabs(mean / N) < 0.002 && fabs(with / N) < 0.002 &&
             fabs(nsq - own) < 1e-6 * own && fabs(bsq - sums) < 1e-9 * sums && sums == 2.0 * N;
        bsq = nsq = 0.0;
        ok = ok && sum_noise(3.0, 0.1, 0.0, &rng, &bsq, &nsq) == 0.0f && nsq == 0.0 && bsq == 9.0;
        if (!ok)
            ++errors;
        printf("  training noise: a tenth of an rms of 2 is %.4f over %d sums, with a mean of %+.4f, and "
               "none before the rms is known: %s\n", sqrt(own / N), N, mean / N,
               ok ? "as it should be" : "WRONG");
    }

    printf("selftest %s\n", errors ? "FAILED" : "passed");
    return errors ? 1 : 0;
}

static void help(void)
{
    printf("pta_mnist selftest\n"
           "pta_mnist invert IN OUT   an idx file of 28 x 28 images, every pixel taken from 255\n"
           "pta_mnist train --data DIR --din 8|16 --wbits B --seed S --out NET [--from NET] [--verbose 1]\n"
           "  --hidden H      hidden layers, each 100 wide (1, which is D3; up to 8)\n"
           "  --sumnoise F    train with Gaussian noise on every layer's sums, F of their rms (0)\n"
           "  --epochs N      run N epochs, in place of stopping when held-out accuracy stops rising\n"
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
           "  --src X         the light source: every line's power together, rms fraction a shot\n"
           "  --srcline X     each line's on its own, rms fraction a shot\n"
           "  --srcflat X     each line's level, rms fraction, fixed for the run\n"
           "  --buses B       the tile's rows as B runs that share their lines (1)\n"
           "  --srcsign pair|offset   what a line's light reaches a column through: its weight\n"
           "                  alone, or its weight and an offset the host takes off (pair)\n"
           "  --levelprobe P  read each line's level through a full-scale weight, P shots a row,\n"
           "                  and take it off; with a seed of its own, so the run's draws stay (0)\n"
           "  --levelfix ideal|weights|weights8|inputs   where what the probe read is applied:\n"
           "                  taken off the model's own line (ideal); or a row at a time on the\n"
           "                  weights as written, at the tile's bits or at 8, or on the inputs\n"
           "  --levelref none|dimmest   a dim line's row held at the rail (none), or every row\n"
           "                  scaled down to the dimmest line's and the sums divided back (none)\n"
           "  --levelpart none|LIST   what --levelfix weights8 leaves, told apart: the tile keeps\n"
           "                  the network as it was, and the sums take the parts listed of what\n"
           "                  the rewritten weights would be off by: read, round, rail.  For a\n"
           "                  source with no noise, held at the rail\n"
           "  --levellayer N  in layer N alone, from 1; or in every layer (0)\n"
           "  --thermalline X thermal sigma as a fraction of one line's light at a detector, an\n"
           "                  input at full scale through a weight of one: the same in every\n"
           "                  layer, as one laser fixes it.  Needs --adcbits\n"
           "  --hidshift D    added to every hidden layer's rescale: -1 hands the next layer\n"
           "                  operands twice as large, and clips the largest (0)\n"
           "  --w1gain B      the first layer's weights written 2^B as large, saturating; the\n"
           "                  hidden rescale takes the gain back (0)\n"
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
    if (argc == 4 && strcmp(argv[1], "invert") == 0) {
        long len = 0, n;
        uint8_t *b = read_file(argv[2], &len);
        FILE *f;
        if ((n = invert_idx(b, len)) < 0) {
            fprintf(stderr, "pta_mnist: %s missing or not an idx file of 28 x 28 images\n", argv[2]);
            free(b);
            return 1;
        }
        f = fopen(argv[3], "wb");
        if (!f || fwrite(b, 1, (size_t)len, f) != (size_t)len || fclose(f) != 0) {
            fprintf(stderr, "pta_mnist: cannot write %s\n", argv[3]);
            free(b);
            return 1;
        }
        free(b);
        printf("invert: %ld pixels\n", n);
        return 0;
    }
    help();
    return argc >= 2 && strcmp(argv[1], "help") == 0 ? 0 : 2;
}
