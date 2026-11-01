// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// npu_web.h -- drive the Verilated c930_npu_top (npu_web_top.sv) from C:
// registers over AXI4-Lite, the DDR stand-in, and the clock. The same calls
// work natively and from WebAssembly (each is exported to JavaScript).
#ifndef NPU_WEB_H
#define NPU_WEB_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void     npu_web_reset(void);                         // (re)build the model, hold reset 8 cycles
int      npu_web_csr_write(uint32_t addr, uint32_t v); // cycles the write took, -1 on timeout
uint32_t npu_web_csr_read(uint32_t addr);              // 0xFFFFFFFF on timeout
void     npu_web_mem_write32(uint32_t byte_addr, uint32_t v);
uint32_t npu_web_mem_read32(uint32_t byte_addr);
int      npu_web_run(int max_cycles);                  // clock until the command finishes; cycles, -1 if not
int      npu_web_step(int cycles);                     // clock this many cycles
uint64_t npu_web_cycles(void);                         // cycles since reset
uint32_t npu_web_pins(void);                           // bit 0 busy, 1 done, 2 error, 3 irq
#ifdef __cplusplus
}
#endif
#endif
