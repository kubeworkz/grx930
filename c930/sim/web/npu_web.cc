// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// npu_web.cc -- the Verilated c930_npu_top, driven a cycle at a time.
#include "npu_web.h"
#include "Vnpu_web_top.h"
#include "Vnpu_web_top__Dpi.h"
#include "verilated.h"
#include "svdpi.h"
#include <memory>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define API EMSCRIPTEN_KEEPALIVE
#else
#define API
#endif

static std::unique_ptr<VerilatedContext> ctx;
static std::unique_ptr<Vnpu_web_top> top;
static uint64_t cycles = 0;

static void tick() {          // one clock: low phase, then the rising edge
  top->clk = 0; top->eval();
  top->clk = 1; top->eval();
  cycles++;
}
static void scope() { svSetScope(svGetScopeFromName("TOP.npu_web_top")); }

extern "C" {
API void npu_web_reset(void) {
  top.reset(); ctx.reset(new VerilatedContext);
  top.reset(new Vnpu_web_top(ctx.get()));
  top->s_axi_awvalid = top->s_axi_wvalid = top->s_axi_arvalid = 0;
  top->s_axi_bready = top->s_axi_rready = 0;
  top->rst_n = 0;
  for (int i = 0; i < 8; i++) tick();
  top->rst_n = 1;
  tick();
  cycles = 0;
}

API int npu_web_csr_write(uint32_t addr, uint32_t v) {
  uint64_t c0 = cycles;
  top->s_axi_awaddr = addr; top->s_axi_wdata = v; top->s_axi_wstrb = 0xF;
  top->s_axi_awvalid = 1; top->s_axi_wvalid = 1; top->s_axi_bready = 1;
  for (int i = 0; i < 1000; i++) {
    top->clk = 0; top->eval();
    // c930_npu_csr.sv performs the write at the first edge AWVALID and WVALID
    // are both high, raises READY with BVALID a cycle later, and drops BVALID
    // at the edge it is taken. Each handshake is sampled just before its edge.
    bool aw = top->s_axi_awvalid && top->s_axi_awready, w = top->s_axi_wvalid && top->s_axi_wready;
    bool b = top->s_axi_bvalid && top->s_axi_bready;
    tick();
    if (aw) top->s_axi_awvalid = 0;
    if (w) top->s_axi_wvalid = 0;
    if (b) { top->s_axi_bready = 0; return (int)(cycles - c0); }
  }
  top->s_axi_awvalid = top->s_axi_wvalid = 0; top->s_axi_bready = 0;
  return -1;
}

API uint32_t npu_web_csr_read(uint32_t addr) {
  top->s_axi_araddr = addr; top->s_axi_arvalid = 1; top->s_axi_rready = 1;
  for (int i = 0; i < 1000; i++) {
    top->clk = 0; top->eval();
    // RVALID and RDATA arrive with ARREADY, and with RREADY high the data is
    // taken at that same edge, so it is read here, before the edge.
    bool ar = top->s_axi_arvalid && top->s_axi_arready;
    bool r = top->s_axi_rvalid && top->s_axi_rready;
    uint32_t data = top->s_axi_rdata;
    tick();
    if (ar) top->s_axi_arvalid = 0;
    if (r) { top->s_axi_rready = 0; return data; }
  }
  top->s_axi_arvalid = 0; top->s_axi_rready = 0;
  return 0xFFFFFFFFu;
}

API void npu_web_mem_write32(uint32_t byte_addr, uint32_t v) { scope(); web_mem_write((int)(byte_addr >> 2), (int)v); top->eval(); }
API uint32_t npu_web_mem_read32(uint32_t byte_addr) { scope(); return (uint32_t)web_mem_read((int)(byte_addr >> 2)); }

API uint32_t npu_web_pins(void) {
  return (top->o_busy ? 1u : 0u) | (top->o_done ? 2u : 0u) | (top->o_error ? 4u : 0u) | (top->o_irq ? 8u : 0u);
}

// Clock until the command START queued has finished, judged the way
// c930_npu_driver.c's npu_drv_wait_done judges it: STATUS read over the bus,
// DONE latched with BUSY clear -- or ERROR, for a command the DMA refused.
API int npu_web_run(int max_cycles) {
  uint64_t c0 = cycles;
  while (cycles - c0 < (uint64_t)max_cycles) {
    for (int i = 0; i < 4; i++) tick();
    uint32_t st = npu_web_csr_read(0x04);
    if (st == 0xFFFFFFFFu) return -1;
    if ((st & 4u) || ((st & 2u) && !(st & 1u))) return (int)(cycles - c0);
  }
  return -1;
}

API int npu_web_step(int n) { for (int i = 0; i < n; i++) tick(); return n; }
API uint64_t npu_web_cycles(void) { return cycles; }
}
