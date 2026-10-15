# openroad_26q4_init.tcl -- copied to $HOME/.openroad by ws/tools/openroad_26q4.sh.
#
# WHY THIS IS NEEDED
#
#   The post-26Q4 OpenROAD build bundles Tcl 9. Tcl 9 sizes the stdout channel from the
#   process locale, and this binary is Debian-linked and runs inside the nix flow image,
#   where the Debian locale data is not (its glibc finds no C.UTF-8), so the channel comes
#   up ASCII. LibreLane's own scripts print UTF-8 -- the very first one,
#   scripts/openroad/common/io.tcl's read_pnr_libs, prints "Reading timing models for
#   corner $corner_name…" -- and the step dies on that character:
#
#     error writing "stdout": invalid or incomplete multibyte or wide character
#         while executing "puts "Reading timing models for corner $corner_name…""
#         (procedure "read_pnr_libs" line 17)
#     ERROR OpenROAD.GlobalRouting failed with an unexpected error
#
#   Measured, run diepin01, 2026-10-14 01:41 UTC: the whole resume stopped one step in.
#   Pinning the channels here is the fix; `-no_init` (which LibreLane does not pass)
#   brings the failure straight back, which is how this file's effect was confirmed.
#
#   The pinned (nix) OpenROAD is Tcl 8.6 and tolerant, so nothing here applies to it --
#   this file is only ever installed by the wrapper that runs the newer build.
catch {fconfigure stdout -encoding utf-8}
catch {fconfigure stderr -encoding utf-8}
# OpenROAD logs to file channels as well; Tcl 9 leaves them at the system encoding too.
catch {fconfigure stdout -buffering line}
