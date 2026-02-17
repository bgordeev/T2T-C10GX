#!/usr/bin/env python3
"""
generate_synthetic_itch.py - Generate synthetic ITCH 5.0 market data
Creates realistic Add/Cancel/Trade messages for testing
"""

import sys
import struct
import random
import argparse
from datetime import datetime, timedelta

# ITCH 5.0 message types
MSG_SYSTEM_EVENT = ord('S')
MSG_ADD_ORDER = ord('A')
MSG_DELETE_ORDER = ord('D')
MSG_REPLACE_ORDER = ord('U')
MSG_EXECUTE_ORDER = ord('E')
MSG_TRADE = ord('P')

class ITCHGenerator:
    def __init__(self, symbols):
        self.symbols = symbols
        self.sequence = 1
        self.timestamp_ns = 34200000000000  # 9:30 AM in nanoseconds
        self.order_id = 1000000
        self.active_orders = {}  # symbol -> [order_ids]
        
    def next_timestamp(self, delta_us=100):
        """Advance timestamp by microseconds"""
        self.timestamp_ns += delta_us * 1000
        return self.timestamp_ns
    
    def pack_symbol(self, symbol):
        """Pack symbol as 8-byte ASCII padded"""
        return symbol.ljust(8)[:8].encode('ascii')
    
    def generate_add_order(self, symbol, buy=True):
        """Generate Add Order message (type A)"""
        self.order_id += 1
        
        # Random price around $150
        price = int((150.0 + random.uniform(-5.0, 5.0)) * 10000)
        shares = random.choice([100, 200, 500, 1000])
        
        # Track order
        if symbol not in self.active_orders:
            self.active_orders[symbol] = []
        self.active_orders[symbol].append(self.order_id)
        
        msg = struct.pack(
            '>HQIQB8sI',
            38,                          # Length (2 bytes)
            self.next_timestamp(),       # Timestamp (8 bytes)
            self.sequence,               # Sequence (4 bytes)
            self.order_id,               # Order ref (8 bytes)
            ord('B') if buy else ord('S'),  # Buy/Sell (1 byte)
            self.pack_symbol(symbol),    # Symbol (8 bytes)
            shares                       # Shares (4 bytes)
        )
        
        # Add price (4 bytes)
        msg += struct.pack('>I', price)
        
        self.sequence += 1
        return msg
    
    def generate_delete_order(self, symbol):
        """Generate Delete Order message (type D)"""
        if not self.active_orders.get(symbol):
            return None
        
        order_id = random.choice(self.active_orders[symbol])
        self.active_orders[symbol].remove(order_id)
        
        msg = struct.pack(
            '>HQIQ',
            23,                     # Length
            self.next_timestamp(),
            self.sequence,
            order_id
        )
        
        self.sequence += 1
        return msg
    
    def generate_trade(self, symbol):
        """Generate Trade message (type P)"""
        price = int((150.0 + random.uniform(-2.0, 2.0)) * 10000)
        shares = random.choice([100, 200, 500])
        
        msg = struct.pack(
            '>HQIQB8sIQI',
            44,                     # Length
            self.next_timestamp(),
            self.sequence,
            self.order_id,
            ord('B'),               # Buy
            self.pack_symbol(symbol),
            shares,
            self.order_id + 1,      # Match number
            price
        )
        
        self.sequence += 1
        return msg
    
    def generate_random_message(self, symbol):
        """Generate random message weighted by probability"""
        r = random.random()
        
        if r < 0.5:  # 50% adds
            return self.generate_add_order(symbol, random.choice([True, False]))
        elif r < 0.8:  # 30% cancels
            return self.generate_delete_order(symbol)
        else:  # 20% trades
            return self.generate_trade(symbol)

def generate_itch_file(output_file, symbols, message_count):
    """Generate ITCH binary file"""
    gen = ITCHGenerator(symbols)
    
    with open(output_file, 'wb') as f:
        print(f"Generating {message_count} ITCH messages...")
        
        for i in range(message_count):
            symbol = random.choice(symbols)
            msg = gen.generate_random_message(symbol)
            
            if msg:
                f.write(msg)
            
            if (i + 1) % 1000 == 0:
                print(f"  Generated {i+1}/{message_count} messages...", end='\r')
        
        print(f"\n✓ Generated {message_count} messages")
        print(f"  Sequence: {gen.sequence}")
        print(f"  Output: {output_file}")

def main():
    parser = argparse.ArgumentParser(description='Generate synthetic ITCH 5.0 data')
    parser.add_argument('output', help='Output file (.itch)')
    parser.add_argument('-c', '--count', type=int, default=10000,
                       help='Number of messages (default: 10000)')
    parser.add_argument('-s', '--symbols', default='AAPL,MSFT,GOOGL,AMZN,TSLA',
                       help='Comma-separated symbols (default: AAPL,MSFT,GOOGL,AMZN,TSLA)')
    
    args = parser.parse_args()
    
    symbols = [s.strip() for s in args.symbols.split(',')]
    
    print("ITCH 5.0 Synthetic Data Generator")
    print("=" * 60)
    print(f"Symbols: {', '.join(symbols)}")
    print(f"Messages: {args.count}")
    print()
    
    generate_itch_file(args.output, symbols, args.count)
    
    # Show file size
    import os
    size = os.path.getsize(args.output)
    print(f"  File size: {size / 1024:.1f} KB")
    print()
    print("Next step:")
    print(f"  Convert to PCAP: ./itch_to_pcap.py {args.output} output.pcap")

if __name__ == '__main__':
    main()
