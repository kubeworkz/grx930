/*
 * GRX930 RISC-V 64 Startup Assembly
 * Sets up stack, calls main()
 *
 * Data/BSS initialization is done in C (simpler and more reliable).
 */

    .section .text.init
    .global _start_text

_start_text:
    /* Set up stack pointer */
    la      sp, _stack_end

    /* Jump to C startup (which clears BSS, copies data, calls main) */
    jal     startup_c

    /* If startup_c returns, loop forever */
3:
    wfi
    j       3b
