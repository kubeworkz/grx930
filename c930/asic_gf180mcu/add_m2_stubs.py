#!/usr/bin/env python3
"""Add Metal2 RECT stubs to clock buffer I pins in the cell LEF.
This gives DRT a Metal2 access point so it can route clock buffer inputs."""

import re

CELL_LEF = "gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0_combined_clean.lef"
OUTPUT_LEF = "gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0_combined_m2stub.lef"

CLOCK_CELLS = [
    'clkbuf_1', 'clkbuf_2', 'clkbuf_4', 'clkbuf_8', 'clkbuf_12', 'clkbuf_16',
    'clkinv_1', 'clkinv_2', 'clkinv_4', 'clkinv_8'
]


def main():
    with open(CELL_LEF) as f:
        lef = f.read()

    count = 0
    for cell in CLOCK_CELLS:
        full_cell = f'gf180mcu_fd_sc_mcu7t5v0__{cell}'

        # Find this specific MACRO block
        macro_pat = rf'(MACRO {re.escape(full_cell)}\b.*?END {re.escape(full_cell)})'
        macro_m = re.search(macro_pat, lef, re.DOTALL)
        if not macro_m:
            print(f"  SKIP {cell}: MACRO not found")
            continue

        macro_text = macro_m.group(1)

        # Find PIN I section within this MACRO
        pin_m = re.search(r'(  PIN I\n.*?  END I)', macro_text, re.DOTALL)
        if not pin_m:
            print(f"  SKIP {cell}: PIN I not found")
            continue

        pin_text = pin_m.group(1)

        # Find Metal1 RECT within the PIN I section
        rect_m = re.search(r'(LAYER Metal1 ;\n        RECT )([\d.]+ [\d.]+ [\d.]+ [\d.]+)', pin_text)
        if not rect_m:
            print(f"  SKIP {cell}: Metal1 RECT not found")
            continue

        coords = rect_m.group(2)
        parts = list(map(float, coords.split()))
        x1, y1, x2, y2 = parts
        # Metal2 stub: same X range, expanded Y by 0.1um
        m2_coords = f'{x1-0.1:.3f} {y1-0.1:.3f} {x2+0.1:.3f} {y2+0.1:.3f}'

        # Insert Metal2 RECT after Metal1 RECT line
        metal2_line = f'      LAYER Metal2 ;\n        RECT {m2_coords} ;\n'
        new_pin = pin_text[:rect_m.end()] + '\n' + metal2_line + pin_text[rect_m.end():]

        # Replace in macro
        new_macro = macro_text[:pin_m.start()] + new_pin + macro_text[pin_m.end():]

        # Replace in full LEF
        lef = lef[:macro_m.start()] + new_macro + lef[macro_m.end():]
        count += 1
        print(f"  Fixed {cell}: Metal2 RECT {m2_coords}")

    with open(OUTPUT_LEF, 'w') as f:
        f.write(lef)

    print(f"\nFixed {count} cells -> {OUTPUT_LEF}")


if __name__ == '__main__':
    main()
