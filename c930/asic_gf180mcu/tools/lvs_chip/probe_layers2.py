import klayout.db as db
GDS="/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
ly=db.Layout(); ly.read(GDS); top=ly.top_cell()
from collections import Counter
c=Counter()
for li in ly.layer_indexes():
    info=ly.get_info(li)
    rc=0; text=0
    # count recursively from the top
    it = top.begin_shapes_rec(li)
    while not it.at_end():
        sh = it.shape()
        rc += 1
        if sh.is_text():
            text += 1
        it.next()
    c[(info.layer, info.datatype, info.name)]= (rc, text)
for k,(n,t) in sorted(c.items(), key=lambda kv:-kv[1][0])[:30]:
    print(f"  {k[0]}/{k[1]} name={k[2]!r}: shapes={n} texts={t}")
