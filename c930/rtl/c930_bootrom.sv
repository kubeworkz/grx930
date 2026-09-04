// -----------------------------------------------------------------------------
// c930_bootrom.sv
//
// 1 KB read-only Boot ROM. AXI4 full slave interface (read channel only).
// Initialized from a hex file at synthesis time.
//
// Address space: 0x0000_0000 – 0x0000_03FF (1024 bytes)
// Data width: 64 bits (8 bytes per beat, 128 beats for full ROM)
// Burst: INCR, configurable length
//
// Write requests are accepted but ignored (returns OKAY with no data effect).
// Read requests return data from the ROM array.
// -----------------------------------------------------------------------------
module c930_bootrom
#(
  parameter int MEM_DEPTH  = 128,           // 1024 bytes / 8 bytes per beat = 128 entries
  parameter int DATA_WIDTH = 64,
  parameter int ADDR_WIDTH = 64,
  parameter int ID_WIDTH   = 4,
  parameter HEX_FILE = "boot.hex"             // path to $readmemh file
)
(
  input  logic i_clk,
  input  logic i_rst_n,

  // ---- AXI4 full slave (read-only) ----
  input  logic [ID_WIDTH-1:0]    s_axi_awid,
  input  logic [ADDR_WIDTH-1:0]  s_axi_awaddr,
  input  logic [7:0]             s_axi_awlen,
  input  logic [2:0]             s_axi_awsize,
  input  logic [1:0]             s_axi_awburst,
  input  logic                   s_axi_awvalid,
  output logic                   s_axi_awready,

  input  logic [DATA_WIDTH-1:0]  s_axi_wdata,
  input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  logic                   s_axi_wlast,
  input  logic                   s_axi_wvalid,
  output logic                   s_axi_wready,

  output logic [ID_WIDTH-1:0]    s_axi_bid,
  output logic [1:0]             s_axi_bresp,
  output logic                   s_axi_bvalid,
  input  logic                   s_axi_bready,

  input  logic [ID_WIDTH-1:0]    s_axi_arid,
  input  logic [ADDR_WIDTH-1:0]  s_axi_araddr,
  input  logic [7:0]             s_axi_arlen,
  input  logic [2:0]             s_axi_arsize,
  input  logic [1:0]             s_axi_arburst,
  input  logic                   s_axi_arvalid,
  output logic                   s_axi_arready,

  output logic [ID_WIDTH-1:0]    s_axi_rid,
  output logic [DATA_WIDTH-1:0]  s_axi_rdata,
  output logic [1:0]             s_axi_rresp,
  output logic                   s_axi_rlast,
  output logic                   s_axi_rvalid,
  input  logic                   s_axi_rready
);

  // ROM storage
  logic [DATA_WIDTH-1:0] rom [0:MEM_DEPTH-1];

  // Initialize from hex file
  initial begin
    for (int i = 0; i < MEM_DEPTH; i++)
      rom[i] = '0;
    // Only load if a real hex file is provided (not empty or placeholder)
    // Icarus crashes on $readmemh("")
    $readmemh(HEX_FILE, rom);
  end

  // =========================================================================
  // Write channel: accept and ignore (read-only ROM)
  // =========================================================================
  assign s_axi_awready = 1'b1;  // always accept
  assign s_axi_wready  = 1'b1;  // always accept
  assign s_axi_bid     = s_axi_awid;
  assign s_axi_bresp   = 2'b00;  // OKAY
  assign s_axi_bvalid  = s_axi_awvalid && s_axi_wvalid;  // pair AW+W

  // =========================================================================
  // Read channel: burst read from ROM
  // =========================================================================
  typedef enum logic [1:0] {
    R_IDLE   = 2'd0,
    R_ACTIVE = 2'd1
  } r_state_t;

  r_state_t r_state;
  logic [ID_WIDTH-1:0]   r_id;
  logic [ADDR_WIDTH-1:0] r_addr;
  logic [7:0]            r_len;
  logic [7:0]            r_beat;
  logic [$clog2(MEM_DEPTH)-1:0] r_idx;

  assign s_axi_arready = (r_state == R_IDLE);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      r_state    <= R_IDLE;
      r_id       <= '0;
      r_addr     <= '0;
      r_len      <= '0;
      r_beat     <= '0;
      r_idx      <= '0;
      s_axi_rvalid <= 1'b0;
      s_axi_rlast  <= 1'b0;
      s_axi_rresp  <= 2'b00;
      s_axi_rdata  <= '0;
      s_axi_rid    <= '0;
    end else begin
      case (r_state)
        R_IDLE: begin
          s_axi_rvalid <= 1'b0;
          s_axi_rlast  <= 1'b0;
          if (s_axi_arvalid && s_axi_arready) begin
            r_id   <= s_axi_arid;
            r_addr <= s_axi_araddr;
            r_len  <= s_axi_arlen;
            r_beat <= 8'd0;
            // Compute starting index: addr[LOG2(MEM_DEPTH*8)-1:3] for 64-bit beats
            r_idx  <= s_axi_araddr[$clog2(MEM_DEPTH*8)-1:3];
            r_state <= R_ACTIVE;
          end
        end

        R_ACTIVE: begin
          // Drive current beat data
          s_axi_rvalid <= 1'b1;
          s_axi_rdata  <= rom[r_idx];
          s_axi_rid    <= r_id;
          s_axi_rresp  <= 2'b00;  // OKAY
          s_axi_rlast  <= (r_beat == r_len);

          if (s_axi_rvalid && s_axi_rready) begin
            if (r_beat == r_len) begin
              // Transaction complete
              s_axi_rvalid <= 1'b0;
              s_axi_rlast  <= 1'b0;
              r_state      <= R_IDLE;
            end else begin
              r_beat <= r_beat + 1;
              r_idx  <= r_idx + 1;
            end
          end
        end

        default: r_state <= R_IDLE;
      endcase
    end
  end

endmodule
