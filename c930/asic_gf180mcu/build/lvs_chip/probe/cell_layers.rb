# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_layers.rb -- which drawn layers does a filler or tap cell carry?
#
# The 190 bulk mismatches sit on wells with no supply. Whether a cell's well can reach a tap
# depends on the neighbours: a `fill_*` cell with no NWELL (21/0) cuts the well between a design
# cell and the next `filltie`, and a `filltie` is the only filler that draws the tap.
#
#   klayout -b -r cell_layers.rb -rd gds=<library.gds>
GDS = $gds
abort('usage: -rd gds=<library.gds>') unless GDS

CELLS = %w[gf180mcu_fd_sc_mcu7t5v0__fill_1 gf180mcu_fd_sc_mcu7t5v0__fill_2
           gf180mcu_fd_sc_mcu7t5v0__fill_4 gf180mcu_fd_sc_mcu7t5v0__fill_8
           gf180mcu_fd_sc_mcu7t5v0__fill_16 gf180mcu_fd_sc_mcu7t5v0__filltie
           gf180mcu_fd_sc_mcu7t5v0__dffq_1 gf180mcu_fd_sc_mcu7t5v0__mux2_1].freeze

ly = RBA::Layout.new
ly.read(GDS)
CELLS.each do |cn|
  c = ly.cell(cn)
  unless c
    puts "#{cn}: not in this GDS"
    next
  end
  parts = []
  ly.layer_indexes.each do |li|
    n = 0
    c.shapes(li).each { |_s| n += 1 }
    next if n.zero?
    info = ly.get_info(li)
    parts << format('%d/%d=%d', info.layer, info.datatype, n)
  end
  puts "#{cn.sub('gf180mcu_fd_sc_mcu7t5v0__', '')}: #{parts.join(' ')}"
end
$stdout.flush
exit!(0)
