# wafer.space GF180MCU Submission Checklist

## Quick Reference

| Item | Value |
|------|-------|
| **Slot** | 1×1 (full) |
| **Die size** | 3.93mm × 5.12mm |
| **Core area** | 12.92 mm² |
| **I/O pads** | 56 default, up to 168 |
| **Cost** | $8,000 (standard) / $7,000 (early bird) |
| **Quantity** | 1,000 bare dies |
| **Deadline** | 16 December 2026 |

## Files to Submit

1. ✅ `grx930_test_chip_routed.gds` — Final GDS (with seal ring)
2. ✅ `grx930_test_chip_routed.v` — Gate-level Verilog netlist
3. ✅ `grx930_test_chip_routed.spef` — Parasitic extraction
4. ✅ `pad_ring.cfg` — Pad ring configuration
5. ✅ `drc.log` — DRC report (must be clean)
6. ✅ `lvs.log` — LVS report (must be clean)

## Verification Requirements

- [ ] DRC clean (zero violations)
- [ ] LVS clean (netlist matches layout)
- [ ] Timing clean (setup/hold met at 50 MHz)
- [ ] Area within budget (≤12.92 mm² core)
- [ ] Seal ring included in GDS
- [ ] Pad ring matches default (56 pads)

## Timeline

| Milestone | Date |
|-----------|------|
| Early bird deadline | 30 September 2026 |
| Purchase deadline | 9 December 2026 |
| GDS submission | 16 December 2026 |
| Parts ship | Q2 2027 |

## Cost Breakdown

| Item | Standard | Early Bird |
|------|----------|------------|
| 1×1 slot | $8,000 | $7,000 |
| + Chip-on-board | +$1,500 | +$1,500 |
| + Full wafer | +$2,000 | +$2,000 |
| **Slot + COB** | **$9,500** | **$8,500** |
| **Slot + Wafer** | **$10,000** | **$9,000** |

## Per-Die Cost

| Quantity | Standard | Early Bird |
|----------|----------|------------|
| 1,000 dies | $8.00/die | $7.00/die |
| + COB (1,000) | $9.50/die | $8.50/die |

## Design Fit Check

| Component | Area | Budget |
|-----------|------|--------|
| Logic (30K cells) | 2.2–3.8 mm² | |
| SRAM (64KB, 128 macros) | 2.94 mm² | |
| Routing (30%) | 1.5–2.0 mm² | |
| **Total** | **6.6–8.8 mm²** | **12.92 mm²** ✅ |

## Commands

```bash
# Build the design
cd c930/asic_gf180mcu
make synth
make pnr
make signoff

# Prepare submission
make submit

# Check results
ls -la build/submission/
```

## Contact

- **wafer.space**: https://wafer.space
- **Discord**: https://discord.gg/wafer-space
- **Email**: info@wafer.space
- **Address**: 143 Cecil Street, #17-04, GB Building, Singapore 069542
