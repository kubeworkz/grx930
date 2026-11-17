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
sub = by["sub"]
vss = by["vss"]
vdd = by["vdd"]
rail = by["$45264"]
abort("missing net") if [sub, vss, vdd, rail].any?(&:nil?)
r_sub = l2n.shapes_of_net(sub, m1, true)
r_rail = l2n.shapes_of_net(rail, m1, true)
r_vss = l2n.shapes_of_net(vss, m3, true)
r_vdd = l2n.shapes_of_net(vdd, m3, true)
def strips(region)
  ys = []
  region.each do |p|
    b = p.bbox
    ys << ((b.bottom + b.top) / 2) if b.width > 100_000 && b.height >= 1_000 && b.height <= 2_000
  end
  ys.uniq.sort
end
vss_strips = strips(r_vss)
vdd_strips = strips(r_vdd)
CELL = 10_000
grid = Hash.new { |h, k| h[k] = [] }
m2.each do |p|
  b = p.bbox
  (b.left / CELL..b.right / CELL).each do |kx|
    (b.bottom / CELL..b.top / CELL).each do |ky|
      grid[[kx, ky]] << [b.left, b.bottom, b.right, b.top]
    end
  end
end
def free?(grid, x, y0, y1, half, cell)
  ((x - half) / cell..(x + half) / cell).each do |kx|
    (y0 / cell..y1 / cell).each do |ky|
      grid[[kx, ky]].each do |b|
        return false if b[0] <= x + half && x - half <= b[2] && b[1] <= y1 && y0 <= b[3]
      end
    end
  end
  true
end
HALF = 700
PAD_Y = 450
M1_HALF = 450
M1_V = 390
M3_HALF = 450
M3_V = 400
def row_intervals(region, y)
  box = RBA::Box.new(0, y - 200, 4_000_000, y + 200)
  (region & RBA::Region.new(box)).each.map(&:bbox).map { |b| [b.left, b.right] }
end
def legal_at?(x, y, ty, grid, r_m1, r_m3)
  lo = [y, ty].min - PAD_Y
  hi = [y, ty].max + PAD_Y
  return false unless free?(grid, x, lo, hi, HALF, CELL)
  m1ok = (r_m1 & RBA::Region.new(RBA::Box.new(x - M1_HALF, y - M1_V, x + M1_HALF, y + M1_V))).count > 0
  m3ok = (r_m3 & RBA::Region.new(RBA::Box.new(x - M3_HALF, ty - M3_V, x + M3_HALF, ty + M3_V))).count > 0
  m1ok && m3ok
end
ys = []
top = RBA::Layout.new
top.read("/work/c930/asic_gf180mcu/build/lvs_chip/fill_regression_tie_final.gds")
gl_top = top.top_cell
lab = gl_top.layout.layer_infos.find { |x| x.layer == 34 && x.datatype == 10 }
RBA::Texts.new(gl_top.begin_shapes_rec(top.find_layer(lab))).each do |t|
  ys << t.y if t.string.upcase == "VSS"
end
ys.sort!
rows = []
ys.each do |y|
  rows << { sum: 0, n: 0, ymax: y } if rows.empty? || y - rows[-1][:ymax] > 300
  r = rows[-1]
  r[:sum] += y
  r[:n] += 1
  r[:ymax] = y
end
row_y = rows.map { |r| (r[:sum] / r[:n].to_f).round }
sites = []
[0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 540].each do |idx|
  y = row_y[idx]
  ty = vss_strips.min_by { |s| (s - y).abs }
  found = nil
  row_intervals(r_sub, y).each do |a, b|
    x = a + M1_HALF
    while x <= b - M1_HALF
      if legal_at?(x, y, ty, grid, r_sub, r_vss)
        found = x
        break
      end
      x += 5_000
    end
    break if found
  end
  abort("no site for row #{idx}") if found.nil?
  sites << ["sub_row_#{idx}", found, y, ty]
end
rb = r_rail.bbox
ry = (rb.bottom + rb.top) / 2
rty = vdd_strips.min_by { |s| (s - ry).abs }
rail_x = []
x = rb.left + M1_HALF
while x <= rb.right - M1_HALF
  rail_x << x if legal_at?(x, ry, rty, grid, r_rail, r_vdd)
  x += 1_000
end
abort("rail sites missing") if rail_x.size < 2
sites << ["rail_left", rail_x.first, ry, rty]
sites << ["rail_right", rail_x.last, ry, rty]

# Build a clean representative drop GDS. Each site contains:
# M1 rail patch 4x4, M2 strap 0.84 wide, M3 patch 4x1.6,
# via1 2x2 H_V, and via2 2x2 V_H at the target strip.
out = RBA::Layout.new
out.dbu = 0.001
cell = out.create_cell("drop_drc_sites")
l = {}
[[34, 0, :m1], [36, 0, :m2], [42, 0, :m3], [35, 0, :v1], [38, 0, :v2]].each do |ln, dt, name|
  l[name] = out.layer(ln, dt)
end
sites.each do |name, x, y, ty|
  cell.shapes(l[:m1]).insert(RBA::Box.new(x - 2000, y - 2000, x + 2000, y + 2000))
  cell.shapes(l[:m3]).insert(RBA::Box.new(x - 2000, ty - 800, x + 2000, ty + 800))
  m2_bottom = [y, ty].min - PAD_Y
  m2_top = [y, ty].max + PAD_Y
  cell.shapes(l[:m2]).insert(RBA::Box.new(x - 420, m2_bottom, x + 420, m2_top))
  # via1 cuts, 2x2, centers +/-260, cut 260
  [-260, 260].each do |dx|
    [-260, 260].each do |dy|
      cell.shapes(l[:v1]).insert(RBA::Box.new(x + dx - 130, y + dy - 130, x + dx + 130, y + dy + 130))
    end
  end
  # via2 cuts, 2x2, centers +/-260, cut 260
  [-260, 260].each do |dx|
    [-260, 260].each do |dy|
      cell.shapes(l[:v2]).insert(RBA::Box.new(x + dx - 130, ty + dy - 130, x + dx + 130, ty + dy + 130))
    end
  end
  puts "SITE\t#{name}\t#{(x*0.001).round(3)}\t#{(y*0.001).round(3)}\t#{(ty*0.001).round(3)}"
end
out.write("/scripts/drop_drc_sites.gds")
puts "WROTE /scripts/drop_drc_sites.gds CELLS=#{out.cells} SITES=#{sites.size}"
