#!/bin/bash
# -----------------------------------------------------------------------------
# setup_hugepages.sh - Configure hugepages for T2T DMA buffers
#
# Requirements:
#   - Run as root
#   - 2MB hugepages support in kernel
#
# Usage:
#   sudo ./setup_hugepages.sh [num_pages]
#
# Default allocates 4 hugepages (8 MB) which is enough for:
#   - 64K entry DMA ring (4 MB)
#   - Headroom for other allocations
# -----------------------------------------------------------------------------

set -e

NUM_PAGES=${1:-4}
HUGEPAGE_SIZE_KB=2048  # 2 MB

echo "T2T Hugepage Setup"
echo "=================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check current hugepage configuration
echo "Current hugepage configuration:"
echo "  Hugepage size:    $(cat /proc/meminfo | grep Hugepagesize | awk '{print $2}') kB"
echo "  Total hugepages:  $(cat /proc/meminfo | grep HugePages_Total | awk '{print $2}')"
echo "  Free hugepages:   $(cat /proc/meminfo | grep HugePages_Free | awk '{print $2}')"
echo ""

# Calculate required memory
REQUIRED_MB=$((NUM_PAGES * HUGEPAGE_SIZE_KB / 1024))
echo "Requesting $NUM_PAGES hugepages ($REQUIRED_MB MB)"

# Allocate hugepages
echo "$NUM_PAGES" > /proc/sys/vm/nr_hugepages

# Verify allocation
ALLOCATED=$(cat /proc/sys/vm/nr_hugepages)
if [ "$ALLOCATED" -lt "$NUM_PAGES" ]; then
    echo "Warning: Only allocated $ALLOCATED of $NUM_PAGES requested hugepages"
    echo "         System may be low on contiguous memory"
    echo "         Try rebooting or reducing the request"
fi

# Mount hugetlbfs if not already mounted
MOUNT_POINT=/dev/hugepages
if ! mountpoint -q $MOUNT_POINT 2>/dev/null; then
    echo "Mounting hugetlbfs at $MOUNT_POINT"
    mkdir -p $MOUNT_POINT
    mount -t hugetlbfs nodev $MOUNT_POINT
fi

# Set permissions for non-root access
chmod 1777 $MOUNT_POINT

echo ""
echo "Final hugepage configuration:"
echo "  Total hugepages:  $(cat /proc/meminfo | grep HugePages_Total | awk '{print $2}')"
echo "  Free hugepages:   $(cat /proc/meminfo | grep HugePages_Free | awk '{print $2}')"
echo ""
echo "Hugepage setup complete."
echo ""
echo "To make this persistent across reboots, add to /etc/sysctl.conf:"
echo "  vm.nr_hugepages = $NUM_PAGES"
echo ""
echo "And add to /etc/fstab:"
echo "  hugetlbfs $MOUNT_POINT hugetlbfs mode=1777 0 0"
