# C930-class AI Engine Slice

First implemented slice of the C930-class server/AI SoC: an INT8
weight-stationary systolic-array GEMM accelerator that plugs into the
`RV64IMAC` reference core as a memory-mapped peripheral.

See [`doc/c930_architecture.md`](doc/c930_architecture.md) for the full SoC
blueprint and the dataflow proof.

## Contents

| Path                          | Description                                        |
|-------------------------------|----------------------------------------------------|
| `rtl/c930_tensor_pe.sv`       | Multiply-accumulate processing element             |
| `rtl/c930_systolic_array.sv`  | Weight-stationary systolic array (N×M mesh)        |
| `rtl/c930_npu_core.sv`        | GEMM control FSM, K- and N-tiling, skew + capture  |
| `rtl/c930_npu_csr.sv`         | MMIO register file + AXI4-Lite slave               |
| `rtl/c930_npu_dma.sv`         | AXI4 full master: fetch A/B, write back C          |
| `rtl/c930_npu_top.sv`         | Accelerator IP top (CSR + DMA + core + IRQ)        |
| `tb/tb_c930_npu.sv`           | Self-checking testbench                            |
| `doc/c930_architecture.md`    | Full SoC architecture specification                |

## What it computes

```
C[M x N] = A[M x K] * B[K x N]      (INT8 operands, INT32 accumulation)
```

`M`, `N`, and `K` are arbitrary (looped / tiled). The controller splits `K`
into tiles of `NUM_ROWS` (accumulator fed back between tiles) and `N` into
tiles of `NUM_COLS` (fresh accumulator per tile).

## Simulation

Easiest: use the Makefile (needs `make` and `iverilog` on PATH):

```sh
cd c930
make           # build + run
make build     # compile only
make wave      # run and print the VCD location
make clean     # remove build/ and the VCD dump
```

Or compile directly with Icarus Verilog:

```sh
mkdir -p build
iverilog -g2012 -Wall -o build/tb_c930_npu.vvp \
    c930/rtl/c930_tensor_pe.sv \
    c930/rtl/c930_systolic_array.sv \
    c930/rtl/c930_npu_core.sv \
    c930/rtl/c930_npu_csr.sv \
    c930/rtl/c930_npu_dma.sv \
    c930/rtl/c930_npu_top.sv \
    c930/tb/tb_c930_npu.sv
vvp build/tb_c930_npu.vvp
```

Verilator (lint):

```sh
verilator --lint-only -Wall \
    c930/rtl/c930_tensor_pe.sv \
    c930/rtl/c930_systolic_array.sv \
    c930/rtl/c930_npu_core.sv \
    c930/rtl/c930_npu_csr.sv \
    c930/rtl/c930_npu_dma.sv \
    c930/rtl/c930_npu_top.sv
```

Expected output: `[PASS] all NPU tests passed`.

## Programming model (from the RV64 core)

1. Place `A` (row-major, stride `K`), `B` (row-major, stride `N`), and an
   output region for `C` (one INT32 per element) in memory accessible to the
   AXI4 master. `A`/`B` are packed 4 INT8 per 32-bit word (little-endian).
2. Write `A_BASE`/`B_BASE`/`C_BASE`, `DIM_M`/`DIM_N`/`DIM_K`, and `CTRL.START`
   over the AXI4-Lite slave.
3. The DMA burst-reads `A` and `B`, the core computes, the DMA burst-writes
   `C` back, then `o_irq` pulses. Poll `STATUS.DONE` or service `o_irq`.

Register map: see the CSR header or `doc/c930_architecture.md` §5.

## Integration with the reference core

Instantiate `c930_npu_top` beside `riscv_core_top`, map its AXI4-Lite slave
into the MMIO aperture through the existing `riscv_core_axi4lite` bridge, and
connect its AXI4 master to the memory fabric (DDR/L3). The DMA autonomously
fetches A/B and stores C, so the RV64 core only programs the CSR and services
the completion IRQ.

## Notes

- Parameters must satisfy `NUM_ROWS >= 2`, `NUM_COLS >= 2` (the weight-load
  address uses `$clog2`). Defaults are 8×8.
- The AXI4-Lite slave is intentionally minimal: one outstanding transaction,
  AW and W channels paired. Adequate for MMIO; use a full interconnect adapter
  if it must sit on a high-performance NoC.
- FP16/FP8/BF16 datapaths are the next steps (see the roadmap in the
  architecture doc).
