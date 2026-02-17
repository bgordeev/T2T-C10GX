// ============================================================================
// File: t2t_pcie_consumer.cpp
// Description: PCIe consumer - polls DMA ring buffer from FPGA
// ============================================================================

#include "t2t_vfio.hpp"
#include "t2t_record.h"
#include <iostream>
#include <atomic>
#include <csignal>
#include <chrono>
#include <thread>
#include <fstream>

// CSR register offsets
constexpr uint32_t CSR_PROD_IDX        = 0x320;
constexpr uint32_t CSR_CONS_IDX        = 0x324;
constexpr uint32_t CSR_RING_BASE_LOW   = 0x300;
constexpr uint32_t CSR_RING_BASE_HIGH  = 0x304;
constexpr uint32_t CSR_RING_ENABLE     = 0x308;

// Ring buffer config
constexpr size_t RING_DEPTH = 65536;
constexpr size_t RING_SIZE  = RING_DEPTH * sizeof(T2TRecord);

static std::atomic<bool> g_running{true};

void signal_handler(int sig) {
    std::cout << "\nShutting down..." << std::endl;
    g_running.store(false);
}

class PCIeConsumer {
public:
    PCIeConsumer(const std::string& device_path, const std::string& output_file)
        : vfio_(device_path), 
          cons_idx_(0), 
          records_processed_(0),
          output_file_(output_file)
    {
        if (!vfio_.is_open()) {
            throw std::runtime_error("Failed to open VFIO device");
        }
        
        bar0_ = static_cast<volatile uint8_t*>(vfio_.map_bar(0));
        if (!bar0_) {
            throw std::runtime_error("Failed to map BAR0");
        }
        
        ring_ = static_cast<T2TRecord*>(vfio_.alloc_hugepage(RING_SIZE));
        if (!ring_) {
            throw std::runtime_error("Failed to allocate ring buffer");
        }
        
        uint64_t ring_phys = vfio_.get_physical_addr(ring_);
        if (ring_phys == 0) {
            throw std::runtime_error("Failed to get physical address");
        }
        
        std::cout << "Ring buffer: " << (RING_SIZE / 1024 / 1024) << " MB" << std::endl;
        std::cout << "  Virtual:  " << static_cast<void*>(ring_) << std::endl;
        std::cout << "  Physical: 0x" << std::hex << ring_phys << std::dec << std::endl;
        
        // Program FPGA
        write_csr(CSR_RING_BASE_LOW, ring_phys & 0xFFFFFFFF);
        write_csr(CSR_RING_BASE_HIGH, (ring_phys >> 32) & 0xFFFFFFFF);
        write_csr(CSR_RING_ENABLE, 1);
        write_csr(CSR_CONS_IDX, 0);
        
        // Open output file if specified
        if (!output_file_.empty()) {
            outfile_.open(output_file_, std::ios::binary);
            if (!outfile_) {
                std::cerr << "Warning: Failed to open " << output_file_ << std::endl;
            } else {
                std::cout << "Logging records to: " << output_file_ << std::endl;
            }
        }
        
        std::cout << "PCIe consumer initialized" << std::endl;
    }
    
    ~PCIeConsumer() {
        if (bar0_) {
            write_csr(CSR_RING_ENABLE, 0);
        }
        
        if (ring_) {
            vfio_.free_hugepage(ring_, RING_SIZE);
        }
        
        if (outfile_.is_open()) {
            outfile_.close();
        }
        
        std::cout << "\nTotal records processed: " << records_processed_ << std::endl;
    }
    
    void run() {
        using namespace std::chrono;
        auto last_stats = steady_clock::now();
        uint64_t last_count = 0;
        
        std::cout << "\nStarting poll loop..." << std::endl;
        std::cout << "Press Ctrl+C to stop\n" << std::endl;
        
        while (g_running.load()) {
            uint32_t prod = read_csr(CSR_PROD_IDX);
            
            while (cons_idx_ != prod) {
                uint32_t idx = cons_idx_ & (RING_DEPTH - 1);
                
                std::atomic_thread_fence(std::memory_order_acquire);
                
                const T2TRecord& rec = ring_[idx];
                
                process_record(rec);
                
                ++cons_idx_;
                ++records_processed_;
            }
            
            write_csr(CSR_CONS_IDX, cons_idx_);
            
            auto now = steady_clock::now();
            if (duration_cast<seconds>(now - last_stats).count() >= 1) {
                uint64_t delta = records_processed_ - last_count;
                std::cout << "Rate: " << delta << " rec/s  |  Total: " 
                          << records_processed_ << std::endl;
                last_count = records_processed_;
                last_stats = now;
            }
            
            std::this_thread::yield();
        }
    }

private:
    t2t::VFIODevice vfio_;
    volatile uint8_t* bar0_;
    T2TRecord* ring_;
    uint32_t cons_idx_;
    uint64_t records_processed_;
    std::string output_file_;
    std::ofstream outfile_;
    
    uint32_t read_csr(uint32_t offset) const {
        volatile uint32_t* reg = reinterpret_cast<volatile uint32_t*>(bar0_ + offset);
        return *reg;
    }
    
    void write_csr(uint32_t offset, uint32_t value) {
        volatile uint32_t* reg = reinterpret_cast<volatile uint32_t*>(bar0_ + offset);
        *reg = value;
    }
    
    void process_record(const T2TRecord& rec) {
        // Write to binary file if enabled
        if (outfile_.is_open()) {
            outfile_.write(reinterpret_cast<const char*>(&rec), sizeof(rec));
        }
        
        // Skip stale records
        if (rec.is_stale()) return;
        
        // Example: print signals with tight spread and low latency
        if (rec.is_accepted() && rec.spread_bps() < 5 && rec.latency_ns() < 500) {
            static uint64_t signal_count = 0;
            if (++signal_count % 1000 == 0) {
                std::cout << "  [SIGNAL] Sym=" << rec.symbol_idx
                          << " Price=$" << rec.price_as_double()
                          << " Spread=" << rec.spread_bps() << "bps"
                          << " Lat=" << rec.latency_ns() << "ns" << std::endl;
            }
        }
    }
};

int main(int argc, char** argv) {
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    std::string device_path = "/dev/vfio/0";
    std::string output_file;
    
    if (argc > 1) device_path = argv[1];
    if (argc > 2) output_file = argv[2];
    
    std::cout << "T2T PCIe Consumer" << std::endl;
    std::cout << "Device: " << device_path << std::endl;
    
    try {
        PCIeConsumer consumer(device_path, output_file);
        consumer.run();
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }
    
    return 0;
}
