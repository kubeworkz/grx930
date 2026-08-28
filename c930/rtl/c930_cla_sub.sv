// -----------------------------------------------------------------------------
// c930_cla_sub.sv
//
// 8-bit carry-lookahead subtractor: diff = a - b.
//
// Replaces the ripple-carry subtraction in c930_fp16_acc to break the
// exponent-difference critical path.  The CLA computes group generate/
// propagate for 2-bit and 4-bit blocks, giving all 8 carries in ~3 LUT
// levels instead of ~8 for a ripple-carry.
//
// Purely combinational — safe for the systolic cascade.
// -----------------------------------------------------------------------------

module c930_cla_sub
(
  input  logic [7:0] i_a,
  input  logic [7:0] i_b,
  output logic [7:0] o_diff
);

  // ---- Bit-level generate/propagate for a - b = a + ~b + 1 ----
  wire [7:0] nb = ~i_b;
  wire [7:0] g = i_a & nb;   // generate: both inputs are 1
  wire [7:0] p = i_a ^ nb;   // propagate: exactly one input is 1

  // ---- 2-bit group generate/propagate ----
  wire G0 = g[1] | (p[1] & g[0]);    // group 0 (bits 0-1)
  wire P0 = p[1] & p[0];
  wire G1 = g[3] | (p[3] & g[2]);    // group 1 (bits 2-3)
  wire P1 = p[3] & p[2];
  wire G2 = g[5] | (p[5] & g[4]);    // group 2 (bits 4-5)
  wire P2 = p[5] & p[4];
  wire G3 = g[7] | (p[7] & g[6]);    // group 3 (bits 6-7)
  wire P3 = p[7] & p[6];

  // ---- 4-bit group generate/propagate ----
  wire G01 = G1 | (P1 & G0);          // group 0-1 (bits 0-3)
  wire P01 = P1 & P0;
  wire G23 = G3 | (P3 & G2);          // group 2-3 (bits 4-7)
  wire P23 = P3 & P2;

  // ---- All carries from CLA equations (c0 = 1 for subtraction) ----
  wire c0 = 1'b1;
  wire c2 = G0 | (P0 & c0);           // carry into bit 2
  wire c4 = G01 | (P01 & c0);         // carry into bit 4
  wire c6 = G23 | (P23 & c4);         // carry into bit 6

  // Per-bit carries within 2-bit groups (depend only on group inputs + cin)
  wire c1 = g[0] | (p[0] & c0);
  wire c3 = g[2] | (p[2] & c2);
  wire c5 = g[4] | (p[4] & c4);
  wire c7 = g[6] | (p[6] & c6);

  // ---- Sum bits: diff[i] = p[i] ^ c_in[i] ----
  assign o_diff[0] = p[0] ^ c0;
  assign o_diff[1] = p[1] ^ c1;
  assign o_diff[2] = p[2] ^ c2;
  assign o_diff[3] = p[3] ^ c3;
  assign o_diff[4] = p[4] ^ c4;
  assign o_diff[5] = p[5] ^ c5;
  assign o_diff[6] = p[6] ^ c6;
  assign o_diff[7] = p[7] ^ c7;

endmodule
