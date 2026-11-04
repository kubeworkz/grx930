// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// sky130_asic_wrapper.sv — ASIC-compatible replacements for Xilinx primitives
// For use with Yosys + SKY130 std-cell library (open-source flow)
//
// This file is read AFTER the RTL files in the Yosys script.
// It provides:
//   1. BUFG replacement (simple buffer for clock tree synthesis)
//   2. DSP48E1 replacement (behavioral multiplier for Yosys to synthesize)

// ============================================================
// 1. BUFG replacement — Yosys/CTS will handle clock tree
// ============================================================
// In FPGA, BUFG buffers the divided clock onto the global clock network.
// In ASIC, CTS (clock tree synthesis) handles this automatically.
// We provide a simple buffer that Yosys will optimize away or map to a
// clock buffer cell from the SKY130 library.

module BUFG (
    input  logic I,
    output logic O
);
    assign O = I;
endmodule

// ============================================================
// 2. DSP48E1 replacement — behavioral multiply-accumulate
// ============================================================
// The GRX930 uses DSP48E1 in two places:
//   - c930_fp16_acc.sv: 48-bit adder (A+B, no multiply)
//   - c930_fp_mul.sv: commented out, not instantiated
//
// We provide a behavioral model that Yosys will synthesize into
// standard cells. The actual DSP48E1 port list is large; we only
// implement the subset the GRX930 actually uses.

module DSP48E1 #(
    // Attributes are accepted and ignored: this stub models the one mode the
    // GRX930 uses (OPMODE 7'b0110011, all internal registers bypassed).
    parameter A_INPUT = "DIRECT",  parameter B_INPUT = "DIRECT",
    parameter USE_DPORT = "FALSE", parameter USE_MULT = "NONE",
    parameter USE_SIMD = "ONE48",  parameter AUTORESET_PATDET = "NO_RESET",
    parameter [47:0] MASK = 48'h3fffffffffff, parameter [47:0] PATTERN = 48'h0,
    parameter SEL_MASK = "MASK",   parameter SEL_PATTERN = "PATTERN",
    parameter USE_PATTERN_DETECT = "NO_PATDET",
    parameter ACASCREG = 0, ADREG = 0, ALUMODEREG = 0, AREG = 0,
    parameter BCASCREG = 0, BREG = 0, CARRYINREG = 0, CARRYINSELREG = 0,
    parameter CREG = 0, DREG = 0, INMODEREG = 0, MREG = 0, OPMODEREG = 0,
    parameter PREG = 0
)(
    output logic [29:0] ACOUT,
    output logic [17:0] BCOUT,
    output logic        CARRYCASCOUT,
    output logic        MULTSIGNOUT,
    output logic [47:0] PCOUT,
    output logic        OVERFLOW,
    output logic        PATTERNBDETECT,
    output logic        PATTERNDETECT,
    output logic        UNDERFLOW,
    output logic [3:0]  CARRYOUT,
    output logic [47:0] P,

    input  logic [29:0] ACIN,
    input  logic [17:0] BCIN,
    input  logic        CARRYCASCIN,
    input  logic        MULTSIGNIN,
    input  logic [47:0] PCIN,
    input  logic [3:0]  ALUMODE,
    input  logic [2:0]  CARRYINSEL,
    input  logic        CLK,
    input  logic [4:0]  INMODE,
    input  logic [6:0]  OPMODE,
    input  logic [29:0] A,
    input  logic [17:0] B,
    input  logic [47:0] C,
    input  logic        CARRYIN,
    input  logic [24:0] D,
    input  logic        CEA1, CEA2, CEAD, CEALUMODE, CEB1, CEB2, CEC, CECARRYIN,
    input  logic        CECTRL, CED, CEINMODE, CEM, CEP,
    input  logic        RSTA, RSTALLCARRYIN, RSTALUMODE, RSTB, RSTC, RSTCTRL,
    input  logic        RSTD, RSTINMODE, RSTM, RSTP
);
    // X = A:B, Z = C (OPMODE 0110011). ALUMODE 0001 is X - Z - 1 with CARRYIN
    // added back, which is how c930_fp16_acc gets an exact subtract out of it.
    wire [47:0] x = {A, B};
    wire [47:0] p_add = x + C + {47'b0, CARRYIN};
    wire [47:0] p_sub = x - C - 48'd1 + {47'b0, CARRYIN};

    assign P        = ALUMODE[0] ? p_sub : p_add;
    assign ACOUT    = A;
    assign BCOUT    = B;
    assign PCOUT    = P;
    assign CARRYOUT = 4'b0;
    assign {CARRYCASCOUT, MULTSIGNOUT, OVERFLOW, PATTERNBDETECT, PATTERNDETECT, UNDERFLOW} = 6'b0;
endmodule
