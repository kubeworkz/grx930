# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# net_pin_api.rb -- what a netlist device exposes for terminals, nets and classes.
#
#   klayout -b -r net_pin_api.rb -rd file=<report.lvsdb>
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
c = nil
lvs.xref.netlist_a.each_circuit { |cc| c = cc }
d = nil
c.each_device { |dd| d = dd; break }
puts "Device methods: #{d.methods.grep(/terminal|pin|net|class/).sort.inspect}"
if d.respond_to?(:terminal_count)
  puts "terminal_count=#{d.terminal_count}"
  d.terminal_count.times do |i|
    t = d.terminal(i)
    puts "  #{i} #{t.class} net=#{t.respond_to?(:net) && t.net ? t.net.expanded_name : 'nil'} name=#{t.respond_to?(:name) ? t.name : '?'}"
  end
end
$stdout.flush
exit!(0)
