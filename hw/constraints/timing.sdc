# =============================================================================
# T2T-C10GX Timing Constraints (SDC)
# =============================================================================
# This file defines timing constraints for the tick-to-trade FPGA design.
# Target: Cyclone 10 GX 10GX220YF780E5G
# =============================================================================

# =============================================================================
# Clock Definitions
# =============================================================================

# Reference clock from SFP+ (156.25 MHz)
create_clock -name refclk_156p25 -period 6.400 [get_ports refclk_156p25]

# Reference clock for PLLs (100 MHz)
create_clock -name refclk_100 -period 10.000 [get_ports refclk_100]

# PCIe reference clock (100 MHz)
create_clock -name pcie_refclk -period 10.000 [get_ports pcie_refclk]

# =============================================================================
# Generated Clocks (from PLLs)
# =============================================================================

# Core processing clock (300 MHz) - from PLL
create_generated_clock -name core_clk \
    -source [get_pins {u_pll_core|*|outclk[0]}] \
    -divide_by 1 \
    [get_pins {u_pll_core|*|outclk[0]}]

# CSR clock (100 MHz) - from PLL
create_generated_clock -name csr_clk \
    -source [get_pins {u_pll_core|*|outclk[1]}] \
    -divide_by 1 \
    [get_pins {u_pll_core|*|outclk[1]}]

# MAC clock (156.25 MHz) - from transceiver
create_generated_clock -name mac_clk \
    -source [get_ports refclk_156p25] \
    -divide_by 1 \
    [get_registers {*mac_clk*}]

# PCIe clock (125 MHz) - from PCIe HIP
create_generated_clock -name pcie_clk \
    -source [get_ports pcie_refclk] \
    -multiply_by 5 \
    -divide_by 4 \
    [get_pins {*pcie*|*coreclkout*}]

# =============================================================================
# Clock Groups (Asynchronous)
# =============================================================================

set_clock_groups -asynchronous \
    -group [get_clocks {refclk_156p25 mac_clk}] \
    -group [get_clocks {core_clk}] \
    -group [get_clocks {pcie_clk}] \
    -group [get_clocks {csr_clk}]

# =============================================================================
# Clock Domain Crossing Constraints
# =============================================================================

# Allow 2 cycles for CDC synchronizers
set_max_delay -from [get_clocks mac_clk] -to [get_clocks core_clk] 6.667
set_max_delay -from [get_clocks core_clk] -to [get_clocks mac_clk] 6.400

set_max_delay -from [get_clocks core_clk] -to [get_clocks pcie_clk] 6.667
set_max_delay -from [get_clocks pcie_clk] -to [get_clocks core_clk] 8.000

set_max_delay -from [get_clocks core_clk] -to [get_clocks csr_clk] 6.667
set_max_delay -from [get_clocks csr_clk] -to [get_clocks core_clk] 10.000

# False paths through CDC FIFOs
set_false_path -from [get_registers {*axi_async_fifo*wr_ptr_gray*}] \
               -to [get_registers {*axi_async_fifo*wr_ptr_sync*}]
set_false_path -from [get_registers {*axi_async_fifo*rd_ptr_gray*}] \
               -to [get_registers {*axi_async_fifo*rd_ptr_sync*}]

# False paths through CDC sync registers
set_false_path -to [get_registers {*cdc_sync*sync_reg[0]*}]

# =============================================================================
# Input/Output Constraints
# =============================================================================

# SFP+ RX (high-speed serial - handled by transceiver)
set_input_delay -clock refclk_156p25 -max 0.5 [get_ports sfp_rx_p]
set_input_delay -clock refclk_156p25 -min 0.0 [get_ports sfp_rx_p]

# SFP+ TX (high-speed serial - handled by transceiver)
set_output_delay -clock refclk_156p25 -max 0.5 [get_ports sfp_tx_p]
set_output_delay -clock refclk_156p25 -min 0.0 [get_ports sfp_tx_p]

# SFP+ control signals
set_output_delay -clock csr_clk -max 5.0 [get_ports sfp_tx_disable]
set_output_delay -clock csr_clk -min 0.0 [get_ports sfp_tx_disable]
set_input_delay -clock csr_clk -max 5.0 [get_ports {sfp_los sfp_mod_det}]
set_input_delay -clock csr_clk -min 0.0 [get_ports {sfp_los sfp_mod_det}]

# GPIO outputs
set_output_delay -clock core_clk -max 2.0 [get_ports gpio_latency_pulse]
set_output_delay -clock core_clk -min 0.0 [get_ports gpio_latency_pulse]
set_output_delay -clock core_clk -max 5.0 [get_ports gpio_status_led*]
set_output_delay -clock core_clk -min 0.0 [get_ports gpio_status_led*]

# Reset input (asynchronous)
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports pcie_perst_n]

# =============================================================================
# Critical Path Constraints
# =============================================================================

# Parser pipeline - ensure single-cycle operation
set_max_delay -from [get_registers {u_parser|stage*}] \
              -to [get_registers {u_parser|stage*}] \
              3.333

# Book TOB update path
set_max_delay -from [get_registers {u_book|tob_bram*}] \
              -to [get_registers {u_book|event_*}] \
              3.333

# Risk gate decision path
set_max_delay -from [get_registers {u_risk|event_reg*}] \
              -to [get_registers {u_risk|risk_reg*}] \
              3.333

# Symbol table lookup
set_max_delay -from [get_registers {u_symtab|lookup_key*}] \
              -to [get_registers {u_symtab|lookup_idx*}] \
              3.333

# =============================================================================
# Multicycle Paths
# =============================================================================

# CSR register reads (2 cycles)
set_multicycle_path -setup 2 -from [get_clocks csr_clk] \
    -to [get_registers {u_csr|read_data*}]
set_multicycle_path -hold 1 -from [get_clocks csr_clk] \
    -to [get_registers {u_csr|read_data*}]

# =============================================================================
# Min/Max Delay for External Interfaces
# =============================================================================

# PCIe interface timing handled by Intel HIP
# No additional constraints needed

# =============================================================================
# Report Settings
# =============================================================================

# Report unconstrained paths
set_timing_analyzer_report_script_cmd {report_timing -from_clock * -to_clock * -setup -npaths 20}
