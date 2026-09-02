// -----------------------------------------------------------------------------
// npu_ddr_alloc.h - Reference memory allocator for the C930 NPU's 64KB DDR.
//
// The NPU has a flat 64KB byte-addressable DDR window.  A/B/C matrices must
// be placed within this window at word-aligned addresses (bits [1:0] = 0)
// for the DMA master to transfer them correctly.
//
// This allocator provides first-fit allocation with alignment support.
// It works in both firmware (RISC-V bare-metal) and host builds (x86/ARM).
//
// Usage:
//   #include "npu_ddr_alloc.h"
//
//   // Initialize with the full 64KB window
//   npu_ddr_alloc_init(0x0000, 0x10000);
//
//   // Allocate A, B, C matrices
//   uint32_t a = npu_ddr_alloc(M * K, 4);      // 4-byte aligned
//   uint32_t b = npu_ddr_alloc(K * N, 4);
//   uint32_t c = npu_ddr_alloc(M * N * 4, 4);  // INT32 output
//
//   // Use a, b, c as CSR values for A_BASE, B_BASE, C_BASE
//   npu_dpi_csr_write(NPU_CSR_A_BASE, a);
//   npu_dpi_csr_write(NPU_CSR_B_BASE, b);
//   npu_dpi_csr_write(NPU_CSR_C_BASE, c);
//
//   // Free when done
//   npu_ddr_free(a);
//   npu_ddr_free(b);
//   npu_ddr_free(c);
//
// The allocator does NOT touch DDR contents — it only manages offsets.
// The caller (or the NPU DMA) handles actual data placement.
// -----------------------------------------------------------------------------

#ifndef NPU_DDR_ALLOC_H
#define NPU_DDR_ALLOC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Configuration ----
#ifndef NPU_DDR_SIZE
#define NPU_DDR_SIZE 65536   // 64 KB
#endif

#ifndef NPU_DDR_MAX_BLOCKS
#define NPU_DDR_MAX_BLOCKS 32   // max simultaneous allocations
#endif

// ---- Block metadata ----
typedef struct {
    uint32_t offset;   // byte offset from window base
    uint32_t size;     // usable size in bytes (excluding alignment padding)
    uint32_t total;    // total allocated (including alignment padding)
    int      free;     // 1 = free block, 0 = in use
} npu_ddr_block_t;

// ---- Allocator state ----
typedef struct {
    uint32_t base;                          // window base offset (usually 0)
    uint32_t size;                          // window size (usually 65536)
    npu_ddr_block_t blocks[NPU_DDR_MAX_BLOCKS];
    int      num_blocks;
} npu_ddr_alloc_t;

// ---- API ----

// Initialize the allocator with a DDR window.
// base: starting byte offset (usually 0x0000 for the NPU's DDR)
// size: window size in bytes (usually 0x10000 = 64KB)
void npu_ddr_alloc_init(npu_ddr_alloc_t *a, uint32_t base, uint32_t size);

// Allocate `size` bytes with the given alignment (must be power of 2).
// Returns the byte offset within the DDR window, or 0 on failure.
// Alignment is applied to the returned offset, so (offset % align) == 0.
uint32_t npu_ddr_alloc(npu_ddr_alloc_t *a, uint32_t size, uint32_t align);

// Free a previously allocated block.
// offset must be a value returned by npu_ddr_alloc.
// Returns 0 on success, -1 if the offset was not found.
int npu_ddr_free(npu_ddr_alloc_t *a, uint32_t offset);

// Reset the allocator, freeing all blocks.
void npu_ddr_alloc_reset(npu_ddr_alloc_t *a);

// Print allocator state (for debugging).
void npu_ddr_alloc_dump(const npu_ddr_alloc_t *a);

// ---- Convenience: global allocator ----
// For firmware or single-device use, a global instance avoids passing
// the allocator struct everywhere.

static npu_ddr_alloc_t g_npu_ddr;

static inline void npu_ddr_init_global(uint32_t base, uint32_t size) {
    npu_ddr_alloc_init(&g_npu_ddr, base, size);
}

static inline uint32_t npu_ddr_malloc(uint32_t size, uint32_t align) {
    return npu_ddr_alloc(&g_npu_ddr, size, align);
}

static inline int npu_ddr_mfree(uint32_t offset) {
    return npu_ddr_free(&g_npu_ddr, offset);
}

#ifdef __cplusplus
}
#endif

// ---- Implementation (header-only) ----
#ifdef NPU_DDR_ALLOC_IMPL

#include <stdio.h>

void npu_ddr_alloc_init(npu_ddr_alloc_t *a, uint32_t base, uint32_t size) {
    a->base = base;
    a->size = size;
    a->num_blocks = 1;
    a->blocks[0].offset = base;
    a->blocks[0].size   = size;
    a->blocks[0].total  = size;
    a->blocks[0].free   = 1;
}

// Round up `value` to the next multiple of `align`.
static inline uint32_t align_up(uint32_t value, uint32_t align) {
    return (value + align - 1) & ~(align - 1);
}

uint32_t npu_ddr_alloc(npu_ddr_alloc_t *a, uint32_t size, uint32_t align) {
    if (size == 0 || align == 0 || (align & (align - 1)) != 0)
        return 0;  // invalid args

    for (int i = 0; i < a->num_blocks; i++) {
        if (!a->blocks[i].free) continue;

        // Align the start offset
        uint32_t aligned_offset = align_up(a->blocks[i].offset, align);
        uint32_t padding = aligned_offset - a->blocks[i].offset;

        // Check if this free block is large enough
        if (padding + size > a->blocks[i].total)
            continue;

        // Split: create free blocks for padding and remainder.
        // Need room for up to 3 blocks (pad, alloc, remain) replacing 1.
        uint32_t total_used = padding + size;
        uint32_t remaining = a->blocks[i].total - total_used;
        int extra = (padding > 0 ? 1 : 0) + (remaining > 0 ? 1 : 0);

        if (a->num_blocks + extra > NPU_DDR_MAX_BLOCKS)
            continue;  // not enough room for metadata

        // Save original block info before overwriting
        uint32_t orig_total = a->blocks[i].total;
        (void)orig_total;

        // Shift existing blocks right to make room for 'extra' new blocks
        for (int j = a->num_blocks - 1; j >= i + 1; j--)
            a->blocks[j + extra] = a->blocks[j];
        a->num_blocks += extra;

        int pos = i;

        // If there was padding, insert a free block for it
        if (padding > 0) {
            a->blocks[pos].offset = a->blocks[i].offset;  // original offset
            a->blocks[pos].size   = padding;
            a->blocks[pos].total  = padding;
            a->blocks[pos].free   = 1;
            pos++;
        }

        // Insert the allocated block
        a->blocks[pos].offset = aligned_offset;
        a->blocks[pos].size   = size;
        a->blocks[pos].total  = total_used;
        a->blocks[pos].free   = 0;
        pos++;

        // If there is remaining space, insert a free block for it
        if (remaining > 0) {
            a->blocks[pos].offset = aligned_offset + size;
            a->blocks[pos].size   = remaining;
            a->blocks[pos].total  = remaining;
            a->blocks[pos].free   = 1;
        }

        return aligned_offset;
    }

    return 0;  // no suitable block found
}

int npu_ddr_free(npu_ddr_alloc_t *a, uint32_t offset) {
    for (int i = 0; i < a->num_blocks; i++) {
        if (a->blocks[i].offset == offset && !a->blocks[i].free) {
            a->blocks[i].free = 1;

            // Coalesce with adjacent free blocks
            // Forward merge
            if (i + 1 < a->num_blocks && a->blocks[i + 1].free) {
                a->blocks[i].total += a->blocks[i + 1].total;
                for (int j = i + 1; j + 1 < a->num_blocks; j++)
                    a->blocks[j] = a->blocks[j + 1];
                a->num_blocks--;
            }
            // Backward merge
            if (i > 0 && a->blocks[i - 1].free) {
                a->blocks[i - 1].total += a->blocks[i].total;
                for (int j = i; j + 1 < a->num_blocks; j++)
                    a->blocks[j] = a->blocks[j + 1];
                a->num_blocks--;
            }

            return 0;
        }
    }
    return -1;  // offset not found
}

void npu_ddr_alloc_reset(npu_ddr_alloc_t *a) {
    a->num_blocks = 1;
    a->blocks[0].offset = a->base;
    a->blocks[0].size   = a->size;
    a->blocks[0].total  = a->size;
    a->blocks[0].free   = 1;
}

void npu_ddr_alloc_dump(const npu_ddr_alloc_t *a) {
    printf("[DDR-ALLOC] base=0x%x size=%u blocks=%d\n",
           a->base, a->size, a->num_blocks);
    for (int i = 0; i < a->num_blocks; i++) {
        const npu_ddr_block_t *b = &a->blocks[i];
        printf("  [%d] 0x%04x-0x%04x  %s  size=%u total=%u\n",
               i, b->offset, b->offset + b->total,
               b->free ? "FREE" : "USED",
               b->size, b->total);
    }
}

#endif // NPU_DDR_ALLOC_IMPL

#endif // NPU_DDR_ALLOC_H
