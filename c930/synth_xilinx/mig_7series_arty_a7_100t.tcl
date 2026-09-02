# ---------------------------------------------------------------------------
# MIG 7 Series IP configuration for Arty A7-100T DDR3L
#
# Target: MT41K128M16JT-125 (Micron, 256 MB, 16-bit bus, 1.35V DDR3L)
# Board:  Digilent Arty A7-100T (XC7A100TCSG324-1)
#
# Run this script in Vivado to create the MIG IP:
#   source mig_7series_arty_a7_100t.tcl
#
# The MIG IP Customizer GUI will open with all settings pre-configured.
# Click "OK" to generate the IP, then "Generate Output Products".
#
# After generation, the IP will be named "mig_7series_0" and the
# following files will be created:
#   - mig_7series_0.xci          (IP configuration)
#   - mig_7series_0/mig_7series_0.xci  (full IP with XDC)
#   - mig_7series_0/src/         (source files)
#   - mig_7series_0/par/         (synthesis scripts)
#
# The DDR3L pin assignments are embedded in the IP's XDC — you do NOT
# need to manually constrain ddr3_dq, ddr3_addr, ddr3_ck, etc.
# ---------------------------------------------------------------------------

# Create the MIG 7 Series IP
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_7series_0

# Configure the MIG for MT41K128M16JT-125 on Arty A7-100T
set_property -dict [list \
    CONFIG.XML_INPUT_FILE {mig_prj_arty_a7_100t.prj} \
    CONFIG.BOARD_PART {digilentinc.com:arty-a7-100t:part0:1.0} \
    CONFIG.FPGA_PART {xc7a100tcsg324-1} \
    CONFIG.SYSTEM_CLOCK_PERIOD {5000} \
    CONFIG.SYSTEM_CLOCK_PERIOD_NODUALLY {5000} \
    CONFIG.SYSTEM_CLOCK_FREQ {200} \
    CONFIG.SYSTEM_CLOCK_FREQ_NOCKE {200} \
    CONFIG.SYSTEM_CLOCK_TYPE {DIFFERENTIAL} \
    CONFIG.SYSTEM_CLOCK_VBAND {1.8} \
    CONFIG.SINGLE_ENDED_INTERFACE {true} \
    CONFIG.C0.DRAM_TYPE {DDR3} \
    CONFIG.C0.DRAM_WIDTH {16} \
    CONFIG.C0.DRAM_SIZE {1024} \
    CONFIG.C0.DRAM_DEVICE_WIDTH {16} \
    CONFIG.C0.DRAM_DENSITY {2048} \
    CONFIG.C0.DRAM_SPEED_BIN {DDR3_1066F} \
    CONFIG.C0.DRAM_PARTNO {MT41K128M16JT-125} \
    CONFIG.C0.DRAM_MEMORY_DEVICE {MT41K128M16JT-125} \
    CONFIG.C0.CLKFBOUT_MULT {12} \
    CONFIG.C0.DIVCLK_DIVIDE {1} \
    CONFIG.C0.CLKOUT0_DIVIDE {3} \
    CONFIG.C0.CLKOUT0_REQUESTED_OUT_FREQ {400.000} \
    CONFIG.C0.USE_PCARD_CLK {false} \
    CONFIG.C0.MMCM_VCO mul {12} \
    CONFIG.C0.MMCM_VCO div {1} \
    CONFIG.C0.MMCM_INPUT_CLOCK_PERIOD {5.000} \
    CONFIG.C0.MMCM_CLKOUT0 {5.000} \
    CONFIG.C0.MMCM_CLKOUT1 {2.500} \
    CONFIG.C0.MMCM_CLKOUT2 {2.500} \
    CONFIG.C0.MMCM_CLKOUT3 {5.000} \
    CONFIG.C0.MMCM_CLKOUT4 {5.000} \
    CONFIG.C0.MMCM_CLKOUT5 {5.000} \
    CONFIG.C0.MMCM_CLKOUT6 {5.000} \
    CONFIG.C0.CLKOUT0_USE_FIFO {false} \
    CONFIG.C0.CLKOUT1_USE_FIFO {false} \
    CONFIG.C0.CLKOUT2_USE_FIFO {false} \
    CONFIG.C0.CLKOUT3_USE_FIFO {false} \
    CONFIG.C0.CLKOUT4_USE_FIFO {false} \
    CONFIG.C0.CLKOUT5_USE_FIFO {false} \
    CONFIG.C0.CLKOUT6_USE_FIFO {false} \
    CONFIG.C0.CLKOUT0_REQUESTED_PHASE {0.000} \
    CONFIG.C0.CLKOUT1_REQUESTED_PHASE {0.000} \
    CONFIG.C0.CLKOUT2_REQUESTED_PHASE {0.000} \
    CONFIG.C0.CLKOUT3_REQUESTED_PHASE {0.000} \
    CONFIG.C0.CLKOUT4_REQUESTED_PHASE {0.000} \
    CONFIG.C0.CLKOUT5_REQUESTED_PHASE {0.000} \
    CONFIG.C0.CLKOUT6_REQUESTED_PHASE {0.000} \
    CONFIG.C0.tCK {1875} \
    CONFIG.C0.tRAS {35.000} \
    CONFIG.C0.tRCD {13.125} \
    CONFIG.C0.tRP {13.125} \
    CONFIG.C0.tRC {48.125} \
    CONFIG.C0.tRFC {110.000} \
    CONFIG.C0.tREFI {7.800} \
    CONFIG.C0.tFAW {30.000} \
    CONFIG.C0.tRRD {7.500} \
    CONFIG.C0.tWTR {7.500} \
    CONFIG.C0.tRP_ab {13.125} \
    CONFIG.C0.tRAS_MIN {35.000} \
    CONFIG.C0.tRC_MIN {48.125} \
    CONFIG.C0.ADDR_WIDTH {14} \
    CONFIG.C0.BANK_WIDTH {3} \
    CONFIG.C0.CS_WIDTH {1} \
    CONFIG.C0.CKE_WIDTH {1} \
    CONFIG.C0.ODT_WIDTH {0} \
    CONFIG.C0.DQ_WIDTH {16} \
    CONFIG.C0.DQS_WIDTH {2} \
    CONFIG.C0.DM_WIDTH {2} \
    CONFIG.C0.DATA_WIDTH {16} \
    CONFIG.C0.N_SCK {0} \
    CONFIG.C0.N_SCK_ENABLE {false} \
    CONFIG.C0.CKE_ENABLED {true} \
    CONFIG.C0.CKE_POLARITY {ACTIVE_HIGH} \
    CONFIG.C0.RAS_POLARITY {ACTIVE_LOW} \
    CONFIG.C0.CAS_POLARITY {ACTIVE_LOW} \
    CONFIG.C0.WE_POLARITY {ACTIVE_LOW} \
    CONFIG.C0.CS_POLARITY {ACTIVE_LOW} \
    CONFIG.C0.ODT_POLARITY {ACTIVE_LOW} \
    CONFIG.C0.RESET_POLARITY {ACTIVE_LOW} \
    CONFIG.C0.VDDAlDo {1.500} \
    CONFIG.C0.VDDQ_VOLTAGE {1.35} \
    CONFIG.C0.VDDIO_VOLTAGE {1.500} \
    CONFIG.C0.EN_BOOTCLK {false} \
    CONFIG.C0.EN_QDRII {false} \
    CONFIG.C0.EN_DDR3 {true} \
    CONFIG.C0.EN_PAR {false} \
    CONFIG.C0.REFCLK_FREQ {200} \
    CONFIG.C0.MIG_UI_EXTRA {false} \
    CONFIG.C0.MIG_DPI {false} \
    CONFIG.C0.NO_OF_CS {1} \
    CONFIG.C0.NO_OF_DM {2} \
    CONFIG.C0.NO_OF_DQS {2} \
    CONFIG.C0.NO_OF_DQ {16} \
    CONFIG.C0.ADDR_CMD_OFFSET {0.0} \
    CONFIG.C0.nCL {7} \
    CONFIG.C0.nCWL {6} \
    CONFIG.C0.nRAS {24} \
    CONFIG.C0.nRFC {112} \
    CONFIG.C0.nRP {7} \
    CONFIG.C0.tCKE {3.750} \
    CONFIG.C0.tCKESR {15.000} \
    CONFIG.C0.tMRD {4} \
    CONFIG.C0.tMOD {12} \
    CONFIG.C0.tZQI {64} \
    CONFIG.C0.tZQCS {80} \
    CONFIG.C0.tRRD_S {6.250} \
    CONFIG.C0.tRRD_L {6.250} \
    CONFIG.C0.tWTR_S {4.000} \
    CONFIG.C0.tWTR_L {7.500} \
    CONFIG.C0.tCCD_S {4.000} \
    CONFIG.C0.tCCD_L {4.000} \
    CONFIG.C0.tRTP_S {4.000} \
    CONFIG.C0.tRTP_L {7.500} \
    CONFIG.C0.tCKSRE {5.000} \
    CONFIG.C0.tCKSRX {5.000} \
    CONFIG.C0.tCKESR {15.000} \
    CONFIG.C0.tCKE {3.750} \
    CONFIG.C0.tMRD {4} \
    CONFIG.C0.tMOD {12} \
    CONFIG.C0.tZQI {64} \
    CONFIG.C0.tZQCS {80} \
] [get_ips mig_7series_0]

# Generate the IP
generate_target {instantiation_template} [get_files mig_7series_0.xci]
generate_target all [get_files mig_7series_0.xci]

puts "INFO: MIG 7 Series IP created and generated for MT41K128M16JT-125."
puts "INFO: DDR3L pin assignments are in mig_7series_0/src/constraints/mig_7series_0.xdc"
puts "INFO: Include this IP in your Vivado project to use the DDR3L controller."
