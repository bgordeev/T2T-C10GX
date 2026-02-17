#!/usr/bin/env python3
"""
configure_risk.py - Configure risk gate parameters
Applies risk profiles to FPGA
"""

import sys
import subprocess

# CSR offsets
PRICE_BAND_BPS  = 0x044
TOKEN_RATE      = 0x048
POSITION_LIMIT  = 0x04C
KILL_SWITCH     = 0x050

# Risk profiles
PROFILES = {
    'default': {
        'price_band_bps': 100,      # 1.0%
        'token_rate': 1000,         # 1000 signals/ms
        'position_limit': 50000,
        'kill_switch': False,
    },
    'aggressive': {
        'price_band_bps': 200,      # 2.0%
        'token_rate': 2000,
        'position_limit': 100000,
        'kill_switch': False,
    },
    'conservative': {
        'price_band_bps': 50,       # 0.5%
        'token_rate': 500,
        'position_limit': 25000,
        'kill_switch': False,
    },
    'disabled': {
        'price_band_bps': 0,
        'token_rate': 0,
        'position_limit': 0,
        'kill_switch': True,
    },
}

def write_csr(offset, value):
    """Write CSR using csr_access.py"""
    cmd = [sys.executable, 'csr_access.py', 'write', hex(offset), str(value)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0

def apply_profile(profile_name):
    """Apply risk profile to FPGA"""
    if profile_name not in PROFILES:
        print(f"Error: Unknown profile '{profile_name}'")
        print(f"Available: {list(PROFILES.keys())}")
        return False
    
    profile = PROFILES[profile_name]
    
    print(f"\nApplying profile: {profile_name}")
    print("=" * 60)
    
    params = [
        ("Price band (bps)", PRICE_BAND_BPS, profile['price_band_bps']),
        ("Token rate", TOKEN_RATE, profile['token_rate']),
        ("Position limit", POSITION_LIMIT, profile['position_limit']),
        ("Kill switch", KILL_SWITCH, 1 if profile['kill_switch'] else 0),
    ]
    
    for name, offset, value in params:
        print(f"{name:20s} = {value:8d} ... ", end='')
        if write_csr(offset, value):
            print("[OK]")
        else:
            print("[FAIL]")
            return False
    
    return True

def main():
    if len(sys.argv) < 2:
        print("Usage: configure_risk.py <profile>")
        print("\nAvailable profiles:")
        for name in PROFILES.keys():
            print(f"  - {name}")
        return 1
    
    profile = sys.argv[1]
    
    print("Risk Parameter Configuration")
    print("=" * 60)
    
    if not apply_profile(profile):
        print("\nFailed to apply profile")
        return 1
    
    print("\nRisk parameters configured successfully")
    return 0

if __name__ == '__main__':
    sys.exit(main())
