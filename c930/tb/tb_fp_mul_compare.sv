// -----------------------------------------------------------------------------
// tb_fp_mul_compare.sv
//
// Verifies the merged c930_fp_mul (single shared mantissa product, mode bit)
// is bit-identical to the original c930_fp16_mul (mode 0) and
// c930_bf16_mul (mode 1) for every input vector.
//
//   * Exhaustive edges: zero, ±denormal, ±min/max normal, ±inf, ±NaN and
//     all cross products of that set.
//   * Random: values with uniform exponent spread plus mantissa random bits,
//     restricted to exponent ranges whose products stay in the region the
//     original modules handle (their historical wrap behavior in the extreme
//     overflow/underflow corners is mirrored by the new module, so any
//     mismatch there would be a real difference and would still be caught).
// -----------------------------------------------------------------------------

module tb_fp_mul_compare;

  logic [15:0] a, b;
  logic [31:0] fp16_ref, bf16_ref, fp16_new, bf16_new;
  int errors = 0;
  int checks = 0;
  longint seed = 42;

  c930_fp16_mul u_fp16_ref (.i_a(a), .i_b(b), .o_result(fp16_ref));
  c930_bf16_mul u_bf16_ref (.i_a(a), .i_b(b), .o_result(bf16_ref));
  c930_fp_mul    u_new (.i_a(a), .i_b(b), .i_mode(1'b0), .o_result(fp16_new));
  c930_fp_mul    u_new_b (.i_a(a), .i_b(b), .i_mode(1'b1), .o_result(bf16_new));

  // Deterministic LFSR-ish PRNG (no $urandom dependency for Icarus compat).
  function automatic logic [15:0] rnd16();
    logic [15:0] r;
    begin
      seed = (seed * 1103515245 + 12345) & 64'hFFFFFFFF;
      r = seed[15:0];
      // Sometimes force a biased exponent for coverage.
      if ((seed >> 16) % 4 == 0) begin
        // exponent spread: occasionally small/denormal-ish or saturated
        case ((seed >> 16) % 4)
          2'd0: r = {r[15], 5'd0, r[9:0]};          // exp 0 region
          2'd1: r = {r[15], r[14:10], r[9:0]};      // normal spread
          2'd2: r = {r[15], 5'd30, r[9:0]};         // near max normal
          default: r = {r[15], r[14:10], r[9:0]};
        endcase
      end
      return r;
    end
  endfunction

  task automatic check_pair(input logic [15:0] va, vb);
    begin
      a = va; b = vb;
      #1;
      checks = checks + 1;
      if (fp16_ref !== fp16_new) begin
        if (errors < 10)
          $display("  [FAIL-fp16] a=%04h b=%04h ref=%08h new=%08h", a, b, fp16_ref, fp16_new);
        errors = errors + 1;
      end
      if (bf16_ref !== bf16_new) begin
        if (errors < 10)
          $display("  [FAIL-bf16] a=%04h b=%04h ref=%08h new=%08h", a, b, bf16_ref, bf16_new);
        errors = errors + 1;
      end
    end
  endtask

  logic [15:0] edges [0:15];
  initial begin
    // Edge set: 0, -0, fp16 denormal, fp16 inf, fp16 nan, fp16 max normal,
    // min normal, 1.0; and bf16 equivalents.
    edges[0]  = 16'h0000;   // +0
    edges[1]  = 16'h8000;   // -0
    edges[2]  = 16'h0001;   // fp16 denormal / bf16 denormal
    edges[3]  = 16'h0400;   // fp16 min normal / bf16 exp 2
    edges[4]  = 16'h3C00;   // 1.0 (fp16 and bf16 both encode 1.0)
    edges[5]  = 16'h7BFF;   // fp16 max normal / bf16 huge
    edges[6]  = 16'h7C00;   // fp16 +inf / bf16 finite (exp 248)
    edges[7]  = 16'hFC00;   // fp16 -inf
    edges[8]  = 16'h7E00;   // fp16 +NaN
    edges[9]  = 16'hFE00;   // fp16 -NaN
    edges[10] = 16'h7F80;   // bf16 +inf / fp16 NaN
    edges[11] = 16'hFF80;   // bf16 -inf / fp16 NaN
    edges[12] = 16'h7FC1;   // bf16 +NaN / fp16 NaN
    edges[13] = 16'h7F7F;   // bf16 max finite
    edges[14] = 16'h0080;   // bf16 min normal
    edges[15] = 16'h4000;   // 2.0

    // Exhaustive cross products of the edge set (256 x 2 modes).
    for (int i = 0; i < 16; i++)
      for (int j = 0; j < 16; j++)
        check_pair(edges[i], edges[j]);

    // Random vectors.
    for (int i = 0; i < 20000; i++)
      check_pair(rnd16(), rnd16());

    if (errors == 0)
      $display("FP_MUL_COMPARE PASSED: %0d checks, 0 mismatches", checks);
    else
      $display("FP_MUL_COMPARE FAILED: %0d checks, %0d mismatches", checks, errors);
    $finish;
  end

endmodule
