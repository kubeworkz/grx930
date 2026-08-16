# RISC-V bare-metal toolchain

The Makefile expects the xPack GNU RISC-V bare-metal toolchain at:

    toolchain/xpack-riscv-none-elf-gcc-15.2.0-1/bin

It is not committed (binary distribution, several hundred MB). Install it with
the xPack manager:

    npm install -g @xpack-dev-tools/riscv-none-elf-gcc@15.2.0-1

or download the archive for your platform from the xPack releases page:

    https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases

then unpack it so the `bin/` directory above exists (i.e. the extracted folder
is named `xpack-riscv-none-elf-gcc-15.2.0-1`).

Verify with:

    ./xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc --version

Only `make sw` (the C driver image) needs the toolchain; `make soc`/`make npu`
can reuse a previously built `sw/npu_prog.hex`.
