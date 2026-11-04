# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# net_terminals.rb -- what the layout's largest net is actually made of.
#
# The stitched die's biggest net is 600,232 terminals. That is 79,784 more than the 520,448 the
# VDD-named nets held before, and the arithmetic can be decomposed in more than one way, so this
# counts the terminals by device class and terminal name instead of guessing: if the net holds
# 345,505 pfet bodies then every nwell joined it; if it holds nfet bodies then it is shorted to the
# substrate; if it holds gate terminals then something else joined it.
#
#   klayout -b -r net_terminals.rb -rd file=<report.lvsdb> [-rd top=0]
TOP = ($top || 0).to_i
t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
puts format('READ %.1f s', Time.now - t0)
nl = lvs.xref.netlist_a
cc = nil
nl.each_circuit { |c| cc = c }
# Nets are reduced to plain values as they are read: holding RBA::Net objects past the circuit
# walk lets the GC free them under the netlist and the interpreter segfaults on exit.
nets = []
cc.each_net { |n| nets << [n.terminal_count, n.cluster_id, n.name.to_s] }
nets.sort_by! { |tc, _id, _name| -tc }
puts "layout nets=#{nets.size}"
nets.first(4).each_with_index do |(tc, _id, name), i|
  puts format('  net %d: terminals=%-8d name=%s', i, tc, name[0, 60])
end
tc, big_id, big_name = nets[TOP]
puts "counting terminals of net #{TOP}: #{tc} terminals, name #{big_name[0, 40]}"
by = Hash.new(0)
ncls = Hash.new(0)
cc.each_device do |d|
  d.terminal_count.times do |i|
    t = d.terminal(i)
    next unless t.net && t.net.cluster_id == big_id
    name = t.respond_to?(:name) && t.name ? t.name.to_s : "T#{i}"
    by["#{d.device_class.name}/#{name}"] += 1
    ncls[d.device_class.name] += 1
  end
end
puts 'by device class:'
ncls.sort_by { |_k, v| -v }.each { |k, v| puts format('  %-12s %d', k, v) }
puts 'by class/terminal:'
by.sort_by { |_k, v| -v }.first(12).each { |k, v| puts format('  %-24s %d', k, v) }
$stdout.flush
exit(0)
