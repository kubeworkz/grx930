# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_clk_composition.rb -- what the pre-stitch clock net actually picked up, and where.
#
# `filled-vnwvd-b12300` is the legal fill with the tied CDL, before any strap: its clock net is
# named CLK,VDD,i_clk and carries 29,484 terminals, 28,988 of which are the clock loads.  This
# probe lists the terminal classes on that net -- bodies, source/drains, gates -- and asks the
# database for the shapes of the non-gate terminals, which is the location of the fragment the
# clock met.
#
#   klayout -b -r lvsdb_clk_composition.rb -rd file=<report.lvsdb> [-rd n=4]
FILE = $file
N = ($n || 4).to_i

t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
puts format('READ %.1f s', Time.now - t0)

nl = lvs.xref.netlist_a
top = nil
nl.each_circuit { |c| top = c if top.nil? }
puts "top=#{top.name}"

best = nil
best_n = -1
top.each_net do |n|
  next unless n.name.to_s.include?('i_clk')
  c = n.terminal_count
  if c > best_n
    best_n = c
    best = n
  end
end
abort('no net with i_clk in its name') if best.nil?
puts format('net id=%d terminals=%d name=%s', best.cluster_id, best_n, best.name.to_s[0, 80])

by = Hash.new(0)
non_gate = []
best.each_terminal do |t|
  d = t.device
  next if d.nil?
  cls = d.device_class.name
  tid = t.terminal_id
  tname = (d.terminal(tid).name.to_s rescue '?')
  by["#{cls}/#{tid} #{tname}"] += 1
  non_gate << t unless tname =~ /gate/i
end
by.sort_by { |k, v| [-v, k] }.each { |k, v| puts format('  %8d  %s', v, k) }
puts "non-gate terminals: #{non_gate.size}"

# What shape-level access does this build offer?
puts "shape APIs: #{lvs.methods.grep(/shape/).sort.inspect}"
puts "net APIs:   #{best.methods.grep(/shape|pin|term/).sort.inspect}"

if $shapes
  want = {}
  lvs.layer_indexes.each do |i|
    info = lvs.layer_info(i)
    next if info.nil?
    want[[info.layer, info.datatype]] = i if info.layer >= 30 && info.layer <= 50
  end
  puts "layer index map (30..50): #{want.sort.inspect}"
  i_cell = lvs.internal_top_cell
  want.sort.each do |(ln, dt), li|
    r_all = RBA::Region.new(i_cell.begin_shapes_rec(li))
    begin
      r = lvs.shapes_of_net(best, r_all)
    rescue StandardError => e
      puts format('-- %d/%d: SKIP %s', ln, dt, e.message[0, 80])
      next
    end
    next if r.nil? || r.is_a?(Array) && r.empty?
    reg = r.is_a?(Array) ? r[0] : r
    unless reg.is_a?(RBA::Region)
      puts format('-- %d/%d: returned %s', ln, dt, r.class)
      next
    end
    puts format('-- %d/%d shapes=%d bbox=%s', ln, dt, reg.count, reg.bbox)
    # summarize in rail bands: a shape centred within 300 dbu of a 7,840 dbu row line is rail metal
    in_band = 0
    band_x = []
    reg.each do |p|
      bb = p.bbox
      cy = (bb.bottom + bb.top) / 2
      k = ((cy - 11_760) / 3_920.0)
      if (k - k.round).abs * 3_920 <= 300
        in_band += 1
        band_x << [k.round, bb.left, bb.right]
      end
    end
    puts format('   in a rail band: %d', in_band)
    band_x.group_by { |row, _a, _b| row }.sort.each do |row, hits|
      puts format('   row %4d: %3d shapes x %d..%d', row, hits.size,
                  hits.map { |_r, a, _b| a }.min, hits.map { |_r, _a, b| b }.max)
    end
  end
end

if $terms
  shown = 0
  bodies = non_gate.select { |t| t.device.device_class.name.to_s.start_with?('pfet') &&
                                 t.terminal_id == 3 }
  bodies += non_gate if bodies.empty?
  bodies.sort_by { |t| t.device.id }.each do |t|
    d = t.device
    puts "\nterminal #{t.terminal_id} of #{d.device_class.name} device #{d.id}"
    begin
      r = lvs.shapes_of_terminal(t)
    rescue StandardError => e
      puts "   shapes_of_terminal: #{e.class}: #{e.message[0, 80]}"
      break
    end
    puts "   #{r.class}"
    if r.is_a?(Hash)
      r.each do |k, v|
        if v.respond_to?(:count) && v.respond_to?(:bbox)
          puts format('   key=%s %s count=%d bbox=%s', k.inspect, v.class, v.count, v.bbox)
        elsif v.is_a?(Array)
          puts format('   key=%s Array(%d) first=%s', k.inspect, v.size, v.first.inspect[0, 120])
        else
          puts format('   key=%s %s %s', k.inspect, v.class, v.inspect[0, 120])
        end
      end
    elsif r.is_a?(RBA::Region)
      puts "   shapes=#{r.count} bbox=#{r.bbox}"
      r.each { |p| puts format('     %s', p.bbox) }
    end
    shown += 1
    break if shown >= N
  end
end

$stdout.flush
exit!(0)
