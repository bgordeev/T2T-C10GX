# -----------------------------------------------------------------------------
# SDC Timing Exceptions for T2T-C10GX
# File: t2t_exceptions.sdc
#
# This file contains timing exceptions that may need tuning during
# integration and timing closure.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Development/Debug Exceptions
# -----------------------------------------------------------------------------

# Heartbeat counter (very slow toggle, no timing requirement)
set_false_path -to [get_registers {*heartbeat*}]

# Build timestamp and git hash (static values)
set_false_path -from [get_keepers {build_timestamp*}]
set_false_path -from [get_keepers {build_git_hash*}]

# -----------------------------------------------------------------------------
# CSR Domain Crossings
# -----------------------------------------------------------------------------

# Configuration registers crossing from csr_clk to core_clk
# These are set infrequently and can tolerate multiple cycle synchronization
set_false_path -from [get_clocks csr_clk] -to [get_registers {*cfg_*_sync*}]

# Status registers crossing from core_clk to csr_clk
set_false_path -from [get_clocks core_clk] -to [get_registers {u_csr/*status*}]

# -----------------------------------------------------------------------------
# MAC to Core CDC
# -----------------------------------------------------------------------------

# Async FIFO between MAC (156.25 MHz) and Core (300 MHz) domains
# Gray code pointers are properly synchronized in the FIFO design
set_max_delay 3.0 -from [get_clocks mac_clk] \
                  -to   [get_registers {u_mac_wrap/u_async_fifo/*_sync*}]

# -----------------------------------------------------------------------------
# Core to PCIe CDC
# -----------------------------------------------------------------------------

# Async FIFO between Core (300 MHz) and PCIe (125 MHz) domains
set_max_delay 4.0 -from [get_clocks core_clk] \
                  -to   [get_registers {u_dma/input_fifo*sync*}]

# Producer index synchronization
set_max_delay 4.0 -from [get_registers {u_dma/prod_idx*}] \
                  -to   [get_registers {u_csr/*prod_idx*}]

# Consumer index synchronization  
set_max_delay 4.0 -from [get_registers {u_csr/*cons_idx*}] \
                  -to   [get_registers {u_dma/*cons_idx_sync*}]

# -----------------------------------------------------------------------------
# Kill Switch Path
# -----------------------------------------------------------------------------

# Kill switch must propagate quickly but is single-bit
# Allow 2 cycles for synchronization
set_max_delay 6.666 -from [get_registers {u_csr/*kill*}] \
                    -to   [get_registers {u_risk/*kill*}]

# -----------------------------------------------------------------------------
# Latency Measurement Path
# -----------------------------------------------------------------------------

# GPIO pulse output should be fast for external measurement
set_max_delay 3.0 -from [get_registers {u_risk/action_pulse*}] \
                  -to   [get_ports gpio_latency_pulse]

# -----------------------------------------------------------------------------
# Memory Initialization
# -----------------------------------------------------------------------------

# Symbol table double-buffer swap (happens during commit)
set_multicycle_path 4 -setup -from [get_registers {u_symtab/*shadow*}] \
                              -to   [get_registers {u_symtab/*active*}]
set_multicycle_path 3 -hold  -from [get_registers {u_symtab/*shadow*}] \
                              -to   [get_registers {u_symtab/*active*}]

# Reference price initialization (rare, during configuration)
set_multicycle_path 4 -setup -through [get_registers {*ref_prices*}]
set_multicycle_path 3 -hold  -through [get_registers {*ref_prices*}]

# -----------------------------------------------------------------------------
# Specific Timing Relaxations (Tune During Closure)
# -----------------------------------------------------------------------------

# If specific paths fail timing, add targeted exceptions here:

# Example: Relax ITCH decoder byte extraction
# set_multicycle_path 2 -setup -from [get_registers {u_decoder/msg_bytes*}] \
#                               -to   [get_registers {u_decoder/*_field*}]

# Example: Relax book bank conflict handling
# set_multicycle_path 2 -setup -from [get_registers {u_book/conflict_fifo*}] \
#                               -to   [get_registers {u_book/pending_*}]

# -----------------------------------------------------------------------------
# Clock Uncertainty (Process/Voltage/Temperature Variation)
# -----------------------------------------------------------------------------

# Additional uncertainty for worst-case analysis
set_clock_uncertainty -setup 0.100 [get_clocks core_clk]
set_clock_uncertainty -hold  0.050 [get_clocks core_clk]

set_clock_uncertainty -setup 0.150 [get_clocks mac_clk]
set_clock_uncertainty -hold  0.075 [get_clocks mac_clk]

# -----------------------------------------------------------------------------
# Notes for Timing Closure
# -----------------------------------------------------------------------------

# If timing fails:
# 1. Check fitter report for specific failing paths
# 2. Consider Logic Lock regions for critical modules
# 3. Enable retiming in fitter settings
# 4. Add pipeline stages if needed (impacts latency budget!)
# 5. Review multicycle paths for correctness
#
# Target latencies (from ASSUMPTIONS.md):
# - MAC → Parser:     ~10 cycles (33 ns)
# - Parser → Decoder: ~15 cycles (50 ns)
# - Decoder → Book:   ~8 cycles (27 ns)  
# - Book → Risk:      ~4 cycles (13 ns)
# - Risk → DMA:       ~3 cycles (10 ns)
# - Total pipeline:   ~40 cycles (133 ns) internal
# - MAC CDC adds:     ~15 cycles (50 ns) at 300 MHz
# - PCIe CDC adds:    ~10 cycles (33 ns) at 300 MHz
#
# Expected total:
# - p50: ~200 cycles (~670 ns from MAC RX)
# - p99: ~300 cycles (~1000 ns with BRAM conflicts)
