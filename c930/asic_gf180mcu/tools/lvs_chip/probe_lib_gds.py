import glob
import klayout.db as db

paths = [
    "/work/c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/gds/gf180mcu_fd_sc_mcu7t5v0.gds",
]
paths += sorted(glob.glob("/work/c930/asic_gf180mcu/gf180mcu_pdk/libs.ref/gf180mcu_fd_io/gds/*.gds"))[:1]
paths += sorted(glob.glob("/work/c930/asic_gf180mcu/wafer_space_integration/**/*.gds", recursive=True))[:5]
for f in paths:
    ly = db.Layout()
    try:
        ly.read(f)
    except Exception as e:
        print(f"{f}: READ FAILED {e}")
        continue
    infos = sorted({(i.layer, i.datatype) for i in ly.layer_infos()})
    c = ly.cell("gf180mcu_fd_sc_mcu7t5v0__clkinv_1")
    labels = []
    if c is not None:
        for li in ly.layer_indexes():
            info = ly.get_info(li)
            for sh in c.shapes(li).each():
                if sh.is_text():
                    labels.append(f"{info.layer}/{info.datatype}:{sh.text.string}")
    print(f"{f.replace('/work/c930/asic_gf180mcu/','')}: {len(infos)} layers, comp22/0={'yes' if (22,0) in infos else 'no'}")
    print(f"    {infos[:16]}")
    if labels:
        print(f"    clkinv_1 labels: {labels[:8]}")
