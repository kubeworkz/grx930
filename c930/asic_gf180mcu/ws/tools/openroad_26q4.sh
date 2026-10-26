#!/bin/sh
# openroad_26q4.sh -- the fixed OpenROAD, usable from inside the pinned flow image.
#
# WHY
#
#   The pinned image ships OpenROAD dcf36133 (rev-date 2026-02-17). Every no-path the
#   FastRoute router finds is fatal there, and the die hits two of them: global routing
#   at GRT_ADJUSTMENT 0.2 (step 37) and, with 0.1 landed, `repair_antennas`' own routing
#   pass inside OpenROAD.RepairAntennas (GRT-0183 on net _167563_). The fixed behaviour
#   is in the OpenROAD 26Q4 line (the recovery change merged Sept 2026); no released
#   LibreLane moves its pin, so the engine has to be supplied here.
#
# WHAT
#
#   The binary is extracted from openroad/debian12:26Q4-407-geb14e40b7b (OpenROAD
#   commit geb14e40b7b, the 26Q4 line) together with its shared libraries, into
#   /work/tools/or26q4/root/. The nix image's own loader cannot start a Debian-linked
#   binary, so this wrapper runs it under ITS OWN loader with a library path -- which
#   is also why no library from either distro leaks into the other.
#
# HOW LIBRELANE PICKS IT UP
#
#   _LLN_OVERRIDE_OPENROAD=/work/ws/tools/openroad_26q4.sh
#   OpenROADStep.get_openroad_path() reads exactly that variable (LibreLane
#   3.1.0.dev1, steps/openroad.py:297), so every OpenROAD-backed step -- global
#   routing, antenna repair, detailed routing, the ODB steps -- runs the new build.
#   Unset, everything is as before.
#
# HOW TO REBUILD THE EXTRACTION
#
#   IMG=openroad/debian12:26Q4-407-geb14e40b7b   # any tag on the 26Q4 line
#   T=/home/ubuntu/grx930_ol2/tools/or26q4
#   docker run --rm --user 0:0 -v $T:/out $IMG sh -c '
#     ldd /OpenROAD/install/bin/openroad | sed -n "s/.*=> \(\/[^ ]*\).*/\1/p" > /tmp/l
#     ldd /OpenROAD/install/bin/openroad | sed -n "s/^[[:space:]]*\(\/[^ ]*ld-linux[^ ]*\).*/\1/p" >> /tmp/l
#     sort -u /tmp/l > /tmp/l2
#     tar -C / -h -cf /out/orfiles.tar -T /tmp/l2
#     tar -C /OpenROAD/install/bin -h -cf /out/orbin.tar openroad'
#   mkdir -p $T/root && tar -xf $T/orfiles.tar -C $T/root && tar -xf $T/orbin.tar -C $T/root
#
#   stdbuf is part of the same extraction, and must be: see LINE BUFFERING below.
#   The /tmp/l2 list that feeds the tar gets one extra line, and the tarball
#   carries the Debian coreutils pair:
#
#     printf '%s\n' /usr/libexec/coreutils/libstdbuf.so >> /tmp/l2
#     tar -C / -h -cf /out/lbuf.tar usr/libexec/coreutils/libstdbuf.so usr/bin/stdbuf
#
# LINE BUFFERING
#
#   The router's progress lines (`    Completing 40% with 441916 violations.`) are
#   raw writes with no tag and no fflush, and LibreLane hands the tool a PIPE, so
#   they sit in an 8 KB stdio buffer. The step log therefore arrives in ~8 KB
#   blocks, which is indistinguishable from a router that has stopped -- measured
#   on diecg01: 182 lines landed in a single 03:40:48 flush after 42 minutes of
#   silence, and iteration 0's count plus iteration 1's start shared one flush.
#   The guard that stops a stalled pass (build/drt_curve_guard.sh) cannot act on a
#   log like that, so the child is made line-buffered here.
#
#   The image's own stdbuf CANNOT do this: its libstdbuf.so wants GLIBC_2.38 and
#   this binary runs on the Debian extraction's libc (measured: `version
#   `GLIBC_2.38' not found`). The extraction's own libstdbuf.so is the one that
#   matches those symbols, so it is preloaded directly -- `stdbuf` itself is not
#   needed, it only sets these two variables. Both are exported so the loader and
#   every library the router dlopens see the same buffering.
#
#   `-h` matters: without it the .so symlinks come out dangling and the loader reports
#   a missing library (`libX11-xcb.so.1: cannot open shared object file`) rather than
#   anything about the real problem.
# ENCODING: this build bundles Tcl 9, which sizes the stdout channel from the process
# locale. This binary is Debian-linked and runs inside the nix image, where its glibc
# finds no C.UTF-8 (no locale data), so the channel comes up ASCII and LibreLane's first
# non-ASCII print kills the step:
#   error writing "stdout": invalid or incomplete multibyte or wide character
#   (procedure "read_pnr_libs" line 17)          -- the "…" in its puts
# Measured: run diepin01, 2026-10-14 01:41, rc=1 one step into the resume. LC_ALL=C.UTF-8
# alone does not fix it (the locale data is the missing part). OpenROAD sources
# $HOME/.openroad at startup unless -no_init is passed (LibreLane does not pass it), so the
# wrapper installs the channel pins there.
set -u
INIT=/work/ws/tools/openroad_26q4_init.tcl
if [ -f "$INIT" ] && [ -w "${HOME:-/nonexistent}" ]; then
    cp -f "$INIT" "${HOME:-}/.openroad" 2>/dev/null || true
fi
R=/work/tools/or26q4/root
LD=""
for cand in "$R/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" "$R/lib64/ld-linux-x86-64.so.2"; do
    if [ -x "$cand" ]; then LD="$cand"; break; fi
done
if [ -z "$LD" ]; then
    echo "openroad_26q4: no dynamic loader under $R -- rebuild the extraction (see header)" >&2
    exit 127
fi
# Line-buffered stdout/stderr: `_STDBUF_O=L` is what the extracted libstdbuf.so
# reads in its constructor. Without the library the variables are inert, so a
# half-built extraction degrades to the old block buffering rather than failing.
LBUF=$R/usr/libexec/coreutils/libstdbuf.so
if [ -f "$LBUF" ]; then
    export LD_PRELOAD=${LD_PRELOAD:+$LD_PRELOAD:}$LBUF
    export _STDBUF_O=L _STDBUF_E=L
fi
exec "$LD" --library-path "$R/lib/x86_64-linux-gnu:$R/lib64" "$R/openroad" "$@"
