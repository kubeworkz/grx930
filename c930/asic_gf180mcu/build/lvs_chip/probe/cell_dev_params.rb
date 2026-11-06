# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# cell_dev_params.rb -- what junction parameters does a *standalone* cell extraction carry?
#
# The die run reports 752 device pairs whose only difference is AS/AD/PS/PD, with the schematic
# side 0.0. If a standalone cell extraction already carries those same nonzero areas and still
# matches its CDL, then the die difference is not "the schematic has no areas" -- it is that the
# die's geometry differs from the standalone cell's, and the parameters are the symptom.
#
#   klayout -b -r cell_dev_params.rb -rd file=<cell report.lvsdb>
FILE = $file
abort('usage: -rd file=<report.lvsdb>') unless FILE

lvs = RBA::LayoutVsSchematic.new
lvs.read(FILE)
x = lvs.xref
abort('NO-XREF') unless x

cp = nil
x.each_circuit_pair { |p| cp = p; break }
abort('NO-PAIR') unless cp
cc = cp.first
abort('NO-LAYOUT-CIRCUIT') unless cc

sigs = Hash.new(0)
cc.each_device do |d|
  dc = d.device_class
  vals = dc.parameter_definitions.map do |pd|
    v = begin
      d.parameter(pd.name)
    rescue StandardError
      'n/a'
    end
    "#{pd.name}=#{v}"
  end
  sigs["#{dc.name} #{vals.join(' ')}"] += 1
end
puts "circuit #{cc.name} devices=#{sigs.values.sum} distinct=#{sigs.size}"
sigs.sort_by { |_k, v| -v }.first(12).each { |k, v| puts format('%6d  %s', v, k) }
$stdout.flush
exit!(0)
