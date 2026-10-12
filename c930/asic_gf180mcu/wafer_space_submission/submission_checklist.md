# wafer.space Submission Checklist for GRX930

## Pre-Submission Verification

### Design Specifications
- [ ] Die size: 3930 × 5120 µm (wafer.space 1×1 slot)
- [ ] Process: GF180MCU 180nm
- [ ] Metal stack: 5LM_1TM_11K
- [ ] Standard cell library: gf180mcu_fd_sc_mcu7t5v0

### DRC/LVS Verification
- [ ] Run DRC check on GDS
- [ ] Run LVS check (netlist vs layout)
- [ ] Verify zero DRC violations
- [ ] Verify zero LVS errors

### GDS File Requirements
- [ ] Single top cell
- [ ] Correct layer mapping (see verify_layers.py)
- [ ] File size reasonable (77 MB expected)
- [ ] No proprietary or restricted layers

### Pin/PAD Requirements
- [ ] All I/O pins on proper metal layers
- [ ] Pin naming matches schematic
- [ ] Minimum pin width满足 foundry rules
- [ ] ESD protection on I/O pads

### Power Grid
- [ ] VDD/VSS stripes on Metal4/Metal5
- [ ] Follow-pin connections on Metal1
- [ ] Via connections between metal layers
- [ ] No floating power nets

### Seal Ring (if required)
- [ ] Seal ring around die edge
- [ ] Proper spacing from core logic
- [ ] Connected to VDD/VSS

## Submission Package Contents

- [ ] `grx930_test_chip_final.gds` - Final layout
- [ ] `README.md` - Design documentation
- [ ] `verify_layers.py` - Layer verification script
- [ ] `submission_checklist.md` - This file

## wafer.space Specific Requirements

### Area Allocation
- [ ] Confirm slot availability on wafer
- [ ] Verify die fits in 1×1 slot
- [ ] Check for conflicts with other designs

### Foundry Rules
- [ ] GF180MCU DRC clean
- [ ] Minimum feature size compliance
- [ ] Antenna rules satisfied
- [ ] Density rules met (metal fill if needed)

### Documentation
- [ ] Design description
- [ ] Pin assignment table
- [ ] Power consumption estimate
- [ ] Target application

## Post-Submission

- [ ] Receive confirmation from wafer.space
- [ ] Review any DRC violations from foundry
- [ ] Make corrections if needed
- [ ] Resubmit if required

## Contact Information

- Design Team: GRX930 Development
- Submission Date: [Current Date]
- wafer.space Account: [Your Account]
