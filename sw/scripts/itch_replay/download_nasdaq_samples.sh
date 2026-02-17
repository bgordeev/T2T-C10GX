#!/bin/bash
# ============================================================================
# download_nasdaq_samples.sh - Download NASDAQ sample ITCH files
# Description: Fetches official ITCH 5.0 sample data from NASDAQ FTP
# ============================================================================

set -e

# Configuration
FTP_SERVER="ftp.nasdaqtrader.com"
FTP_PATH="/files/itch"
DOWNLOAD_DIR="./nasdaq_samples"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================================="
echo "NASDAQ ITCH Sample Data Downloader"
echo "=================================================="
echo

# Check dependencies
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    echo "Error: wget or curl required"
    echo "Install: sudo apt install wget"
    exit 1
fi

# Create download directory
mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"

echo "Download directory: $(pwd)"
echo

# Available sample files (as of 2024)
declare -A SAMPLES
SAMPLES[1]="sample5.txt.gz|Small sample file (5 MB)|quick test"
SAMPLES[2]="01302019.NASDAQ_ITCH50.gz|Full day NASDAQ Jan 30 2019 (8 GB)|full day"
SAMPLES[3]="01302019.BX_ITCH50.gz|Full day BX Jan 30 2019 (2 GB)|alternative"

echo "Available sample files:"
echo
for key in "${!SAMPLES[@]}"; do
    IFS='|' read -r filename desc tag <<< "${SAMPLES[$key]}"
    echo "  [$key] $desc"
    echo "      File: $filename"
    echo
done

read -p "Select file to download (1-3, or 'all'): " choice

download_file() {
    local filename=$1
    local url="ftp://${FTP_SERVER}${FTP_PATH}/${filename}"
    
    echo
    echo -e "${YELLOW}Downloading: $filename${NC}"
    echo "From: $url"
    echo
    
    if command -v wget &>/dev/null; then
        wget -c "$url" -O "$filename"
    else
        curl -C - -o "$filename" "$url"
    fi
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Downloaded: $filename${NC}"
        
        # Show file info
        size=$(stat -f%z "$filename" 2>/dev/null || stat -c%s "$filename")
        size_mb=$(echo "scale=1; $size / 1048576" | bc)
        echo "  Size: ${size_mb} MB"
        
        # Decompress if gzipped
        if [[ "$filename" == *.gz ]]; then
            echo "  Decompressing..."
            gunzip -k "$filename"
            decompressed="${filename%.gz}"
            echo -e "${GREEN}  ✓ Created: $decompressed${NC}"
        fi
    else
        echo "Error downloading $filename"
        return 1
    fi
}

case $choice in
    1)
        IFS='|' read -r filename _ _ <<< "${SAMPLES[1]}"
        download_file "$filename"
        ;;
    2)
        IFS='|' read -r filename _ _ <<< "${SAMPLES[2]}"
        download_file "$filename"
        ;;
    3)
        IFS='|' read -r filename _ _ <<< "${SAMPLES[3]}"
        download_file "$filename"
        ;;
    all)
        for key in "${!SAMPLES[@]}"; do
            IFS='|' read -r filename _ _ <<< "${SAMPLES[$key]}"
            download_file "$filename"
        done
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo
echo "=================================================="
echo "Download complete!"
echo "=================================================="
echo
echo "Files in: $(pwd)"
ls -lh *.txt *.ITCH50 2>/dev/null || echo "No decompressed files yet"
echo
echo "Next steps:"
echo "  1. Convert to PCAP: ./itch_to_pcap.py sample5.txt sample5.pcap"
echo "  2. Replay to FPGA: sudo ./replay_itch.sh sample5.pcap"
echo
