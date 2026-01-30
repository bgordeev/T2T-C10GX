/**
 * @file t2t_device.hpp
 * @brief Userspace driver for T2T-C10GX FPGA device
 *
 * This header provides the interface for interacting with the T2T
 * tick-to-trade FPGA device via PCIe BAR0 (CSR) and BAR2 (DMA rings).
 *
 * Features:
 * - MMIO register access (BAR0)
 * - DMA ring buffer management
 * - Hugepage allocation for DMA
 * - Statistics collection
 * - Configuration management
 *
 */

#ifndef T2T_DEVICE_HPP
#define T2T_DEVICE_HPP

#include <cstdint>
#include <cstddef>
#include <string>
#include <memory>
#include <vector>
#include <functional>
#include <atomic>
#include <optional>

namespace t2t {

//=============================================================================
// Constants
//=============================================================================

constexpr uint32_t T2T_VENDOR_ID = 0x1172;  // Intel FPGA
constexpr uint32_t T2T_DEVICE_ID = 0x0001;  // Custom device ID

constexpr size_t BAR0_SIZE = 4096;          // 4KB CSR space
constexpr size_t DMA_RING_ENTRIES = 65536;  // 64K entries
constexpr size_t DMA_RECORD_SIZE = 64;      // 64 bytes per record
constexpr size_t DMA_RING_SIZE = DMA_RING_ENTRIES * DMA_RECORD_SIZE;

// CSR Register Offsets (from t2t_pkg.sv)
namespace csr {
    constexpr uint32_t BUILD_ID        = 0x000;
    constexpr uint32_t CTRL            = 0x004;
    constexpr uint32_t PRICE_BAND_BPS  = 0x008;
    constexpr uint32_t TOKEN_RATE      = 0x00C;
    constexpr uint32_t POSITION_LIMIT  = 0x010;
    constexpr uint32_t STALE_USEC      = 0x014;
    constexpr uint32_t SEQ_GAP_THR     = 0x018;
    constexpr uint32_t KILL            = 0x01C;
    constexpr uint32_t SYMTAB_DATA     = 0x020;
    constexpr uint32_t SYMTAB_COMMIT   = 0x040;
    constexpr uint32_t EXPECTED_SEQ    = 0x050;
    constexpr uint32_t EXPECTED_PORT   = 0x054;
    constexpr uint32_t MCAST_MAC_LO    = 0x058;
    constexpr uint32_t MCAST_MAC_HI    = 0x05C;
    constexpr uint32_t LAT_HIST_BASE   = 0x100;
    constexpr uint32_t DROPS           = 0x180;
    constexpr uint32_t CRC_BAD         = 0x184;
    constexpr uint32_t SEQ_GAPS        = 0x188;
    constexpr uint32_t ACCEPTS         = 0x18C;
    constexpr uint32_t BLOCKS          = 0x190;
    constexpr uint32_t RING_BASE_LO    = 0x300;
    constexpr uint32_t RING_BASE_HI    = 0x304;
    constexpr uint32_t RING_LEN        = 0x308;
    constexpr uint32_t PROD_IDX        = 0x320;
    constexpr uint32_t CONS_IDX_SHADOW = 0x324;
    constexpr uint32_t MSIX_CFG        = 0x328;
}

// Control register bits
namespace ctrl {
    constexpr uint32_t ENABLE          = (1 << 0);
    constexpr uint32_t PROMISCUOUS     = (1 << 1);
    constexpr uint32_t MCAST_ENABLE    = (1 << 2);
    constexpr uint32_t CHECK_IP_CSUM   = (1 << 3);
    constexpr uint32_t SEQ_CHECK_EN    = (1 << 4);
    constexpr uint32_t MSIX_ENABLE     = (1 << 5);
}

//=============================================================================
// Data Structures
//=============================================================================

/**
 * @brief DMA record structure (64 bytes, cache-line aligned)
 */
struct alignas(64) DmaRecord {
    uint32_t seq;               // Offset 0
    uint32_t reserved0;         // Offset 4
    uint64_t ts_ing;            // Offset 8: Ingress timestamp
    uint64_t ts_dec;            // Offset 16: Decision timestamp
    uint16_t sym_idx;           // Offset 24: Symbol index
    uint8_t  side;              // Offset 26: 0=Bid, 1=Ask
    uint8_t  flags;             // Offset 27: Risk flags
    uint32_t qty;               // Offset 28: Quantity
    uint32_t price;             // Offset 32: Price
    uint32_t ref_px;            // Offset 36: Reference price
    uint32_t feature0;          // Offset 40: Bid-ask spread
    uint32_t feature1;          // Offset 44: Order imbalance
    uint32_t feature2;          // Offset 48: Last trade price
    uint16_t payload_crc16;     // Offset 52: CRC-16
    uint16_t pad;               // Offset 54
    uint64_t reserved1;         // Offset 56
    
    // Flag accessors
    bool accepted() const { return flags & 0x01; }
    bool stale() const { return flags & 0x02; }
    bool price_band_fail() const { return flags & 0x04; }
    bool token_fail() const { return flags & 0x08; }
    bool position_fail() const { return flags & 0x10; }
    bool kill_active() const { return flags & 0x20; }
    
    // Latency calculation (in nanoseconds at 300 MHz)
    uint64_t latency_ns() const {
        return (ts_dec - ts_ing) * 3333 / 1000;  // ~3.33 ns per cycle
    }
};
static_assert(sizeof(DmaRecord) == 64, "DmaRecord must be 64 bytes");

/**
 * @brief Device statistics
 */
struct Statistics {
    uint32_t rx_packets;
    uint32_t rx_bytes;
    uint32_t rx_crc_errors;
    uint32_t rx_drops;
    uint32_t parsed_packets;
    uint32_t messages;
    uint32_t seq_gaps;
    uint32_t book_updates;
    uint32_t bank_conflicts;
    uint32_t risk_accepts;
    uint32_t risk_rejects;
    uint32_t dma_records;
    uint32_t dma_drops;
    
    // Latency histogram (256 bins)
    std::vector<uint32_t> latency_histogram;
};

/**
 * @brief Device configuration
 */
struct Config {
    bool enable = false;
    bool promiscuous = false;
    bool mcast_enable = false;
    uint64_t mcast_mac = 0;
    bool check_ip_csum = true;
    uint16_t expected_port = 0;
    uint16_t price_band_bps = 500;  // 5%
    uint16_t token_rate = 1000;
    uint16_t token_max = 10000;
    int32_t position_limit = 1000000;
    uint32_t stale_usec = 100000;   // 100ms
    uint32_t seq_gap_thr = 100;
    bool kill_switch = false;
    uint32_t expected_seq = 1;
    bool seq_check_en = true;
    bool msix_enable = false;
    uint16_t msix_threshold = 256;
};

//=============================================================================
// Device Interface
//=============================================================================

/**
 * @brief Callback type for received DMA records
 */
using RecordCallback = std::function<void(const DmaRecord&)>;

/**
 * @brief T2T FPGA Device class
 *
 * Provides userspace access to the T2T tick-to-trade FPGA device.
 * Uses VFIO or UIO for safe userspace DMA and MMIO access.
 */
class Device {
public:
    /**
     * @brief Open device by PCIe BDF address
     * @param bdf PCIe address 
     * @return Device instance or nullptr on failure
     */
    static std::unique_ptr<Device> open(const std::string& bdf);
    
    /**
     * @brief Find and open first T2T device
     * @return Device instance or nullptr if not found
     */
    static std::unique_ptr<Device> find_first();
    
    ~Device();
    
    // Non-copyable
    Device(const Device&) = delete;
    Device& operator=(const Device&) = delete;
    
    //-------------------------------------------------------------------------
    // Configuration
    //-------------------------------------------------------------------------
    
    /**
     * @brief Apply configuration to device
     * @param cfg Configuration to apply
     * @return true on success
     */
    bool configure(const Config& cfg);
    
    /**
     * @brief Read current configuration from device
     * @return Current configuration
     */
    Config read_config() const;
    
    /**
     * @brief Enable or disable the device
     */
    void set_enable(bool enable);
    
    /**
     * @brief Set kill switch state
     */
    void set_kill_switch(bool kill);
    
    //-------------------------------------------------------------------------
    // Symbol Table Management
    //-------------------------------------------------------------------------
    
    /**
     * @brief Load symbol into symbol table
     * @param symbol 8-character symbol string
     * @param idx Symbol index (0-1023)
     * @return true on success
     */
    bool load_symbol(const std::string& symbol, uint16_t idx);
    
    /**
     * @brief Commit loaded symbols to active table
     * @return true on success
     */
    bool commit_symbols();
    
    /**
     * @brief Load symbols from file (one per line: SYMBOL,INDEX)
     * @param filename Path to symbol file
     * @return Number of symbols loaded, or -1 on error
     */
    int load_symbols_from_file(const std::string& filename);
    
    //-------------------------------------------------------------------------
    // Reference Price Management
    //-------------------------------------------------------------------------
    
    /**
     * @brief Set reference price for symbol
     * @param sym_idx Symbol index
     * @param price Reference price (4 decimal fixed-point)
     */
    void set_reference_price(uint16_t sym_idx, uint32_t price);
    
    /**
     * @brief Load reference prices from file
     * @param filename Path to price file (one per line: INDEX,PRICE)
     * @return Number of prices loaded, or -1 on error
     */
    int load_prices_from_file(const std::string& filename);
    
    //-------------------------------------------------------------------------
    // DMA Ring Access
    //-------------------------------------------------------------------------
    
    /**
     * @brief Initialize DMA ring buffer
     * @param entries Number of entries (default: 65536)
     * @return true on success
     */
    bool init_dma_ring(size_t entries = DMA_RING_ENTRIES);
    
    /**
     * @brief Poll for new DMA records (non-blocking)
     * @param callback Called for each new record
     * @return Number of records processed
     */
    size_t poll(RecordCallback callback);
    
    /**
     * @brief Poll with timeout
     * @param callback Called for each new record
     * @param timeout_us Timeout in microseconds
     * @return Number of records processed
     */
    size_t poll_timeout(RecordCallback callback, uint64_t timeout_us);
    
    /**
     * @brief Get current producer index
     */
    uint16_t producer_index() const;
    
    /**
     * @brief Get current consumer index
     */
    uint16_t consumer_index() const { return consumer_idx_; }
    
    /**
     * @brief Check if ring is empty
     */
    bool ring_empty() const;
    
    /**
     * @brief Check if ring is full
     */
    bool ring_full() const;
    
    //-------------------------------------------------------------------------
    // Statistics
    //-------------------------------------------------------------------------
    
    /**
     * @brief Read device statistics
     */
    Statistics read_statistics() const;
    
    /**
     * @brief Read latency histogram
     * @return Vector of 256 histogram bin counts
     */
    std::vector<uint32_t> read_latency_histogram() const;
    
    /**
     * @brief Print statistics summary to stdout
     */
    void print_statistics() const;
    
    //-------------------------------------------------------------------------
    // Low-level Register Access
    //-------------------------------------------------------------------------
    
    /**
     * @brief Read 32-bit CSR register
     */
    uint32_t read_reg(uint32_t offset) const;
    
    /**
     * @brief Write 32-bit CSR register
     */
    void write_reg(uint32_t offset, uint32_t value);
    
    /**
     * @brief Get build ID
     */
    uint32_t build_id() const { return read_reg(csr::BUILD_ID); }
    
private:
    Device();
    
    // Implementation details
    struct Impl;
    std::unique_ptr<Impl> impl_;
    
    // DMA ring state
    void* ring_buffer_ = nullptr;
    uint64_t ring_phys_addr_ = 0;
    size_t ring_entries_ = 0;
    std::atomic<uint16_t> consumer_idx_{0};
};

//=============================================================================
// Utility Functions
//=============================================================================

/**
 * @brief Convert price from 4-decimal fixed-point to double
 */
inline double price_to_double(uint32_t price) {
    return static_cast<double>(price) / 10000.0;
}

/**
 * @brief Convert price from double to 4-decimal fixed-point
 */
inline uint32_t double_to_price(double price) {
    return static_cast<uint32_t>(price * 10000.0 + 0.5);
}

/**
 * @brief Format timestamp as string
 */
std::string format_timestamp(uint64_t ts);

/**
 * @brief Format MAC address as string
 */
std::string format_mac(uint64_t mac);

/**
 * @brief Parse MAC address from string
 */
std::optional<uint64_t> parse_mac(const std::string& mac_str);

} // namespace t2t

#endif // T2T_DEVICE_HPP
