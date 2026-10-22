# align_bench.rb -- time the netlist comparison without the 67-minute extraction in front of it.
#
# The die's deck reaches `align` and stops there: 5 h 45 min in the run that was killed at 22:00Z
# without returning (build/lvs_chip/run_chip_stream/klayout.silent_6h.log), 13 min in the run that
# was stopped on purpose (probe.align_default_13min.log). Every experiment that changes one knob
# cannot pay an hour of extraction per data point, so this reads the two netlists the deck would
# have compared -- the extracted netlist from `--net-only`, the CDL from mk_chip_cdl.py -- and runs
# RBA::NetlistComparer on them directly.
#
# What it answers, in order:
#   1. do the two netlists name their circuits the same way? `align`'s documented job is to
#      flatten circuits that have no counterpart, so a name mismatch is both a correctness problem
#      and the likeliest reason the aligner is expensive.
#   2. how long does compare take at the installed defaults, and at lower ambiguity bounds
#      (max_branch_complexity, max_depth)?
#
# This is a timing instrument, not a verdict: the comparer here is constructed by hand, so device
# classes are whatever the two readers produced, which is not what the deck's LVSEngine sets up.
# A MATCH from this script is encouraging; the deck's own compare is the only PASS.
#
#   MSYS_NO_PATHCONV=1 docker run --rm -v "<repo>:/work" -w /work \
#     ghcr.io/efabless/openlane2:2.3.10 \
#     klayout -b -r /work/c930/asic_gf180mcu/build/lvs_chip/probe/align_bench.rb \
#       -rd extracted=/work/c930/asic_gf180mcu/build/lvs_chip/run_chip_stream/extracted.cir \
#       -rd schematic=/work/c930/asic_gf180mcu/build/lvs_chip/grx930_test_chip.cdl \
#       -rd max_branch=500 -rd max_depth=8

C = '/work/c930/asic_gf180mcu'
$extracted = $extracted || "#{C}/build/lvs_chip/run_chip_stream/extracted.cir"
$schematic = $schematic || "#{C}/build/lvs_chip/grx930_test_chip.cdl"


# -rd values are strings, and "0" is truthy in Ruby: every flag goes through this.
def flag?(v)
  !v.nil? && !%w[0 false no off].include?(v.to_s.downcase)
end


def read_netlist(path, label)
  unless File.exist?(path)
    puts "CANNOT-RUN #{label}: no such file #{path}"
    exit 2
  end
  t = Time.now
  nl = RBA::Netlist::new
  nl.read(path, RBA::NetlistSpiceReader::new)
  puts format('read %-9s %-60s %.1f s', label, File.basename(path), Time.now - t)
  nl
end


def stats(nl)
  circuits = 0
  devices = 0
  subcircuits = 0
  nl.each_circuit do |c|
    circuits += 1
    c.each_device { |_d| devices += 1 }
    c.each_subcircuit { |_s| subcircuits += 1 }
  end
  [circuits, devices, subcircuits]
end

layout_nl = read_netlist($extracted, 'layout')
schematic_nl = read_netlist($schematic, 'schematic')

lc, ld, ls = stats(layout_nl)
sc, sd, ss = stats(schematic_nl)
puts format('layout    circuits=%d devices=%d subcircuits=%d', lc, ld, ls)
puts format('schematic circuits=%d devices=%d subcircuits=%d', sc, sd, ss)

layout_names = {}
layout_nl.each_circuit { |c| layout_names[c.name] = true }
schem_names = {}
schematic_nl.each_circuit { |c| schem_names[c.name] = true }
only_layout = layout_names.keys.sort - schem_names.keys.sort
only_schem = schem_names.keys.sort - layout_names.keys.sort
puts "common circuits #{ (layout_names.keys & schem_names.keys).size }"
puts "only in layout  #{only_layout.size}  #{only_layout.first(8).join(' ')}"
puts "only in schematic #{only_schem.size}  #{only_schem.first(8).join(' ')}"

# The deck combines devices AFTER `align` (its prologue is align, make_top_level_pins, simplify,
# combine_devices, purge). If the aligner's cost is ambiguous device/net matching, combining first
# shrinks what it has to match: parallel devices of the same flavour become one. The switch exists
# so the deck can be reordered on the strength of a measurement rather than a guess.
if flag?($combine)
  t = Time.now
  layout_nl.combine_devices
  schematic_nl.combine_devices
  lc, ld, _ = stats(layout_nl)
  sc, sd, _ = stats(schematic_nl)
  puts format('combine_devices %.1f s -> layout devices=%d schematic devices=%d', Time.now - t, ld, sd)
end
if flag?($simplify)
  t = Time.now
  layout_nl.simplify
  schematic_nl.simplify
  puts format('simplify %.1f s', Time.now - t)
end

cmp = RBA::NetlistComparer::new
branch = ($max_branch || 500).to_i
depth = ($max_depth || 8).to_i
cmp.max_branch_complexity = branch if cmp.respond_to?(:max_branch_complexity=)
cmp.max_depth = depth if cmp.respond_to?(:max_depth=)
puts "compare: max_branch_complexity=#{branch} max_depth=#{depth}"

t = Time.now
begin
  same = cmp.compare(layout_nl, schematic_nl)
  puts format('RESULT %s in %.1f s', same ? 'MATCH' : 'MISMATCH', Time.now - t)
  exit(same ? 0 : 1)
rescue StandardError => e
  puts format('RESULT raised %s: %s after %.1f s', e.class, e.message, Time.now - t)
  exit 2
end
