`timescale 1ns/1ps
module tb_perf_trace;
  reg clk = 0, rst_n = 0;
  reg [31:0] cycle = 0;
  always #5 clk = ~clk;
  always @(posedge clk) cycle <= cycle + 1;

  c930_soc_top #(.MAX_M(8), .MAX_K(16), .MAX_N(12)) dut (.i_clk(clk), .i_rst_n(rst_n));

  // Load firmware hex (32-bit word hex -> 8-bit byte DDR)
  logic [31:0] img [0:1023];
  initial begin
    int i;
    for (i = 0; i < 1024; i++) img[i] = 32'h0;
    $readmemh("sw/perf_only.hex", img);
    for (i = 0; i < 1024; i++) begin
      dut.u_ddr.mem[4*i + 0] = img[i][7:0];
      dut.u_ddr.mem[4*i + 1] = img[i][15:8];
      dut.u_ddr.mem[4*i + 2] = img[i][23:16];
      dut.u_ddr.mem[4*i + 3] = img[i][31:24];
    end
  end
  initial begin
    dut.u_ddr.mem[32'h9410] = 8'h00; dut.u_ddr.mem[32'h9411] = 8'h00;
    dut.u_ddr.mem[32'h9412] = 8'h00; dut.u_ddr.mem[32'h9413] = 8'h00;
    dut.u_ddr.mem[32'h9490] = 8'h00;
  end

  wire [31:0] pc = dut.u_cpu.if_pipe_pcf_new;
  wire [3:0]  dcm = dut.u_cpu.u_riscv_core_dcache_top.dcache_controller.STATE;

  integer prev_pc = -1;
  integer prev_dcm = -1;

  initial begin
    rst_n = 0; repeat(20) @(posedge clk); rst_n = 1;
    $display("[BOOT] t=%0d", cycle);
    // Dump first 5000 cycles of PC changes
    repeat(5000) begin
      @(posedge clk);
      if (pc != prev_pc || dcm != prev_dcm) begin
        $display("[TRACE] t=%0d pc=%h dcm=%0d", cycle, pc, dcm);
        prev_pc = pc; prev_dcm = dcm;
        $fflush();
      end
    end
    $display("[END] t=%0d pc=%h dcm=%0d phase=%02h",
      cycle, pc, dcm, dut.u_ddr.mem[32'h9490]);
    $finish;
  end
  initial begin #5000000; $display("[TIMEOUT]"); $finish; end
endmodule
