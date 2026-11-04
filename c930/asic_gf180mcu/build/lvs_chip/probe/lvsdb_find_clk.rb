# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_find_clk.rb -- is the clock already merged with a supply in this lvsdb?
#
# The filled die's clock net is named CLK,VDD,i_clk with 29,484 terminals.  Running the same question
# against the *unfilled* anchored run (anchored-b12300) says whether the merge exists in the artifact
# or was introduced by the fill: if the clock there is a net named only i_clk with 28,988 terminals,
# no fill cell was involved.
#
#   klayout -b -r lvsdb_find_clk.rb -rd file=<report.lvsdb>
FILE = $file
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
puts "read #{FILE}"
nl = lvs.xref.netlist_a
cc = nil
nl.each_circuit { |c| cc = c }
found = []
big = []
cc.each_net do |n|
  tc = n.terminal_count
  nm = n.name.to_s
  found << [tc, nm] if nm.include?('i_clk')
  big << [tc, nm] if tc > 20_000
end
puts "nets with i_clk in the name: #{found.size}"
found.sort_by { |tc, _| -tc }.first(12).each { |tc, nm| puts format('  %7d  %s', tc, nm[0, 90]) }
puts "nets over 20,000 terminals: #{big.size}"
big.sort_by { |tc, _| -tc }.first(8).each { |tc, nm| puts format('  %7d  %s', tc, nm[0, 70]) }
$stdout.flush
exit!(0)
