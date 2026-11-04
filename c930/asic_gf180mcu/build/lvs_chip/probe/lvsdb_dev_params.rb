# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_dev_params.rb -- for the device pairs the comparer could not confirm, which parameter differs?
#
# The stitched exact-RECT die leaves 242 both-sided device pairs at `Mismatch` while both sides carry
# the same counts and the same class (pfet_05v0 -> PFET_05V0, nfet_05v0 -> NFET_05V0). A class swap is
# therefore not the reason: either a parameter is outside tolerance, or the terminals are assigned
# differently. This prints the parameter sets side by side and tallies which keys disagree.
#
#   klayout -b -r lvsdb_dev_params.rb -rd file=<report.lvsdb> [-rd examples=4]
FILE = $file
EXAMPLE = ($examples || 4).to_i

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

# KLayout hands device parameters back as a hash-like of name => value.
def params(d)
  h = {}
  d.each_parameter { |k, v| h[k] = v }
  h
rescue StandardError
  {}
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-CIRCUIT-PAIR') unless cp

diff = Hash.new(0)
same = 0
shown = 0
x.each_device_pair(cp) do |p|
  next unless p.first && p.second && sname(p.status) != 'Match'
  a = params(p.first)
  b = params(p.second)
  keys = (a.keys | b.keys)
  delta = keys.reject { |k| a[k] == b[k] }
  if delta.empty?
    same += 1
    diff['(no parameter differs: terminals/geometry)'] += 1
  else
    delta.each { |k| diff[k] += 1 }
  end
  next if shown >= EXAMPLE
  ca = (p.first.device_class && p.first.device_class.name) rescue '?'
  cb = (p.second.device_class && p.second.device_class.name) rescue '?'
  puts format("\nPAIR %s: layout=%s [%s] schematic=%s [%s]", sname(p.status),
              nname(p.first), ca, nname(p.second), cb)
  keys.sort.each do |k|
    flag = a[k] == b[k] ? '   ' : ' * '
    puts format(' %s%-10s layout=%-14s schematic=%s', flag, k, a[k].inspect, b[k].inspect)
  end
  shown += 1
end

puts "\n== parameters that differ across all both-sided non-Match pairs"
diff.sort_by { |_k, v| -v }.first(12).each { |k, v| puts format('  %-40s %d pairs', k, v) }
puts "pairs with no parameter difference: #{same}"
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
