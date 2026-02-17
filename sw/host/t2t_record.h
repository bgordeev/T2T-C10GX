// ============================================================================
// File: record.h
// Description: Shared record structure for FPGA-to-host DMA transfers
//              64-byte fixed layout, matches FPGA hardware exactly
// ============================================================================

#ifndef T2T_RECORD_H
#define T2T_RECORD_H

#include <cstdint>
#include <cstring>

// Force structure to be packed - no padding bytes inserted by compiler
#pragma pack(push, 1)

struct T2TRecord {
    // Bytes 0-3: ITCH sequence number
    uint32_t  seq;
    
    // Bytes 4-7: Reserved for alignment
    uint32_t  reserved0;
    
    // Bytes 8-15: Ingress timestamp (ns from FPGA counter)
    uint64_t  ts_ingress;
    
    // Bytes 16-23: Decoder completion timestamp
    uint64_t  ts_decode;
    
    // Bytes 24-25: Symbol index (from CAM lookup)
    uint16_t  symbol_idx;
    
    // Byte 26: Side (0=bid, 1=ask)
    uint8_t   side;
    
    // Byte 27: Flags
    //   [0]: stale (sequence gap detected)
    //   [1]: risk_accept
    //   [2-4]: risk_reason (0=none, 1=price_band, 2=rate, 3=position, 4=kill)
    uint8_t   flags;
    
    // Bytes 28-31: Reserved
    uint32_t  reserved1;
    
    // Bytes 32-35: BBO quantity
    uint32_t  quantity;
    
    // Bytes 36-39: BBO price (× 10000, e.g. $150.25 = 1502500)
    uint32_t  price;
    
    // Bytes 40-43: Reference mid-market price
    uint32_t  ref_price;
    
    // Bytes 44-47: Feature 0 - spread in basis points
    uint32_t  feature0;
    
    // Bytes 48-51: Feature 1 - volume imbalance ratio
    uint32_t  feature1;
    
    // Bytes 52-55: Feature 2 - reserved for strategy
    uint32_t  feature2;
    
    // Bytes 56-57: CRC16 of record (optional validation)
    uint16_t  payload_crc;
    
    // Bytes 58-63: Padding to 64 bytes
    uint8_t   reserved[6];
    
    // Helper methods
    bool is_stale() const { return flags & 0x01; }
    bool is_accepted() const { return flags & 0x02; }
    uint8_t risk_reason() const { return (flags >> 2) & 0x07; }
    
    // Price conversion helpers
    double price_as_double() const { return price / 10000.0; }
    double ref_price_as_double() const { return ref_price / 10000.0; }
    
    // Spread in basis points
    uint32_t spread_bps() const { return feature0; }
    
    // Latency calculation (decode - ingress)
    uint64_t latency_ns() const { 
        return ts_decode > ts_ingress ? (ts_decode - ts_ingress) : 0;
    }
};

#pragma pack(pop)

// Compile-time size check - this MUST be exactly 64 bytes
static_assert(sizeof(T2TRecord) == 64, "T2TRecord struct must be exactly 64 bytes");

// Risk reason codes (match FPGA definitions)
enum class RiskReason : uint8_t {
    NONE     = 0,
    PRICE_BAND = 1,
    RATE_LIMIT = 2,
    POSITION   = 3,
    KILL_SWITCH = 4
};

// Side codes
enum class Side : uint8_t {
    BID = 0,
    ASK = 1
};

#endif // T2T_RECORD_H
