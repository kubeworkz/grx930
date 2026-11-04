# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# gds_def_labels.rb -- the labels the *library cells* carry in their definitions.
#
# `lvsdb_dev_namecheck.rb` found layout nets named `D,Z,_32101_`: a net with several names, two of them
# bare pin names. Those come from the PDK cells' own definition labels, which flatten without an
# instance prefix and are therefore not unique on the die -- the reason a name can name nothing.
#
#   klayout -b -r gds_def_labels.rb -rd file=<die.gds> [-rd top=5]
FILE = $file
TOPN = ($top || 5).to_i

ly = RBA::Layout.new
ly.read(FILE)
puts "gds=#{FILE} cells=#{ly.cells} top=#{ly.top_cell.name}"

texts = Hash.new { |h, k| h[k] = Hash.new(0) }
total = 0
ly.each_cell do |c|
  next if c == ly.top_cell
  ly.layer_indexes.each do |li|
    c.shapes(li).each do |s|
      next unless s.is_text? && s.text
      texts[s.text.string][c.name] += 1
      total += 1
    end
  end
end
puts "definition texts=#{total} distinct strings=#{texts.size}"
texts.sort_by { |_k, v| -v.values.sum }.first(TOPN).each do |str, cells|
  puts format('   %-10s %d texts over %d cells', str, cells.values.sum, cells.size)
end
puts 'all distinct strings: ' + texts.keys.sort.join(' ')
$stdout.flush
exit!(0)
