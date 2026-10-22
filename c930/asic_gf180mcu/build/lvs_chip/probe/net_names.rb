# net_names.rb -- does the streamed die carry the labels that would let the comparer align by name?
#
# The LVS engine has `consider_net_names(f)` ("the netlist comparer shall use net names") and an
# aligner whose cost is dominated by ambiguous net matching. Whether that switch can help at all
# depends on a fact about the file: does stream_out.gds carry a text label per net, or only the
# pin labels? This counts texts per layer and prints a sample.
#
#   MSYS_NO_PATHCONV=1 docker run --rm -v "<repo>:/work" ghcr.io/efabless/openlane2:2.3.10 \
#     klayout -b -r /work/c930/asic_gf180mcu/build/lvs_chip/probe/net_names.rb \
#     -rd gds=/work/c930/asic_gf180mcu/build/lvs_chip/stream_out.gds
$gds = $gds || '/work/c930/asic_gf180mcu/build/lvs_chip/stream_out.gds'
ly = RBA::Layout::new
ly.read($gds)
tc = ly.top_cell
puts "top      #{tc.name}  cells #{ly.cells}  dbu #{ly.dbu}"
texts = Hash.new { |h, k| h[k] = [] }
tc.each_inst do |inst|
  # depth 1 only; texts inside library cells are pin labels and are counted separately below
end
ly.layer_indexes.each do |li|
  lname = ly.get_info(li)
  ly.each_cell do |c|
    c.shapes(li).each do |si|
      next unless si.is_text?
      t = si.text
      texts[[lname.layer, lname.datatype]] << t.string
    end
  end
end
texts.sort_by { |k, v| -v.size }.each do |(l, d), v|
  sample = v.uniq.first(6).join(' ')
  puts format('layer %-3d/%-3d texts %-8d distinct %-8d e.g. %s', l, d, v.size, v.uniq.size, sample)
end
puts "total texts #{texts.values.map(&:size).sum}"
