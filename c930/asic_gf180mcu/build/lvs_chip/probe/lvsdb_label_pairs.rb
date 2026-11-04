# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_label_pairs.rb -- do the instance-qualified labels name the nets the comparer paired?
#
# The die carries 133,478 labels of the form `<instance>.<net>`, written at positions verified on the
# cell's own metal. A label that landed on a neighbour's shape would show up here as a paired net
# whose two names disagree in their suffix (`_38455_.NET_2` against `_38455_.NET_1`) -- the pairing
# is the comparer's own, so this is an independent check of every label it managed to pair.
#
#   klayout -b -r lvsdb_label_pairs.rb -rd file=<report.lvsdb> [-rd examples=10]
FILE = $file
EXAMPLE = ($examples || 10).to_i

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
  return '' if o.nil?
  return o.expanded_name if o.respond_to?(:expanded_name)
  return o.name if o.respond_to?(:name)
  o.to_s
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp

same = differ = only_layout = only_schematic = 0
examples = []
# A bucket per outcome: with one shared list the first ten lines came from whichever branch ran
# first (`schematic-only`), which says nothing about the `differ` cases the check is about.
differ_examples = []
x.each_net_pair(cp) do |p|
  a = nname(p.first)
  b = nname(p.second)
  next if a.empty? || b.empty?
  a_internal = a.include?('.') && !a.start_with?('$')
  b_internal = b.include?('.')
  next unless a_internal || b_internal
  if a_internal && b_internal
    ai, an = a.split('.', 2)
    bi, bn = b.split('.', 2)
    if ai == bi && an.casecmp(bn).zero?
      same += 1
    else
      differ += 1
      differ_examples << [sname(p.status), a, b] if differ_examples.size < EXAMPLE
      examples << [sname(p.status), a, b] if examples.size < EXAMPLE
    end
  elsif a_internal
    only_layout += 1
    examples << [sname(p.status), a, '(unnamed)'] if examples.size < EXAMPLE
  else
    only_schematic += 1
    examples << [sname(p.status), '(unnamed)', b] if examples.size < EXAMPLE
  end
end
puts "INSTANCE-QUALIFIED PAIRS same=#{same} differ=#{differ} layout-only=#{only_layout} schematic-only=#{only_schematic}"
puts 'DIFFER EXAMPLES'
differ_examples.each { |s, a, b| puts format('  %-10s layout=%-40s schematic=%s', s, a[0, 40], b[0, 40]) }
puts 'ANY EXAMPLES'
examples.each { |s, a, b| puts format('  %-10s layout=%-40s schematic=%s', s, a[0, 40], b[0, 40]) }
$stdout.flush
exit!(0)
