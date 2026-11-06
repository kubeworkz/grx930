# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# dev_mismatch_cause.rb -- why is each non-Match device pair non-Match?
#
# The labelled September run (`filled-rect-stitched-lab2`) carried 148,715 instance-qualified net
# names, six of `_71769_`'s twelve internal nets named exactly as the schematic names them, and the
# pair counts did not move. Its device pairs show why: the pfet pairs differ at terminal 3, where
# the layout bulk sits on an unnamed well net (`$328`) that has no schematic net at all, against
# the schematic's `VDD`. A net name cannot make an unconnected well equal to a supply.
#
# This classifies every non-Match device pair on that fact instead of on parameters: `equal` when
# every terminal's layout net pairs with the same schematic net, `unpaired-net` when at least one
# terminal's layout net has no schematic partner (recording the terminal ids), `sd-swap` when the
# only difference is source/drain exchange, `other` otherwise.
#
#   klayout -b -r dev_mismatch_cause.rb -rd file=<report.lvsdb> -rd out=<txt>
FILE = $file
OUT = $out
abort('usage: -rd file=<report.lvsdb> -rd out=<txt>') unless FILE && OUT

t0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
puts format('READ %.1f s', Time.now - t0)
x = lvs.xref
abort('NO-XREF') unless x
X = RBA::NetlistCrossReference

def sname(s)
  return 'Match' if s == X::Match
  return 'MatchWithWarning' if s == X::MatchWithWarning
  return 'Mismatch' if s == X::Mismatch
  return 'NoMatch' if s == X::NoMatch
  return 'Skipped' if s == X::Skipped
  return 'None' if s == X::None
  s.to_s
end

def nname(o)
  return '(nil)' if o.nil?
  return o.expanded_name if o.respond_to?(:expanded_name)
  return o.name if o.respond_to?(:name)
  o.to_s
end

def inst_of(name)
  s = name.to_s
  s.include?('.') ? s.split('.', 2).first : '(top)'
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

netmap = {}
x.each_net_pair(cp) do |p|
  next unless p.first && p.second
  netmap[nname(p.first)] = nname(p.second)
end

terms = { a: {}, b: {} }
[[cp.first, :a], [cp.second, :b]].each do |circuit, side|
  next unless circuit
  circuit.each_net do |n|
    nm = nname(n)
    n.each_terminal do |t|
      d = t.device
      next unless d
      (terms[side][d.id] ||= {})[t.terminal_id] = nm
    end
  end
end

kinds = Hash.new(0)
by_term = Hash.new(0)
unpaired_net = Hash.new(0)
by_inst = Hash.new(0)
by_cell = Hash.new(0)
rows = []

x.each_device_pair(cp) do |p|
  next unless p.first && p.second
  st = sname(p.status)
  next if st == 'Match'
  ka = terms[:a][p.first.id] || {}
  kb = terms[:b][p.second.id] || {}
  ids = (ka.keys | kb.keys).sort
  mapped = ids.map { |t| [t, ka[t], kb[t], ka[t] ? netmap[ka[t]] : nil] }
  bad = mapped.reject { |_t, la, lb, ma| la && ma == lb }
  unp = bad.select { |_t, la, _lb, ma| la && ma.nil? }
  equal = bad.empty?
  swap = !equal && ids.size == 4 && mapped.all? do |t, _la, lb, ma|
    partner = { 0 => 2, 2 => 0, 1 => 1, 3 => 3 }[t]
    alt = mapped.find { |q| q[0] == partner }
    ma && alt && ma == alt[2]
  end
  kind = if equal then 'equal'
         elsif unp.any? then 'unpaired-net'
         elsif swap then 'sd-swap'
         else 'other'
         end
  kinds[kind] += 1
  unp.each { |t, la, _lb, _ma| by_term[t] += 1 }
  unp.each { |_t, la, _lb, _ma| unpaired_net[la] += 1 }
  inst = inst_of(nname(p.second))
  by_inst[inst] += 1
  by_cell[p.first.device_class.name.to_s] += 1
  rows << [st, kind, inst, nname(p.first), nname(p.second),
           mapped.map { |t, la, lb, ma| "#{t}:#{la}=>#{lb}#{ma == lb ? '' : "(#{ma.inspect})"}" }.join(' ')]
end

File.open(OUT, 'w') do |fh|
  fh.puts "status\tkind\tinstance\tlayout_dev\tschematic_dev\tterminals"
  rows.each { |r| fh.puts r.join("\t") }
end

puts "device pairs at non-Match: #{rows.size}"
kinds.sort_by { |_k, v| -v }.each { |k, v| puts format('  %-14s %d', k, v) }
puts "unpaired terminal ids: " + by_term.sort.map { |k, v| "#{k}=#{v}" }.join(' ')
puts "distinct unpaired layout nets: #{unpaired_net.size}"
unpaired_net.sort_by { |_k, v| -v }.first(12).each { |k, v| puts format('  %-16s %d device pairs', k, v) }
puts "instances: #{by_inst.size}; top: " + by_inst.sort_by { |_k, v| -v }.first(8).map { |k, v| "#{k}=#{v}" }.join(' ')
puts "layout device classes: " + by_cell.sort.map { |k, v| "#{k}=#{v}" }.join(' ')
puts "WROTE #{OUT}"
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
