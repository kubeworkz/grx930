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
    parameter integer NUM_RECREG  = 1,
    parameter integer NUM_PCREG   = 1,
    parameter integer USE_DPORT   = "FALSE",
    parameter integer USE_MULT    = "NONE",
    parameter integer AREG        = 1,
    parameter integer BREG        = 1,
    parameter integer [47:0] ACASCREG = 1,
    parameter integer [47:0] BCASCREG = 1
)(
    // A port (48-bit, used as 30-bit input in GRX930)
    input  logic [29:0] A,
    // B port (18-bit)
    input  logic [17:0] B,
    // C port (48-bit, used as carry input)
    input  logic [47:0] C,
    // D port (25-bit, unused in GRX930)
    input  logic [24:0] D,
    // Control
    input  logic        CLK,
    input  logic        CEA1, CEA2,
    input  logic        CEB1, CEB2,
    input  logic        CEC, CED, CEM, CEP,
    input  logic        CEALUMODE, CEMULTIPLYIN, CEMULTIPLYOUT,
    input  logic        CECARRYIN, CECINSUB, CECTRL,
    input  logic        RSTA, RSTB, RSTC, RSTD, RSTM, RSTP,
    input  logic        RSTCTRL, RSTCARRYIN, RSTDITHER, RSTMULTIPLYIN,
    input  logic        RSTMULTIPLYOUT, RSTPATTERNDETECT, RSTPATTERNSYNC,
    input  logic        RSTPIPEMODE, RSTSIMPLE, RSTSYNC_IN, RSTSYNC_OUT,
    input  logic        RSTDRECCLK,
    // Cascade
    input  logic [29:0] ACIN,
    input  logic [17:0] BCIN,
    input  logic        CARRYCASCIN,
    input  logic        MULTSIGNIN,
    input  logic [47:0] PCIN,
    // Mode
    input  logic [3:0]  ALUMODE,
    input  logic [2:0]  CARRYINSEL,
    input  logic        CARRYIN,
    // Output enable
    input  logic        OPMODE,
    // Pattern detect
    input  logic        PATTERNDETECT,
    input  logic        PATTERNSYNC,
    // Underflow/overflow
    input  logic        UNDERFLOW,
    input  logic        OVERFLOW,
    input  logic        AUTORESTORE_PATTRN,
    // Ports (direct input)
    input  logic [6:0]  OPMODE_IN,
    // Output
    output logic [29:0] ACOUT,
    output logic [17:0] BCOUT,
    output logic        CARRYCASCOUT,
    output logic        MULTSIGNOUT,
    output logic [47:0] PCOUT,
    output logic [47:0] P,
    output logic        PATTERNDETECT_OUT,
    output logic        PATTERNSYNC_OUT,
    output logic        OVERFLOW_OUT,
    output logic        UNDERFLOW_OUT,
    output logic        CARRYOUT,
    output logic [3:0]  CARRYOUT_OUT
);

    // GRX930 only uses this as a 48-bit adder: P = A + B + C
    // A is sign-extended from 30 to 48 bits
    logic [47:0] a_ext;
    logic [47:0] b_ext;

    assign a_ext = {{18{A[29]}}, A};
    assign b_ext = {{30{B[17]}}, B};

    always_ff @(posedge CLK) begin
        if (CEP) begin
            P <= a_ext + b_ext + C;
        end
    end

    // Unused outputs tied to zero
    assign ACOUT = '0;
    assign BCOUT = '0;
    assign CARRYCASCOUT = '0;
    assign MULTSIGNOUT = '0;
    assign PCOUT = '0;
    assign PATTERNDETECT_OUT = '0;
    assign PATTERNSYNC_OUT = '0;
    assign OVERFLOW_OUT = '0;
    assign UNDERFLOW_OUT = '0;
    assign CARRYOUT = '0;
    assign CARRYOUT_OUT = '0;

endmodule
