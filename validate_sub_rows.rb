$stdout.sync = true
gds_path = "/work/c930/asic_gf180mcu/build/lvs_chip/fill_regression_tie_final.gds"
gl = RBA::Layout.new
gl.read(gds_path)
top = gl.top_cell
def gidx(gl, ln, dt)
  li = gl.layer_infos.find { |x| x.layer == ln && x.datatype == dt }
  li && gl.find_layer(li)
end
m1lab = gidx(gl, 34, 10)
ys = []
RBA::Texts.new(top.begin_shapes_rec(m1lab)).each do |t|
  ys << t.y if t.string.upcase == "VSS"
end
ys.sort!
rows = []
ys.each do |y|
  if rows.empty? || y - rows[-1][:ymax] > 300
    rows << { ymin: y, ymax: y, n: 0, sum: 0 }
  end
  r = rows[-1]
  r[:ymax] = y
  r[:n] += 1
  r[:sum] += y
end
puts "VSS_LABELS=#{ys.size} VSS_ROWS=#{rows.size}"
puts "ROW_Y=#{rows.map { |r| (r[:sum] / r[:n].to_f * gl.dbu).round(3) }.inspect}"

l2n = RBA::LayoutToNetlist.new
l2n.read("/scripts/chip.l2n")
cp = nil
l2n.netlist.each_circuit { |c| cp = c if c.name == "grx930_test_chip" }
sub = nil
cp.each_net { |n| sub = n if n.name == "sub" || n.expanded_name == "sub" }
abort("no sub net") if sub.nil?
m1 = l2n.layer_by_index(25)
rr = l2n.shapes_of_net(sub, m1, true)
abort("no sub M1") if rr.nil? || rr.count == 0
covered = 0
missing = []
rows.each_with_index do |r, i|
  y = (r[:sum] / r[:n].to_f).round
  box = RBA::Box.new(0, y - 200, 4_000_000, y + 200)
  hit = (rr & RBA::Region.new(box)).count > 0
  covered += 1 if hit
  missing << [(y * gl.dbu).round(3), i] unless hit
end
puts "SUB_COVERED_ROWS=#{covered} MISSING_ROWS=#{missing.size}"
missing.first(30).each { |m| puts "  missing_y=#{m[0]} row_index=#{m[1]}" }
