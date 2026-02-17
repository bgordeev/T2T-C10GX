// ============================================================================
// File: t2t_vfio.hpp
// Description: VFIO (Virtual Function I/O) helper for direct FPGA access
// ============================================================================

#ifndef T2T_VFIO_HPP
#define T2T_VFIO_HPP

#include <string>
#include <cstdint>
#include <cstddef>

namespace t2t {

class VFIODevice {
public:
    explicit VFIODevice(const std::string& device_path);
    ~VFIODevice();
    
    // Disable copy
    VFIODevice(const VFIODevice&) = delete;
    VFIODevice& operator=(const VFIODevice&) = delete;
    
    // Map a BAR into process virtual memory
    void* map_bar(int bar_index);
    void unmap_bar(int bar_index);
    size_t get_bar_size(int bar_index) const;
    
    // Allocate DMA-capable hugepage
    void* alloc_hugepage(size_t size);
    void free_hugepage(void* addr, size_t size);
    
    // Get physical address of virtual address
    uint64_t get_physical_addr(void* virt_addr);
    
    bool is_open() const { return container_fd_ >= 0 && group_fd_ >= 0; }
    int get_device_fd() const { return device_fd_; }

private:
    int container_fd_;
    int group_fd_;
    int device_fd_;
    
    struct BarMapping {
        void*  addr;
        size_t size;
        bool   mapped;
    };
    
    BarMapping bar_mappings_[6];
    
    bool setup_vfio();
};

} // namespace t2t

#endif // T2T_VFIO_HPP
