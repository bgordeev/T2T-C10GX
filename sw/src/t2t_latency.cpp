/**
 * @file t2t_latency.cpp
 * @brief Latency analysis and reporting tool
 *
 * Features:
 *   - Real-time latency monitoring
 *   - Histogram visualization
 *   - Percentile calculations
 *   - CSV export
 */

#include "t2t_device.hpp"

#include <iostream>
#include <fstream>
#include <iomanip>
#include <vector>
#include <algorithm>
#include <numeric>
#include <cmath>
#include <csignal>
#include <chrono>
#include <thread>

using namespace t2t;

static std::atomic<bool> g_running{true};

void signal_handler(int) {
    g_running = false;
}

struct LatencyStats {
    uint64_t count = 0;
    uint64_t sum = 0;
    uint64_t min = UINT64_MAX;
    uint64_t max = 0;
    std::vector<uint64_t> samples;
    
    void add(uint64_t latency) {
        count++;
        sum += latency;
        if (latency < min) min = latency;
        if (latency > max) max = latency;
        samples.push_back(latency);
    }
    
    double mean() const {
        return count > 0 ? static_cast<double>(sum) / count : 0.0;
    }
    
    double stddev() const {
        if (count < 2) return 0.0;
        double m = mean();
        double sq_sum = 0;
        for (auto s : samples) {
            double diff = s - m;
            sq_sum += diff * diff;
        }
        return std::sqrt(sq_sum / (count - 1));
    }
    
    uint64_t percentile(double p) {
        if (samples.empty()) return 0;
        std::sort(samples.begin(), samples.end());
        size_t idx = static_cast<size_t>(p * samples.size() / 100.0);
        if (idx >= samples.size()) idx = samples.size() - 1;
        return samples[idx];
    }
};

void print_stats(const LatencyStats& stats, const std::string& label) {
    std::cout << "\n=== " << label << " ===\n";
    std::cout << "Samples:    " << stats.count << "\n";
    std::cout << "Min:        " << stats.min << " ns\n";
    std::cout << "Max:        " << stats.max << " ns\n";
    std::cout << "Mean:       " << std::fixed << std::setprecision(2) << stats.mean() << " ns\n";
    std::cout << "Std Dev:    " << std::fixed << std::setprecision(2) << stats.stddev() << " ns\n";
}

void print_percentiles(LatencyStats& stats) {
    std::cout << "\nPercentiles:\n";
    std::cout << "  p50:      " << stats.percentile(50) << " ns\n";
    std::cout << "  p75:      " << stats.percentile(75) << " ns\n";
    std::cout << "  p90:      " << stats.percentile(90) << " ns\n";
    std::cout << "  p95:      " << stats.percentile(95) << " ns\n";
    std::cout << "  p99:      " << stats.percentile(99) << " ns\n";
    std::cout << "  p99.9:    " << stats.percentile(99.9) << " ns\n";
    std::cout << "  p99.99:   " << stats.percentile(99.99) << " ns\n";
}

void print_histogram(const std::vector<uint32_t>& hist, int bin_width_ns) {
    // Find max for scaling
    uint32_t max_val = *std::max_element(hist.begin(), hist.end());
    if (max_val == 0) {
        std::cout << "(No data)\n";
        return;
    }
    
    const int BAR_WIDTH = 50;
    
    std::cout << "\nLatency Distribution:\n";
    std::cout << std::string(60, '-') << "\n";
    
    // Print significant bins only
    bool in_tail = false;
    int tail_count = 0;
    
    for (size_t i = 0; i < hist.size(); i++) {
        if (hist[i] == 0) {
            if (in_tail) tail_count++;
            continue;
        }
        
        in_tail = true;
        int ns_lo = i * bin_width_ns;
        int ns_hi = (i + 1) * bin_width_ns - 1;
        int bar_len = (hist[i] * BAR_WIDTH) / max_val;
        
        std::cout << std::setw(5) << ns_lo << "-" << std::setw(5) << ns_hi << " ns | "
                  << std::setw(8) << hist[i] << " | "
                  << std::string(bar_len, '#') << "\n";
    }
}

int main(int argc, char* argv[]) {
    int duration_sec = 10;
    bool continuous = false;
    std::string output_file;
    
    // Simple arg parsing
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "-t" && i + 1 < argc) {
            duration_sec = std::stoi(argv[++i]);
        } else if (arg == "-c") {
            continuous = true;
        } else if (arg == "-o" && i + 1 < argc) {
            output_file = argv[++i];
        } else if (arg == "-h" || arg == "--help") {
            std::cout << "Usage: " << argv[0] << " [options]\n";
            std::cout << "  -t SECONDS   Collection duration (default: 10)\n";
            std::cout << "  -c           Continuous mode (periodic reports)\n";
            std::cout << "  -o FILE      Export results to CSV\n";
            return 0;
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
    
    signal(SIGINT, signal_handler);
    
    std::cout << "T2T Latency Analysis\n";
    std::cout << "====================\n";
    std::cout << "Collecting for " << duration_sec << " seconds...\n";
    
    LatencyStats overall_stats;
    LatencyStats accept_stats;
    LatencyStats reject_stats;
    
    auto start = std::chrono::steady_clock::now();
    auto report_time = start;
    
    while (g_running) {
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - start);
        
        if (!continuous && elapsed.count() >= duration_sec) break;
        
        // Poll records
        dev->poll([&](const DmaRecord& rec) {
            uint64_t lat = rec.latency_ns();
            overall_stats.add(lat);
            
            if (rec.accepted()) {
                accept_stats.add(lat);
            } else {
                reject_stats.add(lat);
            }
        });
        
        // Periodic report in continuous mode
        if (continuous) {
            auto since_report = std::chrono::duration_cast<std::chrono::seconds>(now - report_time);
            if (since_report.count() >= 5) {
                std::cout << "\r[" << elapsed.count() << "s] Samples: " << overall_stats.count
                          << " | Mean: " << std::fixed << std::setprecision(0) << overall_stats.mean()
                          << " ns | p99: " << overall_stats.percentile(99) << " ns   ";
                std::cout.flush();
                report_time = now;
            }
        }
        
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
    
    if (continuous) std::cout << "\n";
    
    // Print results
    print_stats(overall_stats, "Overall Latency");
    print_percentiles(overall_stats);
    
    if (accept_stats.count > 0) {
        print_stats(accept_stats, "Accepted Records");
        print_percentiles(accept_stats);
    }
    
    if (reject_stats.count > 0) {
        print_stats(reject_stats, "Rejected Records");
    }
    
    // Hardware histogram
    std::cout << "\n=== Hardware Histogram ===\n";
    auto hw_hist = dev->read_latency_histogram();
    print_histogram(hw_hist, 13);  // ~13 ns per bin at 300 MHz with 4-cycle bins
    
    // Export to CSV if requested
    if (!output_file.empty()) {
        std::ofstream out(output_file);
        out << "latency_ns\n";
        for (auto lat : overall_stats.samples) {
            out << lat << "\n";
        }
        std::cout << "\nExported " << overall_stats.count << " samples to " << output_file << "\n";
    }
    
    return 0;
}
