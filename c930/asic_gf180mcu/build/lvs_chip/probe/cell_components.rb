# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_components.rb -- merged metal1 components inside library cells.
# If a cell's pin metal were shorted to its own rail, the merge would show fewer components than
# the cell has separate metal1 polygons, and the rail component would reach into the row.
#
#   klayout -b -r cell_components.rb -rd lib=<pdk_fd_sc_mcu7t5v0.gds>
ly = RBA::Layout.new
ly.read($lib)
m1 = ly.layer(34, 0)
%w[clkinv_1 dffq_1 mux2_1 nand2_1 filltie fill_2].each do |n|
  c = ly.cell("gf180mcu_fd_sc_mcu7t5v0__#{n}")
  next unless c
  r = RBA::Region.new(c.begin_shapes_rec(m1))
  m = r.merged
  puts "#{n}: raw=#{r.count} merged=#{m.count}"
  m.each do |p|
    bb = p.bbox
    puts format('   %6d..%-6d x %6d..%-6d h=%5d', bb.left, bb.right, bb.bottom, bb.top, bb.height)
  end
end
$stdout.flush
exit!(0)
