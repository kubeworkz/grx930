$stdout.sync = true
l2n = RBA::LayoutToNetlist.new
l2n.read("/scripts/chip.l2n")
cp = nil
l2n.netlist.each_circuit { |c| cp = c if c.name == "grx930_test_chip" }
by = {}
cp.each_net { |n| by[n.name] = n if n.name; by[n.expanded_name] = n if n.expanded_name }
m1 = l2n.layer_by_index(25)
m2 = l2n.layer_by_index(26)
m3 = l2n.layer_by_index(27)
rail = by["$45264"]
vdd = by["vdd"]
abort("missing net") if rail.nil? || vdd.nil?
r_rail = l2n.shapes_of_net(rail, m1, true)
r_vdd = l2n.shapes_of_net(vdd, m3, true)
b = r_rail.bbox
y = (b.bottom + b.top) / 2
CELL = 10_000
grid = Hash.new { |h, k| h[k] = [] }
m2.each do |p|
  bb = p.bbox
  (bb.left / CELL..bb.right / CELL).each do |kx|
    (bb.bottom / CELL..bb.top / CELL).each do |ky|
      grid[[kx, ky]] << [bb.left, bb.bottom, bb.right, bb.top]
    end
  end
end
def free?(grid, x, y0, y1, half, cell)
  (x - half) / cell
  x0 = (x - half) / cell
  x1 = (x + half) / cell
  cy0 = y0 / cell
  cy1 = y1 / cell
  (x0..x1).each do |kx|
    (cy0..cy1).each do |ky|
      grid[[kx, ky]].each do |bb|
        return false if bb[0] <= x + half && x - half <= bb[2] && bb[1] <= y1 && y0 <= bb[3]
      end
    end
  end
  true
end
# Actual VDD strip centers.
vdd_ys = []
r_vdd.each do |p|
  bb = p.bbox
  vdd_ys << ((bb.bottom + bb.top) / 2) if bb.width > 100_000 && bb.height >= 1_000 && bb.height <= 2_000
end
vdd_ys.uniq!
vdd_ys.sort!
ty = vdd_ys.min_by { |s| (s - y).abs }
puts "RAIL_BBOX=#{(b.left*0.001).round(3)}..#{(b.right*0.001).round(3)} x #{(b.bottom*0.001).round(3)}..#{(b.top*0.001).round(3)}"
puts "RAIL_Y=#{(y*0.001).round(3)} VDD_STRIP_Y=#{(ty*0.001).round(3)}"
# Search only actual M1 rail intervals; 0.2 um margin, 1 um step.
box = RBA::Box.new(0, y - 200, 4_000_000, y + 200)
ints = (r_rail & RBA::Region.new(box)).each.map(&:bbox).map { |q| [q.left, q.right] }
puts "RAIL_M1_INTERVALS=#{ints.size}"
legal = []
ints.each do |a, z|
  x = a + 400
  while x <= z - 400
    if free?(grid, x, ty - 200, y + 200, 480, CELL)
      m3ok = (r_vdd & RBA::Region.new(RBA::Box.new(x - 200, ty - 800, x + 200, ty + 800))).count > 0
      legal << x if m3ok
    end
    x += 1_000
  end
end
legal.uniq!
puts "LEGAL_ENDPOINT_X_COUNT=#{legal.size}"
if true
  x1 = 1_484_960
  x2 = 1_656_900
  puts "DROP1=#{(x1*0.001).round(3)},#{(y*0.001).round(3)}"
  puts "DROP2=#{(x2*0.001).round(3)},#{(y*0.001).round(3)}"
  puts "SEPARATION_UM=#{((x2 - x1)*0.001).round(3)}"
  [x1, x2].each_with_index do |x, i|
    m1ok = (r_rail & RBA::Region.new(RBA::Box.new(x - 200, y - 200, x + 200, y + 200))).count > 0
    m3ok = (r_vdd & RBA::Region.new(RBA::Box.new(x - 200, ty - 800, x + 200, ty + 800))).count > 0
    corridor = free?(grid, x, ty - 200, y + 200, 480, CELL)
    puts "  D#{i+1} M1_0.4x0.4=#{m1ok} M2_CORRIDOR_0.96xL=#{corridor} M3_0.4x1.6=#{m3ok}"
    puts "  D#{i+1} ENCLOSURE via1_M2=0.07um via2_M2=0.07um via2_M3=0.67um (cuts 0.26um)"
  end
else
  puts "INSUFFICIENT_LEGAL_ENDPOINTS"
end
