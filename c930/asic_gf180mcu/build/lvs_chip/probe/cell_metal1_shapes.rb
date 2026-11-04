# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_metal1_shapes.rb -- the drawn metal1/via1 of one library cell, merged, with bboxes.
#
# The LEF is an abstraction: it says the clock pin of clkinv_1 is y 0.970..2.950 and its VSS tab
# starts at 0.300. The GDS is what the netter sees, so this prints the real shapes and lets the
# rail/pin overlap be read off instead of inferred.
#
#   klayout -b -r cell_metal1_shapes.rb -rd lib=<pdk_fd_sc_mcu7t5v0.gds> -rd cell=clkinv_1
CELL = $cell || 'clkinv_1'
ly = RBA::Layout.new
ly.read($lib)
c = ly.cell(CELL) or (ly.each_cell { |cc| c = cc if cc.name.end_with?("__#{CELL}") }; c)
puts "cell #{c.name} box=#{c.bbox.to_s} dbu=#{ly.dbu}"
[[34, 0, 'metal1'], [35, 0, 'via1']].each do |ln, dt, label|
  li = ly.find_layer(ln, dt)
  next if li.nil?
  r = RBA::Region.new(c.begin_shapes_rec(li)).merged
  puts "-- #{label}: #{r.count} merged shapes"
  r.each do |p|
    bb = p.bbox
    puts format('   %8d..%-8d x %8d..%-8d  w=%5d h=%5d verts=%d',
                bb.left, bb.right, bb.bottom, bb.top, bb.width, bb.height, p.num_points)
  end
end
$stdout.flush
exit!(0)
