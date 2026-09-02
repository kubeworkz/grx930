// -----------------------------------------------------------------------------
// npu_bringup.c - board bring-up firmware for Arty A7-100T + DDR3L
//
// Runs on the RV64IMAC core (no libc, no OS).  Loaded into DDR3L via JTAG
// at address 0x0000.  The MIG DDR3L controller has already calibrated by the
// time the CPU boots.
//
// Test sequence:
//   1. DDR3L write-read-back test (verify memory is functional)
//   2. NPU INT8 GEMM: 4x4 x 4x4 = 4x4
//   3. Verify C against software reference
//   4. Write pass/fail result to DDR for JTAG readback
//
// Visual feedback on the Arty A7 LEDs:
//   - o_npu_busy  (LD4) lights during NPU compute
//   - o_npu_done  (LD5) pulses on NPU completion
//   - o_npu_error (LD6) stays dark (0 errors)
//   - o_npu_irq   (LD7) pulses with done
//
//   Additionally, the PHASE_ADDR register (readable via JTAG) tracks progress:
//     0x01 = DDR write complete
//     0x02 = DDR read-back passed
//     0x03 = DDR read-back FAILED (check A_ADDR for mismatch)
//     0x04 = NPU configured
//     0x05 = NPU triggered
//     0x06 = NPU done
//     0x07 = C verification passed
//     0x08 = C verification FAILED (check C_ADDR)
//     0xFF = ALL TESTS PASSED
//
// Build:
//   cd c930
//   riscv64-unknown-elf-gcc -nostdlib -march=rv64imac -mabi=lp64 \
//     -T sw/link_boot.ld -O2 -o sw/npu_bringup.elf sw/npu_bringup.c
//   objcopy -O verilog sw/npu_bringup.elf sw/npu_bringup.hex
//
// Flash via JTAG:
//   openocd -f openocd.cfg -c "init; halt; load_image sw/npu_bringup.hex 0 \
//     bin; resume; exit"
//
// Read results via JTAG:
//   openocd -c "init; halt; md32 0x9490 1; md32 0x9410 1; exit"
//   PHASE_ADDR should read 0xFF (all tests passed)
//   DONE_ADDR should read 0xDEADBEEF (GEMM completed)
// -----------------------------------------------------------------------------

typedef unsigned int u32;

// ---------------------------------------------------------------------------
// NPU MMIO register map (byte offset from MMIO_BASE)
// ---------------------------------------------------------------------------
#define MMIO_BASE 0x40000000u

#define CSR_CTRL    (*(volatile u32 *)(MMIO_BASE + 0x00))
#define CSR_STATUS  (*(volatile u32 *)(MMIO_BASE + 0x04))
#define CSR_DIM_M   (*(volatile u32 *)(MMIO_BASE + 0x08))
#define CSR_DIM_N   (*(volatile u32 *)(MMIO_BASE + 0x0C))
#define CSR_DIM_K   (*(volatile u32 *)(MMIO_BASE + 0x10))
#define CSR_A_BASE  (*(volatile u32 *)(MMIO_BASE + 0x14))
#define CSR_B_BASE  (*(volatile u32 *)(MMIO_BASE + 0x18))
#define CSR_C_BASE  (*(volatile u32 *)(MMIO_BASE + 0x1C))
#define CSR_PREC    (*(volatile u32 *)(MMIO_BASE + 0x20))

#define CSR_START   0x1u
#define STATUS_DONE 0x2u
#define STATUS_BUSY 0x1u

// ---------------------------------------------------------------------------
// DDR3L memory map (byte addresses)
// ---------------------------------------------------------------------------
#define A_ADDR      0x8000u     // A matrix: 4x4 = 16 bytes
#define B_ADDR      0x8400u     // B matrix: 4x4 = 16 bytes
#define C_ADDR      0x8800u     // C result: 4x4 = 16 bytes (INT32 = 64 bytes)
#define PHASE_ADDR  0x9490u     // phase tracker (readable via JTAG)
#define DONE_ADDR   0x9410u     // completion magic (testbench polls this)
#define DONE_MAGIC  0xDEADBEEFu
#define RESULT_ADDR 0x9500u     // test result: 0xBEEF0001 = pass, 0xBEEF0000 = fail

// ---------------------------------------------------------------------------
// DDR3L byte-level helpers
// ---------------------------------------------------------------------------
static void ddr_write_byte(unsigned long addr, u32 val)
{
    *(volatile unsigned char *)addr = (unsigned char)(val & 0xFF);
}

static u32 ddr_read_byte(unsigned long addr)
{
    return *(volatile unsigned char *)addr;
}

static void ddr_write32(unsigned long addr, u32 val)
{
    *(volatile u32 *)addr = val;
}

static u32 ddr_read32(unsigned long addr)
{
    return *(volatile u32 *)addr;
}

// ---------------------------------------------------------------------------
// Busy-wait delay (approximate, depends on clock frequency)
// ---------------------------------------------------------------------------
static void delay(volatile int count)
{
    while (count--)
        ;
}

// ---------------------------------------------------------------------------
// Test 1: DDR3L write-read-back
//
// Writes a known pattern to DDR3L, reads it back, and verifies.
// This confirms the MIG DDR3L controller is functioning.
// ---------------------------------------------------------------------------
static int test_ddr3l(void)
{
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;
    int pass = 1;

    // Write test pattern: address XOR 0xA5 at each byte
    for (int i = 0; i < 256; i++) {
        u32 addr = 0x10000u + i;  // test region above code/data
        ddr_write_byte(addr, addr ^ 0xA5);
    }

    *phase = 0x01;  // DDR write complete

    // Read back and verify
    for (int i = 0; i < 256; i++) {
        u32 addr = 0x10000u + i;
        u32 expected = addr ^ 0xA5;
        u32 actual = ddr_read_byte(addr);
        if (actual != expected) {
            // First mismatch: write address and values to scratch for debug
            ddr_write32(PHASE_ADDR + 4, addr);   // failing address
            ddr_write32(PHASE_ADDR + 8, expected); // expected value
            ddr_write32(PHASE_ADDR + 12, actual);  // actual value
            pass = 0;
            break;
        }
    }

    if (pass) {
        *phase = 0x02;  // DDR read-back passed
    } else {
        *phase = 0x03;  // DDR read-back FAILED
    }

    return pass;
}

// ---------------------------------------------------------------------------
// Test 2: NPU INT8 GEMM (4x4 x 4x4 = 4x4)
//
// A = [ 1  2  3  4 ]   B = [ 1  0  0  1 ]   C = A x B
//     [ 5  6  7  8 ]       [ 0  1  1  0 ]       [ 9 13 13  9 ]
//     [ 9 10 11 12 ]       [ 1  0  0  1 ]       [25 37 37 25]
//     [13 14 15 16 ]       [ 0  1  1  0 ]       [41 61 61 41]
//
// Expected C (INT32):
//   C[0][0] = 1*1+2*0+3*1+4*0 = 4
//   C[0][1] = 1*0+2*1+3*0+4*1 = 6
//   C[0][2] = 1*0+2*1+3*0+4*1 = 6
//   C[0][3] = 1*1+2*0+3*1+4*0 = 4
//   C[1][0] = 5*1+6*0+7*1+8*0 = 12
//   C[1][1] = 5*0+6*1+7*0+8*1 = 14
//   C[1][2] = 5*0+6*1+7*0+8*1 = 14
//   C[1][3] = 5*1+6*0+7*1+8*0 = 12
//   C[2][0] = 9*1+10*0+11*1+12*0 = 20
//   C[2][1] = 9*0+10*1+11*0+12*1 = 22
//   C[2][2] = 9*0+10*1+11*0+12*1 = 22
//   C[2][3] = 9*1+10*0+11*1+12*0 = 20
//   C[3][0] = 13*1+14*0+15*1+16*0 = 28
//   C[3][1] = 13*0+14*1+15*0+16*1 = 30
//   C[3][2] = 13*0+14*1+15*0+16*1 = 30
//   C[3][3] = 13*1+14*0+15*1+16*0 = 28
// ---------------------------------------------------------------------------
static int test_npu_gemm(void)
{
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;

    // Expected C values (row-major, 4x4, INT32 little-endian)
    const int expected_c[4][4] = {
        {  4,  6,  6,  4 },
        { 12, 14, 14, 12 },
        { 20, 22, 22, 20 },
        { 28, 30, 30, 28 }
    };

    // Write A matrix (4x4 INT8, row-major)
    // A[i][j] = i*4 + j + 1  (1..16)
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            ddr_write_byte(A_ADDR + i*4 + j, (i*4 + j + 1));

    // Write B matrix (4x4 INT8, row-major)
    // B = [[1,0,0,1],[0,1,1,0],[1,0,0,1],[0,1,1,0]]
    const signed char B[4][4] = {
        { 1, 0, 0, 1 },
        { 0, 1, 1, 0 },
        { 1, 0, 0, 1 },
        { 0, 1, 1, 0 }
    };
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            ddr_write_byte(B_ADDR + i*4 + j, B[i][j]);

    // Clear C region
    for (int i = 0; i < 64; i++)
        ddr_write_byte(C_ADDR + i, 0);

    // Configure NPU
    CSR_DIM_M  = 4;
    CSR_DIM_N  = 4;
    CSR_DIM_K  = 4;
    CSR_A_BASE = A_ADDR;
    CSR_B_BASE = B_ADDR;
    CSR_C_BASE = C_ADDR;
    CSR_PREC   = 0;  // INT8

    *phase = 0x04;  // NPU configured

    // Trigger NPU
    CSR_CTRL = CSR_START;
    *phase = 0x05;  // NPU triggered

    // Wait for completion
    while (!(CSR_STATUS & STATUS_DONE))
        ;

    *phase = 0x06;  // NPU done

    // Read cycle count for diagnostics
    u32 cycles = CSR_STATUS;  // just read status to confirm done
    (void)cycles;

    return 1;
}

// ---------------------------------------------------------------------------
// Test 3: Verify NPU C result against software reference
// ---------------------------------------------------------------------------
static int test_verify_c(void)
{
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;

    const int expected_c[4][4] = {
        {  4,  6,  6,  4 },
        { 12, 14, 14, 12 },
        { 20, 22, 22, 20 },
        { 28, 30, 30, 28 }
    };

    int pass = 1;
    for (int i = 0; i < 4 && pass; i++) {
        for (int j = 0; j < 4; j++) {
            // Read 32-bit INT32 result (little-endian)
            u32 addr = C_ADDR + (i*4 + j)*4;
            u32 val = ddr_read32(addr);
            if ((int)val != expected_c[i][j]) {
                // Write mismatch info for JTAG debug
                ddr_write32(PHASE_ADDR + 16, addr);
                ddr_write32(PHASE_ADDR + 20, (u32)expected_c[i][j]);
                ddr_write32(PHASE_ADDR + 24, val);
                pass = 0;
                break;
            }
        }
    }

    return pass;
}

// ---------------------------------------------------------------------------
// Main: run all tests
// ---------------------------------------------------------------------------
void main(void)
{
    volatile u32 *phase = (volatile u32 *)PHASE_ADDR;
    volatile u32 *result = (volatile u32 *)RESULT_ADDR;

    *phase = 0x00;
    *result = 0;

    // Test 1: DDR3L write-read-back
    if (!test_ddr3l()) {
        *result = 0xBEEF0000u;  // DDR test failed
        for (;;)
            ;
    }

    // Test 2: NPU INT8 GEMM
    test_npu_gemm();

    // Test 3: Verify C result
    if (!test_verify_c()) {
        *phase = 0x08;
        *result = 0xBEEF0001u;  // C verification failed
        for (;;)
            ;
    }

    // All tests passed
    *phase = 0xFF;
    *result = 0xBEEF0002u;  // ALL TESTS PASSED

    // Write DONE_MAGIC for testbench compatibility
    *(volatile u32 *)DONE_ADDR = DONE_MAGIC;

    // Spin forever (LEDs show final state)
    for (;;)
        ;
}
