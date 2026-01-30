#!/bin/bash
# -----------------------------------------------------------------------------
# bind_vfio.sh - Bind T2T PCIe device to VFIO driver for userspace access
#
# Requirements:
#   - Run as root
#   - VFIO and IOMMU enabled in kernel
#   - IOMMU enabled in BIOS
#
# Usage:
#   sudo ./bind_vfio.sh [BDF]
#   sudo ./bind_vfio.sh 0000:03:00.0
#
# -----------------------------------------------------------------------------

set -e

# T2T device identifiers
VENDOR_ID="1172"  # Intel FPGA
DEVICE_ID="0001"  # T2T custom

echo "T2T VFIO Binding Script"
echo "======================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check IOMMU status
if ! dmesg | grep -qi "IOMMU enabled"; then
    echo "Warning: IOMMU may not be enabled"
    echo "         Check BIOS settings and kernel parameters"
    echo "         Add 'intel_iommu=on' or 'amd_iommu=on' to kernel cmdline"
fi

# Load VFIO modules
echo "Loading VFIO modules..."
modprobe vfio
modprobe vfio-pci

# Find device BDF
if [ -n "$1" ]; then
    BDF="$1"
else
    echo "Scanning for T2T devices..."
    BDF=$(lspci -d ${VENDOR_ID}:${DEVICE_ID} -D 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -z "$BDF" ]; then
        echo "Error: No T2T device found (vendor=$VENDOR_ID, device=$DEVICE_ID)"
        echo ""
        echo "Available FPGA devices:"
        lspci -d ${VENDOR_ID}: 2>/dev/null || echo "  (none)"
        exit 1
    fi
fi

echo "Target device: $BDF"

# Get device info
DEVICE_PATH="/sys/bus/pci/devices/$BDF"
if [ ! -d "$DEVICE_PATH" ]; then
    echo "Error: Device $BDF not found in sysfs"
    exit 1
fi

CURRENT_DRIVER=$(basename $(readlink -f "$DEVICE_PATH/driver" 2>/dev/null) 2>/dev/null || echo "none")
IOMMU_GROUP=$(basename $(readlink -f "$DEVICE_PATH/iommu_group" 2>/dev/null) 2>/dev/null || echo "none")

echo "Current driver:  $CURRENT_DRIVER"
echo "IOMMU group:     $IOMMU_GROUP"

if [ "$IOMMU_GROUP" = "none" ]; then
    echo "Error: Device not in an IOMMU group"
    echo "       IOMMU may not be enabled"
    exit 1
fi

# Unbind from current driver
if [ "$CURRENT_DRIVER" != "none" ] && [ "$CURRENT_DRIVER" != "vfio-pci" ]; then
    echo ""
    echo "Unbinding from $CURRENT_DRIVER..."
    echo "$BDF" > "$DEVICE_PATH/driver/unbind" 2>/dev/null || true
fi

# Get vendor:device for VFIO
VENDOR=$(cat "$DEVICE_PATH/vendor" | sed 's/0x//')
DEVICE=$(cat "$DEVICE_PATH/device" | sed 's/0x//')

# Bind to VFIO
echo "Binding to vfio-pci..."
echo "${VENDOR} ${DEVICE}" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
echo "$BDF" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

# Verify binding
sleep 0.5
NEW_DRIVER=$(basename $(readlink -f "$DEVICE_PATH/driver" 2>/dev/null) 2>/dev/null || echo "none")

if [ "$NEW_DRIVER" = "vfio-pci" ]; then
    echo ""
    echo "Success! Device $BDF bound to vfio-pci"
    
    # Set up permissions
    VFIO_GROUP="/dev/vfio/$IOMMU_GROUP"
    if [ -e "$VFIO_GROUP" ]; then
        chmod 666 "$VFIO_GROUP"
        echo "VFIO group device: $VFIO_GROUP (permissions set to 666)"
    fi
    
    echo ""
    echo "The device is now ready for userspace access."
    echo "Run t2t_ctl to interact with the device."
else
    echo ""
    echo "Error: Failed to bind device to vfio-pci"
    echo "Current driver: $NEW_DRIVER"
    exit 1
fi
