/* link_sim.ld - linker script for Verilator SoC simulation.
 * CPU0 resets to PC=0x0 (DDR_BASE in crossbar = 0x0000_0000).
 * Verilator DDR model is 64 KB byte-addressable.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start_text)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 60K
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
  _stack_end = 0xF000;

  /DISCARD/ : {
    *(.comment)
    *(.note*)
    *(.eh_frame*)
    *(.riscv.attributes)
  }
}
