// -----------------------------------------------------------------------------
// c930_pta_contract.svh
//
// The arithmetic of doc/pta_error_model_design_note.md section 4, as functions,
// for every module that has to compute it the same way.  Included rather than
// duplicated because pta_cpu_integration.md section 4.2 says PTM-B and PTM-C
// "must agree" given identical error parameters, and two copies of a rounding
// rule is how that stops being true.
//
// Pure: nothing here reads module state, so an include is all it takes.  The
// corrections that do -- trim_dac, which needs the DAC step and clamp a module
// holds -- stay with their module.
//
// sim/pta_tile_model.c implements the same functions in C, and the lockstep gate
// (make ptm_c_lockstep) holds the two to bitwise agreement.  A change here is a
// change to the contract and belongs in that note first.
//
// Not the only copy in the tree: rtl/c930_npu_act.sv has its own xorshift32,
// msb24 and isqrt4 for the activation stage.  They are the same arithmetic --
// identical but for the PTM_C_ABLATE_XORSHIFT hook below -- and folding them in
// is a separate change with its own gates to re-run.
// -----------------------------------------------------------------------------

  function automatic logic [31:0] xorshift32(input logic [31:0] s);
    logic [31:0] v;
`ifdef PTM_C_ABLATE_XORSHIFT
    v = s ^ (s << 12);
`else
    v = s ^ (s << 13);
`endif
    v = v ^ (v >> 17);
    v = v ^ (v << 5);
    xorshift32 = v;
  endfunction

  // (sum of the four bytes - 510) * 443: about N(0, 1) * 2^16
  function automatic logic signed [19:0] gauss(input logic [31:0] s);
    logic signed [10:0] g;
    g = $signed({3'b0, s[31:24]}) + $signed({3'b0, s[23:16]}) +
        $signed({3'b0, s[15:8]})  + $signed({3'b0, s[7:0]}) - 11'sd510;
    gauss = g * 20'sd443;
  endfunction

  function automatic logic [31:0] stream_seed(input logic [31:0] seed, input logic [31:0] k);
    stream_seed = ((seed ^ k) == 32'd0) ? k : (seed ^ k);
  endfunction

  // c930_npu_act's isqrt4, unchanged: a leading-zero count and a four-entry
  // table of 2^11 * sqrt(1..4), interpolated on six fraction bits.
  function automatic logic [4:0] msb24(input logic [23:0] a);
    logic [7:0] byte_sel;
    logic [2:0] byte_idx;
    logic [2:0] bit_idx;
    if (a[23:16] != 8'd0) begin
      byte_sel = a[23:16]; byte_idx = 3'd2;
    end else if (a[15:8] != 8'd0) begin
      byte_sel = a[15:8];  byte_idx = 3'd1;
    end else begin
      byte_sel = a[7:0];   byte_idx = 3'd0;
    end
    bit_idx = byte_sel[7] ? 3'd7 : byte_sel[6] ? 3'd6 :
              byte_sel[5] ? 3'd5 : byte_sel[4] ? 3'd4 :
              byte_sel[3] ? 3'd3 : byte_sel[2] ? 3'd2 :
              byte_sel[1] ? 3'd1 : 3'd0;
    msb24 = {byte_idx, bit_idx};
  endfunction

  function automatic logic [12:0] isqrt4(input logic [23:0] a);
    logic [4:0]  p;
    logic [3:0]  e;
    logic [7:0]  th;
    logic [1:0]  seg;
    logic [12:0] lo, hi;
    logic [22:0] prod;
    logic [12:0] rn;
    if (a == 24'd0) begin
      isqrt4 = 13'd0;
    end else begin
      p   = msb24(a);
      e   = 4'(p >> 1);
      th  = 8'((a << (5'd22 - {e, 1'b0})) >> 16);
      seg = th[7:6] - 2'd1;
      case (seg)
        2'd0:    begin lo = 13'd2048; hi = 13'd2896; end
        2'd1:    begin lo = 13'd2896; hi = 13'd3547; end
        default: begin lo = 13'd3547; hi = 13'd4096; end
      endcase
      prod = 23'(hi - lo) * 23'(th[5:0]);
      rn   = lo + 13'(prod >> 6);
      isqrt4 = rn >> (4'd11 - e);
    end
  endfunction

  // q(x, B) over the DIN_W-bit operand range: round half up, saturate.
  function automatic int quant(input int x, input int b);
    int h, v, hi, lo;
    if (b == 0 || b >= DIN_W) begin
      quant = x;
    end else begin
      h  = DIN_W - b;
`ifdef PTM_C_ABLATE_QROUND
      v  = x >>> h;
`else
      v  = (x + (1 << (h - 1))) >>> h;
`endif
      hi = (1 << (b - 1)) - 1;
      lo = -(1 << (b - 1));
      if (v > hi) v = hi;
      if (v < lo) v = lo;
      quant = v <<< h;
    end
  endfunction
