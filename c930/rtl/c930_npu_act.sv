// -----------------------------------------------------------------------------
// c930_npu_act.sv
//
// The activation stage S_ACT (doc/npu_act_stage_design_note.md): one transfer
// curve, the shot noise its light carries, a per-column detuning, and an
// optional requantisation standing in for an O-E-O reset, applied to each
// complete sum on its way into C.  The core feeds acc[j] for j = 0 .. nc-1 on
// consecutive cycles; each element is written back ACT_P = 7 cycles later
// (stage 2 is split into 2a: root + draw, and 2b: the k_shot multiply -- the
// unsplit cone was the post-route critical path).
//
// Fixed-point contract.  sim/tb_core_verilator.cc's C reference implements
// these steps exactly, and gate A2 holds the two to bitwise agreement.  All
// shifts on signed values are arithmetic; "floor" is what that gives.
//
//   stage 0  register the element
//   stage 1  x   = sat24((acc * XS[j]) >>> XSHIFT)
//                  acc signed ACC_W; XS unsigned 32; sat24 to [-2^23, 2^23-1]
//   stage 2  rt  = noise_const ? 4096 : isqrt4(|x|)
//            sig = k_shot * rt                 k_shot Q8.8, so sig is Q.8
//            s   = xorshift32(s)               one step per element
//            g   = b3 + b2 + b1 + b0 - 510     the four bytes of the new s
//            gs  = g * 443                     sd(g) * 443 / 2^16 = 0.999
//   stage 3  x2  = sat24(x + ((sig * gs + 2^23) >>> 24))
//   stage 4  u   = x2 + 2^23;  y0, y1 <- T[u >> 14], T[(u >> 14) + 1]
//   stage 5  y   = y0 + (((y1 - y0) * (u & 0x3fff)) >>> 14)
//   stage 6  yr  = (y * R[j]) >>> 12           R unsigned Q4.12
//            c   = requant ? clamp((yr + 2^(S-1)) >>> S, B) << S : yr
//                  S = 24 - B, clamp to [-2^(B-1), 2^(B-1)-1], B in 1..15
//            C   <- sat32(c <<< min(YSHIFT, 32)), sign-extended to ACC_W
//
// isqrt4(a), for a in [0, 2^23]: 0 when a = 0; otherwise with p the index of
// a's top set bit and e = p >> 1, t = a << (22 - 2e) lies in [2^22, 2^24),
// i = t[23:22] - 1 picks a segment of {2048, 2896, 3547, 4096} (round of
// 2^11 * sqrt(1..4)), and
//   isqrt4 = (T4[i] + (((T4[i+1] - T4[i]) * t[21:16]) >> 6)) >> (11 - e)
// -- the leading-zero count and four-entry LUT of pta_cpu_integration.md
// section 4.3, within about 1.5% of the true root.  Shot noise is a scale,
// so that is plenty; what matters is that the C reference computes the same.
//
// The xorshift32 state loads from the seed when the core accepts a start and
// steps once per element, in the order the core feeds them: nt, then m, then
// j.  A zero seed is a fixed point of xorshift32 and gives a constant draw.
//
// Saturations (stage 1, stage 3, stage 6) count as separate events.
// -----------------------------------------------------------------------------
module c930_npu_act
#(
  parameter int NUM_COLS = 8,
  parameter int ACC_W    = 48,
  parameter int C_AW     = 10     // c_mem address width
)
(
  input  logic                        i_clk,
  input  logic                        i_rst_n,

  // Configuration, sampled when the core accepts a start
  input  logic                        i_cfg_load,
  input  logic                        i_requant,
  input  logic [3:0]                  i_adc_bits,
  input  logic [32*NUM_COLS-1:0]      i_xs,
  input  logic [5:0]                  i_xshift,
  input  logic [16*NUM_COLS-1:0]      i_r,
  input  logic [5:0]                  i_yshift,
  input  logic [15:0]                 i_k_shot,
  input  logic                        i_noise_const,
  input  logic [31:0]                 i_seed,

  // Breakpoint table: 1025 signed 24-bit values, written while the core idles
  input  logic                        i_idle,
  input  logic                        i_tbl_wen,
  input  logic [10:0]                 i_tbl_waddr,
  input  logic signed [23:0]          i_tbl_wdata,

  // Element stream from the core
  input  logic                        i_valid,
  input  logic signed [ACC_W-1:0]     i_acc,
  input  logic [$clog2(NUM_COLS)-1:0] i_col,
  input  logic [C_AW-1:0]             i_cidx,

  // Activated element, one cycle per element, ACT_P cycles after it entered
  output logic                        o_wvalid,
  output logic [C_AW-1:0]             o_widx,
  output logic signed [ACC_W-1:0]     o_wdata,

  output logic [31:0]                 o_count,       // elements activated
  output logic [31:0]                 o_sat_count    // saturation events
);

  localparam int CW = $clog2(NUM_COLS);
  localparam logic signed [23:0] X_MAX = 24'sh7fffff;
  localparam logic signed [23:0] X_MIN = -24'sh800000;

  // ---- configuration --------------------------------------------------------
  logic        requant_r, noise_const_r;
  logic [3:0]  adc_bits_r;
  logic [5:0]  xshift_r, yshift_r;
  logic [15:0] k_shot_r;
  logic [31:0] xs_r [0:NUM_COLS-1];
  logic [15:0] r_r  [0:NUM_COLS-1];

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      requant_r     <= 1'b0;
      noise_const_r <= 1'b0;
      adc_bits_r    <= 4'd0;
      xshift_r      <= 6'd0;
      yshift_r      <= 6'd0;
      k_shot_r      <= 16'd0;
      for (int j = 0; j < NUM_COLS; j++) begin
        xs_r[j] <= 32'd0;
        r_r[j]  <= 16'd0;
      end
    end else if (i_cfg_load) begin
      requant_r     <= i_requant;
      noise_const_r <= i_noise_const;
      adc_bits_r    <= i_adc_bits;
      xshift_r      <= i_xshift;
      yshift_r      <= i_yshift;
      k_shot_r      <= i_k_shot;
      for (int j = 0; j < NUM_COLS; j++) begin
        xs_r[j] <= i_xs[32*j +: 32];
        r_r[j]  <= i_r[16*j +: 16];
      end
    end
  end

  // ---- breakpoint table -----------------------------------------------------
  // Two synchronous reads, i and i+1, and a write port used only while idle:
  // a true dual-port block RAM.
  (* ram_style = "block" *) logic signed [23:0] tbl [0:1024];

  // ---- stage 0: the element ---------------------------------------------------
  logic                    v0;
  logic signed [ACC_W-1:0] acc0;
  logic [CW-1:0]           col0;
  logic [C_AW-1:0]         idx0;

  // ---- stage 1: into the table domain ----------------------------------------
  logic signed [ACC_W+32:0] p1;           // acc * xs, xs zero-extended
  logic signed [ACC_W+32:0] p1s;
  logic signed [23:0]       x1_c;
  logic                     sat1_c;
  always_comb begin
    p1   = $signed(acc0) * $signed({1'b0, xs_r[col0]});
    p1s  = p1 >>> xshift_r;
    sat1_c = 1'b0;
    if (p1s > $signed({{(ACC_W+9){1'b0}}, X_MAX})) begin
      x1_c = X_MAX; sat1_c = 1'b1;
    end else if (p1s < $signed({{(ACC_W+9){1'b1}}, X_MIN})) begin
      x1_c = X_MIN; sat1_c = 1'b1;
    end else begin
      x1_c = p1s[23:0];
    end
  end

  logic                v1;
  logic signed [23:0]  x1;
  logic                sat1;
  logic [CW-1:0]       col1;
  logic [C_AW-1:0]     idx1;

  // ---- stage 2: noise scale and draw -----------------------------------------
  // RETIME (setup closure): the old stage 2 evaluated abs -> isqrt4 ->
  // k_shot*rt AND xorshift -> byte-sum -> *443 in one combinational cone into
  // the stage-2 registers -- the post-route critical path (WNS -1.498 at
  // 50 MHz, path x1_reg -> sig20).  Split into 2a (root + draw) and 2b (the
  // k_shot multiply).  Functions are unchanged; ACT_P in c930_npu_core goes
  // 6 -> 7.  The xorshift state still steps once per element at the v1
  // position, so every element consumes the same draw as before.
  // isqrt4's top-bit loop (24-deep priority chain) is restructured as a
  // byte-select tree -- same result, ~4 levels instead of ~24.
  function automatic logic [4:0] msb24(input logic [23:0] a);
    // Highest set bit of a nonzero 24-bit value, balanced:
    // 3-way byte select (range ORs), then an 8-way priority inside the byte.
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
    msb24 = {byte_idx, bit_idx};          // 8*byte_idx + bit_idx
  endfunction

  function automatic logic [12:0] isqrt4(input logic [23:0] a);
    logic [4:0]  p;
    logic [3:0]  e;
    logic [7:0]  th;          // t[23:16]: the segment and the six fraction bits used
    logic [1:0]  seg;
    logic [12:0] lo, hi;
    logic [22:0] prod;
    logic [12:0] rn;
    if (a == 24'd0) begin
      isqrt4 = 13'd0;
    end else begin
      p = msb24(a);
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

  function automatic logic [31:0] xorshift32(input logic [31:0] s);
    logic [31:0] v;
    v = s ^ (s << 13);
    v = v ^ (v >> 17);
    v = v ^ (v << 5);
    xorshift32 = v;
  endfunction

  logic [31:0]        rng, rng_next;
  logic [23:0]        abs1;
  logic [12:0]        rt2a_c;     // stage 2a: the root (or the constant)
  logic signed [19:0] gs2a_c;     // stage 2a: the draw, scaled
  always_comb begin
    abs1     = x1[23] ? 24'(-x1) : x1;      // |-2^23| = 2^23 fits unsigned
    rt2a_c   = noise_const_r ? 13'd4096 : isqrt4(abs1);
    rng_next = xorshift32(rng);
    g2_c     = $signed({3'b0, rng_next[31:24]}) + $signed({3'b0, rng_next[23:16]}) +
               $signed({3'b0, rng_next[15:8]})  + $signed({3'b0, rng_next[7:0]}) -
               11'sd510;
    gs2a_c   = g2_c * 20'sd443;
  end

  // ---- stage 2a registers ------------------------------------------------------
  logic                v2a;
  logic [12:0]         rt2a;
  logic signed [19:0]  gs2a;
  logic signed [23:0]  x2a;
  logic                sat1_2a;
  logic [CW-1:0]       col2a;
  logic [C_AW-1:0]     idx2a;

  // ---- stage 2b: the noise scale multiply --------------------------------------
  logic [28:0]        sig2_c;
  logic signed [10:0] g2_c;
  always_comb begin
    sig2_c   = k_shot_r * rt2a;
  end

  logic                v2;
  logic signed [23:0]  x2;
  logic [28:0]         sig2;
  logic signed [19:0]  gs2;
  logic                sat1_2;
  logic [CW-1:0]       col2;
  logic [C_AW-1:0]     idx2;

  // ---- stage 3: add the noise ------------------------------------------------
  logic signed [49:0]  prod3;
  logic signed [25:0]  noise3;
  logic signed [26:0]  sum3;
  logic signed [23:0]  x3_c;
  logic                sat3_c;
  always_comb begin
    prod3  = $signed({1'b0, sig2}) * gs2;
    noise3 = 26'((prod3 + 50'sd8388608) >>> 24);
    sum3   = $signed({{3{x2[23]}}, x2}) + $signed({noise3[25], noise3});
    sat3_c = 1'b0;
    if (sum3 > 27'sd8388607) begin
      x3_c = X_MAX; sat3_c = 1'b1;
    end else if (sum3 < -27'sd8388608) begin
      x3_c = X_MIN; sat3_c = 1'b1;
    end else begin
      x3_c = sum3[23:0];
    end
  end

  logic                v3;
  logic [23:0]         u3;            // x3 + 2^23
  logic [1:0]          sat3;          // {stage 3, stage 1}
  logic [CW-1:0]       col3;
  logic [C_AW-1:0]     idx3;

  // ---- stage 4: read the two breakpoints --------------------------------------
  wire [10:0] rd0 = {1'b0, u3[23:14]};
  wire [10:0] rd1 = rd0 + 11'd1;

  logic signed [23:0]  y0_4, y1_4;
  always_ff @(posedge i_clk) begin
    if (i_tbl_wen && i_idle)
      tbl[i_tbl_waddr] <= i_tbl_wdata;
    y0_4 <= tbl[rd0];
  end
  always_ff @(posedge i_clk)
    y1_4 <= tbl[rd1];

  logic                v4;
  logic [13:0]         f4;
  logic [1:0]          sat4;
  logic [CW-1:0]       col4;
  logic [C_AW-1:0]     idx4;

  // ---- stage 5: interpolate ------------------------------------------------------
  logic signed [24:0]  d5;
  logic signed [39:0]  prod5;
  logic signed [23:0]  y5_c;
  always_comb begin
    d5    = $signed({y1_4[23], y1_4}) - $signed({y0_4[23], y0_4});
    prod5 = d5 * $signed({1'b0, f4});
    y5_c  = 24'($signed({y0_4[23], y0_4}) + 25'(prod5 >>> 14));
  end

  logic                v5;
  logic signed [23:0]  y5;
  logic [1:0]          sat5;
  logic [CW-1:0]       col5;
  logic [C_AW-1:0]     idx5;

  // ---- stage 6: detune, requantise, scale ---------------------------------------
  logic signed [40:0]  prod6;
  logic signed [28:0]  yr6;
  logic [4:0]          sh6;
  logic signed [28:0]  q6, qc6, c6;
  logic signed [63:0]  wide6;
  logic [5:0]          ys6;
  logic signed [31:0]  out6;
  logic                sat6;
  always_comb begin
    prod6 = y5 * $signed({1'b0, r_r[col5]});
    yr6   = 29'(prod6 >>> 12);
    sh6   = 5'(5'd24 - {1'b0, adc_bits_r});
    q6    = (yr6 + (29'sd1 <<< (sh6 - 5'd1))) >>> sh6;
    if (q6 > ((29'sd1 <<< (adc_bits_r - 4'd1)) - 29'sd1))
      qc6 = (29'sd1 <<< (adc_bits_r - 4'd1)) - 29'sd1;
    else if (q6 < -(29'sd1 <<< (adc_bits_r - 4'd1)))
      qc6 = -(29'sd1 <<< (adc_bits_r - 4'd1));
    else
      qc6 = q6;
    c6    = requant_r ? (qc6 <<< sh6) : yr6;
    ys6   = (yshift_r > 6'd32) ? 6'd32 : yshift_r;
    wide6 = 64'($signed(c6)) <<< ys6;
    sat6  = 1'b0;
    if (wide6 > 64'sh7fffffff) begin
      out6 = 32'sh7fffffff; sat6 = 1'b1;
    end else if (wide6 < -64'sh80000000) begin
      out6 = -32'sh80000000; sat6 = 1'b1;
    end else begin
      out6 = wide6[31:0];
    end
  end

  assign o_wvalid = v5;
  assign o_widx   = idx5;
  assign o_wdata  = ACC_W'(out6);

  // ---- pipeline registers and counters -------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      v0 <= 1'b0; v1 <= 1'b0; v2a <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0; v5 <= 1'b0;
      acc0 <= '0; col0 <= '0; idx0 <= '0;
      x1 <= '0; sat1 <= 1'b0; col1 <= '0; idx1 <= '0;
      rt2a <= '0; gs2a <= '0; x2a <= '0; sat1_2a <= 1'b0; col2a <= '0; idx2a <= '0;
      x2 <= '0; sig2 <= '0; gs2 <= '0; sat1_2 <= 1'b0; col2 <= '0; idx2 <= '0;
      u3 <= '0; sat3 <= '0; col3 <= '0; idx3 <= '0;
      f4 <= '0; sat4 <= '0; col4 <= '0; idx4 <= '0;
      y5 <= '0; sat5 <= '0; col5 <= '0; idx5 <= '0;
      rng <= 32'd0;
      o_count     <= 32'd0;
      o_sat_count <= 32'd0;
    end else begin
      v0 <= i_valid;
      acc0 <= i_acc; col0 <= i_col; idx0 <= i_cidx;

      v1 <= v0;
      x1 <= x1_c; sat1 <= sat1_c; col1 <= col0; idx1 <= idx0;

      // stage 2a: root and draw
      v2a <= v1;
      rt2a <= rt2a_c; gs2a <= gs2a_c; x2a <= x1;
      sat1_2a <= sat1; col2a <= col1; idx2a <= idx1;

      v2 <= v2a;
      x2 <= x2a; sig2 <= sig2_c; gs2 <= gs2a; sat1_2 <= sat1_2a; col2 <= col2a; idx2 <= idx2a;

      v3 <= v2;
      u3 <= x3_c ^ 24'h800000;            // + 2^23 on a 24-bit two's-complement value
      sat3 <= {sat3_c, sat1_2}; col3 <= col2; idx3 <= idx2;

      v4 <= v3;
      f4 <= u3[13:0]; sat4 <= sat3; col4 <= col3; idx4 <= idx3;

      v5 <= v4;
      y5 <= y5_c; sat5 <= sat4; col5 <= col4; idx5 <= idx4;

      if (i_cfg_load)
        rng <= i_seed;
      else if (v1)
        rng <= rng_next;

      if (i_cfg_load) begin
        o_count     <= 32'd0;
        o_sat_count <= 32'd0;
      end else if (v5) begin
        o_count     <= o_count + 32'd1;
        o_sat_count <= o_sat_count + 32'(sat5[0]) + 32'(sat5[1]) + 32'(sat6);
      end
    end
  end

endmodule
