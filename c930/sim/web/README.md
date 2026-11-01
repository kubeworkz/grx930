# c930/sim/web

The GRX930 NPU's RTL (`c930_npu_top`, as `c930_soc_top.sv` builds it) Verilated
and compiled to WebAssembly, so a browser can run the real design.

- `npu_web_top.sv`: the NPU with the SoC's parameters and `tb/tb_c930_npu.sv`'s
  AXI4 memory model at 64 KB (DPI exports load and read it)
- `npu_web.cc`, `npu_web.h`: the C API (exported to JavaScript): reset, CSR
  writes and reads over AXI4-Lite, memory, and `npu_web_run`, which polls
  STATUS as `c930_npu_driver.c` does
- `npu_web_test.cc`: 45 GEMMs (INT8, INT16, INT4, FP16, BF16; nine shapes up to
  8x12x16) checked exactly against a reference, and a refused command
- `run-web.mjs`: the same test through the browser module's exports
- `build.sh OUT`: Verilate once; build the test natively and as WebAssembly, and
  the browser module
- `compare.sh OUT`: all three must pass and print the same bytes

`.github/workflows/npu-web.yml` runs both on changes to the RTL or this folder;
on `main` a passing build is published to the `npu-web` branch with a
`manifest.json` (source commit, RTL digests, tool versions, file digests) and
the transcript. A build that fails or differs is never published.
