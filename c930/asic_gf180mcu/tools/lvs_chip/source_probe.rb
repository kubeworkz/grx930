GDS = "/work/c930/asic_gf180mcu/wafer_space_submission/grx930_test_chip_final.gds"
CELL = "gf180mcu_fd_sc_mcu7t5v0__clkinv_1"

def poly_count(ly)
  n = 0
  ly.each_cell do |c|
    ly.layer_indexes.each do |li|
      c.shapes(li).each { |_s| n += 1 }
    end
  end
  n
end

begin
  source(GDS, CELL)
  puts "source(cell): cell_name=#{source.cell_name} cells=#{source.cells}"
  puts "source(cell): polygons=#{poly_count(source)}"
rescue => e
  puts "source(cell) failed: #{e.class}: #{e}"
end

begin
  source(GDS)
  puts "source(all):  cell_name=#{source.cell_name} cells=#{source.cells}"
  puts "source(all):  polygons=#{poly_count(source)}"
rescue => e
  puts "source(all) failed: #{e.class}: #{e}"
end
