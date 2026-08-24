// -----------------------------------------------------------------------------
// c930_tensor_pe.sv
//
// One processing element of the weight-stationary systolic array.
//
//   * Weight `w` is stationary: loaded once via i_wen/i_wdata and held.
//   * Activation flows left -> right: o_a_out <= i_a_in (registered).
//   * Partial sum flows top -> bottom.
//
// Double-buffered: two weight banks (bank0/bank1) for overlapping weight
// loading with computation.  i_wbank selects which bank to write; i_bank_sel
// selects which bank the multiplier uses.
//
// Supports four datapaths based on i_precision:
//   - INT8/INT16/INT4 (precision 0/1/4): signed integer MAC
//   - FP16 (precision 2): FP16 x FP16 -> FP32 multiplier + FP32 accumulator
//   - BF16 (precision 3): BF16 x BF16 -> FP32 multiplier + FP32 accumulator
//
// Pipeline: the product (fp32_prod) is registered before the accumulator,
// breaking the multiplier->accumulator carry chain.  The PE's output register
// captures the result each cycle.  Cost: 1 extra cycle of latency per PE
// column (product reg + output reg = 2-cycle PE latency).
// -----------------------------------------------------------------------------

module c930_tensor_pe
#(
  parameter int DIN_W = 16,  // activation / weight bit width
  parameter int ACC_W = 48   // accumulator bit width
)
(
  input  logic                        i_clk,
  input  logic                        i_rst_n,

  // Weight load (weight-stationary, double-buffered)
  input  logic                        i_wen,      // write enable
  input  logic                        i_wbank,    // 0=write bank0, 1=write bank1
  input  logic signed [DIN_W-1:0]     i_wdata,

  // Bank select: 0=use bank0 for compute, 1=use bank1
  input  logic                        i_bank_sel,

  // Activation: in from the left neighbor, out to the right neighbor
  input  logic signed [DIN_W-1:0]     i_a_in,
  output logic signed [DIN_W-1:0]     o_a_out,

  // Partial sum: in from the top neighbor, out to the bottom neighbor
  input  logic signed [ACC_W-1:0]     i_ps_in,
  output logic signed [ACC_W-1:0]     o_ps_out,

  // Precision control: 0=INT8, 1=INT16, 2=FP16, 3=BF16, 4=INT4
  input  logic [2:0]                  i_precision
);

  // ---- Double-buffered weight registers ----
  logic signed [DIN_W-1:0] w_bank [0:1];

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      w_bank[0] <= '0;
      w_bank[1] <= '0;
    end else if (i_wen) begin
      w_bank[i_wbank] <= i_wdata;
    end
  end

  // Active weight: mux between banks based on bank select
  logic signed [DIN_W-1:0] w;
  assign w = i_bank_sel ? w_bank[1] : w_bank[0];

  // Activation passthrough (registered, regardless of mode)
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      o_a_out <= '0;
    else
      o_a_out <= i_a_in;
  end

  // ---- Integer MAC path (INT8/INT16/INT4) ----
  logic signed [2*DIN_W-1:0] int_prod;
  assign int_prod = i_a_in * w;

  // Register the integer product (breaks multiply->add carry chain)
  logic signed [2*DIN_W-1:0] int_prod_reg;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      int_prod_reg <= '0;
    else
      int_prod_reg <= int_prod;
  end

  logic signed [ACC_W-1:0] int_ps_out;
  assign int_ps_out = i_ps_in + {{(ACC_W-2*DIN_W){int_prod_reg[2*DIN_W-1]}}, int_prod_reg};

  // ---- FP16 MAC path ----
  logic [15:0] fp16_a, fp16_w;
  assign fp16_a = i_a_in[15:0];
  assign fp16_w = w[15:0];

  // FP16 x FP16 -> FP32 product (combinational)
  logic [31:0] fp16_prod;
  c930_fp16_mul u_fp16_mul (
    .i_a      (fp16_a),
    .i_b      (fp16_w),
    .o_result (fp16_prod)
  );

  // ---- BF16 MAC path ----
  logic [31:0] bf16_prod;
  c930_bf16_mul u_bf16_mul (
    .i_a      (fp16_a),
    .i_b      (fp16_w),
    .o_result (bf16_prod)
  );

  // ---- MUX the FP32 product based on precision ----
  logic [31:0] fp32_prod;
  assign fp32_prod = (i_precision == 3'd3) ? bf16_prod : fp16_prod;

  // Register the FP32 product (breaks multiplier -> accumulator carry chain)
  logic [31:0] fp32_prod_reg;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      fp32_prod_reg <= '0;
    else
      fp32_prod_reg <= fp32_prod;
  end

  // FP32 + FP32 -> FP32 accumulator (combinational, from registered product + i_ps_in)
  logic [31:0] fp32_ps_out;
  c930_fp16_acc u_fp16_acc (
    .i_clk    (i_clk),
    .i_rst_n  (i_rst_n),
    .i_ps_in  (i_ps_in[31:0]),   // lower 32 bits of ACC_W partial sum
    .i_prod   (fp32_prod_reg),   // REGISTERED FP32 product
    .o_ps_out (fp32_ps_out)
  );

  // ---- Output mux based on precision ----
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      o_ps_out <= '0;
    else if (i_precision == 3'd2 || i_precision == 3'd3) begin
      // FP16/BF16 mode: use FP32 accumulator output (zero-extend upper bits)
      o_ps_out[ACC_W-1:32] <= '0;
      o_ps_out[31:0]        <= fp32_ps_out;
    end else begin
      // INT8/INT16/INT4 mode: use integer MAC output
      o_ps_out <= int_ps_out;
    end
  end

endmodule
