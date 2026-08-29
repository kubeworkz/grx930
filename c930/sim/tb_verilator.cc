// tb_verilator.cc - C930 SoC Verilator test harness
// Firmware is embedded in the DDR stub via initial block.
// This harness just clocks the design and checks NPU output signals.

#include <cstdio>
#include <cstdlib>
#include "Vc930_soc_verilator.h"
#include "verilated.h"

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vc930_soc_verilator *top = new Vc930_soc_verilator;

    printf("[TB] C930 SoC Verilator model starting\n");

    // Reset sequence
    top->i_rst_n = 0;
    top->i_clk = 0; top->eval();
    top->i_clk = 1; top->eval();
    for (int i = 0; i < 8; i++) {
        top->i_clk = 0; top->eval();
        top->i_clk = 1; top->eval();
    }
    top->i_rst_n = 1;
    printf("[TB] Reset released\n");
    fflush(stdout);

    // Run until NPU done or timeout
    int max_cycles = 5000000;
    int prev_npu_busy = 0;
    for (int i = 0; i < max_cycles; i++) {
        top->i_clk = 0; top->eval();
        top->i_clk = 1; top->eval();

        // Debug: report NPU state changes
        if (top->o_npu_busy != prev_npu_busy) {
            printf("[TB] cycle %d: NPU busy=%d done=%d\n",
                   i, top->o_npu_busy, top->o_npu_done);
            fflush(stdout);
            prev_npu_busy = top->o_npu_busy;
        }

        if (top->o_npu_done) {
            printf("[TB] NPU done at cycle %d\n", i);
            printf("[TB] NPU: busy=%d done=%d error=%d irq=%d\n",
                   top->o_npu_busy, top->o_npu_done,
                   top->o_npu_error, top->o_npu_irq);
            break;
        }
        if (i % 1000000 == 0 && i > 0) {
            printf("[TB] cycle %d: still running...\n", i);
            fflush(stdout);
        }
        if (i == max_cycles - 1) {
            printf("[TB] TIMEOUT at %d cycles\n", max_cycles);
            printf("[TB] NPU: busy=%d done=%d error=%d irq=%d\n",
                   top->o_npu_busy, top->o_npu_done,
                   top->o_npu_error, top->o_npu_irq);
            fflush(stdout);
        }
    }

    top->final();
    delete top;
    printf("[TB] Done\n");
    return 0;
}
