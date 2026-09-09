/* GRX930 RISC-V 64 Firmware Linker Script */

/* Entry point */
ENTRY(_start_text)

/* Memory regions */
MEMORY
{
    /* Firmware code + data (mapped to DRAM base + offset) */
    ROM (rx)  : ORIGIN = 0x80000000, LENGTH = 256K

    /* Stack and heap (top of ROM region) */
    RAM (rwx) : ORIGIN = 0x80040000, LENGTH = 256K

    /* Kernel load area (where host uploads user kernels) */
    KERNEL (rw) : ORIGIN = 0x81000000, LENGTH = 16M
}

/* Stack size */
_Min_Stack_Size = 4K;

/* Sections */
SECTIONS
{
    /* Code section */
    .text : {
        _text_start = .;
        *(.text.init)    /* Startup code */
        *(.text*)
        _text_end = .;
    } > ROM

    /* Read-only data */
    .rodata : ALIGN(8) {
        _rodata_start = .;
        *(.rodata*)
        *(.srodata*)
        _rodata_end = .;
    } > ROM

    /* Initialized data (copied from ROM to RAM at startup) */
    .data : ALIGN(8) {
        _data_start = .;
        *(.data*)
        *(.sdata*)
        _data_end = .;
    } > RAM AT > ROM

    /* Uninitialized data (zeroed at startup) */
    .bss : ALIGN(8) {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* Stack (grows downward) */
    .stack (NOLOAD) : ALIGN(16) {
        _stack_start = .;
        . += _Min_Stack_Size;
        _stack_end = .;
    } > RAM

    /* Kernel load area (not part of firmware, just a memory region) */
    .kernel : {
        _kernel_start = ORIGIN(KERNEL);
        _kernel_end = ORIGIN(KERNEL) + LENGTH(KERNEL);
    } > KERNEL

    /* Discard unnecessary sections */
    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}


