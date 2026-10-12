# KLayout script: DEF to GDS conversion for GRX930 test chip
# Usage: klayout -b -r def2gds_klayout.rb

lefname = "gf180mcu_pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0_combined_klayout.lef"
deffile = "build/grx930_test_chip.def"
outfile = "build/grx930_test_chip.gds"

layout = RBA::Layout.new
# DEF uses DATABASE MICRONS 2000 → 1 DBU = 0.5 nm = 0.0005 um
layout.dbu = 0.0005

layout.read(lefname)
puts "After LEF: #{layout.cells.size} cells, DBU=#{layout.dbu}"

layout.read(deffile)
puts "After DEF: #{layout.cells.size} cells"

top = layout.top_cell()
bb = top.bbox()
puts "Die area: #{bb.left*layout.dbu},#{bb.bottom*layout.dbu} to #{bb.right*layout.dbu},#{bb.top*layout.dbu} um"
area = (bb.right - bb.left) * (bb.top - bb.bottom) * layout.dbu * layout.dbu
puts "Die area: #{area} um^2 = #{area/1e6} mm^2"

layout.write(outfile)
puts "GDS written to #{outfile}"
