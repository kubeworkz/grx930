// Verilator harness for c930_npu_core.
//
// Drives the core's data-plane preload port directly, so it reaches the full
// MAX_M/MAX_K parameter space without the DMA or a memory model. Checks C
// against a software reference and reports the three performance counters.
// Same cases as tb/tb_core_m64.sv, several orders of magnitude faster, so a
// full M/N/K sweep is a few seconds rather than an overnight iverilog run.
//
//   verilator --cc --exe --build -O3 --top-module c930_npu_core \
//     -o tb_core_verilator sim/tb_core_verilator.cc <core RTL>
//   ./obj_dir/tb_core_verilator            # default case list
//   ./obj_dir/tb_core_verilator --sweep    # M/N/K sweep, CSV on stdout

#include "Vc930_npu_core.h"
#include "verilated.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <string>

namespace {

constexpr int NUM_ROWS = 8;
constexpr int NUM_COLS = 8;
constexpr int MAX_M    = 64;
constexpr int MAX_K    = 256;
constexpr int MAX_N    = 12;

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

struct Result {
    uint32_t cycles, ops, stall;
    bool ok;
};

Result run_case(int M, int N, int K, int width, bool verbose) {
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

    Result r{dut->o_cycle_count, dut->o_op_count, dut->o_stall_count, true};

    int errs = 0;
    for (int m = 0; m < M; ++m)
        for (int n = 0; n < N; ++n) {
            dut->i_c_raddr = m * N + n;
            dut->eval();
            const int32_t got = static_cast<int32_t>(dut->o_c_rdata);
            const int32_t exp = static_cast<int32_t>(cref[m * N + n] & 0xffffffffll);
            if (got != exp) {
                if (errs < 5)
                    printf("  [FAIL] C[%d][%d] = %d expected %d\n", m, n, got, exp);
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
    for (int i = 0; i < 4; ++i) tick();
    dut->i_rst_n = 1;
    for (int i = 0; i < 2; ++i) tick();
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
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        if (arg == "--sweep") sweep = true;
        else if (arg == "--dw" && i + 1 < argc) dw = std::atoi(argv[++i]);
    }

    reset();

    int failures = 0;

    if (!sweep) {
        const struct { int M, N, K; } cases[] = {
            {64, 8, 256}, {64, 8, 64}, {32, 8, 128}, {16, 8, 64},
            {8, 8, 32},   {1, 1, 1},   {7, 5, 13},   {64, 8, 8},
            // multi-N-tile cases (need a model built with -GMAX_N=12)
            {8, 12, 16},  {8, 12, 8},   {3, 12, 2},   {5, 11, 8},
            {1, 12, 16},  {8, 9, 16},
        };
        for (auto& c : cases)
            if (!run_case(c.M, c.N, c.K, dw, true).ok) ++failures;
    } else {
        // The interesting axis is M: weight-load cost amortises over it.
        printf("M,N,K,cycles,ops,stall,useful_macs,pe_utilisation\n");
        for (int M : {1, 2, 4, 8, 16, 32, 64})
            for (int K : {8, 16, 32, 64, 128, 256}) {
                const int N = 8;
                Result r = run_case(M, N, K, dw, false);
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
