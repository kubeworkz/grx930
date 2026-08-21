/* -----------------------------------------------------------------------------
 * link_boot.ld - linker script for npu_boot.c (synth DDR stub firmware).
 *
 * The synth-only DDR stub is a 512-byte boot memory (16 lines x 32 B, byte
 * address 0x000..0x1FF). Everything must fit in that window:
 *   0x000 .. code (must stay below 0x100)
 *   0x100 .. A operand (8 B, line 8)
 *   0x110 .. B operand (8 B, line 8)
 *   0x120 .. C output (16 B, line 9; written by the NPU DMA, no init needed)
 *
 * If the code grows past 0x100 the link fails loudly (address overflow into
 * .ops_a) rather than silently corrupting operands.
 * -----------------------------------------------------------------------------
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 512
}

SECTIONS
{
  .text : {
    *(.text.start)
    *(.text)
    *(.text.*)
  } > RAM

  .rodata : {
    *(.rodata .rodata.*)
  } > RAM

  .data : {
    *(.data .data.*)
  } > RAM

  .bss : {
    *(.bss .bss.*)
    *(COMMON)
  } > RAM

  .ops_a 0x100 : { KEEP(*(.ops_a)) } > RAM
  .ops_b 0x110 : { KEEP(*(.ops_b)) } > RAM
}
