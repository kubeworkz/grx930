/* mul_store_test.S - nine instructions that used to hang the c930's CPU.
 *
 * The M unit's booth and non-restoring datapaths present their result for
 * exactly one cycle, and their control FSM returns to IDLE on that pulse with
 * the instruction still in EX, so it starts the operation over.  A stall in
 * that one cycle therefore loses the result.  On its own that is only slow.
 * With a store in MEM it deadlocks: the hazard unit's stall_mem holds the store
 * while the M unit is busy, the held store re-requests the D-cache every time
 * it completes (a write-through, so it completes every nine cycles), and the
 * D-cache's stall freezes EX -- so the M unit's one-cycle window never lands on
 * an unstalled cycle.  Before rv64imac's result hold, a `mulw` two instructions
 * ahead of a `sw` spun for ever at a constant PC with the write channel busy.
 *
 * This found it: the same program with `addw` in place of `mulw` finished in
 * 184 cycles, and with `mulw` it ran 8 million without retiring one store.
 *
 * It checks the results too, not just that the machine moves: a lost-and-
 * recomputed multiply is invisible in a hang test, and the hold has to survive
 * back-to-back M instructions, which keep i_mul_div_en asserted across the
 * boundary and would otherwise hand the second the first one's result.
 *
 *   make mul_store        the reproducer: must finish and all five values right
 *   make mul_store NO_MUL=1   the control, with addw, which always passed
 */

        .section .text
        .globl _start

        .equ DONE_ADDR,   0x9410       /* 0xDEADBEEF when it gets to the end  */
        .equ RESULT_ADDR, 0x9420       /* the first multiply's product        */
        .equ REC_ADDR,    0x9430       /* the rest of them                    */
        .equ PHASE_ADDR,  0x9490       /* how far it got, if it did not finish */

_start:
        lui     sp, 0x8                /* sp = 0x8000                         */
        addi    sp, sp, -48            /* sp = 0x7fd0                         */
        li      a0, 4
        li      a1, 4

        /* The first touch of this line is a write MISS, so the D-cache fills
         * the line and then writes through -- a long stall, with the M
         * instruction behind it entering EX while the store sits in MEM. */
        sw      a0, 0(sp)

#ifdef NO_MUL
        addw    a0, a0, a1             /* the control: 4 + 4 = 8              */
#else
        mulw    a0, a0, a1             /* 4 * 4 = 16, finishing into a stall  */
#endif
        lui     a5, 0x1

        /* This is the store that spun: a write HIT in the line above, held in
         * MEM by the M unit's busy, re-issued every time it completed. */
        sw      a5, 12(sp)

        li      a4, PHASE_ADDR
        li      a5, 1
        sw      a5, 0(a4)              /* PHASE = 1: past the deadlock        */

        /* Back-to-back M instructions with stores between them, so the hold is
         * exercised where i_mul_div_en never falls. */
        li      a1, 3
#ifdef NO_MUL
        addw    a2, a0, a1             /* 8 + 3 = 11                          */
        addw    a3, a2, a1             /* 11 + 3 = 14                         */
#else
        mulw    a2, a0, a1             /* 16 * 3 = 48                         */
        mulw    a3, a2, a1             /* 48 * 3 = 144                        */
#endif
        sw      a2, 16(sp)
        sw      a3, 20(sp)

        /* The divider has the same one-cycle window, so check it too. */
        li      a1, 5
#ifdef NO_MUL
        addw    a6, a0, a1             /* 8 + 5 = 13                          */
#else
        divw    a6, a0, a1             /* 16 / 5 = 3                          */
#endif
        sw      a6, 24(sp)

        li      a4, PHASE_ADDR
        li      a5, 2
        sw      a5, 0(a4)              /* PHASE = 2: the rest of them ran     */

        /* Report.  Reading back through the stack checks the store data as
         * well as the M results -- a re-issued store writes the same value, so
         * the values being right is not evidence on its own, but a wrong one
         * would be. */
        li      a4, RESULT_ADDR
        sw      a0, 0(a4)
        li      a4, REC_ADDR
        sw      a2, 0(a4)
        sw      a3, 4(a4)
        sw      a6, 8(a4)
        lw      a7, 12(sp)
        sw      a7, 12(a4)             /* the store that used to spin         */

        li      a4, PHASE_ADDR
        li      a5, 9
        sw      a5, 0(a4)
        li      a4, DONE_ADDR
        li      a5, 0xdeadbeef
        sw      a5, 0(a4)

spin:   j       spin
