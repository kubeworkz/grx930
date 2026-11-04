# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# window_shapes.rb -- every metal shape in a small window, layer by layer.
#
# When a component probe says "this rail island also holds a via1", the next question is what the
# metal actually is. This prints the shapes themselves, so a via1 pad that missed its pin is
# visible as geometry rather than inferred from a bbox.
#
#   klayout -b -r window_shapes.rb -rd gds=<file.gds> -rd x0=2431920 -rd y0=2608320 \
#            -rd x1=2433920 -rd y1=2610320
X0 = ($x0 || 0).to_i
Y0 = ($y0 || 0).to_i
X1 = ($x1 || X0 + 2000).to_i
Y1 = ($y1 || Y0 + 2000).to_i

ly = RBA::Layout.new
ly.read($gds)
top = ly.top_cell
box = RBA::Box.new(X0, Y0, X1, Y1)
puts format('window %s  gds=%s', box.to_s, $gds)
[[34, 0, 'metal1'], [35, 0, 'via1'], [36, 0, 'metal2'], [37, 0, 'via2'],
 [42, 0, 'metal3'], [43, 0, 'via3'], [46, 0, 'metal4'], [81, 0, 'metal5']].each do |ln, dt, label|
  li = ly.find_layer(ln, dt)
  next if li.nil?
  reg = RBA::Region.new(top.begin_shapes_rec(li)) & RBA::Region.new(box)
  next if reg.is_empty?
  puts "-- #{label} (#{ln}/#{dt}): #{reg.count} pieces"
  i = 0
  reg.each do |p|
    bb = p.bbox
    puts format('   %8d..%-8d x %8d..%-8d  w=%5d h=%5d area=%d',
                bb.left, bb.right, bb.bottom, bb.top, bb.width, bb.height, p.area)
    i += 1
    break if i >= 40
  end
end

# Names: the streamed file carries the DEF's net labels on the metal's label layer.
[[34, 10], [36, 10], [42, 10], [46, 10], [81, 10], [0, 0]].each do |ln, dt|
  li = ly.find_layer(ln, dt)
  next if li.nil?
  puts "-- texts on #{ln}/#{dt}"
  top.shapes(li).each do |s|
    next unless s.is_text?
    p = s.text.trans.disp
    next unless box.contains?(p)
    puts format('   %-40s at (%d,%d)', s.text.string[0, 40], p.x, p.y)
  end
end
$stdout.flush
exit!(0)
