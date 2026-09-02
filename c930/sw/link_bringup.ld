/* ---------------------------------------------------------------------------
 * link_bringup.ld - linker script for Arty A7-100T DDR3L bring-up firmware
 *
 * The firmware loads at address 0x0000 in DDR3L via JTAG.  The MIG DDR3L
 * controller has already calibrated by the time the CPU boots.
 *
 * Memory layout:
 *   0x0000_0000 .. code/data   firmware text + rodata + data + bss
 *   0x0000_8000                A matrix (4x4 INT8 = 16 bytes)
 *   0x0000_8400                B matrix (4x4 INT8 = 16 bytes)
 *   0x0000_8800                C result (4x4 INT32 = 64 bytes)
 *   0x0000_9490                PHASE_ADDR (status tracker)
 *   0x0000_9410                DONE_ADDR (completion magic)
 *   0x0000_9500                RESULT_ADDR (test result)
 * ------------------------------------------------------------------------ */

ENTRY(_start)

MEMORY
{
    /* DDR3L: full 256 MB, but firmware uses first 64 KB */
    DDR (rwx) : ORIGIN = 0x00000000, LENGTH = 65536

    /* Stack: grows down from top of DDR */
    STACK (rw) : ORIGIN = 0x00008000, LENGTH = 4096
}

SECTIONS
{
    /* Code and read-only data */
    .text : {
        _text_start = .;
        *(.text.startup)
        *(.text*)
        _text_end = .;
    } > DDR

    /* Read-only data (constants) */
    .rodata : {
        _rodata_start = .;
        *(.rodata*)
        _rodata_end = .;
    } > DDR

    /* Initialized data */
    .data : {
        _data_start = .;
        *(.data*)
        _data_end = .;
    } > DDR

    /* Zero-initialized data */
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss*)
        *(COMMON)
        _bss_end = .;
    } > DDR

    /* Stack at the end of the DDR region */
    _stack_top = ORIGIN(STACK) + LENGTH(STACK);
    _heap_end = _stack_top;

    /* Entry point */
    _start = .;
}
