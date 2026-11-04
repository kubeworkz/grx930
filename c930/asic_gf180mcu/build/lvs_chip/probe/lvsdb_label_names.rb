# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_label_names.rb -- did the cell-internal labels reach the die netlist, and under what name?
#
# The labels are written into cell *definitions*, so the flattened netlist should carry them with the
# instance as a prefix (`_68736_.NCKI`), which is exactly how the schematic's flattened names read.
# If the layout instead shows bare `NCKI` on 12,000 nets, the prefix was lost and the name cannot
# identify anything; if no internal name appears at all, the label layer is not being read.
#
#   klayout -b -r lvsdb_label_names.rb -rd file=<report.lvsdb> [-rd want=NCKI] [-rd n=8]
FILE = $file
WANT = ($want || 'NCKI').to_s.upcase
N = ($n || 8).to_i

lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
x = lvs.xref
XA = RBA::NetlistCrossReference

def sname(s)
  return 'Match' if s == XA::Match
  return 'MatchWithWarning' if s == XA::MatchWithWarning
  return 'Mismatch' if s == XA::Mismatch
  return 'NoMatch' if s == XA::NoMatch
  return 'Skipped' if s == XA::Skipped
  return 'None' if s == XA::None
  s.to_s
end

def nname(o)
  return '(nil)' if o.nil?
  return o.expanded_name if o.respond_to?(:expanded_name)
  return o.name if o.respond_to?(:name)
  o.to_s
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp
circuit = cp.first
abort('NO-LAYOUT-CIRCUIT') unless circuit

# Net-name shape on the layout side.
with_dot = with_want = exact_want = total = 0
examples = []
circuit.each_net do |n|
  total += 1
  nm = n.name.to_s
  with_dot += 1 if nm.include?('.')
  if nm.upcase.include?(WANT)
    with_want += 1
    examples << nm if examples.size < N
  end
  exact_want += 1 if nm.upcase == WANT
end
puts "LAYOUT NETS #{total} named-with-dot=#{with_dot} containing-#{WANT}=#{with_want} bare-#{WANT}=#{exact_want}"
examples.each { |e| puts "  #{e}" }

nets = Hash.new(0)
devs = Hash.new(0)
both_net = both_dev = 0
x.each_net_pair(cp) do |p|
  nets[sname(p.status)] += 1
  both_net += 1 if p.first && p.second
end
x.each_device_pair(cp) do |p|
  devs[sname(p.status)] += 1
  both_dev += 1 if p.first && p.second
end
puts 'NET PAIRS    ' + nets.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')
puts 'DEVICE PAIRS ' + devs.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')
returned = 0
x.each_net_pair(cp) { |p| returned += 1 if p.first && p.second && sname(p.status) != 'Match' }
rdev = 0
x.each_device_pair(cp) { |p| rdev += 1 if p.first && p.second && sname(p.status) != 'Match' }
puts "BOTH-SIDED NON-MATCH nets=#{returned} devices=#{rdev}"
$stdout.flush
exit!(0)
