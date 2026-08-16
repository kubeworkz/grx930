// -----------------------------------------------------------------------------
// start.S - bare-metal entry point for the RV64IMAC core.
//
// The core resets with PC = 0, so this must be linked first at address 0x0.
// It sets up a stack and jumps to main() (which never returns).
// -----------------------------------------------------------------------------
    .section .text.start, "ax"
    .globl _start
_start:
    li      sp, 0x8000          // 32 KB stack, grows down
    j       main                // main() never returns
