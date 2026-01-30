/**
 * @file t2t_ctl.cpp
 * @brief Command-line control application for T2T-C10GX device
 *
 * Usage:
 *   t2t_ctl info           - Show device info and statistics
 *   t2t_ctl config         - Show current configuration
 *   t2t_ctl enable         - Enable the device
 *   t2t_ctl disable        - Disable the device
 *   t2t_ctl kill           - Activate kill switch
 *   t2t_ctl load-symbols <file>   - Load symbol table
 *   t2t_ctl load-prices <file>    - Load reference prices
 *   t2t_ctl monitor        - Monitor DMA records in real-time
 *   t2t_ctl bench          - Run latency benchmark
 *
 */

#include "t2t_device.hpp"

#include <iostream>
#include <iomanip>
#include <cstring>
#include <csignal>
#include <chrono>
#include <thread>
#include <atomic>

using namespace t2t;

static std::atomic<bool> g_running{true};

void signal_handler(int) {
    g_running = false;
}

void print_usage(const char* prog) {
    std::cerr << "Usage: " << prog << " <command> [args...]\n\n";
    std::cerr << "Commands:\n";
    std::cerr << "  info              Show device info and statistics\n";
    std::cerr << "  config            Show current configuration\n";
    std::cerr << "  enable            Enable the device\n";
    std::cerr << "  disable           Disable the device\n";
    std::cerr << "  kill              Activate kill switch\n";
    std::cerr << "  unkill            Deactivate kill switch\n";
    std::cerr << "  load-symbols <f>  Load symbol table from file\n";
    std::cerr << "  load-prices <f>   Load reference prices from file\n";
    std::cerr << "  set <reg> <val>   Set register (hex values)\n";
    std::cerr << "  get <reg>         Get register (hex offset)\n";
    std::cerr << "  monitor           Monitor DMA records in real-time\n";
    std::cerr << "  histogram         Print latency histogram\n";
    std::cerr << "  bench             Run latency benchmark\n";
}

int cmd_info(Device& dev) {
    std::cout << "=== T2T-C10GX Device Information ===\n\n";
    std::cout << "Build ID:    0x" << std::hex << dev.build_id() << std::dec << "\n";
    
    auto cfg = dev.read_config();
    std::cout << "Status:      " << (cfg.enable ? "ENABLED" : "DISABLED") << "\n";
    std::cout << "Kill Switch: " << (cfg.kill_switch ? "ACTIVE" : "inactive") << "\n";
    
    std::cout << "\nRing Buffer:\n";
    std::cout << "  Producer Index: " << dev.producer_index() << "\n";
    std::cout << "  Consumer Index: " << dev.consumer_index() << "\n";
    std::cout << "  Empty:          " << (dev.ring_empty() ? "yes" : "no") << "\n";
    std::cout << "  Full:           " << (dev.ring_full() ? "yes" : "no") << "\n";
    
    dev.print_statistics();
    
    return 0;
}

int cmd_config(Device& dev) {
    auto cfg = dev.read_config();
    
    std::cout << "=== T2T-C10GX Configuration ===\n\n";
    std::cout << "Enable:           " << (cfg.enable ? "true" : "false") << "\n";
    std::cout << "Promiscuous:      " << (cfg.promiscuous ? "true" : "false") << "\n";
    std::cout << "Multicast Enable: " << (cfg.mcast_enable ? "true" : "false") << "\n";
    std::cout << "Multicast MAC:    " << format_mac(cfg.mcast_mac) << "\n";
    std::cout << "Check IP Csum:    " << (cfg.check_ip_csum ? "true" : "false") << "\n";
    std::cout << "Expected Port:    " << cfg.expected_port << "\n";
    std::cout << "Seq Check Enable: " << (cfg.seq_check_en ? "true" : "false") << "\n";
    std::cout << "Expected Seq:     " << cfg.expected_seq << "\n";
    std::cout << "\nRisk Parameters:\n";
    std::cout << "  Price Band (bps): " << cfg.price_band_bps << "\n";
    std::cout << "  Token Rate:       " << cfg.token_rate << "/ms\n";
    std::cout << "  Token Max:        " << cfg.token_max << "\n";
    std::cout << "  Position Limit:   " << cfg.position_limit << "\n";
    std::cout << "  Stale Timeout:    " << cfg.stale_usec << " us\n";
    std::cout << "  Seq Gap Thresh:   " << cfg.seq_gap_thr << "\n";
    std::cout << "  Kill Switch:      " << (cfg.kill_switch ? "ACTIVE" : "inactive") << "\n";
    std::cout << "\nMSI-X:\n";
    std::cout << "  Enable:           " << (cfg.msix_enable ? "true" : "false") << "\n";
    std::cout << "  Threshold:        " << cfg.msix_threshold << "\n";
    
    return 0;
}

int cmd_monitor(Device& dev) {
    std::cout << "Monitoring DMA records (Ctrl+C to stop)...\n\n";
    std::cout << std::setw(12) << "Seq"
              << std::setw(8) << "SymIdx"
              << std::setw(6) << "Side"
              << std::setw(12) << "Price"
              << std::setw(10) << "Qty"
              << std::setw(8) << "Accept"
              << std::setw(12) << "Latency"
              << "\n";
    std::cout << std::string(70, '-') << "\n";
    
    signal(SIGINT, signal_handler);
    
    uint64_t total_records = 0;
    uint64_t total_latency = 0;
    
    while (g_running) {
        size_t count = dev.poll([&](const DmaRecord& rec) {
            total_records++;
            uint64_t lat = rec.latency_ns();
            total_latency += lat;
            
            std::cout << std::setw(12) << rec.seq
                      << std::setw(8) << rec.sym_idx
                      << std::setw(6) << (rec.side ? "Ask" : "Bid")
                      << std::setw(12) << std::fixed << std::setprecision(2) 
                      << price_to_double(rec.price)
                      << std::setw(10) << rec.qty
                      << std::setw(8) << (rec.accepted() ? "YES" : "NO")
                      << std::setw(10) << lat << " ns"
                      << "\n";
        });
        
        if (count == 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    
    std::cout << "\n--- Summary ---\n";
    std::cout << "Total records: " << total_records << "\n";
    if (total_records > 0) {
        std::cout << "Average latency: " << (total_latency / total_records) << " ns\n";
    }
    
    return 0;
}

int cmd_histogram(Device& dev) {
    auto hist = dev.read_latency_histogram();
    
    std::cout << "=== Latency Histogram ===\n\n";
    std::cout << "Bin width: 4 cycles (~13 ns)\n\n";
    
    // Find max for scaling
    uint32_t max_val = 0;
    for (auto v : hist) {
        if (v > max_val) max_val = v;
    }
    
    if (max_val == 0) {
        std::cout << "(No samples collected)\n";
        return 0;
    }
    
    // Print histogram with ASCII bars
    const int BAR_WIDTH = 50;
    
    for (int i = 0; i < 64; i++) {  // First 64 bins
        if (hist[i] == 0) continue;
        
        int cycles_lo = i * 4;
        int cycles_hi = cycles_lo + 3;
        int ns_lo = cycles_lo * 10 / 3;
        int ns_hi = cycles_hi * 10 / 3;
        
        int bar_len = (hist[i] * BAR_WIDTH) / max_val;
        
        std::cout << std::setw(4) << ns_lo << "-" << std::setw(4) << ns_hi << " ns | "
                  << std::setw(8) << hist[i] << " |"
                  << std::string(bar_len, '#') << "\n";
    }
    
    return 0;
}

int cmd_bench(Device& dev) {
    std::cout << "=== Latency Benchmark ===\n\n";
    std::cout << "Collecting samples for 10 seconds...\n";
    
    signal(SIGINT, signal_handler);
    
    std::vector<uint64_t> latencies;
    latencies.reserve(1000000);
    
    auto start = std::chrono::steady_clock::now();
    
    while (g_running) {
        dev.poll([&](const DmaRecord& rec) {
            latencies.push_back(rec.latency_ns());
        });
        
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - start).count() >= 10) {
            break;
        }
    }
    
    if (latencies.empty()) {
        std::cout << "No samples collected. Is traffic flowing?\n";
        return 1;
    }
    
    // Sort for percentile calculation
    std::sort(latencies.begin(), latencies.end());
    
    size_t n = latencies.size();
    uint64_t sum = 0;
    for (auto l : latencies) sum += l;
    
    std::cout << "\nResults:\n";
    std::cout << "  Samples:    " << n << "\n";
    std::cout << "  Min:        " << latencies.front() << " ns\n";
    std::cout << "  p50:        " << latencies[n * 50 / 100] << " ns\n";
    std::cout << "  p90:        " << latencies[n * 90 / 100] << " ns\n";
    std::cout << "  p99:        " << latencies[n * 99 / 100] << " ns\n";
    std::cout << "  p99.9:      " << latencies[n * 999 / 1000] << " ns\n";
    std::cout << "  Max:        " << latencies.back() << " ns\n";
    std::cout << "  Average:    " << (sum / n) << " ns\n";
    
    return 0;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }
    
    std::string cmd = argv[1];
    
    if (cmd == "-h" || cmd == "--help") {
        print_usage(argv[0]);
        return 0;
    }
    
    // Open device
    auto dev = Device::find_first();
    if (!dev) {
        std::cerr << "Error: Cannot find T2T device\n";
        return 1;
    }
    
    // Initialize DMA ring for commands that need it
    if (cmd == "monitor" || cmd == "bench") {
        if (!dev->init_dma_ring()) {
            std::cerr << "Error: Cannot initialize DMA ring\n";
            return 1;
        }
    }
    
    // Execute command
    if (cmd == "info") {
        return cmd_info(*dev);
    } else if (cmd == "config") {
        return cmd_config(*dev);
    } else if (cmd == "enable") {
        dev->set_enable(true);
        std::cout << "Device enabled\n";
        return 0;
    } else if (cmd == "disable") {
        dev->set_enable(false);
        std::cout << "Device disabled\n";
        return 0;
    } else if (cmd == "kill") {
        dev->set_kill_switch(true);
        std::cout << "Kill switch ACTIVATED\n";
        return 0;
    } else if (cmd == "unkill") {
        dev->set_kill_switch(false);
        std::cout << "Kill switch deactivated\n";
        return 0;
    } else if (cmd == "load-symbols") {
        if (argc < 3) {
            std::cerr << "Error: Missing filename\n";
            return 1;
        }
        int count = dev->load_symbols_from_file(argv[2]);
        if (count < 0) {
            std::cerr << "Error: Cannot load symbols from " << argv[2] << "\n";
            return 1;
        }
        std::cout << "Loaded " << count << " symbols\n";
        return 0;
    } else if (cmd == "load-prices") {
        if (argc < 3) {
            std::cerr << "Error: Missing filename\n";
            return 1;
        }
        int count = dev->load_prices_from_file(argv[2]);
        if (count < 0) {
            std::cerr << "Error: Cannot load prices from " << argv[2] << "\n";
            return 1;
        }
        std::cout << "Loaded " << count << " reference prices\n";
        return 0;
    } else if (cmd == "set") {
        if (argc < 4) {
            std::cerr << "Error: Usage: set <offset> <value>\n";
            return 1;
        }
        uint32_t offset = std::stoul(argv[2], nullptr, 16);
        uint32_t value = std::stoul(argv[3], nullptr, 16);
        dev->write_reg(offset, value);
        std::cout << "Wrote 0x" << std::hex << value << " to offset 0x" << offset << std::dec << "\n";
        return 0;
    } else if (cmd == "get") {
        if (argc < 3) {
            std::cerr << "Error: Usage: get <offset>\n";
            return 1;
        }
        uint32_t offset = std::stoul(argv[2], nullptr, 16);
        uint32_t value = dev->read_reg(offset);
        std::cout << "0x" << std::hex << offset << " = 0x" << value << std::dec << "\n";
        return 0;
    } else if (cmd == "monitor") {
        return cmd_monitor(*dev);
    } else if (cmd == "histogram") {
        return cmd_histogram(*dev);
    } else if (cmd == "bench") {
        return cmd_bench(*dev);
    } else {
        std::cerr << "Error: Unknown command '" << cmd << "'\n";
        print_usage(argv[0]);
        return 1;
    }
    
    return 0;
}
