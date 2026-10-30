#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# openroad_engine.sh -- the engine wrapper for whichever host this is.
#
#   x86_64 / amd64  ->  ws/tools/openroad_26q4.sh   (the pinned 26Q4 extraction)
#   aarch64 / arm64 ->  ws/tools/openroad_arm64.sh  (the image's own build, stdbuf -oL)
#
# WHY A DISPATCHER AND NOT A TEST IN THE CHAIN
#
#   The chains name one engine path (`_LLN_OVERRIDE_OPENROAD`, `PREDRT_OR`,
#   `DIE_DRT_OR`), and the right engine is a property of the HOST, not of the arm:
#   the pinned 26Q4 image publishes amd64 only (measured 2026-10-26), so the same
#   chain started on an arm64 box would have pointed at a wrapper that exits 127.
#   Pointing them at this file keeps the choice in one place and keeps every
#   chain's default unchanged on x86.
#
#   An unknown architecture is refused rather than falling back to the image's
#   engine: a silent fallback would turn "pinned engine" into an accident of
#   which host the chain happened to land on, and the log would not say so.
set -u

HERE=$(cd "$(dirname "$0")" && pwd) || exit 127

case "$(uname -m)" in
    x86_64|amd64)
        exec "$HERE/openroad_26q4.sh" "$@"
        ;;
    aarch64|arm64)
        exec "$HERE/openroad_arm64.sh" "$@"
        ;;
    *)
        echo "openroad_engine: unsupported host arch $(uname -m) -- x86_64 uses the pinned 26Q4 engine, aarch64 the image's own" >&2
        exit 126
        ;;
esac
