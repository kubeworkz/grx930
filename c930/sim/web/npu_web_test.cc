// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// npu_web_test.cc -- GEMMs through the Verilated NPU, checked and transcribed.
//
// For each precision and shape: operands from a fixed LCG, packed as the DMA
// reads them (row-major, little-endian, 4/2/8 per word), CSRs programmed as
// c930_npu_driver.c does, START, clock to completion, and C checked against a
// reference. Integers are exact (C is acc[31:0]); the float operands are
// quarters in [-2, 2], whose products and sums are exact in FP32, so FP16 and
// BF16 are checked exactly too. Every line printed is a function of the RTL
// alone, so a native build and a WebAssembly build must print the same bytes.
#include "npu_web.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>

static uint32_t lcg = 930;
static uint32_t rnd() { lcg = lcg * 1664525u + 1013904223u; return lcg >> 8; }

static uint16_t f16(float x) {           // exact for quarters in [-2, 2]
  if (x == 0) return 0;
  uint32_t b; memcpy(&b, &x, 4);
  uint32_t s = (b >> 16) & 0x8000, e = ((b >> 23) & 0xff) - 127 + 15, m = (b & 0x7fffff) >> 13;
  return (uint16_t)(s | (e << 10) | m);
}
static uint16_t bf16(float x) { uint32_t b; memcpy(&b, &x, 4); return (uint16_t)(b >> 16); }

struct Prec { int code; const char *name; int bits; bool flt; int lo, hi; };
static const Prec PRECS[] = {
  {0, "INT8", 8, false, -128, 127}, {1, "INT16", 16, false, -32768, 32767},
  {4, "INT4", 4, false, -8, 7},     {2, "FP16", 16, true, 0, 0}, {3, "BF16", 16, true, 0, 0},
};
static const int SHAPES[][3] = { {1,1,1}, {2,3,5}, {4,4,4}, {8,1,4}, {1,12,8}, {5,7,9}, {3,9,11}, {8,8,16}, {8,12,16} };
static const uint32_t A_BASE = 0x8000, B_BASE = 0x8400, C_BASE = 0x8800;

static void pack(uint32_t base, const std::vector<uint32_t> &elems, int bits) {
  int per = 32 / bits; size_t words = (elems.size() + per - 1) / per;
  for (size_t w = 0; w < words; w++) {
    uint32_t v = 0;
    for (int j = 0; j < per && w * per + j < elems.size(); j++)
      v |= (elems[w * per + j] & ((bits == 32) ? 0xffffffffu : ((1u << bits) - 1))) << (j * bits);
    npu_web_mem_write32(base + 4 * (uint32_t)w, v);
  }
}

int main() {
  int bad = 0, n = 0;
  printf("npu_web_test: c930_npu_top, Verilated; SoC parameters (8x8, DIN_W 16, M<=8 K<=16 N<=12)\n");
  for (const Prec &p : PRECS) for (auto &s : SHAPES) {
    int M = s[0], N = s[1], K = s[2];
    npu_web_reset();
    for (uint32_t a = 0x8000; a < 0x9000; a += 4) npu_web_mem_write32(a, 0);
    std::vector<double> A(M * K), B(K * N);
    std::vector<uint32_t> ea, eb;
    for (auto *mat : {&A, &B}) for (auto &x : *mat) {
      if (p.flt) x = ((int)(rnd() % 17) - 8) / 4.0;
      else x = p.lo + (int)(rnd() % (uint32_t)(p.hi - p.lo + 1));
    }
    for (double x : A) ea.push_back(p.flt ? (p.code == 2 ? f16((float)x) : bf16((float)x)) : (uint32_t)(int32_t)x);
    for (double x : B) eb.push_back(p.flt ? (p.code == 2 ? f16((float)x) : bf16((float)x)) : (uint32_t)(int32_t)x);
    pack(A_BASE, ea, p.bits); pack(B_BASE, eb, p.bits);
    npu_web_csr_write(0x08, M); npu_web_csr_write(0x0C, N); npu_web_csr_write(0x10, K);
    npu_web_csr_write(0x14, A_BASE); npu_web_csr_write(0x18, B_BASE); npu_web_csr_write(0x1C, C_BASE);
    npu_web_csr_write(0x20, p.code);
    npu_web_csr_write(0x00, 1);
    int cyc = npu_web_run(200000);
    uint32_t st = npu_web_csr_read(0x04), cy = npu_web_csr_read(0x24), op = npu_web_csr_read(0x2C),
             stall = npu_web_csr_read(0x30), dma = npu_web_csr_read(0x28);
    int miss = 0; uint32_t h = 2166136261u;
    for (int i = 0; i < M; i++) for (int j = 0; j < N; j++) {
      uint32_t got = npu_web_mem_read32(C_BASE + 4 * (uint32_t)(i * N + j));
      h = (h ^ got) * 16777619u;
      uint32_t want;
      if (p.flt) {
        double sum = 0; for (int k = 0; k < K; k++) sum += A[i * K + k] * B[k * N + j];
        float f = (float)sum; memcpy(&want, &f, 4);
      } else {
        long long sum = 0; for (int k = 0; k < K; k++) sum += (long long)A[i * K + k] * (long long)B[k * N + j];
        want = (uint32_t)sum;
      }
      if (got != want) {
        if (miss < 3) printf("    C[%d][%d] = 0x%08X, expected 0x%08X\n", i, j, got, want);
        miss++;
      }
    }
    bool ok = cyc > 0 && (st & 2) && !(st & 4) && miss == 0;
    printf("%-5s M=%d N=%2d K=%2d  run=%6d cycles  STATUS=%u CYCLE_LO=%u OP_COUNT=%u STALL_CT=%u DMA_LAST=%u  C=%08X  %s\n",
           p.name, M, N, K, cyc, st, cy, op, stall, dma, h, ok ? "PASS" : "FAIL");
    bad += !ok; n++;
  }
  // A refused command: K beyond the SoC's 16 sets ERROR without a run.
  npu_web_reset();
  npu_web_csr_write(0x08, 4); npu_web_csr_write(0x0C, 4); npu_web_csr_write(0x10, 20); npu_web_csr_write(0x20, 0);
  npu_web_csr_write(0x00, 1);
  int cyc = npu_web_run(200);
  uint32_t st = npu_web_csr_read(0x04);
  bool ok = (st & 4) != 0;
  printf("INT8  M=4 N= 4 K=20  run=%6d cycles  STATUS=%u (dims past MAX_K: ERROR expected)  %s\n", cyc, st, ok ? "PASS" : "FAIL");
  bad += !ok; n++;
  printf("npu_web_test: %d of %d passed\n", n - bad, n);
  return bad ? 1 : 0;
}
