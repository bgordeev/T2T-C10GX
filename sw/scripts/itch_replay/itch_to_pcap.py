#!/usr/bin/env python3
"""
itch_to_pcap.py - Convert ITCH binary data to PCAP with full network headers
Wraps ITCH messages in Ethernet/IP/UDP for replay to FPGA
"""

import sys
import struct
import argparse
from datetime import datetime

# Ethernet header (14 bytes)
ETH_DST_MAC = bytes.fromhex('01005e000101')  # Multicast MAC
ETH_SRC_MAC = bytes.fromhex('aabbccddeeff')
ETH_TYPE_IP = 0x0800

# IP header constants
IP_VERSION = 4
IP_IHL = 5  # Header length in 32-bit words
IP_TOS = 0
IP_ID = 0x1234
IP_FLAGS_DF = 0x4000  # Don't fragment
IP_TTL = 64
IP_PROTO_UDP = 17
IP_SRC = '192.168.10.1'
IP_DST = '239.0.1.1'  # Multicast

# UDP header constants
UDP_SRC_PORT = 12345
UDP_DST_PORT = 20000

def ip_checksum(data):
    """Calculate IP header checksum"""
    if len(data) % 2 == 1:
        data += b'\x00'
    
    s = sum(struct.unpack('!%dH' % (len(data) // 2), data))
    s = (s >> 16) + (s & 0xffff)
    s += s >> 16
    return ~s & 0xffff

def build_ethernet_header(dst_mac, src_mac):
    """Build 14-byte Ethernet header"""
    return dst_mac + src_mac + struct.pack('!H', ETH_TYPE_IP)

def build_ip_header(payload_len, src_ip, dst_ip):
    """Build 20-byte IP header"""
    total_len = 20 + 8 + payload_len  # IP + UDP + payload
    
    # IP header without checksum
    header = struct.pack(
        '!BBHHHBBH',
        (IP_VERSION << 4) | IP_IHL,  # Version + IHL
        IP_TOS,
        total_len,
        IP_ID,
        IP_FLAGS_DF,
        IP_TTL,
        IP_PROTO_UDP,
        0  # Checksum placeholder
    )
    
    # Add source and dest IPs
    header += struct.pack('!4s4s',
                         bytes(map(int, src_ip.split('.'))),
                         bytes(map(int, dst_ip.split('.'))))
    
    # Calculate and insert checksum
    checksum = ip_checksum(header)
    header = header[:10] + struct.pack('!H', checksum) + header[12:]
    
    return header

def build_udp_header(payload_len, src_port, dst_port):
    """Build 8-byte UDP header"""
    udp_len = 8 + payload_len
    return struct.pack(
        '!HHHH',
        src_port,
        dst_port,
        udp_len,
        0  # Checksum (optional for IPv4)
    )

def write_pcap_header(f):
    """Write PCAP global header"""
    f.write(struct.pack(
        '<IHHIIII',
        0xa1b2c3d4,  # Magic number
        2,           # Major version
        4,           # Minor version
        0,           # Timezone offset
        0,           # Timestamp accuracy
        65535,       # Snaplen
        1            # Link type (Ethernet)
    ))

def write_pcap_packet(f, timestamp_sec, timestamp_usec, packet):
    """Write PCAP packet header + data"""
    packet_len = len(packet)
    
    f.write(struct.pack(
        '<IIII',
        timestamp_sec,
        timestamp_usec,
        packet_len,
        packet_len
    ))
    f.write(packet)

def itch_to_pcap(itch_file, pcap_file, max_msgs_per_udp=20):
    """Convert ITCH file to PCAP"""
    
    print(f"Converting {itch_file} → {pcap_file}")
    print(f"Max messages per UDP datagram: {max_msgs_per_udp}")
    print()
    
    with open(itch_file, 'rb') as fin, open(pcap_file, 'wb') as fout:
        write_pcap_header(fout)
        
        packet_count = 0
        message_count = 0
        timestamp_sec = int(datetime.now().timestamp())
        timestamp_usec = 0
        
        while True:
            # Accumulate multiple ITCH messages into one UDP datagram
            udp_payload = b''
            msgs_in_packet = 0
            
            while msgs_in_packet < max_msgs_per_udp:
                # Read message length (2 bytes, big-endian)
                length_bytes = fin.read(2)
                if not length_bytes:
                    break
                
                msg_len = struct.unpack('>H', length_bytes)[0]
                
                # Read rest of message
                msg_data = fin.read(msg_len - 2)
                if len(msg_data) != msg_len - 2:
                    break
                
                # Add to UDP payload
                udp_payload += length_bytes + msg_data
                msgs_in_packet += 1
                message_count += 1
            
            if not udp_payload:
                break
            
            # Build packet: Ethernet + IP + UDP + ITCH messages
            eth_header = build_ethernet_header(ETH_DST_MAC, ETH_SRC_MAC)
            ip_header = build_ip_header(len(udp_payload), IP_SRC, IP_DST)
            udp_header = build_udp_header(len(udp_payload), UDP_SRC_PORT, UDP_DST_PORT)
            
            packet = eth_header + ip_header + udp_header + udp_payload
            
            # Write to PCAP
            write_pcap_packet(fout, timestamp_sec, timestamp_usec, packet)
            packet_count += 1
            
            # Advance timestamp (10 microseconds per packet)
            timestamp_usec += 10
            if timestamp_usec >= 1000000:
                timestamp_sec += 1
                timestamp_usec = 0
            
            if packet_count % 1000 == 0:
                print(f"  Packets: {packet_count}, Messages: {message_count}", end='\r')
        
        print(f"\n✓ Conversion complete")
        print(f"  Total packets: {packet_count}")
        print(f"  Total ITCH messages: {message_count}")
        print(f"  Output: {pcap_file}")

def main():
    parser = argparse.ArgumentParser(
        description='Convert ITCH binary to PCAP with network headers'
    )
    parser.add_argument('input', help='Input ITCH file')
    parser.add_argument('output', help='Output PCAP file')
    parser.add_argument('-m', '--max-msgs', type=int, default=20,
                       help='Max ITCH messages per UDP packet (default: 20)')
    
    args = parser.parse_args()
    
    try:
        itch_to_pcap(args.input, args.output, args.max_msgs)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
