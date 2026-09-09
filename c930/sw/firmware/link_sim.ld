/* -----------------------------------------------------------------------------
 * link_sim.ld - linker script for the GRX930 echo firmware under the
 * Verilator SoC simulation.
 *
 * The RV64IMAC core resets with PC = 0 (DDR base).  The Verilator DDR model is
 * 64 KB, so everything must live below 0x10000 -- unlike the real-chip
 * linker.ld which places firmware at 0x80000000.  Stack top at 0x8000 matches
 * the NPU test convention (start.S sets sp).
 * -----------------------------------------------------------------------------
 */
OUTPUT_ARCH(riscv)
ENTRY(_start_text)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS
{
  .text : {
    *(.text.init)
    *(.text)
    *(.text.*)
  } > RAM

  .rodata : ALIGN(8) {
    *(.rodata)
    *(.rodata.*)
    *(.srodata*)
  } > RAM

  .data : ALIGN(8) {
    _data_start = .;
    *(.data)
    *(.data.*)
    *(.sdata*)
    _data_end = .;
  } > RAM

  .bss : ALIGN(8) {
    _bss_start = .;
    *(.bss)
    *(.bss.*)
    *(.sbss*)
    *(COMMON)
    _bss_end = .;
  } > RAM

  . = ALIGN(16);
  _stack_top = 0x8000;   /* 32 KB stack, grows down (matches start.S) */

  /DISCARD/ : {
    *(.comment)
    *(.note*)
    *(.eh_frame*)
    *(.riscv.attributes)
  }
}