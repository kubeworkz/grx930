// -----------------------------------------------------------------------------
// c930_cla_comp.sv
//
// 8-bit carry-lookahead comparator: a > b, a == b.
//
// The "greater than" result is derived from the CLA carry-out of (a - b - 1),
// computed in ~3 LUT levels instead of ~8 for a ripple comparator.
// The "equal" result is a fast XOR + NOR.
//
// Purely combinational — safe for the systolic cascade.
// -----------------------------------------------------------------------------

module c930_cla_comp
(
  input  logic [7:0] i_a,
  input  logic [7:0] i_b,
  output logic       o_gt,    // a > b (unsigned)
  output logic       o_eq     // a == b
);

  // ---- Bit-level generate/propagate for a - b = a + ~b + 1 ----
  wire [7:0] nb = ~i_b;
  wire [7:0] g = i_a & nb;
  wire [7:0] p = i_a ^ nb;

  // ---- 2-bit group generate/propagate ----
  wire G0 = g[1] | (p[1] & g[0]);
  wire P0 = p[1] & p[0];
  wire G1 = g[3] | (p[3] & g[2]);
  wire P1 = p[3] & p[2];
  wire G2 = g[5] | (p[5] & g[4]);
  wire P2 = p[5] & p[4];
  wire G3 = g[7] | (p[7] & g[6]);
  wire P3 = p[7] & p[6];

  // ---- 4-bit group generate/propagate ----
  wire G01 = G1 | (P1 & G0);
  wire P01 = P1 & P0;
  wire G23 = G3 | (P3 & G2);
  wire P23 = P3 & P2;

  // ---- Carry-out: c8 = G01 || (P01 && G23) || (P01 && P23 && c0) ----
  // c0 = 1 for subtraction (complement)
  wire c8 = G23 | (P23 & G01) | (P23 & P01);

  // a > b  ⟺  (a - b) has no borrow  ⟺  carry-out = 1  ⟺  a >= b
  // a > b  ⟺  a >= b && a != b
  // Since a >= b is c8, and a != b is |(a ^ b):
  wire [7:0] xor_ab = i_a ^ i_b;
  wire a_neq_b = |xor_ab;

  assign o_gt = c8 & a_neq_b;

  // ---- Equality: a == b  ⟺  all XOR bits are 0 ----
  assign o_eq = ~a_neq_b;

endmodule
