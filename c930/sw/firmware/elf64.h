/**
 * GRX930 ELF64 Definitions
 *
 * Minimal ELF64 structures for parsing RISC-V binaries.
 * Based on the ELF specification (System V ABI).
 */

#ifndef ELF64_H
#define ELF64_H

#include <stdint.h>

// ============================================================================
// ELF Identification
// ============================================================================

#define EI_NIDENT   16      // Size of e_ident[]

// ELF magic numbers
#define ELFMAG0     0x7F
#define ELFMAG1     'E'
#define ELFMAG2     'L'
#define ELFMAG3     'F'

// ELF classes
#define ELFCLASS32  1       // 32-bit objects
#define ELFCLASS64  2       // 64-bit objects

// ELF data encoding
#define ELFDATA2LSB 1       // Little-endian
#define ELFDATA2MSB 2       // Big-endian

// ELF OS/ABI
#define ELFOSABI_NONE   0   // UNIX System V ABI
#define ELFOSABI_LINUX  3   // Linux

// ELF object file types
#define ET_NONE     0       // No file type
#define ET_REL      1       // Relocatable file
#define ET_EXEC     2       // Executable file
#define ET_DYN      3       // Shared object file
#define ET_CORE     4       // Core file

// ============================================================================
// ELF64 Header
// ============================================================================

typedef struct {
    uint8_t     e_ident[EI_NIDENT]; // ELF identification
    uint16_t    e_type;             // Object file type
    uint16_t    e_machine;          // Architecture
    uint32_t    e_version;          // Object file version
    uint64_t    e_entry;            // Entry point address
    uint64_t    e_phoff;            // Program header table offset
    uint64_t    e_shoff;            // Section header table offset
    uint32_t    e_flags;            // Processor-specific flags
    uint16_t    e_ehsize;           // ELF header size
    uint16_t    e_phentsize;        // Program header entry size
    uint16_t    e_phnum;            // Number of program header entries
    uint16_t    e_shentsize;        // Section header entry size
    uint16_t    e_shnum;            // Number of section header entries
    uint16_t    e_shstrndx;         // Section name string table index
} Elf64_Ehdr;

// ============================================================================
// ELF64 Program Header
// ============================================================================

// Segment types
#define PT_NULL     0       // Unused
#define PT_LOAD     1       // Loadable segment
#define PT_DYNAMIC  2       // Dynamic linking info
#define PT_INTERP   3       // Interpreter path
#define PT_NOTE     4       // Auxiliary info
#define PT_PHDR     6       // Program header table

// Segment flags
#define PF_X        0x1     // Execute
#define PF_W        0x2     // Write
#define PF_R        0x4     // Read

typedef struct {
    uint32_t    p_type;     // Segment type
    uint32_t    p_flags;    // Segment flags
    uint64_t    p_offset;   // Segment file offset
    uint64_t    p_vaddr;    // Segment virtual address
    uint64_t    p_paddr;    // Segment physical address
    uint64_t    p_filesz;   // Segment file size
    uint64_t    p_memsz;    // Segment memory size
    uint64_t    p_align;    // Segment alignment
} Elf64_Phdr;

// ============================================================================
// ELF64 Section Header
// ============================================================================

// Section types
#define SHT_NULL    0       // Unused
#define SHT_PROGBITS 1      // Program data
#define SHT_SYMTAB  2       // Symbol table
#define SHT_STRTAB  3       // String table
#define SHT_RELA    4       // Relocation entries
#define SHT_HASH    5       // Symbol hash table
#define SHT_DYNAMIC 6       // Dynamic linking info
#define SHT_NOTE    7       // Notes

// Section flags
#define SHF_WRITE   0x1     // Writable
#define SHF_ALLOC   0x2     // Occupies memory during execution
#define SHF_EXECINSTR 0x4   // Executable

typedef struct {
    uint32_t    sh_name;        // Section name (string table index)
    uint32_t    sh_type;        // Section type
    uint64_t    sh_flags;       // Section flags
    uint64_t    sh_addr;        // Section virtual address
    uint64_t    sh_offset;      // Section file offset
    uint64_t    sh_size;        // Section size
    uint32_t    sh_link;        // Link to another section
    uint32_t    sh_info;        // Additional section info
    uint64_t    sh_addralign;   // Section alignment
    uint64_t    sh_entsize;     // Entry size if section holds table
} Elf64_Shdr;

// ============================================================================
// RISC-V Machine Type
// ============================================================================

#define EM_RISCV    243     // RISC-V

// ============================================================================
// ELF Validation Helpers
// ============================================================================

// Check if data looks like an ELF64 binary
static inline int elf64_is_valid(const void *data, size_t size) {
    if (size < sizeof(Elf64_Ehdr)) {
        return 0;
    }

    const uint8_t *ident = (const uint8_t *)data;

    // Check magic number
    if (ident[0] != ELFMAG0 || ident[1] != ELFMAG1 ||
        ident[2] != ELFMAG2 || ident[3] != ELFMAG3) {
        return 0;
    }

    // Check class (64-bit)
    if (ident[4] != ELFCLASS64) {
        return 0;
    }

    // Check encoding (little-endian for RISC-V)
    if (ident[5] != ELFDATA2LSB) {
        return 0;
    }

    return 1;
}

// Get entry point from ELF header
static inline uint64_t elf64_get_entry(const void *data) {
    const Elf64_Ehdr *ehdr = (const Elf64_Ehdr *)data;
    return ehdr->e_entry;
}

#endif // ELF64_H
