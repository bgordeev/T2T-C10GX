# Register Map

The T2T-C10GX device exposes a 4KB control/status register (CSR) space via PCIe BAR0.

## Register Summary

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x000 | BUILD_ID | RO | Build identifier |
| 0x004 | CTRL | RW | Global control register |
| 0x008 | PRICE_BAND_BPS | RW | Price band (basis points) |
| 0x00C | TOKEN_RATE | RW | Token bucket rate |
| 0x010 | POSITION_LIMIT | RW | Position limit per symbol |
| 0x014 | STALE_USEC | RW | Staleness timeout (μs) |
| 0x018 | SEQ_GAP_THR | RW | Sequence gap threshold |
| 0x01C | KILL | RW | Kill switch |
| 0x020-0x03C | SYMTAB_DATA | RW | Symbol table staging |
| 0x040 | SYMTAB_COMMIT | WO | Symbol table commit |
| 0x050 | EXPECTED_SEQ | RW | Expected sequence number |
| 0x054 | EXPECTED_PORT | RW | Expected UDP port |
| 0x058 | MCAST_MAC_LO | RW | Multicast MAC (low 32 bits) |
| 0x05C | MCAST_MAC_HI | RW | Multicast MAC (high 16 bits) |
| 0x060 | REF_PRICE_ADDR | WO | Reference price address |
| 0x064 | REF_PRICE_DATA | WO | Reference price data |
| 0x0F0 | BUILD_TS | RO | Build timestamp |
| 0x0F4 | GIT_HASH | RO | Git commit hash |
| 0x100-0x17F | LAT_HIST | RO | Latency histogram (256 bins) |
| 0x180 | DROPS | RO | Dropped packet count |
| 0x184 | CRC_BAD | RO | CRC error count |
| 0x188 | SEQ_GAPS | RO | Sequence gap count |
| 0x18C | ACCEPTS | RO | Risk accepts count |
| 0x190 | BLOCKS | RO | Risk blocks count |
| 0x300 | RING_BASE_LO | RW | Ring buffer base (low) |
| 0x304 | RING_BASE_HI | RW | Ring buffer base (high) |
| 0x308 | RING_LEN | RW | Ring buffer length |
| 0x320 | PROD_IDX | RO | Producer index |
| 0x324 | CONS_IDX_SHADOW | RW | Consumer index shadow |
| 0x328 | MSIX_CFG | RW | MSI-X configuration |

## Detailed Register Descriptions

### BUILD_ID (0x000)

Read-only build identifier.

| Bits | Field | Description |
|------|-------|-------------|
| 31:16 | MAGIC | "T2T" identifier (0x5432) |
| 15:8 | MAJOR | Major version |
| 7:0 | MINOR | Minor version |

### CTRL (0x004)

Global control register.

| Bit | Field | Description |
|-----|-------|-------------|
| 0 | ENABLE | Enable pipeline processing |
| 1 | PROMISCUOUS | Accept all packets (ignore MAC filter) |
| 2 | MCAST_ENABLE | Enable multicast MAC filtering |
| 3 | CHECK_IP_CSUM | Verify IP header checksum |
| 4 | SEQ_CHECK_EN | Enable sequence number checking |
| 5 | MSIX_ENABLE | Enable MSI-X interrupts |
| 31:6 | Reserved | Read as 0 |

### PRICE_BAND_BPS (0x008)

Price band configuration in basis points.

| Bits | Field | Description |
|------|-------|-------------|
| 15:0 | BPS | Basis points (e.g., 500 = 5%) |
| 31:16 | Reserved | Read as 0 |

**Example:** A value of 500 means prices must be within ±5% of the reference price.

### TOKEN_RATE (0x00C)

Token bucket rate limiter configuration.

| Bits | Field | Description |
|------|-------|-------------|
| 15:0 | RATE | Tokens added per millisecond |
| 31:16 | MAX | Maximum bucket size |

### POSITION_LIMIT (0x010)

Maximum position limit per symbol (signed 32-bit integer).

### STALE_USEC (0x014)

Data staleness timeout in microseconds. Data older than this threshold is rejected.

### KILL (0x01C)

Kill switch register. Writing 1 to bit 0 immediately blocks all trading signals.

| Bit | Field | Description |
|-----|-------|-------------|
| 0 | KILL | Kill switch active when 1 |
| 31:1 | Reserved | Read as 0 |

!!! warning "Kill Switch"
    The kill switch takes effect within 2 clock cycles (~7 ns) and blocks all risk accepts until cleared.

### Symbol Table Registers (0x020-0x040)

Symbol table entries are loaded through staging registers:

1. Write 8-byte symbol key to SYMTAB_DATA[0:1]
2. Write symbol index to SYMTAB_DATA[2]
3. Write 1 to SYMTAB_COMMIT to load entry
4. Repeat for all symbols
5. Write 2 to SYMTAB_COMMIT to commit and activate

### Ring Buffer Registers (0x300-0x328)

DMA ring buffer configuration:

| Register | Description |
|----------|-------------|
| RING_BASE_LO/HI | 64-bit physical address of ring buffer |
| RING_LEN | Number of entries (must be power of 2) |
| PROD_IDX | Hardware producer index (read-only) |
| CONS_IDX_SHADOW | Software consumer index (write to update) |

### Latency Histogram (0x100-0x17F)

256 32-bit counters representing latency distribution. Each bin covers 4 clock cycles (~13 ns at 300 MHz).

```c
// Read histogram
for (int i = 0; i < 256; i++) {
    histogram[i] = read_reg(0x100 + i * 4);
}
```

## Programming Sequence

### Initialization

```c
// 1. Disable pipeline during configuration
write_reg(CTRL, 0);

// 2. Configure risk parameters
write_reg(PRICE_BAND_BPS, 500);    // 5%
write_reg(TOKEN_RATE, 1000 | (10000 << 16));  // 1000/ms, max 10000
write_reg(POSITION_LIMIT, 1000000);
write_reg(STALE_USEC, 100000);     // 100ms

// 3. Configure ring buffer
write_reg(RING_BASE_LO, ring_phys & 0xFFFFFFFF);
write_reg(RING_BASE_HI, ring_phys >> 32);
write_reg(RING_LEN, 65536);

// 4. Load symbol table (see Symbol Table section)

// 5. Enable pipeline
write_reg(CTRL, ENABLE | CHECK_IP_CSUM | SEQ_CHECK_EN);
```

### Poll for Records

```c
while (running) {
    uint16_t prod = read_reg(PROD_IDX) & 0xFFFF;
    
    while (cons_idx != prod) {
        process_record(&ring[cons_idx]);
        cons_idx = (cons_idx + 1) & (ring_len - 1);
    }
    
    write_reg(CONS_IDX_SHADOW, cons_idx);
}
```
