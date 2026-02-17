#!/usr/bin/env python3
"""
load_symbols.py - Load symbol table into FPGA CAM
Reads symbols.csv and programs the CAM via CSR registers
"""

import sys
import csv
import subprocess
from pathlib import Path

# CSR offsets for symbol table
SYMTAB_WR_INDEX  = 0x400
SYMTAB_WR_SYMBOL_LOW  = 0x404
SYMTAB_WR_SYMBOL_HIGH = 0x408
SYMTAB_WR_ENABLE = 0x40C

def symbol_to_u64(symbol_str):
    """Convert 8-byte ASCII symbol to 64-bit integer"""
    symbol_bytes = symbol_str.ljust(8)[:8].encode('ascii')
    return int.from_bytes(symbol_bytes, byteorder='little')

def write_csr(offset, value):
    """Write CSR using csr_access.py"""
    cmd = [sys.executable, 'csr_access.py', 'write', hex(offset), str(value)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0

def load_symbol(index, symbol):
    """Load one symbol into CAM"""
    symbol_u64 = symbol_to_u64(symbol)
    low = symbol_u64 & 0xFFFFFFFF
    high = (symbol_u64 >> 32) & 0xFFFFFFFF
    
    if not write_csr(SYMTAB_WR_INDEX, index):
        return False
    if not write_csr(SYMTAB_WR_SYMBOL_LOW, low):
        return False
    if not write_csr(SYMTAB_WR_SYMBOL_HIGH, high):
        return False
    if not write_csr(SYMTAB_WR_ENABLE, 1):
        return False
    if not write_csr(SYMTAB_WR_ENABLE, 0):
        return False
    
    return True

def load_from_csv(csv_path):
    """Load all symbols from CSV"""
    if not Path(csv_path).exists():
        print(f"Error: {csv_path} not found")
        return False
    
    count = 0
    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            symbol = row['symbol'].strip()
            index = int(row['index'])
            
            print(f"Loading {index:4d}: {symbol:8s} ", end='')
            
            if load_symbol(index, symbol):
                print("[OK]")
                count += 1
            else:
                print("[FAIL]")
                return False
    
    print(f"\nLoaded {count} symbols")
    return True

def main():
    csv_file = 'symbols.csv'
    
    if len(sys.argv) > 1:
        csv_file = sys.argv[1]
    
    print("Symbol Table Loader")
    print("=" * 60)
    print(f"CSV: {csv_file}\n")
    
    if not load_from_csv(csv_file):
        return 1
    
    print("\nSymbol table loaded successfully")
    return 0

if __name__ == '__main__':
    sys.exit(main())
