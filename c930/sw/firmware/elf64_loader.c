/**
 * GRX930 ELF64 Loader
 *
 * Loads RISC-V ELF64 binaries into memory for execution.
 * Handles:
 *   - ELF header validation
 *   - Program segment loading (PT_LOAD)
 *   - BSS zeroing (p_memsz > p_filesz)
 *   - Entry point resolution
 *
 * Usage:
 *   uint64_t entry;
 *   int result = elf64_load((void *)elf_data, elf_size, &entry);
 *   if (result == 0) {
 *       // Jump to entry point
 *   }
 */

#include <stdint.h>
#include <stddef.h>
#include "elf64.h"

// ============================================================================
// UART output (for error messages)
// ============================================================================

// Forward declaration — defined in main.c or uart_echo_test.c
extern void uart_write_char(uint8_t c);
extern void uart_write_string(const char *str);
extern void uart_write_hex32(uint32_t val);
extern void uart_write_hex64(uint64_t val);

// ============================================================================
// Memory operations (freestanding)
// ============================================================================

static void memset_zero(void *dst, size_t len) {
    uint8_t *d = (uint8_t *)dst;
    for (size_t i = 0; i < len; i++) {
        d[i] = 0;
    }
}

static void memcpy_to(void *dst, const void *src, size_t len) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < len; i++) {
        d[i] = s[i];
    }
}

// ============================================================================
// Error codes
// ============================================================================

#define ELF_OK              0
#define ELF_ERR_TOO_SMALL  -1  // Data too small for ELF header
#define ELF_ERR_BAD_MAGIC  -2  // Not an ELF file
#define ELF_ERR_BAD_CLASS  -3  // Not 64-bit ELF
#define ELF_ERR_BAD_ENDIAN -4  // Not little-endian
#define ELF_ERR_BAD_TYPE   -5  // Not an executable
#define ELF_ERR_BAD_ARCH   -6  // Not RISC-V
#define ELF_ERR_NO_LOAD    -7  // No loadable segments
#define ELF_ERR_BAD_SEG    -8  // Invalid segment
#define ELF_ERR_MEM_OVER   -9  // Segment exceeds memory
#define ELF_ERR_BAD_OFFSET -10 // Segment offset out of range

// ============================================================================
// ELF64 Loader Implementation
// ============================================================================

/**
 * Load an ELF64 binary into memory.
 *
 * @param elf_data     Pointer to ELF binary data
 * @param elf_size     Size of ELF data in bytes
 * @param entry_out    Output: entry point address
 * @return             0 on success, negative error code on failure
 */
int elf64_load(const void *elf_data, size_t elf_size, uint64_t *entry_out) {
    const uint8_t *data = (const uint8_t *)elf_data;

    // ---- Validate minimum size ----
    if (elf_size < sizeof(Elf64_Ehdr)) {
        uart_write_string("ELF: too small (");
        uart_write_hex32((uint32_t)elf_size);
        uart_write_string(")\r\n");
        return ELF_ERR_TOO_SMALL;
    }

    // ---- Parse ELF header ----
    const Elf64_Ehdr *ehdr = (const Elf64_Ehdr *)data;

    // Validate magic
    if (ehdr->e_ident[0] != ELFMAG0 || ehdr->e_ident[1] != ELFMAG1 ||
        ehdr->e_ident[2] != ELFMAG2 || ehdr->e_ident[3] != ELFMAG3) {
        uart_write_string("ELF: bad magic\r\n");
        return ELF_ERR_BAD_MAGIC;
    }

    // Validate class (64-bit)
    if (ehdr->e_ident[4] != ELFCLASS64) {
        uart_write_string("ELF: not 64-bit\r\n");
        return ELF_ERR_BAD_CLASS;
    }

    // Validate encoding (little-endian)
    if (ehdr->e_ident[5] != ELFDATA2LSB) {
        uart_write_string("ELF: not little-endian\r\n");
        return ELF_ERR_BAD_ENDIAN;
    }

    // Validate type (executable)
    if (ehdr->e_type != ET_EXEC) {
        uart_write_string("ELF: not executable (type=");
        uart_write_hex32(ehdr->e_type);
        uart_write_string(")\r\n");
        return ELF_ERR_BAD_TYPE;
    }

    // Validate architecture (RISC-V)
    if (ehdr->e_machine != EM_RISCV) {
        uart_write_string("ELF: not RISC-V (machine=");
        uart_write_hex32(ehdr->e_machine);
        uart_write_string(")\r\n");
        return ELF_ERR_BAD_ARCH;
    }

    // ---- Parse program headers ----
    if (ehdr->e_phoff == 0 || ehdr->e_phnum == 0) {
        uart_write_string("ELF: no program headers\r\n");
        return ELF_ERR_NO_LOAD;
    }

    // Validate program header table is within file
    size_t ph_table_end = ehdr->e_phoff + (size_t)ehdr->e_phnum * (size_t)ehdr->e_phentsize;
    if (ph_table_end > elf_size) {
        uart_write_string("ELF: phdr table exceeds file\r\n");
        return ELF_ERR_BAD_SEG;
    }

    uart_write_string("ELF: loading ");
    uart_write_hex32(ehdr->e_phnum);
    uart_write_string(" segments\r\n");

    int segments_loaded = 0;

    // ---- Load each PT_LOAD segment ----
    for (uint16_t i = 0; i < ehdr->e_phnum; i++) {
        // Calculate pointer to program header
        size_t ph_offset = ehdr->e_phoff + (size_t)i * (size_t)ehdr->e_phentsize;
        const Elf64_Phdr *phdr = (const Elf64_Phdr *)(data + ph_offset);

        // Skip non-loadable segments
        if (phdr->p_type != PT_LOAD) {
            continue;
        }

        // Validate segment
        if (phdr->p_filesz > phdr->p_memsz) {
            uart_write_string("ELF: seg ");
            uart_write_hex32(i);
            uart_write_string(" filesz > memsz\r\n");
            return ELF_ERR_BAD_SEG;
        }

        // Validate file offset
        if (phdr->p_offset + phdr->p_filesz > elf_size) {
            uart_write_string("ELF: seg ");
            uart_write_hex32(i);
            uart_write_string(" exceeds file\r\n");
            return ELF_ERR_BAD_OFFSET;
        }

        // Load segment
        uart_write_string("  seg ");
        uart_write_hex32(i);
        uart_write_string(": addr=");
        uart_write_hex64(phdr->p_vaddr);
        uart_write_string(" file=");
        uart_write_hex64(phdr->p_filesz);
        uart_write_string(" mem=");
        uart_write_hex64(phdr->p_memsz);
        uart_write_string("\r\n");

        // Copy initialized data
        if (phdr->p_filesz > 0) {
            memcpy_to((void *)phdr->p_vaddr, data + phdr->p_offset, phdr->p_filesz);
        }

        // Zero BSS (memory size > file size)
        if (phdr->p_memsz > phdr->p_filesz) {
            size_t bss_size = phdr->p_memsz - phdr->p_filesz;
            memset_zero((void *)(phdr->p_vaddr + phdr->p_filesz), bss_size);
        }

        segments_loaded++;
    }

    if (segments_loaded == 0) {
        uart_write_string("ELF: no loadable segments\r\n");
        return ELF_ERR_NO_LOAD;
    }

    // ---- Set entry point ----
    *entry_out = ehdr->e_entry;

    uart_write_string("ELF: loaded ");
    uart_write_hex32(segments_loaded);
    uart_write_string(" segments, entry=");
    uart_write_hex64(ehdr->e_entry);
    uart_write_string("\r\n");

    return ELF_OK;
}

/**
 * Get ELF info (for debugging/reporting).
 */
typedef struct {
    uint64_t entry;
    uint32_t type;
    uint32_t machine;
    uint16_t phnum;
    uint16_t shnum;
} elf64_info_t;

int elf64_get_info(const void *elf_data, size_t elf_size, elf64_info_t *info) {
    if (elf_size < sizeof(Elf64_Ehdr)) {
        return ELF_ERR_TOO_SMALL;
    }

    const Elf64_Ehdr *ehdr = (const Elf64_Ehdr *)elf_data;

    if (!elf64_is_valid(elf_data, elf_size)) {
        return ELF_ERR_BAD_MAGIC;
    }

    info->entry   = ehdr->e_entry;
    info->type    = ehdr->e_type;
    info->machine = ehdr->e_machine;
    info->phnum   = ehdr->e_phnum;
    info->shnum   = ehdr->e_shnum;

    return ELF_OK;
}

/**
 * Validate an ELF64 binary without loading it.
 */
int elf64_validate(const void *elf_data, size_t elf_size) {
    elf64_info_t info;
    int result = elf64_get_info(elf_data, elf_size, &info);
    if (result != ELF_OK) {
        return result;
    }

    // Additional checks
    if (info.type != ET_EXEC) {
        return ELF_ERR_BAD_TYPE;
    }
    if (info.machine != EM_RISCV) {
        return ELF_ERR_BAD_ARCH;
    }
    if (info.phnum == 0) {
        return ELF_ERR_NO_LOAD;
    }

    return ELF_OK;
}

/**
 * Print ELF info (for debugging).
 */
void elf64_print_info(const void *elf_data, size_t elf_size) {
    elf64_info_t info;

    uart_write_string("=== ELF64 Info ===\r\n");

    if (elf64_get_info(elf_data, elf_size, &info) != ELF_OK) {
        uart_write_string("Invalid ELF file\r\n");
        return;
    }

    uart_write_string("Entry:   0x");
    uart_write_hex64(info.entry);
    uart_write_string("\r\n");

    uart_write_string("Type:    0x");
    uart_write_hex32(info.type);
    uart_write_string("\r\n");

    uart_write_string("Machine: 0x");
    uart_write_hex32(info.machine);
    uart_write_string("\r\n");

    uart_write_string("PH count: ");
    uart_write_hex32(info.phnum);
    uart_write_string("\r\n");

    uart_write_string("SH count: ");
    uart_write_hex32(info.shnum);
    uart_write_string("\r\n");

    uart_write_string("=================\r\n");
}
