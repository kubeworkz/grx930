# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# lvsdb_attrib.rb -- attribute every non-Match net and device pair in a lvsdb to the cell it sits in,
# and say *why* it is a non-Match.
#
# `xref.txt` gives the totals (752 device pairs, 1,112 net pairs at Mismatch). Grouping them by
# instance says where they are but not whether the die has a defect: for a device pair whose class
# and parameters agree, is the terminal connectivity really different, or is the comparer only
# failing to confirm an equivalent device?
#
#   klayout -b -r lvsdb_attrib.rb -rd file=<report.lvsdb> -rd def=<filled.def> -rd out=<dir>
#
# Classification of a device pair:
#   param_diff          a parameter (W/L/NF...) differs between the two devices
#   terminals_equal     every terminal sits on the paired net, yet the comparer did not call it Match
#   terminals_reordered the same multiset of nets on both sides, assigned to different terminals
#                       (a source/drain or bulk transposition: topologically equivalent for a MOS)
#   nets_differ         the sets differ, i.e. a terminal really is on another net
#
# Nets are identified by name: `Netlist::Net` has no id in this build, and KLayout keeps net names
# unique within a circuit, so the expanded name is a sound key (`$123` included).
FILE = $file
DEF_FILE = $def
OUTDIR = $out
EXAMPLE = ($examples || 10).to_i

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

# A schematic device is named `<instance>.<device>`; the prefix is the placed cell. A layout device
# is flat and carries no hierarchy.
def inst_of(name)
  s = name.to_s
  s.include?('.') ? s.split('.', 2).first : '(top)'
end

def mul(arr)
  arr.group_by { |v| v }.map { |k, v| [k.to_s, v.size] }.sort_by { |k, _| k }
end

# Parameters. `Device#each_parameter` does not exist in 0.29; the class carries the definitions and
# `Device#parameter(name)` the value. Print the first device's set so a silent empty is visible.
def params(dev)
  h = {}
  dc = dev.device_class
  return h unless dc && dc.respond_to?(:parameter_definitions)
  dc.parameter_definitions.each do |pd|
    name = (pd.respond_to?(:name) ? pd.name : pd.to_s).to_s
    begin
      h[name] = dev.parameter(name)
    rescue StandardError
      h[name] = nil
    end
  end
  h
rescue StandardError
  h
end

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-CIRCUIT-PAIR') unless cp
puts 'CIRCUIT PAIR ' + ((cp.first || cp.second).respond_to?(:name) ? (cp.first || cp.second).name : '?')

begin
  d0 = nil
  cp.first.each_device { |d| d0 = d; break } if cp.first
  if d0
    puts 'API params(first device): ' + params(d0).inspect
    n0 = nil
    cp.first.each_net { |n| n0 = n; break }
    puts 'API net: ' + n0.methods.grep(/name|id|index/).sort.join(' ') if n0
  end
rescue StandardError => e
  puts "API probe failed: #{e.class}: #{e.message}"
end

# --- DEF: instance -> cell type ----------------------------------------------------------------
inst_cell = {}
if DEF_FILE && File.exist?(DEF_FILE)
  File.foreach(DEF_FILE) do |line|
    s = line.lstrip
    next unless s.start_with?('- ')
    parts = s.split
    inst_cell[parts[1]] = parts[2] if parts.size >= 3
  end
end
puts "DEF instances #{inst_cell.size}"

# --- net index: (side, device id) -> { terminal id => net name } --------------------------------
terms = { a: [], b: [] }
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
puts "indexed terminals: layout #{terms[:a].compact.size} devices, schematic #{terms[:b].compact.size} devices"

# --- net pairing map: layout net name -> schematic net name -------------------------------------
netmap = {}
net_pairs = 0
x.each_net_pair(cp) do |p|
  next unless p.first && p.second
  netmap[nname(p.first)] = nname(p.second)
  net_pairs += 1
end
puts "paired nets #{net_pairs}"

outdir = OUTDIR || '.'
Dir.mkdir(outdir) unless File.directory?(outdir)
dev_io = File.open(File.join(outdir, 'attrib_dev.txt'), 'w')
net_io = File.open(File.join(outdir, 'attrib_net.txt'), 'w')

dev_class = Hash.new(0)
dev_by_inst = Hash.new(0)
dev_by_cell = Hash.new(0)
term_perm = Hash.new(0)
net_class = Hash.new(0)
net_by_inst = Hash.new(0)
net_by_cell = Hash.new(0)
examples = []
dev_pairs = 0
net_pairs_bad = 0

x.each_device_pair(cp) do |p|
  next unless p.first && p.second
  st = sname(p.status)
  next if st == 'Match'
  dev_pairs += 1
  a = p.first
  b = p.second
  inst = inst_of(nname(b))
  cell = inst_cell[inst] || '(not-in-DEF)'
  pa = params(a)
  pb = params(b)
  delta = (pa.keys | pb.keys).reject { |k| pa[k] == pb[k] }
  ka = terms[:a][a.id] || {}
  kb = terms[:b][b.id] || {}
  ids = (ka.keys | kb.keys).sort
  la = ids.map { |t| ka[t] ? netmap[ka[t]] : nil }
  lb = ids.map { |t| kb[t] }
  same = ids.all? { |t| ka[t] && kb[t] && netmap[ka[t]] == kb[t] }
  reordered = !same && ids.all? { |t| ka[t] && kb[t] && netmap[ka[t]] } && mul(la) == mul(lb)
  kind = if delta.any? then 'param_diff'
         elsif same then 'terminals_equal'
         elsif reordered then 'terminals_reordered'
         else 'nets_differ'
         end
  if reordered
    moved = ids.reject { |t| netmap[ka[t]] == kb[t] }
    term_perm[moved.join(',')] += 1 unless moved.empty?
  end
  dev_class[kind] += 1
  dev_by_inst[inst] += 1
  dev_by_cell[cell] += 1
  dev_io.puts [st, kind, inst, cell, delta.map { |k| "#{k}=#{pa[k].inspect}/#{pb[k].inspect}" }.join(','),
               ids.map { |t| "#{t}:#{ka[t]}=>#{kb[t]}" }.join(' ')].join("\t")
  next if examples.size >= EXAMPLE
  examples << [st, kind, inst, cell, nname(a), nname(b), delta, moved]
end

x.each_net_pair(cp) do |p|
  st = sname(p.status)
  next if st == 'Match'
  net_pairs_bad += 1
  if p.first && p.second
    na = nname(p.first)
    nb = nname(p.second)
    inst = inst_of(nb)
    cell = inst_cell[inst] || '(not-in-DEF)'
    kind = if na.start_with?('$') then 'layout-anonymous'
           elsif na == nb then 'same-name'
           elsif na.upcase == nb.upcase then 'case-only'
           else 'different-name'
           end
    net_class[kind] += 1
    net_by_inst[inst] += 1
    net_by_cell[cell] += 1
    net_io.puts [st, kind, inst, cell, na, nb].join("\t")
  elsif p.first
    net_class['layout-only'] += 1
    net_by_inst['(layout-only)'] += 1
    net_io.puts [st, 'layout-only', '', '', nname(p.first), '(nil)'].join("\t")
  else
    nb = nname(p.second)
    inst = inst_of(nb)
    cell = inst_cell[inst] || '(not-in-DEF)'
    net_class['schematic-only'] += 1
    net_by_inst[inst] += 1
    net_by_cell[cell] += 1
    net_io.puts [st, 'schematic-only', inst, cell, '(nil)', nb].join("\t")
  end
end
dev_io.close
net_io.close

puts "== device pairs at non-Match: #{dev_pairs}"
dev_class.sort_by { |_k, v| -v }.each { |k, v| puts format('  %-20s %d', k, v) }
puts "== terminal ids that moved (reordered): #{term_perm.values.sum}"
term_perm.sort_by { |_k, v| -v }.first(6).each { |k, v| puts format('  terms %-12s %d', k, v) }
puts "== device non-Match by cell type: #{dev_by_cell.size} types"
dev_by_cell.sort_by { |_k, v| -v }.first(20).each { |k, v| puts format('  %-52s %d', k, v) }
puts "== device non-Match by instance: #{dev_by_inst.size}"
dev_by_inst.sort_by { |_k, v| -v }.first(EXAMPLE).each { |k, v| puts format('  %-14s %d', k, v) }

puts "== net pairs at non-Match: #{net_pairs_bad}"
net_class.sort_by { |_k, v| -v }.each { |k, v| puts format('  %-20s %d', k, v) }
puts "== net non-Match by cell type: #{net_by_cell.size} types"
net_by_cell.sort_by { |_k, v| -v }.first(20).each { |k, v| puts format('  %-52s %d', k, v) }

puts '== examples'
examples.each do |st, kind, inst, cell, a, b, delta, moved|
  puts format('  %-9s %-19s %-14s %-40s %s', st, kind, inst, cell, delta.map(&:to_s).join(','))
  puts format('      layout=%s schematic=%s moved=%s', a, b, moved.inspect)
end
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
