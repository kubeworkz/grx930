# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# supply_nets.rb -- which nets carry the device body terminals, and are they named?
#
# The die census reports VDD fragments but only 353 VSS terminals against 345,505
# NFET bodies, so most bodies are not on a net named VSS. This prints, per side, the
# nets with the most terminals and their names, plus the fragment count for every
# supply name, which says whether the bodies are on one substrate net or scattered.
#
#   klayout -b -r supply_nets.rb -rd file=<report.lvsdb> [-rd top=N]
t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
puts format('READ %.1f s', Time.now - t0)
x = lvs.xref
abort('NO-XREF') unless x

[[x.netlist_a, 'layout'], [x.netlist_b, 'schematic']].each do |nl, side|
  next unless nl
  cc = nil
  nl.each_circuit { |c| cc = c }
  puts "== #{side} #{cc.name}"
  nets = []
  names = Hash.new { |h, k| h[k] = [0, 0] }
  total_terms = 0
  cc.each_net do |n|
    tc = n.terminal_count
    total_terms += tc
    nm = n.name.to_s
    nm = '(unnamed)' if nm.empty?
    names[nm][0] += 1
    names[nm][1] += tc
    nets << [tc, nm]
  end
  puts format('nets=%d terminals=%d', nets.size, total_terms)
  nets.sort_by! { |tc, _| -tc }
  nets.first(($top || 10).to_i).each do |tc, nm|
    nm = nm.length > 48 ? "#{nm[0, 48]}…" : nm
    puts format('  TOP %10d  %s', tc, nm)
  end
  %w[VDD VSS VNW VPW SUB].each do |s|
    v = names[s]
    next if v[0].zero?
    puts format('  %-4s nets=%-6d terminals=%d', s, v[0], v[1])
  end
  # Nets whose name is a supply name but whose terminal count is small are the leftovers;
  # one name on many nets is the fragmentation the fill is supposed to remove.
end
$stdout.flush
exit!(0)
