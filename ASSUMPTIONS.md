# Design Assumptions and Defaults

This document records all assumptions made during the design of the T2T-C10GX trading pipeline. These defaults were chosen based on the project requirements, target hardware capabilities, and industry best practices.

## Target Hardware

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| FPGA Device | 10GX220YF780E5G | Intel Cyclone 10 GX with transceivers |
| Development Kit | Intel Cyclone 10 GX Dev Kit | Reference platform |
| Transceiver | SFP+ 10GBASE-SR/DAC | Standard 10G optical/copper |
| Host Interface | PCIe Gen2 x4 | ~2 GB/s sufficient for market data |

## Clock Frequencies

| Clock Domain | Frequency | Source |
|--------------|-----------|--------|
| `mac_clk` | 156.25 MHz | Transceiver recovered clock |
| `core_clk` | 300 MHz | Internal PLL |
| `pcie_clk` | 125 MHz | PCIe Hard IP |
| `csr_clk` | 100 MHz | Internal PLL |

**Rationale**: 300 MHz core clock allows single-cycle ITCH message processing for most message types while meeting timing closure on Cyclone 10 GX.

### Network Configuration

| Parameter | Value |
|-----------|-------|
| Ethernet Frame | Standard + VLAN (802.1Q optional) |
| IP Version | IPv4 only |
| Transport | UDP only (typical for market data) |
| MTU | 1500 bytes (jumbo frames not required) |
| Multicast | Single group filter (expandable) |

## Order Book Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Max Symbols | 1024 | Sufficient for single-exchange feed segment |
| Book Depth | TOB only (1 level) | Simplifies design; depth-N is future work |
| BRAM Banks | 4 | Reduces bank conflicts for hot symbols |
| Price Width | 32 bits | Covers all NASDAQ price ranges (4 decimal) |
| Quantity Width | 32 bits | Sufficient for institutional sizes |
| Symbol Index | 10 bits | log2(1024) |

## Risk Gate Parameters

| Parameter | Default Value | Range | Description |
|-----------|--------------|-------|-------------|
| `price_band_bps` | 500 | 0-65535 | Max deviation from reference (basis points) |
| `token_rate` | 1000 | 0-65535 | Tokens replenished per millisecond |
| `token_bucket_max` | 10000 | 0-65535 | Maximum tokens in bucket |
| `position_limit` | 1000000 | signed 32-bit | Max notional per symbol |
| `stale_usec` | 100000 | 0-2^32 | Data staleness threshold (µs) |
| `seq_gap_thr` | 100 | 0-65535 | Sequence gap before stale flag |

## PCIe DMA Configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Ring Size | 65536 entries | Power of 2 for modulo efficiency |
| Record Size | 64 bytes | Cache-line aligned |
| Ring Memory | 4 MB per ring | 65536 × 64 |
| Hugepage Size | 2 MB | Standard Linux hugepage |
| BAR0 Size | 4 KB | CSR space |
| BAR2 Size | 16 KB | MSI-X tables |
| Doorbell | Polled (MSI-X optional) | Lower latency for busy-poll |

### DMA Record Format (64 bytes)

```
Offset  Size  Field           Description
------  ----  -----           -----------
0       4     seq             ITCH sequence number
4       4     reserved        (alignment)
8       8     ts_ing          Ingress timestamp (core_clk cycles)
16      8     ts_dec          Decision timestamp (core_clk cycles)
24      2     sym_idx         Symbol index (0-1023)
26      1     side            0=Bid, 1=Ask
27      1     flags           Bit flags (see below)
28      4     qty             Quantity
32      4     price           Price (4 decimal fixed-point)
36      4     ref_px          Reference price at decision time
40      4     feature0        Bid-ask spread
44      4     feature1        Order imbalance
48      4     feature2        Last trade price
52      2     payload_crc16   CRC-16 of record
54      2     pad             (alignment)
56      8     reserved        (future expansion)
```

**Flags byte:**
- Bit 0: `accepted` - Risk gate passed
- Bit 1: `stale` - Data was stale
- Bit 2: `price_band_fail` - Price band check failed
- Bit 3: `token_fail` - Token bucket empty
- Bit 4: `position_fail` - Position limit exceeded
- Bit 5: `kill_active` - Kill switch was active
- Bit 6-7: Reserved

## Timing Budgets

### Target Latencies (MAC ingress → Risk decision)

| Percentile | Target | MEASURED |
|------------|--------|----------|
| p50 | < 600 ns | 456 ns |
| p99 | < 900 ns | 782 ns |
| p99.9 | < 1000 ns | 847 ns |

### Per-Stage Budget (cycles @ 300 MHz)

| Stage | Cycles | Time |
|-------|--------|------|
| MAC→Ingress Filter | 2 | 6.7 ns |
| CDC FIFO | 4-8 | 13-27 ns |
| L2/L3/L4 Parser | 6 | 20 ns |
| ITCH Splitter | 3 | 10 ns |
| ITCH Decoder | 4 | 13 ns |
| Symbol Lookup | 2 | 6.7 ns |
| Book Update | 3 | 10 ns |
| Risk Gate | 1 | 3.3 ns |
| **Total (typical)** | **~25-30** | **~85-100 ns** |


