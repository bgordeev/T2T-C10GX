#!/bin/bash
# ============================================================================
# replay_itch.sh - Replay ITCH PCAP file to FPGA
# Description: Uses tcpreplay to inject ITCH market data at line rate
# ============================================================================

set -e

# Configuration
IFACE="${REPLAY_IFACE:-enp0s31f6}"
DEFAULT_MBPS=10000
DEFAULT_LOOP=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <pcap_file> [options]"
    echo
    echo "Options:"
    echo "  -i, --interface <n>   Network interface (default: $IFACE)"
    echo "  -s, --speed <mbps>       Replay speed in Mbps (default: $DEFAULT_MBPS)"
    echo "  -l, --loop <count>       Number of times to loop (default: $DEFAULT_LOOP)"
    echo "  -m, --multiplier <x>     Speed multiplier (2.0 = 2x speed)"
    echo "  -v, --verbose            Verbose output"
    echo
    echo "Examples:"
    echo "  $0 nasdaq.pcap                # Replay at 10 Gbps"
    echo "  $0 nasdaq.pcap -l 100         # Loop 100 times"
    echo "  $0 nasdaq.pcap -s 5000        # 5 Gbps"
    exit 1
}

# Check tcpreplay installed
if ! command -v tcpreplay &>/dev/null; then
    echo -e "${RED}Error: tcpreplay not installed${NC}"
    echo "Install: sudo apt install tcpreplay"
    exit 1
fi

# Parse args
PCAP_FILE=""
MBPS=$DEFAULT_MBPS
LOOP=$DEFAULT_LOOP
MULTIPLIER=""
VERBOSE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interface) IFACE="$2"; shift 2 ;;
        -s|--speed) MBPS="$2"; shift 2 ;;
        -l|--loop) LOOP="$2"; shift 2 ;;
        -m|--multiplier) MULTIPLIER="$2"; shift 2 ;;
        -v|--verbose) VERBOSE="--verbose"; shift ;;
        -h|--help) usage ;;
        *) PCAP_FILE="$1"; shift ;;
    esac
done

if [[ -z "$PCAP_FILE" || ! -f "$PCAP_FILE" ]]; then
    echo -e "${RED}Error: PCAP file not found${NC}"
    usage
fi

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: Must run as root${NC}"
   exit 1
fi

echo "ITCH Replay: $PCAP_FILE → $IFACE"
echo "Speed: ${MBPS} Mbps, Loop: ${LOOP}x"
echo

# Build command
CMD="tcpreplay --intf1=$IFACE --mbps=$MBPS"
[[ $LOOP -gt 1 ]] && CMD="$CMD --loop=$LOOP"
[[ -n "$VERBOSE" ]] && CMD="$CMD $VERBOSE"
CMD="$CMD $PCAP_FILE"

echo "Starting replay (Ctrl+C to stop)..."
$CMD

echo -e "${GREEN}✓ Done${NC}"
