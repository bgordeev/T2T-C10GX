# T2T-C10GX Architecture Guide

## Overview

The T2T-C10GX is a hardware tick-to-trade pipeline implemented on an Intel
Cyclone 10 GX FPGA. It processes NASDAQ ITCH 5.0 market data feed and generates
trading signals with sub-microsecond latency.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            T2T-C10GX Architecture                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐        │
│  │  10G    │   │  L2/L3/ │   │  ITCH   │   │  ITCH   │   │ Symbol  │        │
│  │  MAC    │──▶│   L4    │──▶│ Split   │──▶│ Decode  │──▶│  Table  │        │
│  │  Wrap   │   │ Parser  │   │         │   │         │   │  (CAM)  │        │
│  └─────────┘   └─────────┘   └─────────┘   └─────────┘   └────┬────┘        │
│       │                                                       │             │
│  156.25 MHz ─────── 300 MHz (Core Clock Domain) ─────────────-│             │
│                                                               │             │
│                                                               ▼             │ 
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐        │
│  │  PCIe   │◀──│   DMA   │◀──│  Risk   │◀──│  Book   │◀──│  TOB    │        │ 
│  │  HIP    │   │ Engine  │   │  Gate   │   │ Builder │   │  BRAM   │        │
│  └─────────┘   └─────────┘   └─────────┘   └─────────┘   └─────────┘        │ 
│       │                           │                                         │
│  125 MHz ─────────────────────────│───────────────────────────────────────  │
│                                   │                                         │
│                             ┌─────┴─────┐                                   │
│                             │   GPIO    │                                   │
│                             │  Pulse    │ ──▶ Oscilloscope                  │
│                             └───────────┘                                   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                     CSR Block (100 MHz)                              │   │
│  │  • Configuration registers                                           │   │
│  │  • Statistics counters                                               │   │
│  │  • Latency histogram                                                 │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Clock Domains

| Domain | Frequency | Purpose |
|--------|-----------|---------|
| mac_clk | 156.25 MHz | 10G Ethernet transceiver |
| core_clk | 300 MHz | Main processing pipeline |
| pcie_clk | 125 MHz | PCIe endpoint |
| csr_clk | 100 MHz | Configuration/status |

All clock domain crossings use dual-FF synchronizers for single bits and
Gray-coded async FIFOs for multi-bit data.

## Pipeline Stages

### 1. MAC Wrapper (`mac_wrap.sv`)

- Interfaces with Intel 10G MAC Hard IP
- Captures ingress timestamp (64-bit cycle counter)
- Performs CRC verification
- Filters by multicast MAC address
- Extracts Ethernet header (14 bytes)
- Crosses from mac_clk to core_clk via async FIFO

**Latency:** ~10-15 cycles at 156.25 MHz

### 2. L2/L3/L4 Parser (`l2l3l4_parser.sv`)

- 4-stage pipelined parser
- Extracts Ethernet, IP, UDP headers
- Verifies IP checksum (parallel accumulation)
- Validates IP version, protocol, UDP port
- Calculates UDP payload offset

**Latency:** 4 cycles at 300 MHz (~13 ns)

### 3. ITCH Splitter (`itch_splitter.sv`)

- Splits UDP payload into individual ITCH messages
- Handles variable-length messages (1-50 bytes)
- Tracks sequence numbers for gap detection
- Buffers partial messages across packet boundaries

**Latency:** 1-3 cycles at 300 MHz (message dependent)

### 4. ITCH Decoder (`itch_decoder.sv`)

- Decodes NASDAQ ITCH 5.0 message fields
- Supports: Add Order (A/F), Execute (E/C), Cancel (X), Delete (D), Replace (U), Trade (P)
- Big-endian to little-endian conversion
- Initiates symbol table lookup

**Latency:** 2 cycles at 300 MHz (~7 ns)

### 5. Symbol Table (`symtab_cam.sv`)

- 1024-entry Content-Addressable Memory
- 8-byte symbol key (padded with spaces)
- Hash-based indexing with linear probing
- Double-buffered for atomic updates
- Single-cycle lookup

**Latency:** 1 cycle at 300 MHz (~3 ns)

### 6. Book Builder (`book_tob.sv`)

- Maintains top-of-book (TOB) for 1024 symbols
- 4 BRAM banks to reduce hot-symbol conflicts
- Tracks bid/ask price and quantity
- Records last trade price
- Generates book events on TOB changes

**Latency:** 3-4 cycles at 300 MHz (~10-13 ns)

### 7. Risk Gate (`risk_gate.sv`)

Pre-trade risk checks (all single-cycle):

| Check | Description |
|-------|-------------|
| Price Band | `|price - ref_price| / ref_price < threshold` |
| Token Bucket | Per-symbol rate limiting |
| Position Limit | Aggregate position check |
| Staleness | Reject if data too old |
| Kill Switch | Global order blocking |

**Latency:** 2 cycles at 300 MHz (~7 ns)

### 8. DMA Engine (`pcie_dma.sv`)

- 64-byte cache-line aligned records
- 64K entry ring buffer (4 MB)
- Hardware producer index, software consumer index
- MSI-X interrupt support
- Crosses from core_clk to pcie_clk

**Latency:** Variable (PCIe dependent)

## Resource Utilization

Estimated for Cyclone 10 GX 10GX220YF780E5G:

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| ALMs | ~25,000 | 80,330 | ~31% |
| Registers | ~40,000 | 322,640 | ~12% |
| Block RAM (M20K) | ~200 | 587 | ~34% |
| DSP Blocks | ~10 | 192 | ~5% |
| PLLs | 2 | 8 | 25% |
| Transceivers | 5 | 24 | ~21% |

## Latency Budget

Target: p50 < 500 ns, p99 < 800 ns (MAC RX to Risk decision)

| Stage | Cycles | Time (ns) | Cumulative |
|-------|--------|-----------|------------|
| MAC ingress | 10 | 64 | 64 |
| CDC FIFO | 8 | 27 | 91 |
| L2/L3/L4 Parser | 4 | 13 | 104 |
| ITCH Splitter | 2 | 7 | 111 |
| ITCH Decoder | 2 | 7 | 118 |
| Symbol Lookup | 1 | 3 | 121 |
| Book Builder | 4 | 13 | 134 |
| Risk Gate | 2 | 7 | 141 |
| **Total** | **33** | **141** | **~150 ns** |

Note: Actual latency varies with message type, BRAM bank conflicts, and CDC
FIFO fill levels. The 150 ns estimate is for a best-case Add Order message.

## Memory Architecture

### Symbol Table (CAM)

- 1024 entries × 80 bits = 10 KB
- Implemented in M20K block RAM
- Hash function: CRC-based with linear probing

### Book State (TOB)

- 1024 symbols × 2 sides × 64 bits = 128 KB
- 4 BRAM banks indexed by `symbol_idx[1:0]`
- Each bank: 256 entries × 64 bits

### Reference Prices

- 1024 entries × 32 bits = 4 KB
- Single M20K block RAM

### Token Buckets

- 1024 entries × 16 bits = 2 KB
- Distributed RAM or M20K

### Latency Histogram

- 256 bins × 32 bits = 1 KB
- M20K block RAM

## Configuration Interface

The CSR block provides an Avalon-MM slave interface for configuration:

- 4KB address space mapped to PCIe BAR0
- 32-bit read/write registers
- Single-cycle access (no wait states)
- Clock domain: csr_clk (100 MHz)

Configuration is synchronized to core_clk using CDC techniques.

## DMA Interface

The DMA engine provides zero-copy data transfer to host memory:

- Ring buffer with configurable size (up to 64K entries)
- 64-byte records (cache-line aligned)
- Producer/consumer model
- Polling or MSI-X notification

Host software updates the consumer index after processing records.

## Debug Features

- SignalTap II support for internal probing
- GPIO pulse output for oscilloscope latency measurement
- Status LEDs for visual monitoring
- Statistics counters accessible via CSR

## Power Management

Estimated power consumption: ~5W (FPGA core + transceivers)

- Core logic: ~2W
- Transceivers: ~2W (10G + PCIe)
- I/O: ~0.5W
- Clocks/PLLs: ~0.5W

Cooling requirement: Adequate heatsink with forced airflow recommended.

## Error Handling

| Error | Detection | Recovery |
|-------|-----------|----------|
| CRC Error | MAC layer | Drop packet, increment counter |
| IP Checksum | Parser | Drop packet, increment counter |
| Sequence Gap | Splitter | Set stale flag, continue |
| Unknown Message | Decoder | Skip message, increment counter |
| Symbol Not Found | CAM | Use default index (0), log |
| Ring Full | DMA | Drop record, increment counter |
