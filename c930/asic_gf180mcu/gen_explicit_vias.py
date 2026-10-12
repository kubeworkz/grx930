#!/usr/bin/env python3
"""Generate explicit VIA definitions from VIARULEGEN in the tech LEF.
The VIARULEGEN rules specify ENCLOSURE values for metal layers and RECT for via cuts.
We need to compute the metal RECT as via_rect expanded by enclosure values."""

import re

TECH_LEF = "gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0.tlef"
OUTPUT_LEF = "gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0_with_vias.tlef"


def parse_viarulegen_blocks(techlef_text):
    """Parse VIARULEGEN blocks and extract layer info."""
    results = []
    # Match VIARULE xxx GENERATE ... END xxx
    pattern = r'VIARULE\s+(\S+)\s+GENERATE\s*\n(.*?)END\s+\1\s*\n'
    for m in re.finditer(pattern, techlef_text, re.DOTALL):
        name = m.group(1)
        body = m.group(2)
        
        layers = {}
        current_layer = None
        
        for line in body.split('\n'):
            line = line.strip()
            if not line:
                continue
            
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
            elif line.startswith('SPACING') and current_layer:
                pass  # Ignore SPACING for explicit VIAs
        
        results.append((name, layers))
    return results


def generate_explicit_via(name, layers):
    """Generate an explicit VIA definition from parsed layers."""
    # Find via cut layer
    via_layer = None
    via_rect = None
    for lname, ldata in layers.items():
        if lname.startswith('Via'):
            via_layer = lname
            via_rect = ldata.get('rect')
            break
    
    if not via_layer or not via_rect:
        return None
    
    lines = [f'  VIA {name}']
    
    # Via cut layer
    lines.append(f'    LAYER {via_layer} ;')
    lines.append(f'      RECT {via_rect[0]:.3f} {via_rect[1]:.3f} {via_rect[2]:.3f} {via_rect[3]:.3f} ;')
    
    # Metal layers: compute RECT from via_rect + enclosure
    metal_order = ['Metal1', 'Metal2', 'Metal3', 'Metal4', 'Metal5']
    for mname in metal_order:
        if mname not in layers:
            continue
        mdata = layers[mname]
        
        if 'enclosure' in mdata:
            enc = mdata['enclosure']
            # ENCLOSURE enc1 enc2:
            # enc1 = enclosure in direction perpendicular to wire (expand in both X and Y)
            # enc2 = enclosure in direction parallel to wire (often 0)
            # For explicit VIA: expand via_rect by enclosure values
            x1 = via_rect[0]
            y1 = via_rect[1]
            x2 = via_rect[2]
            y2 = via_rect[3]
            
            if len(enc) >= 1 and enc[0] > 0:
                x1 -= enc[0]
                x2 += enc[0]
            if len(enc) >= 2 and enc[1] > 0:
                y1 -= enc[1]
                y2 += enc[1]
            
            lines.append(f'    LAYER {mname} ;')
            lines.append(f'      RECT {x1:.3f} {y1:.3f} {x2:.3f} {y2:.3f} ;')
        elif 'rect' in mdata:
            # Metal layer has explicit RECT (unusual but handle it)
            r = mdata['rect']
            lines.append(f'    LAYER {mname} ;')
            lines.append(f'      RECT {r[0]:.3f} {r[1]:.3f} {r[2]:.3f} {r[3]:.3f} ;')
    
    lines.append(f'  END {name}')
    return '\n'.join(lines)


def main():
    with open(TECH_LEF) as f:
        techlef = f.read()
    
    # Parse VIARULEGEN blocks
    viarule_blocks = parse_viarulegen_blocks(techlef)
    print(f"Parsed {len(viarule_blocks)} VIARULEGEN blocks")
    
    # Generate explicit VIAs
    explicit_vias = []
    for name, layers in viarule_blocks:
        via_def = generate_explicit_via(name, layers)
        if via_def:
            explicit_vias.append(via_def)
            print(f"  Generated VIA: {name} (layers: {list(layers.keys())})")
        else:
            print(f"  SKIPPED: {name}")
    
    print(f"\nGenerated {len(explicit_vias)} explicit VIA definitions")
    
    # Build the VIA block
    via_block = '\n'.join(explicit_vias)
    
    # Insert before END LIBRARY
    output = techlef.replace('END LIBRARY', f'{via_block}\n\nEND LIBRARY')
    
    with open(OUTPUT_LEF, 'w') as f:
        f.write(output)
    
    print(f"Written to {OUTPUT_LEF}")
    print(f"File size: {len(output)} bytes")


if __name__ == '__main__':
    main()
