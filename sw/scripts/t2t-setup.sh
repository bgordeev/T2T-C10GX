#!/bin/bash
#
# t2t-setup.sh - Initialize and configure T2T-C10GX device
#
# Usage:
#   sudo ./t2t-setup.sh [config_dir]
#
# This script:
#   1. Binds device to VFIO driver
#   2. Allocates hugepages for DMA
#   3. Loads symbol table
#   4. Loads reference prices
#   5. Configures device parameters
#

set -e

# Default configuration directory
CONFIG_DIR="${1:-/etc/t2t}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

#=============================================================================
# Step 1: Bind device to VFIO
#=============================================================================
log_info "Step 1: Binding device to VFIO..."

# Check IOMMU
if ! dmesg | grep -q "IOMMU enabled"; then
    log_warn "IOMMU may not be enabled. Add 'intel_iommu=on iommu=pt' to kernel cmdline."
fi

# Load VFIO modules
modprobe vfio-pci

# Find and bind device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/t2t-bind-vfio.sh" ]; then
    "$SCRIPT_DIR/t2t-bind-vfio.sh"
else
    log_warn "t2t-bind-vfio.sh not found, assuming device already bound"
fi

#=============================================================================
# Step 2: Allocate hugepages
#=============================================================================
log_info "Step 2: Allocating hugepages for DMA..."

# Check current hugepages
CURRENT_HP=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)

# Need at least 4 hugepages (8MB) for DMA ring
REQUIRED_HP=4

if [ "$CURRENT_HP" -lt "$REQUIRED_HP" ]; then
    log_info "Allocating $REQUIRED_HP hugepages..."
    echo $REQUIRED_HP > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    
    # Verify allocation
    ALLOCATED=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
    if [ "$ALLOCATED" -lt "$REQUIRED_HP" ]; then
        log_error "Failed to allocate hugepages (got $ALLOCATED, need $REQUIRED_HP)"
        log_info "Try: echo 'vm.nr_hugepages=$REQUIRED_HP' >> /etc/sysctl.conf && sysctl -p"
        exit 1
    fi
fi

# Mount hugetlbfs if not mounted
if ! mount | grep -q "hugetlbfs"; then
    log_info "Mounting hugetlbfs..."
    mkdir -p /mnt/hugepages
    mount -t hugetlbfs nodev /mnt/hugepages
fi

log_info "Hugepages: $(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages) x 2MB"

#=============================================================================
# Step 3: Configure device
#=============================================================================
log_info "Step 3: Configuring device..."

# Find t2t_ctl binary
T2T_CTL=""
for path in "$SCRIPT_DIR/../build/t2t_ctl" "/usr/local/bin/t2t_ctl" "/usr/bin/t2t_ctl"; do
    if [ -x "$path" ]; then
        T2T_CTL="$path"
        break
    fi
done

if [ -z "$T2T_CTL" ]; then
    log_error "t2t_ctl not found. Build it first with: cd sw && mkdir build && cd build && cmake .. && make"
    exit 1
fi

# Disable device during configuration
log_info "Disabling device for configuration..."
$T2T_CTL disable

# Load symbol table
SYMBOLS_FILE="${CONFIG_DIR}/symbols.csv"
if [ -f "$SYMBOLS_FILE" ]; then
    log_info "Loading symbols from $SYMBOLS_FILE..."
    $T2T_CTL load-symbols "$SYMBOLS_FILE"
else
    log_warn "Symbol file not found: $SYMBOLS_FILE"
fi

# Load reference prices
PRICES_FILE="${CONFIG_DIR}/ref_prices.csv"
if [ -f "$PRICES_FILE" ]; then
    log_info "Loading reference prices from $PRICES_FILE..."
    $T2T_CTL load-prices "$PRICES_FILE"
else
    log_warn "Reference prices file not found: $PRICES_FILE"
fi

# Apply configuration from config file (if exists)
CONFIG_FILE="${CONFIG_DIR}/t2t.conf"
if [ -f "$CONFIG_FILE" ]; then
    log_info "Applying configuration from $CONFIG_FILE..."
    source "$CONFIG_FILE"
    
    # Apply settings
    [ -n "$PRICE_BAND_BPS" ] && $T2T_CTL set 0x008 $(printf "0x%x" $PRICE_BAND_BPS)
    [ -n "$TOKEN_RATE" ] && $T2T_CTL set 0x00C $(printf "0x%x" $TOKEN_RATE)
    [ -n "$STALE_USEC" ] && $T2T_CTL set 0x014 $(printf "0x%x" $STALE_USEC)
fi

#=============================================================================
# Step 4: Enable device
#=============================================================================
log_info "Step 4: Enabling device..."
$T2T_CTL enable

#=============================================================================
# Step 5: Verify
#=============================================================================
log_info "Step 5: Verifying configuration..."
$T2T_CTL info

log_info "Setup complete!"
log_info ""
log_info "Next steps:"
log_info "  - Monitor:  t2t_ctl monitor"
log_info "  - Stats:    t2t_ctl info"
log_info "  - Latency:  t2t_ctl bench"
