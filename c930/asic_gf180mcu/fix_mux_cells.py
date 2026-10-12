#!/usr/bin/env python3
"""Replace $_MUX_ cells with gf180mcu_fd_sc_mcu7t5v0__mux2_1 in synthesized Verilog."""

import re
import sys

input_file = "build/grx930_test_chip_synth_v4.v"
output_file = "build/grx930_test_chip_synth_final.v"

with open(input_file, 'r') as f:
    content = f.read()

# Count before
count_before = content.count('\\$_MUX_')
print(f"Found {count_before} $_MUX_ instances")

# Replace: \$_MUX_  <name> ( .A(...), .B(...), .S(...), .Y(...) );
# With:    gf180mcu_fd_sc_mcu7t5v0__mux2_1 <name> ( .I0(...), .I1(...), .S(...), .Z(...) );

# Step 1: Replace the cell type
content = content.replace('\\$_MUX_', 'gf180mcu_fd_sc_mcu7t5v0__mux2_1')

# Step 2: Replace port names (A→I0, B→I1, Y→Z, S stays S)
# Be careful to only replace within MUX instances
# Since we already replaced the cell type, we can do simple replacements
# But we need to be careful not to replace .A and .B in other cells

# Strategy: replace .A( with .I0( and .B( with .I1( only near mux2_1 instances
# Actually, since the Verilog is structural and the port names are unique enough,
# let's use a regex that matches the mux2_1 instantiation pattern

def replace_mux_ports(match):
    """Replace ports in a mux2_1 instantiation."""
    text = match.group(0)
    text = re.sub(r'\.A\(', '.I0(', text)
    text = re.sub(r'\.B\(', '.I1(', text)
    text = re.sub(r'\.Y\(', '.Z(', text)
    return text

# Match mux2_1 instantiations (they were $_MUX_ before replacement)
pattern = r'gf180mcu_fd_sc_mcu7t5v0__mux2_1\s+\S+\s*\([^;]+\);'
content = re.sub(pattern, replace_mux_ports, content, flags=re.DOTALL)

# Verify
count_after_mux = content.count('\\$_MUX_')
count_mux2_1 = content.count('gf180mcu_fd_sc_mcu7t5v0__mux2_1')
print(f"After: {count_after_mux} $_MUX_ remaining, {count_mux2_1} mux2_1 instances")

# Also check for any remaining generic cells
generic_count = len(re.findall(r'\\\$[A-Z][A-Z_0-9]+', content))
print(f"Remaining generic cell references: {generic_count}")

with open(output_file, 'w') as f:
    f.write(content)

print(f"Written to {output_file}")
