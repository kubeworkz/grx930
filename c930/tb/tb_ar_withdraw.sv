// tb_ar_withdraw.sv -- directed regression for the abandoned-AR fixes.
//
// The NPU DMA can withdraw arvalid before a slave accepts it (its phase
// advances past P_WRITE_C while a prefetch AR is still presented).  AXI
// permits withdrawal before acceptance, and both the DMA arbiter
// (c930_axi_dma_arb) and the crossbar (c930_axi_crossbar) now abandon the
// pending grant instead of stranding the read channel in a granted-but-idle
// state that blocks every other master.
//
// This bench locks that behavior in:
//   Part A (crossbar):  for EVERY master m0..m3 --
//     A1. issue an AR with the DDR slave holding arready=0 (no accept)
//     A2. confirm the crossbar granted (R_GRANTED, r_grant==m) and is NOT
//         presenting a false accept (mX_arready stays 0)
//     A3. withdraw arvalid -> crossbar must return to R_IDLE with
//         r_ar_accepted==0
//     A4. recovery: a full read from the same master must then complete
//         (burst beats + rlast, channel idle again)
//     A5. fairness: the next round-robin master's read must also complete
//   Part B (DMA arbiter): same flow for every arbiter master --
//     B1..B3. issue -> rd_addr_phase==1 with owner==m -> withdraw ->
//             rd_addr_phase must clear
//     B4. recovery read from the same master completes
//     B5. next round-robin master's read completes
//   Part C (crossbar write channel): for EVERY master m0..m3 --
//     C1. issue a 3-beat AW with the slave holding awready=0 (no accept);
//         only the first W beat is presented (partial data in flight)
//     C2. confirm the crossbar granted (W_GRANTED, w_grant==m) and is NOT
//         presenting a false accept (mX_awready stays 0)
//     C3. withdraw awvalid + W -> crossbar must return to W_IDLE with the
//         AW never accepted and no W beats taken
//     C4. recovery: a full 3-beat burst from the same master must complete
//         (all beats + B response, channel idle again)
//     C5. fairness: the next round-robin master's 2-beat write completes
//   Part D (DMA arbiter write channel): same flow for every arbiter master --
//     D1..D3. issue -> wr_addr_phase==1 with owner==m -> withdraw ->
//             wr_addr_phase must clear (AW never accepted, no W taken)
//     D4. recovery 3-beat burst from the same master completes
//     D5. next round-robin master's 2-beat write completes
//
// Timeout discipline: the condition waits use bare `wait` statements; a
// global watchdog kills the bench if any sub-test deadlocks.
//
`timescale 1ns/1ps

module t_axi_r_slave #(
  parameter int ADDR_W = 64,
  parameter int DATA_W = 64,
  parameter int ID_W   = 4
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                hold,      // 1: refuse AR acceptance
  input  logic [ID_W-1:0]     s_arid,
  input  logic [ADDR_W-1:0]   s_araddr,
  input  logic [7:0]          s_arlen,
  input  logic [2:0]          s_arsize,
  input  logic [1:0]          s_arburst,
  input  logic                s_arvalid,
  output logic                s_arready,
  output logic [ID_W-1:0]     s_rid,
  output logic [DATA_W-1:0]   s_rdata,
  output logic [1:0]          s_rresp,
  output logic                s_rlast,
  output logic                s_rvalid,
  input  logic                s_rready,
  output logic                busy
);
  typedef enum logic [1:0] { S_IDLE = 0, S_LAT = 1, S_DATA = 2 } st_t;
  st_t  st;
  logic [7:0]  lat_len;
  logic [7:0]  beat_cnt;
  logic [1:0]  lat_cnt;

  assign s_arready = (st == S_IDLE) && !hold;
  assign s_rid     = s_arid;
  assign s_rresp   = 2'b00;
  assign busy      = (st != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= S_IDLE;
      lat_len   <= '0;
      beat_cnt  <= '0;
      lat_cnt   <= '0;
      s_rvalid  <= 1'b0;
      s_rlast   <= 1'b0;
      s_rdata   <= '0;
    end else begin
      case (st)
        S_IDLE: begin
          s_rvalid <= 1'b0;
          s_rlast  <= 1'b0;
          if (s_arvalid && s_arready) begin
            lat_len  <= s_arlen;
            beat_cnt <= '0;
            lat_cnt  <= 2'd2;          // fixed 2-cycle read latency
            st       <= S_LAT;
          end
        end
        S_LAT: begin
          if (lat_cnt == 2'd0) begin
            s_rvalid <= 1'b1;
            s_rdata  <= s_araddr;
            s_rlast  <= (lat_len == 8'd0);
            st       <= S_DATA;
          end else
            lat_cnt <= lat_cnt - 1;
        end
        S_DATA: begin
          if (s_rvalid && s_rready) begin
            if (beat_cnt == lat_len) begin
              s_rvalid <= 1'b0;
              s_rlast  <= 1'b0;
              st       <= S_IDLE;
            end else begin
              beat_cnt <= beat_cnt + 1;
              s_rdata  <= s_araddr + beat_cnt + 1;
              s_rlast  <= (beat_cnt + 1 == lat_len);
            end
          end
        end
      endcase
    end
  end
endmodule

// =============================================================================

module t_axi_w_slave #(
  parameter int ADDR_W = 64,
  parameter int DATA_W = 64,
  parameter int ID_W   = 4
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                hold,      // 1: refuse AW acceptance
  input  logic [ID_W-1:0]     s_awid,
  input  logic [ADDR_W-1:0]   s_awaddr,
  input  logic [7:0]          s_awlen,
  input  logic [2:0]          s_awsize,
  input  logic [1:0]          s_awburst,
  input  logic                s_awvalid,
  output logic                s_awready,
  input  logic [DATA_W-1:0]   s_wdata,
  input  logic [DATA_W/8-1:0] s_wstrb,
  input  logic                s_wlast,
  input  logic                s_wvalid,
  output logic                s_wready,
  output logic [ID_W-1:0]     s_bid,
  output logic [1:0]          s_bresp,
  output logic                s_bvalid,
  input  logic                s_bready,
  output logic                busy,
  output logic [31:0]         aw_cnt,   // AWs accepted (never-accepted checks)
  output logic [31:0]         w_cnt     // W beats accepted (burst-length checks)
);
  typedef enum logic [1:0] { S_IDLE = 0, S_DATA = 1, S_BRESP = 2 } st_t;
  st_t  st;
  logic [ID_W-1:0] bid_reg;

  assign s_awready = (st == S_IDLE) && !hold;
  assign s_wready  = (st == S_DATA);
  assign s_bid     = bid_reg;
  assign s_bresp   = 2'b00;
  assign busy      = (st != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= S_IDLE;
      bid_reg  <= '0;
      s_bvalid <= 1'b0;
      aw_cnt   <= '0;
      w_cnt    <= '0;
    end else begin
      case (st)
        S_IDLE: begin
          s_bvalid <= 1'b0;
          if (s_awvalid && s_awready) begin
            bid_reg <= s_awid;
            aw_cnt  <= aw_cnt + 1;
            st      <= S_DATA;
          end
        end
        S_DATA: begin
          // Count every accepted beat; wlast ends the burst.
          if (s_wvalid && s_wready) begin
            w_cnt <= w_cnt + 1;
            if (s_wlast) begin
              s_bvalid <= 1'b1;
              st       <= S_BRESP;
            end
          end
        end
        S_BRESP: begin
          if (s_bvalid && s_bready) begin
            s_bvalid <= 1'b0;
            st       <= S_IDLE;
          end
        end
      endcase
    end
  end
endmodule

// =============================================================================

module tb_ar_withdraw;
  localparam int ADDR_W = 64;
  localparam int DATA_W = 64;
  localparam int ID_W   = 4;
  localparam int NM     = 4;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;

  int errs = 0;
  int tests = 0;

  // ---------------------------------------------------------------------------
  // Master-side nets (shared by crossbar and arbiter DUTs)
  // ---------------------------------------------------------------------------
  logic [NM-1:0][ID_W-1:0]   m_arid;
  logic [NM-1:0][ADDR_W-1:0] m_araddr;
  logic [NM-1:0][7:0]        m_arlen;
  logic [NM-1:0][2:0]        m_arsize;
  logic [NM-1:0][1:0]        m_arburst;
  logic [NM-1:0]             m_arvalid, m_arready;
  logic [NM-1:0]             m_rvalid, m_rready, m_rlast;
  logic [NM-1:0][DATA_W-1:0] m_rdata;
  logic [NM-1:0][1:0]        m_rresp;
  logic [NM-1:0][ID_W-1:0]   m_rid;
  // b-channel response nets are driven by BOTH DUTs (crossbar + arbiter)
  wire  [NM-1:0]             m_bvalid;
  wire  [NM-1:0][ID_W-1:0]   m_bid;
  wire  [NM-1:0][1:0]        m_bresp;

  // Write channel nets (exercised by the AW-withdrawal tests below)
  logic [NM-1:0] m_awvalid;
  logic [NM-1:0][ADDR_W-1:0] m_awaddr;
  logic [NM-1:0][7:0]        m_awlen;
  logic [NM-1:0][2:0]        m_awsize;
  logic [NM-1:0][1:0]        m_awburst;
  logic [NM-1:0][ID_W-1:0]   m_awid;
  logic [NM-1:0] m_wvalid;
  logic [NM-1:0][DATA_W-1:0] m_wdata;
  logic [NM-1:0][DATA_W/8-1:0] m_wstrb;
  logic [NM-1:0] m_wlast;
  logic [NM-1:0] m_bready;
  logic [NM-1:0] m_awready, m_wready;  // driven by both DUTs (like m_arready)

  // Master beats received (per DUT -- two independent counters)
  logic [NM-1:0][15:0] xb_beats, arb_beats;

  // rready is always asserted (masters always drain)
  assign m_rready = '1;

  // ---------------------------------------------------------------------------
  // DUT 1: crossbar
  // ---------------------------------------------------------------------------
  logic [3:0][ID_W-1:0]   s_arid;
  logic [3:0][ADDR_W-1:0] s_araddr;
  logic [3:0][7:0]        s_arlen;
  logic [3:0][2:0]        s_arsize;
  logic [3:0][1:0]        s_arburst;
  logic [3:0]             s_arvalid, s_arready;
  logic [3:0][ID_W-1:0]   s_rid;
  logic [3:0][DATA_W-1:0] s_rdata;
  logic [3:0][1:0]        s_rresp;
  logic [3:0]             s_rlast, s_rvalid, s_rready;
  logic [3:0]             s_bvalid;
  logic [3:0][ID_W-1:0]   s_bid;
  logic [3:0][1:0]        s_bresp;
  // s_awready/s_wready/s_bready are crossbar INPUTS from the slaves
  wire  [3:0]             s_awready, s_wready, s_bready;
  logic [3:0]             s_awvalid, s_wvalid;
  logic [3:0][ID_W-1:0]   s_awid;
  logic [3:0][ADDR_W-1:0] s_awaddr;
  logic [3:0][7:0]        s_awlen;
  logic [3:0][2:0]        s_awsize;
  logic [3:0][1:0]        s_awburst;
  logic [3:0][DATA_W-1:0] s_wdata;
  logic [3:0][DATA_W/8-1:0] s_wstrb;
  logic [3:0]             s_wlast;

  logic hold_ddr = 0;      // 1: DDR slave refuses AR acceptance

  c930_axi_crossbar #(
    .ADDR_WIDTH (ADDR_W),
    .DATA_WIDTH (DATA_W),
    .ID_WIDTH   (ID_W)
  ) xbar (
    .i_clk (clk), .i_rst_n (rst_n),
    .m0_awid(m_awid[0]), .m0_awaddr(m_awaddr[0]), .m0_awlen(m_awlen[0]),
    .m0_awsize(m_awsize[0]), .m0_awburst(m_awburst[0]), .m0_awvalid(m_awvalid[0]),
    .m0_awready(m_awready[0]), .m0_wdata(m_wdata[0]), .m0_wstrb(m_wstrb[0]), .m0_wlast(m_wlast[0]),
    .m0_wvalid(m_wvalid[0]), .m0_wready(m_wready[0]), .m0_bid(m_bid[0]), .m0_bresp(m_bresp[0]),
    .m0_bvalid(m_bvalid[0]), .m0_bready(m_bready[0]),
    .m0_arid(m_arid[0]), .m0_araddr(m_araddr[0]), .m0_arlen(m_arlen[0]),
    .m0_arsize(m_arsize[0]), .m0_arburst(m_arburst[0]), .m0_arvalid(m_arvalid[0]),
    .m0_arready(m_arready[0]), .m0_rid(m_rid[0]), .m0_rdata(m_rdata[0]),
    .m0_rresp(m_rresp[0]), .m0_rlast(m_rlast[0]), .m0_rvalid(m_rvalid[0]),
    .m0_rready(m_rready[0]),
    .m1_awid(m_awid[1]), .m1_awaddr(m_awaddr[1]), .m1_awlen(m_awlen[1]),
    .m1_awsize(m_awsize[1]), .m1_awburst(m_awburst[1]), .m1_awvalid(m_awvalid[1]),
    .m1_awready(m_awready[1]), .m1_wdata(m_wdata[1]), .m1_wstrb(m_wstrb[1]), .m1_wlast(m_wlast[1]),
    .m1_wvalid(m_wvalid[1]), .m1_wready(m_wready[1]), .m1_bid(m_bid[1]), .m1_bresp(m_bresp[1]),
    .m1_bvalid(m_bvalid[1]), .m1_bready(m_bready[1]),
    .m1_arid(m_arid[1]), .m1_araddr(m_araddr[1]), .m1_arlen(m_arlen[1]),
    .m1_arsize(m_arsize[1]), .m1_arburst(m_arburst[1]), .m1_arvalid(m_arvalid[1]),
    .m1_arready(m_arready[1]), .m1_rid(m_rid[1]), .m1_rdata(m_rdata[1]),
    .m1_rresp(m_rresp[1]), .m1_rlast(m_rlast[1]), .m1_rvalid(m_rvalid[1]),
    .m1_rready(m_rready[1]),
    .m2_awid(m_awid[2]), .m2_awaddr(m_awaddr[2]), .m2_awlen(m_awlen[2]),
    .m2_awsize(m_awsize[2]), .m2_awburst(m_awburst[2]), .m2_awvalid(m_awvalid[2]),
    .m2_awready(m_awready[2]), .m2_wdata(m_wdata[2]), .m2_wstrb(m_wstrb[2]), .m2_wlast(m_wlast[2]),
    .m2_wvalid(m_wvalid[2]), .m2_wready(m_wready[2]), .m2_bid(m_bid[2]), .m2_bresp(m_bresp[2]),
    .m2_bvalid(m_bvalid[2]), .m2_bready(m_bready[2]),
    .m2_arid(m_arid[2]), .m2_araddr(m_araddr[2]), .m2_arlen(m_arlen[2]),
    .m2_arsize(m_arsize[2]), .m2_arburst(m_arburst[2]), .m2_arvalid(m_arvalid[2]),
    .m2_arready(m_arready[2]), .m2_rid(m_rid[2]), .m2_rdata(m_rdata[2]),
    .m2_rresp(m_rresp[2]), .m2_rlast(m_rlast[2]), .m2_rvalid(m_rvalid[2]),
    .m2_rready(m_rready[2]),
    .m3_awid(m_awid[3]), .m3_awaddr(m_awaddr[3]), .m3_awlen(m_awlen[3]),
    .m3_awsize(m_awsize[3]), .m3_awburst(m_awburst[3]), .m3_awvalid(m_awvalid[3]),
    .m3_awready(m_awready[3]), .m3_wdata(m_wdata[3]), .m3_wstrb(m_wstrb[3]), .m3_wlast(m_wlast[3]),
    .m3_wvalid(m_wvalid[3]), .m3_wready(m_wready[3]), .m3_bid(m_bid[3]), .m3_bresp(m_bresp[3]),
    .m3_bvalid(m_bvalid[3]), .m3_bready(m_bready[3]),
    .m3_arid(m_arid[3]), .m3_araddr(m_araddr[3]), .m3_arlen(m_arlen[3]),
    .m3_arsize(m_arsize[3]), .m3_arburst(m_arburst[3]), .m3_arvalid(m_arvalid[3]),
    .m3_arready(m_arready[3]), .m3_rid(m_rid[3]), .m3_rdata(m_rdata[3]),
    .m3_rresp(m_rresp[3]), .m3_rlast(m_rlast[3]), .m3_rvalid(m_rvalid[3]),
    .m3_rready(m_rready[3]),
    .s0_awid(s_awid[0]), .s0_awaddr(s_awaddr[0]), .s0_awlen(s_awlen[0]), .s0_awsize(s_awsize[0]), .s0_awburst(s_awburst[0]),
    .s0_awvalid(s_awvalid[0]), .s0_awready(s_awready[0]),
    .s0_wdata(s_wdata[0]), .s0_wstrb(s_wstrb[0]), .s0_wlast(s_wlast[0]), .s0_wvalid(s_wvalid[0]), .s0_wready(s_wready[0]),
    .s0_bid(s_bid[0]), .s0_bresp(s_bresp[0]), .s0_bvalid(s_bvalid[0]), .s0_bready(s_bready[0]),
    .s0_arid(s_arid[0]), .s0_araddr(s_araddr[0]), .s0_arlen(s_arlen[0]),
    .s0_arsize(s_arsize[0]), .s0_arburst(s_arburst[0]), .s0_arvalid(s_arvalid[0]),
    .s0_arready(s_arready[0]), .s0_rid(s_rid[0]), .s0_rdata(s_rdata[0]),
    .s0_rresp(s_rresp[0]), .s0_rlast(s_rlast[0]), .s0_rvalid(s_rvalid[0]),
    .s0_rready(s_rready[0]),
    .s1_awid(s_awid[1]), .s1_awaddr(s_awaddr[1]), .s1_awlen(s_awlen[1]), .s1_awsize(s_awsize[1]), .s1_awburst(s_awburst[1]),
    .s1_awvalid(s_awvalid[1]), .s1_awready(s_awready[1]),
    .s1_wdata(s_wdata[1]), .s1_wstrb(s_wstrb[1]), .s1_wlast(s_wlast[1]), .s1_wvalid(s_wvalid[1]), .s1_wready(s_wready[1]),
    .s1_bid(s_bid[1]), .s1_bresp(s_bresp[1]), .s1_bvalid(s_bvalid[1]), .s1_bready(s_bready[1]),
    .s1_arid(s_arid[1]), .s1_araddr(s_araddr[1]), .s1_arlen(s_arlen[1]),
    .s1_arsize(s_arsize[1]), .s1_arburst(s_arburst[1]), .s1_arvalid(s_arvalid[1]),
    .s1_arready(s_arready[1]), .s1_rid(s_rid[1]), .s1_rdata(s_rdata[1]),
    .s1_rresp(s_rresp[1]), .s1_rlast(s_rlast[1]), .s1_rvalid(s_rvalid[1]),
    .s1_rready(s_rready[1]),
    .s2_awid(s_awid[2]), .s2_awaddr(s_awaddr[2]), .s2_awlen(s_awlen[2]), .s2_awsize(s_awsize[2]), .s2_awburst(s_awburst[2]),
    .s2_awvalid(s_awvalid[2]), .s2_awready(s_awready[2]),
    .s2_wdata(s_wdata[2]), .s2_wstrb(s_wstrb[2]), .s2_wlast(s_wlast[2]), .s2_wvalid(s_wvalid[2]), .s2_wready(s_wready[2]),
    .s2_bid(s_bid[2]), .s2_bresp(s_bresp[2]), .s2_bvalid(s_bvalid[2]), .s2_bready(s_bready[2]),
    .s2_arid(s_arid[2]), .s2_araddr(s_araddr[2]), .s2_arlen(s_arlen[2]),
    .s2_arsize(s_arsize[2]), .s2_arburst(s_arburst[2]), .s2_arvalid(s_arvalid[2]),
    .s2_arready(s_arready[2]), .s2_rid(s_rid[2]), .s2_rdata(s_rdata[2]),
    .s2_rresp(s_rresp[2]), .s2_rlast(s_rlast[2]), .s2_rvalid(s_rvalid[2]),
    .s2_rready(s_rready[2]),
    .s3_awid(s_awid[3]), .s3_awaddr(s_awaddr[3]), .s3_awlen(s_awlen[3]), .s3_awsize(s_awsize[3]), .s3_awburst(s_awburst[3]),
    .s3_awvalid(s_awvalid[3]), .s3_awready(s_awready[3]),
    .s3_wdata(s_wdata[3]), .s3_wstrb(s_wstrb[3]), .s3_wlast(s_wlast[3]), .s3_wvalid(s_wvalid[3]), .s3_wready(s_wready[3]),
    .s3_bid(s_bid[3]), .s3_bresp(s_bresp[3]), .s3_bvalid(s_bvalid[3]), .s3_bready(s_bready[3]),
    .s3_arid(s_arid[3]), .s3_araddr(s_araddr[3]), .s3_arlen(s_arlen[3]),
    .s3_arsize(s_arsize[3]), .s3_arburst(s_arburst[3]), .s3_arvalid(s_arvalid[3]),
    .s3_arready(s_arready[3]), .s3_rid(s_rid[3]), .s3_rdata(s_rdata[3]),
    .s3_rresp(s_rresp[3]), .s3_rlast(s_rlast[3]), .s3_rvalid(s_rvalid[3]),
    .s3_rready(s_rready[3])
  );

  // DDR slave (S1) is the real model; S0/S2/S3 stay inert.
  assign s_arready[0] = 1'b1;  assign s_rvalid[0] = 1'b0;  assign s_rlast[0] = 1'b0;
  assign s_rdata[0]   = '0;    assign s_rresp[0]  = 2'b00; assign s_rid[0]   = '0;
  assign s_arready[2] = 1'b1;  assign s_rvalid[2] = 1'b0;  assign s_rlast[2] = 1'b0;
  assign s_rdata[2]   = '0;    assign s_rresp[2]  = 2'b00; assign s_rid[2]   = '0;
  assign s_arready[3] = 1'b1;  assign s_rvalid[3] = 1'b0;  assign s_rlast[3] = 1'b0;
  assign s_rdata[3]   = '0;    assign s_rresp[3]  = 2'b00; assign s_rid[3]   = '0;
  // Inert slaves: accept writes immediately, never respond.  The DDR slave
  // (S1) is the real write model below (it drives s_bvalid[1]/s_bid[1]).
  assign s_bvalid[0] = 1'b0;
  assign s_bvalid[2] = 1'b0; assign s_bvalid[3] = 1'b0;
  assign s_bid[0] = '0; assign s_bid[2] = '0; assign s_bid[3] = '0;
  assign s_bresp[0] = 2'b00; assign s_bresp[2] = 2'b00; assign s_bresp[3] = 2'b00;
  assign s_awready[0] = 1'b1; assign s_wready[0] = 1'b1;
  assign s_awready[2] = 1'b1; assign s_wready[2] = 1'b1;
  assign s_awready[3] = 1'b1; assign s_wready[3] = 1'b1;

  t_axi_r_slave #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_ddr_slv (
    .clk(clk), .rst_n(rst_n), .hold(hold_ddr),
    .s_arid(s_arid[1]), .s_araddr(s_araddr[1]), .s_arlen(s_arlen[1]),
    .s_arsize(s_arsize[1]), .s_arburst(s_arburst[1]), .s_arvalid(s_arvalid[1]),
    .s_arready(s_arready[1]), .s_rid(s_rid[1]), .s_rdata(s_rdata[1]),
    .s_rresp(s_rresp[1]), .s_rlast(s_rlast[1]), .s_rvalid(s_rvalid[1]),
    .s_rready(s_rready[1]), .busy()
  );

  // DDR write slave (S1) with a hold switch for AW-accept refusal
  logic xb_hold_aw = 0;
  logic [31:0] xslv_aw_cnt, xslv_w_cnt;
  t_axi_w_slave #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_ddr_wslv (
    .clk(clk), .rst_n(rst_n), .hold(xb_hold_aw),
    .s_awid(s_awid[1]), .s_awaddr(s_awaddr[1]), .s_awlen(s_awlen[1]),
    .s_awsize(s_awsize[1]), .s_awburst(s_awburst[1]), .s_awvalid(s_awvalid[1]),
    .s_awready(s_awready[1]),
    .s_wdata(s_wdata[1]), .s_wstrb(s_wstrb[1]), .s_wlast(s_wlast[1]),
    .s_wvalid(s_wvalid[1]), .s_wready(s_wready[1]),
    .s_bid(s_bid[1]), .s_bresp(s_bresp[1]), .s_bvalid(s_bvalid[1]),
    .s_bready(s_bready[1]), .busy(), .aw_cnt(xslv_aw_cnt),
    .w_cnt(xslv_w_cnt)
  );

  // Beat counters for the crossbar read path
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) xb_beats <= '0;
    else
      for (int i = 0; i < NM; i++)
        if (m_rvalid[i] && m_rready[i]) xb_beats[i] <= xb_beats[i] + 1;
  end

  // ---------------------------------------------------------------------------
  // DUT 2: DMA arbiter (read path)
  // ---------------------------------------------------------------------------
  logic [ID_W-1:0]   a_s_arid;
  logic [ADDR_W-1:0] a_s_araddr;
  logic [7:0]        a_s_arlen;
  logic [2:0]        a_s_arsize;
  logic [1:0]        a_s_arburst;
  logic              a_s_arvalid, a_s_arready;
  logic [ID_W-1:0]   a_s_rid;
  logic [DATA_W-1:0] a_s_rdata;
  logic [1:0]        a_s_rresp;
  logic              a_s_rlast, a_s_rvalid, a_s_rready;
  logic              hold_ars = 0;
  // Arbiter write-side nets (driven by the arb write slave below)
  logic              a_hold_aw = 0;
  logic [31:0]       aslv_aw_cnt, aslv_w_cnt;
  logic [ID_W-1:0]   a_s_awid;
  logic [ADDR_W-1:0] a_s_awaddr;
  logic [7:0]        a_s_awlen;
  logic [2:0]        a_s_awsize;
  logic [1:0]        a_s_awburst;
  logic              a_s_awvalid;
  logic [DATA_W-1:0] a_s_wdata;
  logic [DATA_W/8-1:0] a_s_wstrb;
  logic              a_s_wlast, a_s_wvalid;
  logic              arb_s_awready, arb_s_wready;
  logic              arb_s_bvalid, arb_s_bready;
  logic [ID_W-1:0]   arb_s_bid;
  logic [1:0]        arb_s_bresp;

  c930_axi_dma_arb #(
    .ADDR_WIDTH (ADDR_W),
    .DATA_WIDTH (DATA_W),
    .ID_WIDTH   (ID_W),
    .ARB_ID_BASE(2'b00)
  ) arb (
    .i_clk (clk), .i_rst_n (rst_n),
    .m0_awid(m_awid[0]), .m0_awaddr(m_awaddr[0]), .m0_awlen(m_awlen[0]),
    .m0_awsize(m_awsize[0]), .m0_awburst(m_awburst[0]), .m0_awvalid(m_awvalid[0]),
    .m0_awready(), .m0_wdata(m_wdata[0]), .m0_wstrb(m_wstrb[0]), .m0_wlast(m_wlast[0]),
    .m0_wvalid(m_wvalid[0]), .m0_wready(), .m0_bid(m_bid[0]), .m0_bresp(m_bresp[0]),
    .m0_bvalid(m_bvalid[0]), .m0_bready(m_bready[0]),
    .m0_arid(m_arid[0]), .m0_araddr(m_araddr[0]), .m0_arlen(m_arlen[0]),
    .m0_arsize(m_arsize[0]), .m0_arburst(m_arburst[0]), .m0_arvalid(m_arvalid[0]),
    .m0_arready(), .m0_rid(), .m0_rdata(), .m0_rresp(), .m0_rlast(), .m0_rvalid(),
    .m0_rready(m_rready[0]),
    .m1_awid(m_awid[1]), .m1_awaddr(m_awaddr[1]), .m1_awlen(m_awlen[1]),
    .m1_awsize(m_awsize[1]), .m1_awburst(m_awburst[1]), .m1_awvalid(m_awvalid[1]),
    .m1_awready(), .m1_wdata(m_wdata[1]), .m1_wstrb(m_wstrb[1]), .m1_wlast(m_wlast[1]),
    .m1_wvalid(m_wvalid[1]), .m1_wready(), .m1_bid(m_bid[1]), .m1_bresp(m_bresp[1]),
    .m1_bvalid(m_bvalid[1]), .m1_bready(m_bready[1]),
    .m1_arid(m_arid[1]), .m1_araddr(m_araddr[1]), .m1_arlen(m_arlen[1]),
    .m1_arsize(m_arsize[1]), .m1_arburst(m_arburst[1]), .m1_arvalid(m_arvalid[1]),
    .m1_arready(), .m1_rid(), .m1_rdata(), .m1_rresp(), .m1_rlast(), .m1_rvalid(),
    .m1_rready(m_rready[1]),
    .m2_awid(m_awid[2]), .m2_awaddr(m_awaddr[2]), .m2_awlen(m_awlen[2]),
    .m2_awsize(m_awsize[2]), .m2_awburst(m_awburst[2]), .m2_awvalid(m_awvalid[2]),
    .m2_awready(), .m2_wdata(m_wdata[2]), .m2_wstrb(m_wstrb[2]), .m2_wlast(m_wlast[2]),
    .m2_wvalid(m_wvalid[2]), .m2_wready(), .m2_bid(m_bid[2]), .m2_bresp(m_bresp[2]),
    .m2_bvalid(m_bvalid[2]), .m2_bready(m_bready[2]),
    .m2_arid(m_arid[2]), .m2_araddr(m_araddr[2]), .m2_arlen(m_arlen[2]),
    .m2_arsize(m_arsize[2]), .m2_arburst(m_arburst[2]), .m2_arvalid(m_arvalid[2]),
    .m2_arready(), .m2_rid(), .m2_rdata(), .m2_rresp(), .m2_rlast(), .m2_rvalid(),
    .m2_rready(m_rready[2]),
    .m3_awid(m_awid[3]), .m3_awaddr(m_awaddr[3]), .m3_awlen(m_awlen[3]),
    .m3_awsize(m_awsize[3]), .m3_awburst(m_awburst[3]), .m3_awvalid(m_awvalid[3]),
    .m3_awready(), .m3_wdata(m_wdata[3]), .m3_wstrb(m_wstrb[3]), .m3_wlast(m_wlast[3]),
    .m3_wvalid(m_wvalid[3]), .m3_wready(), .m3_bid(m_bid[3]), .m3_bresp(m_bresp[3]),
    .m3_bvalid(m_bvalid[3]), .m3_bready(m_bready[3]),
    .m3_arid(m_arid[3]), .m3_araddr(m_araddr[3]), .m3_arlen(m_arlen[3]),
    .m3_arsize(m_arsize[3]), .m3_arburst(m_arburst[3]), .m3_arvalid(m_arvalid[3]),
    .m3_arready(), .m3_rid(), .m3_rdata(), .m3_rresp(), .m3_rlast(), .m3_rvalid(),
    .m3_rready(m_rready[3]),
    .s_awid(a_s_awid), .s_awaddr(a_s_awaddr), .s_awlen(a_s_awlen),
    .s_awsize(a_s_awsize), .s_awburst(a_s_awburst), .s_awvalid(a_s_awvalid),
    .s_awready(arb_s_awready),
    .s_wdata(a_s_wdata), .s_wstrb(a_s_wstrb), .s_wlast(a_s_wlast),
    .s_wvalid(a_s_wvalid), .s_wready(arb_s_wready),
    .s_bid(arb_s_bid), .s_bresp(arb_s_bresp), .s_bvalid(arb_s_bvalid),
    .s_bready(arb_s_bready),
    .s_arid(a_s_arid), .s_araddr(a_s_araddr), .s_arlen(a_s_arlen),
    .s_arsize(a_s_arsize), .s_arburst(a_s_arburst), .s_arvalid(a_s_arvalid),
    .s_arready(a_s_arready), .s_rid(a_s_rid), .s_rdata(a_s_rdata),
    .s_rresp(a_s_rresp), .s_rlast(a_s_rlast), .s_rvalid(a_s_rvalid),
    .s_rready(a_s_rready)
  );

  t_axi_r_slave #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_arb_slv (
    .clk(clk), .rst_n(rst_n), .hold(hold_ars),
    .s_arid(a_s_arid), .s_araddr(a_s_araddr), .s_arlen(a_s_arlen),
    .s_arsize(a_s_arsize), .s_arburst(a_s_arburst), .s_arvalid(a_s_arvalid),
    .s_arready(a_s_arready), .s_rid(a_s_rid), .s_rdata(a_s_rdata),
    .s_rresp(a_s_rresp), .s_rlast(a_s_rlast), .s_rvalid(a_s_rvalid),
    .s_rready(a_s_rready), .busy()
  );

  t_axi_w_slave #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_arb_wslv (
    .clk(clk), .rst_n(rst_n), .hold(a_hold_aw),
    .s_awid(a_s_awid), .s_awaddr(a_s_awaddr), .s_awlen(a_s_awlen),
    .s_awsize(a_s_awsize), .s_awburst(a_s_awburst), .s_awvalid(a_s_awvalid),
    .s_awready(arb_s_awready),
    .s_wdata(a_s_wdata), .s_wstrb(a_s_wstrb), .s_wlast(a_s_wlast),
    .s_wvalid(a_s_wvalid), .s_wready(arb_s_wready),
    .s_bid(arb_s_bid), .s_bresp(arb_s_bresp), .s_bvalid(arb_s_bvalid),
    .s_bready(arb_s_bready), .busy(), .aw_cnt(aslv_aw_cnt),
    .w_cnt(aslv_w_cnt)
  );

  // Beat counters for the arbiter read path (shared-port beats, per owner)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) arb_beats <= '0;
    else
      for (int i = 0; i < NM; i++)
        if (arb.s_rvalid && arb.s_rready && (arb.rd_owner == i))
          arb_beats[i] <= arb_beats[i] + 1;
  end

  // Write completions per master (B responses), counted on each DUT's own
  // shared port so parallel activity by the other DUT can't pollute counts.
  logic [NM-1:0][15:0] xb_wdone, arb_wdone;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      xb_wdone  <= '0;
      arb_wdone <= '0;
    end else begin
      for (int i = 0; i < NM; i++) begin
        if (xbar.w_shared_bvalid && xbar.w_shared_bready && (xbar.w_grant == i))
          xb_wdone[i] <= xb_wdone[i] + 1;
        if (arb.s_bvalid && arb.s_bready && (arb.wr_owner == i))
          arb_wdone[i] <= arb_wdone[i] + 1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------------
  task automatic issue_read(input int m, input [ADDR_W-1:0] addr, input [7:0] len);
    @(posedge clk);
    m_arid[m]    <= 4'h0;
    m_araddr[m]  <= addr;
    m_arlen[m]   <= len;
    m_arsize[m]  <= 3'd3;
    m_arburst[m] <= 2'b01;
    m_arvalid[m] <= 1'b1;
  endtask

  task automatic withdraw_read(input int m);
    @(posedge clk);
    m_arvalid[m] <= 1'b0;
  endtask

  // Real masters deassert arvalid once the slave accepts; completed reads
  // must clear it too, or a stale arvalid re-grants a finished master and
  // starves the master under test.
  task automatic read_done(input int m);
    @(posedge clk);
    m_arvalid[m] <= 1'b0;
  endtask

  task automatic clear_all_reads();
    @(posedge clk);
    for (int i = 0; i < NM; i++) m_arvalid[i] <= 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Write-channel helpers (single-beat bursts; wlast is asserted with the
  // address so the slave completes as soon as it accepts both channels)
  // ---------------------------------------------------------------------------
  task automatic issue_write(input int m, input [ADDR_W-1:0] addr, input [7:0] len);
    @(posedge clk);
    m_awid[m]    <= 4'h0;
    m_awaddr[m]  <= addr;
    m_awlen[m]   <= len;
    m_awsize[m]  <= 3'd3;
    m_awburst[m] <= 2'b01;
    m_awvalid[m] <= 1'b1;
    m_wdata[m]   <= addr;
    m_wstrb[m]   <= '1;
    m_wlast[m]   <= (len == 8'd0);
    m_wvalid[m]  <= 1'b1;
    m_bready[m]  <= 1'b1;
  endtask

  task automatic withdraw_write(input int m);
    @(posedge clk);
    m_awvalid[m] <= 1'b0;
    m_wvalid[m]  <= 1'b0;
    m_wlast[m]   <= 1'b0;
  endtask

  task automatic write_done(input int m);
    @(posedge clk);
    m_awvalid[m] <= 1'b0;
    m_wvalid[m]  <= 1'b0;
    m_wlast[m]   <= 1'b0;
    m_bready[m]  <= 1'b0;
  endtask

  // Complete a burst started by issue_write(m, addr, len): drive the
  // remaining `left` beats (len+1 total) with wlast on the last one.
  // Both DUTs present W exactly one cycle after the AW handshake and their
  // slaves accept one beat per cycle, so aligning to m_awready makes the
  // beat count exact: intermediate beats keep wlast=0, the final beat is
  // marked one cycle before the slave samples it, and wvalid drops after
  // the burst is taken (the slave leaves its data phase on wlast, so no
  // extra beat can sneak in).
  task automatic wbeats(input int m, input int left);
    // Sample the AW handshake at posedges only: iverilog's `wait` can
    // resume mid-posedge-processing, making the cycle count of the
    // following @(posedge) ambiguous (observed 0 vs 1 cycles).  A
    // while-loop consumes exactly one posedge per iteration.
    while (!(m_awvalid[m] && m_awready[m])) @(posedge clk);  // AW accepted
    repeat (left - 1) @(posedge clk);       // intermediate beats (wlast=0)
    @(posedge clk);
    m_wlast[m] <= 1'b1;                     // final beat, visible next cycle
    repeat (2) @(posedge clk);
    m_wvalid[m] <= 1'b0;                    // burst complete
  endtask

  task automatic clear_all_writes();
    @(posedge clk);
    for (int i = 0; i < NM; i++) begin
      m_awvalid[i] <= 1'b0;
      m_wvalid[i]  <= 1'b0;
      m_wlast[i]   <= 1'b0;
      m_bready[i]  <= 1'b0;
    end
  endtask

  task automatic check(input bit cond, input string what);
    tests++;
    if (!cond) begin
      $error("FAIL: %s", what);
      errs++;
    end else begin
      $display("  [PASS] %s", what);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Part A: crossbar -- AR withdrawal on every master
  // ---------------------------------------------------------------------------
  task automatic xbar_withdraw_test(input int m);
    int nb;
    string nm;
    nm = $sformatf("xbar m%0d", m);
    $display("=== %s: withdraw mid-address-phase ===", nm);
    clear_all_reads();

    hold_ddr = 1'b1;
    issue_read(m, 64'h0000_8000, 8'd3);
    wait (xbar.r_state == 2'd1 && xbar.r_grant == m[1:0]);
    check(xbar.r_state == 2'd1 && xbar.r_grant == m[1:0],
          $sformatf("%s granted while slave holds arready=0", nm));

    // Slave is not accepting; the master must not receive a false accept.
    repeat (3) @(posedge clk);
    check(m_arready[m] == 1'b0,
          $sformatf("%s no false arready during hold", nm));
    check(xbar.r_shared_arvalid == 1'b1,
          $sformatf("%s request presented to slave", nm));

    withdraw_read(m);
    wait (xbar.r_state == 2'd0);
    check(xbar.r_state == 2'd0,
          $sformatf("%s returns to R_IDLE after withdrawal", nm));
    check(xbar.r_ar_accepted == 1'b0,
          $sformatf("%s AR never accepted", nm));
    check(m_arready[m] == 1'b0,
          $sformatf("%s still no accept across the whole window", nm));
    repeat (2) @(posedge clk);

    // Recovery: full read from the same master must complete normally.
    hold_ddr = 1'b0;
    nb = xb_beats[m];
    issue_read(m, 64'h0000_8000, 8'd3);
    wait (xb_beats[m] >= nb + 4);
    check(xb_beats[m] >= nb + 4,
          $sformatf("%s recovery read delivers 4 beats", nm));
    read_done(m);
    wait (xbar.r_state == 2'd0 && !xbar.r_shared_rvalid);
    check(xbar.r_state == 2'd0 && !xbar.r_shared_rvalid,
          $sformatf("%s channel idle after recovery", nm));

    // Fairness: next round-robin master also completes.
    begin : fair
      int n = (m + 1) % NM;
      int bn = xb_beats[n];
      issue_read(n, 64'h0000_8100, 8'd3);
      wait (xb_beats[n] >= bn + 4);
      check(xb_beats[n] >= bn + 4,
            $sformatf("xbar m%0d read completes after m%0d withdrawal", n, m));
      read_done(n);
    end
    @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Part C: crossbar -- AW withdrawal on every master
  // ---------------------------------------------------------------------------
  task automatic xbar_write_withdraw_test(input int m);
    string nm;
    nm = $sformatf("xbar m%0d", m);
    $display("=== %s: withdraw AW mid-address-phase ===", nm);
    clear_all_writes();

    // Both slaves hold: neither DUT may accept while the master is
    // withdrawing, so the checks below are exact on both sides.
    xb_hold_aw = 1'b1;
    a_hold_aw  = 1'b1;
    // 3-beat burst (len=2): only the first W beat is presented before the
    // AW is withdrawn -- partial W data is in flight on the shared bus.
    issue_write(m, 64'h0000_8000, 8'd2);
    wait (xbar.w_state == 2'd1 && xbar.w_grant == m[1:0]);
    check(xbar.w_state == 2'd1 && xbar.w_grant == m[1:0],
          $sformatf("%s granted while slave holds awready=0", nm));

    // Slave is not accepting; the master must not receive a false accept.
    repeat (3) @(posedge clk);
    check(m_awready[m] == 1'b0,
          $sformatf("%s no false awready during hold", nm));
    check(xbar.w_shared_awvalid == 1'b1,
          $sformatf("%s AW presented to slave", nm));
    check(xbar.w_shared_wvalid == 1'b1,
          $sformatf("%s partial W data presented with AW during hold", nm));

    begin : wnoacc
      int c0 = xslv_aw_cnt;
      int w0 = xslv_w_cnt;
      withdraw_write(m);   // AW + W dropped mid-burst
      wait (xbar.w_state == 2'd0);
      check(xbar.w_state == 2'd0,
            $sformatf("%s returns to W_IDLE after withdrawal", nm));
      check(xslv_aw_cnt == c0,
            $sformatf("%s AW never accepted", nm));
      check(xslv_w_cnt == w0,
            $sformatf("%s no W beats accepted during hold", nm));
      check(m_awready[m] == 1'b0,
            $sformatf("%s still no accept across the whole window", nm));
      repeat (2) @(posedge clk);
    end

    // Recovery: a full 3-beat burst from the same master must complete.
    xb_hold_aw = 1'b0;
    a_hold_aw  = 1'b0;
    begin : wrec
      int nw = xb_wdone[m];
      int w0 = xslv_w_cnt;
      issue_write(m, 64'h0000_8000, 8'd2);
      wbeats(m, 2);       // beats 2..3, wlast on the last
      wait (xb_wdone[m] >= nw + 1);
      check(xb_wdone[m] >= nw + 1,
            $sformatf("%s recovery 3-beat write completes (B received)", nm));
      check(xslv_w_cnt >= w0 + 3,
            $sformatf("%s all 3 W beats of the recovery burst accepted (got %0d)", nm, xslv_w_cnt - w0));
      write_done(m);
      wait (xbar.w_state == 2'd0);
      check(xbar.w_state == 2'd0,
            $sformatf("%s channel idle after recovery", nm));
    end

    // Fairness: next round-robin master completes a 2-beat burst.
    begin : wfair
      int n = (m + 1) % NM;
      int nw = xb_wdone[n];
      issue_write(n, 64'h0000_8100, 8'd1);
      wbeats(n, 1);
      wait (xb_wdone[n] >= nw + 1);
      check(xb_wdone[n] >= nw + 1,
            $sformatf("xbar m%0d write completes after m%0d withdrawal", n, m));
      write_done(n);
    end
    @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Part B: DMA arbiter -- AR withdrawal on every master
  // ---------------------------------------------------------------------------
  task automatic arb_withdraw_test(input int m);
    string nm;
    nm = $sformatf("arb m%0d", m);
    $display("=== %s: withdraw mid-address-phase ===", nm);
    clear_all_reads();

    hold_ars = 1'b1;
    issue_read(m, 64'h0000_8000, 8'd3);
    wait (arb.rd_addr_phase == 1'b1 && arb.rd_owner == m[1:0]);
    check(arb.rd_addr_phase == 1'b1 && arb.rd_owner == m[1:0],
          $sformatf("%s granted (rd_addr_phase, owner=%0d)", nm, m));
    check(a_s_arvalid == 1'b1,
          $sformatf("%s request presented on shared port", nm));

    repeat (3) @(posedge clk);
    check(a_s_arready == 1'b0,
          $sformatf("%s slave not accepting during hold", nm));
    check(arb.rd_active == 1'b0,
          $sformatf("%s no data phase started", nm));

    withdraw_read(m);
    wait (arb.rd_addr_phase == 1'b0);
    check(arb.rd_addr_phase == 1'b0,
          $sformatf("%s clears rd_addr_phase after withdrawal", nm));
    check(arb.rd_active == 1'b0,
          $sformatf("%s rd_active stays clear", nm));
    check(a_s_arvalid == 1'b0,
          $sformatf("%s shared-port request withdrawn", nm));
    repeat (2) @(posedge clk);

    // Recovery: full read from the same master.
    hold_ars = 1'b0;
    begin : rec
      int bn = arb_beats[m];
      issue_read(m, 64'h0000_8000, 8'd3);
      wait (arb_beats[m] >= bn + 4);
      check(arb_beats[m] >= bn + 4,
            $sformatf("%s recovery read delivers 4 beats", nm));
      read_done(m);
      wait (arb.rd_active == 1'b0 && arb.rd_addr_phase == 1'b0);
      check(arb.rd_active == 1'b0 && arb.rd_addr_phase == 1'b0,
            $sformatf("%s arbiter idle after recovery", nm));
    end

    // Fairness: next round-robin master also completes.
    begin : fair2
      int n = (m + 1) % NM;
      int bn = arb_beats[n];
      issue_read(n, 64'h0000_8100, 8'd3);
      wait (arb_beats[n] >= bn + 4);
      check(arb_beats[n] >= bn + 4,
            $sformatf("arb m%0d read completes after m%0d withdrawal", n, m));
      read_done(n);
    end
    @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Part D: DMA arbiter -- AW withdrawal on every master
  // ---------------------------------------------------------------------------
  task automatic arb_write_withdraw_test(input int m);
    string nm;
    nm = $sformatf("arb m%0d", m);
    $display("=== %s: withdraw AW mid-address-phase ===", nm);
    clear_all_writes();

    // Both slaves hold while the master withdraws (see Part C).
    xb_hold_aw = 1'b1;
    a_hold_aw  = 1'b1;
    // 3-beat burst (len=2): only the first W beat is presented.
    issue_write(m, 64'h0000_8000, 8'd2);
    wait (arb.wr_addr_phase == 1'b1 && arb.wr_owner == m[1:0]);
    check(arb.wr_addr_phase == 1'b1 && arb.wr_owner == m[1:0],
          $sformatf("%s granted (wr_addr_phase, owner=%0d)", nm, m));
    check(a_s_awvalid == 1'b1,
          $sformatf("%s AW presented on shared port", nm));
    check(m_wvalid[m] == 1'b1,
          $sformatf("%s partial W data presented with AW during hold", nm));

    repeat (3) @(posedge clk);
    check(arb_s_awready == 1'b0,
          $sformatf("%s slave not accepting during hold", nm));
    check(arb.wr_active == 1'b0,
          $sformatf("%s no data phase started", nm));

    begin : wnoacc2
      int c0 = aslv_aw_cnt;
      int w0 = aslv_w_cnt;
      withdraw_write(m);   // AW + W dropped mid-burst
      wait (arb.wr_addr_phase == 1'b0);
      check(arb.wr_addr_phase == 1'b0,
            $sformatf("%s clears wr_addr_phase after withdrawal", nm));
      check(aslv_aw_cnt == c0,
            $sformatf("%s AW never accepted", nm));
      check(aslv_w_cnt == w0,
            $sformatf("%s no W beats accepted during hold", nm));
      check(arb.wr_active == 1'b0,
            $sformatf("%s wr_active stays clear", nm));
      check(a_s_awvalid == 1'b0,
            $sformatf("%s shared-port AW withdrawn", nm));
      repeat (2) @(posedge clk);
    end

    // Recovery: a full 3-beat burst from the same master.
    xb_hold_aw = 1'b0;
    a_hold_aw  = 1'b0;
    begin : wrec2
      int nw = arb_wdone[m];
      int w0 = aslv_w_cnt;
      issue_write(m, 64'h0000_8000, 8'd2);
      wbeats(m, 2);
      wait (arb_wdone[m] >= nw + 1);
      check(arb_wdone[m] >= nw + 1,
            $sformatf("%s recovery 3-beat write completes (B received)", nm));
      check(aslv_w_cnt >= w0 + 3,
            $sformatf("%s all 3 W beats of the recovery burst accepted (got %0d)", nm, aslv_w_cnt - w0));
      write_done(m);
      wait (arb.wr_active == 1'b0 && arb.wr_addr_phase == 1'b0);
      check(arb.wr_active == 1'b0 && arb.wr_addr_phase == 1'b0,
            $sformatf("%s arbiter idle after recovery", nm));
    end

    // Fairness: next round-robin master completes a 2-beat burst.
    begin : wfair2
      int n = (m + 1) % NM;
      int nw = arb_wdone[n];
      issue_write(n, 64'h0000_8100, 8'd1);
      wbeats(n, 1);
      wait (arb_wdone[n] >= nw + 1);
      check(arb_wdone[n] >= nw + 1,
            $sformatf("arb m%0d write completes after m%0d withdrawal", n, m));
      write_done(n);
    end
    @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    for (int m = 0; m < NM; m++) xbar_withdraw_test(m);

    // Reset between the two DUT groups for a clean arbiter state.
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    for (int m = 0; m < NM; m++) arb_withdraw_test(m);

    // Reset for the write-channel parts (both FSMs start clean).
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    for (int m = 0; m < NM; m++) xbar_write_withdraw_test(m);

    // Reset between the two write DUT groups.
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    for (int m = 0; m < NM; m++) arb_write_withdraw_test(m);

    repeat (8) @(posedge clk);
    if (errs == 0)
      $display("ALL AR/AW-WITHDRAW TESTS PASSED (%0d checks)", tests);
    else
      $display("AR/AW-WITHDRAW TESTS FAILED: %0d errors of %0d checks", errs, tests);
    $finish;
  end

  // Watchdog: hang the bench if a sub-test deadlocks instead of timing out.
  initial begin
    #200000;
    $display("FATAL: testbench watchdog fired (deadlock suspected)");
    $display("AR/AW-WITHDRAW TESTS FAILED: watchdog (errs=%0d)", errs);
    $finish;
  end
endmodule