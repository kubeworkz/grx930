// -----------------------------------------------------------------------------
// c930_uart.sv
//
// Minimal 16550-compatible UART with AXI4-Lite slave interface.
// Provides printf-style debug output for the GRX930 SoC.
//
// Register map (offsets from base address):
//   0x00 TX_DATA   (W)  Write byte to transmit
//   0x04 RX_DATA   (R)  Read byte received
//   0x08 STATUS    (R)  Bit 0: TX full, Bit 1: RX empty, Bit 2: TX done
//   0x0C CTRL      (R/W) Bit 15:0 = baud divisor (default: core_clk/115200)
//   0x10 IRQ_EN    (R/W) Bit 0: TX done IRQ, Bit 1: RX data available IRQ
//
// TX path: CPU writes TX_DATA → TX FIFO (64 bytes) → shift register → TX pin
// RX path: RX pin → shift register → RX FIFO (64 bytes) → CPU reads RX_DATA
//
// Baud rate = core_clk / (CTRL[15:0] + 1) / 16
// Default: 100 MHz / 868 / 16 ≈ 72.0 Hz (actually 115200 baud with 868 divisor)
// -----------------------------------------------------------------------------
module c930_uart
#(
  parameter int CLK_FREQ   = 100_000_000,  // core clock frequency (Hz)
  parameter int BAUD_RATE  = 115200,
  parameter int FIFO_DEPTH = 64
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- UART pins ----
  output logic o_uart_txd,
  input  logic i_uart_rxd,

  // ---- Interrupt output ----
  output logic o_irq,

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
  input  logic        s_axi_rready
);

  // =========================================================================
  // Register map
  // =========================================================================
  localparam [4:0] ADDR_TX_DATA = 5'h00;
  localparam [4:0] ADDR_RX_DATA = 5'h04;
  localparam [4:0] ADDR_STATUS  = 5'h08;
  localparam [4:0] ADDR_CTRL    = 5'h0C;
  localparam [4:0] ADDR_IRQ_EN  = 5'h10;

  // =========================================================================
  // Baud rate generator
  // =========================================================================
  localparam int DEFAULT_DIVISOR = CLK_FREQ / (BAUD_RATE * 16) - 1;

  logic [15:0] baud_divisor;
  logic [15:0] baud_cnt;
  logic        baud_tick;

  assign baud_tick = (baud_cnt == 0);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      baud_cnt     <= DEFAULT_DIVISOR[15:0];
      baud_divisor <= DEFAULT_DIVISOR[15:0];
    end else begin
      if (baud_cnt == 0)
        baud_cnt <= baud_divisor;
      else
        baud_cnt <= baud_cnt - 1;
    end
  end

  // =========================================================================
  // TX path: FIFO → shift register → o_uart_txd
  // =========================================================================
  localparam int FIFO_AW = $clog2(FIFO_DEPTH);

  logic [7:0]  tx_fifo_mem [0:FIFO_DEPTH-1];
  logic [FIFO_AW:0] tx_fifo_wr_ptr, tx_fifo_rd_ptr;
  logic        tx_fifo_full, tx_fifo_empty;
  logic [7:0]  tx_fifo_wdata, tx_fifo_rdata;
  logic        tx_fifo_we, tx_fifo_re;

  assign tx_fifo_full  = (tx_fifo_wr_ptr[FIFO_AW] != tx_fifo_rd_ptr[FIFO_AW]) &&
                         (tx_fifo_wr_ptr[FIFO_AW-1:0] == tx_fifo_rd_ptr[FIFO_AW-1:0]);
  assign tx_fifo_empty = (tx_fifo_wr_ptr == tx_fifo_rd_ptr);
  assign tx_fifo_rdata = tx_fifo_mem[tx_fifo_rd_ptr[FIFO_AW-1:0]];

  always_ff @(posedge i_clk) begin
    if (tx_fifo_we)
      tx_fifo_mem[tx_fifo_wr_ptr[FIFO_AW-1:0]] <= tx_fifo_wdata;
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      tx_fifo_wr_ptr <= '0;
      tx_fifo_rd_ptr <= '0;
    end else begin
      if (tx_fifo_we && !tx_fifo_full)
        tx_fifo_wr_ptr <= tx_fifo_wr_ptr + 1;
      if (tx_fifo_re && !tx_fifo_empty)
        tx_fifo_rd_ptr <= tx_fifo_rd_ptr + 1;
    end
  end

  // TX shift register
  typedef enum logic [1:0] {
    TX_IDLE   = 2'd0,
    TX_START  = 2'd1,
    TX_DATA   = 2'd2,
    TX_STOP   = 2'd3
  } tx_state_t;

  tx_state_t tx_state;
  logic [3:0]  tx_bit_cnt;
  logic [7:0]  tx_shift_reg;
  logic        tx_done;
  logic [3:0]  tx_baud_cnt;
  logic        tx_pop_req;  // TX state machine requests FIFO pop

  assign tx_pop_req = (tx_state == TX_IDLE) && !tx_fifo_empty;
  assign tx_done = (tx_state == TX_STOP) && (tx_baud_cnt == 4'd15);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      tx_state    <= TX_IDLE;
      tx_bit_cnt  <= '0;
      tx_shift_reg <= '0;
      o_uart_txd  <= 1'b1;  // idle high
      tx_baud_cnt <= '0;
    end else if (baud_tick) begin
      case (tx_state)
        TX_IDLE: begin
          o_uart_txd <= 1'b1;
          if (!tx_fifo_empty) begin
            tx_shift_reg <= tx_fifo_rdata;
            tx_state     <= TX_START;
            tx_baud_cnt  <= '0;
          end
        end
        TX_START: begin
          o_uart_txd <= 1'b0;  // start bit
          tx_baud_cnt <= tx_baud_cnt + 1;
          if (tx_baud_cnt == 4'd15) begin
            tx_state   <= TX_DATA;
            tx_bit_cnt <= 4'd0;
            tx_baud_cnt <= '0;
          end
        end
        TX_DATA: begin
          o_uart_txd <= tx_shift_reg[tx_bit_cnt];
          tx_baud_cnt <= tx_baud_cnt + 1;
          if (tx_baud_cnt == 4'd15) begin
            tx_baud_cnt <= '0;
            if (tx_bit_cnt == 4'd7) begin
              tx_state <= TX_STOP;
            end else begin
              tx_bit_cnt <= tx_bit_cnt + 1;
            end
          end
        end
        TX_STOP: begin
          o_uart_txd <= 1'b1;  // stop bit
          tx_baud_cnt <= tx_baud_cnt + 1;
          if (tx_baud_cnt == 4'd15) begin
            tx_state <= TX_IDLE;
          end
        end
        default: tx_state <= TX_IDLE;
      endcase
    end
  end

  // =========================================================================
  // RX path: i_uart_rxd → shift register → FIFO
  // =========================================================================
  logic [7:0]  rx_fifo_mem [0:FIFO_DEPTH-1];
  logic [FIFO_AW:0] rx_fifo_wr_ptr, rx_fifo_rd_ptr;
  logic        rx_fifo_full, rx_fifo_empty;
  logic [7:0]  rx_fifo_wdata, rx_fifo_rdata;
  logic        rx_fifo_we, rx_fifo_re;

  assign rx_fifo_full  = (rx_fifo_wr_ptr[FIFO_AW] != rx_fifo_rd_ptr[FIFO_AW]) &&
                         (rx_fifo_wr_ptr[FIFO_AW-1:0] == rx_fifo_rd_ptr[FIFO_AW-1:0]);
  assign rx_fifo_empty = (rx_fifo_wr_ptr == rx_fifo_rd_ptr);
  assign rx_fifo_rdata = rx_fifo_mem[rx_fifo_rd_ptr[FIFO_AW-1:0]];

  always_ff @(posedge i_clk) begin
    if (rx_fifo_we)
      rx_fifo_mem[rx_fifo_wr_ptr[FIFO_AW-1:0]] <= rx_fifo_wdata;
  end

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rx_fifo_wr_ptr <= '0;
      rx_fifo_rd_ptr <= '0;
    end else begin
      if (rx_fifo_we && !rx_fifo_full)
        rx_fifo_wr_ptr <= rx_fifo_wr_ptr + 1;
      if (rx_fifo_re && !rx_fifo_empty)
        rx_fifo_rd_ptr <= rx_fifo_rd_ptr + 1;
    end
  end

  // RX shift register
  typedef enum logic [1:0] {
    RX_IDLE  = 2'd0,
    RX_START = 2'd1,
    RX_DATA  = 2'd2,
    RX_STOP  = 2'd3
  } rx_state_t;

  rx_state_t rx_state;
  logic [3:0]  rx_bit_cnt;
  logic [7:0]  rx_shift_reg;
  logic [3:0]  rx_baud_cnt;
  logic        rx_done;
  logic [2:0]  rx_sync;  // 3-stage synchronizer for async RX pin

  // Synchronize async RX input
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
      rx_sync <= 3'b111;
    else
      rx_sync <= {rx_sync[1:0], i_uart_rxd};
  end

  wire rx_pin = rx_sync[2];  // synchronized RX

  assign rx_done = (rx_state == RX_STOP) && (rx_baud_cnt == 4'd8);  // sample mid-stop

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      rx_state     <= RX_IDLE;
      rx_bit_cnt   <= '0;
      rx_shift_reg <= '0;
      rx_baud_cnt  <= '0;
      rx_fifo_we   <= 1'b0;
      rx_fifo_wdata <= '0;
    end else if (baud_tick) begin
      rx_fifo_we <= 1'b0;  // default: no write
      case (rx_state)
        RX_IDLE: begin
          if (rx_pin == 1'b0) begin  // start bit detected
            rx_state    <= RX_START;
            rx_baud_cnt <= '0;
          end
        end
        RX_START: begin
          rx_baud_cnt <= rx_baud_cnt + 1;
          if (rx_baud_cnt == 4'd7) begin  // sample mid-start bit
            if (rx_pin == 1'b0) begin  // confirmed start bit
              rx_state   <= RX_DATA;
              rx_bit_cnt <= 4'd0;
              rx_baud_cnt <= '0;
            end else begin
              rx_state <= RX_IDLE;  // false start
            end
          end
        end
        RX_DATA: begin
          rx_baud_cnt <= rx_baud_cnt + 1;
          if (rx_baud_cnt == 4'd15) begin
            rx_baud_cnt <= '0;
            rx_shift_reg[rx_bit_cnt] <= rx_pin;
            if (rx_bit_cnt == 4'd7) begin
              rx_state <= RX_STOP;
            end else begin
              rx_bit_cnt <= rx_bit_cnt + 1;
            end
          end
        end
        RX_STOP: begin
          rx_baud_cnt <= rx_baud_cnt + 1;
          if (rx_baud_cnt == 4'd7) begin  // sample mid-stop bit
            if (rx_pin == 1'b1) begin  // valid stop bit
              rx_fifo_we   <= 1'b1;
              rx_fifo_wdata <= rx_shift_reg;
            end
            rx_state <= RX_IDLE;
          end
        end
        default: rx_state <= RX_IDLE;
      endcase
    end
  end

  // =========================================================================
  // Interrupt logic
  // =========================================================================
  logic irq_tx_done_en, irq_rx_data_en;
  logic irq_tx_done_pending, irq_rx_data_pending;

  assign irq_tx_done_pending = tx_done && irq_tx_done_en;
  assign irq_rx_data_pending = !rx_fifo_empty && irq_rx_data_en;
  assign o_irq = irq_tx_done_pending || irq_rx_data_pending;

  // =========================================================================
  // AXI4-Lite slave (CSR access)
  // =========================================================================
  typedef enum logic [1:0] {
    AXI_IDLE = 2'd0,
    AXI_WR   = 2'd1,
    AXI_RD   = 2'd2
  } axi_state_t;

  axi_state_t axi_state;
  logic [4:0] axi_addr_r;

  assign s_axi_awready = (axi_state == AXI_IDLE);
  assign s_axi_arready = (axi_state == AXI_IDLE) && !s_axi_awvalid;
  assign s_axi_wready  = (axi_state == AXI_WR);
  assign s_axi_rready  = (axi_state == AXI_RD);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      axi_state    <= AXI_IDLE;
      axi_addr_r   <= '0;
      s_axi_bresp  <= 2'b00;
      s_axi_bvalid <= 1'b0;
      s_axi_rresp  <= 2'b00;
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
      tx_fifo_we   <= 1'b0;
      tx_fifo_wdata <= '0;
      tx_fifo_re   <= 1'b0;
      rx_fifo_re   <= 1'b0;
      baud_divisor <= DEFAULT_DIVISOR[15:0];
      irq_tx_done_en <= 1'b0;
      irq_rx_data_en <= 1'b0;
    end else begin
      // Defaults
      s_axi_bvalid <= 1'b0;
      s_axi_rvalid <= 1'b0;
      tx_fifo_we   <= 1'b0;
      tx_fifo_re   <= tx_pop_req;  // TX state machine controls FIFO pop
      rx_fifo_re   <= 1'b0;

      case (axi_state)
        AXI_IDLE: begin
          if (s_axi_awvalid) begin
            axi_addr_r <= s_axi_awaddr[4:0];
            axi_state  <= AXI_WR;
          end else if (s_axi_arvalid) begin
            axi_addr_r <= s_axi_araddr[4:0];
            axi_state  <= AXI_RD;
          end
        end

        AXI_WR: begin
          if (s_axi_wvalid) begin
            s_axi_bvalid <= 1'b1;
            s_axi_bresp  <= 2'b00;
            axi_state    <= AXI_IDLE;

            case (axi_addr_r)
              ADDR_TX_DATA: begin
                if (!tx_fifo_full) begin
                  tx_fifo_we    <= 1'b1;
                  tx_fifo_wdata <= s_axi_wdata[7:0];
                end
              end
              ADDR_CTRL: begin
                if (s_axi_wstrb[0]) baud_divisor[7:0]  <= s_axi_wdata[7:0];
                if (s_axi_wstrb[1]) baud_divisor[15:8] <= s_axi_wdata[15:8];
              end
              ADDR_IRQ_EN: begin
                irq_tx_done_en <= s_axi_wdata[0];
                irq_rx_data_en <= s_axi_wdata[1];
              end
              default: ;  // ignore writes to other addresses
            endcase
          end
        end

        AXI_RD: begin
          s_axi_rvalid <= 1'b1;
          s_axi_rresp  <= 2'b00;
          axi_state    <= AXI_IDLE;

          case (axi_addr_r)
            ADDR_TX_DATA: s_axi_rdata <= '0;  // write-only register
            ADDR_RX_DATA: begin
              s_axi_rdata <= {24'd0, rx_fifo_rdata};
              rx_fifo_re  <= !rx_fifo_empty;
            end
            ADDR_STATUS: s_axi_rdata <= {29'd0, tx_done, rx_fifo_empty, tx_fifo_full};
            ADDR_CTRL:   s_axi_rdata <= {16'd0, baud_divisor};
            ADDR_IRQ_EN: s_axi_rdata <= {30'd0, irq_rx_data_en, irq_tx_done_en};
            default:     s_axi_rdata <= '0;
          endcase
        end

        default: axi_state <= AXI_IDLE;
      endcase
    end
  end

endmodule
