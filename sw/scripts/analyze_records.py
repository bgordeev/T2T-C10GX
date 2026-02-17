#!/usr/bin/env python3
"""
analyze_records.py - Analyze DMA records from binary dump
Generates latency statistics and histograms
"""

import sys
import struct
import numpy as np
from pathlib import Path

RECORD_SIZE = 64
RECORD_FMT = '<IIQQHBBIIIIIIIHxxxxxx'

def parse_record(data):
    """Parse 64-byte record"""
    fields = struct.unpack(RECORD_FMT, data)
    return {
        'seq': fields[0],
        'ts_ingress': fields[2],
        'ts_decode': fields[3],
        'symbol_idx': fields[4],
        'side': fields[5],
        'flags': fields[6],
        'quantity': fields[8],
        'price': fields[9],
        'ref_price': fields[10],
        'feature0': fields[11],
        'latency_ns': fields[3] - fields[2] if fields[3] > fields[2] else 0,
        'is_stale': bool(fields[6] & 0x01),
        'is_accepted': bool(fields[6] & 0x02),
    }

def load_records(binary_file):
    """Load all records"""
    records = []
    with open(binary_file, 'rb') as f:
        while True:
            data = f.read(RECORD_SIZE)
            if len(data) < RECORD_SIZE:
                break
            records.append(parse_record(data))
    return records

def analyze_latency(records):
    """Compute latency stats"""
    latencies = [r['latency_ns'] for r in records]
    if not latencies:
        return None
    
    lat_np = np.array(latencies)
    
    return {
        'count': len(latencies),
        'min': np.min(lat_np),
        'p10': np.percentile(lat_np, 10),
        'p25': np.percentile(lat_np, 25),
        'p50': np.percentile(lat_np, 50),
        'p75': np.percentile(lat_np, 75),
        'p90': np.percentile(lat_np, 90),
        'p99': np.percentile(lat_np, 99),
        'p99_9': np.percentile(lat_np, 99.9),
        'max': np.max(lat_np),
        'mean': np.mean(lat_np),
        'std': np.std(lat_np),
    }

def print_report(records, stats):
    """Print analysis report"""
    print("\n" + "=" * 70)
    print("RECORD ANALYSIS")
    print("=" * 70)
    print(f"\nTotal records: {len(records)}")
    
    print("\nLATENCY (nanoseconds):")
    print(f"  Count:  {stats['count']}")
    print(f"  Min:    {stats['min']:.1f} ns")
    print(f"  p50:    {stats['p50']:.1f} ns")
    print(f"  p90:    {stats['p90']:.1f} ns")
    print(f"  p99:    {stats['p99']:.1f} ns")
    print(f"  p99.9:  {stats['p99_9']:.1f} ns")
    print(f"  Max:    {stats['max']:.1f} ns")
    print(f"  Mean:   {stats['mean']:.1f} ns")
    print(f"  StdDev: {stats['std']:.1f} ns")
    
    accepted = sum(1 for r in records if r['is_accepted'])
    stale = sum(1 for r in records if r['is_stale'])
    
    print("\nRISK GATE:")
    print(f"  Accepted: {accepted} ({accepted*100/len(records):.1f}%)")
    print(f"  Blocked:  {len(records)-accepted}")
    print(f"  Stale:    {stale}")
    
    print("\n" + "=" * 70)

def main():
    if len(sys.argv) < 2:
        print("Usage: analyze_records.py <binary_file>")
        return 1
    
    infile = Path(sys.argv[1])
    if not infile.exists():
        print(f"Error: {infile} not found")
        return 1
    
    print(f"Loading {infile}...")
    records = load_records(infile)
    
    if not records:
        print("No records found")
        return 1
    
    print(f"Loaded {len(records)} records")
    
    stats = analyze_latency(records)
    print_report(records, stats)
    
    # Save CSV if requested
    if len(sys.argv) > 2:
        outfile = sys.argv[2]
        with open(outfile, 'w') as f:
            f.write("metric,value\n")
            for k, v in stats.items():
                f.write(f"{k},{v}\n")
        print(f"\nSaved stats to {outfile}")
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
