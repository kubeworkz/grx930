# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# align_api.rb -- what the comparison engine actually exposes.
#
# The chip run's silent stretch is somewhere at or around `align`, and the deck's own log cannot
# say where (see build/lvs_chip_probe_deck.sh). Before anything is reordered or skipped, this
# asks the installed KLayout what knobs exist: the netlist aligner's own methods, the
# cross-reference object the deck's `compare` returns, and what each one accepts.
#
# Run in the flow image (MSYS_NO_PATHCONV=1 on Windows):
#   docker run --rm -v "<repo>:/work" ghcr.io/efabless/openlane2:2.3.10 \
#     klayout -b -r /work/c930/asic_gf180mcu/build/lvs_chip/probe/align_api.rb
#
# Read-only: it constructs nothing but two empty netlists and prints names.

puts "VERSION #{RBA.const_defined?(:Version) ? RBA::Version : 'unknown'}"
puts "RUBY    #{RUBY_VERSION}"

PAT = /align|match|compare|ambigu|thread|toleran|depth|limit|max|verbose|hier|combine|simplify/i

%w[NetlistComparer NetlistCrossReference Netlist NetlistCircuit NetlistDeviceClass
   LayoutVsSchematic NetlistExtractor].each do |cls|
  next unless RBA.const_defined?(cls)
  k = RBA.const_get(cls)
  ms = k.instance_methods.map(&:to_s).uniq.grep(PAT).sort
  puts "#{cls}: #{ms.inspect}"
end

# Arity matters as much as the name: a knob that takes no argument cannot be tuned.
if RBA.const_defined?(:NetlistComparer)
  cmp = RBA::NetlistComparer.new
  RBA::NetlistComparer.instance_methods.map(&:to_s).uniq.grep(PAT).sort.each do |m|
    obj = cmp.respond_to?(m) ? cmp : RBA::NetlistComparer
    begin
      puts "  NetlistComparer##{m} arity=#{obj.method(m).arity}"
    rescue StandardError => e
      puts "  NetlistComparer##{m} arity=?(#{e.class})"
    end
  end
end

# The aligner itself, if this build exposes it as a class rather than as a comparer method.
%w[NetlistAligner NetlistAlignment NetlistCrossReference].each do |cls|
  next unless RBA.const_defined?(cls)
  k = RBA.const_get(cls)
  puts "#{cls} methods: #{k.instance_methods.map(&:to_s).uniq.sort.first(40).inspect}"
end

nl = RBA::Netlist.new
nl.circuit("a")
nl.circuit("b")
cmp = RBA::NetlistComparer.new
if cmp.respond_to?(:align)
  begin
    xref = cmp.align(nl, nl)
    puts "align(nl, nl) -> #{xref.class}"
    puts "xref methods: #{xref.class.instance_methods.map(&:to_s).uniq.grep(PAT).sort.inspect}"
  rescue StandardError => e
    puts "align(nl, nl) raised #{e.class}: #{e.message}"
  end
else
  puts "NetlistComparer has no align method (the DSL's align is elsewhere)"
end

# The DSL's `align` is a method on the LVS context; its arity is what says whether the deck could
# pass it anything at all (a class filter, a thread count) without editing KLayout.
begin
  puts "global align arity: #{method(:align).arity}"
rescue NameError
  puts "global align: not defined outside a deck (expected: it is DSL-provided)"
end
