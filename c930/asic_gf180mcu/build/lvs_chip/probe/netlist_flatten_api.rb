# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# netlist_flatten_api.rb -- which netlist operations the census can rely on: hierarchy shape,
# flattening, and per-class device counting. Run against a small lvsdb:
#   klayout -b -r netlist_flatten_api.rb -rd file=<report.lvsdb>
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
nl = lvs.xref.netlist_a
puts "class #{nl.class}"
puts "methods #{nl.methods.grep(/flatten|device|circuit|combine/i).sort.inspect}"
ncirc = 0
nl.each_circuit { ncirc += 1 }
puts "circuits #{ncirc} top_circuit_count=#{nl.top_circuit_count}"
nl.each_circuit do |c|
  d = 0
  c.each_device { d += 1 }
  s = 0
  c.each_subcircuit { s += 1 }
  puts "circuit #{c.name} devices=#{d} subcircuits=#{s}"
end
begin
  flat = nl.flatten
  fd = 0
  fcirc = 0
  flat.each_circuit do |c|
    fcirc += 1
    c.each_device { fd += 1 }
  end
  puts "flatten ok: circuits=#{fcirc} devices=#{fd}"
  flat.each_circuit do |c|
    next unless c.respond_to?(:device_class) || true
    h = Hash.new(0)
    c.each_device { |dv| h[dv.device_class.name] += 1 }
    puts "flatten classes #{c.name}: " + h.sort_by { |k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(" ")
  end
rescue StandardError => e
  puts "flatten error: #{e.class}: #{e.message}"
end
$stdout.flush
exit!(0)
