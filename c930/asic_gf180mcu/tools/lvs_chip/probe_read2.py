import klayout.db as db
GDS="/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
CELL="gf180mcu_fd_sc_mcu7t5v0__clkinv_1"
def shapes(cell):
    n=0
    for li in cell.layout().layer_indexes():
        for _ in cell.shapes(li).each(): n+=1
    return n
o=db.LoadLayoutOptions()
print("LoadLayoutOptions attrs:", [a for a in dir(o) if not a.startswith('_')][:40])
try:
    o.cellname=CELL
    print("set cellname ok")
except Exception as e:
    print("cellname set failed:", e)
ly2=db.Layout(); ly2.read(GDS,o)
print("cells kept:", ly2.cells(), "top:", ly2.top_cell().name if ly2.cells() else None)
if ly2.cells(): print("shapes in top:", shapes(ly2.top_cell()), "names:", [x.name for x in ly2.each_cell()][:6])
