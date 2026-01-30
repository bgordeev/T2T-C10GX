/**
 * @file t2t_symbols.cpp
 * @brief Symbol table and reference price management utility
 *
 * Commands:
 *   t2t_symbols load <file>       Load symbols from file
 *   t2t_symbols prices <file>     Load reference prices
 *   t2t_symbols add SYMBOL INDEX  Add single symbol
 *   t2t_symbols price INDEX VALUE Set single reference price
 *   t2t_symbols commit            Commit pending changes
 *   t2t_symbols clear             Clear symbol table
 */

#include "t2t_device.hpp"

#include <iostream>
#include <fstream>
#include <sstream>
#include <iomanip>

using namespace t2t;

void print_usage(const char* prog) {
    std::cerr << "Usage: " << prog << " <command> [args...]\n\n";
    std::cerr << "Commands:\n";
    std::cerr << "  load <file>          Load symbols from CSV file\n";
    std::cerr << "  prices <file>        Load reference prices from CSV file\n";
    std::cerr << "  add <symbol> <idx>   Add single symbol mapping\n";
    std::cerr << "  price <idx> <value>  Set reference price for symbol\n";
    std::cerr << "  commit               Commit pending symbol changes\n";
    std::cerr << "  generate <file>      Generate sample symbol file\n";
    std::cerr << "\nFile formats:\n";
    std::cerr << "  Symbols: SYMBOL,INDEX (one per line)\n";
    std::cerr << "  Prices:  INDEX,PRICE (one per line)\n";
}

int generate_sample_file(const std::string& filename) {
    std::ofstream out(filename);
    if (!out) {
        std::cerr << "Error: Cannot create " << filename << "\n";
        return 1;
    }
    
    // Popular NASDAQ symbols
    const char* symbols[] = {
        "AAPL", "MSFT", "AMZN", "GOOGL", "GOOG", "META", "NVDA", "TSLA",
        "AVGO", "COST", "PEP", "CSCO", "ADBE", "CMCSA", "TXN", "NFLX",
        "QCOM", "INTC", "HON", "AMD", "INTU", "AMAT", "SBUX", "ISRG",
        "BKNG", "MDLZ", "ADP", "GILD", "LRCX", "ADI", "REGN", "VRTX"
    };
    
    out << "# T2T Symbol Table\n";
    out << "# Format: SYMBOL,INDEX\n";
    out << "#\n";
    
    for (size_t i = 0; i < sizeof(symbols)/sizeof(symbols[0]); i++) {
        out << symbols[i] << "," << i << "\n";
    }
    
    std::cout << "Generated " << filename << " with " 
              << sizeof(symbols)/sizeof(symbols[0]) << " symbols\n";
    return 0;
}

int generate_prices_file(const std::string& filename) {
    std::ofstream out(filename);
    if (!out) {
        std::cerr << "Error: Cannot create " << filename << "\n";
        return 1;
    }
    
    // Sample prices (realistic for 2025)
    struct { int idx; double price; } prices[] = {
        {0, 195.50},   // AAPL
        {1, 425.00},   // MSFT
        {2, 185.25},   // AMZN
        {3, 175.00},   // GOOGL
        {4, 176.50},   // GOOG
        {5, 510.00},   // META
        {6, 875.00},   // NVDA
        {7, 250.00},   // TSLA
        {8, 165.00},   // AVGO
        {9, 890.00},   // COST
    };
    
    out << "# T2T Reference Prices\n";
    out << "# Format: INDEX,PRICE\n";
    out << "#\n";
    
    for (const auto& p : prices) {
        out << p.idx << "," << std::fixed << std::setprecision(2) << p.price << "\n";
    }
    
    std::cout << "Generated " << filename << " with sample reference prices\n";
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
    
    // Commands that don't need device
    if (cmd == "generate") {
        if (argc < 3) {
            std::cerr << "Error: Missing filename\n";
            return 1;
        }
        std::string file = argv[2];
        if (file.find("price") != std::string::npos) {
            return generate_prices_file(file);
        } else {
            return generate_sample_file(file);
        }
    }
    
    // Open device
    auto dev = Device::find_first();
    if (!dev) {
        std::cerr << "Error: Cannot find T2T device\n";
        return 1;
    }
    
    if (cmd == "load") {
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
        std::cout << "Use 'commit' command to activate changes\n";
        return 0;
        
    } else if (cmd == "prices") {
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
        
    } else if (cmd == "add") {
        if (argc < 4) {
            std::cerr << "Error: Usage: add <symbol> <index>\n";
            return 1;
        }
        std::string symbol = argv[2];
        uint16_t idx = std::stoul(argv[3]);
        
        if (!dev->load_symbol(symbol, idx)) {
            std::cerr << "Error: Cannot add symbol\n";
            return 1;
        }
        std::cout << "Added " << symbol << " at index " << idx << "\n";
        std::cout << "Use 'commit' command to activate changes\n";
        return 0;
        
    } else if (cmd == "price") {
        if (argc < 4) {
            std::cerr << "Error: Usage: price <index> <value>\n";
            return 1;
        }
        uint16_t idx = std::stoul(argv[2]);
        double price = std::stod(argv[3]);
        
        dev->set_reference_price(idx, double_to_price(price));
        std::cout << "Set reference price for index " << idx << " to $" 
                  << std::fixed << std::setprecision(2) << price << "\n";
        return 0;
        
    } else if (cmd == "commit") {
        if (!dev->commit_symbols()) {
            std::cerr << "Error: Commit failed\n";
            return 1;
        }
        std::cout << "Symbol table committed\n";
        return 0;
        
    } else {
        std::cerr << "Error: Unknown command '" << cmd << "'\n";
        print_usage(argv[0]);
        return 1;
    }
    
    return 0;
}
