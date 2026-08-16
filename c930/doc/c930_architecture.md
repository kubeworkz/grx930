# XuanTie C930-class RISC-V64 Server / AI SoC — Architecture Specification

This document defines the architecture of a C930/C950-class server-grade
RISC-V 64-bit SoC with an integrated AI (tensor) engine, built on and around
the `RV64IMAC` reference core in this repository. All features are public
RISC-V standards or industry-standard interfaces; no proprietary T-Head RTL
is used.

> Status: this is the **architecture blueprint**. The first implemented slice
> is the AI engine (INT8 systolic-array GEMM) under `c930/rtl/` plus a
> self-checking testbench. The wide out-of-order core, coherent fabric, and
> memory controllers are staged behind it.

---

## 1. Goals and positioning

| Axis            | Target                                        |
|-----------------|-----------------------------------------------|
| ISA             | RVA23 (RV64GC + V 1.0 + vector crypto + Zb*) |
| Core            | Wide superscalar out-of-order, 6–8 wide, 12–15 stages |
| Vector          | RVV 1.0, VLEN 256–512, chained multi-pipe     |
| AI              | INT8/INT16/FP16/FP8 tensor engine (systolic)  |
| Caches          | 32–64 KB L1I/L1D, 256 KB–1 MB L2, 16–64 MB shared L3 |
| Memory          | 4–12 ch DDR5/LPDDR5X, HBM3e option            |
| Fabric          | AMBA CHI / AXI5, directory + snoop filter     |
| I/O             | PCIe Gen5/6, CXL 2.0/3.0, UCIe chiplets       |
| Platform        | H, IOMMU, AIA (APLIC+IMSIC), Sstc/Sscofpmf/Svpbmt/Svadu/Svinval |
| Security        | ePMP/PMP, IOPMP, secure boot, TEE/root of trust, scalar+vector crypto |
| RAS / power     | ECC/parity everywhere, machine-check records, Sdext/Smtrace, DVFS, power gating |

---

## 2. Top-level block diagram

```
                          +-----------------------------------------------------------+
                          |                      C930 SoC                            |
                          |                                                           |
  DDR5/HBM  <--->  DDR5/HBM MC  <--+                                                 |
                                    |                                                 |
  PCIe Gen5/6 <--->  PCIe RC      <-+->  Coherent NoC (CHI / AXI5 + directory)  <-+   |
                                    |     (snoop filter, multi-banked)            |   |
  CXL 2.0/3.0 <--->  CXL EP/RC    <-+                                              |   |
                                    |                                              |   |
  UCIe       <--->  UCIe PHY/DI    <-+                                              |   |
                                    |                                              |   |
                 +------------------+---------------+---------------------+        |   |
                 |                  |               |                     |        |   |
            +----v-----+      +-----v-----+    +----v------+       +------v------+ |   |
            | CPU clstr|      | CPU clstr |    | L3/LLC    |       |  NPU (AI)   | |   |
            | 0..N     |      | ...       |    | 16-64 MB  |       |  tensor eng | |   |
            +----+-----+      +-----+-----+    +----+------+       +------+------+ |   |
                 |                  |               |                     |        |   |
            +----v-----+      +-----v-----+    +----v------+       +------v------+ |   |
            | L2 (slc) |      |  L2       |    |           |       | DMA + SMEM  | |   |
            +----+-----+      +-----+-----+    |           |       +------+------+ |   |
                 |                  |          +-----------+                       |   |
                 +------------------+-----------+                                 |   |
                                               |                                  |   |
                    IOMMU / IOPMP / APLIC / IMSIC / RISC-V AIA <--------------------+   |
                    Secure boot / TEE / Root of Trust / RAS / Telemetry               |
                          +-----------------------------------------------------------+
```

Each CPU cluster contains 4–8 cores sharing an L2; the NPU is a first-class
coherent agent with a shared-virtual-memory (SVM) interface so the CPU can hand
it pointers directly (no copy).

---

## 3. Core microarchitecture (staged evolution of the RV64IMAC core)

The reference `riscv_core_top` is a 5-stage **in-order** RV64IMAC core. The
C930 core is reached in three stages; each stage keeps the reference core's
interfaces (`i_`/`o_` ports, AXI4-Lite/AXI4 memory ports) intact so software
and verification reuse carry forward.

1. **Stage 1 — the AI engine now (this slice):** keep the RV64IMAC core as the
   control/application processor and attach the NPU as a memory-mapped
   accelerator on its AXI fabric (see §7).
2. **Stage 2 — RVV 1.0 vector unit:** add a parameterized vector register file
   (VLEN 256) and vector ALU/load-store, decoding the V extension in the
   existing 5-stage pipeline. This gives scalar+vector "C908-class" throughput.
3. **Stage 3 — wide out-of-order:** replace the in-order datapath with
   decode/rename/dispatch/issue, a large ROB, physical register files, deep
   load/store queues, TAGE+perceptron branch prediction, and a CHI master port.
   This is the true C930-class core.

### Stage-3 core parameters (target)

| Structure                | Size                                  |
|--------------------------|---------------------------------------|
| Decode / issue width     | 6–8                                   |
| Pipeline depth           | 12–15                                 |
| ROB / physical regs      | 384–512 entries / 224–256 PRF         |
| Load / store queue       | 128 / 96 deep                         |
| Branch prediction        | TAGE + perceptron + RAS + BTB         |
| Execution units          | 4–6 ALU, 2–4 AGU, 2 LSU, FPU, 2–4 V-pipes |

---

## 4. Cache and memory hierarchy

| Level | Size                        | Notes                                   |
|-------|-----------------------------|-----------------------------------------|
| L1I/D | 32–64 KB each, 8-way        | ECC on tags/data; virtually-indexed L1D |
| L2    | 256 KB–1 MB per core/cluster| parity on tags, ECC on data             |
| L3/LLC| 16–64 MB shared, multi-banked, partitioned | directory/snoop-filter at this level |

- **Coherency:** AMBA CHI (preferred) or AXI5+ACE. CHI channels (REQ/RSP/DAT/SNP)
  map cleanly to the staged NoC.
- **Memory controllers:** 4–12 channels DDR5-5600/LPDDR5X; HBM3e stacks for the
  AI variant; interleaved address hashing to spread traffic.
- **CXL 2.0/3.0:** type-2/3 device support for memory expansion and coherent
  accelerator attach; CXL.cache for the NPU when it acts as a coherent device.

---

## 5. AI engine (implemented in this slice)

The AI engine computes `C[M×N] = A[M×K] × B[K×N]` with a **weight-stationary
systolic array** (TPU-style dataflow). This is the core operator of transformer
/ LLM inference (GEMM and, via two GEMMs, attention).

```
         activations (A rows) ──►  left → right
              │
   ┌───────┬───────┬───────┬───────┐
   │ PE00  │ PE01  │ PE02  │ PE03  │  ◄── row k=0  (weight B[0][*])
   ├───────┼───────┼───────┼───────┤
   │ PE10  │ PE11  │ PE12  │ PE13  │  ◄── row k=1
   ├───────┼───────┼───────┼───────┤
   │ PE20  │ PE21  │ PE22  │ PE23  │  ◄── row k=2
   ├───────┼───────┼───────┼───────┤
   │ PE30  │ PE31  │ PE32  │ PE33  │  ◄── row k=3
   └───────┴───────┴───────┴───────┘
          │       │       │       │
          ▼       ▼       ▼       ▼
      C[m][0]  C[m][1]  C[m][2]  C[m][3]   ◄── partial sums flow top → bottom
```

### Dataflow semantics (hand-verified on a 2×2 example)

- PE `(k, n)` holds weight `B[k][n]`.
- Row `k` carries activation `A[m][k]` (one scalar per pass), which propagates
  left → right (one PE per cycle).
- Column `n` accumulates top → bottom: each PE adds `a * w` to the incoming
  partial sum and passes the result down.
- **Skew:** row `k`'s activation pulse is delayed by `k` cycles, and the
  running accumulator is injected into column `n` delayed by `n` cycles. This
  aligns every product on the array's diagonal.
- Column `n`'s result emerges at the bottom at cycle `NUM_ROWS + n`: the
  partial sum drains through the whole column, including the unused zero rows
  of a partial K-tile. The controller captures the bottom edge in a staggered
  window over `NUM_ROWS + NUM_COLS` cycles.

### Tiling

- `K > NUM_ROWS` is handled by K-tiling: the controller loops over
  `ceil(K/NUM_ROWS)` tiles, feeding the accumulator back into the top edge
  between tiles.
- `N > NUM_COLS` is handled by N-tiling: the controller loops over
  `ceil(N/NUM_COLS)` column tiles with a fresh accumulator per tile.
- `M` is handled by looping output rows.
- Precision: INT8 in, INT32 accumulate (this slice). INT16 and FP16/FP8/BF16
  datapaths are parameterized extensions.

### Modules

| File                          | Role                                            |
|-------------------------------|-------------------------------------------------|
| `c930_tensor_pe.sv`           | One multiply-accumulate PE (weight-stationary)  |
| `c930_systolic_array.sv`      | N×M PE mesh with weight-load addressing         |
| `c930_npu_core.sv`            | GEMM FSM, A/B/C buffers, K/N-tiling, skew + capture |
| `c930_npu_csr.sv`             | MMIO register file + AXI4-Lite slave            |
| `c930_npu_dma.sv`             | AXI4 full master: fetch A/B, write back C       |
| `c930_npu_top.sv`             | Accelerator IP top (CSR + DMA + core + IRQ)     |

### MMIO register map (AXI4-Lite, word offsets)

| Offset | Name    | Access | Description                          |
|--------|---------|--------|--------------------------------------|
| 0x00   | CTRL    | W      | bit0 = START                          |
| 0x04   | STATUS  | R      | bit0 BUSY, bit1 DONE(latched), bit2 ERROR |
| 0x08   | DIM_M   | R/W    | output rows M                         |
| 0x0C   | DIM_N   | R/W    | output cols N                         |
| 0x10   | DIM_K   | R/W    | reduction length K                    |
| 0x14   | A_BASE  | R/W    | activation base (reserved for DMA)    |
| 0x18   | B_BASE  | R/W    | weight base (reserved for DMA)        |
| 0x1C   | C_BASE  | R/W    | result base (reserved for DMA)        |

---

## 6. Virtualization, interrupts, security, RAS (blueprint)

- **Hypervisor (H) + IOMMU:** device isolation for the NPU and PCIe/CXL
  endpoints; two-stage address translation shared with the CPU (SVM).
- **AIA:** APLIC (wired) + IMSIC (MSI) for low-latency interrupts; NPU
  completion raises a fast MSI for agentic loops / tool calling.
- **Security:** ePMP/PMP for CPU, IOPMP for I/O masters (including the NPU's
  DMA), secure boot from an immutable root of trust, TEE, and scalar (Zk) +
  vector (Zvbb/Zvbc/Zvkg/Zvkned) crypto.
- **RAS:** ECC/parity on caches, TLBs, register files; machine-check error
  records; Sdext debug + Smtrace trace; per-core DVFS/power gating and
  telemetry counters for thermal management.

---

## 7. Integration into the RV64IMAC reference

The NPU is a memory-mapped accelerator on the reference core's AXI fabric:

1. Instantiate `c930_npu_top` beside `riscv_core_top` and connect its
   AXI4-Lite slave to the existing `riscv_core_axi4lite` bridge (or directly
   to the interconnect), mapping it into the MMIO aperture.
2. The RV64 core writes the operand buffers (via the data-plane ports, or a
   future AXI DMA master) and programs DIM_*/CTRL, then services the
   `o_irq`/`o_done` interrupt.
3. Software driver: `mmio_write(BASE+CTRL, 1)` to launch; poll or interrupt on
   STATUS.DONE; read `C` back.

The systolic-array module is deliberately interface-clean so it can later be
relocated behind a CHI coherent port or driven directly by the RVV vector unit
(a fused vector/matrix datapath, the C950-class step).

---

## 8. Roadmap

1. **This slice:** INT8 systolic GEMM + CSR + testbench. ✅
2. AXI4 DMA master for the data plane (autonomous fetch of A/B/C from DDR). ✅
3. INT16 / FP16 / BF16 / FP8 datapaths and a configurable precision CSR.
4. RVV 1.0 vector unit + fused vector→matrix dispatch (Stage 2).
5. CHI coherent NPU port (SVM with the CPU), directory/snoop-filter NoC.
6. Wide out-of-order core (Stage 3), then DDR5/HBM + PCIe/CXL + IOMMU/AIA.
