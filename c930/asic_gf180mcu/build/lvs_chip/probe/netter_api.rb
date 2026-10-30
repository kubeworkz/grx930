# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
%w[Netter NetlistComparer LayoutVsSchematic NetlistCrossReference].each do |c|
  next unless RBA.const_defined?(c)
  k = RBA.const_get(c)
  puts "#{c}: " + k.instance_methods.map(&:to_s).uniq.grep(/max|thread|vertex|connect|circuit|simplif|purge|align|compare/i).sort.inspect
end
