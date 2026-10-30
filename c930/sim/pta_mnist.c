// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
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
 * And a network that is not all on the tile (eval --host, --gate).  grxgpu's
 * first board runs one classifier's layers on three engines, the last of them
 * the PTA, and holds each engine to a reference in its own declared format.
 * --host N runs a network's first N layers on the host, exactly, as a digital
 * engine would, and the rest on the tile.  --gate has the probe measure the
 * last layer against that reference as well.  The network's shape is the
 * build's (-DN_SIDE, -DN_HID, -DN_OUT), and D3's unless a build says another.
 * --gatefit F sets the last layer's converter range from that reference on
 * the images that are run, where every other run has it from training images
 * by a rule written for the class: the smallest step at which the largest the
 * reference is, is within the share F of the converter's full scale.
 * --gatebits B gives the last layer's converter B bits at the step it has: a
 * bit more is twice the range at the same LSB, and the noise, which is in
 * that LSB, is what it was.  With --gatefit it is B bits over the fitted
 * range, which is the same range in finer steps.
 * --gatescale M gives the last layer's outputs one scale, fixed at
 * calibration: the least-squares slope of the declared reference on the
 * tile's outputs, over M images the network was not trained on (the first
 * of the 6,000 it holds out), run through the same tile after the test
 * images and with the light's shots their own.  The gate's figures are
 * given again with the outputs times that scale; and the scale the test
 * images would fit themselves, which no calibration knows and no scale
 * betters, with what it leaves.  The run's other figures are what they
 * were.
 * train --host N trains a network whose first N layers are a digital
 * engine's, as eval --host N runs them: their weights at the full D bits
 * and their sums with no tile noise, where the layers after are at --wbits
 * and have --sumnoise on theirs.  The network is written with its N, and
 * eval runs it with that --host and no other.  At N of nought everything is
 * what it was: the file, the training and every line.
 *
 * And the first board's canary as a golden manifest has it (pta_mnist
 * golden): a network of two hidden layers, both the host's, put through its
 * declared format image by image and written as raw tensors.  FC1 and FC2
 * are the host's, exactly, as eval --host runs them; FC2's operands become
 * FC3's activation codes by the contract's quantiser; FC3's exact sum, in
 * the codes' own units, is given, and the converter's code of it, which is
 * the declared reference; and the class, the largest code at its step with
 * its bias.  Beside them a double-precision pass of the network as trained,
 * for the task's quality.  It runs the same images through the tile with
 * its format alone and says how many codes differ: none, or it fails.
 * eval --gateref codes then holds the last layer to that reference: the
 * converter's code of the declared format's exact sum, at the last layer's
 * step and held to its codes, which the owner ruled is the canary's.  The
 * gate's figures are against it, with the largest error in codes and how
 * many outputs are a code off or more, two or more, and so on to 32.
 * eval --lightseed N draws a light's line levels, which are a source's own
 * and do not move from one run of the same vectors to the next, from a seed
 * of their own, where every shot's noise stays the run's: so that runs of
 * one source on many seeds are repeats, and what moves from repeat to repeat
 * can be told from what moves from source to source.
 * A light (--src, --srcline, --srcflat) is the tile's: with layers on the
 * host it lights the rest, and what a host does for its lines, read with
 * --levelprobe and applied with --levelfix, it does to the tile's layers'
 * weights or inputs and to no others.
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
 *                   [--sumnoise F] [--epochs N] [--host N]
 *   pta_mnist eval  --data DIR --net NET [options]        (pta_mnist help)
 *   pta_mnist golden --data DIR --net NET --out DIR --abits B --adcbits B --rows R --cols C
 *                   [--images N] [--cal M]
 */
#include "pta_tile_model.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The network's shape.  D3's is the default, and everything grxcp's plan quotes
 * was run on it.  A build may set another with -DN_SIDE, -DN_HID and -DN_OUT:
 * images N_SIDE square, hidden layers N_HID wide, N_OUT outputs.  A network's
 * file is as long as its shape makes it, and a build of another shape refuses
 * it for its length. */
#ifndef N_SIDE
#define N_SIDE      28
#endif
#ifndef N_HID
#define N_HID       100
#endif
#ifndef N_OUT
#define N_OUT       10
#endif
#define N_IN        (N_SIDE * N_SIDE)
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

/* A network's first layers that the host runs and no tile does: eval --host.
 * Nothing unless it is set. */
static int host_layers = 0;

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

/* PTAMLP2 is one hidden layer, laid out as it always was; PTAMLP3 says how many;
 * PTAMLP4 says how many and how many of the first are the host's (train --host). */
static const char MAGIC[8] = "PTAMLP2", MAGIC_DEEP[8] = "PTAMLP3", MAGIC_HOST[8] = "PTAMLP4";

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
    int      host;              /* its first layers, trained as a digital engine's: 0 for none */
    float   *w[MAX_L];          /* layer l, row n: its output n's input weights */
    float   *b[MAX_L];
} mlp;

/* The network as the host drives the tile. */
typedef struct {
    int      din, hidden;
    int      host;              /* the network's first layers trained as the host's, at D bits */
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
 * The calibration commands' seed base.  C3's probe is a separate phase of a run
 * -- zero weights, one-hot activations -- so its seeds come from the run's seed
 * mixed with this, and they share the run's index counter with the GEMMs: it is
 * one sequence of issued tile commands, not one per phase.  One definition,
 * read by the evaluate path and by the selftest's check 3b.
 */
#define PTA_CAL_SEED_XOR 0xCA11Bu

/*
 * The one place a run forms a seed.  seed_take() advances the run's index and
 * returns gemm_seed() of it, so the count of issued commands and the seed each
 * one gets are the same fact rather than two that can drift apart.  A check
 * that wants the sequence, in order, arms `seed_observe`; a run leaves it NULL
 * and pays one test.  seed_peek() is the same derivation without the run's
 * counter: a caller that numbers its own shots, or that wants one fixed seed
 * twice, still cannot form a seed the derivation does not.
 */
static void (*seed_observe)(uint32_t base, uint32_t index, uint32_t seed);

static uint32_t seed_peek(uint32_t base, uint32_t index)
{
    const uint32_t s = gemm_seed(base, index);
    if (seed_observe != NULL)
        seed_observe(base, index, s);
    return s;
}

static uint32_t seed_take(uint32_t base, uint32_t *index)
{
    return seed_peek(base, (*index)++);
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

/* The bits a layer's weights are trained and run at: a layer of the host's is a
 * digital engine's, at the full D bits, and every other is at the network's. */
static int layer_wbits(int host, int l, int din, int wbits)
{
    return l < host ? din : wbits;
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
        be32(bl + 4) != (uint32_t)count || be32(bi + 8) != N_SIDE || be32(bi + 12) != N_SIDE) {
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
    if (!b || len < 16 || be32(b) != 2051 || be32(b + 8) != N_SIDE || be32(b + 12) != N_SIDE ||
        len != 16 + (long)be32(b + 4) * N_IN)
        return -1;
    for (i = 16; i < len; ++i)
        b[i] = (uint8_t)(255 - b[i]);
    return len - 16;
}

/* An idx file of 28 x 28 images, in memory, pooled to side x side: the middle
 * of each image cut into side x side equal blocks, and each block's mean to
 * the nearest.  The same workload at a smaller size.  out has room for the
 * file as it was.  Returns the bytes of the pooled file, or -1: b is not
 * 28 x 28 images, or blocks of a whole number of pixels do not sit in the
 * middle of 28 for that side. */
static long pool_idx(const uint8_t *b, long len, int side, uint8_t *out)
{
    const int f = (side > 0 && side <= 28) ? 28 / side : 0, edge = 28 - f * side;
    long count, n;
    int r, c, dr, dc;
    if (!b || len < 16 || f < 1 || (edge & 1) || be32(b) != 2051 || be32(b + 8) != 28 ||
        be32(b + 12) != 28 || len != 16 + (long)be32(b + 4) * 784)
        return -1;
    count = (long)be32(b + 4);
    memcpy(out, b, 8);
    memset(out + 8, 0, 8);
    out[11] = out[15] = (uint8_t)side;
    for (n = 0; n < count; ++n)
        for (r = 0; r < side; ++r)
            for (c = 0; c < side; ++c) {
                int s = 0;
                for (dr = 0; dr < f; ++dr)
                    for (dc = 0; dc < f; ++dc)
                        s += b[16 + n * 784 + (edge / 2 + f * r + dr) * 28 + edge / 2 + f * c + dc];
                out[16 + n * side * side + r * side + c] = (uint8_t)((2 * s + f * f) / (2 * f * f));
            }
    return 16 + count * side * side;
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
 * held-out accuracy first fails to rise.
 *
 * host, if it is not zero, is how many of the first layers are the host's: a
 * digital engine's, as eval --host runs them.  Their weights are rounded at
 * the full din bits and not at wbits, and their sums are given no noise.  At
 * nought every layer is the tile's, as it always was. */
static void train(mlp *net, const dataset *tr, const dataset *te, int din, int wbits, int host,
                  int seed, const mlp *start, int verbose, double sumnoise, int epochs,
                  train_report *rep)
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

    memcpy(net->magic, host ? MAGIC_HOST : H == 1 ? MAGIC : MAGIC_DEEP, sizeof MAGIC);
    net->din   = din;
    net->wbits = wbits;
    net->host  = host;
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
                quantise(net->w[l], wq[l], layer_size(H, l), din, layer_wbits(host, l, din, wbits));
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
                    if (sumnoise > 0.0 && host < 1)
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
                        if (sumnoise > 0.0 && l >= host)
                            zz += sum_noise(zz - net->b[l][n], sumnoise, ms[l], &rn, &bsq[l], &nsq[l]);
                        z[l][n] = zz;
                        h[l][n] = zz > 0.0f ? zz : 0.0f;
                    }
                zmax = -1e30f;
                for (o = 0; o < N_OUT; ++o) {
                    float zz = net->b[H][o];
                    for (n = 0; n < N_HID; ++n)
                        zz += wq[H][o * N_HID + n] * h[H - 1][n];
                    if (sumnoise > 0.0 && H >= host)
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
            quantise(net->w[l], wq[l], layer_size(H, l), din, layer_wbits(host, l, din, wbits));
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
            q[l][i] = contract_quant(hn->w[l][i], layer_wbits(hn->host, l, hn->din, wbits), hn->din);
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
 * cfg is the run's, a layer each: the term uses each layer's own quantisers.
 * The lines' levels are drawn from level_seed, and every shot's noise from
 * seed. */
static int light_setup_at(const host_net *hn, const pta_cfg *cfg, uint32_t seed, uint32_t level_seed,
                          double all, double line, double flat, int buses, int offset)
{
    uint64_t s = ((uint64_t)level_seed << 32) | 0x11697u;
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

/* The same, the levels and the shots from one seed, as every run before
 * eval --lightseed had them. */
static int light_setup(const host_net *hn, const pta_cfg *cfg, uint32_t seed, double all,
                       double line, double flat, int buses, int offset)
{
    return light_setup_at(hn, cfg, seed, seed, all, line, flat, buses, offset);
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
 * The first host_layers layers are not the tile's.  The host runs them: each
 * is the exact product of its operands as they are and its weights as its own
 * quantiser has them, with no shot, no converter and no GEMM launched.  And
 * no light: a source's share is in the tile's layers' sums alone, and a
 * correction for its lines scales those layers' inputs and sums alone.
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
        if (light.on && light.fix == FIX_INPUTS && l >= host_layers)
            src = level_inputs(hn, &cfg[l], M, in, src);
        memset(y, 0, (size_t)M * out * sizeof *y);
        if (l < host_layers) {
            const int quant = (cfg[l].impair & PTA_QUANT) != 0;
            for (n = 0; n < out; ++n)
                for (k = 0; k < in; ++k) {
                    const int32_t wv = hn->w[l][n * in + k];
                    const int64_t w = quant ? contract_quant(wv, (int)cfg[l].w_bits, hn->din) : wv;
                    if (w != 0)
                        for (m = 0; m < M; ++m)
                            y[m * out + n] += (int64_t)src[m * in + k] * w;
                }
        } else {
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
                    c.seed = seed_take(seed, gemm);
                    if ((r = pta_gemm(&c, tile, dev, l & 1, M, N, K, g->A, g->B, g->C)) < 0)
                        return -1;
                    sats += r;
                    for (m = 0; m < M; ++m)
                        for (n = 0; n < N; ++n)
                            y[m * out + n0 + n] += g->C[m * N + n];
                }
            }
        }
        if (light.on && l >= host_layers)
            light_add(hn, &cfg[l], l, M, src, y);
        if (light.on && l >= host_layers && light.fix != FIX_NONE && light.gain != 1.0)
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

/* floor(v / 2^s), for v of either sign, as the tile's arithmetic shift has it. */
static int64_t floor_shift(int64_t v, int s)
{
    return v >= 0 ? v >> s : ~((~v) >> s);
}

/*
 * The last layer's declared reference (eval --gate).  It is the declared
 * format's exact sum, as every run before eval --gateref had it; or, with
 * gate_codes at the step's S, the converter's code of that sum, as the tile's
 * converter rounds it with no impairment: floor(sum / 2^S + 1/2), held to
 * its codes, times 2^S.  The gate's tail counts the outputs that many codes
 * off or more, to the nearest code: the light is added after the converter,
 * so a lit output need not be a code.
 */
#define GATE_TAIL 32
static int     gate_codes = -1;     /* the last layer's step S, or -1 for the sum */
static int64_t gate_lim;            /* its converter's codes are -gate_lim .. gate_lim - 1 */

static int64_t gate_reference(int64_t sum)
{
    int64_t c;
    if (gate_codes < 0)
        return sum;
    c = floor_shift(sum + (gate_codes > 0 ? (int64_t)1 << (gate_codes - 1) : 0), gate_codes);
    if (c > gate_lim - 1)
        c = gate_lim - 1;
    if (c < -gate_lim)
        c = -gate_lim;
    return c * ((int64_t)1 << gate_codes);
}

/* Whether an error d is t + 1 codes off or more, to the nearest code. */
static int gate_off(double d, int t)
{
    return fabs(d) > ldexp(t + 0.5, gate_codes);
}

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
    /* the last layer against a reference in its engine's own declared format,
     * which is what a board holds an engine to: eval --gate */
    int     gate;               /* whether to */
    int     gate_bits;          /* the activation bits that engine declares; 0 is the operand's */
    double  ge, gr;             /* sums of squares: its error against that reference, and the reference */
    double  gpeak, gworst;      /* the largest that reference is, and the largest the error */
    double  hpeak, hworst;      /* the same two against the operands as they were given */
    int     gright, gagree;     /* images that reference has right, and images the tile gives its class */
    long    gtail[GATE_TAIL];   /* with the reference in codes: outputs t + 1 codes off or more */
    /* and, for one scale on the last layer's outputs (eval --gatescale), the
     * outputs and that reference, images x N_OUT: NULL unless asked for */
    double *gy, *gf;
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
    free(p->gy);
    free(p->gf);
}

/* M images: their operands, what tile_batch() left in bw for them, and the
 * reference weights from quant_weights() at the network's own width. */
static void probe_batch(probe *p, const host_net *hn, int32_t *const *q, int M, const int32_t *a0,
                        const batch_ws *bw, const uint8_t *labels)
{
    const int H = hn->hidden;
    image_ws ws;
    int m, n, k, o, j, l, t;
    for (m = 0; m < M; ++m) {
        double err[N_OUT], *lg = p->logit + (size_t)p->images * N_OUT, em = 0.0, gm = 0.0;
        const int64_t *y2 = bw->y[H] + m * N_OUT;
        int best = 0, second = -1, tile_best = 0, fmt_best = 0;
        int64_t fmt_top = 0;
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
            if (p->gate) {
                int64_t fmt = 0;
                double df;
                for (k = 0; k < N_HID; ++k)
                    fmt += (int64_t)contract_quant(bw->a[H][m * N_HID + k], p->gate_bits, hn->din) *
                           q[H][o * N_HID + k];
                fmt = gate_reference(fmt);
                df = (double)(y2[o] - fmt);
                if (gate_codes >= 0)
                    for (t = 0; t < GATE_TAIL; ++t)
                        p->gtail[t] += gate_off(df, t);
                p->ge += df * df;
                p->gr += (double)fmt * (double)fmt;
                if (fabs((double)fmt) > p->gpeak)
                    p->gpeak = fabs((double)fmt);
                if (fabs(df) > p->gworst)
                    p->gworst = fabs(df);
                if (p->gy) {
                    p->gy[(size_t)p->images * N_OUT + o] = (double)y2[o];
                    p->gf[(size_t)p->images * N_OUT + o] = (double)fmt;
                }
                if (fabs((double)loc) > p->hpeak)
                    p->hpeak = fabs((double)loc);
                if (fabs(dl) > p->hworst)
                    p->hworst = fabs(dl);
                /* its class: the largest with its bias, and the first of them if two are */
                if (o == 0 || fmt + hn->b[H][o] > fmt_top) {
                    fmt_top  = fmt + hn->b[H][o];
                    fmt_best = o;
                }
            }
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
        if (p->gate) {
            p->gright += fmt_best == labels[m];
            p->gagree += fmt_best == tile_best;
        }
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
    /* the gate's: the last layer's rms error over its declared reference's rms;
     * over the largest that reference is; the largest error over the same; and
     * that largest.  And the last three against the operands as they were given */
    double gate_rms, gate_rmsfs, gate_maxfs, gate_peak, gate8_rmsfs, gate8_maxfs, gate8_peak;
    /* and how often that reference is right, and how often the tile gives its class, percent */
    double gate_ref, gate_agree;
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
    r->gate_rms    = p->gr > 0 ? sqrt(p->ge / p->gr) : 0.0;
    r->gate_rmsfs  = p->gpeak > 0 ? sqrt(p->ge / (n * N_OUT)) / p->gpeak : 0.0;
    r->gate_maxfs  = p->gpeak > 0 ? p->gworst / p->gpeak : 0.0;
    r->gate_peak   = p->gpeak;
    r->gate8_rmsfs = p->hpeak > 0 ? sqrt(p->e[H] / (n * N_OUT)) / p->hpeak : 0.0;
    r->gate8_maxfs = p->hpeak > 0 ? p->hworst / p->hpeak : 0.0;
    r->gate8_peak  = p->hpeak;
    r->gate_ref    = 100.0 * p->gright / n;
    r->gate_agree  = 100.0 * p->gagree / n;
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
            c.seed = seed_take(seed, gemm);
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
            c.seed = seed_peek(own, count);
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
 * A layer the host runs is not lit, and is left as it is: its weights are the
 * network's and its w_bits the run's.
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
                if (l < host_layers) {
                    out->w[l][n * in + j] = w;
                    continue;
                }
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
        for (l = host_layers; l <= H; ++l)
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
    hn->host = net->host;
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

/*
 * A range fitted to the gate (eval --gatefit).  adc_setup() sets a converter's
 * range on training images, to pass all but one sum in ten thousand.  That is
 * a rule for the class, which a clipped sum seldom moves.  A board that holds
 * the last layer's raw outputs to a reference defines its full scale from
 * that reference.
 *
 * declared_peak() is the largest a tile's sum of the last layer's declared
 * reference is over M images, for a network whose other layers all run on the
 * host, so that the reference is known before any shot is taken.  q is the
 * weights at the network's own width, from quant_weights(), and bits the
 * activation bits the tile declares.  It launches nothing.  Returns the peak,
 * or -1.
 *
 * fit_shift() is the smallest shift at which a value is within a share of a
 * converter's full scale, or -1 if the share leaves the converter no code.
 * With the whole of it no sum of the reference is past the range: what the
 * converter then clips is noise, and a clipped sum is nearer its reference
 * than the sum it was.
 */
static int64_t declared_peak(const host_net *hn, const pta_cfg *cfg, gemm_buf *g,
                             int32_t *const *q, int bits, int M, const int32_t *a0, batch_ws *bw)
{
    const int H = hn->hidden, was = host_layers;
    uint32_t gemm = 0;
    int64_t peak = 0;
    long r;
    int m, o, k, k0;
    host_layers = H + 1;                /* every layer, the last too: no shot is taken */
    r = tile_batch(hn, cfg, NULL, NULL, 0, &gemm, g, M, a0, bw);
    host_layers = was;
    if (r != 0 || gemm != 0)
        return -1;
    for (m = 0; m < M; ++m)
        for (o = 0; o < N_OUT; ++o)
            for (k0 = 0; k0 < N_HID; k0 += tile_rows) {
                int64_t fmt = 0;
                for (k = k0; k < k0 + tile_rows && k < N_HID; ++k)
                    fmt += (int64_t)contract_quant(bw->a[H][m * N_HID + k], bits, hn->din) *
                           q[H][o * N_HID + k];
                if (fmt < 0)
                    fmt = -fmt;
                if (fmt > peak)
                    peak = fmt;
            }
    return peak;
}

static int fit_shift(int64_t peak, int adc_bits, double share)
{
    const int64_t lim = (int64_t)floor(share * (double)(((int64_t)1 << (adc_bits - 1)) - 1));
    return (lim < 1 || peak < 0) ? -1 : shift_needed(peak, lim);
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

/* The header, then the depth if it is more than one or any layer is the host's,
 * then how many are the host's if any is, then w and b by layer.  The magic says
 * which: written here from the depth and the host's layers, and so a network
 * with none of the host's is the file it always was. */
static int write_net(FILE *f, const mlp *net)
{
    mlp head = *net;
    int l, ok;
    memcpy(head.magic, net->host ? MAGIC_HOST : net->hidden == 1 ? MAGIC : MAGIC_DEEP, sizeof MAGIC);
    ok = f && fwrite(&head, HEAD_BYTES, 1, f) == 1;
    if (net->hidden > 1 || net->host)
        ok = ok && fwrite(&net->hidden, sizeof(int), 1, f) == 1;
    if (net->host)
        ok = ok && fwrite(&net->host, sizeof(int), 1, f) == 1;
    for (l = 0; ok && l <= net->hidden; ++l) {
        const size_t P = (size_t)layer_size(net->hidden, l), B = (size_t)layer_out(net->hidden, l);
        ok = fwrite(net->w[l], sizeof(float), P, f) == P &&
             fwrite(net->b[l], sizeof(float), B, f) == B;
    }
    return ok ? 0 : -1;
}

static int save_net(const char *path, const mlp *net)
{
    FILE *f = fopen(path, "wb");
    int ok = f && write_net(f, net) == 0;
    if (f && fclose(f) != 0)
        ok = 0;
    return ok ? 0 : -1;
}

/* Reads a network to the end of f and allocates it.  Returns 0, or -1.  A
 * network with layers of the host's has from one to all but its last. */
static int read_net(FILE *f, mlp *net)
{
    int hidden = 1, host = 0, l, ok;
    memset(net, 0, sizeof *net);
    ok = f && fread(net, HEAD_BYTES, 1, f) == 1;
    if (ok && memcmp(net->magic, MAGIC_HOST, sizeof MAGIC_HOST) == 0)
        ok = fread(&hidden, sizeof(int), 1, f) == 1 && hidden >= 1 && hidden <= MAX_HID &&
             fread(&host, sizeof(int), 1, f) == 1 && host >= 1 && host <= hidden;
    else if (ok && memcmp(net->magic, MAGIC_DEEP, sizeof MAGIC_DEEP) == 0)
        ok = fread(&hidden, sizeof(int), 1, f) == 1 && hidden > 1 && hidden <= MAX_HID;
    else
        ok = ok && memcmp(net->magic, MAGIC, sizeof MAGIC) == 0;
    ok = ok && mlp_alloc(net, hidden) == 0;
    net->host = ok ? host : 0;
    for (l = 0; ok && l <= hidden; ++l) {
        const size_t P = (size_t)layer_size(hidden, l), B = (size_t)layer_out(hidden, l);
        ok = fread(net->w[l], sizeof(float), P, f) == P &&
             fread(net->b[l], sizeof(float), B, f) == B;
    }
    ok = ok && fgetc(f) == EOF;
    return ok ? 0 : -1;
}

/* Reads a network and allocates it.  Returns 0, or -1 with a message. */
static int load_net(const char *path, mlp *net)
{
    FILE *f = fopen(path, "rb");
    const int ok = f && read_net(f, net) == 0;
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
        "--verbose", "--hidden", "--sumnoise", "--epochs", "--host", NULL};
    const char *data = opt(argc, argv, "--data", NULL), *out = opt(argc, argv, "--out", NULL);
    const char *from = opt(argc, argv, "--from", NULL);
    const int din = atoi(opt(argc, argv, "--din", "16")), wbits = atoi(opt(argc, argv, "--wbits", "0"));
    const int seed = atoi(opt(argc, argv, "--seed", "1"));
    const int hidden = atoi(opt(argc, argv, "--hidden", "1"));
    const int host = atoi(opt(argc, argv, "--host", "0"));
    const char *noise_opt = opt(argc, argv, "--sumnoise", NULL), *epochs_opt = opt(argc, argv, "--epochs", NULL);
    const double sumnoise = noise_opt ? atof(noise_opt) : 0.0;
    const int epochs = epochs_opt ? atoi(epochs_opt) : 0;
    train_report rep;
    dataset tr, te;
    mlp net, from_net, *start = NULL;
    int l;
    if (check_opts(argc, argv, names) != 0 || !data || !out || (din != 8 && din != 16) ||
        wbits < 0 || wbits > din || hidden < 1 || hidden > MAX_HID ||
        sumnoise < 0.0 || sumnoise > 1.0 || epochs < 0 || epochs > MAX_EPOCHS || host < 0 ||
        host > hidden) {
        fprintf(stderr, "pta_mnist train: --data DIR --din 8|16 --wbits 0..D --seed S --out NET "
                        "[--from NET] [--hidden 1..%d] [--sumnoise 0..1] [--epochs 0..%d] "
                        "[--host 0..H]\n", MAX_HID, MAX_EPOCHS);
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
    train(&net, &tr, &te, din, wbits, host, seed, start, atoi(opt(argc, argv, "--verbose", "0")),
          sumnoise, epochs, &rep);
    if (save_net(out, &net) != 0) {
        fprintf(stderr, "pta_mnist: cannot write %s\n", out);
        return 2;
    }
    printf("din=%d wbits=%d seed=%d from=%d from_epochs=%d epochs=%d held_out=%.2f digital=%.2f",
           din, wbits, seed, net.from_bits, net.from_epochs, net.epochs, net.val_acc, net.test_acc);
    if (hidden > 1)
        printf(" hidden=%d", hidden);
    if (host)
        printf(" host=%d", host);
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

/*
 * One scale on the last layer's outputs (eval --gatescale).  scale_sums()
 * adds, over M images tile_batch() left in bw, the tile's last outputs times
 * their declared reference and the outputs squared: the scale is the one
 * over the other, the least-squares slope of that reference on the outputs.
 * scale_best() is the same over the images the probe kept, and
 * scale_calibrate() over M images of pixels x from the first'th on, run
 * through the tile after the test images: the light's shots are numbered
 * from N_TEST on, so that none of them is a test image's.  scale_fix() is
 * what eval reports: that scale, the images it was fixed on, the scale the
 * probe's images would fit themselves, and the gate's figures with each of
 * the two.  scale_gate()
 * gives the gate's figures again with the outputs times a scale: the rms
 * error over the reference's rms, over the largest the reference is, the
 * largest error over that, and how often the class the scaled outputs give
 * with their biases is the class the reference gives with them.
 */
typedef struct {
    double rms, rmsfs, maxfs, agree;
    double worst;                   /* the largest error, in the sums' units */
    long   tail[GATE_TAIL];         /* with the reference in codes: as the probe's */
} scale_result;

static void scale_sums(const host_net *hn, int32_t *const *q, int bits, int M, const batch_ws *bw,
                       double *yf, double *yy)
{
    const int H = hn->hidden;
    int m, o, k;
    for (m = 0; m < M; ++m)
        for (o = 0; o < N_OUT; ++o) {
            const double y = (double)bw->y[H][m * N_OUT + o];
            int64_t fmt = 0;
            for (k = 0; k < N_HID; ++k)
                fmt += (int64_t)contract_quant(bw->a[H][m * N_HID + k], bits, hn->din) * q[H][o * N_HID + k];
            fmt = gate_reference(fmt);
            *yf += y * (double)fmt;
            *yy += y * y;
        }
}

static double scale_best(const probe *p)
{
    double yf = 0.0, yy = 0.0;
    long i;
    for (i = 0; i < (long)p->images * N_OUT; ++i) {
        yf += p->gy[i] * p->gf[i];
        yy += p->gy[i] * p->gy[i];
    }
    return yy > 0.0 ? yf / yy : 1.0;
}

static void scale_gate(const probe *p, const host_net *hn, double s, scale_result *r)
{
    const int H = hn->hidden;
    double e = 0.0, f2 = 0.0, worst = 0.0;
    int i, o, t, agree = 0;
    memset(r->tail, 0, sizeof r->tail);
    for (i = 0; i < p->images; ++i) {
        const double *y = p->gy + (size_t)i * N_OUT, *f = p->gf + (size_t)i * N_OUT;
        int yb = 0, fb = 0;
        for (o = 0; o < N_OUT; ++o) {
            const double d = s * y[o] - f[o];
            e  += d * d;
            f2 += f[o] * f[o];
            if (fabs(d) > worst)
                worst = fabs(d);
            if (gate_codes >= 0)
                for (t = 0; t < GATE_TAIL; ++t)
                    r->tail[t] += gate_off(d, t);
            if (s * y[o] + (double)hn->b[H][o] > s * y[yb] + (double)hn->b[H][yb])
                yb = o;
            if (f[o] + (double)hn->b[H][o] > f[fb] + (double)hn->b[H][fb])
                fb = o;
        }
        agree += yb == fb;
    }
    r->rms   = f2 > 0.0 ? sqrt(e / f2) : 0.0;
    r->rmsfs = p->gpeak > 0.0 ? sqrt(e / ((double)p->images * N_OUT)) / p->gpeak : 0.0;
    r->maxfs = p->gpeak > 0.0 ? worst / p->gpeak : 0.0;
    r->agree = p->images ? 100.0 * agree / p->images : 0.0;
    r->worst = worst;
}

static int scale_calibrate(const host_net *ht, const host_net *hn, int32_t *const *q, int bits,
                           const pta_cfg *cfg, const pta_tile *tile, pta_device *dev, uint32_t seed,
                           uint32_t *gemm, gemm_buf *g, const uint8_t *x, int first, int M, batch_ws *bw,
                           int32_t *a1, double *scale)
{
    double yf = 0.0, yy = 0.0;
    int base, m, k;
    for (base = 0; base < M; base += MAX_M) {
        const int B = (M - base < MAX_M) ? M - base : MAX_M;
        light.base = N_TEST + base;
        for (m = 0; m < B; ++m)
            for (k = 0; k < N_IN; ++k)
                a1[m * N_IN + k] = pixel_operand(x[(size_t)(first + base + m) * N_IN + k], hn->din);
        if (tile_batch(ht, cfg, tile, dev, seed, gemm, g, B, a1, bw) < 0)
            return -1;
        scale_sums(hn, q, bits, B, bw, &yf, &yy);
    }
    *scale = yy > 0.0 ? yf / yy : 1.0;
    return 0;
}

typedef struct {
    double       scale, best;       /* fixed on the calibration's images, and the probe's images' own */
    int          images, first;     /* how many images the scale was fixed on, and the first of them */
    scale_result at_scale, at_best; /* the gate's figures with the outputs times each */
} scale_report;

static int scale_fix(const probe *p, const host_net *ht, const host_net *hn, int32_t *const *q, int bits,
                     const pta_cfg *cfg, const pta_tile *tile, pta_device *dev, uint32_t seed, uint32_t *gemm,
                     gemm_buf *g, const uint8_t *x, int first, int M, batch_ws *bw, int32_t *a1, scale_report *r)
{
    if (scale_calibrate(ht, hn, q, bits, cfg, tile, dev, seed, gemm, g, x, first, M, bw, a1, &r->scale) != 0)
        return -1;
    r->images = M;
    r->first  = first;
    r->best   = scale_best(p);
    scale_gate(p, hn, r->scale, &r->at_scale);
    scale_gate(p, hn, r->best, &r->at_best);
    return 0;
}

/*
 * The canary's golden tensors (pta_mnist golden).  golden_image() puts one
 * image through a network of two hidden layers, both the host's, in its
 * declared format: each hidden layer's sums, bias, ReLU and rescale as the
 * host runs them (tile_batch()'s host path), at the operands' full width;
 * then the last layer's activation codes, q(x, abits) in units of its own
 * step, and its weight codes the same at wbits; their exact sum in those
 * units; and the converter's code of it, which is pta_element()'s with no
 * impairment: the sum at the tile's own scale, floored at the step 2^S and
 * rounded half up, and held to the converter's codes.  A code held is a
 * range fault, and is counted.  The class is the largest of each code at
 * its step with its bias, the first of them if two are.
 */
/* The class: the largest code at its step with its bias; of two the same,
 * the first. */
static int golden_class(const int8_t *codes, const int64_t *b, int S)
{
    int64_t best = 0;
    int o, cls = 0;
    for (o = 0; o < N_OUT; ++o) {
        const int64_t v = (int64_t)codes[o] * ((int64_t)1 << S) + b[o];
        if (o == 0 || v > best) {
            best = v;
            cls  = o;
        }
    }
    return cls;
}

static int golden_image(const host_net *hn, int32_t *const *q, int abits, int wbits, int adc_bits, int S,
                        const int32_t *a0, int32_t *a1, int32_t *a2, uint8_t *ca, int32_t *sums, int8_t *codes,
                        long *clipped)
{
    const int D = hn->din, H = hn->hidden;
    const int hA = abits > 0 && abits < D ? D - abits : 0, hW = wbits > 0 && wbits < D ? D - wbits : 0;
    const int64_t amax = ((int64_t)1 << (D - 1)) - 1, lim = (int64_t)1 << (adc_bits - 1);
    const int32_t *src = a0;
    int32_t *dst;
    int l, n, k, o;
    for (l = 0; l < H; ++l) {
        const int in = layer_in(l);
        dst = l == 0 ? a1 : a2;
        for (n = 0; n < N_HID; ++n) {
            int64_t v = 0;
            for (k = 0; k < in; ++k)
                v += (int64_t)src[k] * q[l][n * in + k];
            v += hn->b[l][n];
            v = round_shift(v > 0 ? v : 0, hn->sh[l]);
            dst[n] = (int32_t)(v > amax ? amax : v);
        }
        src = dst;
    }
    for (k = 0; k < N_HID; ++k)
        ca[k] = (uint8_t)(contract_quant(a2[k], abits, D) >> hA);
    for (o = 0; o < N_OUT; ++o) {
        int64_t sum = 0, tq;
        for (k = 0; k < N_HID; ++k)
            sum += (int64_t)ca[k] * (q[H][o * N_HID + k] / ((int32_t)1 << hW));
        sums[o] = (int32_t)sum;
        tq = floor_shift(floor_shift(sum * ((int64_t)1 << (hA + hW)) * 256, S) + 128, 8);
        if (tq > lim - 1) { tq = lim - 1; ++*clipped; }
        if (tq < -lim)    { tq = -lim;    ++*clipped; }
        codes[o] = (int8_t)tq;
    }
    return golden_class(codes, hn->b[H], S);
}

/* One image through the network as trained, in double precision: its weights
 * and biases as they are, the pixels over 255, and no quantiser anywhere. */
static void golden_float(const mlp *net, const uint8_t *px, double *logits)
{
    const int H = net->hidden;
    double x[N_IN], h[2][N_HID];
    int l, n, k;
    for (k = 0; k < N_IN; ++k)
        x[k] = px[k] / 255.0;
    for (l = 0; l <= H; ++l) {
        const int in = layer_in(l), out = layer_out(H, l);
        const double *src = l == 0 ? x : h[(l - 1) & 1];
        for (n = 0; n < out; ++n) {
            double z = net->b[l][n];
            for (k = 0; k < in; ++k)
                z += (double)net->w[l][n * in + k] * src[k];
            if (l < H)
                h[l & 1][n] = z > 0.0 ? z : 0.0;
            else
                logits[n] = z;
        }
    }
}

static int write_raw(const char *dir, const char *name, const void *p, size_t bytes)
{
    char path[1024];
    FILE *f;
    int ok;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    f = fopen(path, "wb");
    ok = f && fwrite(p, 1, bytes, f) == bytes;
    if (f && fclose(f) != 0)
        ok = 0;
    if (!ok)
        fprintf(stderr, "pta_mnist: cannot write %s\n", path);
    return ok ? 0 : -1;
}

/* Little-endian, whatever the host's order. */
static void put_le32(uint8_t *b, uint32_t v)
{
    b[0] = (uint8_t)v;
    b[1] = (uint8_t)(v >> 8);
    b[2] = (uint8_t)(v >> 16);
    b[3] = (uint8_t)(v >> 24);
}

static void put_le64(uint8_t *b, uint64_t v)
{
    put_le32(b, (uint32_t)v);
    put_le32(b + 4, (uint32_t)(v >> 32));
}

static int cmd_golden(int argc, char **argv)
{
    static const char *const names[] = {"--data", "--net", "--out", "--abits", "--adcbits", "--rows", "--cols",
        "--images", "--cal", NULL};
    const char *data = opt(argc, argv, "--data", NULL), *path = opt(argc, argv, "--net", NULL);
    const char *out = opt(argc, argv, "--out", NULL);
    const int abits = atoi(opt(argc, argv, "--abits", "0")), adc_bits = atoi(opt(argc, argv, "--adcbits", "0"));
    const int images = atoi(opt(argc, argv, "--images", "1000")), cal = atoi(opt(argc, argv, "--cal", "1000"));
    mlp net_s, *net = &net_s;
    host_net hn;
    dataset tr, te;
    int32_t *q[MAX_L], a1[N_HID], a2[N_HID];
    int S[MAX_L];
    int set, i, k, l, o, H, total;
    long clipped = 0, differ = 0, act_differ = 0, right = 0, hp_right = 0, hp_agree = 0;
    int32_t *a0 = (int32_t *)malloc((size_t)MAX_M * N_IN * sizeof(int32_t));
    batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
    gemm_buf *g = NULL;
    pta_cfg cfg[MAX_L];
    pta_tile tile;
    pta_device dev;

    tile_rows = atoi(opt(argc, argv, "--rows", "0"));
    tile_cols = atoi(opt(argc, argv, "--cols", "0"));
    if (check_opts(argc, argv, names) != 0 || !data || !path || !out || abits < 1 || abits > 8 ||
        adc_bits < 2 || adc_bits > 15 || tile_rows < N_HID || tile_cols < 1 || images < 1 || images > N_TEST ||
        cal < 0 || cal > N_ALL - N_TRAIN) {
        fprintf(stderr, "pta_mnist golden: --data DIR --net NET --out DIR --abits 1..8 --adcbits 2..15 --rows R "
                        "--cols C [--images 1..%d] [--cal 0..%d]: R has to hold the last layer's %d inputs in "
                        "one shot\n", N_TEST, N_ALL - N_TRAIN, N_HID);
        return 2;
    }
    if (!a0 || !bw || load_net(path, net) != 0 || load_mnist(data, &tr, &te) != 0)
        return 2;
    H = net->hidden;
    if (H != 2 || net->host != H || net->din != 8) {
        fprintf(stderr, "pta_mnist: %s is not a canary: two hidden layers, both the host's, at 8 bits\n", path);
        return 2;
    }
    /* the cut is a whole layer, as eval's is on any tile but the core's, and
     * the buffers are the cut's */
    gemm_k = tile_rows * ((N_IN + tile_rows - 1) / tile_rows);
    gemm_n = tile_cols * ((N_HID + tile_cols - 1) / tile_cols);
    if (!(g = gemm_alloc()) || host_setup(&hn, net, &tr) != 0)
        return 2;
    adc_setup(&hn, net, &tr, adc_bits, S);
    for (l = 0; l <= H; ++l)
        q[l] = (int32_t *)malloc((size_t)layer_size(H, l) * sizeof(int32_t));
    quant_weights(&hn, net->wbits, q);

    /* the network's integers */
    {
        int8_t w8[N_HID * N_IN];
        uint8_t b32[4 * N_HID];
        static const char *const wn[3] = {"fc1_weights_int8.bin", "fc2_weights_int8.bin", "fc3_weights_int8.bin"};
        static const char *const bn[3] = {"fc1_bias_int32.bin", "fc2_bias_int32.bin", "fc3_bias_int32.bin"};
        for (l = 0; l <= H; ++l) {
            const int P = layer_size(H, l), hW = l < H ? 0 : hn.din - net->wbits;
            for (i = 0; i < P; ++i)
                w8[i] = (int8_t)(q[l][i] / ((int32_t)1 << hW));
            for (i = 0; i < layer_out(H, l); ++i) {
                if (hn.b[l][i] > INT32_MAX || hn.b[l][i] < INT32_MIN) {
                    fprintf(stderr, "pta_mnist: a bias of layer %d is past 32 bits\n", l + 1);
                    return 2;
                }
                put_le32(b32 + 4 * i, (uint32_t)(int32_t)hn.b[l][i]);
            }
            if (write_raw(out, wn[l], w8, (size_t)P) != 0 ||
                write_raw(out, bn[l], b32, 4 * (size_t)layer_out(H, l)) != 0)
                return 2;
        }
    }
    /* the acceptance images and the calibration images, each through the
     * declared format and through the tile with its format alone */
    memset(cfg, 0, sizeof cfg);
    cfg[0].impair   = PTA_QUANT;
    cfg[0].w_bits   = (uint32_t)net->wbits;
    cfg[0].act_bits = (uint32_t)abits;
    cfg[0].adc_bits = (uint32_t)adc_bits;
    for (l = 1; l <= H; ++l)
        cfg[l] = cfg[0];
    for (l = 0; l <= H; ++l)
        cfg[l].adc_shift = (uint32_t)S[l];
    for (l = 0; l < H; ++l)
        cfg[l].w_bits = (uint32_t)net->din;
    tile.rows  = tile_rows;
    tile.cols  = tile_cols;
    tile.din_w = net->din;
    tile.acc_w = ACC_W;
    if (pta_device_init(&dev, &tile) != 0)
        return 2;
    host_layers = H;
    for (set = 0; set < 2; ++set) {
        const int n = set == 0 ? images : cal, first = set == 0 ? 0 : N_TRAIN;
        const uint8_t *x = set == 0 ? te.x : tr.x;
        int8_t *in8 = (int8_t *)malloc((size_t)n * N_IN + 1), *f1 = (int8_t *)malloc((size_t)n * N_HID + 1);
        uint8_t *px8 = (uint8_t *)malloc((size_t)n * N_IN + 1);
        int8_t *f2 = (int8_t *)malloc((size_t)n * N_HID + 1), *oc = (int8_t *)malloc((size_t)n * N_OUT + 1);
        uint8_t *cin = (uint8_t *)malloc((size_t)n * N_HID + 1), *cls = (uint8_t *)malloc((size_t)n + 1);
        uint8_t *lab = (uint8_t *)malloc((size_t)n + 1), *s32 = (uint8_t *)malloc(4 * (size_t)n * N_OUT + 1);
        uint8_t *hp = (uint8_t *)malloc(8 * (size_t)n * N_OUT + 1);
        uint32_t gemm = 0;
        int base, m;
        if (!in8 || !px8 || !f1 || !f2 || !oc || !cin || !cls || !lab || !s32 || !hp)
            return 2;
        for (base = 0; base < n; base += MAX_M) {
            const int M = (n - base < MAX_M) ? n - base : MAX_M;
            for (m = 0; m < M; ++m)
                for (k = 0; k < N_IN; ++k)
                    a0[m * N_IN + k] = pixel_operand(x[(size_t)(first + base + m) * N_IN + k], net->din);
            if (tile_batch(&hn, cfg, &tile, &dev, 1, &gemm, g, M, a0, bw) < 0)
                return 2;
            for (m = 0; m < M; ++m) {
                const int img = base + m;
                int32_t sums[N_OUT];
                int8_t codes[N_OUT];
                uint8_t ca[N_HID];
                double lg[N_OUT];
                int c, hc = 0;
                c = golden_image(&hn, q, abits, net->wbits, adc_bits, S[H], a0 + m * N_IN, a1, a2, ca, sums, codes,
                                 &clipped);
                for (k = 0; k < N_IN; ++k) {
                    in8[(size_t)img * N_IN + k] = (int8_t)a0[m * N_IN + k];
                    px8[(size_t)img * N_IN + k] = x[(size_t)(first + img) * N_IN + k];
                }
                for (k = 0; k < N_HID; ++k) {
                    f1[(size_t)img * N_HID + k] = (int8_t)a1[k];
                    f2[(size_t)img * N_HID + k] = (int8_t)a2[k];
                    cin[(size_t)img * N_HID + k] = ca[k];
                    act_differ += bw->a[1][m * N_HID + k] != a1[k];
                    act_differ += bw->a[2][m * N_HID + k] != a2[k];
                }
                golden_float(net, x + (size_t)(first + img) * N_IN, lg);
                for (o = 0; o < N_OUT; ++o) {
                    union { double d; uint64_t u; } bits;
                    oc[(size_t)img * N_OUT + o] = codes[o];
                    put_le32(s32 + 4 * ((size_t)img * N_OUT + o), (uint32_t)sums[o]);
                    bits.d = lg[o];
                    put_le64(hp + 8 * ((size_t)img * N_OUT + o), bits.u);
                    differ += bw->y[H][m * N_OUT + o] != (int64_t)codes[o] * ((int64_t)1 << S[H]);
                    if (lg[o] > lg[hc])
                        hc = o;
                }
                cls[img] = (uint8_t)c;
                lab[img] = set == 0 ? te.y[img] : tr.y[first + img];
                if (set == 0) {
                    right += c == lab[img];
                    hp_right += hc == lab[img];
                    hp_agree += hc == c;
                }
            }
        }
        {
            const char *const pre = set == 0 ? "" : "cal_";
            char nm[64];
#define GOLD(NAME, PTR, BYTES) do { snprintf(nm, sizeof nm, "%s%s", pre, NAME); \
                                    if (write_raw(out, nm, PTR, BYTES) != 0) return 2; } while (0)
            if (n > 0) {
                GOLD("pixels_u8.bin", px8, (size_t)n * N_IN);
                GOLD("inputs_int8.bin", in8, (size_t)n * N_IN);
                GOLD("labels_u8.bin", lab, (size_t)n);
                GOLD("fc1_relu_int8.bin", f1, (size_t)n * N_HID);
                GOLD("fc2_relu_int8.bin", f2, (size_t)n * N_HID);
                GOLD("fc3_act_codes_u8.bin", cin, (size_t)n * N_HID);
                GOLD("fc3_sums_int32.bin", s32, 4 * (size_t)n * N_OUT);
                GOLD("fc3_codes_int8.bin", oc, (size_t)n * N_OUT);
                GOLD("class_ids_u8.bin", cls, (size_t)n);
                GOLD("highprec_logits_f64.bin", hp, 8 * (size_t)n * N_OUT);
            }
#undef GOLD
        }
        free(in8); free(px8); free(f1); free(f2); free(oc); free(cin); free(cls); free(lab); free(s32); free(hp);
    }
    host_layers = 0;
    total = (images + cal) * N_OUT;
    printf("golden: net_seed=%d net_wbits=%d net_host=%d images=%d cal=%d cal_first=%d abits=%d adcbits=%d "
           "tile=%dx%d sh=%d,%d S=%d code_shift=%d clipped=%ld tile_differ=%ld of %d act_differ=%ld of %d "
           "declared_right=%.2f highprec_right=%.2f highprec_agree=%.2f\n",
           net->seed, net->wbits, net->host, images, cal, N_TRAIN, abits, adc_bits, tile_rows, tile_cols,
           hn.sh[0], hn.sh[1], S[H], S[H] - (net->din - abits) - (net->din - net->wbits), clipped, differ, total,
           act_differ, 2 * (images + cal) * N_HID, 100.0 * right / images, 100.0 * hp_right / images,
           100.0 * hp_agree / images);
    pta_device_free(&dev);
    host_free(&hn);
    for (l = 0; l <= H; ++l)
        free(q[l]);
    gemm_free(g);
    free(bw);
    free(a0);
    mlp_free(net);
    /* none past the range, and the tile's format alone the declared reference, code for code */
    return clipped == 0 && differ == 0 && act_differ == 0 ? 0 : 1;
}

static int cmd_eval(int argc, char **argv)
{
    static const char *const names[] = {"--data", "--net", "--images", "--seed", "--impair",
        "--wbits", "--abits", "--adcbits", "--thermal", "--photons", "--prog", "--xtalk",
        "--drift", "--hours", "--calibrate", "--trimstep", "--trimmax", "--post-hours",
        "--probe", "--thermal8", "--photons8", "--rows", "--cols", "--maxk", "--maxn", "--src",
        "--srcline", "--srcflat", "--buses", "--srcsign", "--thermalline", "--hidshift",
        "--w1gain", "--levelprobe", "--levelfix", "--levelref", "--levelpart", "--levellayer",
        "--host", "--gate", "--gatefit", "--gatebits", "--gatescale", "--gateref", "--lightseed", NULL};
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
    const int host = atoi(opt(argc, argv, "--host", "0"));
    const int gate = atoi(opt(argc, argv, "--gate", "0"));
    const char *gatefit = opt(argc, argv, "--gatefit", NULL);
    const double fit_share = gatefit ? atof(gatefit) : 0.0;
    const char *gatebits = opt(argc, argv, "--gatebits", NULL);
    const int last_bits = gatebits ? atoi(gatebits) : 0;
    const char *gatescale = opt(argc, argv, "--gatescale", NULL);
    const int scale_images = gatescale ? atoi(gatescale) : 0;
    const char *gateref = opt(argc, argv, "--gateref", "sum");
    const int ref_codes = strcmp(gateref, "codes") == 0;
    const char *lightseed = opt(argc, argv, "--lightseed", NULL);
    const uint32_t level_seed = lightseed ? (uint32_t)strtoul(lightseed, NULL, 0) : seed;
    scale_report rep;
    int64_t fit_peak = 0;
    int fit_was = 0;
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
    memset(&rep, 0, sizeof rep);
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
    /* A line's noise as a laser fixes it, a correction told apart and the two
     * ways of putting a network on the tile are written for a network that is
     * all on it.  A light is the tile's layers' alone, whichever they are. */
    /* A network trained with its first layers the host's runs with those on the
     * host, and no others. */
    if (net->host && host != net->host) {
        fprintf(stderr, "pta_mnist: %s was trained with its first %d layer%s the host's, and runs "
                        "with --host %d\n", path, net->host, net->host == 1 ? "" : "s", net->host);
        return 2;
    }
    if (host < 0 || host > H || (host && (thermalline || hidshift || w1gain || levelpart)) ||
        (gate && !probing)) {
        fprintf(stderr, "pta_mnist: --host is how many of the network's first layers the host runs, "
                        "0 to %d, and is not modelled with --thermalline, --hidshift, --w1gain or "
                        "--levelpart; --gate needs --probe\n", H);
        return 2;
    }
    host_layers = host;
    /* A range is fitted to a reference that is known before any shot: every
     * layer but the last on the host. */
    if (gatefit && (!gate || host != H || fit_share <= 0.0 || fit_share > 1.0 ||
                    atoi(opt(argc, argv, "--adcbits", "0")) < 2)) {
        fprintf(stderr, "pta_mnist: --gatefit is the share of the last converter's full scale its "
                        "declared reference may take, over 0 and up to 1, and needs --gate, "
                        "--adcbits and --host %d\n", H);
        return 2;
    }
    /* A last converter of its own width is no narrower than the others, whose
     * step it keeps. */
    if (gatebits && (!gate || atoi(opt(argc, argv, "--adcbits", "0")) < 2 ||
                     last_bits < atoi(opt(argc, argv, "--adcbits", "0")) || last_bits > 15)) {
        fprintf(stderr, "pta_mnist: --gatebits is the bits of the last layer's converter, from "
                        "--adcbits' to 15, and needs --gate and --adcbits\n");
        return 2;
    }
    /* One scale on the last layer's outputs is fixed on images the network
     * was not trained on, which are not the test images. */
    if (gatescale && (!gate || scale_images < 1 || scale_images > N_ALL - N_TRAIN)) {
        fprintf(stderr, "pta_mnist: --gatescale is how many of the %d held-out training images fix "
                        "the last layer's output scale, and needs --gate\n", N_ALL - N_TRAIN);
        return 2;
    }
    /* The converter's codes are a reference where there is a converter, at a
     * step the run does not move and with the width the run declares. */
    if ((!ref_codes && strcmp(gateref, "sum") != 0) ||
        (ref_codes && (!gate || gatefit || gatebits || atoi(opt(argc, argv, "--adcbits", "0")) < 2))) {
        fprintf(stderr, "pta_mnist: --gateref is sum or codes; codes needs --gate and --adcbits, and "
                        "is not taken with --gatefit or --gatebits\n");
        return 2;
    }
    /* A light's levels from a seed of their own need a light. */
    if (lightseed && !lit) {
        fprintf(stderr, "pta_mnist: --lightseed is the seed of a light's line levels, and needs --src, "
                        "--srcline or --srcflat\n");
        return 2;
    }

    memset(cfg, 0, sizeof cfg);
    if (parse_impair(opt(argc, argv, "--impair", "quant"), &cfg[0].impair) != 0) {
        fprintf(stderr, "pta_mnist: --impair takes none or a list of quant,thermal,shot,prog,drift,xtalk\n");
        return 2;
    }
    if (ref_codes && !(cfg[0].impair & PTA_QUANT)) {
        fprintf(stderr, "pta_mnist: --gateref codes needs the tile's format, --impair quant\n");
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
    /* The layers a network was trained with as the host's are at its full width. */
    for (l = 0; l < net->host; ++l)
        cfg[l].w_bits = (uint32_t)net->din;
    /* The last layer's converter, where it has a width of its own: the step is
     * still the one adc_setup() gave the run's width, unless it is fitted. */
    if (gatebits)
        cfg[H].adc_bits = (uint32_t)last_bits;
    /* The last layer's range, fitted to its declared reference on the images
     * that are run: a board's golden manifest. */
    if (gatefit) {
        const int bits = (cfg[H].impair & PTA_QUANT) ? (int)cfg[H].act_bits : 0;
        int32_t *fq[MAX_L] = {NULL};
        for (l = 0; l <= H; ++l)
            if (!(fq[l] = (int32_t *)malloc((size_t)layer_size(H, l) * sizeof(int32_t))))
                return 2;
        quant_weights(hn, net->wbits, fq);
        for (base = 0; base < images; base += MAX_M) {
            const int M = (images - base < MAX_M) ? images - base : MAX_M;
            int64_t p;
            for (m = 0; m < M; ++m)
                for (k = 0; k < N_IN; ++k)
                    a1[m * N_IN + k] = pixel_operand(te.x[(size_t)(base + m) * N_IN + k], net->din);
            if ((p = declared_peak(hn, cfg, g, fq, bits, M, a1, bw)) < 0)
                return 2;
            if (p > fit_peak)
                fit_peak = p;
        }
        for (l = 0; l <= H; ++l)
            free(fq[l]);
        fit_was = S[H];
        if ((S[H] = fit_shift(fit_peak, (int)cfg[H].adc_bits, fit_share)) < 0) {
            fprintf(stderr, "pta_mnist: --gatefit leaves the converter no code\n");
            return 2;
        }
    }
    for (l = 0; l <= H; ++l)
        cfg[l].adc_shift = (uint32_t)S[l];
    /* The last layer's reference in its converter's codes, at the step it has. */
    if (ref_codes) {
        gate_codes = S[H];
        gate_lim   = (int64_t)1 << (cfg[H].adc_bits - 1);
    }

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
        /* A fitted converter's noise is in its own LSB: the 8-bit one's of the same range. */
        if (gatefit && (S8[H] = fit_shift(fit_peak, 8, fit_share)) < 0)
            return 2;
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
        pr.gate      = gate;
        pr.gate_bits = (cfg[H].impair & PTA_QUANT) ? (int)cfg[H].act_bits : 0;
        if (gatescale) {
            pr.gy = (double *)malloc((size_t)images * N_OUT * sizeof(double));
            pr.gf = (double *)malloc((size_t)images * N_OUT * sizeof(double));
            if (!pr.gy || !pr.gf)
                return 2;
        }
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
        (calibrate_bank(&dev, &cfg[0], &tile, 0, seed ^ PTA_CAL_SEED_XOR, &gemm, calibrate, g) != 0 ||
         calibrate_bank(&dev, &cfg[1], &tile, 1, seed ^ PTA_CAL_SEED_XOR, &gemm, calibrate, g) != 0)) {
        fprintf(stderr, "pta_mnist: the calibration could not run\n");
        return 2;
    }
    if ((cfg[0].impair & PTA_DRIFT) && post_steps)
        pta_drift_age(&dev, &cfg[0], post_steps);

    if (lit && light_setup_at(hn, cfg, seed, level_seed, src_all, src_line, src_flat, buses,
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
    for (l = host; l <= H; ++l)
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

    /* The range was fitted to the reference the probe then measured, where the
     * last layer is one tile's sum and the two are the same thing. */
    if (gatefit && N_HID <= tile_rows && pr.gpeak != (double)fit_peak) {
        fprintf(stderr, "pta_mnist: --gatefit fitted the range to a reference the probe did not measure\n");
        return 2;
    }
    /* The last layer's output scale, fixed at calibration: the held-out images,
     * after the test images and through the same tile, with its lines as they
     * were read and the light's shots their own. */
    if (gatescale && scale_fix(&pr, ht, hn, pq, pr.gate_bits, cfg, &tile, &dev, seed, &gemm, g, tr.x, N_TRAIN,
                               scale_images, bw, a1, &rep) != 0) {
        fprintf(stderr, "pta_mnist: pta_gemm refused a GEMM\n");
        return 2;
    }
    join_ints(s_txt, sizeof s_txt, S, H + 1);
    join_ints(sh_txt, sizeof sh_txt, hn->sh, H);
    printf("din=%d net_wbits=%d net_seed=%d from=%d epochs=%d digital=%.2f impair=0x%02x wbits=%u abits=%u "
           "adcbits=%u S=%s sh=%s thermal=%g photons=%g prog=%g xtalk=%g drift=%s hours=%g "
           "steps=%llu sigma_d=%u d_max=%u cal=%d trimstep=%g trimmax=%g post_hours=%g "
           "seed=%u images=%d correct=%d acc=%.2f sats=%ld elements=%ld",
           net->din, net->wbits, net->seed, net->from_bits, net->epochs, net->test_acc, cfg[0].impair, cfg[H].w_bits,
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
    /* And the layers the host ran, when it ran any. */
    if (host)
        printf(" host=%d", host);
    /* And the network's own, when it was trained with layers of the host's, and
     * the width the host ran those at. */
    if (net->host)
        printf(" net_host=%d host_wbits=%u", net->host, cfg[0].w_bits);
    /* And the light only when there is some. */
    if (lit)
        printf(" src=%g srcline=%g srcflat=%g buses=%d srcsign=%s", src_all, src_line, src_flat,
               buses, src_sign);
    /* And the levels' own seed, when they have one, with the rms of the levels
     * it drew: runs of one source show the same. */
    if (lightseed) {
        double l2 = 0.0;
        int li;
        for (li = 0; li < light.lines; ++li)
            l2 += light.level[li] * light.level[li];
        printf(" lightseed=%u light_levels=%.6f", level_seed, light.lines ? sqrt(l2 / light.lines) : 0.0);
    }
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
        /* And the gate's figures, when they were asked for: the last layer against
         * its declared format, and its largest values against the operands as given;
         * and how often that reference is right, and the tile gives its class. */
        if (gate)
            printf(" gate_bits=%d gate_rms=%.5f gate_rmsfs=%.5f gate_maxfs=%.5f gate_peak=%.0f "
                   "gate8_rmsfs=%.5f gate8_maxfs=%.5f gate8_peak=%.0f gate_ref=%.2f gate_agree=%.2f",
                   pr.gate_bits, pv.gate_rms, pv.gate_rmsfs, pv.gate_maxfs, pv.gate_peak, pv.gate8_rmsfs,
                   pv.gate8_maxfs, pv.gate8_peak, pv.gate_ref, pv.gate_agree);
        /* And, with the reference in the converter's codes, its step, the
         * largest error in codes, and the outputs a code off or more, two or
         * more, and so on. */
        if (gate_codes >= 0) {
            printf(" gate_codes=%d gate_maxcode=%.2f gate_tail=", gate_codes, ldexp(pr.gworst, -gate_codes));
            for (l = 0; l < GATE_TAIL; ++l)
                printf("%s%ld", l ? "," : "", pr.gtail[l]);
        }
        /* And the range, when it was fitted: the share asked, and the shift the
         * training images' rule had given the last layer. */
        if (gatefit)
            printf(" gate_fit=%g gate_was=%d", fit_share, fit_was);
        /* And the last converter's width, where it has one of its own. */
        if (gatebits)
            printf(" gate_adcbits=%d", last_bits);
        /* And the gate's figures with the last layer's outputs times the scale
         * fixed on the held-out images, and which images those were; and the
         * scale the test images would fit themselves, with the rms error it
         * leaves. */
        if (gatescale)
            printf(" gate_scale=%.5f gate_scale_images=%d gate_scale_first=%d gate_scale_rms=%.5f "
                   "gate_scale_rmsfs=%.5f gate_scale_maxfs=%.5f gate_scale_agree=%.2f gate_scale_best=%.5f "
                   "gate_scale_best_rms=%.5f",
                   rep.scale, rep.images, rep.first, rep.at_scale.rms, rep.at_scale.rmsfs, rep.at_scale.maxfs,
                   rep.at_scale.agree, rep.best, rep.at_best.rms);
        /* And the same two with the outputs times that scale. */
        if (gatescale && gate_codes >= 0) {
            printf(" gate_scale_maxcode=%.2f gate_scale_tail=", ldexp(rep.at_scale.worst, -gate_codes));
            for (l = 0; l < GATE_TAIL; ++l)
                printf("%s%ld", l ? "," : "", rep.at_scale.tail[l]);
        }
        probe_free(&pr);
        for (l = 0; l <= H; ++l)
            free(pq[l]);
    }
    printf("\n");
    gate_codes = -1;
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

/*
 * The seed derivation as grxcp's baseline states it
 * (docs/designs/pta_fotonix_baseline.md section 7, v0.3): splitmix64 seeded
 * with (base << 32) | index, whose high 32 bits are the issued command's
 * PTA_SEED.  A second implementation on purpose -- this is the normative
 * text, and check 3b below is that the harness agrees with it command by
 * command.  If this ever has to change, the map changed with it.
 */
static uint32_t normative_seed(uint32_t base, uint32_t index)
{
    uint64_t z = ((uint64_t)base << 32) | index;
    z += 0x9E3779B97F4A7C15ull;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return (uint32_t)((z ^ (z >> 31)) >> 32);
}

/* The derivation at commit b1a6e1b, at words no run reaches by accident.  A
 * change to either side of check 3b has to face these numbers, so a renumbered
 * sequence cannot pass as a rename. */
static const struct { uint32_t base, index, seed; } seed_pins[5] = {
    {7u,            0u,  0xBCDA4680u},
    {7u,            53u, 0x1D2F1B83u},
    {7u ^ 0xCA11Bu, 0u,  0xDE5D6D61u},
    {7u ^ 0xCA11Bu, 47u, 0xBA30AB33u},
    {12345u,        54u, 0xF3444374u},
};

/* Check 3b's transcript of what the issue path asked for, in order. */
#define SEED_TRACE_MAX 1024
static uint32_t seed_tr_base[SEED_TRACE_MAX];
static uint32_t seed_tr_index[SEED_TRACE_MAX];
static uint32_t seed_tr_seed[SEED_TRACE_MAX];
static int      seed_tr_n;
static int      seed_tr_over;

static void seed_record(uint32_t base, uint32_t index, uint32_t seed)
{
    if (seed_tr_n < SEED_TRACE_MAX) {
        seed_tr_base[seed_tr_n]  = base;
        seed_tr_index[seed_tr_n] = index;
        seed_tr_seed[seed_tr_n]  = seed;
    } else {
        seed_tr_over = 1;
    }
    ++seed_tr_n;
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

/* Whether a batch's sums in the layers the host runs are the ones kept: H
 * layers of M x N_HID, one after another. */
static int host_sums_same(const batch_ws *bw, const int64_t *kept, int H, int M)
{
    int l, same = 1;

    for (l = 0; l < H; ++l)
        same &= memcmp(kept + (size_t)l * M * N_HID, bw->y[l],
                       (size_t)M * N_HID * sizeof(int64_t)) == 0;
    return same;
}

/* How far a batch's last sums are from the ones kept: the sum of squares. */
static double sums_off(const int64_t *y, const int64_t *kept, int count)
{
    double off = 0.0;
    int i;

    for (i = 0; i < count; ++i)
        off += ((double)y[i] - (double)kept[i]) * ((double)y[i] - (double)kept[i]);
    return off;
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

    /* 3b. the issued tile commands' seed sequence.  The walk is check 3's --
     *     both banks calibrated, then two batches of images -- and every seed
     *     the tile is given is recorded in order and held to the derivation
     *     grxcp's baseline section 7 pins, at this run's own index.  What it
     *     pins is the harness's numbering, the C1 model's: the tile's
     *     calibration seeds are not these, they are the engine's, whose streams
     *     load from PTA_CAL_SEED ^ (j * 0x9E3779B1) (rtl/pta/c930_pta_cal.sv),
     *     and this model has no engine to imitate.  What the check catches is
     *     the numbering, not the arithmetic: an index that restarts, a
     *     calibration that stops taking indices, or a base that changes all
     *     leave the accuracy green and nothing but the numbers different. */
    for (di = 0; di < 2; ++di) {
        const int D = dins[di];
        const int H = 1;
        const pta_tile tile = {tile_rows, tile_cols, D, ACC_W};
        const uint32_t run_seed = 7;             /* as check 3's walk */
        const uint32_t cal_seed = run_seed ^ PTA_CAL_SEED_XOR;
        const int repeats  = 16;                 /* the calib gate's --calibrate 16 */
        const int nb       = 2;                  /* batches */
        const int M        = 37;
        const int per_cal  = 3 * repeats;         /* quantised, so PASSES is 3 */
        const int cal_cmds = 2 * per_cal;         /* both banks' probes, in one counter */
        host_net hn;
        gemm_buf *g = gemm_alloc();
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
        int32_t *a1 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t));
        pta_cfg cfg[MAX_L];
        pta_device dev;
        uint32_t gemm = 0;
        uint64_t rsv = 0x5EED5EED5EED1234ull;   /* this check's own: the later ones keep rs */
        int b, i, l, per_walk = 0, first = -1, bads = 0;

        for (l = 0; l <= H; ++l)
            per_walk += ((layer_out(H, l) + gemm_n - 1) / gemm_n)
                      * ((layer_in(l) + gemm_k - 1) / gemm_k);
        pta_device_init(&dev, &tile);
        host_alloc(&hn, D, H);
        for (l = 0; l <= H; ++l) {
            const int P = layer_size(H, l);
            for (i = 0; i < P; ++i)
                hn.w[l][i] = (int32_t)(splitmix64(&rsv) % (uint64_t)(1 << D)) - (1 << (D - 1));
        }
        for (l = 0; l < H; ++l)
            hn.sh[l] = D + 3 - l;
        memset(cfg, 0, sizeof cfg);
        cfg[0].impair    = PTA_QUANT;
        cfg[0].w_bits    = 3;
        cfg[0].act_bits  = (uint32_t)D - 3;
        cfg[0].adc_bits  = 7;
        cfg[0].trim_step = 64;
        cfg[0].trim_max  = 128;
        for (l = 1; l <= H; ++l)
            cfg[l] = cfg[0];
        for (i = 0; i < M * N_IN; ++i)
            a1[i] = (int32_t)(splitmix64(&rsv) % (uint64_t)(1 << (D - 1)));

        pta_model_reset(&dev, run_seed);
        seed_tr_n    = 0;
        seed_tr_over = 0;
        seed_observe = seed_record;
        for (b = 0; b < 2; ++b)
            bads += calibrate_bank(&dev, &cfg[b], &tile, b, cal_seed, &gemm, repeats, g) != 0;
        for (b = 0; b < nb; ++b)
            bads += tile_batch(&hn, cfg, &tile, &dev, run_seed, &gemm, g, M, a1, bw) < 0;
        seed_observe = NULL;

        for (i = 0; i < seed_tr_n && first < 0; ++i) {
            const uint32_t want_base = (i < cal_cmds) ? cal_seed : run_seed;
            if (seed_tr_base[i] != want_base || seed_tr_index[i] != (uint32_t)i ||
                seed_tr_seed[i] != normative_seed(seed_tr_base[i], seed_tr_index[i]))
                first = i;
        }
        for (i = 0; i < 5; ++i)
            bads += normative_seed(seed_pins[i].base, seed_pins[i].index) != seed_pins[i].seed ||
                    gemm_seed(seed_pins[i].base, seed_pins[i].index) != seed_pins[i].seed;
        /* two words of the transcript itself: the first calibration command, and
         * the first command of the first batch, `cal_cmds` indices later.
         * Between them they pin the calibration base and that calibration
         * consumed the GEMMs' counter, which is the one thing the map's own
         * GEMM count would not. */
        bads += seed_tr_n < cal_cmds + 1 || seed_tr_seed[0] != 0xDE5D6D61u ||
                seed_tr_seed[cal_cmds] != 0x76078299u;
        bads += seed_tr_over || seed_tr_n != cal_cmds + nb * per_walk;

        printf("selftest: D=%d issued %d tile commands, %d expected (2 x %d calibrated, "
               "%d x %d in %d batches), first divergence at %d, pinned words %s\n",
               D, seed_tr_n, cal_cmds + nb * per_walk, per_cal, nb, per_walk, nb, first,
               bads ? "DIFFER" : "match");
        if (bads)
            errors += fail("an issued tile command's seed is not the normative derivation "
                            "at its own index");
        pta_device_free(&dev);
        host_free(&hn);
        gemm_free(g);
        free(bw);
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

    /* 5b. layers the host runs.  A network's first layers on the host and the
     *     rest on the tile: a host layer's sums are the exact product of its
     *     operands as they were given and its weights as its quantiser has
     *     them, a tile layer's are what they always were, and only the tile's
     *     layers are launched.  And an impairment does not reach a layer the
     *     host runs. */
    {
        const int D = 8, H = 2, M = 37;
        const int32_t lo = -(1 << (D - 1)), span = 1 << D;
        const int64_t amax = ((int64_t)1 << (D - 1)) - 1;
        const pta_tile tile = {ROWS, COLS, D, ACC_W};
        host_net hn;
        gemm_buf *g = gemm_alloc();
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
        image_ws *ws = (image_ws *)malloc(sizeof *ws);
        int32_t *a1 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t)), *q[MAX_L];
        uint64_t r5 = 0x5B5B5Bull;              /* its own, so that the draws after it stay */
        pta_cfg cfg[MAX_L];
        uint32_t gemm;
        int host, pass, i, m, n, k, l, bad = 0, launched = 1, reached = 0, spared = 1;
        pta_device dev;
        pta_device_init(&dev, &tile);
        host_alloc(&hn, D, H);
        for (l = 0; l <= H; ++l) {
            const int P = layer_size(H, l);
            q[l] = (int32_t *)malloc((size_t)P * sizeof(int32_t));
            for (i = 0; i < P; ++i)
                hn.w[l][i] = lo + (int32_t)(splitmix64(&r5) % (uint64_t)span);
        }
        for (l = 0; l < H; ++l) {
            for (i = 0; i < N_HID; ++i)
                hn.b[l][i] = (int64_t)(splitmix64(&r5) % (1ull << (2 * D + 6))) - (1ll << (2 * D + 5));
            hn.sh[l] = D + 3 - l;
        }
        for (i = 0; i < M * N_IN; ++i)
            a1[i] = (int32_t)(splitmix64(&r5) % (uint64_t)(1 << (D - 1)));
        for (host = 0; host <= H; ++host)
            for (pass = 0; pass < 2; ++pass) {
                uint32_t want = 0;
                gemm = 0;
                memset(cfg, 0, sizeof cfg);
                if (pass == 1) {
                    cfg[0].impair   = PTA_QUANT;
                    cfg[0].w_bits   = 3;
                    cfg[0].act_bits = (uint32_t)D - 3;
                }
                for (l = 1; l <= H; ++l)
                    cfg[l] = cfg[0];
                host_layers = host;
                if (tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0)
                    ++bad;
                quant_weights(&hn, (int)cfg[0].w_bits, q);
                for (m = 0; m < M; ++m)
                    /* the network as it was asked for: a host layer takes its operands as they are */
                    for (l = 0; l <= H; ++l) {
                        const int in = layer_in(l), out = layer_out(H, l);
                        const int ab = l < host ? 0 : (int)cfg[0].act_bits;
                        const int32_t *src = l == 0 ? a1 + m * N_IN : ws->a[l];
                        for (n = 0; n < out; ++n) {
                            int64_t s = 0, v;
                            for (k = 0; k < in; ++k)
                                s += (int64_t)contract_quant(src[k], ab, D) * q[l][n * in + k];
                            ws->y[l][n] = s;
                            if (l < H) {
                                v = s + hn.b[l][n];
                                v = round_shift(v > 0 ? v : 0, hn.sh[l]);
                                ws->a[l + 1][n] = (int32_t)(v > amax ? amax : v);
                            }
                        }
                        bad += memcmp(ws->y[l], bw->y[l] + m * out, (size_t)out * sizeof(int64_t)) != 0;
                    }
                for (l = host; l <= H; ++l)
                    want += (uint32_t)(((layer_out(H, l) + gemm_n - 1) / gemm_n) *
                                       ((layer_in(l) + gemm_k - 1) / gemm_k));
                launched &= gemm == want;
            }
        /* a programming error of an LSB, with every layer but the last on the host */
        memset(cfg, 0, sizeof cfg);
        cfg[0].impair   = PTA_PROG_ERR;
        cfg[0].sigma_pr = 256;
        for (l = 1; l <= H; ++l)
            cfg[l] = cfg[0];
        host_layers = H;
        gemm        = 0;
        if (tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0)
            ++bad;
        quant_weights(&hn, 0, q);
        for (m = 0; m < M; ++m) {
            direct_image(&hn, q, 0, a1 + m * N_IN, ws);
            for (l = 0; l < H; ++l)
                spared &= memcmp(ws->y[l], bw->y[l] + m * N_HID, N_HID * sizeof(int64_t)) == 0;
            reached |= memcmp(ws->y[H], bw->y[H] + m * N_OUT, N_OUT * sizeof(int64_t)) != 0;
        }
        host_layers = 0;
        printf("selftest: layers the host runs: none, the first and the first two of three, with the "
               "quantisers and without, %d images each against the network as it was asked for: %d "
               "differ; only the tile's layers are launched: %s; a programming error on the tile reaches "
               "its own layer and no layer the host runs: %s\n", M, bad, launched ? "so" : "NOT SO",
               (reached && spared) ? "so" : "NOT SO");
        if (bad || !launched || !reached || !spared)
            errors += fail("a layer the host runs is not the exact product it should be");
        pta_device_free(&dev);
        host_free(&hn);
        for (l = 0; l <= H; ++l)
            free(q[l]);
        gemm_free(g);
        free(bw);
        free(ws);
        free(a1);
    }

    /* 5c. the gate's figures: the last layer against a reference in its
     *     engine's own declared format.  With nothing impaired there is no
     *     error and the two references are one.  With the quantisers on and
     *     no converter the tile is its declared format exactly, and is off
     *     the operands as they were given.  With a programming error on as
     *     well, the figures are the ones worked out here from the sums.  And
     *     the class: the tile's against its declared reference's, which with
     *     the quantisers on is every image, where the host's is not once the
     *     activations are coarse enough to part the two. */
    {
        const int D = 8, H = 2, M = 37, AB = 5, WB = 6, COARSE = 2;
        const int32_t lo = -(1 << (D - 1)), span = 1 << D;
        const pta_tile tile = {ROWS, COLS, D, ACC_W};
        host_net hn;
        gemm_buf *g = gemm_alloc();
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
        int32_t *a1 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t)), *q[MAX_L];
        uint8_t labels[MAX_M];
        uint64_t r5 = 0x5C5C5Cull;
        double shown[4] = {0.0, 0.0, 0.0, 0.0};
        int kind, i, m, o, k, l, ran = 1, clean = 1, exact = 1, same = 1, classes = 1, parted = 0, split = 0;
        pta_device dev;
        pta_device_init(&dev, &tile);
        host_alloc(&hn, D, H);
        for (l = 0; l <= H; ++l) {
            const int P = layer_size(H, l);
            q[l] = (int32_t *)malloc((size_t)P * sizeof(int32_t));
            for (i = 0; i < P; ++i)
                hn.w[l][i] = lo + (int32_t)(splitmix64(&r5) % (uint64_t)span);
        }
        for (l = 0; l < H; ++l) {
            for (i = 0; i < N_HID; ++i)
                hn.b[l][i] = (int64_t)(splitmix64(&r5) % (1ull << (2 * D + 6))) - (1ll << (2 * D + 5));
            hn.sh[l] = D + 3 - l;
        }
        for (i = 0; i < M * N_IN; ++i)
            a1[i] = (int32_t)(splitmix64(&r5) % (uint64_t)(1 << (D - 1)));
        /* an output bias that levels the outputs: each output's sum, a mean over the images, is
         * taken off it.  A class is then what an image's own sums make it, and is close run, so that
         * an error moves it; and labels of every class */
        {
            image_ws *ws = (image_ws *)malloc(sizeof *ws);
            int64_t mean[N_OUT] = {0};
            ran &= ws != NULL;
            quant_weights(&hn, 0, q);
            for (m = 0; ran && m < M; ++m) {
                direct_image(&hn, q, 0, a1 + m * N_IN, ws);
                for (o = 0; o < N_OUT; ++o)
                    mean[o] += ws->y[H][o];
            }
            for (o = 0; o < N_OUT; ++o)
                hn.b[H][o] = -(mean[o] / M);
            free(ws);
        }
        for (m = 0; m < M; ++m)
            labels[m] = (uint8_t)(splitmix64(&r5) % N_OUT);
        /* kinds: nothing impaired; the quantisers; a programming error of an LSB as well; the
         * quantisers with activations of 2 bits, which part the declared reference from the host;
         * and a programming error of 32 LSB, which parts the tile from its declared reference */
        for (kind = 0; ran && kind < 5; ++kind) {
            const int bits = kind == 0 ? 0 : (kind == 3 ? COARSE : AB);
            const int noisy = kind == 2 || kind == 4;
            const double count = (double)M * N_OUT;
            double ge = 0.0, gr = 0.0, gpeak = 0.0, gworst = 0.0, he = 0.0, hpeak = 0.0, hworst = 0.0;
            int gright = 0, gagree = 0, hagree = 0;
            pta_cfg cfg[MAX_L];
            uint32_t gemm = 0;
            probe p;
            probe_result pv;
            memset(cfg, 0, sizeof cfg);
            if (kind) {
                cfg[0].impair   = PTA_QUANT | (noisy ? PTA_PROG_ERR : 0);
                cfg[0].w_bits   = WB;
                cfg[0].act_bits = (uint32_t)bits;
                cfg[0].sigma_pr = kind == 4 ? 256 * 32 : 256;
            }
            for (l = 1; l <= H; ++l)
                cfg[l] = cfg[0];
            host_layers = H;
            ran &= probe_init(&p, M, H) == 0;
            p.gate      = 1;
            p.gate_bits = bits;
            ran &= ran && tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) >= 0;
            if (!ran)
                break;
            quant_weights(&hn, kind ? WB : 0, q);
            probe_batch(&p, &hn, q, M, a1, bw, labels);
            for (m = 0; m < M; ++m) {
                int64_t ft[N_OUT], lt[N_OUT], yt[N_OUT];
                int fb = 0, lb = 0, yb = 0;
                for (o = 0; o < N_OUT; ++o) {
                    const double y = (double)bw->y[H][m * N_OUT + o];
                    int64_t loc = 0, fmt = 0;
                    for (k = 0; k < N_HID; ++k) {
                        const int32_t av = bw->a[H][m * N_HID + k];
                        loc += (int64_t)av * q[H][o * N_HID + k];
                        fmt += (int64_t)contract_quant(av, bits, D) * q[H][o * N_HID + k];
                    }
                    ge += (y - (double)fmt) * (y - (double)fmt);
                    gr += (double)fmt * (double)fmt;
                    he += (y - (double)loc) * (y - (double)loc);
                    if (fabs((double)fmt) > gpeak)      gpeak = fabs((double)fmt);
                    if (fabs(y - (double)fmt) > gworst) gworst = fabs(y - (double)fmt);
                    if (fabs((double)loc) > hpeak)      hpeak = fabs((double)loc);
                    if (fabs(y - (double)loc) > hworst) hworst = fabs(y - (double)loc);
                    ft[o] = fmt + hn.b[H][o];
                    lt[o] = loc + hn.b[H][o];
                    yt[o] = bw->y[H][m * N_OUT + o] + hn.b[H][o];
                }
                for (o = 1; o < N_OUT; ++o) {
                    if (ft[o] > ft[fb]) fb = o;
                    if (lt[o] > lt[lb]) lb = o;
                    if (yt[o] > yt[yb]) yb = o;
                }
                gright += fb == labels[m];
                gagree += fb == yb;
                hagree += lb == yb;
                if (kind == 3)
                    split += fb != lb;
            }
            probe_finish(&p, labels, 7, &pv);
            /* the class: counted as it is here, the declared reference's and the host's apart */
            classes &= p.gright == gright && p.gagree == gagree && p.agree == hagree &&
                       fabs(pv.gate_ref - 100.0 * gright / M) < 1e-12 &&
                       fabs(pv.gate_agree - 100.0 * gagree / M) < 1e-12;
            if (!noisy)
                classes &= gagree == M;             /* the tile is its declared format, and gives its class */
            if (kind == 0)
                classes &= hagree == M && pv.gate_ref == pv.ref;
            if (kind == 3)
                classes &= hagree == M - split;     /* and not the host's, where those two part */
            if (kind == 4)
                parted = M - gagree;
            same &= p.ge == ge && p.gr == gr && p.gpeak == gpeak && p.gworst == gworst &&
                    p.hpeak == hpeak && p.hworst == hworst && gpeak > 0.0 && hpeak > 0.0;
            same &= fabs(pv.gate_rms - sqrt(ge / gr)) < 1e-12 && pv.gate_peak == gpeak &&
                    fabs(pv.gate_rmsfs - sqrt(ge / count) / gpeak) < 1e-12 &&
                    fabs(pv.gate_maxfs - gworst / gpeak) < 1e-12 && pv.gate8_peak == hpeak &&
                    fabs(pv.gate8_rmsfs - sqrt(he / count) / hpeak) < 1e-12 &&
                    fabs(pv.gate8_maxfs - hworst / hpeak) < 1e-12 &&
                    pv.gate_rmsfs <= pv.gate_maxfs && pv.gate8_rmsfs <= pv.gate8_maxfs;
            if (kind == 0)
                clean &= ge == 0.0 && he == 0.0 && gpeak == hpeak && pv.e[H] == 0.0;
            if (kind == 1 || kind == 3)
                exact &= ge == 0.0 && gworst == 0.0 && he > 0.0 && hworst > 0.0 && pv.e[H] > 0.0;
            if (noisy)
                exact &= ge > 0.0 && gworst > 0.0;
            if (kind == 2) {
                shown[0] = pv.gate_rms;
                shown[1] = pv.gate_rmsfs;
                shown[2] = pv.gate_maxfs;
                shown[3] = pv.e[H];
            }
            probe_free(&p);
        }
        host_layers = 0;
        printf("selftest: the gate's figures: nothing impaired is no error against either reference: %s; "
               "with the quantisers on the tile is its declared format exactly and is off the operands "
               "as given, and a programming error shows against both: %s; the figures are the ones "
               "worked out from the sums: %s (with that error, %.4f of the declared reference's rms, "
               "%.4f and at the most %.4f of its largest, and %.4f of the operands' as given); the class "
               "the tile gives against the class its declared reference gives, and that reference "
               "against the labels, counted as they are here: %s (with activations of 2 bits and no error "
               "the tile gives its declared reference's class on all %d images, where that reference and "
               "the host part on %d; with a programming error of 32 LSB the tile and its reference part "
               "on %d)\n",
               clean ? "so" : "NOT SO", exact ? "so" : "NOT SO", same ? "they are" : "THEY ARE NOT",
               shown[0], shown[1], shown[2], shown[3], classes ? "they are" : "THEY ARE NOT", M, split,
               parted);
        if (!ran || !clean || !exact || !same || !classes || split == 0 || parted == 0)
            errors += fail("the gate's figures are not the last layer against its declared format");
        pta_device_free(&dev);
        host_free(&hn);
        for (l = 0; l <= H; ++l)
            free(q[l]);
        gemm_free(g);
        free(bw);
        free(a1);
    }

    /* 5d. pool.  Two made-up images of 28 x 28: pooled to 8 x 8, each pixel
     *     is the mean of its block of nine in the middle 24 x 24, to the
     *     nearest, and the margin does not count; to 14 x 14 it is a mean of
     *     four; to 28 x 28 it is the file it was.  A side whose blocks do not
     *     sit in the middle, a file that is not 28 x 28 images and a file a
     *     byte short are refused. */
    {
        enum { IMGS = 2, PIX = 28 * 28 };
        uint8_t src[16 + IMGS * PIX], out[16 + IMGS * PIX], bad_in[16 + IMGS * PIX];
        uint64_t r5 = 0x5D5D5Dull;
        long got8, got14, got28;
        int i, n, r, c, dr, dc, ok = 1, refused;
        memset(src, 0, 16);
        src[2] = 8; src[3] = 3; src[7] = IMGS; src[11] = 28; src[15] = 28;
        for (i = 0; i < IMGS * PIX; ++i)
            src[16 + i] = (uint8_t)(splitmix64(&r5) & 0xFF);
        got8 = pool_idx(src, (long)sizeof src, 8, out);
        ok &= got8 == 16 + IMGS * 64 && be32(out) == 2051 && be32(out + 4) == IMGS &&
              be32(out + 8) == 8 && be32(out + 12) == 8;
        for (n = 0; ok && n < IMGS; ++n)
            for (r = 0; r < 8; ++r)
                for (c = 0; c < 8; ++c) {
                    int s = 0;
                    for (dr = 0; dr < 3; ++dr)
                        for (dc = 0; dc < 3; ++dc)
                            s += src[16 + n * PIX + (2 + 3 * r + dr) * 28 + 2 + 3 * c + dc];
                    ok &= out[16 + n * 64 + r * 8 + c] == (uint8_t)((2 * s + 9) / 18);
                }
        /* the margin does not count: light it, and the pooled file is the same */
        memcpy(bad_in, src, sizeof src);
        for (n = 0; n < IMGS; ++n)
            for (r = 0; r < 28; ++r)
                for (c = 0; c < 28; ++c)
                    if (r < 2 || r >= 26 || c < 2 || c >= 26)
                        bad_in[16 + n * PIX + r * 28 + c] ^= 0xFF;
        {
            uint8_t again[16 + IMGS * 64];
            ok &= pool_idx(bad_in, (long)sizeof bad_in, 8, again) == got8 &&
                  memcmp(again, out, (size_t)got8) == 0;
        }
        got14 = pool_idx(src, (long)sizeof src, 14, out);
        ok &= got14 == 16 + IMGS * 196 && be32(out + 8) == 14 &&
              out[16] == (uint8_t)((2 * (src[16] + src[17] + src[16 + 28] + src[16 + 29]) + 4) / 8);
        got28 = pool_idx(src, (long)sizeof src, 28, out);
        ok &= got28 == (long)sizeof src && memcmp(out, src, sizeof src) == 0;
        refused = pool_idx(src, (long)sizeof src, 9, out) < 0 && pool_idx(src, (long)sizeof src, 5, out) < 0 &&
                  pool_idx(src, (long)sizeof src, 0, out) < 0 && pool_idx(src, (long)sizeof src, 29, out) < 0 &&
                  pool_idx(src, (long)sizeof src - 1, 8, out) < 0;
        memcpy(bad_in, src, sizeof src);
        bad_in[15] = 27;                            /* 28 x 27: not ours */
        refused &= pool_idx(bad_in, (long)sizeof bad_in, 8, out) < 0;
        printf("selftest: pool: %d images of 28 x 28 to 8 x 8, each pixel the mean of its nine in the "
               "middle 24 x 24 and the margin not counted, to 14 x 14 a mean of four, and to 28 x 28 "
               "the file it was: %s; sides of 9, 5, 0 and 29, 28 x 27 images and a file a byte short: "
               "%s\n", IMGS, ok ? "as it should be" : "WRONG", refused ? "refused" : "TAKEN");
        if (!ok || !refused)
            errors += fail("pool does not pool an idx file's images");
    }

    /* 5e. a range fitted to the gate.  A three-layer network of made-up
     *     weights on the 128 x 64 tile, which takes its last layer whole, with
     *     the first two layers on the host.  The largest its declared
     *     reference is, is the probe's, all at once or a batch at a time, and
     *     nothing is launched to find it.  The fitted shift is the smallest
     *     at which that largest is within full scale, and at half of full
     *     scale within half.  With the format alone and the fitted range no
     *     sum is past the converter and none is off its reference by more
     *     than half a step; two steps under it some are, and by more than a
     *     step.  And a share that leaves the converter no code is refused. */
    {
        const int D = 8, H = 2, M = 37, AB = 5, WB = 6, BITS = 8;
        const int32_t lo = -(1 << (D - 1)), span = 1 << D;
        const int64_t top = ((int64_t)1 << (BITS - 1)) - 1;
        const pta_tile tile = {128, 64, D, ACC_W};
        host_net hn;
        gemm_buf *g;
        batch_ws *bw = (batch_ws *)malloc(sizeof *bw);
        int32_t *a1 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t)), *q[MAX_L];
        uint8_t labels[MAX_M];
        uint64_t r5 = 0x5E5E5Eull;
        pta_cfg cfg[MAX_L];
        int64_t peak, first, rest;
        long sats_fit = -1, sats_under = -1;
        double worst_fit = -1.0, worst_under = -1.0, probed = -1.0;
        int i, l, s_fit, s_half, pass, found, fitted, format, refused;
        pta_device dev;
        tile_rows = tile.rows;
        tile_cols = tile.cols;
        gemm_k = tile_rows * ((N_IN + tile_rows - 1) / tile_rows);
        gemm_n = tile_cols * ((N_HID + tile_cols - 1) / tile_cols);
        g = gemm_alloc();
        pta_device_init(&dev, &tile);
        host_alloc(&hn, D, H);
        memset(labels, 0, sizeof labels);
        for (l = 0; l <= H; ++l) {
            const int P = layer_size(H, l);
            q[l] = (int32_t *)malloc((size_t)P * sizeof(int32_t));
            for (i = 0; i < P; ++i)
                hn.w[l][i] = lo + (int32_t)(splitmix64(&r5) % (uint64_t)span);
        }
        for (l = 0; l < H; ++l) {
            for (i = 0; i < N_HID; ++i)
                hn.b[l][i] = (int64_t)(splitmix64(&r5) % (1ull << (2 * D + 6))) - (1ll << (2 * D + 5));
            hn.sh[l] = D + 3 - l;
        }
        for (i = 0; i < M * N_IN; ++i)
            a1[i] = (int32_t)(splitmix64(&r5) % (uint64_t)(1 << (D - 1)));
        memset(cfg, 0, sizeof cfg);
        cfg[0].impair   = PTA_QUANT;
        cfg[0].w_bits   = WB;
        cfg[0].act_bits = AB;
        cfg[0].adc_bits = BITS;
        for (l = 1; l <= H; ++l)
            cfg[l] = cfg[0];
        quant_weights(&hn, WB, q);
        host_layers = H;
        peak  = declared_peak(&hn, cfg, g, q, AB, M, a1, bw);
        first = declared_peak(&hn, cfg, g, q, AB, 20, a1, bw);
        rest  = declared_peak(&hn, cfg, g, q, AB, M - 20, a1 + 20 * N_IN, bw);
        found = host_layers == H && peak > 0 && first > 0 && rest > 0 && first <= peak && rest <= peak &&
                (first == peak || rest == peak);
        s_fit  = fit_shift(peak, BITS, 1.0);
        s_half = fit_shift(peak, BITS, 0.5);
        fitted = s_fit >= 2 && round_shift(peak, s_fit) <= top && round_shift(peak, s_fit - 1) > top &&
                 s_half > s_fit && round_shift(peak, s_half) <= top / 2 &&
                 round_shift(peak, s_half - 1) > top / 2 && fit_shift(0, BITS, 1.0) == 0;
        /* the format alone: at the fitted range, and two steps under it */
        for (pass = 0; fitted && pass < 2; ++pass) {
            uint32_t gemm = 0;
            probe p;
            long r;
            for (l = 0; l <= H; ++l)
                cfg[l].adc_shift = (uint32_t)(s_fit - 2 * pass);
            if (probe_init(&p, M, H) != 0)
                break;
            p.gate      = 1;
            p.gate_bits = AB;
            host_layers = H;
            r = tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw);
            probe_batch(&p, &hn, q, M, a1, bw, labels);
            if (pass == 0) {
                sats_fit  = r;
                worst_fit = p.gworst;
                probed    = p.gpeak;
            } else {
                sats_under  = r;
                worst_under = p.gworst;
            }
            probe_free(&p);
        }
        host_layers = 0;
        format = fitted && sats_fit == 0 && probed == (double)peak && worst_fit <= ldexp(1.0, s_fit - 1) &&
                 sats_under > 0 && worst_under > ldexp(1.0, s_fit - 2);
        refused = fit_shift(peak, BITS, 0.001) < 0 && fit_shift(peak, 1, 1.0) < 0 && fit_shift(-1, BITS, 1.0) < 0;
        printf("selftest: a range fitted to the gate: the largest the declared reference is over %d "
               "images, all at once or a batch at a time, with nothing launched: %s; the fitted shift, "
               "%d, is the smallest at which it is within full scale, and %d within half of it: %s; with "
               "the format alone no sum is past the fitted range, the probe's largest reference is the "
               "one it was fitted to, and none is off it by more than half a step, where two steps "
               "under it %ld sums are past the range and one is off by %.1f of that step: %s; a share "
               "that leaves no code, a converter of one bit and a peak under zero: %s\n",
               M, found ? "found" : "NOT FOUND", s_fit, s_half, fitted ? "so" : "NOT SO", sats_under,
               s_fit >= 2 ? worst_under / ldexp(1.0, s_fit - 2) : 0.0, format ? "so" : "NOT SO",
               refused ? "refused" : "TAKEN");
        if (!found || !fitted || !format || !refused)
            errors += fail("a range fitted to the gate is not the smallest that holds its reference");
        /* 5f. a converter with a bit more.  The same network and the format
         *     alone.  At the fitted step a 9-bit converter gives the sums the
         *     8-bit one does, every one.  One step under it the 8-bit one has
         *     sums past its range and the 9-bit one has none, and none off
         *     its reference by more than half of that step: a bit more at
         *     the same step is twice the range.  And no more than twice:
         *     fitted for itself, a 9-bit converter's shift is the smallest
         *     at which the reference is within 255 codes, which is under the
         *     8-bit one's, as a reference of 255 fits a step of one and one
         *     of 256 does not; and a step under that it has sums past its
         *     range, which are held at 255 of that step, or at 256 under
         *     nought, and nowhere else.  They are counted one for one: a
         *     10-bit converter at that step has none, and gives another sum
         *     for each of them and for no other. */
        {
            const int s9 = fit_shift(peak, BITS + 1, 1.0);
            const int ruled = s9 >= 1 && s9 < s_fit && round_shift(peak, s9) <= 2 * top + 1 &&
                              round_shift(peak, s9 - 1) > 2 * top + 1 &&
                              fit_shift(2 * top + 1, BITS + 1, 1.0) == 0 &&
                              fit_shift(2 * top + 2, BITS + 1, 1.0) == 1 &&
                              fit_shift(top, BITS, 1.0) == 0 && fit_shift(top + 1, BITS, 1.0) == 1;
            int64_t *kept = (int64_t *)malloc((size_t)2 * M * N_OUT * sizeof(int64_t));
            int64_t *held = kept ? kept + M * N_OUT : NULL;
            int64_t hi = 0, lo = 0;
            long sats8 = -1, sats9 = -1, sats_same = -1, sats_past = -1, sats_wide = -1, other = 0;
            double worst9 = -1.0;
            int same = 0, wider = 0, railed = 0;
            for (pass = 0; fitted && ruled && kept && pass < 6; ++pass) {
                /* 8 bits and then 9 at the fitted step; 8 and then 9 a step
                 * under it; and 9 and then 10 a step under the 9's own */
                const int bits = (pass == 0 || pass == 2) ? BITS : pass == 5 ? BITS + 2 : BITS + 1;
                const int at = pass < 2 ? s_fit : pass < 4 ? s_fit - 1 : s9 - 1;
                uint32_t gemm = 0;
                probe p;
                long r;
                for (l = 0; l <= H; ++l) {
                    cfg[l].adc_bits  = (uint32_t)bits;
                    cfg[l].adc_shift = (uint32_t)at;
                }
                if (probe_init(&p, M, H) != 0)
                    break;
                p.gate      = 1;
                p.gate_bits = AB;
                host_layers = H;
                r = tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw);
                probe_batch(&p, &hn, q, M, a1, bw, labels);
                if (pass == 0)
                    memcpy(kept, bw->y[H], (size_t)M * N_OUT * sizeof(int64_t));
                if (pass == 1) {
                    sats_same = r;
                    same = memcmp(kept, bw->y[H], (size_t)M * N_OUT * sizeof(int64_t)) == 0;
                }
                if (pass == 2)
                    sats8 = r;
                if (pass == 3) {
                    sats9  = r;
                    worst9 = p.gworst;
                }
                if (pass == 5) {
                    sats_wide = r;
                    for (i = 0; i < M * N_OUT; ++i)
                        other += held[i] != bw->y[H][i];
                }
                if (pass == 4) {
                    sats_past = r;
                    memcpy(held, bw->y[H], (size_t)M * N_OUT * sizeof(int64_t));
                    for (i = 0; i < M * N_OUT; ++i) {
                        if (bw->y[H][i] > hi)
                            hi = bw->y[H][i];
                        if (bw->y[H][i] < lo)
                            lo = bw->y[H][i];
                    }
                }
                probe_free(&p);
            }
            host_layers = 0;
            if (ruled) {
                const int64_t up = (2 * top + 1) * ((int64_t)1 << (s9 - 1));
                const int64_t down = -(2 * top + 2) * ((int64_t)1 << (s9 - 1));
                railed = hi <= up && lo >= down && (hi == up || lo == down);
            }
            wider = fitted && ruled && same && sats_same == 0 && sats8 > 0 && sats9 == 0 &&
                    worst9 >= 0.0 && worst9 <= ldexp(1.0, s_fit - 2) && sats_past > 0 && railed &&
                    sats_wide == 0 && other == sats_past;
            printf("selftest: a converter with a bit more: at the fitted step a 9-bit converter gives "
                   "the 8-bit one's sums, all %d: %s; a step under it the 8-bit one has %ld sums past "
                   "its range and the 9-bit one %ld, and none off by more than half of that step; and "
                   "fitted for itself its shift is %d where the 8-bit one's is %d, the smallest at "
                   "which the reference is within 255 codes, and a step under that %ld of its sums "
                   "are past its range and held at its last code, the ones a 10-bit converter "
                   "gives otherwise: %s\n",
                   M * N_OUT, same ? "so" : "NOT SO", sats8, sats9, s9, s_fit, sats_past,
                   wider ? "so" : "NOT SO");
            if (!wider)
                errors += fail("a converter with a bit more is not twice the range at the same step");
            free(kept);
        }
        /* 5g. a light on a tile that has the last layer alone.  The same
         *     network and the format alone, at the fitted step, with the
         *     first two layers on the host.  Lit, the layers the host runs
         *     are the sums they were: a source lights the tile.  With lines
         *     that are not level and no noise, each of the last layer's sums
         *     gains its rows' lines' levels times what each row carries,
         *     worked out here from the lines.  With noise on the source the
         *     host's layers are still what they were, and the last layer's
         *     sums move.  And a correction for the lines, on the weights at
         *     8 bits, on them with every row brought down to the dimmest
         *     line's, or on the inputs, touches nothing of the host's: its
         *     layers' weights and widths and sums are what they were, the
         *     last layer's weights are written at the operand's width, and
         *     its corrected sums are nearer the unlit ones than the
         *     uncorrected were. */
        {
            enum { WAYS = 3 };
            static const int how[WAYS] = {FIX_WEIGHTS8, FIX_WEIGHTS8, FIX_INPUTS};
            static const int dimmest[WAYS] = {0, 1, 0};
            const int outs = M * N_OUT, hid = M * N_HID;
            int64_t *kept = (int64_t *)malloc(((size_t)H * hid + outs) * sizeof(int64_t));
            int64_t *dark = kept ? kept + (size_t)H * hid : NULL;
            double found = 0.0, left = 0.0, off_lit = 0.0, nearer[WAYS] = {0.0, 0.0, 0.0};
            int spared = 1, gained = 1, moved = 0, noisy = 0, mended = 1, way, m, o, k;
            uint32_t gemm = 0;

            for (l = 0; l <= H; ++l) {
                cfg[l].adc_bits  = BITS;
                cfg[l].adc_shift = (uint32_t)s_fit;
            }
            host_layers = H;
            if (!fitted || !kept || tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0)
                spared = 0;
            for (l = 0; spared && l < H; ++l)
                memcpy(kept + (size_t)l * hid, bw->y[l], (size_t)hid * sizeof(int64_t));
            if (spared)
                memcpy(dark, bw->y[H], (size_t)outs * sizeof(int64_t));
            /* lines that are not level, and no noise */
            if (spared && light_setup(&hn, cfg, 7, 0.0, 0.0, 0.2, 2, 0) == 0 &&
                tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) >= 0) {
                spared &= host_sums_same(bw, kept, H, M);
                for (m = 0; m < M; ++m)
                    for (o = 0; o < N_OUT; ++o) {
                        double d = 0.0;
                        for (k = 0; k < N_HID; ++k)
                            d += (contract_quant(bw->a[H][m * N_HID + k], AB, D) *
                                  light.level[(k % tile_rows) % light.lines]) *
                                 (light.wq[H][o * N_HID + k] + 0.0);
                        gained &= bw->y[H][m * N_OUT + o] == dark[m * N_OUT + o] + (int64_t)floor(d + 0.5);
                        moved |= bw->y[H][m * N_OUT + o] != dark[m * N_OUT + o];
                    }
                off_lit = sums_off(bw->y[H], dark, outs);
            } else {
                spared = 0;
            }
            /* noise on the source, the lines together and each on its own */
            if (spared && light_setup(&hn, cfg, 7, 0.01, 0.05, 0.0, 2, 0) == 0 &&
                tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) >= 0) {
                spared &= host_sums_same(bw, kept, H, M);
                noisy = memcmp(bw->y[H], dark, (size_t)outs * sizeof(int64_t)) != 0;
            } else {
                spared = 0;
            }
            /* and the lines read and corrected, three ways */
            for (way = 0; spared && way < WAYS; ++way) {
                host_net hf;
                const host_net *ht = NULL;
                memset(&hf, 0, sizeof hf);
                if (light_setup(&hn, cfg, 7, 0.0, 0.0, 0.2, 2, 0) != 0) {
                    mended = 0;
                    break;
                }
                light.keep = 1;
                if (level_probe(&dev, &cfg[0], &tile, 7, 16, g, &found, &left) == 0)
                    ht = level_apply(&hf, &hn, cfg, how[way], dimmest[way]);
                if (!ht || tile_batch(ht, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0) {
                    mended = 0;
                } else {
                    const double off = sums_off(bw->y[H], dark, outs);
                    spared &= host_sums_same(bw, kept, H, M);
                    nearer[way] = off > 0.0 ? sqrt(off_lit / off) : 0.0;
                    mended &= nearer[way] > 1.0 && (dimmest[way] ? light.gain < 1.0 : light.gain == 1.0);
                    for (l = 0; l < H; ++l)
                        mended &= cfg[l].w_bits == (uint32_t)WB &&
                                  memcmp(ht->w[l], hn.w[l], (size_t)layer_size(H, l) * sizeof(int32_t)) == 0;
                    mended &= cfg[H].w_bits == (uint32_t)(how[way] == FIX_WEIGHTS8 ? D : WB);
                }
                if (ht && ht != &hn)
                    host_free(&hf);
                for (l = 0; l <= H; ++l)
                    cfg[l].w_bits = WB;
            }
            light_free();
            host_layers = 0;
            printf("selftest: a light on a tile that has the last layer alone: lit, the layers the "
                   "host runs are the sums they were: %s; with lines %.3f rms off and no noise each of "
                   "the last layer's %d sums gains its rows' lines' levels times what each row carries: "
                   "%s; with noise on the source they move: %s; and the lines read and corrected on the "
                   "weights at 8 bits, on them to the dimmest line and on the inputs leave the host's "
                   "weights and widths alone and the last layer's sums %.1f, %.1f and %.1f times "
                   "nearer the unlit ones: %s\n",
                   spared ? "so" : "NOT SO", found, outs, gained && moved ? "so" : "NOT SO",
                   noisy ? "so" : "NOT SO", nearer[0], nearer[1], nearer[2], mended ? "so" : "NOT SO");
            if (!spared || !gained || !moved || !noisy || !mended)
                errors += fail("a light on a tile with layers on the host is not the tile's layers' alone");
            free(kept);
        }
        /* 5h. one scale on the last layer's outputs.  The same network at the
         *     fitted step, the first two layers on the host, and as many other
         *     made-up images to fix the scale on.  At a scale of one the gate's
         *     figures are the probe's own, to the bit.  The scale fixed on the
         *     other images is the one the probe would fit on them, to the bit.
         *     With the format alone it is within a hundredth of one, and with
         *     2% of crosstalk it is lower: crosstalk swells a sum whose inputs
         *     are none below nought.  There the outputs times it are nearer
         *     their reference than the outputs are.  The scale the images fit
         *     themselves leaves no more than one does, than the fixed one does,
         *     or than a hundredth either side of it.  The last layer is given
         *     biases here, which a class is taken with: the last output's is
         *     four times full scale and the rest are nought, so that every
         *     image's class is the last.  Times two the outputs are as far off
         *     as their reference is large, in rms and at the largest, to two
         *     hundredths, and give the class worked out here; times nought they
         *     are as far off as their reference is large, exactly, and give
         *     every image the biases' class.  What eval reports, on made-up
         *     pixels from the seventh image on, is that scale done by hand on
         *     the same images, to the bit, with its last batch's shots
         *     numbered from N_TEST on; the images and the first of them it was
         *     given; the best scale of the images the probe kept; and the
         *     gate's figures with each of the two, figure for figure. */
        {
            int32_t *a2 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t));
            double fixed[2] = {0.0, 0.0}, at_one[2] = {0.0, 0.0}, at_fixed[2] = {0.0, 0.0};
            int run = a2 != NULL && fitted, one = 1, same = 1, least = 1, twice = 1, calibrated = 0, lower, pass2;
            int bias_best = 0;
            uint32_t gemm = 0;
            for (i = 0; a2 && i < M * N_IN; ++i)
                a2[i] = (int32_t)(splitmix64(&r5) % (uint64_t)(1 << (D - 1)));
            for (i = 0; i < N_OUT; ++i)
                hn.b[H][i] = 0;
            hn.b[H][N_OUT - 1] = ((int64_t)4 * 127) << s_fit;     /* four times full scale */
            bias_best = N_OUT - 1;
            for (pass2 = 0; run && pass2 < 2; ++pass2) {
                probe p, pc;
                scale_result r1, rf, rb, rx, r2;
                double yf = 0.0, yy = 0.0, best;
                for (l = 0; l <= H; ++l) {
                    cfg[l].impair    = PTA_QUANT | (pass2 ? PTA_XTALK : 0u);
                    cfg[l].xtalk     = pass2 ? 5u : 0u;
                    cfg[l].w_bits    = WB;
                    cfg[l].adc_bits  = BITS;
                    cfg[l].adc_shift = (uint32_t)s_fit;
                }
                host_layers = H;
                if (probe_init(&p, M, H) != 0 || probe_init(&pc, M, H) != 0) {
                    run = 0;
                    break;
                }
                p.gate = pc.gate = 1;
                p.gate_bits = pc.gate_bits = AB;
                p.gy  = (double *)malloc((size_t)M * N_OUT * sizeof(double));
                p.gf  = (double *)malloc((size_t)M * N_OUT * sizeof(double));
                pc.gy = (double *)malloc((size_t)M * N_OUT * sizeof(double));
                pc.gf = (double *)malloc((size_t)M * N_OUT * sizeof(double));
                if (!p.gy || !p.gf || !pc.gy || !pc.gf ||
                    tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0) {
                    run = 0;
                } else {
                    probe_batch(&p, &hn, q, M, a1, bw, labels);
                    if (tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a2, bw) < 0) {
                        run = 0;
                    } else {
                        scale_sums(&hn, q, AB, M, bw, &yf, &yy);
                        probe_batch(&pc, &hn, q, M, a2, bw, labels);
                        fixed[pass2] = yy > 0.0 ? yf / yy : 0.0;
                        same &= fixed[pass2] == scale_best(&pc);
                        best = scale_best(&p);
                        scale_gate(&p, &hn, 1.0, &r1);
                        scale_gate(&p, &hn, fixed[pass2], &rf);
                        scale_gate(&p, &hn, best, &rb);
                        one &= r1.rms == sqrt(p.ge / p.gr) && r1.rmsfs == sqrt(p.ge / (M * N_OUT)) / p.gpeak &&
                               r1.maxfs == p.gworst / p.gpeak && r1.agree == 100.0 * p.gagree / M;
                        at_one[pass2]   = r1.rms;
                        at_fixed[pass2] = rf.rms;
                        least &= rb.rms <= r1.rms && rb.rms <= rf.rms;
                        scale_gate(&p, &hn, best * 0.99, &rx);
                        least &= rb.rms <= rx.rms;
                        scale_gate(&p, &hn, best * 1.01, &rx);
                        least &= rb.rms <= rx.rms;
                        if (pass2 == 0) {
                            int m0, o0, theirs = 0, doubled = 0;
                            twice = 1;
                            /* times two and times nought: the class worked out here, and the
                             * biases' own; and the reference's own size */
                            for (m0 = 0; m0 < M; ++m0) {
                                const double *f = p.gf + (size_t)m0 * N_OUT, *y = p.gy + (size_t)m0 * N_OUT;
                                int fb = 0, yb = 0;
                                for (o0 = 0; o0 < N_OUT; ++o0) {
                                    if (f[o0] + (double)hn.b[H][o0] > f[fb] + (double)hn.b[H][fb])
                                        fb = o0;
                                    if (2.0 * y[o0] + (double)hn.b[H][o0] > 2.0 * y[yb] + (double)hn.b[H][yb])
                                        yb = o0;
                                }
                                theirs  += fb == bias_best;
                                doubled += fb == yb;
                            }
                            scale_gate(&p, &hn, 2.0, &r2);
                            twice &= fabs(r2.rms - 1.0) < 0.02 && fabs(r2.maxfs - 1.0) < 0.02 &&
                                     r2.agree == 100.0 * doubled / M && theirs == M;
                            scale_gate(&p, &hn, 0.0, &r2);
                            twice &= r2.rms == 1.0 && r2.maxfs == 1.0 && r2.agree == 100.0 * theirs / M;
                        }
                    }
                }
                probe_free(&p);
                probe_free(&pc);
            }
            for (l = 0; l <= H; ++l) {
                cfg[l].impair = PTA_QUANT;
                cfg[l].xtalk  = 0u;
            }
            host_layers = 0;
            /* what eval reports: the format alone, which draws nothing */
            {
                uint8_t *px = (uint8_t *)malloc((size_t)(M + 7) * N_IN);
                int32_t *a3 = (int32_t *)malloc(MAX_M * N_IN * sizeof(int32_t));
                double yf = 0.0, yy = 0.0;
                probe pp;
                scale_report rep;
                scale_result ra, rb;
                const int base_was = light.base;    /* the tests after this one number their shots from it */
                uint32_t gemm = 0;
                for (l = 0; l <= H; ++l)
                    cfg[l].adc_shift = (uint32_t)s_fit;
                host_layers = H;
                for (i = 0; px && i < (M + 7) * N_IN; ++i)
                    px[i] = (uint8_t)(splitmix64(&r5) & 0xFF);
                memset(&pp, 0, sizeof pp);
                if (!px || !a3 || probe_init(&pp, M, H) != 0 ||
                    !(pp.gy = (double *)malloc((size_t)M * N_OUT * sizeof(double))) ||
                    !(pp.gf = (double *)malloc((size_t)M * N_OUT * sizeof(double))) ||
                    tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a1, bw) < 0) {
                    run = 0;
                } else {
                    pp.gate      = 1;
                    pp.gate_bits = AB;
                    probe_batch(&pp, &hn, q, M, a1, bw, labels);
                    if (scale_fix(&pp, &hn, &hn, q, AB, cfg, &tile, &dev, 7, &gemm, g, px, 7, M, bw, a3, &rep) != 0) {
                        run = 0;
                    } else {
                        calibrated = light.base == N_TEST && rep.images == M && rep.first == 7 &&
                                     rep.best == scale_best(&pp);
                        for (i = 0; i < M * N_IN; ++i)
                            a3[i] = pixel_operand(px[(size_t)7 * N_IN + i], D);
                        if (tile_batch(&hn, cfg, &tile, &dev, 7, &gemm, g, M, a3, bw) < 0)
                            run = 0;
                        else
                            scale_sums(&hn, q, AB, M, bw, &yf, &yy);
                        scale_gate(&pp, &hn, rep.scale, &ra);
                        scale_gate(&pp, &hn, rep.best, &rb);
                        calibrated &= yy > 0.0 && rep.scale == yf / yy &&
                                      ra.rms == rep.at_scale.rms && ra.rmsfs == rep.at_scale.rmsfs &&
                                      ra.maxfs == rep.at_scale.maxfs && ra.agree == rep.at_scale.agree &&
                                      rb.rms == rep.at_best.rms && rb.rmsfs == rep.at_best.rmsfs &&
                                      rb.maxfs == rep.at_best.maxfs && rb.agree == rep.at_best.agree &&
                                      ra.rms != rb.rms;
                    }
                }
                probe_free(&pp);
                light.base  = base_was;
                host_layers = 0;
                free(px);
                free(a3);
            }
            lower = run && fabs(fixed[0] - 1.0) < 0.01 && fixed[1] < fixed[0] && at_fixed[1] < at_one[1];
            one &= run;
            printf("selftest: one scale on the last layer's outputs: at a scale of one the gate's figures "
                   "are the probe's own: %s; the scale fixed on %d other images is the one the probe fits "
                   "on them: %s; with the format alone it is %.4f, and with 2%% of crosstalk %.4f, where "
                   "the outputs times it are %.2f%% of their reference's rms off and the outputs %.2f%%: %s; "
                   "the scale the images fit themselves leaves the least: %s; and outputs times two, or "
                   "times nought, are as far off as their reference is large, and times nought give the "
                   "biases' class: %s; and what eval reports is that scale on the images it was given, "
                   "its shots numbered past the test images', and the gate's figures with it and with the "
                   "best: %s\n",
                   one ? "so" : "NOT SO", M, same ? "so" : "NOT SO", fixed[0], fixed[1], 100.0 * at_fixed[1],
                   100.0 * at_one[1], lower ? "so" : "NOT SO", least ? "so" : "NOT SO", twice ? "so" : "NOT SO",
                   calibrated ? "so" : "NOT SO");
            if (!one || !same || !least || !twice || !lower || !calibrated)
                errors += fail("one scale on the last layer's outputs is not the least-squares slope of its reference");
            free(a2);
        }
        /* 5j. the golden pass.  The same network, its two hidden layers made
         *     the host's: golden_image() gives, image for image, the operands
         *     the tile's host gives its hidden layers, and the codes the tile
         *     gives its last layer with the format alone, each code at its step
         *     the tile's output; the class is the largest code at its step with
         *     its bias, and of two the same the first, which four ties made
         *     for it hold, as the canary's vectors have none; and two steps
         *     under the fitted one, the codes held are the sums the tile says
         *     are past its range, one for one. */
        {
            int32_t g1[N_HID], g2[N_HID], gs[N_OUT];
            int8_t gc[N_OUT];
            uint8_t gca[N_HID];
            long same_act = 0, same_code = 0, held = 0, tile_held = 0, gcls_ok = 0;
            int pass2, m2, k2, o2, ties_ok = 0;
            int8_t tc[N_OUT];
            int64_t tb[N_OUT];
            hn.host = H;
            quant_weights(&hn, WB, q);
            light_free();
            for (pass2 = 0; pass2 < 2; ++pass2) {
                uint32_t gemm = 0;
                long r;
                memset(cfg, 0, sizeof cfg);
                for (l = 0; l <= H; ++l) {
                    cfg[l].impair    = PTA_QUANT;
                    cfg[l].w_bits    = WB;
                    cfg[l].act_bits  = AB;
                    cfg[l].adc_bits  = BITS;
                    cfg[l].adc_shift = (uint32_t)(s_fit - 2 * pass2);
                }
                for (l = 0; l < H; ++l)
                    cfg[l].w_bits = D;
                host_layers = H;
                r = tile_batch(&hn, cfg, &tile, &dev, 9, &gemm, g, M, a1, bw);
                host_layers = 0;
                for (m2 = 0; m2 < M; ++m2) {
                    long clip = 0;
                    int64_t best = 0;
                    int want = 0;
                    const int c = golden_image(&hn, q, AB, WB, BITS, s_fit - 2 * pass2, a1 + m2 * N_IN, g1, g2, gca,
                                               gs, gc, &clip);
                    held += clip;
                    for (k2 = 0; k2 < N_HID; ++k2)
                        same_act += bw->a[1][m2 * N_HID + k2] == g1[k2] && bw->a[2][m2 * N_HID + k2] == g2[k2] &&
                                    gca[k2] == (uint8_t)(contract_quant(g2[k2], AB, D) >> (D - AB));
                    for (o2 = 0; o2 < N_OUT; ++o2) {
                        const int64_t v = (int64_t)gc[o2] * ((int64_t)1 << (s_fit - 2 * pass2)) + hn.b[H][o2];
                        same_code += bw->y[H][m2 * N_OUT + o2] == (int64_t)gc[o2] * ((int64_t)1 << (s_fit - 2 * pass2));
                        if (o2 == 0 || v > best) {
                            best = v;
                            want = o2;
                        }
                    }
                    gcls_ok += c == want;
                }
                if (pass2 == 1)
                    tile_held = r;
                else
                    tile_held -= r;
            }
            hn.host = 0;
            /* ties, which the canary's vectors do not have: all the same, the
             * first; two the largest, the first of them; a bias parts them;
             * a code one under with a bias one step over, the first again */
            memset(tc, 0, sizeof tc);
            memset(tb, 0, sizeof tb);
            ties_ok += golden_class(tc, tb, 9) == 0;
            tc[3] = tc[N_OUT - 1] = 5;
            ties_ok += golden_class(tc, tb, 9) == 3;
            tb[N_OUT - 1] = 1;
            ties_ok += golden_class(tc, tb, 9) == N_OUT - 1;
            tc[3] = 4;
            tb[3] = 513;
            ties_ok += golden_class(tc, tb, 9) == 3;
            {
                const int ok5j = same_act == 2L * M * N_HID && same_code == 2L * M * N_OUT && gcls_ok == 2L * M &&
                                 ties_ok == 4 && tile_held > 0 && held == tile_held;
                printf("selftest: the golden pass: of %d images, at the fitted step and two under it, the hidden "
                       "operands and the last layer's activation codes are the tile's host's, and every code at "
                       "its step is the tile's output with the format alone: %s; the class is the largest code "
                       "at its step with its bias: %s, and of two the same the first: %s; and two steps under, "
                       "%ld codes held, the sums the tile says are past its range: %s\n", M,
                       same_act == 2L * M * N_HID && same_code == 2L * M * N_OUT ? "so" : "NOT SO",
                       gcls_ok == 2L * M ? "so" : "NOT SO", ties_ok == 4 ? "so" : "NOT SO", held,
                       held == tile_held && tile_held > 0 ? "so" : "NOT SO");
                if (!ok5j)
                    errors += fail("the golden pass is not the tile's format alone");
            }
        }
        /* 5k. the last layer held to its converter's codes (eval --gateref
         *     codes).  gate_reference() at a step's edges, worked by hand.
         *     Then the same network, its two hidden layers the host's, with
         *     the last layer's biases levelled so that a class can move.  With
         *     the format alone, at the fitted step and two under it, the
         *     reference the probe holds the tile to is golden_image()'s codes
         *     at their step, image for image, codes held at the range among
         *     them; the tile is that reference exactly, every image's class
         *     its class and no output a code off; and how often it is right is
         *     the golden class's.  With noise and crosstalk the probe's
         *     figures, its largest error and its tail are what is worked out
         *     here from the tile's outputs and the golden codes, and the tail
         *     falls as it goes; the scale's sums are against the codes, and
         *     its figures at one are the probe's.  With no step the reference
         *     is the sum, as before. */
        {
            int32_t k1[N_HID], k2[N_HID], ksum[N_OUT];
            int8_t kc[N_OUT];
            uint8_t kca[N_HID];
            long kclip = 0, held_under = 0, off1 = 0, ktail[GATE_TAIL];
            int64_t kmean[N_OUT];
            const int64_t k9 = (int64_t)1 << 9;
            const int hA = D - AB, hW = WB < D ? D - WB : 0;
            int hand, exact = 1, worked = 1, falls = 1, scaled = 1, as_sum = 1, moved = 0;
            int kpass, km, ko, kt;
            gate_codes = 9;
            gate_lim   = 128;
            hand = gate_reference(255) == 0 && gate_reference(256) == k9 && gate_reference(767) == k9 &&
                   gate_reference(768) == 2 * k9 && gate_reference(-256) == 0 && gate_reference(-257) == -k9 &&
                   gate_reference(127 * k9 + 255) == 127 * k9 && gate_reference(127 * k9 + 256) == 127 * k9 &&
                   gate_reference(1000 * k9) == 127 * k9 && gate_reference(-128 * k9 - 256) == -128 * k9 &&
                   gate_reference(-1000 * k9) == -128 * k9 && gate_off(1.5 * k9, 0) && !gate_off(0.5 * k9, 0) &&
                   gate_off(2.51 * k9, 2) && !gate_off(2.5 * k9, 2);
            gate_codes = 0;
            hand &= gate_reference(-5) == -5 && gate_reference(7) == 7 && gate_reference(300) == 127;
            gate_codes = -1;
            hand &= gate_reference(-123457) == -123457 && gate_reference(65536) == 65536;
            hn.host = H;
            light_free();
            /* the last layer's biases levelled: each output's mean code at the fitted step taken off */
            memset(kmean, 0, sizeof kmean);
            for (km = 0; km < M; ++km) {
                golden_image(&hn, q, AB, WB, BITS, s_fit, a1 + km * N_IN, k1, k2, kca, ksum, kc, &kclip);
                for (ko = 0; ko < N_OUT; ++ko)
                    kmean[ko] += (int64_t)kc[ko] * ((int64_t)1 << s_fit);
            }
            for (ko = 0; ko < N_OUT; ++ko)
                hn.b[H][ko] = -kmean[ko] / M;
            for (kpass = 0; kpass < 3; ++kpass) {
                const int step = kpass == 1 ? s_fit - 2 : s_fit;
                uint32_t gemm = 0;
                double ge = 0.0, gr = 0.0, worst = 0.0, yf = 0.0, yy = 0.0, yf2 = 0.0, yy2 = 0.0;
                int gagree = 0, gright = 0;
                probe kp;
                scale_result kr;
                memset(cfg, 0, sizeof cfg);
                for (l = 0; l <= H; ++l) {
                    cfg[l].impair    = PTA_QUANT | (kpass == 2 ? PTA_THERMAL | PTA_XTALK : 0u);
                    cfg[l].sigma_th  = kpass == 2 ? 64u : 0u;
                    cfg[l].xtalk     = kpass == 2 ? 2u : 0u;
                    cfg[l].w_bits    = WB;
                    cfg[l].act_bits  = AB;
                    cfg[l].adc_bits  = BITS;
                    cfg[l].adc_shift = (uint32_t)step;
                }
                for (l = 0; l < H; ++l)
                    cfg[l].w_bits = D;
                host_layers = H;
                if (tile_batch(&hn, cfg, &tile, &dev, 11u + (uint32_t)kpass, &gemm, g, M, a1, bw) < 0 ||
                    probe_init(&kp, M, H) != 0) {
                    host_layers = 0;
                    worked = 0;
                    break;
                }
                host_layers = 0;
                kp.gate      = 1;
                kp.gate_bits = AB;
                kp.gy = (double *)malloc((size_t)M * N_OUT * sizeof(double));
                kp.gf = (double *)malloc((size_t)M * N_OUT * sizeof(double));
                if (!kp.gy || !kp.gf) {
                    probe_free(&kp);
                    worked = 0;
                    break;
                }
                gate_codes = step;
                gate_lim   = (int64_t)1 << (BITS - 1);
                probe_batch(&kp, &hn, q, M, a1, bw, labels);
                scale_sums(&hn, q, AB, M, bw, &yf, &yy);
                scale_gate(&kp, &hn, 1.0, &kr);
                memset(ktail, 0, sizeof ktail);
                for (km = 0; km < M; ++km) {
                    long clip = 0;
                    int yb = 0;
                    const int c = golden_image(&hn, q, AB, WB, BITS, step, a1 + km * N_IN, k1, k2, kca, ksum, kc,
                                               &clip);
                    if (kpass == 1)
                        held_under += clip;
                    for (ko = 0; ko < N_OUT; ++ko) {
                        const double y = (double)bw->y[H][km * N_OUT + ko];
                        const double ref = (double)((int64_t)kc[ko] * ((int64_t)1 << step));
                        const double d = y - ref;
                        ge += d * d;
                        gr += ref * ref;
                        if (fabs(d) > worst)
                            worst = fabs(d);
                        for (kt = 0; kt < GATE_TAIL; ++kt)
                            ktail[kt] += fabs(d) >= ldexp((double)(kt + 1), step);
                        worked &= kp.gf[(size_t)km * N_OUT + ko] == ref;
                        yf2 += y * ref;
                        yy2 += y * y;
                        if (y + (double)hn.b[H][ko] > (double)bw->y[H][km * N_OUT + yb] + (double)hn.b[H][yb])
                            yb = ko;
                    }
                    gagree += c == yb;
                    gright += c == labels[km];
                }
                worked &= kp.ge == ge && kp.gr == gr && kp.gworst == worst && kp.gagree == gagree &&
                          kp.gright == gright && yf == yf2 && yy == yy2;
                for (kt = 0; kt < GATE_TAIL; ++kt)
                    worked &= kp.gtail[kt] == ktail[kt];
                scaled &= kr.rms == (gr > 0.0 ? sqrt(ge / gr) : 0.0) && kr.worst == worst;
                for (kt = 0; kt < GATE_TAIL; ++kt)
                    scaled &= kr.tail[kt] == ktail[kt];
                if (kpass < 2) {
                    exact &= ge == 0.0 && worst == 0.0 && gagree == M && ktail[0] == 0;
                } else {
                    off1  = ktail[0];
                    moved = M - gagree;
                    falls &= ktail[0] > 0;
                    for (kt = 1; kt < GATE_TAIL; ++kt)
                        falls &= ktail[kt] <= ktail[kt - 1];
                    /* and with no step, the same outputs against the sum */
                    gate_codes = -1;
                    {
                        probe ks2;
                        if (probe_init(&ks2, M, H) == 0 &&
                            (ks2.gy = (double *)malloc((size_t)M * N_OUT * sizeof(double))) != NULL &&
                            (ks2.gf = (double *)malloc((size_t)M * N_OUT * sizeof(double))) != NULL) {
                            ks2.gate      = 1;
                            ks2.gate_bits = AB;
                            probe_batch(&ks2, &hn, q, M, a1, bw, labels);
                            for (km = 0; km < M; ++km) {
                                long clip = 0;
                                golden_image(&hn, q, AB, WB, BITS, step, a1 + km * N_IN, k1, k2, kca, ksum, kc,
                                             &clip);
                                for (ko = 0; ko < N_OUT; ++ko)
                                    as_sum &= ks2.gf[(size_t)km * N_OUT + ko] ==
                                              (double)((int64_t)ksum[ko] * ((int64_t)1 << (hA + hW)));
                            }
                            for (kt = 0; kt < GATE_TAIL; ++kt)
                                as_sum &= ks2.gtail[kt] == 0;
                        } else {
                            as_sum = 0;
                        }
                        probe_free(&ks2);
                    }
                }
                gate_codes = -1;
                probe_free(&kp);
            }
            gate_codes = -1;
            hn.host = 0;
            exact &= held_under > 0;
            printf("selftest: the last layer held to its converter's codes: by hand at a step's edges: %s; "
                   "with the format alone, at the fitted step and two under it (%ld codes held), the probe's "
                   "reference is the golden codes and the tile is that reference exactly: %s; with noise and "
                   "crosstalk the probe's figures, largest error and tail are those worked out here, %ld of %d "
                   "outputs a code off or more and %d classes moved, and the tail falls: %s; the scale's sums "
                   "and its figures at one are against the codes: %s; and with no step the reference is the "
                   "sum: %s\n", hand ? "so" : "NOT SO", held_under, exact && worked ? "so" : "NOT SO", off1,
                   M * N_OUT, moved, worked && falls ? "so" : "NOT SO", scaled ? "so" : "NOT SO",
                   as_sum ? "so" : "NOT SO");
            if (!(hand && exact && worked && falls && scaled && as_sum && moved > 0))
                errors += fail("the gate's codes are not the converter's");
        }
        /* 5l. a light's levels from a seed of their own (eval --lightseed).
         *     The same network's last layer, and the operands it was last
         *     given.  A light set up with the shots' seed A and the levels'
         *     B has B's levels, line for line; with no level it adds what A's
         *     own light adds, and with no shot's noise what B's adds.  And
         *     light_setup() is light_setup_at() with the two seeds the same:
         *     the light every run before had. */
        {
            const int NL = 2;
            int64_t *ya = (int64_t *)calloc((size_t)M * N_OUT, sizeof(int64_t));
            int64_t *yb = (int64_t *)calloc((size_t)M * N_OUT, sizeof(int64_t));
            double *lev = (double *)malloc((size_t)tile.rows * sizeof(double));
            int lines = 0, levels = 1, shots = 1, steady = 1, same_old = 1, ii, pass3;
            cfg[H].impair = PTA_QUANT;
            for (pass3 = 0; ya && yb && lev && pass3 < 3; ++pass3) {
                /* 0: levels alone; 1: shots alone; 2: both, and light_setup() against light_setup_at() */
                const double fl = pass3 == 1 ? 0.0 : 0.2, al = pass3 == 0 ? 0.0 : 0.01, li = pass3 == 0 ? 0.0 : 0.05;
                memset(ya, 0, (size_t)M * N_OUT * sizeof(int64_t));
                memset(yb, 0, (size_t)M * N_OUT * sizeof(int64_t));
                if (light_setup_at(&hn, cfg, 21, 34, al, li, fl, NL, 0) != 0) {
                    levels = 0;
                    break;
                }
                lines = light.lines;
                for (ii = 0; ii < light.lines; ++ii)
                    lev[ii] = light.level[ii];
                light_add(&hn, &cfg[H], H, M, bw->a[H], ya);
                if (light_setup_at(&hn, cfg, pass3 == 0 ? 34 : 21, pass3 == 0 ? 34 : 21, al, li, fl, NL, 0) != 0) {
                    levels = 0;
                    break;
                }
                light_add(&hn, &cfg[H], H, M, bw->a[H], yb);
                if (pass3 == 0)
                    for (ii = 0; ii < light.lines; ++ii)
                        levels &= light.level[ii] == lev[ii] && lev[ii] != 0.0;
                for (ii = 0; ii < M * N_OUT; ++ii) {
                    if (pass3 == 0)
                        steady &= ya[ii] == yb[ii];
                    if (pass3 == 1)
                        shots &= ya[ii] == yb[ii];
                }
                if (pass3 == 2) {
                    int64_t *yc = ya;
                    double lev2[1];
                    memset(yc, 0, (size_t)M * N_OUT * sizeof(int64_t));
                    if (light_setup(&hn, cfg, 21, al, li, fl, NL, 0) != 0) {
                        same_old = 0;
                        break;
                    }
                    lev2[0] = light.level[0];
                    light_add(&hn, &cfg[H], H, M, bw->a[H], yc);
                    for (ii = 0; ii < M * N_OUT; ++ii)
                        same_old &= yc[ii] == yb[ii];
                    same_old &= lev2[0] != lev[0];      /* 21's levels are not 34's */
                }
            }
            light_free();
            printf("selftest: a light's levels from a seed of their own: with the shots' seed and the levels' "
                   "apart, the %d lines' levels are the levels' seed's: %s; with no level the light is the "
                   "shots' seed's own: %s, and with no shot's noise the levels' seed's: %s; and one seed for "
                   "both is the light every run before had: %s\n", lines, levels ? "so" : "NOT SO",
                   shots ? "so" : "NOT SO", steady ? "so" : "NOT SO", same_old ? "so" : "NOT SO");
            if (!(lines > 0 && levels && shots && steady && same_old))
                errors += fail("a light's levels are not their seed's");
            free(ya);
            free(yb);
            free(lev);
        }
        pta_device_free(&dev);
        host_free(&hn);
        for (l = 0; l <= H; ++l)
            free(q[l]);
        gemm_free(g);
        free(bw);
        free(a1);
        tile_rows = ROWS;
        tile_cols = COLS;
        gemm_k = MAX_K;
        gemm_n = MAX_N;
    }

    /* 5i. a network trained with its first layers the host's (train --host).
     *     Its file says how many are, and is read back as it was written; a
     *     network with none of the host's is the file it always was, and a
     *     file that says none of them, or every layer, is refused.  A layer
     *     of the host's is at the full D bits, in training and on the host,
     *     and every other at the network's, and the host's view of the
     *     network says which.  Training puts its noise on the tile's sums
     *     alone: an epoch on made-up images puts none on the host's layers
     *     and some on the last, where with none of the host's it puts some on
     *     every layer.  With no noise, at the width the host's are at, the
     *     two train the same network weight for weight, and at the network's
     *     they do not: the host's layers are trained at their own width.  What
     *     training reports of a network is its accuracy at each layer's width.
     *     And a network of one hidden layer, that one the host's, is written
     *     and read back as it was. */
    {
        const int D = 8, H = 2, WB = 6, HOST = 2;
        const float NOISE = 0.1f;
        mlp net, back, a[6], one;
        dataset tr, te;
        host_net hn, hp;
        train_report rep[6];
        float *wq[MAX_L];
        int32_t *q[MAX_L], *qp[MAX_L];
        uint64_t r6 = 0x5115ull;
        long len_host = -1, len_plain = -1, off_grid = 0, plain_off = 0;
        int i, k, l, n, round_trip, plain_ok, refused = 1, widths, host_view, noise_ok, same, apart;
        int trained_at, reported, one_ok;
        FILE *f;

        memset(&net, 0, sizeof net);
        net.din   = D;
        net.wbits = WB;
        net.seed  = 1;
        mlp_alloc(&net, H);
        for (l = 0; l <= H; ++l) {
            for (i = 0; i < layer_size(H, l); ++i)
                net.w[l][i] = (float)((int)(splitmix64(&r6) % 255) - 127) / 128.0f;
            for (n = 0; n < layer_out(H, l); ++n)
                net.b[l][n] = (float)((int)(splitmix64(&r6) % 9) - 4) / 64.0f;
        }
        /* the file, with two of the host's and with none */
        net.host = HOST;
        f = tmpfile();
        round_trip = f && write_net(f, &net) == 0;
        len_host = f ? ftell(f) : -1;
        if (f)
            rewind(f);
        round_trip = round_trip && read_net(f, &back) == 0 && memcmp(back.magic, MAGIC_HOST, sizeof MAGIC_HOST) == 0 &&
                     back.host == HOST && back.hidden == H && back.din == D && back.wbits == WB &&
                     len_host == net_bytes(H) + (long)sizeof(int);
        for (l = 0; round_trip && l <= H; ++l)
            round_trip = memcmp(back.w[l], net.w[l], (size_t)layer_size(H, l) * sizeof(float)) == 0 &&
                         memcmp(back.b[l], net.b[l], (size_t)layer_out(H, l) * sizeof(float)) == 0;
        if (round_trip)
            mlp_free(&back);
        /* a file that says none of the host's, or every layer, is refused */
        for (k = 0; f && k < 2; ++k) {
            const int bad = k == 0 ? 0 : H + 1;
            fseek(f, (long)HEAD_BYTES + (long)sizeof(int), SEEK_SET);
            fwrite(&bad, sizeof(int), 1, f);
            rewind(f);
            if (read_net(f, &back) == 0) {
                refused = 0;
                mlp_free(&back);
            }
        }
        if (f)
            fclose(f);
        net.host = 0;
        f = tmpfile();
        plain_ok = f && write_net(f, &net) == 0;
        len_plain = f ? ftell(f) : -1;
        if (f)
            rewind(f);
        plain_ok = plain_ok && read_net(f, &back) == 0 && memcmp(back.magic, MAGIC_DEEP, sizeof MAGIC_DEEP) == 0 &&
                   back.host == 0 && len_plain == net_bytes(H);
        if (plain_ok)
            mlp_free(&back);
        if (f)
            fclose(f);

        /* the widths: a rule, the host's view and its weight operands */
        widths = layer_wbits(HOST, 0, D, WB) == D && layer_wbits(HOST, 1, D, WB) == D &&
                 layer_wbits(HOST, H, D, WB) == WB && layer_wbits(0, 0, D, WB) == WB;
        memset(&tr, 0, sizeof tr);
        memset(&te, 0, sizeof te);
        tr.n = N_ALL;
        te.n = N_TEST;
        tr.x = (uint8_t *)calloc((size_t)N_ALL * N_IN, 1);
        tr.y = (uint8_t *)malloc(N_ALL);
        te.x = (uint8_t *)calloc((size_t)N_TEST * N_IN, 1);
        te.y = (uint8_t *)malloc(N_TEST);
        for (i = 0; i < N_ALL + N_TEST; ++i) {
            uint8_t *x = i < N_ALL ? tr.x + (size_t)i * N_IN : te.x + (size_t)(i - N_ALL) * N_IN;
            for (k = 0; k < 24; ++k)
                x[splitmix64(&r6) % N_IN] = (uint8_t)(1 + splitmix64(&r6) % 255);
            if (i < N_ALL)
                tr.y[i] = (uint8_t)(splitmix64(&r6) % 10);
            else
                te.y[i - N_ALL] = (uint8_t)(splitmix64(&r6) % 10);
        }
        net.host = HOST;
        host_view = host_setup(&hn, &net, &tr) == 0;
        net.host = 0;
        host_view = host_view && host_setup(&hp, &net, &tr) == 0 && hn.host == HOST && hp.host == 0;
        for (l = 0; l <= H; ++l) {
            q[l]  = (int32_t *)malloc((size_t)layer_size(H, l) * sizeof(int32_t));
            qp[l] = (int32_t *)malloc((size_t)layer_size(H, l) * sizeof(int32_t));
        }
        if (host_view) {
            quant_weights(&hn, WB, q);
            quant_weights(&hp, WB, qp);
            for (l = 0; l <= H; ++l)
                for (i = 0; i < layer_size(H, l); ++i) {
                    const int32_t want = contract_quant(hn.w[l][i], l < HOST ? D : WB, D);
                    host_view &= q[l][i] == want && qp[l][i] == contract_quant(hp.w[l][i], WB, D);
                    if (l < HOST) {
                        off_grid  += q[l][i] % 4 != 0;
                        plain_off += qp[l][i] % 4 != 0;
                    } else
                        host_view &= q[l][i] % 4 == 0;
                }
            host_view &= off_grid > 0 && plain_off == 0;
            host_free(&hn);
            host_free(&hp);
        }

        /* an epoch of training: with noise, two of the host's and none; then with
         * none at D bits, two and none; and with none at the network's, two and none */
        for (k = 0; k < 6; ++k) {
            memset(&a[k], 0, sizeof a[k]);
            mlp_alloc(&a[k], H);
            train(&a[k], &tr, &te, D, (k == 2 || k == 3) ? D : WB, (k & 1) ? 0 : HOST, 1, NULL, 0,
                  k < 2 ? NOISE : 0.0, 1, &rep[k]);
        }
        trained_at = memcmp(a[4].w[0], a[5].w[0], (size_t)layer_size(H, 0) * sizeof(float)) != 0 &&
                     memcmp(a[4].w[1], a[5].w[1], (size_t)layer_size(H, 1) * sizeof(float)) != 0;
        for (l = 0; l <= H; ++l) {
            wq[l] = (float *)malloc((size_t)layer_size(H, l) * sizeof(float));
            quantise(a[4].w[l], wq[l], layer_size(H, l), D, layer_wbits(HOST, l, D, WB));
        }
        reported = digital_accuracy(&a[4], wq, &tr, N_TRAIN, N_ALL - N_TRAIN) == a[4].val_acc &&
                   digital_accuracy(&a[4], wq, &te, 0, N_TEST) == a[4].test_acc;
        for (l = 0; l <= H; ++l)
            free(wq[l]);
        /* one hidden layer, the host's */
        memset(&one, 0, sizeof one);
        one.din   = D;
        one.wbits = WB;
        one.seed  = 3;
        mlp_alloc(&one, 1);
        one.host = 1;
        for (l = 0; l <= 1; ++l)
            for (i = 0; i < layer_size(1, l); ++i)
                one.w[l][i] = (float)((int)(splitmix64(&r6) % 255) - 127) / 128.0f;
        f = tmpfile();
        one_ok = f && write_net(f, &one) == 0 && ftell(f) == net_bytes(1) + 2L * (long)sizeof(int);
        if (f)
            rewind(f);
        one_ok = one_ok && read_net(f, &back) == 0 && back.hidden == 1 && back.host == 1 &&
                 memcmp(back.w[1], one.w[1], (size_t)layer_size(1, 1) * sizeof(float)) == 0;
        if (one_ok)
            mlp_free(&back);
        if (f)
            fclose(f);
        mlp_free(&one);
        noise_ok = rep[0].got[0] == 0.0 && rep[0].got[1] == 0.0 && fabs(rep[0].got[H] - NOISE) < 0.03 &&
                   fabs(rep[1].got[0] - NOISE) < 0.03 && fabs(rep[1].got[1] - NOISE) < 0.03 &&
                   fabs(rep[1].got[H] - NOISE) < 0.03 && a[0].host == HOST && a[1].host == 0 &&
                   memcmp(a[0].magic, MAGIC_HOST, sizeof MAGIC_HOST) == 0 && memcmp(a[1].magic, MAGIC_DEEP, sizeof MAGIC_DEEP) == 0;
        same = 1;
        apart = 0;
        for (l = 0; l <= H; ++l) {
            same &= memcmp(a[2].w[l], a[3].w[l], (size_t)layer_size(H, l) * sizeof(float)) == 0 &&
                    memcmp(a[2].b[l], a[3].b[l], (size_t)layer_out(H, l) * sizeof(float)) == 0;
            apart += memcmp(a[0].w[l], a[1].w[l], (size_t)layer_size(H, l) * sizeof(float)) != 0;
        }
        same &= rep[2].got[0] == 0.0 && rep[3].got[H] == 0.0 && apart == H + 1;
        printf("selftest: a network trained with its first %d layers the host's: its file says so and is "
               "read back as written, %ld bytes where with none of the host's it is %ld, the file it "
               "always was: %s; a file that says none or every layer is refused: %s; the host's layers "
               "are at %d bits and the last at %d, in training and on the host, %ld of the host's first "
               "weights off the %d-bit grid: %s; an epoch puts noise of %.3f, %.3f and %.3f on the "
               "three layers' sums, where with none of the host's it puts %.3f, %.3f and %.3f: %s; and "
               "with no noise at %d bits the two train the same network, and at %d bits they do not, "
               "the host's at their own width: %s; what training reports is the accuracy at each layer's "
               "width: %s; and a network of one hidden layer, the host's, is read back as written: %s\n",
               HOST, len_host, len_plain, round_trip && plain_ok ? "so" : "NOT SO", refused ? "so" : "NOT SO",
               D, WB, off_grid, WB, widths && host_view ? "so" : "NOT SO", rep[0].got[0], rep[0].got[1],
               rep[0].got[H], rep[1].got[0], rep[1].got[1], rep[1].got[H], noise_ok ? "so" : "NOT SO", D,
               WB, same && trained_at ? "so" : "NOT SO", reported ? "so" : "NOT SO", one_ok ? "so" : "NOT SO");
        if (!round_trip || !plain_ok || !refused || !widths || !host_view || !noise_ok || !same || !trained_at ||
            !reported || !one_ok)
            errors += fail("a network with layers of the host's is not trained, written or run as the host's");
        for (k = 0; k < 6; ++k)
            mlp_free(&a[k]);
        for (l = 0; l <= H; ++l) {
            free(q[l]);
            free(qp[l]);
        }
        mlp_free(&net);
        free(tr.x);
        free(tr.y);
        free(te.x);
        free(te.y);
    }

    /* The tests from here on are written to D3's shape: its layers' sizes, its
     * file's length, tiles and thresholds chosen for it.  A build of another
     * shape is the same source, and runs the tests above, which are of any. */
    if (N_SIDE != 28 || N_HID != 100 || N_OUT != 10) {
        printf("selftest: built for images %d x %d, layers %d wide and %d outputs: the tests that are "
               "of D3's shape are not run on this build\n", N_SIDE, N_SIDE, N_HID, N_OUT);
        printf("selftest %s\n", errors ? "FAILED" : "passed");
        return errors ? 1 : 0;
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
            cfg.seed = seed_take(5, &gemm);
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
                cfg[0].seed = seed_peek(5, 0);
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
           "pta_mnist invert IN OUT   an idx file of this build's images, every pixel taken from 255\n"
           "pta_mnist pool IN OUT     an idx file of 28 x 28 images, pooled to this build's size: the\n"
           "                          middle cut into equal blocks, and each block's mean\n"
           "pta_mnist train --data DIR --din 8|16 --wbits B --seed S --out NET [--from NET] [--verbose 1]\n"
           "  --hidden H      hidden layers, each as wide as the build has them, 100 unless it says\n"
           "                  another (1, which is D3; up to 8)\n"
           "  --sumnoise F    train with Gaussian noise on every layer's sums, F of their rms (0)\n"
           "  --epochs N      run N epochs, in place of stopping when held-out accuracy stops rising\n"
           "  --host N        the first N layers are the host's: weights at the full D bits, and no\n"
           "                  --sumnoise on their sums (0); eval runs the network with --host N\n"
           "pta_mnist golden --data DIR --net NET --out DIR --abits B --adcbits B --rows R --cols C\n"
           "                 [--images N] [--cal M]   the canary's golden tensors, in its declared format\n"
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
           "                  noise in 8-bit LSB, and the accuracy that error alone predicts\n");
    printf("  --src X         the light source: every line's power together, rms fraction a shot\n"
           "  --srcline X     each line's on its own, rms fraction a shot\n"
           "  --srcflat X     each line's level, rms fraction, fixed for the run\n"
           "  --lightseed N   the seed the lines' levels are drawn from, where the shots' noise\n"
           "                  stays the run's: one source's repeats.  The line gives the levels' rms,\n"
           "                  light_levels (the run's --seed)\n"
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
           "  --host N        the network's first N layers run on the host, exactly, and the rest on\n"
           "                  the tile.  A light, and a correction for its lines, are the tile's\n"
           "                  layers' alone (0)\n"
           "  --gate 1        with --probe: the last layer against a reference in its own declared\n"
           "                  format, as rms over the reference's rms, over its largest value, and\n"
           "                  the largest error over that value; and against the operands as given.\n"
           "                  And how often that reference is right, and the tile gives its class\n"
           "  --gatefit F     with --gate and every layer but the last on the host: the last converter's\n"
           "                  range from that reference on the images run, the smallest step at which\n"
           "                  the largest it is, is within F of full scale (1 fits it; 0.5 leaves a bit)\n"
           "  --gatebits B    with --gate: the last layer's converter has B bits, at the step the run's\n"
           "                  converters have: a bit more is twice the range at the same LSB\n"
           "  --gatescale M   with --gate: the gate's figures again with the last layer's outputs times\n"
           "                  one scale, fixed on the first M of the 6,000 held-out training images\n"
           "                  after the test images; and the scale the test images would fit themselves\n"
           "  --gateref codes with --gate: the last layer held to its converter's codes, at its step, in\n"
           "                  place of the declared format's exact sum (sum); with the largest error in\n"
           "                  codes and how many outputs are 1 to 32 codes off or more.  Needs --adcbits\n"
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
    if (argc >= 2 && strcmp(argv[1], "golden") == 0)
        return cmd_golden(argc, argv);
    if (argc == 4 && strcmp(argv[1], "invert") == 0) {
        long len = 0, n;
        uint8_t *b = read_file(argv[2], &len);
        FILE *f;
        if ((n = invert_idx(b, len)) < 0) {
            fprintf(stderr, "pta_mnist: %s missing or not an idx file of %d x %d images\n", argv[2],
                    N_SIDE, N_SIDE);
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
    if (argc == 4 && strcmp(argv[1], "pool") == 0) {
        long len = 0, n = -1;
        uint8_t *b = read_file(argv[2], &len), *out = b ? (uint8_t *)malloc((size_t)len + 1) : NULL;
        FILE *f;
        if (!out || (n = pool_idx(b, len, N_SIDE, out)) < 0) {
            fprintf(stderr, "pta_mnist: %s missing, not an idx file of 28 x 28 images, or 28 does not "
                            "pool to %d\n", argv[2], N_SIDE);
            free(b);
            free(out);
            return 1;
        }
        f = fopen(argv[3], "wb");
        if (!f || fwrite(out, 1, (size_t)n, f) != (size_t)n || fclose(f) != 0) {
            fprintf(stderr, "pta_mnist: cannot write %s\n", argv[3]);
            free(b);
            free(out);
            return 1;
        }
        free(b);
        free(out);
        printf("pool: %ld images to %d x %d\n", (n - 16) / (N_SIDE * N_SIDE), N_SIDE, N_SIDE);
        return 0;
    }
    help();
    return argc >= 2 && strcmp(argv[1], "help") == 0 ? 0 : 2;
}
