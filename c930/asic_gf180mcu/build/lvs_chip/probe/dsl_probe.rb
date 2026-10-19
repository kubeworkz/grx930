# probe: which tiling/threading directives does the LVS DSL expose?
puts "PROBE threads? #{respond_to?(:threads).inspect}"
puts "PROBE tiles? #{respond_to?(:tiles).inspect}"
puts "PROBE tile_borders? #{respond_to?(:tile_borders).inspect}"
puts "PROBE methods: #{methods.grep(/thread|tile|tiling|deep|flat/).sort.inspect}"
