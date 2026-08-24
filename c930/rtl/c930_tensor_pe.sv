// -----------------------------------------------------------------------------
// c930_tensor_pe.sv
//
// One processing element of the weight-stationary systolic array.
//
//   * Weight `w` is stationary: loaded once via i_wen/i_wdata and held.
//   * Activation flows left -> right: o_a_out <= i_a_in (registered).
//   * Partial sum flows top -> bottom.
//
// Supports four datapaths based on i_precision:
//   - INT8/INT16 (precision 0/1): signed integer MAC
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
  parameter int DIN_W = 16,  // activation / weight bit width (8 for INT8, 16 for INT16/FP16/BF16)
  parameter int ACC_W = 48   // accumulator bit width (48 for INT8/INT16, FP uses lower 32)
)
(
  input  logic                        i_clk,
  input  logic                        i_rst_n,

  // Weight load (weight-stationary)
  input  logic                        i_wen,
  input  logic signed [DIN_W-1:0]     i_wdata,

  // Activation: in from the left neighbor, out to the right neighbor
  input  logic signed [DIN_W-1:0]     i_a_in,
  output logic signed [DIN_W-1:0]     o_a_out,

  // Partial sum: in from the top neighbor, out to the bottom neighbor
  input  logic signed [ACC_W-1:0]     i_ps_in,
  output logic signed [ACC_W-1:0]     o_ps_out,

  // Precision control: 0=INT8, 1=INT16, 2=FP16, 3=BF16
  input  logic [1:0]                  i_precision
);

  // ---- Weight register ----
  logic signed [DIN_W-1:0] w;

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      w <= '0;
    else if (i_wen)
      w <= i_wdata;
  end

  // Activation passthrough (registered, regardless of mode)
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      o_a_out <= '0;
    else
      o_a_out <= i_a_in;
  end

  // ---- Integer MAC path (INT8/INT16) ----
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
  assign fp32_prod = (i_precision == 2'd3) ? bf16_prod : fp16_prod;

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
    else if (i_precision == 2'd2 || i_precision == 2'd3) begin
      // FP16/BF16 mode: use FP32 accumulator output (zero-extend upper bits)
      o_ps_out[ACC_W-1:32] <= '0;
      o_ps_out[31:0]        <= fp32_ps_out;
    end else begin
      // INT8/INT16 mode: use integer MAC output
      o_ps_out <= int_ps_out;
    end
  end

endmodule
