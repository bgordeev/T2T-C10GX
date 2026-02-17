#!/bin/bash
# ============================================================================
# loopback_test.sh - Test PCAP replay in loopback mode
# Description: Replays traffic and captures it back for validation
# ============================================================================

set -e

PCAP_FILE="${1}"
IFACE="${2:-lo}"  # Default to loopback
CAPTURE_FILE="captured_$(date +%s).pcap"
REPLAY_COUNT=100

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <pcap_file> [interface]"
    echo
    echo "Tests PCAP replay by capturing traffic back"
    echo
    echo "Examples:"
    echo "  $0 test.pcap           # Loopback test"
    echo "  $0 test.pcap eth0      # Test on eth0"
    exit 1
}

if [[ -z "$PCAP_FILE" || ! -f "$PCAP_FILE" ]]; then
    usage
fi

if [[ $EUID -ne 0 ]]; then
   echo "Error: Must run as root"
   exit 1
fi

echo "=================================================="
echo "PCAP Loopback Test"
echo "=================================================="
echo "Input PCAP:  $PCAP_FILE"
echo "Interface:   $IFACE"
echo "Capture:     $CAPTURE_FILE"
echo

# Check dependencies
for cmd in tcpreplay tcpdump tshark; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: $cmd not installed"
        echo "Install: sudo apt install tcpreplay wireshark"
        exit 1
    fi
done

# Start capture in background
echo "[1/4] Starting packet capture..."
tcpdump -i "$IFACE" -w "$CAPTURE_FILE" -s 65535 udp &
TCPDUMP_PID=$!
sleep 1

# Replay packets
echo "[2/4] Replaying packets..."
tcpreplay --intf1="$IFACE" --loop=$REPLAY_COUNT "$PCAP_FILE" 2>&1 | grep -E "packets|successful"

sleep 1

# Stop capture
echo "[3/4] Stopping capture..."
kill $TCPDUMP_PID
sleep 1

# Analyze captured traffic
echo "[4/4] Analyzing captured traffic..."
echo

if [[ ! -f "$CAPTURE_FILE" || ! -s "$CAPTURE_FILE" ]]; then
    echo "✗ No packets captured"
    exit 1
fi

CAPTURED_PACKETS=$(tshark -r "$CAPTURE_FILE" 2>/dev/null | wc -l)
echo "Captured packets: $CAPTURED_PACKETS"

if [[ $CAPTURED_PACKETS -gt 0 ]]; then
    echo -e "${GREEN}✓ Loopback test passed${NC}"
    echo
    echo "Packet details:"
    tshark -r "$CAPTURE_FILE" -c 5 2>/dev/null | head -5
    echo
    echo "Saved capture: $CAPTURE_FILE"
else
    echo "✗ Test failed - no packets captured"
    exit 1
fi
