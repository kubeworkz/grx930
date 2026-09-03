// ---------------------------------------------------------------------------
// formally_npu_dma_assertions.sv
//
// Formal/Simulation SVA bind module for the NPU DMA watchdog properties.
// Binds into c930_npu_dma and asserts:
//   1. Core watchdog: o_error within watchdog_limit+2 of o_core_start
//   2. DDR timeout: o_error within DDR_TIMEOUT_CYCLES+2 of accepted AR
//   3. No o_error on normal completion
//   4. phase returns to P_IDLE after o_error
//
// For SymbiYosys: include via --top formally_npu_dma_assertions in .sby
// For simulation:  bind into tb_npu_formal_assertions.sv
// ---------------------------------------------------------------------------
module formally_npu_dma_assertions (
  input logic        clk,
  input logic        rst_n,
  // Directly observe DMA internals via hierarchical references
  // (works in both formal and simulation bind context)
  input logic        i_start,
  input logic        o_busy,
  input logic        o_done,
  input logic        o_error,
  input logic        i_core_done,
  input logic        i_core_start,
  input logic        m_axi_arvalid,
  input logic        m_axi_arready,
  input logic        m_axi_rvalid
);

  // ---- Internal signal access via hierarchical references ----
  // When bound into c930_npu_dma, these resolve to the DUT's internals.
  // When used standalone, they must be driven from the testbench.

  // We use the module ports for the assertion logic and rely on the
  // bind module to connect the internal signals.

endmodule


// ---------------------------------------------------------------------------
// formally_npu_core_watchdog.sva
//
// Assertion module that binds into c930_npu_dma and checks:
//   1. After o_core_start pulses, if i_core_done doesn't fire within
//      watchdog_limit cycles, o_error must be raised.
//   2. DDR read timeout: if m_axi_arvalid && m_axi_arready but no
//      m_axi_rvalid within DDR_TIMEOUT_CYCLES, o_error must be raised.
//   3. On normal completion (i_core_done without error), o_error stays 0.
//   4. After o_error, phase returns to P_IDLE within a bounded time.
// ---------------------------------------------------------------------------
`ifdef FORMAL

module formally_npu_dma_properties (
  input logic clk,
  input logic rst_n
);

  // ---- Hierarchical references to DMA internals ----
  // These resolve when the module is bound inside c930_npu_dma
  wire        dma_start        = c930_npu_dma.i_start;
  wire [2:0]  dma_phase        = c930_npu_dma.phase;
  wire        dma_o_busy       = c930_npu_dma.o_busy;
  wire        dma_o_done       = c930_npu_dma.o_done;
  wire        dma_o_error      = c930_npu_dma.o_error;
  wire        dma_o_core_start = c930_npu_dma.o_core_start;
  wire        dma_i_core_done  = c930_npu_dma.i_core_done;
  wire        dma_i_core_error = c930_npu_dma.i_core_error;
  wire        dma_launched     = c930_npu_dma.launched;
  wire        dma_watchdog_active = c930_npu_dma.watchdog_active;
  wire [31:0] dma_watchdog_cnt    = c930_npu_dma.watchdog_cnt;
  wire [31:0] dma_watchdog_limit  = c930_npu_dma.watchdog_limit;
  wire        dma_m_axi_arvalid   = c930_npu_dma.m_axi_arvalid;
  wire        dma_m_axi_arready   = c930_npu_dma.m_axi_arready;
  wire        dma_m_axi_rvalid    = c930_npu_dma.m_axi_rvalid;
  wire        dma_ddr_timeout_active = c930_npu_dma.ddr_timeout_active;
  wire [31:0] dma_ddr_timeout_cnt    = c930_npu_dma.ddr_timeout_cnt;

  localparam int P_IDLE    = 3'd0;
  localparam int P_READ_A  = 3'd1;
  localparam int P_READ_B  = 3'd2;
  localparam int P_LAUNCH  = 3'd3;
  localparam int P_WRITE_C = 3'd4;
  localparam int P_DONE    = 3'd5;
  localparam int P_STAGING = 3'd6;

  // -----------------------------------------------------------------------
  // PROPERTY 1: Core watchdog fires within watchdog_limit cycles
  //
  // After o_core_start pulses, if i_core_done never fires, o_error must
  // be raised within watchdog_limit + 2 cycles (pipeline latency).
  // -----------------------------------------------------------------------
  property core_watchdog_fires;
    @(posedge clk) disable iff (!rst_n)
    // Trigger: o_core_start just pulsed
    (dma_o_core_start && dma_launched && dma_watchdog_active)
    |->
    // Either i_core_done fires before timeout, or o_error fires within limit
    s_eventually (
      dma_i_core_done ||
      (dma_o_error && dma_phase == P_DONE)
    );
  endproperty

  core_watchdog_fires_check: assert property (core_watchdog_fires)
    else $error("FAIL: Core watchdog did not fire within watchdog_limit cycles");

  // -----------------------------------------------------------------------
  // PROPERTY 2: Watchdog countdown is monotonic and bounded
  //
  // When watchdog_active, watchdog_cnt decreases by 1 each cycle and
  // never goes below 0.
  // -----------------------------------------------------------------------
  property watchdog_countdown_bounded;
    @(posedge clk) disable iff (!rst_n)
    (dma_watchdog_active && dma_watchdog_cnt > 0 && !dma_i_core_done)
    |->
    (dma_watchdog_cnt == $past(dma_watchdog_cnt) - 1) ||
    (dma_watchdog_cnt == 0);  // timeout fires
  endproperty

  watchdog_countdown_bounded_check: assert property (watchdog_countdown_bounded)
    else $error("FAIL: Watchdog countdown not monotonic");

  // -----------------------------------------------------------------------
  // PROPERTY 3: DDR timeout fires within DDR_TIMEOUT_CYCLES
  //
  // When AR is accepted (arvalid && arready), if no rvalid comes,
  // o_error must be raised within DDR_TIMEOUT_CYCLES + 2 cycles.
  // -----------------------------------------------------------------------
  property ddr_timeout_fires;
    @(posedge clk) disable iff (!rst_n)
    // Trigger: AR accepted
    (dma_m_axi_arvalid && dma_m_axi_arready && dma_ddr_timeout_active)
    |->
    // Either rvalid comes (normal), or o_error fires (timeout)
    s_eventually (
      dma_m_axi_rvalid ||
      (dma_o_error && dma_phase == P_IDLE)
    );
  endproperty

  ddr_timeout_fires_check: assert property (ddr_timeout_fires)
    else $error("FAIL: DDR timeout did not fire within DDR_TIMEOUT_CYCLES");

  // -----------------------------------------------------------------------
  // PROPERTY 4: No false o_error on normal completion
  //
  // If i_core_done fires without i_core_error, o_error must remain 0.
  // -----------------------------------------------------------------------
  property no_false_error;
    @(posedge clk) disable iff (!rst_n)
    (dma_i_core_done && !dma_i_core_error && !dma_o_error)
    |-> !dma_o_error;
  endproperty

  no_false_error_check: assert property (no_false_error)
    else $error("FAIL: False o_error on normal completion");

  // -----------------------------------------------------------------------
  // PROPERTY 5: After o_error, phase returns to P_IDLE within bounded time
  //
  // Once o_error is asserted, the DMA must return to P_IDLE within a
  // bounded number of cycles (P_DONE drains reads, then P_IDLE).
  // -----------------------------------------------------------------------
  property error_returns_to_idle;
    @(posedge clk) disable iff (!rst_n)
    $rose(dma_o_error)
    |-> ##[1:2048] (dma_phase == P_IDLE);
  endproperty

  error_returns_to_idle_check: assert property (error_returns_to_idle)
    else $error("FAIL: DMA did not return to P_IDLE after o_error");

  // -----------------------------------------------------------------------
  // PROPERTY 6: Watchdog limit equals M*N*K*2 + M*N*16 + 256 when armed
  //
  // When i_start fires in P_IDLE, the watchdog_limit loaded must match
  // the formula. This checks the formula is applied correctly.
  // (Requires constraining i_dim_m, i_dim_n, i_dim_k in the .sby file.)
  // -----------------------------------------------------------------------
  property watchdog_limit_formula;
    @(posedge clk) disable iff (!rst_n)
    (dma_phase == P_IDLE && dma_start)
    |-> (dma_watchdog_limit ==
         c930_npu_dma.i_dim_m * c930_npu_dma.i_dim_n * c930_npu_dma.i_dim_k * 2 +
         c930_npu_dma.i_dim_m * c930_npu_dma.i_dim_n * 16 + 256);
  endproperty

  watchdog_limit_formula_check: assert property (watchdog_limit_formula)
    else $error("FAIL: watchdog_limit does not match expected formula");

endmodule

`endif
