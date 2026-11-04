# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# net_composition.rb -- what the layout's largest net is made of, walked from the net side.
#
# The stitched die's largest net is 600,232 terminals against a schematic VDD of 571,169. Counting
# from `Net#each_terminal` (rather than iterating devices, which crashed the bindings) says whether
# the extra terminals are device bodies, gate terminals, or another net's source/drain.
#
#   klayout -b -r net_composition.rb -rd file=<report.lvsdb> [-rd top=0]
t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
puts format('READ %.1f s', Time.now - t0)
nl = lvs.xref.netlist_a
cc = nil
nl.each_circuit { |c| cc = c }
nets = []
cc.each_net { |n| nets << [n.terminal_count, n.cluster_id, n.name.to_s] }
nets.sort_by! { |tc, _id, _name| -tc }
puts "layout nets=#{nets.size}"
nets.first(6).each_with_index { |(tc, _id, nm), i| puts format('  %d %8d  %s', i, tc, nm[0, 50]) }
tc, big_id, big_name = nets[($top || 0).to_i]
puts "net #{($top || 0).to_i}: #{tc} terminals"
by = Hash.new(0)
seen = 0
cc.each_net do |n|
  next unless n.cluster_id == big_id
  n.each_terminal do |t|
    seen += 1
    if seen == 1
      puts "  terminal methods: #{t.methods.grep(/dev|term|class|name|id/).sort.inspect}"
    end
    d = t.respond_to?(:device) ? t.device : nil
    cls = d ? d.device_class.name : '?'
    tid = t.respond_to?(:terminal_id) ? t.terminal_id : '?'
    tname = ''
    begin
      tname = d && tid.is_a?(Integer) && d.terminal(tid).respond_to?(:name) ? d.terminal(tid).name.to_s : ''
    rescue StandardError
      tname = ''
    end
    by["#{cls}/#{tname.empty? ? tid : tname}"] += 1
  end
end
puts "  walked #{seen} terminals"
by.sort_by { |_k, v| -v }.first(16).each { |k, v| puts format('  %-28s %d', k, v) }
$stdout.flush
exit(0)
