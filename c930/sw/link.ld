/* -----------------------------------------------------------------------------
 * link.ld - linker script for the C930 SoC test program.
 *
 * Flat memory map (matches c930_soc_top / c930_ddr):
 *   0x0000_0000 : code (.text.start first)
 *   after code  : .rodata, .data, .bss
 *   0x0000_8000 : stack top (start.S sets sp here)
 *   0x0000_9000 : A buffer   (NPU reads)
 *   0x0000_9100 : B buffer   (NPU reads)
 *   0x0000_9200 : C buffer   (NPU writes)
 *   0x0000_9300 : done magic (CPU writes; testbench polls)
 *   0x4000_0000 : NPU MMIO control/status (uncached)
 * -----------------------------------------------------------------------------
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
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

  /* NPU operand tables live at fixed DDR addresses. They are part of the flat
   * image the testbench loads into DDR, so the core never copies them: the
   * NPU's AXI4 DMA fetches A/B straight from these addresses. */
  .a_buf 0x9000 : {
    KEEP(*(.a_buf))
  } > RAM

  .b_buf 0x9100 : {
    KEEP(*(.b_buf))
  } > RAM
}
