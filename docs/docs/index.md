# T2T-C10GX Documentation

## Overview

T2T-C10GX is a high-performance, low-latency market data processing pipeline implemented on an Intel Cyclone 10 GX FPGA. It processes NASDAQ ITCH 5.0 market data feeds and generates trading signals with sub-microsecond latency.


## Key Features

| Feature | Specification |
|---------|---------------|
| **Target Device** | Cyclone 10 GX 10GX220YF780E5G |
| **Network Interface** | 10G SFP+ (single port) |
| **Host Interface** | PCIe Gen2 x4 |
| **Protocol** | NASDAQ ITCH 5.0 |
| **Symbol Capacity** | 1,024 symbols |
| **Book Depth** | Top-of-Book (1 level) |
| **Target Latency** | p50: 456 ns, p99: 782 ns |

## Performance Targets

The pipeline is designed for ultra-low latency operation:

- **p50 Latency**: 456 ns (MAC RX → Risk decision)
- **p99 Latency**: 782 ns (including BRAM bank conflicts)
- **Throughput**: Line-rate 10 Gbps

## Quick Links

<div class="grid cards" markdown>

-   :material-rocket-launch:{ .lg .middle } **Getting Started**

    ---

    Set up your hardware and build the project

    [:octicons-arrow-right-24: Quick Start](getting-started/quickstart.md)

-   :material-chip:{ .lg .middle } **Architecture**

    ---

    Understand the pipeline design

    [:octicons-arrow-right-24: Overview](architecture/overview.md)

-   :material-code-braces:{ .lg .middle } **RTL Reference**

    ---

    Detailed module documentation

    [:octicons-arrow-right-24: Package Types](rtl/package.md)

-   :material-api:{ .lg .middle } **API Reference**

    ---

    Register map and DMA formats

    [:octicons-arrow-right-24: Registers](api/registers.md)

</div>

## Project Structure

```
t2t-c10gx/
├── hw/                     # Hardware (RTL)
│   ├── rtl/               # SystemVerilog source
│   │   ├── pkg/           # Package definitions
│   │   ├── mac/           # MAC wrapper
│   │   ├── parser/        # Protocol parsers
│   │   ├── book/          # Order book
│   │   ├── risk/          # Risk gate
│   │   ├── pcie/          # PCIe DMA
│   │   ├── csr/           # Control/Status
│   │   └── top/           # Top-level
│   ├── tb/                # Testbenches
│   ├── constraints/       # SDC files
│   └── quartus/           # Project files
├── sw/                     # Software
│   ├── include/           # C++ headers
│   ├── src/               # Source files
│   └── scripts/           # Utility scripts
└── docs/                   # Documentation
```

## License

This project is licensed under the MIT License. See [LICENSE](https://github.com/example/t2t-c10gx/blob/main/LICENSE) for details.

## Acknowledgments

- Intel FPGA for Cyclone 10 GX development tools
- NASDAQ for ITCH 5.0 protocol specification
- The open-source FPGA community
