# npu-web

Written by `.github/workflows/npu-web.yml` and force-pushed on every passing build:
`c930_npu_top` Verilated and compiled to WebAssembly, with the API in
`c930/sim/web/npu_web.h`. Its transcript (`transcript.txt`) was printed byte for byte
the same natively, by the WebAssembly C test and through this module.
Source commit: 7b732ec0232daed3c0f2f7a443a38c728ae624b4.
