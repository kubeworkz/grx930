// npu_dpi.cc - DPI functions for NPU CSR and DDR memory access.
// Called from the SystemVerilog wrapper via DPI imports.
// C++ code drives the AXI4-Lite signals through a shared state struct.

#include <cstdint>
#include <cstring>
#include "svdpi.h"

// ---- CSR address map (must match c930_npu_csr.sv) ----
static const uint32_t CSR_CTRL      = 0x00;
static const uint32_t CSR_STATUS    = 0x04;
static const uint32_t CSR_DIM_M     = 0x08;
static const uint32_t CSR_DIM_N     = 0x0C;
static const uint32_t CSR_DIM_K     = 0x10;
static const uint32_t CSR_A_BASE    = 0x14;
static const uint32_t CSR_B_BASE    = 0x18;
static const uint32_t CSR_C_BASE    = 0x1C;
static const uint32_t CSR_PREC      = 0x20;
static const uint32_t CSR_CYCLE     = 0x24;  // CYCLE_LO (32-bit)
// 0x28 is reserved (dead code in RTL, always reads 0)
static const uint32_t CSR_OP_COUNT  = 0x2C;
static const uint32_t CSR_STALL     = 0x30;
static const uint32_t CSR_DMA_CT    = 0x34;
// STATUS bitfield: bit 0 = BUSY, bit 1 = DONE, bit 2 = ERROR
static const uint32_t STATUS_BUSY   = 0x01;
static const uint32_t STATUS_DONE   = 0x02;
static const uint32_t STATUS_ERROR  = 0x04;

// ---- Shared state between C++ and Verilog ----
// These are set by C++ and read by the Verilog always_ff block.
static uint32_t csr_awaddr;
static uint32_t csr_wdata;
static uint32_t csr_wstrb;
static int      csr_awvalid;
static int      csr_wvalid;
static uint32_t csr_araddr;
static int      csr_arvalid;
static uint32_t csr_rdata;
static uint32_t csr_shadow[14];  // shadow register file for reads

// DDR memory (flat byte array, 64KB)
static uint8_t ddr_mem[65536];

// ---- DPI function implementations ----

extern "C" {

// Write a CSR: set AWADDR, WDATA, WSTRB, pulse AWVALID/WVALID
void dpi_npu_csr_write(int addr, int data) {
    // In the actual Verilog, this would drive the AXI4-Lite signals.
    // For the standalone wrapper, we maintain a shadow CSR map that
    // the C++ test harness reads directly.
    // The actual NPU CSR writes go through the AXI4-Lite slave in the RTL.
    //
    // For now, we provide a software shadow that the test harness uses.
    // The RTL-level CSR access requires driving the AXI signals for
    // NUM_ROWS*NUM_COLS cycles (the AXI handshake timing).
    csr_awaddr  = (uint32_t)addr;
    csr_wdata   = (uint32_t)data;
    csr_wstrb   = 0xF;
    csr_awvalid = 1;
    csr_wvalid  = 1;
    // Update shadow register for reads
    int idx = (addr >> 2) & 0xF;
    if (idx >= 0 && idx < 14) {
        if (idx != 1)  // STATUS is read-only
            csr_shadow[idx] = (uint32_t)data;
    }
}

// Read a CSR: set ARADDR, pulse ARVALID, return RDATA
int dpi_npu_csr_read(int addr) {
    csr_araddr  = (uint32_t)addr;
    csr_arvalid = 1;
    // Return from shadow register file
    int idx = (addr >> 2) & 0xF;
    if (idx >= 0 && idx < 14)
        return (int)csr_shadow[idx];
    return 0;
}

// Write a 32-bit word to DDR memory
void dpi_npu_mem_write(int addr, int data, int strb) {
    uint32_t a = (uint32_t)addr;
    if (a + 3 >= sizeof(ddr_mem)) return;
    if (strb & 0x1) ddr_mem[a+0] = data;
    if (strb & 0x2) ddr_mem[a+1] = data >> 8;
    if (strb & 0x4) ddr_mem[a+2] = data >> 16;
    if (strb & 0x8) ddr_mem[a+3] = data >> 24;
}

// Read a 32-bit word from DDR memory
int dpi_npu_mem_read(int addr) {
    uint32_t a = (uint32_t)addr;
    if (a + 3 >= sizeof(ddr_mem)) return 0;
    return ddr_mem[a] | (ddr_mem[a+1] << 8) |
           (ddr_mem[a+2] << 16) | (ddr_mem[a+3] << 24);
}

} // extern "C"

// ---- C++ API for grxcp team ----

// Get a pointer to the DDR memory (for bulk loads)
extern "C" uint8_t* npu_get_ddr_ptr(void) {
    return ddr_mem;
}

// Get/set CSR shadow values
extern "C" void npu_set_csr_shadow(int addr, int data) {
    int idx = (addr >> 2) & 0xF;
    if (idx >= 0 && idx < 14 && idx != 1)  // STATUS is read-only
        csr_shadow[idx] = (uint32_t)data;
}

extern "C" uint32_t npu_get_csr_shadow(int addr) {
    int idx = (addr >> 2) & 0xF;
    if (idx >= 0 && idx < 14)
        return csr_shadow[idx];
    return 0;
}
