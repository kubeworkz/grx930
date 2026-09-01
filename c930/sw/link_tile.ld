/* link_tile.ld - linker script for npu_tile_test firmware.
 *
 * Code goes to 0x0000-0x0FFF (4 KB).  A/B/C scratch buffers sit above:
 *   0x1000 : A (M*K bytes)
 *   0x2000 : B (K*N bytes)
 *   0x3000 : C (M*N*4 bytes)
 *   0x4000 : C_ref (M*N*4 bytes)
 *   0x5000 : tiling scratch (A_tile + B_tile + C_tile + C_acc)
 *   0x8000 : stack top
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 4K
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
