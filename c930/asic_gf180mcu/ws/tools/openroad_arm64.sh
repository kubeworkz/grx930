#!/bin/sh
# openroad_arm64.sh -- the arm64 host's engine wrapper: the flow image's OWN
# openroad (the nix build LibreLane already resolves), run under `stdbuf -oL` so
# its progress lines reach the step log one line at a time.
#
# WHY THIS EXISTS
#
#   ws/tools/openroad_26q4.sh pins the 26Q4 engine by extracting
#   openroad/debian12:26Q4-407-geb14e40b7b and running it under that extraction's
#   loader. That image is amd64 ONLY -- measured on 2.31.100.64 (aarch64),
#   2026-10-26:
#
#     docker pull ...          => no matching manifest for linux/arm64/v8
#     docker manifest inspect  => "architecture": "amd64"   (single entry)
#
#   so on an aarch64 host the pinned wrapper has nothing it can exec and exits
#   127. An arm64 arm therefore runs the engine the pre-check image ships:
#   OpenROAD dcf36133, which is the SAME commit the x86 flow image pins -- the
#   arm is not running a different engine from the x86 boxes, only a different
#   host architecture for it.
#
# WHAT THIS DOES NOT PROVIDE
#
#   The 26Q4 line's fixes are not in dcf36133. The die hits two no-paths that
#   only 26Q4 recovers from: global routing at GRT_ADJUSTMENT 0.2 (step 37) and
#   `repair_antennas`' own routing pass inside OpenROAD.RepairAntennas (GRT-0183
#   on net _167563_). A step that needs those fixes cannot be rescued on arm64 --
#   it has to run on an x86 host. This wrapper makes an arm64 arm possible and
#   observable; it does not make it equivalent. The banner it prints says so on
#   every step, so an arm64 log is never mistaken for a pinned-engine log.
#
# WHY PLAIN stdbuf IS ENOUGH HERE (AND IS NOT ON x86)
#
#   On x86 the image's own stdbuf cannot touch the Debian-linked 26Q4 binary --
#   its libstdbuf.so wants GLIBC_2.38 and the wrapper has to preload the
#   extraction's instead. Here both sides are the image's own nix build, so the
#   `stdbuf` on PATH and the `openroad` on PATH agree on libc, and `stdbuf -oL`
#   does what it says.
#
#   It matters because LibreLane hands the tool a PIPE. Without line buffering
#   the router's raw progress writes sit in an 8 KB stdio buffer, so the step log
#   looks frozen for tens of minutes and build/drt_curve_guard.sh cannot tell a
#   stall from a slow iteration (measured on diecg01: 182 lines arrived in one
#   03:40:48 flush after 42 minutes of silence). That is the same failure the
#   x86 wrapper's libstdbuf preload addresses, reached a different way.
#
# NO INIT FILE
#
#   openroad_26q4_init.tcl is NOT installed here, deliberately. It exists to pin
#   Tcl 9's stdout channel to UTF-8 for the Debian-linked 26Q4 build, whose glibc
#   finds no C.UTF-8 inside the nix image. This image's openroad is Tcl 8.6 and
#   tolerant, so there is nothing to pin -- and writing a $HOME/.openroad for it
#   would change behaviour the flow does not otherwise have on arm64.
#
# HOW THE FLOW PICKS IT
#
#   _LLN_OVERRIDE_OPENROAD=/work/ws/tools/openroad_arm64.sh
#   or let the host decide: ws/tools/openroad_engine.sh.
#
# TESTING
#
#   OR_ARM64_BIN=<program> replaces the engine, which is how the line buffering
#   is measured against a writer with known behaviour: the wrapper execs
#   `stdbuf -oL <program>`, so a program that writes one line per second shows
#   the log growing per poll here and not without it.
set -u

ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64) ;;
    *)
        echo "openroad_arm64: host is $ARCH, not aarch64 -- use ws/tools/openroad_26q4.sh for the pinned engine" >&2
        exit 126
        ;;
esac

BIN=${OR_ARM64_BIN:-}
if [ -z "$BIN" ]; then
    BIN=$(command -v openroad) || {
        echo "openroad_arm64: no openroad on PATH -- this wrapper runs the flow image's own engine, so it must run inside that image" >&2
        exit 127
    }
fi
[ -x "$BIN" ] || { echo "openroad_arm64: $BIN is not executable" >&2; exit 126; }

# The banner is skipped for `-version`: the chains record which engine ran with
# `"$OR" -version 2>&1 | head -1`, and a banner line there would hide the version.
if [ "${1:-}" != "-version" ] && [ "${1:-}" != "--version" ]; then
    echo "OPENROAD_ARM64: $BIN under stdbuf -oL (image engine, no 26Q4 fixes)" >&2
fi

if ! command -v stdbuf >/dev/null 2>&1; then
    echo "OPENROAD_ARM64: no stdbuf on PATH -- running block-buffered; the step log will not grow between polls and the guard falls back to its wall-clock bounds" >&2
    exec "$BIN" "$@"
fi

exec stdbuf -oL "$BIN" "$@"
