#!/bin/bash
# ============================================================================
# setup_replay_network.sh - Configure network interface for ITCH replay
# Description: Prepares 10G NIC for high-speed packet replay to FPGA
# ============================================================================

set -e

# Configuration
IFACE="${1:-enp0s31f6}"  # Default interface, override with arg
TARGET_IP="192.168.10.1"
FPGA_IP="192.168.10.2"
NETMASK="255.255.255.0"

echo "=================================================="
echo "ITCH Replay Network Setup"
echo "=================================================="
echo "Interface: $IFACE"
echo "Host IP:   $TARGET_IP"
echo "FPGA IP:   $FPGA_IP"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root" 
   echo "Usage: sudo $0 [interface_name]"
   exit 1
fi

# Check if interface exists
if ! ip link show "$IFACE" &>/dev/null; then
    echo "Error: Interface $IFACE not found"
    echo
    echo "Available interfaces:"
    ip link show | grep -E "^[0-9]+" | cut -d: -f2 | tr -d ' '
    exit 1
fi

echo "[1/6] Bringing down interface..."
ip link set "$IFACE" down

echo "[2/6] Disabling hardware offloads (for accurate replay)..."
# Disable all offloading features that could interfere with timing
ethtool -K "$IFACE" gro off 2>/dev/null || echo "  GRO already off"
ethtool -K "$IFACE" lro off 2>/dev/null || echo "  LRO already off"
ethtool -K "$IFACE" gso off 2>/dev/null || echo "  GSO already off"
ethtool -K "$IFACE" tso off 2>/dev/null || echo "  TSO already off"
ethtool -K "$IFACE" sg off 2>/dev/null || echo "  SG already off"
ethtool -K "$IFACE" tx off 2>/dev/null || echo "  TX checksum already off"
ethtool -K "$IFACE" rx off 2>/dev/null || echo "  RX checksum already off"

echo "[3/6] Setting MTU to jumbo frames (9000 bytes)..."
ip link set "$IFACE" mtu 9000

echo "[4/6] Configuring IP address..."
ip addr flush dev "$IFACE"
ip addr add "$TARGET_IP/$NETMASK" dev "$IFACE"

echo "[5/6] Bringing up interface..."
ip link set "$IFACE" up

echo "[6/6] Verifying configuration..."
sleep 1
ip addr show "$IFACE"

# Check if interface is up
if ip link show "$IFACE" | grep -q "state UP"; then
    echo
    echo "✓ Success! Network interface ready for ITCH replay"
    echo
    echo "Configuration:"
    echo "  - Hardware offloads: DISABLED (for timing accuracy)"
    echo "  - MTU: 9000 bytes (jumbo frames)"
    echo "  - IP: $TARGET_IP"
    echo
    echo "Next steps:"
    echo "  1. Connect $IFACE to FPGA SFP+ port with fiber/copper"
    echo "  2. Run: ./replay_itch.sh <pcap_file>"
    echo
else
    echo
    echo "✗ Warning: Interface may not be fully operational"
    echo "  Check cable connection and link status"
    exit 1
fi

# Disable firewall for this interface (optional)
read -p "Disable firewall for $IFACE? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if command -v ufw &>/dev/null; then
        ufw allow in on "$IFACE"
        echo "✓ UFW configured"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=trusted --add-interface="$IFACE"
        echo "✓ firewalld configured"
    fi
fi

# Show link status
echo
echo "Link status:"
ethtool "$IFACE" | grep -E "Speed|Duplex|Link detected"

exit 0
