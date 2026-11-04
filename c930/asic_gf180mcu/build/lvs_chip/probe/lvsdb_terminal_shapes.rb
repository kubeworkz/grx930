# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_terminal_shapes.rb -- the metal around the terminals the clock net picked up from a rail.
#
# The pre-stitch clock net (id 1686, 29,484 terminals: 28,988 gates + 496 supply-side terminals)
# is the one net that names both i_clk and VDD.  The 496 are PFET source/drains whose rail is on the
# net, so their shapes are the *location* of the island the clock met.  `shapes_of_terminal` works on
# flat transistor netlists, which is what this run is.
#
#   klayout -b -r lvsdb_terminal_shapes.rb -rd file=<report.lvsdb> [-rd want=pfet_05v0] [-rd n=6]
FILE = $file
WANT = $want || 'pfet_05v0'
N = ($n || 6).to_i

t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
puts format('READ %.1f s', Time.now - t0)
nl = lvs.xref.netlist_a
cc = nil
nl.each_circuit { |c| cc = c }
best = nil
best_n = -1
cc.each_net do |n|
  next unless n.name.to_s.include?('i_clk')
  c = n.terminal_count
  if c > best_n
    best_n = c
    best = n
  end
end
puts "net id=#{best.cluster_id} terminals=#{best_n}"

shown = 0
best.each_terminal do |t|
  d = t.device
  next if d.nil?
  cls = d.device_class.name
  next unless cls == WANT
  tid = t.terminal_id
  tname = (d.terminal(tid).name.to_s rescue '?')
  next if tname =~ /gate|G/i
  puts "\nterminal #{tname} of #{cls} (device #{d.id})"
  begin
    r = lvs.shapes_of_terminal(t)
  rescue StandardError => e
    puts "   shapes_of_terminal: #{e.message[0, 70]}"
    next
  end
  if r.is_a?(RBA::Region)
    puts "   region: #{r.count} shapes"
    r.each { |p| bb = p.bbox; puts format('     %8d..%-8d x %8d..%-8d h=%5d', bb.left, bb.right, bb.bottom, bb.top, bb.height) }
  else
    puts "   #{r.class}: #{r.inspect[0, 200]}"
  end
  shown += 1
  break if shown >= N
end
puts "\nshown #{shown}"
$stdout.flush
exit!(0)
