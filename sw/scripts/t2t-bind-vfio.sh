#!/bin/bash
#
# t2t-bind-vfio.sh - Bind T2T FPGA device to VFIO driver for userspace access
#
# Usage:
#   sudo ./t2t-bind-vfio.sh [BDF]
#
# If BDF is not specified, the script will search for the T2T device.
#

set -e

# T2T device identifiers
VENDOR_ID="1172"
DEVICE_ID="0001"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check for root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Find device BDF
if [ -n "$1" ]; then
    BDF="$1"
else
    log_info "Searching for T2T device (${VENDOR_ID}:${DEVICE_ID})..."
    BDF=$(lspci -d ${VENDOR_ID}:${DEVICE_ID} -D 2>/dev/null | head -1 | cut -d' ' -f1)
    
    if [ -z "$BDF" ]; then
        log_error "T2T device not found"
        exit 1
    fi
fi

log_info "Found device at $BDF"

# Get device info
DEVICE_PATH="/sys/bus/pci/devices/$BDF"

if [ ! -d "$DEVICE_PATH" ]; then
    log_error "Device path not found: $DEVICE_PATH"
    exit 1
fi

# Read vendor/device IDs
VENDOR=$(cat "$DEVICE_PATH/vendor" | sed 's/0x//')
DEVICE=$(cat "$DEVICE_PATH/device" | sed 's/0x//')

log_info "Vendor: $VENDOR, Device: $DEVICE"

# Get IOMMU group
IOMMU_GROUP=$(readlink "$DEVICE_PATH/iommu_group" | xargs basename)

if [ -z "$IOMMU_GROUP" ]; then
    log_error "Device is not in an IOMMU group. Is IOMMU enabled?"
    log_info "Add 'intel_iommu=on iommu=pt' to kernel command line"
    exit 1
fi

log_info "IOMMU group: $IOMMU_GROUP"

# Check if there are other devices in the group
GROUP_DEVICES=$(ls /sys/kernel/iommu_groups/$IOMMU_GROUP/devices/)
NUM_DEVICES=$(echo "$GROUP_DEVICES" | wc -l)

if [ "$NUM_DEVICES" -gt 1 ]; then
    log_warn "Multiple devices in IOMMU group $IOMMU_GROUP:"
    echo "$GROUP_DEVICES"
    log_warn "All devices in the group will be bound to VFIO"
fi

# Load VFIO modules
log_info "Loading VFIO modules..."
modprobe vfio-pci

# Unbind from current driver
CURRENT_DRIVER=$(readlink "$DEVICE_PATH/driver" 2>/dev/null | xargs basename || echo "none")
log_info "Current driver: $CURRENT_DRIVER"

if [ "$CURRENT_DRIVER" != "none" ] && [ "$CURRENT_DRIVER" != "vfio-pci" ]; then
    log_info "Unbinding from $CURRENT_DRIVER..."
    echo "$BDF" > "$DEVICE_PATH/driver/unbind" 2>/dev/null || true
fi

# Bind all devices in the group to vfio-pci
for DEV in $GROUP_DEVICES; do
    DEV_PATH="/sys/bus/pci/devices/$DEV"
    DEV_VENDOR=$(cat "$DEV_PATH/vendor" | sed 's/0x//')
    DEV_DEVICE=$(cat "$DEV_PATH/device" | sed 's/0x//')
    
    # Check current driver
    DEV_DRIVER=$(readlink "$DEV_PATH/driver" 2>/dev/null | xargs basename || echo "none")
    
    if [ "$DEV_DRIVER" = "vfio-pci" ]; then
        log_info "$DEV already bound to vfio-pci"
        continue
    fi
    
    # Unbind if needed
    if [ "$DEV_DRIVER" != "none" ]; then
        log_info "Unbinding $DEV from $DEV_DRIVER..."
        echo "$DEV" > "$DEV_PATH/driver/unbind" 2>/dev/null || true
    fi
    
    # Register device ID with vfio-pci
    log_info "Binding $DEV to vfio-pci..."
    echo "$DEV_VENDOR $DEV_DEVICE" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    
    # Try direct bind
    echo "$DEV" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
done

# Verify binding
sleep 0.5
NEW_DRIVER=$(readlink "$DEVICE_PATH/driver" 2>/dev/null | xargs basename || echo "none")

if [ "$NEW_DRIVER" = "vfio-pci" ]; then
    log_info "Successfully bound to vfio-pci"
else
    log_error "Failed to bind to vfio-pci (current: $NEW_DRIVER)"
    exit 1
fi

# Set permissions on VFIO group device
VFIO_DEV="/dev/vfio/$IOMMU_GROUP"

if [ -e "$VFIO_DEV" ]; then
    chmod 0666 "$VFIO_DEV"
    log_info "Set permissions on $VFIO_DEV"
else
    log_warn "VFIO device $VFIO_DEV not found"
fi

# Set permissions on VFIO container
if [ -e "/dev/vfio/vfio" ]; then
    chmod 0666 /dev/vfio/vfio
fi

log_info "Done! Device $BDF is ready for userspace access"
log_info "VFIO group device: /dev/vfio/$IOMMU_GROUP"
