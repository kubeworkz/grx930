// Verilator harness for c930_npu_core.
//
// Drives the core's data-plane preload port directly, so it reaches the full
// MAX_M/MAX_K parameter space without the DMA or a memory model. Checks C
// against a software reference and reports the three performance counters.
// Same cases as tb/tb_core_m64.sv, several orders of magnitude faster, so a
// full M/N/K sweep is a few seconds rather than an overnight iverilog run.
//
//   verilator --cc --exe --build -O3 --top-module c930_npu_core -GMAX_N=12 \
//     -o tb_core_verilator sim/tb_core_verilator.cc <core RTL>
//   ./obj_dir/tb_core_verilator            # default case list
//   ./obj_dir/tb_core_verilator --sweep    # M/N/K sweep, CSV on stdout
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

#include "Vc930_npu_core.h"
#include "verilated.h"

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

struct Result {
    uint32_t cycles, ops, stall;
    uint32_t act_count, act_sats, act_cycles;
    int      model_sats;
    int      changed;     // elements S_ACT moved off their plain sum
    bool ok;
};

Result run_case(int M, int N, int K, int width, bool verbose, const ActCfg& act) {
    std::vector<int>     a(static_cast<size_t>(M) * K);
    std::vector<int>     b(static_cast<size_t>(K) * N);
    std::vector<int64_t> cref(static_cast<size_t>(M) * N, 0);

    for (int m = 0; m < M; ++m)
        for (int k = 0; k < K; ++k) {
            a[m * K + k] = rnd(width);
            preload(0, m * K + k, a[m * K + k]);
        }
    for (int k = 0; k < K; ++k)
        for (int n = 0; n < N; ++n) {
            b[k * N + n] = rnd(width);
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

    // A-row watermark: this harness writes all of A up front, so every row is
    // resident.  Zero would work too (the core reads 0 as "no watermark"), but
    // saying M exercises the comparison the DMA path actually drives.
    dut->i_a_rows_ready = M;
    dut->i_dim_m = M; dut->i_dim_n = N; dut->i_dim_k = K;
    dut->i_start = 1; tick();
    dut->i_start = 0;

    uint64_t guard = 0;
    while (!dut->o_done) {
        tick();
        if (++guard > 50'000'000ull) { fprintf(stderr, "timeout\n"); exit(2); }
    }
    tick();

    int changed = 0;
    for (size_t e = 0; e < cref.size(); ++e)
        if (static_cast<int32_t>(cexp[e]) != static_cast<int32_t>(cref[e])) ++changed;

    Result r{dut->o_cycle_count, dut->o_op_count, dut->o_stall_count,
             dut->o_act_count, dut->o_act_sat_count, dut->o_act_cycles, model_sats,
             changed, true};

    int errs = 0;
    for (int m = 0; m < M; ++m)
        for (int n = 0; n < N; ++n) {
            dut->i_c_raddr = m * N + n;
            dut->eval();
            const int32_t got = static_cast<int32_t>(dut->o_c_rdata);
            const int32_t exp = static_cast<int32_t>(cexp[m * N + n] & 0xffffffffll);
            if (got != exp) {
                if (errs < 5) {
                    if (act.en)
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
    dut->i_wwmask = 0; dut->i_wwaddr = 0; dut->i_wwdata = 0;
    dut->i_act_tbl_wen = 0; dut->i_act_tbl_waddr = 0; dut->i_act_tbl_wdata = 0;
    apply_act(ActCfg{});
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
    int  perturb = -1;
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        if (arg == "--sweep") sweep = true;
        else if (arg == "--dw" && i + 1 < argc) dw = std::atoi(argv[++i]);
        else if (arg == "--act" && i + 1 < argc) act_mode = argv[++i];
        else if (arg == "--table" && i + 1 < argc) table_path = argv[++i];
        else if (arg == "--perturb" && i + 1 < argc) perturb = std::atoi(argv[++i]);
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

    if (act_mode == "identity") {
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

    if (!sweep)
        printf(failures ? "[core] %d FAILURES\n" : "[core] all cases passed\n", failures);
    return failures ? 1 : 0;
}
