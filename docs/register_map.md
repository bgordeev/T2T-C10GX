# T2T-C10GX Register Map

## Overview

The T2T-C10GX device exposes a 4KB register space via PCIe BAR0. All registers
are 32-bit aligned and accessed via Avalon-MM interface.

## Register Summary

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x000 | BUILD_ID | RO | Build identification |
| 0x004 | CTRL | RW | Global control register |
| 0x008 | PRICE_BAND_BPS | RW | Price band threshold (basis points) |
| 0x00C | TOKEN_RATE | RW | Token bucket rate/max |
| 0x010 | POSITION_LIMIT | RW | Position limit per symbol |
| 0x014 | STALE_USEC | RW | Staleness threshold (microseconds) |
| 0x018 | SEQ_GAP_THR | RW | Sequence gap threshold |
| 0x01C | KILL | RW | Kill switch control |
| 0x020-0x03C | SYMTAB_DATA | WO | Symbol table data staging |
| 0x040 | SYMTAB_COMMIT | WO | Symbol table commit trigger |
| 0x050 | EXPECTED_SEQ | RW | Expected sequence number |
| 0x054 | EXPECTED_PORT | RW | Expected UDP port |
| 0x058 | MCAST_MAC_LO | RW | Multicast MAC [31:0] |
| 0x05C | MCAST_MAC_HI | RW | Multicast MAC [47:32] |
| 0x060 | REF_PRICE_ADDR | WO | Reference price address |
| 0x064 | REF_PRICE_DATA | WO | Reference price data (triggers write) |
| 0x0F0 | BUILD_TS | RO | Build timestamp |
| 0x0F4 | BUILD_HASH | RO | Git commit hash |
| 0x100-0x17F | LAT_HIST | RO | Latency histogram (32 bins shown) |
| 0x180 | DROPS | RO | RX drop counter |
| 0x184 | CRC_BAD | RO | CRC error counter |
| 0x188 | SEQ_GAPS | RO | Sequence gap counter |
| 0x18C | ACCEPTS | RO | Risk accept counter |
| 0x190 | BLOCKS | RO | Risk reject counter |
| 0x194 | RX_PACKETS | RO | RX packet counter |
| 0x198 | RX_BYTES | RO | RX byte counter |
| 0x19C | PARSED_PKTS | RO | Parsed packet counter |
| 0x1A0 | MESSAGES | RO | ITCH message counter |
| 0x1A4 | BOOK_UPDATES | RO | Book update counter |
| 0x1A8 | BANK_CONFLICTS | RO | BRAM bank conflict counter |
| 0x1AC | DMA_RECORDS | RO | DMA record counter |
| 0x1B0 | DMA_DROPS | RO | DMA drop counter |
| 0x300 | RING_BASE_LO | RW | DMA ring base address [31:0] |
| 0x304 | RING_BASE_HI | RW | DMA ring base address [63:32] |
| 0x308 | RING_LEN | RW | DMA ring length (entries) |
| 0x320 | PROD_IDX | RO | Producer index |
| 0x324 | CONS_IDX_SHADOW | RW | Consumer index shadow |
| 0x328 | MSIX_CFG | RW | MSI-X configuration |

## Register Details

### BUILD_ID (0x000)

| Bits | Name | Description |
|------|------|-------------|
| 31:16 | MAGIC | Magic number (0x5432 = "T2") |
| 15:8 | VERSION_MAJOR | Major version |
| 7:0 | VERSION_MINOR | Minor version |

### CTRL (0x004)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | ENABLE | Global enable (1 = enabled) |
| 1 | PROMISCUOUS | Accept all packets (1 = promiscuous) |
| 2 | MCAST_ENABLE | Enable multicast filtering |
| 3 | CHECK_IP_CSUM | Verify IP header checksum |
| 4 | SEQ_CHECK_EN | Enable sequence number checking |
| 5 | MSIX_ENABLE | Enable MSI-X interrupts |
| 31:6 | Reserved | Reserved (write as 0) |

### PRICE_BAND_BPS (0x008)

| Bits | Name | Description |
|------|------|-------------|
| 15:0 | BPS | Price band in basis points (e.g., 500 = 5%) |
| 31:16 | Reserved | Reserved |

### TOKEN_RATE (0x00C)

| Bits | Name | Description |
|------|------|-------------|
| 15:0 | RATE | Tokens added per millisecond |
| 31:16 | MAX | Maximum bucket size |

### POSITION_LIMIT (0x010)

| Bits | Name | Description |
|------|------|-------------|
| 31:0 | LIMIT | Maximum position per symbol (signed) |

### STALE_USEC (0x014)

| Bits | Name | Description |
|------|------|-------------|
| 31:0 | USEC | Staleness threshold in microseconds |

### SEQ_GAP_THR (0x018)

| Bits | Name | Description |
|------|------|-------------|
| 31:0 | THRESHOLD | Max allowed sequence gaps before stale flag |

### KILL (0x01C)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | ACTIVE | Kill switch (1 = block all orders) |
| 31:1 | Reserved | Reserved |

### SYMTAB_DATA (0x020-0x03C)

Symbol table entry staging registers:

| Offset | Content |
|--------|---------|
| 0x020 | Symbol key bytes [3:0] (little-endian) |
| 0x024 | Symbol key bytes [7:4] |
| 0x028 | Symbol index [9:0] |
| 0x02C | Reserved |

### SYMTAB_COMMIT (0x040)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | LOAD | Load staged entry into shadow table |
| 1 | COMMIT | Swap shadow and active tables |
| 31:2 | Reserved | Reserved |

### RING_BASE_LO/HI (0x300, 0x304)

64-bit physical address of DMA ring buffer in host memory.

### RING_LEN (0x308)

| Bits | Name | Description |
|------|------|-------------|
| 15:0 | LEN | Ring buffer length in entries (power of 2) |
| 31:16 | Reserved | Reserved |

### PROD_IDX (0x320)

| Bits | Name | Description |
|------|------|-------------|
| 15:0 | INDEX | Current producer index (read-only) |
| 31:16 | Reserved | Reserved |

### CONS_IDX_SHADOW (0x324)

| Bits | Name | Description |
|------|------|-------------|
| 15:0 | INDEX | Consumer index (written by software) |
| 31:16 | Reserved | Reserved |

### MSIX_CFG (0x328)

| Bits | Name | Description |
|------|------|-------------|
| 15:0 | THRESHOLD | Records before interrupt |
| 31:16 | Reserved | Reserved |

## DMA Record Format

Each DMA record is 64 bytes (cache-line aligned):

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 | 4 | seq | Record sequence number |
| 4 | 4 | reserved | Reserved |
| 8 | 8 | ts_ing | Ingress timestamp (cycles) |
| 16 | 8 | ts_dec | Decision timestamp (cycles) |
| 24 | 2 | sym_idx | Symbol index |
| 26 | 1 | side | Side (0=Bid, 1=Ask) |
| 27 | 1 | flags | Status flags |
| 28 | 4 | qty | Quantity |
| 32 | 4 | price | Price (4 decimal fixed-point) |
| 36 | 4 | ref_px | Reference price |
| 40 | 4 | feature0 | Bid-ask spread |
| 44 | 4 | feature1 | Order imbalance |
| 48 | 4 | feature2 | Last trade price |
| 52 | 2 | crc16 | Payload CRC-16 |
| 54 | 2 | pad | Padding |
| 56 | 8 | reserved | Reserved |

### Flags Byte

| Bit | Name | Description |
|-----|------|-------------|
| 0 | ACCEPT | Order accepted (1) or rejected (0) |
| 1 | STALE | Data was marked stale |
| 2 | PRICE_BAND | Rejected: price band violation |
| 3 | TOKEN | Rejected: token bucket empty |
| 4 | POSITION | Rejected: position limit exceeded |
| 5 | KILL | Rejected: kill switch active |
| 7:6 | Reserved | Reserved |

## Latency Histogram

The latency histogram has 256 bins starting at offset 0x100. Each bin is a
32-bit counter. Bin width is 4 clock cycles (~13 ns at 300 MHz).

| Bin | Latency Range |
|-----|---------------|
| 0 | 0-13 ns |
| 1 | 13-27 ns |
| 2 | 27-40 ns |
| ... | ... |
| 255 | 3387+ ns |

Read each bin: `histogram[i] = read_reg(0x100 + i*4)`

## Programming Sequence

### Initialization

1. Read BUILD_ID to verify device presence
2. Clear CTRL (disable device)
3. Configure RING_BASE_LO/HI with DMA buffer address
4. Set RING_LEN (must be power of 2)
5. Load symbol table entries
6. Commit symbol table
7. Load reference prices
8. Set risk parameters
9. Set CTRL.ENABLE to start

### Symbol Table Load

```c
// Load symbol "AAPL    " at index 0
write_reg(SYMTAB_DATA+0, 0x4C504141);  // "LPAA" little-endian
write_reg(SYMTAB_DATA+4, 0x20202020);  // "    " padding
write_reg(SYMTAB_DATA+8, 0);           // Index 0
write_reg(SYMTAB_COMMIT, 1);           // Load entry

// Repeat for all symbols...

write_reg(SYMTAB_COMMIT, 2);           // Commit (swap tables)
```

### Reference Price Load

```c
// Set reference price for symbol 0 to $150.00
write_reg(REF_PRICE_ADDR, 0);          // Symbol index
write_reg(REF_PRICE_DATA, 1500000);    // Price * 10000
```

### DMA Polling

```c
while (running) {
    uint16_t prod = read_reg(PROD_IDX) & 0xFFFF;
    while (cons != prod) {
        DmaRecord* rec = &ring[cons];
        process(rec);
        cons = (cons + 1) & (ring_len - 1);
    }
    write_reg(CONS_IDX_SHADOW, cons);
}
```
