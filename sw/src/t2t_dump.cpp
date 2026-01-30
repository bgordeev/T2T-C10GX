/**
 * @file t2t_dump.cpp
 * @brief DMA record dump utility - captures and saves records to file
 *
 * Usage:
 *   t2t_dump -o output.csv           Dump to CSV
 *   t2t_dump -o output.bin -b        Dump to binary
 *   t2t_dump -n 10000                Capture N records then exit
 *   t2t_dump -t 60                   Capture for T seconds
 *   t2t_dump -f "sym_idx==42"        Filter records
 */

#include "t2t_device.hpp"

#include <iostream>
#include <fstream>
#include <iomanip>
#include <csignal>
#include <cstring>
#include <getopt.h>
#include <chrono>
#include <atomic>

using namespace t2t;

static std::atomic<bool> g_running{true};

void signal_handler(int) {
    g_running = false;
}

void print_usage(const char* prog) {
    std::cerr << "Usage: " << prog << " [options]\n\n";
    std::cerr << "Options:\n";
    std::cerr << "  -o, --output FILE    Output file (default: stdout)\n";
    std::cerr << "  -b, --binary         Binary output format\n";
    std::cerr << "  -n, --count N        Stop after N records\n";
    std::cerr << "  -t, --time SECONDS   Stop after SECONDS\n";
    std::cerr << "  -q, --quiet          Suppress progress output\n";
    std::cerr << "  -h, --help           Show this help\n";
}

int main(int argc, char* argv[]) {
    std::string output_file = "-";
    bool binary_format = false;
    uint64_t max_records = 0;
    uint64_t max_seconds = 0;
    bool quiet = false;
    
    // Parse options
    static struct option long_options[] = {
        {"output", required_argument, 0, 'o'},
        {"binary", no_argument, 0, 'b'},
        {"count", required_argument, 0, 'n'},
        {"time", required_argument, 0, 't'},
        {"quiet", no_argument, 0, 'q'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    
    int opt;
    while ((opt = getopt_long(argc, argv, "o:bn:t:qh", long_options, nullptr)) != -1) {
        switch (opt) {
            case 'o': output_file = optarg; break;
            case 'b': binary_format = true; break;
            case 'n': max_records = std::stoull(optarg); break;
            case 't': max_seconds = std::stoull(optarg); break;
            case 'q': quiet = true; break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }
    
    // Open device
    auto dev = Device::find_first();
    if (!dev) {
        std::cerr << "Error: Cannot find T2T device\n";
        return 1;
    }
    
    if (!dev->init_dma_ring()) {
        std::cerr << "Error: Cannot initialize DMA ring\n";
        return 1;
    }
    
    // Open output file
    std::ostream* out = &std::cout;
    std::ofstream file;
    
    if (output_file != "-") {
        auto mode = binary_format ? (std::ios::binary | std::ios::out) : std::ios::out;
        file.open(output_file, mode);
        if (!file) {
            std::cerr << "Error: Cannot open " << output_file << "\n";
            return 1;
        }
        out = &file;
    }
    
    // Write CSV header
    if (!binary_format) {
        *out << "seq,ts_ing,ts_dec,sym_idx,side,price,qty,ref_px,accepted,reason,latency_ns,spread,imbalance\n";
    }
    
    // Setup signal handler
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Capture loop
    auto start_time = std::chrono::steady_clock::now();
    uint64_t total_records = 0;
    uint64_t last_report = 0;
    
    if (!quiet) {
        std::cerr << "Capturing records (Ctrl+C to stop)...\n";
    }
    
    while (g_running) {
        // Check time limit
        if (max_seconds > 0) {
            auto now = std::chrono::steady_clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - start_time);
            if (static_cast<uint64_t>(elapsed.count()) >= max_seconds) break;
        }
        
        // Check record limit
        if (max_records > 0 && total_records >= max_records) break;
        
        // Poll for records
        size_t count = dev->poll([&](const DmaRecord& rec) {
            if (binary_format) {
                out->write(reinterpret_cast<const char*>(&rec), sizeof(rec));
            } else {
                *out << rec.seq << ","
                     << rec.ts_ing << ","
                     << rec.ts_dec << ","
                     << rec.sym_idx << ","
                     << (rec.side ? "S" : "B") << ","
                     << std::fixed << std::setprecision(4) << price_to_double(rec.price) << ","
                     << rec.qty << ","
                     << std::fixed << std::setprecision(4) << price_to_double(rec.ref_px) << ","
                     << (rec.accepted() ? "1" : "0") << ","
                     << static_cast<int>(rec.flags >> 2) << ","
                     << rec.latency_ns() << ","
                     << rec.feature0 << ","
                     << static_cast<int32_t>(rec.feature1) << "\n";
            }
            total_records++;
        });
        
        // Progress report
        if (!quiet && total_records - last_report >= 10000) {
            auto now = std::chrono::steady_clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - start_time);
            double rate = (total_records * 1000.0) / elapsed.count();
            std::cerr << "\rRecords: " << total_records 
                      << " (" << std::fixed << std::setprecision(1) << rate << "/s)   ";
            last_report = total_records;
        }
        
        if (count == 0) {
            // Brief sleep to avoid busy-waiting
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    }
    
    if (!quiet) {
        std::cerr << "\n\nCapture complete: " << total_records << " records\n";
    }
    
    return 0;
}
