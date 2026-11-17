$stdout.sync = true
l2n = RBA::LayoutToNetlist.new
l2n.read("/scripts/chip.l2n")
cp = nil
l2n.netlist.each_circuit { |c| cp = c if c.name == "grx930_test_chip" }
by = {}
cp.each_net { |n| by[n.name] = n if n.name; by[n.expanded_name] = n if n.expanded_name }
m1 = l2n.layer_by_index(25)
rail = by["$45264"]
r = l2n.shapes_of_net(rail, m1, true)
b = r.bbox
puts "BBOX=#{b.left} #{b.bottom} #{b.right} #{b.top}"
shapes = []
r.each { |p| bb = p.bbox; shapes << [bb.left, bb.bottom, bb.right, bb.top, bb.width, bb.height] }
puts "SHAPES=#{shapes.size}"
puts "WIDTH_HIST=#{shapes.map { |s| s[4] }.tally.sort.to_h}"
puts "HEIGHT_HIST=#{shapes.map { |s| s[5] }.tally.sort.to_h}"
puts "Y_HIST=#{shapes.map { |s| (s[1] + s[3]) / 2 }.tally.sort.to_h}"
puts "FIRST20"
shapes.sort.first(20).each { |s| puts s.map { |v| (v * 0.001).round(3) }.inspect }
puts "LAST20"
shapes.sort.last(20).each { |s| puts s.map { |v| (v * 0.001).round(3) }.inspect }
# intervals at each distinct center y
ys = shapes.map { |s| (s[1] + s[3]) / 2 }.uniq.sort
ys.each do |y|
  ints = []
  shapes.each do |s|
    next unless s[1] <= y && y <= s[3]
    ints << [s[0], s[2]]
  end
  ints.sort!
  merged = []
  ints.each do |a, z|
    if merged.empty? || a > merged[-1][1]
      merged << [a, z]
    else
      merged[-1][1] = z if z > merged[-1][1]
    end
  end
  puts "Y=#{(y*0.001).round(3)} INTERVALS=#{merged.map { |a, z| [(a*0.001).round(3), (z*0.001).round(3)] }.inspect}"
end
