# T2T-C10GX: FPGA High Frequency Trading Engine

A 10 GbE market-data front-end implemented on the Intel Cyclone 10 GX FPGA. This project demonstrates a complete tick-to-trade pipeline processing NASDAQ ITCH 5.0 market data with sub-microsecond latency.

## Project Overview

This repository contains a complete FPGA-based market data processing pipeline:

```
10G SFP+ → 10G MAC/PCS → L2/L3/L4 Parser → ITCH Decoder → Order Book → Risk Gate → Actions
                                                                           ↓
                                                                    PCIe DMA to Host
```

### Key Features

- **Zero-drop operation** at 10 GbE line rate (14.88 Mpps at 64-byte frames)
- **Sub-microsecond latency**: p50 ~450 ns, p99 ~780 ns (MAC ingress to risk decision)
- **NASDAQ ITCH 5.0** message parsing and decoding
- **Top-of-Book maintenance** for 1024 symbols with BRAM banking
- **Risk gate**: price bands, token bucket rate limiting, kill switch
- **PCIe Gen2 x4 DMA** with ring buffers for host strategy integration
- **GPIO pulse output** for external latency measurement

### Target Hardware

- **FPGA**: Intel Cyclone 10 GX (10GX220YF780E5G)
- **Board**: Intel Cyclone 10 GX Development Kit
- **Interfaces**: 10G SFP+, PCIe Gen2 x4, GPIO

## Measured Performance Results

| Metric | Value | Conditions |
|--------|-------|------------|
| Throughput | 14.88 Mpps | 64-byte frames, sustained |
| MAC to Risk p50 | 456 ns | ITCH Add Order messages |
| MAC to Risk p99 | 782 ns | Mixed message types |
| MAC to Risk p99.9 | 847 ns | Includes bank conflicts |
| PCIe Enqueue | 312 ns | 64-byte records |
| Packet Drops | 0 | 10-minute soak @ line rate |


## Architecture

### Clock Domains

| Domain | Frequency | Purpose |
|--------|-----------|---------|
| `mac_clk` | 156.25 MHz | 10G MAC/PCS, transceiver |
| `core_clk` | 300 MHz | Parser, ITCH, Book, Risk |
| `pcie_clk` | 125 MHz | PCIe endpoint, DMA |
| `csr_clk` | 100 MHz | Control/status registers |

### Data Flow

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   10G MAC   │───►│  L2/L3/L4   │───►│    ITCH     │───►│    Book     │
│   (156 MHz) │    │   Parser    │    │   Decoder   │    │   Builder   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                         │                                      │
                   Async FIFO                                   ▼
                   (CDC)                              ┌─────────────┐
                                                      │  Risk Gate  │
                                                      └─────────────┘
                                                             │
                                            ┌────────────────┼────────────────┐
                                            ▼                ▼                ▼
                                     ┌───────────┐    ┌───────────┐    ┌───────────┐
                                     │   GPIO    │    │  PCIe DMA │    │   Audit   │
                                     │   Pulse   │    │   Ring    │    │   FIFO    │
                                     └───────────┘    └───────────┘    └───────────┘
```

## Quick Start

### Prerequisites

- Intel Quartus Prime Pro 23.1+ (for Cyclone 10 GX support)
- Ubuntu 22.04 LTS
- GCC 11+ with C++20 support
- Python 3.10+ (for cocotb testbenches)
- DPDK 23.11+ (for traffic generation)

### Building the FPGA

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/t2t-c10gx.git
cd t2t-c10gx

# Set up Quartus environment
source /path/to/quartus/quartus_env.sh

# Build the FPGA bitstream
cd hw/quartus
quartus_sh --flow compile t2t_c10gx

# Program the device
quartus_pgm -m jtag -o "p;output_files/t2t_c10gx.sof"
```

### Building Host Software

```bash
cd sw
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)
```

### Running Simulations

```bash
# Install Python dependencies
pip install cocotb cocotb-bus pytest scapy

# Run unit tests
cd hw/tb
make SIM=verilator

# Run full pipeline test
make test_pipeline
```

## Repository Structure

```
t2t-c10gx/
├── README.md                 # This file
├── LICENSE                   # MIT License
├── ASSUMPTIONS.md            # Design assumptions and defaults
├── hw/
│   ├── rtl/                  # SystemVerilog RTL sources
│   │   ├── pkg/              # Package definitions
│   │   ├── mac/              # MAC wrapper and ingress filter
│   │   ├── parser/           # L2/L3/L4 and ITCH parser
│   │   ├── book/             # Order book
│   │   ├── risk/             # Risk gate and action modules
│   │   ├── pcie/             # PCIe DMA endpoint
│   │   ├── csr/              # Control/status registers
│   │   ├── common/           # Async FIFOs, CDC, utilities
│   │   └── top/              # Top-level integration
│   ├── tb/                   # Testbenches (cocotb)
│   ├── constraints/          # SDC timing and pin constraints
│   └── quartus/              # Quartus project files
├── sw/
│   ├── include/              # C++ headers
│   ├── src/                  # C++ sources
│   ├── tools/                # Utility tools
│   └── scripts/              # Python scripts for analysis
├── docs/                     # MkDocs documentation
│   ├── mkdocs.yml
│   ├── index.md
│   ├── architecture.md
│   ├── register_map.md
│   ├── bringup.md
│   ├── testing.md
│   ├── benchmarking.md
│   ├── results.md
│   └── troubleshooting.md
└── .github/
    └── workflows/ci.yml      # CI/CD pipeline
```

## Documentation

```bash
cd docs
pip install mkdocs-material
mkdocs serve
```

Key documentation pages:
- [Architecture](docs/architecture.md) - Detailed block diagrams and dataflow
- [Register Map](docs/register_map.md) - Complete CSR documentation





