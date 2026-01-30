# -----------------------------------------------------------------------------
# SDC Timing Constraints for T2T-C10GX
# File: t2t_timing.sdc
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Clock Definitions
# -----------------------------------------------------------------------------

# Reference clock for 10G Ethernet transceiver (156.25 MHz)
create_clock -name refclk_156p25 -period 6.400 [get_ports refclk_156p25]

# Reference clock for core PLL (100 MHz)
create_clock -name refclk_100 -period 10.000 [get_ports refclk_100]

# PCIe reference clock (100 MHz)
create_clock -name pcie_refclk -period 10.000 [get_ports pcie_refclk]

# -----------------------------------------------------------------------------
# Generated Clocks (from PLLs)
# -----------------------------------------------------------------------------

# Core clock: 300 MHz (3.333 ns period)
# Note: Actual clock will be created by PLL IP
create_generated_clock -name core_clk \
    -source [get_ports refclk_100] \
    -multiply_by 3 \
    [get_pins {u_pll_core|outclk_0}]

# CSR clock: 100 MHz (10 ns period)
create_generated_clock -name csr_clk \
    -source [get_ports refclk_100] \
    -divide_by 1 \
    [get_pins {u_pll_core|outclk_1}]

# MAC clock: 156.25 MHz from transceiver recovered clock
create_generated_clock -name mac_clk \
    -source [get_ports refclk_156p25] \
    -divide_by 1 \
    [get_pins {u_mac_wrap|mac_clk}]

# PCIe clock: 125 MHz (8 ns period)
# Note: This comes from PCIe Hard IP
create_generated_clock -name pcie_clk \
    -source [get_ports pcie_refclk] \
    -multiply_by 5 \
    -divide_by 4 \
    [get_pins {pcie_hip|coreclkout}]

# -----------------------------------------------------------------------------
# Clock Groups (Asynchronous Domains)
# -----------------------------------------------------------------------------

# All clocks are asynchronous to each other
set_clock_groups -asynchronous \
    -group {refclk_156p25 mac_clk} \
    -group {refclk_100 core_clk csr_clk} \
    -group {pcie_refclk pcie_clk}

# -----------------------------------------------------------------------------
# Core Clock Domain Constraints (300 MHz)
# -----------------------------------------------------------------------------

# Target: 3.333 ns period with margin
set CORE_PERIOD 3.333
set CORE_SETUP_MARGIN 0.100
set CORE_HOLD_MARGIN 0.050

# Critical path: Parser to Book
set_max_delay -from [get_registers {u_parser/*}] \
              -to   [get_registers {u_book/*}] \
              [expr {$CORE_PERIOD - $CORE_SETUP_MARGIN}]

# Critical path: Book to Risk
set_max_delay -from [get_registers {u_book/*}] \
              -to   [get_registers {u_risk/*}] \
              [expr {$CORE_PERIOD - $CORE_SETUP_MARGIN}]

# Multicycle path for symbol table lookup (2 cycles)
set_multicycle_path 2 -setup -from [get_registers {u_decoder/sym_lookup*}] \
                              -to   [get_registers {u_symtab/lookup*}]
set_multicycle_path 1 -hold  -from [get_registers {u_decoder/sym_lookup*}] \
                              -to   [get_registers {u_symtab/lookup*}]

# Multicycle path for reference price lookup (2 cycles)
set_multicycle_path 2 -setup -from [get_registers {u_risk/event_p1*}] \
                              -to   [get_registers {u_risk/ref_prices*}]
set_multicycle_path 1 -hold  -from [get_registers {u_risk/event_p1*}] \
                              -to   [get_registers {u_risk/ref_prices*}]

# -----------------------------------------------------------------------------
# CDC Constraints
# -----------------------------------------------------------------------------

# False path for reset synchronizers
set_false_path -from [get_registers {*rst_n*}] -to [get_registers {*cdc_reset_sync*}]

# False path for CDC synchronizers (2-FF)
set_false_path -to [get_registers {*cdc_sync_2ff*}]

# Max delay for FIFO gray code pointers
set_max_delay 2.0 -from [get_registers {*async_fifo*wr_ptr_gray*}] \
                  -to   [get_registers {*async_fifo*wr_ptr_gray_sync*}]
set_max_delay 2.0 -from [get_registers {*async_fifo*rd_ptr_gray*}] \
                  -to   [get_registers {*async_fifo*rd_ptr_gray_sync*}]

# -----------------------------------------------------------------------------
# I/O Constraints
# -----------------------------------------------------------------------------

# GPIO latency pulse output
# Fast output for timing measurement
set_output_delay -clock core_clk -max 1.0 [get_ports gpio_latency_pulse]
set_output_delay -clock core_clk -min 0.0 [get_ports gpio_latency_pulse]

# Status LEDs (slow, relaxed timing)
set_output_delay -clock csr_clk -max 5.0 [get_ports gpio_status_led[*]]
set_output_delay -clock csr_clk -min 0.0 [get_ports gpio_status_led[*]]

# SFP control signals
set_output_delay -clock csr_clk -max 5.0 [get_ports sfp_tx_disable]
set_input_delay  -clock csr_clk -max 5.0 [get_ports sfp_los]
set_input_delay  -clock csr_clk -max 5.0 [get_ports sfp_mod_det]

# Reset input (asynchronous)
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports pcie_perst_n]

# -----------------------------------------------------------------------------
# Memory Timing
# -----------------------------------------------------------------------------

# BRAM read latency (1 cycle)
set_multicycle_path 1 -setup -through [get_pins {*bram*|q*}]

# Symbol table BRAM
set_max_delay 2.5 -from [get_registers {u_symtab/table_mem*}] \
                  -to   [get_registers {u_symtab/lookup_result*}]

# Book BRAM banks
set_max_delay 2.5 -from [get_registers {u_book/tob_mem*}] \
                  -to   [get_registers {u_book/tob_read*}]

# -----------------------------------------------------------------------------
# Transceiver Constraints
# -----------------------------------------------------------------------------

# 10G Ethernet transceiver timing (handled by IP)
# Note: Intel Ethernet IP generates its own constraints

# PCIe transceiver timing (handled by Hard IP)
# Note: PCIe Hard IP generates its own constraints

# -----------------------------------------------------------------------------
# Report Generation
# -----------------------------------------------------------------------------

# Create timing reports for critical paths
# report_timing -setup -npaths 50 -detail full_path -panel_name "Setup: Core Domain"
# report_timing -hold -npaths 50 -detail full_path -panel_name "Hold: Core Domain"

# -----------------------------------------------------------------------------
# Design-specific Exceptions
# -----------------------------------------------------------------------------

# Statistics counters (clear-on-read, no timing critical)
set_false_path -to [get_registers {*stat_*}]

# Configuration registers (written infrequently)
set_multicycle_path 2 -setup -from [get_registers {u_csr/reg_*}]
set_multicycle_path 1 -hold  -from [get_registers {u_csr/reg_*}]

# Token bucket counters (timing relaxed, updated once per ms)
set_multicycle_path 2 -setup -to [get_registers {u_risk/token_bucket*}]
set_multicycle_path 1 -hold  -to [get_registers {u_risk/token_bucket*}]
