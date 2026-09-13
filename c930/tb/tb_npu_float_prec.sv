// -----------------------------------------------------------------------------
// tb_npu_float_prec.sv
//
// The UART GEMM sweep of sim/tb_uart_echo.cc, replayed against c930_npu_top
// alone: no CPU, cache, crossbar or firmware.  Same SoC parameters (DIN_W 16,
// MAX_M 8, MAX_K 16, MAX_N 12), same fixed A/B/C addresses, same operand
// patterns and the same eighteen cases in the same order, one command at a
// time.  C is pre-filled with 0xDEADBEEF and every element is checked exactly:
// INT32 for the integer modes, the FP32 bit pattern of the integer reference
// for FP16/BF16 (the operands are small integers, so every sum is exact).
// Six more float cases follow with K > NUM_ROWS, so a running sum crosses a
// K tile, which none of the UART sweep's float shapes do.
//
// On a mismatch it prints the core's A/B operand memories in both banks, so a
// wrong operand and a wrong product can be told apart.
//
//   iverilog -g2012 -o build/tb_npu_float_prec.vvp $(NPU_RTL) tb/tb_npu_float_prec.sv
//   vvp build/tb_npu_float_prec.vvp
// -----------------------------------------------------------------------------
module tb_npu_float_prec;

  localparam int NUM_ROWS = 8;
  localparam int NUM_COLS = 8;
  localparam int DIN_W    = 16;
  localparam int ACC_W    = 48;
  localparam int MAX_M    = 8;
  localparam int MAX_K    = 16;
  localparam int MAX_N    = 12;

  localparam [31:0] A_ADDR = 32'h9000;   // uart_gemm_test.c
  localparam [31:0] B_ADDR = 32'h9400;
  localparam [31:0] C_ADDR = 32'h9800;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  // AXI4-Lite (CSR)
  logic [31:0] s_axi_awaddr  = '0;
  logic        s_axi_awvalid = 1'b0;
  logic        s_axi_awready;
  logic [31:0] s_axi_wdata   = '0;
  logic [3:0]  s_axi_wstrb   = '0;
  logic        s_axi_wvalid  = 1'b0;
  logic        s_axi_wready;
  logic [1:0]  s_axi_bresp;
  logic        s_axi_bvalid;
  logic        s_axi_bready  = 1'b0;
  logic [31:0] s_axi_araddr  = '0;
  logic        s_axi_arvalid = 1'b0;
  logic        s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0]  s_axi_rresp;
  logic        s_axi_rvalid;
  logic        s_axi_rready  = 1'b0;

  // AXI4 full master (DMA) <-> memory model
  logic [31:0] m_axi_araddr;
  logic [7:0]  m_axi_arlen;
  logic [2:0]  m_axi_arsize;
  logic [1:0]  m_axi_arburst;
  logic        m_axi_arvalid;
  logic        m_axi_arready;
  logic [63:0] m_axi_rdata;
  logic [1:0]  m_axi_rresp;
  logic        m_axi_rlast;
  logic        m_axi_rvalid;
  logic        m_axi_rready;
  logic [31:0] m_axi_awaddr;
  logic [7:0]  m_axi_awlen;
  logic [2:0]  m_axi_awsize;
  logic [1:0]  m_axi_awburst;
  logic        m_axi_awvalid;
  logic        m_axi_awready;
  logic [63:0] m_axi_wdata;
  logic [7:0]  m_axi_wstrb;
  logic        m_axi_wlast;
  logic        m_axi_wvalid;
  logic        m_axi_wready;
  logic [1:0]  m_axi_bresp;
  logic        m_axi_bvalid;
  logic        m_axi_bready;

  logic o_busy, o_done, o_error, o_irq;

  c930_npu_top #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .DIN_W    (DIN_W),
    .ACC_W    (ACC_W),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N)
  ) dut (
    .i_clk         (clk),
    .i_rst_n       (rst_n),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .m_axi_araddr  (m_axi_araddr),
    .m_axi_arlen   (m_axi_arlen),
    .m_axi_arsize  (m_axi_arsize),
    .m_axi_arburst (m_axi_arburst),
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rlast   (m_axi_rlast),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awlen   (m_axi_awlen),
    .m_axi_awsize  (m_axi_awsize),
    .m_axi_awburst (m_axi_awburst),
    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_wdata   (m_axi_wdata),
    .m_axi_wstrb   (m_axi_wstrb),
    .m_axi_wlast   (m_axi_wlast),
    .m_axi_wvalid  (m_axi_wvalid),
    .m_axi_wready  (m_axi_wready),
    .m_axi_bresp   (m_axi_bresp),
    .m_axi_bvalid  (m_axi_bvalid),
    .m_axi_bready  (m_axi_bready),
    .o_busy        (o_busy),
    .o_done        (o_done),
    .o_error       (o_error),
    .o_irq         (o_irq)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // AXI4 slave memory model, as tb_c930_npu.sv, sized for the SoC addresses
  // ---------------------------------------------------------------------------
  localparam int MEM_DEPTH = 16384;       // 32-bit words: bytes 0x0000-0xFFFF
  logic [31:0] mem [0:MEM_DEPTH-1];

  logic [31:0] r_addr;
  logic [7:0]  r_len;
  logic [7:0]  r_beat;
  logic        r_busy;
  logic [1:0]  rd_byte_off;
  logic [127:0] rd_window;

  assign m_axi_arready = ~r_busy;
  assign m_axi_rvalid  = r_busy;
  assign m_axi_rlast   = (r_beat == r_len);
  assign rd_byte_off = r_addr[1:0];
  assign rd_window = { mem[(r_addr >> 2) + r_beat*2 + 3],
                       mem[(r_addr >> 2) + r_beat*2 + 2],
                       mem[(r_addr >> 2) + r_beat*2 + 1],
                       mem[(r_addr >> 2) + r_beat*2] };
  assign m_axi_rdata = rd_window >> {rd_byte_off, 3'b000};
  assign m_axi_rresp = 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_busy <= 1'b0;
      r_addr <= '0;
      r_len  <= '0;
      r_beat <= '0;
    end else begin
      if (m_axi_arvalid && m_axi_arready && !r_busy) begin
        r_addr <= m_axi_araddr;
        r_len  <= m_axi_arlen;
        r_beat <= 8'd0;
        r_busy <= 1'b1;
      end
      if (r_busy && m_axi_rvalid && m_axi_rready) begin
        if (r_beat == r_len)
          r_busy <= 1'b0;
        else
          r_beat <= r_beat + 1;
      end
    end
  end

  logic [31:0] w_addr;
  logic [7:0]  w_len;
  logic [7:0]  w_beat;
  logic        w_busy;
  logic        b_valid;

  assign m_axi_awready = ~w_busy;
  assign m_axi_wready  = w_busy;
  assign m_axi_bvalid  = b_valid;
  assign m_axi_bresp   = 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_busy  <= 1'b0;
      b_valid <= 1'b0;
      w_addr  <= '0;
      w_len   <= '0;
      w_beat  <= '0;
    end else begin
      if (m_axi_awvalid && m_axi_awready && !w_busy) begin
        w_addr <= m_axi_awaddr;
        w_len  <= m_axi_awlen;
        w_beat <= 8'd0;
        w_busy <= 1'b1;
      end
      if (w_busy && m_axi_wvalid && m_axi_wready) begin
        for (int i = 0; i < 4; i++)
          if (m_axi_wstrb[i])
            mem[(w_addr >> 2) + w_beat*2][i*8 +: 8] <= m_axi_wdata[i*8 +: 8];
        for (int i = 0; i < 4; i++)
          if (m_axi_wstrb[i+4])
            mem[(w_addr >> 2) + w_beat*2 + 1][i*8 +: 8] <= m_axi_wdata[(i+4)*8 +: 8];
        if (w_beat == w_len) begin
          w_busy  <= 1'b0;
          b_valid <= 1'b1;
        end else begin
          w_beat <= w_beat + 1;
        end
      end
      if (b_valid && m_axi_bready)
        b_valid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // CSR access
  // ---------------------------------------------------------------------------
  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);
    s_axi_awaddr  = addr;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = data;
    s_axi_wstrb   = 4'hF;
    s_axi_wvalid  = 1'b1;
    s_axi_bready  = 1'b1;
    wait (s_axi_awready && s_axi_wready);
    s_axi_awvalid = 1'b0;
    s_axi_wvalid  = 1'b0;
    wait (s_axi_bvalid);
    @(posedge clk);
    s_axi_bready  = 1'b0;
  endtask

  // One command at a time, as uart_gemm_test.c issues them.
  task automatic run_gemm(input int m, n, k, input int prec);
    axi_write(32'h14, A_ADDR);
    axi_write(32'h18, B_ADDR);
    axi_write(32'h1C, C_ADDR);
    axi_write(32'h08, m[31:0]);
    axi_write(32'h0C, n[31:0]);
    axi_write(32'h10, k[31:0]);
    axi_write(32'h20, prec[31:0]);
    axi_write(32'h00, 32'h1);
    wait (o_done === 1'b1);
    @(posedge clk);
    wait (o_busy === 1'b0);
  endtask

  // ---------------------------------------------------------------------------
  // Operand packing, as tb_uart_echo.cc
  // ---------------------------------------------------------------------------
  task automatic store_byte(input int addr, input logic [7:0] val);
    mem[addr >> 2][(addr & 3) * 8 +: 8] = val;
  endtask

  // Exact IEEE encodings of a small integer: FP32, and binary16 / bfloat16.
  function automatic logic [31:0] fp32_of_int(input int v);
    int mag, p;
    if (v == 0) return 32'h0;
    mag = (v < 0) ? -v : v;
    p = 0;
    while ((mag >> (p + 1)) != 0) p++;
    return {v < 0, 8'(127 + p), 23'((mag << (23 - p)) & 32'h7FFFFF)};
  endfunction

  function automatic logic [15:0] half_of_int(input int v);
    int mag, p;
    if (v == 0) return 16'h0;
    mag = (v < 0) ? -v : v;
    p = 0;
    while ((mag >> (p + 1)) != 0) p++;
    return {v < 0, 5'(15 + p), 10'((mag << (10 - p)) & 32'h3FF)};
  endfunction

  function automatic logic [15:0] elem16(input int prec, input int v);
    case (prec)
      1: return 16'(v);
      2: return half_of_int(v);
      default: return fp32_of_int(v) >> 16;          // BF16: top half of FP32
    endcase
  endfunction

  // Operands of the UART sweep: A[i] = (3i+1) mod 9 - 4, B[i] = (5i+2) mod 9 - 4.
  function automatic int a_val(input int i); return ((i * 3 + 1) % 9) - 4; endfunction
  function automatic int b_val(input int i); return ((i * 5 + 2) % 9) - 4; endfunction

  task automatic pack(input logic [31:0] base, input int n_elem, input int prec,
                      input bit is_b);
    for (int i = 0; i < n_elem; i++) begin
      int v = is_b ? b_val(i) : a_val(i);
      case (prec)
        0: store_byte(base + i, 8'(v));
        4: begin
          int addr = base + i / 2;
          mem[addr >> 2][(addr & 3) * 8 + (i % 2) * 4 +: 4] = 4'(v);
        end
        default: begin
          logic [15:0] u = elem16(prec, v);
          store_byte(base + 2 * i, u[7:0]);
          store_byte(base + 2 * i + 1, u[15:8]);
        end
      endcase
    end
  endtask

  // ---------------------------------------------------------------------------
  // Diagnosis: the core's operand memories, both banks
  // ---------------------------------------------------------------------------
  task automatic dump_operands(input int n_show);
    $write("      bank_sel dma %0d core_b %0d\n", dut.u_dma.bank_sel, dut.u_core.b_bank_sel);
    $write("      a_mem_0:");
    for (int i = 0; i < n_show; i++) $write(" %04h", dut.u_core.a_mem_0[i]);
    $write("\n      a_mem_1:");
    for (int i = 0; i < n_show; i++) $write(" %04h", dut.u_core.a_mem_1[i]);
    $write("\n      b_mem_0:");
    for (int i = 0; i < n_show; i++) $write(" %04h", dut.u_core.b_mem_0[i]);
    $write("\n      b_mem_1:");
    for (int i = 0; i < n_show; i++) $write(" %04h", dut.u_core.b_mem_1[i]);
    $write("\n      want B :");
    for (int i = 0; i < n_show; i++) $write(" %04h", elem16(prec_now, b_val(i)));
    $write("\n");
  endtask

  int prec_now;

  task automatic run_case(input int prec, m, n, k, inout int passed);
    int nbad = 0;
    string name;
    case (prec)
      0: name = "INT8 "; 1: name = "INT16"; 2: name = "FP16 "; 3: name = "BF16 ";
      default: name = "INT4 ";
    endcase
    prec_now = prec;
    pack(A_ADDR, m * k, prec, 1'b0);
    pack(B_ADDR, k * n, prec, 1'b1);
    for (int i = 0; i < m * n; i++) mem[(C_ADDR >> 2) + i] = 32'hDEADBEEF;

    run_gemm(m, n, k, prec);

    for (int mi = 0; mi < m; mi++)
      for (int ni = 0; ni < n; ni++) begin
        int ref_sum = 0;
        logic [31:0] want, got;
        for (int ki = 0; ki < k; ki++) ref_sum += a_val(mi * k + ki) * b_val(ki * n + ni);
        want = (prec == 2 || prec == 3) ? fp32_of_int(ref_sum) : 32'(ref_sum);
        got  = mem[(C_ADDR >> 2) + mi * n + ni];
        if (got !== want) begin
          if (nbad < 3)
            $display("      C[%0d] got %08h want %08h (%0d)", mi * n + ni, got, want, ref_sum);
          nbad++;
        end
      end
    if (nbad == 0) begin
      passed++;
      $display("  GEMM %s %2dx%2dx%2d  PASS", name, m, n, k);
    end else begin
      $display("  GEMM %s %2dx%2dx%2d  FAIL  %0d/%0d wrong", name, m, n, k, nbad, m * n);
      dump_operands(8);
    end
  endtask

  initial begin
    int passed = 0;
    for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 32'h0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("UART GEMM sweep, replayed on c930_npu_top:");
    run_case(0, 1,  1,  1, passed); run_case(0, 1,  1, 16, passed);
    run_case(0, 1, 12,  8, passed); run_case(0, 2,  3,  5, passed);
    run_case(0, 4,  4,  4, passed); run_case(0, 5,  7,  9, passed);
    run_case(0, 8,  1,  4, passed); run_case(0, 8,  4,  1, passed);
    run_case(0, 8, 12, 16, passed); run_case(0, 3,  9, 11, passed);
    run_case(1, 4,  4,  4, passed); run_case(2, 4,  4,  4, passed);
    run_case(3, 4,  4,  4, passed); run_case(4, 4,  4,  4, passed);
    run_case(1, 2,  3,  5, passed); run_case(2, 2,  3,  5, passed);
    run_case(3, 2,  3,  5, passed); run_case(4, 2,  3,  5, passed);

    // Every float case above has K <= NUM_ROWS, so its running sum never
    // crosses a K tile.  These do, and N-tile too.
    $display("Float across K tiles:");
    run_case(2, 5,  7,  9, passed); run_case(3, 5,  7,  9, passed);
    run_case(2, 3,  9, 11, passed); run_case(3, 3,  9, 11, passed);
    run_case(2, 8, 12, 16, passed); run_case(3, 8, 12, 16, passed);

    $display("  total %0d/24", passed);
    if (passed != 24) $fatal(1, "%0d case(s) failed", 24 - passed);
    $finish;
  end

  initial begin
    #50_000_000;
    $fatal(1, "timeout");
  end

endmodule
