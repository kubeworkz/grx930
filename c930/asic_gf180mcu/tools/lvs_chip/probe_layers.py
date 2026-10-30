# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
import gzip, os, tempfile
import klayout.db as db

def infos(path, label):
    if path.endswith(".gz"):
        tmp = tempfile.NamedTemporaryFile(suffix=".gds", delete=False)
        with gzip.open(path, "rb") as s:
            tmp.write(s.read())
        tmp.close(); path = tmp.name
    ly = db.Layout(); ly.read(path)
    got = [f"{i.layer}/{i.datatype}:{i.name}" for i in ly.layer_infos()]
    print(f"-- {label}: {ly.cells()} cells, {len(got)} layers")
    print("   first 12:", got[:12])
    print("   named:", [g for g in got if not g.endswith(":")][:12])

infos("/work/c930/asic_gf180mcu/libs.tech/klayout/tech/lvs/testing/unit/mos_devices/layout/nfet_05v0.gds.gz", "PDK fixture nfet_05v0")
infos("/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds", "our die")
infos("/work/c930/asic_gf180mcu/build/lvs_chip/probe/clkinv_probe.gds", "our probe")
