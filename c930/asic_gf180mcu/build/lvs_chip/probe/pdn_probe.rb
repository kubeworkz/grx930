# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# pdn_probe.rb -- what is actually drawn at a populated row boundary?
#
# The lvsdb splits VDD into 14,175 nets and VNW (PFET bodies) into the nwell islands, so something
# that should tie the rails together is not there. This counts each layer in a thin band at a row
# boundary that has cells above and below it (row at DEF y=4805920 -> gds 2402960; its top rail is at
# gds 2406880). Vias in the band are what a PDN drop to the rails would look like.
#
#   klayout -b -r pdn_probe.rb -rd gds=<stream_out.gds> [-rd y=2406400 -rd half=200]
Y = ($y || 2_406_400).to_i
HALF = ($half || 200).to_i
LAYERS = [
  ['nwell',  21, 0],
  ['metal1', 34, 0],
  ['via1',   35, 0],
  ['metal2', 36, 0],
  ['via2',   38, 0],
  ['metal3', 42, 0],
  ['via3',   40, 0],
  ['metal4', 46, 0],
  ['via4',   41, 0],
  ['metal5', 81, 0]
]

t0 = Time.now
ly = RBA::Layout.new
ly.read($gds)
puts format('dbu=%.4f bbox=%s', ly.dbu, ly.top_cell.bbox.to_s)
band = RBA::Box.new(0, Y - HALF, ly.top_cell.bbox.right, Y + HALF)
LAYERS.each do |name, l, d|
  reg = RBA::Region.new(ly.top_cell.begin_shapes_rec(ly.layer(l, d))) & RBA::Region.new(band)
  n = reg.count
  next if n.zero?
  bb = reg.bbox
  puts format('%-7s shapes=%-7d area=%-12d x %8d..%-8d y %8d..%-8d',
              name, n, reg.area, bb.left, bb.right, bb.bottom, bb.top)
end
puts format('ELAPSED %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
