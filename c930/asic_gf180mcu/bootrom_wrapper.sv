// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// Wrapper to define BOOT_HEX_FILE before including c930_bootrom.sv
`define BOOT_HEX_FILE "/work/c930/asic_gf180mcu/boot.hex"
`include "../../c930/rtl/c930_bootrom.sv"
