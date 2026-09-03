// -----------------------------------------------------------------------------
// c930_npu_csr.sv
//
// Control/status register file for the NPU with a command queue.
//
// Register map (word offsets):
//   0x00 CTRL       (W)  bit0 START — push command to queue
//   0x04 STATUS     (R)  bit0 BUSY, bit1 DONE (latched), bit2 ERROR
//   0x08 DIM_M      (R/W) output rows
//   0x0C DIM_N      (R/W) output cols
//   0x10 DIM_K      (R/W) reduction length
//   0x14 A_BASE     (R/W) A matrix base address
//   0x18 B_BASE     (R/W) B matrix base address
//   0x1C C_BASE     (R/W) C matrix base address
//   0x20 PREC       (R/W) bit[2:0] precision
//   0x24 CYCLE_LO   (R)  free-running cycle counter
//   0x2C OP_COUNT   (R)  MAC operations completed
//   0x30 STALL_CT   (R)  stall cycles
//   0x34 DMA_CT     (R)  DMA busy cycles (live counter)
//   0x28 DMA_LAST   (R)  latched cycle count from last completed GEMM
//   0x38 QUEUE_STAT (R)  bit[3:0] occupancy, bit[4] full
//   0x3C QUEUE_MAX  (R)  max depth (compile-time)
//
// Command queue:
//   CTRL.START snapshots the current CSR values into a FIFO. If the engine
//   is idle and the FIFO is empty, the command dispatches immediately from
//   the live CSRs. If the engine is busy, the command waits in the FIFO and
//   dispatches automatically when the engine completes. The CPU never blocks.
// -----------------------------------------------------------------------------
module c930_npu_csr
#(
  parameter int CMD_QUEUE_DEPTH = 4
)
(
  input  logic        i_clk,
  input  logic        i_rst_n,

  // ---- AXI4-Lite slave ----
  input  logic [31:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,

  input  logic [31:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // ---- NPU core interface (driven from dispatch register) ----
  output logic        o_start,
  output logic [15:0] o_dim_m,
  output logic [15:0] o_dim_n,
  output logic [15:0] o_dim_k,
  output logic [31:0] o_a_base,
  output logic [31:0] o_b_base,
  output logic [31:0] o_c_base,
  output logic [2:0]  o_precision,
  input  logic        i_busy,
  input  logic        i_done,
  input  logic        i_error,

  // Performance counters
  input  logic [31:0] i_cycle_count,
  input  logic [31:0] i_op_count,
  input  logic [31:0] i_stall_count,
  input  logic [31:0] i_dma_cycle_count,
  input  logic [31:0] i_dma_last_count,

  // ---- FIFO head (next GEMM params for cross-GEMM prefetch) ----
  output logic        o_fifo_valid,    // 1 when FIFO has a queued command
  output logic [15:0] o_fifo_dim_m,
  output logic [15:0] o_fifo_dim_n,
  output logic [15:0] o_fifo_dim_k,
  output logic [31:0] o_fifo_a_base,
  output logic [31:0] o_fifo_b_base,
  output logic [31:0] o_fifo_c_base,
  output logic [2:0]  o_fifo_precision
);

  localparam logic [3:0] ADDR_CTRL      = 4'h0;
  localparam logic [3:0] ADDR_STAT      = 4'h1;
  localparam logic [3:0] ADDR_DIM_M     = 4'h2;
  localparam logic [3:0] ADDR_DIM_N     = 4'h3;
  localparam logic [3:0] ADDR_DIM_K     = 4'h4;
  localparam logic [3:0] ADDR_A_BASE    = 4'h5;
  localparam logic [3:0] ADDR_B_BASE    = 4'h6;
  localparam logic [3:0] ADDR_C_BASE    = 4'h7;
  localparam logic [3:0] ADDR_PREC      = 4'h8;
  localparam logic [3:0] ADDR_CYCLE_LO  = 4'h9;
  localparam logic [3:0] ADDR_OP_COUNT  = 4'hB;
  localparam logic [3:0] ADDR_STALL_CT  = 4'hC;
  localparam logic [3:0] ADDR_DMA_CT    = 4'hD;
  localparam logic [3:0] ADDR_DMA_LAST  = 4'hA;  // 0x28: latched DMA cycle count from last completed GEMM
  localparam logic [3:0] ADDR_QUEUE_STAT = 4'hE;
  localparam logic [3:0] ADDR_QUEUE_MAX  = 4'hF;

  // ---------------------------------------------------------------------------
  // Live CSR registers
  // ---------------------------------------------------------------------------
  logic [15:0] dim_m, dim_n, dim_k;
  logic [31:0] a_base, b_base, c_base;
  logic [2:0]  precision;
  logic        done_latch;

  // ---------------------------------------------------------------------------
  // Dispatch register — drives o_dim_m etc. to the DMA.
  // Loaded either from live CSRs (idle, FIFO empty) or from FIFO head.
  // ---------------------------------------------------------------------------
  logic [15:0] cur_dim_m, cur_dim_n, cur_dim_k;
  logic [31:0] cur_a_base, cur_b_base, cur_c_base;
  logic [2:0]  cur_precision;
  logic        start_pulse;

  assign o_dim_m     = cur_dim_m;
  assign o_dim_n     = cur_dim_n;
  assign o_dim_k     = cur_dim_k;
  assign o_a_base    = cur_a_base;
  assign o_b_base    = cur_b_base;
  assign o_c_base    = cur_c_base;
  assign o_precision = cur_precision;
  assign o_start     = start_pulse;

  // FIFO head outputs for cross-GEMM prefetch
  assign o_fifo_valid    = !fifo_empty;
  assign o_fifo_dim_m    = fifo_head[15:0];
  assign o_fifo_dim_n    = fifo_head[31:16];
  assign o_fifo_dim_k    = fifo_head[47:32];
  assign o_fifo_a_base   = fifo_head[79:48];
  assign o_fifo_b_base   = fifo_head[111:80];
  assign o_fifo_c_base   = fifo_head[143:112];
  assign o_fifo_precision = fifo_head[146:144];

  // ---------------------------------------------------------------------------
  // Command FIFO (147 bits per entry)
  // ---------------------------------------------------------------------------
  localparam int CMD_W = 32 + 32 + 32 + 16 + 16 + 16 + 3;

  logic [CMD_W-1:0] fifo_mem [0:CMD_QUEUE_DEPTH-1];
  logic [$clog2(CMD_QUEUE_DEPTH):0] fifo_wr_ptr, fifo_rd_ptr;
  logic [$clog2(CMD_QUEUE_DEPTH):0] fifo_count;
  logic fifo_push, fifo_pop;
  logic [CMD_W-1:0] fifo_head;

  wire [$clog2(CMD_QUEUE_DEPTH)-1:0] fifo_wr_idx = fifo_wr_ptr[$clog2(CMD_QUEUE_DEPTH)-1:0];
  wire [$clog2(CMD_QUEUE_DEPTH)-1:0] fifo_rd_idx = fifo_rd_ptr[$clog2(CMD_QUEUE_DEPTH)-1:0];

  assign fifo_head = fifo_mem[fifo_rd_idx];
  wire   fifo_empty = (fifo_count == 0);
  wire   fifo_full  = (fifo_count == CMD_QUEUE_DEPTH);

  wire [CMD_W-1:0] cmd_snapshot = {
    precision,
    c_base, b_base, a_base,
    dim_k, dim_n, dim_m
  };

  // Initialize
  integer fi;
  initial begin
    fifo_wr_ptr = 0;
    fifo_rd_ptr = 0;
    fifo_count  = 0;
    fifo_pop    = 0;
    fifo_push   = 0;
    for (fi = 0; fi < CMD_QUEUE_DEPTH; fi = fi + 1)
      fifo_mem[fi] = '0;
  end

  // ---------------------------------------------------------------------------
  // Start detection (rising edge of CTRL.START write)
  // ---------------------------------------------------------------------------
  logic start_written;
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      start_written <= 1'b0;
    else if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid &&
             s_axi_awaddr[5:2] == ADDR_CTRL && s_axi_wstrb[0] && s_axi_wdata[0])
      start_written <= 1'b1;
    else
      start_written <= 1'b0;
  end

  wire start_requested = start_written;

  // ---------------------------------------------------------------------------
  // Dispatcher FSM
  //
  // D_IDLE:   engine idle. If FIFO non-empty, pop and dispatch from head.
  //           If FIFO empty, dispatch immediately from live CSRs.
  // D_WAIT:   engine busy — wait for done, then return to D_IDLE.
  //
  // pending_start: latches a START that arrived while D_WAIT.  Without this,
  // a rapid back-to-back START (CTA1 + CTA2 within one DMA registration
  // cycle) is lost: the dispatcher is in D_WAIT, so start_requested is
  // ignored, and the FIFO push condition fails because i_busy hasn't gone
  // high yet.  The pending_start flag ensures the FIFO push fires when the
  // engine becomes busy, and the dispatcher sees the queued command when it
  // returns to D_IDLE.
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    D_IDLE,
    D_WAIT
  } disp_state_t;

  disp_state_t disp_state;
  logic        pending_start;  // START captured while dispatcher is in D_WAIT
  logic        pending_pushed; // one-shot: set once do_push fires for pending_start
  logic        was_busy;       // DMA was busy — prevents spurious double DRAIN

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      disp_state    <= D_IDLE;
      start_pulse   <= 1'b0;
      fifo_pop      <= 1'b0;
      pending_start <= 1'b0;
      pending_pushed <= 1'b0;
      was_busy      <= 1'b0;
      cur_dim_m     <= 16'd0;
      cur_dim_n     <= 16'd0;
      cur_dim_k     <= 16'd0;
      cur_a_base    <= 32'd0;
      cur_b_base    <= 32'd0;
      cur_c_base    <= 32'd0;
      cur_precision <= 3'd0;
    end else begin
      start_pulse <= 1'b0;
      fifo_pop    <= 1'b0;

      case (disp_state)
        D_IDLE: begin
          // Check for a pending START that arrived while we were dispatching
          if (pending_start && !fifo_empty) begin
            // Previous pending_start pushed to FIFO — dispatch from head
            cur_dim_m     <= fifo_head[15:0];
            cur_dim_n     <= fifo_head[31:16];
            cur_dim_k     <= fifo_head[47:32];
            cur_a_base    <= fifo_head[79:48];
            cur_b_base    <= fifo_head[111:80];
            cur_c_base    <= fifo_head[143:112];
            cur_precision <= fifo_head[146:144];
            fifo_pop      <= 1'b1;
            pending_start  <= 1'b0;
            pending_pushed <= 1'b0;
            start_pulse    <= 1'b1;
            disp_state     <= D_WAIT;
          end else if (pending_start && fifo_empty) begin
            // Pending start but FIFO push hasn't registered yet.
            // Wait one cycle for do_push to update fifo_count.
          end else if (start_requested) begin
            if (!fifo_empty) begin
              // FIFO has queued commands — dispatch from head
              cur_dim_m     <= fifo_head[15:0];
              cur_dim_n     <= fifo_head[31:16];
              cur_dim_k     <= fifo_head[47:32];
              cur_a_base    <= fifo_head[79:48];
              cur_b_base    <= fifo_head[111:80];
              cur_c_base    <= fifo_head[143:112];
              cur_precision <= fifo_head[146:144];
              fifo_pop      <= 1'b1;
            end else begin
              // FIFO empty — dispatch directly from live CSRs (zero bubble)
              cur_dim_m     <= dim_m;
              cur_dim_n     <= dim_n;
              cur_dim_k     <= dim_k;
              cur_a_base    <= a_base;
              cur_b_base    <= b_base;
              cur_c_base    <= c_base;
              cur_precision <= precision;
            end
            start_pulse <= 1'b1;
            disp_state  <= D_WAIT;
          end else if (!fifo_empty) begin
            // FIFO drain: engine idle, no new START, but commands queued.
            // Without this branch, queued commands strand forever —
            // the grxcp team's back-to-back regression (occupancy stuck
            // at 1, STATUS=0x2, queue count corrupted on 3+ commands).
            cur_dim_m     <= fifo_head[15:0];
            cur_dim_n     <= fifo_head[31:16];
            cur_dim_k     <= fifo_head[47:32];
            cur_a_base    <= fifo_head[79:48];
            cur_b_base    <= fifo_head[111:80];
            cur_c_base    <= fifo_head[143:112];
            cur_precision <= fifo_head[146:144];
            fifo_pop      <= 1'b1;
            start_pulse   <= 1'b1;
            disp_state    <= D_WAIT;
          end
        end

        D_WAIT: begin
          if (start_requested) begin
            if (do_push) begin
              // First clause already pushed this cycle — no need for pending
              pending_start  <= 1'b0;
              pending_pushed <= 1'b1;  // mark consumed
            end else begin
              // Push couldn't fire yet (i_busy=0 edge case) — defer push
              pending_start  <= 1'b1;
              pending_pushed <= 1'b0;
            end
          end
          // Mark pending as consumed once do_push fires for it
          if (pending_start && do_push && !pending_pushed)
            pending_pushed <= 1'b1;
          // Track that DMA was actually busy — don't return to D_IDLE until
          // the DMA has consumed start_pulse and entered a non-IDLE phase.
          // Without this, the dispatcher returns to D_IDLE one cycle too
          // early (before the DMA's phase change takes effect), causing a
          // spurious second DRAIN that pops the next FIFO entry.
          // Return to D_IDLE only after DMA was busy then became idle.
          // This prevents a spurious second DRAIN before start_pulse is
          // consumed (the DMA's phase change is an NBA, so i_busy lags
          // start_pulse by one cycle).
          if (i_busy)
            was_busy <= 1'b1;
          if (!i_busy && was_busy) begin
            disp_state     <= D_IDLE;
            pending_start  <= 1'b0;
            pending_pushed <= 1'b0;
            was_busy       <= 1'b0;
          end
        end

        default: disp_state <= D_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Push/pop enable signals (combinational)
  //
  // Push fires when:
  //  (a) normal START while engine busy or FIFO non-empty, OR
  //  (b) pending_start latched while engine is still busy (the START arrived
  //      in D_WAIT before i_busy went high, so we need to push retroactively)
  wire do_push = (start_requested && !fifo_full && (i_busy || !fifo_empty)) ||
                (pending_start && !pending_pushed && !fifo_full && i_busy);
  wire do_pop  = fifo_pop && !fifo_empty;

  // ---------------------------------------------------------------------------
  // FIFO push/pop
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      fifo_wr_ptr <= 0;
      fifo_rd_ptr <= 0;
      fifo_count  <= 0;
    end else begin
      // Push: START writes snapshot to FIFO when the command cannot be
      // dispatched immediately (engine busy or FIFO non-empty), or when a
      // pending_start is waiting for the engine to go busy.
      // After the push, clear pending_start so do_push doesn't re-fire
      // every cycle (the root cause of the grxcp team's corrupted queue).
      if (do_push) begin
        fifo_mem[fifo_wr_idx] <= cmd_snapshot;
        fifo_wr_ptr <= fifo_wr_ptr + 1;
      end

      // Pop: dispatcher requested a pop
      if (fifo_pop && !fifo_empty) begin
        fifo_rd_ptr <= fifo_rd_ptr + 1;
      end

      // Count update
      if (do_push && do_pop)
        fifo_count <= fifo_count;           // push+pop cancel
      else if (do_push)
        fifo_count <= fifo_count + 1;
      else if (do_pop)
        fifo_count <= fifo_count - 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Write channel
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      dim_m         <= 16'd0;
      dim_n         <= 16'd0;
      dim_k         <= 16'd0;
      a_base        <= 32'd0;
      b_base        <= 32'd0;
      c_base        <= 32'd0;
      precision     <= 3'd0;
      done_latch    <= 1'b0;
    end else begin
      if (i_done)
        done_latch <= 1'b1;

      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;

      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;

      if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;

        case (s_axi_awaddr[5:2])
          ADDR_CTRL: begin
            if (s_axi_wstrb[0] && s_axi_wdata[0])
              done_latch <= 1'b0;
          end
          ADDR_DIM_M:  if (s_axi_wstrb[0]) dim_m <= s_axi_wdata[15:0];
          ADDR_DIM_N:  if (s_axi_wstrb[0]) dim_n <= s_axi_wdata[15:0];
          ADDR_DIM_K:  if (s_axi_wstrb[0]) dim_k <= s_axi_wdata[15:0];
          ADDR_A_BASE: if (s_axi_wstrb[0]) a_base <= s_axi_wdata;
          ADDR_B_BASE: if (s_axi_wstrb[0]) b_base <= s_axi_wdata;
          ADDR_C_BASE: if (s_axi_wstrb[0]) c_base <= s_axi_wdata;
          ADDR_PREC:   if (s_axi_wstrb[0]) precision <= s_axi_wdata[2:0];
          default: ;
        endcase

        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= 2'b00;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read channel
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= 32'd0;
      s_axi_rresp   <= 2'b00;
    end else begin
      s_axi_arready <= 1'b0;

      if (s_axi_rvalid && s_axi_rready)
        s_axi_rvalid <= 1'b0;

      if (s_axi_arvalid && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;

        case (s_axi_araddr[5:2])
          ADDR_STAT:       s_axi_rdata <= {29'd0, i_error, done_latch, i_busy};
          ADDR_DIM_M:      s_axi_rdata <= {16'd0, dim_m};
          ADDR_DIM_N:      s_axi_rdata <= {16'd0, dim_n};
          ADDR_DIM_K:      s_axi_rdata <= {16'd0, dim_k};
          ADDR_A_BASE:     s_axi_rdata <= a_base;
          ADDR_B_BASE:     s_axi_rdata <= b_base;
          ADDR_C_BASE:     s_axi_rdata <= c_base;
          ADDR_PREC:       s_axi_rdata <= {29'd0, precision};
          ADDR_CYCLE_LO:   s_axi_rdata <= i_cycle_count;
          ADDR_OP_COUNT:   s_axi_rdata <= i_op_count;
          ADDR_STALL_CT:   s_axi_rdata <= i_stall_count;
          ADDR_DMA_CT:     s_axi_rdata <= i_dma_cycle_count;
          ADDR_DMA_LAST:   s_axi_rdata <= i_dma_last_count;
          ADDR_QUEUE_STAT: s_axi_rdata <= {28'd0, fifo_full, fifo_count[$clog2(CMD_QUEUE_DEPTH):0]};
          ADDR_QUEUE_MAX:  s_axi_rdata <= {28'd0, CMD_QUEUE_DEPTH[3:0]};
          default:         s_axi_rdata <= 32'd0;
        endcase

        s_axi_rvalid <= 1'b1;
        s_axi_rresp  <= 2'b00;
      end
    end
  end

endmodule
