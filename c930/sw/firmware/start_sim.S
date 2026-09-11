/* -----------------------------------------------------------------------------
 * start_sim.S - entry point for the Verilator SoC simulation.
 *
 * The core resets with PC = 0 (DDR base).  The sim DDR model is 64 KB, so the
 * stack top is 0x8000 (32 KB stack growing down), matching the NPU test
 * convention.  Jumps to startup_c() which clears BSS and runs the echo loop.
 * -----------------------------------------------------------------------------
 */
    .section .text.init, "ax"
    .globl _start_text

_start_text:
    /* Set up stack pointer: top of the 32 KB sim stack */
    li      sp, 0x8000

    /* Jump to C startup (clears BSS, inits UART, runs echo loop) */
    jal     startup_c

    /* If startup_c returns, loop forever */
3:
    wfi
    j       3b