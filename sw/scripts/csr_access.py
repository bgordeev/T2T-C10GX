#!/usr/bin/env python3
"""
csr_access.py - Direct CSR register read/write via VFIO
Low-level tool for debugging and configuration
"""

import sys
import mmap
import struct
from pathlib import Path

VFIO_DEVICE = "/dev/vfio/0"
BAR0_SIZE = 1024 * 1024  # 1 MB

class CSRAccess:
    def __init__(self, device_path=VFIO_DEVICE):
        self.fd = None
        self.bar0 = None
        
        try:
            # Open VFIO device
            self.fd = open(device_path, 'r+b', buffering=0)
            
            # Memory map BAR0
            self.bar0 = mmap.mmap(
                self.fd.fileno(),
                BAR0_SIZE,
                mmap.MAP_SHARED,
                mmap.PROT_READ | mmap.PROT_WRITE
            )
            
            print(f"Opened {device_path}, mapped {BAR0_SIZE} bytes")
            
        except Exception as e:
            print(f"Error opening device: {e}")
            if self.bar0:
                self.bar0.close()
            if self.fd:
                self.fd.close()
            raise
    
    def __del__(self):
        if self.bar0:
            self.bar0.close()
        if self.fd:
            self.fd.close()
    
    def read_u32(self, offset):
        """Read 32-bit value from CSR"""
        if offset + 4 > BAR0_SIZE:
            raise ValueError(f"Offset {hex(offset)} out of range")
        
        self.bar0.seek(offset)
        data = self.bar0.read(4)
        return struct.unpack('<I', data)[0]
    
    def write_u32(self, offset, value):
        """Write 32-bit value to CSR"""
        if offset + 4 > BAR0_SIZE:
            raise ValueError(f"Offset {hex(offset)} out of range")
        
        self.bar0.seek(offset)
        self.bar0.write(struct.pack('<I', value & 0xFFFFFFFF))
        self.bar0.flush()
    
    def read_u64(self, offset):
        """Read 64-bit value from two consecutive CSRs"""
        low = self.read_u32(offset)
        high = self.read_u32(offset + 4)
        return (high << 32) | low
    
    def write_u64(self, offset, value):
        """Write 64-bit value to two consecutive CSRs"""
        self.write_u32(offset, value & 0xFFFFFFFF)
        self.write_u32(offset + 4, (value >> 32) & 0xFFFFFFFF)

def main():
    if len(sys.argv) < 3:
        print("Usage:")
        print("  csr_access.py read <offset>")
        print("  csr_access.py write <offset> <value>")
        print()
        print("Examples:")
        print("  csr_access.py read 0x100")
        print("  csr_access.py write 0x200 0x12345678")
        return 1
    
    cmd = sys.argv[1].lower()
    offset = int(sys.argv[2], 0)
    
    try:
        csr = CSRAccess()
        
        if cmd == 'read':
            value = csr.read_u32(offset)
            print(f"{hex(offset)}: {hex(value)} ({value})")
            
        elif cmd == 'write':
            if len(sys.argv) < 4:
                print("Error: write requires a value")
                return 1
            
            value = int(sys.argv[3], 0)
            csr.write_u32(offset, value)
            print(f"Wrote {hex(value)} to {hex(offset)}")
            
            # Read back to verify
            readback = csr.read_u32(offset)
            if readback == value:
                print("Verified OK")
            else:
                print(f"Warning: readback mismatch: {hex(readback)}")
        
        else:
            print(f"Unknown command: {cmd}")
            return 1
            
    except Exception as e:
        print(f"Error: {e}")
        return 1
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
