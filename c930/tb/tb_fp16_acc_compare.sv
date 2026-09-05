// -----------------------------------------------------------------------------
// tb_fp16_acc_compare.sv
//
// Verifies the new DSP-backed c930_fp16_acc against the previous
// implementation (c930_fp16_acc_old) and against ground truth:
//
//   Part 1: hand-computed exact-value cases (bit-exact FP32 expectations)
//   Part 2: constrained random pairs (exponent diff <= 31, no specials):
//           new MUST equal old (both are exact here)
//   Part 3: extreme pairs (exponent diff >= 27): the smaller operand's
//           mantissa shifts out entirely, so the result must equal the
//           larger operand exactly.  (The old module's shift WRAPS for
//           diff >= 32, so only the new module is checked here.)
//   Part 4: edge-case cross product (zeros, inf, nan, subnormals):
//           new must equal old.
//
// Rationale for Part 3: with the shift clamped to 31, B's contribution is
// zero when diff >= 27, so A +/- 0 = A exactly under truncation semantics.
// -----------------------------------------------------------------------------
module tb_fp16_acc_compare;

  logic [31:0] i_ps, i_prod;
  logic [31:0] o_new, o_old;

  c930_fp16_acc     u_new (.i_clk(1'b0), .i_rst_n(1'b1), .i_ps_in(i_ps),
                           .i_prod(i_prod), .o_ps_out(o_new));
  c930_fp16_acc_old u_old (.i_clk(1'b0), .i_rst_n(1'b1), .i_ps_in(i_ps),
                           .i_prod(i_prod), .o_ps_out(o_old));

  int total      = 0;
  int mismatches = 0;
  int errs       = 0;

  // ---- Drive one input pair, return outputs ----
  task automatic drive(input logic [31:0] a, b, output logic [31:0] n, o);
    begin
      i_ps   = a;
      i_prod = b;
      #1;
      n = o_new;
      o = o_old;
    end
  endtask

  // ---- Part 2/4: old-vs-new agreement check ----
  task automatic run_pair(input logic [31:0] a, b);
    logic [31:0] n, o;
    begin
      drive(a, b, n, o);
      total = total + 1;
      if (n !== o) begin
        mismatches = mismatches + 1;
        if (mismatches <= 10)
          $display("  MISMATCH: a=0x%08h b=0x%08h new=0x%08h old=0x%08h",
                   a, b, n, o);
      end
      if (n === 32'hxxxxxxxx) begin
        errs = errs + 1;
        $display("  X-PROP: a=0x%08h b=0x%08h", a, b);
      end
    end
  endtask

  // ---- Part 1: exact expectation check (new module) ----
  task automatic check_exact(input logic [31:0] a, b, exp);
    logic [31:0] n, o;
    begin
      drive(a, b, n, o);
      total = total + 1;
      if (n !== exp) begin
        errs = errs + 1;
        $display("  [FAIL] a=0x%08h b=0x%08h: got 0x%08h expect 0x%08h",
                 a, b, n, exp);
      end
    end
  endtask

  // ---- Part 4: nan -> {*, 255, 1}; inf rules; zero passthrough ----
  task automatic check_nan(input logic [31:0] a, b);
    logic [31:0] n, o;
    begin
      drive(a, b, n, o);
      total = total + 1;
      if (n[30:23] !== 8'd255 || n[22:0] !== 23'd1) begin
        errs = errs + 1;
        $display("  [FAIL-nan] a=0x%08h b=0x%08h: got 0x%08h", a, b, n);
      end
    end
  endtask

  task automatic check_inf_inf(input logic [31:0] a, b);
    logic [31:0] n, o;
    begin
      drive(a, b, n, o);
      total = total + 1;
      if (n !== {a[31], 8'hFF, 23'd0}) begin
        errs = errs + 1;
        $display("  [FAIL-inf-inf] a=0x%08h b=0x%08h: got 0x%08h", a, b, n);
      end
    end
  endtask

  task automatic check_inf_finite(input logic [31:0] a, b);
    logic [31:0] n, o;
    begin
      drive(a, b, n, o);
      total = total + 1;
      if (a[30:23] == 8'd255) begin
        if (n !== a) begin
          errs = errs + 1;
          $display("  [FAIL-inf-finite] a=0x%08h b=0x%08h: got 0x%08h", a, b, n);
        end
      end else begin
        if (n !== b) begin
          errs = errs + 1;
          $display("  [FAIL-inf-finite] a=0x%08h b=0x%08h: got 0x%08h", a, b, n);
        end
      end
    end
  endtask

  // ---- Larger-operand check incl. zero handling (diff >= 27) ----
  task automatic check_larger_z(input logic [31:0] a, b);
    logic [31:0] n, o;
    logic [31:0] larger;
    logic [7:0] ea, eb;
    begin
      ea = a[30:23];
      eb = b[30:23];
      if (ea == 8'd0 && a[22:0] == 23'd0) begin      // a is +0/-0
        larger = (eb == 8'd0 && b[22:0] == 23'd0) ? 32'h00000000 : b;
      end else if (eb == 8'd0 && b[22:0] == 23'd0) begin
        larger = a;
      end else if (ea > eb) begin
        larger = a;
      end else if (eb > ea) begin
        larger = b;
      end else begin
        larger = (a[22:0] >= b[22:0]) ? a : b;
      end
      drive(a, b, n, o);
      total = total + 1;
      if (n !== larger) begin
        errs = errs + 1;
        if (errs <= 15)
          $display("  [FAIL-edge] a=0x%08h b=0x%08h: got 0x%08h expect 0x%08h",
                   a, b, n, larger);
      end
      if (n === 32'hxxxxxxxx) begin
        errs = errs + 1;
        $display("  X-PROP: a=0x%08h b=0x%08h", a, b);
      end
    end
  endtask

  // ---- Part 3: result must equal the larger operand (diff >= 27) ----
  task automatic check_larger(input logic [31:0] a, b);
    logic [31:0] n, o;
    logic [31:0] larger;
    logic [7:0] ea, eb;
    begin
      ea = a[30:23];
      eb = b[30:23];
      // Larger = the one with the bigger exponent (ties impossible here:
      // diff >= 27 means strictly larger exponent); equal-exponent falls
      // back to the mantissa tie-break like the sort.
      if (ea > eb)
        larger = a;
      else if (eb > ea)
        larger = b;
      else
        larger = (a[22:0] >= b[22:0]) ? a : b;
      drive(a, b, n, o);
      total = total + 1;
      if (n !== larger) begin
        errs = errs + 1;
        if (errs <= 10)
          $display("  [FAIL-extreme] a=0x%08h b=0x%08h: got 0x%08h expect 0x%08h (larger)",
                   a, b, n, larger);
      end
      if (n === 32'hxxxxxxxx) begin
        errs = errs + 1;
        $display("  X-PROP: a=0x%08h b=0x%08h", a, b);
      end
    end
  endtask

  // ---- Random normal float with exponent in [lo, hi] ----
  function automatic logic [31:0] rand_normal_lo_hi(input int lo, hi);
    logic [31:0] v;
    v[31]    = $urandom & 1'b1;
    v[30:23] = lo + ($urandom % (hi - lo + 1));
    v[22:0]  = $urandom;
    return v;
  endfunction

  initial begin
    logic [31:0] edge_vals [0:16];
    logic [31:0] a, b, n, o;
    int i, j;

    $display("=== FP16 acc compare: new (DSP-backed) vs old ===");

    // ---- Part 1: hand-computed exact cases ----
    // 1024 + (-32) = 992  (equal mantissas, far apart)
    check_exact(32'h44800000, 32'hC2000000, 32'h44780000);
    // 1024 + (-48) = 976  (mant_b > mant_a: fixed-direction subtract)
    check_exact(32'h44800000, 32'hC2400000, 32'h44740000);
    // 1024 + (-40) = 984
    check_exact(32'h44800000, 32'hC2200000, 32'h44760000);
    // 1024 + 48 = 1072    (same signs, far apart)
    check_exact(32'h44800000, 32'h42400000, 32'h44860000);
    // 1.5 + 2.5 = 4.0     (same exponent, overflow to exp+1)
    check_exact(32'h3FC00000, 32'h40200000, 32'h40800000);
    // 2.5 - 1.5 = 1.0     (subtraction, shift by 1)
    check_exact(32'h40200000, 32'hBFC00000, 32'h3F800000);
    // 1.0 - 1.0 = +0.0    (exact cancellation)
    check_exact(32'h3F800000, 32'hBF800000, 32'h00000000);
    // 1.5 + (-1.5) = +0.0
    check_exact(32'h3FC00000, 32'hBFC00000, 32'h00000000);
    // 1.0 + 0.0 = 1.0     (zero operand passthrough)
    check_exact(32'h3F800000, 32'h00000000, 32'h3F800000);
    // 0.0 + 1.0 = 1.0
    check_exact(32'h00000000, 32'h3F800000, 32'h3F800000);
    // 1.0 + inf = inf
    check_exact(32'h3F800000, 32'h7F800000, 32'h7F800000);
    // 1.0 + nan = nan (payload 1 per result_pre)
    check_exact(32'h3F800000, 32'h7FC00000, 32'h7F800001);
    // 3.0 + 5.0 = 8.0
    check_exact(32'h40400000, 32'h40A00000, 32'h41000000);
    // 0.5 + 0.5 = 1.0
    check_exact(32'h3F000000, 32'h3F000000, 32'h3F800000);
    // 1.75 - 0.5 = 1.25
    check_exact(32'h3FE00000, 32'hBF000000, 32'h3FA00000);
    // 1.0 + 1.0 = 2.0
    check_exact(32'h3F800000, 32'h3F800000, 32'h40000000);

    // ---- Part 2: constrained random sweep (diff <= 31, no specials) ----
    for (i = 0; i < 8000; i++)
      run_pair(rand_normal_lo_hi(100, 131), rand_normal_lo_hi(100, 131));

    // ---- Part 3: extreme pairs (diff >= 27 -> result = larger operand) ----
    for (i = 0; i < 3000; i++) begin
      logic [7:0] ea, eb;
      ea = 130 + ($urandom % 100);           // [130, 229]
      eb = 1 + ($urandom % 30);              // [1, 30]  -> diff >= 100
      a[31]    = $urandom & 1'b1;
      a[30:23] = ea;
      a[22:0]  = $urandom;
      b[31]    = $urandom & 1'b1;            // random sign (both cases)
      b[30:23] = eb;
      b[22:0]  = $urandom;
      check_larger(a, b);
    end
    // Moderate-extreme: diff in [32, 126] (the old module's wrap range)
    for (i = 0; i < 3000; i++) begin
      logic [7:0] ea, eb;
      ea = 140 + ($urandom % 80);            // [140, 219]
      eb = ea - (32 + ($urandom % 95));      // diff in [32, 126]
      a[31]    = $urandom & 1'b1;
      a[30:23] = ea;
      a[22:0]  = $urandom;
      b[31]    = $urandom & 1'b1;
      b[30:23] = eb;
      b[22:0]  = $urandom;
      check_larger(a, b);
    end

    // ---- Part 4: edge-case cross product ----
    edge_vals[0]  = 32'h00000000;   // +0
    edge_vals[1]  = 32'h80000000;   // -0
    edge_vals[2]  = 32'h3F800000;   // 1.0
    edge_vals[3]  = 32'hBF800000;   // -1.0
    edge_vals[4]  = 32'h7F800000;   // +inf
    edge_vals[5]  = 32'hFF800000;   // -inf
    edge_vals[6]  = 32'h7FC00000;   // +nan
    edge_vals[7]  = 32'hFFC00000;   // -nan
    edge_vals[8]  = 32'h7F7FFFFF;   // max normal
    edge_vals[9]  = 32'h00800000;   // min normal
    edge_vals[10] = 32'h00000001;   // min subnormal
    edge_vals[11] = 32'h007FFFFF;   // max subnormal
    edge_vals[12] = 32'h7FFFFFFF;   // nan (max payload)
    edge_vals[13] = 32'h3FFFFFFF;   // just below 2.0
    edge_vals[14] = 32'hFFFFFFFF;   // nan (-max payload)
    edge_vals[15] = 32'h00000000;
    edge_vals[16] = 32'h3F000000;   // 0.5
    for (i = 0; i < 17; i++) begin
      for (j = 0; j < 17; j++) begin
        logic [31:0] pa, pb;
        logic [7:0] eamax, ebmax, ediff;
        logic has_nan, has_inf;
        pa = edge_vals[i];
        pb = edge_vals[j];
        has_nan = (pa[30:23] == 8'd255 && pa[22:0] != 23'd0) ||
                  (pb[30:23] == 8'd255 && pb[22:0] != 23'd0);
        has_inf = (pa[30:23] == 8'd255 && pa[22:0] == 23'd0) ||
                  (pb[30:23] == 8'd255 && pb[22:0] == 23'd0);
        if (has_nan) begin
          check_nan(pa, pb);
        end else if (has_inf) begin
          if (pa[30:23] == 8'd255 && pb[30:23] == 8'd255)
            check_inf_inf(pa, pb);
          else
            check_inf_finite(pa, pb);
        end else begin
          eamax = pa[30:23];
          ebmax = pb[30:23];
          ediff = (eamax > ebmax) ? (eamax - ebmax) : (ebmax - eamax);
          if (ediff >= 8'd27)
            check_larger_z(pa, pb);
          else
            run_pair(pa, pb);
        end
      end
    end

    // ---- Report ----
    $display("=== %0d checks: %0d old-vs-new mismatches, %0d errors ===",
             total, mismatches, errs);
    if (mismatches == 0 && errs == 0)
      $display("FP16_ACC_COMPARE PASSED");
    else begin
      $display("FP16_ACC_COMPARE FAILED");
      $finish(1);
    end
    $finish;
  end

endmodule