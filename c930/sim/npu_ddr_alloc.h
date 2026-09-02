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
// Usage (from exactly ONE .c file, define the impl):
//
//   #define NPU_DDR_ALLOC_IMPL
//   #include "npu_ddr_alloc.h"
//
//   npu_ddr_alloc_t ddr;
//   npu_ddr_alloc_init(&ddr, 0x0000, 0x10000);
//
//   uint32_t a = npu_ddr_alloc(&ddr, M * K, 4);
//   uint32_t b = npu_ddr_alloc(&ddr, K * N, 4);
//   uint32_t c = npu_ddr_alloc(&ddr, M * N * 4, 4);
//
//   // Use a, b, c as CSR values for A_BASE, B_BASE, C_BASE
//   // ...
//
//   npu_ddr_free(&ddr, a);
//   npu_ddr_free(&ddr, b);
//   npu_ddr_free(&ddr, c);
//
// Sentinel: npu_ddr_alloc returns NPU_DDR_ALLOC_FAILED (0xFFFFFFFF) on failure.
// The caller must check for this before using the offset.
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

// Sentinel: returned on failure.  Not a valid DDR offset.
#define NPU_DDR_ALLOC_FAILED  0xFFFFFFFFu

// ---- Block metadata ----
typedef struct {
    uint32_t offset;   // byte offset from window base
    uint32_t size;     // usable size in bytes (excluding alignment padding)
    uint32_t total;    // total span including padding (size for non-padded)
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
void npu_ddr_alloc_init(npu_ddr_alloc_t *a, uint32_t base, uint32_t size);

// Allocate `size` bytes with the given alignment (must be power of 2).
// Returns the byte offset, or NPU_DDR_ALLOC_FAILED on failure.
uint32_t npu_ddr_alloc(npu_ddr_alloc_t *a, uint32_t size, uint32_t align);

// Free a previously allocated block.  Returns 0 on success, -1 if not found.
int npu_ddr_free(npu_ddr_alloc_t *a, uint32_t offset);

// Reset the allocator, freeing all blocks.
void npu_ddr_alloc_reset(npu_ddr_alloc_t *a);

// Print allocator state (for debugging).
void npu_ddr_alloc_dump(const npu_ddr_alloc_t *a);

#ifdef __cplusplus
}
#endif

// ---- Implementation (header-only, define NPU_DDR_ALLOC_IMPL in exactly one TU) ----
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
static inline uint32_t npu_align_up(uint32_t value, uint32_t align) {
    return (value + align - 1) & ~(align - 1);
}

uint32_t npu_ddr_alloc(npu_ddr_alloc_t *a, uint32_t size, uint32_t align) {
    if (size == 0 || align == 0 || (align & (align - 1)) != 0)
        return NPU_DDR_ALLOC_FAILED;

    for (int i = 0; i < a->num_blocks; i++) {
        if (!a->blocks[i].free) continue;

        // Align the start offset within this free block
        uint32_t aligned_offset = npu_align_up(a->blocks[i].offset, align);
        uint32_t padding = aligned_offset - a->blocks[i].offset;

        // Check if this free block is large enough (wrap-safe)
        if (a->blocks[i].size < padding || a->blocks[i].size - padding < size)
            continue;

        // Available space after alignment
        uint32_t avail = a->blocks[i].size - padding;
        uint32_t remainder = avail - size;

        // How many new blocks do we need? (pad, alloc, remain — minus what we replace)
        int extra = (padding > 0 ? 1 : 0) + (remainder > 0 ? 1 : 0);

        if (a->num_blocks + extra > NPU_DDR_MAX_BLOCKS)
            continue;  // not enough metadata slots

        // Shift existing blocks right to make room
        for (int j = a->num_blocks - 1; j >= i + 1; j--)
            a->blocks[j + extra] = a->blocks[j];
        a->num_blocks += extra;

        int pos = i;

        // If there was padding, insert a free block for it
        if (padding > 0) {
            a->blocks[pos].offset = a->blocks[i].offset;
            a->blocks[pos].size   = padding;
            a->blocks[pos].total  = padding;
            a->blocks[pos].free   = 1;
            pos++;
        }

        // Insert the allocated block (total = size, NOT size + padding)
        a->blocks[pos].offset = aligned_offset;
        a->blocks[pos].size   = size;
        a->blocks[pos].total  = size;
        a->blocks[pos].free   = 0;
        pos++;

        // If there is remaining space, insert a free block for it
        if (remainder > 0) {
            a->blocks[pos].offset = aligned_offset + size;
            a->blocks[pos].size   = remainder;
            a->blocks[pos].total  = remainder;
            a->blocks[pos].free   = 1;
        }

        return aligned_offset;
    }

    return NPU_DDR_ALLOC_FAILED;  // no suitable block found
}

int npu_ddr_free(npu_ddr_alloc_t *a, uint32_t offset) {
    if (offset == NPU_DDR_ALLOC_FAILED) return -1;

    for (int i = 0; i < a->num_blocks; i++) {
        if (a->blocks[i].offset == offset && !a->blocks[i].free) {
            a->blocks[i].free = 1;

            // Coalesce with adjacent free blocks
            // Forward merge
            if (i + 1 < a->num_blocks && a->blocks[i + 1].free) {
                a->blocks[i].size += a->blocks[i + 1].size;
                a->blocks[i].total = a->blocks[i].size;
                for (int j = i + 1; j + 1 < a->num_blocks; j++)
                    a->blocks[j] = a->blocks[j + 1];
                a->num_blocks--;
            }
            // Backward merge
            if (i > 0 && a->blocks[i - 1].free) {
                a->blocks[i - 1].size += a->blocks[i].size;
                a->blocks[i - 1].total = a->blocks[i - 1].size;
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
    uint32_t sum_total = 0;
    for (int i = 0; i < a->num_blocks; i++) {
        const npu_ddr_block_t *b = &a->blocks[i];
        sum_total += b->total;
        printf("  [%d] 0x%04x-0x%04x  %s  size=%u total=%u\n",
               i, b->offset, b->offset + b->total,
               b->free ? "FREE" : "USED",
               b->size, b->total);
    }
    printf("  sum(total) = %u %s\n", sum_total,
           sum_total <= a->size ? "(OK)" : "(OVERFLOW!)");
}

#endif // NPU_DDR_ALLOC_IMPL

#endif // NPU_DDR_ALLOC_H
