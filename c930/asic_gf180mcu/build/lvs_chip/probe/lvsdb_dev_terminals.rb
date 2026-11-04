# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_dev_terminals.rb -- for a mismatched device pair, which terminal sits on which net?
#
# `lvsdb_dev_params.rb` says none of the 242 both-sided non-Match device pairs differs in a
# parameter, so their disagreement is in terminal assignment. `Netlist#device.terminal(i)` only
# returns the terminal *definition* (a name), so the nets are collected by walking every net's
# terminals once and indexing them by (device id, terminal id).
#
#   klayout -b -r lvsdb_dev_terminals.rb -rd file=<report.lvsdb> [-rd examples=2]
FILE = $file
EXAMPLE = ($examples || 2).to_i

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

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-CIRCUIT-PAIR') unless cp

# (side, device id) -> { terminal id => net name }, plus the net's own pair status by name.
nets = { a: {}, b: {} }
status = { a: {}, b: {} }
[[cp.first, :a], [cp.second, :b]].each do |circuit, side|
  next unless circuit
  circuit.each_net do |n|
    nm = nname(n)
    n.each_terminal do |t|
      d = t.device
      next unless d
      (nets[side][d.id] ||= {})[t.terminal_id] = nm
      status[side][nm] = true
    end
  end
end
puts "indexed nets: layout #{nets[:a].size} devices, schematic #{nets[:b].size} devices"

shown = 0
x.each_device_pair(cp) do |p|
  next unless p.first && p.second && sname(p.status) != 'Match'
  puts format("\nPAIR %s layout=%s schematic=%s", sname(p.status), nname(p.first), nname(p.second))
  ka = nets[:a][p.first.id] || {}
  kb = nets[:b][p.second.id] || {}
  (ka.keys | kb.keys).sort.each do |tid|
    na = ka[tid].to_s
    nb = kb[tid].to_s
    flag = na == nb ? '  ' : ' *'
    puts format(' %s term %-2d layout=%-26s schematic=%-26s', flag, tid, na[0, 26], nb[0, 26])
  end
  shown += 1
  break if shown >= EXAMPLE
end
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
