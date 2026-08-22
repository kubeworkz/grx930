// -----------------------------------------------------------------------------
// c930_npu_dma.sv
//
// AXI4 full master for the NPU data plane. On START it autonomously:
//
//   1. P_READ_A   : burst-read A (M*K packed INT8) from A_BASE and stream the
//                   bytes into the core's A buffer via the preload port.
//   2. P_READ_B   : burst-read B (K*N packed INT8) from B_BASE likewise.
//   3. P_LAUNCH   : pulse the core's start and wait for its done.
//   4. P_WRITE_C  : burst-write C (M*N INT32 words) to C_BASE.
//   5. P_DONE     : pulse o_done.
//
// A and B are packed little-endian, 4 INT8 per 32-bit beat, row-major:
//   A byte (m*K + k) lives at beat (m*K + k)/4, lane (m*K + k)%4.
//   B byte (k*N + n) lives at beat (k*N + n)/4, lane (k*N + n)%4.
// C is one INT32 per 32-bit beat: beat (m*N + n).
//
// Bursts are INCR with 4-byte beats. The R channel is back-pressured while a
// beat's 4 bytes are unpacked into the core (one byte per cycle), so the read
// rate is naturally throttled by the unpacking rate.
// -----------------------------------------------------------------------------
module c930_npu_dma
#(
  parameter int AXI_ADDR_W = 32,
  parameter int AXI_DATA_W = 32,
  parameter int DIN_W      = 16,
  parameter int ACC_W      = 40,
  parameter int MAX_M      = 64,
  parameter int MAX_K      = 256,
  parameter int MAX_N      = 8
)
(
  input  logic        i_clk,
  input  logic        i_rst_n,

  // ---- Control (from the CSR via the top) ----
  input  logic        i_start,
  input  logic [15:0] i_dim_m,
  input  logic [15:0] i_dim_n,
  input  logic [15:0] i_dim_k,
  input  logic [31:0] i_a_base,
  input  logic [31:0] i_b_base,
  input  logic [31:0] i_c_base,
  input  logic [1:0]  i_precision,   // 0=INT8, 1=INT16

  // ---- Status (to the CSR / top) ----
  output logic        o_busy,
  output logic        o_done,
  output logic        o_error,

  // ---- Core data plane + control ----
  output logic                    o_wen,       // preload write enable
  output logic                    o_wsel,      // 0 = A, 1 = B
  output logic [15:0]             o_waddr,
  output logic signed [DIN_W-1:0] o_wdata,
  output logic                    o_core_start,
  input  logic                    i_core_done,
  input  logic                    i_core_error,
  output logic [15:0]             o_c_raddr,
  input  logic signed [ACC_W-1:0] i_c_rdata,

  // ---- AXI4 master: read address ----
  output logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,

  // ---- AXI4 master: read data ----
  input  logic [AXI_DATA_W-1:0] m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready,

  // ---- AXI4 master: write address ----
  output logic [AXI_ADDR_W-1:0] m_axi_awaddr,
  output logic [7:0]            m_axi_awlen,
  output logic [2:0]            m_axi_awsize,
  output logic [1:0]            m_axi_awburst,
  output logic                  m_axi_awvalid,
  input  logic                  m_axi_awready,

  // ---- AXI4 master: write data ----
  output logic [AXI_DATA_W-1:0] m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
  output logic                  m_axi_wlast,
  output logic                  m_axi_wvalid,
  input  logic                  m_axi_wready,

  // ---- AXI4 master: write response ----
  input  logic [1:0]            m_axi_bresp,
  input  logic                  m_axi_bvalid,
  output logic                  m_axi_bready
);

  localparam int BYTES_PER_BEAT = AXI_DATA_W / 8;   // 4
  localparam [2:0] BEAT_SIZE    = $clog2(BYTES_PER_BEAT);  // 2 -> 4 bytes/beat

  // Precision-dependent element size: INT8=1 byte, INT16=2 bytes
  logic [1:0] elem_size;   // 1 for INT8, 2 for INT16
  int  elems_per_beat;     // 4 for INT8, 2 for INT16

  // ---- Phases ----
  localparam [2:0] P_IDLE    = 3'd0;
  localparam [2:0] P_READ_A  = 3'd1;
  localparam [2:0] P_READ_B  = 3'd2;
  localparam [2:0] P_LAUNCH  = 3'd3;
  localparam [2:0] P_WRITE_C = 3'd4;
  localparam [2:0] P_DONE    = 3'd5;

  // ---- Read sub-states ----
  localparam [1:0] RS_AR     = 2'd0;
  localparam [1:0] RS_R      = 2'd1;
  localparam [1:0] RS_UNPACK = 2'd2;

  // ---- Write sub-states (3 bits: five states) ----
  localparam [2:0] WS_AW    = 3'd0;
  localparam [2:0] WS_ADDR  = 3'd1;
  localparam [2:0] WS_DATA  = 3'd2;
  localparam [2:0] WS_DRIVE = 3'd3;
  localparam [2:0] WS_B     = 3'd4;

  logic [2:0] phase;
  logic [1:0] rd_sub;
  logic [2:0] wr_sub;

  logic [15:0] dm, dn, dk;
  logic [31:0] a_base_r, b_base_r, c_base_r;

  int  elem_cnt;      // bytes (A/B read) or words (C write) this phase
  int  rd_beats;      // ceil(elem_cnt / BYTES_PER_BEAT) for reads
  int  rd_beat;       // read beats received so far
  int  flat_idx;      // flat byte index into the A/B buffer
  int  unpack_idx;    // 0..BYTES_PER_BEAT-1 within the current beat
  int  c_idx;         // C element index (also C beat index)
  logic [AXI_DATA_W-1:0] rword;
  logic [AXI_DATA_W-1:0] wdata_reg;
  logic wsel_reg;     // 0 = reading A, 1 = reading B
  logic launched;

  logic dims_ok;
  assign dims_ok = (i_dim_m >= 1) && (i_dim_m <= MAX_M) &&
                   (i_dim_n >= 1) && (i_dim_n <= MAX_N) &&
                   (i_dim_k >= 1) && (i_dim_k <= MAX_K);

  assign o_busy = (phase != P_IDLE);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      phase         <= P_IDLE;
      rd_sub        <= RS_AR;
      wr_sub        <= WS_AW;
      o_done        <= 1'b0;
      o_error       <= 1'b0;
      o_wen         <= 1'b0;
      o_core_start  <= 1'b0;
      launched      <= 1'b0;
      m_axi_arvalid <= 1'b0;
      m_axi_rready  <= 1'b0;
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid  <= 1'b0;
      m_axi_bready  <= 1'b0;
      m_axi_arlen   <= 8'd0;
      m_axi_awlen   <= 8'd0;
      m_axi_arsize  <= 3'd0;
      m_axi_arburst <= 2'b00;
      m_axi_awsize  <= 3'd0;
      m_axi_awburst <= 2'b00;
    end else begin
      // Per-cycle defaults
      o_done        <= 1'b0;
      o_wen         <= 1'b0;
      o_core_start  <= 1'b0;
      m_axi_arvalid <= 1'b0;
      m_axi_rready  <= 1'b0;
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid  <= 1'b0;
      m_axi_bready  <= 1'b0;

      case (phase)

        // ---------------------------------------------------------------------
        P_IDLE: begin
          if (i_start) begin
            if (!dims_ok) begin
              o_error <= 1'b1;
            end else begin
              o_error  <= 1'b0;
              dm       <= i_dim_m;
              dn       <= i_dim_n;
              dk       <= i_dim_k;
              a_base_r <= i_a_base;
              b_base_r <= i_b_base;
              c_base_r <= i_c_base;
              elem_size    <= (i_precision == 2'd0) ? 2'd1 : 2'd2;
              elems_per_beat <= (i_precision == 2'd0) ? 4 : 2;
              elem_cnt   <= i_dim_m * i_dim_k * ((i_precision == 2'd0) ? 1 : 2);  // A bytes
              rd_beats   <= (i_dim_m * i_dim_k * ((i_precision == 2'd0) ? 1 : 2) + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
              rd_beat    <= 0;
              flat_idx   <= 0;
              unpack_idx <= 0;
              wsel_reg   <= 1'b0;                           // A first
              rd_sub     <= RS_AR;
              phase      <= P_READ_A;
            end
          end
        end

        // ---------------------------------------------------------------------
        // Shared A/B burst read: one INCR burst, unpack 4 bytes per beat.
        // ---------------------------------------------------------------------
        P_READ_A, P_READ_B: begin
          case (rd_sub)
            RS_AR: begin
              if (m_axi_arvalid && m_axi_arready) begin
                rd_sub       <= RS_R;
                m_axi_rready <= 1'b1;
              end else begin
                m_axi_arvalid <= 1'b1;
                m_axi_arlen   <= rd_beats - 1;   // <= 31, int -> 8-bit truncates cleanly
                m_axi_arsize  <= BEAT_SIZE;
                m_axi_arburst <= 2'b01;           // INCR
                m_axi_araddr  <= wsel_reg ? b_base_r : a_base_r;
              end
            end

            RS_R: begin
              if (m_axi_rvalid && m_axi_rready) begin
                rword       <= m_axi_rdata;
                rd_beat     <= rd_beat + 1;
                unpack_idx  <= 0;
                rd_sub      <= RS_UNPACK;
              end else begin
                m_axi_rready <= 1'b1;
              end
            end

            RS_UNPACK: begin
              o_wen   <= 1'b1;
              o_wsel  <= wsel_reg;
              o_waddr <= flat_idx[15:0];
              // INT8: sign-extend 8→16 bits; INT16: direct 16-bit
              if (elem_size == 2'd1)
                o_wdata <= {{8{rword[unpack_idx*8+7]}}, rword[unpack_idx*8 +: 8]};
              else
                o_wdata <= rword[unpack_idx*16 +: 16];
              flat_idx   <= flat_idx + 1;
              unpack_idx <= unpack_idx + 1;
              if (unpack_idx == elems_per_beat - 1) begin
                // last byte of this beat
                if (rd_beat == rd_beats) begin
                  if (wsel_reg) begin
                    // B fully loaded -> launch the core
                    phase  <= P_LAUNCH;
                    rd_sub <= RS_AR;
                  end else begin
                    // A loaded -> move on to B
                    elem_cnt   <= dn * dk * elem_size;
                    rd_beats   <= (dn * dk * elem_size + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;
                    rd_beat    <= 0;
                    flat_idx   <= 0;
                    unpack_idx <= 0;
                    wsel_reg   <= 1'b1;
                    rd_sub     <= RS_AR;
                    phase      <= P_READ_B;
                  end
                end else begin
                  // more beats to unpack
                  rd_sub       <= RS_R;
                  m_axi_rready <= 1'b1;
                end
              end
            end
          endcase
        end

        // ---------------------------------------------------------------------
        P_LAUNCH: begin
          if (!launched) begin
            o_core_start <= 1'b1;
            launched     <= 1'b1;
          end else if (i_core_done) begin
            launched <= 1'b0;
            if (i_core_error) begin
              o_error <= 1'b1;
              phase   <= P_DONE;
            end else begin
              c_idx  <= 0;
              wr_sub <= WS_AW;
              phase  <= P_WRITE_C;
            end
          end
        end

        // ---------------------------------------------------------------------
        P_WRITE_C: begin
          case (wr_sub)
            WS_AW: begin
              if (m_axi_awvalid && m_axi_awready) begin
                c_idx  <= 0;
                wr_sub <= WS_ADDR;
              end else begin
                m_axi_awvalid <= 1'b1;
                m_axi_awlen   <= dn * dm - 1;    // <= 95, int -> 8-bit truncates cleanly
                m_axi_awsize  <= BEAT_SIZE;
                m_axi_awburst <= 2'b01;           // INCR
                m_axi_awaddr  <= c_base_r;
              end
            end

            WS_ADDR: begin
              o_c_raddr <= c_idx[15:0];
              wr_sub    <= WS_DATA;
            end

            WS_DATA: begin
              wdata_reg <= i_c_rdata;                       // latches c_mem[c_idx]
              wr_sub    <= WS_DRIVE;
            end

            WS_DRIVE: begin
              if (m_axi_wvalid && m_axi_wready) begin
                if (c_idx == dn * dm - 1) begin
                  wr_sub       <= WS_B;
                  m_axi_bready <= 1'b1;
                end else begin
                  c_idx  <= c_idx + 1;
                  wr_sub <= WS_ADDR;
                end
              end else begin
                m_axi_wvalid <= 1'b1;
                m_axi_wdata  <= wdata_reg;
                m_axi_wstrb  <= {BYTES_PER_BEAT{1'b1}};
                m_axi_wlast  <= (c_idx == dn * dm - 1);
              end
            end

            WS_B: begin
              if (m_axi_bvalid && m_axi_bready)
                phase <= P_DONE;
              else
                m_axi_bready <= 1'b1;
            end
          endcase
        end

        // ---------------------------------------------------------------------
        P_DONE: begin
          o_done <= 1'b1;
          phase  <= P_IDLE;
        end

        default: phase <= P_IDLE;
      endcase
    end
  end

endmodule
