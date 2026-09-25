module riscv_core_mul_div 
#(
  parameter XLEN = 64
)
(
  input   logic [XLEN-1:0] i_mul_div_srcA,
  input   logic [XLEN-1:0] i_mul_div_srcB,
  input   logic [2:0]      i_mul_div_control,
  input   logic            i_mul_div_en,
  input   logic            i_mul_div_isword,
  input   logic            i_mul_div_clk,
  input   logic            i_mul_div_rstn,
  // High while the EX stage is held, so the unit can tell a stall from the
  // instruction leaving: see the result hold below.
  input   logic            i_mul_div_stall_ex,
  output  logic            o_mul_div_busy,   
  output  logic            o_mul_div_done,
  output  logic            o_mul_div_overflow,
  output  logic            o_mul_div_div_by_zero,
  output  logic [XLEN-1:0] o_mul_div_result 
);

logic [XLEN-1:0] mul_result;
logic [XLEN-1:0] div_result;
logic [XLEN-1:0] fast_result;
logic [XLEN-1:0] mul_div_result;

logic            mul_done;
logic            div_done;

logic            mul_start;
logic            div_start;

logic mul_div_sel;
logic out_sel;

// The control FSM's own outputs, before the result hold at the end of the file.
logic            ctrl_busy;
logic            ctrl_done;
logic            ctrl_overflow;
logic            ctrl_div_by_zero;
logic [XLEN-1:0] ctrl_result;
logic            res_held;

logic [XLEN-1:0]   multiplicand;
logic [XLEN-1:0]   multiplier;
logic [2*XLEN-1:0] product;

logic [XLEN-1:0] dividend;
logic [XLEN-1:0] divisor;
logic [XLEN-1:0] quotient;      
logic [XLEN-1:0] remainder;

// Registered operand boundary: srcA/srcB are captured at issue and the
// start pulses are delayed one cycle, so the datapath (sign-prep, booth
// accumulator, non-restoring subtractor) reads stable registered operands
// instead of a combinational chain from the core's srcB mux. The control
// FSM stays on the raw operands -- its fast-path comparisons are short and
// must resolve in the issue cycle. EX is frozen by the m-busy stall for the
// whole op, so the raw operands are stable while the registers re-capture.
logic [XLEN-1:0] srcA_reg;
logic [XLEN-1:0] srcB_reg;
logic            mul_start_d;
logic            div_start_d;

always_ff @(posedge i_mul_div_clk, negedge i_mul_div_rstn)
  if (!i_mul_div_rstn)
    begin
      srcA_reg    <= '0;
      srcB_reg    <= '0;
      mul_start_d <= 1'b0;
      div_start_d <= 1'b0;
    end
  else
    begin
      srcA_reg    <= i_mul_div_srcA;
      srcB_reg    <= i_mul_div_srcB;
      mul_start_d <= mul_start;
      div_start_d <= div_start;
    end

riscv_core_mul_div_ctrl
#(
  .XLEN(XLEN)
)
u_riscv_core_mul_div_ctrl
(
  .i_mul_div_ctrl_srcA(i_mul_div_srcA),
  .i_mul_div_ctrl_srcB(i_mul_div_srcB),
  .i_mul_div_ctrl_control(i_mul_div_control[2:0]),
  // Gated so a held result cannot start the operation over.
  .i_mul_div_ctrl_en(i_mul_div_en && !res_held),
  .i_mul_div_ctrl_isword(i_mul_div_isword),
  .i_mul_div_ctrl_clk(i_mul_div_clk),
  .i_mul_div_ctrl_rstn(i_mul_div_rstn),
  .i_mul_div_ctrl_mul_dn(mul_done),
  .i_mul_div_ctrl_div_dn(div_done),
  .o_mul_div_ctrl_out_fast(fast_result),
  .o_mul_div_ctrl_mul_start(mul_start),
  .o_mul_div_ctrl_div_start(div_start),
  .o_mul_div_ctrl_busy(ctrl_busy),
  .o_mul_div_ctrl_done(ctrl_done),
  .o_mul_div_ctrl_div_by_zero(ctrl_div_by_zero),
  .o_mul_div_ctrl_overflow(ctrl_overflow),
  .o_mul_div_ctrl_mul_div_sel(mul_div_sel),
  .o_mul_div_ctrl_out_sel(out_sel)
);

riscv_core_mul_in
#(
  .XLEN(XLEN)
)
u_riscv_core_mul_in
(
  .i_mul_in_srcA(srcA_reg),
  .i_mul_in_srcB(srcB_reg),
  .i_mul_in_control(i_mul_div_control[1:0]),
  .i_mul_in_isword(i_mul_div_isword),
  .o_mul_in_multiplicand(multiplicand),
  .o_mul_in_multiplier(multiplier)
);


riscv_core_booth
#(
  .XLEN(XLEN)
)
u_riscv_core_booth
(
  .i_booth_multiplicand(multiplicand),
  .i_booth_multilpier(multiplier),
  .i_booth_en(mul_start_d),
  .i_booth_clk(i_mul_div_clk),
  .i_booth_rstn(i_mul_div_rstn),
  .o_booth_done(mul_done),
  .o_booth_product(product)
);


riscv_core_mul_out
#(
  .XLEN(XLEN)
)
u_riscv_core_mul_out
(
  .i_mul_out_srcA_Dsign(srcA_reg[XLEN-1]),
  .i_mul_out_srcB_Dsign(srcB_reg[XLEN-1]),
  .i_mul_out_srcA_Wsign(srcA_reg[XLEN/2-1]),
  .i_mul_out_srcB_Wsign(srcB_reg[XLEN/2-1]),
  .i_mul_out_control(i_mul_div_control[1:0]),
  .i_mul_out_isword(i_mul_div_isword),
  .i_mul_out_product(product),
  .o_mul_out_result(mul_result)
);

riscv_core_div_in
#(
  .XLEN(XLEN)
)
u_riscv_core_div_in
(
  .i_div_in_srcA(srcA_reg),
  .i_div_in_srcB(srcB_reg),
  .i_div_in_control(i_mul_div_control[1:0]),
  .i_div_in_isword(i_mul_div_isword),
  .o_div_in_dividend(dividend),
  .o_div_in_divisor(divisor)
);


riscv_core_non_restoring
#(
  .XLEN(XLEN)
)
u_riscv_core_non_restoring
(
  .i_non_restoring_dividend(dividend),
  .i_non_restoring_divisor(divisor),
  .i_non_restoring_en(div_start_d),
  .i_non_restoring_clk(i_mul_div_clk),
  .i_non_restoring_rstn(i_mul_div_rstn),
  .o_non_restoring_done(div_done),
  .o_non_restoring_quotient(quotient),
  .o_non_restoring_remainder(remainder)
);


riscv_core_div_out
#(
  .XLEN(XLEN)
)
u_riscv_core_div_out
(
  .i_div_out_srcA_Dsign(srcA_reg[XLEN-1]),
  .i_div_out_srcB_Dsign(srcB_reg[XLEN-1]),
  .i_div_out_srcA_Wsign(srcA_reg[XLEN/2-1]),
  .i_div_out_srcB_Wsign(srcB_reg[XLEN/2-1]),
  .i_div_out_control(i_mul_div_control[1:0]),
  .i_div_out_isword(i_mul_div_isword),
  .i_div_out_quotient(quotient),
  .i_div_out_remainder(remainder),
  .o_div_out_result(div_result)
);


riscv_core_mux2x1
#(
  .XLEN (XLEN)
)
u_riscv_core_mux2x1_mul_div
(
  .i_mux2x1_in0 (mul_result)
  ,.i_mux2x1_in1(div_result)
  ,.i_mux2x1_sel(mul_div_sel)
  ,.o_mux2x1_out(mul_div_result)
);

riscv_core_mux2x1
#(
  .XLEN (XLEN)
)
u_riscv_core_mux2x1_out_sel
(
  .i_mux2x1_in0 (mul_div_result)
  ,.i_mux2x1_in1(fast_result)
  ,.i_mux2x1_sel(out_sel)
  ,.o_mux2x1_out(ctrl_result)
);

// ---------------------------------------------------------------------------
// Result hold
//
// booth and non_restoring present their result for exactly ONE cycle -- the
// cycle their done pulses -- and drive zero otherwise, and the control FSM
// returns to IDLE on that pulse with i_mul_div_en still asserted, so it starts
// the operation again.  A stall in that one cycle therefore loses the result
// silently and recomputes it, which is slow but survivable on its own.  With a
// store in MEM it is a deadlock: stall_mem holds the store while this unit is
// busy, the held store re-requests the D-cache every time it completes, and the
// D-cache's stall freezes EX -- so the one-cycle window lands on a stalled
// cycle for ever.  A `mulw` two instructions ahead of a `sw` hangs the machine;
// c930/sw/mul_store_test.S is nine instructions that did.
//
// So latch the result when it arrives into a stalled pipeline, report done and
// drop busy while it is latched, and gate the FSM's enable so it cannot
// restart.  The latch clears when EX advances, which is the cycle the
// instruction leaves -- not when i_mul_div_en falls, because back-to-back M
// instructions hold that asserted and the second would be handed the first
// one's result.
// ---------------------------------------------------------------------------
logic [XLEN-1:0] res_reg;
logic            of_reg;
logic            dbz_reg;

always_ff @(posedge i_mul_div_clk, negedge i_mul_div_rstn)
  if (!i_mul_div_rstn)
    begin
      res_held <= 1'b0;
      res_reg  <= '0;
      of_reg   <= 1'b0;
      dbz_reg  <= 1'b0;
    end
  else if (res_held)
    begin
      // Held until the pipeline takes it.
      if (!i_mul_div_stall_ex)
        res_held <= 1'b0;
    end
  else if (ctrl_done && i_mul_div_stall_ex)
    begin
      // Finished into a stalled pipeline, so keep it.  With EX not stalled the
      // result is latched into EX/MEM this cycle and there is nothing to hold.
      res_held <= 1'b1;
      res_reg  <= ctrl_result;
      of_reg   <= ctrl_overflow;
      dbz_reg  <= ctrl_div_by_zero;
    end

assign o_mul_div_busy        = ctrl_busy && !res_held;
assign o_mul_div_done        = ctrl_done || res_held;
assign o_mul_div_result      = res_held ? res_reg : ctrl_result;
assign o_mul_div_overflow    = res_held ? of_reg  : ctrl_overflow;
assign o_mul_div_div_by_zero = res_held ? dbz_reg : ctrl_div_by_zero;

endmodule