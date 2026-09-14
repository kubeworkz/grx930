// c930_soc_verilator.sv -- Verilator harness top for the single-core SoC.
//
// Exposes the UART pins (o_uart_txd / i_uart_rxd) and the DDR testbench
// preload/readback ports so a C++ testbench can load firmware into DDR,
// release reset, and talk to the core over the 16550 UART (0x4000_1000).
//
// The NPU sizing is overridable with -G.  The feed measurement (grxcp
// pta_program_plan.md, F0) builds it at the PTA sweep's shape with
// F0_FEED_PROBE defined -- see sim/build_grx930_verilator.sh.
module c930_soc_verilator #(
  parameter int NUM_ROWS = 4,
  parameter int NUM_COLS = 4,
  parameter int MAX_M    = 8,
  parameter int MAX_K    = 16,
  parameter int MAX_N    = 12
) (
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- NPU status ----
  output logic o_npu_busy,
  output logic o_npu_done,
  output logic o_npu_error,
  output logic o_npu_irq,

  // ---- UART ----
  input  logic i_uart_rxd,
  output logic o_uart_txd,

  // ---- DDR testbench preload port ----
  input  logic        i_tb_wr_en,
  input  logic [31:0] i_tb_wr_addr,
  input  logic [7:0]  i_tb_wr_data,
  // ---- DDR testbench readback port ----
  input  logic [31:0] i_tb_rd_addr,
  output logic [7:0]  o_tb_rd_data
);

  c930_soc_top #(
    .NUM_ROWS (NUM_ROWS),
    .NUM_COLS (NUM_COLS),
    .MAX_M    (MAX_M),
    .MAX_K    (MAX_K),
    .MAX_N    (MAX_N),
    .MEM_BYTES(65536),
    .CLK_DIV  (1)
  ) u_soc (
    .i_clk      (i_clk),
    .i_rst_n    (i_rst_n),
    .o_npu_busy (o_npu_busy),
    .o_npu_done (o_npu_done),
    .o_npu_error(o_npu_error),
    .o_npu_irq  (o_npu_irq),
    .o_uart_txd (o_uart_txd),
    .i_uart_rxd (i_uart_rxd),
    .i_tb_wr_en   (i_tb_wr_en),
    .i_tb_wr_addr (i_tb_wr_addr),
    .i_tb_wr_data (i_tb_wr_data),
    .i_tb_rd_addr (i_tb_rd_addr),
    .o_tb_rd_data (o_tb_rd_data)
  );

`ifdef F0_FEED_PROBE
  // ---- Feed probe on NPU0 (measurement only) ----
  // The windows and counters of tb/tb_npu_feed.sv, plus what the SoC path adds:
  // cycles from an AR accepted at NPU0's master port to that burst's first R
  // beat (the NPU-level memory model takes exactly one), and in-burst cycles
  // with no beat, split by which side held it up.
  wire [2:0] f0_phase = u_soc.u_npu.u_dma.phase;
  wire [2:0] f0_state = u_soc.u_npu.u_core.state;
  wire f0_ar = u_soc.u_npu.m_axi_arvalid && u_soc.u_npu.m_axi_arready;
  wire f0_r  = u_soc.u_npu.m_axi_rvalid  && u_soc.u_npu.m_axi_rready;
  wire f0_aw = u_soc.u_npu.m_axi_awvalid && u_soc.u_npu.m_axi_awready;
  wire f0_w  = u_soc.u_npu.m_axi_wvalid  && u_soc.u_npu.m_axi_wready;

  int f0_win;
  int f0_ph [8];
  int f0_cs [8];
  int f0_pf1_busy, f0_pf1_ars, f0_pf1_beats;
  int f0_pf2_busy, f0_pf2_ars, f0_pf2_beats, f0_pf2_unpk;
  int f0_nar, f0_nrb, f0_naw, f0_nwb, f0_wall, f0_drain_beats;
  int f0_lat_sum, f0_lat_max, f0_lat_n, f0_lat_cnt;
  int f0_rwait, f0_bp;
  int f0_core_cyc, f0_core_stall, f0_core_arow;
  logic f0_on, f0_lat_armed, f0_in_burst, f0_core_done_q;
  logic [2:0] f0_prev_phase;
  logic [31:0] f0_abase;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      f0_win <= 0;
      f0_on <= 1'b0;
      f0_prev_phase <= 3'd0;
      f0_core_done_q <= 1'b0;
      f0_lat_armed <= 1'b0;
      f0_in_burst <= 1'b0;
      f0_wall <= 0; f0_drain_beats <= 0;
      f0_nar <= 0; f0_nrb <= 0; f0_naw <= 0; f0_nwb <= 0;
      f0_pf1_busy <= 0; f0_pf1_ars <= 0; f0_pf1_beats <= 0;
      f0_pf2_busy <= 0; f0_pf2_ars <= 0; f0_pf2_beats <= 0; f0_pf2_unpk <= 0;
      f0_lat_sum <= 0; f0_lat_max <= 0; f0_lat_n <= 0; f0_lat_cnt <= 0;
      f0_rwait <= 0; f0_bp <= 0;
      for (int i = 0; i < 8; i++) begin f0_ph[i] <= 0; f0_cs[i] <= 0; end
    end else begin
      f0_prev_phase <= f0_phase;
      f0_core_done_q <= u_soc.u_npu.u_core.o_done;
      if (u_soc.u_npu.u_core.o_done && !f0_core_done_q) begin
        f0_core_cyc   <= u_soc.u_npu.u_core.cycle_cnt;
        f0_core_stall <= u_soc.u_npu.u_core.stall_cnt;
        f0_core_arow  <= u_soc.u_npu.u_core.arow_stall_cnt;
      end
      if (f0_phase == 3'd1 || f0_phase == 3'd6) f0_abase <= u_soc.u_npu.u_dma.a_base_r;

      // Path latency: AR accepted -> first R beat of that burst.
      if (f0_ar) begin
        f0_lat_armed <= 1'b1;
        f0_lat_cnt <= 1;
        f0_in_burst <= 1'b1;
      end else if (f0_lat_armed) begin
        if (u_soc.u_npu.m_axi_rvalid) begin
          f0_lat_armed <= 1'b0;
          f0_lat_sum <= f0_lat_sum + f0_lat_cnt;
          f0_lat_n <= f0_lat_n + 1;
          if (f0_lat_cnt > f0_lat_max) f0_lat_max <= f0_lat_cnt;
        end else begin
          f0_lat_cnt <= f0_lat_cnt + 1;
        end
      end
      if (f0_r && u_soc.u_npu.m_axi_rlast) f0_in_burst <= 1'b0;

      if (f0_prev_phase == 3'd5 && f0_phase != 3'd5) begin   // left P_DONE
        $display("[F0] gemm=%0d a_base=0x%05h wall=%0d dma_last=%0d | phase read_a=%0d read_b=%0d launch=%0d write_c=%0d done=%0d staging=%0d",
                 f0_win, f0_abase, f0_wall, u_soc.u_npu.u_dma.o_dma_last_count,
                 f0_ph[1], f0_ph[2], f0_ph[3], f0_ph[4], f0_ph[5], f0_ph[6]);
        $display("[F0] gemm=%0d core cycles=%0d wstall=%0d arow_stall=%0d | state idle=%0d wload=%0d accld=%0d run=%0d write=%0d arow=%0d act=%0d",
                 f0_win, f0_core_cyc, f0_core_stall, f0_core_arow,
                 f0_cs[0], f0_cs[1], f0_cs[2], f0_cs[3], f0_cs[4], f0_cs[5], f0_cs[6]);
        $display("[F0] gemm=%0d axi ar=%0d rbeats=%0d aw=%0d wbeats=%0d drain_beats=%0d | pf1 busy=%0d ars=%0d beats=%0d | pf2 busy=%0d ars=%0d beats=%0d unpk=%0d",
                 f0_win, f0_nar, f0_nrb, f0_naw, f0_nwb, f0_drain_beats,
                 f0_pf1_busy, f0_pf1_ars, f0_pf1_beats,
                 f0_pf2_busy, f0_pf2_ars, f0_pf2_beats, f0_pf2_unpk);
        $display("[F0] gemm=%0d path ar_to_r bursts=%0d sum=%0d max=%0d | in-burst cycles with no beat: rvalid low=%0d, rready low=%0d",
                 f0_win, f0_lat_n, f0_lat_sum, f0_lat_max, f0_rwait, f0_bp);
        f0_win <= f0_win + 1;
        f0_on <= (f0_phase != 3'd0);
        f0_wall <= 0; f0_drain_beats <= 0;
        f0_nar <= 0; f0_nrb <= 0; f0_naw <= 0; f0_nwb <= 0;
        f0_pf1_busy <= 0; f0_pf1_ars <= 0; f0_pf1_beats <= 0;
        f0_pf2_busy <= 0; f0_pf2_ars <= 0; f0_pf2_beats <= 0; f0_pf2_unpk <= 0;
        f0_lat_sum <= 0; f0_lat_max <= 0; f0_lat_n <= 0;
        f0_rwait <= 0; f0_bp <= 0;
        for (int i = 0; i < 8; i++) begin f0_ph[i] <= 0; f0_cs[i] <= 0; end
      end else begin
        if (f0_phase != 3'd0) f0_on <= 1'b1;
        if (f0_on || f0_phase != 3'd0) begin
          f0_wall <= f0_wall + 1;
          f0_ph[f0_phase] <= f0_ph[f0_phase] + 1;
          f0_cs[f0_state] <= f0_cs[f0_state] + 1;
          if (f0_phase == 3'd5 && f0_r) f0_drain_beats <= f0_drain_beats + 1;
          if (u_soc.u_npu.u_dma.pf_state != 2'd0) f0_pf1_busy <= f0_pf1_busy + 1;
          if (u_soc.u_npu.u_dma.pf_state == 2'd1 && f0_ar) f0_pf1_ars <= f0_pf1_ars + 1;
          if (u_soc.u_npu.u_dma.pf_state == 2'd2 && f0_r) f0_pf1_beats <= f0_pf1_beats + 1;
          if (u_soc.u_npu.u_dma.pf2_state != 2'd0) f0_pf2_busy <= f0_pf2_busy + 1;
          if (u_soc.u_npu.u_dma.pf2_state == 2'd1 && f0_ar) f0_pf2_ars <= f0_pf2_ars + 1;
          if (u_soc.u_npu.u_dma.pf2_state == 2'd2 && f0_r) f0_pf2_beats <= f0_pf2_beats + 1;
          if (u_soc.u_npu.u_dma.pf2_state == 2'd3) f0_pf2_unpk <= f0_pf2_unpk + 1;
          if (f0_ar) f0_nar <= f0_nar + 1;
          if (f0_r)  f0_nrb <= f0_nrb + 1;
          if (f0_aw) f0_naw <= f0_naw + 1;
          if (f0_w)  f0_nwb <= f0_nwb + 1;
          if (f0_in_burst && !f0_lat_armed && !u_soc.u_npu.m_axi_rvalid) f0_rwait <= f0_rwait + 1;
          if (f0_in_burst && u_soc.u_npu.m_axi_rvalid && !u_soc.u_npu.m_axi_rready) f0_bp <= f0_bp + 1;
        end
      end
    end
  end
`endif

endmodule
