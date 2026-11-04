# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# probe: what a NetlistCrossReference pair object exposes in this KLayout build.
# Run on a small lvsdb:  klayout -b -r lvsdb_api.rb -rd file=<report.lvsdb>
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
x = lvs.xref
puts "PROBE circuits: #{x.circuit_count}"
puts "PROBE netlists: #{x.netlist_a ? 'a' : '-'} #{x.netlist_b ? 'b' : '-'}"
shown = 0
x.each_circuit_pair do |cp|
  puts "PROBE circuit_pair class: #{cp.class}"
  puts "PROBE circuit_pair methods: #{cp.methods.sort.inspect}"
  puts "PROBE circuit_pair status: #{cp.status.inspect}"
  %w[a b name].each do |m|
    next unless cp.respond_to?(m)
    v = cp.send(m)
    puts "PROBE circuit_pair #{m}: #{v.class} #{v.respond_to?(:name) ? v.name : v.inspect}"
  end
  x.each_net_pair(cp) do |np|
    puts "PROBE net_pair class: #{np.class}"
    puts "PROBE net_pair methods: #{np.methods.sort.inspect}"
    puts "PROBE net_pair status: #{np.status.inspect}"
    %w[a b].each do |m|
      next unless np.respond_to?(m)
      v = np.send(m)
      puts "PROBE net_pair #{m}: #{v.class} #{v.respond_to?(:expanded_name) ? v.expanded_name : v.inspect}"
    end
    shown += 1
    break
  end
  break
end
x.each_device_pair(RBA::NetlistCrossReference::CircuitPairData) rescue nil
puts "PROBE done shown=#{shown}"
