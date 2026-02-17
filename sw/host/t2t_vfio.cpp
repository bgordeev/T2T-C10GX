// ============================================================================
// File: t2t_vfio.cpp
// Description: VFIO helper implementation
// ============================================================================

#include "t2t_vfio.hpp"
#include <iostream>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/vfio.h>

namespace t2t {

VFIODevice::VFIODevice(const std::string& device_path)
    : container_fd_(-1), group_fd_(-1), device_fd_(-1)
{
    for (int i = 0; i < 6; i++) {
        bar_mappings_[i].addr = nullptr;
        bar_mappings_[i].size = 0;
        bar_mappings_[i].mapped = false;
    }
    
    if (!setup_vfio()) {
        std::cerr << "Failed to setup VFIO" << std::endl;
        return;
    }
    
    device_fd_ = ioctl(group_fd_, VFIO_GROUP_GET_DEVICE_FD, device_path.c_str());
    if (device_fd_ < 0) {
        std::cerr << "Failed to get device FD for " << device_path << std::endl;
        return;
    }
    
    struct vfio_device_info device_info = { .argsz = sizeof(device_info) };
    if (ioctl(device_fd_, VFIO_DEVICE_GET_INFO, &device_info) < 0) {
        std::cerr << "Failed to get device info" << std::endl;
        close(device_fd_);
        device_fd_ = -1;
        return;
    }
    
    std::cout << "VFIO device opened: " << device_path 
              << " (" << device_info.num_regions << " regions)" << std::endl;
}

VFIODevice::~VFIODevice() {
    for (int i = 0; i < 6; i++) {
        if (bar_mappings_[i].mapped) {
            unmap_bar(i);
        }
    }
    
    if (device_fd_ >= 0) close(device_fd_);
    if (group_fd_ >= 0) close(group_fd_);
    if (container_fd_ >= 0) close(container_fd_);
}

bool VFIODevice::setup_vfio() {
    container_fd_ = open("/dev/vfio/vfio", O_RDWR);
    if (container_fd_ < 0) {
        std::cerr << "Failed to open /dev/vfio/vfio" << std::endl;
        return false;
    }
    
    int vfio_version = ioctl(container_fd_, VFIO_GET_API_VERSION);
    if (vfio_version != VFIO_API_VERSION) {
        std::cerr << "VFIO API version mismatch" << std::endl;
        return false;
    }
    
    if (!ioctl(container_fd_, VFIO_CHECK_EXTENSION, VFIO_TYPE1_IOMMU)) {
        std::cerr << "VFIO Type1 IOMMU not supported" << std::endl;
        return false;
    }
    
    group_fd_ = open("/dev/vfio/0", O_RDWR);
    if (group_fd_ < 0) {
        std::cerr << "Failed to open VFIO group" << std::endl;
        return false;
    }
    
    struct vfio_group_status group_status = { .argsz = sizeof(group_status) };
    if (ioctl(group_fd_, VFIO_GROUP_GET_STATUS, &group_status) < 0) {
        std::cerr << "Failed to get group status" << std::endl;
        return false;
    }
    
    if (!(group_status.flags & VFIO_GROUP_FLAGS_VIABLE)) {
        std::cerr << "VFIO group not viable" << std::endl;
        return false;
    }
    
    if (ioctl(group_fd_, VFIO_GROUP_SET_CONTAINER, &container_fd_) < 0) {
        std::cerr << "Failed to set group container" << std::endl;
        return false;
    }
    
    if (ioctl(container_fd_, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU) < 0) {
        std::cerr << "Failed to set IOMMU type" << std::endl;
        return false;
    }
    
    return true;
}

void* VFIODevice::map_bar(int bar_index) {
    if (bar_index < 0 || bar_index >= 6) return nullptr;
    if (bar_mappings_[bar_index].mapped) return bar_mappings_[bar_index].addr;
    
    struct vfio_region_info region_info = { .argsz = sizeof(region_info) };
    region_info.index = bar_index;
    
    if (ioctl(device_fd_, VFIO_DEVICE_GET_REGION_INFO, &region_info) < 0) {
        std::cerr << "Failed to get region info for BAR" << bar_index << std::endl;
        return nullptr;
    }
    
    if (region_info.size == 0) return nullptr;
    
    void* addr = mmap(nullptr, region_info.size,
                      PROT_READ | PROT_WRITE, MAP_SHARED,
                      device_fd_, region_info.offset);
    
    if (addr == MAP_FAILED) {
        std::cerr << "Failed to mmap BAR" << bar_index << std::endl;
        return nullptr;
    }
    
    bar_mappings_[bar_index].addr = addr;
    bar_mappings_[bar_index].size = region_info.size;
    bar_mappings_[bar_index].mapped = true;
    
    std::cout << "Mapped BAR" << bar_index << ": " 
              << region_info.size << " bytes" << std::endl;
    
    return addr;
}

void VFIODevice::unmap_bar(int bar_index) {
    if (bar_index < 0 || bar_index >= 6) return;
    if (!bar_mappings_[bar_index].mapped) return;
    
    munmap(bar_mappings_[bar_index].addr, bar_mappings_[bar_index].size);
    bar_mappings_[bar_index].addr = nullptr;
    bar_mappings_[bar_index].size = 0;
    bar_mappings_[bar_index].mapped = false;
}

size_t VFIODevice::get_bar_size(int bar_index) const {
    if (bar_index < 0 || bar_index >= 6) return 0;
    return bar_mappings_[bar_index].size;
}

void* VFIODevice::alloc_hugepage(size_t size) {
    size_t aligned_size = (size + 0x1FFFFF) & ~0x1FFFFF;
    
    void* addr = mmap(nullptr, aligned_size,
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
                      -1, 0);
    
    if (addr == MAP_FAILED) {
        std::cerr << "Failed to allocate hugepage" << std::endl;
        return nullptr;
    }
    
    if (mlock(addr, aligned_size) < 0) {
        std::cerr << "Failed to lock hugepage" << std::endl;
        munmap(addr, aligned_size);
        return nullptr;
    }
    
    std::cout << "Allocated " << (aligned_size / 1024 / 1024) 
              << " MB hugepage" << std::endl;
    
    return addr;
}

void VFIODevice::free_hugepage(void* addr, size_t size) {
    if (!addr) return;
    size_t aligned_size = (size + 0x1FFFFF) & ~0x1FFFFF;
    munlock(addr, aligned_size);
    munmap(addr, aligned_size);
}

uint64_t VFIODevice::get_physical_addr(void* virt_addr) {
    int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
    if (pagemap_fd < 0) return 0;
    
    uint64_t page_offset = (reinterpret_cast<uint64_t>(virt_addr) / 4096) * 8;
    uint64_t entry;
    
    if (pread(pagemap_fd, &entry, sizeof(entry), page_offset) != sizeof(entry)) {
        close(pagemap_fd);
        return 0;
    }
    
    close(pagemap_fd);
    
    uint64_t pfn = entry & ((1ULL << 55) - 1);
    if (pfn == 0) return 0;
    
    return (pfn * 4096) + (reinterpret_cast<uint64_t>(virt_addr) % 4096);
}

} // namespace t2t
