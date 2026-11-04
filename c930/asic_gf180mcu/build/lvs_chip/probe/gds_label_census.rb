# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# gds_label_census.rb -- what `label_cell_nets.py` actually wrote into the streamed die.
#
# The labeller reports what it intended to write; this reads the file back. Labels go on each net's
# own label layer (34/10 for metal1, 36/10 for metal2, ...), so the census walks every layer. Three
# numbers matter: texts per layer in the top cell, how many of them are in the top cell rather than a
# cell definition (a definition label flattens to a bare `NCKI` and names nothing), and how many
# distinct `<instance>.<net>` names exist.
#
#   klayout -b -r gds_label_census.rb -rd file=<die.gds> [-rd examples=5]
FILE = $file
EXAMPLES = ($examples || 5).to_i

t0 = Time.now
ly = RBA::Layout.new
ly.read(FILE)
puts format('gds=%s  read in %.1f s', FILE, Time.now - t0)
puts "dbu=#{ly.dbu} cells=#{ly.cells} top=#{ly.top_cell.name}"

top = ly.top_cell
by_layer = Hash.new(0)
names = {}
ly.layer_indexes.each do |li|
  info = ly.get_info(li)
  key = format('%d/%d', info.layer, info.datatype)
  # `begin_shapes_rec(li).each` hands the block the iterator in this KLayout, not a shape, so step
  # it explicitly.
  it = top.begin_shapes_rec(li)
  until it.at_end?
    s = it.shape
    if s.is_text?
      t = s.text
      if t
        by_layer[key] += 1
        names[t.string] = key
      end
    end
    it.next
  end
end
total = by_layer.values.sum
puts format('texts in top cell: %d over %d layers', total, by_layer.size)
by_layer.sort_by { |_k, v| -v }.first(12).each do |k, v|
  puts format('   %-7s %8d texts', k, v)
end
puts "distinct names=#{names.size}"

dotted = names.keys.count { |n| n.include?('.') }
puts "instance-qualified (contain '.'): #{dotted}"

defs = 0
by_cell = Hash.new(0)
ly.each_cell do |c|
  next if c == top
  ly.layer_indexes.each do |li|
    c.shapes(li).each { |s| by_cell[c.name] += 1 if s.is_text? }
  end
end
defs = by_cell.values.sum
puts format('texts in cell definitions=%d (cells with any: %d)', defs, by_cell.size)
by_cell.sort_by { |_k, v| -v }.first(EXAMPLES).each do |cn, v|
  puts format('   definition %-24s %d texts', cn, v)
end

dotted_names = names.keys.select { |n| n.include?('.') }
dotted_names.sort.first(EXAMPLES).each { |n| puts "   e.g. #{n}" }
puts format('DONE %.1f s', Time.now - t0)
$stdout.flush
exit!(0)
