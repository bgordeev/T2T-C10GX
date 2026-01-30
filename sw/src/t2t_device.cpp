/**
 * @file t2t_device.cpp
 * @brief Implementation of T2T-C10GX userspace driver
 */

#include "t2t_device.hpp"

#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <dirent.h>
#include <cstring>
#include <fstream>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <chrono>
#include <thread>

namespace t2t {

//=============================================================================
// Implementation Details
//=============================================================================

struct Device::Impl {
    int uio_fd = -1;
    void* bar0 = nullptr;
    size_t bar0_size = BAR0_SIZE;
    std::string bdf;
    
    ~Impl() {
        if (bar0 != nullptr && bar0 != MAP_FAILED) {
            munmap(bar0, bar0_size);
        }
        if (uio_fd >= 0) {
            close(uio_fd);
        }
    }
};

//=============================================================================
// Device Implementation
//=============================================================================

Device::Device() : impl_(std::make_unique<Impl>()) {}

Device::~Device() {
    if (ring_buffer_ != nullptr && ring_buffer_ != MAP_FAILED) {
        munmap(ring_buffer_, ring_entries_ * DMA_RECORD_SIZE);
    }
}

std::unique_ptr<Device> Device::open(const std::string& bdf) {
    auto device = std::unique_ptr<Device>(new Device());
    
    // Find UIO device for this BDF
    std::string uio_path;
    DIR* dir = opendir("/sys/class/uio");
    if (!dir) {
        std::cerr << "Error: Cannot open /sys/class/uio - is UIO driver loaded?\n";
        return nullptr;
    }
    
    struct dirent* entry;
    while ((entry = readdir(dir)) != nullptr) {
        if (strncmp(entry->d_name, "uio", 3) != 0) continue;
        
        std::string device_link = "/sys/class/uio/" + std::string(entry->d_name) + "/device";
        char resolved[PATH_MAX];
        if (realpath(device_link.c_str(), resolved) == nullptr) continue;
        
        // Check if this UIO device corresponds to our BDF
        if (strstr(resolved, bdf.c_str()) != nullptr) {
            uio_path = "/dev/" + std::string(entry->d_name);
            break;
        }
    }
    closedir(dir);
    
    if (uio_path.empty()) {
        std::cerr << "Error: No UIO device found for BDF " << bdf << "\n";
        return nullptr;
    }
    
    // Open UIO device
    device->impl_->uio_fd = ::open(uio_path.c_str(), O_RDWR | O_SYNC);
    if (device->impl_->uio_fd < 0) {
        std::cerr << "Error: Cannot open " << uio_path << ": " << strerror(errno) << "\n";
        return nullptr;
    }
    
    // Map BAR0 (CSR space)
    device->impl_->bar0 = mmap(nullptr, BAR0_SIZE, PROT_READ | PROT_WRITE,
                                MAP_SHARED, device->impl_->uio_fd, 0);
    if (device->impl_->bar0 == MAP_FAILED) {
        std::cerr << "Error: Cannot mmap BAR0: " << strerror(errno) << "\n";
        return nullptr;
    }
    
    device->impl_->bdf = bdf;
    
    // Verify device by checking build ID
    uint32_t build_id = device->read_reg(csr::BUILD_ID);
    if ((build_id & 0xFFFF0000) != 0x54325400) {  // "T2T\0" in upper bytes
        std::cerr << "Warning: Unexpected build ID: 0x" << std::hex << build_id << std::dec << "\n";
    }
    
    return device;
}

std::unique_ptr<Device> Device::find_first() {
    // Scan PCIe devices for T2T
    DIR* dir = opendir("/sys/bus/pci/devices");
    if (!dir) return nullptr;
    
    struct dirent* entry;
    while ((entry = readdir(dir)) != nullptr) {
        if (entry->d_name[0] == '.') continue;
        
        std::string vendor_path = "/sys/bus/pci/devices/" + std::string(entry->d_name) + "/vendor";
        std::string device_path = "/sys/bus/pci/devices/" + std::string(entry->d_name) + "/device";
        
        std::ifstream vendor_file(vendor_path);
        std::ifstream device_file(device_path);
        
        uint32_t vendor_id = 0, device_id = 0;
        vendor_file >> std::hex >> vendor_id;
        device_file >> std::hex >> device_id;
        
        if (vendor_id == T2T_VENDOR_ID && device_id == T2T_DEVICE_ID) {
            closedir(dir);
            return open(entry->d_name);
        }
    }
    closedir(dir);
    
    std::cerr << "Error: No T2T device found\n";
    return nullptr;
}

//=============================================================================
// Register Access
//=============================================================================

uint32_t Device::read_reg(uint32_t offset) const {
    if (offset >= BAR0_SIZE) return 0xFFFFFFFF;
    volatile uint32_t* reg = reinterpret_cast<volatile uint32_t*>(
        static_cast<uint8_t*>(impl_->bar0) + offset);
    return *reg;
}

void Device::write_reg(uint32_t offset, uint32_t value) {
    if (offset >= BAR0_SIZE) return;
    volatile uint32_t* reg = reinterpret_cast<volatile uint32_t*>(
        static_cast<uint8_t*>(impl_->bar0) + offset);
    *reg = value;
    __sync_synchronize();  // Memory barrier
}

//=============================================================================
// Configuration
//=============================================================================

bool Device::configure(const Config& cfg) {
    // Build control register
    uint32_t ctrl = 0;
    if (cfg.enable) ctrl |= ctrl::ENABLE;
    if (cfg.promiscuous) ctrl |= ctrl::PROMISCUOUS;
    if (cfg.mcast_enable) ctrl |= ctrl::MCAST_ENABLE;
    if (cfg.check_ip_csum) ctrl |= ctrl::CHECK_IP_CSUM;
    if (cfg.seq_check_en) ctrl |= ctrl::SEQ_CHECK_EN;
    if (cfg.msix_enable) ctrl |= ctrl::MSIX_ENABLE;
    
    // Write configuration registers
    write_reg(csr::PRICE_BAND_BPS, cfg.price_band_bps);
    write_reg(csr::TOKEN_RATE, (static_cast<uint32_t>(cfg.token_max) << 16) | cfg.token_rate);
    write_reg(csr::POSITION_LIMIT, static_cast<uint32_t>(cfg.position_limit));
    write_reg(csr::STALE_USEC, cfg.stale_usec);
    write_reg(csr::SEQ_GAP_THR, cfg.seq_gap_thr);
    write_reg(csr::KILL, cfg.kill_switch ? 1 : 0);
    write_reg(csr::EXPECTED_SEQ, cfg.expected_seq);
    write_reg(csr::EXPECTED_PORT, cfg.expected_port);
    write_reg(csr::MSIX_CFG, cfg.msix_threshold);
    
    // Multicast MAC
    write_reg(csr::MCAST_MAC_LO, static_cast<uint32_t>(cfg.mcast_mac & 0xFFFFFFFF));
    write_reg(csr::MCAST_MAC_HI, static_cast<uint32_t>(cfg.mcast_mac >> 32));
    
    // Finally, write control register to enable
    write_reg(csr::CTRL, ctrl);
    
    return true;
}

Config Device::read_config() const {
    Config cfg;
    
    uint32_t ctrl = read_reg(csr::CTRL);
    cfg.enable = (ctrl & ctrl::ENABLE) != 0;
    cfg.promiscuous = (ctrl & ctrl::PROMISCUOUS) != 0;
    cfg.mcast_enable = (ctrl & ctrl::MCAST_ENABLE) != 0;
    cfg.check_ip_csum = (ctrl & ctrl::CHECK_IP_CSUM) != 0;
    cfg.seq_check_en = (ctrl & ctrl::SEQ_CHECK_EN) != 0;
    cfg.msix_enable = (ctrl & ctrl::MSIX_ENABLE) != 0;
    
    cfg.price_band_bps = read_reg(csr::PRICE_BAND_BPS) & 0xFFFF;
    
    uint32_t token = read_reg(csr::TOKEN_RATE);
    cfg.token_rate = token & 0xFFFF;
    cfg.token_max = (token >> 16) & 0xFFFF;
    
    cfg.position_limit = static_cast<int32_t>(read_reg(csr::POSITION_LIMIT));
    cfg.stale_usec = read_reg(csr::STALE_USEC);
    cfg.seq_gap_thr = read_reg(csr::SEQ_GAP_THR);
    cfg.kill_switch = (read_reg(csr::KILL) & 1) != 0;
    cfg.expected_seq = read_reg(csr::EXPECTED_SEQ);
    cfg.expected_port = read_reg(csr::EXPECTED_PORT) & 0xFFFF;
    cfg.msix_threshold = read_reg(csr::MSIX_CFG) & 0xFFFF;
    
    uint64_t mac_lo = read_reg(csr::MCAST_MAC_LO);
    uint64_t mac_hi = read_reg(csr::MCAST_MAC_HI);
    cfg.mcast_mac = (mac_hi << 32) | mac_lo;
    
    return cfg;
}

void Device::set_enable(bool enable) {
    uint32_t ctrl = read_reg(csr::CTRL);
    if (enable) {
        ctrl |= ctrl::ENABLE;
    } else {
        ctrl &= ~ctrl::ENABLE;
    }
    write_reg(csr::CTRL, ctrl);
}

void Device::set_kill_switch(bool kill) {
    write_reg(csr::KILL, kill ? 1 : 0);
}

//=============================================================================
// Symbol Table
//=============================================================================

bool Device::load_symbol(const std::string& symbol, uint16_t idx) {
    if (idx >= 1024) return false;
    
    // Pad symbol to 8 characters
    std::string padded = symbol;
    while (padded.length() < 8) padded += ' ';
    padded = padded.substr(0, 8);
    
    // Write symbol key (8 bytes as 2x32-bit words)
    uint32_t key_lo = 0, key_hi = 0;
    for (int i = 0; i < 4; i++) {
        key_lo |= static_cast<uint32_t>(padded[i]) << (i * 8);
        key_hi |= static_cast<uint32_t>(padded[4+i]) << (i * 8);
    }
    
    write_reg(csr::SYMTAB_DATA, key_lo);
    write_reg(csr::SYMTAB_DATA + 4, key_hi);
    write_reg(csr::SYMTAB_DATA + 8, idx);
    
    // Trigger load
    write_reg(csr::SYMTAB_COMMIT, 1);
    
    return true;
}

bool Device::commit_symbols() {
    write_reg(csr::SYMTAB_COMMIT, 2);
    return true;
}

int Device::load_symbols_from_file(const std::string& filename) {
    std::ifstream file(filename);
    if (!file) return -1;
    
    int count = 0;
    std::string line;
    while (std::getline(file, line)) {
        // Skip empty lines and comments
        if (line.empty() || line[0] == '#') continue;
        
        // Parse "SYMBOL,INDEX" or "SYMBOL INDEX"
        std::stringstream ss(line);
        std::string symbol;
        uint16_t idx;
        
        if (line.find(',') != std::string::npos) {
            std::getline(ss, symbol, ',');
            ss >> idx;
        } else {
            ss >> symbol >> idx;
        }
        
        if (load_symbol(symbol, idx)) {
            count++;
        }
    }
    
    commit_symbols();
    return count;
}

//=============================================================================
// Reference Prices
//=============================================================================

void Device::set_reference_price(uint16_t sym_idx, uint32_t price) {
    write_reg(0x060, sym_idx);  // ref_price_addr
    write_reg(0x064, price);    // ref_price_data (triggers write)
}

int Device::load_prices_from_file(const std::string& filename) {
    std::ifstream file(filename);
    if (!file) return -1;
    
    int count = 0;
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] == '#') continue;
        
        std::stringstream ss(line);
        uint16_t idx;
        double price;
        char delim;
        
        if (line.find(',') != std::string::npos) {
            ss >> idx >> delim >> price;
        } else {
            ss >> idx >> price;
        }
        
        set_reference_price(idx, double_to_price(price));
        count++;
    }
    
    return count;
}

//=============================================================================
// DMA Ring
//=============================================================================

bool Device::init_dma_ring(size_t entries) {
    // Allocate hugepage-backed memory
    size_t size = entries * DMA_RECORD_SIZE;
    
    // Try 2MB hugepages first
    ring_buffer_ = mmap(nullptr, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
                        -1, 0);
    
    if (ring_buffer_ == MAP_FAILED) {
        // Fall back to regular pages (not ideal for DMA)
        ring_buffer_ = mmap(nullptr, size, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS,
                            -1, 0);
        if (ring_buffer_ == MAP_FAILED) {
            std::cerr << "Error: Cannot allocate DMA ring buffer\n";
            return false;
        }
        std::cerr << "Warning: Using regular pages for DMA buffer (not hugepages)\n";
    }
    
    // Lock pages in memory
    if (mlock(ring_buffer_, size) != 0) {
        std::cerr << "Warning: Cannot lock DMA buffer in memory\n";
    }
    
    // Get physical address (requires root or CAP_SYS_ADMIN)
    // In practice, you'd use VFIO IOMMU mapping instead
    ring_phys_addr_ = 0;  // Placeholder - real impl needs VFIO
    
    ring_entries_ = entries;
    consumer_idx_.store(0);
    
    // Configure device with ring parameters
    write_reg(csr::RING_BASE_LO, static_cast<uint32_t>(ring_phys_addr_ & 0xFFFFFFFF));
    write_reg(csr::RING_BASE_HI, static_cast<uint32_t>(ring_phys_addr_ >> 32));
    write_reg(csr::RING_LEN, static_cast<uint32_t>(entries));
    write_reg(csr::CONS_IDX_SHADOW, 0);
    
    return true;
}

size_t Device::poll(RecordCallback callback) {
    uint16_t prod = producer_index();
    uint16_t cons = consumer_idx_.load(std::memory_order_acquire);
    size_t count = 0;
    
    while (cons != prod) {
        const DmaRecord* record = reinterpret_cast<const DmaRecord*>(
            static_cast<uint8_t*>(ring_buffer_) + (cons * DMA_RECORD_SIZE));
        
        callback(*record);
        
        cons = (cons + 1) & (ring_entries_ - 1);
        count++;
    }
    
    if (count > 0) {
        consumer_idx_.store(cons, std::memory_order_release);
        write_reg(csr::CONS_IDX_SHADOW, cons);
    }
    
    return count;
}

size_t Device::poll_timeout(RecordCallback callback, uint64_t timeout_us) {
    auto start = std::chrono::steady_clock::now();
    size_t total = 0;
    
    while (true) {
        size_t count = poll(callback);
        total += count;
        
        if (count > 0) break;  // Got data, return
        
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(now - start);
        if (static_cast<uint64_t>(elapsed.count()) >= timeout_us) break;
        
        // Brief pause to reduce CPU usage
        std::this_thread::sleep_for(std::chrono::microseconds(10));
    }
    
    return total;
}

uint16_t Device::producer_index() const {
    return read_reg(csr::PROD_IDX) & 0xFFFF;
}

bool Device::ring_empty() const {
    return producer_index() == consumer_idx_.load();
}

bool Device::ring_full() const {
    uint16_t prod = producer_index();
    uint16_t cons = consumer_idx_.load();
    return ((prod + 1) & (ring_entries_ - 1)) == cons;
}

//=============================================================================
// Statistics
//=============================================================================

Statistics Device::read_statistics() const {
    Statistics stats;
    
    stats.rx_packets = read_reg(0x194);
    stats.rx_bytes = read_reg(0x198);
    stats.rx_crc_errors = read_reg(csr::CRC_BAD);
    stats.rx_drops = read_reg(csr::DROPS);
    stats.parsed_packets = read_reg(0x19C);
    stats.messages = read_reg(0x1A0);
    stats.seq_gaps = read_reg(csr::SEQ_GAPS);
    stats.book_updates = read_reg(0x1A4);
    stats.bank_conflicts = read_reg(0x1A8);
    stats.risk_accepts = read_reg(csr::ACCEPTS);
    stats.risk_rejects = read_reg(csr::BLOCKS);
    stats.dma_records = read_reg(0x1AC);
    stats.dma_drops = read_reg(0x1B0);
    
    stats.latency_histogram = read_latency_histogram();
    
    return stats;
}

std::vector<uint32_t> Device::read_latency_histogram() const {
    std::vector<uint32_t> hist(256);
    for (int i = 0; i < 256; i++) {
        hist[i] = read_reg(csr::LAT_HIST_BASE + i * 4);
    }
    return hist;
}

void Device::print_statistics() const {
    auto stats = read_statistics();
    
    std::cout << "\n=== T2T Device Statistics ===\n";
    std::cout << "Build ID:        0x" << std::hex << build_id() << std::dec << "\n";
    std::cout << "\nRX Statistics:\n";
    std::cout << "  Packets:       " << stats.rx_packets << "\n";
    std::cout << "  Bytes:         " << stats.rx_bytes << "\n";
    std::cout << "  CRC Errors:    " << stats.rx_crc_errors << "\n";
    std::cout << "  Drops:         " << stats.rx_drops << "\n";
    std::cout << "\nParsing Statistics:\n";
    std::cout << "  Parsed:        " << stats.parsed_packets << "\n";
    std::cout << "  Messages:      " << stats.messages << "\n";
    std::cout << "  Seq Gaps:      " << stats.seq_gaps << "\n";
    std::cout << "\nBook Statistics:\n";
    std::cout << "  Updates:       " << stats.book_updates << "\n";
    std::cout << "  Bank Conflicts:" << stats.bank_conflicts << "\n";
    std::cout << "\nRisk Statistics:\n";
    std::cout << "  Accepts:       " << stats.risk_accepts << "\n";
    std::cout << "  Rejects:       " << stats.risk_rejects << "\n";
    std::cout << "\nDMA Statistics:\n";
    std::cout << "  Records:       " << stats.dma_records << "\n";
    std::cout << "  Drops:         " << stats.dma_drops << "\n";
    std::cout << "\n";
}

//=============================================================================
// Utility Functions
//=============================================================================

std::string format_timestamp(uint64_t ts) {
    // Convert cycles to nanoseconds (assuming 300 MHz)
    uint64_t ns = ts * 10 / 3;
    uint64_t us = ns / 1000;
    uint64_t ms = us / 1000;
    uint64_t s = ms / 1000;
    
    std::ostringstream ss;
    ss << s << "." << std::setfill('0') << std::setw(3) << (ms % 1000)
       << "." << std::setw(3) << (us % 1000)
       << "." << std::setw(3) << (ns % 1000);
    return ss.str();
}

std::string format_mac(uint64_t mac) {
    std::ostringstream ss;
    ss << std::hex << std::setfill('0');
    for (int i = 5; i >= 0; i--) {
        ss << std::setw(2) << ((mac >> (i * 8)) & 0xFF);
        if (i > 0) ss << ":";
    }
    return ss.str();
}

std::optional<uint64_t> parse_mac(const std::string& mac_str) {
    uint64_t mac = 0;
    int parts[6];
    
    if (sscanf(mac_str.c_str(), "%x:%x:%x:%x:%x:%x",
               &parts[0], &parts[1], &parts[2],
               &parts[3], &parts[4], &parts[5]) != 6) {
        return std::nullopt;
    }
    
    for (int i = 0; i < 6; i++) {
        mac = (mac << 8) | (parts[i] & 0xFF);
    }
    
    return mac;
}

} 
