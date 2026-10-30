/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Gridworkz */
/* test_chip_boot.S -- boot firmware for the GRX930 1x1 GF180MCU test chip.
 *
 * Memory map of the chip (see asic_gf180mcu/openlane2_rtl/src/grx930_test_chip.sv):
 *   0x0000_0000 - 0x0000_07FF : 2 KB SRAM (code, data, stack; higher addresses alias)
 *   0x4000_1000 - 0x4000_100F : UART 16550 registers
 *   reset PC = 0x0
 *
 * What it does, in the order the testbench checks it:
 *   1. prints "GRX930 OK\n" on the UART (fetch + I-cache + MMIO write path),
 *   2. polls STATUS.tx_fifo_full before each character, so the run also
 *      exercises MMIO *reads* interleaved with I-cache fills -- the combination
 *      that froze an MMIO load in MMIO_RD_RETIRE and made it read the wrong
 *      response (see doc/dcache_mmio_read_hold.md),
 *   3. stores a magic word to SRAM at 0x400 and reads it back (D-cache
 *      write-through plus a load hit),
 *   4. leaves 0x0000_C0DE at 0x408 only if the read-back matched, otherwise
 *      prints '!' and leaves 0x0000_DEAD,
 *   5. spins.
 *
 * All instructions are 4 bytes (.option norvc) so a failure here is not a
 * compressed-decoder question.
 *
 * Build: sw/build_test_chip_fw.sh  (riscv64-unknown-elf-gcc + bin2hex.py)
 */

  .section .text.init, "ax"
  .globl _start
  .option norvc

  /* Poll STATUS (0x08) bit 0 = tx_fifo_full, then write the byte to TX (0x00). */
  .macro PUTCH ch
    li    x7, \ch
1:  lw    x8, 8(x5)
    and   x8, x8, x6
    bnez  x8, 1b
    sw    x7, 0(x5)
  .endm

_start:
  li    x2, 0x700             /* stack: top of the SRAM data area */
  lui   x5, 0x40001           /* x5 = 0x4000_1000, UART base      */
  li    x6, 1                 /* STATUS bit 0 = tx_fifo_full      */

  PUTCH 'G'
  PUTCH 'R'
  PUTCH 'X'
  PUTCH '9'
  PUTCH '3'
  PUTCH '0'
  PUTCH ' '
  PUTCH 'O'
  PUTCH 'K'
  PUTCH '\n'

  /* SRAM write / read-back: the store goes through the D-cache's write-through
     port, the load re-reads it (a D-cache hit if the line is still resident).
     MAGIC/MARK sit at 0x400, clear of the 0x110-byte image and of the stack at
     0x700; the TB reads both hierarchically. */
  .equ MAGIC, 0x400
  .equ MARK,  0x408

  lui   x7, 0x2A5A1
  addi  x7, x7, 0x234         /* x7 = 0x2A5A_1234 */
  sd    x7, MAGIC(x0)
  ld    x8, MAGIC(x0)
  bne   x8, x7, fail

  li    x9, 0xC0DE
  sd    x9, MARK(x0)          /* success marker */
  j     halt

fail:
  li    x10, 0x21             /* '!' */
  sw    x10, 0(x5)
  li    x9, 0xDEAD
  sd    x9, MARK(x0)
halt:
  j     halt

/* No .data: everything the program needs is immediate or written at runtime.
   The default link keeps the image contiguous from 0, so bin2hex.py emits a
   hex file the testbench can load word for word. */
