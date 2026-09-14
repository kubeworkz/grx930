// -----------------------------------------------------------------------------
// tb_act_equiv.sv -- equivalence gate for the activation stage retime.
//
// Instantiates the pristine module (c930_npu_act_ref, extracted from the last
// commit that passed main's A2 gate) next to the edited c930_npu_act and
// drives both with identical stimulus: randomized configs, randomized
// breakpoint tables, and an element stream with realistic magnitude
// distribution (small sums, large sums, saturation-inducing extremes, all
// eight columns, bubble gaps in the valid stream).
//
// Any cycle where the two disagree on o_wvalid/o_widx/o_wdata or on the
// counters is a FAIL.  Since main's A2 gate proved ref == C reference
// bitwise, ref == new closes the bit-exactness chain for the retime.
//
// Usage:  iverilog -g2012 -o build/tb_act_equiv.vvp \
//           rtl/c930_npu_act.sv tb/c930_npu_act_ref.sv tb/tb_act_equiv.sv
//         vvp build/tb_act_equiv.vvp
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_act_equiv;

  localparam int NUM_COLS = 8;
  localparam int ACC_W    = 48;
  localparam int C_AW     = 10;
  localparam int CW       = $clog2(NUM_COLS);

  logic clk = 1'b0;
  always #5 clk = ~clk;

  // ---- common stimulus -------------------------------------------------------
  logic              rst_n = 1'b0;
  logic              cfg_load = 1'b0;
  logic              requant, noise_const;
  logic [3:0]        adc_bits;
  logic [5:0]        xshift, yshift;
  logic [15:0]       k_shot;
  logic [31:0]       seed;
  logic [255:0]      xs_flat;      // per-column XS, 8 x 32
  logic [127:0]      r_flat;       // per-column R,  8 x 16
  logic              idle;
  logic              tbl_wen = 1'b0;
  logic [10:0]       tbl_waddr;
  logic signed [23:0] tbl_wdata;
  logic              valid = 1'b0;
  logic signed [ACC_W-1:0] acc;
  logic [CW-1:0]     col;
  logic [C_AW-1:0]   cidx;

  int errors  = 0;
  int checked = 0;

  // ---- reference (pristine) ---------------------------------------------------
  logic                rv_valid;
  logic [C_AW-1:0]     rv_widx;
  logic signed [ACC_W-1:0] rv_wdata;
  logic [31:0]         rv_count, rv_sats;

  c930_npu_act_ref u_ref (
    .i_clk(clk), .i_rst_n(rst_n),
    .i_cfg_load(cfg_load), .i_requant(requant), .i_adc_bits(adc_bits),
    .i_xs(xs_flat), .i_xshift(xshift), .i_r(r_flat), .i_yshift(yshift),
    .i_k_shot(k_shot), .i_noise_const(noise_const), .i_seed(seed),
    .i_idle(idle), .i_tbl_wen(tbl_wen), .i_tbl_waddr(tbl_waddr),
    .i_tbl_wdata(tbl_wdata),
    .i_valid(valid), .i_acc(acc), .i_col(col), .i_cidx(cidx),
    .o_wvalid(rv_valid), .o_widx(rv_widx), .o_wdata(rv_wdata),
    .o_count(rv_count), .o_sat_count(rv_sats)
  );

  // ---- device under test (edited) ----------------------------------------------
  logic                dv_valid;
  logic [C_AW-1:0]     dv_widx;
  logic signed [ACC_W-1:0] dv_wdata;
  logic [31:0]         dv_count, dv_sats;

  c930_npu_act u_dut (
    .i_clk(clk), .i_rst_n(rst_n),
    .i_cfg_load(cfg_load), .i_requant(requant), .i_adc_bits(adc_bits),
    .i_xs(xs_flat), .i_xshift(xshift), .i_r(r_flat), .i_yshift(yshift),
    .i_k_shot(k_shot), .i_noise_const(noise_const), .i_seed(seed),
    .i_idle(idle), .i_tbl_wen(tbl_wen), .i_tbl_waddr(tbl_waddr),
    .i_tbl_wdata(tbl_wdata),
    .i_valid(valid), .i_acc(acc), .i_col(col), .i_cidx(cidx),
    .o_wvalid(dv_valid), .o_widx(dv_widx), .o_wdata(dv_wdata),
    .o_count(dv_count), .o_sat_count(dv_sats)
  );  // ---- per-cycle equivalence check----------------------------------------------
  // The retime adds exactly one pipeline stage, so the reference stream is
  // delayed by one cycle before comparing.  Counters increment at the write
  // position, so they are compared once per phase, after both pipelines have
  // fully drained.
  logic                rv_valid_d;
  logic [C_AW-1:0]     rv_widx_d;
  logic signed [ACC_W-1:0] rv_wdata_d;

  always @(posedge clk) begin
    rv_valid_d <= rv_valid;
    rv_widx_d  <= rv_widx;
    rv_wdata_d <= rv_wdata;
  end

  int phase_errors;
  always @(posedge clk) begin
    if (rst_n) begin
      if (rv_valid_d !== dv_valid) begin
        errors++;
        $display("[FAIL] t=%0t valid mismatch ref=%b dut=%b", $time, rv_valid_d, dv_valid);
      end else if (rv_valid_d) begin
        checked++;
        if (rv_widx_d !== dv_widx) begin
          errors++;
          $display("[FAIL] t=%0t widx ref=%0d dut=%0d", $time, rv_widx_d, dv_widx);
        end
        if (rv_wdata_d !== dv_wdata) begin
          errors++;
          $display("[FAIL] t=%0t wdata ref=%h dut=%h (idx %0d)",
                   $time, rv_wdata_d, dv_wdata, rv_widx_d);
        end
      end
    end
  end

  // ---- stimulus ------------------------------------------------------------------
  int unsigned rs = 32'hC0FFEE;
  function automatic int unsigned rnd();
    rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5);
    return rs;
  endfunction

  task automatic drive_cfg(input int phase);
    requant     = (phase % 2) == 0;
    noise_const = (phase % 5) == 3;
    adc_bits    = 4'(1 + (rnd() % 15));
    xshift      = 6'(rnd() % 32);
    yshift      = 6'(rnd() % 64);
    k_shot      = (phase % 3) == 0 ? 16'h0
                : (phase % 3) == 1 ? 16'h4000 : 16'hFFFF;
    seed        = (phase == 4) ? 32'h0 : rnd() | 32'd1;   // one zero-seed case
    for (int j = 0; j < NUM_COLS; j++) begin
      xs_flat[j*32 +: 32] = rnd() | (32'd1 << 12);        // nonzero, varied scale
      r_flat[j*16 +: 16]  = 16'(rnd());
    end
    cfg_load = 1'b1;
    @(posedge clk);
    cfg_load = 1'b0;
  endtask

  task automatic write_table(input int phase);
    // 1025 random signed 24-bit entries; identical data to both DUTs.
    logic [23:0] v;
    idle = 1'b1;
    for (int a = 0; a < 1025; a++) begin
      if (phase % 2 == 0) v = 24'(rnd());
      else                v = 24'h800000 + 24'(a % 2049);  // ramp incl. identity-ish
      tbl_wen   = 1'b1;
      tbl_waddr = 11'(a);
      tbl_wdata = $signed(v);
      @(posedge clk);
    end
    tbl_wen = 1'b0;
  endtask

  int unsigned pick;
  int unsigned rb;
  task automatic stream(input int n_elems);
    idle = 1'b0;
    for (int e = 0; e < n_elems; e++) begin
      if ((rnd() % 4) == 0) begin           // bubble
        valid = 1'b0;
        @(posedge clk);
      end
      pick = rnd() % 10;
      if (pick < 3)       acc = 48'($signed(rnd() % 8193) - 4096);        // small
      else if (pick < 6)  acc = 48'($signed(rnd() % (1<<30)) - (1<<29));  // large
      else if (pick < 8) begin                                            // huge / sat
        rb = rnd() % 4;
        case (rb)
          0:       acc =  48'sh400000000000;   // +2^46
          1:       acc = -48'sh400000000000;   // -2^46
          2:       acc =  48'sh7FFFFFFFFFFF;       // +max
          default: acc = -48'sh800000000000;       // -min
        endcase
      end
      else                acc = 48'd0;
      col  = 3'(rnd() % NUM_COLS);
      cidx = 10'(rnd() % 1024);
      valid = 1'b1;
      @(posedge clk);
    end
    valid = 1'b0;
    idle  = 1'b1;
    repeat (12) @(posedge clk);             // full drain
  endtask

  initial begin
    xs_flat = '0; r_flat = '0;
    idle = 1'b1;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    for (int phase = 0; phase < 8; phase++) begin
      write_table(phase);
      drive_cfg(phase);
      stream(400 + 50 * (phase % 3));
      // Pipelines drained: the counters must agree exactly.
      if (rv_count !== dv_count || rv_sats !== dv_sats) begin
        errors++;
        $display("[FAIL] phase %0d counters: count ref=%0d dut=%0d, sats ref=%0d dut=%0d",
                 phase, rv_count, dv_count, rv_sats, dv_sats);
      end
    end

    repeat (8) @(posedge clk);
    if (errors == 0)
      $display("[PASS] tb_act_equiv: %0d output elements bit-exact, counters match",
               checked);
    else
      $display("[FAIL] tb_act_equiv: %0d errors over %0d checked elements",
               errors, checked);
    $finish;
  end

endmodule
