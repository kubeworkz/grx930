# GRX930 Test Chip — GF180MCU Area Analysis (1×1 Slot)

## Verdict: ✅ Design FITS in 1×1 Slot

The stripped-down GRX930 test chip (1× RV64IMAC + UART + 64KB SRAM) fits in the wafer.space 1×1 slot with **32–49% margin**.

### Area Breakdown

| Component | Area (conservative) | Area (optimistic) |
|-----------|-------------------|-------------------|
| Logic (30K cells) | 3.79 mm² | 2.17 mm² |
| SRAM (64KB, 128 macros) | 2.94 mm² | 2.94 mm² |
| Routing overhead (30%) | ×1.3 | ×1.3 |
| **Total** | **8.76 mm²** | **6.64 mm²** |
| **1×1 slot core** | **12.92 mm²** | **12.92 mm²** |
| **Margin** | **32%** | **49%** |

### Slot Comparison

| Slot | Core Area | Fits? | Margin |
|------|-----------|-------|--------|
| 0.5×0.5 (quarter) | 1.73 mm² | ❌ No | — |
| 0.5×1 (half-width) | 4.46 mm² | ❌ No | — |
| 1×0.5 (half-height) | 5.02 mm² | ❌ No | — |
| **1×1 (full)** | **12.92 mm²** | **✅ Yes** | **32–49%** |

### Why It Fits

The key insight is that the test chip uses only ~30K standard cells (after removing NPU, multi-core, L2, DDR controller). At GF180MCU density (8k–14k cells/mm²), this is only 2–4 mm² of logic. Combined with the 64KB SRAM (2.94 mm²), the total is 6.6–8.8 mm², well within the 12.92 mm² core.

### Comparison with Run 1 Designs

| Design | Cells/mm² | Cells | Area (mm²) |
|--------|-----------|-------|------------|
| Cloneless1 (best) | 22,000 | 316,000 | 14.4 |
| Tiny Tapeout | 14,000 | 204,000 | 14.6 |
| KianV RISC-V | 6,000 | 89,000 | 14.8 |
| **GRX930 test chip** | **8,000** | **30,332** | **8.8** |

The GRX930 test chip is smaller than all Run 1 designs because we stripped it down to just one core + UART + SRAM.

### Cost

| Item | Cost |
|------|------|
| 1×1 slot (standard) | $8,000 |
| 1×1 slot (early bird) | $7,000 |
| Chip-on-board packaging | $1,500 |
| Full undiced wafer | $2,000 |
| **Total (slot + COB)** | **$9,500** |

**Per-die cost**: $8.00 (standard) / $7.00 (early bird)

### Timeline

- **Purchase deadline**: 9 December 2026
- **GDS submission**: 16 December 2026
- **Parts ship**: Q2 2027

### What's on the Test Chip

- ✅ 1× RV64IMAC core (64-bit, 5-stage in-order)
- ✅ 2KB I-cache + 2KB D-cache (tiny, BRAM-based)
- ✅ 64KB on-chip SRAM (boot/data memory)
- ✅ UART (16550, debug output)
- ✅ Boot ROM (256 bytes)
- ✅ GPIO (4-bit heartbeat LED)
- ✅ External interrupt

### What's Not on the Test Chip

- ❌ NPU (saves ~300K gates)
- ❌ Multi-core (saves 3× CPU + arbiter)
- ❌ DDR controller (uses on-chip SRAM)
- ❌ L2 cache (not needed for single core)
- ❌ APLIC (simplified interrupt)
- ❌ Cache coherency fabric

### Next Steps

1. **Synthesize** the test chip with GF180MCU cells
2. **Run P&R** to verify placement and routing
3. **DRC/LVS** to ensure clean submission
4. **Purchase slot** on Crowd Supply before 9 December 2026
5. **Submit GDS** to wafer.space by 16 December 2026
