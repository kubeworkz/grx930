# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# supply_pairing.rb -- what happened to the supply nets in the cross-reference.
#
# After tools/lvs_chip/mk_chip_cdl.py began tying VNW->VDD and VPW->VSS, the filled-die comparison
# paired 42 devices where the previous CDL paired 9,872. That is a *change in correspondence*, and
# the question this answers is whether the merged supply nets are what changed it: if the schematic
# VDD/VSS hubs are unpaired while the layout keeps 522 VDD fragments, no bound can pair them, and
# every device whose bulk sits on an unpaired fragment is out of reach.
#
#   klayout -b -r supply_pairing.rb -rd file=<report.lvsdb> [-rd names=VDD,VSS,SUB,VNW]
#
# Read-only.
T0 = Time.now
lvs = RBA::LayoutVsSchematic.new
lvs.read($file)
puts format('READ %.1f s', Time.now - T0)
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

# The die's top pair is the one with the most nets; there is only one circuit on both sides.
top = nil
x.each_circuit_pair do |cp|
  n = 0
  x.each_net_pair(cp) { n += 1 }
  top = [cp, n] if top.nil? || n > top[1]
end
cp = top[0]
puts "TOP #{cp.first ? cp.first.name : cp.second.name} net_pairs=#{top[1]}"

want = ($names || 'VDD,VSS,SUB,VNW').split(',')
per = Hash.new { |h, k| h[k] = Hash.new(0) }
paired_total = 0
paired_named = 0
x.each_net_pair(cp) do |p|
  st = sname(p.status)
  a = p.first
  b = p.second
  paired_total += 1 if a && b
  paired_named += 1 if a && b && !(a.name.to_s.empty? && b.name.to_s.empty?)
  [a, b].each_with_index do |n, side|
    next unless n
    nm = n.name.to_s
    next if nm.empty?
    want.each do |w|
      # A layout net can carry a label per pin; KLayout keeps one name per net, so an exact match
      # is the only reliable test here (the census counts by name set, this counts by net name).
      per["#{side.zero? ? 'layout' : 'schematic'} #{w}"][st] += 1 if nm == w
    end
  end
end

puts format('PAIRED nets=%d named=%d', paired_total, paired_named)
want.each do |w|
  %w[layout schematic].each do |side|
    h = per["#{side} #{w}"]
    next if h.empty?
    tot = h.values.sum
    puts format('SUPPLY %-10s %-9s nets=%d  %s', w, side, tot,
                h.sort_by { |_, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' '))
  end
end

# The largest net on each side, with its partner: that is where a merged hub would show up.
[[x.netlist_a, 'layout'], [x.netlist_b, 'schematic']].each do |nl, side|
  next unless nl
  cc = nil
  nl.each_circuit { |c| cc = c }
  big = nil
  cc.each_net do |n|
    big = n if big.nil? || n.terminal_count > big.terminal_count
  end
  next unless big
  puts format('BIGGEST %-9s %d terminals  name=%s', side, big.terminal_count,
              big.name.to_s.empty? ? '(unnamed)' : big.name)
end
x.each_net_pair(cp) do |p|
  a = p.first
  b = p.second
  next unless a && b
  next unless a.name.to_s == 'VDD' || b.name.to_s == 'VDD'
  puts format('VDD-PAIR %s: layout=%d terms (%s) schematic=%d terms (%s)',
              sname(p.status), a.terminal_count, a.name.to_s.empty? ? '-' : a.name,
              b.terminal_count, b.name.to_s.empty? ? '-' : b.name)
  break
end
puts format('DONE %.1f s', Time.now - T0)
$stdout.flush
exit!(0)
