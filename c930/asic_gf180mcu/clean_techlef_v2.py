#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
"""Create a clean tech LEF:
1. Parse original VIARULEGEN blocks (with ENCLOSURE) to generate explicit VIAs
2. Remove ENCLOSURE from VIARULEGEN blocks (DRT doesn't support LEF58_ENCLOSURE)
3. Remove PROPERTY LEF58_EOLENCLOSURE (not supported)
4. Add explicit VIA definitions before END LIBRARY"""

import re

TECH_LEF = "gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0.tlef"
OUTPUT_LEF = "gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0_tlef_v3.tlef"

def main():
    with open(TECH_LEF) as f:
        content = f.read()

    # Step 1: Parse original VIARULEGEN blocks to generate explicit VIAs
    viarule_pattern = r'VIARULE\s+(\S+)\s+GENERATE\s*\n(.*?)END\s+\1\s*\n'
    viarules = re.findall(viarule_pattern, content, re.DOTALL)

    explicit_vias = []
    for name, body in viarules:
        layers = {}
        current_layer = None
        for line in body.split('\n'):
            line = line.strip()
            if line.startswith('LAYER '):
                current_layer = line.split()[1].rstrip(';')
                if current_layer not in layers:
                    layers[current_layer] = {}
            elif line.startswith('RECT ') and current_layer:
                coords = list(map(float, line.replace('RECT ', '').rstrip(';').split()))
                layers[current_layer]['rect'] = coords
            elif line.startswith('ENCLOSURE') and current_layer:
                enc = list(map(float, line.replace('ENCLOSURE', '').rstrip(';').split()))
                layers[current_layer]['enclosure'] = enc

        via_layer = None
        via_rect = None
        for ln, ld in layers.items():
            if ln.startswith('Via'):
                via_layer = ln
                via_rect = ld.get('rect')
                break
        if not via_layer or not via_rect:
            continue

        lines = [f'  VIA {name}']
        lines.append(f'    LAYER {via_layer} ;')
        lines.append(f'      RECT {via_rect[0]:.3f} {via_rect[1]:.3f} {via_rect[2]:.3f} {via_rect[3]:.3f} ;')
        for mname in ['Metal1', 'Metal2', 'Metal3', 'Metal4', 'Metal5']:
            if mname not in layers:
                continue
            mdata = layers[mname]
            if 'enclosure' in mdata:
                enc = mdata['enclosure']
                x1, y1, x2, y2 = via_rect
                if len(enc) >= 1 and enc[0] > 0:
                    x1 -= enc[0]; x2 += enc[0]
                if len(enc) >= 2 and enc[1] > 0:
                    y1 -= enc[1]; y2 += enc[1]
                lines.append(f'    LAYER {mname} ;')
                lines.append(f'      RECT {x1:.3f} {y1:.3f} {x2:.3f} {y2:.3f} ;')
            elif 'rect' in mdata:
                r = mdata['rect']
                lines.append(f'    LAYER {mname} ;')
                lines.append(f'      RECT {r[0]:.3f} {r[1]:.3f} {r[2]:.3f} {r[3]:.3f} ;')
        lines.append(f'  END {name}')
        explicit_vias.append('\n'.join(lines))

    print(f"Generated {len(explicit_vias)} explicit VIAs from original VIARULEGEN")

    # Step 2: Remove ENCLOSURE from VIARULEGEN blocks
    def remove_enclosure_from_viarule(match):
        block = match.group(0)
        lines = block.split('\n')
        cleaned = [l for l in lines if not l.strip().startswith('ENCLOSURE ')]
        return '\n'.join(cleaned)

    content = re.sub(
        r'VIARULE\s+\S+\s+GENERATE\n.*?END\s+\S+',
        remove_enclosure_from_viarule,
        content,
        flags=re.DOTALL
    )

    # Step 3: Remove PROPERTY LEF58_EOLENCLOSURE
    content = re.sub(r'  PROPERTY LEF58_EOLENCLOSURE "\n.*?" ;\n', '', content, flags=re.DOTALL)
    content = re.sub(r'  PROPERTY LEF58_EOLENCLOSURE "[^"]*" ;\n', '', content)

    # Step 4: Add explicit VIAs before END LIBRARY
    via_block = '\n'.join(explicit_vias)
    output = content.replace('END LIBRARY', f'{via_block}\n\nEND LIBRARY')

    with open(OUTPUT_LEF, 'w') as f:
        f.write(output)

    # Verify
    print(f"LEF58_EOLENCLOSURE count: {output.count('LEF58_EOLENCLOSURE')}")
    print(f"Lines: {len(output.splitlines())}")
    print(f"Written to {OUTPUT_LEF}")


if __name__ == '__main__':
    main()
