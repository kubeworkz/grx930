require 'etc'

# No stdout buffering
$stdout.sync = true

# Active-layer fill for the wafer.space 1x1 template.
#
# Drop-in replacement for the GF180MCU PDK's libs.tech/klayout/tech/scripts/fill_all.rb: it runs
# the foundry's dummy COMP and dummy Poly2 fills (vendored next to this file with the single
# spacing change documented in README.md) and then the foundry's own metal fill unchanged.
#
# Usage (same interface as the PDK script):
#   klayout -b -zz -r fill_active.rb -rd input=<in.gds> -rd output=<out.gds> -rd topcell=<cell> \
#           [-rd threads=<n>] [-rd comp_halo_um=<um>] [-rd fill_um=<um>] \
#           [-rd line_space_um=<um>] [-rd pair_metal_um=<um>] [-rd pdk_scripts_dir=<dir>]
#
# The same names, with the same defaults, are what the flow sets through
# KLAYOUT_FILLER_OPTIONS (see README.md); every -rd value arrives as a string, so each one is
# normalised here rather than used raw.
#
# -rd comp_halo_um: extra COMP exclusion halo in um for the COMP fill (default 0 = the checked
# DCF.4 rule distance; 10 reproduces the foundry fill_comp.rb). The Poly2 fill is generated
# from the resulting dummy COMP and has no halo of its own -- see fill_poly2_active.rb.
# -rd fill_um / line_space_um: the COMP fill cell and its line space (default 6.0 / 2.0 -- 2.0
# because DCF.2b's checked minimum is 1.9 and the pattern's own diagonal term is
# (line_space - 0.5) * sqrt(2), see fill_comp_active.rb; 5.0 / 3.0 reproduces the foundry
# fill_comp.rb pattern).
# -rd pair_metal_um: DPF.12/DPF.13 (dummy Poly2 to circuit Metal1/Metal2) for the pairing filter
# (default 0 = off, because the deck comments both rules out; 2.0 is the deck's value when they
# are enabled). See fill_poly2_active.rb for the evidence.
#
# Read-required: the foundry metal fill still comes from the PDK (fill_metal.rb), located via
# -rd pdk_scripts_dir or the PDK_ROOT/PDK environment. $Metal2_ignore_active is the one option
# that still reaches it, unchanged, through the flow's KLAYOUT_FILLER_OPTIONS.

# klayout -b -r script exits 0 even when the script raised, so a failed fill would look like a
# successful flow step. Force a non-zero status unless the write at the end actually happened.
$fill_ok = false
at_exit do
  next if $fill_ok
  $stdout.puts "FILL_INCOMPLETE"
  $stdout.flush
  $stderr.flush
  exit!(1)
end

puts "Reading layout…"

$ly = RBA::Layout::new()
$ly.read($input)

$micron2dbu = RBA::CplxTrans::new($ly.dbu).inverted

$top_cell = $ly.top_cell

# Layers

COMP   = $ly.layer(22, 0)
Poly2  = $ly.layer(30, 0)
Metal1 = $ly.layer(34, 0)
Metal2 = $ly.layer(36, 0)
Metal3 = $ly.layer(42, 0)
Metal4 = $ly.layer(46, 0)
Metal5 = $ly.layer(81, 0)

RES_MK = $ly.layer(110, 5)
IND_MK = $ly.layer(151, 5)

Nwell    = $ly.layer(21, 0)
DNWELL   = $ly.layer(12, 0)
LVPWELL  = $ly.layer(204, 0)
Dualgate = $ly.layer(55, 0)

Pad = $ly.layer(37, 0)

COMP_Dummy   = $ly.layer(22, 4)
Poly2_Dummy  = $ly.layer(30, 4)
Metal1_Dummy = $ly.layer(34, 4)
Metal2_Dummy = $ly.layer(36, 4)
Metal3_Dummy = $ly.layer(42, 4)
Metal4_Dummy = $ly.layer(46, 4)
Metal5_Dummy = $ly.layer(81, 4)

FuseTop       = $ly.layer(75, 0)
POLYFUSE      = $ly.layer(220, 0)
FUSEWINDOW_D  = $ly.layer(96, 1)
PMNDMY        = $ly.layer(152, 5)
MTPMK         = $ly.layer(122, 5)
OTP_MK        = $ly.layer(173, 5)
NDMY          = $ly.layer(111, 5)

# chip's bbox (boundary to fill)
$chip = $ly.top_cell().dbbox()

# threads (-rd yields a String, so normalise it before it reaches TilingProcessor)
$threads = ($threads || Etc.nprocessors).to_i
$threads = Etc.nprocessors if $threads < 1

# The spacing parameter. -rd yields strings on the KLayout command line, so normalise it here.
$comp_halo_um = ($comp_halo_um || 0.0).to_f

puts "COMP exclusion halo: #{$comp_halo_um} um"

# The metal fill is still the foundry's own script (metals already pass the density deck, and
# the metal pattern is the part most sensitive to getting the DRC exactly right). Locate it in
# the PDK, overridable with -rd pdk_scripts_dir=<dir>.
$pdk_scripts_dir ||= ENV['PDK_SCRIPTS_DIR']
if ! $pdk_scripts_dir || $pdk_scripts_dir.to_s.empty?
  pdk_root = ENV['PDK_ROOT']
  pdk      = ENV['PDK'] || 'gf180mcuD'
  $pdk_scripts_dir = File.join(pdk_root.to_s, pdk, 'libs.tech', 'klayout', 'tech', 'scripts')
end
if ! $pdk_scripts_dir || ! File.directory?($pdk_scripts_dir)
  $stderr.puts "ERROR: PDK scripts directory not found (#{$pdk_scripts_dir.inspect}); " \
               "pass -rd pdk_scripts_dir=<dir> or set PDK_ROOT/PDK"
  exit 1
end
puts "PDK scripts: #{$pdk_scripts_dir}"

# Get (or create) a top-level fill cell. If the layout already carries the cell -- filling a
# layout that has been through a fill before -- it is reused together with its existing
# top-level instance, so re-running the script never doubles the instances.
def fill_companion_cell(name)
  cell = $ly.cell(name)
  return cell if cell
  cell = $ly.create_cell(name)
  $top_cell.insert(RBA::CellInstArray::new(cell, RBA::Trans::new(0, 0)))
  cell
end

$ly.start_changes()

$fill_cell_comp   = fill_companion_cell("COMP_FILL")
$fill_cell_poly2  = fill_companion_cell("POLY2_FILL")
$fill_cell_metal1 = fill_companion_cell("METAL1_FILL")
$fill_cell_metal2 = fill_companion_cell("METAL2_FILL")
$fill_cell_metal3 = fill_companion_cell("METAL3_FILL")
$fill_cell_metal4 = fill_companion_cell("METAL4_FILL")
$fill_cell_metal5 = fill_companion_cell("METAL5_FILL")

$ly.end_changes()

# This is an object which will receive the regions to tile
# It is driven single-threaded which is good since the tiling function
# isn't multi-threading safe
class TilingOperator < RBA::TileOutputReceiver
  def initialize(ly, fill_cell, *fill_args)
    @ly = ly
    @fill_cell = fill_cell
    @fill_args = fill_args
  end
  def put(ix, iy, tile, obj, dbu, clip)
    # This is the core function. It creates the fill.
    # For details see https://www.klayout.de/doc-qt4/code/class_Cell.html#k_63
    @fill_cell.fill_region(obj, *@fill_args)
  end
end

puts "Starting COMP fill…"
require_relative 'fill_comp_active.rb'

puts "Starting Poly2 fill…"
require_relative 'fill_poly2_active.rb'

puts "Starting Metal fill…"
require File.join($pdk_scripts_dir, 'fill_metal.rb')

puts "Done!"

$ly.write($output)
raise "output file #{$output} was not written" unless File.file?($output) && File.size($output) > 0
puts "Wrote #{$output} (#{File.size($output)} bytes)"

$fill_ok = true
