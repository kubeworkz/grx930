# DEF/GDS consistency checks for G0.
# Required -rd values: gds, def, expected_drops, report.
#
# Full-chip checks (always run):
#   the DEF's own NETS/SPECIALNETS routing is rebuilt as top-level metal and
#   XORed against the frozen GDS; the N ECO drops must be present as the
#   approved 2x2 Via1/Via2 names, and each must match the GDS cut array at its
#   DEF anchor.
#
# Windowed checks (when -rd base, -rd base_def and -rd sites are all given):
#   inside each site window, (final.gds - base.gds) must equal
#   (eco_routed.def - filled.def); no new metal or Via1/Via2 cut may fall
#   outside the site windows. The window is the Stage 6 crop window: x +-1.5 um,
#   y from min(y,ty)-1.5 um to max(y,ty)+1.5 um, in GDS dbu (1 nm). One
#   WINDOW line per site is reported.
$stdout.sync = true

gds = $gds
def_file = $def
base_gds = $base
base_def_file = $base_def
sites_file = $sites
topcell = $topcell || "grx930_test_chip"
raise "missing expected_drops (-rd expected_drops=<N>)" if $expected_drops.nil? || $expected_drops.to_s.empty?
expected_drops = $expected_drops.to_i
report = $report || "/work/build/production/manifests/def_gds_checks.txt"

raise "missing gds path" if gds.nil? || gds.empty?
raise "missing DEF path" if def_file.nil? || def_file.empty?

given = [base_gds, base_def_file, sites_file].count { |v| v && !v.to_s.empty? }
windowed = given == 3
raise "windowed checks need all of -rd base, -rd base_def and -rd sites" if given.positive? && !windowed

# DEF layer name -> PDK GDS layer. Coordinates are converted from DEF units
# (2000/um) to the GDS' 0.001 um dbu by dividing by two.
LAYERS = {
  "Metal1" => [5, 0, 34, 0],
  "Metal2" => [7, 0, 36, 0],
  "Metal3" => [9, 0, 42, 0],
  "Metal4" => [11, 0, 46, 0],
  "Metal5" => [13, 0, 81, 0],
}.freeze
WIDTHS = {
  "Metal1" => 460,   # 0.230 um at 2000 dbu/um
  "Metal2" => 560,   # 0.280 um
  "Metal3" => 560,
  "Metal4" => 560,
  "Metal5" => 880,   # 0.440 um
}.freeze

VIA1 = "Via1_2X2_0_60_10_60_H_V"
VIA2 = "Via2_2X2_0_60_10_60_V_H"
# GDS cut layers for the approved 2x2 arrays (GF180MCU: Via1 35/0, Via2 38/0).
VIA_CUT_LAYER = { VIA1 => [35, 0], VIA2 => [38, 0] }.freeze
# 2x2 cut array: 0.26 um cuts on 0.52 um centers, in GDS dbu (0.001 um).
CUT_BOXES = [
  [-390, -390, -130, -130],
  [130, -390, 390, -130],
  [-390, 130, -130, 390],
  [130, 130, 390, 390],
].freeze

POINT_RE = /\(\s*(\*|-?\d+)\s+(\*|-?\d+)\s*(?:-?\d+)?\s*\)/
RECT_RE = /RECT\s*\(\s*(-?\d+)\s+(-?\d+)\s*(-?\d+)\s*(-?\d+)\s*\)/
ROUTE_RE = /(ROUTED|NEW|FIXED|COVER|NOSHIELD)\s+([A-Za-z][0-9A-Za-z]*)/
TOKEN_RE = /RECT\s*\(\s*-?\d+\s+-?\d+\s+-?\d+\s+-?\d+\s*\)|\(\s*(?:\*|-?\d+)\s+(?:\*|-?\d+)\s*(?:-?\d+)?\s*\)|[A-Za-z_][0-9A-Za-z_]*/

DefData = Struct.new(:regions, :via1, :via2)

# DEF is 2000 dbu/um and the GDS is 1000 dbu/um. The stream-out converts
# each coordinate with Python's round-half-to-even, so match that instead of
# flooring: a 1-dbu edge error becomes millions of dbu2 on a long stripe.
def gds_dbu(v)
  q, r = v.divmod(2)
  return q if r.zero?
  q.even? ? q : q + 1
end

def add_box(regions, layer, x0, y0, x1, y1)
  regions[layer].insert(RBA::Box.new(gds_dbu(x0), gds_dbu(y0),
                                     gds_dbu(x1), gds_dbu(y1)))
end

def add_segment(regions, layer, x0, y0, x1, y1, w)
  h = w / 2
  add_box(regions, layer,
          [x0, x1].min - h, [y0, y1].min - h,
          [x0, x1].max + h, [y0, y1].max + h)
end

# {layer: Region} for a DEF's NETS and SPECIALNETS routing, plus the ECO via
# anchors. Routing boxes are inserted with the stream-out's rounding, so the
# region equals what stream_out.py writes for the same DEF.
def parse_def(path)
  regions = Hash.new { |h, k| h[k] = RBA::Region.new }
  via1 = 0
  via2 = 0
  section = nil
  layer = nil
  width = nil
  pts = []
  last = nil
  anchors1 = []
  anchors2 = []

  File.foreach(path) do |line|
    s = line.strip
    if s.start_with?("SPECIALNETS ") || s.start_with?("NETS ")
      section = :nets
      layer = nil
      width = nil
      pts = []
      last = nil
      next
    end
    if s.start_with?("END SPECIALNETS") || s.start_with?("END NETS")
      section = nil
      next
    end
    next unless section == :nets
    if s.start_with?("- ")
      layer = nil
      width = nil
      pts = []
      last = nil
      next
    end

    body = s.start_with?("+") ? s[1..].strip : s
    if (m = ROUTE_RE.match(body))
      layer = m[2]
      rest = body[m.end(0)..] || ""
      width = nil
      if (w = rest.match(/\A\s*(\d+)\s*(.*)\z/))
        width = w[1].to_i
        rest = w[2]
      end
      rest = rest.sub(/\A\s*\+\s*SHAPE\s+\w+\s*/, "")
      pts = []
      last = nil
    elsif layer.nil?
      next
    else
      rest = body
    end

    head = rest.split(";", 2)[0]
    pos = 0
    head.scan(TOKEN_RE) do |tok|
      m = Regexp.last_match
      gap = head[pos...m.begin(0)]
      raise "unreadable DEF routing token #{gap.inspect}" unless gap.strip.empty?
      pos = m.end(0)
      if (r = RECT_RE.match(tok))
        raise "RECT without one anchor" unless last && pts.length == 1
        dx1, dy1, dx2, dy2 = r.captures.map(&:to_i)
        raise "RECT with no area" unless dx2 > dx1 && dy2 > dy1
        add_box(regions, layer, last[0] + dx1, last[1] + dy1,
                last[0] + dx2, last[1] + dy2)
        pts = []
        last = nil
        next
      end
      if tok.start_with?("(")
        a, b = POINT_RE.match(tok).captures
        if a == "*" || b == "*"
          raise "`*` without previous point" unless last
          x = a == "*" ? last[0] : a.to_i
          y = b == "*" ? last[1] : b.to_i
        else
          x = a.to_i
          y = b.to_i
        end
        if pts.any?
          x0, y0 = pts[-1]
          w = width || WIDTHS[layer]
          raise "no width for #{layer}" unless w
          add_segment(regions, layer, x0, y0, x, y, w)
        end
        pts << [x, y]
        last = [x, y]
        next
      end

      if tok == VIA1
        raise "#{VIA1} has no anchor point" unless last
        via1 += 1
        anchors1 << last
      elsif tok == VIA2
        raise "#{VIA2} has no anchor point" unless last
        via2 += 1
        anchors2 << last
      end
      pts = []
      last = nil
    end
    raise "trailing DEF routing text #{head[pos..].inspect}" unless head[pos..].strip.empty?
  end
  d = DefData.new(regions, via1, via2)
  [d, anchors1, anchors2]
end

def layout_region(layout, cell, li, hier)
  hier ? RBA::Region.new(cell.begin_shapes_rec(li)) : RBA::Region.new(cell.shapes(li))
end

def site_window(x, y, ty)
  RBA::Box.new(x - 1500, [y, ty].min - 1500, x + 1500, [y, ty].max + 1500)
end

def box_region(box)
  region = RBA::Region.new
  region.insert(box)
  region
end

final_def, eco_via1, eco_via2 = parse_def(def_file)

gds_layout = RBA::Layout.new
gds_layout.read(gds)
gds_cell = gds_layout.cell(topcell)
raise "topcell #{topcell} not found in GDS" if gds_cell.nil?

lines = []
failures = []

# Full-chip expected cut geometry, anchored at the DEF via points. Each 2x2
# array is compared only inside its own 0.78 um window so unrelated GDS vias
# are not mistaken for ECO drops.
cut_expected = {}
[VIA1, VIA2].each do |name|
  expected = RBA::Region.new
  windows = RBA::Region.new
  anchors = name == VIA1 ? eco_via1 : eco_via2
  anchors.each do |x, y|
    cx = gds_dbu(x)
    cy = gds_dbu(y)
    CUT_BOXES.each do |x0, y0, x1, y1|
      expected.insert(RBA::Box.new(cx + x0, cy + y0, cx + x1, cy + y1))
    end
    windows.insert(RBA::Box.new(cx - 390, cy - 390, cx + 390, cy + 390))
  end
  cut_expected[name] = [expected, windows]
end

LAYERS.each do |name, (_dl, _dd, gl, gd)|
  gds_li = gds_layout.find_layer(RBA::LayerInfo.new(gl, gd))
  if gds_li.nil?
    failures << "#{name}: missing GDS layer #{gl}/#{gd}"
    next
  end
  def_region = final_def.regions[name]
  gds_region = RBA::Region.new(gds_cell.shapes(gds_li))
  xor_region = def_region ^ gds_region
  lines << "DEF_#{name}_SHAPES=#{def_region.count}"
  lines << "GDS_#{name}_SHAPES=#{gds_region.count}"
  lines << "XOR_#{name}_DBU2=#{xor_region.area}"
  failures << "#{name}: DEF/GDS top-level XOR is #{xor_region.area} dbu2" unless xor_region.area == 0
end

VIA_CUT_LAYER.each do |name, (gl, gd)|
  gds_li = gds_layout.find_layer(RBA::LayerInfo.new(gl, gd))
  if gds_li.nil?
    failures << "#{name}: missing GDS cut layer #{gl}/#{gd}"
    next
  end
  # Cuts live in the VIA_* child cells, so the region must include hierarchy.
  gds_cut = RBA::Region.new(gds_cell.begin_shapes_rec(gds_li))
  expected, windows = cut_expected[name]
  observed = gds_cut & windows
  xor = observed ^ expected
  lines << "GDS_#{name}_CUTS=#{observed.count}"
  lines << "XOR_#{name}_CUT_DBU2=#{xor.area}"
  unless xor.area == 0
    failures << "#{name}: GDS cuts do not match the 2x2 array at every DEF anchor (XOR #{xor.area} dbu2)"
  end
end

lines << "ECO_#{VIA1}=#{final_def.via1}"
lines << "ECO_#{VIA2}=#{final_def.via2}"
lines << "EXPECTED_DROPS=#{expected_drops}"
failures << "Via1_2X2 drops #{final_def.via1} != #{expected_drops}" unless final_def.via1 == expected_drops
failures << "Via2_2X2 drops #{final_def.via2} != #{expected_drops}" unless final_def.via2 == expected_drops

if windowed
  base_def, = parse_def(base_def_file)

  sites = []
  File.foreach(sites_file) do |line|
    next if line.start_with?("#") || line.strip.empty?
    f = line.strip.split(",")
    raise "site row needs name,x,y,ty: #{line.strip.inspect}" if f.length < 4
    sites << [f[0], f[1].to_i, f[2].to_i, f[3].to_i]
  end
  raise "no sites in #{sites_file}" if sites.empty?

  windows = RBA::Region.new
  sites.each { |_name, x, y, ty| windows.insert(site_window(x, y, ty)) }

  base_layout = RBA::Layout.new
  base_layout.read(base_gds)
  base_cell = base_layout.cell(topcell)
  raise "base topcell #{topcell} not found in #{base_gds}" if base_cell.nil?

  window_xor = Array.new(sites.size, 0)
  window_delta = Array.new(sites.size, 0)

  # Metals: GDS top-level delta against the DEF routing delta.
  LAYERS.each do |name, (_dl, _dd, gl, gd)|
    gds_li = gds_layout.find_layer(RBA::LayerInfo.new(gl, gd))
    base_li = base_layout.find_layer(RBA::LayerInfo.new(gl, gd))
    next if gds_li.nil? || base_li.nil?
    delta_gds = layout_region(gds_layout, gds_cell, gds_li, false) -
                layout_region(base_layout, base_cell, base_li, false)
    delta_def = final_def.regions[name] - base_def.regions[name]
    outside_gds = delta_gds - windows
    outside_def = delta_def - windows
    lines << "OUTSIDE_WINDOWS_#{name}_DBU2=#{outside_gds.area}"
    lines << "OUTSIDE_WINDOWS_DEF_#{name}_DBU2=#{outside_def.area}"
    failures << "#{name}: #{outside_gds.area} dbu2 of new GDS geometry outside the site windows" unless outside_gds.area == 0
    failures << "#{name}: #{outside_def.area} dbu2 of new DEF routing outside the site windows" unless outside_def.area == 0
    sites.each_with_index do |(_name, x, y, ty), i|
      win = box_region(site_window(x, y, ty))
      g = delta_gds & win
      d = delta_def & win
      window_xor[i] += (g ^ d).area
      window_delta[i] += g.area
    end
  end

  # Via1/Via2: the DEF delta is the anchors, so compare the GDS cut delta with
  # the expected 2x2 arrays inside each window.
  [VIA1, VIA2].each do |name|
    gl, gd = VIA_CUT_LAYER[name]
    gds_li = gds_layout.find_layer(RBA::LayerInfo.new(gl, gd))
    base_li = base_layout.find_layer(RBA::LayerInfo.new(gl, gd))
    next if gds_li.nil? || base_li.nil?
    delta_gds = layout_region(gds_layout, gds_cell, gds_li, true) -
                layout_region(base_layout, base_cell, base_li, true)
    expected = cut_expected[name][0]
    outside = delta_gds - windows
    short = name == VIA1 ? "Via1_2X2" : "Via2_2X2"
    lines << "OUTSIDE_WINDOWS_#{short}_CUT_DBU2=#{outside.area}"
    failures << "#{short}: #{outside.area} dbu2 of new GDS cuts outside the site windows" unless outside.area == 0
    sites.each_with_index do |(_name, x, y, ty), i|
      win = box_region(site_window(x, y, ty))
      g = delta_gds & win
      e = expected & win
      window_xor[i] += (g ^ e).area
      window_delta[i] += g.area
    end
  end

  if sites.size != expected_drops
    failures << "site list has #{sites.size} windows, expected #{expected_drops}"
  end

  bad_windows = 0
  empty_windows = 0
  sites.each_with_index do |(name, _x, _y, _ty), i|
    ok = window_xor[i].zero?
    empty = window_delta[i].zero?
    status = ok && !empty ? "PASS" : "FAIL"
    bad_windows += 1 if status == "FAIL"
    empty_windows += 1 if empty
    lines << "WINDOW #{name} xor_dbu2=#{window_xor[i]} delta_dbu2=#{window_delta[i]} #{status}"
  end
  lines << "WINDOWS=#{sites.size}"
  lines << "WINDOWS_WITH_DELTA=#{sites.size - empty_windows}"
  lines << "WINDOW_FAILURES=#{bad_windows}"
  failures << "#{bad_windows} site windows failed the delta check" if bad_windows.positive?
  failures << "#{empty_windows} site windows have no new geometry" if empty_windows.positive?
end

lines << "FAILURES=#{failures.join('; ')}"
text = lines.join("\n") + "\n"
puts text
File.write(report, text)
exit(failures.empty? ? 0 : 1)
