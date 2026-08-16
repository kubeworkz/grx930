/* -----------------------------------------------------------------------------
 * link.ld - linker script for the C930 SoC test program.
 *
 * Flat memory map (matches c930_soc_top / c930_ddr):
 *   0x0000_0000 : code (.text.start first)
 *   after code  : .rodata, .data, .bss
 *   0x0000_8000 : stack top (start.S sets sp here)
 *   0x0000_9000 : A buffer   (testbench preloads; NPU DMA reads)
 *   0x0000_9100 : B buffer   (testbench preloads; NPU DMA reads)
 *   0x0000_9200 : C buffer   (NPU DMA writes; testbench checks)
 *   0x0000_9400 : workload descriptor M/N/K (testbench writes)
 *   0x0000_9410 : done magic (CPU writes; testbench polls)
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
}
