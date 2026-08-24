// tb_fx_acc.sv — standalone test for c930_fx_acc
module tb_fx_acc;
  logic [47:0] ps_in, ps_out;
  logic [31:0] prod;

  c930_fx_acc u_dut (.i_ps_in(ps_in), .i_prod(prod), .o_ps_out(ps_out));

  task automatic check(input string name, input logic [47:0] got, input logic [47:0] exp);
    if (got !== exp)
      $display("[FAIL] %s: got=%h exp=%h", name, got, exp);
    else
      $display("[PASS] %s: %h", name, got);
  endtask

  initial begin
    // FP32 constants: 1.0=3F800000, 0.5=3F000000, 0.25=3E800000, 0.125=3E000000

    // Test 1: 0 + 1.0 = 1.0
    ps_in = 0; prod = 32'h3F800000; #1;
    check("0 + 1.0", ps_out, {1'b0, 8'd127, 32'h80000000});

    // Test 2: 1.0 + 1.0 = 2.0 (overflow)
    ps_in = {1'b0, 8'd127, 32'h80000000}; prod = 32'h3F800000; #1;
    check("1.0 + 1.0", ps_out, {1'b0, 8'd128, 32'h80000000});

    // Test 3: 2.0 + 0.5 = 2.5
    ps_in = {1'b0, 8'd128, 32'h80000000}; prod = 32'h3F000000; #1;
    check("2.0 + 0.5", ps_out, {1'b0, 8'd128, 32'hA0000000});

    // Test 4: Chain: 0 -> +1.0 -> +1.0 -> +1.0 -> +1.0 = 4.0
    ps_in = 0; prod = 32'h3F800000; #1;
    ps_in = ps_out; prod = 32'h3F800000; #1;
    ps_in = ps_out; prod = 32'h3F800000; #1;
    ps_in = ps_out; prod = 32'h3F800000; #1;
    check("4x 1.0 chain", ps_out, {1'b0, 8'd129, 32'h80000000});

    // Test 5: 1.0 + 0.125 = 1.125
    // 0.125 = 2^-3, FP32 = 0x3E000000
    ps_in = {1'b0, 8'd127, 32'h80000000}; prod = 32'h3E000000; #1;
    // Expected: 1.125 = 1 + 1/8. Fixed-point: exp=127, mant=0x90000000 (1.125 * 2^31)
    check("1.0 + 0.125", ps_out, {1'b0, 8'd127, 32'h90000000});

    // Test 6: 4x 0.125 = 0.5
    ps_in = 0; prod = 32'h3E000000; #1;
    ps_in = ps_out; prod = 32'h3E000000; #1;
    ps_in = ps_out; prod = 32'h3E000000; #1;
    ps_in = ps_out; prod = 32'h3E000000; #1;
    // 0.5 = 2^-1, fixed-point: exp=126, mant=0x80000000
    check("4x 0.125 chain", ps_out, {1'b0, 8'd126, 32'h80000000});

    // Test 7: Different exponents in chain: 1.0 + 0.5 + 0.25 + 0.125 = 1.875
    ps_in = 0; prod = 32'h3F800000; #1;           // 1.0
    ps_in = ps_out; prod = 32'h3F000000; #1;      // +0.5
    ps_in = ps_out; prod = 32'h3E800000; #1;      // +0.25
    ps_in = ps_out; prod = 32'h3E000000; #1;      // +0.125
    // 1.875 = 1 + 7/8. Fixed-point: exp=127, mant=0xF0000000 (1.875 * 2^31)
    check("1+0.5+0.25+0.125", ps_out, {1'b0, 8'd127, 32'hF0000000});

    // Test 8: Subtraction: 1.0 + (-0.5) = 0.5
    ps_in = {1'b0, 8'd127, 32'h80000000}; prod = 32'hBF000000; #1;
    check("1.0 + (-0.5)", ps_out, {1'b0, 8'd126, 32'h80000000});

    $display("Done.");
    $finish;
  end
endmodule
