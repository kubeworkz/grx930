// ---------------------------------------------------------------------------
// start_bringup.S - minimal boot entry point for DDR3L bring-up firmware
//
// Placed at address 0x0000 (first instruction in DDR3L).
// Sets up the stack pointer and jumps to main().
// ---------------------------------------------------------------------------

    .section .text.startup, "ax", @progbits
    .global _start
    .type   _start, @function

_start:
    // Set up stack pointer (grows down from 0x8000)
    li   sp, 0x8000

    // Clear BSS (if any)
    la   t0, _bss_start
    la   t1, _bss_end
1:  bge  t0, t1, 2f
    sd   zero, 0(t0)
    addi t0, t0, 8
    j    1b
2:
    // Jump to main
    jal  ra, main

    // Infinite loop (should never return)
3:  j    3b
