// Verilator harness for c930_npu_core.
//
// Drives the core's data-plane preload port directly, so it reaches the full
// MAX_M/MAX_K parameter space without the DMA or a memory model. Checks C
// against a software reference and reports the three performance counters.
// Same cases as tb/tb_core_m64.sv, several orders of magnitude faster, so a
// full M/N/K sweep is a few seconds rather than an overnight iverilog run.
//
//   verilator --cc --exe --build -O3 --top-module c930_npu_core -GMAX_N=12 \
//     -CFLAGS -I../sim -o tb_core_verilator \
//     sim/tb_core_verilator.cc sim/pta_tile_model.c <core RTL>
//   ./obj_dir/tb_core_verilator            # default case list
//   ./obj_dir/tb_core_verilator --sweep    # M/N/K sweep, CSV on stdout
//
// <core RTL> is the core's list in the Makefile's NPU_RTL, less the CSR, DMA
// and top.  For a PTM-C build add -DPTM_C and take rtl/pta/c930_fp32_add.sv and
// rtl/pta/c930_ptm_c.sv in place of the systolic array and its PEs.
//
// The activation stage, S_ACT (doc/npu_act_stage_design_note.md section 6):
//
//   (default)                       gate A0: S_ACT disabled.  The output is
//                                   byte-identical to a core without S_ACT,
//                                   so A0 is a diff of the two runs.
//   --act identity [--table F]      gate A1: each case runs disabled and then
//                                   through the identity table.  C must equal
//                                   the digital reference exactly, and
//                                   CYCLE_COUNT must grow by M * Nt * ACT_P
//                                   with OP_COUNT and STALL_COUNT unchanged.
//                                   Without --table the table is computed.
//   --act full --table F            gate A2: a real transfer curve with shot
//                                   noise, detuning and requantisation on;
//                                   C must match act_element() bit for bit.
//   --perturb I                     take one LSB off breakpoint I on its way into
//                                   the DUT only: the ablation for A1 and A2.
//                                   Down, not up: the interpolation floors, so
//                                   on the identity table +1 is absorbed for
//                                   every input except one exactly on x_I,
//                                   while -1 moves both neighbouring segments.
//
// act_element() is the C reference for c930_npu_act.sv, whose header states
// the fixed-point contract both implement.  Tables are the $readmemh images
// c930/sim/act_table_gen.py writes.
//
// The PTA error model, phase C1 (doc/pta_error_model_design_note.md section 5).
// Build the model with -DPTM_C and rtl/pta's tile, link sim/pta_tile_model.c,
// the C reference, and pass --tile ptm_c to say so.
//
//   (default), --tile ptm_c         gate P0: every impairment clear, C exact.
//   --pta directed                  semantics pinned by hand-computed cases:
//                                   the quantisers and the ADC at half-LSB
//                                   boundaries and at saturation; crosstalk,
//                                   and a stale row outside the K tile that
//                                   must not couple; drift from a model reset,
//                                   at its bound, held, and reset again.
//   --pta quant|thermal|shot|prog   gates P1-P6: one impairment, or all six;
//   --pta drift|xtalk|all           C and the ADC saturation count must match
//                                   pta_gemm() bit for bit at every shape.
//                                   Drift runs its 14 GEMMs on one device,
//                                   with a GEMM that holds drift, a model
//                                   reset pulsed while busy (ignored) and one
//                                   while idle.
//   --pta refuse                    impairments the build cannot model, FP16
//                                   and BF16 with any impairment, and S > 40
//                                   raise o_error at start; the next valid
//                                   start clears it.  A digital-array build
//                                   refuses every impairment.
//
// The PTA calibration, phase C3(b) (design note section 5, gates P7 to P9).
//
//   --pta trim                      gate P7: the two correction paths.  A trim
//                                   per cell through the weight DAC and an
//                                   affine per column after the ADC, written
//                                   into the RTL and the model together: C and
//                                   the saturation count must match pta_gemm()
//                                   at every shape.  Directed cases pin the
//                                   DAC's step and clamp and the affine's
//                                   rounding against values worked out by
//                                   hand, and with every impairment clear a
//                                   loaded correction must change nothing.
//   --pta engine                    gate P8: the calibration engine.  Drift is
//                                   accumulated, the engine calibrates, and both
//                                   errors it publishes and every trim it wrote
//                                   must match pta_cal_bank() -- the trims by
//                                   reading the tile back one cell at a time.
//                                   Also its refusals: an amplitude the probe
//                                   cannot read back, a START that arrives
//                                   while CAL_BUSY is set, a MODEL_RST during
//                                   a calibration, and DRIFT_ALARM when a trim
//                                   cannot reach what was asked of it.
//   --pta sched                     gate P9: the four schedulers, on a GEMM
//                                   sequence whose A rows arrive the way the
//                                   DMA delivers them.  The shadow scheduler
//                                   must cost less wall-clock than the periodic
//                                   one at the same accuracy, which is C3's own
//                                   gate.  The drift-predictive one is reported
//                                   rather than gated: how often it fires is
//                                   PTA_CAL_THR's to decide.
//
// Ablations: PTM_C_ABLATE_TRIM (a trim written without the DAC's step) and
// PTM_C_ABLATE_AFFINE (the affine applied before the ADC) fail P7's directed
// cases; PTA_CAL_ABLATE_RANGE (a probe that keeps the GEMM's ADC range, which
// is what C3(a) measured the cost of) fails P8.

#include "Vc930_npu_core.h"
#include "verilated.h"
#include "pta_tile_model.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>

namespace {

constexpr int NUM_ROWS = 8;
constexpr int NUM_COLS = 8;
constexpr int MAX_M    = 64;
constexpr int MAX_K    = 256;
constexpr int MAX_N    = 12;
constexpr int ACT_P    = 7;       // c930_npu_act: element in to result written
                                  // (7 since the stage-2 split -- root/draw and
                                  // the k_shot multiply are separate cycles)
constexpr int ACT_TBL  = 1025;    // breakpoints

Vc930_npu_core* dut = nullptr;
uint64_t main_time = 0;

void tick() {
    dut->i_clk = 0; dut->eval();
    dut->i_clk = 1; dut->eval();
    main_time++;
}

// Deterministic operand generator: no rand(), so runs reproduce bit for bit
// across machines and across the iverilog bench.
uint32_t lfsr_state = 0xACE1u;
int rnd(int width) {
    lfsr_state ^= lfsr_state << 13;
    lfsr_state ^= lfsr_state >> 17;
    lfsr_state ^= lfsr_state << 5;
    const int span = 1 << width;
    return static_cast<int>(lfsr_state % span) - (span >> 1);
}

// Zero a port whatever width Verilator gave it: an integer up to 64 bits, a
// VlWide of 32-bit words beyond.  i_wwdata is WR_LANES * DIN_W bits, so it is
// 64 bits at DIN_W 8 and 128 at DIN_W 16.
template <typename T> void zero(T& port) { port = 0; }
template <std::size_t W> void zero(VlWide<W>& port) {
    for (std::size_t i = 0; i < W; ++i) port[i] = 0;
}

void preload(int sel, int addr, int val) {
    dut->i_wen   = 1;
    dut->i_wsel  = sel;
    dut->i_waddr = addr;
    dut->i_wdata = val;
    tick();
    dut->i_wen = 0;
}

// ---------------------------------------------------------------------------
// S_ACT reference
// ---------------------------------------------------------------------------
struct ActCfg {
    bool     en          = false;
    bool     requant     = false;
    bool     noise_const = false;
    int      adc_bits    = 0;     // 1..15
    int      xshift      = 0;
    int      yshift      = 0;
    uint16_t k_shot      = 0;     // Q8.8
    uint32_t seed        = 1;
    uint32_t xs[NUM_COLS] = {};   // XSCALE * s_j
    uint16_t r[NUM_COLS]  = {};   // 1 / s_j, Q4.12
};

std::vector<int32_t> act_table(ACT_TBL, 0);

uint32_t xorshift32(uint32_t s) {
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

uint32_t isqrt4(uint32_t a) {
    if (a == 0) return 0;
    static const uint32_t T4[4] = {2048, 2896, 3547, 4096};
    const int p = 31 - __builtin_clz(a);
    const int e = p >> 1;
    const uint32_t t = (a << (22 - 2 * e)) & 0xFFFFFFu;
    const int seg = static_cast<int>(t >> 22) - 1;
    const uint32_t lo = T4[seg], hi = T4[seg + 1];
    const uint32_t rn = lo + (((hi - lo) * ((t >> 16) & 0x3Fu)) >> 6);
    return rn >> (11 - e);
}

struct ActOut {
    int32_t c;
    int     sats;
};

// One element through stages 1-6 of c930_npu_act.sv, advancing rng once.
ActOut act_element(int64_t acc, int j, const ActCfg& cfg, uint32_t& rng) {
    int sats = 0;
    const __int128 p1 = static_cast<__int128>(acc) * static_cast<__int128>(cfg.xs[j]);
    const __int128 p1s = p1 >> cfg.xshift;
    int32_t x;
    if (p1s > 0x7FFFFF)       { x = 0x7FFFFF;  ++sats; }
    else if (p1s < -0x800000) { x = -0x800000; ++sats; }
    else                        x = static_cast<int32_t>(p1s);

    const uint32_t ax  = x < 0 ? static_cast<uint32_t>(-static_cast<int64_t>(x))
                               : static_cast<uint32_t>(x);
    const uint32_t rt  = cfg.noise_const ? 4096u : isqrt4(ax);
    const uint64_t sig = static_cast<uint64_t>(cfg.k_shot) * rt;
    rng = xorshift32(rng);
    const int g = static_cast<int>((rng >> 24) & 0xFF) + static_cast<int>((rng >> 16) & 0xFF) +
                  static_cast<int>((rng >> 8) & 0xFF)  + static_cast<int>(rng & 0xFF) - 510;
    const int64_t gs = static_cast<int64_t>(g) * 443;

    const __int128 prod3 = static_cast<__int128>(sig) * gs;
    const int64_t noise = static_cast<int64_t>((prod3 + (static_cast<__int128>(1) << 23)) >> 24);
    const int64_t sum3 = static_cast<int64_t>(x) + noise;
    int32_t x2;
    if (sum3 > 0x7FFFFF)       { x2 = 0x7FFFFF;  ++sats; }
    else if (sum3 < -0x800000) { x2 = -0x800000; ++sats; }
    else                         x2 = static_cast<int32_t>(sum3);

    const uint32_t u = static_cast<uint32_t>(x2 + 0x800000);
    const uint32_t i = u >> 14, f = u & 0x3FFFu;
    const int64_t y0 = act_table[i], y1 = act_table[i + 1];
    const int64_t y  = y0 + (((y1 - y0) * static_cast<int64_t>(f)) >> 14);

    const int64_t yr = (y * static_cast<int64_t>(cfg.r[j])) >> 12;
    int64_t c = yr;
    if (cfg.requant) {
        const int B = cfg.adc_bits, sh = 24 - B;
        int64_t q = (yr + (1LL << (sh - 1))) >> sh;
        const int64_t hi = (1LL << (B - 1)) - 1, lo = -(1LL << (B - 1));
        q = std::max(lo, std::min(hi, q));
        c = q * (1LL << sh);
    }
    const int ys = std::min(cfg.yshift, 32);
    const __int128 wide = static_cast<__int128>(c) * (static_cast<__int128>(1) << ys);
    int32_t out;
    if (wide > 0x7FFFFFFF)                 { out = 0x7FFFFFFF;            ++sats; }
    else if (wide < -static_cast<__int128>(0x80000000LL)) { out = INT32_MIN; ++sats; }
    else                                     out = static_cast<int32_t>(wide);
    return {out, sats};
}

void apply_act(const ActCfg& cfg) {
    dut->i_act_en          = cfg.en;
    dut->i_act_requant     = cfg.requant;
    dut->i_act_adc_bits    = cfg.adc_bits;
    dut->i_act_xshift      = cfg.xshift;
    dut->i_act_yshift      = cfg.yshift;
    dut->i_act_k_shot      = cfg.k_shot;
    dut->i_act_noise_const = cfg.noise_const;
    dut->i_act_seed        = cfg.seed;
    for (int j = 0; j < NUM_COLS; ++j) dut->i_act_xs[j] = cfg.xs[j];
    for (int w = 0; w < (16 * NUM_COLS + 31) / 32; ++w) dut->i_act_r[w] = 0;
    for (int j = 0; j < NUM_COLS; ++j) {
        const int bit = 16 * j;
        dut->i_act_r[bit / 32] |= static_cast<uint32_t>(cfg.r[j]) << (bit % 32);
    }
}

void write_table(int perturb) {
    for (int i = 0; i < ACT_TBL; ++i) {
        const int32_t v = act_table[i] - (i == perturb ? 1 : 0);
        dut->i_act_tbl_wen   = 1;
        dut->i_act_tbl_waddr = i;
        dut->i_act_tbl_wdata = static_cast<uint32_t>(v) & 0xFFFFFFu;
        tick();
    }
    dut->i_act_tbl_wen = 0;
}

bool load_table(const std::string& path) {
    std::ifstream in(path);
    if (!in) { fprintf(stderr, "cannot open %s\n", path.c_str()); return false; }
    std::string line;
    int n = 0;
    while (std::getline(in, line)) {
        if (line.rfind("//", 0) == 0) continue;
        std::istringstream ss(line);
        std::string tok;
        while (ss >> tok) {
            if (n >= ACT_TBL) { fprintf(stderr, "%s: too many entries\n", path.c_str()); return false; }
            const int32_t v = static_cast<int32_t>(std::stoul(tok, nullptr, 16) & 0xFFFFFFu);
            act_table[n++] = (v & 0x800000) ? v - 0x1000000 : v;
        }
    }
    if (n != ACT_TBL) { fprintf(stderr, "%s: %d entries, want %d\n", path.c_str(), n, ACT_TBL); return false; }
    return true;
}

void identity_table() {
    for (int i = 0; i < ACT_TBL; ++i)
        act_table[i] = std::min(-0x800000 + (i << 14), 0x7FFFFF);
}

// ---------------------------------------------------------------------------
// PTA error model
// ---------------------------------------------------------------------------
const pta_cfg PTA_OFF = {};

void apply_pta(const pta_cfg& cfg) {
    dut->i_pta_impair    = cfg.impair;
    dut->i_pta_act_bits  = cfg.act_bits;
    dut->i_pta_w_bits    = cfg.w_bits;
    dut->i_pta_adc_bits  = cfg.adc_bits;
    dut->i_pta_adc_shift = cfg.adc_shift;
    dut->i_pta_seed      = cfg.seed;
    dut->i_pta_sigma_th  = cfg.sigma_th;
    dut->i_pta_k_shot    = cfg.k_shot;
    dut->i_pta_sigma_pr  = cfg.sigma_pr;
    dut->i_pta_drift_sigma = cfg.drift_sigma;
    dut->i_pta_drift_log2  = cfg.drift_log2;
    dut->i_pta_drift_max   = cfg.drift_max;
    dut->i_pta_xtalk       = cfg.xtalk;
}

// The modelled device.  Drift outlives a GEMM, so the model's state does too,
// from one run_case to the next, exactly as the RTL's.
pta_device g_dev = {};

// ---------------------------------------------------------------------------
// PTA calibration, phase C3(b)
// ---------------------------------------------------------------------------
struct CalCfg {
    bool     en        = false;
    uint32_t sched     = 0;      // 0 off, 1 periodic, 2 predictive, 3 shadow
    uint32_t per       = 0;      // PTA_CAL_PER
    uint32_t thr       = 0;      // PTA_CAL_THR
    uint32_t amp_log2  = 0;      // probe amplitude, 1 << this
    uint32_t reps_log2 = 0;      // repeats a pass, 1 << this
    uint32_t passes    = 3;      // auto-ranging passes, PTA_CAL_CFG[9:8]
    uint32_t trim_log2 = 0;      // the weight DAC's step, 1 << this, Q.8
    uint32_t trim_max  = 0;      // and its clamp
    uint32_t seed      = 0;
    bool     bank      = false;
};

void apply_cal(const CalCfg& c) {
    dut->i_pta_cal_en    = c.en;
    dut->i_pta_cal_sched = c.sched;
    dut->i_pta_cal_per   = c.per;
    dut->i_pta_cal_thr   = c.thr;
    dut->i_pta_cal_amp   = c.amp_log2;
    dut->i_pta_cal_reps  = c.reps_log2;
    dut->i_pta_cal_passes = c.passes;
    dut->i_pta_cal_bank  = c.bank;
    dut->i_pta_trim_log2 = c.trim_log2;
    dut->i_pta_trim_max  = c.trim_max;
    dut->i_pta_cal_seed  = c.seed;
}

// A cell's trim and a column's affine, into the RTL's stores and the model's
// together.  The DAC rounds and clamps in both, which is the point.
void write_trim(const pta_cfg& dac, int bank, int row, int col, int64_t q88) {
    dut->i_pta_trim_wen  = 1;
    dut->i_pta_trim_bank = bank;
    dut->i_pta_trim_row  = row;
    dut->i_pta_trim_col  = col;
    dut->i_pta_trim_data = static_cast<uint32_t>(static_cast<int32_t>(q88));
    tick();
    dut->i_pta_trim_wen = 0;
    pta_trim_write(&g_dev, &dac, bank, row, col, q88);
}

void write_affine(int col, int32_t gain, int32_t offs) {
    dut->i_pta_aff_wen  = 1;
    dut->i_pta_aff_col  = col;
    dut->i_pta_aff_gain = static_cast<uint32_t>(gain) & 0x3FFFFu;
    dut->i_pta_aff_offs = static_cast<uint32_t>(offs);
    tick();
    dut->i_pta_aff_wen = 0;
    pta_column_cal(&g_dev, col, gain, offs);
}

void cal_reset() {
    dut->i_pta_cal_rst = 1;
    tick();
    dut->i_pta_cal_rst = 0;
    pta_cal_reset(&g_dev);
}

// One calibration, fired by CAL_NOW while the core is idle, run to completion.
// Returns the cycles CAL_BUSY was set for, or 0 if it never started.
uint64_t run_cal_now(uint64_t patience = 200'000) {
    uint64_t waited = 0, busy = 0;
    dut->i_pta_cal_now = 1;
    tick();
    dut->i_pta_cal_now = 0;
    while (!dut->o_pta_cal_busy && waited++ < 200) tick();
    while (dut->o_pta_cal_busy && busy++ < patience) tick();
    tick();
    return dut->o_pta_cal_busy ? 0 : busy;
}

// A model reset, in the RTL and the model together.  Only while idle.
void model_reset(uint32_t seed) {
    dut->i_pta_seed      = seed;
    dut->i_pta_model_rst = 1;
    tick();
    dut->i_pta_model_rst = 0;
    pta_model_reset(&g_dev, seed);
}

// When set, the next run_case pulses a model reset this many cycles after its
// start, while the core is busy.  The core must ignore it, so the model does
// not reset either.
long g_busy_rst_at = -1;

// C as the RTL reads it back.
std::vector<int32_t> read_c(int M, int N) {
    std::vector<int32_t> c(static_cast<size_t>(M) * N);
    for (int i = 0; i < M * N; ++i) {
        dut->i_c_raddr = i;
        dut->eval();
        c[i] = static_cast<int32_t>(dut->o_c_rdata);
    }
    return c;
}

struct Result {
    uint32_t cycles, ops, stall;
    uint32_t act_count, act_sats, act_cycles;
    int      model_sats;
    int      changed;     // elements S_ACT or the tile moved off their plain sum
    uint32_t pta_sats;    // o_pta_sat_count
    long     model_pta_sats;
    bool ok;
};

Result run_case(int M, int N, int K, int width, bool verbose, const ActCfg& act,
                const pta_cfg& pta = PTA_OFF,
                const std::vector<int>* a_in = nullptr,
                const std::vector<int>* b_in = nullptr) {
    std::vector<int>     a(static_cast<size_t>(M) * K);
    std::vector<int>     b(static_cast<size_t>(K) * N);
    std::vector<int64_t> cref(static_cast<size_t>(M) * N, 0);

    // Operands are generated, or given by a directed case.
    for (int m = 0; m < M; ++m)
        for (int k = 0; k < K; ++k) {
            a[m * K + k] = a_in ? (*a_in)[m * K + k] : rnd(width);
            preload(0, m * K + k, a[m * K + k]);
        }
    for (int k = 0; k < K; ++k)
        for (int n = 0; n < N; ++n) {
            b[k * N + n] = b_in ? (*b_in)[k * N + n] : rnd(width);
            preload(1, k * N + n, b[k * N + n]);
        }
    for (int m = 0; m < M; ++m)
        for (int n = 0; n < N; ++n)
            for (int k = 0; k < K; ++k)
                cref[m * N + n] += static_cast<int64_t>(a[m * K + k]) * b[k * N + n];

    // What C should read back.  With S_ACT on, each complete sum goes through
    // the reference in the order the core feeds it: N tile, row, column.
    std::vector<int64_t> cexp(cref);
    int model_sats = 0;
    if (act.en) {
        uint32_t rng = act.seed;
        for (int n_base = 0; n_base < N; n_base += NUM_COLS) {
            const int nc = std::min(NUM_COLS, N - n_base);
            for (int m = 0; m < M; ++m)
                for (int j = 0; j < nc; ++j) {
                    const ActOut o = act_element(cref[m * N + n_base + j], j, act, rng);
                    cexp[m * N + n_base + j] = o.c;
                    model_sats += o.sats;
                }
        }
    }
    apply_act(act);

    // With the tile's error model on, pta_gemm() walks the core's loop order
    // and says what every C element must be.
    long model_pta_sats = 0;
    if (pta.impair) {
        const pta_tile tile = {NUM_ROWS, NUM_COLS, width, 48};
        std::vector<int32_t> A(a.begin(), a.end()), B(b.begin(), b.end());
        std::vector<int64_t> C(cexp.size());
        model_pta_sats = pta_gemm(&pta, &tile, &g_dev, 0, M, N, K, A.data(), B.data(), C.data());
        cexp.assign(C.begin(), C.end());
    }
    apply_pta(pta);

    // A-row watermark: this harness writes all of A up front, so every row is
    // resident.  Zero would work too (the core reads 0 as "no watermark"), but
    // saying M exercises the comparison the DMA path actually drives.
    dut->i_a_rows_ready = M;
    dut->i_dim_m = M; dut->i_dim_n = N; dut->i_dim_k = K;
    while (dut->o_pta_cal_busy) tick();   // the dispatch guard, see run_raw()
    dut->i_start = 1; tick();
    dut->i_start = 0;

    uint64_t guard = 0;
    while (!dut->o_done) {
        const bool pulse = g_busy_rst_at >= 0 && guard == static_cast<uint64_t>(g_busy_rst_at);
        if (pulse) { dut->i_pta_seed = 0xDEADBEEFu; dut->i_pta_model_rst = 1; }
        tick();
        if (pulse) { dut->i_pta_model_rst = 0; dut->i_pta_seed = pta.seed; }
        if (++guard > 50'000'000ull) { fprintf(stderr, "timeout\n"); exit(2); }
    }
    g_busy_rst_at = -1;
    tick();

    int changed = 0;
    for (size_t e = 0; e < cref.size(); ++e)
        if (static_cast<int32_t>(cexp[e]) != static_cast<int32_t>(cref[e])) ++changed;

    Result r{dut->o_cycle_count, dut->o_op_count, dut->o_stall_count,
             dut->o_act_count, dut->o_act_sat_count, dut->o_act_cycles, model_sats,
             changed, dut->o_pta_sat_count, model_pta_sats, true};

    int errs = 0;
    for (int m = 0; m < M; ++m)
        for (int n = 0; n < N; ++n) {
            dut->i_c_raddr = m * N + n;
            dut->eval();
            const int32_t got = static_cast<int32_t>(dut->o_c_rdata);
            const int32_t exp = static_cast<int32_t>(cexp[m * N + n] & 0xffffffffll);
            if (got != exp) {
                if (errs < 5) {
                    if (act.en || pta.impair)
                        printf("  [FAIL] C[%d][%d] = %d expected %d (sum %lld)\n",
                               m, n, got, exp, static_cast<long long>(cref[m * N + n]));
                    else
                        printf("  [FAIL] C[%d][%d] = %d expected %d\n", m, n, got, exp);
                }
                ++errs;
            }
        }
    r.ok = (errs == 0);

    if (verbose) {
        printf("[core] DW=%d M=%-3d N=%-2d K=%-4d cycles=%-8u ops=%-9u stall=%-8u  %s\n",
               width, M, N, K, r.cycles, r.ops, r.stall, r.ok ? "PASS" : "FAIL");
    }
    return r;
}

// A GEMM the model is not told about.  P9's shadow scheduler interrupts GEMMs,
// so the RTL's tile and the model's part company by design: what P9 measures is
// wall-clock and the residual the tile is left with, not parity.
// gap 0 means every A row is resident at the start; otherwise row m is
// announced `gap` cycles after row m-1, the way the DMA delivers them, and the
// core waits in S_AROW between rows -- the idle window the shadow is for.
uint64_t run_raw(int M, int N, int K, int gap, const std::vector<int>& a,
                 const std::vector<int>& b, const pta_cfg& pta) {
    for (int i = 0; i < M * K; ++i) preload(0, i, a[i]);
    for (int i = 0; i < K * N; ++i) preload(1, i, b[i]);
    apply_pta(pta);
    dut->i_dim_m = M; dut->i_dim_n = N; dut->i_dim_k = K;
    dut->i_a_rows_ready = gap > 0 ? 1 : M;
    // Never dispatch into a calibrating tile.  Here the harness is the
    // dispatcher, so it owes the tile the guard the CSR owes it (grxcp
    // pta_cpu_integration.md section 3.2): a START during a calibration is not
    // taken, and whoever sent it then waits for a done that never comes.  This
    // is how P9 first failed, which is as good a demonstration of the guard's
    // purpose as the regression itself.
    while (dut->o_pta_cal_busy) tick();
    dut->i_start = 1; tick();
    dut->i_start = 0;

    uint64_t n = 0;
    int rows = 1;
    while (!dut->o_done) {
        if (gap > 0 && rows < M && (n % static_cast<uint64_t>(gap)) == 0)
            dut->i_a_rows_ready = ++rows;
        tick();
        if (++n > 4'000'000ull) {
            fprintf(stderr, "[timeout] M=%d N=%d K=%d gap=%d after %llu cycles:"
                            " busy=%d cal_busy=%d cal_ct=%u rows=%d err=%d\n",
                    M, N, K, gap, static_cast<unsigned long long>(n), dut->o_busy,
                    dut->o_pta_cal_busy, dut->o_pta_cal_ct, rows, dut->o_pta_cal_err);
            exit(2);
        }
    }
    tick();
    dut->i_a_rows_ready = M;
    return n;
}

uint64_t run_streamed(int M, int N, int K, int width, int gap, const pta_cfg& pta) {
    std::vector<int> a(static_cast<size_t>(M) * K), b(static_cast<size_t>(K) * N);
    for (auto& x : a) x = rnd(width);
    for (auto& x : b) x = rnd(width);
    return run_raw(M, N, K, gap, a, b, pta);
}

// A read-back is an instrument, and needs a range where what it is reading lands
// a few codes up.  A GEMM's shift is set for its sums, and a cell's error is
// several thousand times smaller: at DIN_W 16 it is under one ADC code there, so
// every read-back would come back zero.  The shift below puts a drift at its
// clamp a handful of codes up at either width -- the same argument as the probe's
// auto-ranging, and the same reason.  (That the figure depends on the operand
// width at all is the design note's open question 2: drift is quoted in weight
// LSB, which do not scale with DIN_W.)
pta_cfg read_cfg(const pta_cfg& cfg, int amp_log2) {
    pta_cfg c = cfg;
    c.adc_shift = static_cast<uint32_t>(amp_log2 + 2);
    return c;
}

// The tile read back a cell at a time: zero weights and one activation at
// `amp`, so C[r][n] is what cell (r, n) still carries -- its programming error,
// its drift and its trim, through the ADC.  The zeroing redraws the programming
// error, which no trim can anticipate, so this measure has a floor; what it
// compares fairly is one tile against another.
std::vector<int32_t> read_cells_raw(int amp, const pta_cfg& pta) {
    std::vector<int> a(static_cast<size_t>(NUM_ROWS) * NUM_ROWS, 0),
                     b(static_cast<size_t>(NUM_ROWS) * NUM_COLS, 0);
    for (int r = 0; r < NUM_ROWS; ++r) a[r * NUM_ROWS + r] = amp;
    run_raw(NUM_ROWS, NUM_COLS, NUM_ROWS, 0, a, b, pta);
    return read_c(NUM_ROWS, NUM_COLS);
}

// The same, with the model told: run_case holds the RTL to pta_gemm(), so every
// cell's trim is checked separately.
std::vector<int32_t> read_cells(int width, int amp, const pta_cfg& pta, bool* match) {
    std::vector<int> a(static_cast<size_t>(NUM_ROWS) * NUM_ROWS, 0),
                     b(static_cast<size_t>(NUM_ROWS) * NUM_COLS, 0);
    for (int r = 0; r < NUM_ROWS; ++r) a[r * NUM_ROWS + r] = amp;
    const Result res = run_case(NUM_ROWS, NUM_COLS, NUM_ROWS, width, false, ActCfg{}, pta,
                                &a, &b);
    if (match) *match = res.ok && static_cast<long>(res.pta_sats) == res.model_pta_sats;
    return read_c(NUM_ROWS, NUM_COLS);
}

double mean_abs(const std::vector<int32_t>& v) {
    double s = 0;
    for (int32_t x : v) s += x < 0 ? -static_cast<double>(x) : static_cast<double>(x);
    return v.empty() ? 0.0 : s / static_cast<double>(v.size());
}

void reset() {
    dut->i_rst_n = 0;
    dut->i_wen = 0; dut->i_wsel = 0; dut->i_waddr = 0; dut->i_wdata = 0;
    dut->i_staging_wen = 0; dut->i_staging_wsel = 0;
    dut->i_staging_waddr = 0; dut->i_staging_wdata = 0;
    dut->i_bank_sel = 0; dut->i_wbank = 0;
    dut->i_start = 0; dut->i_precision = 0; dut->i_c_raddr = 0;
    dut->i_a_rows_ready = 0;
    dut->i_abort = 0;
    dut->i_wwen = 0; dut->i_wwsel = 0; dut->i_wwbank = 0;
    dut->i_wwmask = 0; dut->i_wwaddr = 0; zero(dut->i_wwdata);
    dut->i_act_tbl_wen = 0; dut->i_act_tbl_waddr = 0; dut->i_act_tbl_wdata = 0;
    apply_act(ActCfg{});
    apply_pta(PTA_OFF);
    apply_cal(CalCfg{});
    dut->i_pta_model_rst = 0;
    dut->i_pta_cal_now   = 0;
    dut->i_pta_cal_rst   = 0;
    dut->i_pta_trim_wen  = 0;
    dut->i_pta_trim_bank = 0;
    dut->i_pta_trim_row  = 0;
    dut->i_pta_trim_col  = 0;
    dut->i_pta_trim_data = 0;
    dut->i_pta_aff_wen   = 0;
    dut->i_pta_aff_col   = 0;
    dut->i_pta_aff_gain  = 256;
    dut->i_pta_aff_offs  = 0;
    for (int i = 0; i < 4; ++i) tick();
    dut->i_rst_n = 1;
    for (int i = 0; i < 2; ++i) tick();
}

// Gate A2's operating point.  Fixed, so a run is reproducible; varied by case,
// so every path through stage 6 and the constant-sigma path are covered.
ActCfg full_cfg(int case_idx) {
    // Detuning per physical column, s in (0, 1]: the input scale carries s and
    // the output factor carries 1/s, in the table's own units.
    static const double S[NUM_COLS] = {1.0, 0.9, 0.75, 0.6, 0.5, 0.95, 0.8, 0.7};
    // Every seventh case runs hot: 16x the input gain saturates stages 1 and 3
    // on large sums, and a 10-bit output shift saturates stage 6.
    const bool hot = (case_idx % 7) == 6;
    ActCfg c;
    c.en          = true;
    c.xshift      = hot ? 4 : 8;                   // x ~ 16 * s * acc, or 256 * s * acc
    c.k_shot      = 0x4000;                        // 64.0: a few percent of the knee
    c.seed        = 0x2545F491u ^ static_cast<uint32_t>(case_idx);
    c.requant     = (case_idx % 2) == 0;
    c.adc_bits    = 6;
    c.noise_const = (case_idx % 5) == 3;
    c.yshift      = hot ? 10 : 0;
    for (int j = 0; j < NUM_COLS; ++j) {
        c.xs[j] = static_cast<uint32_t>(16.0 * 256.0 * S[j] + 0.5);
        c.r[j]  = static_cast<uint16_t>(4096.0 / S[j] + 0.5);
    }
    return c;
}

// Gates P1-P6's operating points.  S sits where an 8-bit ADC spans a K tile's
// typical sums (about 2^15 at DIN_W 8, 2^31 at 16); every fifth case runs S
// four bits hotter so the ADC saturates, and one case's seed makes the THERMAL
// stream's seed ^ K zero, the reload's special case.  Drift steps every 1, 2, 4
// or 8 shots, and its fifth-case clamp is tight enough to bind.
pta_cfg pta_gate_cfg(const std::string& mode, int idx, int dw) {
    const uint32_t base = dw == 8 ? 8 : 24;
    const bool     hot  = (idx % 5) == 4;
    const bool     odd  = (idx % 2) == 1;
    pta_cfg c = {};
    c.seed      = (idx == 5) ? 0x9E3779B9u : (0x1234567u ^ (static_cast<uint32_t>(idx) * 0x9E3779B1u));
    c.adc_shift = hot ? base - 4 : base;
    if (mode == "quant") {
        c.impair = PTA_QUANT;
        switch (idx % 4) {
        case 0:  c.act_bits = dw - 2; c.w_bits = dw - 2; c.adc_bits = 8; break;
        case 1:  c.act_bits = 4;      c.w_bits = 4;      c.adc_bits = 6; c.adc_shift += 1; break;
        case 2:  c.act_bits = 0;      c.w_bits = dw - 1; c.adc_bits = 0; c.adc_shift = 0; break;
        default: c.act_bits = dw;     c.w_bits = 0;      c.adc_bits = 4; break;
        }
    } else if (mode == "thermal") {
        c.impair   = PTA_THERMAL | (odd ? PTA_QUANT : 0u);
        c.sigma_th = odd ? 0x0280 : 0x0060;                 // 2.5 or 0.375 LSB
    } else if (mode == "shot") {
        c.impair = PTA_SHOT | (odd ? PTA_QUANT : 0u);
        c.k_shot = odd ? 0x0200 : 0x0040;                   // k = 2.0 or 0.25
    } else if (mode == "prog") {
        c.impair   = PTA_PROG_ERR | (odd ? PTA_QUANT : 0u);
        c.sigma_pr = odd ? 0x0300 : 0x0080;                 // 3.0 or 0.5 weight LSB
    } else if (mode == "drift") {
        c.impair      = PTA_DRIFT | (odd ? (PTA_QUANT | PTA_PROG_ERR) : 0u);
        c.sigma_pr    = 0x0100;
        c.drift_sigma = odd ? 0x0200 : 0x0080;              // 2.0 or 0.5 weight LSB a step
        c.drift_log2  = static_cast<uint32_t>(idx % 4);
        c.drift_max   = hot ? 0x0100 : 0x0600;              // 1 or 6 weight LSB
        if (idx == 4) c.impair = PTA_QUANT | PTA_PROG_ERR;  // drift held: not applied, not stepped
    } else if (mode == "xtalk") {
        c.impair      = PTA_XTALK | (odd ? (PTA_QUANT | PTA_DRIFT) : 0u);
        c.xtalk       = odd ? 0x60 : 0x20;                  // chi 0.375 or 0.125
        c.drift_sigma = 0x0100;
        c.drift_log2  = 2;
        c.drift_max   = 0x0400;
    } else {  // all
        c.impair      = PTA_QUANT | PTA_THERMAL | PTA_SHOT | PTA_DRIFT | PTA_XTALK | PTA_PROG_ERR;
        c.sigma_th    = 0x0180;
        c.k_shot      = 0x0080;
        c.sigma_pr    = 0x0100;
        c.drift_sigma = 0x0100;
        c.drift_log2  = 1;
        c.drift_max   = 0x0400;
        c.xtalk       = 0x40;
    }
    if (c.impair & PTA_QUANT) {
        if (mode != "quant") { c.act_bits = dw - 2; c.w_bits = dw - 3; c.adc_bits = 7; }
    }
    return c;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vc930_npu_core;

    // DIN_W is a compile-time parameter of the DUT, so it cannot be varied at
    // run time: build a second model with -GDIN_W=16 and pass --dw 16 to match.
    // Passing a width the model was not built for silently truncates operands.
    bool sweep = false;
    int  dw    = 8;
    std::string act_mode = "off", table_path;
    std::string pta_mode = "off", tile = "array";
    int  perturb = -1;
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        if (arg == "--sweep") sweep = true;
        else if (arg == "--dw" && i + 1 < argc) dw = std::atoi(argv[++i]);
        else if (arg == "--act" && i + 1 < argc) act_mode = argv[++i];
        else if (arg == "--table" && i + 1 < argc) table_path = argv[++i];
        else if (arg == "--perturb" && i + 1 < argc) perturb = std::atoi(argv[++i]);
        else if (arg == "--pta" && i + 1 < argc) pta_mode = argv[++i];
        else if (arg == "--tile" && i + 1 < argc) tile = argv[++i];
    }
    const bool pta_gate = pta_mode == "quant" || pta_mode == "thermal" || pta_mode == "shot" ||
                          pta_mode == "prog" || pta_mode == "drift" || pta_mode == "xtalk" ||
                          pta_mode == "all";
    const bool pta_cal = pta_mode == "trim" || pta_mode == "engine" || pta_mode == "sched";
    if (!(pta_mode == "off" || pta_gate || pta_cal || pta_mode == "directed" ||
          pta_mode == "refuse") || !(tile == "array" || tile == "ptm_c")) {
        fprintf(stderr, "--pta must be off, directed, quant, thermal, shot, prog, drift, xtalk,"
                        " all, refuse, trim, engine or sched; --tile array or ptm_c\n");
        return 2;
    }
    if (pta_mode != "off" && pta_mode != "refuse" && tile != "ptm_c") {
        fprintf(stderr, "--pta %s needs a PTM-C build (--tile ptm_c)\n", pta_mode.c_str());
        return 2;
    }
    if (act_mode != "off" && act_mode != "identity" && act_mode != "full") {
        fprintf(stderr, "--act must be off, identity or full\n");
        return 2;
    }
    if (act_mode == "full" && table_path.empty()) {
        fprintf(stderr, "--act full needs --table\n");
        return 2;
    }

    reset();
    {
        const pta_tile t = {NUM_ROWS, NUM_COLS, dw, 48};
        if (pta_device_init(&g_dev, &t) != 0) { fprintf(stderr, "out of memory\n"); return 2; }
    }

    if (act_mode != "off") {
        if (table_path.empty()) identity_table();
        else if (!load_table(table_path)) return 2;
        write_table(perturb);
    }

    int failures = 0;

    const struct { int M, N, K; } cases[] = {
        {64, 8, 256}, {64, 8, 64}, {32, 8, 128}, {16, 8, 64},
        {8, 8, 32},   {1, 1, 1},   {7, 5, 13},   {64, 8, 8},
        // multi-N-tile cases (need a model built with -GMAX_N=12)
        {8, 12, 16},  {8, 12, 8},   {3, 12, 2},   {5, 11, 8},
        {1, 12, 16},  {8, 9, 16},
    };

    if (pta_mode == "directed") {
        // The contract's rounding, pinned by values worked out by hand from
        // doc/pta_error_model_design_note.md section 4 -- not by pta_gemm(),
        // which run_case then holds the RTL to.  Operands at half-LSB
        // boundaries either side of zero and at both extremes.
        const int mx = (1 << (dw - 1)) - 1, mn = -(1 << (dw - 1));
        const pta_tile tile = {NUM_ROWS, NUM_COLS, dw, 48};
        struct Directed {
            const char* what;
            int M, N, K;
            std::vector<int> a, b;
            pta_cfg cfg;
            std::vector<int64_t> want;
            long want_sats;
        };
        pta_cfg q_act = {};  q_act.impair = PTA_QUANT; q_act.act_bits = dw - 4; q_act.seed = 1;
        pta_cfg q_w   = {};  q_w.impair   = PTA_QUANT; q_w.w_bits     = dw - 4; q_w.seed   = 1;
        pta_cfg q_adc = {};  q_adc.impair = PTA_QUANT; q_adc.adc_bits = 4; q_adc.adc_shift = 2;
        q_adc.seed = 1;
        const std::vector<Directed> cases_d = {
            // q(x, D-4): h = 4, so (x + 8) >>> 4, clamped to [-8, 7], times 16
            {"activation quantiser", 6, 1, 1, {8, 7, -8, -9, mx, mn}, {1}, q_act,
             {16, 0, 0, -16, mx + 1 - 16, mn}, 0},
            {"weight quantiser", 1, 6, 1, {1}, {8, 7, -8, -9, mx, mn}, q_w,
             {16, 0, 0, -16, mx + 1 - 16, mn}, 0},
            // B_adc 4, S 2: floor((a + 2) / 4), clamped to [-8, 7], times 4
            {"ADC", 6, 1, 1, {2, 1, -2, -3, mx, mn}, {1}, q_adc,
             {4, 0, 0, -4, 28, -32}, 2},
        };
        for (const auto& d : cases_d) {
            std::vector<int32_t> A(d.a.begin(), d.a.end()), B(d.b.begin(), d.b.end());
            std::vector<int64_t> C(static_cast<size_t>(d.M) * d.N);
            const long sats = pta_gemm(&d.cfg, &tile, &g_dev, 0, d.M, d.N, d.K, A.data(), B.data(),
                                       C.data());
            const bool model_ok = C == d.want && sats == d.want_sats;
            const Result r = run_case(d.M, d.N, d.K, dw, false, ActCfg{}, d.cfg, &d.a, &d.b);
            const bool ok = model_ok && r.ok && static_cast<long>(r.pta_sats) == d.want_sats;
            printf("[PD] %-22s model %s, RTL %s, saturations %u (want %ld)  %s\n", d.what,
                   model_ok ? "matches hand values" : "DIFFERS from hand values",
                   r.ok ? "matches model" : "DIFFERS from model", r.pta_sats, d.want_sats,
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        }

        // Crosstalk at chi = 0.5, two rows with weights 10 and 20 and
        // activations 1: row 0's input sees 10 + 0.5*20 = 20 and row 1's
        // 20 + 0.5*10 = 25, so C = 45 where the exact sum is 30.
        pta_cfg xt = {};
        xt.impair = PTA_XTALK; xt.xtalk = 0x80; xt.seed = 1;
        const std::vector<int> xa = {1, 1}, xb = {10, 20};
        auto xtalk_case = [&](const char* what) {
            std::vector<int32_t> A(xa.begin(), xa.end()), B(xb.begin(), xb.end());
            std::vector<int64_t> C(1);
            pta_gemm(&xt, &tile, &g_dev, 0, 1, 1, 2, A.data(), B.data(), C.data());
            const Result r = run_case(1, 1, 2, dw, false, ActCfg{}, xt, &xa, &xb);
            const bool ok = C[0] == 45 && r.ok;
            printf("[PD] %-22s model C = %lld (want 45), RTL %s  %s\n", what,
                   static_cast<long long>(C[0]), r.ok ? "matches model" : "DIFFERS from model",
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        };
        xtalk_case("crosstalk");
        // Leave 100 in row 2 from a K = 3 GEMM, then repeat.  Row 2 lies
        // outside the K tile, so it must not couple: if it did, row 1 would see
        // 20 + 0.5*(10 + 100) = 75 and C would be 95.
        {
            const std::vector<int> a3 = {0, 0, 0}, b3 = {10, 20, 100};
            const Result r3 = run_case(1, 1, 3, dw, false, ActCfg{}, xt, &a3, &b3);
            if (!r3.ok) ++failures;
        }
        xtalk_case("crosstalk, stale row");

        // Drift, on one shape: weight 0 and activation 1 everywhere, so each
        // result is its cell's drift, rounded to a weight LSB.
        const int dM = 16, dN = 8, dK = 1;
        const std::vector<int> da(static_cast<size_t>(dM) * dK, 1), db(static_cast<size_t>(dK) * dN, 0);
        pta_cfg dr = {};
        dr.impair = PTA_DRIFT; dr.seed = 3;
        dr.drift_sigma = 0xFFFF;      // 256 weight LSB a step
        dr.drift_max   = 0x0100;      // clamp at 1 weight LSB
        auto drift_case = [&](const char* what, int log2, uint32_t sigma,
                              int want_nonzero_min, int want_nonzero_max,
                              const std::vector<int32_t>* same_as) {
            dr.drift_log2 = log2; dr.drift_sigma = sigma;
            const Result r = run_case(dM, dN, dK, dw, false, ActCfg{}, dr, &da, &db);
            const std::vector<int32_t> c = read_c(dM, dN);
            int nonzero = 0, out_of_bound = 0;
            for (int32_t v : c) { if (v != 0) ++nonzero; if (v < -1 || v > 1) ++out_of_bound; }
            // Held drift: every shot sees the drift the last GEMM ended with,
            // so every row equals that GEMM's last row.
            bool held = true;
            if (same_as)
                for (int m = 0; m < dM; ++m)
                    for (int n = 0; n < dN; ++n)
                        if (c[m * dN + n] != (*same_as)[n]) held = false;
            const bool ok = r.ok && out_of_bound == 0 && held &&
                            nonzero >= want_nonzero_min && nonzero <= want_nonzero_max;
            printf("[PD] %-22s RTL %s, %d of %d results off zero, %d past the bound%s  %s\n", what,
                   r.ok ? "matches model" : "DIFFERS from model", nonzero, dM * dN, out_of_bound,
                   same_as ? (held ? ", unchanged" : ", CHANGED") : "", ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
            return c;
        };
        model_reset(0x0D1F7u);
        // From a reset, drift is zero until its clock first fills: 16 shots, a
        // step every 32.
        drift_case("drift, before a step", 5, 0xFFFF, 0, 0, nullptr);
        // A step every shot at 256 LSB: nearly every cell pinned at +-1 LSB.
        const std::vector<int32_t> pinned = drift_case("drift, at its bound", 0, 0xFFFF,
                                                       dM * dN * 9 / 10, dM * dN, nullptr);
        const std::vector<int32_t> last(pinned.end() - dN, pinned.end());
        // Sigma 0: the clock and the generator still run, but nothing moves.
        drift_case("drift, held", 0, 0, dM * dN * 9 / 10, dM * dN, &last);
        model_reset(0x0D1F7u);
        drift_case("drift, after a reset", 5, 0xFFFF, 0, 0, nullptr);
    } else if (pta_gate) {
        int idx = 0;
        int moved_cases = 0;
        model_reset(0x5EED0001u);
        for (auto& c : cases) {
            if (pta_mode == "drift" && idx == 6) g_busy_rst_at = 40;          // ignored
            if (pta_mode == "drift" && idx == 9) model_reset(0x5EED0009u);    // honoured
            const pta_cfg cfg = pta_gate_cfg(pta_mode, idx++, dw);
            const Result r = run_case(c.M, c.N, c.K, dw, false, ActCfg{}, cfg);
            const bool ok = r.ok && static_cast<long>(r.pta_sats) == r.model_pta_sats;
            if (r.changed > 0) ++moved_cases;
            printf("[P-%s] M=%-3d N=%-2d K=%-4d impair=0x%02x bits=%u/%u/%u S=%-2u"
                   " moved=%-5d sats=%u (model %ld)  %s\n",
                   pta_mode.c_str(), c.M, c.N, c.K, cfg.impair, cfg.act_bits, cfg.w_bits,
                   cfg.adc_bits, cfg.adc_shift, r.changed, r.pta_sats, r.model_pta_sats,
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        }
        // An impairment that moves nothing is not being tested.
        const bool moved = moved_cases >= 12;
        printf("[P-%s] %d of 14 shapes moved off their exact sums  %s\n", pta_mode.c_str(),
               moved_cases, moved ? "PASS" : "FAIL");
        if (!moved) ++failures;
    } else if (pta_mode == "trim") {
        // Gate P7: the two correction paths.
        CalCfg cal;
        cal.trim_log2 = 2;                 // the DAC's step: a quarter of a 6-bit code
        cal.trim_max  = 16;                // and a clamp the directed case can reach
        apply_cal(cal);
        pta_cfg dac = {};
        dac.trim_step = 1u << cal.trim_log2;
        dac.trim_max  = cal.trim_max;

        model_reset(0x5EED0007u);
        cal_reset();

        // Every width zero leaves the quantisers as identities and the ADC
        // unquantised, so a column is (y + 128) >> 8 and nothing else: the
        // directed values below are the contract's arithmetic, not pta_gemm's.
        pta_cfg plain = {};
        plain.impair = PTA_QUANT;
        plain.seed   = 1;
        plain.trim_step = dac.trim_step;
        plain.trim_max  = dac.trim_max;

        // (1) The DAC's step and clamp.  Eight rows of activation 127 against
        // zero weights, so C[0][n] = (1016 * stored_n + 128) >>> 8, where
        // stored_n is what a DAC of step 4 and clamp 16 took.
        {
            const int64_t req[NUM_COLS]  = {6, -6, 5, 2, 1, 100, -100, 0};
            const int64_t want[NUM_COLS] = {32, -32, 16, 16, 0, 64, -63, 0};
            std::vector<int> a(NUM_ROWS, 127), b(NUM_ROWS * NUM_COLS, 0);
            for (int r = 0; r < NUM_ROWS; ++r)
                for (int c = 0; c < NUM_COLS; ++c)
                    write_trim(dac, 0, r, c, req[c]);
            const Result r0 = run_case(1, NUM_COLS, NUM_ROWS, dw, false, ActCfg{}, plain,
                                       &a, &b);
            const std::vector<int32_t> got = read_c(1, NUM_COLS);
            bool hand = true;
            for (int c = 0; c < NUM_COLS; ++c)
                if (got[c] != static_cast<int32_t>(want[c])) hand = false;
            const bool ok = hand && r0.ok;
            printf("[P7] %-24s RTL %s, model %s  %s\n", "trim through the DAC",
                   hand ? "matches hand values" : "DIFFERS from hand values",
                   r0.ok ? "agrees" : "DIFFERS", ok ? "PASS" : "FAIL");
            if (!ok) {
                for (int c = 0; c < NUM_COLS; ++c)
                    printf("       col %d: asked %4lld, C = %5d (want %lld)\n", c,
                           static_cast<long long>(req[c]), got[c],
                           static_cast<long long>(want[c]));
                ++failures;
            }
        }

        // A clamp that the patterns below do not spend their whole range against.
        cal.trim_max  = 0x1000;            // 16 weight LSB
        dac.trim_max  = cal.trim_max;
        plain.trim_max = cal.trim_max;
        apply_cal(cal);

        // (2) The affine's rounding, on hand values: out 10 and -10 through
        // four gains and offsets, with the contract's round-half-up.
        {
            cal_reset();
            const int32_t gains[4] = {384, 128, 256, 0};
            const int32_t offs[4]  = {7, 0, -3, 4};
            for (int c = 0; c < 4; ++c) write_affine(c, gains[c], offs[c]);
            const std::vector<int> a = {10, -10}, b = {1, 1, 1, 1};
            const int64_t want[8] = {22, 5, 7, 4, -8, -5, -13, 4};
            const Result r1 = run_case(2, 4, 1, dw, false, ActCfg{}, plain, &a, &b);
            const std::vector<int32_t> got = read_c(2, 4);
            bool hand = true;
            for (int i = 0; i < 8; ++i)
                if (got[i] != static_cast<int32_t>(want[i])) hand = false;
            const bool ok = hand && r1.ok;
            printf("[P7] %-24s RTL %s, model %s  %s\n", "column affine",
                   hand ? "matches hand values" : "DIFFERS from hand values",
                   r1.ok ? "agrees" : "DIFFERS", ok ? "PASS" : "FAIL");
            if (!ok) {
                for (int i = 0; i < 8; ++i)
                    printf("       [%d][%d] C = %5d (want %lld)\n", i / 4, i % 4, got[i],
                           static_cast<long long>(want[i]));
                ++failures;
            }
        }

        // (3) A correction is a correction to the error model, so with every
        // impairment clear it must change nothing: P0 still holds with the
        // stores loaded.
        {
            for (int r = 0; r < NUM_ROWS; ++r)
                for (int c = 0; c < NUM_COLS; ++c)
                    write_trim(dac, 0, r, c, ((r * 37 + c * 53) % 601) - 300);
            for (int c = 0; c < NUM_COLS; ++c) write_affine(c, 200, 9);
            const Result off = run_case(8, 8, 32, dw, false, ActCfg{}, PTA_OFF);
            printf("[P7] %-24s %s  %s\n", "off is still exact",
                   off.ok ? "a loaded correction changes nothing"
                          : "the exact sum MOVED", off.ok ? "PASS" : "FAIL");
            if (!off.ok) ++failures;
        }

        // (4) Every shape, with every impairment and a correction of its own.
        {
            int idx = 0, moved_cases = 0;
            for (auto& cs : cases) {
                pta_cfg cfg = pta_gate_cfg("all", idx, dw);
                cfg.trim_step = dac.trim_step;
                cfg.trim_max  = dac.trim_max;
                for (int r = 0; r < NUM_ROWS; ++r)
                    for (int j = 0; j < NUM_COLS; ++j)
                        write_trim(dac, 0, r, j, ((r * 37 + j * 53 + idx * 11) % 601) - 300);
                for (int j = 0; j < NUM_COLS; ++j)
                    write_affine(j, 256 + ((j * 13 + idx * 7) % 97) - 48,
                                 ((j * 7 + idx) % 21) - 10);
                const Result r2 = run_case(cs.M, cs.N, cs.K, dw, false, ActCfg{}, cfg);
                const bool ok = r2.ok && static_cast<long>(r2.pta_sats) == r2.model_pta_sats;
                if (r2.changed > 0) ++moved_cases;
                printf("[P7] M=%-3d N=%-2d K=%-4d trim+affine loaded moved=%-5d sats=%u"
                       " (model %ld)  %s\n", cs.M, cs.N, cs.K, r2.changed, r2.pta_sats,
                       r2.model_pta_sats, ok ? "PASS" : "FAIL");
                if (!ok) ++failures;
                ++idx;
            }
            const bool moved = moved_cases >= 12;
            printf("[P7] %d of 14 shapes moved off their exact sums  %s\n", moved_cases,
                   moved ? "PASS" : "FAIL");
            if (!moved) ++failures;
        }
    } else if (pta_mode == "engine") {
        // Gate P8: the calibration engine against pta_cal_bank().
        const pta_tile tile = {NUM_ROWS, NUM_COLS, dw, 48};
        CalCfg cal;
        cal.en        = true;
        cal.sched     = 0;                 // CAL_NOW only
        cal.amp_log2  = static_cast<uint32_t>(dw - 2);
        cal.reps_log2 = 2;                 // four repeats: what C3(a) measured is enough
        cal.trim_log2 = 2;
        cal.trim_max  = 0x2000;
        cal.seed      = 0x00CA11B0u;
        apply_cal(cal);

        pta_cfg cfg = {};
        cfg.impair      = PTA_QUANT | PTA_PROG_ERR | PTA_DRIFT | PTA_XTALK;
        cfg.act_bits    = static_cast<uint32_t>(dw - 2);
        cfg.w_bits      = static_cast<uint32_t>(dw - 3);
        cfg.adc_bits    = 7;
        cfg.adc_shift   = dw == 8 ? 8 : 24;
        cfg.seed        = 0x42424242u;
        cfg.sigma_pr    = 0x0200;
        cfg.drift_sigma = 0x0180;
        cfg.drift_log2  = 1;
        cfg.drift_max   = 0x0C00;
        cfg.xtalk       = 0x20;
        cfg.trim_step   = 1u << cal.trim_log2;
        cfg.trim_max    = cal.trim_max;

        model_reset(0x5EED0008u);
        cal_reset();

        // Drift and programming error accumulate over a few GEMMs, in the RTL
        // and the model together.
        for (int i = 0; i < 3; ++i)
            if (!run_case(16, 8, 64, dw, false, ActCfg{}, cfg).ok) ++failures;

        bool before_ok = true;
        const pta_cfg rcfg = read_cfg(cfg, static_cast<int>(cal.amp_log2));
        const std::vector<int32_t> before = read_cells(dw, 1 << cal.amp_log2, rcfg,
                                                       &before_ok);
        if (!before_ok) ++failures;

        // Calibrate, in the RTL and the reference together.  The engine's
        // streams load from cal.seed mixed with the calibration's number, which
        // is what lets the reference reproduce the draws exactly.
        const uint32_t j    = dut->o_pta_cal_ct;
        const uint64_t busy = run_cal_now();
        pta_streams st;
        pta_start(&st, cal.seed ^ (j * 0x9E3779B1u));
        const pta_cal_cfg cc = {cal.amp_log2, cal.reps_log2, cal.passes};
        int     clamped = 0;
        long    sats    = 0;
        int64_t found   = -1;
        const int64_t resid = pta_cal_bank(&g_dev, &cfg, &tile, 0, &st, &cc, &sats, &clamped,
                                           &found);
        const bool r_ok = busy > 0 && dut->o_pta_cal_valid && dut->o_pta_cal_ct == j + 1 &&
                          static_cast<int64_t>(dut->o_pta_err_max) == resid &&
                          static_cast<int64_t>(dut->o_pta_err_found) == found &&
                          !dut->o_pta_cal_err;
        printf("[P8] %-24s %llu cycles, found %u (model %lld), left %u (model %lld),"
               " CAL_CT %u, valid %d, err %d  %s\n", "one calibration",
               static_cast<unsigned long long>(busy), dut->o_pta_err_found,
               static_cast<long long>(found), dut->o_pta_err_max,
               static_cast<long long>(resid), dut->o_pta_cal_ct, dut->o_pta_cal_valid,
               dut->o_pta_cal_err, r_ok ? "PASS" : "FAIL");
        if (!r_ok) ++failures;

        // Every trim, one at a time: if any cell disagrees with the reference,
        // its column's readout does.
        bool after_ok = true;
        const std::vector<int32_t> after = read_cells(dw, 1 << cal.amp_log2, rcfg, &after_ok);
        printf("[P8] %-24s mean |cell| %.2f -> %.2f, every cell %s  %s\n",
               "the trims it wrote", mean_abs(before), mean_abs(after),
               after_ok ? "matches the reference" : "DIFFERS from the reference",
               after_ok ? "PASS" : "FAIL");
        if (!after_ok) ++failures;

        // It has to have moved the tile, or nothing above is a test.  How far it
        // can move it is measured at the end of this gate, where a trim is up
        // against drift rather than an error redrawn at every weight write.
        const bool moved = mean_abs(after) < mean_abs(before);
        printf("[P8] %-24s mean |cell| %.2f against %.2f  %s\n", "the tile moved",
               mean_abs(after), mean_abs(before), moved ? "PASS" : "FAIL");
        if (!moved) ++failures;

        // Every shape still agrees with the model, now with the trims in place.
        {
            int bad = 0;
            for (auto& cs : cases) {
                const Result r = run_case(cs.M, cs.N, cs.K, dw, false, ActCfg{}, cfg);
                if (!(r.ok && static_cast<long>(r.pta_sats) == r.model_pta_sats)) {
                    printf("[P8] M=%-3d N=%-2d K=%-4d after calibration  FAIL\n",
                           cs.M, cs.N, cs.K);
                    ++bad;
                }
            }
            printf("[P8] %-24s 14 shapes against pta_gemm(), %d bad  %s\n",
                   "with trims loaded", bad, bad == 0 ? "PASS" : "FAIL");
            failures += bad;
        }

        // A START and a MODEL_RST that arrive during a calibration.  Neither may
        // be taken, and neither may be lost in silence.
        {
            cal_reset();
            const uint32_t jk = dut->o_pta_cal_ct;
            dut->i_pta_cal_now = 1; tick(); dut->i_pta_cal_now = 0;
            uint64_t w = 0;
            while (!dut->o_pta_cal_busy && w++ < 200) tick();
            const bool started = dut->o_pta_cal_busy;
            dut->i_dim_m = 4; dut->i_dim_n = 4; dut->i_dim_k = 4;
            dut->i_start = 1; dut->i_pta_model_rst = 1; tick();
            dut->i_start = 0; dut->i_pta_model_rst = 0;
            const bool no_busy = !dut->o_busy;
            while (dut->o_pta_cal_busy) tick();
            tick();
            // That calibration moved the tile -- shots fired, drift stepped --
            // so the reference has to run it too or the two part company here.
            pta_streams sk;
            pta_start(&sk, cal.seed ^ (jk * 0x9E3779B1u));
            pta_cal_bank(&g_dev, &cfg, &tile, 0, &sk, &cc, nullptr, nullptr, nullptr);
            const bool ok = started && no_busy && dut->o_pta_cal_err && !dut->o_busy;
            printf("[P8] %-24s cal ran %d, BUSY stayed %d, ERR %d  %s\n",
                   "START during a cal", started, !no_busy, dut->o_pta_cal_err,
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        }

        // A trim that cannot reach what the estimator asked for: DRIFT_ALARM,
        // and the reference says the same.
        {
            CalCfg tight = cal;
            tight.trim_max = 0x0040;       // a quarter of a weight LSB
            apply_cal(tight);
            cal_reset();
            pta_cfg tcfg = cfg;
            tcfg.trim_max = tight.trim_max;
            const uint32_t j2 = dut->o_pta_cal_ct;
            run_cal_now();
            pta_streams st2;
            pta_start(&st2, tight.seed ^ (j2 * 0x9E3779B1u));
            int cl = 0;
            long s2 = 0;
            const int64_t r2 = pta_cal_bank(&g_dev, &tcfg, &tile, 0, &st2, &cc, &s2, &cl,
                                            nullptr);
            const bool ok = dut->o_pta_drift_alarm == (cl != 0) && cl != 0 &&
                            static_cast<int64_t>(dut->o_pta_err_max) == r2;
            printf("[P8] %-24s alarm %d, reference %d, residual %u (model %lld)  %s\n",
                   "a trim at its clamp", dut->o_pta_drift_alarm, cl, dut->o_pta_err_max,
                   static_cast<long long>(r2), ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
            apply_cal(cal);
        }

        // An amplitude the probe cannot read back through the quantiser.
        {
            cal_reset();
            CalCfg bad = cal;
            bad.amp_log2 = static_cast<uint32_t>(dw - 1);
            apply_cal(bad);
            const uint32_t ct = dut->o_pta_cal_ct;
            run_cal_now();
            const pta_cal_cfg bc = {bad.amp_log2, bad.reps_log2, bad.passes};
            pta_streams st3;
            pta_start(&st3, bad.seed);
            const int64_t ref = pta_cal_bank(&g_dev, &cfg, &tile, 0, &st3, &bc, nullptr,
                                             nullptr, nullptr);
            const bool ok = !dut->o_pta_cal_valid && dut->o_pta_cal_err &&
                            dut->o_pta_cal_ct == ct && ref < 0;
            printf("[P8] %-24s refused %d, CAL_CT %u (was %u), reference %lld  %s\n",
                   "an unreadable amplitude", dut->o_pta_cal_err ? 1 : 0,
                   dut->o_pta_cal_ct, ct, static_cast<long long>(ref),
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
            apply_cal(cal);
        }

        // What the trim is for: drift, which stays where it is until something
        // takes it away.  With the programming error off, what the probe
        // measures is what a trim can hold, and the residual should collapse.
        // (With it on, every weight write redraws it, and the floor that leaves
        // is what the sub-tests above measure against.)
        {
            pta_cfg d = cfg;
            d.impair     = PTA_QUANT | PTA_DRIFT | PTA_XTALK;
            d.sigma_pr   = 0;
            d.drift_log2 = 0;              // a step a shot: drift in a hurry
            model_reset(0x5EED0088u);
            cal_reset();
            for (int i = 0; i < 3; ++i)
                if (!run_case(16, 8, 64, dw, false, ActCfg{}, d).ok) ++failures;
            // And now hold it still, as the fitted rate does: one step every
            // 2^20 shots, where a calibration is 96 of them.  A tile that
            // drifts faster than it can be measured cannot be calibrated, and
            // saying so is not the same as measuring the trim.
            d.drift_log2 = 20;
            bool m0 = true, m1 = true;
            const pta_cfg dr = read_cfg(d, static_cast<int>(cal.amp_log2));
            const std::vector<int32_t> pre = read_cells(dw, 1 << cal.amp_log2, dr, &m0);
            const uint32_t jd = dut->o_pta_cal_ct;
            run_cal_now();
            pta_streams sd;
            pta_start(&sd, cal.seed ^ (jd * 0x9E3779B1u));
            int64_t fd = -1;
            const int64_t rd = pta_cal_bank(&g_dev, &d, &tile, 0, &sd, &cc, nullptr, nullptr,
                                            &fd);
            const std::vector<int32_t> post = read_cells(dw, 1 << cal.amp_log2, dr, &m1);
            const double a0 = mean_abs(pre), a1 = mean_abs(post);
            const bool ok = m0 && m1 && static_cast<int64_t>(dut->o_pta_err_max) == rd &&
                            static_cast<int64_t>(dut->o_pta_err_found) == fd &&
                            a1 * 4.0 < a0;
            printf("[P8] %-24s mean |cell| %.2f -> %.2f, found %u (model %lld), left %u"
                   " (model %lld), parity %s  %s\n", "recovery from drift", a0, a1,
                   dut->o_pta_err_found, static_cast<long long>(fd), dut->o_pta_err_max,
                   static_cast<long long>(rd), (m0 && m1) ? "holds" : "BROKEN",
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        }
    } else if (pta_mode == "sched") {
        // Gate P9: the four schedulers, on the same work with the same operands
        // and the same A-row arrivals.  C3's gate is the last two columns: the
        // shadow scheduler has to cost less wall-clock than the periodic one
        // without giving up accuracy.
        pta_cfg cfg = {};
        // Drift only: a trim can take drift away, and the programming error
        // that is redrawn at every weight write would only set a floor under
        // the measurement (P8 measures against that floor separately).
        cfg.impair      = PTA_QUANT | PTA_DRIFT;
        cfg.act_bits    = static_cast<uint32_t>(dw - 2);
        cfg.w_bits      = static_cast<uint32_t>(dw - 3);
        cfg.adc_bits    = 7;
        cfg.adc_shift   = dw == 8 ? 8 : 24;
        cfg.seed        = 0x1234567u;
        cfg.sigma_pr    = 0;
        cfg.drift_sigma = 0x0200;
        cfg.drift_log2  = 4;               // a step every 16 shots: drift that bites
        cfg.drift_max   = 0x1800;

        struct Sched { const char* what; uint32_t mode; uint32_t per; uint32_t thr; };
        // The same minimum interval for all three, so what is being compared is
        // the policy and not the budget: the periodic scheduler takes every
        // 12,000 cycles, and the two that predict take no more than that and
        // only when the extrapolation asks for it.
        const Sched modes[] = {
            {"off",        0, 0,     0},
            {"periodic",   1, 12000, 0},
            {"predictive", 2, 12000, 4000},
            {"shadow",     3, 12000, 4000},
        };
        struct Out { uint64_t cycles; uint32_t ct, cyc, err; double resid; };
        Out out[4] = {};
        int i = 0;
        for (const auto& s : modes) {
            CalCfg cal;
            cal.en        = s.mode != 0;
            cal.sched     = s.mode;
            cal.per       = s.per;
            cal.thr       = s.thr;
            cal.amp_log2  = static_cast<uint32_t>(dw - 2);
            cal.reps_log2 = 0;             // one probe a pass: 1,728 cycles all told
            cal.trim_log2 = 2;
            cal.trim_max  = 0x2000;
            cal.seed      = 0x00CA11B0u;

            reset();
            lfsr_state = 0xACE1u;          // the same operands for every mode
            model_reset(0x5EED0009u);      // and the same drift realisation
            apply_cal(cal);
            cal_reset();

            // A row every 1,200 cycles against 8 rows that take about 80 each:
            // the operand supply, not the tile, is the limit, which is what X2
            // says the chiplet's link does to it -- and it is what makes the
            // idle windows long enough for a calibration to hide inside one.
            uint64_t total = 0;
            for (int g = 0; g < 4; ++g)
                total += run_streamed(8, 8, 64, dw, 1200, cfg);

            CalCfg quiet = cal;
            quiet.en = false;
            apply_cal(quiet);              // no calibration inside the readout
            const std::vector<int32_t> cells =
                read_cells_raw(1 << cal.amp_log2, read_cfg(cfg, static_cast<int>(cal.amp_log2)));
            out[i++] = {total, dut->o_pta_cal_ct, dut->o_pta_cal_cyc, dut->o_pta_err_found,
                        mean_abs(cells)};
            fprintf(stderr, "  %s done: %llu cycles, %u calibrations\n", s.what,
                    static_cast<unsigned long long>(total), dut->o_pta_cal_ct);
        }

        for (int k = 0; k < 4; ++k)
            printf("[P9] %-11s cycles %-9llu calibrations %-3u cal cycles %-8u"
                   " last found %-6u mean |cell| %.2f\n", modes[k].what,
                   static_cast<unsigned long long>(out[k].cycles), out[k].ct, out[k].cyc,
                   out[k].err, out[k].resid);

        // Calibrating at all has to be worth it, or the comparison is empty.  The
        // two modes the CPU document's claim is between are gated; how often the
        // predictive one fires is PTA_CAL_THR's to decide, so it is reported.
        const bool worth = out[1].resid < out[0].resid * 0.75 &&
                           out[3].resid < out[0].resid * 0.75;
        printf("[P9] %-24s %.2f uncalibrated against %.2f periodic and %.2f shadow"
               " (predictive %.2f, at its own threshold)  %s\n",
               "calibration is worth it", out[0].resid, out[1].resid, out[3].resid,
               out[2].resid, worth ? "PASS" : "FAIL");
        if (!worth) ++failures;

        // C3's gate: less wall-clock than periodic, at the same accuracy.
        const bool cheaper = out[3].cycles < out[1].cycles;
        const bool as_good = out[3].resid <= out[1].resid * 1.5;
        printf("[P9] %-24s shadow %llu cycles against periodic %llu, left %.2f"
               " against %.2f  %s\n", "shadow costs less",
               static_cast<unsigned long long>(out[3].cycles),
               static_cast<unsigned long long>(out[1].cycles), out[3].resid, out[1].resid,
               (cheaper && as_good) ? "PASS" : "FAIL");
        if (!(cheaper && as_good)) ++failures;

        // And every scheduler has to have fired, or it was not tested.
        const bool fired = out[0].ct == 0 && out[1].ct > 0 && out[2].ct > 0 && out[3].ct > 0;
        printf("[P9] %-24s off %u, periodic %u, predictive %u, shadow %u  %s\n",
               "each scheduler fired", out[0].ct, out[1].ct, out[2].ct, out[3].ct,
               fired ? "PASS" : "FAIL");
        if (!fired) ++failures;
    } else if (pta_mode == "refuse") {
        auto refused = [&](const pta_cfg& cfg, int prec) {
            apply_pta(cfg);
            dut->i_precision = prec;
            dut->i_dim_m = 4; dut->i_dim_n = 4; dut->i_dim_k = 4;
            dut->i_start = 1; tick();
            dut->i_start = 0; tick();
            const bool r = dut->o_error && !dut->o_busy;
            dut->i_precision = 0;
            apply_pta(PTA_OFF);
            return r;
        };
        struct Bad { const char* what; uint32_t impair; int prec; uint32_t shift; };
        std::vector<Bad> bad;
        if (tile == "ptm_c") {
            bad = {{"MZM_NL, not built", PTA_MZM_NL, 0, 8},
                   {"QUANT with FP16", PTA_QUANT, 2, 8},
                   {"THERMAL with BF16", PTA_THERMAL, 3, 8},
                   {"DRIFT with FP16", PTA_DRIFT, 2, 8},
                   {"XTALK with BF16", PTA_XTALK, 3, 8},
                   {"QUANT with S = 41", PTA_QUANT, 0, 41}};
        } else {
            bad = {{"QUANT, digital array", PTA_QUANT, 0, 8},
                   {"THERMAL, digital array", PTA_THERMAL, 0, 8},
                   {"SHOT, digital array", PTA_SHOT, 0, 8},
                   {"PROG_ERR, digital array", PTA_PROG_ERR, 0, 8},
                   {"DRIFT, digital array", PTA_DRIFT, 0, 8},
                   {"XTALK, digital array", PTA_XTALK, 0, 8}};
        }
        for (const auto& b : bad) {
            pta_cfg cfg = {};
            cfg.impair = b.impair; cfg.adc_shift = b.shift; cfg.act_bits = dw - 2;
            cfg.seed = 7;
            const bool ref = refused(cfg, b.prec);
            // The next valid start clears the error.  A PTM-C build takes an
            // impaired GEMM at the boundary shift of 40; the array, an exact one.
            pta_cfg good = {};
            if (tile == "ptm_c") { good.impair = PTA_QUANT; good.adc_bits = 8; good.adc_shift = 40; good.seed = 7; }
            const Result after = run_case(4, 4, 4, dw, false, ActCfg{}, good);
            const bool ok = ref && after.ok && !dut->o_error;
            printf("[PR] %-24s %s, then a valid GEMM %s  %s\n", b.what,
                   ref ? "refused" : "NOT refused", after.ok ? "passes" : "fails",
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        }
    } else if (act_mode == "identity") {
        // Unit scales, no noise, no detuning, no requantisation: the table is
        // the only thing between acc and C.
        ActCfg id;
        id.en = true;
        id.seed = 1;
        for (int j = 0; j < NUM_COLS; ++j) { id.xs[j] = 1; id.r[j] = 4096; }
        for (auto& c : cases) {
            const Result off = run_case(c.M, c.N, c.K, dw, false, ActCfg{});
            const Result on  = run_case(c.M, c.N, c.K, dw, false, id);
            const int nt = (c.N + NUM_COLS - 1) / NUM_COLS;
            uint32_t act_cyc = 0;
            for (int n_base = 0; n_base < c.N; n_base += NUM_COLS)
                act_cyc += static_cast<uint32_t>(c.M * (std::min(NUM_COLS, c.N - n_base) + ACT_P));
            const bool cyc_ok = on.cycles == off.cycles + static_cast<uint32_t>(c.M * nt * ACT_P) &&
                                on.ops == off.ops && on.stall == off.stall &&
                                on.act_cycles == act_cyc &&
                                on.act_count == static_cast<uint32_t>(c.M * c.N) &&
                                on.act_sats == 0;
            const bool ok = off.ok && on.ok && cyc_ok;
            printf("[A1] M=%-3d N=%-2d K=%-4d cycles %u -> %u (+%u, want +%d) act_cycles=%u/%u"
                   " act=%u sats=%u  %s\n",
                   c.M, c.N, c.K, off.cycles, on.cycles, on.cycles - off.cycles,
                   c.M * nt * ACT_P, on.act_cycles, act_cyc, on.act_count, on.act_sats,
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        }

        // S_ACT with a float precision must refuse at start, like a bad
        // dimension: raise o_error and stay idle.  The next valid start clears it.
        for (int prec : {2, 3}) {
            apply_act(id);
            dut->i_precision = prec;
            dut->i_dim_m = 4; dut->i_dim_n = 4; dut->i_dim_k = 4;
            dut->i_start = 1; tick();
            dut->i_start = 0; tick();
            const bool refused = dut->o_error && !dut->o_busy;
            dut->i_precision = 0;
            const Result after = run_case(4, 4, 4, dw, false, id);
            const bool ok = refused && after.ok && !dut->o_error;
            printf("[A1] act_en with precision %d: %s, then a valid GEMM %s  %s\n", prec,
                   refused ? "refused" : "NOT refused", after.ok ? "passes" : "fails",
                   ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        }
    } else if (act_mode == "full") {
        int idx = 0;
        for (auto& c : cases) {
            const ActCfg cfg = full_cfg(idx++);
            const Result r = run_case(c.M, c.N, c.K, dw, false, cfg);
            const bool ok = r.ok && static_cast<int>(r.act_sats) == r.model_sats &&
                            r.act_count == static_cast<uint32_t>(c.M * c.N);
            printf("[A2] M=%-3d N=%-2d K=%-4d requant=%d noise_const=%d xshift=%d yshift=%-2d"
                   " act=%u changed=%d sats=%u (model %d)  %s\n",
                   c.M, c.N, c.K, cfg.requant, cfg.noise_const, cfg.xshift, cfg.yshift,
                   r.act_count, r.changed, r.act_sats, r.model_sats, ok ? "PASS" : "FAIL");
            if (!ok) ++failures;
        }
    } else if (!sweep) {
        for (auto& c : cases)
            if (!run_case(c.M, c.N, c.K, dw, true, ActCfg{}).ok) ++failures;
    } else {
        // The interesting axis is M: weight-load cost amortises over it.
        printf("M,N,K,cycles,ops,stall,useful_macs,pe_utilisation\n");
        for (int M : {1, 2, 4, 8, 16, 32, 64})
            for (int K : {8, 16, 32, 64, 128, 256}) {
                const int N = 8;
                Result r = run_case(M, N, K, dw, false, ActCfg{});
                if (!r.ok) ++failures;
                const double useful = static_cast<double>(M) * N * K;
                const double util   = useful /
                    (static_cast<double>(r.cycles) * NUM_ROWS * NUM_COLS);
                printf("%d,%d,%d,%u,%u,%u,%.0f,%.4f\n",
                       M, N, K, r.cycles, r.ops, r.stall, useful, util);
            }
    }

    dut->final();
    delete dut;
    pta_device_free(&g_dev);

    if (!sweep)
        printf(failures ? "[core] %d FAILURES\n" : "[core] all cases passed\n", failures);
    return failures ? 1 : 0;
}
