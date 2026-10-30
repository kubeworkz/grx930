#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gridworkz
# reset_cts_install_check.sh -- does ws/tools/lln_reset_cts.sh actually install the
# CTS patch in THIS image? Run it as a container command, the same way ws_exec.sh is:
#
#   docker run --rm --user 0:0 -v /home/ubuntu/grx930_ol2:/work \
#       ghcr.io/wafer-space/gf180mcu-precheck:latest \
#       /work/ws/probe/reset_cts_install_check.sh
#
# Why this exists: the patch writes into /nix/store, which is read-only on most
# images. "The wrapper is sourced and cannot fail" is not evidence that the CTS
# script was changed -- a read-only store answers `PATCH_LLN_RESET_CTS
# status=read-only` and the flow then runs exactly as LibreLane built it, with the
# reset untreed and nothing in the step log saying so. One line, one exit code.
#
# A fresh container starts from the unmodified image, so this measures what an arm
# gets, not what a previous arm left behind.
. /work/ws/tools/lln_reset_cts.sh
