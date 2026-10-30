# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
import glob
import klayout.db as db
files = sorted(glob.glob("/work/c930/asic_gf180mcu/build/*.gds") + glob.glob("/work/c930/asic_gf180mcu/wafer_space_submission/*.gds"))
for f in files:
    ly = db.Layout()
    try:
        ly.read(f)
    except Exception as e:
        print(f"{f}: READ FAILED {e}")
        continue
    infos = sorted({(i.layer, i.datatype) for i in ly.layer_infos()})
    tops = [c.name for c in ly.top_cells()][:3]
    has_pdk = (22, 0) in infos
    print(f"{f.split('/')[-1]}: {len(infos)} layers, comp22/0={'yes' if has_pdk else 'no'}, tops={tops[:2]}")
    print(f"    {infos[:14]}")
